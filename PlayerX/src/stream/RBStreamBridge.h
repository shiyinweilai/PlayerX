#pragma once
/**
 * RBStreamBridge.h — 码流分析模块的 Qt/QML 桥接层（多 slot 版本）
 *
 * 设计目标（与 码流分析架构.md §5 一致）：
 *   - 多 slot（最多 9 路，与 YuvBridge 一致），每路独立 RBDemuxer 复用做预扫描；
 *   - 提供 Q_INVOKABLE 接口给 QML，QML 不感知 RBDemuxer；
 *   - 块级深度信息（CU 划分 / QP）依赖 §4 提到的"FFmpeg 解码器打补丁导出"路径，
 *     一期先返回空数组，UI 自行走"未支持"降级显示；
 *   - 所有数据通过 QVariantList / QVariantMap 暴露给 QML，避免 C++ 结构体跨边界。
 *
 * 一期（P0）实现：
 *   - openFile / closeSlot / slotCount             —— 多 slot 容器
 *   - filePath / fileName / streamInfo(slot)       —— 顶层流参数（profile/level/width/height/fps/codec 等）
 *   - frameCount / currentFrame / gotoFrame / nextFrame / prevFrame / firstFrame
 *                                                  —— 帧导航（不真正解码）
 *   - frameList(slot) / gopList(slot)               —— 一次性拿全量（预扫描后）
 *   - hrdEstimate(slot)                             —— 基础 HRD 估算（基于 SPS）
 *   - blockInfoAt(slot, frame)                      —— 占位：返回空数组
 *   - seekPlayerTo(slot, frame)                     —— 联动播放（先用 Engine 替代）
 *
 * 二期再实现：
 *   - 通过 §4 补丁导出块级 CU / QP / MV
 *   - 块级惰性解析（LRU 缓存）
 *   - 联动 RBDecoder 真正解码
 */

#include <QObject>
#include <QString>
#include <QStringList>
#include <QtConcurrent/QtConcurrent>
#include <QFutureWatcher>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QByteArray>
#include <QSettings>
#include <QImage>
#include <QQuickImageProvider>
#include <cstdio>
#include <memory>
#include <vector>
#include <atomic>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/pixfmt.h>
}

#include "stream/RBFrameOrderMapper.h"
#include "stream/RBRefStructureParser.h"

namespace rb {
class RBDemuxer;
class RBBlockAnalyzer;
struct RBBlockInfo;
class RBSyntaxAnalyzer;   // 语法面板：CBS 解析 SPS/PPS/VPS 名值对（实现在 .cpp include）
}

class RBStreamBridge : public QObject {
    Q_OBJECT
    // 帧图像提供者需要直接读取槽位内的画面缓存
    friend class FrameImageProvider;
    Q_PROPERTY(int slotCount READ slotCount NOTIFY slotCountChanged)
    Q_PROPERTY(int prescanning READ prescanning NOTIFY prescanningChanged)
    // 暴露给 QML 的最大 slot 数（与 YuvBridge.MaxSlots 一致），便于
    // setup 阶段对 "可打开文件数" 做硬性裁剪。
    Q_PROPERTY(int maxSlots READ maxSlots CONSTANT)

public:
    static constexpr int MaxSlots = 9;

    explicit RBStreamBridge(QObject* parent = nullptr);
    ~RBStreamBridge() override;

    int slotCount() const { return m_slotCount; }
    int prescanning() const { return m_prescanning; }
    int maxSlots() const { return MaxSlots; }

    // ── 多 slot 容器 ─────────────────────────────────────────────
    Q_INVOKABLE int  openFile(const QString& path);
    Q_INVOKABLE void closeSlot(int slot);
    Q_INVOKABLE void closeAll();

    // ── 单 slot 基础信息 ─────────────────────────────────────────
    Q_INVOKABLE bool   hasFile(int slot) const;
    Q_INVOKABLE QString filePath(int slot) const;
    Q_INVOKABLE QString fileName(int slot) const;
    Q_INVOKABLE QString codecName(int slot) const;        // h264 / hevc / ...
    Q_INVOKABLE QString codecLongName(int slot) const;
    Q_INVOKABLE int    width(int slot) const;
    Q_INVOKABLE int    height(int slot) const;
    Q_INVOKABLE double fps(int slot) const;
    Q_INVOKABLE double durationSec(int slot) const;
    Q_INVOKABLE long long bitrate(int slot) const;        // 容器声明的平均码率
    Q_INVOKABLE QString pixFmtName(int slot) const;       // yuv420p / ...
    Q_INVOKABLE QString colorSpaceName(int slot) const;
    Q_INVOKABLE QString colorRangeName(int slot) const;
    Q_INVOKABLE QString profileName(int slot) const;      // Baseline/Main/High/Rext...
    Q_INVOKABLE int    profileId(int slot) const;
    Q_INVOKABLE int    levelId(int slot) const;

