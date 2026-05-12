/**
 * SliderCompareItem.cpp — 双路视频"滑动比较"渲染 Item 的实现
 *
 * 渲染策略（与 VideoFrameProvider 严格一致，避免任何画质回退）：
 *   ① 每路独立的 SwsContext，缩放算法 = SWS_LANCZOS（Lanczos3 6×6 采样、带负瓣）
 *      搭配 SWS_FULL_CHR_H_INT | SWS_ACCURATE_RND，色彩矩阵由 rbSwsApplyColorspace
 *      根据 frame->colorspace / color_range 动态设置（BT.709 / BT.601 / full vs limited）。
 *   ② 目标尺寸 = 视频在 widget 内"等比缩放居中"后，**屏幕物理像素**整数四舍五入。
 *      sws 直接把帧缩到该物理像素尺寸，paint 1:1 上屏，**关闭** SmoothPixmapTransform，
 *      杜绝 Qt 端二次双线性插值（网格伪影 + 内嵌文字模糊的根因）。
 *   ③ 分割：splitX = round(boundingRect.width * splitRatio * dpr)，左半画左路图、
 *      右半画右路图；中间 1 物理像素白色竖线，逻辑像素折算回 paint 用 QRectF。
 *   ④ 不调任何播放控制（rbPlay / rbSeekTo / rbStepFrame），仅 rbGetCurrentFrame 读帧。
 */
#include "SliderCompareItem.h"
#include "EngineBridge.h"
#include "rb_video_player.h"

#include <QPainter>
#include <QQuickWindow>
#include <QPaintDevice>
#include <algorithm>
#include <cmath>

extern "C" {
#include <libavutil/frame.h>
}

namespace rbqt {

// 与 VideoFrameProvider.cpp 中的同名函数完全一致：把 frame 的色彩空间/范围信息
// 应用到 SwsContext，避免 BT.709 / full-range 视频被错误矩阵解码出灰阶偏移
// 引发的"伪边缘 / 网格"伪影。
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
        coeffs, src_range,
        coeffs, 1,
        0, FIXED_1_0, FIXED_1_0);
}

SliderCompareItem::SliderCompareItem(QQuickItem* parent)
    : QQuickPaintedItem(parent) {
    setRenderTarget(QQuickPaintedItem::FramebufferObject);
    setFillColor(Qt::black);
}

SliderCompareItem::~SliderCompareItem() {
    rbReleaseSws(m_left);
    rbReleaseSws(m_right);
}

QObject* SliderCompareItem::engineObject() const { return m_engine.data(); }

void SliderCompareItem::setEngineObject(QObject* obj) {
    auto* eng = qobject_cast<EngineBridge*>(obj);
    if (m_engine.data() == eng) return;

    if (m_engine) {
        disconnect(m_engine.data(), &EngineBridge::requestRepaint,
                   this, &SliderCompareItem::onEngineRepaint);
    }
    m_engine = eng;
    if (m_engine) {
        connect(m_engine.data(), &EngineBridge::requestRepaint,
                this, &SliderCompareItem::onEngineRepaint);
    }
    emit engineChanged();
    update();
}

void SliderCompareItem::setLeftIndex(int v) {
    if (v == m_leftIndex) return;
    m_leftIndex = v;
    rbReleaseSws(m_left);  // 切换路数 → 重建 sws（分辨率/格式可能变）
    m_left.image = QImage();
    emit leftIndexChanged();
    update();
}

void SliderCompareItem::setRightIndex(int v) {
    if (v == m_rightIndex) return;
    m_rightIndex = v;
    rbReleaseSws(m_right);
    m_right.image = QImage();
    emit rightIndexChanged();
    update();
}

void SliderCompareItem::setSplitRatio(double r) {
    if (r < 0.0) r = 0.0;
    if (r > 1.0) r = 1.0;
    if (qFuzzyCompare(r + 1.0, m_splitRatio + 1.0)) return;
    m_splitRatio = r;
    emit splitRatioChanged();
    update();
}

void SliderCompareItem::onEngineRepaint() {
    update();
}

void SliderCompareItem::rbReleaseSws(Side& s) {
    if (s.sws) {
        sws_freeContext(s.sws);
        s.sws = nullptr;
    }
    s.srcW = s.srcH = 0;
    s.srcFmt = -1;
    s.dstW = s.dstH = 0;
}

