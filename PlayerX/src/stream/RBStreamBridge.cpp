/**
 * RBStreamBridge.cpp — 码流分析桥接层实现
 *
 * 一期（P0）实现要点：
 *   1) openFile() 内部用 RBDemuxer 临时打开文件，只读不启动线程；
 *      拿到顶层流参数后用 av_read_frame 顺序遍历一遍包，统计：
 *        · 每包字节数（→ frameSizes）
 *        · 每包 NAL type（h264/hevc）粗判 I/P/B 帧
 *        · 简易 GOP 切分（每个 IDR/I 帧视为 GOP 起点）
 *      预扫描完关闭 RBDemuxer，避免长期占用文件句柄。
 *   2) SPS/VUI 解析（cpbSize / bitrate）依赖 Exp-Golomb 码流解析，
 *      一期不实现精细解析，cpbSizeBits / cbrBitrateBits 全部置 0；
 *      hrdEstimate() 看到 available=false 即返回"无估算"。
 *   3) blockInfoAt() 一律返回空数组；UI 走"该格式暂不支持块级分析"降级。
 *
 * 说明：以上"不实现精细解析"的部分后续按架构 §4 走 FFmpeg 解码器补丁路径
 *       补齐，不在本文件中留坑。RBStreamAnalyzer 类按 §3 设计是独立模块，
 *       本桥接层目前直接做扫描是因为范围小（h264/hevc mp4+annexb），
 *       后续可拆出 RBStreamAnalyzer/RBBitstreamParser 替换此处实现。
 */

#include "stream/RBStreamBridge.h"
#include "stream/RBBlockAnalyzer.h"
#include "stream/RBSyntaxAnalyzer.h"
#include "core/rb_demuxer.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/pixdesc.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <cmath>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QImage>
#include <QTextStream>
#include <QCryptographicHash>
#include <QDebug>
#include <QPainter>
#include <QFont>
#include <QColor>
#include <cstring>

// 编码序 ↔ 显示序映射换算（定义在文件后部，此处前置声明供前部函数使用）
static int dispToCodeOf(const rb::RBFrameOrderMapper::Result& om, int d);
static int codeToDispOf(const rb::RBFrameOrderMapper::Result& om, int c);

namespace {
// 简易帧类型判定（仅 h264 / hevc）：
//   h264: nal_unit_type ∈ {5} → IDR；{1..4,6..9} 视同非 IDR（这里用启发：第一个非 IDR 标记 P）
//   hevc: nal_unit_type ∈ {19,20} → IDR；其余非 IDR 标 P
//   不区分 P / B（一期够用；UI 染色按"关键帧黄 / 其他蓝"已能呈现 GOP 节奏）
//
// 实际更稳的判定：参照 RBDecoder/FFmpeg 内部查 h264_slice / hevc_slice_header，
// 但那需要打开解码器。一期避免解码开销，先用 NAL type 启发即可。
int classifyNalUnitTypeH264(int nalType) {
    if (nalType == 5) return 3;          // IDR
    if (nalType == 1) return 1;          // 标 P（h264 全部非 IDR slice 视为 P）
    if (nalType == 7) return -1;         // SPS
    if (nalType == 8) return -1;         // PPS
    return 0;                            // 其它
}
int classifyNalUnitTypeHevc(int nalType) {
    if (nalType == 19 || nalType == 20) return 3;  // IDR_W_RADL / IDR_N_LP
    if (nalType == 0 || nalType == 1)  return 1;   // TRAIL_N / TRAIL_R 视作 P
    if (nalType == 32) return -1;        // SPS
    if (nalType == 33) return -1;        // PPS
    return 0;
}

// AnnexB 起头 0x00 0x00 0x00 0x01 / 0x00 0x00 0x01
// 不做完整 NAL split，只取前几个字节定位 nal_unit_type。
int peekNalTypeAnnexB(const uint8_t* data, int size) {
    if (!data || size < 5) return -1;
    int i = 0;
    if (data[0] == 0 && data[1] == 0) {
        if (data[2] == 1)              { i = 3; }
        else if (data[2] == 0 && data[3] == 1) { i = 4; }
        else return -1;
    }
    if (i >= size) return -1;
    return data[i] & 0x1F;   // h264 末 5 bit 是 nal_unit_type
}

// AVCC 长度前缀模式：前 N 字节是 NAL 长度（按 AVCC lengthSizeMinusOne+1）
int peekNalTypeAvcc(const uint8_t* data, int size, int lengthSize) {
    if (!data || size < lengthSize + 1) return -1;
    int nalLen = 0;
    for (int i = 0; i < lengthSize; ++i) {
        nalLen = (nalLen << 8) | data[i];
    }
    if (nalLen <= 0 || lengthSize + nalLen > size) return -1;
    return data[lengthSize] & 0x1F;  // h264 末 5 bit
}

// VVC（H.266）帧类型判定：
//   nal_unit_type ∈ {7,8} → IDR_W_RADL / IDR_N_LP
//   nal_unit_type ∈ {9,10} → CRA / GDR（同为 IRAP 关键帧，按 IDR 处理以切 GOP）
//   nal_unit_type ∈ {0,1,2,3} → TRAIL/STSA/RADL/RASL 视作 P
//   nal_unit_type ∈ {15,16} → SPS / PPS（非 VCL，跳过）
// 不区分 P / B（与 h264/hevc 分支保持一致）。
[[maybe_unused]] int classifyNalUnitTypeVvc(int nalType) {
    if (nalType == 7 || nalType == 8)  return 3;   // IDR_W_RADL / IDR_N_LP
    if (nalType == 9 || nalType == 10) return 3;   // CRA / GDR（IRAP）
    if (nalType == 0 || nalType == 1 ||
        nalType == 2 || nalType == 3)  return 1;   // TRAIL / STSA / RADL / RASL
    if (nalType == 15 || nalType == 16) return -1; // SPS / PPS
    return 0;
}

// ★ VVC 的 NAL header 布局与 HEVC 不同，必须单独处理：
//   HEVC: forbidden(1) | type(6) | layer_id(6) | tid(3)   → type 在 bit1..bit6
//   VVC : forbidden(1) | reserved(1) | layer_id(6) | type(5) | tid(3) → type 在 bit8..bit12
// 因此 VVC 的 nal_unit_type 位于 **第 2 个字节**（bit8..bit12），
// 提取方式为 (b1 >> 3) & 0x1F，而 HEVC 是 (b0 & 0x7E) >> 1。
// 若沿用 HEVC 的掩码解析 VVC，type 会整体错位，导致帧类型/GOP 全判错。
[[maybe_unused]] int peekNalTypeVvcAnnexB(const uint8_t* data, int size) {
    if (!data || size < 6) return -1;
    int i = 0;
    if (data[0] == 0 && data[1] == 0) {
        if (data[2] == 1)              { i = 3; }
        else if (data[2] == 0 && data[3] == 1) { i = 4; }
        else return -1;
    }
    // VVC header 是 2 字节：需要 i+1 < size
    if (i + 1 >= size) return -1;
    return (data[i + 1] >> 3) & 0x1F;
}
[[maybe_unused]] int peekNalTypeVvcAvcc(const uint8_t* data, int size, int lengthSize) {
    if (!data || size < lengthSize + 2) return -1;
    int nalLen = 0;
    for (int i = 0; i < lengthSize; ++i) {
        nalLen = (nalLen << 8) | data[i];
    }
    if (nalLen <= 0 || lengthSize + nalLen > size) return -1;
    // 第 2 个字节（bit8..bit12）才是 type
    return (data[lengthSize + 1] >> 3) & 0x1F;
}

// hevc 的 nal_unit_type 是首字节的 bit1..bit6（mask 0x7E 右移 1）
int peekNalTypeHevcAnnexB(const uint8_t* data, int size) {
    if (!data || size < 5) return -1;
    int i = 0;
    if (data[0] == 0 && data[1] == 0) {
        if (data[2] == 1)              { i = 3; }
        else if (data[2] == 0 && data[3] == 1) { i = 4; }
        else return -1;
    }
    if (i >= size) return -1;
    return (data[i] & 0x7E) >> 1;
}
int peekNalTypeHevcAvcc(const uint8_t* data, int size, int lengthSize) {
    if (!data || size < lengthSize + 1) return -1;
    int nalLen = 0;
    for (int i = 0; i < lengthSize; ++i) {
        nalLen = (nalLen << 8) | data[i];
    }
    if (nalLen <= 0 || lengthSize + nalLen > size) return -1;
    return (data[lengthSize] & 0x7E) >> 1;
}

// 语法缓存里按字段名取整数值。CBS 字段名可能带数组下标，用精确匹配。
int syntaxFieldInt(const QVariantList& cache, const QString& name, bool* found) {
    for (const QVariant& v : cache) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("name")).toString() == name) {
            if (found) *found = true;
            return m.value(QStringLiteral("value")).toInt();
        }
    }
    if (found) *found = false;
    return 0;
}

// 按编解码语法取 CtbSizeY / 宏块边长：
//   VVC  : CtbSizeY = 1 << (sps_log2_ctu_size_minus5 + 5)   ∈ {32,64,128}
//   HEVC : CtbSizeY = 1 << (log2_min_luma_cb + 3 + log2_diff_max_min) ∈ {16,32,64}
//   H.264: 宏块固定 16
int ctuSizeFromSyntax(const QString& codec, const QVariantList& syntax) {
    bool found = false;
    if (codec == QLatin1String("vvc") || codec == QLatin1String("h266")) {
        const int v = syntaxFieldInt(syntax, QStringLiteral("sps_log2_ctu_size_minus5"), &found);
        if (found) {
            const int sz = 1 << (v + 5);
            if (sz >= 32 && sz <= 128) return sz;
        }
        return 128;
    }
    if (codec == QLatin1String("hevc") || codec == QLatin1String("h265")) {
        bool fMin = false, fDiff = false;
        const int min3 = syntaxFieldInt(syntax,
            QStringLiteral("log2_min_luma_coding_block_size_minus3"), &fMin);
        const int diff = syntaxFieldInt(syntax,
            QStringLiteral("log2_diff_max_min_luma_coding_block_size"), &fDiff);
        if (fMin && fDiff) {
            const int log2 = min3 + 3 + diff;
            if (log2 >= 4 && log2 <= 6) return 1 << log2;
        }
        return 64;
    }
    return 16;   // H.264 宏块
}

// QT 划分深度：每做一次四叉树分裂 depth + 1。
// 例：CTU 128 → 64×64 为 depth 1；128 → 32×32 为 depth 2。
// 非方形（VVC BT/TT）按较长边对齐到 2 的幂，对应 QT 深度（MTT 不再加层）。
int qtSplitDepth(int ctu, int w, int h) {
    if (ctu <= 1 || w <= 0 || h <= 0) return 0;
    int side = std::max(w, h);
    int p2 = 1;
    while (p2 < side) p2 <<= 1;
    if (p2 > ctu) p2 = ctu;
    int d = 0;
    for (int s = ctu; s > p2; s >>= 1) ++d;
    return d;
}

} // namespace

RBStreamBridge::RBStreamBridge(QObject* parent)
    : QObject(parent) {}

RBStreamBridge::~RBStreamBridge() {
    closeAll();
}

int RBStreamBridge::openFile(const QString& path) {
    if (path.isEmpty()) return -1;
    // 找一个空 slot
    int slot = -1;
    for (int i = 0; i < MaxSlots; ++i) {
        if (!m_slots[i].inUse) { slot = i; break; }
    }
    if (slot < 0) return -1;   // 已满

    Slot s;
    s.path = path;

    // 用 RBDemuxer 临时打开：不开线程，只为拿 AVFormatContext / CodecParameters
    rb::RBDemuxer demuxer;
    bool ok = false;
    if (demuxer.rbOpen(path.toStdString())) {
        ok = parseSlot(slot, s, demuxer);
        demuxer.rbClose();
    } else {
        qWarning() << "[StreamBridge] rbOpen failed, try raw annexb fallback:" << path;
    }

    // 裸流 fallback：.h264 / .265 / .hevc 后缀走 annexb 直读
    if (!ok) {
        if (parseRawAnnexB(s)) {
            ok = true;
        }
    }

    if (!ok) {
        qWarning() << "[StreamBridge] parse failed for" << path;
        return -1;
    }

    // 日志在 move 之前打印，避免 moved-from 状态导致字段全空
    qInfo() << "[StreamBridge] openFile ok slot=" << slot
            << "path=" << s.path
            << "w=" << s.width << "h=" << s.height
            << "fps=" << (s.fps.den > 0 ? double(s.fps.num)/s.fps.den : 0)
            << "codec=" << s.codecName
            << "frames=" << s.frameTypes.size();

    m_slots[slot] = std::move(s);
    m_slots[slot].inUse = true;
    ++m_slotCount;

    // 恢复用户上次的「编码顺序」勾选偏好（持久化于 QSettings）。
    // 在 fileOpened 之前设置：StreamView 打开瞬间读到的即最终状态；
    // fileOpened 之后再补发 frameOrderModeChanged 让 QML orderMode
    // 属性同步（否则重启后 QML 默认 0，开关显示与 C++ 状态不一致，
    // 表现为「明明勾选着却要重新点一下才生效」）。
    {
        QSettings settings("PlayerX", "RBStreamBridge");
        const int saved = settings.value("frameOrderMode", 0).toInt();
        if (saved == 1) m_slots[slot].frameOrderMode = 1;
    }

    emit slotCountChanged();
    emit fileOpened(slot);
    if (m_slots[slot].frameOrderMode == 1)
        emit frameOrderModeChanged(slot);
    // 后台一次解析 slice 头得到真实层级与参考关系（层级面板），结果缓存后只读。
    // hevc/vvc：解析完成回调里用逐帧 POC 快速合成映射（0.6s@4K VVC），
    // 不再预启动整流解码（2.2s）；解析失败时回调内自动回退整流解码。
    startRefStructBuild(slot);
    // h264 等解析器不支持的编码：解析器不启动（内部按编码分流），
    // 直接走整流解码建立映射，行为与此前一致。
    {
        const QString& cn = m_slots[slot].codecName;
        if (cn != "hevc" && cn != "h265" && cn != "vvc" && cn != "h266")
            startOrderMapBuild(slot);
    }
    // 后台一次 CBS 解析 SPS/PPS/VPS 名值对（右侧栏 Syntax Info），结果缓存后只读。
    startSyntaxBuild(slot);
    return slot;
}

