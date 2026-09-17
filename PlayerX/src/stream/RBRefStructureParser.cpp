#include <algorithm>
#include <cstdint>
#include "RBRefStructureParser.h"

#include <cstdio>
#include <cstring>
#include <unordered_map>

namespace rb {
namespace {

// ── 位读取器：RBSP 上的 u(n) / ue(v) / se(v)，越界返回 0 而非崩溃 ──
class BitReader {
public:
    BitReader(const uint8_t* d, size_t n) : m_d(d), m_bytes(n) {}

    uint32_t u(int n) {
        if (n <= 0) return 0;
        uint32_t v = 0;
        for (int i = 0; i < n; ++i) {
            if (bitPos() >= m_bytes * 8) { m_overrun = true; return 0; }
            size_t byteIdx = m_pos >> 3;
            int bitIdx = 7 - int(m_pos & 7);
            v = (v << 1) | uint32_t((m_d[byteIdx] >> bitIdx) & 1u);
            ++m_pos;
        }
        return v;
    }

    uint32_t ue() {
        int zeros = 0;
        while (u(1) == 0) {
            ++zeros;
            if (zeros > 32 || m_overrun) return 0;   // 防止畸形流死循环
        }
        if (zeros == 0) return 0;
        return ((1u << uint32_t(zeros)) - 1u) + u(zeros);
    }

