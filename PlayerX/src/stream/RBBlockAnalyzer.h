#pragma once
/**
 * RBBlockAnalyzer.h — 块级深度信息分析器（P1 阶段）
 *
 * 设计目标（对应 码流分析架构.md §4，但采用"原生 side data"路线）：
 *   原始方案要求在 PlayerX/ffmpeg/libavcodec 里给 h264dec.c / hevcdec.c 打补丁
 *   导出块级 QP/CU/MV。实际核查发现：vendor 的 FFmpeg 中 H.264 已原生支持——
 *   h264dec.c 的 h264_export_enc_params() 会在 decode 时把逐宏块的
 *   QP / 坐标 / 尺寸 写入 AV_FRAME_DATA_VIDEO_ENC_PARAMS side data，
 *   只需在打开解码器时设置：
 *       codecCtx->export_side_data |= AV_CODEC_EXPORT_DATA_VIDEO_ENC_PARAMS;
 *   因此 H.264 **无需修改任何 FFmpeg 源码**。
 *
 *   HEVC 需要一个小补丁：hevcdec.h 中已有 qp_y_tab（逐 CTU 的 QP）和
 *   tab_mvf（逐 PU 的 MV 场），数据都已算好但未导出 side data。
 *   一期先对 HEVC 用"CTU 级 QP"降级方案（qp_y_tab 已可访问），
 *   完整 CU/MV 导出留到 P1.5。
 *
 * 职责：
 *   - 独立于播放路径，用专用 AVCodecContext 打开码流，seek 到指定帧解码；
 *   - 从 AVFrame 的 video_enc_params side data 提取逐块 QP/CU；
 *   - 提供 LRU 缓存，避免重复解码同一帧。
 *
 * 不引入任何 Qt 类型（与 RBStreamAnalyzer 的约束一致），可独立编译。
 */

#include <cstdint>
#include <string>
#include <vector>
#include <list>
#include <unordered_map>
#include <mutex>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/video_enc_params.h>
#include <libavutil/motion_vector.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

namespace rb {

// 单个块（CU / 宏块）的块级信息
struct RBBlockInfo {
    int   x = 0, y = 0, w = 0, h = 0;  // 块在图像中的位置与尺寸（像素）
    int   qp = 0;                       // 该块的亮度 QP
    bool  isSkip = false;
    bool  isIntra = true;
    float mvx = 0.f, mvy = 0.f;        // 帧间块运动矢量（帧内块为 0）
    // ── 图2 详情卡片扩展字段 ──
    int   refIdx = 0;                   // 参考索引（L0）
    int   predMode = 0;                 // 预测模式枚举：0=Intra,1=P_L0,2=B_L0L1...
    bool  hasResidual = false;          // 是否有残差（coded_block_flag 类信息）
};

// 一帧的块级分析结果
struct RBFrameBlocks {
    int                    frameIndex = -1;
    int                    width = 0, height = 0;
    std::vector<RBBlockInfo> blocks;
    double                 avgQp = 0.0;
    int                    minQp = 0, maxQp = 0;
    bool                   valid = false;   // false 表示该帧无块级数据

    // ── 底层原始画面（RGB24），供 UI 在真实画面上叠加 CU 网格 ──
    // 仅在需要显示原始画面时才填充（见 rbEnableFrameImage）。
    std::vector<uint8_t>   rgb;             // 宽*高*3，行主序；空表示不可用
    int                    rgbWidth = 0;
    int                    rgbHeight = 0;
    bool                   hasRgb = false;
};

class RBBlockAnalyzer {
public:
    RBBlockAnalyzer();
    ~RBBlockAnalyzer();

    // 打开码流，准备块级解码。成功返回 true。
    // 内部会设置 export_side_data 以启用块级导出。
    bool rbOpen(const std::string& filePath);
    void rbClose();
    bool rbIsOpen() const { return m_opened; }

