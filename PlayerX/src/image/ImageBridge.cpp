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
        QImage img = reader.read();
        if (img.isNull()) continue;

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
        if (img.colorSpace().isValid()) {
            switch (img.colorSpace().colorModel()) {
                case QColorSpace::ColorModel::Rgb:   m["colorSpace"] = "RGB"; break;
                case QColorSpace::ColorModel::Cmyk:  m["colorSpace"] = "CMYK"; break;
                case QColorSpace::ColorModel::Gray:  m["colorSpace"] = "Gray"; break;
                default:                              m["colorSpace"] = "Unknown"; break;
            }
        } else {
            m["colorSpace"] = "sRGB (default)";
        }
#else
        m["colorSpace"] = "—";
#endif
    } else {
        m["bitDepth"] = 0;
        m["hasAlpha"] = false;
        m["colorType"] = "—";
        m["colorSpace"] = "—";
        m["dpiX"] = 72;
        m["dpiY"] = 72;
    }

    // 动图帧数（GIF / animated WebP）
    m["frameCount"] = reader.imageCount();

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
