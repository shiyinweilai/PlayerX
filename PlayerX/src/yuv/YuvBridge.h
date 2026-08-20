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

    // 像素块统计/悬浮矩阵的块大小（8/16/32/64），全局唯一，顶部菜单"YUV 分析→
    // 块大小"设置。不依赖右侧栏是否打开；影响 pixelBlock8x8 / pixelBlockStats8x8
    // / blockHistogram 以及悬浮矩阵浮窗的对齐块大小。
    Q_PROPERTY(int blockSize READ blockSize WRITE setBlockSize NOTIFY blockSizeChanged)

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

    // ── 块级直方图统计（右侧栏"块级别"模式，8×8 块，对齐规则与 pixelBlock8x8 一致）──
    Q_INVOKABLE QVariantMap blockHistogram(int slot, int plane, int px, int py) const;

    // ── 双路块级差异总览（右侧栏"差异总览"热力图，plane: 0=Y,1=U,2=V）────────
    // 按 blockSize 网格划分两路的公共分辨率（取交集宽高），逐块计算平均绝对差，
    // 用于绘制整帧差异热力图快速定位"从哪个块开始出现差异"。
    // 返回 QVariantMap：
    //   { "cols","rows","blockSize","width","height",
    //     "values": [double,...],   // cols*rows 个块的平均绝对差（行优先）
    //     "maxDiff": double,        // 最大差异值（用于归一化色阶）
    //     "firstDiffCol","firstDiffRow": int }  // 第一个有效差异块坐标，-1=完全一致
    Q_INVOKABLE QVariantMap blockDiffOverview(int slotA, int slotB, int plane) const;

    // ── 全局鼠标悬浮像素坐标（供右侧栏"块级别"统计随鼠标实时刷新）───────
    // 由 YuvWindow.qml 的像素悬浮 MouseArea 在 positionChanged / exited 时上报。
    Q_INVOKABLE void setHoverPixel(int slot, int px, int py, bool valid);
    Q_INVOKABLE int  hoverSlot() const { return m_hoverSlot; }
    Q_INVOKABLE int  hoverPixelX() const { return m_hoverPixelX; }
    Q_INVOKABLE int  hoverPixelY() const { return m_hoverPixelY; }
    Q_INVOKABLE bool hoverValid() const { return m_hoverValid; }

    // ── 右侧栏"差异总览"热力图 → 左侧对比浮窗 联动跳转 ──────────────────
    // 用户在右侧栏热力图上点击某个块时调用，YuvWindow.qml 监听
    // pixelInspectRequested 信号，在双路对比模式下把浮窗组固定到该像素坐标。
    Q_INVOKABLE void requestPixelInspect(int px, int py) { emit pixelInspectRequested(px, py); }

    // ── 块大小设置（8/16/32/64，全局唯一）───────────────────────────────
    int  blockSize() const { return m_blockSize; }
    void setBlockSize(int size);

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
    void hoverChanged();
    void blockSizeChanged();
    void pixelInspectRequested(int px, int py);

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

    // 全局鼠标悬浮像素坐标（跨 slot 共享，供右侧栏"块级别"统计使用）
    int  m_hoverSlot{0};
    int  m_hoverPixelX{0};
    int  m_hoverPixelY{0};
    bool m_hoverValid{false};

    // 像素块统计/悬浮矩阵的块大小，默认 8×8，可选 8/16/32/64
    int  m_blockSize{8};
};
