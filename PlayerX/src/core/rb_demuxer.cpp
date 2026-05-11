#include "rb_demuxer.h"
#include <iostream>
#include <cstring>
#include <chrono>
#include <thread>

namespace rb {

// ═══════════════════════════════════════════════════════════════════════════
// RBPacketQueue
// ═══════════════════════════════════════════════════════════════════════════

RBPacketQueue::RBPacketQueue() = default;

RBPacketQueue::~RBPacketQueue() {
    stop();
    empty();
}

void RBPacketQueue::rbPush(AVPacket* pkt) {
    std::unique_lock<std::mutex> lk(m_mtx);
    // 队列满或 stopped 时等待
    m_cvNotFull.wait(lk, [this]{ return m_count < kCapacity || m_stopped.load(); });
    if (m_stopped.load()) return; // stopped 时丢弃

    AVPacket* copy = av_packet_alloc();
    av_packet_ref(copy, pkt);
    m_buf[m_tail] = copy;
    m_tail = (m_tail + 1) % kCapacity;
    ++m_count;
    m_cvNotEmpty.notify_one();
}

AVPacket* RBPacketQueue::rbPop() {
    std::unique_lock<std::mutex> lk(m_mtx);
    m_cvNotEmpty.wait(lk, [this]{ return m_count > 0 || m_eof.load() || m_stopped.load(); });
    if (m_count == 0) return nullptr; // stopped 或 eof 且无包

    AVPacket* pkt = m_buf[m_head];
    m_buf[m_head] = nullptr;
    m_head = (m_head + 1) % kCapacity;
    --m_count;
    m_cvNotFull.notify_one();
    return pkt;
}

void RBPacketQueue::stop() {
    m_stopped.store(true);
    m_eof.store(false);
    m_cvNotFull.notify_all();
    m_cvNotEmpty.notify_all();
}

void RBPacketQueue::restart() {
    m_stopped.store(false);
    m_eof.store(false);
    m_cvNotFull.notify_all();
    m_cvNotEmpty.notify_all();
}

void RBPacketQueue::empty() {
    std::lock_guard<std::mutex> lk(m_mtx);
    while (m_count > 0) {
        AVPacket* pkt = m_buf[m_head];
        if (pkt) { av_packet_free(&pkt); }
        m_buf[m_head] = nullptr;
        m_head = (m_head + 1) % kCapacity;
        --m_count;
    }
    m_head = m_tail = 0;
    m_cvNotFull.notify_all();
}

void RBPacketQueue::rbSetEof() {
    m_eof.store(true);
    m_cvNotEmpty.notify_all();
}

int RBPacketQueue::rbSize() const {
    std::lock_guard<std::mutex> lk(m_mtx);
    return m_count;
}

// ═══════════════════════════════════════════════════════════════════════════
// RBDemuxer
// ═══════════════════════════════════════════════════════════════════════════

RBDemuxer::RBDemuxer() = default;

RBDemuxer::~RBDemuxer() {
    rbClose();
}

bool RBDemuxer::rbOpen(const std::string& filePath) {
    rbClose();

    if (avformat_open_input(&m_fmtCtx, filePath.c_str(), nullptr, nullptr) < 0) {
        std::cerr << "[RBDemuxer] 无法打开文件: " << filePath << std::endl;
        return false;
    }
    if (avformat_find_stream_info(m_fmtCtx, nullptr) < 0) {
        std::cerr << "[RBDemuxer] 无法获取流信息" << std::endl;
        avformat_close_input(&m_fmtCtx);
        return false;
    }

    m_videoStreamIdx = av_find_best_stream(m_fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    m_audioStreamIdx = av_find_best_stream(m_fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);

    if (m_videoStreamIdx < 0) {
        std::cerr << "[RBDemuxer] 未找到视频流" << std::endl;
        avformat_close_input(&m_fmtCtx);
        return false;
    }

    m_duration = (m_fmtCtx->duration > 0)
        ? static_cast<double>(m_fmtCtx->duration) / AV_TIME_BASE
        : 0.0;

    return true;
}

void RBDemuxer::rbClose() {
    rbStopReading();
    if (m_fmtCtx) {
        avformat_close_input(&m_fmtCtx);
        m_fmtCtx = nullptr;
    }
    m_videoStreamIdx = -1;
    m_audioStreamIdx = -1;
    m_duration = 0.0;
}

void RBDemuxer::rbStartReading() {
    if (m_running.load() || !m_fmtCtx) return;
    m_running.store(true);
    m_idle.store(false);
    m_readThread = std::thread(&RBDemuxer::readLoop, this);
}

void RBDemuxer::rbStopReading() {
    m_running.store(false);
    // 唤醒可能阻塞在 push 的线程
    m_videoQueue.stop();
    m_audioQueue.stop();
    if (m_readThread.joinable()) m_readThread.join();
}

void RBDemuxer::rbDoSeek(double seconds) {
    // 在主线程直接执行 seek（readLoop 已处于 idle 状态）
    int64_t ts = static_cast<int64_t>(seconds * AV_TIME_BASE);
    // 先尝试精确 seek
    int ret = avformat_seek_file(m_fmtCtx, -1, INT64_MIN, ts, ts, 0);
    if (ret < 0) {
        // 回退：向后找最近关键帧
        av_seek_frame(m_fmtCtx, -1, ts, AVSEEK_FLAG_BACKWARD);
    }
}

AVCodecParameters* RBDemuxer::rbVideoCodecPar() const {
    if (!m_fmtCtx || m_videoStreamIdx < 0) return nullptr;
    return m_fmtCtx->streams[m_videoStreamIdx]->codecpar;
}

AVCodecParameters* RBDemuxer::rbAudioCodecPar() const {
    if (!m_fmtCtx || m_audioStreamIdx < 0) return nullptr;
    return m_fmtCtx->streams[m_audioStreamIdx]->codecpar;
}

AVRational RBDemuxer::rbVideoTimeBase() const {
    if (!m_fmtCtx || m_videoStreamIdx < 0) return {1, 1};
    return m_fmtCtx->streams[m_videoStreamIdx]->time_base;
}

AVRational RBDemuxer::rbAudioTimeBase() const {
    if (!m_fmtCtx || m_audioStreamIdx < 0) return {1, 1};
    return m_fmtCtx->streams[m_audioStreamIdx]->time_base;
}

void RBDemuxer::readLoop() {
    AVPacket* pkt = av_packet_alloc();

    while (m_running.load()) {
        // ── seeking 期间：进入 idle，等待主线程完成 seek ──────────────────
        if (m_seeking.load()) {
            m_idle.store(true);
            while (m_seeking.load() && m_running.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            m_idle.store(false);
            continue;
        }

        // ── 队列 stopped（seek 开始时 stop 了队列）：等待 restart ─────────
        if (m_videoQueue.isStopped()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        int ret = av_read_frame(m_fmtCtx, pkt);
        if (ret < 0) {
            // EOF 或读取错误
            m_videoQueue.rbSetEof();
            m_audioQueue.rbSetEof();
            // 等待 seek 或 stop
            while (m_running.load() && !m_seeking.load() && !m_videoQueue.isStopped()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            continue;
        }

        if (pkt->stream_index == m_videoStreamIdx) {
            m_videoQueue.rbPush(pkt);
        } else if (pkt->stream_index == m_audioStreamIdx) {
            m_audioQueue.rbPush(pkt);
        }
        av_packet_unref(pkt);
    }

    av_packet_free(&pkt);
}

} // namespace rb
