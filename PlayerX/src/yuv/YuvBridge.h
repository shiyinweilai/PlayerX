#pragma once
/**
 * YuvBridge.h — YuvAnalyzer 的 Qt/QML 桥接层（多 slot 版本）
 *
 * 把纯 C++ 的 YuvAnalyzer 包装为 QObject，通过 Q_INVOKABLE 暴露给 QML。
 * 支持最多 MaxSlots(=9) 个 YUV 文件同时打开/渲染，每个 slot 独立管理一个
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

    // ── 是否隐藏渲染区底部内嵌操作按钮（顶部菜单"YUV 分析 ▸ 内嵌操作"开关）──
    // true  = 隐藏（默认；用户专注画面不被按钮遮挡）
    // false = 显示（hover 时淡入淡出浮起）
    // 持久化到 QSettings，跨会话保留用户选择。
    Q_PROPERTY(bool inlineControlsHidden READ inlineControlsHidden WRITE setInlineControlsHidden NOTIFY inlineControlsHiddenChanged)

    // ── 全局缩放比例（底部"缩放按钮组"1/8 / 1/4 / 1/2 / 1X / 2X / 4X / 8X）──
    // 默认 1.0（1X），不持久化（每次启动固定为 1X，避免老用户历史设置让首屏
    // 看不到全图）。所有 YuvDisplayItem 都监听此属性变化，多路对比自动同步。
    Q_PROPERTY(qreal globalScale READ globalScale WRITE setGlobalScale NOTIFY globalScaleChanged)

public:
    static constexpr int MaxSlots = 9;

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

    // ── 还原视图（缩放 1X + 平移归零）──────────────────────────────────
    // 发出 resetViewChanged() 信号，所有 YuvDisplayItem 监听此信号并把
    // 自己的 panX/panY 归零，同时把 globalScale 设回 1.0（发 globalScaleChanged
    // 触发预缩放图重算）。仅 yuv tab 生效（QML 端 enabled 限制）。
    Q_INVOKABLE void resetView();

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
    //     "mean", "stddev", "variance", "min", "max", "range", "binCount" }
    Q_INVOKABLE QVariantMap histogram(int slot, int plane) const;

    // ── 块级直方图统计（右侧栏"块级别"模式，8×8 块，对齐规则与 pixelBlock8x8 一致）──
    Q_INVOKABLE QVariantMap blockHistogram(int slot, int plane, int px, int py) const;

    // ── 块级"梯度 / 纹理 / 锐利度"统计（与 blockHistogram 同一块，对齐规则同源）──
    // 返回字段与 planeStats 一致，但 sampleCount 反映该块的像素数（通常 = blockSize²）。
    // 块太小（如 8×8 < 3×3）算不出有意义的梯度时 sampleCount=0 + 梯度全 0。
    Q_INVOKABLE QVariantMap blockStats(int slot, int plane, int px, int py) const;

    // ── 帧级"梯度 / 纹理 / 锐利度"全方向统计（plane: 0=Y, 1=U, 2=V）──────
    // 返回 QVariantMap：
    //   { "mean", "stddev", "variance", "min", "max", "range",
    //     "gradHorizMean", "gradVertMean",
    //     "gradDiag45Mean", "gradDiag135Mean",
    //     "gradMean", "laplacianEnergy", "tenengrad",
    //     "sampleCount" }
    //   单位：均值/标准差/方差/极差在 0..255（或 0..1023）值域；
    //   梯度幅值、能量、Tenengrad 等越大代表画面纹理越强/越锐利。
    Q_INVOKABLE QVariantMap planeStats(int slot, int plane) const;

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

    // ── 滑动对比切换请求（由快捷键 B 触发，YuvWindow 监听信号执行切换）──
    Q_INVOKABLE void requestToggleSliderCompare() { emit toggleSliderCompareRequested(); }

    // ── 画面内侧路径信息显隐切换（由快捷键 C 触发，YuvWindow 监听信号执行切换）──
    Q_INVOKABLE void requestToggleSlotInfo() { emit toggleSlotInfoRequested(); }

    // ── 块大小设置（8/16/32/64，全局唯一）───────────────────────────────
    int  blockSize() const { return m_blockSize; }
    void setBlockSize(int size);

    // ── 是否隐藏渲染区底部内嵌操作按钮 ────────────────────────────────
    bool inlineControlsHidden() const { return m_inlineControlsHidden; }
    void setInlineControlsHidden(bool hidden);

    // ── 全局缩放比例（所有 YuvDisplayItem 共享）────────────────────────
    qreal globalScale() const { return m_globalScale; }
    void setGlobalScale(qreal s);
    // 缩放档位索引（0..6 → 1/8, 1/4, 1/2, 1X, 2X, 4X, 8X），
    // 供 QML "Repeater" 选中态绑定使用
    Q_INVOKABLE int currentScaleIndex() const;
    Q_INVOKABLE void setCurrentScaleIndex(int idx);
    Q_INVOKABLE QStringList scalePresetLabels() const;
    // 滚轮缩放：按 delta 正负沿档位上下切一格（delta>0 放大，<0 缩小）。
    // 边界自动 clamp 到 [0, 6]，不会越界。
    Q_INVOKABLE void bumpScale(int delta);
    // 线性连续缩放：globalScale 乘以 factor（factor>1 放大，<1 缩小）。
    // 与 bumpScale 的档位式跳变不同，这里做平滑的连续缩放，滚轮每次只放大/缩小
    // 一小步（如 ×1.1），跳变感弱得多。边界自动 clamp 到 [1/8, 8]。
    Q_INVOKABLE void zoomBy(qreal factor);

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

    // ── "上次打开"位置持久化：FileDialog/FolderDialog 打开前读取、关闭后写入，
    //    让"添加文件/添加文件夹"按钮下次打开时跳回上次选的目录，而非根目录。 ──
    Q_INVOKABLE QString lastOpenedFolder() const;
    Q_INVOKABLE void    setLastOpenedFolder(const QString& folder);

signals:
    void frameChanged(int slot);
    void fileOpened(int slot);
    void displayModeChanged(int slot);
    void slotCountChanged();
    void yuvPresetsChanged();
    void playStateChanged(int slot);
    void resetViewChanged();
    void hoverChanged();
    void blockSizeChanged();
    void pixelInspectRequested(int px, int py);
    void toggleSliderCompareRequested();
    void toggleSlotInfoRequested();
    void inlineControlsHiddenChanged();
    void globalScaleChanged();

private:
    void refreshFrameImage(int slot);
    void stopTimer(int slot);

    std::unique_ptr<rb::YuvAnalyzer> m_analyzers[MaxSlots];
    QImage m_frameImages[MaxSlots];
    int    m_displayModes[MaxSlots]{0, 0, 0, 0, 0, 0, 0, 0, 0};

    // 播放定时器（每个 slot 独立）
    QTimer* m_playTimers[MaxSlots]{nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    bool    m_playing[MaxSlots]{false, false, false, false, false, false, false, false, false};
    bool    m_reversing[MaxSlots]{false, false, false, false, false, false, false, false, false};

    // 全局鼠标悬浮像素坐标（跨 slot 共享，供右侧栏"块级别"统计使用）
    int  m_hoverSlot{0};
    int  m_hoverPixelX{0};
    int  m_hoverPixelY{0};
    bool m_hoverValid{false};

    // 像素块统计/悬浮矩阵的块大小，默认 8×8，可选 8/16/32/64
    int  m_blockSize{8};

    // 是否隐藏渲染区底部内嵌操作按钮；默认 true（隐藏，让用户专注画面）
    bool m_inlineControlsHidden{true};

    // 全局缩放比例（底部缩放按钮组驱动）；默认 1.0（1X），不持久化
    qreal m_globalScale{1.0};
};