    // 当前码流是否支持块级分析（H.264 原生支持；HEVC 走 CTU 降级；其它不支持）
    bool rbBlockSupport() const { return m_blockSupport; }
    // 支持的精度描述，用于 UI 提示（如 "宏块级(16×16)" / "CTU级(64×64)"）
    std::string rbBlockGranularity() const { return m_granularity; }

    int  rbWidth()  const { return m_width; }
    int  rbHeight() const { return m_height; }
    int  rbFrameCount() const { return m_frameCount; }

    // 惰性解析指定帧的块级信息。带 LRU 缓存。
    // 返回 valid=false 表示该帧取不到块级数据（UI 走降级）。
    const RBFrameBlocks& rbBlockInfoAt(int frameIndex);

    // 缓存控制
    void rbSetCacheSize(int n) { m_cacheMax = n > 1 ? n : 1; }
    void rbClearCache();

    // ── 底层原始画面 ────────────────────────────────────────────
    // 开启后，rbBlockInfoAt() 会顺带把该帧转成 RGB24 存入 RBFrameBlocks::rgb，
    // 供 UI 在真实画面上绘制 CU 划分。默认关闭以节省内存与转换开销。
    void rbEnableFrameImage(bool on) { m_wantFrameImage = on; }
    bool rbFrameImageEnabled() const { return m_wantFrameImage; }

private:
    // 把 AVFrame 转成 RGB24 写入 out（需要 swscale）
    bool convertToRgb(AVFrame* frame, RBFrameBlocks& out);
    // 解码到指定帧（内部 seek + 顺序解码），成功返回该帧的 AVFrame
    AVFrame* decodeFrameAt(int frameIndex);
    // 从 AVFrame 的 side data 提取块级信息
    bool extractBlocks(AVFrame* frame, RBFrameBlocks& out);
    // H.264：从 AVVideoEncParams（AV_VIDEO_ENC_PARAMS_H264）提取逐宏块
    bool extractH264(AVFrame* frame, RBFrameBlocks& out);
    // 从 AV_FRAME_DATA_MOTION_VECTORS 填充每个块的 MV / 参考索引（图2 需要）
    void fillMotionVectors(AVFrame* frame, RBFrameBlocks& out);
    // HEVC 降级：CTU 级 QP（来自 qp_y_tab，需补丁；一期若取不到则返回 false）
    bool extractHevcCtu(AVFrame* frame, RBFrameBlocks& out);
    void releaseFrame(AVFrame*& frame);
    bool openDecoder();

    AVFormatContext* m_fmt{nullptr};
    AVCodecContext*  m_codecCtx{nullptr};
    int              m_videoStream{-1};
    bool             m_opened{false};
    bool             m_blockSupport{false};
    std::string      m_granularity;
    int              m_width{0}, m_height{0};
    int              m_frameCount{0};
    AVCodecID        m_codecId{AV_CODEC_ID_NONE};

    // LRU 缓存：frameIndex -> RBFrameBlocks
    std::list<std::pair<int, RBFrameBlocks>>                m_cacheList;
    std::unordered_map<int, decltype(m_cacheList)::iterator> m_cacheMap;
    int                                                     m_cacheMax{8};
    // 解码器互斥锁：AVCodecContext 非线程安全。
    // 异步播放（Worker 线程）与主线程统计/取块可能同时解码，
    // 并发 avcodec_send/receive 会踩坏解码器内部状态导致崩溃（pred_regular 空指针）。
    mutable std::mutex                                      m_codecMutex;

    // 顺序解码游标：多数场景下用户是连续翻帧，缓存游标可避免重复 seek
    int              m_cursorFrame{-1};

    // 是否需要在解析块级信息时顺带导出原始画面（RGB24）
    bool             m_wantFrameImage{false};
    struct SwsContext* m_sws{nullptr};      // 复用的 swscale 上下文
};

} // namespace rb
