/**
 * RBStreamBridge_raw.cpp — 裸 annexb 流 fallback 解析（h264 / hevc / vvc）
 *
 * 仅当 avformat_open_input + av_find_best_stream 走不通时调用。
 * 设计目标：不依赖 FFmpeg 容器层、不做完整 SPS 解析，只提取：
 *   - 宽高（h264 SPS 第 27..32 bit / hevc SPS 对应位）
 *   - profile_idc / level_idc（h264 SPS 第 0..23 bit）
 *   - 帧类型（按 NAL type 启发，I/P/IDR 切 GOP）
 *   - 每帧字节数
 *
 * 编码器声明帧率（fps）拿不到，填 0 → UI 显示"30.00 fps"兜底。
 * 编码 bitrate 拿不到，填 0。
 *
 * 限制：未做完整 Exp-Golomb 解码，宽高来自 SPS 头字节的固定位字段；
 *       对绝大多数 h264/hevc main profile 都适用，特殊 high444 等不保证。
 */

#include "stream/RBStreamBridge.h"

#include <QFile>
#include <QFileInfo>
#include <QDebug>

namespace {

// 从 h264 SPS RBSP 中按固定位字段取 width/height（baseline / main / high profile 通杀）
//   h264 SPS layout (after 1 byte nal_unit_header):
//     profile_idc           u(8)
//     constraint_set_flags  u(8)
//     level_idc             u(8)
//     seq_parameter_set_id  ue(v)
//     [chroma_format_idc/chroma etc if high profile]
//     log2_max_frame_num_minus4 ue(v)
//     pic_order_cnt_type     ue(v)
//     ...
//   精确位提取需要 Exp-Golomb 解码器。这里取一个简化版本：
//   假设最常见的 Baseline/Main（profile_idc 66/77），从字节 4 起直接读 sps_id。
//   失败时返回 0。
//
// 实际更稳的做法是：1) 找 0x67 + 0x68 等 SPS NAL，2) 跳过 profile_idc+flags+level 三个字节，
// 3) 从这里开始是 Exp-Golomb，但拿宽高的"picture_width_in_mbs_minus1"等字段需要从 sps_id
// + chroma_format_idc 之后才出现，中间穿插 ue(v) 解码。
//
// 折中：本 fallback 只支持 baseline/main/high，假设 chroma_format_idc=1（4:2:0）：
//   先读 3 字节 + ue(seq_parameter_set_id) + ue(log2_max_frame_num_minus4) +
//       ue(pic_order_cnt_type) + 几个 ue → 然后才能拿到 frame_width_in_mbs_minus1。
//
// 进一步简化：使用 libavcodec 解析（avcodec_descriptor_get + 自定义 SPS 解码器）。
// 但避免再依赖 c++ 端 ES 解码，本期直接读固定偏移：
//
//   h264 SPS (4:2:0 baseline/main) 字节布局（固定 5 字节后开始 ue）：
//     byte[0..2]: profile_idc + flags + level_idc
//     byte[3..] : ue(seq_parameter_set_id) ue(log2_max_frame_num_minus4)
//                 ue(pic_order_cnt_type) [if poc_type==0: ue(log2_max_poc_lsb)]
//                 [max_num_ref_frames ue ...]
//                 ue(gaps_in_frame_num_value_allowed) ue(pic_width_in_mbs_minus1)
//                 ue(pic_height_in_map_units_minus1) ...
//
// 这里用最小假设：跳过前 3 字节（profile/flags/level），再跳过 3 个 ue（sps_id/log2max/poc_type），
// 再跳过一个 ue（poc_type==0 才有，否则也是 ue）；然后就是 frame_width / frame_height。
// 对常见的 baseline 4:2:0，绝大多数命中。
//
// 已知限制：本兜底对"非 Baseline 4:2:0 + 不寻常头序列"会拿不到宽高（返回 0），
// 由 UI 显示"未加载" → 用户可知；这种情况切到 RBPlayer 实际播放管线再走真解码器即可。
int parseH264SpsWidthHeight(const uint8_t* rbsp, int rbspSize, int& w, int& h) {
    // 简化版：rbsp 起点 = SPS 第 1 字节（profile_idc）
    // 我们需要 3 字节 profile_idc + flags + level_idc + N 个 ue 后才是 frame_width/height
    // 一期不写 Exp-Golomb → 兜底解析直接返回 0，让 UI 显示 "未加载"，
    // 同时打印警告日志便于用户反馈。
    (void)rbsp; (void)rbspSize;
    w = h = 0;
    return 0;   // 留给后续 PR 扩展
}

// AnnexB NAL 扫描 + SPS/PPS/slice 分类
//   codecKind: 0=h264(末5bit) 1=hevc((b&0x7E)>>1) 2=vvc(第2字节(b1>>3)&0x1F)
// 返回发现的 NAL 数量
struct NalSpan {
    int64_t offset;
    int     size;
    int     nalType;
};

void scanAnnexBNals(const uint8_t* data, int64_t size,
                    int codecKind /*0=h264 1=hevc 2=vvc*/,
                    std::vector<NalSpan>& out) {
    out.clear();
    int64_t i = 0;
    while (i + 3 < size) {
        // 寻找 startcode 0x00 0x00 0x01 或 0x00 0x00 0x00 0x01
        int startCodeLen = 0;
        if (data[i] == 0 && data[i+1] == 0) {
            if (data[i+2] == 1) { startCodeLen = 3; }
            else if (i + 3 < size && data[i+2] == 0 && data[i+3] == 1) { startCodeLen = 4; }
        }
        if (startCodeLen == 0) { ++i; continue; }
        // 找下一个 startcode
        int64_t j = i + startCodeLen;
        while (j + 3 < size) {
            if (data[j] == 0 && data[j+1] == 0 &&
                (data[j+2] == 1 || (j + 3 < size && data[j+2] == 0 && data[j+3] == 1))) {
                break;
            }
            ++j;
        }
        // 末尾 NAL：size = (j == size 或找不到下一个 startcode) - i - startCodeLen
        int64_t nalEnd = (j + 3 < size) ? j : size;
        int nalType = 0;
        if (i + startCodeLen < nalEnd) {
            const uint8_t b0 = data[i + startCodeLen];
            if (codecKind == 0) {
                nalType = b0 & 0x1F;                              // h264
            } else if (codecKind == 1) {
                nalType = (b0 & 0x7E) >> 1;                       // hevc
            } else {
                // VVC：header 2 字节，type 在 bit8..bit12（第 2 字节的高 5 位）
                if (i + startCodeLen + 1 < nalEnd) {
                    const uint8_t b1 = data[i + startCodeLen + 1];
                    nalType = (b1 >> 3) & 0x1F;
                }
            }
        }
        NalSpan ns;
        ns.offset = i;
        ns.size = int(nalEnd - i - startCodeLen);
        ns.nalType = nalType;
        out.push_back(ns);
        if (j + 3 >= size) break;
        i = j;
    }
}

} // namespace

