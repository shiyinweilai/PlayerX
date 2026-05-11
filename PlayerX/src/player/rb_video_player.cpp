#include "rb_video_player.h"
#include "../core/rb_demuxer.h"
#include "../core/rb_decoder.h"
#include "../core/rb_frame_queue.h"
#include <iostream>
#include <chrono>

extern "C" {
#include <libavutil/time.h>
}

namespace rb {

// ─── 工具：获取当前系统时间（秒）─────────────────────────────────────────────
static double rbWallTime() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

// ═══════════════════════════════════════════════════════════════════════════
// RBVideoPlayer
// ═══════════════════════════════════════════════════════════════════════════

RBVideoPlayer::RBVideoPlayer()
    : m_demuxer(std::make_unique<RBDemuxer>())
    , m_decoder(std::make_unique<RBDecoder>())
    , m_frameQueue(std::make_unique<RBFrameQueue>())
{}

RBVideoPlayer::~RBVideoPlayer() {
    rbClose();
}

bool RBVideoPlayer::rbOpen(const std::string& filePath) {
    rbClose();

    if (!m_demuxer->rbOpen(filePath)) {
        m_state.store(RBPlayerState::Error);
        return false;
    }

    AVCodecParameters* vpar = m_demuxer->rbVideoCodecPar();
    if (!vpar || !m_decoder->rbInit(vpar, true)) {
        m_state.store(RBPlayerState::Error);
        return false;
    }

    m_filePath      = filePath;
    m_duration      = m_demuxer->rbDuration();
    m_videoTimeBase = m_demuxer->rbVideoTimeBase();
    m_currentTime.store(0.0);
    m_seekPending   = false;
    m_state.store(RBPlayerState::Ready);

    // restart 队列（rbClose 会 stop 队列，必须先 restart 才能正常 push/pop）
    m_demuxer->rbVideoQueue().restart();
    m_demuxer->rbAudioQueue().restart();

    // 启动解复用 + 解码线程
    m_demuxer->rbStartReading();
    m_decoder->rbStartDecoding(&m_demuxer->rbVideoQueue(), m_frameQueue.get());

    return true;
}

void RBVideoPlayer::rbClose() {
    // 先把状态设为非 Playing，避免 rbGetCurrentFrame 继续消费
    m_state.store(RBPlayerState::Idle);

    // 1. stop pktQueue：唤醒阻塞在 rbPop 的解码线程
    m_demuxer->rbVideoQueue().stop();
    m_demuxer->rbAudioQueue().stop();

    // 2. flush frameQueue：唤醒阻塞在 rbPush 的解码线程（帧队列满时）
    m_frameQueue->rbFlush();

    // 3. 停止解码线程（此时解码线程不再阻塞，可以安全 join）
    m_decoder->rbStopDecoding();

    // 4. 停止解复用线程
    m_demuxer->rbStopReading();

    // 5. 清理资源
    rbReleaseCurrentFrame();
    m_decoder->rbClose();
    m_demuxer->rbClose();

    m_filePath.clear();
    m_duration = 0.0;
    m_currentTime.store(0.0);
    m_seekPending = false;
}

void RBVideoPlayer::rbPlay() {
    auto s = m_state.load();
    if (s == RBPlayerState::Idle || s == RBPlayerState::Error) return;

    if (s == RBPlayerState::Ended) {
        // 重播：seek 到开头，rbSeekTo 内部已设置 m_seekPending
        rbSeekTo(0.0);
        // rbSeekTo 不改变播放状态，必须在这里设为 Playing
        m_state.store(RBPlayerState::Playing);
        return;
    }

    m_playStartWallTime = rbWallTime();
    m_playStartPts      = m_currentTime.load();

    if (s == RBPlayerState::Ready) {
        // 首次播放：解码线程刚启动，帧队列可能为空
        // 设 seekPending，等第一帧到达后再对齐时钟，避免时钟跑飞跳帧
        m_seekPending = true;
    }
    // Paused → Playing：直接从当前时间继续，不需要 seekPending

    m_state.store(RBPlayerState::Playing);
}

void RBVideoPlayer::rbPause() {
    if (m_state.load() == RBPlayerState::Playing) {
        m_state.store(RBPlayerState::Paused);
    }
}

void RBVideoPlayer::rbStop() {
    m_state.store(RBPlayerState::Ready);
    m_currentTime.store(0.0);
}

void RBVideoPlayer::rbTogglePause() {
    if (rbIsPlaying()) rbPause();
    else if (rbIsPaused()) rbPlay();
    else if (rbIsEnded()) rbPlay(); // Ended 状态：空格键触发 replay
}

void RBVideoPlayer::rbSeekTo(double seconds) {
    seconds = std::max(0.0, std::min(seconds, m_duration));

    // ── 严格复现 video-compare 的 seek 流程 ──────────────────────────────
    //
    // 步骤1: 设 seeking=true，通知所有工作线程进入 idle
    m_demuxer->rbSetSeeking(true);
    m_decoder->rbSetSeeking(true);

    // 步骤2: stop 包队列，唤醒所有阻塞在 push/pop 的线程
    m_demuxer->rbVideoQueue().stop();
    m_demuxer->rbAudioQueue().stop();

    // 步骤3: 循环 empty 各队列，等待所有线程进入 idle
    //        （对应 video-compare 的 while(!ready_to_seek_.all_are_idle()) 循环）
    auto emptyQueues = [&]() {
        m_demuxer->rbVideoQueue().empty();
        m_demuxer->rbAudioQueue().empty();
        m_frameQueue->rbFlush();
    };
    while (!m_demuxer->rbIsIdle() || !m_decoder->rbIsIdle()) {
        emptyQueues();
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    emptyQueues(); // 最后再 empty 一次

    // 步骤4: 主线程直接执行 seek（所有工作线程已 idle，无并发访问）
    m_demuxer->rbDoSeek(seconds);

    // 步骤5: restart 队列，让工作线程可以重新 push/pop
    m_demuxer->rbVideoQueue().restart();
    m_demuxer->rbAudioQueue().restart();

    // 步骤6: 清除 seeking 标志，工作线程自动恢复
    m_demuxer->rbSetSeeking(false);
    m_decoder->rbSetSeeking(false);

    // 对齐时钟
    m_seekPending       = true;
    m_currentTime.store(seconds);
    m_playStartWallTime = rbWallTime();
    m_playStartPts      = seconds;

    // 若视频已播完，用户主动 seek 说明想继续播放，自动恢复 Playing
    if (m_state.load() == RBPlayerState::Ended) {
        m_state.store(RBPlayerState::Playing);
    }
}

void RBVideoPlayer::rbSetMasterClock(double masterTime) {
    m_masterClock = masterTime;
}

AVFrame* RBVideoPlayer::rbGetCurrentFrame() {
    if (m_state.load() != RBPlayerState::Playing) {
        return m_currentFrame; // 暂停时返回最后一帧
    }

    // 计算当前播放时间
    double wallNow = rbWallTime();
    double playTime;
    if (m_useMasterClock) {
        playTime = m_masterClock;
    } else {
        playTime = m_playStartPts + (wallNow - m_playStartWallTime);
    }
    playTime = std::min(playTime, m_duration > 0 ? m_duration : playTime);

    // 从队列中取出 PTS <= playTime 的帧
    bool gotFrame = false;
    while (true) {
        AVFrame* next = m_frameQueue->rbPeek();
        if (!next) {
            // 队列空
            if (m_frameQueue->rbIsEof()) {
                m_state.store(RBPlayerState::Ended);
            } else if (m_seekPending) {
                // seek/replay 后第一帧还没到：暂停时钟推进，等帧到了再对齐
                m_playStartWallTime = wallNow;
            }
            break;
        }

        // 计算帧的 PTS（秒）
        int64_t rawPts = (next->best_effort_timestamp != AV_NOPTS_VALUE)
                       ? next->best_effort_timestamp
                       : next->pts;
        double framePts = (rawPts != AV_NOPTS_VALUE)
            ? rawPts * av_q2d(m_videoTimeBase)
            : m_currentFramePts + av_q2d(m_videoTimeBase);

        if (m_seekPending && !gotFrame) {
            // seek 后第一帧到达：对齐时钟到该帧的 PTS，避免第一帧被跳过
            m_playStartPts      = framePts;
            m_playStartWallTime = wallNow;
            playTime            = framePts;
            m_seekPending       = false;
        }

        if (framePts <= playTime + 0.005) { // 5ms 容差
            // 弹出并替换当前帧
            AVFrame* f = m_frameQueue->rbPop();
            if (f) {
                rbReleaseCurrentFrame();
                m_currentFrame    = f;
                m_currentFramePts = framePts;
                gotFrame = true;
            }
        } else {
            break; // 帧还没到时间
        }
    }

    // 只有拿到帧后才更新 currentTime（避免无帧时时间狁进导致帧被跳过）
    if (gotFrame || m_currentFrame) {
        m_currentTime.store(playTime);
    }

    return m_currentFrame;
}

int RBVideoPlayer::rbWidth()  const { return m_decoder->rbWidth(); }
int RBVideoPlayer::rbHeight() const { return m_decoder->rbHeight(); }

void RBVideoPlayer::rbReleaseCurrentFrame() {
    if (m_currentFrame) {
        av_frame_free(&m_currentFrame);
        m_currentFrame = nullptr;
    }
}

} // namespace rb