bool RBStreamBridge::parseSlot(int slot, Slot& s, rb::RBDemuxer& demuxer) {
    Q_UNUSED(slot);
    AVFormatContext* fmt = nullptr;
    // 通过 demuxer 内部成员（友元不可得）→ 改用 avformat 重新打开不现实；
    // 改方案：直接调 avformat_open_input + av_read_frame 做一次性扫描，
    // 不复用 RBDemuxer 的线程模型（线程在 RBStreamBridge 用不上）。

    if (avformat_open_input(&fmt, s.path.toStdString().c_str(), nullptr, nullptr) < 0) {
        qWarning() << "[StreamBridge] avformat_open_input failed";
        return false;
    }
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        qWarning() << "[StreamBridge] avformat_find_stream_info failed";
        avformat_close_input(&fmt);
        return false;
    }
    // 取视频流
    int vIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (vIdx < 0) {
        qWarning() << "[StreamBridge] no video stream, nb_streams=" << fmt->nb_streams;
        avformat_close_input(&fmt);
        return false;
    }
    qInfo() << "[StreamBridge] parseSlot ok: streams=" << fmt->nb_streams
            << "vIdx=" << vIdx
            << "path=" << s.path;
    AVStream* vs = fmt->streams[vIdx];
    AVCodecParameters* par = vs->codecpar;

    s.width  = par->width;
    s.height = par->height;
    s.fps    = vs->avg_frame_rate.num > 0 ? vs->avg_frame_rate
                                          : vs->r_frame_rate;
    s.duration = fmt->duration > 0 ? double(fmt->duration) / AV_TIME_BASE : 0.0;
    s.bitrate = fmt->bit_rate;
    s.pixFmt = static_cast<AVPixelFormat>(par->format);
    s.colorSpace = par->color_space;
    s.colorRange = par->color_range;
    s.profile = par->profile;
    s.level   = par->level;
    if (par->codec_id == AV_CODEC_ID_H264) {
        s.codecName = "h264";
        s.codecLongName = "H.264 / AVC";
    } else if (par->codec_id == AV_CODEC_ID_HEVC) {
        s.codecName = "hevc";
        s.codecLongName = "H.265 / HEVC";
    } else if (par->codec_id == AV_CODEC_ID_VVC) {
        s.codecName = "vvc";
        s.codecLongName = "H.266 / VVC";
    } else {
        // 非 h264/hevc（vp9/av1/mpeg 等）：用编码器短名，不要用容器名
        s.codecName = codecIdToShortName(par->codec_id);
        s.codecLongName = codecIdToLongName(par->codec_id);
    }

    // 记录容器格式名（供 UI 展示）
    s.containerFormat = fmt->iformat ? QString::fromUtf8(fmt->iformat->name) : "";
    s.containerLongName = fmt->iformat ? QString::fromUtf8(fmt->iformat->long_name) : "";

    // 决定 NAL 读取方式：AnnexB（裸流）vs AVCC（mp4 等封装）
    //   · annexb：H.265 raw / h264 raw / m2ts / ts / flv 等
    //   · avcc  ：mp4 / mov / 3gp / m4v 等
    bool isAnnexB = fmt->iformat->name
                    && (std::strcmp(fmt->iformat->name, "h264") == 0
                        || std::strcmp(fmt->iformat->name, "hevc") == 0
                        || std::strcmp(fmt->iformat->name, "vvc") == 0
                        || std::strcmp(fmt->iformat->name, "mpegts") == 0
                        || std::strcmp(fmt->iformat->name, "flv") == 0
                        || std::strcmp(fmt->iformat->name, "matroska") == 0
                        || std::strcmp(fmt->iformat->name, "aac") == 0);
    int avccLengthSize = 0;  // mp4: 4 字节长度
    // 保存容器 extradata 拷贝（语法面板：avcC/hvcC/vvcC 参数集，后台 CBS 解析用）
    if (par->extradata && par->extradata_size > 0) {
        s.extradataCopy = QByteArray(reinterpret_cast<const char*>(par->extradata),
                                     par->extradata_size);
    }
    if (!isAnnexB) {
        // 从 extradata 解析 AVCC lengthSizeMinusOne（h264 7bit / hevc 6bit）
        // VVC 的 mp4 封装同样使用长度前缀（4 字节），无 AVCC 结构可解析，走默认。
        if (par->extradata && par->extradata_size > 0) {
            if (s.codecName == "h264" && par->extradata_size >= 5) {
                avccLengthSize = (par->extradata[4] & 0x03) + 1;
            } else if (s.codecName == "hevc" && par->extradata_size >= 3) {
                avccLengthSize = (par->extradata[2] & 0x03) + 1;
            } else {
                avccLengthSize = 4;  // mp4 默认 4 字节（含 VVC）
            }
        } else {
            avccLengthSize = 4;
        }
    }

    // ── 预扫描：顺序读包，统计帧类型 / 大小 / GOP 切分 ──
    m_prescanning = 1;
    emit prescanningChanged();
    s.frameTypes.clear();
    s.frameSizes.clear();
    s.frameAvgQp.assign(1, -1.0);  // 占位
    s.gopStartFrames.clear();
    s.gopFrameCounts.clear();
    s.gopIsOpen.clear();

    AVPacket* pkt = av_packet_alloc();
    int  gopStart = 0;
    bool firstFrame = true;
    int  framesInGop = 0;
    int  frameIdx = 0;

    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == vIdx) {
            // 帧类型判定：
            //   IDR → AV_PKT_FLAG_KEY 且第一帧或紧接 key 之后
            //   I   → AV_PKT_FLAG_KEY（非第一帧）
            //   P   → 非 key 帧（B 帧一期不区分）
            // 用 av_packet_flag_key(pkt) 可靠覆盖 annexb 和 avcc 两种封装，
            // 不依赖 NAL type 启发——避免 SPS/PPS NAL 导致整包被丢弃。
            int type = 1;  // 默认 P
            if (pkt->flags & AV_PKT_FLAG_KEY) {
                type = (firstFrame || s.frameTypes.empty()) ? 3 : 0;  // 首帧 IDR / 其余 I
            }
            // 每帧字节数
            s.frameSizes.push_back(pkt->size);
            // IDR / I 帧：GOP 起点
            if (type == 3 || (type == 0 && firstFrame)) {
                if (!firstFrame) {
                    s.gopFrameCounts.push_back(framesInGop);
                    s.gopIsOpen.push_back(false);  // 一期占位：closed GOP
                }
                s.gopStartFrames.push_back(frameIdx);
                framesInGop = 0;
                firstFrame  = false;
            }
            s.frameTypes.push_back(type);
            ++framesInGop;
            ++frameIdx;
        }
        av_packet_unref(pkt);
    }
    // 收尾 GOP
    if (!firstFrame) {
        s.gopFrameCounts.push_back(framesInGop);
        s.gopIsOpen.push_back(false);
    }
    av_packet_free(&pkt);

    // 若没扫到任何 GOP（极小文件 / 全是 SEI），手动建一个 GOP
    if (s.gopStartFrames.empty() && !s.frameTypes.empty()) {
        s.gopStartFrames.push_back(0);
        s.gopFrameCounts.push_back(int(s.frameTypes.size()));
        s.gopIsOpen.push_back(false);
    }

    // 编码序 POC 由后台映射器（RBFrameOrderMapper）真解码建立，见 buildOrderMap()

    // ── SPS/VUI 解析：解析码率 / CPB 容量（h264 仅基础，hevc 留空） ──
    // 一期：不展开完整 Exp-Golomb 解析，cpb 字段保持 0 → hrdEstimate available=false。
    // UI 端走"暂无法估算 HRD"降级显示，避免假数据误导用户。
    s.cpbSizeBits   = 0;
    s.cbrBitrateBits = 0;

    avformat_close_input(&fmt);
    m_prescanning = 0;
    emit prescanningChanged();
    return true;
}

void RBStreamBridge::freeSlot(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_slots[slot].inUse) return;
    // 关键：先停掉该 slot 的异步解码任务并等待其真正结束。
    // 否则 Worker 线程仍在 rbBlockInfoAt() 里使用 AVCodecContext，
    // 而下面 m_slots[slot] = Slot{} 会销毁解码器 → 野指针崩溃
    // （崩溃栈：ff_executor_execute / task_stage_done 空指针）。
    cancelPlayAsync(slot);
    // 映射构建 worker 持有 &Slot 指针，重置前必须先取消并等待其结束，否则野指针。
    cancelOrderMap(slot);
    // 语法解析 worker 是纯函数式（拷贝参数、不触碰 Slot），但 watcher 需回收防悬挂。
    if (auto* w = m_slots[slot].syntaxWatcher) {
        disconnect(w, nullptr, this, nullptr);
        if (w->isRunning() || w->isStarted())
            w->waitForFinished();
        w->deleteLater();
        m_slots[slot].syntaxWatcher = nullptr;
    }
    if (auto* w = m_slots[slot].sliceWatcher) {
        disconnect(w, nullptr, this, nullptr);
        if (w->isRunning() || w->isStarted())
            w->waitForFinished();
        w->deleteLater();
        m_slots[slot].sliceWatcher = nullptr;
    }
    // 参考结构解析同样是纯函数式 worker，watcher 需回收防悬挂。
    if (auto* w = m_slots[slot].refStructWatcher) {
        disconnect(w, nullptr, this, nullptr);
        if (w->isRunning() || w->isStarted())
            w->waitForFinished();
        w->deleteLater();
        m_slots[slot].refStructWatcher = nullptr;
    }
    m_slots[slot] = Slot{};
    --m_slotCount;
    if (m_slotCount < 0) m_slotCount = 0;
}

void RBStreamBridge::closeSlot(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_slots[slot].inUse) return;
    freeSlot(slot);
    emit slotCountChanged();
    emit fileClosed(slot);
}

void RBStreamBridge::closeAll() {
    bool any = false;
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_slots[i].inUse) {
            // 同 freeSlot：销毁解码器前必须先结束异步任务
            cancelPlayAsync(i);
            m_slots[i] = Slot{};
            any = true;
        }
    }
    if (any) {
        m_slotCount = 0;
        emit slotCountChanged();
    }
}

bool RBStreamBridge::hasFile(int slot) const {
    return slot >= 0 && slot < MaxSlots && m_slots[slot].inUse;
}
QString RBStreamBridge::filePath(int slot) const {
    if (!hasFile(slot)) return QString();
    return m_slots[slot].path;
}
QString RBStreamBridge::fileName(int slot) const {
    if (!hasFile(slot)) return QString();
    const QString& p = m_slots[slot].path;
    int idx = p.lastIndexOf('/');
    int idx2 = p.lastIndexOf('\\');
    int i = qMax(idx, idx2);
    return i >= 0 ? p.mid(i + 1) : p;
}
QString RBStreamBridge::codecName(int slot) const {
    return hasFile(slot) ? m_slots[slot].codecName : QString();
}
QString RBStreamBridge::codecLongName(int slot) const {
    return hasFile(slot) ? m_slots[slot].codecLongName : QString();
}
int RBStreamBridge::width(int slot) const {
    return hasFile(slot) ? m_slots[slot].width : 0;
}
int RBStreamBridge::height(int slot) const {
    return hasFile(slot) ? m_slots[slot].height : 0;
}
double RBStreamBridge::fps(int slot) const {
    if (!hasFile(slot)) return 0;
    const auto& fr = m_slots[slot].fps;
    return fr.den > 0 ? double(fr.num) / fr.den : 0;
}
double RBStreamBridge::durationSec(int slot) const {
    return hasFile(slot) ? m_slots[slot].duration : 0;
}
long long RBStreamBridge::bitrate(int slot) const {
    return hasFile(slot) ? m_slots[slot].bitrate : 0;
}
QString RBStreamBridge::pixFmtName(int slot) const {
    if (!hasFile(slot)) return QString();
    return pixFmtToString(m_slots[slot].pixFmt);
}
QString RBStreamBridge::colorSpaceName(int slot) const {
    if (!hasFile(slot)) return QString();
    return colorSpaceToString(m_slots[slot].colorSpace);
}
QString RBStreamBridge::colorRangeName(int slot) const {
    if (!hasFile(slot)) return QString();
    return colorRangeToString(m_slots[slot].colorRange);
}
QString RBStreamBridge::profileName(int slot) const {
    if (!hasFile(slot)) return QString();
    // h264 需结合 codecId 才能正确翻译，hevc 同理
    if (m_slots[slot].codecName == "h264") {
        return profileIdToString(AV_CODEC_ID_H264, m_slots[slot].profile);
    }
    if (m_slots[slot].codecName == "hevc") {
        return profileIdToString(AV_CODEC_ID_HEVC, m_slots[slot].profile);
    }
    if (m_slots[slot].codecName == "vvc") {
        return profileIdToString(AV_CODEC_ID_VVC, m_slots[slot].profile);
    }
    return QString::number(m_slots[slot].profile);
}
int RBStreamBridge::profileId(int slot) const {
    return hasFile(slot) ? m_slots[slot].profile : -100;
}
int RBStreamBridge::levelId(int slot) const {
    return hasFile(slot) ? m_slots[slot].level : -100;
}

int RBStreamBridge::frameCount(int slot) const {
    if (!hasFile(slot)) return 0;
    return int(m_slots[slot].frameTypes.size());
}
int RBStreamBridge::currentFrame(int slot) const {
    if (!hasFile(slot)) return 0;
    return m_slots[slot].currentFrame;
}
void RBStreamBridge::gotoFrame(int slot, int frame) {
    if (!hasFile(slot)) return;
    int n = frameCount(slot);
    if (n <= 0) return;
    if (frame < 0) frame = 0;
    if (frame >= n) frame = n - 1;
    if (m_slots[slot].currentFrame != frame) {
        m_slots[slot].currentFrame = frame;
        emit currentFrameChanged(slot);
        requestSliceSyntax(slot);
    }
}
void RBStreamBridge::nextFrame(int slot) { gotoFrame(slot, currentFrame(slot) + 1); }
void RBStreamBridge::prevFrame(int slot) { gotoFrame(slot, currentFrame(slot) - 1); }
void RBStreamBridge::firstFrame(int slot) { gotoFrame(slot, 0); }

QVariantMap RBStreamBridge::streamInfo(int slot) const {
    QVariantMap m;
    if (!hasFile(slot)) return m;
    const Slot& s = m_slots[slot];
    m["codec"]        = s.codecName;
    m["codecLong"]    = s.codecLongName;
    m["profile"]      = profileName(slot);
    m["level"]        = QString::number(s.level);
    m["width"]        = s.width;
    m["height"]       = s.height;
    m["fps"]          = fps(slot);
    m["duration"]     = s.duration;
    m["bitrate"]      = double(s.bitrate);
    m["pixFmt"]       = pixFmtName(slot);
    m["colorSpace"]   = colorSpaceName(slot);
    m["colorRange"]   = colorRangeName(slot);
    m["frameCount"]   = int(s.frameTypes.size());
    m["fileName"]     = fileName(slot);
    m["filePath"]     = s.path;
    m["containerFormat"]   = s.containerFormat;
    m["containerLongName"] = s.containerLongName;
    return m;
}

QVariantList RBStreamBridge::frameList(int slot) const {
    QVariantList list;
    if (!hasFile(slot)) return list;
    const Slot& s = m_slots[slot];
    const int n = int(s.frameTypes.size());
    list.reserve(n);
    const double fpsv = fps(slot) > 0 ? fps(slot) : 30.0;

    // ── 有真实映射（RBFrameOrderMapper 后台解码建立的编码序↔显示序双射）──
    // 真实 POC 语义：一帧在显示序里的位置（每个 IDR 处复位从 0 计）。
    if (s.orderMap.ok) {
        const bool codingOrder = (s.frameOrderMode == 1);
        if (!codingOrder) {
            // 显示顺序：按解码器真实输出序遍历（dispToCode），POC = 显示位置（IDR 复位）
            const int nd = int(s.orderMap.dispToCode.size());
            int pocBase = 0;
            for (int d = 0; d < nd; ++d) {
                const int c = s.orderMap.dispToCode[d];
                if (c < 0 || c >= n) continue;
                int t = s.frameTypes[c];
                if (c < int(s.orderMap.codePictType.size())) {
                    const int real = s.orderMap.codePictType[c];
                    if (real == 1 || real == 2) t = real;         // P/B 以解码器为准
                    else if (real == 0 && t != 3) t = 0;          // I（非 IDR）
                }
                if (t == 3) pocBase = d;
                const int pocVal = d - pocBase;
                const double ptsSec = double(d) / fpsv;
                list.append(frameItemToMap(c, t,
                                           (c < int(s.frameSizes.size())) ? s.frameSizes[c] : 0,
                                           ptsSec, ptsSec, pocVal,
                                           (c < int(s.frameAvgQp.size())) ? s.frameAvgQp[c] : s.frameAvgQp[0]));
            }
            return list;
        }
        // 编码顺序：按编码序（包序）列出，POC = 该帧的显示序位置 codeToDisp[i]
        // GOP=4（编码序 I P B B）→ POC = 0,4,2,1,3
        for (int i = 0; i < n; ++i) {
            int t = s.frameTypes[i];
            if (i < int(s.orderMap.codePictType.size())) {
                const int real = s.orderMap.codePictType[i];
                if (real == 0 || real == 1 || real == 2)
                    t = (t == 3) ? 3 : real;                      // 保留 IDR 判定
            }
            const int dispIdx = (i < int(s.orderMap.codeToDisp.size()))
                                ? s.orderMap.codeToDisp[i] : -1;
            const double ptsSec = (dispIdx >= 0) ? double(dispIdx) / fpsv : double(i) / fpsv;
            list.append(frameItemToMap(i, t,
                                       (i < int(s.frameSizes.size())) ? s.frameSizes[i] : 0,
                                       ptsSec, ptsSec,
                                       (dispIdx >= 0) ? dispIdx : i,
                                       (i < int(s.frameAvgQp.size())) ? s.frameAvgQp[i] : s.frameAvgQp[0]));
        }
        return list;
    }

    // ── 映射未就绪（打开瞬间/构建中/非 hevc-h264-vvc）：简易递增 POC，保证秒开先有值 ──
    int poc = 0;
    for (int i = 0; i < n; ++i) {
        int t = s.frameTypes[i];
        double ptsSec = double(i) / fpsv;
        list.append(frameItemToMap(i, t, s.frameSizes[i], ptsSec, ptsSec, poc, s.frameAvgQp[0]));
        if (t == 3) poc = 0; else ++poc;
    }
    return list;
}

