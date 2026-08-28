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
#include <QFutureWatcher>
#include <memory>
#include <deque>
#include <mutex>

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

    // ── YUV 值面板（像素矩阵浮窗 + avg/min/max 统计）可见性 ──
    // true  = 显示（默认；hover 视频时弹出像素统计浮窗）
    // false = 隐藏（V 快捷键或菜单勾选切换）
    // 不持久化，每次启动默认为 true。
    Q_PROPERTY(bool pixelInfoVisible READ pixelInfoVisible WRITE setPixelInfoVisible NOTIFY pixelInfoVisibleChanged)

    // ── 色度插值模式（控制 4:2:0/4:2:2 上采样算法）──
    // 0 = Nearest Neighbor（默认；像素级分析标准，展示原始色度值）
    // 1 = Bilinear（双线性，预览观看更平滑）
    // 2 = Bicubic（双三次，更平滑但计算更重）
    // 持久化到 QSettings，跨会话保留用户选择。
    Q_PROPERTY(int chromaInterpolation READ chromaInterpolation WRITE setChromaInterpolation NOTIFY chromaInterpolationChanged)

    // ── 颜色转换标准（控制 YUV→RGB 色彩矩阵与值域范围）──
    // 0 = ITU-R BT.709 limited range（默认；现代高清标准）
    // 1 = ITU-R BT.709 full range
    // 2 = ITU-R BT.601 limited range（标清标准）
    // 3 = ITU-R BT.601 full range
    // 4 = ITU-R BT.2020 limited range（超高清标准）
    // 5 = ITU-R BT.2020 full range
    // 持久化到 QSettings，跨会话保留用户选择。
    Q_PROPERTY(int colorConversion READ colorConversion WRITE setColorConversion NOTIFY colorConversionChanged)

    // ── 全局缩放比例（底部"缩放按钮组"1/8 / 1/4 / 1/2 / 1X / 2X / 4X / 8X）──
    // 默认 1.0（1X），不持久化（每次启动固定为 1X，避免老用户历史设置让首屏
    // 看不到全图）。所有 YuvDisplayItem 都监听此属性变化，多路对比自动同步。
    Q_PROPERTY(qreal globalScale READ globalScale WRITE setGlobalScale NOTIFY globalScaleChanged)

    // ── 右侧统计面板是否展开 ──
    // QML 绑定 Main.qml 的 rightSidebarOpen → YuvBridge.rightSidebarOpen。
    // 当右侧栏展开时，播放期间也实时计算帧级统计（兼顾实时渲染统计图）；
    // 当右侧栏收起时，播放期间跳过统计计算，保证最大渲染帧率。
    Q_PROPERTY(bool rightSidebarOpen READ rightSidebarOpen WRITE setRightSidebarOpen NOTIFY rightSidebarOpenChanged)

    // ── 多通道同步播放帧率（fps）──
    // 多通道同步播放时的统一渲染帧率，默认 30fps。用户可在顶部菜单调整
    // （如 15/24/25/30/60）。单通道播放不受此影响（按文件自身 fps）。
    // 持久化到 QSettings，跨会话保留。
    Q_PROPERTY(int syncFps READ syncFps WRITE setSyncFps NOTIFY syncFpsChanged)

    // ── 差异检测：两路 YUV 播放时，检测到帧差异则暂停并弹窗 ──
    Q_PROPERTY(bool diffDetectEnabled READ diffDetectEnabled WRITE setDiffDetectEnabled NOTIFY diffDetectEnabledChanged)

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

    // ── 全局播放控制（多通道同步 / 单通道独立）──────────────────────
    Q_INVOKABLE void globalPlay();            // 全局播放
    Q_INVOKABLE void globalPlayReverse();     // 全局倒放
    Q_INVOKABLE void globalPause();           // 全局暂停
    Q_INVOKABLE void globalTogglePlayPause(); // 全局切换播放/暂停
    Q_INVOKABLE void globalToggleReverse();   // 全局切换正/倒放

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

    // ── YUV 值面板可见性 ──
    bool pixelInfoVisible() const { return m_pixelInfoVisible; }
    void setPixelInfoVisible(bool visible);

    // ── 色度插值模式 ──
    int  chromaInterpolation() const { return m_chromaInterpolation; }
    void setChromaInterpolation(int mode);

    // ── 颜色转换标准 ──
    int  colorConversion() const { return m_colorConversion; }
    void setColorConversion(int mode);

    // ── 全局缩放比例（所有 YuvDisplayItem 共享）────────────────────────
    qreal globalScale() const { return m_globalScale; }
    void setGlobalScale(qreal s);

    // ── 右侧统计面板是否展开 ──
    bool rightSidebarOpen() const { return m_rightSidebarOpen; }
    void setRightSidebarOpen(bool open);

    // ── 多通道同步播放帧率 ──
    int  syncFps() const { return m_syncFps; }
    void setSyncFps(int fps);

    // ── 差异检测开关 ──
    bool diffDetectEnabled() const { return m_diffDetectEnabled; }
    void setDiffDetectEnabled(bool enabled);

    // ── 差异暂停后恢复播放 ──
    // resumeAfterDiff: 继续比较差异（恢复播放，下帧仍检测）
    // ignoreDiffContinue: 忽略此差异继续播放（恢复播放，本次会话不再检测）
    Q_INVOKABLE void resumeAfterDiff();
    Q_INVOKABLE void ignoreDiffContinue();
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
    void pixelInfoVisibleChanged();
    void chromaInterpolationChanged();
    void colorConversionChanged();
    void globalScaleChanged();
    void rightSidebarOpenChanged();
    void syncFpsChanged();
    // 两路 YUV 播放中检测到差异时发出，QML 监听弹窗。
    // frameNum = 当前帧号, maxAbsDiff = Y 通道最大绝对差
    void diffDetected(int frameNum, int maxAbsDiff);
    void diffDetectEnabledChanged();
    // 帧级统计异步计算完成时发出，QML 监听此信号递增 ver 刷新面板。
    // 播放期间不发此信号（统计跳过），暂停/逐帧时才计算并发出。
    void statsReady(int slot);

