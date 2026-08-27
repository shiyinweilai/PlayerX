// YuvDisplayItem.cpp — YUV 画面渲染组件（QQuickItem + Scene Graph）
//
// Phase 2 优化实现：
//   - GPU 路径：QSGGeometryNode + QSGTextureMaterial，上传原始 RGBA 纹理，
//     GPU 硬件缩放（GL_NEAREST 放大 / GL_LINEAR+Mipmap 缩小），省掉 CPU preScale。
//   - CPU 路径（软件后端 / 无 GPU）：preScale 预缩放 + 纹理上传，
//     保留与原 QQuickPaintedItem 等价的渲染质量。
//
// MOC 桩：YuvDisplayItem 实现在此 .cpp 中，AUTOMOC 生成 meta object 代码。

#include "YuvDisplayItem.h"
#include <QQuickWindow>
#include <QSGGeometry>
#include <QSGSimpleRectNode>
#include <cmath>
#include <algorithm>
#include <cstring>

YuvDisplayItem::YuvDisplayItem(QQuickItem* parent)
    : QQuickItem(parent)
{
    setFlag(QQuickItem::ItemHasContents, true);
}

bool YuvDisplayItem::isSoftwareBackend() const {
    if (!m_softwareBackendCache.has_value()) {
        if (window()) {
            QSGRendererInterface* ri = window()->rendererInterface();
            m_softwareBackendCache = (ri &&
                ri->graphicsApi() == QSGRendererInterface::Software);
        } else {
            m_softwareBackendCache = false;  // 窗口未就绪，先假设 GPU
        }
    }
    return *m_softwareBackendCache;
}

QImage YuvDisplayItem::preScale(const QImage& src, qreal scale) const {
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
            // 水平放大：每个源像素 → n 个目标像素（memcpy 4 字节，避免 pixel() 深拷贝）
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

void YuvDisplayItem::setImage(const QImage& img) {
    m_image = img;
    m_imageDirty = true;
    m_geometryDirty = true;
    update();
    emit imageChanged();
}

void YuvDisplayItem::setPanX(qreal v) {
    if (qFuzzyCompare(m_panX, v)) return;
    m_panX = v;
    m_geometryDirty = true;
    update();
    emit panChanged();
}

void YuvDisplayItem::setPanY(qreal v) {
    if (qFuzzyCompare(m_panY, v)) return;
    m_panY = v;
    m_geometryDirty = true;
    update();
    emit panChanged();
}

void YuvDisplayItem::onGlobalScaleChanged(qreal newScale) {
    if (qFuzzyCompare(m_scale, newScale)) return;
    m_scale = newScale;
    for (int i = 0; i < 7; ++i) {
        if (qFuzzyCompare(kScaleValues[i], newScale)) {
            m_currentScaleIndex = i;
            break;
        }
    }
    m_geometryDirty = true;
    // CPU 路径需要重做 preScale；GPU 路径只需重算几何（缩放由 GPU 做）。
    if (isSoftwareBackend() && !m_image.isNull()) {
        m_scaledForCPU = preScale(m_image, m_scale);
        m_imageDirty = true;
    }
    update();
    emit scaleChanged();
}

QSGNode* YuvDisplayItem::updatePaintNode(QSGNode* oldNode, UpdatePaintNodeData*) {
    const bool software = isSoftwareBackend();

    // ── 确定实际要上传的纹理图像 ──
    // GPU 路径：上传原始分辨率 m_image（GPU 做缩放，省掉 CPU preScale 30-50ms/帧）
    // CPU 路径：上传 preScale 后的 m_scaledForCPU（与原 QQuickPaintedItem 等价）
    const QImage& texSource = software
        ? (m_scaledForCPU.isNull() ? m_image : m_scaledForCPU)
        : m_image;

    if (texSource.isNull()) {
        delete oldNode;
        return nullptr;
    }

    // ── 创建或更新纹理 ──
    QSGGeometryNode* node = static_cast<QSGGeometryNode*>(oldNode);
    QSGTextureMaterial* material = nullptr;
    QSGGeometry* geometry = nullptr;

    if (!node) {
        node = new QSGGeometryNode;
        geometry = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), 4);
        geometry->setDrawingMode(QSGGeometry::DrawTriangleStrip);
        node->setGeometry(geometry);
        node->setFlag(QSGNode::OwnsGeometry);

        material = new QSGTextureMaterial;
        node->setMaterial(material);
        node->setFlag(QSGNode::OwnsMaterial);

        m_texture = nullptr;
        m_imageDirty = true;
        m_geometryDirty = true;
    } else {
        geometry = node->geometry();
        material = static_cast<QSGTextureMaterial*>(node->material());
    }

    // ── 更新纹理（仅在图像内容变更时）──
    if (m_imageDirty || !m_texture) {
        if (m_texture) {
            delete m_texture;
            m_texture = nullptr;
        }
        m_texture = window()->createTextureFromImage(texSource);
        if (m_texture) {
            // 放大用 nearest（零插值，严格物理像素）；缩小用 linear（平滑）
            if (software) {
                // 软件后端：纹理已经是 preScale 后的尺寸，1:1 贴图即可
                m_texture->setFiltering(QSGTexture::Nearest);
            } else {
                m_texture->setFiltering(
                    (m_scale >= 1.0)
                        ? QSGTexture::Nearest   // 放大：GL_NEAREST
                        : QSGTexture::Linear);  // 缩小：GL_LINEAR
            }
            material->setTexture(m_texture);
        }
        m_imageDirty = false;
    }

    // ── 更新几何顶点（在图像/缩放/平移/尺寸变更时）──
    if (m_geometryDirty) {
        const QRectF r = boundingRect();
        const int iw = texSource.width();
        const int ih = texSource.height();
        if (iw <= 0 || ih <= 0) {
            m_geometryDirty = false;
            return node;
        }

        // GPU 路径：顶点坐标 = 原始图像尺寸 × scale（GPU 纹理采样自动缩放）
        // CPU 路径：顶点坐标 = preScale 后的尺寸（纹理已是目标尺寸，1:1 贴图）
        const qreal drawW = software ? iw : (iw * m_scale);
        const qreal drawH = software ? ih : (ih * m_scale);

        const double dx = r.x() + (r.width()  - drawW) / 2.0 + m_panX;
        const double dy = r.y() + (r.height() - drawH) / 2.0 + m_panY;

        QSGGeometry::TexturedPoint2D* v = geometry->vertexDataAsTexturedPoint2D();
        v[0].set(dx,            dy,            0.0f, 0.0f);  // 左上
        v[1].set(dx,            dy + drawH,    0.0f, 1.0f);  // 左下
        v[2].set(dx + drawW,    dy,            1.0f, 0.0f);  // 右上
        v[3].set(dx + drawW,    dy + drawH,    1.0f, 1.0f);  // 右下

        node->markDirty(QSGNode::DirtyGeometry);
        m_geometryDirty = false;
    }

    return node;
}
