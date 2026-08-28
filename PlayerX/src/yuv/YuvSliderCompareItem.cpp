// YuvSliderCompareItem.cpp — YUV 双路滑动比较渲染组件（QQuickPaintedItem + QPainter）
//
// 与播放对比的 SliderCompareItem 采用相同的 QPainter 裁剪策略：
//   - 左路只画 [0, splitX] 区域，右路只画 [splitX, width] 区域
//   - 中间 1 物理像素白色分割线
//   - CPU preScale 保证画质（与 YuvDisplayItem 一致）

#include "YuvSliderCompareItem.h"
#include <QPainter>
#include <QQuickWindow>
#include <QPaintDevice>
#include <cmath>
#include <cstring>
#include <algorithm>

YuvSliderCompareItem::YuvSliderCompareItem(QQuickItem* parent)
    : QQuickPaintedItem(parent)
{
    setRenderTarget(QQuickPaintedItem::FramebufferObject);
    setFillColor(Qt::black);
}

// CPU preScale：与 YuvDisplayItem 完全一致
//   - 放大（整数倍）→ nearest-neighbor 逐像素复制
//   - 缩小 / 非整数放大 → Qt::SmoothTransformation
QImage YuvSliderCompareItem::preScale(const QImage& src, qreal scale) const {
    if (src.isNull() || qFuzzyCompare(scale, 1.0)) return src;
    const int iw = src.width();
    const int ih = src.height();
    const int tw = std::max(1, static_cast<int>(std::round(iw * scale)));
    const int th = std::max(1, static_cast<int>(std::round(ih * scale)));
    if (tw == iw && th == ih) return src;

    const bool isIntUpScale = (scale > 1.0) &&
        (qFuzzyCompare(scale, std::round(scale)));
    if (isIntUpScale) {
        const int n = static_cast<int>(std::round(scale));
        QImage out(tw, th, src.format());
        const int bpp = src.bytesPerLine() / src.width();  // bytes per pixel (RGBA=4)
        for (int sy = 0; sy < ih; ++sy) {
            const int dyBase = sy * n;
            const uint8_t* srcRow = src.constScanLine(sy);
            uint8_t* dstRow0 = out.scanLine(dyBase);
            // 水平放大：每个源像素 → n 个目标像素（memcpy bpp 字节，格式无关）
            for (int sx = 0; sx < iw; ++sx) {
                const int dxBase = sx * n;
                const uint8_t* srcPix = srcRow + sx * bpp;
                uint8_t* dstPix = dstRow0 + dxBase * bpp;
                for (int dx = 0; dx < n; ++dx) {
                    std::memcpy(dstPix + dx * bpp, srcPix, static_cast<size_t>(bpp));
                }
            }
            // 垂直复制：将首行 memcpy 到剩余 n-1 行（整行批量复制）
            const size_t rowBytes = static_cast<size_t>(tw) * bpp;
            for (int dy = 1; dy < n; ++dy) {
                std::memcpy(out.scanLine(dyBase + dy), dstRow0, rowBytes);
            }
        }
        return out;
    }
    return src.scaled(tw, th, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
}

void YuvSliderCompareItem::setLeftImage(const QImage& img) {
    m_leftImage = img;
    m_needRescale = true;
    update();
    emit leftImageChanged();
}

void YuvSliderCompareItem::setRightImage(const QImage& img) {
    m_rightImage = img;
    m_needRescale = true;
    update();
    emit rightImageChanged();
}

void YuvSliderCompareItem::setPanX(qreal v) {
    if (qFuzzyCompare(m_panX, v)) return;
    m_panX = v;
    update();
    emit panChanged();
}

void YuvSliderCompareItem::setPanY(qreal v) {
    if (qFuzzyCompare(m_panY, v)) return;
    m_panY = v;
    update();
    emit panChanged();
}

void YuvSliderCompareItem::onGlobalScaleChanged(qreal newScale) {
    if (qFuzzyCompare(m_scale, newScale)) return;
    m_scale = newScale;
    m_needRescale = true;
    update();
    emit scaleChanged();
}

void YuvSliderCompareItem::setSplitRatio(double r) {
    if (r < 0.0) r = 0.0;
    if (r > 1.0) r = 1.0;
    if (qFuzzyCompare(r + 1.0, m_splitRatio + 1.0)) return;
    m_splitRatio = r;
    emit splitRatioChanged();
    update();
}

void YuvSliderCompareItem::paint(QPainter* painter) {
    const QRectF rect = boundingRect();
    if (rect.width() <= 0 || rect.height() <= 0) return;

    const qreal dpr = (window() ? window()->devicePixelRatio()
                                : painter->device()->devicePixelRatioF());
    const int areaW = std::max(1, int(std::round(rect.width() * dpr)));
    const int areaH = std::max(1, int(std::round(rect.height() * dpr)));

    // ── preScale 因子 = m_scale × dpr（与 YuvDisplayItem GPU 路径等价） ──
    // YuvDisplayItem GPU 路径：drawW = iw * m_scale（逻辑像素），GPU 按 dpr 放大到
    // iw * m_scale * dpr 物理像素。本组件用 QPainter 物理像素坐标系，preScale 到
    // iw * m_scale * dpr 物理像素后 1:1 绘制，再 physToLogical 除以 dpr 还原逻辑坐标。
    // scale=1.0 → 原始分辨率 1:1（与 YuvDisplayItem 完全一致）。
    const double totalScale = m_scale * dpr;

    // ── 按需 preScale（缩放因子或 widget 尺寸变化时重算） ──
    if (m_needRescale ||
        !qFuzzyCompare(m_cachedTotalScaleL, qreal(totalScale)) ||
        m_cachedAreaW != areaW || m_cachedAreaH != areaH) {
        if (!m_leftImage.isNull())
            m_leftScaled = preScale(m_leftImage, totalScale);
        else
            m_leftScaled = QImage();
        if (!m_rightImage.isNull())
            m_rightScaled = preScale(m_rightImage, totalScale);
        else
            m_rightScaled = QImage();
        m_cachedTotalScaleL = qreal(totalScale);
        m_cachedTotalScaleR = qreal(totalScale);
        m_cachedAreaW = areaW;
        m_cachedAreaH = areaH;
        m_needRescale = false;
    }

    // 分割位置（widget 物理像素）
    int splitX = std::clamp(int(std::round(areaW * m_splitRatio)), 0, areaW);

    // 关闭 Qt 二次插值
    painter->setRenderHint(QPainter::SmoothPixmapTransform, false);
    painter->setRenderHint(QPainter::Antialiasing, false);

    // 物理像素 → 逻辑像素转换
    auto physToLogical = [dpr, &rect](double x, double y, double w, double h) {
        return QRectF(rect.x() + x / dpr,
                      rect.y() + y / dpr,
                      w / dpr,
                      h / dpr);
    };

    // 辅助：在 widget 物理像素子区间 [physL, physR] 上绘制一路图像
    // 图像已 preScale 到目标物理像素尺寸，1:1 居中绘制（与 SliderCompareItem 一致）
    auto drawSide = [&](const QImage& img, int physL, int physR) {
        if (img.isNull() || physR <= physL) return;

        const int iw = img.width();
        const int ih = img.height();
        // preScale 后的图像直接居中 1:1 绘制
        const int drawW = iw;
        const int drawH = ih;
        const int offX = (areaW - drawW) / 2 + int(m_panX * dpr);
        const int offY = (areaH - drawH) / 2 + int(m_panY * dpr);

        // 裁剪到 [physL, physR]
        const int imgL = offX;
        const int imgR = offX + drawW;
        const int clipL = std::max(physL, imgL);
        const int clipR = std::min(physR, imgR);
        if (clipR <= clipL) return;

        const int srcX = clipL - imgL;
        const int srcW = clipR - clipL;
        const QRectF srcRect(srcX, 0, srcW, ih);
        const QRectF dstRect = physToLogical(clipL, offY, srcW, drawH);
        painter->setRenderHint(QPainter::SmoothPixmapTransform, false);
        painter->drawImage(dstRect, img, srcRect);
    };

    // ─── 画左半 [0, splitX] ──────────────────
    drawSide(m_leftScaled, 0, splitX);

    // ─── 画右半 [splitX, areaW] ───────────────
    drawSide(m_rightScaled, splitX, areaW);

    // ─── 中间分割线（1 物理像素白色） ──────────────────────────
    if (splitX >= 0 && splitX <= areaW) {
        const QRectF lineRect = physToLogical(splitX, 0, 1, areaH);
        painter->fillRect(lineRect, QColor(255, 255, 255, 220));
    }
}
