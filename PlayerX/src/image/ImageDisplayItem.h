#pragma once
/**
 * ImageDisplayItem.h — 图片分析模块的物理像素级渲染组件（QQuickPaintedItem）
 *
 * ⚠️ 核心正确性依赖：DPR（devicePixelRatio）感知
 *   boundingRect() 返回的是**逻辑像素**。在 Retina 屏（DPR=2）上，如果直接用
 *   逻辑像素算缩放目标，得到的 QImage 只有实际屏幕物理像素的 1/2，随后 QPainter
 *   会把它双线性放大 2× 上屏 —— 这正是"文字发糊、不如系统预览清晰"的根因。
 *
 *   正确做法（与 VideoFrameProvider / SliderCompareItem 一致）：
 *     1. areaW/areaH = boundingRect × dpr        → 屏幕物理像素
 *     2. 在 CPU 端把源图缩放到 dstW/dstH（物理像素整数）
 *     3. 上屏 target 矩形 = 物理像素 / dpr        → 换回逻辑像素给 QPainter
 *     4. **关闭** SmoothPixmapTransform，保证 1:1 贴图不再被二次插值
 *
 * 渲染质量策略（renderMode）：
 *   "standard"（默认，物理像素级）：
 *       整数倍放大 → nearest-neighbor 块复制（零插值，严格物理像素）
 *       其他情况   → Qt::SmoothTransformation（双三次，高质量下采样）
 *   "smooth"：始终 Qt::SmoothTransformation（放大柔和）
 *   "pixel" ：始终 Qt::FastTransformation（最近邻，逐像素分析）
 *
 * 变换：rotation（90° 步进）、flipH、flipV、panX/panY、userScale。
 */

#include <QQuickPaintedItem>
#include <QQuickWindow>
#include <QPainter>
#include <QPaintDevice>
#include <QImage>
#include <cmath>
#include <algorithm>

class ImageDisplayItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QImage image READ image WRITE setImage NOTIFY imageChanged)
    Q_PROPERTY(qreal panX READ panX WRITE setPanX NOTIFY panChanged)
    Q_PROPERTY(qreal panY READ panY WRITE setPanY NOTIFY panChanged)
    Q_PROPERTY(qreal imgScale READ imgScale WRITE setImgScale NOTIFY imgScaleChanged)
    Q_PROPERTY(int imgRotation READ imgRotation WRITE setImgRotation NOTIFY transformChanged)
    Q_PROPERTY(bool flipH READ flipH WRITE setFlipH NOTIFY transformChanged)
    Q_PROPERTY(bool flipV READ flipV WRITE setFlipV NOTIFY transformChanged)
    Q_PROPERTY(QString renderMode READ renderMode WRITE setRenderMode NOTIFY renderModeChanged)