QVariantList RBStreamBridge::gopList(int slot) const {
    QVariantList list;
    if (!hasFile(slot)) return list;
    const Slot& s = m_slots[slot];
    for (int i = 0; i < int(s.gopStartFrames.size()); ++i) {
        QVariantMap m;
        m["startFrameIndex"] = s.gopStartFrames[i];
        m["frameCount"]      = s.gopFrameCounts[i];
        m["isOpenGop"]       = bool(s.gopIsOpen[i]);
        list.append(m);
    }
    return list;
}

// 编码顺序勾选：只切换 POC 展示口径（显示序 / 编码序），不重建解码器、
// 不触发解码、不影响播放与秒开。真实 POC 由后台映射器（startOrderMapBuild）提供。
int RBStreamBridge::frameOrderMode(int slot) const {
    if (!hasFile(slot)) return 0;
    return m_slots[slot].frameOrderMode;
}
// ── UI 帧号 → 解码器输出序索引 ──
// decodeFrameAt(n) 的语义是「第 n 个输出帧」（=显示序），而 UI 在编码顺序模式下
// 列表与跳转用的是编码序（包序）。不换算的话画面会一直按播放序渲染
// （水印 1080-0 → 1080-1 → 1080-2 递增），与层级图的编码序对不上。
// 显示顺序模式或映射未就绪时原样返回，保持旧行为。
int RBStreamBridge::decodeIndexOf(int slot, int frameIndex) const {
    if (!hasFile(slot)) return frameIndex;
    const Slot& s = m_slots[slot];
    if (s.frameOrderMode != 1) return frameIndex;   // 显示顺序：同序
    if (!s.orderMap.ok) return frameIndex;          // 映射未就绪
    const int d = codeToDispOf(s.orderMap, frameIndex);
    return (d >= 0) ? d : frameIndex;               // 换算失败退回原值
}
void RBStreamBridge::setFrameOrderMode(int slot, int mode) {
    if (!hasFile(slot)) return;
    int& cur = m_slots[slot].frameOrderMode;
    const int next = (mode == 1) ? 1 : 0;
    if (cur != next) {
        cur = next;
        // 持久化：记住用户偏好，下次打开同一文件（或重启）自动恢复。
        // 语义：勾选编码顺序 → 任何新打开的文件都尝试继承该偏好。
        {
            QSettings settings("PlayerX", "RBStreamBridge");
            settings.setValue("frameOrderMode", next);
        }
        emit frameOrderModeChanged(slot);
        requestSliceSyntax(slot);
    }
}

// 映射是否就绪：后台解码完成且结果有效。未就绪时 UI 保持显示顺序、勾选禁用。
bool RBStreamBridge::frameOrderMapReady(int slot) const {
    if (!hasFile(slot)) return false;
    const Slot& s = m_slots[slot];
    return s.orderMapBuilding == 0 && s.orderMap.ok;
}

// 启动后台映射构建（打开文件后调用）：独立线程整流解码一遍，
// 建立编码序↔显示序双射。与播放/块级解码零共享，不阻塞秒开。
// 仅作回退路径：hevc/vvc 的首选路径在 onRefStructBuilt 里用解析器 POC
// 快速合成（0.6s vs 2.2s@4K VVC）；解析失败/不支持时才走到这里。
void RBStreamBridge::startOrderMapBuild(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (!s.inUse || s.orderMapWatcher) return;   // 已在构建或已完成

    s.orderMapBuilding = 1;
    Slot* target = &s;   // Slot 数组固定，指针稳定（freeSlot 前 cancel 已等待）
    auto cancel = std::make_shared<std::atomic_bool>(false);
    s.orderMapCancel = cancel;

    QFuture<void> future = QtConcurrent::run([target, cancel]() {
        // 纯 Worker：独立解码整个流（软解、无 side_data），与其它组件零共享。
        target->orderMap = rb::RBFrameOrderMapper::build(target->path.toStdString(),
                                                         cancel.get());
    });
    s.orderMapWatcher = new QFutureWatcher<void>(this);
    s.orderMapWatcher->setFuture(future);
    connect(s.orderMapWatcher, &QFutureWatcher<void>::finished,
            this, [this, slot]() { onOrderMapBuilt(slot); });
}

void RBStreamBridge::onOrderMapBuilt(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (s.orderMapWatcher) {
        s.orderMapWatcher->deleteLater();
        s.orderMapWatcher = nullptr;
    }
    s.orderMapBuilding = 0;
    emit frameOrderMapReadyChanged(slot);
    requestSliceSyntax(slot);
}

