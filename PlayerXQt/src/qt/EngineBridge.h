#pragma once
/**
 * EngineBridge.h — 把 RBPlayerEngine 包装成 QML 可用的 Q_OBJECT 单例
 *
 * 设计要点：
 *   - 在 QML 里以 `Engine` 作为单例访问（qmlRegisterSingletonInstance），
 *     这样 N 个 VideoFrameProvider 都能拿到同一个引擎。
 *   - 提供 layoutMode / activeIndex / fileCount / playing / position / duration
 *     等属性给 QML 双向绑定。
 *   - 全局/单路控制 slot：play/pause/togglePause/seek/stepFrame
 *                       togglePauseAt/seekAt/stepFrameAt
 *   - 内部 60Hz QTimer：每帧 rbTick() + 检查状态变更后 emit 信号。
 */

#include <QObject>
#include <QStringList>
#include <QUrl>
#include <QTimer>
#include <memory>

namespace rb {
class RBPlayerEngine;
class RBVideoPlayer;
}

namespace rbqt {

class EngineBridge : public QObject {
    Q_OBJECT

    Q_PROPERTY(int        fileCount   READ fileCount   NOTIFY fileCountChanged)
    Q_PROPERTY(int        activeIndex READ activeIndex WRITE setActiveIndex NOTIFY activeIndexChanged)
    Q_PROPERTY(int        layoutMode  READ layoutMode  WRITE setLayoutMode  NOTIFY layoutModeChanged)
    Q_PROPERTY(bool       playing     READ playing     NOTIFY playingChanged)
    Q_PROPERTY(double     position    READ position    NOTIFY positionChanged)
    Q_PROPERTY(double     duration    READ duration    NOTIFY durationChanged)
    Q_PROPERTY(QStringList titles     READ titles      NOTIFY filesChanged)

public:
    // 与 QML 同步的 layout 枚举
    // 注意：Single 模式仍保留（数字键 1-9 第二次按下时使用），但默认布局是 SideBySide。
    enum LayoutMode {
        LayoutSingle      = 0, // 只显示 activeIndex 这一路
        LayoutSideBySide  = 1, // 横排自适应（最多 9 路）— 默认
        LayoutGrid2x2     = 2, // 2x2（最多 4 路）
        LayoutGrid2x3     = 3, // 2x3（最多 6 路）
        LayoutGrid3x3     = 4, // 3x3（最多 9 路）
    };
    Q_ENUM(LayoutMode)

    explicit EngineBridge(QObject* parent = nullptr);
    ~EngineBridge() override;

    rb::RBPlayerEngine* engine() const { return m_engine.get(); }

    // 给 VideoFrameProvider 直接拿 player 指针（同线程，无需锁外部 wrap）
    rb::RBVideoPlayer* playerAt(int idx) const;

    // 属性 getter
    int         fileCount()   const;
    int         activeIndex() const { return m_activeIndex; }
    int         layoutMode()  const { return m_layoutMode; }
    bool        playing()     const { return m_lastPlaying; }
    double      position()    const { return m_lastPosition; }
    double      duration()    const { return m_lastDuration; }
    QStringList titles()      const;

    void setActiveIndex(int v);
    void setLayoutMode(int v);

public slots:
    // 文件管理
    bool openFiles(const QList<QUrl>& urls);
    bool addFile(const QUrl& url);
    void closeAt(int idx);
    void closeAll();

    // 全局控制
    void play();
    void pause();
    void togglePause();
    void seek(double seconds);
    // 相对 seek：每路在各自当前位置上 ±delta，独立时钟的路不被对齐到主时钟。
    // 顶部 << / >> 按钮使用，区别于绝对 seek（进度条拖拽）。
    void seekRelative(double deltaSeconds);
    void stepFrame(int n);

    // 单路控制
    void togglePauseAt(int idx);
    void seekAt(int idx, double seconds);
    void stepFrameAt(int idx, int n);

    // 工具
    QString fileNameAt(int idx) const;
    double  positionAt(int idx) const;
    double  durationAt(int idx) const;
    bool    playingAt(int idx) const;

signals:
    void fileCountChanged();
    void filesChanged();
    void activeIndexChanged();
    void layoutModeChanged();
    void playingChanged();
    void positionChanged();
    void durationChanged();
    void requestRepaint(); // 通知所有 VideoFrameProvider 刷新

private slots:
    void onTick();

private:
    std::unique_ptr<rb::RBPlayerEngine> m_engine;
    QTimer  m_timer;
    int     m_activeIndex{0};
    int     m_layoutMode{LayoutSideBySide};

    // 缓存上次广播值，避免每帧 emit
    bool    m_lastPlaying{false};
    // 缓存"任一路在播放"状态，用于检测 true→false 的下降沿。
    // 单路独立播放走到末尾时，全局 m_playing 一直是 false（不会触发 playingChanged），
    // 但单路 Engine.playingAt(idx) 从 true 变 false，QML 端 cellPlayBtn 文本依赖
    // playingChanged 才会重算 → 必须主动 emit 一次。
    bool    m_lastAnyPlaying{false};
    double  m_lastPosition{-1.0};
    double  m_lastDuration{-1.0};
    int     m_lastFileCount{0};
};

} // namespace rbqt

