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
    // 读线程已退出，清空包队列里残留的旧视频数据，
    // 避免下次 rbOpen 后启动的解码线程拿到旧 packet 喂给新解码器，
    // 导致 HEVC 报 "PPS id out of range" 等错误。
    m_videoQueue.empty();
    m_audioQueue.empty();
}

void RBDemuxer::rbDoSeek(double seconds) {
    // 在主线程直接执行 seek（readLoop 已处于 idle 状态）。
    //
    // 历史 bug：原先使用
    //     avformat_seek_file(ctx, -1, INT64_MIN, ts, ts, 0);
    // 等价于"目标必须 ≤ ts"的严格区间。当 ts 处于两个关键帧之间、
    // 或文件 index 不全（典型的 mp4 mdat 在前 / 流式封装），FFmpeg 会
    // 因找不到满足约束的关键帧而返回失败，fallback 路径再退到一个
    // 极早的关键帧，表现为"右键快进无效甚至跳回开头"。
    //
    // 改用与 video-compare 一致的实现：av_seek_frame + AVSEEK_FLAG_BACKWARD，
    // 语义为"落到 ≤ ts 的最近关键帧"，对正向快进 / 反向快退均正确。
    int64_t ts = static_cast<int64_t>(seconds * AV_TIME_BASE);
    av_seek_frame(m_fmtCtx, -1, ts, AVSEEK_FLAG_BACKWARD);
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

AVRational RBDemuxer::rbVideoFrameRate() const {
    if (!m_fmtCtx || m_videoStreamIdx < 0) return {0, 1};
    AVStream* st = m_fmtCtx->streams[m_videoStreamIdx];
    // 用 FFmpeg 官方的 av_guess_frame_rate，它内部会综合 r_frame_rate、
    // avg_frame_rate、codec time_base、field order 等信息给出最稳妥的帧率。
    // 之前只看 r_frame_rate 的写法，会在某些 MP4（r_frame_rate 被写成容器
    // time_base 的倒数，如 10000/1）下得到 ~10000fps 的错误结果，进而让
    // rbStepFrame 的 fd≈0.0001s，多路帧步进"另一路画面不动"。
    AVRational r = av_guess_frame_rate(m_fmtCtx, st, nullptr);
    if (r.num > 0 && r.den > 0) return r;
    if (st->avg_frame_rate.num > 0 && st->avg_frame_rate.den > 0) return st->avg_frame_rate;
    if (st->r_frame_rate.num > 0 && st->r_frame_rate.den > 0) return st->r_frame_rate;
    return {0, 1};
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
