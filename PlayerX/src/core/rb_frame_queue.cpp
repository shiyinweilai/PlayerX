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
    m_cvNotFull.wait(lk, [this]{ return m_count < kCapacity || m_flushing.load() || m_aborted.load(); });
    if (m_aborted.load() || m_flushing.load()) {
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
    m_cvNotEmpty.wait(lk, [this]{ return m_count > 0 || m_eof.load() || m_flushing.load() || m_aborted.load(); });
    if (m_count == 0) return nullptr;

    AVFrame* f = m_buf[m_head];
    m_buf[m_head] = nullptr;
    m_head = (m_head + 1) % kCapacity;
    --m_count;
    m_cvNotFull.notify_one();
    return f;
}

AVFrame* RBFrameQueue::rbPeek() {
    // flushing / aborted 期间返回 nullptr：防止渲染线程拿到即将被 free 的帧裸指针
    // （rbFlush 持锁清空队列时，若渲染线程已通过 rbPeek 拿到指针并在锁外
    // 访问帧数据，会发生 use-after-free 崩溃）
    if (m_flushing.load() || m_aborted.load()) return nullptr;
    std::lock_guard<std::mutex> lk(m_mtx);
    if (m_count == 0) return nullptr;
    return m_buf[m_head];
}

void RBFrameQueue::rbFlush() {
    // ⚠️ 修复竞态（use-after-free）：
    // 旧实现在持锁期间直接 av_frame_free 队列里的帧。渲染线程的
    // rbGetCurrentFrame() 可能刚通过 rbPeek() 拿到帧裸指针，正在锁外
    // 访问 next->best_effort_timestamp 等字段，此时 rbFlush 持锁 free
    // 同一帧 → use-after-free → 崩溃（日志现象：CLOSEALL dying.size=2
    // will free now 之后无 done，播放中切下一组 5 次复现一次）。
    //
    // 修复：先设 m_flushing=true（让 rbPeek 立刻返回 nullptr，阻断渲染
    // 线程继续拿新帧指针），然后持锁把帧指针收集到本地 vector 并置空
    // 队列槽位，释放锁后再统一 av_frame_free。这样持锁期间帧内存不会
    // 被 free，渲染线程已持有的裸指针在本次 flush 持锁结束前仍然有效。
    m_flushing.store(true);
    m_eof.store(false);
    // 通知等待中的线程（rbPush/rbPop），让它们感知到 flushing 状态
    m_cvNotFull.notify_all();
    m_cvNotEmpty.notify_all();

    // 持锁：只做指针置空，不做 av_frame_free
    AVFrame* toFree[kCapacity] = {};
    int freeCount = 0;
    {
        std::lock_guard<std::mutex> lk(m_mtx);
        while (m_count > 0) {
            AVFrame* f = m_buf[m_head];
            if (f) toFree[freeCount++] = f;  // 收集，稍后锁外 free
            m_buf[m_head] = nullptr;
            m_head = (m_head + 1) % kCapacity;
            --m_count;
        }
        m_head = m_tail = 0;
    }
    // 锁外释放：此时渲染线程若持有旧帧裸指针，它们来自 rbPeek/rbPop
    // 的上一次调用，不在 toFree 里（队列槽位已置 nullptr），不会被
    // 二次 free。渲染线程在 m_flushing=true 期间调用 rbPeek 会得到
    // nullptr，不会再拿到新的即将被 free 的指针。
    for (int i = 0; i < freeCount; ++i) {
        av_frame_free(&toFree[i]);
    }
    m_flushing.store(false);
}

void RBFrameQueue::rbSetEof() {
    m_eof.store(true);
    m_cvNotEmpty.notify_all();
}

void RBFrameQueue::rbAbort() {
    // 永久让 push 立即丢帧返回，pop/peek 立即返回 nullptr。
    // 用于 rbClose 中在 join 解码线程之前唤醒它，避免线程阻塞在
    // rbPush wait 里导致 rbStopDecoding 的 join() 永久卡住。
    //
    // 与 rbFlush 区别：flush 结束后会自动释放 flushing 标志，push 还能继续工作；
    // abort 是一条 sticky 状态，需显式 rbReset() 才会解除。
    m_aborted.store(true);
    m_cvNotFull.notify_all();
    m_cvNotEmpty.notify_all();

    // 同时清空现有帧（复用 rbFlush 的“锁内收集 + 锁外 free”避免 use-after-free）
    AVFrame* toFree[kCapacity] = {};
    int freeCount = 0;
    {
        std::lock_guard<std::mutex> lk(m_mtx);
        while (m_count > 0) {
            AVFrame* f = m_buf[m_head];
            if (f) toFree[freeCount++] = f;
            m_buf[m_head] = nullptr;
            m_head = (m_head + 1) % kCapacity;
            --m_count;
        }
        m_head = m_tail = 0;
    }
    for (int i = 0; i < freeCount; ++i) av_frame_free(&toFree[i]);
}

void RBFrameQueue::rbReset() {
    // 解除 abort，恢复正常工作。rbOpen 启动新解码线程前调用。
    m_aborted.store(false);
    m_eof.store(false);
    m_cvNotFull.notify_all();
    m_cvNotEmpty.notify_all();
}

int RBFrameQueue::rbSize() const {
    std::lock_guard<std::mutex> lk(m_mtx);
    return m_count;
}

} // namespace rb