// 取消并回收映射构建（freeSlot / 换文件时）：先置协作式取消标志（worker 每包检查，
// 毫秒级退出），再等待真正结束，避免野指针与 worker 泄漏。
void RBStreamBridge::cancelOrderMap(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (QFutureWatcher<void>* w = s.orderMapWatcher) {
        disconnect(w, nullptr, this, nullptr);
        if (s.orderMapCancel)
            s.orderMapCancel->store(true, std::memory_order_relaxed);
        if (w->isRunning() || w->isStarted())
            w->waitForFinished();
        w->deleteLater();
        s.orderMapWatcher = nullptr;
        s.orderMapBuilding = 0;
        s.orderMapCancel = nullptr;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// 语法元素面板（纯增量：后台一次 CBS 解析 + 只读缓存 + 信号通知）
// 独立模块：不触碰渲染/播放/块级路径，Worker 拷贝参数后台跑，主线程写缓存。
// ─────────────────────────────────────────────────────────────────────────
void RBStreamBridge::startSyntaxBuild(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (!s.inUse || s.syntaxWatcher) return;   // 已在构建或已完成

    // Worker 拷贝参数（路径 / 编码名 / extradata），不触碰 Slot 与 Qt 对象
    const QString path = s.path;
    const QString codec = s.codecName;
    const QByteArray extra = s.extradataCopy;

    QFuture<QVariantList> future = QtConcurrent::run([path, codec, extra]() {
        // 纯 Worker：CBS 解析参数集名值对，零共享状态
        std::vector<rb::RBSyntaxEntry> result = rb::RBSyntaxAnalyzer::analyze(
            codec,
            reinterpret_cast<const uint8_t*>(extra.constData()),
            extra.size(),
            path);   // 始终带文件路径：vvcC 里 PPS 常被截断，AnnexB 整包才完整
        return rb::RBSyntaxAnalyzer::toVariantList(result);
    });

    auto* watcher = new QFutureWatcher<QVariantList>(this);
    s.syntaxWatcher = watcher;
    watcher->setFuture(future);
    connect(watcher, &QFutureWatcher<QVariantList>::finished,
            this, [this, slot]() { onSyntaxBuilt(slot); });
}

namespace {

QVariantList syntaxEntriesOfSet(const QVariantList& all, const QString& set)
{
    QVariantList out;
    for (const auto& v : all) {
        if (v.toMap().value(QStringLiteral("set")).toString() == set)
            out.append(v);
    }
    return out;
}

QVariantList mergeSyntaxSlice(const QVariantList& all, const QVariantList& slice)
{
    QVariantList out;
    for (const auto& v : all) {
        if (v.toMap().value(QStringLiteral("set")).toString() != QLatin1String("SLICE"))
            out.append(v);
    }
    for (const auto& v : slice)
        out.append(v);
    return out;
}

} // namespace

void RBStreamBridge::onSyntaxBuilt(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (auto* w = s.syntaxWatcher) {
        s.syntaxCache = w->result();
        w->deleteLater();
    }
    s.syntaxWatcher = nullptr;
    s.syntaxReadyFlag = true;
    s.syntaxParamCache = QVariantList();
    for (const auto& v : s.syntaxCache) {
        if (v.toMap().value(QStringLiteral("set")).toString() != QLatin1String("SLICE"))
            s.syntaxParamCache.append(v);
    }
    const QVariantList firstSlice = syntaxEntriesOfSet(s.syntaxCache, QStringLiteral("SLICE"));
    if (!firstSlice.isEmpty()) {
        s.sliceSyntaxByPic.insert(0, firstSlice);
        s.syntaxSlicePic = 0;
    }
    s.syntaxCache = mergeSyntaxSlice(s.syntaxParamCache, firstSlice);
    emit syntaxReadyChanged(slot);
    requestSliceSyntax(slot);
}

QVariantList RBStreamBridge::syntaxEntries(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return {};
    return m_slots[slot].syntaxCache;
}

void RBStreamBridge::requestSliceSyntax(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (!s.inUse || !s.syntaxReadyFlag) return;

    int pic = s.currentFrame;
    if (pic < 0) pic = 0;
    if (s.frameOrderMode != 1 && s.orderMap.ok) {
        const int d = s.currentFrame;
        if (d >= 0 && d < int(s.orderMap.dispToCode.size()))
            pic = s.orderMap.dispToCode[size_t(d)];
    }
    if (pic < 0) pic = 0;

    if (s.sliceSyntaxByPic.contains(pic)) {
        if (s.syntaxSlicePic != pic) {
            s.syntaxCache = mergeSyntaxSlice(s.syntaxParamCache, s.sliceSyntaxByPic.value(pic));
            s.syntaxSlicePic = pic;
            emit syntaxReadyChanged(slot);
        }
        return;
    }
    if (s.sliceWatcher) {
        s.pendingSlicePic = pic;
        return;
    }
    startSliceSyntaxBuild(slot, pic);
}

void RBStreamBridge::startSliceSyntaxBuild(int slot, int pictureIndex) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (!s.inUse || s.sliceWatcher) return;

    const QString path = s.path;
    const QString codec = s.codecName;
    const QByteArray extra = s.extradataCopy;
    const int pic = pictureIndex;

    QFuture<QVariantList> future = QtConcurrent::run([path, codec, extra, pic]() {
        std::vector<rb::RBSyntaxEntry> result = rb::RBSyntaxAnalyzer::analyzePicture(
            codec,
            reinterpret_cast<const uint8_t*>(extra.constData()),
            extra.size(),
            path,
            pic);
        return rb::RBSyntaxAnalyzer::toVariantList(result);
    });

    auto* watcher = new QFutureWatcher<QVariantList>(this);
    s.sliceWatcher = watcher;
    s.sliceBuildingPic = pic;
    watcher->setFuture(future);
    connect(watcher, &QFutureWatcher<QVariantList>::finished,
            this, [this, slot]() { onSliceSyntaxBuilt(slot); });
}

void RBStreamBridge::onSliceSyntaxBuilt(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    QVariantList slice;
    if (auto* w = s.sliceWatcher) {
        slice = w->result();
        w->deleteLater();
    }
    s.sliceWatcher = nullptr;
    const int donePic = s.sliceBuildingPic;
    s.sliceBuildingPic = -1;

    if (!slice.isEmpty() && donePic >= 0) {
        const QVariantList only = syntaxEntriesOfSet(slice, QStringLiteral("SLICE"));
        const QVariantList use = only.isEmpty() ? slice : only;
        s.sliceSyntaxByPic.insert(donePic, use);

        int wantPic = s.currentFrame;
        if (s.frameOrderMode != 1 && s.orderMap.ok) {
            const int d = s.currentFrame;
            if (d >= 0 && d < int(s.orderMap.dispToCode.size()))
                wantPic = s.orderMap.dispToCode[size_t(d)];
        }
        if (s.pendingSlicePic >= 0)
            wantPic = s.pendingSlicePic;
        if (wantPic == donePic) {
            s.syntaxCache = mergeSyntaxSlice(s.syntaxParamCache, use);
            s.syntaxSlicePic = donePic;
            emit syntaxReadyChanged(slot);
        }
    }

    const int pending = s.pendingSlicePic;
    s.pendingSlicePic = -1;
    if (pending >= 0)
        requestSliceSyntax(slot);
}

// ── 参考结构：后台一次解析 slice 头（真实层级 + 参考关系）────────────
// 与语法面板同一模式：Worker 拷贝路径后台跑，主线程写缓存、发信号。
// 仅对 hevc 生效；解析失败/不支持时 ok=false，UI 回退启发式，不影响其它功能。
void RBStreamBridge::startRefStructBuild(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (!s.inUse || s.refStructWatcher) return;      // 已在构建或已完成
    // hevc / vvc 均可：RBRefStructureParser 内部按 NAL 布局自动分流，
    // 非这两种编码会在解析内返回 ok=false，UI 自动回退启发式。
    // 完成回调 onRefStructBuilt 还会用其逐帧 POC 快速合成编码序映射
    // （hevc/vvc 的映射首选路径，免整流解码）。
    if (s.codecName != "hevc" && s.codecName != "h265" &&
        s.codecName != "vvc"  && s.codecName != "h266") return;

    const QString path = s.path;
    QFuture<rb::RBRefStructureParser::Result> future =
        QtConcurrent::run([path]() {
            return rb::RBRefStructureParser::parse(path.toStdString(), nullptr);
        });

    auto* w = new QFutureWatcher<rb::RBRefStructureParser::Result>(this);
    s.refStructWatcher = w;
    w->setFuture(future);
    connect(w, &QFutureWatcher<rb::RBRefStructureParser::Result>::finished,
            this, [this, slot]() { onRefStructBuilt(slot); });
}

void RBStreamBridge::onRefStructBuilt(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    if (auto* w = s.refStructWatcher) {
        s.refStruct = w->result();
        w->deleteLater();
    }
    s.refStructWatcher = nullptr;
    s.refStructReadyFlag = true;
    emit refStructReadyChanged(slot);

    // ── POC 快速合成映射（hevc/vvc 首选路径）──────────────────
    // 解析器逐帧 POC（IDR 复位）+ GOP 基底即可合成编码序↔显示序双射，
    // 免整流解码（4K VVC：0.6s 解析 vs 2.2s 整流解码）。
    // 已实测与 RBFrameOrderMapper 整流解码结果完全一致
    // （266: 0,32,16,8,4,2,1,3...；265: 0,4,2,1,3...）。
    // 合成失败（双射校验不过/帧数对不上）→ 回退整流解码，行为同旧行为。
    if (!s.orderMap.ok && s.orderMapWatcher == nullptr) {
        bool fastDone = false;
        const auto& rf = s.refStruct;
        const int n = int(rf.frames.size());
        if (rf.ok && n > 0 && n == int(s.frameTypes.size())) {
            std::vector<int> codeToDisp(size_t(n), -1);
            std::vector<int> dispToCode(size_t(n), -1);
            // GOP 显示基底：第 g 个 GOP 的显示起点 = 前 g 个 GOP 帧数和
            std::vector<int> gopDispBase(rf.gopStarts.size(), 0);
            for (size_t g = 1; g < rf.gopStarts.size(); ++g)
                gopDispBase[g] = gopDispBase[g - 1] + rf.gopSizes[g - 1];
            bool ok = true;
            for (int c = 0; c < n && ok; ++c) {
                size_t g = 0;
                while (g + 1 < rf.gopStarts.size() && rf.gopStarts[g + 1] <= size_t(c)) ++g;
                const int d = gopDispBase[g] + rf.frames[size_t(c)].poc;
                if (d < 0 || d >= n) { ok = false; break; }
                codeToDisp[size_t(c)] = d;
                if (dispToCode[size_t(d)] != -1) { ok = false; break; }  // 显示位重复
                dispToCode[size_t(d)] = c;
            }
            if (ok)
                for (int d = 0; d < n; ++d)
                    if (dispToCode[size_t(d)] < 0) { ok = false; break; }
            if (ok) {
                rb::RBFrameOrderMapper::Result fast;
                fast.ok = true;
                fast.frameCount  = n;
                fast.packetCount = n;
                fast.codeToDisp  = std::move(codeToDisp);
                fast.dispToCode  = std::move(dispToCode);
                // 帧类型翻转：parser 0=B 1=P 2=I ↔ mapper 0=I 1=P 2=B
                fast.codePictType.assign(size_t(n), -1);
                for (int c = 0; c < n; ++c)
                    fast.codePictType[size_t(c)] =
                        (rf.frames[size_t(c)].type == 2) ? 0 :
                        (rf.frames[size_t(c)].type == 1) ? 1 : 2;
                fast.dispPictType.assign(size_t(n), -1);
                for (int d = 0; d < n; ++d)
                    fast.dispPictType[size_t(d)] =
                        fast.codePictType[size_t(fast.dispToCode[size_t(d)])];
                s.orderMap = std::move(fast);
                s.orderMapBuilding = 0;
                emit frameOrderMapReadyChanged(slot);
                fastDone = true;
            }
        }
        // 快速合成失败 → 回退整流解码（h264/解析失败/双射不过时到这）
        if (!fastDone)
            startOrderMapBuild(slot);
    }
    requestSliceSyntax(slot);
}

static int dispToCodeOf(const rb::RBFrameOrderMapper::Result& om, int d) {
    if (!om.ok) return -1;
    if (d < 0 || d >= int(om.dispToCode.size())) return -1;
    return om.dispToCode[size_t(d)];
}

static int codeToDispOf(const rb::RBFrameOrderMapper::Result& om, int c) {
    if (!om.ok) return -1;
    if (c < 0 || c >= int(om.codeToDisp.size())) return -1;
    return om.codeToDisp[size_t(c)];
}

// 参考结构是否就绪（真实数据可用；false 时 UI 回退启发式）。
// 额外校验帧数与编码序包数一致：容器封装流（mp4 等）不含 Annex-B 起始码，
// 若误从数据字节匹配出「伪起始码」，帧数会对不上 → 拒绝使用，避免层级错乱。
bool RBStreamBridge::refStructReady(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return false;
    const Slot& s = m_slots[slot];
    if (!s.refStructReadyFlag || !s.refStruct.ok || !s.orderMap.ok) return false;
    const int packets = int(s.orderMap.codeToDisp.size());
    const int parsed = int(s.refStruct.frames.size());
    return packets > 0 && parsed == packets;
}

// 显示序 → 编码（解码）序下标；映射未就绪返回 -1（UI 退回 idx+1）。
// 与 dispToCodeOf 同源，保证层级图「解码序」与顶栏/右侧栏口径一致。
int RBStreamBridge::codeIndexOf(int slot, int displayIndex) const {
    if (!refStructReady(slot)) return -1;
    const Slot& s = m_slots[slot];
    return dispToCodeOf(s.orderMap, displayIndex);
}

int RBStreamBridge::frameLayer(int slot, int displayIndex) const {
    if (!refStructReady(slot)) return -1;
    const Slot& s = m_slots[slot];
    const int c = dispToCodeOf(s.orderMap, displayIndex);
    if (c < 0 || c >= int(s.refStruct.frames.size())) return -1;
    return s.refStruct.frames[size_t(c)].layer;
}

QVariantList RBStreamBridge::frameRefs(int slot, int displayIndex) const {
    QVariantList out;
    if (!refStructReady(slot)) return out;
    const Slot& s = m_slots[slot];
    const int c = dispToCodeOf(s.orderMap, displayIndex);
    if (c < 0 || c >= int(s.refStruct.frames.size())) return out;
    const auto& refs = s.refStruct.frames[size_t(c)].refs;
    for (size_t k = 0; k < refs.size(); ++k) {
        const int d = codeToDispOf(s.orderMap, refs[k]);
        if (d >= 0) out.append(d);                    // 只输出能换算到显示序的参考
    }
    return out;
}

// RPS 中 used=0 的条目：本帧不做预测，但要求解码器保留在 DPB 供后续帧使用。
// 换算口径与 frameRefs 完全一致（解码序 → 显示序）。
QVariantList RBStreamBridge::frameKeptRefs(int slot, int displayIndex) const {
    QVariantList out;
    if (!refStructReady(slot)) return out;
    const Slot& s = m_slots[slot];
    const int c = dispToCodeOf(s.orderMap, displayIndex);
    if (c < 0 || c >= int(s.refStruct.frames.size())) return out;
    const auto& kept = s.refStruct.frames[size_t(c)].kept;
    for (size_t k = 0; k < kept.size(); ++k) {
        const int d = codeToDispOf(s.orderMap, kept[k]);
        if (d >= 0) out.append(d);
    }
    return out;
}

// 真实解析的 GOP 大小：取出现次数最多的尺寸（众数），
// 比首/末 GOP 更能代表编码器的标称配置（首尾常因截断而不完整）。
int RBStreamBridge::refGopSize(int slot) const {
    if (!refStructReady(slot)) return 0;
    const Slot& s = m_slots[slot];
    const auto& sizes = s.refStruct.gopSizes;
    if (sizes.empty()) return 0;
    std::vector<int> sorted(sizes.begin(), sizes.end());
    std::sort(sorted.begin(), sorted.end());
    int best = sorted[0], bestCnt = 1, cur = sorted[0], curCnt = 1;
    for (size_t k = 1; k < sorted.size(); ++k) {
        if (sorted[k] == cur) { ++curCnt; }
        else {
            if (curCnt >= bestCnt) { bestCnt = curCnt; best = cur; }
            cur = sorted[k]; curCnt = 1;
        }
    }
    if (curCnt >= bestCnt) best = cur;
    return best;
}

int RBStreamBridge::refMiniGop(int slot) const {
    if (!refStructReady(slot)) return 0;
    return m_slots[slot].refStruct.miniGopSize;
}

int RBStreamBridge::refGpbCount(int slot) const {
    if (!refStructReady(slot)) return 0;
    return m_slots[slot].refStruct.gpbCount;
}

bool RBStreamBridge::refHasIdr(int slot) const {
    if (!refStructReady(slot)) return false;
    return m_slots[slot].refStruct.hasIdr;
}

bool RBStreamBridge::refHasCra(int slot) const {
    if (!refStructReady(slot)) return false;
    return m_slots[slot].refStruct.hasCra;
}

bool RBStreamBridge::frameIsGpb(int slot, int displayIndex) const {
    if (!refStructReady(slot)) return false;
    const Slot& s = m_slots[slot];
    const int c = dispToCodeOf(s.orderMap, displayIndex);
    if (c < 0 || c >= int(s.refStruct.frames.size())) return false;
    return s.refStruct.frames[size_t(c)].isGpb;
}

bool RBStreamBridge::refOpenGop(int slot) const {
    if (!refStructReady(slot)) return false;
    return m_slots[slot].refStruct.openGop;
}

bool RBStreamBridge::syntaxReady(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return false;
    return m_slots[slot].syntaxReadyFlag;
}

QVariantMap RBStreamBridge::hrdEstimate(int slot) const {
    QVariantMap m;
    if (!hasFile(slot)) {
        m["available"] = false;
        return m;
    }
    const Slot& s = m_slots[slot];
    if (s.cpbSizeBits <= 0) {
        m["available"]      = false;
        m["cpbSizeBits"]    = 0;
        m["bitRateBits"]    = 0;
        m["peakRatio"]      = 0.0;
        m["overflowRisk"]   = false;
        m["underflowRisk"]  = false;
        return m;
    }
    // 简易估算：所有帧按 SPS 声明码率持续打，峰值占用率 = 1.0（无变化）
    // 真实估算需累计码流进入 CPB 的字节流。一期无可用数据 → available=true + peakRatio=1.0
    m["available"]      = true;
    m["cpbSizeBits"]    = double(s.cpbSizeBits);
    m["bitRateBits"]    = double(s.cbrBitrateBits);
    m["peakRatio"]      = 1.0;
    m["overflowRisk"]   = false;
    m["underflowRisk"]  = false;
    return m;
}

rb::RBBlockAnalyzer* RBStreamBridge::blockAnalyzerFor(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return nullptr;
    Slot& s = const_cast<Slot&>(m_slots[slot]);
    if (!s.inUse) return nullptr;
    if (s.blockAnalyzer) return s.blockAnalyzer.get();
    if (s.blockAnalyzerTried) return nullptr;   // 曾失败，不再重试

    s.blockAnalyzerTried = true;
    s.blockAnalyzer = std::make_unique<rb::RBBlockAnalyzer>();
    // ★ 必须在 rbOpen 之前配置：rbOpen 会立即启动后台预解码线程，
    //   若晚于 rbOpen 设置，后台线程已按 m_wantFrameImage=false 跑起来，
    //   整片预解码不产出 RGB → 画面永远停在首帧不更新。
    // 开启底层原始画面导出：UI 需要在真实渲染图上叠加 CU 划分网格
    s.blockAnalyzer->rbEnableFrameImage(true);
    // RGB 保留帧数：RGB 由 YUV 按需转（只转当前显示帧），无需全量常驻，
    // 只保留最近 16 帧滑动窗口即可；全量常驻的是更省的 YUV（后台顺带存）。
    s.blockAnalyzer->rbSetCacheSize(16);
    if (!s.blockAnalyzer->rbOpen(s.path.toStdString())) {
        qWarning() << "[StreamBridge] block analyzer open failed:" << s.path;
        s.blockAnalyzer.reset();
        return nullptr;
    }
    qInfo() << "[StreamBridge] block analyzer ready:" << s.path
            << "granularity=" << QString::fromStdString(s.blockAnalyzer->rbBlockGranularity());
    return s.blockAnalyzer.get();
}

QVariantMap RBStreamBridge::blockInfoToMap(const rb::RBBlockInfo& bi) {
    QVariantMap m;
    m["x"]       = bi.x;
    m["y"]       = bi.y;
    m["w"]       = bi.w;
    m["h"]       = bi.h;
    m["qp"]      = bi.qp;
    m["isSkip"]  = bi.isSkip;
    m["isIntra"] = bi.isIntra;
    m["mvx"]     = double(bi.mvx);
    m["mvy"]     = double(bi.mvy);
    // ── 图2 详情卡片扩展字段 ──
    m["refIdx"]      = bi.refIdx;
    m["refIdxL1"]    = bi.refIdxL1;
    m["predMode"]    = bi.predMode;
    m["predFlag"]    = bi.predFlag;
    m["hasResidual"] = bi.hasResidual;
    m["mvxL0"]       = double(bi.mvxL0);
    m["mvyL0"]       = double(bi.mvyL0);
    m["mvxL1"]       = double(bi.mvxL1);
    m["mvyL1"]       = double(bi.mvyL1);
    m["treeType"]    = bi.treeType;
    m["cqtDepth"]    = bi.cqtDepth;
    return m;
}

bool RBStreamBridge::blockInfoSupported(int slot) const {
    auto* ba = blockAnalyzerFor(slot);
    return (ba && ba->rbBlockSupport());
}

QString RBStreamBridge::blockGranularity(int slot) const {
    auto* ba = blockAnalyzerFor(slot);
    if (!ba || !ba->rbBlockSupport()) return QString{};
    return QString::fromStdString(ba->rbBlockGranularity());
}

QVariantList RBStreamBridge::blockInfoAt(int slot, int frameIndex) const {
    QVariantList out;
    auto* ba = blockAnalyzerFor(slot);
    if (!ba || !ba->rbBlockSupport() || frameIndex < 0) return out;

    const rb::RBFrameBlocks& fb = ba->rbBlockInfoAt(frameIndex);

    // ── 同步底层原始画面：把解码出的 RGB 缓存为 QImage，供 CU 网格叠加 ──
    // ★ 画面必须与块信息解耦：只要有 RGB 就同步画面并递增版本号，
    //   即使该帧块信息为空（如 B 帧首帧 side data 缺失）。否则画面被块信息
    //   连坐隐藏 → 黑屏。此段务必在 fb.valid 门禁之前执行。
    // blockInfoAt 是 const，这里需要修改缓存，故做 const_cast（逻辑上是缓存更新）
    Slot& s = const_cast<Slot&>(m_slots[slot]);
    if (fb.hasRgb && !fb.rgb.empty() && fb.rgbWidth > 0 && fb.rgbHeight > 0) {
        QImage img(fb.rgb.data(), fb.rgbWidth, fb.rgbHeight,
                   fb.rgbWidth * 3, QImage::Format_RGB888);
        s.lastFrameImage    = img.copy();   // 深拷贝，脱离 fb 内存
        s.lastFrameImageFor = frameIndex;
        s.frameImageVersion++;
        // blockInfoAt 是 const，发信号需去掉 const（逻辑上仍是本对象）
        const_cast<RBStreamBridge*>(this)->frameImageChanged(slot);
    }

    // 块信息列表：无有效块时返回空（画面已在上方独立同步，不受影响）
    if (!fb.valid) return out;

    const int ctu = ctuSizeFromSyntax(s.codecName, s.syntaxCache);
    out.reserve(static_cast<int>(fb.blocks.size()));
    for (const auto& bi : fb.blocks) {
        QVariantMap m = blockInfoToMap(bi);
        m[QStringLiteral("ctuSize")] = ctu;
        m[QStringLiteral("depth")]   = qtSplitDepth(ctu, bi.w, bi.h);
        out.push_back(std::move(m));
    }
    return out;
}

QImage RBStreamBridge::FrameImageProvider::requestImage(const QString& id,
                                                        QSize* size,
                                                        const QSize& requestedSize) {
    Q_UNUSED(requestedSize)
    // id 形如 "<slot>_<uiFrame>_<version>_<refreshKey>"。
    // ★ 必须按 URL 里的帧号取图，不能返回被任意 blockInfoAt 调用覆写的
    //   lastFrameImage —— 否则播放到第 N 帧时，若别的绑定用旧帧号调过
    //   blockInfoAt，画面会被拽回旧帧（现象：底部帧号 70 但画面是 16）。
    const int slot    = id.section('_', 0, 0).toInt();
    const int uiFrame = id.section('_', 1, 1).toInt();
    if (m_bridge && slot >= 0 && slot < MaxSlots) {
        auto* ba = m_bridge->blockAnalyzerFor(slot);
        if (ba && ba->rbBlockSupport() && uiFrame >= 0) {
            // UI 帧号（编码序模式下）→ 解码器输出序。
            const int outIdx = m_bridge->decodeIndexOf(slot, uiFrame);
            const rb::RBFrameBlocks& fb = ba->rbBlockInfoAt(outIdx);
            if (fb.hasRgb && !fb.rgb.empty() && fb.rgbWidth > 0 && fb.rgbHeight > 0) {
                QImage img(fb.rgb.data(), fb.rgbWidth, fb.rgbHeight,
                           fb.rgbWidth * 3, QImage::Format_RGB888);
                if (size) *size = img.size();
                return img.copy();   // 深拷贝，脱离 fb 内存
            }
        }
        // 回退：analyzer 尚未就绪时用最后一帧兜底，避免全黑。
        const Slot& s = m_bridge->m_slots[slot];
        if (!s.lastFrameImage.isNull()) {
            if (size) *size = s.lastFrameImage.size();
            return s.lastFrameImage;
        }
    }
    if (size) *size = QSize(1, 1);
    return QImage();   // 空图：QML 侧显示占位/不绘制
}

int RBStreamBridge::frameImageVersion(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return 0;
    return m_slots[slot].frameImageVersion;
}

QVariantMap RBStreamBridge::blockStats(int slot, int frameIndex) const {
    QVariantMap m;
    m["valid"]      = false;
    m["avgQp"]      = 0.0;
    m["minQp"]      = 0;
    m["maxQp"]      = 0;
    m["blockCount"] = 0;
    m["width"]      = 0;
    m["height"]     = 0;

    auto* ba = blockAnalyzerFor(slot);
    if (!ba || !ba->rbBlockSupport() || frameIndex < 0) return m;

    const rb::RBFrameBlocks& fb = ba->rbBlockInfoAt(frameIndex);
    if (!fb.valid) return m;

    m["valid"]      = true;
    m["avgQp"]      = fb.avgQp;
    m["minQp"]      = fb.minQp;
    m["maxQp"]      = fb.maxQp;
    m["blockCount"] = static_cast<int>(fb.blocks.size());
    m["width"]      = fb.width;
    m["height"]     = fb.height;

    int skipN = 0, intraN = 0, interN = 0, ibcN = 0, pltN = 0, mvN = 0;
    qint64 skipA = 0, intraA = 0, interA = 0, ibcA = 0, pltA = 0, totalA = 0;
    double mvSum = 0.0;
    for (const auto& bi : fb.blocks) {
        const qint64 a = qint64(std::max(1, bi.w)) * qint64(std::max(1, bi.h));
        totalA += a;
        const int pm = bi.predMode;
        if (bi.isSkip || pm == 2) {
            ++skipN; skipA += a;
        } else if (pm == 4) {
            ++ibcN; ibcA += a;
        } else if (pm == 3) {
            ++pltN; pltA += a;
        } else if (bi.isIntra || pm == 1) {
            ++intraN; intraA += a;
        } else {
            ++interN; interA += a;
        }
        if (!bi.isIntra && !bi.isSkip && pm != 1 && pm != 2) {
            mvSum += std::hypot(double(bi.mvx), double(bi.mvy));
            ++mvN;
        }
    }
    const double denom = totalA > 0 ? double(totalA) : 1.0;
    m["skipCount"]    = skipN;
    m["intraCount"]   = intraN;
    m["interCount"]   = interN;
    m["ibcCount"]     = ibcN;
    m["pltCount"]     = pltN;
    m["skipAreaPct"]  = 100.0 * double(skipA) / denom;
    m["intraAreaPct"] = 100.0 * double(intraA) / denom;
    m["interAreaPct"] = 100.0 * double(interA) / denom;
    m["ibcAreaPct"]   = 100.0 * double(ibcA) / denom;
    m["pltAreaPct"]   = 100.0 * double(pltA) / denom;
    m["avgAbsMv"]     = mvN > 0 ? mvSum / double(mvN) : 0.0;
    return m;
}

void RBStreamBridge::seekPlayerTo(int slot, int frameIndex) {
    // 一期不真正联动 EngineBridge（避免双向循环依赖 RBStreamBridge <-> EngineBridge）；
    // 简单日志 + 后续接 EngineBridge.seekPlayerTo(slot, secs)。
    if (!hasFile(slot)) return;
    const double secs = fps(slot) > 0 ? double(frameIndex) / fps(slot) : 0;
    qInfo() << "[StreamBridge] seekPlayerTo slot=" << slot
            << "frame=" << frameIndex << "secs=" << secs;
}

// ─────────────────────────────────────────────────────────────────────────
// 异步"真播放"（策略与 YuvBridge 一致）
//
// 4K VVC 单帧可达数十万 CU，若在主线程同步做 decode + extractBlocks +
// 转 QVariantList，单帧就要数秒；播放定时器每 40ms 一拍会持续堆积，
// 最终 UI 冻结（表现为"卡死"）。
//
// 策略：
//   1) 解码（含 CU 导出、RGB 转换）全部放进 Worker 线程，主线程零阻塞；
//   2) 用 playBusy 做"忙则跳过本拍"——上一帧还没解完就丢弃本次 tick，
//      因此播放可以变慢（取决于解码速度），但绝不堆积、绝不卡死；
//   3) 解码完成后仅在主线程更新缓存并发信号，QML 自然刷新。
// ─────────────────────────────────────────────────────────────────────────
// 停止该 slot 的异步解码任务并等待其结束。
// 必须在销毁 Slot（解码器）之前调用，否则 Worker 线程会访问已释放资源。
void RBStreamBridge::cancelPlayAsync(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;

    QFutureWatcher<void>* w = m_playWatchers[slot];
    if (!w) { m_slots[slot].playBusy = false; return; }

    // 1) 先断开信号：避免 finished 回调在本对象/slot 已重置后仍被调用
    disconnect(w, nullptr, this, nullptr);

    // 2) 等待正在跑的任务真正结束（解码不可中断，只能等）
    if (w->isRunning() || w->isStarted())
        w->waitForFinished();

    w->deleteLater();
    m_playWatchers[slot] = nullptr;
    m_slots[slot].playBusy = false;
    m_slots[slot].playActiveFrame = -1;
    m_slots[slot].playPendingFrame = -1;
}

bool RBStreamBridge::isPlayBusy(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return false;
    return m_slots[slot].playBusy;
}

// 入参 frameIndex 是【UI 帧号】（编码顺序模式下即编码序），不是解码器输出序。
// 内部统一换算：编码顺序模式下 UI 帧号 c 对应输出序 decodeIndexOf(c)。
// 此前 QML 直接传输出序、这里又把它当 UI 帧号回填 currentFrame，
// 导致帧号与画面各按一套序推进（GOP=4 该 0,4,2,1,3 实际 0,1,2,3）。
void RBStreamBridge::requestPlayStep(int slot, int frameIndex) {
    if (!hasFile(slot) || frameIndex < 0) return;
    Slot& s = m_slots[slot];
    const int n = frameCount(slot);
    if (n > 0 && frameIndex >= n) frameIndex = n - 1;

    // UI 帧号 → 解码器输出序（显示顺序模式下恒等）
    const int outIdx = decodeIndexOf(slot, frameIndex);

    // 忙：记录最新目标帧后直接返回（跳过本拍，不堆积）
    if (s.playBusy) {
        s.playPendingFrame = frameIndex;
        s.playPendingOut   = outIdx;
        return;
    }

    // 空闲：本拍目标记入 playActiveFrame（pending 只留给忙时合并的新目标），
    // 完成后由 onPlayStepFinished 回填 currentFrame = playActiveFrame。
    s.playActiveFrame  = frameIndex;
    s.playPendingFrame = -1;
    s.playPendingOut   = -1;
    runPlayStepAsync(slot, outIdx);
}

// ── 异步跳帧 ────────────────────────────────────────────────────────────
// 与 requestPlayStep 同一 Worker/Watcher 基础设施（共享 playBusy/pending）：
//   · 空闲：立即把目标帧（UI 帧号）转输出序后丢给 Worker 预解码；
//   · 忙：仅记录最新目标（pending 合并），当前帧解完后 onPlayStepFinished
//     会用 pending 继续追，连续点击只解最终目标帧，绝不堆积、不冻结主线程。
// 完成后回填 currentFrame → QML 的 slotBlocks/slotBlockStats 绑定重取时，
// 帧已在 LRU 缓存里，blockInfoAt 变成纯查表，主线程零解码。
void RBStreamBridge::requestGotoAsync(int slot, int frameIndex) {
    if (!hasFile(slot)) return;
    Slot& s = m_slots[slot];
    const int n = frameCount(slot);
    if (n <= 0) return;
    if (frameIndex < 0) frameIndex = 0;
    if (frameIndex >= n) frameIndex = n - 1;

    const int outIdx = decodeIndexOf(slot, frameIndex);
    if (s.playBusy) {                    // 上一个目标仍在解：合并为最新目标
        s.playPendingFrame = frameIndex;
        s.playPendingOut   = outIdx;
        return;
    }
    // 空闲：本拍目标记入 playActiveFrame（pending 只留给忙时合并的新目标），
    // 完成后由 onPlayStepFinished 回填 currentFrame = playActiveFrame。
    s.playActiveFrame  = frameIndex;
    s.playPendingFrame = -1;
    s.playPendingOut   = -1;
    runPlayStepAsync(slot, outIdx);
}

void RBStreamBridge::runPlayStepAsync(int slot, int frameIndex) {
    Slot& s = m_slots[slot];
    s.playBusy = true;
    // 注意：不再清空 playPendingFrame/playPendingOut。
    // 旧实现在这里清 pending，导致 onPlayStepFinished 永远走 currentFrame+1
    // 分支（「下一帧」），任意 goto 跳转完成后帧号都被改成旧帧+1。
    // 本拍目标由调用方写入 playActiveFrame；pending 只表示忙时合并的新目标。

    // Worker 线程：解码目标帧（内部会更新 lastFrameImage / 块缓存由主线程补）
    auto* ba = blockAnalyzerFor(slot);
    if (!ba) { s.playBusy = false; return; }

    QFuture<void> future = QtConcurrent::run([ba, frameIndex]() {
        // 仅做解码 + 块提取（结果留在 RBBlockAnalyzer 的 LRU 缓存中）
        // 注意：不在此处触碰任何 QImage / QObject（Worker 线程禁止）
        (void)ba->rbBlockInfoAt(frameIndex);
    });

    if (!m_playWatchers[slot]) {
        m_playWatchers[slot] = new QFutureWatcher<void>(this);
        connect(m_playWatchers[slot], &QFutureWatcher<void>::finished,
                this, [this, slot]() { onPlayStepFinished(slot); });
    }
    m_playWatchers[slot]->setFuture(future);
}

void RBStreamBridge::onPlayStepFinished(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    Slot& s = m_slots[slot];
    s.playBusy = false;

    // 回到主线程：回填本拍目标帧号并发信号（触发 QML 重新取画面/块）
    // currentFrame 是 UI 帧号（编码顺序模式下 = 编码序），必须用 UI 帧号回填。
    // 旧逻辑在 pending 被 runPlayStepAsync 清空后恒走 currentFrame+1 分支，
    // 任意跳转完成后帧号都被改成「旧当前帧+1」——即点击层级图块时
    // 「跳到目标帧后立马又跳到下一帧」的根因。
    if (s.playActiveFrame >= 0) {
        s.currentFrame = s.playActiveFrame;
        s.playActiveFrame = -1;
    }
    emit currentFrameChanged(slot);

    // 解码期间来了新目标（pending 合并）：继续追，只解最终目标帧
    if (s.playPendingFrame >= 0) {
        const int pf = s.playPendingFrame;
        const int po = s.playPendingOut;
        s.playPendingFrame = -1;
        s.playPendingOut   = -1;
        s.playActiveFrame  = pf;
        runPlayStepAsync(slot, po);
    }
}

// ═════════════════════════════════════════════════════════════════════════
// 轻量探测（setup 阶段用）
// ═════════════════════════════════════════════════════════════════════════

// 从 h264 裸流中解析 SPS，提取 max_num_ref_frames（参考帧数）
// 返回 -1 表示解析失败
static int parseH264MaxRefFrames(const uint8_t* data, int64_t size) {
    int64_t i = 0;
    while (i + 4 <= size) {
        int scLen = 0;
        if (data[i] == 0 && data[i+1] == 0) {
            if (data[i+2] == 1) scLen = 3;
            else if (i + 3 < size && data[i+2] == 0 && data[i+3] == 1) scLen = 4;
        }
        if (scLen == 0) { ++i; continue; }
        if (i + scLen >= size) break;
        int nalType = data[i + scLen] & 0x1F;
        // nal_type 7 = SPS
        if (nalType == 7) {
            const uint8_t* sps = data + i + scLen + 1; // 跳过 NAL header
            int64_t spsSize = size - (i + scLen + 1);
            // 找下一个 start code 作为 SPS 结束
            for (int64_t j = 0; j + 3 < spsSize; ++j) {
                if (sps[j] == 0 && sps[j+1] == 0 &&
                    (sps[j+2] == 1 || (j + 3 < spsSize && sps[j+2] == 0 && sps[j+3] == 1))) {
                    spsSize = j;
                    break;
                }
            }
            // 简易 Exp-Golomb 解析器
            // SPS 结构：profile_idc(1) constraint_flags(1) level_idc(1) seq_parameter_set_id(ue)
            //   然后根据 profile 跳过 chroma/transform/scaling 相关字段
            //   接着：log2_max_frame_num_minus4(ue) → pic_order_cnt_type(ue)
            //   根据 poc_type 跳过 → max_num_ref_frames(ue)
            int bitPos = 0;
            auto readBit = [&]() -> int {
                if (bitPos / 8 >= spsSize) return 0;
                int byteIdx = bitPos / 8;
                int bitIdx = 7 - (bitPos % 8);
                bitPos++;
                return (sps[byteIdx] >> bitIdx) & 1;
            };
            auto readUE = [&]() -> uint32_t {
                int leadingZeros = 0;
                while (readBit() == 0 && leadingZeros < 32) ++leadingZeros;
                uint32_t val = 0;
                for (int k = 0; k < leadingZeros; ++k)
                    val = (val << 1) | readBit();
                return (1 << leadingZeros) - 1 + val;
            };
            // profile_idc(8) + constraint(8) + level(8)
            if (spsSize < 3) return -1;
            int profileIdc = sps[0];
            bitPos = 24; // 跳过前 3 字节
            uint32_t spsId = readUE();
            // High profile 系列有额外字段
            if (profileIdc == 100 || profileIdc == 110 || profileIdc == 122 ||
                profileIdc == 244 || profileIdc == 44  || profileIdc == 83  ||
                profileIdc == 86  || profileIdc == 118 || profileIdc == 128) {
                uint32_t chromaFormatIdc = readUE();
                if (chromaFormatIdc == 3) readBit(); // separate_colour_plane_flag
                readUE(); // bit_depth_luma_minus8
                readUE(); // bit_depth_chroma_minus8
                readBit(); // qpprime_y_zero_transform_bypass_flag
                int seqScalingMatrixPresent = readBit();
                if (seqScalingMatrixPresent) {
                    int loops = (chromaFormatIdc != 3) ? 8 : 12;
                    for (int k = 0; k < loops; ++k) {
                        if (readBit()) { // seq_scaling_list_present_flag
                            // 跳过 scaling list（简化：粗略跳过）
                            int listSize = (k < 6) ? 16 : 64;
                            for (int n = 0; n < listSize; ++n) {
                                readUE(); // delta_scale
                            }
                        }
                    }
                }
            }
            readUE(); // log2_max_frame_num_minus4
            uint32_t pocType = readUE();
            if (pocType == 0) {
                readUE(); // log2_max_pic_order_cnt_lsb_minus4
            } else if (pocType == 1) {
                readBit(); // delta_pic_order_always_zero_flag
                readUE();  // offset_for_non_ref_pic (se, 但 ue 读法相同)
                readUE();  // offset_for_top_to_bottom_field (se)
                uint32_t numRefFramesInPoc = readUE();
                for (uint32_t k = 0; k < numRefFramesInPoc; ++k)
                    readUE(); // offset_for_ref_frame (se)
            }
            // max_num_ref_frames
            uint32_t maxRefFrames = readUE();
            return int(maxRefFrames);
        }
        // 跳到下一个 start code
        int64_t j = i + scLen + 1;
        while (j + 3 < size) {
            if (data[j] == 0 && data[j+1] == 0 &&
                (data[j+2] == 1 ||
                 (j + 3 < size && data[j+2] == 0 && data[j+3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= size) break;
        i = j;
    }
    return -1;
}

QVariantMap RBStreamBridge::probeFile(const QString& path) const {
    QVariantMap m;
    if (path.isEmpty()) return m;

    AVFormatContext* fmt = nullptr;
    int ret = avformat_open_input(&fmt, path.toUtf8().constData(), nullptr, nullptr);
    if (ret < 0 || !fmt) {
        qWarning() << "[StreamBridge] probeFile avformat_open_input failed:" << path;
        return m;
    }
    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        qWarning() << "[StreamBridge] probeFile avformat_find_stream_info failed:" << path;
        avformat_close_input(&fmt);
        return m;
    }

    // 找视频流
    int vIdx = -1;
    for (unsigned i = 0; i < fmt->nb_streams; ++i) {
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            vIdx = int(i); break;
        }
    }

    // 文件名
    QString fn;
    int slash = path.lastIndexOf('/');
    fn = (slash >= 0) ? path.mid(slash + 1) : path;

    m["fileName"]     = fn;
    m["filePath"]     = path;
    m["format"]       = QString::fromUtf8(fmt->iformat ? fmt->iformat->name : "");
    m["formatLong"]   = QString::fromUtf8(fmt->iformat ? fmt->iformat->long_name : "");
    m["duration"]     = (fmt->duration > 0) ? double(fmt->duration) / AV_TIME_BASE : 0.0;
    m["bitrate"]      = double(fmt->bit_rate);
    m["fileSize"]     = qint64(fmt->pb ? avio_size(fmt->pb) : 0);
    {
        QFileInfo fi(path);
        m["fileModified"] = fi.lastModified().toString("yyyy-MM-dd HH:mm:ss");
    }

    if (vIdx >= 0) {
        AVCodecParameters* par = fmt->streams[vIdx]->codecpar;
        // 不用 desc->long_name（FFmpeg 返回 "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10" 太冗长）
        m["codec"]        = codecIdToShortName(par->codec_id);
        m["codecLong"]    = codecIdToLongName(par->codec_id);
        m["width"]        = par->width;
        m["height"]       = par->height;
        m["profile"]      = profileIdToString(par->codec_id, par->profile);
        m["level"]        = QString::number(par->level);
        AVRational fr = av_guess_frame_rate(fmt, fmt->streams[vIdx], nullptr);
        m["fps"]          = (fr.den > 0) ? double(fr.num) / fr.den : 0.0;
        m["pixFmt"]       = pixFmtToString(AVPixelFormat(par->format));
        m["colorSpace"]   = colorSpaceToString(par->color_space);
        m["colorRange"]   = colorRangeToString(par->color_range);
        m["frameCount"]   = int(fmt->streams[vIdx]->nb_frames);
        // 裸 VVC/HEVC 容器常不写 nb_frames；按视频包数补一帧数（与开始分析预扫描一致）
        if (m["frameCount"].toInt() <= 0) {
            const AVCodecID cid = par->codec_id;
            const char* iname = fmt->iformat ? fmt->iformat->name : "";
            const bool rawish = (cid == AV_CODEC_ID_H264 || cid == AV_CODEC_ID_HEVC
                                 || cid == AV_CODEC_ID_VVC)
                                || (iname && (std::strcmp(iname, "h264") == 0
                                              || std::strcmp(iname, "hevc") == 0
                                              || std::strcmp(iname, "vvc") == 0));
            if (rawish) {
                AVPacket* pk = av_packet_alloc();
                int n = 0;
                while (pk && av_read_frame(fmt, pk) >= 0) {
                    if (pk->stream_index == vIdx) ++n;
                    av_packet_unref(pk);
                }
                av_packet_free(&pk);
                if (n > 0) m["frameCount"] = n;
            }
        }
        // ── 补充字段 ──
        m["colorPrimaries"] = colorPrimariesToString(par->color_primaries);
        m["colorTransfer"]  = colorTransferToString(par->color_trc);
        m["chromaLocation"] = chromaLocationToString(par->chroma_location);
        m["fieldOrder"]     = fieldOrderToString(par->field_order);
        m["bitsPerRawSample"] = (par->bits_per_raw_sample > 0)
                                ? QString::number(par->bits_per_raw_sample) : "—";
        m["hasBFrames"]     = (fmt->streams[vIdx]->codecpar->video_delay > 0)
                                ? QString::number(fmt->streams[vIdx]->codecpar->video_delay)
                                : "0";
        m["refs"]           = "—";  // AVCodecParameters 无此字段，后续从 SPS 解析
        m["isAvc"]          = (par->codec_id == AV_CODEC_ID_H264 || par->codec_id == AV_CODEC_ID_HEVC)
                                ? (par->extradata_size > 0 && par->extradata[0] == 1)
                                : false;
    } else {
        m["codec"]        = "";
        m["codecLong"]    = "";
        m["width"]        = 0;
        m["height"]       = 0;
        m["profile"]      = "";
        m["level"]        = "";
        m["fps"]          = 0.0;
        m["pixFmt"]       = "";
        m["colorSpace"]   = "";
        m["colorRange"]   = "";
        m["frameCount"]   = 0;
    }

    avformat_close_input(&fmt);

    // ── 裸流信息补全 ──
    // 裸 h264/hevc 文件缺少容器元数据：bitrate / duration / frameCount 全为 0。
    // 扫描 NAL start codes 数出 slice 帧数，再反推时长和码率。
    bool isRawBitstream = (m["format"].toString() == "h264"
                           || m["format"].toString() == "hevc"
                           || m["format"].toString() == "vvc"
                           || m["codec"].toString() == "vvc");
    if (isRawBitstream && vIdx >= 0) {
        int fc = m["frameCount"].toInt();
        double dur = m["duration"].toDouble();
        double br = m["bitrate"].toDouble();

        if (fc <= 0 || dur <= 0 || br <= 0) {
            QFile f(path);
            if (f.open(QIODevice::ReadOnly)) {
                QByteArray bytes = f.readAll();
                f.close();
                int64_t fileSize = bytes.size();
                const uint8_t* data = reinterpret_cast<const uint8_t*>(bytes.constData());
                const QString codec = m["codec"].toString();
                const bool isHevc = (codec == "hevc");
                const bool isVvc  = (codec == "vvc");

                // 扫描 NAL start codes，统计画面数
                int sliceCount = 0;
                int vvcPh = 0, vvcVcl = 0;
                int64_t i = 0;
                while (i + 4 <= fileSize) {
                    int scLen = 0;
                    if (data[i] == 0 && data[i+1] == 0) {
                        if (data[i+2] == 1) scLen = 3;
                        else if (i + 3 < fileSize && data[i+2] == 0 && data[i+3] == 1) scLen = 4;
                    }
                    if (scLen == 0) { ++i; continue; }
                    if (i + scLen >= fileSize) break;
                    if (isVvc) {
                        // nuh_unit_type 在第 2 字节高 5 bit
                        if (i + scLen + 1 >= fileSize) break;
                        const int nalType = (data[i + scLen + 1] >> 3) & 0x1F;
                        if (nalType == 19) ++vvcPh;           // PH_NUT
                        if (nalType <= 10) ++vvcVcl;           // VCL 0–10
                    } else {
                        int nalType = isHevc ? ((data[i + scLen] & 0x7E) >> 1)
                                             : (data[i + scLen] & 0x1F);
                        // h264: 1=non-IDR slice, 5=IDR slice
                        // hevc: 0-9=TRAIL/TSA/STSA/RADL/RASL, 16-21=BLA/IDR/CRA
                        if (!isHevc) {
                            if (nalType == 1 || nalType == 5) ++sliceCount;
                        } else {
                            if (nalType <= 9 || (nalType >= 16 && nalType <= 21)) ++sliceCount;
                        }
                    }
                    // 跳到下一个 start code
                    int64_t j = i + scLen + 1;
                    while (j + 3 < fileSize) {
                        if (data[j] == 0 && data[j+1] == 0 &&
                            (data[j+2] == 1 ||
                             (j + 3 < fileSize && data[j+2] == 0 && data[j+3] == 1)))
                            break;
                        ++j;
                    }
                    if (j + 3 >= fileSize) break;
                    i = j;
                }
                if (isVvc)
                    sliceCount = (vvcPh > 0) ? vvcPh : vvcVcl;

                double fpsVal = m["fps"].toDouble();
                if (fc <= 0 && sliceCount > 0) {
                    m["frameCount"] = sliceCount;
                    fc = sliceCount;
                }
                if (dur <= 0 && fc > 0 && fpsVal > 0) {
                    dur = double(fc) / fpsVal;
                    m["duration"] = dur;
                }
                if (br <= 0 && dur > 0 && fileSize > 0) {
                    m["bitrate"] = double(fileSize) * 8.0 / dur;
                }

                qInfo() << "[StreamBridge] probeFile raw enhancement:"
                        << "sliceCount=" << sliceCount
                        << "duration=" << dur
                        << "bitrate=" << m["bitrate"].toDouble()
                        << "fileSize=" << fileSize;
            }
        }

        // 色彩空间启发式推断（裸流 VUI 常为 unspecified）
        // SD(宽<1280) → BT.601, HD(宽≥1280) → BT.709
        QString cs = m["colorSpace"].toString();
        if (cs == "Unknown" || cs.isEmpty()) {
            int w = m["width"].toInt();
            m["colorSpace"] = (w >= 1280) ? "BT.709 (推断)" : "BT.601 (推断)";
        }

        // 参考帧数：从 SPS max_num_ref_frames 解析
        if (m["refs"].toString() == "—") {
            QFile f2(path);
            if (f2.open(QIODevice::ReadOnly)) {
                QByteArray bytes2 = f2.readAll();
                f2.close();
                const uint8_t* raw = reinterpret_cast<const uint8_t*>(bytes2.constData());
                int maxRefs = parseH264MaxRefFrames(raw, bytes2.size());
                if (maxRefs >= 0)
                    m["refs"] = QString::number(maxRefs);
            }
        }
    }

    // 裸流 fallback：avformat 打不开时（纯 annexb .h264/.265）
    if (vIdx < 0) {
        QFileInfo fi(path);
        QString suf = fi.suffix().toLower();
        if (suf == "h264" || suf == "264") {
            m["codec"]     = "h264";
            m["codecLong"] = "H.264 / AVC";
        } else if (suf == "hevc" || suf == "h265" || suf == "265") {
            m["codec"]     = "hevc";
            m["codecLong"] = "H.265 / HEVC";
        } else if (suf == "vvc" || suf == "h266" || suf == "266") {
            m["codec"]     = "vvc";
            m["codecLong"] = "H.266 / VVC";
        }
        m["format"]    = "annexb";
        m["formatLong"] = "Raw Annex-B bitstream";
    }

    qInfo() << "[StreamBridge] probeFile ok:" << path
            << "codec=" << m.value("codec").toString()
            << "w=" << m.value("width").toInt()
            << "h=" << m.value("height").toInt()
            << "fps=" << m.value("fps").toDouble();
    return m;
}

// ═════════════════════════════════════════════════════════════════════════
// 裸码流导出（解封装 AVCC → Annex-B）
// ═════════════════════════════════════════════════════════════════════════

QVariantMap RBStreamBridge::demuxToAnnexB(const QString& path, const QString& outPath) {
    QVariantMap result;
    result["ok"] = false;
    result["frameCount"] = 0;
    result["fileSize"] = qint64(0);
    result["error"] = "";

    if (path.isEmpty() || outPath.isEmpty()) {
        result["error"] = "路径为空";
        return result;
    }

    AVFormatContext* fmt = nullptr;
    int ret = avformat_open_input(&fmt, path.toUtf8().constData(), nullptr, nullptr);
    if (ret < 0 || !fmt) {
        result["error"] = "无法打开文件";
        return result;
    }
    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        avformat_close_input(&fmt);
        result["error"] = "无法获取流信息";
        return result;
    }

    int vIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (vIdx < 0) {
        avformat_close_input(&fmt);
        result["error"] = "未找到视频流";
        return result;
    }

    AVStream* vs = fmt->streams[vIdx];
    AVCodecParameters* par = vs->codecpar;
    bool isH264  = (par->codec_id == AV_CODEC_ID_H264);
    bool isHevc  = (par->codec_id == AV_CODEC_ID_HEVC);
    bool isVvc   = (par->codec_id == AV_CODEC_ID_VVC);

    if (!isH264 && !isHevc && !isVvc) {
        avformat_close_input(&fmt);
        result["error"] = "仅支持 H.264 / H.265 / H.266，当前编码：" +
                          codecIdToShortName(par->codec_id);
        return result;
    }

    // 判断源是否已是裸流
    bool isAlreadyRaw = (fmt->iformat && (
        std::strcmp(fmt->iformat->name, "h264") == 0 ||
        std::strcmp(fmt->iformat->name, "hevc") == 0 ||
        std::strcmp(fmt->iformat->name, "vvc") == 0));

    QFile outFile(outPath);
    if (!outFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        avformat_close_input(&fmt);
        result["error"] = "无法创建输出文件：" + outPath;
        return result;
    }

    int64_t totalSize = fmt->pb ? avio_size(fmt->pb) : 0;
    int frameCount = 0;
    int64_t bytesWritten = 0;

    // ── Annex-B 起始码 ──
    static const uint8_t sc3[] = {0x00, 0x00, 0x01};       // 3-byte start code
    static const uint8_t sc4[] = {0x00, 0x00, 0x00, 0x01}; // 4-byte start code

    if (isAlreadyRaw) {
        // 源已是裸流：直接复制
        avformat_close_input(&fmt);
        QFile srcFile(path);
        if (!srcFile.open(QIODevice::ReadOnly)) {
            result["error"] = "无法读取源文件";
            return result;
        }
        bytesWritten = outFile.write(srcFile.readAll());
        srcFile.close();
        outFile.close();
        result["ok"] = true;
        result["fileSize"] = qint64(bytesWritten);
        result["frameCount"] = 0; // 裸流不遍历计数
        return result;
    }

    // ── 写入参数集（SPS/PPS for H264, VPS/SPS/PPS for HEVC）──
    // 封装文件的 extradata 是 AVCC 格式（length-prefixed），需转成 Annex-B
    if (par->extradata && par->extradata_size > 0) {
        const uint8_t* ed = par->extradata;
        int edSize = par->extradata_size;

        if (isH264 && edSize >= 7 && ed[0] == 1) {
            // AVCC 格式：avcC box
            int numSPS = ed[5] & 0x1f;
            int pos = 6;
            for (int i = 0; i < numSPS && pos + 2 <= edSize; ++i) {
                int spsLen = (ed[pos] << 8) | ed[pos + 1];
                pos += 2;
                if (pos + spsLen > edSize) break;
                outFile.write(reinterpret_cast<const char*>(sc4), 4);
                outFile.write(reinterpret_cast<const char*>(ed + pos), spsLen);
                bytesWritten += 4 + spsLen;
                pos += spsLen;
            }
            int numPPS = (pos < edSize) ? ed[pos] : 0;
            ++pos;
            for (int i = 0; i < numPPS && pos + 2 <= edSize; ++i) {
                int ppsLen = (ed[pos] << 8) | ed[pos + 1];
                pos += 2;
                if (pos + ppsLen > edSize) break;
                outFile.write(reinterpret_cast<const char*>(sc4), 4);
                outFile.write(reinterpret_cast<const char*>(ed + pos), ppsLen);
                bytesWritten += 4 + ppsLen;
                pos += ppsLen;
            }
        } else if (isHevc && edSize >= 23 && (ed[0] >> 6) == 1) {
            // hvcC 格式
            int numArrays = ed[22];
            int pos = 23;
            for (int i = 0; i < numArrays && pos + 3 <= edSize; ++i) {
                int numNalus = (ed[pos + 1] << 8) | ed[pos + 2];
                pos += 3;
                for (int j = 0; j < numNalus && pos + 2 <= edSize; ++j) {
                    int naluLen = (ed[pos] << 8) | ed[pos + 1];
                    pos += 2;
                    if (pos + naluLen > edSize) break;
                    outFile.write(reinterpret_cast<const char*>(sc4), 4);
                    outFile.write(reinterpret_cast<const char*>(ed + pos), naluLen);
                    bytesWritten += 4 + naluLen;
                    pos += naluLen;
                }
            }
        } else {
            // 可能已经是 Annex-B 格式的 extradata，直接写入
            outFile.write(reinterpret_cast<const char*>(ed), edSize);
            bytesWritten += edSize;
        }
    }

    // ── 逐包读取，AVCC → Annex-B 转换 ──
    AVPacket* pkt = av_packet_alloc();
    static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};

    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == vIdx && pkt->data && pkt->size > 4) {
            // AVCC 格式：每个 NALU 前 4 字节为大端长度
            int offset = 0;
            while (offset + 4 <= pkt->size) {
                uint32_t naluLen = (uint32_t(pkt->data[offset]) << 24) |
                                   (uint32_t(pkt->data[offset + 1]) << 16) |
                                   (uint32_t(pkt->data[offset + 2]) << 8) |
                                   uint32_t(pkt->data[offset + 3]);
                offset += 4;
                if (naluLen == 0 || offset + naluLen > pkt->size) break;

                // 写入 4-byte start code + NALU 数据
                outFile.write(reinterpret_cast<const char*>(startCode), 4);
                outFile.write(reinterpret_cast<const char*>(pkt->data + offset),
                              int(naluLen));
                bytesWritten += 4 + int64_t(naluLen);
                offset += int(naluLen);
            }
            ++frameCount;
        }
        av_packet_unref(pkt);

        // 进度上报
        if (totalSize > 0 && pkt->pos > 0) {
            double ratio = double(pkt->pos) / double(totalSize);
            if (ratio > 1.0) ratio = 1.0;
            emit demuxProgress(path, ratio);
        }
    }

    av_packet_free(&pkt);
    avformat_close_input(&fmt);
    outFile.close();

    emit demuxProgress(path, 1.0);

    qInfo() << "[StreamBridge] demuxToAnnexB done:" << path
            << "frames=" << frameCount
            << "bytes=" << bytesWritten
            << "->" << outPath;

    result["ok"] = true;
    result["frameCount"] = frameCount;
    result["fileSize"] = qint64(bytesWritten);
    return result;
}

