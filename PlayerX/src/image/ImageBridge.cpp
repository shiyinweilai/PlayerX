/**
 * ImageBridge.cpp — 见 ImageBridge.h
 */
#include "ImageBridge.h"

#include <QImage>
#include <QImageReader>
#include <QColorSpace>
#include <QFileInfo>
#include <QFile>
#include <QDateTime>
#include <QSettings>
#include <QVariantList>
#include <QVariantMap>
#include <QStringList>
#include <cmath>
#include <QDebug>

// ── QSettings 辅助（与 YuvBridge / RBStreamBridge 同款） ──────────
static QSettings& imageSettings() {
    static QSettings s("PlayerX", "ImageBridge");
    return s;
}
static void imageSettingsSync() {
    imageSettings().sync();
}

// ── 格式名 → 中文长名映射 ──────────────────────────────────────────
static QString formatLongName(const QString& fmt) {
    static const QHash<QString, QString> map = {
        {"png",  "PNG (Portable Network Graphics)"},
        {"jpg",  "JPEG (Joint Photographic Experts Group)"},
        {"jpeg", "JPEG (Joint Photographic Experts Group)"},
        {"bmp",  "BMP (Windows Bitmap)"},
        {"webp", "WebP"},
        {"tiff", "TIFF (Tagged Image File Format)"},
        {"tif",  "TIFF (Tagged Image File Format)"},
        {"gif",  "GIF (Graphics Interchange Format)"},
        {"svg",  "SVG (Scalable Vector Graphics)"},
        {"heic", "HEIF/HEIC (High Efficiency Image)"},
        {"heif", "HEIF (High Efficiency Image Format)"},
        {"ico",  "ICO (Windows Icon)"},
        {"tga",  "TGA (Truevision Targa)"},
        {"pcx",  "PCX (Picture Exchange)"},
        {"ppm",  "PPM (Portable PixMap)"},
        {"xbm",  "XBM (X Bitmap)"},
        {"xpm",  "XPM (X PixMap)"},
    };
    return map.value(fmt.toLower(), fmt.toUpper());
}

ImageBridge::ImageBridge(QObject* parent)
    : QObject(parent)
{
}

ImageBridge::~ImageBridge() = default;

// ── 色彩管理：把任意 ICC Profile 的图统一到 sRGB ──────────────────────
//
// 为什么必须做：
//   Qt Quick 的场景图把纹理数据当作**已经是显示色彩空间**的像素直接上屏，
//   不做任何 ICC 转换。而 macOS 预览 / Quick Look 走 ColorSync，会把图片的
//   源色彩空间（Display P3、Adobe RGB、ProPhoto…）正确映射到显示器空间。
//   两者对比就会看到：颜色饱和度/色相偏移（尤其是蓝色、红色大字），
//   以及文字边缘抗锯齿灰阶被整体偏移导致的"发虚"观感。
//
// 处理策略：
//   1) 有有效 ICC Profile 且不是 sRGB → 转换到 sRGB
//   2) 无 ICC Profile → 按 Web/行业惯例视为 sRGB，不动
//   3) 灰度/CMYK 先转成 RGB 再处理
//   4) 统一输出 Format_ARGB32_Premultiplied，避免后续缩放时反复转格式
QImage ImageBridge::normalizeColorSpace(const QImage& src) {
    if (src.isNull()) return src;

    QImage img = src;

    // CMYK / 索引色 / 灰度等先规整到 32 位 RGB，QColorSpace 转换要求 RGB 模型
    switch (img.format()) {
        case QImage::Format_ARGB32_Premultiplied:
        case QImage::Format_ARGB32:
        case QImage::Format_RGB32:
        case QImage::Format_RGBX8888:
        case QImage::Format_RGBA8888:
        case QImage::Format_RGBA8888_Premultiplied:
            break;
        default:
            img = img.convertToFormat(QImage::Format_ARGB32_Premultiplied);
            break;
    }

    const QColorSpace cs = img.colorSpace();
    const QColorSpace srgb = QColorSpace(QColorSpace::SRgb);

    if (cs.isValid() && cs != srgb) {
        // 关键一步：按源 Profile 正确映射到 sRGB
        img.convertToColorSpace(srgb);
    } else if (!cs.isValid()) {
        // 无 Profile：按行业惯例标记为 sRGB（只打标签，不改像素）
        img.setColorSpace(srgb);
    }

    if (img.format() != QImage::Format_ARGB32_Premultiplied)
        img = img.convertToFormat(QImage::Format_ARGB32_Premultiplied);

    return img;
}

