#pragma once
/**
 * YuvSliderCompareItem.h — YUV 双路滑动比较渲染组件（QQuickPaintedItem）
 *
 * 设计借鉴播放对比的 SliderCompareItem，但针对 YUV 模块做了简化：
 *   - 输入是两个 QImage（来自 YuvBridge.frameImage(0/1)），而非 AVFrame
 *   - 不需要 SwsContext（图像已被 YuvBridge 解码为 RGBA QImage）
 *   - 缩放策略与 YuvDisplayItem 完全一致（preScale + paint 1:1 贴图）
 *   - paint() 按 splitRatio 把画面切成左右两半：
 *       [0, splitX]        画 leftImage（slot 0）
 *       (splitX, width]    画 rightImage（slot 1）
 *     中间画 1px 白色竖线作为分隔条。
 *   - 两路图像共享 panX/panY/scale，确保分割线两侧的像素严格对齐。
 *
 * 使用方式（QML）：
 *   YuvSliderCompareItem {
 *       anchors.fill: parent
 *       leftImage:  YuvBridge.frameImage(0)
 *       rightImage: YuvBridge.frameImage(1)
 *       splitRatio: 0.5
 *       panX: 0; panY: 0
 *   }
 */

#include <QQuickPaintedItem>
#include <QPainter>
#include <QImage>
#include <cmath>
#include <algorithm>

class YuvSliderCompareItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QImage leftImage READ leftImage WRITE setLeftImage NOTIFY leftImageChanged)
    Q_PROPERTY(QImage rightImage READ rightImage WRITE setRightImage NOTIFY rightImageChanged)
    Q_PROPERTY(qreal panX READ panX WRITE setPanX NOTIFY panChanged)
    Q_PROPERTY(qreal panY READ panY WRITE setPanY NOTIFY panChanged)
    Q_PROPERTY(qreal scale READ scale NOTIFY scaleChanged)
    Q_PROPERTY(double splitRatio READ splitRatio WRITE setSplitRatio NOTIFY splitRatioChanged)

public:
    explicit YuvSliderCompareItem(QQuickItem* parent = nullptr)
        : QQuickPaintedItem(parent) {
        setAntialiasing(false);
        setSmooth(true);
        setFillColor(QColor(10, 10, 14));
    }

    // preScale：与 YuvDisplayItem::preScale 完全一致，保证渲染质量不回退。
    //   - 缩放 = 1   → 原图，不做任何重采样
    //   - 缩放 < 1   → Qt::SmoothTransformation（双三次插值）
    //   - 缩放 > 1   → 整数倍 nearest-neighbor（零插值，严格物理像素）；
    //                  非整数倍退回 SmoothTransformation
    QImage preScale(const QImage& src, qreal scale) const {
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
            for (int sy = 0; sy < ih; ++sy) {
                const int dyBase = sy * n;
                for (int sx = 0; sx < iw; ++sx) {
                    const QRgb p = src.pixel(sx, sy);
                    const int dxBase = sx * n;
                    for (int dy = 0; dy < n; ++dy) {
                        QRgb* row = reinterpret_cast<QRgb*>(
                            out.scanLine(dyBase + dy));
                        for (int dx = 0; dx < n; ++dx) {
                            row[dxBase + dx] = p;
                        }
                    }
                }
            }
            return out;
        }
        return src.scaled(tw, th, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    void paint(QPainter* painter) override {
        const QRectF r = boundingRect();
        if (r.width() <= 0 || r.height() <= 0) return;

        const qreal splitX = r.x() + r.width() * m_splitRatio;

        // ── 左半：画 leftImage，裁剪到 [r.x(), splitX] ──
        if (!m_leftScaled.isNull()) {
            painter->save();
            painter->setClipRect(QRectF(r.x(), r.y(), splitX - r.x(), r.height()));
            const int iw = m_leftScaled.width();
            const int ih = m_leftScaled.height();
            const double dx = r.x() + (r.width() - iw) / 2.0 + m_panX;
            const double dy = r.y() + (r.height() - ih) / 2.0 + m_panY;
            painter->drawImage(QPointF(dx, dy), m_leftScaled);
            painter->restore();
        }

        // ── 右半：画 rightImage，裁剪到 [splitX, r.x()+r.width()] ──
        if (!m_rightScaled.isNull()) {
            painter->save();
            painter->setClipRect(QRectF(splitX, r.y(),
                                        r.x() + r.width() - splitX, r.height()));
            const int iw = m_rightScaled.width();
            const int ih = m_rightScaled.height();
            const double dx = r.x() + (r.width() - iw) / 2.0 + m_panX;
            const double dy = r.y() + (r.height() - ih) / 2.0 + m_panY;
            painter->drawImage(QPointF(dx, dy), m_rightScaled);
            painter->restore();
        }

        // ── 分割线（1px 白色半透明竖线）──
        painter->fillRect(QRectF(splitX - 0.5, r.y(), 1.0, r.height()),
                          QColor(255, 255, 255, 200));
    }

    // ── 属性 getter / setter ──

    QImage leftImage() const { return m_leftImage; }
    void setLeftImage(const QImage& img) {
        m_leftImage = img;
        m_leftScaled = preScale(img, m_scale);
        update();
        emit leftImageChanged();
    }

    QImage rightImage() const { return m_rightImage; }
    void setRightImage(const QImage& img) {
        m_rightImage = img;
        m_rightScaled = preScale(img, m_scale);
        update();
        emit rightImageChanged();
    }

    qreal panX() const { return m_panX; }
    void setPanX(qreal v) {
        if (qFuzzyCompare(m_panX, v)) return;
        m_panX = v;
        update();
        emit panChanged();
    }

    qreal panY() const { return m_panY; }
    void setPanY(qreal v) {
        if (qFuzzyCompare(m_panY, v)) return;
        m_panY = v;
        update();
        emit panChanged();
    }

    qreal scale() const { return m_scale; }

    // 由 YuvBridge.globalScaleChanged 驱动（与 YuvDisplayItem 一致）
    Q_INVOKABLE void onGlobalScaleChanged(qreal newScale) {
        if (qFuzzyCompare(m_scale, newScale)) return;
        m_scale = newScale;
        if (!m_leftImage.isNull())
            m_leftScaled = preScale(m_leftImage, m_scale);
        if (!m_rightImage.isNull())
            m_rightScaled = preScale(m_rightImage, m_scale);
        update();
        emit scaleChanged();
    }

    double splitRatio() const { return m_splitRatio; }
    void setSplitRatio(double r) {
        if (r < 0.0) r = 0.0;
        if (r > 1.0) r = 1.0;
        if (qFuzzyCompare(r + 1.0, m_splitRatio + 1.0)) return;
        m_splitRatio = r;
        emit splitRatioChanged();
        update();
    }

signals:
    void leftImageChanged();
    void rightImageChanged();
    void panChanged();
    void scaleChanged();
    void splitRatioChanged();

private:
    QImage m_leftImage;
    QImage m_rightImage;
    QImage m_leftScaled;
    QImage m_rightScaled;
    qreal  m_panX = 0;
    qreal  m_panY = 0;
    qreal  m_scale = 1.0;
    double m_splitRatio = 0.5;
};
