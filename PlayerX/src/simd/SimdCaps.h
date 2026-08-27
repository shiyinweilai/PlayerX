#pragma once
/**
 * SimdCaps.h — 运行时 CPU 指令集检测
 *
 * 简化策略（不考虑老旧机器，老旧机器一律走标量 C）：
 *   ARM64 → NEON 是 AArch64 强制标配，无需检测
 *   x86-64 → 仅检测 AVX2，不支持则回退标量 C
 *
 * 检测结果缓存，全进程只执行一次 CPUID。
 */

namespace simd {

enum class Isa {
    Scalar,   // 纯 C 标量实现（老旧机器兜底）
    AVX2,     // x86-64 AVX2 + FMA
    NEON,     // ARM64 NEON
};

/// 启动时检测最佳 ISA（仅调用一次，内部有缓存）
Isa detectBestIsa();

/// 运行时查询（缓存 detectBestIsa() 结果，后续调用 O(1)）
Isa runtimeIsa();

} // namespace simd
