// YuvSliderCompareItem.cpp — YUV 双路滑动比较渲染组件（QQuickItem + Scene Graph）
//
// 与 YuvDisplayItem 同样的 GPU/CPU 双路径策略：
//   - GPU 路径：两个 QSGGeometryNode + 纹理，GPU 硬件缩放。
//   - CPU 路径（软件后端）：preScale + 纹理上传。

#include "YuvSliderCompareItem.h"
#include <QQuickWindow>
#include <QSGGeometry>
#include <cmath>
#include <algorithm>

YuvSliderCompareItem::YuvSliderCompareItem(QQuickItem* parent)
    : QQuickItem(parent)
{
    setFlag(QQuickItem::ItemHasContents, true);
}

bool YuvSliderCompareItem::isSoftwareBackend() const {
    if (!m_softwareBackendCache.has_value()) {
        if (window()) {
            QSGRendererInterface* ri = window()->rendererInterface();
            m_softwareBackendCache = (ri &&
                ri->graphicsApi() == QSGRendererInterface::Software);
        } else {
            m_softwareBackendCache = false;
        }
    }
    return *m_softwareBackendCache;
}

QImage YuvSliderCompareItem::preScale(const QImage& src, qreal scale) const {
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

void YuvSliderCompareItem::setLeftImage(const QImage& img) {
    m_leftImage = img;
    m_leftDirty = true;
    m_geomDirty = true;
    if (isSoftwareBackend() && !m_leftImage.isNull())
        m_leftScaled = preScale(m_leftImage, m_scale);
    update();
    emit leftImageChanged();
}

void YuvSliderCompareItem::setRightImage(const QImage& img) {
    m_rightImage = img;
    m_rightDirty = true;
    m_geomDirty = true;
    if (isSoftwareBackend() && !m_rightImage.isNull())
        m_rightScaled = preScale(m_rightImage, m_scale);
    update();
    emit rightImageChanged();
}

void YuvSliderCompareItem::setPanX(qreal v) {
    if (qFuzzyCompare(m_panX, v)) return;
    m_panX = v;
    m_geomDirty = true;
    update();
    emit panChanged();
}

void YuvSliderCompareItem::setPanY(qreal v) {
    if (qFuzzyCompare(m_panY, v)) return;
    m_panY = v;
    m_geomDirty = true;
    update();
    emit panChanged();
}

void YuvSliderCompareItem::onGlobalScaleChanged(qreal newScale) {
    if (qFuzzyCompare(m_scale, newScale)) return;
    m_scale = newScale;
    m_geomDirty = true;
    if (isSoftwareBackend()) {
        if (!m_leftImage.isNull()) {
            m_leftScaled = preScale(m_leftImage, m_scale);
            m_leftDirty = true;
        }
        if (!m_rightImage.isNull()) {
            m_rightScaled = preScale(m_rightImage, m_scale);
            m_rightDirty = true;
        }
    }
    update();
    emit scaleChanged();
}

void YuvSliderCompareItem::setSplitRatio(double r) {
    if (r < 0.0) r = 0.0;
    if (r > 1.0) r = 1.0;
    if (qFuzzyCompare(r + 1.0, m_splitRatio + 1.0)) return;
    m_splitRatio = r;
    m_geomDirty = true;
    emit splitRatioChanged();
    update();
}

// 辅助：为一路图像创建/更新 geometry node + texture
static void updateOneSide(QSGGeometryNode*& node, QSGTexture*& tex,
                          const QImage& src, const QImage& scaled,
                          bool software, qreal scale,
                          const QRectF& drawRect,
                          QQuickWindow* win,
                          bool& imgDirty, bool& geomDirty)
{
    const QImage& texSource = software
        ? (scaled.isNull() ? src : scaled)
        : src;
    if (texSource.isNull()) {
        if (node) {
            delete node;
            node = nullptr;
        }
        return;
    }

    if (!node) {
        node = new QSGGeometryNode;
auto* geom = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), 4);
        geom->setDrawingMode(QSGGeometry::DrawTriangleStrip);
        node->setGeometry(geom);
        node->setFlag(QSGNode::OwnsGeometry);
        auto* mat = new QSGTextureMaterial;
        node->setMaterial(mat);
        node->setFlag(QSGNode::OwnsMaterial);
        imgDirty = true;
        geomDirty = true;
    }

    auto* material = static_cast<QSGTextureMaterial*>(node->material());

    if (imgDirty || !tex) {
        if (tex) { delete tex; tex = nullptr; }
        tex = win->createTextureFromImage(texSource);
        if (tex) {
            if (software)
                tex->setFiltering(QSGTexture::Nearest);
            else
                tex->setFiltering((scale >= 1.0) ? QSGTexture::Nearest
                                                 : QSGTexture::Linear);
            material->setTexture(tex);
        }
        imgDirty = false;
    }

    if (geomDirty) {
        const int iw = texSource.width();
        const int ih = texSource.height();
        if (iw <= 0 || ih <= 0) return;
        const qreal drawW = software ? iw : (iw * scale);
        const qreal drawH = software ? ih : (ih * scale);
        auto* v = node->geometry()->vertexDataAsTexturedPoint2D();
        v[0].set(drawRect.x(),                 drawRect.y(),                  0.0f, 0.0f);
        v[1].set(drawRect.x(),                 drawRect.y() + drawRect.height(), 0.0f, 1.0f);
        v[2].set(drawRect.x() + drawRect.width(), drawRect.y(),               1.0f, 0.0f);
        v[3].set(drawRect.x() + drawRect.width(), drawRect.y() + drawRect.height(), 1.0f, 1.0f);
        node->markDirty(QSGNode::DirtyGeometry);
    }
}

