#pragma once
/**
 * YuvDisplayItem.h — 超简 YUV 画面渲染组件（QQuickPaintedItem）
 *
 * 接收 YuvBridge.frameImage 的 QImage 绑定，直接 QPainter::drawImage 贴到屏幕上。
 * 支持右键拖拽平移（panX/panY）+ 整数/分数倍缩放。
 *
 * 缩放策略（保证"物理像素级渲染"）：
 *   - 缩放 ≠ 1 时，在 setImage() 里**预先**把 m_image 缩到目标物理尺寸（用
 *     QImage::scaled + Qt::SmoothTransformation），缓存到 m_scaled。
 *   - 缩放 > 1 且为整数倍（如 2X/4X/8X）时，改用 nearest-neighbor（每原像素
 *     复制到 N×N 块），彻底避免插值——每个输出像素都精确对应一个源像素，最贴近
 *     "物理像素"语义。
 *   - paint() 始终按 m_scaled 的真实尺寸 1:1 画到屏幕，QPainter 不再做任何
 *     重采样；这样从源到屏永远只有一次有质量的变换，不损失清晰度。
 */

#include <QQuickPaintedItem>
#include <QPainter>
#include <QImage>

class YuvDisplayItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QImage image READ image WRITE setImage NOTIFY imageChanged)
    Q_PROPERTY(qreal panX READ panX WRITE setPanX NOTIFY panChanged)
    Q_PROPERTY(qreal panY READ panY WRITE setPanY NOTIFY panChanged)
    // 当前缩放比例（来自 YuvBridge.globalScale，多路共享）。
    // YuvDisplayItem 自己不再持有 scale 状态——所有缩放都通过
    // YuvBridge.setGlobalScale() 统一管理，QML 端只读这里。
    Q_PROPERTY(qreal scale READ scale NOTIFY scaleChanged)
    // 当前缩放档位索引（0..6，与 YuvBridge.currentScaleIndex() 同源）
    Q_PROPERTY(int currentScaleIndex READ currentScaleIndex NOTIFY scaleChanged)

public:
    explicit YuvDisplayItem(QQuickItem* parent = nullptr)
        : QQuickPaintedItem(parent) {
        setAntialiasing(false);
        setSmooth(true);
        setFillColor(QColor(10, 10, 14));
    }

    // 预缩放：对源图按 scale 提前缩到 m_scaled，paint() 1:1 贴。
    //   - 缩放 = 1   → m_scaled = m_image，不做任何重采样
    //   - 缩放 < 1   → Qt::SmoothTransformation（双三次插值，缩放后的图像是
    //                  "目标物理尺寸"，不是源尺寸）
    //   - 缩放 > 1   → 若为整数倍：nearest-neighbor（每源像素复制 N×N 块，
    //                  严格物理像素）；否则退回 SmoothTransformation
    // 设计目标：任何缩放下，**从源到屏只发生一次**有质量的缩放变换，
    // QPainter 在最终合成时按 1:1 贴图，不引入第二次重采样。
    QImage preScale(const QImage& src, qreal scale) const {
        if (src.isNull() || qFuzzyCompare(scale, 1.0)) return src;
        const int iw = src.width();
        const int ih = src.height();
        const int tw = std::max(1, static_cast<int>(std::round(iw * scale)));
        const int th = std::max(1, static_cast<int>(std::round(ih * scale)));
        if (tw == iw && th == ih) return src;

        // 整数倍放大：纯 nearest-neighbor，每源像素复制到 N×N 块，零插值
        const bool isIntUpScale = (scale > 1.0) &&
            (qFuzzyCompare(scale, std::round(scale)));
        if (isIntUpScale) {
            const int n = static_cast<int>(std::round(scale));
            QImage out(tw, th, src.format());
            // 按块复制：每个源像素 → 输出 N×N 块
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
        // 缩小 / 非整数放大：QImage::scaled 高质量插值
        return src.scaled(tw, th, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    void paint(QPainter* painter) override {
        const QImage& draw = m_scaled.isNull() ? m_image : m_scaled;
        if (draw.isNull()) return;
        const int iw = draw.width();
        const int ih = draw.height();
        if (iw <= 0 || ih <= 0) return;
        const QRectF r = boundingRect();
        // 1:1 居中 + 平移偏移（m_scaled 已是预缩到目标物理尺寸，这里 1:1 画）
        const double dx = r.x() + (r.width()  - iw) / 2.0 + m_panX;
        const double dy = r.y() + (r.height() - ih) / 2.0 + m_panY;
        painter->drawImage(QPointF(dx, dy), draw);
    }

    void setImage(const QImage& img) {
        m_image = img;
        m_scaled = preScale(img, m_scale);
        update();
        emit imageChanged();
    }

    QImage image() const { return m_image; }

    qreal panX() const { return m_panX; }
    qreal panY() const { return m_panY; }

    void setPanX(qreal v) {
        if (qFuzzyCompare(m_panX, v)) return;
        m_panX = v;
        update();
        emit panChanged();
    }

    void setPanY(qreal v) {
        if (qFuzzyCompare(m_panY, v)) return;
        m_panY = v;
        update();
        emit panChanged();
    }

    // scale / currentScaleIndex 现在通过 onGlobalScaleChanged() 监听 YuvBridge
    // 的 globalScaleChanged 信号；外部只读，不要直接写。
    qreal scale() const { return m_scale; }
    int currentScaleIndex() const { return m_currentScaleIndex; }

    // 由 YuvBridge.globalScaleChanged 驱动：更新内部 m_scale / m_currentScaleIndex
    // 并按新 scale 重算 m_scaled。
    // 必须标记 Q_INVOKABLE：QML 端通过 `yuvDisp.onGlobalScaleChanged(scale)` 直接
    // 调用（非 Q_INVOKABLE 的 public 方法在 QML 里不可见，调用会静默失败，
    // 表现为"只移动不缩放"）。
    Q_INVOKABLE void onGlobalScaleChanged(qreal newScale) {
        if (qFuzzyCompare(m_scale, newScale)) return;
        m_scale = newScale;
        for (int i = 0; i < 7; ++i) {
            if (qFuzzyCompare(kScaleValues[i], newScale)) {
                m_currentScaleIndex = i;
                break;
            }
        }
        if (!m_image.isNull()) {
            m_scaled = preScale(m_image, m_scale);
        }
        update();
        emit scaleChanged();
    }

signals:
    void imageChanged();
    void panChanged();
    void scaleChanged();

private:
    // 缩放档位常量（与 YuvBridge::kScaleValues 严格保持一致）：
    //   0: 1/8, 1: 1/4, 2: 1/2, 3: 1X, 4: 2X, 5: 4X, 6: 8X
    static constexpr qreal kScaleValues[7] = {0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0};

    QImage m_image;       // 源图（原始物理尺寸）
    QImage m_scaled;      // 按 m_scale 预缩到目标物理尺寸，paint() 1:1 贴
    qreal m_panX = 0;
    qreal m_panY = 0;
    qreal m_scale = 1.0;  // 1.0 = 1X 默认
    int m_currentScaleIndex = 3;  // 默认指向 "1X"
};