// ═════════════════════════════════════════════════════════════════════════
// setup 导出：YUV / 指定帧 / 帧列表（不占分析 slot）
// ═════════════════════════════════════════════════════════════════════════

namespace {

QString frameYuvMd5(const AVFrame* fr) {
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(AVPixelFormat(fr->format));
    if (!desc || !fr->data[0]) return QString();
    QCryptographicHash hash(QCryptographicHash::Md5);
    const int nb = av_pix_fmt_count_planes(AVPixelFormat(fr->format));
    for (int p = 0; p < nb; ++p) {
        const int sh = (p == 0) ? 0 : desc->log2_chroma_h;
        const int rows = (fr->height + ((1 << sh) - 1)) >> sh;
        const int ls = av_image_get_linesize(AVPixelFormat(fr->format), fr->width, p);
        if (ls <= 0 || !fr->data[p]) return QString();
        for (int y = 0; y < rows; ++y)
            hash.addData(reinterpret_cast<const char*>(fr->data[p] + y * fr->linesize[p]), ls);
    }
    return QString::fromLatin1(hash.result().toHex());
}

int writeRawPlanes(QIODevice& out, const AVFrame* fr) {
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(AVPixelFormat(fr->format));
    if (!desc || !fr->data[0]) return -1;
    const int nb = av_pix_fmt_count_planes(AVPixelFormat(fr->format));
    for (int p = 0; p < nb; ++p) {
        const int sh = (p == 0) ? 0 : desc->log2_chroma_h;
        const int rows = (fr->height + ((1 << sh) - 1)) >> sh;
        const int ls = av_image_get_linesize(AVPixelFormat(fr->format), fr->width, p);
        if (ls <= 0 || !fr->data[p]) return -1;
        for (int y = 0; y < rows; ++y) {
            if (out.write(reinterpret_cast<const char*>(fr->data[p] + y * fr->linesize[p]),
                          ls) != ls)
                return -1;
        }
    }
    return 0;
}

const char* pictTypeName(AVPictureType t) {
    switch (t) {
    case AV_PICTURE_TYPE_I:  return "I";
    case AV_PICTURE_TYPE_P:  return "P";
    case AV_PICTURE_TYPE_B:  return "B";
    case AV_PICTURE_TYPE_S:  return "S";
    case AV_PICTURE_TYPE_SI: return "SI";
    case AV_PICTURE_TYPE_SP: return "SP";
    case AV_PICTURE_TYPE_BI: return "BI";
    default: return "?";
    }
}

struct OpenedDec {
    AVFormatContext* fmt = nullptr;
    AVCodecContext*  dec = nullptr;
    int vIdx = -1;
};

void closeDec(OpenedDec& o) {
    if (o.dec) avcodec_free_context(&o.dec);
    if (o.fmt) avformat_close_input(&o.fmt);
    o = {};
}

bool openDec(const QString& path, OpenedDec& o, QString* err) {
    int ret = avformat_open_input(&o.fmt, path.toUtf8().constData(), nullptr, nullptr);
    if (ret < 0 || !o.fmt) {
        if (err) *err = "无法打开文件";
        return false;
    }
    if (avformat_find_stream_info(o.fmt, nullptr) < 0) {
        if (err) *err = "无法获取流信息";
        closeDec(o);
        return false;
    }
    o.vIdx = av_find_best_stream(o.fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (o.vIdx < 0) {
        if (err) *err = "未找到视频流";
        closeDec(o);
        return false;
    }
    const AVCodec* codec = avcodec_find_decoder(o.fmt->streams[o.vIdx]->codecpar->codec_id);
    if (!codec) {
        if (err) *err = "找不到解码器";
        closeDec(o);
        return false;
    }
    o.dec = avcodec_alloc_context3(codec);
    if (!o.dec || avcodec_parameters_to_context(o.dec, o.fmt->streams[o.vIdx]->codecpar) < 0
        || avcodec_open2(o.dec, codec, nullptr) < 0) {
        if (err) *err = "打开解码器失败";
        closeDec(o);
        return false;
    }
    return true;
}

} // namespace

QVariantMap RBStreamBridge::exportDecodedYuv(const QString& path, const QString& outPath,
                                             int first, int last) {
    QVariantMap r;
    r["ok"] = false;
    if (path.isEmpty() || outPath.isEmpty()) {
        r["error"] = "路径为空";
        return r;
    }
    if (first < 0) first = 0;
    QString err;
    OpenedDec o;
    if (!openDec(path, o, &err)) {
        r["error"] = err;
        return r;
    }
    QFile out(outPath);
    if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        closeDec(o);
        r["error"] = "无法创建输出文件";
        return r;
    }
    AVPacket* pkt = av_packet_alloc();
    AVFrame* fr = av_frame_alloc();
    int idx = 0, written = 0;
    auto handle = [&](AVFrame* f) {
        if (last >= 0 && idx > last) return;
        if (idx >= first && (last < 0 || idx <= last)) {
            if (writeRawPlanes(out, f) == 0) ++written;
        }
        ++idx;
        if ((idx & 7) == 0)
            emit exportJobProgress(QString("YUV %1 帧…").arg(idx),
                                   last >= 0 ? double(idx) / double(last + 1) : 0);
    };
    while (av_read_frame(o.fmt, pkt) >= 0) {
        if (pkt->stream_index != o.vIdx) { av_packet_unref(pkt); continue; }
        if (avcodec_send_packet(o.dec, pkt) == 0) {
            while (avcodec_receive_frame(o.dec, fr) == 0) {
                handle(fr);
                av_frame_unref(fr);
            }
        }
        av_packet_unref(pkt);
        if (last >= 0 && idx > last) break;
    }
    avcodec_send_packet(o.dec, nullptr);
    while (avcodec_receive_frame(o.dec, fr) == 0) {
        handle(fr);
        av_frame_unref(fr);
    }
    av_packet_free(&pkt);
    av_frame_free(&fr);
    const QString pix = QString::fromLatin1(av_get_pix_fmt_name(o.dec->pix_fmt) ? av_get_pix_fmt_name(o.dec->pix_fmt) : "?");
    const int w = o.dec->width, h = o.dec->height;
    closeDec(o);
    out.close();
    r["ok"] = written > 0;
    r["frameCount"] = written;
    r["error"] = written > 0 ? QString() : "没有写出任何帧";
    r["pixFmt"] = pix;
    r["width"] = w;
    r["height"] = h;
    return r;
}

