/**
 * rb_player_engine.cpp — RBPlayerEngine 实现
 */

#include "rb_player_engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <future>
#include <vector>

namespace rb {

static double rbWallTime() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

RBPlayerEngine::RBPlayerEngine() = default;
RBPlayerEngine::~RBPlayerEngine() { rbCloseAll(); }

// ════════════════════════════════════════════════════════════════════════
// 文件管理
// ════════════════════════════════════════════════════════════════════════

bool RBPlayerEngine::rbOpenFiles(const std::vector<std::string>& files) {
    rbCloseAll();
    if (files.empty()) return false;

    std::lock_guard<std::mutex> lk(m_mutex);
    bool anyOk = false;
    int  count = std::min<int>(static_cast<int>(files.size()), kMaxPlayers);
    for (int i = 0; i < count; ++i) {
        auto p = std::make_unique<RBVideoPlayer>();
        if (p->rbOpen(files[i])) {
            // 多路同步：所有路启用主时钟模式
            p->rbEnableMasterClock(true);
            m_players.push_back(std::move(p));
            anyOk = true;
        }
        // 打开失败的文件直接跳过，不占槽位
    }

    // 复位主时钟
    m_playing.store(false);
    m_anchorWall = rbWallTime();
    m_anchorPts  = 0.0;
    m_pausedPts  = 0.0;
    // 倍速复位为 1.0x（“打开新文件 = 干净状态”）
    m_speed       = 1.0;
    m_speedLevel  = 0;
    for (auto& q : m_players) { if (q) q->rbSetSpeed(1.0); }
    return anyOk;
}

int RBPlayerEngine::rbAddFile(const std::string& file) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (static_cast<int>(m_players.size()) >= kMaxPlayers) return -1;

    auto p = std::make_unique<RBVideoPlayer>();
    if (!p->rbOpen(file)) return -1;

    // ────────────────────────────────────────────────────────────────
    // 解耦：新加入的视频从自己的 0 开始独立播放，不被主时钟拖到当前位置
    //
    // 旧行为（出问题）：
    //   p->rbEnableMasterClock(true);
    //   p->rbSetMasterClock(rbComputeMasterLocked());  // 拉到 e.g. 1:20
    //   if (m_playing) p->rbPlay();
    // 现象：
    //   1) 已经播到 1:20 时点击"添加" → 新视频被强行设置主时钟到 1:20，
    //      内部从 0 解码追赶 → 视觉上"快速播放追赶"；
    //   2) 同时添加两个视频 → 两路都被同一主时钟广播覆盖，时间戳相互
    //      绑定，无法独立播放/控制。
    //
    // 新行为：与"单路控制（rbTogglePauseAt / rbSeekAt / rbStepFrameAt）"
    // 的既有策略保持一致 —— 让该路脱离主时钟（rbEnableMasterClock(false)），
    // 不会被 rbTick 的 rbBroadcastClock 覆盖；从自身 0 位置独立起播。
    // 用户后续如需多路对齐，可通过：拖拽全局进度条（rbSeek 内部会重新
    // 把所有路 rbEnableMasterClock(true) 拉回主时钟）来主动对齐。
    // ────────────────────────────────────────────────────────────────
    p->rbEnableMasterClock(false);
    // 让新加路继承当前全局倍速，避免“主时钟 2x 下独立路仍 1x”的不一致。
    p->rbSetSpeed(m_speed);
    if (m_playing.load()) {
        p->rbPlay();          // 全局在播 → 新路从 0 独立播
    }
    // 全局暂停态：新路保持初始暂停在 0，由用户后续控制。

    m_players.push_back(std::move(p));
    return static_cast<int>(m_players.size()) - 1;
}

bool RBPlayerEngine::rbReplaceAt(int idx, const std::string& file) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (idx < 0 || idx >= static_cast<int>(m_players.size())) return false;
    if (file.empty()) return false;

    auto np = std::make_unique<RBVideoPlayer>();
    if (!np->rbOpen(file)) {
        // 打开失败：保持原 player 不变，由调用方决定是否提示用户。
        return false;
    }
    // 与 rbAddFile 一致的初始化策略：脱离主时钟、继承全局倍速、若全局在播则起播。
    np->rbEnableMasterClock(false);
    np->rbSetSpeed(m_speed);
    if (m_playing.load()) {
        np->rbPlay();
    }

    // 关闭旧 player 后再原地替换槽位：索引保持不变，layout/UI 无需重排。
    if (m_players[idx]) m_players[idx]->rbClose();
    m_players[idx] = std::move(np);
    return true;
}

