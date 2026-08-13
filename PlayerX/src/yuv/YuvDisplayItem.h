#pragma once
/**
 * YuvDisplayItem.h — 超简 YUV 画面渲染组件（QQuickPaintedItem）
 *
 * 接收 YuvBridge.frameImage 的 QImage 绑定，直接 QPainter::drawImage 贴到屏幕上。
 * 与 VideoFrameProvider 不同：不带任何播放逻辑 / 时钟同步 / 缩放平移。
 */

#include <QQuickPaintedItem>
#include <QPainter>
#include <QImage>

class YuvDisplayItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QImage image READ image WRITE setImage NOTIFY imageChanged)

public:
    explicit YuvDisplayItem(QQuickItem* parent = nullptr)
        : QQuickPaintedItem(parent) {
        setAntialiasing(false);
        setSmooth(true);
        setFillColor(QColor(10, 10, 14));
    }

    void paint(QPainter* painter) override {
        if (m_image.isNull()) return;
        // 1:1 原尺寸显示，居中。窗口不够大时多出部分会被裁切（用户可调整窗口）。
        // 这样能精准判断每像素质量，不被浏览器/播放器常见的"双线性缩放"模糊掉。
        const int iw = m_image.width();
        const int ih = m_image.height();
        if (iw <= 0 || ih <= 0) return;
        const QRectF r = boundingRect();
        const double dx = r.x() + (r.width()  - iw) / 2.0;
        const double dy = r.y() + (r.height() - ih) / 2.0;
        painter->drawImage(QRectF(dx, dy, iw, ih), m_image);
    }

    void setImage(const QImage& img) {
        m_image = img;
        update();
        emit imageChanged();
    }

    QImage image() const { return m_image; }

signals:
    void imageChanged();

private:
    QImage m_image;
};