QVariantMap RBStreamBridge::exportDecodedFrames(const QString& path, const QString& outDir,
                                                int first, int last, const QString& format) {
    QVariantMap r;
    r["ok"] = false;
    if (path.isEmpty() || outDir.isEmpty()) {
        r["error"] = "路径为空";
        return r;
    }
    if (first < 0) first = 0;
    const QString fmt = format.toLower();
    const bool asPng = (fmt != "yuv");
    QDir().mkpath(outDir);
    QString err;
    OpenedDec o;
    if (!openDec(path, o, &err)) {
        r["error"] = err;
        return r;
    }
    SwsContext* sws = nullptr;
    AVPacket* pkt = av_packet_alloc();
    AVFrame* fr = av_frame_alloc();
    int idx = 0, written = 0;
    QString stem = QFileInfo(path).completeBaseName();
    auto handle = [&](AVFrame* f) {
        if (last >= 0 && idx > last) return;
        if (idx >= first && (last < 0 || idx <= last)) {
            const QString name = QString("%1/%2_%3").arg(outDir, stem)
                                    .arg(idx, 6, 10, QChar('0'));
            bool ok = false;
            if (asPng) {
                if (!sws) {
                    sws = sws_getContext(f->width, f->height, AVPixelFormat(f->format),
                                         f->width, f->height, AV_PIX_FMT_RGB24,
                                         SWS_BILINEAR, nullptr, nullptr, nullptr);
                }
                if (sws) {
                    QImage img(f->width, f->height, QImage::Format_RGB888);
                    uint8_t* dst[4] = { img.bits(), nullptr, nullptr, nullptr };
                    int dstLs[4] = { int(img.bytesPerLine()), 0, 0, 0 };
                    sws_scale(sws, f->data, f->linesize, 0, f->height, dst, dstLs);
                    ok = img.save(name + ".png", "PNG");
                }
            } else {
                QFile yuv(name + ".yuv");
                ok = yuv.open(QIODevice::WriteOnly | QIODevice::Truncate)
                     && writeRawPlanes(yuv, f) == 0;
            }
            if (ok) ++written;
        }
        ++idx;
        if ((idx & 7) == 0)
            emit exportJobProgress(QString("导出帧 %1…").arg(idx),
                                   last >= 0 ? double(idx) / double(last + 1) : 0);
    };
    while (av_read_frame(o.fmt, pkt) >= 0) {
        if (pkt->stream_index != o.vIdx) { av_packet_unref(pkt); continue; }
        if (avcodec_send_packet(o.dec, pkt) == 0) {
            while (avcodec_receive_frame(o.dec, fr) == 0) {
                handle(fr);
                av_frame_unref(fr);
            }
        }
        av_packet_unref(pkt);
        if (last >= 0 && idx > last) break;
    }
    avcodec_send_packet(o.dec, nullptr);
    while (avcodec_receive_frame(o.dec, fr) == 0) {
        handle(fr);
        av_frame_unref(fr);
    }
    if (sws) sws_freeContext(sws);
    av_packet_free(&pkt);
    av_frame_free(&fr);
    closeDec(o);
    r["ok"] = written > 0;
    r["frameCount"] = written;
    r["error"] = written > 0 ? QString() : "没有写出任何帧";
    return r;
}

