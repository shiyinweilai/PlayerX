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
#include <QVariantMap>
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
    // 倍速控制：全局倍速因子（1.0 = 原速）。
    // 仅提供读接口与 adjustSpeed/resetSpeed slot，不允许 QML 直接赋任意值，
    // 避免跳出合理范围。
    Q_PROPERTY(double     speed       READ speed       NOTIFY speedChanged)

    // 末尾循环播放：true=播放结束后无缝从头继续；false=播放结束后停在末尾
    // 默认 true（自动重播）。详见 RBPlayerEngine::rbSetLoopEnabled。
    Q_PROPERTY(bool       loopEnabled READ loopEnabled WRITE setLoopEnabled NOTIFY loopEnabledChanged)

    // ─── 全局视图变换（窗口内缩放 / 平移）─────────────────────────────────
    // 设计要点：
    //   ① 全局共享一份 zoom/panX/panY，所有 VideoFrameProvider 与 SliderCompareItem
    //      读同一组状态 → 任意一路操作，所有路同步缩放/平移，无需手动对齐。
    //   ② panX/panY 是"归一化平移"：以视频显示矩形宽/高为单位（[-1,1] 安全区，
    //      具体由 C++ 渲染端按 zoom 夹紧）。这样不同分辨率/不同 cell 尺寸的视频
    //      都按"对应内容点"同步平移，永远像素级对齐。
    //   ③ 1.0× 时 panX=panY=0，渲染走与现状字节级一致的快路径，画质零回退。
    Q_PROPERTY(double     viewZoom    READ viewZoom    NOTIFY viewTransformChanged)
    Q_PROPERTY(double     viewPanX    READ viewPanX    NOTIFY viewTransformChanged)
    Q_PROPERTY(double     viewPanY    READ viewPanY    NOTIFY viewTransformChanged)
    // 派生属性：是否处于非默认变换（zoom != 1 或 pan != 0），
    // 用于底部"视图复位"按钮的高亮 / 启用判断。
    Q_PROPERTY(bool       viewTransformed READ viewTransformed NOTIFY viewTransformChanged)

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
    // shared_ptr 版本：渲染热路径（paint 线程）专用，避免
    // rbCloseAll 期间使用裸指针导致 use-after-free。
    std::shared_ptr<rb::RBVideoPlayer> playerAtShared(int idx) const;

    // 属性 getter
    int         fileCount()   const;
    int         activeIndex() const { return m_activeIndex; }
    int         layoutMode()  const { return m_layoutMode; }
    bool        playing()     const { return m_lastPlaying; }
    double      position()    const { return m_lastPosition; }
    double      duration()    const { return m_lastDuration; }
    QStringList titles()      const;
    double      speed()       const { return m_lastSpeed; }
    bool        loopEnabled() const;

    double      viewZoom()      const { return m_viewZoom; }
    double      viewPanX()      const { return m_viewPanX; }
    double      viewPanY()      const { return m_viewPanY; }
    bool        viewTransformed() const {
        return std::abs(m_viewZoom - 1.0) > 1e-6
            || std::abs(m_viewPanX) > 1e-6
            || std::abs(m_viewPanY) > 1e-6;
    }

    void setActiveIndex(int v);
    void setLayoutMode(int v);
    void setLoopEnabled(bool on);

public slots:
    // 文件管理
    bool openFiles(const QList<QUrl>& urls);
    bool addFile(const QUrl& url);
    // 原地替换某一路（索引不变）；用于"换视频"按钮。
    bool replaceAt(int idx, const QUrl& url);
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

    // 倍速控制（全局）
    // adjustSpeed(+1)：倍速上一级（6 级为一倍）
    // adjustSpeed(-1)：倍速下一级
    // resetSpeed()：重置为 1.0x
    // setSpeed(x)：直接跳到某个倍率（供菜单常用档位使用，内部会裁到合理范围）
    void adjustSpeed(int delta);
    void resetSpeed();
    void setSpeed(double speed);

    // ─── 全局视图变换 slot ──────────────────────────────────────────────
    // anchorNX/anchorNY ∈ [0,1]：缩放锚点在"视频显示矩形"内的归一化坐标，
    // 用来实现"以鼠标当前位置为中心"的缩放。anchor 缺省（0.5,0.5）即中心缩放。
    // 实现行为：保持锚点对应的视频内容点在屏幕上的位置不变，更新 zoom/pan。
    void zoomBy(double factor, double anchorNX, double anchorNY);
    void zoomTo(double absZoom, double anchorNX, double anchorNY);
    // 增量平移：dxN/dyN 为"显示矩形"为单位的归一化增量（鼠标拖拽 dx/areaW、dy/areaH）。
    // 画面跟随鼠标方向移动（鼠标向右拖 → 画面向右走）。
    void panBy(double dxN, double dyN);
    // 复位到 zoom=1, pan=(0,0)
    void resetViewTransform();

    // 单路控制
    void togglePauseAt(int idx);
    void seekAt(int idx, double seconds);
    void stepFrameAt(int idx, int n);

    // 工具
    QString fileNameAt(int idx) const;
    // 取某路视频的绝对文件路径（用于评分等持久化场景；空字符串表示该路未打开）
    Q_INVOKABLE QString filePathAt(int idx) const;
    double  positionAt(int idx) const;
    double  durationAt(int idx) const;
    bool    playingAt(int idx) const;
    // 视频信息（供右键信息面板使用）
    // 返回 QVariantMap，包含：
    //   codec(string), width(int), height(int), fps(double),
    //   frameNum(int), frameType(string), pts(double)
    Q_INVOKABLE QVariantMap videoInfoAt(int idx) const;

    // 写文本文件（供 QML 侧持久化配置文件，如 dimensions.json）
    // path 为绝对路径；返回 true 表示写入成功。
    Q_INVOKABLE bool writeTextFile(const QString& path, const QString& content);

signals:
    void fileCountChanged();
    void filesChanged();
    void activeIndexChanged();
    void layoutModeChanged();
    void playingChanged();
    void positionChanged();
    void durationChanged();
    void speedChanged();
    void loopEnabledChanged();
    void viewTransformChanged();
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
    double  m_lastSpeed{1.0};

    // 全局视图变换（缩放 / 平移），所有路同步生效
    double  m_viewZoom{1.0};
    double  m_viewPanX{0.0}; // 归一化：以视频显示矩形宽为单位
    double  m_viewPanY{0.0}; // 归一化：以视频显示矩形高为单位

    // 缩放范围（与产品需求保持一致）
    static constexpr double kZoomMin = 0.2;
    static constexpr double kZoomMax = 8.0;

    // 把 pan 限制在合法范围（避免拖出黑边过远）。zoom<=1 时强制 pan=0。
    void rbClampViewPan();
};

} // namespace rbqt

