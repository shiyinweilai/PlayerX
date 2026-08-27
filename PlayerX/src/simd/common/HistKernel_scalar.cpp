/**
 * HistKernel_scalar.cpp — 直方图标量参考实现
 *
 * 所有平台恒编译，作为：
 *   1. 不支持 AVX2/NEON 的老旧机器的兜底路径
 *   2. SIMD 实现的正确性验证基准
 *   3. 性能对比基准
 *
 * 算法与 YuvAnalyzer::computeHistogramFromSnapshot 中的标量循环
 * 逐行等价，仅提取为独立 POD 接口。
 */
#include "HistKernel.h"
#include <cmath>
#include <climits>

namespace simd {

void computeHistogram_scalar(const HistInput& in, HistOutput& out) {
    out.bins.assign(in.binCount, 0);

    long long sum = 0, sumSq = 0;
    int minVal = INT_MAX, maxVal = INT_MIN;
    long long count = 0;

    if (in.bytesPerSample == 2) {
        // ── 高位深（10/12/16bit）──
        for (int y = 0; y < in.height; ++y) {
            const uint16_t* row = reinterpret_cast<const uint16_t*>(
                in.data + static_cast<size_t>(y) * in.stride);
            for (int x = 0; x < in.width; ++x) {
                const int val = row[x];
                if (val < in.binCount) out.bins[val]++;
                sum += val;
                sumSq += static_cast<long long>(val) * val;
                if (val < minVal) minVal = val;
                if (val > maxVal) maxVal = val;
                ++count;
            }
        }
    } else if (in.isInterleavedUV) {
        // ── NV12/NV21 交错 UV 平面 ──
        const int off = in.uvOffset;
        for (int y = 0; y < in.height; ++y) {
            const uint8_t* row = in.data + static_cast<size_t>(y) * in.stride;
            for (int x = 0; x < in.width; ++x) {
                const int val = row[x * 2 + off];
                if (val < in.binCount) out.bins[val]++;
                sum += val;
                sumSq += static_cast<long long>(val) * val;
                if (val < minVal) minVal = val;
                if (val > maxVal) maxVal = val;
                ++count;
            }
        }
    } else {
        // ── 8bit 灰度平面 ──
        for (int y = 0; y < in.height; ++y) {
            const uint8_t* row = in.data + static_cast<size_t>(y) * in.stride;
            for (int x = 0; x < in.width; ++x) {
                const int val = row[x];
                out.bins[val]++;
                sum += val;
                sumSq += static_cast<long long>(val) * val;
                if (val < minVal) minVal = val;
                if (val > maxVal) maxVal = val;
                ++count;
            }
        }
    }

    if (count > 0) {
        const double mean = static_cast<double>(sum) / count;
        const double meanSq = mean * mean;
        const double sqMean = static_cast<double>(sumSq) / count;
        const double var = (sqMean > meanSq) ? (sqMean - meanSq) : 0.0;
        out.mean = mean;
        out.stddev = std::sqrt(var);
        out.variance = var;
        out.minVal = minVal;
        out.maxVal = maxVal;
        out.range = maxVal - minVal;
        out.count = count;
    }
}

} // namespace simd
