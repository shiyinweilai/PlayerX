#include "rb_video_player.h"
#include "../core/rb_demuxer.h"
#include "../core/rb_decoder.h"
#include "../core/rb_frame_queue.h"
#include <iostream>
#include <chrono>
#include <thread>

extern "C" {
#include <libavutil/time.h>
#include <libavutil/frame.h>
#include <libavutil/pixdesc.h>
#include <libavcodec/avcodec.h>
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
    // 严重警告：rbClose 会调 rbAbort（永久封住 push/pop），这里必须先 rbReset 解除才能后续重新起动
    m_frameQueue->rbReset();
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
    m_seekPending.store(false);
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

    // ⚠️ 修复“播放中切下一组卡死”（2026-06-11）：
    // 旧顺序是先 stopReading 再 rbFlush 再 stopDecoding。但解码线程可能
    // 正阐 EOF flush 路径上在 frameQueue->rbPush 里 wait（队列满 8 帧，而
    // m_state=Idle 后渲染线程不再 pop）。第一次 rbFlush 结束后会自动释放
    // m_flushing 标志、队列被设空，解码线程被唤醒后可能拼进 “队列未满且不是
    // flushing” 的窗口期，重新 push 后 EOF flush 还会出更多帧，再次 push
    // 霔住。此时主线程走到 rbStopDecoding 的 join() → 永久卡死。
    // 日志现象：RBE-CLOSEALL outer-scope dying.size=2 will free now 之后无 done，
    // 播放中切下一组反复发生。
    //
    // 修复：在 join 任何工作线程之前，先 rbAbort frameQueue（sticky 状态，让后续
    // 所有 rbPush 立即 free 帧 return）。这样解码线程不会再被决定性地阔在
    // rbPush wait 里。下一次 rbOpen 会 rbReset 解除 abort。

    fprintf(stderr, "[RBVP-CLOSE] entry: state=Idle qsize=%d\n", m_frameQueue ? m_frameQueue->rbSize() : -1);

    // 数据流：demuxer → pktQueue → decoder → frameQueue → renderer
    // 顺序必须从上游到下游逐级“断气”，且下游要在 join 上游之前先唤醒。

    // 1. 唤醒 frameQueue（永久）：避免解码线程阻塞在 rbPush
    if (m_frameQueue) m_frameQueue->rbAbort();
    fprintf(stderr, "[RBVP-CLOSE] frameQueue aborted\n");

    // 2. 停读线程（demuxer）：m_running=false + pktQueue.stop()
    //    rbStopReading 内部会 join 读线程，并 empty pktQueue 清除残留旧包，
    //    防止新解码器接收到旧视频的 NALU 导致 PPS/POC 错误。
    m_demuxer->rbStopReading();
    fprintf(stderr, "[RBVP-CLOSE] demuxer stopped\n");

    // 3. 停解码线程（pktQueue 已空且 stopped，frameQueue 已 abort，
    //    解码线程无论在哪个 wait 上都会被唤醒退出，join 不会卡死）
    m_decoder->rbStopDecoding();
    fprintf(stderr, "[RBVP-CLOSE] decoder stopped\n");

    // 4. 清理资源
    rbReleaseCurrentFrame();
    m_decoder->rbClose();
    m_demuxer->rbClose();
    fprintf(stderr, "[RBVP-CLOSE] codecs closed\n");

    // 5. 重置所有时钟相关状态，避免新视频接续旧时间戳
    m_filePath.clear();
    m_duration          = 0.0;
    m_currentTime.store(0.0);
    m_currentFramePts   = 0.0;
    m_playStartWallTime.store(0.0);
    m_playStartPts.store(0.0);
    m_seekPending.store(false);
    m_displayFrameIndex = 0;
    fprintf(stderr, "[RBVP-CLOSE] done\n");
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

    m_playStartWallTime.store(rbWallTime());
    m_playStartPts.store(m_currentTime.load());

    if (s == RBPlayerState::Ready) {
        // 首次播放：解码线程刚启动，帧队列可能为空
        // 设 seekPending，等第一帧到达后再对齐时钟，避免时钟跑飞跳帧
        m_seekPending.store(true);
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
    m_seekPending.store(true);
    m_currentTime.store(seconds);
    m_playStartWallTime.store(rbWallTime());
    m_playStartPts.store(seconds);

    // ── 状态语义：rbSeekTo 不擅自升级为 Playing；Ended 必须降为 Paused ──
    // 历史上这里有一段「Ended → Playing」自动恢复，目的是让 Ended 态空格键
    // 重播时能直接进入播放。但它造成了一个隐蔽 bug：
    //   多路对比下，路 0（左路）经常先于其他路播到末尾进入 Ended 状态。
    //   此时用户点全局重置（Engine::seek(0)）：
    //     1) 路 0 进 rbSeekTo(0)，末尾被偷偷升级为 Playing
    //     2) 引擎随后调 rbRefreshPausedFrame(200) 想把首帧刷到画面上
    //     3) rbRefreshPausedFrame 第一行检查 state==Playing 直接 return false
    //     4) 路 0 画面停在 Ended 时的旧帧（如 #17）不更新；其它路正常显示 #0
    // 现象：「按重置后 1 号通道偶尔卡住」（与帧率/视频本身无关）。
    //
    // 正确做法：
    //   · rbPlay() 在 Ended 态会自己 rbSeekTo(0) + 显式 set Playing，不依赖此副作用
    //   · 重置 / 进度条拖拽 / 单路 seek 希望保持「不主动播放」语义，绝不能偷偷升级
    //   · 但 Ended 也不该保留——已经离开末尾位置，应回到 Paused，使得：
    //       a) rbRefreshPausedFrame 能成功刷新首帧（它的白名单是 Ready/Paused/Ended，
    //          这里降为 Paused 仍然在白名单内，画面正确刷新）
    //       b) 用户随后点播放走 rbPlay 的 Paused 分支，从当前位置（已 seek 到的位置）
    //          直接续播，不会再次走 Ended→rbSeekTo(0) 的重播分支
    //   · rbStepFrame 慢路径上层已自行把 Ended 降为 Paused，行为不变
    if (m_state.load() == RBPlayerState::Ended) {
        m_state.store(RBPlayerState::Paused);
    }
}

void RBVideoPlayer::rbSetMasterClock(double masterTime) {
    m_masterClock.store(masterTime);
}

void RBVideoPlayer::rbSetSpeed(double speed) {
    // 倍速安全范围：1/128 ~ 128 倍（与 video-compare 一致）。
    // 超出范围视为无意义，不调整。
    if (!(speed > 0.0)) speed = 1.0;
    if (speed < 1.0/128.0) speed = 1.0/128.0;
    if (speed > 128.0)     speed = 128.0;
    if (speed == m_speed.load()) return;

    // 重锰本地时钟，避免倍速变更瞬间 playTime 跳变。
    //   原公式 playTime = m_playStartPts + (now - m_playStartWallTime) * m_speed
    //   切换为 m_speed' 后：先取 now 冻结当前 playTime，再以它为新起点续走。
    if (m_state.load() == RBPlayerState::Playing && !m_useMasterClock.load()) {
        const double wallNow  = rbWallTime();
        const double playNow  = m_playStartPts.load() + (wallNow - m_playStartWallTime.load()) * m_speed.load();
        m_playStartPts.store(playNow);
        m_playStartWallTime.store(wallNow);
    }
    m_speed.store(speed);
}
AVFrame* RBVideoPlayer::rbGetCurrentFrame() {
    if (m_state.load() != RBPlayerState::Playing) {
        return m_currentFrame; // 暂停时返回最后一帧
    }

    // 计算当前播放时间
    double wallNow = rbWallTime();
    double playTime;
    if (m_useMasterClock.load()) {
        playTime = m_masterClock.load();
    } else {
        // 本地时钟需作倍速缩放；m_speed=1.0 时与原逻辑一致。
        playTime = m_playStartPts.load() + (wallNow - m_playStartWallTime.load()) * m_speed.load();
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
            } else if (m_seekPending.load()) {
                // seek/replay 后第一帧还没到：暂停时钟推进，等帧到了再对齐
                m_playStartWallTime.store(wallNow);
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

        if (m_seekPending.load() && !gotFrame) {
            // seek 后第一帧到达：
            //   av_seek_frame(AVSEEK_FLAG_BACKWARD) 会落到 ≤ 目标时间的
            //   最近关键帧，因此队列前面会有一段 PTS < 目标时间 的"前置
            //   帧"（仅用于解码连续性，不应显示）。
            //
            //   策略：丢弃 PTS 明显早于目标时间（>0.5s）的帧，直到遇到
            //   PTS ≥ 目标时间附近的帧再对齐时钟。这样进度条不会从用户
            //   点击的位置"弹回"到关键帧位置。
            double target = m_playStartPts.load(); // rbSeekTo 中设置为目标时间
            if (framePts + 0.5 < target) {
                // 前置帧：直接丢弃
                AVFrame* drop = m_frameQueue->rbPop();
                if (drop) av_frame_free(&drop);
                continue;
            }
            // 找到目标位置的帧，对齐时钟
            m_playStartPts.store(framePts);
            m_playStartWallTime.store(wallNow);
            playTime            = framePts;
            m_currentTime.store(framePts);
            m_seekPending.store(false);
        }

        if (framePts <= playTime + 0.005) { // 5ms 容差
            // 弹出并替换当前帧
            AVFrame* f = m_frameQueue->rbPop();
            if (f) {
                rbUpdateFrameIndex(framePts);
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

double RBVideoPlayer::rbFrameDuration() const {
    if (!m_demuxer) return 1.0 / 30.0;
    AVRational r = m_demuxer->rbVideoFrameRate();
    if (r.num > 0 && r.den > 0) {
        double fps = av_q2d(r);
        // 真实视频帧率范围大致在 [1, 240]（含 24/25/29.97/30/50/59.94/60/120/240）。
        // 超出这个范围多半是容器元数据异常（如 10000fps / 90000fps），直接丢弃。
        if (fps >= 1.0 && fps <= 240.0) return 1.0 / fps;
    }
    // 注意：不能用 m_videoTimeBase 做 fallback —— MP4 等容器的 time_base
    // 常是 1/10000 或 1/90000，与实际帧率无关；旧实现据此返回 0.0001s，
    // 会让多路帧步进算出 target≈cur，第二路帧画面永远不动。
    return 1.0 / 30.0;
}

void RBVideoPlayer::rbStepFrame(int n) {
    auto s = m_state.load();
    if (s == RBPlayerState::Idle || s == RBPlayerState::Error) return;
    if (n == 0) return;

    // 帧步进语义：暂停画面下让用户逐帧观察。
    // 播放中先 pause，与系统播放器（如 macOS QuickTime / Windows 系统播放器）一致。
    // Ended 也降为 Paused：否则慢路径里 rbSeekTo 会把 Ended 自动升回 Playing，
    // 导致 rbRefreshPausedFrameExact 因 state==Playing 直接返回，画面/PTS 不更新。
    if (s == RBPlayerState::Playing || s == RBPlayerState::Ended) {
        m_state.store(RBPlayerState::Paused);
    }

    const double fd = rbFrameDuration();
    // cur 取 currentFramePts 与 currentTime 的较大者：
    //   多路同步播放时，短视频已到末尾停在 m_currentFramePts ≈ duration_short，
    //   但 m_currentTime 仍由主时钟驱动到 duration_long 附近。
    //   按"上一帧"应从用户感知位置（主时钟）回退，而不是从该路最后真实帧 PTS 回退，
    //   否则进度条会从主时钟位置大幅跳回短视频末尾。
    const double curFp = m_currentFramePts;
    const double curCt = m_currentTime.load();
    const double cur   = std::max(curFp, curCt);

    // ─── 快路径：前进时直接从 frameQueue 顺序消费（严格逐帧）─────────────
    // 解码线程在播放/暂停态都会持续把后续帧 push 进队列（kCapacity=8），
    // 因此连按"前进一帧"时，队列里通常已经存在 PTS > 当前 PTS 的下一帧。
    // 走"pop 即换帧"的路径，完全不触发 av_seek_frame / 线程同步，几乎零开销。
    //
    // 关键改进：队列暂时为空时，短超时等待解码线程产出新帧，而不是立刻 fallback
    // 到 seek 慢路径。多路场景下，慢路径以 fd/2 为阈值丢帧、且 PTS/duration 取整
    // 在 GOP 边界附近会累积误差，导致"实际命中 PTS"跨 N 帧——表现为帧号跳变。
    // 走快路径则严格 +1 帧，所有路完全一致。
    //
    // 仅在以下情况 fallback 到 seek 慢路径：
    //   - n < 0（后退）：解码线程不能反向产帧，必须 seek
    //   - 等待解码超时（已到末端 / EOF）
    if (n > 0) {
        bool ok = true;
        for (int i = 0; i < n && ok; ++i) {
            ok = false;
            using clock = std::chrono::steady_clock;
            // 单帧最多等 200ms（够解码线程产出 1-2 帧；EOF / 卡顿场景才会超时）
            auto deadline = clock::now() + std::chrono::milliseconds(200);

            while (clock::now() < deadline) {
                AVFrame* peek = m_frameQueue->rbPeek();
                if (!peek) {
                    // 队列空：让出 CPU 让解码线程产出下一帧
                    std::this_thread::sleep_for(std::chrono::milliseconds(2));
                    continue;
                }
                int64_t rawPts = (peek->best_effort_timestamp != AV_NOPTS_VALUE)
                                ? peek->best_effort_timestamp
                                : peek->pts;
                double framePts = (rawPts != AV_NOPTS_VALUE)
                    ? rawPts * av_q2d(m_videoTimeBase)
                    : m_currentFramePts + fd;

                if (framePts <= m_currentFramePts + fd * 0.25) {
                    // 旧帧/重复帧：丢掉继续找
                    AVFrame* drop = m_frameQueue->rbPop();
                    if (drop) av_frame_free(&drop);
                    continue;
                }

                // 命中下一帧：替换 currentFrame
                AVFrame* f = m_frameQueue->rbPop();
                if (f) {
                    rbUpdateFrameIndex(framePts);
                    rbReleaseCurrentFrame();
                    m_currentFrame      = f;
                    m_currentFramePts   = framePts;
                    m_playStartPts.store(framePts);
                    m_playStartWallTime.store(rbWallTime());
                    m_currentTime.store(framePts);
                    m_seekPending.store(false);
                    ok = true;
                }
                break;
            }
            if (!ok) break;
        }
        if (ok) return; // 快路径成功，结束
        // 快路径失败（等待超时 / EOF），落到下方 seek 慢路径作为兜底
    }

    // ─── 后退专用路径：“找 PTS 严格小于 cur 的最大 PTS 帧” ───────────
    // 不依赖 fd 估算 target，对 VFR / PTS 不等距 / GOP 边界都鲁棒。
    // 典型场景（0002_a.mp4）：
    //   #14 PTS=0.472s，#15 PTS=0.539s（间隔 0.067s≈2·fd，视频录制丢帧）
    //   从 #15 后退，旧逻辑 target=0.539-0.0335=0.505，dropThresh=0.489
    //   → #14 的 0.472 < 0.489 被当作”前置帧“丢弃或仅作 fallback
    //   → #15 的 0.539 又被误认为“目标” → 位置不变 → 起”退不动“。
    // 新逻辑：seek 到 cur 附近后，从解码序列中保留“所有 PTS < cur-eps 中
    // 最大的那一帧”，遇到 PTS ≥ cur-eps 的帧就停。这样不管间隔多大都
    // 能准确拿到“上一帧”。
    if (n == -1) {
        // 后退一帧：seek 到 cur 之前一个足够远的位置，让解码器能还原
        // 出中间所有帧。fd*3 足够跨过 VFR 的大间隔。
        const double seekTarget = std::max(0.0, cur - fd * 3.0);
        rbSeekTo(seekTarget);
        if (rbStepBackwardOne(cur, 1500)) return;
        // 完全失败（已在 PTS=0 附近、无可后退）：不做任何处理
        return;
    }

    // ─── 多帧后退 / 前进慢路径：seek 到目标帧 PTS 附近，再用帧级阈值丢前置帧 ─────
    // 关键技巧：底层 av_seek_frame 走 BACKWARD 关键帧，rbRefreshPausedFrameExact
    // 用 fd/2 作为丢弃阈值，能精确停在目标帧上而非关键帧。
    //
    // 后退（n<0）放宽超时：HEVC / 大 GOP（16/32/64）场景下，BACKWARD seek 落到
    // GOP 起始 IDR，要从 IDR 一路解码到 target（可能 30+ 帧），500ms 在硬解失败/
    // 软解时容易超时。
    const double target = std::max(0.0, std::min(cur + n * fd, m_duration));
    rbSeekTo(target);
    rbRefreshPausedFrameExact(target, fd, n < 0 ? 1500 : 500);
}
bool RBVideoPlayer::rbRefreshPausedFrameExact(double target, double frameDur, int timeoutMs) {
    auto s = m_state.load();
    if (s == RBPlayerState::Idle || s == RBPlayerState::Error || s == RBPlayerState::Playing) {
        return false;
    }
    using clock = std::chrono::steady_clock;
    auto deadline = clock::now() + std::chrono::milliseconds(timeoutMs);

    // 丢帧阈值：PTS < target - frameDur/2 认为是 keyframe 表的"前置帧"。
    // 只留下 PTS 距目标不超过 0.5 帧的帧，即目标帧本身（或与其重合的临近帧）。
    const double dropThresh = target - frameDur * 0.5;

    // 兜底候选帧：保存"PTS < dropThresh 但最接近 target 的那一帧"。
    // 用于解决"大 GOP（HEVC GOP=16+）+ B 帧 + 后退一帧"的死锁场景：
    //   target 处于 GOP 中段，BACKWARD seek 落到 GOP 起始的 IDR，
    //   解码线程会先吐 IDR ~ target-1 这一长串帧，全部 < dropThresh；
    //   若直接丢光，超时返回 false → 当前帧不换 → target 不变
    //   → 下一次按"上一帧"还是同一个 target → 永远卡在 #16 那种 GOP 边界帧。
    // 改进：保留最后一个 < dropThresh 的帧作为兜底，超时时换上它。
    // 这样实际效果：最坏只回退到 GOP 边界的"上一帧"附近（误差 ≤1 帧），
    // 用户连按"上一帧"可以一路回退到 0，不会停滞。
    AVFrame* fallback         = nullptr;
    double   fallbackPts      = 0.0;
    auto useAndReleaseFallback = [&](){
        if (!fallback) return false;
        rbUpdateFrameIndex(fallbackPts);
        rbReleaseCurrentFrame();
        m_currentFrame      = fallback;
        m_currentFramePts   = fallbackPts;
        m_playStartPts.store(fallbackPts);
        m_playStartWallTime.store(rbWallTime());
        m_currentTime.store(fallbackPts);
        m_seekPending.store(false);
        fallback            = nullptr;
        return true;
    };

    while (clock::now() < deadline) {
        AVFrame* peek = m_frameQueue->rbPeek();
        if (peek) {
            int64_t rawPts = (peek->best_effort_timestamp != AV_NOPTS_VALUE)
                           ? peek->best_effort_timestamp
                           : peek->pts;
            // 关键：rawPts 为 AV_NOPTS_VALUE 时绝不能当 0 处理，否则永远满足
            // framePts < dropThresh，帧被一路丢光，500ms timeout 后
            // m_currentFrame 没换，多路下表现为"只第一路画面更新"。
            // 解码顺序里无 PTS 的帧，按"上一帧 PTS + frameDur"估算；这种帧
            // 直接当作目标帧命中，不再参与丢帧判断。
            bool   noPts = (rawPts == AV_NOPTS_VALUE);
            double framePts = noPts ? (m_currentFramePts + frameDur)
                                    : rawPts * av_q2d(m_videoTimeBase);

            if (m_seekPending.load() && !noPts && framePts < dropThresh) {
                // 前置帧：保留为 fallback（取最接近 target 的那一帧）
                AVFrame* drop = m_frameQueue->rbPop();
                if (drop) {
                    if (!fallback || framePts > fallbackPts) {
                        if (fallback) av_frame_free(&fallback);
                        fallback    = drop;
                        fallbackPts = framePts;
                    } else {
                        av_frame_free(&drop);
                    }
                }
                continue;
            }

            AVFrame* f = m_frameQueue->rbPop();
            if (f) {
                if (fallback) av_frame_free(&fallback);
                rbUpdateFrameIndex(framePts);
                rbReleaseCurrentFrame();
                m_currentFrame    = f;
                m_currentFramePts = framePts;
                m_playStartPts.store(framePts);
                m_playStartWallTime.store(rbWallTime());
                m_currentTime.store(framePts);
                m_seekPending.store(false);
                return true;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    // 超时：用兜底候选帧。fallback 为最接近 target 的"前置帧"，
    // 退而求其次也比卡死强（用户表现为"上一帧"虽然偏一点点但能持续后退）。
    if (useAndReleaseFallback()) return true;
    return false;
}

bool RBVideoPlayer::rbStepBackwardOne(double curPts, int timeoutMs) {
    // 后退一帧专用：找到 PTS 严格小于 curPts 的最大 PTS 帧。
    // 调用前必须已经做过 rbSeekTo(curPts - 足够大余量)，让解码器从更早的关键帧
    // 开始解码，覆盖 curPts 之前的帧序列。
    auto s = m_state.load();
    if (s == RBPlayerState::Idle || s == RBPlayerState::Error || s == RBPlayerState::Playing) {
        return false;
    }
    using clock = std::chrono::steady_clock;
    auto deadline = clock::now() + std::chrono::milliseconds(timeoutMs);

    // PTS 比较的浮点容差（避免与 curPts 相等的帧被误判为"严格小"）。
    // 取一个很小的值即可，经验上 1ms 已远小于任何真实 fd。
    const double kEps = 0.001;

    // 候选帧：当前为止见过的、PTS < curPts - kEps 的最大 PTS 帧。
    AVFrame* best         = nullptr;
    double   bestPts      = -1.0;

    auto commitBest = [&](){
        if (!best) return false;
        rbUpdateFrameIndex(bestPts);
        rbReleaseCurrentFrame();
        m_currentFrame      = best;
        m_currentFramePts   = bestPts;
        m_playStartPts.store(bestPts);
        m_playStartWallTime.store(rbWallTime());
        m_currentTime.store(bestPts);
        m_seekPending.store(false);
        best                = nullptr;
        return true;
    };

    while (clock::now() < deadline) {
        AVFrame* peek = m_frameQueue->rbPeek();
        if (!peek) {
            if (m_frameQueue->rbIsEof()) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }
        int64_t rawPts = (peek->best_effort_timestamp != AV_NOPTS_VALUE)
                       ? peek->best_effort_timestamp
                       : peek->pts;
        bool   noPts = (rawPts == AV_NOPTS_VALUE);
        double framePts = noPts ? (m_currentFramePts /* 占位 */)
                                : rawPts * av_q2d(m_videoTimeBase);

        if (noPts) {
            // 无 PTS 帧：当作"未知"，直接消费，不参与候选挑选。
            AVFrame* drop = m_frameQueue->rbPop();
            if (drop) av_frame_free(&drop);
            continue;
        }

        if (framePts >= curPts - kEps) {
            // 已到达/越过当前帧：候选 best 就是"严格上一帧"，提交并返回。
            // peek 这一帧不消费（留给后续播放/前进路径自然消费）。
            if (commitBest()) return true;
            // 若没有候选（说明 BACKWARD seek 没有覆盖到 curPts 之前的帧 ——
            // 极端情况：curPts ≈ 0，已无更早的帧），退出。
            return false;
        }

        // PTS < curPts - kEps：作为后退候选。取最大 PTS。
        AVFrame* f = m_frameQueue->rbPop();
        if (!f) continue;
        if (!best || framePts > bestPts) {
            if (best) av_frame_free(&best);
            best    = f;
            bestPts = framePts;
        } else {
            av_frame_free(&f);
        }
    }
    // 超时：用当前最佳候选兜底
    if (commitBest()) return true;
    return false;
}

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
    const double target = m_playStartPts.load();

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
            if (m_seekPending.load() && framePts + 0.5 < target) {
                AVFrame* drop = m_frameQueue->rbPop();
                if (drop) av_frame_free(&drop);
                continue;
            }

            // 弹出目标帧作为当前显示帧
            AVFrame* f = m_frameQueue->rbPop();
            if (f) {
                rbUpdateFrameIndex(framePts);
                rbReleaseCurrentFrame();
                m_currentFrame    = f;
                m_currentFramePts = framePts;
                // 对齐时钟，但保持暂停状态：清除 seekPending，使 rbGetCurrentFrame
                // 后续即便切到 Playing 也不会再丢这一帧
                m_playStartPts.store(framePts);
                m_playStartWallTime.store(rbWallTime());
                m_currentTime.store(framePts);
                m_seekPending.store(false);
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

// ─── 帧信息查询 ──────────────────────────────────────────────────────────────

int64_t RBVideoPlayer::rbCurrentFrameNum() const {
    // 直接返回按显示顺序自增的连续帧序号（由 rbUpdateFrameIndex 维护）。
    //
    // 不再使用 m_currentFrame->pts / duration 推算，原因：
    //   1. 含 B 帧的 GOP，PTS 不是"显示顺序的等差数列"，pts/dur 会出现
    //      0,1,2,2,3,4,4,5… 这种重复或跳变（跨路 GOP 结构不同更明显）；
    //   2. VFR 视频每帧 duration 不一致，pts/avgDur 误差累积；
    //   3. 容器 start_time 偏移会让首帧帧号偏离 0。
    // 自增序号在快路径每帧 +1，seek/大跨度跳时按 PTS·fps 重校准，
    // 多路全程严格一致，符合用户对"连按下一帧就 +1"的直觉。
    if (!m_currentFrame) return 0;
    return m_displayFrameIndex;
}

void RBVideoPlayer::rbUpdateFrameIndex(double newPts) {
    // 在替换 m_currentFrame 之前调用：根据 newPts 与当前帧 PTS 的差更新序号。
    if (!m_currentFrame) {
        // 首帧：用 PTS·fps 估算起始序号（容器 start_time 不为 0 时也能对）。
        double fps = rbFps();
        m_displayFrameIndex = (fps > 0.0)
            ? static_cast<int64_t>(newPts * fps + 0.5)
            : 0;
        return;
    }
    const double fd = rbFrameDuration();
    if (fd <= 0.0) {
        m_displayFrameIndex += 1;
        return;
    }
    const double dt = newPts - m_currentFramePts;
    // VFR / B 帧 PTS 不等距场景下，相邻一帧的 dt 可能是 0.5fd ~ 3fd。
    // 这里用宽容性区间判“严格相邻一帧”：只要 PTS 单调且间隔在 ±3fd 内，
    // 都认为是“退/进一帧”。避免 0002_a.mp4 这种首段有丢帧的视频被当成“大跨度
    // 跳”、被 PTS·fps 误校准为 #16（实际应是 #15）。
    if (dt > 0.0 && dt < fd * 3.0) {
        m_displayFrameIndex += 1;             // 严格下一显示帧
    } else if (dt < 0.0 && dt > -fd * 3.0) {
        m_displayFrameIndex -= 1;             // 严格上一显示帧
    } else {
        // seek / 大跨度跳（|dt| ≥ 3fd）：按 PTS·fps 重校准
        double fps = rbFps();
        m_displayFrameIndex = (fps > 0.0)
            ? static_cast<int64_t>(newPts * fps + 0.5)
            : m_displayFrameIndex + (dt > 0 ? 1 : -1);
    }
}

char RBVideoPlayer::rbCurrentFrameType() const {
    if (!m_currentFrame) return '?';
    return av_get_picture_type_char(m_currentFrame->pict_type);
}

double RBVideoPlayer::rbFps() const {
    if (!m_demuxer) return 0.0;
    AVRational r = m_demuxer->rbVideoFrameRate();
    if (r.num > 0 && r.den > 0) {
        double fps = av_q2d(r);
        if (fps >= 1.0 && fps <= 240.0) return fps;
    }
    return 0.0;
}

std::string RBVideoPlayer::rbCodecName() const {
    if (!m_demuxer) return "";
    AVCodecParameters* par = m_demuxer->rbVideoCodecPar();
    if (!par) return "";
    const char* name = avcodec_get_name(par->codec_id);
    return name ? name : "";
}

std::string RBVideoPlayer::rbPixelFormatName() const {
    // 像素格式有两个层级，需要分别报告：
    //   ① 码流声明格式（codecpar->format）—— 来自容器 SPS / extradata，
    //      ffprobe 报告的就是这个，例如 yuv420p / yuv420p10le。
    //   ② 实际产出的 AVFrame->format —— 解码器真正吐到 CPU 上的格式。
    //      软解时 ① == ②；硬解时 VideoToolbox 在 macOS 上几乎总是输出
    //      nv12（8bit）或 p010le（10bit），即使码流是 yuv420p。
    //
    // 输出策略：
    //   - 两者一致：仅显示一个（如 "yuv420p"）
    //   - 两者不同：显示 "码流 → 输出"（如 "yuv420p → nv12 (VT)"）
    //   - 还没解出第一帧：仅显示码流格式
    std::string streamFmt;
    if (m_demuxer) {
        AVCodecParameters* par = m_demuxer->rbVideoCodecPar();
        if (par && par->format != AV_PIX_FMT_NONE) {
            const char* n = av_get_pix_fmt_name(
                static_cast<AVPixelFormat>(par->format));
            if (n) streamFmt = n;
        }
    }

    std::string runtimeFmt;
    if (m_currentFrame && m_currentFrame->format != AV_PIX_FMT_NONE) {
        const char* n = av_get_pix_fmt_name(
            static_cast<AVPixelFormat>(m_currentFrame->format));
        if (n) runtimeFmt = n;
    }

    if (runtimeFmt.empty()) return streamFmt;            // 没解出帧：只显示码流
    if (streamFmt.empty())  return runtimeFmt;           // 兜底
    if (streamFmt == runtimeFmt) return streamFmt;       // 软解一致

    // 硬解或像素格式发生转换 —— 双层显示
    bool hw = m_decoder && m_decoder->rbHwAccelActive();
    return streamFmt + " → " + runtimeFmt + (hw ? " (VT)" : "");
}

std::string RBVideoPlayer::rbColorSpaceName() const {
    // 优先从当前帧读取（FFmpeg 会从码流 VUI 解出来填到 frame->colorspace）
    AVColorSpace sp = AVCOL_SPC_UNSPECIFIED;
    if (m_currentFrame) sp = m_currentFrame->colorspace;
    if (sp == AVCOL_SPC_UNSPECIFIED && m_decoder) sp = m_decoder->rbColorSpace();
    if (sp == AVCOL_SPC_UNSPECIFIED) return "";
    const char* n = av_color_space_name(sp);
    return n ? n : "";
}

std::string RBVideoPlayer::rbColorRangeName() const {
    AVColorRange r = AVCOL_RANGE_UNSPECIFIED;
    if (m_currentFrame) r = m_currentFrame->color_range;
    if (r == AVCOL_RANGE_UNSPECIFIED && m_decoder) r = m_decoder->rbColorRange();
    if (r == AVCOL_RANGE_MPEG) return "tv";   // limited
    if (r == AVCOL_RANGE_JPEG) return "pc";   // full
    return "";
}

bool RBVideoPlayer::rbHwAccelActive() const {
    return m_decoder && m_decoder->rbHwAccelActive();
}

std::string RBVideoPlayer::rbDecoderName() const {
    if (!m_decoder) return "";
    return m_decoder->rbDecoderName();
}

} // namespace rb
