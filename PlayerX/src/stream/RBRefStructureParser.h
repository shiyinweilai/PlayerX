#pragma once
/**
 * RBRefStructureParser.h — 参考结构解析器（独立模块）
 *
 * 目的：
 *   从码流真实解析每一帧的「参考关系」与「层级」，
 *   替代此前基于帧类型 + 位置的启发式猜测（对纯 B 金字塔失真）。
 *
 * 原理（已在 qp31.265 上用 ffmpeg trace_headers 逐帧验证）：
 *   1) 遍历 Annex-B NAL（0x000001 / 0x00000001），去 RBSP 逃逸（0x000003）；
 *   2) 解析 SPS 取 log2_max_pic_order_cnt_lsb 与 num_short_term_ref_pic_sets；
 *      解析 PPS 取 dependent_slice_segments_enabled_flag /
 *      output_flag_present_flag / num_extra_slice_header_bits；
 *   3) 每个首切片（first_slice_segment_in_pic_flag=1）解 slice 头：
 *      slice_type、slice_pic_order_cnt_lsb（含 MSB 传播与 IDR 复位）、
 *      short_term_ref_pic_set（含 SPS 集与 slice 内联集两种来源）；
 *   4) 由 used_by_curr_pic 标记筛出真正被当前帧使用的参考（POC 集合）；
 *   5) 层级推导（与 VQ Analyzer stream view 的金字塔高度一致）：
 *        I/IDR（或无参考）        → 0
 *        双侧 B（过去+未来都有 used 参考）→ 1 + max(过去侧最高层, 未来侧最高层)
 *        单侧（P / 尾部锚点，仅过去参考）→ 1 + min(所有 used 参考层)
 *
 * 输出口径（重要）：
 *   全部按「解码序」（= 编码序 = 包序）索引，与 RBFrameOrderMapper 的
 *   codeToDisp 同口径；QML 侧按显示序排布时用 dispToCode 换算。
 *
 * 隔离性（与 RBFrameOrderMapper / RBBlockAnalyzer 约束一致）：
 *   - 不引入 Qt 类型，可独立编译；
 *   - 不触碰解码器 / 播放管线 / 其它模块状态；
 *   - 无 goto，纯结构化控制流；
 *   - 只读打开输入文件，不写任何数据。
 *
 * 耗时：与文件大小成正比（纯位流解析，远快于解码），仍应在后台线程调用。
 */

#include <cstdint>
#include <string>
#include <vector>
#include <atomic>

namespace rb {

class RBRefStructureParser {
public:
    // 单帧的参考结构信息（按解码序存放）
    struct FrameRef {
        int  poc = 0;                 // 图像顺序计数（显示序位置，IDR 处复位）
        int  type = 2;                // 0=B 1=P 2=I（与 AV_PICTURE_TYPE 对齐）
        int  layer = 0;               // 层级：0 最重要（I/IDR），数字越大越不重要
        std::vector<int> refs;        // 本帧使用到的参考帧，元素是「解码序索引」
        std::vector<int> kept;        // RPS 中 used=0 的条目：不参与本帧预测，但要求保留在 DPB
        int  bytes = 0;               // 该帧所在 NAL 的字节数（近似帧大小）
        bool isIdr = false;           // IDR（nal 19/20）：清空 DPB，closed GOP 边界
        bool isCra = false;           // CRA（nal 21）：不清空 DPB，open GOP 的候选边界
        // GPB（Generalized P/B）：slice_type=B 但所有参考都在过去（无未来参考）。
        // 低延迟 B，可即时解码，不引入重排序延迟。判定见 cpp 填充处。
        bool isGpb = false;
    };

    struct Result {
        bool ok = false;              // 解析是否成功且有效
        int  frameCount = 0;          // 解析出的帧数（= 首切片个数）
        std::vector<FrameRef> frames; // 按解码序

        // ── GOP 统计（以 IRAP 为边界，按解码序切分）──
        std::vector<int>   gopSizes;  // 每个 GOP 的帧数
        std::vector<int>   gopStarts; // 每个 GOP 的首帧「解码序」下标
        bool hasCra = false;          // 码流中是否出现 CRA（nal 21）
        bool hasIdr = false;          // 码流中是否出现 IDR（nal 19/20）
        bool openGop = false;         // open GOP 判定：CRA 之后存在跨边界反向参考
        int  miniGopSize = 0;         // mini-GOP（分层 B 金字塔单元）大小，取锚点间距众数
        int  gpbCount = 0;            // GPB 帧总数（低延迟 B）
    };

    // 解析整个文件（Annex-B 裸流）。支持 hevc / h265；
    // 其它编码（含 h264）返回 ok=false，调用方回退启发式。
    // cancel：协作式取消检查点（非空且 *cancel==true 时提前返回 ok=false）。
    static Result parse(const std::string& filePath,
                        const std::atomic_bool* cancel = nullptr);
};

} // namespace rb
