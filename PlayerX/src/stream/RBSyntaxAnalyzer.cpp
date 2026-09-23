/**
 * RBSyntaxAnalyzer.cpp — 语法元素分析器实现
 *
 * 核心思路（复用内嵌 FFmpeg CBS，零手写语法解析）：
 *   1. ff_cbs_init(AV_CODEC_ID_H264/HEVC/VVC) 创建 CBS 上下文；
 *   2. ctx->trace_enable = 1; ctx->trace_read_callback = collectReadCb;
 *      → FFmpeg 逐语法元素解析时回调我们（name + value + 数组下标），
 *        与 VQ Analyzer 的 Syntax Info 同源（CBS trace 即其数据来源）。
 *   3. 数据源两条路径，PPS 不完整时以文件 AnnexB 为准：
 *      a) 容器 extradata（avcC/hvcC/vvcC）→ 拆单元后按 VPS→SPS→PPS 开 trace；
 *      b) 裸 AnnexB 文件 → 自扫参数集 NAL，同样按依赖顺序 read_packet。
 *   4. 逐 NAL 解析，解析前按 NAL 类型设置组标签（两遍法，见下）。
 *   5. 参数集进同一 CBS 上下文后，再读指定图像的 PH + 首个 VCL header
 *      → set="SLICE"（H.266 常把 picture_header 嵌在 slice 头里）。
 *
 * 标签正确性（两遍解析法）：
 *   实测发现单遍解析时 hvcC 中 VPS/SPS/PPS 全被标成 SPS。根因：
 *   read_extradata 的 trace 回调发生在“整个 fragment 解析”期间，回调侧
 *   无法知道当前条目属于哪个 NAL。修复：
 *   第一遍 read_extradata 关 trace，只拿 fragment.units[] 的 NAL 类型与数据；
 *   第二遍把每个参数集 NAL 单独包装成 AnnexB packet 逐个 read_packet 开 trace，
 *   解析前写 currentSet = label(nalType)，回调据此打标签 → VPS/SPS/PPS/APS
 *   各自归位（与 VQ Analyzer 的 tab 一致）。
 *
 * 失败语义：任何一步失败都返回已收集到的部分（可能为空），
 * QML 端拿到空列表走“暂不支持”降级显示，不影响任何既有功能。
 */

#include "stream/RBSyntaxAnalyzer.h"

#include <QDebug>
#include <QFile>
#include <algorithm>
#include <cstring>
#include <utility>

extern "C" {
#include "libavcodec/cbs.h"
#include "libavformat/avformat.h"
}

// cbs.h 的 CBS_FUNC 宏已声明 ff_cbs_init / ff_cbs_close / ff_cbs_read /
// ff_cbs_read_extradata（含完整签名）；仅 fragment_free 不在公开头，
// 手动声明（签名与 cbs_internal.h 一致）：
extern "C" {
void ff_cbs_fragment_free(CodedBitstreamFragment* frag);
}

