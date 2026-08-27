#pragma once
/**
 * YuvSliderCompareItem.h — YUV 双路滑动比较渲染组件（QQuickItem + Scene Graph）
 *
 * Phase 2 优化：从 QQuickPaintedItem 改为 QQuickItem + QSGGeometryNode。
 * 与 YuvDisplayItem 同样的 GPU/CPU 双路径策略。
 *
 * paint 逻辑：按 splitRatio 把画面切成左右两半，各画一路图像。
 *   - GPU 路径：两个 QSGGeometryNode（各一个纹理），各自裁剪。
 *   - CPU 路径（软件后端）：preScale + 纹理上传，与原实现等价。
 */

#include <QQuickItem>
#include <QImage>
#include <QSGGeometryNode>
#include <QSGTextureMaterial>
#include <QSGTexture>
#include <optional>

class YuvSliderCompareItem : public QQuickItem {
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
    QSGNode* updatePaintNode(QSGNode* oldNode, UpdatePaintNodeData* data) override;

private:
    QImage preScale(const QImage& src, qreal scale) const;
    bool isSoftwareBackend() const;

    QImage m_leftImage;
    QImage m_rightImage;
    QImage m_leftScaled;    // CPU 路径
    QImage m_rightScaled;   // CPU 路径
    qreal  m_panX = 0;
    qreal  m_panY = 0;
    qreal  m_scale = 1.0;
    double m_splitRatio = 0.5;

    QSGTexture* m_leftTex = nullptr;
    QSGTexture* m_rightTex = nullptr;
    bool m_leftDirty = true;
    bool m_rightDirty = true;
    bool m_geomDirty = true;
    mutable std::optional<bool> m_softwareBackendCache;
};
