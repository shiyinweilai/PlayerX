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

    // ─── 帧获取（渲染线程调用，每帧调用一次）──────────────────────────────
    // 返回当前应显示的帧（不移交所有权），nullptr 表示无新帧
    // 内部根据 PTS 和时钟决定是否推进
    AVFrame* rbGetCurrentFrame();

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

    // ─── 时钟同步（多路同步时由 RBPlayerUI 调用）──────────────────────────
    // 设置外部主时钟（秒），播放器将以此为基准对齐
    void rbSetMasterClock(double masterTime);
    bool rbUseMasterClock() const { return m_useMasterClock; }
    void rbEnableMasterClock(bool enable) { m_useMasterClock = enable; }

private:
    void rbReleaseCurrentFrame();

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

    // 播放时钟
    double                        m_playStartWallTime{0.0}; // 开始播放时的系统时间
    double                        m_playStartPts{0.0};      // 开始播放时的 PTS
    bool                          m_seekPending{false};     // seek 后等待第一帧对齐时钟

    // 主时钟同步
    bool                          m_useMasterClock{false};
    double                        m_masterClock{0.0};
};

} // namespace rb
