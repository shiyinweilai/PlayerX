/**
 * VideoFrameProvider.cpp — 实现 QML 视频项
 */

#include "VideoFrameProvider.h"
#include "rb_video_player.h"

#include <QPainter>
#include <QFileInfo>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
}

namespace rbqt {

VideoFrameProvider::VideoFrameProvider(QQuickItem* parent)
    : QQuickPaintedItem(parent)
    , m_player(std::make_unique<rb::RBVideoPlayer>())
{
    // QQuickPaintedItem：让 paint() 在 GPU 表面上执行而非每次拷贝
    setRenderTarget(QQuickPaintedItem::FramebufferObject);
    // 让背景清空后再画，避免缩放/移动时残影
    setFillColor(Qt::black);

    // 渲染节拍：~60Hz；实际拉帧 + update 触发 paint
    m_renderTimer.setInterval(16);
    connect(&m_renderTimer, &QTimer::timeout, this, &VideoFrameProvider::onTick);
    m_renderTimer.start();

    // 进度上报节拍：~10Hz 已足够给 QML 进度条用
    m_positionTimer.setInterval(100);
    connect(&m_positionTimer, &QTimer::timeout, this, &VideoFrameProvider::onPositionPoll);
    m_positionTimer.start();
}

VideoFrameProvider::~VideoFrameProvider() {
    m_renderTimer.stop();
    m_positionTimer.stop();
    if (m_player) m_player->rbClose();
    rbReleaseSwsContext();
}

// ─── 属性访问 ────────────────────────────────────────────────────────────────

bool VideoFrameProvider::isPlaying() const {
    return m_player ? m_player->rbIsPlaying() : false;
}

double VideoFrameProvider::position() const {
    return m_player ? m_player->rbCurrentTime() : 0.0;
}

double VideoFrameProvider::duration() const {
    return m_player ? m_player->rbDuration() : 0.0;
}

void VideoFrameProvider::setSource(const QUrl& url) {
    if (url == m_source) return;
    m_source = url;
    emit sourceChanged();

    if (!m_player) return;

    // QUrl 可能是 file:// 形式，转成本地路径
    QString localPath = url.isLocalFile() ? url.toLocalFile() : url.toString();

    m_player->rbClose();
    m_currentImage = QImage(); // 清空旧画面

    if (localPath.isEmpty()) return;

    if (m_player->rbOpen(localPath.toStdString())) {
        m_player->rbPlay();
        emit durationChanged();
        emit playingChanged();
        update();
    }
}

// ─── 播放控制 ────────────────────────────────────────────────────────────────

void VideoFrameProvider::play() {
    if (!m_player) return;
    m_player->rbPlay();
    emit playingChanged();
}

void VideoFrameProvider::pause() {
    if (!m_player) return;
    m_player->rbPause();
    emit playingChanged();
}

void VideoFrameProvider::togglePause() {
    if (!m_player) return;
    m_player->rbTogglePause();
    emit playingChanged();
}

void VideoFrameProvider::seek(double seconds) {
    if (!m_player) return;
    m_player->rbSeekTo(seconds);
    // 暂停下让画面立即更新到 seek 位置（与旧 SDL 版一致）
    if (m_player->rbIsPaused()) {
        m_player->rbRefreshPausedFrame(300);
    }
    emit positionChanged();
    update();
}

void VideoFrameProvider::stepFrame(int n) {
    if (!m_player) return;
    m_player->rbStepFrame(n);
    emit playingChanged();
    emit positionChanged();
    update();
}

// ─── 主循环：拉帧 + 触发重绘 ────────────────────────────────────────────────

void VideoFrameProvider::onTick() {
    if (!m_player) return;
    AVFrame* frame = m_player->rbGetCurrentFrame();
    if (frame) {
        rbConvertFrameToImage();
        update(); // 触发 paint()
    }
    // 状态同步
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

// ─── 帧格式转换：AVFrame → QImage(RGBA8888) ─────────────────────────────────
//
// 用 swscale 把任意像素格式（YUV420P / NV12 / VideoToolbox 输出等）转成
// QImage::Format_RGBA8888，便于 QPainter 直接绘制。
// SwsContext 缓存：仅在源宽/高/格式变化时才重建，避免每帧重建。

void VideoFrameProvider::rbConvertFrameToImage() {
    AVFrame* f = m_player->rbGetCurrentFrame();
    if (!f || f->width <= 0 || f->height <= 0) return;

    // 硬解(VideoToolbox)输出的 frame->format 可能是 hw 格式；解码器内部
    // 已做过 transfer 到系统内存（见 rb_decoder.cpp），这里 frame 应是普通像素格式。
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

// ─── 绘制：保持视频纵横比，居中铺满 ────────────────────────────────────────
//
// 注意：清晰度方面我们让 QPainter 关闭 SmoothPixmapTransform，
// 让最终 GPU 缩放走 nearest，避免双线性带来的"毛边"感。
// 若需要平滑效果以后再切换。

void VideoFrameProvider::paint(QPainter* painter) {
    if (m_currentImage.isNull()) return;

    const QRectF dstRect = boundingRect();
    if (dstRect.width() <= 0 || dstRect.height() <= 0) return;

    // 计算保持纵横比的目标矩形（letterbox）
    const double srcAR = double(m_currentImage.width()) / double(m_currentImage.height());
    const double dstAR = dstRect.width() / dstRect.height();
    QRectF target = dstRect;
    if (srcAR > dstAR) {
        // 视频更宽：上下留黑边
        double h = dstRect.width() / srcAR;
        target.setY(dstRect.y() + (dstRect.height() - h) / 2.0);
        target.setHeight(h);
    } else {
        // 视频更高：左右留黑边
        double w = dstRect.height() * srcAR;
        target.setX(dstRect.x() + (dstRect.width() - w) / 2.0);
        target.setWidth(w);
    }

    painter->setRenderHint(QPainter::SmoothPixmapTransform, true);
    painter->drawImage(target, m_currentImage);
}

} // namespace rbqt
