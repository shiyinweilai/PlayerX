/**
 * GradKernel_avx2.cpp — 梯度/Sobel/Laplacian/Tenengrad AVX2 实现（x86-64 Windows）
 *
 * 编译选项：-mavx2 -mfma（由 CMake set_source_files_properties 设置）
 *
 * 优化策略：
 *   - 每批 16 像素（x-1 .. x+16），用 128bit lane 拆为两个 8 像素组
 *   - vsubq_s16 对应 _mm_sub_epi16，vabsq_s16 对应 _mm_abs_epi16 (AVX2)
 *   - 平方和用 _mm_madd_epi16（4×32bit）+ _mm_add_epi64 累加
 *
 * 仅处理 8bit 平面；10bit+ 走标量回退。
 */
#include "GradKernel.h"
#include <immintrin.h>
#include <cstdlib>
#include <cmath>

namespace simd {

// 标量回退（10bit+ 路径）
void computeGradient_scalar(const GradInput& in, GradOutput& out);

// 水平归约 s32x4 → s64x2
static inline __m128i cvtepi32_epi64(__m128i v) {
    __m128i zero = _mm_setzero_si128();
    return _mm_unpacklo_epi32(v, _mm_cmpgt_epi32(zero, v));
}

static void grad8bit_avx2(const uint8_t* data, int pw, int ph, int stride,
                          double& sGH, double& sGV, double& sG45, double& sG135,
                          double& sLap, double& sTgd, long long& nGrad) {
    const int xStart = 1;
    const int xEnd   = pw - 1;
    // 16 对齐（AVX2 128bit lane × 2 = 256bit = 16×u8）
    const int wA     = xStart + ((xEnd - xStart) & ~15);

    for (int y = 1; y < ph - 1; ++y) {
        const uint8_t* rowU = data + (y - 1) * stride;
        const uint8_t* rowC = data + y * stride;
        const uint8_t* rowD = data + (y + 1) * stride;
        int x = xStart;

        for (; x < wA; x += 16) {
            // 加载 17 像素（x-1 .. x+16），用 unaligned load
            // 中心 16 像素 = loadu(x)，左邻居 = loadu(x-1) 取高 16
            __m128i cC = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowC + x));
            __m128i cL = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowC + x - 1));
            __m128i cR = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowC + x + 1));
            __m128i uC = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowU + x));
            __m128i uL = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowU + x - 1));
            __m128i uR = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowU + x + 1));
            __m128i dC = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowD + x));
            __m128i dL = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowD + x - 1));
            __m128i dR = _mm_loadu_si128(reinterpret_cast<const __m128i*>(rowD + x + 1));

            // cL = [x-1..x+14], cC = [x..x+15], cR = [x+1..x+16]
            // 左邻居 = cL（错位 1，等效 NEON vget_low），右邻居 = cR（错位 1，等效 vext）

            // 8→16 widen（拆 128 为两个 64→128）
            // 低 8 像素
            __m128i wC_lo   = _mm_cvtepu8_epi16(cC);
            __m128i wL_lo   = _mm_cvtepu8_epi16(cL);
            __m128i wR_lo   = _mm_cvtepu8_epi16(cR);
            __m128i wU_lo   = _mm_cvtepu8_epi16(uC);
            __m128i wD_lo   = _mm_cvtepu8_epi16(dC);
            __m128i wUL_lo  = _mm_cvtepu8_epi16(uL);
            __m128i wUR_lo  = _mm_cvtepu8_epi16(uR);
            __m128i wDL_lo  = _mm_cvtepu8_epi16(dL);
            __m128i wDR_lo  = _mm_cvtepu8_epi16(dR);

            // 高 8 像素
            __m128i cC_hi   = _mm_srli_si128(cC, 8);
            __m128i cL_hi   = _mm_srli_si128(cL, 8);
            __m128i cR_hi   = _mm_srli_si128(cR, 8);
            __m128i uC_hi   = _mm_srli_si128(uC, 8);
            __m128i dC_hi   = _mm_srli_si128(dC, 8);
            __m128i uL_hi   = _mm_srli_si128(uL, 8);
            __m128i uR_hi   = _mm_srli_si128(uR, 8);
            __m128i dL_hi   = _mm_srli_si128(dL, 8);
            __m128i dR_hi   = _mm_srli_si128(dR, 8);

            __m128i wC_hi   = _mm_cvtepu8_epi16(cC_hi);
            __m128i wL_hi   = _mm_cvtepu8_epi16(cL_hi);
            __m128i wR_hi   = _mm_cvtepu8_epi16(cR_hi);
            __m128i wU_hi   = _mm_cvtepu8_epi16(uC_hi);
            __m128i wD_hi   = _mm_cvtepu8_epi16(dC_hi);
            __m128i wUL_hi  = _mm_cvtepu8_epi16(uL_hi);
            __m128i wUR_hi  = _mm_cvtepu8_epi16(uR_hi);
            __m128i wDL_hi  = _mm_cvtepu8_epi16(dL_hi);
            __m128i wDR_hi  = _mm_cvtepu8_epi16(dR_hi);

            // 处理低 8 像素和高 8 像素
            for (int half = 0; half < 2; ++half) {
                __m128i wC   = (half == 0) ? wC_lo  : wC_hi;
                __m128i wL   = (half == 0) ? wL_lo  : wL_hi;
                __m128i wR   = (half == 0) ? wR_lo  : wR_hi;
                __m128i wU   = (half == 0) ? wU_lo  : wU_hi;
                __m128i wD   = (half == 0) ? wD_lo  : wD_hi;
                __m128i wUL  = (half == 0) ? wUL_lo : wUL_hi;
                __m128i wUR  = (half == 0) ? wUR_lo : wUR_hi;
                __m128i wDL  = (half == 0) ? wDL_lo : wDL_hi;
                __m128i wDR  = (half == 0) ? wDR_lo : wDR_hi;

                // 一阶差分
                __m128i gH   = _mm_sub_epi16(wR,  wL);
                __m128i gV   = _mm_sub_epi16(wD,  wU);
                __m128i g45  = _mm_sub_epi16(wDR, wUL);
                __m128i g135 = _mm_sub_epi16(wDL, wUR);

                // abs + horizontal sum (AVX2 _mm_abs_epi16)
                __m128i absH   = _mm_abs_epi16(gH);
                __m128i absV   = _mm_abs_epi16(gV);
                __m128i abs45  = _mm_abs_epi16(g45);
                __m128i abs135 = _mm_abs_epi16(g135);
                // 8×i16 → 4×i32 via madd with all-1s
                __m128i ones = _mm_set1_epi16(1);
                __m128i sumH   = _mm_madd_epi16(absH,   ones);
                __m128i sumV   = _mm_madd_epi16(absV,   ones);
                __m128i sum45  = _mm_madd_epi16(abs45,  ones);
                __m128i sum135 = _mm_madd_epi16(abs135, ones);
                // 4×i32 → scalar
                sGH   += _mm_extract_epi32(sumH,   0) + _mm_extract_epi32(sumH,   1)
                       + _mm_extract_epi32(sumH,   2) + _mm_extract_epi32(sumH,   3);
                sGV   += _mm_extract_epi32(sumV,   0) + _mm_extract_epi32(sumV,   1)
                       + _mm_extract_epi32(sumV,   2) + _mm_extract_epi32(sumV,   3);
                sG45  += _mm_extract_epi32(sum45,  0) + _mm_extract_epi32(sum45,  1)
                       + _mm_extract_epi32(sum45,  2) + _mm_extract_epi32(sum45,  3);
                sG135 += _mm_extract_epi32(sum135, 0) + _mm_extract_epi32(sum135, 1)
                       + _mm_extract_epi32(sum135, 2) + _mm_extract_epi32(sum135, 3);

                // Sobel
                // Gx = (TR + 2R + BR) - (TL + 2L + BL)
                __m128i sx = _mm_sub_epi16(
                    _mm_add_epi16(wUR, _mm_add_epi16(_mm_slli_epi16(wR, 1), wDR)),
                    _mm_add_epi16(wUL, _mm_add_epi16(_mm_slli_epi16(wL, 1), wDL)));
                // Gy = (BL + 2D + BR) - (TL + 2U + TR)
                __m128i sy = _mm_sub_epi16(
                    _mm_add_epi16(wDL, _mm_add_epi16(_mm_slli_epi16(wD, 1), wDR)),
                    _mm_add_epi16(wUL, _mm_add_epi16(_mm_slli_epi16(wU, 1), wUR)));

                // Laplacian: 4*C - L - R - U - D
                __m128i lap = _mm_sub_epi16(
                    _mm_slli_epi16(wC, 2),
                    _mm_add_epi16(wL, _mm_add_epi16(wR,
                        _mm_add_epi16(wU, wD))));

                // sLap += lap², sTgd += sx² + sy²
                // madd_epi16: 4×i16×i16 → 4×i32, 然后逐组 unpack 到 i64 累加
                __m128i lapSq = _mm_madd_epi16(lap, lap);
                __m128i sxSq  = _mm_madd_epi16(sx, sx);
                __m128i sySq  = _mm_madd_epi16(sy, sy);

                sLap += static_cast<double>(_mm_extract_epi32(lapSq, 0))
                      + static_cast<double>(_mm_extract_epi32(lapSq, 1))
                      + static_cast<double>(_mm_extract_epi32(lapSq, 2))
                      + static_cast<double>(_mm_extract_epi32(lapSq, 3));
                sTgd += static_cast<double>(_mm_extract_epi32(sxSq, 0))
                      + static_cast<double>(_mm_extract_epi32(sxSq, 1))
                      + static_cast<double>(_mm_extract_epi32(sxSq, 2))
                      + static_cast<double>(_mm_extract_epi32(sxSq, 3))
                      + static_cast<double>(_mm_extract_epi32(sySq, 0))
                      + static_cast<double>(_mm_extract_epi32(sySq, 1))
                      + static_cast<double>(_mm_extract_epi32(sySq, 2))
                      + static_cast<double>(_mm_extract_epi32(sySq, 3));

                nGrad += 8;
            }
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

void computeGradient_avx2(const GradInput& in, GradOutput& out) {
    if (in.bytesPerSample == 1) {
        double sGH = 0, sGV = 0, sG45 = 0, sG135 = 0;
        double sLap = 0, sTgd = 0;
        long long nGrad = 0;

        grad8bit_avx2(in.data, in.width, in.height, in.stride,
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
