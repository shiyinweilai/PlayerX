#pragma once
/**
 * rb_decoder.h — 视频解码器
 * 从 RBPacketQueue 取包，解码为 AVFrame，送入 RBFrameQueue。
 * 支持硬件加速（macOS VideoToolbox / 软解回退）。
 *
 * seek 机制严格参照 video-compare：
 *   主线程设 seeking=true → 解码线程检测到后自己 flush + 进入 idle
 *   主线程等 idle → seek → restart → seeking=false → 解码线程恢复
 */

#include <atomic>
#include <thread>
#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
}

namespace rb {

struct RBPacketQueue;
struct RBFrameQueue;

class RBDecoder {
public:
    RBDecoder();
    ~RBDecoder();

    // 初始化解码器（codecpar 来自 RBDemuxer）
    bool rbInit(AVCodecParameters* codecpar, bool hwAccel = true);
    void rbClose();

    // 启动/停止解码线程
    void rbStartDecoding(RBPacketQueue* pktQueue, RBFrameQueue* frameQueue);
    void rbStopDecoding();

    // 设置 seeking 标志（由 RBVideoPlayer 在 seek 期间设置）
    // 解码线程检测到后会自己 flush + 进入 idle
    void rbSetSeeking(bool seeking) { m_seeking.store(seeking); }
    bool rbIsIdle() const { return m_idle.load(); }

    bool rbIsRunning() const { return m_running.load(); }

    // 查询解码器参数
    int rbWidth()  const;
    int rbHeight() const;
    AVPixelFormat rbPixFmt() const;

private:
    void decodeLoop(RBPacketQueue* pktQueue, RBFrameQueue* frameQueue);

    AVCodecContext*     m_codecCtx{nullptr};
    AVBufferRef*        m_hwDeviceCtx{nullptr};
    AVPixelFormat       m_hwPixFmt{AV_PIX_FMT_NONE};
    AVCodecParameters*  m_codecparCopy{nullptr};
    bool                m_hwAccelEnabled{false};

    std::thread         m_decodeThread;
    std::atomic<bool>   m_running{false};
    std::atomic<bool>   m_seeking{false}; // 主线程设置，解码线程检测
    std::atomic<bool>   m_idle{false};    // 解码线程进入 idle 后设置
};

} // namespace rb