QSGNode* YuvSliderCompareItem::updatePaintNode(QSGNode* oldNode, UpdatePaintNodeData*) {
    const bool software = isSoftwareBackend();
    const QRectF r = boundingRect();
    if (r.width() <= 0 || r.height() <= 0) {
        delete oldNode;
        return nullptr;
    }

    // 使用一个根 node 管理左右两个子 node
    QSGNode* root = oldNode;
    if (!root) {
        root = new QSGNode;  // 普通 container node
    }

    // ── 左半区域 ──
    const qreal splitX = r.x() + r.width() * m_splitRatio;
    const QRectF leftRect(r.x(), r.y(), splitX - r.x(), r.height());
    {
        // 安全获取/创建左子节点
        QSGGeometryNode* leftNodePtr = static_cast<QSGGeometryNode*>(root->childAtIndex(0));
        if (!leftNodePtr) {
            leftNodePtr = new QSGGeometryNode;
            root->appendChildNode(leftNodePtr);
        }

        const QImage& texSource = software
            ? (m_leftScaled.isNull() ? m_leftImage : m_leftScaled)
            : m_leftImage;

        if (texSource.isNull()) {
            // 隐藏左侧
            leftNodePtr->markDirty(QSGNode::DirtyForceUpdate);
        } else {
            // 更新纹理
            auto* mat = static_cast<QSGTextureMaterial*>(leftNodePtr->material());
            if (!mat) {
                mat = new QSGTextureMaterial;
                leftNodePtr->setMaterial(mat);
                leftNodePtr->setFlag(QSGNode::OwnsMaterial);
            }
            if (!leftNodePtr->geometry()) {
auto* geom = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), 4);
                geom->setDrawingMode(QSGGeometry::DrawTriangleStrip);
                leftNodePtr->setGeometry(geom);
                leftNodePtr->setFlag(QSGNode::OwnsGeometry);
            }
            if (m_leftDirty || !m_leftTex) {
                if (m_leftTex) { delete m_leftTex; m_leftTex = nullptr; }
                m_leftTex = window()->createTextureFromImage(texSource);
                if (m_leftTex) {
                    m_leftTex->setFiltering(software ? QSGTexture::Nearest
                        : ((m_scale >= 1.0) ? QSGTexture::Nearest : QSGTexture::Linear));
                    mat->setTexture(m_leftTex);
                }
                m_leftDirty = false;
            }
            // 几何
            if (m_geomDirty) {
                const int iw = texSource.width();
                const int ih = texSource.height();
                const qreal drawW = software ? iw : (iw * m_scale);
                const qreal drawH = software ? ih : (ih * m_scale);
                const double dx = r.x() + (r.width() - drawW) / 2.0 + m_panX;
                const double dy = r.y() + (r.height() - drawH) / 2.0 + m_panY;
                auto* v = leftNodePtr->geometry()->vertexDataAsTexturedPoint2D();
                v[0].set(dx,            dy,            0.0f, 0.0f);
                v[1].set(dx,            dy + drawH,    0.0f, 1.0f);
                v[2].set(dx + drawW,    dy,            1.0f, 0.0f);
                v[3].set(dx + drawW,    dy + drawH,    1.0f, 1.0f);
                leftNodePtr->markDirty(QSGNode::DirtyGeometry);
            }
        }
    }

    // ── 右半区域 ──
    {
        QSGGeometryNode* rightNodePtr = static_cast<QSGGeometryNode*>(root->childAtIndex(1));
        if (!rightNodePtr) {
            rightNodePtr = new QSGGeometryNode;
            root->appendChildNode(rightNodePtr);
        }

        const QImage& texSource = software
            ? (m_rightScaled.isNull() ? m_rightImage : m_rightScaled)
            : m_rightImage;

        if (!texSource.isNull()) {
            auto* mat = static_cast<QSGTextureMaterial*>(rightNodePtr->material());
            if (!mat) {
                mat = new QSGTextureMaterial;
                rightNodePtr->setMaterial(mat);
                rightNodePtr->setFlag(QSGNode::OwnsMaterial);
            }
            if (!rightNodePtr->geometry()) {
auto* geom = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), 4);
                geom->setDrawingMode(QSGGeometry::DrawTriangleStrip);
                rightNodePtr->setGeometry(geom);
                rightNodePtr->setFlag(QSGNode::OwnsGeometry);
            }
            if (m_rightDirty || !m_rightTex) {
                if (m_rightTex) { delete m_rightTex; m_rightTex = nullptr; }
                m_rightTex = window()->createTextureFromImage(texSource);
                if (m_rightTex) {
                    m_rightTex->setFiltering(software ? QSGTexture::Nearest
                        : ((m_scale >= 1.0) ? QSGTexture::Nearest : QSGTexture::Linear));
                    mat->setTexture(m_rightTex);
                }
                m_rightDirty = false;
            }
            if (m_geomDirty) {
                const int iw = texSource.width();
                const int ih = texSource.height();
                const qreal drawW = software ? iw : (iw * m_scale);
                const qreal drawH = software ? ih : (ih * m_scale);
                const double dx = r.x() + (r.width() - drawW) / 2.0 + m_panX;
                const double dy = r.y() + (r.height() - drawH) / 2.0 + m_panY;
                auto* v = rightNodePtr->geometry()->vertexDataAsTexturedPoint2D();
                v[0].set(dx,            dy,            0.0f, 0.0f);
                v[1].set(dx,            dy + drawH,    0.0f, 1.0f);
                v[2].set(dx + drawW,    dy,            1.0f, 0.0f);
                v[3].set(dx + drawW,    dy + drawH,    1.0f, 1.0f);
                rightNodePtr->markDirty(QSGNode::DirtyGeometry);
            }
        }
    }

    m_geomDirty = false;
    return root;
}
