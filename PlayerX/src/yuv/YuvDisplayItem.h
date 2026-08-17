#pragma once
/**
 * YuvDisplayItem.h — 超简 YUV 画面渲染组件（QQuickPaintedItem）
 *
 * 接收 YuvBridge.frameImage 的 QImage 绑定，直接 QPainter::drawImage 贴到屏幕上。
 * 支持右键拖拽平移（panX/panY），1:1 居中显示，不缩放。
 */

#include <QQuickPaintedItem>
#include <QPainter>
#include <QImage>

class YuvDisplayItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QImage image READ image WRITE setImage NOTIFY imageChanged)
    Q_PROPERTY(qreal panX READ panX WRITE setPanX NOTIFY panChanged)
    Q_PROPERTY(qreal panY READ panY WRITE setPanY NOTIFY panChanged)

public:
    explicit YuvDisplayItem(QQuickItem* parent = nullptr)
        : QQuickPaintedItem(parent) {
        setAntialiasing(false);
        setSmooth(true);
        setFillColor(QColor(10, 10, 14));
    }

    void paint(QPainter* painter) override {
        if (m_image.isNull()) return;
        const int iw = m_image.width();
        const int ih = m_image.height();
        if (iw <= 0 || ih <= 0) return;
        const QRectF r = boundingRect();
        // 1:1 居中 + 平移偏移
        const double dx = r.x() + (r.width()  - iw) / 2.0 + m_panX;
        const double dy = r.y() + (r.height() - ih) / 2.0 + m_panY;
        painter->drawImage(QRectF(dx, dy, iw, ih), m_image);
    }

    void setImage(const QImage& img) {
        m_image = img;
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

signals:
    void imageChanged();
    void panChanged();

private:
    QImage m_image;
    qreal m_panX = 0;
    qreal m_panY = 0;
};
