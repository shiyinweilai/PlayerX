#include "rb_video_player.h"
#include "../core/rb_demuxer.h"
#include "../core/rb_decoder.h"
#include "../core/rb_frame_queue.h"
#include <iostream>
#include <chrono>
#include <thread>

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
    // 注意：调用方（rbOpenFileForCell）已经先调用了 rbClose()，这里不再重复
    // 防御性再 flush 一次，确保帧队列绝对干净（无旧视频残帧）
    m_frameQueue->rbFlush();
    rbReleaseCurrentFrame();

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

    // ── 严格按依赖关系倒序停止 ───────────────────────────────────────────
    // 数据流：demuxer → pktQueue → decoder → frameQueue → renderer
    // 必须先停"上游"，避免下游退出后上游还在生产旧数据进队列。

    // 1. 停止读线程（demuxer）：m_running=false + pktQueue.stop()
    //    rbStopReading 内部会 join 读线程，并 empty pktQueue 清除残留旧包，
    //    防止新解码器接收到旧视频的 NALU 导致 PPS/POC 错误。
    m_demuxer->rbStopReading();

    // 2. flush frameQueue：唤醒可能阻塞在 rbPush 的解码线程
    m_frameQueue->rbFlush();

    // 3. 停止解码线程（此时 pktQueue 已空且 stopped，解码线程不会再产新帧）
    m_decoder->rbStopDecoding();

    // 4. 解码线程已退出，再做一次 frameQueue flush，
    //    清掉解码线程退出前 push 进去的最后几帧（避免新视频复用时拿到旧帧）
    m_frameQueue->rbFlush();

    // 5. 清理资源（释放 codec/format context）
    rbReleaseCurrentFrame();
    m_decoder->rbClose();
    m_demuxer->rbClose();

    // 6. 重置所有时钟相关状态，避免新视频接续旧时间戳
    m_filePath.clear();
    m_duration          = 0.0;
    m_currentTime.store(0.0);
    m_currentFramePts   = 0.0;
    m_playStartWallTime = 0.0;
    m_playStartPts      = 0.0;
    m_seekPending       = false;
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
            // seek 后第一帧到达：
            //   av_seek_frame(AVSEEK_FLAG_BACKWARD) 会落到 ≤ 目标时间的
            //   最近关键帧，因此队列前面会有一段 PTS < 目标时间 的"前置
            //   帧"（仅用于解码连续性，不应显示）。
            //
            //   策略：丢弃 PTS 明显早于目标时间（>0.5s）的帧，直到遇到
            //   PTS ≥ 目标时间附近的帧再对齐时钟。这样进度条不会从用户
            //   点击的位置"弹回"到关键帧位置。
            double target = m_playStartPts; // rbSeekTo 中设置为目标时间
            if (framePts + 0.5 < target) {
                // 前置帧：直接丢弃
                AVFrame* drop = m_frameQueue->rbPop();
                if (drop) av_frame_free(&drop);
                continue;
            }
            // 找到目标位置的帧，对齐时钟
            m_playStartPts      = framePts;
            m_playStartWallTime = wallNow;
            playTime            = framePts;
            m_currentTime.store(framePts);
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

bool RBVideoPlayer::rbRefreshPausedFrame(int timeoutMs) {
    // 仅对已加载且非播放状态的视频生效（Ready/Paused/Ended）
    auto s = m_state.load();
    if (s == RBPlayerState::Idle || s == RBPlayerState::Error || s == RBPlayerState::Playing) {
        return false;
    }

    // 等待解码线程把 seek 后的帧产出到帧队列
    using clock = std::chrono::steady_clock;
    auto deadline = clock::now() + std::chrono::milliseconds(timeoutMs);

    // 目标时间（rbSeekTo 已把 m_playStartPts 设为目标 seek 秒数）
    const double target = m_playStartPts;

    while (clock::now() < deadline) {
        AVFrame* peek = m_frameQueue->rbPeek();
        if (peek) {
            int64_t rawPts = (peek->best_effort_timestamp != AV_NOPTS_VALUE)
                           ? peek->best_effort_timestamp
                           : peek->pts;
            double framePts = (rawPts != AV_NOPTS_VALUE)
                ? rawPts * av_q2d(m_videoTimeBase)
                : 0.0;

            // 与 rbGetCurrentFrame 保持一致：丢弃 seek 关键帧前的"前置帧"
            if (m_seekPending && framePts + 0.5 < target) {
                AVFrame* drop = m_frameQueue->rbPop();
                if (drop) av_frame_free(&drop);
                continue;
            }

            // 弹出目标帧作为当前显示帧
            AVFrame* f = m_frameQueue->rbPop();
            if (f) {
                rbReleaseCurrentFrame();
                m_currentFrame    = f;
                m_currentFramePts = framePts;
                // 对齐时钟，但保持暂停状态：清除 seekPending，使 rbGetCurrentFrame
                // 后续即便切到 Playing 也不会再丢这一帧
                m_playStartPts      = framePts;
                m_playStartWallTime = rbWallTime();
                m_currentTime.store(framePts);
                m_seekPending       = false;
                return true;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return false;
}

void RBVideoPlayer::rbReleaseCurrentFrame() {
    if (m_currentFrame) {
        av_frame_free(&m_currentFrame);
        m_currentFrame = nullptr;
    }
}

} // namespace rb
