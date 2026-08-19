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
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QTimer>
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
    Q_INVOKABLE int openFiles(const QVariantList& files);
    Q_INVOKABLE void closeAll();
    Q_INVOKABLE int slotCount() const;

    // ── 单 slot 文件操作 ──────────────────────────────────────────────
    Q_INVOKABLE void closeFile(int slot);
    Q_INVOKABLE void gotoFrame(int slot, int frameNum);
    Q_INVOKABLE void nextFrame(int slot);
    Q_INVOKABLE void prevFrame(int slot);
    Q_INVOKABLE void firstFrame(int slot);
    Q_INVOKABLE void lastFrame(int slot);

    // ── 播放控制（缓存播放）──────────────────────────────────────────
    Q_INVOKABLE void play(int slot);            // 正向播放
    Q_INVOKABLE void playReverse(int slot);     // 倒放
    Q_INVOKABLE void pause(int slot);           // 暂停
    Q_INVOKABLE void togglePlayPause(int slot); // 切换播放/暂停
    Q_INVOKABLE bool isPlaying(int slot) const; // 是否正在播放
    Q_INVOKABLE bool isReversing(int slot) const; // 是否倒放中
    Q_INVOKABLE void skipForward(int slot, int frames = 15);  // 快进 N 帧
    Q_INVOKABLE void skipBackward(int slot, int frames = 15); // 快退 N 帧
    Q_INVOKABLE void resetFrame(int slot);      // 重置到首帧

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

    // ── 像素级查询（8×8 块）──────────────────────────────────────────────
    Q_INVOKABLE QVariantList pixelBlock8x8(int slot, int px, int py) const;

    // ── 8×8 块统计（Y/U/V 各自的 avg / min / max）───────────────────────
    // 返回 QVariantMap：
    //   { "yAvg", "yMin", "yMax",
    //     "uAvg", "uMin", "uMax",
    //     "vAvg", "vMin", "vMax" }
    Q_INVOKABLE QVariantMap pixelBlockStats8x8(int slot, int px, int py) const;

    // ── 直方图统计（当前帧，plane: 0=Y, 1=U, 2=V）──────────────────────
    // 返回 QVariantMap：
    //   { "bins": [int,...],       // 桶计数（8bit=256, 10bit=1024）
    //     "mean", "stddev", "min", "max", "binCount" }
    Q_INVOKABLE QVariantMap histogram(int slot, int plane) const;

    // ── 预设持久化（用 QSettings 保存到磁盘）───────────────────────────
    Q_INVOKABLE QStringList yuvSizePresets() const;
    Q_INVOKABLE void addYuvSizePreset(const QString& size);
    Q_INVOKABLE void removeYuvSizePreset(const QString& size);

    Q_INVOKABLE QStringList yuvFormatPresets() const;
    Q_INVOKABLE void addYuvFormatPreset(const QString& fmt);
    Q_INVOKABLE void removeYuvFormatPreset(const QString& fmt);

    Q_INVOKABLE QList<double> yuvFpsPresets() const;
    Q_INVOKABLE void addYuvFpsPreset(double fps);
    Q_INVOKABLE void removeYuvFpsPreset(double fps);

    // ── 文件列表 + 每文件参数持久化 ────────────────────────────────────
    Q_INVOKABLE QStringList yuvFileList() const;
    Q_INVOKABLE void setYuvFileList(const QVariantList& files);

    Q_INVOKABLE QString yuvFileParams(const QString& path) const;
    Q_INVOKABLE void setYuvFileParams(const QString& path, const QString& params);

signals:
    void frameChanged(int slot);
    void fileOpened(int slot);
    void displayModeChanged(int slot);
    void slotCountChanged();
    void yuvPresetsChanged();
    void playStateChanged(int slot);

private:
    void refreshFrameImage(int slot);
    void stopTimer(int slot);

    std::unique_ptr<rb::YuvAnalyzer> m_analyzers[MaxSlots];
    QImage m_frameImages[MaxSlots];
    int    m_displayModes[MaxSlots]{0, 0, 0};

    // 播放定时器（每个 slot 独立）
    QTimer* m_playTimers[MaxSlots]{nullptr, nullptr, nullptr};
    bool    m_playing[MaxSlots]{false, false, false};
    bool    m_reversing[MaxSlots]{false, false, false};
};
