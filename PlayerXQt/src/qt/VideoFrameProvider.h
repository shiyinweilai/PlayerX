#pragma once
/**
 * VideoFrameProvider.h — 把 RBVideoPlayer 包装成 QML 可用的 QQuickItem
 *
 * 职责：
 *   1. 持有一个 RBVideoPlayer，对外暴露 source/playing/position/duration 属性
 *   2. 用 QTimer 周期性从 RBVideoPlayer 拉帧，AVFrame(YUV/NV12) → RGBA → QImage
 *   3. 通过 QQuickPaintedItem 把 QImage 绘制到 QQuickItem 区域
 *
 * 渲染策略：
 *   第 1 阶段先用 QQuickPaintedItem（CPU 绘制），实现简单、足够可用。
 *   后续如果性能不够再升级到 QSGSimpleTextureNode + GPU 上传 / Qt Multimedia。
 *
 * 解耦原则：
 *   只依赖 PlayerXQt/src/core 与 PlayerXQt/src/player 中的代码。
 *   不依赖 SDL，不依赖旧 PlayerX 工程的任何文件。
 */

#include <QQuickPaintedItem>
#include <QImage>
#include <QTimer>
#include <QString>
#include <QUrl>
#include <memory>

extern "C" {
#include <libswscale/swscale.h>
#include <libavutil/pixfmt.h>
}

namespace rb {
class RBVideoPlayer;
}

namespace rbqt {

class VideoFrameProvider : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QUrl    source       READ source       WRITE setSource       NOTIFY sourceChanged)
    Q_PROPERTY(bool    playing      READ isPlaying    NOTIFY playingChanged)
    Q_PROPERTY(double  position     READ position     NOTIFY positionChanged)
    Q_PROPERTY(double  duration     READ duration     NOTIFY durationChanged)
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

public slots:
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

private slots:
    void onTick();          // 由 m_renderTimer 触发，~60Hz
    void onPositionPoll();  // 由 m_positionTimer 触发，~10Hz，刷新 position 信号

private:
    void rbConvertFrameToImage();    // AVFrame → m_currentImage
    void rbReleaseSwsContext();

    QUrl                              m_source;
    std::unique_ptr<rb::RBVideoPlayer> m_player;

    // 渲染相关
    QImage                            m_currentImage;
    SwsContext*                       m_swsCtx{nullptr};
    int                               m_swsSrcW{0};
    int                               m_swsSrcH{0};
    int                               m_swsSrcFmt{-1};

    QTimer                            m_renderTimer;     // ~60fps 拉帧 + update()
    QTimer                            m_positionTimer;   // ~10Hz 刷新 position 给 QML

    // 缓存上一次广播的状态，避免每帧 emit 信号
    bool                              m_lastPlaying{false};
    double                            m_lastPosition{-1.0};
    double                            m_lastDuration{-1.0};
};

} // namespace rbqt