void RBPlayerEngine::rbCloseAt(int idx) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (idx < 0 || idx >= static_cast<int>(m_players.size())) return;
    if (m_players[idx]) m_players[idx]->rbClose();
    m_players.erase(m_players.begin() + idx);
}

void RBPlayerEngine::rbCloseAll() {
    std::lock_guard<std::mutex> lk(m_mutex);
    for (auto& p : m_players) {
        if (p) p->rbClose();
    }
    m_players.clear();
    m_playing.store(false);
    m_anchorWall = rbWallTime();
    m_anchorPts  = 0.0;
    m_pausedPts  = 0.0;
    m_speed      = 1.0;
    m_speedLevel = 0;
    m_pendingAnchorRebase = false;
}

int RBPlayerEngine::rbCount() const {
    std::lock_guard<std::mutex> lk(m_mutex);
    return static_cast<int>(m_players.size());
}

RBVideoPlayer* RBPlayerEngine::rbAt(int idx) const {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (idx < 0 || idx >= static_cast<int>(m_players.size())) return nullptr;
    return m_players[idx].get();
}

const std::string& RBPlayerEngine::rbPathAt(int idx) const {
    static const std::string kEmpty;
    std::lock_guard<std::mutex> lk(m_mutex);
    if (idx < 0 || idx >= static_cast<int>(m_players.size())) return kEmpty;
    return m_players[idx]->rbFilePath();
}

// ════════════════════════════════════════════════════════════════════════
// 全局控制
// ════════════════════════════════════════════════════════════════════════

void RBPlayerEngine::rbPlay() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    // ────────────────────────────────────────────────────────────────
    // 全局 ▶ 语义（用户需求）：不对齐时间戳。
    //   - 已经在独立播放（脱离主时钟）的路：完全不动，让它继续按自己时
    //     钟播；
    //   - 已经在主时钟下播放的路：继续播；
    //   - 仅"当前暂停"的路（既没走主时钟、也没在独立播放）：从它各自
    //     停下的位置恢复播放，并继续走独立时钟（不重新加入主时钟，
    //     避免被主时钟的 anchorPts 拉到其他位置造成"加速追赶"）。
    //
    // 结果：每路从各自停下的位置接着播；不会强行把某路时间戳对齐到
    // 其他路，符合用户期望的"全局 ▶ = 全部继续播"。
    // ────────────────────────────────────────────────────────────────

    // 末尾点击 ▶ = 自动 replay：单路 RBVideoPlayer::rbPlay() 检测到 Ended
    // 会自动 seek 回 0，引擎层的 m_pausedPts 仍停留在 duration。这里把
    // 锚点复位到 0，避免主时钟下一次 tick 把刚 replay 到 0 的路再次拉到末尾。
    bool allEnded = true;
    for (auto& p : m_players) {
        if (!p) continue;
        if (!p->rbIsEnded()) { allEnded = false; break; }
    }
    if (allEnded) {
        m_pausedPts  = 0.0;
        m_anchorPts  = 0.0;
        m_anchorWall = rbWallTime();
        // 全部 Ended 场景下让所有路重新加入主时钟，从 0 开始齐播
        for (auto& p : m_players) {
            if (!p) continue;
            p->rbEnableMasterClock(true);
            p->rbPlay();
        }
        if (!m_playing.load()) {
            m_anchorWall = rbWallTime();
            m_anchorPts  = 0.0;
            m_playing.store(true);
        }
        // 修复：p->rbPlay() 在 Ended 自动 replay 时要内部 seek 到 0、
        // 解码首帧，每路耗时不一致。串行调用完后把 anchorWall 复位到
        // "全部就绪"这一刻，避免先 ready 的路被主时钟 broadcast 推到
        // 几十 ms 之后，画面出现"卡一下再追上"。
        m_anchorWall = rbWallTime();
        // 等所有路首帧到达后，把 anchorPts 重锚为 max(各路实际首帧 PTS)，
        // 解决"路 0 视频首帧 PTS=0.533 而路 1=0"导致的左路单独卡帧问题。
        m_pendingAnchorRebase = true;
        return;
    }

    // 非"全部 Ended"场景：保留每路当前状态（独立播放/独立暂停/主时钟），
    // 只对"当前没在播"的路单独恢复播放，不重置锚点。
    if (!m_playing.load()) {
        // 引擎全局处于暂停态（主时钟没在跑）。把"主时钟仍在用且当前暂停
        // 的路"拉回主时钟模式下播放：以 m_pausedPts 作为锚点。
        m_anchorWall = rbWallTime();
        m_anchorPts  = m_pausedPts;
        m_playing.store(true);
        for (auto& p : m_players) {
            if (!p) continue;
            // 仅对"还在主时钟模式"的路重新走主时钟 ▶；脱离主时钟的单路
            // （独立播放或独立暂停）保留各自状态不动。
            if (p->rbUseMasterClock()) {
                p->rbPlay();
            }
        }
        // 修复：每路 rbPlay() 要从暂停的 lastFrame 状态重新启动解码、
        // 重填队列，耗时不一致。串行完成后把 anchorWall 重置到"全部
        // 就绪"这一刻，避免先 ready 的路被立刻推几十 ms 出现卡顿。
        m_anchorWall = rbWallTime();
    }

    // 把"独立暂停"的路单独恢复播放（仍走独立时钟，不强行加入主时钟）。
    // 避免被主时钟的 anchorPts 拉到其他位置 = 不会"加速追赶"。
    for (auto& p : m_players) {
        if (!p) continue;
        if (!p->rbUseMasterClock() && !p->rbIsPlaying()) {
            p->rbPlay();   // 独立时钟下从各自停下的位置继续
        }
    }
}

