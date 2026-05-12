#pragma once
/**
 * rb_player_engine.h — 多路视频协调器（Pure C++，不依赖 Qt / SDL）
 *
 * 职责：
 *   - 持有最多 kMaxPlayers 路 RBVideoPlayer
 *   - 维护全局主时钟（wall clock 推进），所有 player 通过 rbSetMasterClock 对齐
 *   - 全局控制：openFiles / play / pause / seek / stepFrame 一次操作所有路
 *   - 单路控制：openAt / closeAt / togglePauseAt / seekAt / stepFrameAt
 *
 * 主时钟策略（与旧工程 RBPlayerUI 一致）：
 *   - duration  = max over all players（短视频提前到 Ended，仍用最长的那条做时间线）
 *   - position  = 全局 wall clock 自起点累加，受 pause / seek 影响
 *   - 切换为暂停时冻结时钟；继续播放时 wall 锚点重置
 *
 * 解耦：仅依赖 PlayerXQt/src/player + PlayerXQt/src/core，不引入 Qt。
 */

#include <memory>
#include <vector>
#include <string>
#include <mutex>
#include <atomic>

#include "rb_video_player.h"

namespace rb {

class RBPlayerEngine {
public:
    static constexpr int kMaxPlayers = 9; // 上限，UI 端按 layout 自行决定显示几路

    RBPlayerEngine();
    ~RBPlayerEngine();

    // ─── 文件管理 ──────────────────────────────────────────────────────
    // 一次打开多路：先全部 close，按顺序 open，自动重置时钟
    bool rbOpenFiles(const std::vector<std::string>& files);
    // 追加一路；返回新 index，失败返回 -1
    int  rbAddFile(const std::string& file);
    // 关闭某一路（保留槽位为 nullptr 的语义：不留洞，直接 erase）
    void rbCloseAt(int idx);
    // 关闭全部
    void rbCloseAll();

    int                rbCount() const;
    RBVideoPlayer*     rbAt(int idx) const;
    const std::string& rbPathAt(int idx) const; // 不存在返回空串

    // ─── 全局控制（作用于所有路，主时钟驱动）────────────────────────
    void rbPlay();
    void rbPause();
    void rbTogglePause();
    void rbSeek(double seconds);
    // 相对 seek：每路在各自当前位置上 ±delta，独立时钟的路不被对齐。
    //   - 主时钟下的路：以主时钟当前位置 + delta 作为统一目标（仍对齐）
    //   - 独立时钟（已脱离主时钟）的路：以该路自己的 currentTime + delta
    // 这样 a 单路独立暂停在 ta 时按全局 +5s，a 跳到 ta+5；其他路跳到 tm+5，
    // 不会强行把 a 拉到 tm+5（即"对齐主时钟"）。
    void rbSeekRelative(double deltaSeconds);
    void rbStepFrame(int n); // 全局逐帧

    // ─── 单路控制（不影响其他路；用于多窗口独立操作）─────────────────
    void rbTogglePauseAt(int idx);
    void rbSeekAt(int idx, double seconds);
    void rbStepFrameAt(int idx, int n);

    // ─── 状态查询 ─────────────────────────────────────
    // 注意：rbIsPlaying 语义为“任一路在播即算播放中”（含独立时钟下的路），
    // 实现位于 .cpp 中（需持锁遍历 players）。
    bool   rbIsPlaying()   const;
    double rbPosition()    const; // 全局主时钟（秒）
    double rbDuration()    const; // 所有路 duration 的最大值
    bool   rbIsAllEnded()  const;
    double rbFrameDuration() const; // 取所有路中最小的单帧时长，用于全局帧步进

    // ─── 倍速控制（全局）────────────────────────────────────
    // 主时钟按 m_speed 倍率推进，同时下发给所有 player 以保证独立时钟路
    // 也同步倍速。采用 video-compare 同样的 2^(level/6) 步进策略：每按 6
    // 次倍速变 2x；level 范围 [-42, 42] 对应 [1/128, 128] 倍。
    void   rbSetSpeed(double speed);
    double rbSpeed() const { return m_speed; }
    // 调节倍速级别（递增递减 1，外部不必计算 factor）
    void   rbAdjustSpeedLevel(int delta);
    int    rbSpeedLevel() const { return m_speedLevel; }
    void   rbResetSpeed(); // 重置为 1.0x
    // ─── 给渲染层调用：每帧 tick，会推进主时钟并把时钟下发给各 player ──
    // 调用者通常是 QTimer @ ~60Hz。
    void rbTick();

private:
    // 把当前主时钟时间下发给所有 player（仅 Playing 时）
    void rbBroadcastClock(double t);
    // 根据当前 wall 计算主时钟（需在持锁状态下调用）
    double rbComputeMasterLocked() const;

    mutable std::mutex                          m_mutex;
    std::vector<std::unique_ptr<RBVideoPlayer>> m_players;

    // ── 全局时钟 ──
    std::atomic<bool> m_playing{false};
    // 起始锚点：在 rbPlay / rbSeek 时刷新
    double m_anchorWall{0.0};   // wall clock 起点（秒）
    double m_anchorPts{0.0};    // 主时钟在锚点时的值（秒）
    // 暂停时缓存主时钟值（恢复播放时作为新 anchorPts）
    double m_pausedPts{0.0};

    // 倍速： m_speed = 2^(m_speedLevel / 6)。level=0 即 1.0x。
    // 主时钟推进量 m· m_speed，同时下发给所有 player 的 rbSetSpeed。
    int    m_speedLevel{0};
    double m_speed{1.0};
};

} // namespace rb