private:
    void refreshFrameImage(int slot);
    void refreshFrameImageAsync(int slot);
    void refreshFrameImageAsyncToFrame(int slot, int targetFrame);
    void stopTimer(int slot);
    // 在 Worker 线程异步计算帧级统计（histogram + planeStats × 3 平面），
    // 完成后缓存到 m_cachedStats 并发 statsReady 信号。
    void computeStatsAsync(int slot, int frameNum);
    // 清空指定 slot 的统计缓存
    void invalidateStatsCache(int slot);

    // ── 多通道同步播放（预解码缓冲队列方案）──────────────────────────
    // 单通道时使用 per-slot QTimer（原有逻辑）。
    // 多通道时：每个通道后台持续解码填充帧缓冲队列（生产者），
    // 主时钟以固定 syncFps 从各队列取帧显示（消费者）。
    // 只有当所有活跃通道队列都有可取帧时，主时钟才推进一帧，
    // 从而在固定帧率下天然同步 —— 快的通道填满缓冲后闲置，不会超前。
    int  activeSlotCount() const;             // 当前已打开文件数
    void startSyncPlay(bool reverse);         // 启动同步播放
    void stopSyncPlay();                      // 停止同步播放
    void onSyncTimerTick();                   // 主时钟回调：从各队列取帧显示
    void scheduleDecode(int slot);            // 触发某通道后台解码下一帧填缓冲
    void onDecodeFinished(int slot);          // 某通道一帧解码完成回调
    void checkDiffDetect();                   // 差异检测（两路 YUV 帧显示后调用）
    int  m_syncStep{1};                       // 同步推进步长（正向=1，倒放=-1）

    // 预解码帧缓冲：每通道一个队列，缓存已解码好的帧（图像 + 帧号）
    struct DecodedFrame {
        QImage image;
        int    frameNum = -1;
    };
    static constexpr int kBufferCapacity = 6;  // 每通道缓冲容量（帧）
    std::deque<DecodedFrame> m_frameBuffer[MaxSlots];
    int  m_nextDecodeFrame[MaxSlots]{0, 0, 0, 0, 0, 0, 0, 0, 0}; // 下一个待解码帧号
    bool m_decodeInFlight[MaxSlots]{false, false, false, false, false, false, false, false, false}; // 该通道是否有解码任务在途
    bool m_reachedEnd[MaxSlots]{false, false, false, false, false, false, false, false, false};     // 该通道是否已解码到文件末尾
    QFutureWatcher<QImage>* m_decodeWatchers[MaxSlots]{}; // 同步播放专用解码 watcher
    int  m_decodeTargetFrame[MaxSlots]{-1, -1, -1, -1, -1, -1, -1, -1, -1}; // 在途解码的目标帧号
    int  m_visibleFrame[MaxSlots]{0, 0, 0, 0, 0, 0, 0, 0, 0}; // 每通道当前"已显示"的帧号（同步播放权威帧号）

    // 异步解码管线（单通道逐帧导航用）：每个 slot 一个 watcher + 预取状态
    // refreshFrameImageAsync 在 Worker 线程执行 seek+read+getFrameImageLocked，
    // 完成后在主线程把结果写入 m_frameImages 并发 frameChanged 信号。
    QFutureWatcher<QImage>* m_watchers[MaxSlots]{};
    int  m_pendingFrame[MaxSlots]{-1, -1, -1, -1, -1, -1, -1, -1, -1};  // Worker 正在解码的帧号
    bool m_asyncBusy[MaxSlots]{false, false, false, false, false, false, false, false, false};

    // ── 帧级统计缓存 ──
    // 异步计算结果缓存：histogram() / planeStats() 直接返回缓存值，零阻塞。
    // 缓存由 computeStatsAsync 在 Worker 线程填充，帧变化时触发。
    struct CachedStats {
        int frameNum = -1;             // 缓存对应的帧号，-1 = 无缓存
        QVariantMap hist[3];           // Y/U/V 直方图（bins + mean/stddev/min/max/...）
        QVariantMap stats[3];          // Y/U/V 平面统计（梯度/纹理/锐利度）
    };
    CachedStats m_cachedStats[MaxSlots];
    QFutureWatcher<void>* m_statsWatchers[MaxSlots]{};
    int m_statsPendingFrame[MaxSlots]{-1, -1, -1, -1, -1, -1, -1, -1, -1};

    std::unique_ptr<rb::YuvAnalyzer> m_analyzers[MaxSlots];
    QImage m_frameImages[MaxSlots];
    int    m_displayModes[MaxSlots]{0, 0, 0, 0, 0, 0, 0, 0, 0};

    // 播放定时器（每个 slot 独立）
    QTimer* m_playTimers[MaxSlots]{nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    bool    m_playing[MaxSlots]{false, false, false, false, false, false, false, false, false};
    bool    m_reversing[MaxSlots]{false, false, false, false, false, false, false, false, false};
    // 从头播放标记：play() 时若已在最后一帧，异步 seek 到 0 并置此标志，
    // 定时器回调看到此标志时跳过末尾检测，等 seek 完成后正常推进。
    bool    m_replayFromStart[MaxSlots]{false, false, false, false, false, false, false, false, false};

    // ── 多通道同步播放主时钟 ──
    // 多通道时，所有 slot 由这个 timer 同步驱动，使用最低 FPS 的 interval
    // 确保最慢的通道也能跟上；单通道时不使用此 timer，走 per-slot 逻辑。
    QTimer* m_syncTimer{nullptr};

    // 全局鼠标悬浮像素坐标（跨 slot 共享，供右侧栏"块级别"统计使用）
    int  m_hoverSlot{0};
    int  m_hoverPixelX{0};
    int  m_hoverPixelY{0};
    bool m_hoverValid{false};

    // 像素块统计/悬浮矩阵的块大小，默认 8×8，可选 8/16/32/64
    int  m_blockSize{8};

    // 是否隐藏渲染区底部内嵌操作按钮；默认 true（隐藏，让用户专注画面）
    bool m_inlineControlsHidden{true};

    // YUV 值面板可见性；默认 true（显示，hover 视频时弹出像素统计浮窗）
    bool m_pixelInfoVisible{true};

    // 色度插值模式；默认 0 = NearestNeighbor（像素级分析标准）
    int  m_chromaInterpolation{0};

    // 颜色转换标准；默认 0 = BT709 limited range（现代高清标准）
    int  m_colorConversion{0};

    // 全局缩放比例（底部缩放按钮组驱动）；默认 1.0（1X），不持久化
    qreal m_globalScale{1.0};
    bool m_rightSidebarOpen{false};
    int  m_syncFps{30};  // 多通道同步播放帧率，默认 30fps

    // ── 差异检测（仅两路 YUV 播放）──
    bool m_diffDetectEnabled{false};  // 差异检测开关
    bool m_diffPaused{false};         // 因差异暂停中（避免重复触发）
    // 用户选择"忽略差异继续播放"时置 true，下次播放不再检测差异，
    // 直到重新打开文件或切换 diffDetectEnabled。
    bool m_diffIgnoreOnce{false};
};
