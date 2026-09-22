#pragma once
/**
 * RBSyntaxAnalyzer.h — 码流语法元素分析器（SPS/PPS/VPS 名值对，右侧栏 Syntax Info）
 *
 * 设计目标：
 *   - 复用项目内嵌 FFmpeg 的 CBS（Coded Bitstream）完整语法解析：
 *     h264 / hevc / vvc 三大标准的 SPS/PPS/VPS 字段顺序、字段名、推断值
 *     全部由 FFmpeg cbs_h264/cbs_h265/cbs_h266 提供，本文件零手写解析，
 *     与 VQ Analyzer 的 Syntax Info 同源（CBS trace 即其数据来源）。
 *   - 通过 CBS 的 trace_read_callback 逐语法元素回调，收集
 *     { name, value } 名值对列表。参数集之外再解析指定图像的
 *     picture header + 首 slice header（CBS 只读到 header，不含 CU）。
 *   - 独立模块：不触碰 RBStreamBridge 的 Slot / blockAnalyzer / 渲染路径，
 *     仅在 RBStreamBridge 新增的两个只读 Q_INVOKABLE 后面被调用。
 *
 * 用法（RBStreamBridge 内）：
 *   rb::RBSyntaxAnalyzer analyzer;
 *   auto entries = analyzer.analyze(codecName, extradata, annexbFilePath);
 *   // entries: [{ name: "sps_log2_ctu_size_minus5", value: "0", ... }, ...]
 *
 * 数据来源优先级：
 *   1) 容器 extradata（avcC/hvcC/vvcC）先拆参数集；
 *   2) 若 PPS 未解析完整（缺 init_qp 等），再用裸 AnnexB 文件前 N MB
 *      扫 VPS/SPS/PPS。VVC PPS 依赖已解析 SPS，必须按类型顺序喂 CBS。
 *   3) 同一 CBS 上下文里再喂该图像的 PH（若有）+ 首个 VCL，得到 SLICE。
 *
 * 线程模型：纯函数式。analyze() 可在任意线程调用（QML 打开文件时后台跑一次，
 * 结果缓存于 RBStreamBridge::Slot，之后 QML 只读缓存）。
 */

#include <QString>
#include <QStringList>
#include <QVariantList>
#include <vector>
#include <cstdint>
#include <utility>

struct GetBitContext;   // libavcodec 内部类型，仅前置声明（实现在 .cpp 中用 cbs.h）

namespace rb {

// 一条语法元素记录（名值对 + 所属参数集 + 组名前缀）
struct RBSyntaxEntry {
    QString set;    // 所属参数集："SPS" / "PPS" / "VPS" / "SLICE"
    QString name;   // 标准字段名，如 "sps_log2_ctu_size_minus5"
    QString value;  // 十进制值（SE golomb 已还原为有符号数）
};

class RBSyntaxAnalyzer {
public:
    // 分析入口：参数集 + 码流第一幅图像的 PH/SH（set="SLICE"）。
    //   codecName: "h264" / "hevc" / "vvc"（RBStreamBridge::Slot::codecName）
    //   extradata / extradataSize: 容器内参数集（可空：裸流无 extradata）
    //   annexbPath: 裸码流文件路径（可空：容器文件用 extradata 即可）
    // 返回按解析顺序排列的名值对列表（空 = 不支持/解析失败）。
    static std::vector<RBSyntaxEntry> analyze(const QString& codecName,
                                              const uint8_t* extradata,
                                              int extradataSize,
                                              const QString& annexbPath);

    // 只解析解码序第 pictureIndex 幅图像的 PH + 首 slice header。
    // 必须先有同文件的 SPS/PPS（内部会无 trace 地再喂一遍参数集）。
    static std::vector<RBSyntaxEntry> analyzePicture(const QString& codecName,
                                                     const uint8_t* extradata,
                                                     int extradataSize,
                                                     const QString& annexbPath,
                                                     int pictureIndex);

    // 便捷重载：全量转 QVariantList（QML 直接消费）
    static QVariantList toVariantList(const std::vector<RBSyntaxEntry>& entries);

    // AnnexB 参数集 NAL 分离（公开给 bridge 复用：找 SPS/PPS/VPS）
    // 输入完整码流数据，输出 [startOffset, size) 形式的参数集 NAL 列表
    // （已含起始码；type 通过回调外的 peek 判定，见 .cpp）。
    static std::vector<std::pair<int64_t, int64_t>> findParameterSetNals(
        const uint8_t* data, int64_t size, int codec /* 0=h264 1=hevc 2=vvc */);

private:
    // CBS trace 回调（ctx 是 Collector 结构体）
    struct Collector;
    static void collectReadCb(void* traceContext, GetBitContext* gbc,
                              int startPosition, const char* str,
                              const int* subscripts, int64_t value);
};

} // namespace rb
