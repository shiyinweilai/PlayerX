/**
 * GradKernel_neon.cpp — 梯度/Sobel/Laplacian/Tenengrad NEON 实现（ARM64）
 *
 * 仅处理 8bit 平面；10bit+ 走标量回退。
 * 每批 8 像素，加载上/中/下三行各 10 像素（含左右邻居），
 * 用 vext_u8 提取左/右偏移，vsubq_s16 做差分，
 * vabsq_s16 + vaddlvq_s16 归约绝对值之和，
 * vmull_s16 → vaddvq_s32 归约平方和。
 */
#include "GradKernel.h"
#include <arm_neon.h>
#include <cstdlib>
#include <cmath>

namespace simd {

// 标量回退（10bit+ 路径）
void computeGradient_scalar(const GradInput& in, GradOutput& out);

static void grad8bit_neon(const uint8_t* data, int pw, int ph, int stride,
                          double& sGH, double& sGV, double& sG45, double& sG135,
                          double& sLap, double& sTgd, long long& nGrad) {
    const int xStart = 1;
    const int xEnd   = pw - 1;
    const int wA     = xStart + ((xEnd - xStart) & ~7);  // 8 对齐

    for (int y = 1; y < ph - 1; ++y) {
        const uint8_t* rowU = data + (y - 1) * stride;
        const uint8_t* rowC = data + y * stride;
        const uint8_t* rowD = data + (y + 1) * stride;
        int x = xStart;

        for (; x < wA; x += 8) {
            // 加载 10 像素（x-1 .. x+8），取高 8 个为中心，低 8 个为左邻居
            uint8x16_t c16 = vld1q_u8(rowC + x - 1);
            uint8x16_t u16 = vld1q_u8(rowU + x - 1);
            uint8x16_t d16 = vld1q_u8(rowD + x - 1);

            uint8x8_t vC  = vget_high_u8(c16);
            uint8x8_t vL  = vget_low_u8(c16);
            uint8x8_t vR  = vext_u8(vget_low_u8(c16), vget_high_u8(c16), 1);

            uint8x8_t vU  = vget_high_u8(u16);
            uint8x8_t vD  = vget_high_u8(d16);
            uint8x8_t vUL = vget_low_u8(u16);
            uint8x8_t vUR = vext_u8(vget_low_u8(u16), vget_high_u8(u16), 1);
            uint8x8_t vDL = vget_low_u8(d16);
            uint8x8_t vDR = vext_u8(vget_low_u8(d16), vget_high_u8(d16), 1);

            // Widen to u16
            uint16x8_t wC   = vmovl_u8(vC);
            uint16x8_t wL   = vmovl_u8(vL);
            uint16x8_t wR   = vmovl_u8(vR);
            uint16x8_t wU   = vmovl_u8(vU);
            uint16x8_t wD   = vmovl_u8(vD);
            uint16x8_t wUL  = vmovl_u8(vUL);
            uint16x8_t wUR  = vmovl_u8(vUR);
            uint16x8_t wDL  = vmovl_u8(vDL);
            uint16x8_t wDR  = vmovl_u8(vDR);

            // 一阶差分
            int16x8_t gH   = vsubq_s16(vreinterpretq_s16_u16(wR),  vreinterpretq_s16_u16(wL));
            int16x8_t gV   = vsubq_s16(vreinterpretq_s16_u16(wD),  vreinterpretq_s16_u16(wU));
            int16x8_t g45  = vsubq_s16(vreinterpretq_s16_u16(wDR), vreinterpretq_s16_u16(wUL));
            int16x8_t g135 = vsubq_s16(vreinterpretq_s16_u16(wDL), vreinterpretq_s16_u16(wUR));

            // abs 归约
            sGH   += vaddlvq_s16(vabsq_s16(gH));
            sGV   += vaddlvq_s16(vabsq_s16(gV));
            sG45  += vaddlvq_s16(vabsq_s16(g45));
            sG135 += vaddlvq_s16(vabsq_s16(g135));

            // Sobel: Gx = (TR + 2R + BR) - (TL + 2L + BL)
            //        Gy = (BL + 2D + BR) - (TL + 2U + TR)
            int16x8_t sx = vsubq_s16(
                vaddq_s16(vreinterpretq_s16_u16(wUR),
                    vaddq_s16(vshlq_n_s16(vreinterpretq_s16_u16(wR), 1),
                              vreinterpretq_s16_u16(wDR))),
                vaddq_s16(vreinterpretq_s16_u16(wUL),
                    vaddq_s16(vshlq_n_s16(vreinterpretq_s16_u16(wL), 1),
                              vreinterpretq_s16_u16(wDL))));
            int16x8_t sy = vsubq_s16(
                vaddq_s16(vreinterpretq_s16_u16(wDL),
                    vaddq_s16(vshlq_n_s16(vreinterpretq_s16_u16(wD), 1),
                              vreinterpretq_s16_u16(wDR))),
                vaddq_s16(vreinterpretq_s16_u16(wUL),
                    vaddq_s16(vshlq_n_s16(vreinterpretq_s16_u16(wU), 1),
                              vreinterpretq_s16_u16(wUR))));

            // Laplacian: 4*C - L - R - U - D
            int16x8_t lap = vsubq_s16(
                vshlq_n_s16(vreinterpretq_s16_u16(wC), 2),
                vaddq_s16(vreinterpretq_s16_u16(wL),
                    vaddq_s16(vreinterpretq_s16_u16(wR),
                        vaddq_s16(vreinterpretq_s16_u16(wU),
                                  vreinterpretq_s16_u16(wD)))));

            // sLap += lap², sTgd += sx² + sy²  (widen to s32 避免溢出)
            int32x4_t lapLo = vmovl_s16(vget_low_s16(lap));
            int32x4_t lapHi = vmovl_s16(vget_high_s16(lap));
            sLap += static_cast<double>(vaddvq_s32(vmulq_s32(lapLo, lapLo)))
                  + static_cast<double>(vaddvq_s32(vmulq_s32(lapHi, lapHi)));

            int32x4_t sxLo = vmovl_s16(vget_low_s16(sx));
            int32x4_t sxHi = vmovl_s16(vget_high_s16(sx));
            int32x4_t syLo = vmovl_s16(vget_low_s16(sy));
            int32x4_t syHi = vmovl_s16(vget_high_s16(sy));
            sTgd += static_cast<double>(vaddvq_s32(vmulq_s32(sxLo, sxLo)))
                  + static_cast<double>(vaddvq_s32(vmulq_s32(sxHi, sxHi)))
                  + static_cast<double>(vaddvq_s32(vmulq_s32(syLo, syLo)))
                  + static_cast<double>(vaddvq_s32(vmulq_s32(syHi, syHi)));

            nGrad += 8;
        }

        // 尾部标量
        for (; x < xEnd; ++x) {
            const int vC  = rowC[x];
            const int vL  = rowC[x - 1];
            const int vR  = rowC[x + 1];
            const int vU  = rowU[x];
            const int vD  = rowD[x];
            const int vTL = rowU[x - 1];
            const int vTR = rowU[x + 1];
            const int vBL = rowD[x - 1];
            const int vBR = rowD[x + 1];
            const int gH  = vR - vL;
            const int gV  = vD - vU;
            const int g45 = vBR - vTL;
            const int g135 = vBL - vTR;
            const int ssx = (vTR + 2 * vR + vBR) - (vTL + 2 * vL + vBL);
            const int ssy = (vBL + 2 * vD + vBR) - (vTL + 2 * vU + vTR);
            const int lap = (4 * vC) - vL - vR - vU - vD;
            sGH   += std::abs(gH);
            sGV   += std::abs(gV);
            sG45  += std::abs(g45);
            sG135 += std::abs(g135);
            sLap  += static_cast<double>(lap) * lap;
            sTgd  += static_cast<double>(ssx) * ssx + static_cast<double>(ssy) * ssy;
            ++nGrad;
        }
    }
}

void computeGradient_neon(const GradInput& in, GradOutput& out) {
    if (in.bytesPerSample == 1) {
        double sGH = 0, sGV = 0, sG45 = 0, sG135 = 0;
        double sLap = 0, sTgd = 0;
        long long nGrad = 0;

        grad8bit_neon(in.data, in.width, in.height, in.stride,
                      sGH, sGV, sG45, sG135, sLap, sTgd, nGrad);

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
        return;
    }

    // 10bit+ → 标量回退
    computeGradient_scalar(in, out);
}

} // namespace simd