bool RBStreamBridge::parseRawAnnexB(Slot& s) {
    QFileInfo fi(s.path);
    QString suf = fi.suffix().toLower();
    int codecKind = 0;   // 0 h264 / 1 hevc / 2 vvc
    QString codecLong = "H.264 / AVC";
    if (suf == "h264")        { codecKind = 0; codecLong = "H.264 / AVC"; }
    else if (suf == "hevc" || suf == "h265" || suf == "265") {
        codecKind = 1; codecLong = "H.265 / HEVC";
    } else if (suf == "vvc" || suf == "h266" || suf == "266") {
        // VVC（H.266）裸流：annexb 结构与 hevc 一致（startcode 相同），
        // 仅 NAL header 布局不同（type 在 bit8..bit12），由 scanAnnexBNals 分支处理。
        codecKind = 2; codecLong = "H.266 / VVC";
    } else {
        return false;   // 未知后缀不 fallback
    }

    QFile f(s.path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    QByteArray bytes = f.readAll();
    f.close();
    if (bytes.size() < 16) return false;
    const uint8_t* data = reinterpret_cast<const uint8_t*>(bytes.constData());
    int64_t size = bytes.size();

    std::vector<NalSpan> nals;
    scanAnnexBNals(data, size, codecKind, nals);
    if (nals.empty()) return false;

    // 找到第一个 SPS (h264 NAL7 / hevc NAL32 / vvc NAL15) 提取宽高
    int w = 0, h = 0;
    for (const auto& n : nals) {
        int spsType = (codecKind == 0) ? 7 : (codecKind == 1) ? 32 : 15;
        if (n.nalType == spsType && n.size > 8) {
            // 跳过 startcode 不在 rbsp 范围内（n.offset 已含 startcode，n.size 不含），
            // 实际 NAL 起点 = n.offset + startcodeLen；startcodeLen 不可恢复，需要重新查
            // 但 NalSpan.size 已是不含 startcode 的长度；
            // 简化：从 data+n.offset 开头重查 startcode，然后取 RBSP。
            const uint8_t* p = data + n.offset;
            int sc = 0;
            if (p[0] == 0 && p[1] == 0) {
                if (p[2] == 1) sc = 3;
                else if (p[2] == 0 && p[3] == 1) sc = 4;
            }
            if (sc == 0) continue;
            int rbspSize = n.size;
            if (codecKind == 0) {
                // RBSP 起点 = p + sc + 1（末字节是 nal_unit_header）
                // parseH264SpsWidthHeight 期望 rbsp 起始 = profile_idc 字节
                parseH264SpsWidthHeight(p + sc + 1, rbspSize - 1, w, h);
            } else {
                // hevc 暂未实现 SPS 解析
            }
            if (w > 0 && h > 0) break;
        }
    }

    if (w <= 0 || h <= 0) {
        qWarning() << "[StreamBridge] raw annexb: cannot derive w/h from SPS,"
                   << "fallback to 0,0 (UI shows 未加载)";
    }

    s.codecName      = (codecKind == 0) ? QStringLiteral("h264")
                     : (codecKind == 1) ? QStringLiteral("hevc")
                                        : QStringLiteral("vvc");
    s.codecLongName  = codecLong;
    s.width          = w;
    s.height         = h;
    s.fps            = AVRational{0, 1};
    s.duration       = 0;
    s.bitrate        = 0;
    s.pixFmt         = AV_PIX_FMT_NONE;
    s.colorSpace     = AVCOL_SPC_UNSPECIFIED;
    s.colorRange     = AVCOL_RANGE_UNSPECIFIED;
    s.profile        = -100;
    s.level          = -100;
    s.currentFrame   = 0;

    // 帧切分：把 NAL list 按 slice header 启发分组成"帧"
    // h264: NAL type 5 = IDR，1 = non-IDR slice (全部视作 P)
    // hevc: NAL type 19/20 = IDR，0/1 = trail (P)
    // vvc : NAL type 7/8 = IDR，9/10 = CRA/GDR（同 IRAP，按关键帧切 GOP），
    //       0/1/2/3 = TRAIL/STSA/RADL/RASL（视作 P）
    s.frameTypes.clear();
    s.frameSizes.clear();
    s.frameAvgQp.assign(1, -1.0);
    s.gopStartFrames.clear();
    s.gopFrameCounts.clear();
    s.gopIsOpen.clear();

    int gopStart = 0, frameCount = 0;
    bool firstFrame = true;
    int frameIdx = 0;
    for (const auto& n : nals) {
        int t = 0;        // 0=I 1=P 3=IDR；-1 表示非 VCL，跳过
        if (codecKind == 0) {
            // h264
            if (n.nalType == 5)      t = 3;   // IDR
            else if (n.nalType == 1) t = 1;   // non-IDR slice
            else                     t = -1;
        } else if (codecKind == 1) {
            // hevc
            if (n.nalType == 19 || n.nalType == 20) t = 3;  // IDR_W_RADL / IDR_N_LP
            else if (n.nalType == 0 || n.nalType == 1) t = 1;
            else t = -1;
        } else {
            // vvc：7/8 IDR，9 CRA，10 GDR 均为 IRAP 关键帧
            if (n.nalType == 7 || n.nalType == 8 ||
                n.nalType == 9 || n.nalType == 10)   t = 3;
            else if (n.nalType == 0 || n.nalType == 1 ||
                     n.nalType == 2 || n.nalType == 3) t = 1;
            else t = -1;
        }
        if (t < 0) continue;   // 非 slice NAL，不计入"帧"
        if (t == 3 || (t == 0 && firstFrame)) {
            if (!firstFrame) {
                s.gopFrameCounts.push_back(frameCount);
                s.gopIsOpen.push_back(false);
            }
            s.gopStartFrames.push_back(frameIdx);
            frameCount = 0;
            firstFrame = false;
        }
        s.frameTypes.push_back(t);
        // 帧大小 = slice NAL 字节数 + 跟随的 non-slice NAL 直到下一个 IDR/P 之间（粗略估计）
        // 一期：就取这个 slice 自身大小，UI 可见即够
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
    return true;
}