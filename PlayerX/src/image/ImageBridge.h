#pragma once
/**
 * ImageBridge.h — 图片分析模块的 Qt/QML 桥接层（多 slot 版本）
 *
 * 设计目标（与 YuvBridge / RBStreamBridge 结构一致）：
 *   - 多 slot（最多 9 路），每路独立管理一张图片
 *   - 提供 Q_INVOKABLE 接口给 QML，QML 不感知 QImage 细节
 *   - 图片元信息（宽高、格式、位深、文件大小等）通过 QVariantMap 暴露
 *   - 支持 2 路滑动对比模式
 *
 * 与 YuvBridge 的差异：
 *   - 不需要帧导航 / 播放（图片是静态的）
 *   - 不需要色度插值 / 颜色转换（直接用 QImage 加载）
 *   - 图片信息通过 QImageReader 获取（格式、尺寸、位深）
 */

#include <QObject>
#include <QImage>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVariantMap>
#include <QSettings>
#include <memory>

class ImageBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(int slotCount READ slotCount NOTIFY slotCountChanged)
    Q_PROPERTY(int maxSlots READ maxSlots CONSTANT)

public:
    static constexpr int MaxSlots = 9;

    explicit ImageBridge(QObject* parent = nullptr);
    ~ImageBridge() override;

    int slotCount() const { return m_slotCount; }
    int maxSlots() const { return MaxSlots; }

    // ── 多 slot 容器 ─────────────────────────────────────────────
    Q_INVOKABLE int  openFiles(const QVariantList& files);
    Q_INVOKABLE int  addFiles(const QVariantList& files);
    Q_INVOKABLE void closeSlot(int slot);
    Q_INVOKABLE void closeAll();

    // ── 单 slot 基础信息 ─────────────────────────────────────────
    Q_INVOKABLE bool   hasFile(int slot) const;
    Q_INVOKABLE QString filePath(int slot) const;
    Q_INVOKABLE QString fileName(int slot) const;

    // ── 图片元信息 ───────────────────────────────────────────────
    // 返回 QVariantMap 字段：
    //   { fileName, filePath, width, height, format, formatLong,
    //     bitDepth, hasAlpha, fileSize, fileModified,
    //     colorSpace, colorType, dpiX, dpiY, frameCount }
    // format: "png" / "jpeg" / "bmp" / "webp" / ...（QImageReader::format）
    // bitDepth: 每像素位数（8/16/32/48/64 等）
    // frameCount: 动图帧数（GIF/WEBP 动图 >1，静态图 = 1）
    Q_INVOKABLE QVariantMap imageInfo(int slot) const;

    // ── 轻量探测（setup 阶段用）──────────────────────────────────
    // 不打开 slot，只读文件头拿基本元信息。
    // 返回字段与 imageInfo() 一致。
    Q_INVOKABLE QVariantMap probeFile(const QString& path) const;

    // ── 图片数据（供 QML Image 渲染）──────────────────────────────
    // 返回 QImage（QML 端通过 ImageProvider 或直接转 path 加载）
    Q_INVOKABLE QImage image(int slot) const;

    // ── 文件列表持久化 ────────────────────────────────────────────
    Q_INVOKABLE QStringList imageFileList() const;
    Q_INVOKABLE void setImageFileList(const QVariantList& files);

    // ── "上次打开"位置持久化 ──────────────────────────────────────
    Q_INVOKABLE QString lastOpenedFolder() const;
    Q_INVOKABLE void    setLastOpenedFolder(const QString& folder);

signals:
    void slotCountChanged();
    void fileOpened(int slot);
    void fileClosed(int slot);

private:
    struct Slot {
        bool     inUse = false;
        QString  path;
        QImage   img;
        QVariantMap info;
    };

    Slot m_slots[MaxSlots];
    int  m_slotCount{0};

    QVariantMap probePath(const QString& path) const;

    // 色彩管理：把任意 ICC Profile 的图统一映射到 sRGB，
    // 对齐 macOS ColorSync 的行为（详见 .cpp 中的说明）。
    static QImage normalizeColorSpace(const QImage& src);
};
