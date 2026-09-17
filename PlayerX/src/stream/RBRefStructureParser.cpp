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
