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

// ── 诊断日志节流：rbTick 一秒最多打一次 TICK 快照，避免刷屏 ──
// 仅用于调试：上一次打 TICK 快照的 wall 时间；以及 anyPending 上一次取值
// 用来检测 true→false 翻转（rebase 触发瞬间）。
static double  g_lastTickLogWall = 0.0;
static int     g_lastAnyPending  = -1;   // -1 = 未初始化

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
    fprintf(stderr,
            "[RBE-OPEN] done: count=%zu anyOk=%d m_anchorPts=0 m_anchorWall=%.3f "
            "m_pausedPts=0 m_speed=1\n",
            m_players.size(), (int)anyOk, m_anchorWall);
    for (size_t i = 0; i < m_players.size(); ++i) {
        auto& p = m_players[i];
        if (!p) continue;
        fprintf(stderr,
                "[RBE-OPEN]   player[%zu] dur=%.3f curT=%.3f isPlaying=%d isPaused=%d isEnded=%d\n",
                i, p->rbDuration(), p->rbCurrentTime(),
                p->rbIsPlaying(), p->rbIsPaused(), p->rbIsEnded());
    }
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
    fprintf(stderr,
            "[RBE-CLOSEALL] reset: m_playing=0 m_anchorPts=0 m_anchorWall=%.3f "
            "m_pausedPts=0 m_speed=1 pendingRebase=0\n",
            m_anchorWall);
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
    //
    // ── 扩展：主时钟也已到达 duration 边界视为"已结束" ──
    // 场景：长短视频混播时，主时钟到 max(duration) 触发 rbTick 边界处理
    // 把所有路 rbPause()（→ Paused，不会变 Ended）。此时各路 rbIsEnded()
    // 多数为 false（尤其长路被强制 pause 在末尾，根本没走自然 EOF），
    // 旧 allEnded 判定 → false → 走"非 allEnded"分支 →
    //   m_anchorPts = m_pausedPts = duration → master 从 duration 起跑
    //   → 下次 rbTick 立刻又判定 t >= dur 把所有路 pause
    //   → 视觉上"按空格主时钟跳一下又停，画面没回到 0，无法重新播放"。
    // 修复：把"主时钟已停在 duration 附近（容差 50ms）"也算作 allEnded，
    // 走 replay 分支 → seek 回 0 → 从头播放，与重置按钮行为一致。
    double maxDur = 0.0;
    for (auto& p : m_players) if (p) maxDur = std::max(maxDur, p->rbDuration());
    bool allEnded = true;
    for (auto& p : m_players) {
        if (!p) continue;
        if (!p->rbIsEnded()) { allEnded = false; break; }
    }
    bool atEndBoundary = (maxDur > 0.0 && m_pausedPts >= maxDur - 0.05);
    fprintf(stderr, "[RBE-PLAY] m_playing=%d m_pausedPts=%.3f maxDur=%.3f allEnded=%d atEndBoundary=%d\n",
            m_playing.load(), m_pausedPts, maxDur, allEnded, atEndBoundary);
    for (size_t i = 0; i < m_players.size(); ++i) {
        auto& p = m_players[i];
        if (!p) continue;
        fprintf(stderr, "[RBE-PLAY]   player[%zu] isPlaying=%d isPaused=%d isEnded=%d curT=%.3f dur=%.3f\n",
                i, p->rbIsPlaying(), p->rbIsPaused(), p->rbIsEnded(),
                p->rbCurrentTime(), p->rbDuration());
    }
    if (allEnded || atEndBoundary) {
        m_pausedPts  = 0.0;
        m_anchorPts  = 0.0;
        m_anchorWall = rbWallTime();
        // 末尾重播：让所有路重新加入主时钟，从 0 开始齐播。
        //
        // 单路 RBVideoPlayer::rbPlay() 的状态分支：
        //   · Ended  → 内部 rbSeekTo(0) 重播
        //   · Paused → 从 m_currentTime 恢复（=duration，不会到 0！）
        //   · Ready  → 从 m_currentTime 起播
        //
        // 短长视频混播时，主时钟到 max(duration) 触发 rbTick 边界处理把
        // 所有路 rbPause()（Playing→Paused），此时长路 rbIsEnded()=false。
        // 旧实现只对 Ended 路 replay 成功，Paused 路 rbPlay 后会卡在末尾。
        // 这里对所有"非 Playing"路统一显式 rbSeekTo(0) 把位置归零，再 rbPlay
        // 让其切到 Playing。已经是 Ended 的路 rbPlay 内部还会再 seek 一次，
        // 多一次 av_seek 但功能稳定（≤50ms 用户无感）。
        for (auto& p : m_players) {
            if (!p) continue;
            p->rbEnableMasterClock(true);
            // Paused/Ready 状态下 rbPlay 不会自动回 0，先显式 seek 归零。
            // 已 Ended 的路无需先 seek（rbPlay 内部会做），但显式 seek 一次
            // 也不会出错——为了路径统一这里全部 seek。
            if (!p->rbIsEnded()) {
                p->rbSeekTo(0.0);
            }
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
        fprintf(stderr, "[RBE-REBASE] schedule from rbPlay(atEnd): pendingRebase=true\n");
        fprintf(stderr,
                "[RBE-PLAY] EXIT(atEnd): m_playing=%d m_anchorPts=%.3f m_anchorWall=%.3f "
                "m_pausedPts=%.3f m_speed=%.3f pendingRebase=%d\n",
                m_playing.load(), m_anchorPts, m_anchorWall, m_pausedPts, m_speed,
                (int)m_pendingAnchorRebase);
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
    fprintf(stderr,
            "[RBE-PLAY] EXIT: m_playing=%d m_anchorPts=%.3f m_anchorWall=%.3f "
            "m_pausedPts=%.3f m_speed=%.3f\n",
            m_playing.load(), m_anchorPts, m_anchorWall, m_pausedPts, m_speed);
}

void RBPlayerEngine::rbPause() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

    if (m_playing.load()) {
        m_pausedPts = rbComputeMasterLocked();
        m_playing.store(false);
        fprintf(stderr, "[RBE-PAUSE] m_pausedPts updated to %.3f\n", m_pausedPts);
    } else {
        fprintf(stderr, "[RBE-PAUSE] already paused, m_pausedPts=%.3f\n", m_pausedPts);
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
    // ── 关键修复：末尾态按空格 = 完整重置 + 播放（等价于按重置按钮再播放） ──
    //
    // 旧实现仅靠 rbPlay() 内部的 allEnded/atEndBoundary 判定来 replay，
    // 在以下时序上仍可能失败：
    //   · 视频播放过程中，rbTick 边界处理是定时器触发的（~16ms 间隔），
    //     如果用户在 t≥dur 但 rbTick 边界处理还未执行的瞬间按空格，
    //     rbIsPlaying() 仍返回 true → 走 rbPause() 分支：m_pausedPts
    //     可能因 rbComputeMasterLocked() 计算偏差刚好 < dur-0.05 → 下次
    //     rbPlay 走非 replay 分支 → 视觉上"按一下跳一下，不从头播"。
    //
    // 新策略：在 rbTogglePause 入口先快照状态，判定"末尾态"（任一路接近
    // duration 或所有 player 已 Ended），不论当前 m_playing 是 true/false，
    // 一律走完整重置 + 播放流程：rbSeek(0) → rbPlay()，与"按重置按钮再
    // 按空格"完全等价。
    bool isPl  = rbIsPlaying();
    bool atEnd = false;
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        double maxDur = 0.0;
        for (auto& p : m_players) if (p) maxDur = std::max(maxDur, p->rbDuration());
        // 三个判定任一成立都视为"已到末尾"：
        //   1) 主时钟（或暂停锚点）已贴近 duration
        //   2) 所有路 isEnded
        //   3) 所有主时钟路 currentTime 都贴近 duration（边界 force-pause 后）
        if (maxDur > 0.0) {
            double cur = m_playing.load() ? rbComputeMasterLocked() : m_pausedPts;
            if (cur >= maxDur - 0.05) atEnd = true;
            if (!atEnd) {
                bool allEnded = !m_players.empty();
                bool allAtDur = !m_players.empty();
                for (auto& p : m_players) {
                    if (!p) { allEnded = false; allAtDur = false; break; }
                    if (!p->rbIsEnded()) allEnded = false;
                    if (p->rbCurrentTime() < p->rbDuration() - 0.05) allAtDur = false;
                }
                if (allEnded || allAtDur) atEnd = true;
            }
        }
    }
    fprintf(stderr, "[RBE-TOGGLE] enter: isPlaying=%d m_playing=%d m_pausedPts=%.3f atEnd=%d\n",
            isPl, m_playing.load(), m_pausedPts, atEnd);

    if (atEnd) {
        // ─── 末尾态完整重启：等价于"重新打开视频文件"+"按播放" ───
        //
        // 旧方案 rbSeek(0)+rbPlay() 在 Windows 上仍会失败：rbSeek 设置
        // m_pendingAnchorRebase=true 期望 rbTick 在所有路 seekPending=0
        // 时把 anchorPts 重锚到"max(各路首帧 PTS)"，但 player 内部
        // m_currentTime 是异步更新的（只有解码线程把首帧解出并被 UI
        // 渲染层取走时才更新），rbTick 触发时取到的 curT 要么是 0（首
        // 帧未解出）要么是 dur=5.062（脏值）。两种值都让 rebase 失败 —
        // 取 0 时主时钟从 0 起跑导致路 0（首帧 PTS=0.533）卡半秒；取
        // 5.062 又会被容差过滤回 0，依然是从 0 起跑卡半秒。
        //
        // 不再用 seek+play，改成"销毁所有 player 后用相同文件重新打开"
        // 的硬重启策略：
        //   ① 保存当前所有路的文件路径（按索引顺序）
        //   ② 保存当前倍速、speedLevel
        //   ③ rbCloseAll() 释放所有 demuxer/decoder/queue
        //   ④ rbOpenFiles() 用相同文件按相同顺序重新打开 → 全部从 0 起、
        //      启用主时钟、状态完全等价于"用户刚打开 N 个视频"
        //   ⑤ 恢复倍速（rbOpenFiles 会强制复位为 1.0）
        //   ⑥ rbPlay() 启动 → 走与"首次打开后按播放"完全相同的代码路径
        //
        // 代价：每路重新 av_format_open + 找流 + 创建解码器 + 解码首帧，
        // 几十毫秒到几百毫秒（取决于硬解上下文重建）。但末尾按空格本来
        // 就不是高频操作，且能彻底消除脏状态，比再继续打补丁可靠。
        std::vector<std::string> paths;
        int    savedSpeedLevel = 0;
        double savedSpeed      = 1.0;
        {
            std::lock_guard<std::mutex> lk(m_mutex);
            paths.reserve(m_players.size());
            for (auto& p : m_players) {
                if (p) paths.push_back(p->rbFilePath());
            }
            savedSpeedLevel = m_speedLevel;
            savedSpeed      = m_speed;
        }
        fprintf(stderr, "[RBE-RESTART] atEnd → full restart, paths=%zu speedLevel=%d\n",
                paths.size(), savedSpeedLevel);
        if (paths.empty()) return;

        // rbCloseAll 内部会持锁并复位所有状态；rbOpenFiles 内部先 closeAll
        // 再持锁重新打开。两者都是公共 API，能确保状态彻底干净。
        rbOpenFiles(paths);

        // rbOpenFiles 会强制 m_speed=1.0（"打开新文件 = 干净状态"），但
        // 这里语义是"重启同一组视频继续播"，应保留用户调过的倍速。
        if (savedSpeed != 1.0) {
            std::lock_guard<std::mutex> lk(m_mutex);
            m_speed      = savedSpeed;
            m_speedLevel = savedSpeedLevel;
            for (auto& p : m_players) { if (p) p->rbSetSpeed(savedSpeed); }
        }

        rbPlay();   // 走"首次打开后按播放"的标准路径，与刚打开时按空格完全一致
        return;
    }

    if (isPl) rbPause();
    else      rbPlay();
}