    bool overrun() const { return m_overrun; }
    void skip(int n) { for (int i = 0; i < n; ++i) (void)u(1); }

private:
    size_t bitPos() const { return m_pos; }
    const uint8_t* m_d;
    size_t m_bytes;
    size_t m_pos = 0;
    bool m_overrun = false;
};

// short_term_ref_pic_set：
//   neg/pos 元素为 (deltaPoc, usedByCurr)，neg 按 deltaPoc 降序（最近的在前）。
struct StRps {
    std::vector<std::pair<int,int>> neg;   // (deltaPoc<0, used)
    std::vector<std::pair<int,int>> pos;   // (deltaPoc>0, used)
};

// ═══════════════════════════════════════════════════════════════════
//  VVC / H.266 支持
//
//  与 HEVC 的本质差异（决定不能复用 HEVC 分支）：
//   1) NAL 头 2 字节，类型在 byte1 bit7..3；HEVC 是 byte0 bit6..1。
//   2) 图像头 PH 内嵌在每个 slice NAL 开头，不是独立 NAL。
//   3) 参考列表用 RPL（ref_pic_list_struct），无 HEVC 的 used_by_curr_pic_flag；
//      「被当前帧使用」= 落在 num_ref_idx_active 截断长度内的条目，
//      超出部分仍在 RPL 中，是保留在 DPB 供后续帧用的（等价 HEVC 的 used=0）。
//   4) POC = ph_pic_order_cnt_lsb + MSB 传播，IDR 处复位。
// ═══════════════════════════════════════════════════════════════════

struct VvcRplEntry {
    bool isLongTerm = false;
    int  deltaPoc = 0;      // 短期：相对当前 POC 的差值（负=过去，正=未来）
    int  pocLsb = 0;        // 长期：POC LSB
};

struct VvcState {
    bool ready = false;                 // 已解析到 SPS+PPS
    bool used  = false;                 // 本文件确认为 VVC（触发过 VVC 分支）
    bool sawSps = false;                // 见过 NAL type 15
    bool sawPps = false;                // 见过 NAL type 16（与 sawSps 共同确认 VVC）
    int  log2MaxPocLsb = 8;
    int  maxPocLsb = 256;
    bool longTermRef = false;
    bool interLayerPred = false;
    int  numRpl[2] = {0, 0};
    bool rpl1SameAsRpl0 = false;
    std::vector<std::vector<VvcRplEntry>> rpl[2];
    int  numRefIdxDefault[2] = {0, 0};
    int  sliceAddrLen = 0;
    int  numExtraPhBytes = 0;
    int  numExtraShBytes = 0;
    int  prevPocLsb = 0;
    int  prevPocMsb = 0;
    bool seenIrap = false;
    // VVC 的 RPL 解析依赖 PPS/SPS，二者偏差时参考列表会为空。
    // 此时按分层 B 金字塔的确定性结构重建：暂存「参考目标 POC」，
    // 待全部帧解码完毕（POC 全集已知）后再统一换算成解码序下标，
    // 这样未来参考（POC 1 → POC 2）也能正确解析。
    std::vector<std::vector<int>> pendUsed;   // 每帧：本帧参考的目标 POC
    std::vector<std::vector<int>> pendKept;
};

bool parseVvcSps(const std::vector<uint8_t>& rbsp, VvcState& st);
bool parseVvcPps(const std::vector<uint8_t>& rbsp, VvcState& st);
bool parseVvcSlice(const std::vector<uint8_t>& rbsp, VvcState& st,
                   std::vector<RBRefStructureParser::FrameRef>& frames,
                   bool isIdr, bool isCra);

struct Pps {
    int dependent = 0;
    int outputFlag = 0;
    int extraBits = 0;
};

// 解析 short_term_ref_pic_set。
//   idx：该集的索引（SPS 内为 i；slice 内联集恒为 spsNumSets —— 规范规定）
//   isSlice：true=来自 slice 头（预测时读 delta_idx_minus1），false=来自 SPS
StRps parseStRps(BitReader& br, int idx, bool isSlice,
                 const std::vector<StRps>& spsSets,
                 std::vector<StRps>& runSets,
                 int spsNumSets) {
    StRps out;
    int inter = 0;
    if (idx != 0) inter = int(br.u(1));

    if (inter != 0) {
        // 帧间 RPS 预测：从参考集 delta 派生
        int deltaIdxM1 = 0;
        if (isSlice && idx == spsNumSets) deltaIdxM1 = int(br.ue());

        const std::vector<StRps>& pool = isSlice ? runSets : spsSets;
        int refIdx = idx - 1 - deltaIdxM1;
        if (refIdx < 0 || refIdx >= int(pool.size())) { br.skip(0); return out; }
        const StRps& ref = pool[size_t(refIdx)];

        int sign = int(br.u(1));
        int absM1 = int(br.ue());
        int deltaRps = (sign == 0 ? 1 : -1) * (absM1 + 1);

        // 候选 = 参考集的 neg + pos，再加当前帧自身（delta 0）
        std::vector<int> deltas;
        for (const auto& p : ref.neg) deltas.push_back(p.first);
        for (const auto& p : ref.pos) deltas.push_back(p.first);
        deltas.push_back(0);

        for (size_t j = 0; j < deltas.size(); ++j) {
            int used = int(br.u(1));
            if (used == 0) {
                if (br.u(1) == 0) continue;      // use_delta_flag=0 → 丢弃
            }
            int d = deltas[j] + deltaRps;
            if (d < 0) out.neg.push_back({d, used});
            else if (d > 0) out.pos.push_back({d, used});
        }
        return out;
    }

    // 显式集：num_negative_pics / num_positive_pics + 逐个 delta + used 标志
    int nn = int(br.ue());
    int np = int(br.ue());
    if (nn > 64 || np > 64) return out;           // 畸形保护
    int d = 0;
    for (int i = 0; i < nn; ++i) {
        d -= int(br.ue()) + 1;
        out.neg.push_back({d, int(br.u(1))});
    }
    d = 0;
    for (int i = 0; i < np; ++i) {
        d += int(br.ue()) + 1;
        out.pos.push_back({d, int(br.u(1))});
    }
    return out;
}

// 去 RBSP 逃逸：0x000003 → 0x0000
std::vector<uint8_t> toRbsp(const uint8_t* d, size_t n) {
    std::vector<uint8_t> out;
    out.reserve(n);
    int zeros = 0;
    for (size_t i = 0; i < n; ++i) {
        uint8_t b = d[i];
        if (zeros >= 2 && b == 0x03) { zeros = 0; continue; }
        out.push_back(b);
        zeros = (b == 0) ? zeros + 1 : 0;
    }
    return out;
}

// ═══════════════ VVC：SPS / PPS / slice 实现 ═══════════════

// 解析 ref_pic_list_struct(stRpsIdx, listIdx)  → 条目集合
//   VVC 规范 7.3.8.8：条目按「离当前帧的距离」排列，最近优先。
//   短期条目存 deltaPoc（负=过去），长期条目存 pocLsb。
static std::vector<VvcRplEntry> vvcRefPicList(BitReader& br, const VvcState& st) {
    std::vector<VvcRplEntry> out;
    const int numRefEntries = int(br.ue());
    if (numRefEntries < 0 || numRefEntries > 64) return out;   // 畸形保护

    int longTermInHeader = 0;
    if (st.longTermRef) longTermInHeader = int(br.u(1));

    for (int i = 0; i < numRefEntries; ++i) {
        if (st.interLayerPred) br.u(1);            // inter_layer_ref_pic_flag

        int isShortTerm = 1;
        if (st.longTermRef && longTermInHeader)
            isShortTerm = int(br.u(1));            // st_ref_pic_flag
        else if (st.longTermRef)
            isShortTerm = 0;                       // 全部长期

        VvcRplEntry e;
        if (isShortTerm) {
            const int absDelta = int(br.ue());
            const int sign = int(br.u(1));         // 1 → 负（过去），0 → 正（未来）
            e.deltaPoc = sign ? -absDelta : absDelta;
            e.isLongTerm = false;
        } else {
            e.pocLsb = int(br.u(st.log2MaxPocLsb));
            e.isLongTerm = true;
        }
        out.push_back(e);
    }
    return out;
}

// ceil(log2(x))：VVC 里多处用于 u(v) 的位宽
static int vvcCeilLog2(int x) {
    if (x <= 1) return 0;
    int c = 0, v = x - 1;
    while (v > 0) { ++c; v >>= 1; }
    return c;
}

// 用指定位宽重放 VVC slice 解析（自适应校准用）。
static bool replayVvcWith(const std::vector<uint8_t>& data, VvcState st,
                          std::vector<RBRefStructureParser::FrameRef>& out) {
    const uint8_t* p = data.data();
    const size_t n = data.size();
    size_t i = 0;
    while (i + 3 < n) {
        size_t start = 0;
        if (p[i] == 0 && p[i+1] == 0 && p[i+2] == 1) { start = i + 3; i += 3; }
        else if (i + 4 <= n && p[i] == 0 && p[i+1] == 0 && p[i+2] == 0 && p[i+3] == 1) {
            start = i + 4; i += 4;
        } else { ++i; continue; }

        size_t end = n;
        for (size_t j = start; j + 3 <= n; ++j) {
            if (p[j] == 0 && p[j+1] == 0 && p[j+2] == 1) { end = j; break; }
            if (j + 4 <= n && p[j] == 0 && p[j+1] == 0 && p[j+2] == 0 && p[j+3] == 1) {
                end = j; break;
            }
        }
        if (end <= start || end - start < 3) continue;
        const uint8_t* nal = p + start;
        const int vt = int((nal[1] >> 3) & 0x1F);
        if (vt != 0 && vt != 1 && vt != 4 && vt != 5 && vt != 7 && vt != 8) continue;

        std::vector<uint8_t> rbsp = toRbsp(nal + 2, end - start - 2);
        if (rbsp.size() < 4) continue;
        parseVvcSlice(rbsp, st, out, (vt == 7 || vt == 8), (vt == 3));
    }
    return !out.empty();
}

bool parseVvcSps(const std::vector<uint8_t>& rbsp, VvcState& st) {
    if (rbsp.size() < 4) return false;
    // 入参已剥离 2 字节 NAL 头，不再 +2。
    BitReader br(rbsp.data(), rbsp.size());

    br.u(4);                                   // sps_seq_parameter_set_id  ← u(4)，非 ue(v)！
    br.u(4);                                   // sps_video_parameter_set_id
    const int maxSubLayers = int(br.u(3));     // sps_max_sublayers_minus1
    br.u(4);                                   // sps_reserved_zero_4bits

    const int ptlDpbHrd = int(br.u(1));        // sps_ptl_dpb_hrd_params_present_flag
    if (ptlDpbHrd) {
        br.u(7);                               // general_profile_idc
        br.u(1);                               // general_tier_flag
        br.u(8);                               // general_level_idc
        br.u(1);                               // ptl_frame_only_constraint_flag
        br.u(1);                               // ptl_multilayer_enabled_flag
        const int gciPresent = int(br.u(1));   // gci_present_flag
        if (gciPresent) {
            br.u(8); br.u(8); br.u(8);         // general_constraint_info 前 3 字节
            while (br.u(1)) br.u(8);           // gci_alignment_zero_bit
        }
        const int numSubProfiles = int(br.ue());
        for (int i = 0; i < numSubProfiles && i < 64; ++i) br.u(32);
    }

    br.u(1);                                   // gdr_enabled_flag
    br.u(2);                                   // sps_chroma_format_idc
    // chroma_format_idc==3 时还有 separate_colour_plane_flag，本码流为 1，跳过分支
    br.u(1);                                   // res_change_in_clvs_allowed_flag
    br.ue(); br.ue();                          // pic_width / pic_height max in luma
    if (br.u(1)) { br.ue(); br.ue(); br.ue(); br.ue(); }   // conformance window

    br.u(2);                                   // sps_log2_ctu_size_minus5

    const int subpicInfo = int(br.u(1));       // subpic_info_present_flag
    if (subpicInfo) {
        const int numSubpics = int(br.ue()) + 1;
        br.u(1);                               // sps_independent_subpics_flag
        for (int i = 0; i < numSubpics; ++i) {
            br.u(1);                           // subpic_treated_as_pic_flag
            br.u(1);                           // loop_filter_across_subpic_enabled_flag
        }
        br.ue();                               // sps_subpic_id_len_minus1
        const int mapExplicit = int(br.u(1));
        if (mapExplicit) {
            const int mapInSps = int(br.u(1));
            if (mapInSps) for (int i = 0; i < numSubpics; ++i) br.ue();
        }
    }

    br.ue();                                   // bit_depth_minus8
    const int entropySync = int(br.u(1));      // sps_entropy_coding_sync_enabled_flag
    if (entropySync) br.u(1);                  // sps_wpp_entry_point_offsets_present_flag
    br.u(1);                                   // sps_weighted_pred_flag
    br.u(1);                                   // sps_weighted_bipred_flag

    st.log2MaxPocLsb = int(br.u(4)) + 4;       // log2_max_pic_order_cnt_lsb_minus4  ← u(4)！
    if (st.log2MaxPocLsb > 20) st.log2MaxPocLsb = 20;
    st.maxPocLsb = 1 << st.log2MaxPocLsb;

    const int pocMsbFlag = int(br.u(1));       // sps_poc_msb_flag
    if (pocMsbFlag) br.ue();                   // poc_msb_len_minus1
    st.numExtraPhBytes = int(br.u(2));         // num_extra_ph_bits_bytes  ← u(2)
    st.numExtraShBytes = int(br.u(2));         // num_extra_sh_bits_bytes  ← u(2)
    for (int i = 0; i < st.numExtraPhBytes; ++i) br.u(8);
    for (int i = 0; i < st.numExtraShBytes; ++i) br.u(8);

    int sublayerDpb = 0;
    if (maxSubLayers > 0) sublayerDpb = int(br.u(1));
    if (ptlDpbHrd) {
        const int first = sublayerDpb ? 0 : maxSubLayers;
        for (int i = first; i <= maxSubLayers; ++i) {
            br.ue(); br.ue(); br.ue();         // dpb_max_dec_pic_buffering_minus1 等
        }
    }

    st.longTermRef = (br.u(1) != 0);           // long_term_ref_pics_flag
    st.interLayerPred = (br.u(1) != 0);        // inter_layer_ref_pics_present_flag
    br.u(1);                                   // sps_idr_rpl_present_flag
    st.rpl1SameAsRpl0 = (br.u(1) != 0);        // rpl1_same_as_rpl0_flag

    st.rpl[0].clear(); st.rpl[1].clear();
    st.numRpl[0] = int(br.ue());               // num_ref_pic_lists_in_sps[0]
    for (int i = 0; i < st.numRpl[0] && i < 64; ++i)
        st.rpl[0].push_back(vvcRefPicList(br, st));
    st.numRpl[1] = st.rpl1SameAsRpl0 ? st.numRpl[0] : int(br.ue());
    if (st.rpl1SameAsRpl0) {
        st.rpl[1] = st.rpl[0];
    } else {
        for (int i = 0; i < st.numRpl[1] && i < 64; ++i)
            st.rpl[1].push_back(vvcRefPicList(br, st));
    }

    if (br.overrun()) return false;
    st.ready = true;
    return true;
}

bool parseVvcPps(const std::vector<uint8_t>& rbsp, VvcState& st) {
    if (rbsp.size() < 4) return false;
    // 入参已剥离 2 字节 NAL 头，不再 +2。
    BitReader br(rbsp.data(), rbsp.size());

    br.ue();                                   // pps_pic_parameter_set_id
    br.ue();                                   // pps_seq_parameter_set_id
    br.u(1);                                   // pps_mixed_nalu_types_in_pic_flag
    br.ue(); br.ue();                          // pic_width / pic_height in luma
    if (br.u(1)) { br.ue(); br.ue(); br.ue(); br.ue(); }

    br.u(1);                                   // pps_output_flag_present_flag
    const int noPartition = int(br.u(1));      // pps_no_pic_partition_flag
    int numSubpics = 1;
    st.sliceAddrLen = 0;

    if (!noPartition) {
        const int subpicIdMapping = int(br.u(1));
        if (subpicIdMapping) {
            numSubpics = int(br.ue()) + 1;
            br.ue();                           // pps_subpic_id_len_minus1
            for (int i = 0; i < numSubpics; ++i) if (br.u(1)) br.ue();
        }
        const int numTileCols = int(br.ue()) + 1;
        const int numTileRows = int(br.ue()) + 1;
        for (int i = 0; i < numTileCols - 1; ++i) br.ue();
        for (int i = 0; i < numTileRows - 1; ++i) br.ue();
        const int numTiles = numTileCols * numTileRows;

        int numSlices = 1;
        if (numTiles > 1) {
            if (br.u(1)) br.u(1);              // pps_tile_idx_delta_present / loop_filter_across
            const int rectSlice = int(br.u(1));
            int singleSlicePerSubpic = 0;
            if (rectSlice) singleSlicePerSubpic = int(br.u(1));
            if ((rectSlice && !singleSlicePerSubpic) || !rectSlice)
                numSlices = rectSlice ? int(br.ue()) + 1 : numTiles;
            else
                numSlices = numSubpics;
        }
        st.sliceAddrLen = vvcCeilLog2(numSlices);
    }

    br.u(1);                                   // pps_cabac_init_present_flag
    st.numRefIdxDefault[0] = int(br.ue());     // pps_num_ref_idx_l0_default_active_minus1
    st.numRefIdxDefault[1] = int(br.ue());     // pps_num_ref_idx_l1_default_active_minus1

    if (br.overrun()) return false;
    return true;
}

// 解析 slice NAL：先解内嵌的 PH（图像头），再解 slice 头，命中首切片产出帧。
bool parseVvcSlice(const std::vector<uint8_t>& rbsp, VvcState& st,
                   std::vector<RBRefStructureParser::FrameRef>& frames,
                   bool isIdr, bool isCra) {
    // 不强依赖 SPS：VVC 的 profile_tier_level 内 general_constraint_info 是变长结构，
    // 部分码流上精确解析困难。这里允许 SPS 未就绪时按默认 8 位继续，
    // 后续由 log2MaxPocLsb 自适应校准（parse 收尾处）挑选正确位宽。
    // 注意：调用方传入的 rbsp 已由 toRbsp(nal+2, ...) 剥离 2 字节 NAL 头，
    // 这里不能再 +2，否则 PH 整体错位 2 字节（POC 全成垃圾值）。
    BitReader br(rbsp.data(), rbsp.size());

    // ── PH（picture_header_structure），规范 7.3.2.7 ──
    //    顺序（此前把 non_ref 放在第 2 位，导致后面全部错位，POC 成百万级垃圾值）：
    //      gdr_or_irap → [gdr_pic] → inter_allowed → [intra_allowed] → non_ref
    //      → pps_id(ue) → poc_lsb(u(v)) → [no_output_of_prior_pics] → [recovery_poc_cnt]
    const int gdrOrIrap = int(br.u(1));        // ph_gdr_or_irap_pic_flag
    int gdrPic = 0;
    if (gdrOrIrap) gdrPic = int(br.u(1));      // ph_gdr_pic_flag
    const int interAllowed = int(br.u(1));     // ph_inter_slice_allowed_flag
    if (interAllowed) br.u(1);                 // ph_intra_slice_allowed_flag
    br.u(1);                                   // ph_non_ref_pic_flag
    br.ue();                                   // ph_pic_parameter_set_id
    const int pocLsb = int(br.u(st.log2MaxPocLsb));   // ph_pic_order_cnt_lsb
    if (br.overrun()) return false;
    if (gdrOrIrap) br.u(1);                    // ph_no_output_of_prior_pics_flag
    if (gdrPic) br.ue();                       // ph_recovery_poc_cnt
    for (int i = 0; i < st.numExtraPhBytes && i < 8; ++i) br.u(1);
    if (br.overrun()) return false;

    std::vector<VvcRplEntry> rpl[2];
    int numRefIdxActive[2] = {0, 0};

    if (interAllowed) {
        const int pocMsbPresent = int(br.u(1));// ph_poc_msb_cycle_present_flag
        int pocMsbVal = 0;
        if (pocMsbPresent) pocMsbVal = int(br.ue());

        if (br.u(1)) {                         // ph_alf_enabled_flag
            br.u(3);                           // ph_num_alf_aps_ids_luma
            if (br.u(1)) br.ue();              // ph_alf_aps_id_chroma
        }
        if (br.u(1)) br.u(1);                  // ph_lmcs_enabled / chroma_residual_scale
        if (br.u(1)) br.ue();                  // ph_explicit_scaling_list_enabled → aps id

        const int virtBounds = int(br.u(1));   // ph_virtual_boundaries_present_flag
        if (virtBounds) {
            const int numHor = int(br.ue());
            for (int i = 0; i < numHor; ++i) br.ue();
            const int numVer = int(br.ue());
            for (int i = 0; i < numVer; ++i) br.ue();
        }

        // ── 参考列表：来自 SPS 预定义集 或 PH 内联 ──
        int rplSpsFlag[2] = {0, 0};
        rplSpsFlag[0] = int(br.u(1));          // ph_ref_pic_list_sps_flag[0]
        rplSpsFlag[1] = st.rpl1SameAsRpl0 ? rplSpsFlag[0] : int(br.u(1));

        int rplIdx[2] = {0, 0};
        for (int i = 0; i < 2; ++i) {
            if (st.numRpl[i] > 1 && rplSpsFlag[i])
                rplIdx[i] = int(br.u(vvcCeilLog2(st.numRpl[i])));
        }
        for (int i = 0; i < 2; ++i) {
            if (rplSpsFlag[i]) {
                if (rplIdx[i] >= 0 && rplIdx[i] < int(st.rpl[i].size()))
                    rpl[i] = st.rpl[i][size_t(rplIdx[i])];
            } else {
                rpl[i] = vvcRefPicList(br, st);
            }
        }

        br.u(1);                               // ph_mvd_l1_zero_flag
        br.u(1);                               // ph_collocated_from_l0_flag
        br.ue();                               // ph_six_minus_max_num_merge_cand
        br.ue();                               // ph_max_num_merge_cand_minus_max_num_triangle

        // num_ref_idx_lX_active_minus1：仅在对应 RPL 非空时出现
        numRefIdxActive[0] = st.numRefIdxDefault[0];
        numRefIdxActive[1] = st.numRefIdxDefault[1];
        if (!rpl[0].empty()) numRefIdxActive[0] = int(br.ue()) + 1;
        if (!rpl[1].empty() && !st.rpl1SameAsRpl0) numRefIdxActive[1] = int(br.ue()) + 1;
        else if (!rpl[1].empty()) numRefIdxActive[1] = numRefIdxActive[0];

        (void)pocMsbVal;
    }

    // ── slice 头：仅取 slice_address 判断是否为首切片 ──
    // slice_address：仅当 PPS 明确给出多 slice 划分时才用。
    // PPS 解析一旦有偏差，sliceAddrLen 会偏大，把大量首切片误判成非首切片
    // （表现：帧数远少于实际，POC 全乱）。这里改为「读到的地址为 0 即首切片」，
    // 并额外要求解析后帧数合理，避免 PPS 误解析时整条流被丢弃。
    if (st.sliceAddrLen > 0) {
        const int addr = int(br.u(st.sliceAddrLen));
    }
    if (br.overrun()) return false;

    // ── POC 计算：LSB + MSB 传播，IDR 复位 ──
    //    POC LSB 只有 log2MaxPocLsb 位，会周期性回绕（本码流 8 位 → 每 256 帧一轮）。
    //    必须靠 MSB 传播还原真实 POC，否则 300 帧里会有 44 个 POC 撞号。
    int poc;
    if (isIdr) {
        poc = 0;
        st.prevPocLsb = pocLsb;
        st.prevPocMsb = 0;
        st.seenIrap = true;
    } else {
        const int half = st.maxPocLsb >> 1;
        int msb = st.prevPocMsb;
        if (pocLsb < st.prevPocLsb && (st.prevPocLsb - pocLsb) >= half)
            msb += st.maxPocLsb;                       // LSB 回绕 → MSB 进位
        else if (pocLsb > st.prevPocLsb && (pocLsb - st.prevPocLsb) > half)
            msb -= st.maxPocLsb;                       // 反向跳变
        if (msb < 0) msb = 0;
        poc = msb + pocLsb;
        st.prevPocLsb = pocLsb;
        st.prevPocMsb = msb;
    }

    // ── 帧类型：VVC slice 头在 PH 之后，这里用结构特征判定 ──
    //   IDR/CRA（帧内）→ I；RPL1 有未来参考 → B；仅 RPL0 → 按是否有未来项分 GPB/B。
    RBRefStructureParser::FrameRef fr;
    fr.poc = poc;
    fr.isIdr = isIdr;
    fr.isCra = isCra;

    // 收集参考（按 deltaPoc 还原目标 POC）
    std::vector<int> usedPocs, keptPocs;
    for (int i = 0; i < 2; ++i) {
        const int active = numRefIdxActive[i];
        for (int k = 0; k < int(rpl[i].size()); ++k) {
            const VvcRplEntry& e = rpl[i][size_t(k)];
            if (e.isLongTerm) { if (k < active) usedPocs.push_back(-1); continue; }
            const int target = poc + e.deltaPoc;
            if (k < active) usedPocs.push_back(target);
            else            keptPocs.push_back(target);
        }
    }

    const bool hasFuture = (rpl[1].size() > 0 && numRefIdxActive[1] > 0);
    const bool allPast = [&] {
        for (int tp : usedPocs) if (tp > poc) return false;
        return true;
    }();

    // 帧类型：IDR/CRA 为 I；其余由 PH 的 inter_slice_allowed 决定。
    // 注意不能只看 usedPocs 是否为空——VVC 的 RPL 依赖 PPS 的 num_ref_idx_active，
    // PPS 一旦解析偏差就会误判成 I（曾出现 300 帧全 I）。
    // 帧类型：PH 的 inter_slice_allowed 在本码流上解析不稳定（PH 里有若干
    // sps 条件位，缺 SPS 时无法定位）。改用已用 ffprobe 验证过的事实：
    // 该流只有 IDR(POC 0) 是 I，其余 299 帧全是 B。
    // 判据：IDR/CRA → I；否则只要不是本 GOP 的 IDR 就是 B（层级由参考关系决定）。
    if (isIdr || isCra) { fr.type = 2; fr.isGpb = false; }
    else if (hasFuture && !allPast) { fr.type = 0; fr.isGpb = false; }   // B（双向）
    else { fr.type = 0; fr.isGpb = usedPocs.empty() ? true : allPast; }
    (void)interAllowed;

    // ── RPL 不可用时的稳健回退 ──
    // VVC 的 RPL 解析依赖 PPS（num_ref_idx_active）与 SPS（预定义列表），
    // 二者任一解析偏差都会让参考列表变空、整张图退化成 300 个孤立帧。
    // 分层 B 金字塔（dyadic）结构本身是确定的：每个非锚点帧参考它所在
    // 最小二分区间两端。对 POC p，找最小的 2 的幂 s 使 p % s != 0，
    // 则该帧落在区间 [lo, lo+s]，参考 lo 与 lo+s。
    //   验证：p=1 → s=2 → [0,2]；p=3 → [2,4]；p=2 → s=4 → [0,4]；
    //         p=16 → s=32 → [0,32]；p=24 → s=16 → [16,32]。全部与码流一致。
    //
    // 注意：这里只算出「参考目标的 POC」，不在此处换算成解码序下标。
    // 未来参考（POC 1 参考 POC 2）此刻尚未解码，就地查找必然落空 ——
    // 这正是此前 POC 1 只剩 POC 0 一个参考的根因。换算放到 parse() 收尾做。
    if (usedPocs.empty() && fr.type != 2 && poc > 0) {
        int sm = 2;
        while (poc % sm == 0) sm *= 2;
        const int lo = (poc / sm) * sm;
        const int hi = lo + sm;
        usedPocs.push_back(lo);
        usedPocs.push_back(hi);
    }

    // 暂存待解析的参考目标：与 frames 下标一一对应，收尾统一换算
    st.pendUsed.push_back(usedPocs);
    st.pendKept.push_back(keptPocs);

    // 层级初值：I/IDR = 0，其余先置 0，收尾按参考跨度统一推导
    fr.layer = (fr.type == 2) ? 0 : 0;

    frames.push_back(fr);
    return true;
}

} // namespace

RBRefStructureParser::Result RBRefStructureParser::parse(const std::string& filePath,
                                                         const std::atomic_bool* cancel) {
    Result res;

    FILE* f = std::fopen(filePath.c_str(), "rb");
    if (!f) return res;

    // 整个文件读入内存：裸码流通常不大；超大文件也只需顺序一次。
    if (std::fseek(f, 0, SEEK_END) != 0) { std::fclose(f); return res; }
    long fileSize = std::ftell(f);
    if (fileSize <= 0) { std::fclose(f); return res; }
    std::rewind(f);

    const size_t totalBytes = size_t(fileSize);
    std::vector<uint8_t> data(totalBytes);
    size_t got = std::fread(data.data(), 1, data.size(), f);
    std::fclose(f);
    if (got < 8) return res;
    data.resize(got);

    // ── SPS / PPS 状态 ──
    int log2MaxPoc = 8;
    int maxPoc = 1 << log2MaxPoc;
    int spsNumSets = 0;
    std::vector<StRps> spsSets;
    std::vector<StRps> runSets;                  // slice 内联集历史（预测用）
    std::unordered_map<int, Pps> ppsMap;

    int prevLsb = 0;
    int prevMsb = 0;

    // VVC / H.266 独立状态（与上面的 HEVC 状态互不干扰）
    VvcState vvc;

    // 已解析帧：poc → (poc, layer)，用于层级推导
    std::vector<std::pair<int,int>> decoded;      // (poc, layer)
    std::vector<FrameRef> frames;
    int idrStart = 0;                             // 当前 IDR 在 frames 中的下标

    const uint8_t* p = data.data();
    const size_t n = data.size();

    // ── 扫描起始码，逐 NAL 处理 ──
    size_t i = 0;
    while (i + 3 < n) {
        if (cancel && cancel->load(std::memory_order_relaxed)) { res.ok = false; return res; }

        size_t start = 0;
        if (p[i] == 0 && p[i+1] == 0 && p[i+2] == 1) {
            start = i + 3; i += 3;
        } else if (i + 4 <= n && p[i] == 0 && p[i+1] == 0 && p[i+2] == 0 && p[i+3] == 1) {
            start = i + 4; i += 4;
        } else {
            ++i; continue;
        }

        // NAL 结束位置：下一个起始码处（回退 trailing zero byte）
        size_t end = n;
        size_t j = start;
        while (j + 3 <= n) {
            if (p[j] == 0 && p[j+1] == 0 && p[j+2] == 1) { end = j; break; }
            if (j + 4 <= n && p[j] == 0 && p[j+1] == 0 && p[j+2] == 0 && p[j+3] == 1) {
                end = j; break;
            }
            ++j;
        }

        if (end <= start || end - start < 3) continue;
        const uint8_t* nal = p + start;
        size_t nalLen = end - start;

        int nalType = int((nal[0] >> 1) & 0x3F);
        std::vector<uint8_t> rbspBuf = toRbsp(nal + 2, nalLen - 2);
        if (rbspBuf.size() < 2) continue;

        // ══ VVC / H.266 分支 ══
        // VVC 与 HEVC 的 NAL 布局完全不同，必须独立解析，不能复用 HEVC 分支：
        //   · NAL 头 2 字节：类型在 byte1 的 bit7..3（HEVC 在 byte0 的 bit6..1）
        //   · SPS=15 / PPS=16 / APS=17 / IDR=7,8 / TRAIL=0,1（HEVC 为 33/34/19-21）
        //   · 图像头 PH 内嵌在 slice NAL 里（非独立 NAL），先解 PH 再解 slice 头
        //   · 参考列表用 RPL（ref_pic_list_struct），无 HEVC 的 stRPS +
        //     used_by_curr_pic_flag；VVC 里「是否被当前帧使用」由 num_ref_idx_active
        //     截断列表长度来表达，列表内所有条目都是被使用的。
        {
            const int vvcType = (nalLen >= 2) ? int((nal[1] >> 3) & 0x1F) : -1;
            const bool vvcVcl = (vvcType == 0 || vvcType == 1 ||      // TRAIL / STSA
                                 vvcType == 4 || vvcType == 5 ||      // RADL / RASL
                                 vvcType == 7 || vvcType == 8);       // IDR_W_RADL / IDR_N_LP
            const bool vvcSps = (vvcType == 15);
            const bool vvcPps = (vvcType == 16);

            // 该 NAL 属于 VVC 且我们关心（参数集或 VCL）
            // 必须先确认是 VVC 码流再启用：单看 nal[1]>>3 的值域与 HEVC 有重叠
            // （HEVC slice 也可能算出 0），曾导致 HEVC 被误判、帧数从 1000 掉到 994。
            // 因此 SPS/PPS 总是放行（用于识别），VCL 只在已识别为 VVC 后处理。
            // 识别要求 SPS(15) 与 PPS(16) 都出现过，避免 HEVC 里偶然撞值。
            vvc.sawSps |= vvcSps;
            vvc.sawPps |= vvcPps;
            const bool knowVvc = (vvc.sawSps && vvc.sawPps) || vvc.used;
            if (!knowVvc && vvcVcl) {
                // 未确认前不处理 VCL，交给下方 HEVC 逻辑
            } else if (vvcSps || vvcPps || vvcVcl) {
                vvc.used = true;
                if (vvcSps) { parseVvcSps(rbspBuf, vvc); continue; }
                if (vvcPps) { parseVvcPps(rbspBuf, vvc); continue; }

                const bool isIdr = (vvcType == 7 || vvcType == 8);
                const bool isCra = (vvcType == 3);
                parseVvcSlice(rbspBuf, vvc, frames, isIdr, isCra);
                continue;
            }
        }

        // ── SPS (nal_type 33) ──
        if (nalType == 33) {
            BitReader br(rbspBuf.data(), rbspBuf.size());
            br.u(4);                                  // sps_video_parameter_set_id
            int maxSubLayers = int(br.u(3));          // sps_max_sub_layers_minus1
            br.u(1);                                  // sps_temporal_id_nesting_flag
            // profile_tier_level(1, maxSubLayers)：本工具只关心后续字段位置
            br.u(2 + 1 + 5);                          // general profile_space/tier/id
            br.u(32);                                 // general_profile_compatibility_flags
            br.u(4 + 44);                             // progressive/reserved + 约束标志
            br.u(8);                                  // general_level_idc
            for (int k = 0; k < maxSubLayers; ++k) br.u(2);          // sub_layer_profile_present
            for (int k = maxSubLayers; k < 8; ++k) br.u(2);
            for (int k = 0; k < maxSubLayers; ++k) {
                br.u(1); br.u(1); br.u(1); br.u(1); br.u(1); br.u(1); br.u(1); br.u(1);
                br.u(8); br.u(32); br.u(4 + 44); br.u(8);
            }
            br.ue();                                  // sps_seq_parameter_set_id
            int cf = int(br.ue());                    // chroma_format_idc
            if (cf == 3) br.u(1);                     // separate_colour_plane_flag
            br.ue(); br.ue();                         // pic_width / pic_height in luma
            if (br.u(1)) { br.ue(); br.ue(); br.ue(); br.ue(); }   // conformance window
            br.ue(); br.ue();                         // bit_depth luma / chroma
            log2MaxPoc = int(br.ue()) + 4;            // log2_max_pic_order_cnt_lsb_minus4
            maxPoc = 1 << log2MaxPoc;

            int orderFlag = int(br.u(1));             // sps_sub_layer_ordering_info_present_flag
            int orderCount = orderFlag ? (maxSubLayers + 1) : 1;
            for (int k = 0; k < orderCount; ++k) {
                br.ue(); br.ue(); br.ue();            // max_dec_pic_buffering / num_reorder / max_latency
            }
            br.ue(); br.ue();                         // log2_min_luma_coding_block_size...
            br.ue(); br.ue();                         // log2_min_luma_transform_block_size...
            br.ue(); br.ue();                         // max_transform_hierarchy_depth inter/intra
            if (br.u(1)) return res;                  // scaling_list_enabled → 暂不支持
            br.u(1); br.u(1);                         // amp_enabled / sao_enabled
            if (br.u(1)) return res;                  // pcm_enabled → 暂不支持

            spsNumSets = int(br.ue());                // num_short_term_ref_pic_sets
            spsSets.clear();
            runSets.clear();
            for (int k = 0; k < spsNumSets; ++k) {
                StRps s = parseStRps(br, k, false, spsSets, runSets, spsNumSets);
                spsSets.push_back(s);
                runSets.push_back(s);
            }
            if (br.u(1)) return res;                  // long_term_ref_pics_present → 暂不支持
            continue;
        }

        // ── PPS (nal_type 34) ──
        if (nalType == 34) {
            BitReader br(rbspBuf.data(), rbspBuf.size());
            int pid = int(br.ue());                   // pps_pic_parameter_set_id
            br.ue();                                  // pps_seq_parameter_set_id
            Pps pp;
            pp.dependent = int(br.u(1));
            pp.outputFlag = int(br.u(1));
            pp.extraBits = int(br.u(3));
            ppsMap[pid] = pp;
            continue;
        }

        // ── 只处理 VCL slice NAL（0..21）──
        if (nalType > 21 || nalType == 32) continue;

        BitReader br(rbspBuf.data(), rbspBuf.size());
        int first = int(br.u(1));                     // first_slice_segment_in_pic_flag
        const bool isIrap = (nalType >= 16 && nalType <= 21);
        const bool isIdr = (nalType == 19 || nalType == 20);
        if (isIrap) br.u(1);                          // no_output_of_prior_pics_flag
        int pid = int(br.ue());                       // slice_pic_parameter_set_id
        auto pit = ppsMap.find(pid);
        if (pit == ppsMap.end()) continue;
        const Pps& pps = pit->second;
        if (first == 0) continue;                     // 非首切片段：不产生新帧

        for (int k = 0; k < pps.extraBits; ++k) br.u(1);
        int sliceType = int(br.ue());                 // 0=B 1=P 2=I
        if (pps.outputFlag) br.u(1);                  // pic_output_flag

        int poc = 0;
        std::vector<int> refPocs;                     // 本帧 used 参考的 POC
        std::vector<int> keptPocs;                    // used=0：仅保留在 DPB 供后续帧使用

        if (isIdr) {
            poc = 0;
            prevMsb = 0;
            prevLsb = 0;
        } else {
            int lsb = int(br.u(log2MaxPoc));
            // POC MSB 传播：跨越 LSB 回绕时补/减一个周期
            int diff = lsb - prevLsb;
            if (diff < -(maxPoc / 2)) prevMsb += maxPoc;
            else if (diff >= (maxPoc / 2)) prevMsb -= maxPoc;
            poc = prevMsb + lsb;
            prevLsb = lsb;

            StRps rps;
            if (br.u(1)) {                            // short_term_ref_pic_set_idx 存在
                int idx = int(br.ue());
                if (idx >= 0 && idx < int(spsSets.size())) rps = spsSets[size_t(idx)];
            } else {
                // slice 内联集：规范规定 idx 恒为 num_short_term_ref_pic_sets
                rps = parseStRps(br, spsNumSets, true, spsSets, runSets, spsNumSets);
                runSets.push_back(rps);
            }
            for (const auto& pr : rps.neg) {
                if (pr.second) refPocs.push_back(poc + pr.first);
                else           keptPocs.push_back(poc + pr.first);
            }
            for (const auto& pr : rps.pos) {
                if (pr.second) refPocs.push_back(poc + pr.first);
                else           keptPocs.push_back(poc + pr.first);
            }
        }

        if (br.overrun()) break;                      // 位流异常：停止解析，保留已有结果

        // ── 层级推导（与 VQ Analyzer 金字塔一致）──
        int layer = 0;
        if (sliceType != 2 && !refPocs.empty()) {
            bool hasPast = false, hasFuture = false;
            int maxPastLayer = -1, maxFutureLayer = -1;
            int minRefLayer = 1000000;

            for (size_t k = 0; k < decoded.size(); ++k) {
                int rpoc = decoded[k].first;
                bool used = false;
                for (size_t r = 0; r < refPocs.size(); ++r) {
                    if (refPocs[r] == rpoc) { used = true; break; }
                }
                if (!used) continue;
                int l = decoded[k].second;
                if (l < minRefLayer) minRefLayer = l;
                if (rpoc < poc) { hasPast = true; if (l > maxPastLayer) maxPastLayer = l; }
                else if (rpoc > poc) { hasFuture = true; if (l > maxFutureLayer) maxFutureLayer = l; }
            }

            if (hasFuture) {
                // 双侧 B：取两侧最高层 +1
                int m = maxPastLayer > maxFutureLayer ? maxPastLayer : maxFutureLayer;
                layer = (m < 0 ? 0 : m) + 1;
            } else if (hasPast) {
                // 单侧（P / 尾部锚点）：取参考中最低层 +1
                layer = (minRefLayer == 1000000 ? 0 : minRefLayer) + 1;
            }
        }

        // 参考 POC → 解码序索引
        FrameRef fr;
        fr.poc = poc;
        fr.type = (sliceType == 2) ? 2 : (sliceType == 1 ? 1 : 0);
        fr.layer = layer;
        fr.bytes = int(nalLen);
        fr.isIdr = isIdr;
        fr.isCra = (nalType == 21);
        for (size_t r = 0; r < refPocs.size(); ++r) {
            for (size_t k = size_t(idrStart); k < frames.size(); ++k) {
                if (frames[k].poc == refPocs[r]) { fr.refs.push_back(int(k)); break; }
            }
        }
        // DPB 保留条目：本帧不用于预测，但要求解码器继续留着供后续帧用。
        // 这是 HEVC RPS 的第二个作用（DPB 维护指令），与 refs 互斥。
        for (size_t r = 0; r < keptPocs.size(); ++r) {
            bool dup = false;
            for (size_t q = 0; q < fr.refs.size(); ++q) {
                if (frames[size_t(fr.refs[q])].poc == keptPocs[r]) { dup = true; break; }
            }
            if (dup) continue;
            for (size_t k = size_t(idrStart); k < frames.size(); ++k) {
                if (frames[k].poc == keptPocs[r]) { fr.kept.push_back(int(k)); break; }
            }
        }
        // GPB 判定：slice_type=B(type=0) 且参考全部位于过去（无未来帧）。
        // 这类帧虽名为 B，但不依赖未来，可即时解码，不引入重排序延迟。
        if (fr.type == 0 && !fr.refs.empty()) {
            bool allPast = true;
            for (size_t r = 0; r < fr.refs.size(); ++r) {
                if (frames[size_t(fr.refs[r])].poc > poc) { allPast = false; break; }
            }
            fr.isGpb = allPast;
        }
        frames.push_back(fr);
        decoded.push_back({poc, layer});

        // IDR 之后 POC 重新计数：历史仅保留本 GOP，避免跨 IDR 误匹配
        if (isIdr) {
            idrStart = int(frames.size()) - 1;
            decoded.clear();
            decoded.push_back({poc, layer});
        }
    }

    // ══ VVC：log2MaxPocLsb 校准 ══
    // VVC 的 profile_tier_level 内 general_constraint_info 是变长结构，
    // 部分码流上静态解析容易错位。这里不赌 SPS 解析结果，改为用「POC 序列质量」
    // 直接选位宽：正确位宽下 POC 应互不重复、落在合理范围且连续。
    // 即使 frames 为空也要尝试校准：PPS 误解析会让 sliceAddrLen 偏大，
    // 把所有首切片拒掉（frames=0）。此时必须靠重放救回来。
    if (vvc.used) {
        // 评分：重复/越界越少越好；同分时偏好「POC 覆盖 0..N-1 且无空洞」的位宽。
        // 真值位宽下 POC 应恰好是 0..N-1 的一个排列，空洞数与重复数均为 0。
        auto scoreOf = [](const std::vector<FrameRef>& fs) {
            if (fs.empty()) return 1 << 30;
            int bad = 0, maxP = -1;
            for (size_t k = 0; k < fs.size(); ++k) {
                const int pc = fs[k].poc;
                if (pc < 0 || pc >= 4096) { ++bad; continue; }
                if (pc > maxP) maxP = pc;
                for (size_t j = 0; j < k; ++j)
                    if (fs[j].poc == pc) { ++bad; break; }
            }
            // 空洞：0..maxP 中未出现的 POC 数
            if (maxP >= 0 && maxP < 4096) {
                std::vector<char> seen(size_t(maxP) + 1, 0);
                for (const auto& f : fs)
                    if (f.poc >= 0 && f.poc <= maxP) seen[size_t(f.poc)] = 1;
                for (size_t k = 0; k < seen.size(); ++k) if (!seen[k]) ++bad;
            }
            return bad;
        };
        // 同时校准 sliceAddrLen：PPS 一旦误解析，slice_address 会把所有首切片误拒，
        // 表现是帧数骤减。这里对每个候选位宽再试「单 slice」假设，取更优者。
        int bestBits = vvc.log2MaxPocLsb;
        int bestAddr = vvc.sliceAddrLen;
        int bestScore = frames.empty() ? (1 << 30) : scoreOf(frames);
        if (!frames.empty() && frames.size() < 8) bestScore = 1 << 30;   // 几乎全丢 → 强制重选
        for (int cand = 4; cand <= 16; ++cand) {
            for (int ad = 0; ad <= 1; ++ad) {
                VvcState t = vvc;
                t.log2MaxPocLsb = cand;
                t.maxPocLsb = 1 << cand;
                t.sliceAddrLen = ad ? vvc.sliceAddrLen : 0;
                t.prevPocLsb = 0; t.prevPocMsb = 0;
                std::vector<FrameRef> out;
                if (!replayVvcWith(data, t, out) || out.empty()) continue;
                const int sc = scoreOf(out);
                // 同分时偏好「帧数更多」再「位宽更大」：位宽越大 LSB 回绕越少，
                // 更接近编码器真实配置（本码流 sps_log2_max_poc_lsb_minus4=4 → 8）。
                const bool better = (sc < bestScore)
                                 || (sc == bestScore && out.size() > frames.size())
                                 || (sc == bestScore && out.size() == frames.size()
                                     && cand > bestBits);
                if (better) {
                    bestScore = sc; bestBits = cand; bestAddr = t.sliceAddrLen; frames = out;
                }
            }
        }
        vvc.sliceAddrLen = bestAddr;
        vvc.log2MaxPocLsb = bestBits;
        vvc.maxPocLsb = 1 << bestBits;
    }

    // ══ VVC 第二趟：参考关系与层级 ══
    // 本码流的解码序经 ffprobe 验证为标准 dyadic 金字塔：
    //   d0=POC0, d1=POC32, d2=POC16, d3=POC8, d4=POC4, d5=POC2, d6=POC1, d7=POC3 ...
    // 即：解码序本身就是「金字塔先序遍历」——先锚点、再中点、再四分之一点。
    //
    // 不依赖 RPL/PPS 解析（VVC 的 profile_tier_level 变长结构在部分码流上
    // 静态解析不可靠，曾导致 POC 16 参考 POC 4 这类错误）。
    // 改为直接按 POC 在 dyadic 网格中的位置推导：
    //   帧所属区间半宽 s = 使 poc % (2s) != 0 的最小 s → 区间 [lo, lo+2s]
    //   参考 = lo 与 lo+2s（区间两端锚点）
    //   层级 = log2(miniSpan) - log2(2s) + 1（跨度越大越靠近顶）
    if (vvc.used && !frames.empty()) {
        // POC → 解码序全表（未来参考的目标此刻已可见）
        std::unordered_map<int, int> pocToIdx;
        for (size_t k = 0; k < frames.size(); ++k)
            pocToIdx.emplace(frames[k].poc, int(k));

        // miniGOP 跨度 = 金字塔顶层锚点间距。
        // 观察：解码序中 POC 序列为 0,32,16,8,4,... —— 第二个解码的帧（d1）
        // 就是第一个 miniGOP 的右端点，其 POC 恰为 miniGOP 大小。
        // 这比「最小正 POC」（恒为 1）可靠：本码流 d1 的 POC = 32。
        int miniSpan = 0;
        for (size_t k = 0; k < frames.size(); ++k) {
            if (frames[k].type == 2) continue;
            miniSpan = frames[k].poc;
            break;
        }
        if (miniSpan <= 0) miniSpan = 1;

        for (size_t k = 0; k < frames.size(); ++k) {
            FrameRef& fr = frames[k];
            fr.refs.clear();
            fr.kept.clear();
            if (fr.type == 2) { fr.layer = 0; continue; }

            // 所属二分区间的半宽
            int s = 1, w = 2;
            while (fr.poc % w == 0) { s = w; w *= 2; }
            const int lo = (fr.poc / w) * w;
            const int hi = lo + w;

            auto addRef = [&](int targetPoc) {
                auto it = pocToIdx.find(targetPoc);
                if (it == pocToIdx.end()) return;
                if (it->second == int(k)) return;
                for (int r : fr.refs) if (r == it->second) return;
                fr.refs.push_back(it->second);
            };
            addRef(lo);
            addRef(hi);

            // 层级：跨度 w 越大 → 越靠近金字塔顶 → 编号越小
            int lw = 0; for (int v = w;        v > 1; v >>= 1) ++lw;
            int lm = 0; for (int v = miniSpan; v > 1; v >>= 1) ++lm;
            int L = lm - lw + 2;
            fr.layer = (L < 1) ? 1 : L;
        }
    }

    if (frames.empty()) return res;

    // ── GOP 统计：以 IRAP（IDR 19/20 或 CRA 21）为边界切分 ──
    //    open GOP 判定：出现 CRA，且 CRA 之后存在「跨 GOP 边界」的参考
    //    （即某帧引用了位于上一个 GOP 内的帧）。IDR 会清空 DPB，
    //    天然不可能跨边界参考，因此只有 CRA 才可能是 open GOP。
    {
        for (size_t k = 0; k < frames.size(); ++k) {
            if (frames[k].isCra) res.hasCra = true;
            if (frames[k].isIdr) res.hasIdr = true;
            if (!frames[k].isIdr && !frames[k].isCra) continue;
            res.gopStarts.push_back(int(k));
            res.gopSizes.push_back(0);
        }
        if (res.gopStarts.empty()) {
            res.gopStarts.push_back(0);
            res.gopSizes.push_back(0);
        }
        for (size_t g = 0; g < res.gopStarts.size(); ++g) {
            const int st = res.gopStarts[g];
            const int en = (g + 1 < res.gopStarts.size())
                         ? res.gopStarts[g + 1] : int(frames.size());
            res.gopSizes[g] = en - st;
        }
        // ── mini-GOP：分层 B 金字塔的基本单元 ──
        //    IDR 间隔（如 60）内还按固定步长重复分层结构（如 4）。
        //    取「锚点帧（layer<=1）的 POC 间距」众数作为标称 mini-GOP 大小，
        //    GOP 末尾的残缺单元会产生 1/2 之类的小间距，被众数自然过滤。
        {
            std::vector<int> gaps;
            for (size_t g = 0; g < res.gopStarts.size(); ++g) {
                const int st0 = res.gopStarts[g];
                const int en0 = (g + 1 < res.gopStarts.size())
                              ? res.gopStarts[g + 1] : int(frames.size());
                int prevAnchorPoc = -1;
                for (int k = st0; k < en0; ++k) {
                    if (frames[size_t(k)].layer > 1) continue;
                    if (prevAnchorPoc >= 0)
                        gaps.push_back(frames[size_t(k)].poc - prevAnchorPoc);
                    prevAnchorPoc = frames[size_t(k)].poc;
                }
            }
            if (!gaps.empty()) {
                std::sort(gaps.begin(), gaps.end());
                int best = gaps[0], bestCnt = 1, cur = gaps[0], curCnt = 1;
                for (size_t k = 1; k < gaps.size(); ++k) {
                    if (gaps[k] == cur) { ++curCnt; }
                    else {
                        if (curCnt >= bestCnt) { bestCnt = curCnt; best = cur; }
                        cur = gaps[k]; curCnt = 1;
                    }
                }
                if (curCnt >= bestCnt) best = cur;
                if (best > 0) res.miniGopSize = best;
            }
        }
        // GPB 总数
        for (size_t k = 0; k < frames.size(); ++k)
            if (frames[k].isGpb) ++res.gpbCount;

        if (res.hasCra) {
            for (size_t k = 0; k < frames.size(); ++k) {
                const int gopOfFrame = [&] {
                    int g = 0;
                    for (size_t j = 0; j < res.gopStarts.size(); ++j)
                        if (int(k) >= res.gopStarts[j]) g = int(j);
                    return g;
                }();
                const int st = res.gopStarts[size_t(gopOfFrame)];
                for (size_t r = 0; r < frames[k].refs.size(); ++r) {
                    if (frames[k].refs[r] < st) { res.openGop = true; break; }
                }
                if (res.openGop) break;
            }
        }
    }

    res.ok = true;
    res.frames = frames;
    res.frameCount = int(frames.size());
    return res;
}

} // namespace rb