QVariantMap RBStreamBridge::exportFrameListCsv(const QString& path, const QString& outPath) {
    QVariantMap r;
    r["ok"] = false;
    if (path.isEmpty() || outPath.isEmpty()) {
        r["error"] = "路径为空";
        return r;
    }
    QString err;
    OpenedDec o;
    if (!openDec(path, o, &err)) {
        r["error"] = err;
        return r;
    }
    QFile out(outPath);
    if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        closeDec(o);
        r["error"] = "无法创建 CSV";
        return r;
    }
    QTextStream ts(&out);
    ts.setEncoding(QStringConverter::Utf8);
    ts << "index,type,pts,pkt_dts,pkt_size,width,height,md5\n";
    AVPacket* pkt = av_packet_alloc();
    AVFrame* fr = av_frame_alloc();
    int idx = 0;
    auto handle = [&](AVFrame* f, int pktSize) {
        ts << idx << ',' << pictTypeName(f->pict_type) << ','
           << qint64(f->pts) << ',' << qint64(f->pkt_dts) << ','
           << pktSize << ',' << f->width << ',' << f->height << ','
           << frameYuvMd5(f) << '\n';
        ++idx;
        if ((idx & 7) == 0)
            emit exportJobProgress(QString("帧列表 %1 帧…").arg(idx), 0);
    };
    while (av_read_frame(o.fmt, pkt) >= 0) {
        if (pkt->stream_index != o.vIdx) { av_packet_unref(pkt); continue; }
        if (avcodec_send_packet(o.dec, pkt) == 0) {
            while (avcodec_receive_frame(o.dec, fr) == 0) {
                handle(fr, pkt->size);
                av_frame_unref(fr);
            }
        }
        av_packet_unref(pkt);
    }
    avcodec_send_packet(o.dec, nullptr);
    while (avcodec_receive_frame(o.dec, fr) == 0) {
        handle(fr, 0);
        av_frame_unref(fr);
    }
    av_packet_free(&pkt);
    av_frame_free(&fr);
    closeDec(o);
    out.close();
    r["ok"] = idx > 0;
    r["frameCount"] = idx;
    r["error"] = idx > 0 ? QString() : "没有解码到帧";
    return r;
}

void RBStreamBridge::startExportYuv(const QString& path, const QString& outPath,
                                    int first, int last) {
    if (m_exportBusy) {
        emit exportJobFinished(false, "已有导出任务在运行");
        return;
    }
    m_exportBusy = true;
    emit exportJobProgress("开始导出 YUV…", 0);
    QtConcurrent::run([this, path, outPath, first, last]() {
        const QVariantMap r = exportDecodedYuv(path, outPath, first, last);
        const bool ok = r.value("ok").toBool();
        QString msg = r.value("error").toString();
        if (ok) {
            msg = QString("已导出 YUV %1 帧（%2x%3 %4）")
                      .arg(r.value("frameCount").toInt())
                      .arg(r.value("width").toInt())
                      .arg(r.value("height").toInt())
                      .arg(r.value("pixFmt").toString());
        }
        QMetaObject::invokeMethod(this, [this, ok, msg]() {
            m_exportBusy = false;
            emit exportJobFinished(ok, msg);
        }, Qt::QueuedConnection);
    });
}

