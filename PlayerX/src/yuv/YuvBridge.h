#pragma once
/**
 * YuvBridge.h — YuvAnalyzer 的 Qt/QML 桥接层（多 slot 版本）
 *
 * 把纯 C++ 的 YuvAnalyzer 包装为 QObject，通过 Q_INVOKABLE 暴露给 QML。
 * 支持最多 MaxSlots(=3) 个 YUV 文件同时打开/渲染，每个 slot 独立管理一个
 * YuvAnalyzer；所有操作与查询都带 slot 参数（0..MaxSlots-1）。
 * YuvWindow.qml 通过 "YuvBridge" context property 直接调用。
 */

#include <QObject>
#include <QImage>
#include <QString>
#include <QStringList>
#include <memory>

namespace rb {
class YuvAnalyzer;
}

class YuvBridge : public QObject {
    Q_OBJECT

    // slotCount 作为属性暴露（带 NOTIFY），QML 绑定能自动跟随 slotCountChanged
    // 更新，从而驱动 setup/render 切换与渲染窗口重建。
    Q_PROPERTY(int slotCount READ slotCount NOTIFY slotCountChanged)

public:
    static constexpr int MaxSlots = 3;

    explicit YuvBridge(QObject* parent = nullptr);
    ~YuvBridge() override;

    // ── 批量打开 ──────────────────────────────────────────────────────
    // 一次打开多个 YUV 文件（最多 MaxSlots 个），返回成功打开的数量。
    // 成功打开的 slot 从 0 开始连续编号。
    // 每个文件的渲染参数（宽高/格式/帧率）从 yuvFileParams(path) 持久化记录读取，
    // 做到每个文件用自己独立的参数渲染，渲染窗口之间不共享任何状态。
    // 用 QVariantList 接收（QML 传 JS 数组最稳妥），内部转 QStringList。
    Q_INVOKABLE int openFiles(const QVariantList& files);
    // 关闭所有 slot。
    Q_INVOKABLE void closeAll();
    // 当前打开的 slot 数量（0..MaxSlots）。
    Q_INVOKABLE int slotCount() const;

    // ── 单 slot 文件操作 ──────────────────────────────────────────────
    Q_INVOKABLE void closeFile(int slot);
    Q_INVOKABLE void gotoFrame(int slot, int frameNum);
    Q_INVOKABLE void nextFrame(int slot);
    Q_INVOKABLE void prevFrame(int slot);
    Q_INVOKABLE void firstFrame(int slot);
    Q_INVOKABLE void lastFrame(int slot);

    // ── 单 slot 查询 ──────────────────────────────────────────────────
    Q_INVOKABLE QImage  frameImage(int slot) const;
    Q_INVOKABLE int     currentFrame(int slot) const;
    Q_INVOKABLE int     totalFrames(int slot) const;
    Q_INVOKABLE int     width(int slot) const;
    Q_INVOKABLE int     height(int slot) const;
    Q_INVOKABLE QString filePath(int slot) const;
    Q_INVOKABLE QString fileName(int slot) const;   // 仅文件名（basename）
    Q_INVOKABLE QString fmtName(int slot) const;
    Q_INVOKABLE double  fps(int slot) const;
    Q_INVOKABLE bool    hasFile(int slot) const;
    Q_INVOKABLE int     displayMode(int slot) const;
    Q_INVOKABLE void    setDisplayMode(int slot, int mode);

    // ── 预设持久化（用 QSettings 保存到磁盘）───────────────────────────
    // 尺寸预设（"1920x1080"），按添加顺序去重；QML 用于"宽高预设"下拉。
    Q_INVOKABLE QStringList yuvSizePresets() const;
    Q_INVOKABLE void addYuvSizePreset(const QString& size);
    Q_INVOKABLE void removeYuvSizePreset(const QString& size);

    // 像素格式预设（"yuv420p" 等），同上。
    Q_INVOKABLE QStringList yuvFormatPresets() const;
    Q_INVOKABLE void addYuvFormatPreset(const QString& fmt);
    Q_INVOKABLE void removeYuvFormatPreset(const QString& fmt);

    // 帧率预设（23.976 / 30 / 60 …），同上。
    Q_INVOKABLE QList<double> yuvFpsPresets() const;
    Q_INVOKABLE void addYuvFpsPreset(double fps);
    Q_INVOKABLE void removeYuvFpsPreset(double fps);

    // ── 文件列表 + 每文件参数持久化 ────────────────────────────────────
    // 文件列表（本地路径），跨会话保留。
    Q_INVOKABLE QStringList yuvFileList() const;
    Q_INVOKABLE void setYuvFileList(const QVariantList& files);

    // 某个文件的渲染参数，格式 "1920x1080|yuv420p|30"；无记录返回空串。
    // 以文件 basename 作为 key（避免完整路径中的 '/' 被 QSettings 解析为 group）。
    Q_INVOKABLE QString yuvFileParams(const QString& path) const;
    Q_INVOKABLE void setYuvFileParams(const QString& path, const QString& params);

signals:
    // 某 slot 帧变化（frameNum），QML 据此刷新对应窗口画面
    void frameChanged(int slot);
    // 某 slot 打开/关闭（用于 QML 重建窗口）
    void fileOpened(int slot);
    void displayModeChanged(int slot);
    void slotCountChanged();
    // 任一预设集合（尺寸/格式/帧率）变化时触发，QML 重新拉取列表
    void yuvPresetsChanged();

private:
    void refreshFrameImage(int slot);

    std::unique_ptr<rb::YuvAnalyzer> m_analyzers[MaxSlots];
    QImage m_frameImages[MaxSlots];
    int    m_displayModes[MaxSlots]{0, 0, 0};
};