    // ── 单 slot 帧导航（不真正解码，仅按 fps 推算）────────────────
    Q_INVOKABLE int     frameCount(int slot) const;       // ≈ duration * fps
    Q_INVOKABLE int     currentFrame(int slot) const;     // 用户设定的"当前帧"，默认 0
    Q_INVOKABLE void    gotoFrame(int slot, int frame);
    Q_INVOKABLE void    nextFrame(int slot);
    Q_INVOKABLE void    prevFrame(int slot);
    Q_INVOKABLE void firstFrame(int slot);

    // ── 文件列表持久化（QSettings） ──────────────────────────────
    // 与 YuvBridge.yuvFileList / setYuvFileList 对齐：
    //   读写 ~/.config/PlayerX/RBStreamBridge.ini 的 streamFileList key
    Q_INVOKABLE QStringList streamFileList() const;
    Q_INVOKABLE void setStreamFileList(const QVariantList& files);

    // ── 顶流信息（一次性）─────────────────────────────────────────
    // 返回 QVariantMap 字段：
    //   { codec, codecLong, profile, level, width, height, fps,
    //     duration, bitrate, pixFmt, colorSpace, colorRange,
    //     frameCount, fileName, filePath }
    Q_INVOKABLE QVariantMap streamInfo(int slot) const;

    // ── 帧列表（预扫描结果）───────────────────────────────────────
    // 每项：{ packetIndex, pts, dts, poc, type(I/P/B/IDR), sizeBytes, avgQp }
    // avgQp 在块级补丁未启用时统一为 -1，UI 走降级展示。
    Q_INVOKABLE QVariantList frameList(int slot) const;
    // 编码顺序勾选（仅影响 POC 展示口径，不动播放/解码管线）：
    // 0=显示顺序（POC 递增） 1=编码顺序（POC 按 GOP 重排，如 GOP=4 → 0,4,2,1,3）
    Q_INVOKABLE int frameOrderMode(int slot) const;
    Q_INVOKABLE void setFrameOrderMode(int slot, int mode);
    // 把 UI 侧的帧号换算成「解码器输出序索引」。
    // 解码器（decodeFrameAt）按输出序（=显示序）计数，而 UI 在编码顺序模式下
    // 用的是编码序（包序）索引；两者混用会导致画面按播放序渲染、与层级图对不上。
    // 显示顺序模式下原样返回；映射未就绪时也原样返回（保持旧行为）。
    Q_INVOKABLE int  decodeIndexOf(int slot, int frameIndex) const;
    // 编码序映射是否就绪（后台解码完成）。未就绪时 UI 保持显示顺序、勾选禁用。
    Q_INVOKABLE bool frameOrderMapReady(int slot) const;

    // ── 语法元素面板（SPS/PPS/VPS 名值对，右侧栏 Syntax Info）──
    // 后台一次 CBS 解析，结果缓存；QML 只读。每项 { set, name, value }。
    Q_INVOKABLE QVariantList syntaxEntries(int slot) const;
    // 语法解析是否就绪（后台完成后为 true）。
    Q_INVOKABLE bool syntaxReady(int slot) const;

    // ── 参考结构（真实层级 + 参考关系，右侧/底部层级面板）──
    // 数据来自 RBRefStructureParser 对 slice 头的真实解析，按「解码序」存放；
    // 此处对外统一按「显示序」索引，内部用 orderMap.dispToCode 换算。
    // 每帧层级：0 最重要（I/IDR），数字越大越不重要；-1=未就绪/不支持。
    Q_INVOKABLE int frameLayer(int slot, int displayIndex) const;
    // 该帧参考的帧（元素是显示序索引）；未就绪返回空列表。
    Q_INVOKABLE QVariantList frameRefs(int slot, int displayIndex) const;
    // 参考结构是否就绪（真实数据可用；false 时 UI 回退启发式层级）。
    Q_INVOKABLE bool refStructReady(int slot) const;

