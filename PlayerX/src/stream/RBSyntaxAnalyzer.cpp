/**
 * RBSyntaxAnalyzer.cpp — 语法元素分析器实现
 *
 * 核心思路（复用内嵌 FFmpeg CBS，零手写语法解析）：
 *   1. ff_cbs_init(AV_CODEC_ID_H264/HEVC/VVC) 创建 CBS 上下文；
 *   2. ctx->trace_enable = 1; ctx->trace_read_callback = collectReadCb;
 *      → FFmpeg 逐语法元素解析时回调我们（name + value + 数组下标），
 *        与 VQ Analyzer 的 Syntax Info 同源（CBS trace 即其数据来源）。
 *   3. 数据源两条路径：
 *      a) 容器 extradata（avcC/hvcC/vvcC）→ ff_cbs_read_extradata；
 *      b) 裸 AnnexB 文件 → 自扫参数集 NAL → 逐 NAL ff_cbs_read_packet。
 *   4. 逐 NAL 解析，解析前按 NAL 类型设置组标签（两遍法，见下）。
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
#include <cstring>
#include <utility>

extern "C" {
#include "libavcodec/cbs.h"
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

} // namespace

// ── trace 收集器 ────────────────────────────────────────────────
struct RBSyntaxAnalyzer::Collector {
    std::vector<RBSyntaxEntry>* out = nullptr;
    QString currentSet;
};

void RBSyntaxAnalyzer::collectReadCb(void* traceContext, GetBitContext* gbc,
                                     int startPosition, const char* name,
                                     const int* subscripts, int64_t value)
{
    Q_UNUSED(gbc)
    Q_UNUSED(startPosition)
    Collector* c = static_cast<Collector*>(traceContext);
    if (!c || !name) return;
    // 数组字段（如 sps_qp_table_start_minus26[0]）展开下标
    QString fieldName = QString::fromUtf8(name);
    if (subscripts && subscripts[0] > 0) {
        fieldName += QStringLiteral("[");
        for (int i = 1; i <= subscripts[0]; ++i) {
            if (i > 1) fieldName += QStringLiteral(",");
            fieldName += QString::number(subscripts[i]);
        }
        fieldName += QStringLiteral("]");
    }
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

    // 1) 创建 CBS 上下文
    CodedBitstreamContext* ctx = nullptr;
    if (ff_cbs_init(&ctx, codecId, nullptr) < 0 || !ctx) {
        qWarning() << "[SyntaxAnalyzer] ff_cbs_init failed for" << codecName;
        return entries;
    }

    Collector collector;
    collector.out = &entries;
    ctx->trace_enable = 1;
    ctx->trace_read_callback = &RBSyntaxAnalyzer::collectReadCb;
    ctx->trace_context = &collector;

    // 2) 数据源 A：容器 extradata（avcC/hvcC/vvcC）—— 两遍解析法
    //    第一遍：ctxA 拆单元拿类型与数据（hvcC 的 VPS/SPS/PPS、vvcC 的
    //    DCI/VPS/SPS/PPS/APS 都在 extradata 里）
    //    第二遍：ctxB（全新上下文，天然 AnnexB 模式）逐参数集开 trace 解析。
    //    不能复用同一 ctx：read_extradata 会置 mp4 标志（长度前缀模式），
    //    复用则第二遍 AnnexB 包按长度前缀解析而报 Invalid NAL unit size。
    bool extradataOk = false;
    if (extradata && extradataSize > 0) {
        AVCodecParameters* par = avcodec_parameters_alloc();
        par->codec_id = codecId;
        par->extradata = const_cast<uint8_t*>(extradata);
        par->extradata_size = extradataSize;

        // ── 第一遍：拆单元（ctxA，关 trace）──
        CodedBitstreamContext* ctxA = nullptr;
        if (ff_cbs_init(&ctxA, codecId, nullptr) >= 0 && ctxA) {
            ctxA->trace_enable = 0;
            CodedBitstreamFragment frag1;
            memset(&frag1, 0, sizeof(frag1));
            std::vector<std::pair<int, QByteArray>> paramSets;   // { nalType, AnnexB 数据 }
            if (ff_cbs_read_extradata(ctxA, &frag1, par) >= 0) {
                for (int u = 0; u < frag1.nb_units; ++u) {
                    const int t = int(frag1.units[u].type);
                    if (!isParameterSetNal(codecIdx, t)) continue;
                    // unit->data 是去防竞争字节后的 RBSP 且不含起始码 → 包装
                    // 成 AnnexB（起始码 + data）再单独喂给 read_packet
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

            // ── 第二遍：逐参数集开 trace 解析（ctxB 全新上下文）──
            CodedBitstreamContext* ctxB = nullptr;
            if (paramSets.size() > 0 && ff_cbs_init(&ctxB, codecId, nullptr) >= 0 && ctxB) {
                ctxB->trace_enable = 1;
                ctxB->trace_read_callback = &RBSyntaxAnalyzer::collectReadCb;
                ctxB->trace_context = &collector;
                for (const auto& ps : paramSets) {
                    const QString label = parameterSetLabel(codecIdx, ps.first);
                    if (label.isEmpty()) continue;
                    collector.currentSet = label;
                    AVPacket* pkt = av_packet_alloc();
                    pkt->data = reinterpret_cast<uint8_t*>(const_cast<char*>(ps.second.constData()));
                    pkt->size = int(ps.second.size());
                    CodedBitstreamFragment frag2;
                    memset(&frag2, 0, sizeof(frag2));
                    if (ff_cbs_read_packet(ctxB, &frag2, pkt) >= 0) {
                        extradataOk = extradataOk || entries.size() > 0;
                    }
                    ff_cbs_fragment_free(&frag2);
                    av_packet_free(&pkt);
                }
                ff_cbs_close(&ctxB);
            }
        }

        par->extradata = nullptr;   // 防止 alloc 的 par 析构释放外部 buffer
        par->extradata_size = 0;
        avcodec_parameters_free(&par);
    }

    // 3) 数据源 B：裸 AnnexB 文件（.h264/.265/.266）
    //    extradata 失败或为空时启用；扫描前 8MB 收集参数集 NAL
    if (!extradataOk && !annexbPath.isEmpty()) {
        QFile f(annexbPath);
        if (f.open(QIODevice::ReadOnly)) {
            static constexpr int64_t kMaxScan = 8LL * 1024 * 1024;
            const QByteArray blob = f.read(kMaxScan);
            f.close();
            const uint8_t* data = reinterpret_cast<const uint8_t*>(blob.constData());
            const int64_t size = blob.size();

            // 扫描参数集 NAL（findParameterSetNals 返回含起始码的 [off, len)）
            auto nals = findParameterSetNals(data, size, codecIdx);
            // 按 NAL 类型去重：GOP 头会重复发 SPS/PPS/APS（8MB 内可达数百份），
            // 每类只解析首个（同一文件内参数集内容一致，VQ Analyzer 同样只显示一份）
            bool typeSeen[32] = { false };
            for (const auto& nal : nals) {
                const int64_t scOff = nal.first;
                const int64_t scLen = annexbStartCodeLen(data + scOff, size - scOff);
                const uint8_t* nalData = data + scOff + scLen;
                const int64_t nalDataLen = nal.second - scLen;
                if (nalDataLen < 3) continue;
                int nalType = (codecIdx == 0) ? nalTypeH264(nalData)
                            : (codecIdx == 1) ? nalTypeHevc(nalData)
                                              : nalTypeVvc(nalData);
                QString label = parameterSetLabel(codecIdx, nalType);
                if (label.isEmpty()) continue;
                if (nalType >= 0 && nalType < 32 && typeSeen[nalType]) continue;
                if (nalType >= 0 && nalType < 32) typeSeen[nalType] = true;

                collector.currentSet = label;   // trace 回调据此打组标签
                AVPacket* pkt = av_packet_alloc();
                pkt->data = const_cast<uint8_t*>(data + scOff);
                pkt->size = int(nal.second);
                CodedBitstreamFragment frag;
                memset(&frag, 0, sizeof(frag));
                if (ff_cbs_read_packet(ctx, &frag, pkt) >= 0) {
                    // trace 回调已收集本 NAL 的名值对
                }
                ff_cbs_fragment_free(&frag);
                av_packet_free(&pkt);
            }
        }
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
    if (!data || size <= 0) return out;

    int64_t pos = 0;
    int64_t prevDataStart = -1;
    int64_t prevStartCodeOff = -1;
    while (pos < size) {
        int64_t sc = annexbStartCodeLen(data + pos, size - pos);
        if (sc > 0) {
            if (prevDataStart >= 0) {
                const uint8_t* nal = data + prevDataStart;
                if (size - prevDataStart >= 2) {
                    int nalType = (codec == 0) ? nalTypeH264(nal)
                                : (codec == 1) ? nalTypeHevc(nal)
                                               : nalTypeVvc(nal);
                    if (isParameterSetNal(codec, nalType)) {
                        // 返回 [起始码位置, NAL 总长（含起始码）)
                        out.push_back({prevStartCodeOff, pos - prevStartCodeOff});
                    }
                }
            }
            prevStartCodeOff = pos;
            prevDataStart = pos + sc;
        }
        ++pos;
    }
    if (prevDataStart >= 0 && size - prevDataStart >= 2) {
        const uint8_t* nal = data + prevDataStart;
        int nalType = (codec == 0) ? nalTypeH264(nal)
                    : (codec == 1) ? nalTypeHevc(nal)
                                   : nalTypeVvc(nal);
        if (isParameterSetNal(codec, nalType)) {
            out.push_back({prevStartCodeOff, size - prevStartCodeOff});
        }
    }
    return out;
}

} // namespace rb