// ── 多 slot 容器 ────────────────────────────────────────────────────

int ImageBridge::openFiles(const QVariantList& files) {
    // 先清空旧的
    closeAll();

    int opened = 0;
    for (const QVariant& v : files) {
        QString path = v.toString();
        if (path.startsWith("file://")) {
            path = QUrl(path).toLocalFile();
        }
        path = path.replace('\\', '/');
        if (path.isEmpty()) continue;

        if (opened >= MaxSlots) break;

        QImageReader reader(path);
        reader.setAutoDetectImageFormat(true);
        // EXIF 方向自动校正（手机拍摄的图片常带 Orientation tag，
        // 系统预览会自动应用；不处理会导致显示方向错误）
        reader.setAutoTransform(true);
        QImage img = reader.read();
        if (img.isNull()) continue;

        // ── 色彩管理（关键）──────────────────────────────────────────
        // 很多 PNG/JPEG 内嵌 ICC Profile（Display P3、Adobe RGB 等）。
        // 若不做转换而把原始像素当 sRGB 直接上屏，颜色会明显偏移，
        // 且文字抗锯齿灰阶被整体偏移后对比度下降、主观锐度变差。
        // macOS 预览通过 ColorSync 做这一步，这里用 QColorSpace 对齐。
        img = normalizeColorSpace(img);

        m_slots[opened].inUse = true;
        m_slots[opened].path  = path;
        m_slots[opened].img   = img;
        m_slots[opened].info  = probePath(path);
        ++opened;
    }

    m_slotCount = opened;
    emit slotCountChanged();
    for (int i = 0; i < opened; ++i)
        emit fileOpened(i);
    return opened;
}

// 追加文件到已有 slot（不关闭已打开的），返回实际新增数量
int ImageBridge::addFiles(const QVariantList& files) {
    int added = 0;
    int firstNewSlot = -1;

    for (const QVariant& v : files) {
        if (m_slotCount >= MaxSlots) break;

        QString path = v.toString();
        if (path.startsWith("file://")) {
            path = QUrl(path).toLocalFile();
        }
        path = path.replace('\\', '/');
        if (path.isEmpty()) continue;

        // 跳过已打开的重复文件
        bool dup = false;
        for (int i = 0; i < m_slotCount; ++i) {
            if (m_slots[i].path == path) { dup = true; break; }
        }
        if (dup) continue;

        QImageReader reader(path);
        reader.setAutoDetectImageFormat(true);
        reader.setAutoTransform(true);
        QImage img = reader.read();
        if (img.isNull()) continue;

        img = normalizeColorSpace(img);

        int slot = m_slotCount;
        m_slots[slot].inUse = true;
        m_slots[slot].path  = path;
        m_slots[slot].img   = img;
        m_slots[slot].info  = probePath(path);
        ++m_slotCount;
        ++added;
        if (firstNewSlot < 0) firstNewSlot = slot;
        emit fileOpened(slot);
    }

    if (added > 0) emit slotCountChanged();
    return added;
}

void ImageBridge::closeSlot(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_slots[slot].inUse) return;

    m_slots[slot].inUse = false;
    m_slots[slot].path.clear();
    m_slots[slot].img = QImage();
    m_slots[slot].info.clear();
    emit fileClosed(slot);

    // 紧凑化：把后面的 slot 前移
    for (int i = slot; i < MaxSlots - 1; ++i) {
        if (m_slots[i + 1].inUse) {
            m_slots[i] = std::move(m_slots[i + 1]);
            m_slots[i + 1].inUse = false;
            m_slots[i + 1].path.clear();
            m_slots[i + 1].img = QImage();
            m_slots[i + 1].info.clear();
        }
    }
    --m_slotCount;
    emit slotCountChanged();
}

