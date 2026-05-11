#pragma once
/**
 * rb_demuxer.h — 解复用器
 * 负责打开媒体文件，在独立线程中读取 AVPacket 并分发到视频/音频包队列。
 *
 * seek 机制严格参照 video-compare：
 *   主线程设 seeking=true → stop 队列 → 等所有线程 idle → av_seek_frame
 *   → restart 队列 → seeking=false
 */

#include <string>
#include <atomic>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <memory>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
}

namespace rb {

// ─── 包队列（线程安全，有界阻塞队列）────────────────────────────────────────
struct RBPacketQueue {
    static constexpr int kCapacity = 256;

    RBPacketQueue();
    ~RBPacketQueue();

    // 生产者：推入一个包（会拷贝引用计数），队列满或 stopped 时阻塞等待
    void rbPush(AVPacket* pkt);
    // 消费者：弹出一个包，队列空时阻塞等待；返回 nullptr 表示 stopped/eof
    AVPacket* rbPop();

    // --- video-compare 风格的队列控制 ---
    // stop(): 停止接受新包，唤醒所有阻塞的 push/pop（seek 开始时调用）
    void stop();
    // restart(): 重新允许 push/pop（seek 完成后调用）
    void restart();
    // empty(): 清空队列中所有包（seek 期间循环调用，排空各线程残留帧）
    void empty();
    // isStopped(): 队列是否处于 stopped 状态
    bool isStopped() const { return m_stopped.load(); }

    // 标记 EOF，唤醒所有等待的消费者
    void rbSetEof();
    bool rbIsEof() const { return m_eof.load(); }
    int  rbSize()  const;

private:
    AVPacket*               m_buf[kCapacity]{};
    int                     m_head{0};
    int                     m_tail{0};
    int                     m_count{0};
    mutable std::mutex      m_mtx;
    std::condition_variable m_cvNotFull;
    std::condition_variable m_cvNotEmpty;
    std::atomic<bool>       m_eof{false};
    std::atomic<bool>       m_stopped{false};
};

// ─── 解复用器 ─────────────────────────────────────────────────────────────────
class RBDemuxer {
public:
    RBDemuxer();
    ~RBDemuxer();

    // 打开文件，成功返回 true
    bool rbOpen(const std::string& filePath);
    void rbClose();

    // 启动/停止读取线程
    void rbStartReading();
    void rbStopReading();

    // 设置 seeking 标志（由 RBVideoPlayer 在 seek 期间设置）
    // readLoop 检测到此标志后会进入 idle 状态
    void rbSetSeeking(bool seeking) { m_seeking.store(seeking); }
    bool rbIsIdle() const { return m_idle.load(); }

    // 直接执行 seek（在主线程调用，readLoop 已 idle 后才调用）
    void rbDoSeek(double seconds);

    // 查询
    bool   rbIsOpen()           const { return m_fmtCtx != nullptr; }
    double rbDuration()         const { return m_duration; }
    int    rbVideoStreamIndex() const { return m_videoStreamIdx; }
    int    rbAudioStreamIndex() const { return m_audioStreamIdx; }

    AVCodecParameters* rbVideoCodecPar() const;
    AVCodecParameters* rbAudioCodecPar() const;
    AVRational         rbVideoTimeBase() const;
    AVRational         rbAudioTimeBase() const;

    // 包队列（解码器从这里取包）
    RBPacketQueue& rbVideoQueue() { return m_videoQueue; }
    RBPacketQueue& rbAudioQueue() { return m_audioQueue; }

private:
    void readLoop();

    AVFormatContext*    m_fmtCtx{nullptr};
    int                 m_videoStreamIdx{-1};
    int                 m_audioStreamIdx{-1};
    double              m_duration{0.0};

    RBPacketQueue       m_videoQueue;
    RBPacketQueue       m_audioQueue;

    std::thread         m_readThread;
    std::atomic<bool>   m_running{false};
    std::atomic<bool>   m_seeking{false}; // 主线程设置，readLoop 检测
    std::atomic<bool>   m_idle{false};    // readLoop 进入 idle 后设置
};

} // namespace rb
