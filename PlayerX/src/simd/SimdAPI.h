#pragma once
/**
 * SimdAPI.h — SIMD 加速层统一公共入口
 *
 * 外部模块（YuvAnalyzer / ImageBridge / RBStreamBridge 等）只需 include
 * 此文件即可使用所有 SIMD 加速函数。运行时自动 dispatch 到最优 ISA
 * 实现（AVX2 / NEON / 标量），调用方无需关心底层指令集选择。
 *
 * 设计原则：
 *   1. 模块独立维护——common/ 放跨模块共享 kernel，yuv/ image/ stream/
 *      放各模块专用 kernel，拆分时按模块整包带走。
 *   2. 零 GPU 依赖——纯 CPU SIMD，无 OpenGL / Metal / Vulkan 调用。
 *   3. 老旧机器兜底——检测不到 AVX2/NEON 时自动走标量 C，功能不缺失。
 */
#include "SimdCaps.h"
#include "common/HistKernel.h"
#include "common/GradKernel.h"
// #include "yuv/YuvConvertKernel.h"

namespace simd {
// 公共 API 在各 kernel 头文件中声明，此处仅做聚合 include。
} // namespace simd