namespace rb {

namespace {

// ── AnnexB 起始码扫描 ───────────────────────────────────────────
int64_t annexbStartCodeLen(const uint8_t* p, int64_t remaining) {
    if (remaining >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1)
        return 4;
    if (remaining >= 3 && p[0] == 0 && p[1] == 0 && p[2] == 1)
        return 3;
    return -1;
}

// NAL 类型提取（起始码后首字节起）：
//   h264: byte0 & 0x1F
//   hevc: (byte0 & 0x7E) >> 1
//   vvc : (byte1 >> 3) & 0x1F   ← VVC header 2 字节（bit8..bit12 为 type）
int nalTypeH264(const uint8_t* p) { return p[0] & 0x1F; }
int nalTypeHevc(const uint8_t* p) { return (p[0] & 0x7E) >> 1; }
int nalTypeVvc (const uint8_t* p) { return (p[1] >> 3) & 0x1F; }

int nalTypeOf(int codec, const uint8_t* p) {
    if (codec == 0) return nalTypeH264(p);
    if (codec == 1) return nalTypeHevc(p);
    return nalTypeVvc(p);
}

int nalHeaderBytes(int codec) { return (codec == 0) ? 1 : 2; }

bool isVclNal(int codec, int nalType) {
    if (codec == 0) return nalType >= 1 && nalType <= 5;
    if (codec == 1) return (nalType >= 0 && nalType <= 9)
                        || (nalType >= 16 && nalType <= 21);
    return nalType <= 3 || (nalType >= 7 && nalType <= 10);
}

bool isPhNal(int codec, int nalType) {
    return codec == 2 && nalType == 19;   // VVC PH_NUT
}

bool isPpsNal(int codec, int nalType) {
    if (codec == 0) return nalType == 8;
    if (codec == 1) return nalType == 34;
    return nalType == 16;
}

bool isApsNal(int codec, int nalType) {
    return codec == 2 && (nalType == 17 || nalType == 18);
}

QByteArray wrapAnnexb(const uint8_t* data, int size)
{
    QByteArray a;
    a.reserve(size + 4);
    a.append('\x00');
    a.append('\x00');
    a.append('\x00');
    a.append('\x01');
    a.append(reinterpret_cast<const char*>(data), size);
    return a;
}

void eraseSet(std::vector<RBSyntaxEntry>& v, const QString& set)
{
    v.erase(std::remove_if(v.begin(), v.end(),
                           [&](const RBSyntaxEntry& e) { return e.set == set; }),
            v.end());
}

std::vector<RBSyntaxEntry> takeSet(const std::vector<RBSyntaxEntry>& v, const QString& set)
{
    std::vector<RBSyntaxEntry> out;
    for (const auto& e : v)
        if (e.set == set) out.push_back(e);
    return out;
}

// VVC: sh_picture_header_in_slice_header_flag
// HEVC: first_slice_segment_in_pic_flag
// H.264: first_mb_in_slice==0 当且仅当 ue 的首比特为 1
bool vclStartsPicture(int codec, const uint8_t* nal, int64_t nalLen) {
    const int hdr = nalHeaderBytes(codec);
    if (nalLen <= hdr) return false;
    return (nal[hdr] & 0x80) != 0;
}

struct NalSpan {
    int64_t startOff = 0;
    int64_t totalLen = 0;
    int nalType = -1;
};

std::vector<NalSpan> scanNals(const uint8_t* data, int64_t size, int codec)
{
    std::vector<NalSpan> out;
    if (!data || size <= 0) return out;
    int64_t pos = 0;
    int64_t prevDataStart = -1;
    int64_t prevStartCodeOff = -1;
    while (pos < size) {
        const int64_t sc = annexbStartCodeLen(data + pos, size - pos);
        if (sc > 0) {
            if (prevDataStart >= 0 && size - prevDataStart >= 2) {
                NalSpan n;
                n.startOff = prevStartCodeOff;
                n.totalLen = pos - prevStartCodeOff;
                n.nalType = nalTypeOf(codec, data + prevDataStart);
                out.push_back(n);
            }
            prevStartCodeOff = pos;
            prevDataStart = pos + sc;
        }
        ++pos;
    }
    if (prevDataStart >= 0 && size - prevDataStart >= 2) {
        NalSpan n;
        n.startOff = prevStartCodeOff;
        n.totalLen = size - prevStartCodeOff;
        n.nalType = nalTypeOf(codec, data + prevDataStart);
        out.push_back(n);
    }
    return out;
}

// 解码序第 pictureIndex 幅图的 PH（若有）+ 首个 VCL，AnnexB 含起始码。
std::vector<std::pair<int, QByteArray>> findPicturePackets(
    const uint8_t* data, int64_t size, int codec, int pictureIndex)
{
    std::vector<std::pair<int, QByteArray>> out;
    if (!data || size <= 0 || pictureIndex < 0) return out;

    int currentPic = -1;
    bool currentHasSlice = false;
    std::vector<std::pair<int, QByteArray>> current;

    const auto nals = scanNals(data, size, codec);
    for (const auto& nal : nals) {
        const int64_t sc = annexbStartCodeLen(data + nal.startOff, size - nal.startOff);
        if (sc < 0) continue;
        const uint8_t* nalData = data + nal.startOff + sc;
        const int64_t nalDataLen = nal.totalLen - sc;
        const bool ph = isPhNal(codec, nal.nalType);
        const bool vcl = isVclNal(codec, nal.nalType);
        if (!ph && !vcl) continue;

        const bool startsPic = ph || (vcl && vclStartsPicture(codec, nalData, nalDataLen));
        if (startsPic) {
            if (currentPic == pictureIndex && currentHasSlice)
                return current;
            current.clear();
            currentHasSlice = false;
            ++currentPic;
        } else if (currentPic < 0 && vcl) {
            // 缺 PH / first_slice 标志时仍把第一个 VCL 当图 0
            currentPic = 0;
        }

        if (currentPic != pictureIndex) continue;

        current.push_back({nal.nalType, QByteArray(
            reinterpret_cast<const char*>(data + nal.startOff), int(nal.totalLen))});
        if (vcl) {
            currentHasSlice = true;
            return current;
        }
    }
    if (currentPic == pictureIndex && !current.empty())
        return current;
    return {};
}

// ── 参数集 NAL 类型判定 + 组标签 ─────────────────────────────────
// 与 FFmpeg vvc.h / hevc.h NUT 枚举一致；H.264 无 VPS。
bool isParameterSetNal(int codec, int nalType) {
    if (codec == 0) {           // h264: 7=SPS 8=PPS
        return nalType == 7 || nalType == 8;
    }
    if (codec == 1) {           // hevc: 32=VPS 33=SPS 34=PPS
        return nalType == 32 || nalType == 33 || nalType == 34;
    }
    // vvc: 13=DCI 14=VPS 15=SPS 16=PPS 17/18=APS
    return nalType == 13 || nalType == 14 || nalType == 15
        || nalType == 16 || nalType == 17 || nalType == 18;
}

QString parameterSetLabel(int codec, int nalType) {
    if (codec == 0) {
        if (nalType == 7) return QStringLiteral("SPS");
        if (nalType == 8) return QStringLiteral("PPS");
    } else if (codec == 1) {
        if (nalType == 32) return QStringLiteral("VPS");
        if (nalType == 33) return QStringLiteral("SPS");
        if (nalType == 34) return QStringLiteral("PPS");
    } else {
        if (nalType == 13) return QStringLiteral("DCI");
        if (nalType == 14) return QStringLiteral("VPS");
        if (nalType == 15) return QStringLiteral("SPS");
        if (nalType == 16) return QStringLiteral("PPS");
        if (nalType == 17 || nalType == 18) return QStringLiteral("APS");
    }
    return QString();
}

// VPS → SPS → PPS，CBS 解析 PPS 必须先有同 id 的 SPS（H.266 7.3.2.5）。
int paramSetRank(int codec, int nalType)
{
    if (codec == 0) {
        if (nalType == 7) return 0;
        if (nalType == 8) return 1;
    } else if (codec == 1) {
        if (nalType == 32) return 0;
        if (nalType == 33) return 1;
        if (nalType == 34) return 2;
    } else {
        if (nalType == 13) return 0;
        if (nalType == 14) return 1;
        if (nalType == 15) return 2;
        if (nalType == 16) return 3;
        if (nalType == 17 || nalType == 18) return 4;
    }
    return 50;
}

bool ppsLooksComplete(const std::vector<RBSyntaxEntry>& entries)
{
    for (const auto& e : entries) {
        if (e.set != QLatin1String("PPS")) continue;
        if (e.name.contains(QLatin1String("init_qp_minus26")))
            return true;
    }
    return false;
}

// CBS 模板把数组名写成 dpb_max_…[i]，trace 回调同时给出数值下标。
// 官方 trace_read_log 是「替换」方括号里的占位符，不是再拼一层。
// 旧实现追加成 [i][0]，既不符合 H.266 7.3 的写法，也让 RPL 对不上。
QString formatSyntaxName(const char* str, const int* subscripts)
{
    const int subs = (subscripts && subscripts[0] > 0) ? subscripts[0] : 0;
    QString out;
    out.reserve(int(strlen(str)) + subs * 4);
    int n = 0;
    for (int i = 0; str[i];) {
        if (str[i] == '[') {
            if (n < subs) {
                ++n;
                out += QLatin1Char('[');
                out += QString::number(subscripts[n]);
                ++i;
                while (str[i] && str[i] != ']') ++i;
                if (str[i] == ']') {
                    out += QLatin1Char(']');
                    ++i;
                }
            } else {
                while (str[i] && str[i] != ']')
                    out += QLatin1Char(str[i++]);
                if (str[i] == ']')
                    out += QLatin1Char(str[i++]);
            }
        } else {
            out += QLatin1Char(str[i++]);
        }
    }
    return out;
}

int firstSubscript(const int* subscripts)
{
    return (subscripts && subscripts[0] > 0) ? subscripts[1] : 0;
}

bool syntaxBaseEquals(const char* name, const char* base)
{
    const size_t n = strlen(base);
    return std::strncmp(name, base, n) == 0 && (name[n] == '\0' || name[n] == '[');
}

// 把 listIdx / rplsIdx 插到已替换过的入口下标前面：
//   abs_delta_poc_st[3] → abs_delta_poc_st[0][5][3]
//   ltrp_in_header_flag → ltrp_in_header_flag[0][5]
QString insertRplOuterIndices(const QString& name, int listIdx, int rplsIdx)
{
    const int br = name.indexOf(QLatin1Char('['));
    const QString prefix = QStringLiteral("[%1][%2]").arg(listIdx).arg(rplsIdx);
    if (br < 0)
        return name + prefix;
    return name.left(br) + prefix + name.mid(br);
}

QString insertStRpsIndex(const QString& name, int stRpsIdx)
{
    const int br = name.indexOf(QLatin1Char('['));
    const QString prefix = QStringLiteral("[%1]").arg(stRpsIdx);
    if (br < 0)
        return name + prefix;
    return name.left(br) + prefix + name.mid(br);
}

int syntaxInt(const std::vector<RBSyntaxEntry>& v, const QString& set,
              const QString& name, bool* ok)
{
    for (const auto& e : v) {
        if (e.set == set && e.name == name) {
            if (ok) *ok = true;
            return e.value.toInt();
        }
    }
    if (ok) *ok = false;
    return 0;
}

void appendHevcDerived(std::vector<RBSyntaxEntry>& entries)
{
    bool okW = false, okH = false, okMin = false, okDiff = false;
    const QString sps = QStringLiteral("SPS");
    const int w = syntaxInt(entries, sps, QStringLiteral("pic_width_in_luma_samples"), &okW);
    const int h = syntaxInt(entries, sps, QStringLiteral("pic_height_in_luma_samples"), &okH);
    const int log2Min = syntaxInt(entries, sps,
        QStringLiteral("log2_min_luma_coding_block_size_minus3"), &okMin);
    const int log2Diff = syntaxInt(entries, sps,
        QStringLiteral("log2_diff_max_min_luma_coding_block_size"), &okDiff);
    if (!okW || !okH || !okMin || !okDiff || w <= 0 || h <= 0)
        return;

    const int MinCbLog2SizeY = log2Min + 3;
    const int CtbLog2SizeY = MinCbLog2SizeY + log2Diff;
    if (MinCbLog2SizeY < 3 || CtbLog2SizeY > 6)
        return;
    const int MinCbSizeY = 1 << MinCbLog2SizeY;
    const int CtbSizeY = 1 << CtbLog2SizeY;
    const int PicWidthInMinCbsY = w / MinCbSizeY;
    const int PicHeightInMinCbsY = h / MinCbSizeY;
    const int PicWidthInCtbsY = (w + CtbSizeY - 1) / CtbSizeY;
    const int PicHeightInCtbsY = (h + CtbSizeY - 1) / CtbSizeY;

    bool okTbMin = false, okTbDiff = false, okBdY = false, okBdC = false;
    const int tbMin = syntaxInt(entries, sps,
        QStringLiteral("log2_min_luma_transform_block_size_minus2"), &okTbMin);
    const int tbDiff = syntaxInt(entries, sps,
        QStringLiteral("log2_diff_max_min_luma_transform_block_size"), &okTbDiff);
    const int bdY = syntaxInt(entries, sps, QStringLiteral("bit_depth_luma_minus8"), &okBdY);
    const int bdC = syntaxInt(entries, sps, QStringLiteral("bit_depth_chroma_minus8"), &okBdC);

    std::vector<RBSyntaxEntry> extra;
    extra.reserve(20);
    auto add = [&](const char* n, int val) {
        RBSyntaxEntry e;
        e.set = sps;
        e.name = QString::fromLatin1(n);
        e.value = QString::number(val);
        extra.push_back(std::move(e));
    };
    add("MinCbLog2SizeY", MinCbLog2SizeY);
    add("CtbLog2SizeY", CtbLog2SizeY);
    add("MinCbSizeY", MinCbSizeY);
    add("CtbSizeY", CtbSizeY);
    add("PicWidthInMinCbsY", PicWidthInMinCbsY);
    add("PicHeightInMinCbsY", PicHeightInMinCbsY);
    add("PicWidthInCtbsY", PicWidthInCtbsY);
    add("PicHeightInCtbsY", PicHeightInCtbsY);
    add("PicSizeInMinCbsY", PicWidthInMinCbsY * PicHeightInMinCbsY);
    add("PicSizeInCtbsY", PicWidthInCtbsY * PicHeightInCtbsY);
    add("PicSizeInSamplesY", w * h);
    if (okTbMin && okTbDiff) {
        const int MinTbLog2SizeY = tbMin + 2;
        const int MaxTbLog2SizeY = MinTbLog2SizeY + tbDiff;
        add("MinTbLog2SizeY", MinTbLog2SizeY);
        add("MaxTbLog2SizeY", MaxTbLog2SizeY);
        add("MinTbSizeY", 1 << MinTbLog2SizeY);
        add("MaxTbSizeY", 1 << MaxTbLog2SizeY);
    }
    if (okBdY) {
        add("BitDepthY", bdY + 8);
        add("QpBdOffsetY", 6 * bdY);
    }
    if (okBdC)
        add("BitDepthC", bdC + 8);

    auto lastSps = entries.end();
    for (auto it = entries.begin(); it != entries.end(); ++it) {
        if (it->set == sps)
            lastSps = it + 1;
    }
    entries.insert(lastSps, extra.begin(), extra.end());
}

} // namespace

// ── trace 收集器 ────────────────────────────────────────────────
struct RBSyntaxAnalyzer::Collector {
    std::vector<RBSyntaxEntry>* out = nullptr;
    QString currentSet;
    bool emitEntries = true;
    // VVC ref_pic_list_struct(listIdx, rplsIdx) 的外层下标：CBS 对
    // num_ref_entries / abs_delta_poc_st 等只 trace 入口 i，不带 list/rpls。
    int rplListIdx = 0;
    int rplRplsIdx = -1;
    bool rplFromSpsLists = false;
    bool inlineRplSeen = false;
    int spsNumRefPicLists[2] = {0, 0};
    // H.265 7.3.6.1 short_term_ref_pic_set(stRpsIdx)：CBS 只 trace 入口 i
    int hevcStRpsIdx = -1;