void RBPlayerEngine::rbPause() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    if (m_playing.load()) {
        m_pausedPts = rbComputeMasterLocked();
        m_playing.store(false);
    }
    // 全局暂停语义：所有路都停（含脱离主时钟的独立播放路）。
    // 注意不修改 rbUseMasterClock 标志：保留各路"是否走主时钟"的状态，
    // 下次全局 ▶ 时仍能让独立的路从各自停下的位置接着播，不被对齐。
    for (auto& p : m_players) {
        if (p) p->rbPause();
    }
}

bool RBPlayerEngine::rbIsPlaying() const {
    // "全局是否在播"语义：只要有任一路在播就算播放中（含独立时钟下的路）。
    // 这样全局 ▶/⏸ 按钮在"a 暂停、bc 独立播放"场景下也能正确显示 ⏸ 图标。
    if (m_playing.load()) return true;
    std::lock_guard<std::mutex> lk(m_mutex);
    for (auto& p : m_players) {
        if (p && p->rbIsPlaying()) return true;
    }
    return false;
}

void RBPlayerEngine::rbTogglePause() {
    if (rbIsPlaying()) rbPause();
    else               rbPlay();
}

void RBPlayerEngine::rbSeek(double seconds) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    seconds = std::max(0.0, seconds);
    m_anchorWall = rbWallTime();
    m_anchorPts  = seconds;
    m_pausedPts  = seconds;

    for (auto& p : m_players) {
        if (!p) continue;
        // 重新启用主时钟，全局 seek 下所有路重新对齐
        p->rbEnableMasterClock(true);
        // 各路独立 clamp 到自己的 duration；若超过则停在结尾
        double dur = p->rbDuration();
        double t   = (dur > 0.0) ? std::min(seconds, dur) : seconds;
        p->rbSeekTo(t);
        // 暂停时主动刷新到 seek 后的首帧（多窗对齐）
        if (!m_playing.load()) {
            p->rbRefreshPausedFrame(200);
        }
    }

    // ───────────────────────────────────────────────────────────────────
    // 修复：rbSeekTo 是阻塞调用（要 flush 解码器、重新 demux、解码
    // 首帧），每路耗时可达几十毫秒——尤其 Windows 上硬解上下文重建慢。
    //
    // 旧实现把 m_anchorWall 设在循环开始前，等所有路 seek 完后已经过
    // 去 N 毫秒；如果此时 m_playing=true，下一次 rbTick 就会按
    //   master = seconds + (wallNow - wallBeforeSeek) * speed   // ≈ 0.05s
    // 给所有路下发新时钟。先 seek 完的那路（通常是左/路 0）画面已就位
    // 在 pts=0，下一帧立刻被推到 ~0.05s → 视觉上"卡一下、再快速追赶"。
    // 后 seek 完的那路（路 1）解码本身就晚到，反而和这个偏移对齐。
    //
    // 修复：所有路 seek 全部完成后，把 anchorWall 复位为"现在"，让主
    // 时钟从"全部就绪那一刻"开始累加，避免任一路出现起跑偏移。
    // ───────────────────────────────────────────────────────────────────
    m_anchorWall = rbWallTime();

    // 标记：等 rbTick 看到所有主时钟路 seekPending 都清掉那一刻，把
    // anchorPts 重锚到 max(各路实际首帧 PTS)。修复 Windows 上播放中
    // 重置时"路 0 卡 17 帧、路 1 追上后才一起播"的问题——根因是不同
    // 路视频 av_seek 后第一个解码帧 PTS 不一致（路 0=0.533，路 1=0），
    // 主时钟若仍从 target=0 起跑，路 0 队列里没有 PTS≤0 的帧能取，
    // 画面只能停在 seek 之前的最后一帧直到主时钟追上 0.533s。
    m_pendingAnchorRebase = true;
}