    // ── GOP 列表（预扫描结果）─────────────────────────────────────
    // 每项：{ startFrameIndex, frameCount, isOpenGop }
    Q_INVOKABLE QVariantList gopList(int slot) const;

    // ── HRD 估算 ────────────────────────────────────────────────
    // 当前基于 SPS 声明的 CPB 容量 / 码率，估算整片峰值占用率。
    // 返回 QVariantMap：
    //   { available,           // bool, 是否能给出有效估算
    //     cpbSizeBits,         // 声明的 CPB 容量
    //     bitRateBits,         // 声明的 bit rate
    //     peakRatio,           // 估算峰值占用率（0..1+）
    //     overflowRisk,        // 估算 >1
    //     underflowRisk }      // 估算 < 0.1
    // 字段不可用时 available=false，其它字段为 0/false。
    Q_INVOKABLE QVariantMap hrdEstimate(int slot) const;

    // ── 块级信息（CU 划分 / QP / MV）—— P1 真实实现 ──────────────
    // 返回 QVariantList（每项一帧内一个块）：
    //   { x, y, w, h, qp, isSkip, isIntra, mvx, mvy }
    // P1：通过 RBBlockAnalyzer 解码该帧并从 AVVideoEncParams side data 提取。
    //      H.264 原生支持（逐宏块 16×16）；HEVC 走 CTU 降级；其它编码返回空数组。
    // 取不到时返回空数组，UI 走"该格式暂不支持块级分析"降级。
    Q_INVOKABLE QVariantList blockInfoAt(int slot, int frameIndex) const;

    // 当前码流是否支持块级分析（避免 UI 白等）
    Q_INVOKABLE bool blockInfoSupported(int slot) const;
    // 块级精度描述，如 "宏块级 (16×16)"；不支持时为空串
    Q_INVOKABLE QString blockGranularity(int slot) const;
    // 该帧块级统计：{ valid, avgQp, minQp, maxQp, blockCount, width, height }
    Q_INVOKABLE QVariantMap blockStats(int slot, int frameIndex) const;

    // ── 联动播放器 seek（占位）────────────────────────────────────
    // 一期仅日志 + 后续接 EngineBridge.seekPlayerTo。
    // 帧号 → 秒数（按 fps 反推），再交给 Engine。
    Q_INVOKABLE void seekPlayerTo(int slot, int frameIndex);

    // ── 轻量探测（setup 阶段用）──────────────────────────────────
    // 不打开 slot、不做帧级预扫描，只调 avformat_open_input +
    // avformat_find_stream_info 拿基本流信息。
    // 返回 QVariantMap 字段与 streamInfo() 一致。
    // 用于 setup 阶段点击文件时即时显示基本信息。
    Q_INVOKABLE QVariantMap probeFile(const QString& path) const;

    // ── 裸码流导出（解封装）──────────────────────────────────────
    // 将封装文件（mp4/mov/mkv/flv/ts 等）中的视频码流提取为 Annex-B 裸码流。
    // 若源文件已是裸流（.h264/.265/.hevc），直接复制。
    // path: 输入文件路径  outPath: 输出文件路径（含文件名）
    // 返回 QVariantMap：{ ok(bool), frameCount(int), fileSize(qint64), error(QString) }
    Q_INVOKABLE QVariantMap demuxToAnnexB(const QString& path, const QString& outPath);

    // ── 底层原始画面（供 CU 网格叠加在真实渲染图上）──────────────
    // 返回该 slot 当前帧解码后的画面。QML 侧用量：
    //   Image { source: "image://streamframe/" + slot + "_" + frame + "_" + version }
    // version 用于强制刷新（帧切换时递增）。
    class FrameImageProvider : public QQuickImageProvider {
    public:
        explicit FrameImageProvider(RBStreamBridge* bridge)
            : QQuickImageProvider(QQuickImageProvider::Image), m_bridge(bridge) {}
        QImage requestImage(const QString& id, QSize* size,
                            const QSize& requestedSize) override;
    private:
        RBStreamBridge* m_bridge;
    };

    // 帧图像版本号：帧切换时递增，供 QML 拼接 URL 强制刷新
    Q_INVOKABLE int frameImageVersion(int slot) const;

