/**
 * SimdCaps.cpp — 运行时 CPU 指令集检测实现
 *
 * 简化检测：
 *   ARM64 (Apple Silicon) → NEON 是 AArch64 强制标配，直接返回，零开销
 *   x86-64 (Windows/Intel Mac) → 一次 CPUID 检测 AVX2，不支持则 Scalar
 */
#include "SimdCaps.h"
#include "SimdConfig.h"

#if RB_SIMD_ARM
// ── ARM64 ──────────────────────────────────────────────────────────────
// NEON 在 AArch64 中是强制标配（ARMv8-A），每一颗 Apple Silicon 芯片都支持。
// 无需运行时检测，直接返回。
simd::Isa simd::detectBestIsa() { return Isa::NEON; }

#elif RB_SIMD_X86
// ── x86-64 ─────────────────────────────────────────────────────────────
// 仅检测 AVX2（CPUID leaf 7, sub-leaf 0, EBX[5]）。
// 老旧 CPU 不支持 AVX2 → 返回 Scalar，走纯 C 路径。
#if defined(_MSC_VER)
#include <intrin.h>
static bool hasAVX2() {
    int regs[4];
    __cpuidex(regs, 7, 0);
    if (!(regs[1] & (1 << 5))) return false;       // EBX[5] = AVX2
    __cpuid(regs, 1);
    return (regs[2] & (1 << 27)) != 0;              // ECX[27] = OSXSAVE
}
#elif defined(__GNUC__) || defined(__clang__)
#include <cpuid.h>
static bool hasAVX2() {
    unsigned int a, b, c, d;
    if (!__get_cpuid_count(7, 0, &a, &b, &c, &d)) return false;
    if (!(b & (1 << 5))) return false;               // EBX[5] = AVX2
    if (!__get_cpuid(1, &a, &b, &c, &d)) return false;
    return (c & (1 << 27)) != 0;                     // ECX[27] = OSXSAVE
}
#endif

simd::Isa simd::detectBestIsa() {
    return hasAVX2() ? Isa::AVX2 : Isa::Scalar;
}

#else
// ── 未知架构 ───────────────────────────────────────────────────────────
simd::Isa simd::detectBestIsa() { return Isa::Scalar; }
#endif

simd::Isa simd::runtimeIsa() {
    static Isa cached = detectBestIsa();
    return cached;
}
