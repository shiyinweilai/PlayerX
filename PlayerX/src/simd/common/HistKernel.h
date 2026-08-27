#pragma once
/**
 * HistKernel.h — 直方图 + 均值/方差/极值 kernel 接口定义
 *
 * 单次遍历计算：
 *   - 256 桶（8bit）或 1024 桶（10bit+）直方图
 *   - 像素值 sum / sumSq → 均值 / 方差 / 标准差
 *   - min / max / range
 *
 * 数据结构设计原则：
 *   - HistInput / HistOutput 是纯 POD，不依赖 Qt / FFmpeg，
 *     方便各模块独立拆分。
 *   - 字段覆盖 YuvAnalyzer::PlaneHistogram 的全部输出，
 *     调用方拿到 out 后可直接填充 PlaneHistogram。
 *
 * 调用示例：
 *   simd::HistInput in{...};
 *   simd::HistOutput out;
 *   simd::computeHistogram(in, out);
 */
#include <cstdint>
#include <vector>

namespace simd {

struct HistInput {
    const uint8_t* data;      // 平面数据指针
    int   width;              // 有效像素宽
    int   height;             // 有效像素高
    int   stride;             // 行步幅（字节），可能含 padding
    int   bytesPerSample;     // 1 = 8bit, 2 = 10/12/16bit
    int   binCount;           // 256 或 1024（由调用方按位深确定）
    // NV12/NV21 交错 UV：每 2 字节一组 (U,V)，plane>=1 时启用
    bool  isInterleavedUV = false;
    int   uvOffset = 0;       // 交错时取 U(offset=0) 或 V(offset=1)
};

struct HistOutput {
    std::vector<int> bins;    // 直方图桶（binCount 个元素）
    double mean     = 0.0;
    double stddev   = 0.0;
    double variance = 0.0;
    int    minVal   = 0;
    int    maxVal   = 0;
    int    range    = 0;
    long long count = 0;
};

/// 运行时自动 dispatch 到 AVX2 / NEON / 标量
void computeHistogram(const HistInput& in, HistOutput& out);

} // namespace simd
