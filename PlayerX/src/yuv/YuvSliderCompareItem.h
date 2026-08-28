#pragma once
/**
 * YuvSliderCompareItem.h — YUV 双路滑动比较渲染组件（QQuickPaintedItem + QPainter）
 *
 * 与播放对比的 SliderCompareItem 采用相同渲染策略：
 *   - QQuickPaintedItem + FramebufferObject 渲染目标
 *   - QPainter drawImage(srcRect, dstRect) 精确裁剪左右两路
 *   - 中间 1 物理像素白色分割线
 *   - CPU preScale 保证画质（与 YuvDisplayItem 一致）：
 *     放大 → nearest-neighbor，缩小 → SmoothTransformation
 *
 * 替代原 QQuickItem + Scene Graph 方案（纹理坐标裁剪不可靠且无分割线）。
 */

#include <QQuickPaintedItem>
#include <QImage>

class YuvSliderCompareItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QImage leftImage READ leftImage WRITE setLeftImage NOTIFY leftImageChanged)
    Q_PROPERTY(QImage rightImage READ rightImage WRITE setRightImage NOTIFY rightImageChanged)
    Q_PROPERTY(qreal panX READ panX WRITE setPanX NOTIFY panChanged)
    Q_PROPERTY(qreal panY READ panY WRITE setPanY NOTIFY panChanged)
    Q_PROPERTY(qreal scale READ scale NOTIFY scaleChanged)
    Q_PROPERTY(double splitRatio READ splitRatio WRITE setSplitRatio NOTIFY splitRatioChanged)

public:
    explicit YuvSliderCompareItem(QQuickItem* parent = nullptr);

    QImage leftImage() const { return m_leftImage; }
    void setLeftImage(const QImage& img);
    QImage rightImage() const { return m_rightImage; }
    void setRightImage(const QImage& img);

    qreal panX() const { return m_panX; }
    void setPanX(qreal v);
    qreal panY() const { return m_panY; }
    void setPanY(qreal v);

    qreal scale() const { return m_scale; }
    Q_INVOKABLE void onGlobalScaleChanged(qreal newScale);

    double splitRatio() const { return m_splitRatio; }
    void setSplitRatio(double r);

signals:
    void leftImageChanged();
    void rightImageChanged();
    void panChanged();
    void scaleChanged();
    void splitRatioChanged();

protected:
    void paint(QPainter* painter) override;

private:
    QImage preScale(const QImage& src, qreal scale) const;

    QImage m_leftImage;
    QImage m_rightImage;
    QImage m_leftScaled;    // preScale(总缩放=fit-to-view×m_scale) 后的左路图
    QImage m_rightScaled;   // preScale 后的右路图
    qreal  m_panX = 0;
    qreal  m_panY = 0;
    qreal  m_scale = 1.0;
    double m_splitRatio = 0.5;

    // paint 缓存：避免每帧重做 preScale
    qreal m_cachedTotalScaleL = -1.0;
    qreal m_cachedTotalScaleR = -1.0;
    int   m_cachedAreaW = 0;
    int   m_cachedAreaH = 0;
    bool  m_needRescale = true;
};
