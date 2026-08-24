#pragma once
/**
 * RBStreamBridge.h — 码流分析模块的 Qt/QML 桥接层（多 slot 版本）
 *
 * 设计目标（与 码流分析架构.md §5 一致）：
 *   - 多 slot（最多 3 路，与 YuvBridge 一致），每路独立 RBDemuxer 复用做预扫描；
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
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QSettings>
#include <cstdio>
#include <memory>
#include <vector>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/pixfmt.h>
}

namespace rb {
class RBDemuxer;
}

class RBStreamBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(int slotCount READ slotCount NOTIFY slotCountChanged)
    Q_PROPERTY(int prescanning READ prescanning NOTIFY prescanningChanged)
    // 暴露给 QML 的最大 slot 数（与 YuvBridge.MaxSlots 一致），便于
    // setup 阶段对 "可打开文件数" 做硬性裁剪。
    Q_PROPERTY(int maxSlots READ maxSlots CONSTANT)

public:
    static constexpr int MaxSlots = 3;

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

    // ── 块级信息（CU 划分 / QP / MV）—— 一期占位 ────────────────
    // 返回 QVariantList（每项一帧内一个块）：
    //   { x, y, w, h, qp, isSkip, isIntra, mvx, mvy }
    // 一期不接 FFmpeg 补丁，返回空数组；UI 走"该格式暂不支持块级分析"降级。
    Q_INVOKABLE QVariantList blockInfoAt(int slot, int frameIndex) const;

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

signals:
    void slotCountChanged();
    void prescanningChanged();
    void prescanProgress(int slot, double ratio); // 大文件预扫描进度（占位）
    void frameReady(int slot, int frameIndex);    // 块级信息异步就绪（占位）
    void fileOpened(int slot);
    void fileClosed(int slot);
    void currentFrameChanged(int slot);

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
        std::vector<long long> frameSizes;        // 每帧字节数（来自 AVPacket.size）
        std::vector<double>  frameAvgQp;          // 每帧平均 QP（未启用补丁：-1）
        long long cpbSizeBits = 0;                // SPS 声明的 CPB 容量（0=未知）
        long long cbrBitrateBits = 0;             // SPS 声明的目标码率（0=未知）
    };

    bool parseSlot(int slot, Slot& s, rb::RBDemuxer& demuxer);
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

    Slot m_slots[MaxSlots];
    int  m_slotCount = 0;
    int  m_prescanning = 0;  // 0/1，简单布尔占位
};
