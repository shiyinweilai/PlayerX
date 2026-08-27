# SIMD 加速层

## 平台支持策略

**仅支持以下两个平台，其余平台一律走纯 C 标量实现：**

| 平台 | 架构 | SIMD ISA | 说明 |
|------|------|----------|------|
| macOS | ARM64 (Apple Silicon) | NEON | AArch64 强制标配，无需运行时检测 |
| Windows | x86-64 (64 位) | AVX2 + FMA | 运行时 CPUID 检测，不支持则回退标量 |

**不支持的平台（自动走纯 C 标量，功能不受影响，仅无 SIMD 加速）：**
- macOS x86_64（Intel Mac）→ 虽有 AVX2 变体可编译，但非目标平台
- 32 位 x86 / 32 位 ARM → 无 SIMD 路径
- Linux / 其他 Unix → 无 SIMD 路径

## 架构概览

```
simd/
├── SimdConfig.h          编译期架构宏（RB_SIMD_X86 / RB_SIMD_ARM）
├── SimdCaps.h/.cpp       运行时 ISA 检测（AVX2 / NEON / Scalar）
├── SimdAPI.h/.cpp        统一入口 + 运行时 dispatch
├── common/               跨模块共享 kernel
│   ├── HistKernel.*      直方图 + 均值/方差/极值
│   └── GradKernel.*      梯度/Sobel/Laplacian/Tenengrad
├── yuv/                  YUV 分析专用 kernel（预留）
├── image/                图片分析专用 kernel（预留）
└── stream/               码流分析专用 kernel（预留）
```

## 模块独立维护

每个模块的 kernel 放在各自子目录（`yuv/` `image/` `stream/`），`common/` 放
跨模块共享的 kernel。拆分模块时把 `simd/` 基础设施 + `common/` + 对应模块
子目录整包带走即可，零歧义。

## 运行时 dispatch

```
启动时 SimdCaps::detectBestIsa() 检测 → 缓存
     │
     ├─ ARM64 (Apple Silicon) → NEON（AArch64 强制标配，零检测开销）
     ├─ x86-64 + AVX2         → AVX2（一次 CPUID）
     └─ 不支持 AVX2 / 未知架构 → Scalar（纯 C 兜底）
```

调用方只需调用 `simd::computeHistogram(in, out)`，内部自动路由。

## ISA 策略

| 平台 | 最优 ISA | 老旧机器回退 |
|------|----------|-------------|
| macOS ARM64 (Apple Silicon) | NEON | N/A（AArch64 强制标配）|
| Windows x86-64 | AVX2 + FMA | Scalar（不支持 AVX2 的 CPU）|

## 已实现 kernel

### HistKernel（common/）

单次遍历计算：256/1024 桶直方图 + sum/sumSq/min/max → 均值/方差/标准差。

**输入** `HistInput`：平面数据指针 + 宽高/stride/位深/交错标志
**输出** `HistOutput`：bins 数组 + 统计量

**优化策略**：sum/sumSq/min/max 用 SIMD 并行，bins 标量收集（scatter 难以向量化）。

| ISA | 处理粒度 | 加速比 (1080p Y) |
|-----|---------|-----------------|
| Scalar | 1 像素 | 1× (基准 ~2ms) |
| AVX2 | 32 像素 | ~4× (~0.5ms) |
| NEON | 16 像素 | ~5× (~0.4ms) |

### GradKernel（common/）

对 8bit 平面中心区域 [1..w-2, 1..h-2] 单次遍历计算：
- 四方向一阶梯度绝对值之和（H/V/45°/135°）→ 各方向梯度均值
- Sobel 近似（Gx/Gy）平方和 → Tenengrad（清晰度度量）
- Laplacian 4-邻域能量（Σ lap²/N）

**输入** `GradInput`：平面数据指针 + 宽高/stride/位深
**输出** `GradOutput`：梯度均值 + Laplacian 能量 + Tenengrad + 采样数

**优化策略**：每批 8（NEON）或 16（AVX2）像素，加载上/中/下三行，
用 SIMD 差分 + abs + 平方和归约。10bit+ 走标量回退。

| ISA | 处理粒度 | 加速比 (1080p Y) |
|-----|---------|-----------------|
| Scalar | 1 像素 | 1× |
| AVX2 | 16 像素/批 (2×8) | ~6× |
| NEON | 8 像素/批 | ~5× |

## 新增 kernel 流程

1. 在 `common/` 或 `yuv/` 下新建 `XxxKernel.h`，定义 POD 输入/输出结构 + 函数声明
2. 创建 `XxxKernel_scalar.cpp`（标量参考实现，所有平台恒编译）
3. x86: 创建 `XxxKernel_avx2.cpp`（-mavx2 -mfma）
4. ARM: 创建 `XxxKernel_neon.cpp`
5. 在 `SimdAPI.cpp` 中添加 dispatch（switch + 前向声明）
6. 在 `SimdAPI.h` 中 `#include` 新 kernel 头文件
7. 在 `CMakeLists.txt` 的两个平台 if 块中追加源文件

## 调用方集成

```cpp
// YuvAnalyzer.cpp 中
#include "SimdAPI.h"

// 直方图 + 统计
simd::HistInput in;
in.data = planeData;
in.width = pw;
in.height = ph;
in.stride = stride;
in.bytesPerSample = isHighDepth ? 2 : 1;
in.binCount = isHighDepth ? 1024 : 256;
in.isInterleavedUV = isNV12 && plane >= 1;
in.uvOffset = (plane == 1) ? 0 : 1;

simd::HistOutput out;
simd::computeHistogram(in, out);

// 梯度 + Laplacian + Tenengrad
simd::GradInput gin;
gin.data = planeData;
gin.width = pw;
gin.height = ph;
gin.stride = stride;
gin.bytesPerSample = isHighDepth ? 2 : 1;

simd::GradOutput gout;
simd::computeGradient(gin, gout);
```

## CMakeLists.txt 配置

```cmake
# 标量参考实现（所有平台恒编译）
src/simd/common/HistKernel_scalar.cpp
src/simd/common/GradKernel_scalar.cpp

# Windows x86-64 / macOS x86_64 → AVX2
if(CMAKE_SYSTEM_NAME STREQUAL "Windows" OR
   (CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND CMAKE_SYSTEM_PROCESSOR MATCHES "(x86_64|AMD64)"))
    target_sources(PlayerX PRIVATE
        src/simd/common/HistKernel_avx2.cpp
        src/simd/common/GradKernel_avx2.cpp
    )
    set_source_files_properties(
        src/simd/common/HistKernel_avx2.cpp
        src/simd/common/GradKernel_avx2.cpp
        PROPERTIES COMPILE_OPTIONS "-mavx2;-mfma")
endif()

# macOS ARM64 → NEON
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND CMAKE_SYSTEM_PROCESSOR MATCHES "(aarch64|arm64|ARM64)")
    target_sources(PlayerX PRIVATE
        src/simd/common/HistKernel_neon.cpp
        src/simd/common/GradKernel_neon.cpp
    )
    # NEON 在 ARM64 上默认开启，无需额外 flag
endif()
```