    // ── 异步"真播放"（仿 YuvBridge：解码在 Worker 线程，主线程零阻塞）──
    // QML 播放定时器每拍调用 requestPlayStep；若上一帧仍在解码则直接跳过本拍，
    // 保证播放可以慢，但绝不堆积、绝不卡死（4K VVC 单帧可达数十万 CU）。
    Q_INVOKABLE void requestPlayStep(int slot, int frameIndex);
    Q_INVOKABLE bool isPlayBusy(int slot) const;

signals:
    void slotCountChanged();
    void prescanningChanged();
    void prescanProgress(int slot, double ratio); // 大文件预扫描进度（占位）
    void frameReady(int slot, int frameIndex);    // 块级信息异步就绪（占位）
    void fileOpened(int slot);
    void fileClosed(int slot);
    void currentFrameChanged(int slot);
    void demuxProgress(const QString& path, double ratio);  // 裸码流导出进度
    // 帧图像就绪（画面解码完成，QML 需刷新 Image source）
    void frameImageChanged(int slot);
    // 编码顺序勾选变化（POC 展示口径切换，QML 需刷新帧列表绑定）
    void frameOrderModeChanged(int slot);
    // 编码序映射就绪变化（后台解码完成，QML 需刷新帧列表并放开切换）
    void frameOrderMapReadyChanged(int slot);
    // 语法元素解析就绪（右侧栏 Syntax Info 刷新）
    void syntaxReadyChanged(int slot);
    // 参考结构解析就绪（层级面板刷新为真实层级/参考关系）
    void refStructReadyChanged(int slot);

private:
    struct Slot {
        bool   inUse = false;
        QString path;
        // 顶层流参数（来自 AVFormatContext / AVCodecParameters）
        QString codecName;
        QString codecLongName;
        QString containerFormat;      // 容器格式短名（mp4 / mov / matroska / avi …）
        QString containerLongName;    // 容器格式长名
        int     width = 0;
        int     height = 0;
        AVRational fps{0, 1};
        double  duration = 0.0;
        long long bitrate = 0;
        AVPixelFormat pixFmt = AV_PIX_FMT_NONE;
        AVColorSpace  colorSpace = AVCOL_SPC_UNSPECIFIED;
        AVColorRange  colorRange = AVCOL_RANGE_UNSPECIFIED;
        int     profile = -100;
        int     level   = -100;
        int     currentFrame = 0;
        // 预扫描结果（轻量：只保留 GOP 列表，帧列表按需重新生成避免占大内存）
        std::vector<int> gopStartFrames;          // 每个 GOP 的起始帧索引
        std::vector<int> gopFrameCounts;          // 每个 GOP 的帧数
        std::vector<bool> gopIsOpen;              // 是否 open GOP（占位：先 false）
        std::vector<int> frameTypes;              // 每帧的 I/P/B 标记（0=I 1=P 2=B 3=IDR）
        int  frameOrderMode = 0;                  // 0=显示顺序 1=编码顺序（仅影响展示口径）
        // 编码序↔显示序映射（RBFrameOrderMapper 后台一次解码建立，纯真实数据）：
        // 打开文件后异步启动，就绪后 frameList 的 POC 用 codeToDisp（真实显示序位置）。
        // 例：GOP=4 编码序 I P B B → POC = 0,4,2,1,3。未就绪时退化简易递增，不阻塞秒开。
        rb::RBFrameOrderMapper::Result orderMap;  // ok=false 表示不可用
        QFutureWatcher<void>* orderMapWatcher = nullptr;
        int orderMapBuilding = 0;                 // 1=后台解码中
        std::shared_ptr<std::atomic_bool> orderMapCancel = nullptr;  // 协作式取消
        // ── 语法元素面板（SPS/PPS/VPS 名值对，右侧栏 Syntax Info）──
        // 打开文件后台一次 CBS 解析（RBSyntaxAnalyzer），结果缓存；QML 只读。
        QByteArray  extradataCopy;                // 容器参数集拷贝（供 CBS 解析）
        QVariantList syntaxCache;                 // SPS/PPS/VPS 名值对
        bool        syntaxReadyFlag = false;      // 后台解析是否完成
        QFutureWatcher<QVariantList>* syntaxWatcher = nullptr;
        // ── 参考结构（真实层级 + 参考关系，RBRefStructureParser 后台解析）──
        // 按「解码序」索引；QML 展示显示序时用 orderMap.dispToCode 换算。
        // 未就绪（ok=false）时 UI 回退启发式层级，不阻塞秒开。
        rb::RBRefStructureParser::Result refStruct;
        bool refStructReadyFlag = false;
        QFutureWatcher<rb::RBRefStructureParser::Result>* refStructWatcher = nullptr;
        std::vector<long long> frameSizes;        // 每帧字节数（来自 AVPacket.size）
        std::vector<double>  frameAvgQp;          // 每帧平均 QP（未启用补丁：-1）
        long long cpbSizeBits = 0;                // SPS 声明的 CPB 容量（0=未知）
        long long cbrBitrateBits = 0;             // SPS 声明的目标码率（0=未知）
        // P1：块级分析器（惰性创建，仅在首次请求块级信息时打开解码器）
        std::unique_ptr<rb::RBBlockAnalyzer> blockAnalyzer;
        bool blockAnalyzerTried = false;          // 已尝试创建过（失败则不再重试）
        // 底层画面版本号：每次帧切换/画面更新时递增，供 QML URL 强制刷新
        int  frameImageVersion = 0;
        // 最近一次成功导出的画面（避免 Image provider 重复解码）
        QImage lastFrameImage;
        int    lastFrameImageFor = -1;           // 该画面对应的帧号（-1=无）
        // ── 异步播放状态（Worker 线程解码画面+块，主线程只发信号）──
        bool   playBusy = false;                 // 上一帧仍在解码中
        int    playPendingFrame = -1;            // 解码期间新请求的帧号（-1=无）
    };

