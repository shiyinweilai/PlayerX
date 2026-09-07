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
#include "core/rb_demuxer.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/pixdesc.h>
}

#include <QFile>
#include <QFileInfo>
#include <QDebug>
#include <cstring>

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
    emit slotCountChanged();
    emit fileOpened(slot);
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
    // 简易 POC 重建：IDR=0, 之后递增。真实 POC 需 slice header 解析，一期不实现。
    int poc = 0;
    for (int i = 0; i < n; ++i) {
        int t = s.frameTypes[i];
        // 帧类型字符串：IDR / I / P / B
        QString tStr;
        switch (t) {
            case 3: tStr = "IDR"; break;
            case 0: tStr = "I";   break;
            case 1: tStr = "P";   break;
            case 2: tStr = "B";   break;
            default: tStr = "P"; break;  // 未知兜底
        }
        double ptsSec = (n > 0) ? double(i) / (fps(slot) > 0 ? fps(slot) : 30.0) : 0;
        double dtsSec = ptsSec;  // 一期 DTS≈PTS
        list.append(frameItemToMap(i, t, s.frameSizes[i], ptsSec, dtsSec, poc, s.frameAvgQp[0]));
        // 简单 POC 规则：IDR 复位为 0；其余 ++
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

QVariantList RBStreamBridge::blockInfoAt(int /*slot*/, int /*frameIndex*/) const {
    // 一期占位：始终返回空数组。
    // 接入路径见 码流分析架构.md §4（FFmpeg 解码器打补丁导出）。
    return QVariantList{};
}

void RBStreamBridge::seekPlayerTo(int slot, int frameIndex) {
    // 一期不真正联动 EngineBridge（避免双向循环依赖 RBStreamBridge <-> EngineBridge）；
    // 简单日志 + 后续接 EngineBridge.seekPlayerTo(slot, secs)。
    if (!hasFile(slot)) return;
    const double secs = fps(slot) > 0 ? double(frameIndex) / fps(slot) : 0;
    qInfo() << "[StreamBridge] seekPlayerTo slot=" << slot
            << "frame=" << frameIndex << "secs=" << secs;
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
                           || m["format"].toString() == "hevc");
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
                bool isHevc = (m["codec"].toString() == "hevc");

                // 扫描 NAL start codes，统计 slice NAL 数量
                int sliceCount = 0;
                int64_t i = 0;
                while (i + 4 <= fileSize) {
                    int scLen = 0;
                    if (data[i] == 0 && data[i+1] == 0) {
                        if (data[i+2] == 1) scLen = 3;
                        else if (i + 3 < fileSize && data[i+2] == 0 && data[i+3] == 1) scLen = 4;
                    }
                    if (scLen == 0) { ++i; continue; }
                    if (i + scLen >= fileSize) break;
                    int nalType = isHevc ? ((data[i + scLen] & 0x7E) >> 1)
                                         : (data[i + scLen] & 0x1F);
                    // h264: 1=non-IDR slice, 5=IDR slice
                    // hevc: 0-9=TRAIL/TSA/STSA/RADL/RASL, 16-21=BLA/IDR/CRA
                    if (!isHevc) {
                        if (nalType == 1 || nalType == 5) ++sliceCount;
                    } else {
                        if (nalType <= 9 || (nalType >= 16 && nalType <= 21)) ++sliceCount;
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

    if (!isH264 && !isHevc) {
        avformat_close_input(&fmt);
        result["error"] = "仅支持 H.264 / H.265，当前编码：" +
                          codecIdToShortName(par->codec_id);
        return result;
    }

    // 判断源是否已是裸流
    bool isAlreadyRaw = (fmt->iformat && (
        std::strcmp(fmt->iformat->name, "h264") == 0 ||
        std::strcmp(fmt->iformat->name, "hevc") == 0));

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
