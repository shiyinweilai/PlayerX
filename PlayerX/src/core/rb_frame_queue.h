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
};

} // namespace rb