    // 惰性获取/创建该 slot 的块级分析器；失败返回 nullptr
    rb::RBBlockAnalyzer* blockAnalyzerFor(int slot) const;
    static QVariantMap  blockInfoToMap(const rb::RBBlockInfo& bi);

    bool parseSlot(int slot, Slot& s, rb::RBDemuxer& demuxer);
    // 编码序↔显示序映射：打开文件后台异步解码一遍建立（RBFrameOrderMapper）。
    // 不阻塞秒开与播放；就绪后 frameList 的 POC 使用真实显示序位置。
    void startOrderMapBuild(int slot);   // 启动后台构建
    void onOrderMapBuilt(int slot);      // 后台完成回调（主线程）
    void cancelOrderMap(int slot);       // 取消并回收（freeSlot/换文件时）
    // 语法元素面板：打开文件后台一次 CBS 解析 SPS/PPS/VPS，结果缓存。
    void startSyntaxBuild(int slot);     // 启动后台解析
    void onSyntaxBuilt(int slot);        // 后台完成回调（主线程写缓存）
    // 参考结构：后台一次解析 slice 头，得到真实层级与参考关系。
    void startRefStructBuild(int slot);  // 启动后台解析
    void onRefStructBuilt(int slot);     // 后台完成回调（主线程写缓存）
    // 裸流 fallback：当 avformat 解析失败（裸 h264/hevc annexb）时直接读文件，
    // 按 0x000001 / 0x00000001 切 NAL 单元，识别 SPS 拿宽高，按 IDR 切 GOP。
    // 不依赖任何 FFmpeg 容器解析。
    bool parseRawAnnexB(Slot& s);
    void freeSlot(int slot);
    static QVariantMap frameItemToMap(int packetIndex, int type, long long sizeBytes,
                                      double pts, double dts, int poc, double avgQp);
    static QString colorSpaceToString(AVColorSpace cs);
    static QString colorRangeToString(AVColorRange cr);
    static QString colorPrimariesToString(AVColorPrimaries cp);
    static QString colorTransferToString(AVColorTransferCharacteristic trc);
    static QString chromaLocationToString(AVChromaLocation cl);
    static QString fieldOrderToString(AVFieldOrder fo);
    static QString pixFmtToString(AVPixelFormat f);
    static QString profileIdToString(AVCodecID id, int profileId);
    static QString codecIdToShortName(AVCodecID id);
    static QString codecIdToLongName(AVCodecID id);

    // 异步播放：Worker 线程解码指定帧（画面+块），完成后回主线程更新缓存
    void runPlayStepAsync(int slot, int frameIndex);
    void onPlayStepFinished(int slot);
    // 停止并等待该 slot 的异步解码任务结束（销毁解码器前必须调用）
    void cancelPlayAsync(int slot);
    QFutureWatcher<void>* m_playWatchers[MaxSlots]{nullptr};

    Slot m_slots[MaxSlots];
    int  m_slotCount = 0;
    int  m_prescanning = 0;  // 0/1，简单布尔占位
};
