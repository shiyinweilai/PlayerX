/**
 * SimdAPI.cpp — 运行时 dispatch 实现
 *
 * 根据 SimdCaps::runtimeIsa() 的检测结果，将每个公共 API 调用路由到
 * 对应 ISA 的 kernel 实现。编译期用 RB_SIMD_X86 / RB_SIMD_ARM 宏
 * 确保只引用当前平台实际编译的变体。
 */
#include "SimdAPI.h"
#include "SimdConfig.h"

namespace simd {

// ── 标量参考实现（所有平台恒编译）──
void computeHistogram_scalar(const HistInput& in, HistOutput& out);

// ── AVX2 变体（仅 x86-64 编译）──
#if RB_SIMD_X86
void computeHistogram_avx2(const HistInput& in, HistOutput& out);
#endif

// ── NEON 变体（仅 ARM64 编译）──
#if RB_SIMD_ARM
void computeHistogram_neon(const HistInput& in, HistOutput& out);
#endif

// ── 运行时 dispatch ──
void computeHistogram(const HistInput& in, HistOutput& out) {
    switch (runtimeIsa()) {
#if RB_SIMD_X86
    case Isa::AVX2:  computeHistogram_avx2(in, out);  return;
#endif
#if RB_SIMD_ARM
    case Isa::NEON:  computeHistogram_neon(in, out);  return;
#endif
    case Isa::Scalar:
    default:         computeHistogram_scalar(in, out); return;
    }
}

// ── GradKernel 前向声明 ──
void computeGradient_scalar(const GradInput& in, GradOutput& out);
#if RB_SIMD_X86
void computeGradient_avx2(const GradInput& in, GradOutput& out);
#endif
#if RB_SIMD_ARM
void computeGradient_neon(const GradInput& in, GradOutput& out);
#endif

// ── GradKernel 运行时 dispatch ──
void computeGradient(const GradInput& in, GradOutput& out) {
    switch (runtimeIsa()) {
#if RB_SIMD_X86
    case Isa::AVX2:  computeGradient_avx2(in, out);  return;
#endif
#if RB_SIMD_ARM
    case Isa::NEON:  computeGradient_neon(in, out);  return;
#endif
    case Isa::Scalar:
    default:         computeGradient_scalar(in, out); return;
    }
}

} // namespace simd