void RBPlayerEngine::rbSeek(double seconds) {
    seconds = std::max(0.0, seconds);

    // ─── 重置到开头：走完整重启路径（与末尾按空格 atEnd 分支同源） ───
    //
    // 经实测（Windows）：播放中按"重置按钮"调用 rbSeek(0) 时，仍然
    // 出现"路 0 卡 17 帧、时间正常推进、过几秒画面才追上"的现象。
    // 根因和末尾按空格完全相同：
    //   ① rbSeekTo 阻塞调用，串行 flush + 重 demux + 解码首帧
    //   ② 各路首帧 PTS 不同（路 0=0.533，路 1=0）
    //   ③ rbTick 触发 rebase 时 player 内 m_currentTime 还是异步更新中
    //      → 拿不到正确的 0.533，rebase 退化到 0
    //   ④ 主时钟从 0 起跑，路 0 队列里没有 PTS≤0 的帧能弹 → 画面冻住
    //
    // m_pendingAnchorRebase + 容差防御 在 Windows 上很难做对（curT 要么
    // 0 要么>容差），不如直接走"销毁 + 重新打开"的硬重启：保存路径列表 +
    // m_playing 状态 → rbCloseAll → rbOpenFiles → 恢复倍速 → 按原 m_playing
    // 决定 rbPlay 还是保持 ready 暂停态。这样所有路都是新对象，
    // 状态完全等价于"用户刚打开 N 个视频"，绝不会再卡帧。
    //
    // 仅 seconds<=0 走重启，进度条拖到非 0 位置仍走原 seek 路径（拖动
    // 是高频操作、用户对延迟敏感、且 m_pendingAnchorRebase 在拖动场景
    // 下可接受）。
    //
    // 注意：这里不能持锁——rbCloseAll/rbOpenFiles 内部要持同一把锁。
    if (seconds <= 0.0) {
        std::vector<std::string> paths;
        bool wasPlaying        = false;
        int  savedSpeedLevel   = 0;
        double savedSpeed      = 1.0;
        {
            std::lock_guard<std::mutex> lk(m_mutex);
            if (m_players.empty()) return;
            paths.reserve(m_players.size());
            for (auto& p : m_players) {
                if (p) paths.push_back(p->rbFilePath());
            }
            wasPlaying      = m_playing.load();
            savedSpeedLevel = m_speedLevel;
            savedSpeed      = m_speed;
        }
        fprintf(stderr, "[RBE-RESTART] rbSeek(0) → full restart, paths=%zu wasPlaying=%d speedLevel=%d\n",
                paths.size(), wasPlaying, savedSpeedLevel);
        if (paths.empty()) return;

        rbOpenFiles(paths);

        // 恢复倍速（rbOpenFiles 强制重置为 1.0）
        if (savedSpeed != 1.0) {
            std::lock_guard<std::mutex> lk(m_mutex);
            m_speed      = savedSpeed;
            m_speedLevel = savedSpeedLevel;
            for (auto& p : m_players) { if (p) p->rbSetSpeed(savedSpeed); }
        }

        if (wasPlaying) {
            rbPlay();   // 重置前在播 → 重启后继续播放
        } else {
            // 重置前是暂停态：让所有路把首帧刷出来作为暂停帧（与原 rbSeek
            // 的 rbRefreshPausedFrame(200) 行为一致），UI 显示首帧而非黑屏。
            std::lock_guard<std::mutex> lk(m_mutex);
            for (auto& p : m_players) {
                if (p) p->rbRefreshPausedFrame(200);
            }
        }
        return;
    }

    // ─── 原有逻辑：seek 到非 0 位置（进度条拖拽等） ───
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_players.empty()) return;

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
    fprintf(stderr,
            "[RBE-SEEK] EXIT(non-zero): seconds=%.3f m_anchorPts=%.3f m_anchorWall=%.3f "
            "m_pausedPts=%.3f pendingRebase=1\n",
            seconds, m_anchorPts, m_anchorWall, m_pausedPts);
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
    fprintf(stderr,
            "[RBE-SEEKREL] EXIT: delta=%.3f masterTarget=%.3f m_anchorPts=%.3f "
            "m_anchorWall=%.3f m_pausedPts=%.3f pendingRebase=1\n",
            deltaSeconds, masterTarget, m_anchorPts, m_anchorWall, m_pausedPts);
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

    // 诊断日志：节流 1 秒/次打印引擎内部快照，避免刷屏
    {
        const double wallNow = rbWallTime();
        if (wallNow - g_lastTickLogWall >= 1.0) {
            g_lastTickLogWall = wallNow;
            const double t = rbComputeMasterLocked();
            double maxDur = 0.0;
            for (auto& p : m_players) if (p) maxDur = std::max(maxDur, p->rbDuration());
            fprintf(stderr,
                    "[RBE-TICK] snapshot: m_playing=%d t=%.3f maxDur=%.3f "
                    "m_anchorPts=%.3f m_anchorWall=%.3f dt=%.3f "
                    "m_pausedPts=%.3f m_speed=%.3f pendingRebase=%d players=%zu\n",
                    m_playing.load(), t, maxDur,
                    m_anchorPts, m_anchorWall, wallNow - m_anchorWall,
                    m_pausedPts, m_speed, (int)m_pendingAnchorRebase,
                    m_players.size());
        }
    }

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
            // ⚠ 不要再用 p->rbIsPlaying() 过滤：m_state 翻转是异步的，
            // 引擎刚调完 p->rbPlay() 后 isPlaying() 可能仍返回 false，
            // 但解码线程已启动、m_seekPending=true。若过滤掉就会让
            // anyPending=false 提前进入 rebase 分支，此时 player 内部
            // 还没解出新首帧，rebase 用到的 curT 全是脏值或 0 → 卡帧。
            if (p->rbIsSeekPending()) { anyPending = true; break; }
        }
        // 诊断日志：anyPending 翻转时打一次（每事件 1 行，不刷屏）
        const int curAnyPending = anyPending ? 1 : 0;
        if (curAnyPending != g_lastAnyPending) {
            fprintf(stderr,
                    "[RBE-PENDING] anyPending: %d -> %d  m_playing=%d "
                    "m_anchorPts=%.3f m_anchorWall=%.3f pendingRebase=%d\n",
                    g_lastAnyPending, curAnyPending, m_playing.load(),
                    m_anchorPts, m_anchorWall, (int)m_pendingAnchorRebase);
            g_lastAnyPending = curAnyPending;
        }
        if (anyPending) {
            // 冻结主时钟在 anchorPts：把 anchorWall 跟着 now 一起走，
            // 公式 master = anchorPts + (now - anchorWall)*speed 恒等于 anchorPts
            //
            // ⚠ 这个冻结**独立于** m_pendingAnchorRebase 标志：只要有任一
            // 主时钟路还在 seekPending（首帧未到），主时钟就必须停摆，
            // 否则 UI 渲染线程的 rbGetCurrentFrame 会不停 store 推进的
            // m_masterClock 到 m_currentTime → curT 飞快跑到 N 秒，进而
            // 让边界 t>=dur 触发 boundary→pause→画面冻住。
            //
            // 即使没设置 m_pendingAnchorRebase（如完整重启路径），冻结
            // 也是必要的：等所有路解出首帧后再让主时钟正常推进。
            m_anchorWall = rbWallTime();
        }
        if (!anyPending && m_pendingAnchorRebase) {
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
            //
            // ⚠ 关键防脏值：rbSeekTo 是阻塞的但 player 内部的 m_currentTime
            // 不一定立即更新到目标值（尤其末尾态 replay 场景：上一帧的
            // currentTime 还停留在 dur=5.062，新解码线程尚未推出 PTS=0 的
            // 首帧）。如果不加限制直接取 max，会把 seek 前的"末尾时间"当
            // 成新首帧 PTS，导致：
            //   ① m_anchorPts 被瞬间拉到 5.062
            //   ② 紧接的 boundary 检测立刻触发 → 全局 pause、画面停死
            // 这正是 Windows 上"播放结束按空格画面不动"的直接原因。
            //
            // 防御：只接受"和当前 anchorPts 偏差 ≤ kRebaseTolerance"的
            // currentTime 作为有效首帧 PTS。一个 GOP 通常 ≤ 0.6s，给到 1.0s
            // 已涵盖绝大多数实拍/AIGC 视频；超过这个范围的肯定是脏值。
            constexpr double kRebaseTolerance = 1.0;  // 单位：秒
            double maxPts = m_anchorPts;
            for (auto& p : m_players) {
                if (!p) continue;
                if (!p->rbUseMasterClock()) continue;
                // ⚠ 同样不用 isPlaying 过滤：异步状态翻转期间路 0 可能
                // 已解出首帧（curT=0.533）但 isPlaying 仍是 false，过滤
                // 掉就会丢失关键的首帧 PTS 信息，rebase 退化为不动。
                double cur = p->rbCurrentTime();
                // 只取"在容差范围内"的较大值作为首帧 PTS；超出的忽略
                // （多半是 seek 前的旧值，新解码尚未刷新）。
                if (cur > m_anchorPts + kRebaseTolerance) continue;
                if (cur < m_anchorPts) continue;  // 不可能比锚点还早
                maxPts = std::max(maxPts, cur);
            }
            m_anchorPts  = maxPts;
            m_anchorWall = rbWallTime();
            m_pausedPts  = maxPts;
            m_pendingAnchorRebase = false;
            // 详细日志：列出每路 curT，便于诊断 rebase 是否取到了正确值
            fprintf(stderr, "[RBE-REBASE] anchorPts -> %.3f", maxPts);
            for (size_t i = 0; i < m_players.size(); ++i) {
                auto& p = m_players[i];
                if (!p) continue;
                fprintf(stderr, "  p[%zu]:curT=%.3f,isPlaying=%d,seekPending=%d",
                        i, p->rbCurrentTime(), p->rbIsPlaying(), p->rbIsSeekPending());
            }
            fprintf(stderr, "\n");
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
            // 详细日志：揭示 t 的来源（anchorPts + (now-anchorWall)*speed）
            // 用于诊断"刚 rbPlay 完 t 就 ≥ dur"的异常 boundary 触发
            const double wallNow = rbWallTime();
            fprintf(stderr,
                    "[RBE-TICK] boundary hit: t=%.3f dur=%.3f → pause all"
                    "  anchorPts=%.3f anchorWall=%.3f now=%.3f dt=%.3f speed=%.3f"
                    "  m_pausedPts(before)=%.3f\n",
                    t, dur,
                    m_anchorPts, m_anchorWall, wallNow, wallNow - m_anchorWall, m_speed,
                    m_pausedPts);
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

