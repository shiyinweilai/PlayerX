/**
 * VideoFrameProvider.cpp — 实现 QML 视频项
 *
 * 两种工作模式（互斥，由是否设置了 engine 决定）：
 *   ① 自持有模式：本 Item 内部 own 一个 RBVideoPlayer，自启 ~60Hz QTimer 拉帧。
 *   ② 引擎绑定模式：本 Item 仅持有 EngineBridge 指针 + playerIndex，
 *      帧的拉取由 EngineBridge 全局调度（onTick 中 rbTick），
 *      本 Item 通过 EngineBridge::requestRepaint 信号触发 onEngineRepaint→update()。
 */

#include "VideoFrameProvider.h"
#include "EngineBridge.h"
#include "rb_video_player.h"
#include "rb_player_engine.h"

#include <QPainter>
#include <QFileInfo>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
}

namespace rbqt {

VideoFrameProvider::VideoFrameProvider(QQuickItem* parent)
    : QQuickPaintedItem(parent)
{
    // GPU 表面绘制 + 黑色背景
    setRenderTarget(QQuickPaintedItem::FramebufferObject);
    setFillColor(Qt::black);

    // 自持有模式的 timer 默认启动；进入引擎模式时停止
    m_renderTimer.setInterval(16);
    connect(&m_renderTimer, &QTimer::timeout, this, &VideoFrameProvider::onTick);

    m_positionTimer.setInterval(100);
    connect(&m_positionTimer, &QTimer::timeout, this, &VideoFrameProvider::onPositionPoll);
}

VideoFrameProvider::~VideoFrameProvider() {
    m_renderTimer.stop();
    m_positionTimer.stop();
    if (m_player) m_player->rbClose();
    rbReleaseSwsContext();
}

// ─── 模式辅助 ────────────────────────────────────────────────────────────

rb::RBVideoPlayer* VideoFrameProvider::rbActivePlayer() const {
    if (m_engine) return m_engine->playerAt(m_playerIndex);
    return m_player.get();
}

// ─── 属性访问 ────────────────────────────────────────────────────────────

bool VideoFrameProvider::isPlaying() const {
    auto* p = rbActivePlayer();
    return p ? p->rbIsPlaying() : false;
}

double VideoFrameProvider::position() const {
    auto* p = rbActivePlayer();
    return p ? p->rbCurrentTime() : 0.0;
}

double VideoFrameProvider::duration() const {
    auto* p = rbActivePlayer();
    return p ? p->rbDuration() : 0.0;
}

// ─── 自持有模式：source 设置 ────────────────────────────────────────────

void VideoFrameProvider::setSource(const QUrl& url) {
    if (url == m_source) return;
    m_source = url;
    emit sourceChanged();

    if (m_engine) {
        // 引擎模式下 source 仅作显示用途，不实际播放
        return;
    }

    if (!m_player) {
        m_player = std::make_unique<rb::RBVideoPlayer>();
        m_renderTimer.start();
        m_positionTimer.start();
    }

    QString localPath = url.isLocalFile() ? url.toLocalFile() : url.toString();
    m_player->rbClose();
    m_currentImage = QImage();

    if (localPath.isEmpty()) return;

    if (m_player->rbOpen(localPath.toStdString())) {
        m_player->rbPlay();
        emit durationChanged();
        emit playingChanged();
        update();
    }
}

// ─── 引擎绑定模式 ────────────────────────────────────────────────────────

EngineBridge* VideoFrameProvider::engine() const {
    return m_engine.data();
}

void VideoFrameProvider::setEngine(EngineBridge* eng) {
    if (m_engine.data() == eng) return;

    if (m_engine) {
        disconnect(m_engine.data(), &EngineBridge::requestRepaint,
                   this, &VideoFrameProvider::onEngineRepaint);
    }
    m_engine = eng;

    if (m_engine) {
        // 引擎模式：停掉自持有 timer，关闭可能存在的旧自持有 player
        m_renderTimer.stop();
        m_positionTimer.stop();
        if (m_player) {
            m_player->rbClose();
            m_player.reset();
        }
        connect(m_engine.data(), &EngineBridge::requestRepaint,
                this, &VideoFrameProvider::onEngineRepaint);
    } else {
        // 退出引擎模式：恢复自持有 timer
        m_renderTimer.start();
        m_positionTimer.start();
    }

    emit engineChanged();
    update();
}

// QML 桥接：通过 QObject* 形式访问 engine
QObject* VideoFrameProvider::engineObject() const {
    return m_engine.data();
}

void VideoFrameProvider::setEngineObject(QObject* obj) {
    setEngine(qobject_cast<EngineBridge*>(obj));
}

void VideoFrameProvider::setPlayerIndex(int idx) {
    if (idx == m_playerIndex) return;
    m_playerIndex = idx;
    // 切换播放器后需要重建 sws（分辨率/格式可能变）+ 清空当前图，避免显示旧帧
    rbReleaseSwsContext();
    m_currentImage = QImage();
    emit playerIndexChanged();
    update();
}

// ─── 播放控制（自持有模式才有效；引擎模式建议走 engine.*）────────────────

void VideoFrameProvider::play() {
    if (m_engine) { m_engine->play(); return; }
    if (m_player) m_player->rbPlay();
    emit playingChanged();
}

void VideoFrameProvider::pause() {
    if (m_engine) { m_engine->pause(); return; }
    if (m_player) m_player->rbPause();
    emit playingChanged();
}

void VideoFrameProvider::togglePause() {
    if (m_engine) { m_engine->togglePause(); return; }
    if (m_player) m_player->rbTogglePause();
    emit playingChanged();
}

void VideoFrameProvider::seek(double seconds) {
    if (m_engine) { m_engine->seek(seconds); return; }
    if (!m_player) return;
    m_player->rbSeekTo(seconds);
    if (m_player->rbIsPaused()) {
        m_player->rbRefreshPausedFrame(300);
    }
    emit positionChanged();
    update();
}

void VideoFrameProvider::stepFrame(int n) {
    if (m_engine) { m_engine->stepFrame(n); return; }
    if (!m_player) return;
    m_player->rbStepFrame(n);
    emit playingChanged();
    emit positionChanged();
    update();
}

// ─── 主循环：拉帧 + 重绘 ────────────────────────────────────────────────

void VideoFrameProvider::onTick() {
    // 自持有模式
    if (!m_player) return;
    AVFrame* frame = m_player->rbGetCurrentFrame();
    if (frame) {
        rbConvertFrameToImage();
        update();
    }
    bool nowPlaying = m_player->rbIsPlaying();
    if (nowPlaying != m_lastPlaying) {
        m_lastPlaying = nowPlaying;
        emit playingChanged();
    }
}

void VideoFrameProvider::onPositionPoll() {
    if (!m_player) return;
    double pos = m_player->rbCurrentTime();
    if (qFuzzyCompare(pos + 1.0, m_lastPosition + 1.0)) return;
    m_lastPosition = pos;
    emit positionChanged();

    double dur = m_player->rbDuration();
    if (!qFuzzyCompare(dur + 1.0, m_lastDuration + 1.0)) {
        m_lastDuration = dur;
        emit durationChanged();
    }
}

void VideoFrameProvider::onEngineRepaint() {
    // 引擎模式：每帧让 rbConvertFrameToImage 内部从 player 拉帧并转换。
    auto* p = rbActivePlayer();
    if (!p) return;
    rbConvertFrameToImage();
    update();
}

// ─── 帧格式转换：AVFrame → QImage(RGBA8888) ─────────────────────────────

void VideoFrameProvider::rbConvertFrameToImage() {
    auto* p = rbActivePlayer();
    if (!p) return;
    AVFrame* f = p->rbGetCurrentFrame();
    if (!f || f->width <= 0 || f->height <= 0) return;

    AVPixelFormat srcFmt = (AVPixelFormat)f->format;
    if (srcFmt == AV_PIX_FMT_NONE) return;

    if (m_currentImage.size() != QSize(f->width, f->height) ||
        m_currentImage.format() != QImage::Format_RGBA8888) {
        m_currentImage = QImage(f->width, f->height, QImage::Format_RGBA8888);
    }

    if (!m_swsCtx ||
        m_swsSrcW != f->width || m_swsSrcH != f->height || m_swsSrcFmt != srcFmt) {
        rbReleaseSwsContext();
        m_swsCtx = sws_getContext(
            f->width, f->height, srcFmt,
            f->width, f->height, AV_PIX_FMT_RGBA,
            SWS_BILINEAR, nullptr, nullptr, nullptr);
        m_swsSrcW   = f->width;
        m_swsSrcH   = f->height;
        m_swsSrcFmt = srcFmt;
    }
    if (!m_swsCtx) return;

    uint8_t*  dst[4]       = { m_currentImage.bits(), nullptr, nullptr, nullptr };
    int       dstStride[4] = { static_cast<int>(m_currentImage.bytesPerLine()), 0, 0, 0 };
    sws_scale(m_swsCtx, f->data, f->linesize, 0, f->height, dst, dstStride);
}

void VideoFrameProvider::rbReleaseSwsContext() {
    if (m_swsCtx) {
        sws_freeContext(m_swsCtx);
        m_swsCtx = nullptr;
    }
    m_swsSrcW = m_swsSrcH = 0;
    m_swsSrcFmt = -1;
}

// ─── 绘制：保持视频纵横比，居中铺满 ────────────────────────────────────

void VideoFrameProvider::paint(QPainter* painter) {
    if (m_currentImage.isNull()) return;

    const QRectF dstRect = boundingRect();
    if (dstRect.width() <= 0 || dstRect.height() <= 0) return;

    const double srcAR = double(m_currentImage.width()) / double(m_currentImage.height());
    const double dstAR = dstRect.width() / dstRect.height();
    QRectF target = dstRect;
    if (srcAR > dstAR) {
        double h = dstRect.width() / srcAR;
        target.setY(dstRect.y() + (dstRect.height() - h) / 2.0);
        target.setHeight(h);
    } else {
        double w = dstRect.height() * srcAR;
        target.setX(dstRect.x() + (dstRect.width() - w) / 2.0);
        target.setWidth(w);
    }

    painter->setRenderHint(QPainter::SmoothPixmapTransform, true);
    painter->drawImage(target, m_currentImage);
}

} // namespace rbqt
