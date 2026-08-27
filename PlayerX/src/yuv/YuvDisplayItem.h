#pragma once
/**
 * YuvDisplayItem.h — YUV 画面渲染组件（QQuickItem + Scene Graph）
 *
 * Phase 2 优化：从 QQuickPaintedItem 改为 QQuickItem + QSGGeometryNode +
 * QSGTextureMaterial，实现 GPU 硬件加速渲染。
 *
 * 双路径策略（自动适配有无 GPU）：
 *   - GPU 路径（硬件后端）：上传原始分辨率 RGBA 纹理，GPU 负责缩放，
 *     彻底消除 CPU preScale（4K 省掉 30-50ms/帧）。
 *       缩放 > 1（放大）：GL_NEAREST，零插值，等价于 CPU nearest-neighbor。
 *       缩放 < 1（缩小）：GL_LINEAR + Mipmap，质量可接受。
 *       缩放 = 1（1:1）：GL_NEAREST，精确像素映射。
 *   - CPU 路径（软件后端 / 无 GPU）：保留 preScale 预缩放 + 纹理上传，
 *     行为与原 QQuickPaintedItem 等价，保证无 GPU 机器正常工作。
 *
 * 渲染质量约束（用户长期要求）：
 *   放大时严格 nearest-neighbor（GPU GL_NEAREST 与 CPU 逐像素复制结果一致），
 *   不接受任何导致原图模糊的双线性/多级插值。
 */

#include <QQuickItem>
#include <QImage>
#include <QSGGeometryNode>
#include <QSGTextureMaterial>
#include <QSGTexture>
#include <optional>

class YuvDisplayItem : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QImage image READ image WRITE setImage NOTIFY imageChanged)
    Q_PROPERTY(qreal panX READ panX WRITE setPanX NOTIFY panChanged)
    Q_PROPERTY(qreal panY READ panY WRITE setPanY NOTIFY panChanged)
    Q_PROPERTY(qreal scale READ scale NOTIFY scaleChanged)
    Q_PROPERTY(int currentScaleIndex READ currentScaleIndex NOTIFY scaleChanged)

public:
    explicit YuvDisplayItem(QQuickItem* parent = nullptr);

    void setImage(const QImage& img);
    QImage image() const { return m_image; }

    qreal panX() const { return m_panX; }
    void setPanX(qreal v);
    qreal panY() const { return m_panY; }
    void setPanY(qreal v);

    qreal scale() const { return m_scale; }
    int currentScaleIndex() const { return m_currentScaleIndex; }

    // 由 YuvBridge.globalScaleChanged 驱动：更新内部 m_scale / m_currentScaleIndex
    // 并标记需要重算几何（GPU）或重做 preScale+纹理（CPU）。
    Q_INVOKABLE void onGlobalScaleChanged(qreal newScale);

signals:
    void imageChanged();
    void panChanged();
    void scaleChanged();

protected:
    QSGNode* updatePaintNode(QSGNode* oldNode, UpdatePaintNodeData* data) override;

private:
    // 缩放档位常量（与 YuvBridge::kScaleValues 严格一致）
    static constexpr qreal kScaleValues[7] = {0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0};

    // 检测当前 Scene Graph 后端是否为软件渲染（无 GPU）
    bool isSoftwareBackend() const;

    // CPU 路径专用：preScale 预缩放（与原 QQuickPaintedItem 实现一致）
    //   - 缩放 = 1   → 原图
    //   - 缩放 < 1   → Qt::SmoothTransformation（双三次插值）
    //   - 缩放 > 1   → 整数倍 nearest-neighbor；非整数退回 SmoothTransformation
    QImage preScale(const QImage& src, qreal scale) const;

    QImage m_image;            // 源图（原始物理尺寸，来自 YuvBridge）
    QImage m_scaledForCPU;     // CPU 路径：preScale 后的预缩放图
    qreal  m_panX = 0;
    qreal  m_panY = 0;
    qreal  m_scale = 1.0;
    int    m_currentScaleIndex = 3;

    QSGTexture* m_texture = nullptr;
    bool m_imageDirty   = true;   // 图像内容变更 → 需重建纹理
    bool m_geometryDirty = true;  // 位置/尺寸/缩放变更 → 需重算顶点
    mutable std::optional<bool> m_softwareBackendCache;
};