void RBPlayerEngine::rbSeekRelative(double deltaSeconds) {    // ────────────────────────────────────────────────────────────────
    // 全局相对 seek（前进/后退按钮）：
    //   - 主时钟下的路：以主时钟当前位置 + delta 作为统一目标（仍齐播）
    //   - 独立时钟下的路（已脱离主时钟）：以该路自身 currentTime + delta，
    //     不被强行对齐到主时钟位置。
    //
    // 这与"用户在顶部进度条上拖拽"的语义不同——拖拽是绝对 seek，期望
    // 全部跳到同一位置；按 << / >> 是"全部 ±N 秒"，应保留每路相对位置。
    // ────────────────────────────────────────────────────────────────
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    // 1) 主时钟那批路：算统一目标 + clamp，并更新主时钟锚点
    double masterCur    = rbComputeMasterLocked();
    double masterTarget = std::max(0.0, masterCur + deltaSeconds);
    m_anchorWall = rbWallTime();
    m_anchorPts  = masterTarget;
    m_pausedPts  = masterTarget;

    for (auto& p : m_players) {
        if (!p) continue;
        if (p->rbUseMasterClock()) {
            // 主时钟路：跳到统一目标（clamp 到自身 duration）
            double dur = p->rbDuration();
            double t   = (dur > 0.0) ? std::min(masterTarget, dur) : masterTarget;
            p->rbSeekTo(t);
            if (!m_playing.load()) {
                p->rbRefreshPausedFrame(200);
            }
        } else {
            // 独立时钟路：基于该路自身当前位置 ±delta
            double cur = p->rbCurrentTime();
            double dur = p->rbDuration();
            double t   = std::max(0.0, cur + deltaSeconds);
            if (dur > 0.0) t = std::min(t, dur);
            p->rbSeekTo(t);
            if (!p->rbIsPlaying()) {
                p->rbRefreshPausedFrame(200);
            }
        }
    }

    // 同 rbSeek 的修复：rbSeekTo 串行耗时，所有路完成后重置 anchorWall，
    // 避免主时钟下一次 broadcast 把先就绪那路推到偏移位置造成"卡一下
    // 再追赶"。这里只影响主时钟路；独立时钟路本来就不读主时钟。
    m_anchorWall = rbWallTime();

    // 同 rbSeek：等所有主时钟路 seekPending 清掉那一刻，把 anchorPts 重
    // 锚为 max(各路实际首帧 PTS)，避免某路因首帧 PTS 较大而单独卡帧。
    m_pendingAnchorRebase = true;
}


