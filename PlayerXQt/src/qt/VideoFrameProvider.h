#pragma once
/**
 * VideoFrameProvider.h — 把视频帧渲染到 QML 的 QQuickPaintedItem
 *
 * 支持两种工作模式：
 *   ① 自持有模式（向后兼容，单路场景）：
 *      - 直接 setSource(QUrl) 后内部 new RBVideoPlayer 解码播放
 *   ② 引擎绑定模式（多路场景）：
 *      - 设置 engine + playerIndex 后，本 Item 仅负责"显示 engine 中第 N 路 player 的当前帧"
 *      - 不再持有播放器、不再调用 rbPlay/rbSeek（由 EngineBridge 统一管理）
 *
 * 渲染策略：
 *   QQuickPaintedItem(FramebufferObject) + swscale → QImage(RGBA8888) → QPainter 绘制。
 *   对每个 Item 私有 SwsContext，输入分辨率/格式变化时重建。
 *
 * 解耦原则：
 *   仅依赖 PlayerXQt/src/core / PlayerXQt/src/player / PlayerXQt/src/qt，
 *   不引入 SDL，不依赖旧 PlayerX 工程。
 */

#include <QQuickPaintedItem>
#include <QImage>
#include <QTimer>
#include <QString>
#include <QUrl>
#include <QPointer>
#include <memory>

extern "C" {
#include <libswscale/swscale.h>
#include <libavutil/pixfmt.h>
}

namespace rb {
class RBVideoPlayer;
}

namespace rbqt {

class EngineBridge;

class VideoFrameProvider : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QUrl    source       READ source       WRITE setSource       NOTIFY sourceChanged)
    Q_PROPERTY(bool    playing      READ isPlaying    NOTIFY playingChanged)
    Q_PROPERTY(double  position     READ position     NOTIFY positionChanged)
    Q_PROPERTY(double  duration     READ duration     NOTIFY durationChanged)

    // ─── 引擎绑定模式 ──────────────────────────────────────────────────
    // 用 QObject* 而非具体类型，避免依赖 QML 元类型注册；setEngine 中做 cast。
    Q_PROPERTY(QObject* engine      READ engineObject WRITE setEngineObject NOTIFY engineChanged)
    Q_PROPERTY(int      playerIndex READ playerIndex  WRITE setPlayerIndex  NOTIFY playerIndexChanged)

    QML_ELEMENT
public:
    explicit VideoFrameProvider(QQuickItem* parent = nullptr);
    ~VideoFrameProvider() override;

    // QQuickPaintedItem
    void paint(QPainter* painter) override;

    // 属性 ─────────────────────────────────────────────────────────────────
    QUrl   source()   const { return m_source; }
    void   setSource(const QUrl& url);
    bool   isPlaying() const;
    double position() const;
    double duration() const;

    EngineBridge* engine() const;
    void          setEngine(EngineBridge* eng);

    // QML 桥接：QObject* 形式 getter/setter
    QObject* engineObject() const;
    void     setEngineObject(QObject* obj);

    int  playerIndex() const { return m_playerIndex; }
    void setPlayerIndex(int idx);

public slots:
    // 自持有模式下生效；引擎模式建议使用 engine.* 系列
    void play();
    void pause();
    void togglePause();
    void seek(double seconds);
    void stepFrame(int n);

signals:
    void sourceChanged();
    void playingChanged();
    void positionChanged();
    void durationChanged();
    void engineChanged();
    void playerIndexChanged();

private slots:
    void onTick();          // 自持有模式下由 m_renderTimer 触发
    void onPositionPoll();  // 自持有模式下 ~10Hz 刷新 position 信号
    void onEngineRepaint(); // 引擎模式下由 EngineBridge 触发

private:
    // 把 frame 转换为目标显示尺寸 (dstW x dstH) 的 RGBA QImage —— 关键：sws 直接
    // Lanczos 缩到屏幕物理像素尺寸，paint() 1:1 上屏，避免任何 Qt 端二次采样。
    void rbConvertFrameToImage(int dstW, int dstH);
    void rbReleaseSwsContext();
    rb::RBVideoPlayer* rbActivePlayer() const; // 当前真正的 player（引擎模式或自持有）

    QUrl                              m_source;
    std::unique_ptr<rb::RBVideoPlayer> m_player; // 仅自持有模式使用

    QPointer<EngineBridge>            m_engine;
    int                               m_playerIndex{0};

    // 渲染相关
    QImage                            m_currentImage;   // 已缩放到 dstW×dstH 的 RGBA
    SwsContext*                       m_swsCtx{nullptr};
    int                               m_swsSrcW{0};
    int                               m_swsSrcH{0};
    int                               m_swsSrcFmt{-1};
    int                               m_swsDstW{0};     // 当前 sws 目标宽（屏幕物理像素）
    int                               m_swsDstH{0};     // 当前 sws 目标高（屏幕物理像素）

    QTimer                            m_renderTimer;     // 自持有模式 ~60fps 拉帧
    QTimer                            m_positionTimer;   // 自持有模式 ~10Hz 进度

    bool                              m_lastPlaying{false};
    double                            m_lastPosition{-1.0};
    double                            m_lastDuration{-1.0};
};

} // namespace rbqt