// 把单路 frame 转成"目标物理像素"的 RGBA QImage。areaW/areaH 是 widget 的物理
// 像素尺寸；本路视频按其纵横比在 area 内等比缩放居中，并把目标矩形的左上偏移
// （offX/offY）写回 Side，paint() 据此放置图像。
void SliderCompareItem::rbConvertSide(Side& s, rb::RBVideoPlayer* p, int areaW, int areaH) {
    if (!p || areaW <= 0 || areaH <= 0) {
        s.image = QImage();
        return;
    }
    AVFrame* f = p->rbGetCurrentFrame();
    if (!f || f->width <= 0 || f->height <= 0) return;

    AVPixelFormat srcFmt = (AVPixelFormat)f->format;
    if (srcFmt == AV_PIX_FMT_NONE) return;

    // 等比缩放，物理像素四舍五入到整数
    const double scaleX = double(areaW) / double(f->width);
    const double scaleY = double(areaH) / double(f->height);
    const double scale  = std::min(scaleX, scaleY);
    const int    dstW   = std::max(1, int(std::round(f->width  * scale)));
    const int    dstH   = std::max(1, int(std::round(f->height * scale)));

    // 目标 QImage
    if (s.image.size() != QSize(dstW, dstH) ||
        s.image.format() != QImage::Format_RGBA8888) {
        s.image = QImage(dstW, dstH, QImage::Format_RGBA8888);
    }

    // 仅在 src 三元组或 dst 尺寸变化时重建 SwsContext
    if (!s.sws ||
        s.srcW != f->width || s.srcH != f->height ||
        s.srcFmt != srcFmt ||
        s.dstW != dstW || s.dstH != dstH) {
        if (s.sws) { sws_freeContext(s.sws); s.sws = nullptr; }
        s.sws = sws_getContext(
            f->width, f->height, srcFmt,
            dstW, dstH, AV_PIX_FMT_RGBA,
            SWS_LANCZOS | SWS_FULL_CHR_H_INT | SWS_ACCURATE_RND,
            nullptr, nullptr, nullptr);
        s.srcW = f->width;
        s.srcH = f->height;
        s.srcFmt = srcFmt;
        s.dstW = dstW;
        s.dstH = dstH;
    }
    if (!s.sws) return;

    rbSwsApplyColorspace(s.sws, f);

    uint8_t*  dst[4]       = { s.image.bits(), nullptr, nullptr, nullptr };
    int       dstStride[4] = { static_cast<int>(s.image.bytesPerLine()), 0, 0, 0 };
    sws_scale(s.sws, f->data, f->linesize, 0, f->height, dst, dstStride);

    // 居中偏移（widget 物理像素坐标系）
    s.offX = (areaW - dstW) / 2;
    s.offY = (areaH - dstH) / 2;
}

void SliderCompareItem::paint(QPainter* painter) {
    if (!painter || !m_engine) return;

    auto* pl = m_engine->playerAt(m_leftIndex);
    auto* pr = m_engine->playerAt(m_rightIndex);
    // 任一路没有就只画黑底（基类 fillColor 已处理）
    if (!pl && !pr) return;

    const QRectF rect = boundingRect();
    if (rect.width() <= 0 || rect.height() <= 0) return;

    const qreal dpr = (window() ? window()->devicePixelRatio()
                                : painter->device()->devicePixelRatioF());
    const int areaW = std::max(1, int(std::round(rect.width()  * dpr)));
    const int areaH = std::max(1, int(std::round(rect.height() * dpr)));

    // 各自 sws 缩放到目标物理像素尺寸（每路按自身纵横比居中）
    rbConvertSide(m_left,  pl, areaW, areaH);
    rbConvertSide(m_right, pr, areaW, areaH);

    // 分割位置（widget 物理像素）
    int splitX = std::clamp(int(std::round(areaW * m_splitRatio)), 0, areaW);

    // 关闭一切 Qt 二次插值，与 VideoFrameProvider 一致
    painter->setRenderHint(QPainter::SmoothPixmapTransform, false);
    painter->setRenderHint(QPainter::Antialiasing,           false);

    // 把 widget 物理像素坐标转成逻辑像素 QRectF（QPainter 用逻辑坐标）
    auto physToLogical = [dpr, &rect](int x, int y, int w, int h) {
        return QRectF(rect.x() + double(x) / dpr,
                      rect.y() + double(y) / dpr,
                      double(w) / dpr,
                      double(h) / dpr);
    };

    // ─── 画左半（widget 物理像素 [0, splitX]）─────────────────────────
    if (!m_left.image.isNull() && splitX > 0) {
        // 左图在 widget 物理像素中的覆盖矩形：[m_left.offX, m_left.offX+m_left.dstW]
        const int imgL = m_left.offX;
        const int imgR = m_left.offX + m_left.dstW;
        const int clipL = std::max(0, imgL);
        const int clipR = std::min(splitX, imgR);
        if (clipR > clipL) {
            // 取图像内部对应子矩形（源）
            const int srcX = clipL - imgL;       // ≥ 0
            const int srcW = clipR - clipL;
            const QRectF srcRect(srcX, 0, srcW, m_left.dstH);
            const QRectF dstRect = physToLogical(clipL, m_left.offY,
                                                 srcW, m_left.dstH);
            painter->drawImage(dstRect, m_left.image, srcRect);
        }
    }

    // ─── 画右半（widget 物理像素 [splitX, areaW]）─────────────────────
    if (!m_right.image.isNull() && splitX < areaW) {
        const int imgL = m_right.offX;
        const int imgR = m_right.offX + m_right.dstW;
        const int clipL = std::max(splitX, imgL);
        const int clipR = std::min(areaW,  imgR);
        if (clipR > clipL) {
            const int srcX = clipL - imgL;
            const int srcW = clipR - clipL;
            const QRectF srcRect(srcX, 0, srcW, m_right.dstH);
            const QRectF dstRect = physToLogical(clipL, m_right.offY,
                                                 srcW, m_right.dstH);
            painter->drawImage(dstRect, m_right.image, srcRect);
        }
    }

    // ─── 中间分割线（1 物理像素白色） ────────────────────────────────
    if (splitX >= 0 && splitX <= areaW) {
        const QRectF lineRect = physToLogical(std::max(0, splitX - 0), 0,
                                              1, areaH);
        painter->fillRect(lineRect, QColor(255, 255, 255, 220));
    }
}

} // namespace rbqt
