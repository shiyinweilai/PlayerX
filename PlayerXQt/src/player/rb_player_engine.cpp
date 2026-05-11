/**
 * rb_player_engine.cpp — RBPlayerEngine 实现
 */

#include "rb_player_engine.h"

#include <algorithm>
#include <chrono>

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

    // 末尾点击播放 = 自动 replay：
    // 单路 RBVideoPlayer::rbPlay() 检测到 Ended 会自动 seek 回 0，但引擎层的
    // m_pausedPts 仍停留在 duration —— 若不在这里复位主时钟锚点，下一次
    // rbTick 会用 m_anchorPts(=duration) 把刚 seek 到 0 的单路重新拉回末尾，
    // 进度条也始终显示末尾。所以一旦发现"全部 Ended"就把锚点复位到 0。
    bool allEnded = true;
    for (auto& p : m_players) {
        if (!p) continue;
        if (!p->rbIsEnded()) { allEnded = false; break; }
    }
    if (allEnded) {
        m_pausedPts  = 0.0;
        m_anchorPts  = 0.0;
        m_anchorWall = rbWallTime();
    }

    if (!m_playing.load()) {
        // 从暂停恢复：以 m_pausedPts 作为新的锚点 PTS，并重置 wall 锚点
        m_anchorWall = rbWallTime();
        m_anchorPts  = m_pausedPts;
        m_playing.store(true);
    }
    for (auto& p : m_players) {
        if (!p) continue;
        // 重新启用主时钟（之前可能被单路操作关过）
        p->rbEnableMasterClock(true);
        p->rbPlay();
    }
}

void RBPlayerEngine::rbPause() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    if (m_playing.load()) {
        m_pausedPts = rbComputeMasterLocked();
        m_playing.store(false);
    }
    for (auto& p : m_players) {
        if (p) p->rbPause();
    }
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

void RBPlayerEngine::rbStepFrame(int n) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    // 全局帧步进语义：先全局 pause，再以"最小帧时长"的步长推进所有路
    if (m_playing.load()) {
        m_pausedPts = rbComputeMasterLocked();
        m_playing.store(false);
        for (auto& p : m_players) if (p) p->rbPause();
    }

    // 取所有路中最小的 frameDuration 作为全局步长
    double fd = 1.0 / 30.0;
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

    for (auto& p : m_players) {
        if (!p) continue;
        p->rbStepFrame(n); // 内部已 pause + seek + refresh
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