void RBPlayerEngine::rbStepFrame(int n) {
    // ───────────────────────────────────────────────────────────────────
    // 全局帧步进：完全持锁串行调用每路单路 rbStepFrame。
    //   - 前进 (n>0 且 ≤3)：单路内部走 fast path（pop 队列），毫秒级；
    //   - 后退 (n<0)：单路内部走 seek 慢路径，每路 ~50-500ms。N 路串行会
    //     有可见卡顿，但功能正确。多路场景下用户能容忍。
    //
    // 不再用并发 / 统一 target —— 那些都被验证会引入"反向只生效第一路"
    // 等正确性问题。优先保证功能正确，性能优化以后再做。
    // ───────────────────────────────────────────────────────────────────
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    // 全局帧步进语义：先全局 pause
    if (m_playing.load()) {
        m_pausedPts = rbComputeMasterLocked();
        m_playing.store(false);
        for (auto& p : m_players) if (p) p->rbPause();
    }

    // 取所有路中最小的 frameDuration 作为全局步长（仅用于更新主时钟锚点）
    double fd    = 1.0 / 30.0;
    bool   first = true;
    for (auto& p : m_players) {
        if (!p) continue;
        double f = p->rbFrameDuration();
        if (first) { fd = f; first = false; }
        else       { fd = std::min(fd, f); }
    }

    double target = std::max(0.0, m_pausedPts + n * fd);
    m_anchorWall = rbWallTime();
    m_anchorPts  = target;
    m_pausedPts  = target;

    // 每路用各自的 currentFramePts 做 step（与单路按钮行为一致，
    // 已验证正确）。多路时刻不齐时各路各走各的一帧，可接受。
    for (auto& p : m_players) {
        if (!p) continue;
        p->rbStepFrame(n);
    }
}

// ════════════════════════════════════════════════════════════════════════
// 单路控制（不影响其他路）
// ════════════════════════════════════════════════════════════════════════

void RBPlayerEngine::rbTogglePauseAt(int idx) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (idx < 0 || idx >= static_cast<int>(m_players.size())) return;
    auto& p = m_players[idx];
    if (!p) return;

    // 单路暂停时关闭主时钟模式，避免被全局时钟覆盖；恢复时再打开
    if (p->rbIsPlaying()) {
        p->rbEnableMasterClock(false);
        p->rbPause();
    } else {
        // 把当前位置作为单路的新锚点继续
        p->rbEnableMasterClock(false);
        p->rbPlay();
    }
}

void RBPlayerEngine::rbSeekAt(int idx, double seconds) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (idx < 0 || idx >= static_cast<int>(m_players.size())) return;
    auto& p = m_players[idx];
    if (!p) return;

    // 单路 seek：必须脱离主时钟，否则下一次 rbTick 会把该路拉回主时钟位置，
    // 视觉上 seek 像没生效。与 rbStepFrameAt / rbTogglePauseAt 保持一致策略。
    p->rbEnableMasterClock(false);
    p->rbSeekTo(seconds);
    if (!m_playing.load() || !p->rbIsPlaying()) {
        p->rbRefreshPausedFrame(200);
    }
}

void RBPlayerEngine::rbStepFrameAt(int idx, int n) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (idx < 0 || idx >= static_cast<int>(m_players.size())) return;
    auto& p = m_players[idx];
    if (!p) return;
    // 单路帧步进时，要脱离主时钟，否则下一次 broadcast 会把它拉回主时钟位置
    p->rbEnableMasterClock(false);
    p->rbStepFrame(n);
}

// ════════════════════════════════════════════════════════════════════════
// 状态查询
// ════════════════════════════════════════════════════════════════════════

double RBPlayerEngine::rbPosition() const {
    std::lock_guard<std::mutex> lk(m_mutex);
    return rbComputeMasterLocked();
}

double RBPlayerEngine::rbDuration() const {
    std::lock_guard<std::mutex> lk(m_mutex);
    double d = 0.0;
    for (auto& p : m_players) {
        if (p) d = std::max(d, p->rbDuration());
    }
    return d;
}

bool RBPlayerEngine::rbIsAllEnded() const {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return false;
    for (auto& p : m_players) {
        if (p && !p->rbIsEnded()) return false;
    }
    return true;
}

double RBPlayerEngine::rbFrameDuration() const {
    std::lock_guard<std::mutex> lk(m_mutex);
    double fd = 1.0 / 30.0;
    bool   first = true;
    for (auto& p : m_players) {
        if (!p) continue;
        double f = p->rbFrameDuration();
        if (first) { fd = f; first = false; }
        else       { fd = std::min(fd, f); }
    }
    return fd;
}

