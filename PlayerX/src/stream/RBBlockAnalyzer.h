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
#include <memory>
#include <mutex>
#include <thread>
#include <atomic>
#include <condition_variable>

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
    int   refIdxL1 = -1;                // 参考索引（L1），未用为 -1
    int   predMode = 0;                 // 预测模式：VVC 对齐 PredMode；H.264 为 0=Intra/1=P/2=B
    int   predFlag = 0;                 // 参考方向：0=Intra,1=L0,2=L1,3=Bi（VVC PredFlag）
    bool  hasResidual = false;          // 是否有残差（coded_block_flag 类信息）
    float mvxL0 = 0.f, mvyL0 = 0.f;    // L0，像素
    float mvxL1 = 0.f, mvyL1 = 0.f;    // L1，像素
    int   treeType = 0;                 // 0=SINGLE 1=DUAL_LUMA 2=DUAL_CHROMA
    int   cqtDepth = -1;                // 解码器记录的 QT 深度；-1=未导出
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

    // ── 原始 YUV（解码器原生输出，紧凑打包）────────────────────
    // 后台解码时顺带保存，供 rbBlockInfoAt 命中时按需转 RGB（只转当前帧）。
    // 相比 RGB 更省内存（约一半），且随时可重转任意帧，不受 RGB LRU 淘汰影响。
    std::vector<uint8_t>   yuv;             // 各平面紧凑拼接
    int                    yuvW = 0, yuvH = 0;
    int                    yuvFmt = -1;     // AVPixelFormat
    int                    yuvLinesize[4] = {0,0,0,0};   // 紧凑后的行距
    int                    yuvPlaneOff[4] = {0,0,0,0};    // 各平面在 yuv 中的偏移
    int                    yuvNumPlanes = 0;
    bool                   hasYuv = false;
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
    // 把 AVFrame 的 YUV 平面紧凑保存到 out.yuv（后台线程调用，零转换开销）
    bool saveYuv(AVFrame* frame, RBFrameBlocks& out);
    // 从 out 已保存的 YUV 按需转出 RGB24（任意线程，用独立 sws 上下文 + 独立锁）。
    // 命中帧缺 RGB 时调用，只转这一帧，几毫秒；转完写回 out.rgb。
    bool ensureRgbFromYuv(RBFrameBlocks& out);
    // 后台预解码线程入口：从头到尾顺序解码整个码流，沿途把每帧块数据
    // （及可选 RGB）填入 m_store，解一帧唤醒一次等待者。是唯一持有解码权
    // 的线程——m_fmt / m_codecCtx / m_sws 只在此线程访问，杜绝并发崩溃。
    void prefetchLoop();
    void startPrefetch();
    void stopPrefetch();
    // 从 AVFrame 的 side data 提取块级信息
    bool extractBlocks(AVFrame* frame, RBFrameBlocks& out);
    // H.264：从 AVVideoEncParams（AV_VIDEO_ENC_PARAMS_H264）提取逐宏块
    bool extractH264(AVFrame* frame, RBFrameBlocks& out);
    // VVC：从 AV_FRAME_DATA_CODEC_BLOCK_INFO 提取真实逐块 QP / pred_mode
    bool extractVvc(AVFrame* frame, RBFrameBlocks& out);
    // 从 AV_FRAME_DATA_MOTION_VECTORS 填充每个块的 MV / 参考索引（图2 需要）
    void fillMotionVectors(AVFrame* frame, RBFrameBlocks& out);
    // HEVC 降级：CTU 级 QP（来自 qp_y_tab，需补丁；一期若取不到则返回 false）
    bool extractHevcCtu(AVFrame* frame, RBFrameBlocks& out);
    void releaseFrame(AVFrame*& frame);
    bool openDecoder();

    AVFormatContext* m_fmt{nullptr};
    AVCodecContext*  m_codecCtx{nullptr};
    int              m_videoStream{-1};
    std::string      m_filePath;   // prefetchLoop 重新打开文件用（裸流 seek 不可靠）
    bool             m_opened{false};
    bool             m_blockSupport{false};
    std::string      m_granularity;
    int              m_width{0}, m_height{0};
    int              m_frameCount{0};
    AVCodecID        m_codecId{AV_CODEC_ID_NONE};

    // ── 帧存储（后台线程写，任意线程读）────────────────────────
    // 块数据用 shared_ptr 常驻：一旦解出永不失效，rbBlockInfoAt 返回的引用
    // 始终稳定（调用方会拿着引用读 blocks/rgb，不能被淘汰移动）。
    // 块数据体积小（每帧几十 KB），全量常驻可接受。
    std::unordered_map<int, std::shared_ptr<RBFrameBlocks>>  m_store;
    // RGB 内存水位：4K RGB24 约 24MB/帧，不能全量常驻。
    // 只保留最近访问的若干帧 RGB（LRU），淘汰时把该帧 shared 的 rgb 清空
    // （块数据仍在）。m_cacheMax 复用为 RGB 保留帧数上限。
    std::list<int>                                           m_rgbLru;   // 头=最近
    int                                                      m_cacheMax{12};
    // 保护 m_store / m_rgbLru / m_decodedUpTo / m_prefetchDone 的锁。
    mutable std::mutex                                       m_storeMutex;
    // 后台解码进度：已成功解码并入库的最大帧号（-1 表示尚无）。
    int                                                      m_decodedUpTo{-1};
    // 后台预解码线程 + 同步。
    std::thread                                              m_prefetchThread;
    std::condition_variable                                  m_cv;       // 配 m_storeMutex
    std::atomic<bool>                                        m_stop{false};
    bool                                                     m_prefetchDone{false};

    // 空结果哨兵：帧取不到时返回它的引用（valid=false）。
    RBFrameBlocks    m_emptyResult;

    // 是否需要在解析块级信息时顺带导出原始画面（RGB24）
    bool             m_wantFrameImage{false};

    struct SwsContext* m_sws{nullptr};      // 复用的 swscale 上下文（仅后台线程用）

    // 按需转 RGB 专用 swscale 上下文（rbBlockInfoAt 命中缺 RGB 时用），
    // 与后台 m_sws 完全分离；可能被多个读线程调用，用独立锁串行化。
    struct SwsContext* m_onDemandSws{nullptr};
    std::mutex         m_onDemandMutex;
};

} // namespace rb