void ImageBridge::closeAll() {
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_slots[i].inUse) emit fileClosed(i);
        m_slots[i].inUse = false;
        m_slots[i].path.clear();
        m_slots[i].img = QImage();
        m_slots[i].info.clear();
    }
    m_slotCount = 0;
    emit slotCountChanged();
}

// ── 单 slot 基础信息 ────────────────────────────────────────────────

bool ImageBridge::hasFile(int slot) const {
    return slot >= 0 && slot < MaxSlots && m_slots[slot].inUse;
}

QString ImageBridge::filePath(int slot) const {
    if (!hasFile(slot)) return {};
    return m_slots[slot].path;
}

QString ImageBridge::fileName(int slot) const {
    if (!hasFile(slot)) return {};
    return QFileInfo(m_slots[slot].path).fileName();
}

// ── 像素级统计 ──────────────────────────────────────────────────────

QVariantMap ImageBridge::pixelStats(int slot) const {
    QVariantMap result;
    qDebug() << "[pixelStats] called slot=" << slot << "hasFile=" << hasFile(slot);
    if (!hasFile(slot)) return result;

    const QImage img = m_slots[slot].img;
    qDebug() << "[pixelStats] img.isNull=" << img.isNull() << "size=" << img.size() << "format=" << img.format();
    if (img.isNull()) return result;

    // 转为 RGB32（不带 alpha 的计算更简单）
    const QImage rgb = img.format() == QImage::Format_ARGB32_Premultiplied
                        ? img.convertToFormat(QImage::Format_RGB32)
                        : (img.format() == QImage::Format_RGB32 ? img : img.convertToFormat(QImage::Format_RGB32));
    const bool hasAlpha = img.hasAlphaChannel();

    const int w = rgb.width();
    const int h = rgb.height();
    const int totalPixels = w * h;
    if (totalPixels <= 0) return result;

    // 256 bin 直方图
    int histR[256] = {}, histG[256] = {}, histB[256] = {}, histLum[256] = {};
    double sumR = 0, sumG = 0, sumB = 0, sumLum = 0;
    double sumR2 = 0, sumG2 = 0, sumB2 = 0;
    int minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0;
    int alphaPixels = 0;

    // 大图采样：超过 1M 像素则步长采样，保证 <50ms
    const int step = totalPixels > 1000000 ? (totalPixels / 1000000 + 1) : 1;
    int sampledPixels = 0;

    for (int y = 0; y < h; ++y) {
        const QRgb* line = reinterpret_cast<const QRgb*>(rgb.constScanLine(y));
        for (int x = 0; x < w; x += step) {
            const QRgb px = line[x];
            const int r = qRed(px);
            const int g = qGreen(px);
            const int b = qBlue(px);
            // BT.601 亮度
            const int lum = (r * 299 + g * 587 + b * 114) / 1000;

            histR[r]++; histG[g]++; histB[b]++; histLum[lum]++;
            sumR += r; sumG += g; sumB += b; sumLum += lum;
            sumR2 += (double)r * r; sumG2 += (double)g * g; sumB2 += (double)b * b;
            if (r < minR) minR = r; if (r > maxR) maxR = r;
            if (g < minG) minG = g; if (g > maxG) maxG = g;
            if (b < minB) minB = b; if (b > maxB) maxB = b;
            ++sampledPixels;
        }
    }

    // Alpha 统计（从原图）
    if (hasAlpha) {
        for (int y = 0; y < h; ++y) {
            const QRgb* line = reinterpret_cast<const QRgb*>(img.constScanLine(y));
            for (int x = 0; x < w; ++x) {
                if (qAlpha(line[x]) < 255) ++alphaPixels;
            }
        }
    }

    const double n = sampledPixels;
    const double meanR = sumR / n, meanG = sumG / n, meanB = sumB / n;
    const double meanLum = sumLum / n;
    const double varR = sumR2 / n - meanR * meanR;
    const double varG = sumG2 / n - meanG * meanG;
    const double varB = sumB2 / n - meanB * meanB;

    // 转 QVariantList
    QVariantList vR, vG, vB, vL;
    for (int i = 0; i < 256; ++i) {
        vR << histR[i]; vG << histG[i]; vB << histB[i]; vL << histLum[i];
    }

    result["histR"] = vR;
    result["histG"] = vG;
    result["histB"] = vB;
    result["histLum"] = vL;
    result["meanR"] = qRound(meanR);
    result["meanG"] = qRound(meanG);
    result["meanB"] = qRound(meanB);
    result["meanLum"] = qRound(meanLum);
    result["minR"] = minR; result["maxR"] = maxR;
    result["minG"] = minG; result["maxG"] = maxG;
    result["minB"] = minB; result["maxB"] = maxB;
    result["stdR"] = qRound(std::sqrt(qMax(0.0, varR)));
    result["stdG"] = qRound(std::sqrt(qMax(0.0, varG)));
    result["stdB"] = qRound(std::sqrt(qMax(0.0, varB)));
    result["alphaRatio"] = hasAlpha ? (double)alphaPixels / totalPixels : 0.0;
    result["sampled"] = sampledPixels;
    result["total"] = totalPixels;

    qDebug() << "[pixelStats] done: meanR=" << result["meanR"] << "meanLum=" << result["meanLum"]
             << "histR count=" << vR.size() << "sampled=" << sampledPixels;
    return result;
}

