#pragma once
/**
 * ImageSliderCompareItem.h — 图片分析双路滑动比较渲染组件（QQuickPaintedItem）
 *
 * ⚠️ 与 ImageDisplayItem 相同的 DPR 感知要求：
 *   boundingRect() 是逻辑像素，必须 × devicePixelRatio 才是屏幕物理像素。
 *   两路图共享同一个 fitScale（物理像素域计算），保证分割线两侧像素严格对齐。
 *   上屏时关闭 SmoothPixmapTransform，1:1 贴图不做二次插值。
 */

#include <QQuickPaintedItem>
#include <QQuickWindow>
#include <QPainter>
#include <QPaintDevice>
#include <QImage>
#include <cmath>
#include <algorithm>

class ImageSliderCompareItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QImage leftImage READ leftImage WRITE setLeftImage NOTIFY leftImageChanged)
    Q_PROPERTY(QImage rightImage READ rightImage WRITE setRightImage NOTIFY rightImageChanged)
    Q_PROPERTY(qreal panX READ panX WRITE setPanX NOTIFY panChanged)
    Q_PROPERTY(qreal panY READ panY WRITE setPanY NOTIFY panChanged)
    Q_PROPERTY(qreal imgScale READ imgScale WRITE setImgScale NOTIFY imgScaleChanged)
    Q_PROPERTY(double splitRatio READ splitRatio WRITE setSplitRatio NOTIFY splitRatioChanged)
    Q_PROPERTY(QString renderMode READ renderMode WRITE setRenderMode NOTIFY renderModeChanged)