    void beginSet(const QString& set) {
        currentSet = set;
        rplListIdx = 0;
        rplRplsIdx = -1;
        rplFromSpsLists = false;
        inlineRplSeen = false;
        hevcStRpsIdx = -1;
    }
};

void RBSyntaxAnalyzer::collectReadCb(void* traceContext, GetBitContext* gbc,
                                     int startPosition, const char* name,
                                     const int* subscripts, int64_t value)
{
    Q_UNUSED(gbc)
    Q_UNUSED(startPosition)
    Collector* c = static_cast<Collector*>(traceContext);
    if (!c || !name) return;

    QString fieldName = formatSyntaxName(name, subscripts);

    // H.266 7.3.10 / 7.3.2.4：RPL 字段带 [listIdx][rplsIdx][i]。
    if (syntaxBaseEquals(name, "sps_num_ref_pic_lists")) {
        c->rplListIdx = firstSubscript(subscripts);
        c->rplRplsIdx = -1;
        c->rplFromSpsLists = true;
        if (c->rplListIdx >= 0 && c->rplListIdx < 2)
            c->spsNumRefPicLists[c->rplListIdx] = int(value);
    } else if (syntaxBaseEquals(name, "rpl_sps_flag")
               || syntaxBaseEquals(name, "rpl_idx")) {
        c->rplListIdx = firstSubscript(subscripts);
        c->rplFromSpsLists = false;
        c->rplRplsIdx = -1;
    } else if (syntaxBaseEquals(name, "num_ref_entries")) {
        if (c->rplFromSpsLists) {
            ++c->rplRplsIdx;
        } else {
            // PH/SH 里 rpl_sps_flag[1] 常被 infer，不进 trace；第二份
            // 内联 RPL 仍要标成 listIdx=1。
            if (c->inlineRplSeen && c->rplListIdx == 0)
                c->rplListIdx = 1;
            c->inlineRplSeen = true;
            const int list = (c->rplListIdx >= 0 && c->rplListIdx < 2) ? c->rplListIdx : 0;
            c->rplRplsIdx = c->spsNumRefPicLists[list];
        }
        fieldName = QStringLiteral("num_ref_entries[%1][%2]")
                        .arg(c->rplListIdx).arg(c->rplRplsIdx);
    } else if (syntaxBaseEquals(name, "abs_delta_poc_st")
               || syntaxBaseEquals(name, "strp_entry_sign_flag")
               || syntaxBaseEquals(name, "inter_layer_ref_pic_flag")
               || syntaxBaseEquals(name, "st_ref_pic_flag")
               || syntaxBaseEquals(name, "ltrp_in_header_flag")
               || syntaxBaseEquals(name, "rpls_poc_lsb_lt")
               || syntaxBaseEquals(name, "ilrp_idx")) {
        if (c->rplRplsIdx >= 0)
            fieldName = insertRplOuterIndices(fieldName, c->rplListIdx, c->rplRplsIdx);
    } else if (syntaxBaseEquals(name, "num_short_term_ref_pic_sets")) {
        c->hevcStRpsIdx = -1;
    } else if (syntaxBaseEquals(name, "inter_ref_pic_set_prediction_flag")) {
        ++c->hevcStRpsIdx;
        fieldName = QStringLiteral("inter_ref_pic_set_prediction_flag[%1]")
                        .arg(c->hevcStRpsIdx);
    } else if (syntaxBaseEquals(name, "delta_idx_minus1")
               || syntaxBaseEquals(name, "delta_rps_sign")
               || syntaxBaseEquals(name, "abs_delta_rps_minus1")
               || syntaxBaseEquals(name, "used_by_curr_pic_flag")
               || syntaxBaseEquals(name, "use_delta_flag")
               || syntaxBaseEquals(name, "num_negative_pics")
               || syntaxBaseEquals(name, "num_positive_pics")
               || syntaxBaseEquals(name, "delta_poc_s0_minus1")
               || syntaxBaseEquals(name, "used_by_curr_pic_s0_flag")
               || syntaxBaseEquals(name, "delta_poc_s1_minus1")
               || syntaxBaseEquals(name, "used_by_curr_pic_s1_flag")) {
        if (c->hevcStRpsIdx >= 0)
            fieldName = insertStRpsIndex(fieldName, c->hevcStRpsIdx);
    }

    if (!c->emitEntries || !c->out) return;

    RBSyntaxEntry e;
    e.set = c->currentSet;
    e.name = fieldName;
    e.value = QString::number(static_cast<long long>(value));
    c->out->push_back(std::move(e));
}

std::vector<RBSyntaxEntry> RBSyntaxAnalyzer::analyze(const QString& codecName,
                                                     const uint8_t* extradata,
                                                     int extradataSize,
                                                     const QString& annexbPath)
{
    std::vector<RBSyntaxEntry> entries;

    enum AVCodecID codecId = AV_CODEC_ID_NONE;
    int codecIdx = -1;   // 0=h264 1=hevc 2=vvc（内部 NAL 刳定用）
    if (codecName == QStringLiteral("h264")) {
        codecId = AV_CODEC_ID_H264; codecIdx = 0;
    } else if (codecName == QStringLiteral("hevc")) {
        codecId = AV_CODEC_ID_HEVC;  codecIdx = 1;
    } else if (codecName == QStringLiteral("vvc")) {
        codecId = AV_CODEC_ID_VVC;   codecIdx = 2;
    } else {
        return entries;   // 其它编码不支持语法面板（UI 降级）
    }

    Collector collector;
    collector.out = &entries;

    auto parsePackets = [&](CodedBitstreamContext* c,
                            std::vector<std::pair<int, QByteArray>> packets) {
        if (!c || packets.empty()) return;
        std::sort(packets.begin(), packets.end(),
                  [codecIdx](const std::pair<int, QByteArray>& a,
                             const std::pair<int, QByteArray>& b) {
                      return paramSetRank(codecIdx, a.first)
                             < paramSetRank(codecIdx, b.first);
                  });
        for (const auto& ps : packets) {
            const QString label = parameterSetLabel(codecIdx, ps.first);
            if (label.isEmpty()) continue;
            collector.beginSet(label);
            AVPacket* pkt = av_packet_alloc();
            pkt->data = reinterpret_cast<uint8_t*>(
                const_cast<char*>(ps.second.constData()));
            pkt->size = int(ps.second.size());
            CodedBitstreamFragment frag;
            memset(&frag, 0, sizeof(frag));
            ff_cbs_read_packet(c, &frag, pkt);
            ff_cbs_fragment_free(&frag);
            av_packet_free(&pkt);
        }
    };

    // VPS/SPS/DCI 各留一份；PPS/APS 全部留下（vvcC 里第一份 PPS 常是截断的）。
    auto collectAnnexbPackets = [&](const uint8_t* data, int64_t size) {
        std::vector<std::pair<int, QByteArray>> packets;
        bool typeSeen[64] = { false };
        int ppsCount = 0, apsCount = 0;
        for (const auto& nal : scanNals(data, size, codecIdx)) {
            if (parameterSetLabel(codecIdx, nal.nalType).isEmpty()) continue;
            const bool multi = isPpsNal(codecIdx, nal.nalType)
                            || isApsNal(codecIdx, nal.nalType);
            // HEVC VPS/SPS 是 32/33，必须用到 64；原先 <32 导致裸 265
            // 每遇到一次参数集就重复收集。
            if (!multi && nal.nalType >= 0 && nal.nalType < 64) {
                if (typeSeen[nal.nalType]) continue;
                typeSeen[nal.nalType] = true;
            }
            if (isPpsNal(codecIdx, nal.nalType) && ++ppsCount > 8) continue;
            if (isApsNal(codecIdx, nal.nalType) && ++apsCount > 32) continue;
            packets.push_back({nal.nalType, QByteArray(
                reinterpret_cast<const char*>(data + nal.startOff), int(nal.totalLen))});
        }
        return packets;
    };

    auto collectAvformatPackets = [&](const QString& path) {
        std::vector<std::pair<int, QByteArray>> packets;
        AVFormatContext* fmt = nullptr;
        if (avformat_open_input(&fmt, path.toUtf8().constData(), nullptr, nullptr) < 0)
            return packets;
        avformat_find_stream_info(fmt, nullptr);
        const int vIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        if (vIdx < 0) {
            avformat_close_input(&fmt);
            return packets;
        }
        CodedBitstreamContext* split = nullptr;
        if (ff_cbs_init(&split, codecId, nullptr) < 0 || !split) {
            avformat_close_input(&fmt);
            return packets;
        }
        split->trace_enable = 0;
        AVPacket* pkt = av_packet_alloc();
        int nPkt = 0;
        while (nPkt < 40 && av_read_frame(fmt, pkt) >= 0) {
            if (pkt->stream_index == vIdx) {
                ++nPkt;
                CodedBitstreamFragment frag;
                memset(&frag, 0, sizeof(frag));
                ff_cbs_read_packet(split, &frag, pkt);
                for (int u = 0; u < frag.nb_units; ++u) {
                    const int t = int(frag.units[u].type);
                    if (!isParameterSetNal(codecIdx, t) || !frag.units[u].data)
                        continue;
                    packets.push_back({t, wrapAnnexb(frag.units[u].data,
                                                     int(frag.units[u].data_size))});
                }
                ff_cbs_fragment_free(&frag);
            }
            av_packet_unref(pkt);
        }
        av_packet_free(&pkt);
        ff_cbs_close(&split);
        avformat_close_input(&fmt);
        return packets;
    };

    auto parseOneAnnexb = [&](CodedBitstreamContext* c, const QByteArray& annexb) {
        if (!c || annexb.isEmpty()) return;
        AVPacket* pkt = av_packet_alloc();
        pkt->data = reinterpret_cast<uint8_t*>(const_cast<char*>(annexb.constData()));
        pkt->size = int(annexb.size());
        CodedBitstreamFragment frag;
        memset(&frag, 0, sizeof(frag));
        ff_cbs_read_packet(c, &frag, pkt);
        ff_cbs_fragment_free(&frag);
        av_packet_free(&pkt);
    };

    auto loadParamSetsQuiet = [&](CodedBitstreamContext* c,
                                  const std::vector<std::pair<int, QByteArray>>& packets) {
        if (!c || packets.empty()) return;
        collector.emitEntries = false;
        parsePackets(c, packets);
        collector.emitEntries = true;
    };

    auto parsePictureSlice = [&](CodedBitstreamContext* c,
                                 const std::vector<std::pair<int, QByteArray>>& pic) {
        if (!c || pic.empty()) return;
        collector.beginSet(QStringLiteral("SLICE"));
        for (const auto& ps : pic)
            parseOneAnnexb(c, ps.second);
    };

    std::vector<std::pair<int, QByteArray>> paramPackets;
    std::vector<RBSyntaxEntry> paramEntries;
    collector.out = &paramEntries;

    // 2) 数据源 A：容器 extradata（avcC/hvcC/vvcC）—— 两遍解析法
    //    第一遍：ctxA 拆单元拿类型与数据；第二遍 ctxB 按 VPS→SPS→PPS
    //    顺序开 trace。VVC PPS 的宽高是 ue(v)，range 上限来自已解析 SPS；
    //    且 CBS 在读到 pps_seq_parameter_set_id 后立刻查 h266->sps[]，
    //    所以同一上下文里必须先成功解析 SPS。
    if (extradata && extradataSize > 0) {
        AVCodecParameters* par = avcodec_parameters_alloc();
        par->codec_id = codecId;
        par->extradata = const_cast<uint8_t*>(extradata);
        par->extradata_size = extradataSize;

        CodedBitstreamContext* ctxA = nullptr;
        if (ff_cbs_init(&ctxA, codecId, nullptr) >= 0 && ctxA) {
            ctxA->trace_enable = 0;
            CodedBitstreamFragment frag1;
            memset(&frag1, 0, sizeof(frag1));
            std::vector<std::pair<int, QByteArray>> paramSets;
            if (ff_cbs_read_extradata(ctxA, &frag1, par) >= 0) {
                for (int u = 0; u < frag1.nb_units; ++u) {
                    const int t = int(frag1.units[u].type);
                    if (!isParameterSetNal(codecIdx, t)) continue;
                    QByteArray annexb;
                    annexb.reserve(int(frag1.units[u].data_size) + 4);
                    annexb.append('\x00');
                    annexb.append('\x00');
                    annexb.append('\x00');
                    annexb.append('\x01');
                    annexb.append(reinterpret_cast<const char*>(frag1.units[u].data),
                                  int(frag1.units[u].data_size));
                    paramSets.push_back({t, annexb});
                }
            }
            ff_cbs_fragment_free(&frag1);
            ff_cbs_close(&ctxA);

            if (!paramSets.empty())
                paramPackets = paramSets;

            CodedBitstreamContext* ctxB = nullptr;
            if (!paramSets.empty()
                && ff_cbs_init(&ctxB, codecId, nullptr) >= 0 && ctxB) {
                ctxB->trace_enable = 1;
                ctxB->trace_read_callback = &RBSyntaxAnalyzer::collectReadCb;
                ctxB->trace_context = &collector;
                parsePackets(ctxB, paramSets);
                ff_cbs_close(&ctxB);
            }
        }

        par->extradata = nullptr;
        par->extradata_size = 0;
        avcodec_parameters_free(&par);
    }

    // 3) 码流里的参数集。vvcC 经常只有完整 SPS + 截断 PPS（47×7），
    //    APS 更不会进 extradata。按 set 合并：SPS/VPS 可留 extra，
    //    PPS 必须换成带 init_qp 的整包，APS 从图前 NAL 追加。
    QByteArray annexbBlob;
    std::vector<std::pair<int, QByteArray>> inbandPackets;
    if (!annexbPath.isEmpty()) {
        QFile f(annexbPath);
        if (f.open(QIODevice::ReadOnly)) {
            static constexpr int64_t kMaxScan = 16LL * 1024 * 1024;
            annexbBlob = f.read(kMaxScan);
            f.close();
            inbandPackets = collectAnnexbPackets(
                reinterpret_cast<const uint8_t*>(annexbBlob.constData()),
                annexbBlob.size());
        }
        bool inbandHasFatPps = false;
        for (const auto& p : inbandPackets) {
            if (isPpsNal(codecIdx, p.first) && p.second.size() >= 12) {
                inbandHasFatPps = true;
                break;
            }
        }
        if (!ppsLooksComplete(paramEntries) && !inbandHasFatPps) {
            auto fromFmt = collectAvformatPackets(annexbPath);
            inbandPackets.insert(inbandPackets.end(), fromFmt.begin(), fromFmt.end());
        }
    }

    auto parseWithSps = [&](const std::vector<std::pair<int, QByteArray>>& body,
                            std::vector<RBSyntaxEntry>* dest) {
        CodedBitstreamContext* ctx = nullptr;
        if (ff_cbs_init(&ctx, codecId, nullptr) < 0 || !ctx) return;
        ctx->trace_enable = 1;
        ctx->trace_read_callback = &RBSyntaxAnalyzer::collectReadCb;
        ctx->trace_context = &collector;
        collector.out = dest;
        std::vector<std::pair<int, QByteArray>> base;
        for (const auto& p : paramPackets) {
            if (isPpsNal(codecIdx, p.first) || isApsNal(codecIdx, p.first))
                continue;
            base.push_back(p);
        }
        loadParamSetsQuiet(ctx, base);
        collector.emitEntries = true;
        for (const auto& ps : body) {
            const QString label = parameterSetLabel(codecIdx, ps.first);
            if (label.isEmpty()) continue;
            collector.beginSet(label);
            parseOneAnnexb(ctx, ps.second);
        }
        ff_cbs_close(&ctx);
        collector.out = &paramEntries;
    };

    if (!inbandPackets.empty()) {
        std::vector<std::pair<int, QByteArray>> ppsPkts, apsPkts, otherPkts;
        for (const auto& p : inbandPackets) {
            if (isPpsNal(codecIdx, p.first)) ppsPkts.push_back(p);
            else if (isApsNal(codecIdx, p.first)) apsPkts.push_back(p);
            else otherPkts.push_back(p);
        }
        bool haveSps = false;
        for (const auto& p : paramPackets) {
            if (parameterSetLabel(codecIdx, p.first) == QLatin1String("SPS")) {
                haveSps = true;
                break;
            }
        }
        if (!haveSps)
            paramPackets.insert(paramPackets.end(), otherPkts.begin(), otherPkts.end());

        if (!ppsLooksComplete(paramEntries)) {
            std::vector<RBSyntaxEntry> bestPps;
            std::pair<int, QByteArray> bestPpsPkt{-1, {}};
            for (const auto& pps : ppsPkts) {
                if (pps.second.size() < 12) continue;   // vvcC 截断包通常只有几字节
                std::vector<RBSyntaxEntry> tmp;
                parseWithSps({pps}, &tmp);
                auto only = takeSet(tmp, QStringLiteral("PPS"));
                if (ppsLooksComplete(only)) {
                    bestPps = std::move(only);
                    bestPpsPkt = pps;
                    break;
                }
                if (bestPps.empty() && !only.empty()) {
                    bestPps = std::move(only);
                    bestPpsPkt = pps;
                }
            }
            if (ppsLooksComplete(bestPps)) {
                eraseSet(paramEntries, QStringLiteral("PPS"));
                paramEntries.insert(paramEntries.end(), bestPps.begin(), bestPps.end());
                if (bestPpsPkt.first >= 0) {
                    paramPackets.erase(std::remove_if(paramPackets.begin(), paramPackets.end(),
                        [codecIdx](const std::pair<int, QByteArray>& p) {
                            return isPpsNal(codecIdx, p.first);
                        }), paramPackets.end());
                    paramPackets.push_back(bestPpsPkt);
                }
            } else if (paramPackets.empty() && !otherPkts.empty()) {
                paramPackets.insert(paramPackets.end(), otherPkts.begin(), otherPkts.end());
            }
        }

        if (!apsPkts.empty()) {
            std::vector<RBSyntaxEntry> apsEntries;
            parseWithSps(apsPkts, &apsEntries);
            eraseSet(paramEntries, QStringLiteral("APS"));
            auto onlyAps = takeSet(apsEntries, QStringLiteral("APS"));
            paramEntries.insert(paramEntries.end(), onlyAps.begin(), onlyAps.end());
            for (const auto& a : apsPkts)
                paramPackets.push_back(a);
        }
    }

    // 裸 265：extradata 为空或只解析出 PPS 时，VPS/SPS 已进 paramPackets
    // 却从未开 trace。这里补一遍发出去。
    {
        auto hasSet = [&](const QString& set) {
            for (const auto& e : paramEntries)
                if (e.set == set) return true;
            return false;
        };
        const bool missVps = !hasSet(QStringLiteral("VPS"));
        const bool missSps = !hasSet(QStringLiteral("SPS"));
        if (missVps || missSps) {
            std::vector<std::pair<int, QByteArray>> need;
            auto takeNeed = [&](const std::vector<std::pair<int, QByteArray>>& src) {
                for (const auto& p : src) {
                    const QString lab = parameterSetLabel(codecIdx, p.first);
                    if ((missVps && lab == QLatin1String("VPS"))
                        || (missSps && lab == QLatin1String("SPS")))
                        need.push_back(p);
                }
            };
            takeNeed(paramPackets);
            if (need.empty()) {
                takeNeed(inbandPackets);
                paramPackets.insert(paramPackets.end(), need.begin(), need.end());
            }
            if (!need.empty()) {
                CodedBitstreamContext* ctxFill = nullptr;
                if (ff_cbs_init(&ctxFill, codecId, nullptr) >= 0 && ctxFill) {
                    ctxFill->trace_enable = 1;
                    ctxFill->trace_read_callback = &RBSyntaxAnalyzer::collectReadCb;
                    ctxFill->trace_context = &collector;
                    std::vector<RBSyntaxEntry> filled;
                    collector.out = &filled;
                    parsePackets(ctxFill, need);
                    ff_cbs_close(&ctxFill);
                    collector.out = &paramEntries;
                    if (missVps) {
                        auto only = takeSet(filled, QStringLiteral("VPS"));
                        paramEntries.insert(paramEntries.begin(),
                                            only.begin(), only.end());
                    }
                    if (missSps) {
                        auto only = takeSet(filled, QStringLiteral("SPS"));
                        size_t ins = 0;
                        for (size_t i = 0; i < paramEntries.size(); ++i)
                            if (paramEntries[i].set == QLatin1String("VPS"))
                                ins = i + 1;
                        paramEntries.insert(paramEntries.begin() + int(ins),
                                            only.begin(), only.end());
                    }
                }
            }
        }
    }

    // 4) 第一幅图的 PH + 首 slice header。写入独立列表，绝不覆盖参数集。
    std::vector<RBSyntaxEntry> sliceEntries;
    if (!annexbBlob.isEmpty() && !paramPackets.empty()) {
        auto pic = findPicturePackets(
            reinterpret_cast<const uint8_t*>(annexbBlob.constData()),
            annexbBlob.size(), codecIdx, 0);
        if (!pic.empty()) {
            CodedBitstreamContext* ctxSlice = nullptr;
            if (ff_cbs_init(&ctxSlice, codecId, nullptr) >= 0 && ctxSlice) {
                ctxSlice->trace_enable = 1;
                ctxSlice->trace_read_callback = &RBSyntaxAnalyzer::collectReadCb;
                ctxSlice->trace_context = &collector;
                collector.out = &sliceEntries;
                loadParamSetsQuiet(ctxSlice, paramPackets);
                parsePictureSlice(ctxSlice, pic);
                ff_cbs_close(&ctxSlice);
            }
        }
    }

    entries = std::move(paramEntries);
    entries.insert(entries.end(), sliceEntries.begin(), sliceEntries.end());
    if (codecIdx == 1)
        appendHevcDerived(entries);
    return entries;
}

std::vector<RBSyntaxEntry> RBSyntaxAnalyzer::analyzePicture(const QString& codecName,
                                                            const uint8_t* extradata,
                                                            int extradataSize,
                                                            const QString& annexbPath,
                                                            int pictureIndex)
{
    std::vector<RBSyntaxEntry> entries;
    if (pictureIndex < 0 || annexbPath.isEmpty())
        return entries;

    enum AVCodecID codecId = AV_CODEC_ID_NONE;
    int codecIdx = -1;
    if (codecName == QStringLiteral("h264")) {
        codecId = AV_CODEC_ID_H264; codecIdx = 0;
    } else if (codecName == QStringLiteral("hevc")) {
        codecId = AV_CODEC_ID_HEVC;  codecIdx = 1;
    } else if (codecName == QStringLiteral("vvc")) {
        codecId = AV_CODEC_ID_VVC;   codecIdx = 2;
    } else {
        return entries;
    }

    Collector collector;
    collector.out = &entries;

    auto parsePackets = [&](CodedBitstreamContext* c,
                            std::vector<std::pair<int, QByteArray>> packets) {
        if (!c || packets.empty()) return;
        std::sort(packets.begin(), packets.end(),
                  [codecIdx](const std::pair<int, QByteArray>& a,
                             const std::pair<int, QByteArray>& b) {
                      return paramSetRank(codecIdx, a.first)
                             < paramSetRank(codecIdx, b.first);
                  });
        for (const auto& ps : packets) {
            const QString label = parameterSetLabel(codecIdx, ps.first);
            if (label.isEmpty()) continue;
            collector.beginSet(label);
            AVPacket* pkt = av_packet_alloc();
            pkt->data = reinterpret_cast<uint8_t*>(
                const_cast<char*>(ps.second.constData()));
            pkt->size = int(ps.second.size());
            CodedBitstreamFragment frag;
            memset(&frag, 0, sizeof(frag));
            ff_cbs_read_packet(c, &frag, pkt);
            ff_cbs_fragment_free(&frag);
            av_packet_free(&pkt);
        }
    };

    std::vector<std::pair<int, QByteArray>> paramPackets;
    if (extradata && extradataSize > 0) {
        AVCodecParameters* par = avcodec_parameters_alloc();
        par->codec_id = codecId;
        par->extradata = const_cast<uint8_t*>(extradata);
        par->extradata_size = extradataSize;
        CodedBitstreamContext* ctxA = nullptr;
        if (ff_cbs_init(&ctxA, codecId, nullptr) >= 0 && ctxA) {
            ctxA->trace_enable = 0;
            CodedBitstreamFragment frag1;
            memset(&frag1, 0, sizeof(frag1));
            if (ff_cbs_read_extradata(ctxA, &frag1, par) >= 0) {
                for (int u = 0; u < frag1.nb_units; ++u) {
                    const int t = int(frag1.units[u].type);
                    if (!isParameterSetNal(codecIdx, t)) continue;
                    QByteArray annexb;
                    annexb.reserve(int(frag1.units[u].data_size) + 4);
                    annexb.append('\x00');
                    annexb.append('\x00');
                    annexb.append('\x00');
                    annexb.append('\x01');
                    annexb.append(reinterpret_cast<const char*>(frag1.units[u].data),
                                  int(frag1.units[u].data_size));
                    paramPackets.push_back({t, annexb});
                }
            }
            ff_cbs_fragment_free(&frag1);
            ff_cbs_close(&ctxA);
        }
        par->extradata = nullptr;
        par->extradata_size = 0;
        avcodec_parameters_free(&par);
    }

    QFile f(annexbPath);
    if (!f.open(QIODevice::ReadOnly))
        return entries;

    static constexpr int64_t kChunk = 16LL * 1024 * 1024;
    static constexpr int64_t kMaxScan = 64LL * 1024 * 1024;
    QByteArray blob = f.read(kChunk);
    auto pic = findPicturePackets(
        reinterpret_cast<const uint8_t*>(blob.constData()),
        blob.size(), codecIdx, pictureIndex);
    while (pic.empty() && !f.atEnd() && blob.size() < kMaxScan) {
        blob += f.read(kChunk);
        pic = findPicturePackets(
            reinterpret_cast<const uint8_t*>(blob.constData()),
            blob.size(), codecIdx, pictureIndex);
    }
    f.close();

    {
        std::pair<int, QByteArray> bestPps{-1, {}};
        bool typeSeen[32] = { false };
        for (const auto& nal : scanNals(
                 reinterpret_cast<const uint8_t*>(blob.constData()),
                 blob.size(), codecIdx)) {
            if (parameterSetLabel(codecIdx, nal.nalType).isEmpty()) continue;
            QByteArray raw(reinterpret_cast<const char*>(blob.constData() + nal.startOff),
                           int(nal.totalLen));
            if (isPpsNal(codecIdx, nal.nalType)) {
                if (raw.size() > bestPps.second.size())
                    bestPps = {nal.nalType, raw};
                continue;
            }
            if (nal.nalType >= 0 && nal.nalType < 32) {
                if (typeSeen[nal.nalType]) continue;
                typeSeen[nal.nalType] = true;
            }
            if (paramPackets.empty() || isApsNal(codecIdx, nal.nalType))
                paramPackets.push_back({nal.nalType, raw});
        }
        if (bestPps.first >= 0 && bestPps.second.size() >= 12) {
            paramPackets.erase(std::remove_if(paramPackets.begin(), paramPackets.end(),
                [codecIdx](const std::pair<int, QByteArray>& p) {
                    return isPpsNal(codecIdx, p.first);
                }), paramPackets.end());
            paramPackets.push_back(std::move(bestPps));
        }
    }

    if (pic.empty() || paramPackets.empty())
        return entries;

    CodedBitstreamContext* ctx = nullptr;
    if (ff_cbs_init(&ctx, codecId, nullptr) < 0 || !ctx)
        return entries;
    ctx->trace_enable = 1;
    ctx->trace_read_callback = &RBSyntaxAnalyzer::collectReadCb;
    ctx->trace_context = &collector;
    collector.emitEntries = false;
    parsePackets(ctx, paramPackets);
    collector.emitEntries = true;
    collector.beginSet(QStringLiteral("SLICE"));
    for (const auto& ps : pic) {
        AVPacket* pkt = av_packet_alloc();
        pkt->data = reinterpret_cast<uint8_t*>(
            const_cast<char*>(ps.second.constData()));
        pkt->size = int(ps.second.size());
        CodedBitstreamFragment frag;
        memset(&frag, 0, sizeof(frag));
        ff_cbs_read_packet(ctx, &frag, pkt);
        ff_cbs_fragment_free(&frag);
        av_packet_free(&pkt);
    }
    ff_cbs_close(&ctx);
    return entries;
}

QVariantList RBSyntaxAnalyzer::toVariantList(const std::vector<RBSyntaxEntry>& entries)
{
    QVariantList out;
    out.reserve(int(entries.size()));
    for (const auto& e : entries) {
        QVariantMap m;
        m.insert(QStringLiteral("set"), e.set);
        m.insert(QStringLiteral("name"), e.name);
        m.insert(QStringLiteral("value"), e.value);
        out.append(m);
    }
    return out;
}

std::vector<std::pair<int64_t, int64_t>> RBSyntaxAnalyzer::findParameterSetNals(
    const uint8_t* data, int64_t size, int codec)
{
    std::vector<std::pair<int64_t, int64_t>> out;
    for (const auto& nal : scanNals(data, size, codec)) {
        if (isParameterSetNal(codec, nal.nalType))
            out.push_back({nal.startOff, nal.totalLen});
    }
    return out;
}

} // namespace rb
