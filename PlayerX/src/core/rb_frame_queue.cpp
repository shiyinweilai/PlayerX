#include "rb_frame_queue.h"
#include <cstring>

extern "C" {
#include <libavutil/mem.h>
}

namespace rb {

RBFrameQueue::RBFrameQueue() = default;

RBFrameQueue::~RBFrameQueue() {
    rbFlush();
}

void RBFrameQueue::rbPush(AVFrame* frame) {
    std::unique_lock<std::mutex> lk(m_mtx);
    m_cvNotFull.wait(lk, [this]{ return m_count < kCapacity || m_flushing.load(); });
    if (m_flushing.load()) {
        av_frame_free(&frame);
        return;
    }
    m_buf[m_tail] = frame;
    m_tail = (m_tail + 1) % kCapacity;
    ++m_count;
    m_cvNotEmpty.notify_one();
}

AVFrame* RBFrameQueue::rbPop() {
    std::unique_lock<std::mutex> lk(m_mtx);
    m_cvNotEmpty.wait(lk, [this]{ return m_count > 0 || m_eof.load() || m_flushing.load(); });
    if (m_count == 0) return nullptr;

    AVFrame* f = m_buf[m_head];
    m_buf[m_head] = nullptr;
    m_head = (m_head + 1) % kCapacity;
    --m_count;
    m_cvNotFull.notify_one();
    return f;
}

AVFrame* RBFrameQueue::rbPeek() {
    std::lock_guard<std::mutex> lk(m_mtx);
    if (m_count == 0) return nullptr;
    return m_buf[m_head];
}

void RBFrameQueue::rbFlush() {
    m_flushing.store(true);
    m_eof.store(false);
    {
        std::lock_guard<std::mutex> lk(m_mtx);
        while (m_count > 0) {
            AVFrame* f = m_buf[m_head];
            if (f) av_frame_free(&f);
            m_buf[m_head] = nullptr;
            m_head = (m_head + 1) % kCapacity;
            --m_count;
        }
        m_head = m_tail = 0;
    }
    m_cvNotFull.notify_all();
    m_cvNotEmpty.notify_all();
    m_flushing.store(false);
}

void RBFrameQueue::rbSetEof() {
    m_eof.store(true);
    m_cvNotEmpty.notify_all();
}

int RBFrameQueue::rbSize() const {
    std::lock_guard<std::mutex> lk(m_mtx);
    return m_count;
}

} // namespace rb