public:
    explicit ImageSliderCompareItem(QQuickItem* parent = nullptr)
        : QQuickPaintedItem(parent) {
        setAntialiasing(false);
        setSmooth(false);
        setFillColor(QColor(10, 10, 14));
        setRenderTarget(QQuickPaintedItem::FramebufferObject);
    }

    qreal effectiveDpr(QPainter* painter = nullptr) const {
        if (window()) return window()->devicePixelRatio();
        if (painter && painter->device()) return painter->device()->devicePixelRatioF();
        return 1.0;
    }

    // 多级渐进降采样（说明见 ImageDisplayItem.h）
    static QImage progressiveDownscale(const QImage& src, int tw, int th) {
        QImage cur = src;
        while (cur.width() >= tw * 2 && cur.height() >= th * 2
               && cur.width() > 1 && cur.height() > 1) {
            cur = cur.scaled(std::max(1, cur.width()  / 2),
                             std::max(1, cur.height() / 2),
                             Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
        }
        if (cur.width() == tw && cur.height() == th) return cur;
        return cur.scaled(tw, th, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    QImage scaleToPhysical(const QImage& src, int tw, int th) const {
        if (src.isNull() || tw <= 0 || th <= 0) return src;
        const int iw = src.width();
        const int ih = src.height();
        if (tw == iw && th == ih) return src;

        if (m_renderMode == "pixel")
            return src.scaled(tw, th, Qt::IgnoreAspectRatio, Qt::FastTransformation);

        if (m_renderMode != "smooth") {
            if (tw > iw && th > ih && (tw % iw == 0) && (th % ih == 0)
                && (tw / iw == th / ih)) {
                const int n = tw / iw;
                QImage out(tw, th, QImage::Format_ARGB32_Premultiplied);
                const QImage srcConv = (src.format() == QImage::Format_ARGB32_Premultiplied)
                                           ? src
                                           : src.convertToFormat(QImage::Format_ARGB32_Premultiplied);
                for (int sy = 0; sy < ih; ++sy) {
                    const QRgb* srow = reinterpret_cast<const QRgb*>(srcConv.constScanLine(sy));
                    for (int dy = 0; dy < n; ++dy) {
                        QRgb* drow = reinterpret_cast<QRgb*>(out.scanLine(sy * n + dy));
                        for (int sx = 0; sx < iw; ++sx) {
                            const QRgb p = srow[sx];
                            const int dxBase = sx * n;
                            for (int dx = 0; dx < n; ++dx)
                                drow[dxBase + dx] = p;
                        }
                    }
                }
                return out;
            }
        }

        if (tw * 2 <= iw && th * 2 <= ih)
            return progressiveDownscale(src, tw, th);

        return src.scaled(tw, th, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    void paint(QPainter* painter) override {
        const QRectF r = boundingRect();
        if (r.width() <= 0 || r.height() <= 0) return;
        if (m_leftImage.isNull() && m_rightImage.isNull()) return;

        // ① 逻辑像素 → 屏幕物理像素
        const qreal dpr = effectiveDpr(painter);
        const int areaW = std::max(1, int(std::round(r.width()  * dpr)));
        const int areaH = std::max(1, int(std::round(r.height() * dpr)));

        // ② 两路共享 fitScale（取较小值），保证分割线两侧严格对齐
        double fitScale = 1e18;
        if (!m_leftImage.isNull())
            fitScale = std::min(fitScale,
                std::min(double(areaW) / double(m_leftImage.width()),
                         double(areaH) / double(m_leftImage.height())));
        if (!m_rightImage.isNull())
            fitScale = std::min(fitScale,
                std::min(double(areaW) / double(m_rightImage.width()),
                         double(areaH) / double(m_rightImage.height())));
        if (fitScale > 1e17) fitScale = 1.0;
        const double actual = fitScale * m_imgScale;

        // ③ 缩放到物理像素（带缓存）
        const bool cacheStale = (m_cacheScale != actual)
            || (m_cacheMode != m_renderMode)
            || (m_cacheLeftKey  != m_leftImage.cacheKey())
            || (m_cacheRightKey != m_rightImage.cacheKey());
        if (cacheStale) {
            if (!m_leftImage.isNull()) {
                m_leftScaled = scaleToPhysical(m_leftImage,
                    std::max(1, int(std::round(m_leftImage.width()  * actual))),
                    std::max(1, int(std::round(m_leftImage.height() * actual))));
            } else m_leftScaled = QImage();
            if (!m_rightImage.isNull()) {
                m_rightScaled = scaleToPhysical(m_rightImage,
                    std::max(1, int(std::round(m_rightImage.width()  * actual))),
                    std::max(1, int(std::round(m_rightImage.height() * actual))));
            } else m_rightScaled = QImage();
            m_cacheScale    = actual;
            m_cacheMode     = m_renderMode;
            m_cacheLeftKey  = m_leftImage.cacheKey();
            m_cacheRightKey = m_rightImage.cacheKey();
        }

        // ④ 关闭二次插值
        painter->setRenderHint(QPainter::SmoothPixmapTransform, false);
        painter->setRenderHint(QPainter::Antialiasing,          false);

        const qreal splitX = r.x() + r.width() * m_splitRatio;

        // ── 左半 ──
        if (!m_leftScaled.isNull()) {
            painter->save();
            painter->setClipRect(QRectF(r.x(), r.y(), splitX - r.x(), r.height()));
            const double lw = double(m_leftScaled.width())  / dpr;
            const double lh = double(m_leftScaled.height()) / dpr;
            painter->drawImage(
                QRectF(r.x() + (r.width()  - lw) / 2.0 + m_panX,
                       r.y() + (r.height() - lh) / 2.0 + m_panY, lw, lh),
                m_leftScaled);
            painter->restore();
        }

        // ── 右半 ──
        if (!m_rightScaled.isNull()) {
            painter->save();
            painter->setClipRect(QRectF(splitX, r.y(),
                                        r.x() + r.width() - splitX, r.height()));
            const double rw = double(m_rightScaled.width())  / dpr;
            const double rh = double(m_rightScaled.height()) / dpr;
            painter->drawImage(
                QRectF(r.x() + (r.width()  - rw) / 2.0 + m_panX,
                       r.y() + (r.height() - rh) / 2.0 + m_panY, rw, rh),
                m_rightScaled);
            painter->restore();
        }

        // ── 分割线（1 物理像素宽）──
        painter->fillRect(QRectF(splitX - 0.5 / dpr, r.y(), 1.0 / dpr, r.height()),
                          QColor(61, 122, 223, 230));
    }

    void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override {
        QQuickPaintedItem::geometryChange(newGeometry, oldGeometry);
        m_cacheScale = -1;
        update();
    }

    // ── getters / setters ──
    QImage leftImage() const { return m_leftImage; }
    void setLeftImage(const QImage& img) {
        m_leftImage = img; m_cacheScale = -1; update(); emit leftImageChanged();
    }

    QImage rightImage() const { return m_rightImage; }
    void setRightImage(const QImage& img) {
        m_rightImage = img; m_cacheScale = -1; update(); emit rightImageChanged();
    }

    qreal panX() const { return m_panX; }
    void setPanX(qreal v) {
        if (qFuzzyCompare(m_panX + 1.0, v + 1.0)) return;
        m_panX = v; update(); emit panChanged();
    }

    qreal panY() const { return m_panY; }
    void setPanY(qreal v) {
        if (qFuzzyCompare(m_panY + 1.0, v + 1.0)) return;
        m_panY = v; update(); emit panChanged();
    }

    qreal imgScale() const { return m_imgScale; }
    void setImgScale(qreal v) {
        if (v < 0.01) v = 0.01;
        if (qFuzzyCompare(m_imgScale, v)) return;
        m_imgScale = v; m_cacheScale = -1; update(); emit imgScaleChanged();
    }

    double splitRatio() const { return m_splitRatio; }
    void setSplitRatio(double v) {
        if (v < 0.0) v = 0.0;
        if (v > 1.0) v = 1.0;
        if (qFuzzyCompare(v + 1.0, m_splitRatio + 1.0)) return;
        m_splitRatio = v; update(); emit splitRatioChanged();
    }

    QString renderMode() const { return m_renderMode; }
    void setRenderMode(const QString& v) {
        if (m_renderMode == v) return;
        m_renderMode = v; m_cacheScale = -1; update(); emit renderModeChanged();
    }

signals:
    void leftImageChanged();
    void rightImageChanged();
    void panChanged();
    void imgScaleChanged();
    void splitRatioChanged();
    void renderModeChanged();

private:
    QImage  m_leftImage;
    QImage  m_rightImage;
    QImage  m_leftScaled;
    QImage  m_rightScaled;
    qreal   m_panX = 0;
    qreal   m_panY = 0;
    qreal   m_imgScale = 1.0;
    double  m_splitRatio = 0.5;
    QString m_renderMode = "standard";

    double  m_cacheScale = -1;
    QString m_cacheMode;
    qint64  m_cacheLeftKey  = 0;
    qint64  m_cacheRightKey = 0;
};
