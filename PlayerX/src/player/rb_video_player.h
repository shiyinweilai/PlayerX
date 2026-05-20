#pragma once
/**
 * rb_video_player.h — 单路视频播放器
 * 封装 Demuxer + Decoder + FrameQueue，对外提供：
 *   - 打开/关闭文件
 *   - 播放/暂停/停止/Seek
 *   - 获取当前帧（供渲染层使用）
 *   - 查询播放状态（时间、时长、是否结束）
 *
 * 设计为多路可复用：RBPlayerUI 可持有多个 RBVideoPlayer 实例。
 */

#include <string>
#include <atomic>
#include <memory>
#include <functional>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/rational.h>
}

namespace rb {

class RBDemuxer;
class RBDecoder;
struct RBFrameQueue;

// 播放状态
enum class RBPlayerState {
    Idle,       // 未加载
    Ready,      // 已加载，未播放
    Playing,    // 播放中
    Paused,     // 暂停
    Ended,      // 播放结束
    Error       // 错误
};

class RBVideoPlayer {
public:
    RBVideoPlayer();
    ~RBVideoPlayer();

    // ─── 生命周期 ──────────────────────────────────────────────────────────
    bool rbOpen(const std::string& filePath);
    void rbClose();

    // ─── 播放控制 ──────────────────────────────────────────────────────────
    void rbPlay();
    void rbPause();
    void rbStop();
    void rbTogglePause();
    void rbSeekTo(double seconds);

    // 帧级步进（n>0 前进，n<0 后退）。播放中会先暂停；seek 后等待解码线程
    // 产出目标帧并立即作为当前显示帧（rbRefreshPausedFrame）。
    // 实现要点：底层 av_seek_frame 走 BACKWARD 关键帧 + 解码侧丢弃 PTS<目标
    // 的前置帧的现成机制，因此把目标 PTS 设为 curPts + (n - 0.5)*frameDur，
    // 命中"解码到下一帧"的语义；负方向同理。
    void rbStepFrame(int n);

    // 估算单帧时长（秒），用于帧步进与"<< / >>" 5s 等粗粒度区分。
    // 优先用容器声明的 r_frame_rate（无丢帧封装），回退 avg_frame_rate，
    // 再回退视频流 time_base 的倒数；最差兜底 1/30。
    double rbFrameDuration() const;

    // ─── 帧获取（渲染线程调用，每帧调用一次）──────────────────────────────
    // 返回当前应显示的帧（不移交所有权），nullptr 表示无新帧
    // 内部根据 PTS 和时钟决定是否推进
    AVFrame* rbGetCurrentFrame();

    // 暂停状态下主动刷新到 seek/reset 后的首帧。
    // 用法：rbPause() + rbSeekTo(t) 之后调用本方法，将解码出的目标帧
    // 替换为 m_currentFrame，使暂停画面立刻显示到 seek 后位置（首帧）。
    // 内部会等待解码线程产出帧（最长 timeoutMs 毫秒），返回是否成功。
    bool rbRefreshPausedFrame(int timeoutMs = 300);

    // 帧级精确版本：用半帧时长作为丢弃阈值，而不是 rbRefreshPausedFrame 的 0.5s
    // 兜底容差。专用于 rbStepFrame —— 让 seek 后丢帧严格停在 PTS ≥ target - fd/2
    // 的目标帧上（不再被关键帧"误判为目标"）。target 是帧 PTS，frameDur 是单帧时长。
    bool rbRefreshPausedFrameExact(double target, double frameDur, int timeoutMs = 500);

    // ─── 状态查询 ──────────────────────────────────────────────────────────
    RBPlayerState rbState()       const { return m_state.load(); }
    bool          rbIsPlaying()   const { return m_state.load() == RBPlayerState::Playing; }
    bool          rbIsPaused()    const { return m_state.load() == RBPlayerState::Paused; }
    bool          rbIsEnded()     const { return m_state.load() == RBPlayerState::Ended; }
    double        rbCurrentTime() const { return m_currentTime.load(); }
    double        rbDuration()    const { return m_duration; }
    int           rbWidth()       const;
    int           rbHeight()      const;
    const std::string& rbFilePath() const { return m_filePath; }

    // ─── 帧信息查询（供 UI 信息面板使用）──────────────────────────────────
    // 当前帧帧号（基于 PTS / 帧时长估算，与 display.cpp 同逻辑）
    int64_t       rbCurrentFrameNum()  const;
    // 当前帧类型字符：'I' / 'P' / 'B' / '?' （av_get_picture_type_char）
    char          rbCurrentFrameType() const;
    // 视频 FPS（来自容器 r_frame_rate，回退 avg_frame_rate）
    double        rbFps()              const;
    // 编解码器名称（如 "h264" / "hevc" / "vp9"）
    std::string   rbCodecName()        const;
    // 像素格式名（如 "yuv420p" / "nv12"），来自实际解码器输出
    std::string   rbPixelFormatName()  const;
    // 色彩空间（如 "bt709" / "bt2020nc"）
    std::string   rbColorSpaceName()   const;
    // 色彩范围（"tv" / "pc"）
    std::string   rbColorRangeName()   const;
    // 是否启用了硬件加速（实际生效，包含回退后的状态）
    bool          rbHwAccelActive()    const;
    // 实际使用的解码器名（如 h264 / h264_videotoolbox），与 rbCodecName 区别在于
    // 后者来自容器声明的 codec_id，前者来自 AVCodecContext->codec->name
    std::string   rbDecoderName()      const;