// ════════════════════════════════════════════════════════════════════════
// Tick：每帧调用，推进主时钟并下发
// ════════════════════════════════════════════════════════════════════════

void RBPlayerEngine::rbTick() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    // ───────────────────────────────────────────────────────────────────
    // 主时钟"等所有主时钟路就绪"闸门：
    //
    // 现象（Windows 高频复现）：全局重置/全局播放/全局 seek 后，左路
    // 视频卡顿一下再快速追上右路。
    //
    // 根因：rbSeek/rbPlay 末尾虽然把 m_anchorWall 重锚为"返回那一刻"，
    // 但此时各路 demuxer/decoder 刚 restart，第一帧仍在异步解码中。
    // 等几十毫秒后 rbTick 触发，master 已从 anchorPts 跑出 N ms。
    // 先就绪的那路（通常解码上下文重建快的）一收到第一帧立刻被主时钟
    // 推到 N ms 位置 —— 队列里 PTS 早于 master 的若干帧立刻被消费掉，
    // 视觉上就是"卡一下连刷数帧追赶"。两路视频帧率不同（如 16fps vs
    // 24fps）/ GOP 不同时差异更明显。
    //
    // 修复：rbTick 推进主时钟前，先检查"所有主时钟模式且在播的路"是否
    // 都已清掉 m_seekPending（首帧已到、时钟已对齐）。只要有任何一路
    // 还 pending，就把 m_anchorWall 重锚为 now，等价于让主时钟原地
    // "停摆"在 m_anchorPts 不前进。所有路都就绪后自然恢复推进。
    //
    // 仅检查"主时钟模式且当前在播"的路：独立时钟路的 seekPending 不
    // 影响主时钟；停在 Ready/Paused/Ended 的路也不该卡主时钟（后者
    // 不会有人等它出帧）。
    // ───────────────────────────────────────────────────────────────────
    if (m_playing.load()) {
        bool anyPending = false;
        for (auto& p : m_players) {
            if (!p) continue;
            if (!p->rbUseMasterClock()) continue;
            if (!p->rbIsPlaying())      continue;
            if (p->rbIsSeekPending()) { anyPending = true; break; }
        }
        if (anyPending) {
            // 冻结主时钟在 anchorPts：把 anchorWall 跟着 now 一起走，
            // 公式 master = anchorPts + (now - anchorWall)*speed 恒等于 anchorPts
            m_anchorWall = rbWallTime();
        } else if (m_pendingAnchorRebase) {
            // ─── 闸门解除瞬间：重锚 anchorPts 到"各路实际首帧 PTS 的最大值" ──
            // 走到这里说明所有主时钟+在播的路都已 seekPending=false，意味着
            // 各路 RBVideoPlayer::rbGetCurrentFrame 已对齐时钟、把 currentTime
            // 设为各自第一帧的真实 PTS。
            //
            // 不同视频 GOP / 起始关键帧布局差异会导致首帧 PTS 不同：
            //   路 0：videoA av_seek(0) 后首个解码帧 PTS = 0.533s（≈ 16 帧 @30fps）
            //   路 1：videoB av_seek(0) 后首个解码帧 PTS = 0.000s
            // 若主时钟仍从 anchorPts=0 起跑：
            //   · 路 0 队列里只有 PTS≥0.533 的帧，没有任何帧满足 framePts≤0
            //     → rbGetCurrentFrame 不弹帧 → 画面停在 seek 前的旧帧
            //     → 直到主时钟跑到 0.533s 才取走首帧（视觉上卡 0.5s）
            //   · 路 1 队列正常按主时钟节奏播 #0、#1、...
            //   → 用户看到"路 0 停帧、路 1 单独跑了一会儿、追到 #17 才同步"
            //
            // 修复：把 anchorPts 提升到所有路 currentTime 的最大值，相当于
            // 主时钟从"最晚的那个首帧 PTS"开始计时：
            //   · 路 0 立即显示首帧（PTS 0.533 ≤ 0.533）
            //   · 路 1 队列里 PTS=0~0.533 的帧在一个 tick 内被批量丢弃，最终
            //     停在 PTS≤0.533 的最后一帧上（视觉上从 #17 开始同步播放）
            // 两路从此真正对齐，不会再出现"某路单独卡帧"。
            double maxPts = m_anchorPts;
            for (auto& p : m_players) {
                if (!p) continue;
                if (!p->rbUseMasterClock()) continue;
                if (!p->rbIsPlaying())      continue;
                maxPts = std::max(maxPts, p->rbCurrentTime());
            }
            m_anchorPts  = maxPts;
            m_anchorWall = rbWallTime();
            m_pausedPts  = maxPts;
            m_pendingAnchorRebase = false;
        }
    } else {
        // 全局非播放态（rbRefreshPausedFrame 已在调用方处理首帧），
        // 标志失效，直接清掉避免下次播放误触发。
        m_pendingAnchorRebase = false;
    }

    double t = rbComputeMasterLocked();

    // 边界：若 t 超过最长 duration，停在结尾，自动 pause
    double dur = 0.0;
    for (auto& p : m_players) if (p) dur = std::max(dur, p->rbDuration());
    if (dur > 0.0 && t >= dur) {
        t = dur;
        if (m_playing.load()) {
            m_pausedPts = t;
            m_playing.store(false);
            for (auto& p : m_players) if (p) p->rbPause();
        }
    }

    // 下发主时钟（仅给"使用主时钟模式"的 player；单路独立播放的不动）
    for (auto& p : m_players) {
        if (!p) continue;
        if (p->rbUseMasterClock()) {
            p->rbSetMasterClock(t);
        }
    }
}

