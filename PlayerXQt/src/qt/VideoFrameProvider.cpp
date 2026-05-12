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
#include <QQuickWindow>
#include <QPaintDevice>
#include <algorithm>
#include <cmath>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixfmt.h>
}

namespace rbqt {

// 把 frame 的色彩空间/范围信息应用到 SwsContext。
// 不调用此函数时 sws 默认按 BT.601 + limited range 解码 YUV，对：
//   ① BT.709 视频（绝大多数现代手机/相机/H.264 1080p+）
//   ② full-range 视频（color_range = AVCOL_RANGE_JPEG，常见于手机）
// 会产生轻微色偏与对比度压缩 —— 高对比度边缘（白字幕/黑背景）的灰阶过渡曲
// 线偏移 → 笔画粗细不均 → 视觉上的“毛边/网格伪影”。
// 与旧工程 PlayerX/rb_video_cell.cpp、video-compare/format_converter.cpp 行为对齐。
static void rbSwsApplyColorspace(SwsContext* ctx, const AVFrame* frame) {
    if (!ctx || !frame) return;
    int sws_cs = SWS_CS_ITU601;
    switch (frame->colorspace) {
        case AVCOL_SPC_BT709:        sws_cs = SWS_CS_ITU709;    break;
        case AVCOL_SPC_FCC:          sws_cs = SWS_CS_FCC;       break;
        case AVCOL_SPC_SMPTE170M:    sws_cs = SWS_CS_SMPTE170M; break;
        case AVCOL_SPC_SMPTE240M:    sws_cs = SWS_CS_SMPTE240M; break;
        case AVCOL_SPC_BT2020_CL:
        case AVCOL_SPC_BT2020_NCL:   sws_cs = SWS_CS_BT2020;    break;
        default: break;
    }
    const int* coeffs = sws_getCoefficients(sws_cs);
    const int src_range = (frame->color_range == AVCOL_RANGE_JPEG) ? 1 : 0;
    constexpr int FIXED_1_0 = (1 << 16);
    sws_setColorspaceDetails(ctx,
        coeffs, src_range,        // src
        coeffs, 1,                // dst：RGB 输出永远 full-range
        0, FIXED_1_0, FIXED_1_0);
}

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
    m_swsDstW = m_swsDstH = 0;
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
    // 自持有模式：仅触发重绘，真正的 sws 转换在 paint() 里按目标尺寸完成。
    // 这样 sws 一次就把帧 Lanczos 缩到屏幕物理像素，paint 1:1 上屏，避免任何
    // Qt 端二次插值（双线性）造成的网格伪影与文字模糊。
    if (!m_player) return;
    AVFrame* frame = m_player->rbGetCurrentFrame();
    if (frame) {
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
    // 引擎模式：仅触发重绘，sws 转换延迟到 paint()（需要目标 dst 尺寸）。
    auto* p = rbActivePlayer();
    if (!p) return;
    update();
}

// ─── 帧格式转换：AVFrame → 目标尺寸 RGBA QImage ─────────────────────────
//
// 关键改造（对齐旧工程 PlayerX/rb_video_cell.cpp 的成熟方案）：
//   1) 直接把 sws 的目标尺寸设成屏幕“物理像素”dstW×dstH —— sws 一次完成
//      色彩转换 + 缩放，绝不让 Qt 的 QPainter 再做第二次重采样。
//   2) 缩放算法用 SWS_LANCZOS（Lanczos3，6×6 采样、带负瓣）替代默认的
//      SWS_BILINEAR（2×2 双线性、无负瓣）：
//        · BILINEAR 在非整数缩放比下会沿采样网格累积偏差 → 网格伪影；
//        · BILINEAR 下采样视频内文字（字幕/时间戳）会糊成一团；
//        · LANCZOS 锐边保持最好（mpv 默认重采样器）。
//      搭配 SWS_FULL_CHR_H_INT | SWS_ACCURATE_RND 确保色度全分辨率插值
//      与精确舍入，消除 4:2:0 视频在白字幕等高对比边缘的彩色毛边。
//   3) rbSwsApplyColorspace —— 让 BT.709 / full-range 视频用正确矩阵
//      解 YUV，避免错误矩阵造成的灰阶偏移“伪边缘”。
//
// dstW/dstH 由 paint() 根据 boundingRect × devicePixelRatio + 视频纵横比
// 计算得到，传给本函数；这里只在三元组（src 尺寸、src 格式、dst 尺寸）变化
// 时才重建 SwsContext。
void VideoFrameProvider::rbConvertFrameToImage(int dstW, int dstH) {
    if (dstW <= 0 || dstH <= 0) return;
    auto* p = rbActivePlayer();
    if (!p) return;
    AVFrame* f = p->rbGetCurrentFrame();
    if (!f || f->width <= 0 || f->height <= 0) return;

    AVPixelFormat srcFmt = (AVPixelFormat)f->format;
    if (srcFmt == AV_PIX_FMT_NONE) return;

    // 目标 QImage 大小必须与 sws 目标尺寸一致；不一致或首次时分配。
    if (m_currentImage.size() != QSize(dstW, dstH) ||
        m_currentImage.format() != QImage::Format_RGBA8888) {
        m_currentImage = QImage(dstW, dstH, QImage::Format_RGBA8888);
    }

    // SwsContext 仅在 src 三元组或 dst 尺寸变化时重建（缩放系数会被缓存）。
    if (!m_swsCtx ||
        m_swsSrcW != f->width || m_swsSrcH != f->height ||
        m_swsSrcFmt != srcFmt ||
        m_swsDstW != dstW || m_swsDstH != dstH) {
        rbReleaseSwsContext();
        m_swsCtx = sws_getContext(
            f->width, f->height, srcFmt,
            dstW, dstH, AV_PIX_FMT_RGBA,
            SWS_LANCZOS | SWS_FULL_CHR_H_INT | SWS_ACCURATE_RND,
            nullptr, nullptr, nullptr);
        m_swsSrcW   = f->width;
        m_swsSrcH   = f->height;
        m_swsSrcFmt = srcFmt;
        m_swsDstW   = dstW;
        m_swsDstH   = dstH;
    }
    if (!m_swsCtx) return;

    // 每帧应用色彩空间/范围（开销极小，但 frame 的 colorspace/range 可能动态变化）
    rbSwsApplyColorspace(m_swsCtx, f);

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
    m_swsDstW = m_swsDstH = 0;
}

// ─── 绘制：保持视频纵横比，居中、按物理像素 1:1 整数对齐铺满 ────────────────
//
// 流程（严格对齐旧工程 PlayerX/rb_video_cell.cpp 的“整数对齐 + 1:1 上屏”）：
//   ① 取当前帧分辨率 fw×fh（如 1080×1920），以及当前 widget 的物理像素尺寸
//      areaW×areaH（boundingRect × devicePixelRatio）。
//   ② 按视频纵横比等比缩放，dstW/dstH **四舍五入到整数像素**（std::round）。
//      浮点截断会导致 sws 的目标尺寸与屏幕实际渲染矩形错位 → 亚像素偏差 →
//      边缘像素采样发生 0~0.999 像素偏移 → 字幕等高对比边缘出现毛边/锯齿。
//   ③ 调用 rbConvertFrameToImage(dstW, dstH) —— sws 一次 Lanczos 直接缩到
//      dstW×dstH 的 RGBA。
//   ④ paint 用整数 QRectF（同样四舍五入）直接 1:1 上屏，**关闭** Qt 的
//      SmoothPixmapTransform —— 因为图像已经是目标物理像素尺寸，再开双线性
//      只会徒增模糊（这是用户反馈“缩放后视频内文字模糊”的核心元凶）。
void VideoFrameProvider::paint(QPainter* painter) {
    if (!painter) return;

    // 当前帧尺寸（决定纵横比；用 player 的 frame 尺寸而非 m_currentImage，
    // 因为首帧到达前 m_currentImage 仍是空的）
    auto* p = rbActivePlayer();
    if (!p) return;
    AVFrame* f = p->rbGetCurrentFrame();
    if (!f || f->width <= 0 || f->height <= 0) return;
    const int fw = f->width;
    const int fh = f->height;

    // boundingRect 是逻辑像素，乘 DPR 得到屏幕物理像素 —— sws 的目标必须是
    // 物理像素，否则 Retina 屏会得到 0.5× 大小的 RGB 缓冲再被 Qt 双线性放大
    // 到 1×（这正是网格伪影最容易出现的路径）。
    const QRectF dstRect = boundingRect();
    if (dstRect.width() <= 0 || dstRect.height() <= 0) return;
    const qreal dpr = (window() ? window()->devicePixelRatio()
                                : painter->device()->devicePixelRatioF());
    const int areaW = std::max(1, int(std::round(dstRect.width()  * dpr)));
    const int areaH = std::max(1, int(std::round(dstRect.height() * dpr)));

    // 等比缩放，整数物理像素
    const double scaleX = double(areaW) / double(fw);
    const double scaleY = double(areaH) / double(fh);
    const double scale  = std::min(scaleX, scaleY);
    const int    dstW   = std::max(1, int(std::round(fw * scale)));
    const int    dstH   = std::max(1, int(std::round(fh * scale)));

    // 先按目标物理像素尺寸做一次 sws Lanczos 转换 + 缩放
    rbConvertFrameToImage(dstW, dstH);
    if (m_currentImage.isNull()) return;

    // 计算上屏矩形：物理像素整数对齐，再换回逻辑像素给 QPainter（QPainter
    // 的坐标系是逻辑像素）。先用整数物理像素居中，再除以 dpr 得到逻辑坐标。
    const int physOffsetX = (areaW - dstW) / 2;
    const int physOffsetY = (areaH - dstH) / 2;
    const QRectF target(
        dstRect.x() + double(physOffsetX) / dpr,
        dstRect.y() + double(physOffsetY) / dpr,
        double(dstW) / dpr,
        double(dstH) / dpr);

    // 关键：图像已经是目标物理像素，1:1 上屏。**关闭** SmoothPixmapTransform，
    // 否则 Qt 还会做一次双线性插值——网格伪影 / 文字糊化的元凶。
    painter->setRenderHint(QPainter::SmoothPixmapTransform, false);
    painter->setRenderHint(QPainter::Antialiasing,           false);
    painter->drawImage(target, m_currentImage);
}

} // namespace rbqt
