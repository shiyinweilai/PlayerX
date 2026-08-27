#pragma once
/**
 * SimdConfig.h — 编译期架构检测宏
 *
 * 基于编译器目标架构宏判断平台，不依赖 -mavx2 等 ISA 编译选项
 *（同一 target 中不同 .cpp 可能使用不同的 -m 选项，此处只看架构）。
 *
 * RB_SIMD_X86 / RB_SIMD_ARM 用于 SimdAPI.cpp 的编译期分支，
 * 确保只引用当前平台实际编译的 kernel 变体。
 */
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
  #define RB_SIMD_X86 1
  #define RB_SIMD_ARM 0
#elif defined(__aarch64__) || defined(_M_ARM64) || defined(__ARM_NEON)
  #define RB_SIMD_X86 0
  #define RB_SIMD_ARM 1
#else
  #define RB_SIMD_X86 0
  #define RB_SIMD_ARM 0
#endif