void RBStreamBridge::startExportFrames(const QString& path, const QString& outDir,
                                       int first, int last, const QString& format) {
    if (m_exportBusy) {
        emit exportJobFinished(false, "已有导出任务在运行");
        return;
    }
    m_exportBusy = true;
    emit exportJobProgress("开始导出指定帧…", 0);
    QtConcurrent::run([this, path, outDir, first, last, format]() {
        const QVariantMap r = exportDecodedFrames(path, outDir, first, last, format);
        const bool ok = r.value("ok").toBool();
        QString msg = r.value("error").toString();
        if (ok)
            msg = QString("已导出 %1 帧到 %2").arg(r.value("frameCount").toInt()).arg(outDir);
        QMetaObject::invokeMethod(this, [this, ok, msg]() {
            m_exportBusy = false;
            emit exportJobFinished(ok, msg);
        }, Qt::QueuedConnection);
    });
}

void RBStreamBridge::startExportFrameList(const QString& path, const QString& outPath) {
    if (m_exportBusy) {
        emit exportJobFinished(false, "已有导出任务在运行");
        return;
    }
    m_exportBusy = true;
    emit exportJobProgress("开始导出帧列表…", 0);
    QtConcurrent::run([this, path, outPath]() {
        const QVariantMap r = exportFrameListCsv(path, outPath);
        const bool ok = r.value("ok").toBool();
        QString msg = r.value("error").toString();
        if (ok)
            msg = QString("已导出帧列表 %1 行").arg(r.value("frameCount").toInt());
        QMetaObject::invokeMethod(this, [this, ok, msg]() {
            m_exportBusy = false;
            emit exportJobFinished(ok, msg);
        }, Qt::QueuedConnection);
    });
}

// ═════════════════════════════════════════════════════════════════════════
// 文件列表持久化（QSettings）—— 与 YuvBridge.yuvFileList 对齐
// ═════════════════════════════════════════════════════════════════════════

QStringList RBStreamBridge::streamFileList() const {
    QSettings settings("PlayerX", "RBStreamBridge");
    QStringList files = settings.value("streamFileList").toStringList();
    qDebug() << "[StreamBridge] streamFileList:" << files.size() << "files <-"
             << settings.fileName();
    return files;
}

void RBStreamBridge::setStreamFileList(const QVariantList& files) {
    QStringList list;
    list.reserve(files.size());
    for (const QVariant& v : files) {
        list << v.toString();
    }
    QSettings settings("PlayerX", "RBStreamBridge");
    settings.setValue("streamFileList", list);
    qDebug() << "[StreamBridge] setStreamFileList:" << list.size() << "files ->"
             << settings.fileName();
}

QVariantMap RBStreamBridge::frameItemToMap(int packetIndex, int type, long long sizeBytes,
                                           double pts, double dts, int poc, double avgQp) {
    QVariantMap m;
    m["packetIndex"] = packetIndex;
    QString tStr = "P";
    switch (type) {
        case 3: tStr = "IDR"; break;
        case 0: tStr = "I";   break;
        case 1: tStr = "P";   break;
        case 2: tStr = "B";   break;
    }
    m["type"] = tStr;
    m["sizeBytes"] = double(sizeBytes);
    m["pts"] = pts;
    m["dts"] = dts;
    m["poc"] = poc;
    m["avgQp"] = avgQp;
    return m;
}

QString RBStreamBridge::pixFmtToString(AVPixelFormat f) {
    const char* name = av_get_pix_fmt_name(f);
    return name ? QString::fromUtf8(name) : QString();
}

QString RBStreamBridge::colorSpaceToString(AVColorSpace cs) {
    switch (cs) {
        case AVCOL_SPC_BT709:       return "BT.709";
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M:   return "BT.601";
        case AVCOL_SPC_BT2020_NCL:
        case AVCOL_SPC_BT2020_CL:   return "BT.2020";
        case AVCOL_SPC_SMPTE240M:   return "SMPTE-240M";
        default:                    return "Unknown";
    }
}

QString RBStreamBridge::colorRangeToString(AVColorRange cr) {
    switch (cr) {
        case AVCOL_RANGE_JPEG: return "full";
        case AVCOL_RANGE_MPEG: return "tv";
        default:               return "unspecified";
    }
}

// 色彩原色（ primaries ）
QString RBStreamBridge::colorPrimariesToString(AVColorPrimaries cp) {
    switch (cp) {
        case AVCOL_PRI_BT709:      return "BT.709";
        case AVCOL_PRI_BT470M:
        case AVCOL_PRI_BT470BG:
        case AVCOL_PRI_SMPTE170M:  return "BT.601";
        case AVCOL_PRI_SMPTE240M:  return "SMPTE-240M";
        case AVCOL_PRI_BT2020:     return "BT.2020";
        case AVCOL_PRI_SMPTE428:   return "SMPTE-428";
        case AVCOL_PRI_SMPTE431:   return "DCI-P3";
        case AVCOL_PRI_SMPTE432:   return "Display P3";
        case AVCOL_PRI_EBU3213:    return "EBU-3213";
        default:                   return "unspecified";
    }
}

// 传输特性（ transfer characteristics ）
QString RBStreamBridge::colorTransferToString(AVColorTransferCharacteristic trc) {
    switch (trc) {
        case AVCOL_TRC_BT709:      return "BT.709";
        case AVCOL_TRC_GAMMA22:
        case AVCOL_TRC_GAMMA28:    return "Gamma";
        case AVCOL_TRC_SMPTE170M:  return "BT.601";
        case AVCOL_TRC_SMPTE240M:  return "SMPTE-240M";
        case AVCOL_TRC_LINEAR:     return "Linear";
        case AVCOL_TRC_LOG:
        case AVCOL_TRC_LOG_SQRT:   return "Log";
        case AVCOL_TRC_IEC61966_2_4: return "IEC-61966-2-4";
        case AVCOL_TRC_BT1361_ECG: return "BT.1361";
        case AVCOL_TRC_IEC61966_2_1: return "sRGB";
        case AVCOL_TRC_BT2020_10:
        case AVCOL_TRC_BT2020_12:  return "BT.2020";
        case AVCOL_TRC_SMPTE2084:  return "PQ (HDR)";
        case AVCOL_TRC_SMPTE428:   return "SMPTE-428";
        case AVCOL_TRC_ARIB_STD_B67: return "HLG (HDR)";
        default:                   return "unspecified";
    }
}

// 色度位置
QString RBStreamBridge::chromaLocationToString(AVChromaLocation cl) {
    switch (cl) {
        case AVCHROMA_LOC_LEFT:        return "left";
        case AVCHROMA_LOC_CENTER:      return "center";
        case AVCHROMA_LOC_TOPLEFT:     return "top-left";
        case AVCHROMA_LOC_TOP:         return "top";
        case AVCHROMA_LOC_BOTTOMLEFT:  return "bottom-left";
        case AVCHROMA_LOC_BOTTOM:      return "bottom";
        default:                        return "unspecified";
    }
}

// 场序
QString RBStreamBridge::fieldOrderToString(AVFieldOrder fo) {
    switch (fo) {
        case AV_FIELD_PROGRESSIVE: return "progressive";
        case AV_FIELD_TT:          return "top-first";
        case AV_FIELD_BB:          return "bottom-first";
        case AV_FIELD_TB:          return "top-coded, bottom-display";
        case AV_FIELD_BT:          return "bottom-coded, top-display";
        default:                   return "unspecified";
    }
}

// ── codec_id → 简洁可读名称 ──
// FFmpeg desc->long_name 太冗长（如 "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"），
// 这里给出简短中文友好名称，与其他代码路径保持一致。
QString RBStreamBridge::codecIdToShortName(AVCodecID id) {
    switch (id) {
        case AV_CODEC_ID_H264:       return "h264";
        case AV_CODEC_ID_HEVC:       return "hevc";
        case AV_CODEC_ID_VVC:        return "vvc";
        case AV_CODEC_ID_VP9:        return "vp9";
        case AV_CODEC_ID_AV1:        return "av1";
        case AV_CODEC_ID_MPEG1VIDEO: return "mpeg1";
        case AV_CODEC_ID_MPEG2VIDEO: return "mpeg2";
        case AV_CODEC_ID_MPEG4:      return "mpeg4";
        default: {
            const AVCodecDescriptor* d = avcodec_descriptor_get(id);
            return QString::fromUtf8(d ? d->name : "unknown");
        }
    }
}

QString RBStreamBridge::codecIdToLongName(AVCodecID id) {
    switch (id) {
        case AV_CODEC_ID_H264:       return "H.264 / AVC";
        case AV_CODEC_ID_HEVC:       return "H.265 / HEVC";
        case AV_CODEC_ID_VVC:        return "H.266 / VVC";
        case AV_CODEC_ID_VP9:        return "VP9";
        case AV_CODEC_ID_AV1:        return "AV1";
        case AV_CODEC_ID_MPEG1VIDEO: return "MPEG-1 Video";
        case AV_CODEC_ID_MPEG2VIDEO: return "MPEG-2 Video";
        case AV_CODEC_ID_MPEG4:      return "MPEG-4 Video";
        default: {
            const AVCodecDescriptor* d = avcodec_descriptor_get(id);
            return QString::fromUtf8(d ? d->long_name : "Unknown");
        }
    }
}

QString RBStreamBridge::profileIdToString(AVCodecID id, int profileId) {
    // FFmpeg 未提供从 raw profile 整数到字符串的 API，h264 业内通用翻译如下：
    if (id == AV_CODEC_ID_H264) {
        switch (profileId) {
            case 66:  return "Baseline";
            case 77:  return "Main";
            case 88:  return "Extended";
            case 100: return "High";
            case 110: return "High10";
            case 122: return "High422";
            case 244: return "High444";
            default:  return QString::number(profileId);
        }
    }
    if (id == AV_CODEC_ID_HEVC) {
        switch (profileId) {
            case 1:  return "Main";
            case 2:  return "Main10";
            case 3:  return "MainStillPicture";
            case 4:  return "Rext";
            case 9:  return "Scc";
            default: return QString::number(profileId);
        }
    }
    if (id == AV_CODEC_ID_VVC) {
        // FFmpeg 的 ff_vvc_profiles 仅定义两项（defs.h）：
        //   AV_PROFILE_VVC_MAIN_10     = 1
        //   AV_PROFILE_VVC_MAIN_10_444 = 33
        switch (profileId) {
            case 1:  return "Main 10";
            case 33: return "Main 10 4:4:4";
            default: return QString::number(profileId);
        }
    }
    return QString::number(profileId);
}

// ═════════════════════════════════════════════════════════════════════════
// 裸 annexb fallback：当 avformat 解析失败（裸 h264/hevc 文件）时调用
// ═════════════════════════════════════════════════════════════════════════

namespace rbstream_raw {
struct NalSpan {
    int64_t offset;
    int     size;
    int     nalType;
};

void scanAnnexBNals(const uint8_t* data, int64_t size,
                    int codecKind, std::vector<NalSpan>& out) {
    out.clear();
    int64_t i = 0;
    while (i + 3 < size) {
        int startCodeLen = 0;
        if (data[i] == 0 && data[i+1] == 0) {
            if (data[i+2] == 1) startCodeLen = 3;
            else if (i + 3 < size && data[i+2] == 0 && data[i+3] == 1) startCodeLen = 4;
        }
        if (startCodeLen == 0) { ++i; continue; }
        int64_t j = i + startCodeLen;
        while (j + 3 < size) {
            if (data[j] == 0 && data[j+1] == 0 &&
                (data[j+2] == 1 ||
                 (j + 3 < size && data[j+2] == 0 && data[j+3] == 1))) break;
            ++j;
        }
        int64_t nalEnd = (j + 3 < size) ? j : size;
        int nalType = 0;
        if (i + startCodeLen < nalEnd) {
            const uint8_t b = data[i + startCodeLen];
            nalType = (codecKind == 0) ? (b & 0x1F) : ((b & 0x7E) >> 1);
        }
        NalSpan ns{ i, int(nalEnd - i - startCodeLen), nalType };
        out.push_back(ns);
        if (j + 3 >= size) break;
        i = j;
    }
}
} // namespace rbstream_raw

bool RBStreamBridge::parseRawAnnexB(Slot& s) {
    QFileInfo fi(s.path);
    const QString suf = fi.suffix().toLower();
    int codecKind = 0;
    QString codecLong = "H.264 / AVC";
    if (suf == "h264") {
        codecKind = 0; codecLong = "H.264 / AVC";
    } else if (suf == "hevc" || suf == "h265" || suf == "265") {
        codecKind = 1; codecLong = "H.265 / HEVC";
    } else {
        return false;
    }

    QFile f(s.path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    QByteArray bytes = f.readAll();
    f.close();
    if (bytes.size() < 16) return false;
    const uint8_t* data = reinterpret_cast<const uint8_t*>(bytes.constData());
    int64_t size = bytes.size();

    std::vector<rbstream_raw::NalSpan> nals;
    rbstream_raw::scanAnnexBNals(data, size, codecKind, nals);
    qInfo() << "[StreamBridge] raw annexb fallback:"
            << "codecKind=" << codecKind
            << "fileSize=" << size
            << "nals=" << nals.size();

    // 找第一个 IDR/slice + SPS
    s.codecName      = (codecKind == 0) ? QStringLiteral("h264") : QStringLiteral("hevc");
    s.codecLongName  = codecLong;
    // 裸流下宽高拿不到（避免写 Exp-Golomb 解析），填0让 UI 标"未加载"，
    // 同时让用户知道只有 h264 / hevc annexB 头足够复杂时才能正确解析。
    // 实践中先尝试走 RBPlayer 实际播放管线（SPS 是 AVCC 编码时 avcodec 也解析不到）。
    s.width          = 0;
    s.height         = 0;
    s.fps            = AVRational{0, 1};
    s.duration       = 0;
    s.bitrate        = 0;
    s.pixFmt         = AV_PIX_FMT_NONE;
    s.colorSpace     = AVCOL_SPC_UNSPECIFIED;
    s.colorRange     = AVCOL_RANGE_UNSPECIFIED;
    s.profile        = -100;
    s.level          = -100;
    s.currentFrame   = 0;

    s.frameTypes.clear();
    s.frameSizes.clear();
    s.frameAvgQp.assign(1, -1.0);
    s.gopStartFrames.clear();
    s.gopFrameCounts.clear();
    s.gopIsOpen.clear();

    const int sliceIdr = (codecKind == 0) ? 5 : 19;
    int frameCount = 0;
    bool firstFrame = true;
    int frameIdx = 0;
    for (const auto& n : nals) {
        if (n.nalType != sliceIdr && !(codecKind == 0 ? n.nalType == 1 : n.nalType <= 1)) continue;
        int t = (n.nalType == sliceIdr) ? 3 : 1;
        if (t == 3 || firstFrame) {
            if (!firstFrame) {
                s.gopFrameCounts.push_back(frameCount);
                s.gopIsOpen.push_back(false);
            }
            s.gopStartFrames.push_back(frameIdx);
            frameCount = 0;
            firstFrame = false;
        }
        s.frameTypes.push_back(t);
        s.frameSizes.push_back(n.size);
        ++frameCount;
        ++frameIdx;
    }
    if (!firstFrame) {
        s.gopFrameCounts.push_back(frameCount);
        s.gopIsOpen.push_back(false);
    }
    if (s.gopStartFrames.empty() && !s.frameTypes.empty()) {
        s.gopStartFrames.push_back(0);
        s.gopFrameCounts.push_back(int(s.frameTypes.size()));
        s.gopIsOpen.push_back(false);
    }
    return !s.frameTypes.empty();
}