public:
    explicit ImageDisplayItem(QQuickItem* parent = nullptr)
        : QQuickPaintedItem(parent) {
        setAntialiasing(false);
        setSmooth(false);
        setFillColor(QColor(10, 10, 14));
        // 让 QQuickPaintedItem 的内部 FBO/图像也按 DPR 分配，避免自身被降采样
        setRenderTarget(QQuickPaintedItem::FramebufferObject);
    }

    // ── 当前有效 DPR ──
    qreal effectiveDpr(QPainter* painter = nullptr) const {
        if (window()) return window()->devicePixelRatio();
        if (painter && painter->device()) return painter->device()->devicePixelRatioF();
        return 1.0;
    }

    // ── 大幅缩小时的多级渐进降采样 ──────────────────────────────────
    // 行业标准做法（等效 Mipmap 金字塔）：一次性把 4000px 宽的图缩到 800px，
    // 即使用双三次也会因采样点不足丢失高频细节（文字发糊、出现摩尔纹）。
    // 正确做法是反复减半到接近目标尺寸，最后一步再精确缩放——每步都在
    // Nyquist 频率内，高频能量被逐级正确低通滤除而不是直接折叠。
    // 这是 macOS ColorSync/ImageIO 与各类专业看图软件的共同策略。
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

    // ── CPU 端缩放到指定物理像素尺寸 ──
    QImage scaleToPhysical(const QImage& src, int tw, int th) const {
        if (src.isNull() || tw <= 0 || th <= 0) return src;
        const int iw = src.width();
        const int ih = src.height();
        if (tw == iw && th == ih) return src;

        // "pixel" 模式：始终最近邻
        if (m_renderMode == "pixel")
            return src.scaled(tw, th, Qt::IgnoreAspectRatio, Qt::FastTransformation);

        // "standard"（默认）：整数倍放大走块复制，零插值
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

        // 缩小到不足一半：走多级渐进降采样（文字锐度关键）
        if (tw * 2 <= iw && th * 2 <= ih)
            return progressiveDownscale(src, tw, th);

        // 其余情况：单次双三次高质量缩放
        return src.scaled(tw, th, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    // ── paint：DPR 感知 + 物理像素 1:1 贴图 ──
    void paint(QPainter* painter) override {
        if (m_image.isNull()) return;
        const QRectF dstRect = boundingRect();
        if (dstRect.width() <= 0 || dstRect.height() <= 0) return;

        const int iw = m_image.width();
        const int ih = m_image.height();
        if (iw <= 0 || ih <= 0) return;

        // ① 逻辑像素 → 屏幕物理像素
        const qreal dpr = effectiveDpr(painter);
        const int areaW = std::max(1, int(std::round(dstRect.width()  * dpr)));
        const int areaH = std::max(1, int(std::round(dstRect.height() * dpr)));

        // ② 旋转 90/270 时，用于 fit 计算的图片宽高需要互换
        const bool swapped = (m_imgRotation % 180) != 0;
        const int fitW = swapped ? ih : iw;
        const int fitH = swapped ? iw : ih;

        // ③ fitScale（物理像素域）× 用户缩放
        const double fitScale = std::min(double(areaW) / double(fitW),
                                         double(areaH) / double(fitH));
        const double actual = fitScale * m_imgScale;
        const int dstW = std::max(1, int(std::round(iw * actual)));
        const int dstH = std::max(1, int(std::round(ih * actual)));

        // ④ CPU 端缩放到物理像素目标尺寸（缓存，避免每帧重算）
        if (m_cacheW != dstW || m_cacheH != dstH
            || m_cacheMode != m_renderMode || m_cacheSrcKey != m_image.cacheKey()) {
            m_scaled     = scaleToPhysical(m_image, dstW, dstH);
            m_cacheW     = dstW;
            m_cacheH     = dstH;
            m_cacheMode  = m_renderMode;
            m_cacheSrcKey = m_image.cacheKey();
        }
        if (m_scaled.isNull()) return;

        // ⑤ 关闭 QPainter 的二次插值 —— 图像已是目标物理像素，1:1 上屏
        painter->setRenderHint(QPainter::SmoothPixmapTransform, false);
        painter->setRenderHint(QPainter::Antialiasing,          false);

        painter->save();

        // ⑥ 变换中心（逻辑像素坐标 + pan 偏移）
        const double cx = dstRect.x() + dstRect.width()  / 2.0 + m_panX;
        const double cy = dstRect.y() + dstRect.height() / 2.0 + m_panY;
        painter->translate(cx, cy);

        if (m_imgRotation != 0)
            painter->rotate(m_imgRotation);

        if (m_flipH || m_flipV)
            painter->scale(m_flipH ? -1.0 : 1.0, m_flipV ? -1.0 : 1.0);

        // ⑦ 上屏矩形：物理像素 / dpr → 逻辑像素（QPainter 坐标系是逻辑像素）
        const double logicalW = double(dstW) / dpr;
        const double logicalH = double(dstH) / dpr;
        painter->drawImage(
            QRectF(-logicalW / 2.0, -logicalH / 2.0, logicalW, logicalH),
            m_scaled);

        painter->restore();
    }

    void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override {
        QQuickPaintedItem::geometryChange(newGeometry, oldGeometry);
        m_cacheW = m_cacheH = -1;   // 视图尺寸变化，缓存失效
        update();
    }

    // ── getters / setters ──
    QImage image() const { return m_image; }
    void setImage(const QImage& img) {
        m_image = img;
        m_cacheW = m_cacheH = -1;
        update();
        emit imageChanged();
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
        m_imgScale = v; m_cacheW = m_cacheH = -1; update(); emit imgScaleChanged();
    }

    int imgRotation() const { return m_imgRotation; }
    void setImgRotation(int v) {
        if (m_imgRotation == v) return;
        m_imgRotation = v; m_cacheW = m_cacheH = -1; update(); emit transformChanged();
    }

    bool flipH() const { return m_flipH; }
    void setFlipH(bool v) {
        if (m_flipH == v) return;
        m_flipH = v; update(); emit transformChanged();
    }

    bool flipV() const { return m_flipV; }
    void setFlipV(bool v) {
        if (m_flipV == v) return;
        m_flipV = v; update(); emit transformChanged();
    }

    QString renderMode() const { return m_renderMode; }
    void setRenderMode(const QString& v) {
        if (m_renderMode == v) return;
        m_renderMode = v; m_cacheW = m_cacheH = -1; update(); emit renderModeChanged();
    }

signals:
    void imageChanged();
    void panChanged();
    void imgScaleChanged();
    void transformChanged();
    void renderModeChanged();

private:
    QImage  m_image;
    QImage  m_scaled;              // 已缩到屏幕物理像素，paint() 1:1 贴
    qreal   m_panX = 0;
    qreal   m_panY = 0;
    qreal   m_imgScale = 1.0;      // 用户缩放（1.0 = 适配视图）
    int     m_imgRotation = 0;
    bool    m_flipH = false;
    bool    m_flipV = false;
    QString m_renderMode = "standard";

    // 缩放结果缓存
    int      m_cacheW = -1;
    int      m_cacheH = -1;
    QString  m_cacheMode;
    qint64   m_cacheSrcKey = 0;
};