// ── 图片元信息 ──────────────────────────────────────────────────────

QVariantMap ImageBridge::imageInfo(int slot) const {
    if (!hasFile(slot)) return {};
    return m_slots[slot].info;
}

QImage ImageBridge::image(int slot) const {
    if (!hasFile(slot)) return {};
    return m_slots[slot].img;
}

// ── 轻量探测 ────────────────────────────────────────────────────────

QVariantMap ImageBridge::probeFile(const QString& path) const {
    return probePath(path);
}

QVariantMap ImageBridge::probePath(const QString& path) const {
    QVariantMap m;
    QFileInfo fi(path);
    m["fileName"] = fi.fileName();
    m["filePath"] = fi.absoluteFilePath();

    if (!fi.exists() || !fi.isFile()) return m;

    m["fileSize"] = (qint64)fi.size();
    m["fileModified"] = fi.lastModified().toString("yyyy-MM-dd HH:mm:ss");

    QImageReader reader(path);
    reader.setAutoDetectImageFormat(true);

    const QSize size = reader.size();
    m["width"]  = size.width();
    m["height"] = size.height();

    const QString fmt = reader.format().toLower();
    m["format"] = fmt;
    m["formatLong"] = formatLongName(fmt);

    // 位深：QImage::depth() 返回每像素位数
    // 先读图拿 depth（部分格式 QImageReader 不直接暴露位深）
    QImage img = reader.read();
    if (!img.isNull()) {
        m["bitDepth"] = img.depth();
        m["hasAlpha"] = img.hasAlphaChannel();

        // 色彩空间
        switch (img.format()) {
            case QImage::Format_RGB32:
            case QImage::Format_ARGB32:
            case QImage::Format_RGBX8888:
            case QImage::Format_RGBA8888:
                m["colorType"] = "RGB"; break;
            case QImage::Format_Grayscale8:
            case QImage::Format_Grayscale16:
                m["colorType"] = "Grayscale"; break;
            case QImage::Format_Indexed8:
                m["colorType"] = "Indexed"; break;
            default:
                m["colorType"] = "RGB"; break;
        }

        // DPI
        const qreal dprX = img.physicalDpiX();
        const qreal dprY = img.physicalDpiY();
        m["dpiX"] = dprX > 0 ? dprX : 72;
        m["dpiY"] = dprY > 0 ? dprY : 72;

        // 色彩空间（ICC profile / sRGB 等）
        // Qt6: QImage::colorSpace() 返回 QColorSpace
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        const QColorSpace cs = img.colorSpace();
        if (cs.isValid()) {
            switch (cs.colorModel()) {
                case QColorSpace::ColorModel::Rgb:   m["colorSpace"] = "RGB"; break;
                case QColorSpace::ColorModel::Cmyk:  m["colorSpace"] = "CMYK"; break;
                case QColorSpace::ColorModel::Gray:  m["colorSpace"] = "Gray"; break;
                default:                              m["colorSpace"] = "Unknown"; break;
            }

            // ── ICC Profile 详细信息 ──
            // 用 primaries + transferFunction 推断命名色彩空间
            const QColorSpace::Primaries prim = cs.primaries();
            const QColorSpace::TransferFunction tf = cs.transferFunction();
            const QByteArray iccData = cs.iccProfile();
            m["hasICC"] = !iccData.isEmpty();

            QString profileName;
            if (prim == QColorSpace::Primaries::SRgb && tf == QColorSpace::TransferFunction::SRgb)
                profileName = "sRGB IEC61966-2.1";
            else if (prim == QColorSpace::Primaries::SRgb && tf == QColorSpace::TransferFunction::Linear)
                profileName = "sRGB Linear";
            else if (prim == QColorSpace::Primaries::AdobeRgb)
                profileName = "Adobe RGB (1998)";
            else if (prim == QColorSpace::Primaries::DciP3D65)
                profileName = "Display P3";
            else if (prim == QColorSpace::Primaries::ProPhotoRgb)
                profileName = "ProPhoto RGB";
            else if (prim == QColorSpace::Primaries::Bt2020)
                profileName = "BT.2020";
            else {
                // 未命名但有效 → 尝试 description，否则标注自定义
                QString desc = cs.description();
                profileName = desc.isEmpty() ? "Custom ICC Profile" : desc;
            }
            m["iccProfile"] = profileName;

            // ICC 数据大小（字节）
            if (!iccData.isEmpty())
                m["iccSize"] = (int)iccData.size();

            // 白点
            const QPointF whitePt = cs.whitePoint();
            m["whitePoint"] = QString("x=%1 y=%2")
                                  .arg(whitePt.x(), 0, 'f', 4)
                                  .arg(whitePt.y(), 0, 'f', 4);

            // gamma / 传输函数
            if (tf == QColorSpace::TransferFunction::Gamma) {
                m["gamma"] = QString::number(cs.gamma(), 'f', 2);
            } else {
                QString tfName;
                switch (tf) {
                    case QColorSpace::TransferFunction::Linear:      tfName = "Linear"; break;
                    case QColorSpace::TransferFunction::SRgb:        tfName = "sRGB EOTF"; break;
                    case QColorSpace::TransferFunction::ProPhotoRgb: tfName = "ProPhoto"; break;
                    case QColorSpace::TransferFunction::Bt2020:      tfName = "BT.2020"; break;
                    case QColorSpace::TransferFunction::St2084:      tfName = "ST.2084 (PQ)"; break;
                    case QColorSpace::TransferFunction::Hlg:         tfName = "HLG"; break;
                    default:                                         tfName = "Custom"; break;
                }
                m["gamma"] = tfName;
            }

            // 原色信息（Primaries）
            QString primName;
            switch (prim) {
                case QColorSpace::Primaries::SRgb:        primName = "sRGB / BT.709"; break;
                case QColorSpace::Primaries::AdobeRgb:    primName = "Adobe RGB"; break;
                case QColorSpace::Primaries::DciP3D65:    primName = "DCI-P3 D65"; break;
                case QColorSpace::Primaries::ProPhotoRgb: primName = "ProPhoto RGB"; break;
                case QColorSpace::Primaries::Bt2020:      primName = "BT.2020"; break;
                default:                                  primName = "Custom"; break;
            }
            m["primaries"] = primName;
        } else {
            m["colorSpace"] = "sRGB (default)";
            m["iccProfile"] = "无 (按 sRGB 惯例)";
            m["hasICC"] = false;
            m["whitePoint"] = "—";
            m["gamma"] = "—";
            m["primaries"] = "—";
        }
#else
        m["colorSpace"] = "—";
        m["iccProfile"] = "—";
        m["hasICC"] = false;
        m["whitePoint"] = "—";
        m["gamma"] = "—";
#endif
    } else {
        m["bitDepth"] = 0;
        m["hasAlpha"] = false;
        m["colorType"] = "—";
        m["colorSpace"] = "—";
        m["iccProfile"] = "—";
        m["hasICC"] = false;
        m["whitePoint"] = "—";
        m["gamma"] = "—";
        m["primaries"] = "—";
        m["dpiX"] = 72;
        m["dpiY"] = 72;
    }

    // 动图帧数（GIF / animated WebP）
    m["frameCount"] = reader.imageCount();

    // ── EXIF 方向（手机拍摄图片常带 Orientation tag）──
    // QImageReader 在 setAutoTransform(true) 时会自动应用方向，
    // 这里报告原始 EXIF orientation 值（1=正常，3=180°，6=90°CW，8=90°CCW…）
    // 注意：probePath 未调用 setAutoTransform，所以读出的图是原始方向
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    const int exifOrientation = reader.transformation();
    m["exifOrientation"] = exifOrientation;
    static const QStringList orientNames = {
        "正常 (1)",         // 0 → None
        "镜像水平 (2)",     // 1 → Flip
        "180° (3)",         // 2 → Rotate180
        "镜像垂直 (4)",     // 3 → Rotate180 + Flip
        "镜像水平+270° (5)",// 4 → Transpose
        "90° CW (6)",       // 5 → Rotate90
        "镜像水平+90° (7)", // 6 → Transverse
        "90° CCW (8)"       // 7 → Rotate270
    };
    if (exifOrientation >= 0 && exifOrientation < orientNames.size())
        m["exifOrientationDesc"] = orientNames[exifOrientation];
    else
        m["exifOrientationDesc"] = "正常 (1)";
#else
    m["exifOrientation"] = 0;
    m["exifOrientationDesc"] = "—";
#endif

    // ── 色彩范围（图片场景通常为 Full Range）──
    // 图片不像视频有 limited/full range 之分，但 ICC 色彩空间转换后
    // 像素均为 full range。此处提供信息给用户。
    m["colorRange"] = "Full Range";

    // ── 像素总数量与宽高比 ──
    const int w = m.value("width").toInt();
    const int h = m.value("height").toInt();
    if (w > 0 && h > 0) {
        m["pixelCount"] = w * h;
        // 约分宽高比
        int gcd = [] (int a, int b) -> int { while (b) { int t = a % b; a = b; b = t; } return a; }(w, h);
        m["aspectRatio"] = QString("%1:%2").arg(w / gcd).arg(h / gcd);
    }

    return m;
}

// ── 文件列表持久化 ──────────────────────────────────────────────────

QStringList ImageBridge::imageFileList() const {
    return imageSettings().value("image_presets/fileList").toStringList();
}

void ImageBridge::setImageFileList(const QVariantList& files) {
    QStringList list;
    for (const QVariant& v : files) {
        list << v.toString();
    }
    imageSettings().setValue("image_presets/fileList", list);
    imageSettingsSync();
}

// ── "上次打开"位置持久化 ────────────────────────────────────────────

QString ImageBridge::lastOpenedFolder() const {
    return imageSettings().value("image_presets/lastFolder").toString();
}

void ImageBridge::setLastOpenedFolder(const QString& folder) {
    imageSettings().setValue("image_presets/lastFolder", folder);
    imageSettingsSync();
}
