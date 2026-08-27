#pragma once
/**
 * GradKernel.h — 梯度/Sobel/Laplacian/Tenengrad kernel 接口定义
 *
 * 对 8bit 平面中心区域 [1..w-2, 1..h-2] 做单次遍历，计算：
 *   - 四方向一阶梯度绝对值之和（H/V/45°/135°）→ 各方向梯度均值
 *   - Sobel 近似（Gx/Gy）平方和 → Tenengrad（清晰度度量）
 *   - Laplacian 4-邻域能量（Σ lap²/N）
 *
 * 数据结构设计原则与 HistKernel 一致：纯 POD，不依赖 Qt/FFmpeg。
 *
 * 调用示例：
 *   simd::GradInput in{...};
 *   simd::GradOutput out;
 *   simd::computeGradient(in, out);
 */
#include <cstdint>

namespace simd {

struct GradInput {
    const uint8_t* data;      // 平面数据指针
    int   width;              // 有效像素宽
    int   height;             // 有效像素高
    int   stride;             // 行步幅（字节）
    int   bytesPerSample;     // 1 = 8bit（仅 8bit 走 SIMD，其余标量回退）
};

struct GradOutput {
    double gradHorizMean   = 0.0;
    double gradVertMean    = 0.0;
    double gradDiag45Mean  = 0.0;
    double gradDiag135Mean = 0.0;
    double gradMean        = 0.0;  // 四方向平均
    double laplacianEnergy = 0.0;  // Σ lap² / N
    double tenengrad       = 0.0;  // Σ (sx²+sy²) / N
    long long sampleCount  = 0;
};

/// 运行时自动 dispatch 到 AVX2 / NEON / 标量
void computeGradient(const GradInput& in, GradOutput& out);

} // namespace simd
