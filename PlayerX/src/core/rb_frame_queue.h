#pragma once
/**
 * rb_frame_queue.h — 解码帧队列
 * 线程安全的有界阻塞队列，存放解码后的 AVFrame（含 PTS）。
 * 生产者：解码线程；消费者：渲染线程。
 */

#include <atomic>
#include <mutex>
#include <condition_variable>

extern "C" {
#include <libavutil/frame.h>
}

namespace rb {

struct RBFrameQueue {
    static constexpr int kCapacity = 8;

    RBFrameQueue();
    ~RBFrameQueue();

    // 生产者：推入帧（移交所有权），队列满时阻塞
    void rbPush(AVFrame* frame);
    // 消费者：弹出帧（调用方负责 av_frame_free），队列空时阻塞；返回 nullptr 表示 eof/flush
    AVFrame* rbPop();
    // 消费者：非阻塞 peek，不移除，返回 nullptr 表示空
    AVFrame* rbPeek();

    void rbFlush();
    void rbSetEof();
    bool rbIsEof()   const { return m_eof.load(); }
    int  rbSize()    const;

    // ── 生命周期：abort/reset（与 PacketQueue 的 stop/restart 对称）──────────
    // rbAbort: 永久让 rbPush 立即 free 帧 return，rbPop/rbPeek 立即返回 nullptr。
    //   用于 rbClose 流程：必须在 join 解码线程之前调用，否则解码线程可能
    //   阻塞在 rbPush（队列满 + 无消费者）→ join 永久卡死 → UI 卡死。
    // rbReset: 解除 abort，恢复正常工作。rbOpen 启动新解码线程前调用。
    void rbAbort();
    void rbReset();

private:
    AVFrame*                m_buf[kCapacity]{};
    int                     m_head{0};
    int                     m_tail{0};
    int                     m_count{0};
    mutable std::mutex      m_mtx;
    std::condition_variable m_cvNotFull;
    std::condition_variable m_cvNotEmpty;
    std::atomic<bool>       m_eof{false};
    std::atomic<bool>       m_flushing{false};
    std::atomic<bool>       m_aborted{false};
};

} // namespace rb