// ════════════════════════════════════════════════════════════════════════
// 内部
// ════════════════════════════════════════════════════════════════════════

double RBPlayerEngine::rbComputeMasterLocked() const {
    if (!m_playing.load()) return m_pausedPts;
    return m_anchorPts + (rbWallTime() - m_anchorWall) * m_speed;
}

void RBPlayerEngine::rbBroadcastClock(double t) {
    for (auto& p : m_players) {
        if (p && p->rbUseMasterClock()) p->rbSetMasterClock(t);
    }
}

// ═════════════════════════════════════════════════════════════════════
// 倍速控制：采用 video-compare 同样的 2^(level/6) 类似对数步進
// ═════════════════════════════════════════════════════════════════════
static constexpr int    kSpeedKeyPressesToDouble = 6;            // 每 6 按 ×2
static constexpr int    kSpeedLevelMaxAbs        = 6 * 7;        // ±128倍
static double rbSpeedFactorFromLevel(int level) {
    return std::pow(2.0, static_cast<double>(level) / static_cast<double>(kSpeedKeyPressesToDouble));
}

void RBPlayerEngine::rbSetSpeed(double speed) {
    if (!(speed > 0.0)) return;
    if (speed < 1.0/128.0) speed = 1.0/128.0;
    if (speed > 128.0)     speed = 128.0;

    std::lock_guard<std::mutex> lk(m_mutex);
    if (speed == m_speed) return;

    // 重锚主时钟以避免倍速变更瞬间主时钟跳变：
    //   master = anchorPts + (now - anchorWall) * speed
    // 切换为 speed' 后，先冻结当前 master 然后以它为新起点。
    if (m_playing.load()) {
        const double now = rbWallTime();
        m_anchorPts  = m_anchorPts + (now - m_anchorWall) * m_speed;
        m_anchorWall = now;
    }
    m_speed = speed;

    // 带动所有 player 的本地倍速（独立时钟路生效；主时钟路本字段不影响
    // 选帧逻辑，但仍推送以保证 “独立 → 主时钟” 切换后立即一致）。
    for (auto& p : m_players) {
        if (p) p->rbSetSpeed(m_speed);
    }
}

void RBPlayerEngine::rbAdjustSpeedLevel(int delta) {
    int newLevel = m_speedLevel + delta;
    if (newLevel >  kSpeedLevelMaxAbs) newLevel =  kSpeedLevelMaxAbs;
    if (newLevel < -kSpeedLevelMaxAbs) newLevel = -kSpeedLevelMaxAbs;
    if (newLevel == m_speedLevel) return;
    m_speedLevel = newLevel;
    rbSetSpeed(rbSpeedFactorFromLevel(newLevel));
}

void RBPlayerEngine::rbResetSpeed() {
    if (m_speedLevel == 0 && m_speed == 1.0) return;
    m_speedLevel = 0;
    rbSetSpeed(1.0);
}

} // namespace rb

