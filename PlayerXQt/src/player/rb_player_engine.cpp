/**
 * rb_player_engine.cpp — RBPlayerEngine 实现
 */

#include "rb_player_engine.h"

#include <algorithm>
#include <chrono>
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
    return anyOk;
}

int RBPlayerEngine::rbAddFile(const std::string& file) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (static_cast<int>(m_players.size()) >= kMaxPlayers) return -1;

    auto p = std::make_unique<RBVideoPlayer>();
    if (!p->rbOpen(file)) return -1;

    p->rbEnableMasterClock(true);
    // 新加入的路把 master clock 同步到当前位置
    p->rbSetMasterClock(rbComputeMasterLocked());
    if (m_playing.load()) p->rbPlay();
    m_players.push_back(std::move(p));
    return static_cast<int>(m_players.size()) - 1;
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
}

void RBPlayerEngine::rbSeekRelative(double deltaSeconds) {
    // ────────────────────────────────────────────────────────────────
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
    return m_anchorPts + (rbWallTime() - m_anchorWall);
}

void RBPlayerEngine::rbBroadcastClock(double t) {
    for (auto& p : m_players) {
        if (p && p->rbUseMasterClock()) p->rbSetMasterClock(t);
    }
}

} // namespace rb