    // ─── 时钟同步（多路同步时由 RBPlayerUI 调用）──────────────
    // 设置外部主时钟（秒），播放器将以此为基准对齐
    void rbSetMasterClock(double masterTime);
    bool rbUseMasterClock() const { return m_useMasterClock.load(); }
    void rbEnableMasterClock(bool enable) { m_useMasterClock.store(enable); }

    // seek 后是否仍在等待第一帧对齐时钟。
    // 引擎层据此实现"主时钟等所有路就绪后再起跑"，避免先就绪那路被
    // 主时钟立刻推到 N 毫秒位置后出现"卡一下追上"现象（Windows 上
    // 解码启动慢，更易触发）。
    bool rbIsSeekPending() const { return m_seekPending.load(); }

    // ─── 倍速控制 ─────────────────────────────────────────────────────
    // 设置本地时钟倍速因子（用于不走主时钟的独立路及主时钟为补偿同一因子同步设置）。
    // 语义： m_speed=1.0 为原速。本地时钟公式：
    //   playTime = m_playStartPts + (now - m_playStartWallTime) * m_speed
    // 主时钟模式下本字段不生效（由 RBPlayerEngine 控制主时钟倍速），
    // 但仍会被推送以保证 “独立路” 切换为主时钟后立即一致。
    // 重错锁 m_playStartPts/WallTime 避免倍速变更璬间 PTS 跳变。
    void rbSetSpeed(double speed);
    double rbSpeed() const { return m_speed.load(); }
private:
    void rbReleaseCurrentFrame();

    // 切换 currentFrame 前调用：根据新帧 PTS 与当前帧 PTS 的差更新连续帧序号。
    //   - dt ≈ +fd（±0.5fd 容差）→ index += 1（严格下一显示帧）
    //   - dt ≈ -fd                → index -= 1
    //   - 其他（首帧 / seek / 大跨度跳）→ 用 PTS·fps 重新校准
    // 这样可以避开"基于 PTS/duration 推算帧号"在 B 帧 / VFR / PTS 偏移下的跳变。
    void rbUpdateFrameIndex(double newPts);

    // 后退一帧专用：从已 seek 后的帧队列里持续解码，找到"PTS 严格小于 curPts 的
    // 最大 PTS 帧"作为目标。VFR / PTS 不等距 / GOP 边界等场景下比 fd 估算更鲁棒。
    // curPts: 当前帧的 PTS（秒），辅助函数会找到比它严格小的"最近一帧"。
    // 返回 true 表示成功换帧。
    bool rbStepBackwardOne(double curPts, int timeoutMs = 1500);

    std::unique_ptr<RBDemuxer>    m_demuxer;
    std::unique_ptr<RBDecoder>    m_decoder;
    std::unique_ptr<RBFrameQueue> m_frameQueue;

    std::string                   m_filePath;
    double                        m_duration{0.0};
    std::atomic<double>           m_currentTime{0.0};
    std::atomic<RBPlayerState>    m_state{RBPlayerState::Idle};

    // 当前持有的帧（渲染层使用完后由下次调用释放）
    AVFrame*                      m_currentFrame{nullptr};
    double                        m_currentFramePts{0.0};
    AVRational                    m_videoTimeBase{1, 1};

    // 当前显示帧的连续序号（按显示顺序 0,1,2,…），由 rbUpdateFrameIndex 维护。
    // 对应 rbCurrentFrameNum() 的返回值；不再用 pts/duration 推算。
    int64_t                       m_displayFrameIndex{0};

    // 播放时钟
    // 注意：所有这些字段会被「主线程（rbPlay/rbPause/rbSeekTo/rbSetSpeed）」
    // 与「Qt 渲染线程（rbGetCurrentFrame）」同时访问。改 atomic 是为了消除
    // 数据竞争 UB——即便 x86_64 下 double 单条 mov 能原子读写，跨平台、
    // 跨编译器优化下普通 double 仍是 UB（编译器可能将其拆分指令、缓存到寄存
    // 器、重排顺序）。Windows release 下表现为「按下空格立刻切下一组」偶发
    // 段错误。
    std::atomic<double>           m_playStartWallTime{0.0}; // 开始播放时的系统时间
    std::atomic<double>           m_playStartPts{0.0};      // 开始播放时的 PTS
    std::atomic<bool>             m_seekPending{false};     // seek 后等待第一帧对齐时钟

    // 主时钟同步
    std::atomic<bool>             m_useMasterClock{false};
    std::atomic<double>           m_masterClock{0.0};

    // 倍速因子（1.0 = 原速）；playTime 推进中 wall 增量会乘以此倍速。
    // 不动 PTS 本身，只动 “wall 隔 → PTS 增量” 的换算。不影响帧步进、seek、
    // 解码任何路径、渲染任何路径。
    std::atomic<double>           m_speed{1.0};
};

} // namespace rb
