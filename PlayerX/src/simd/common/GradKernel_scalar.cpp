/**
 * GradKernel_scalar.cpp — 梯度/Sobel/Laplacian/Tenengrad 标量参考实现
 *
 * 所有平台恒编译，作为：
 *   1. 不支持 AVX2/NEON 的老旧机器的兜底路径
 *   2. SIMD 实现的正确性验证基准
 *   3. 10bit+ 路径的回退（仅 8bit 走 SIMD）
 *
 * 算法与 YuvAnalyzer::computeStatsLocked 第二遍循环逐行等价。
 */
#include "GradKernel.h"
#include <cstdlib>
#include <cmath>

namespace simd {

void computeGradient_scalar(const GradInput& in, GradOutput& out) {
    // 太小算不出有意义的梯度
    if (in.width < 3 || in.height < 3) return;

    const bool isHighDepth = (in.bytesPerSample == 2);

    // 选行读取函数
    auto readPixel = [&](int x, int y) -> int {
        const uint8_t* row = in.data + static_cast<size_t>(y) * in.stride;
        if (isHighDepth) {
            return reinterpret_cast<const uint16_t*>(row)[x];
        }
        return row[x];
    };

    double sGH = 0, sGV = 0, sG45 = 0, sG135 = 0;
    double sLap = 0, sTgd = 0;
    long long nGrad = 0;

    for (int y = 1; y < in.height - 1; ++y) {
        for (int x = 1; x < in.width - 1; ++x) {
            const int vC  = readPixel(x,     y);
            const int vL  = readPixel(x - 1, y);
            const int vR  = readPixel(x + 1, y);
            const int vU  = readPixel(x,     y - 1);
            const int vD  = readPixel(x,     y + 1);
            const int vTL = readPixel(x - 1, y - 1);
            const int vTR = readPixel(x + 1, y - 1);
            const int vBL = readPixel(x - 1, y + 1);
            const int vBR = readPixel(x + 1, y + 1);

            const int gH   = vR - vL;
            const int gV   = vD - vU;
            const int g45  = vBR - vTL;
            const int g135 = vBL - vTR;
            const int sx   = (vTR + 2 * vR + vBR) - (vTL + 2 * vL + vBL);
            const int sy   = (vBL + 2 * vD + vBR) - (vTL + 2 * vU + vTR);
            const int lap  = (4 * vC) - vL - vR - vU - vD;

            sGH   += std::abs(gH);
            sGV   += std::abs(gV);
            sG45  += std::abs(g45);
            sG135 += std::abs(g135);
            sLap  += static_cast<double>(lap) * lap;
            sTgd  += static_cast<double>(sx) * sx + static_cast<double>(sy) * sy;
            ++nGrad;
        }
    }

    if (nGrad > 0) {
        out.gradHorizMean   = sGH   / nGrad;
        out.gradVertMean    = sGV   / nGrad;
        out.gradDiag45Mean  = sG45  / nGrad;
        out.gradDiag135Mean = sG135 / nGrad;
        out.gradMean        = (out.gradHorizMean + out.gradVertMean +
                               out.gradDiag45Mean + out.gradDiag135Mean) / 4.0;
        out.laplacianEnergy = sLap  / nGrad;
        out.tenengrad       = sTgd  / nGrad;
        out.sampleCount     = nGrad;
    }
}

} // namespace simd
