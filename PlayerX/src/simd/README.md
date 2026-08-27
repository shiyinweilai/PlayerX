# SIMD 加速层

## 架构概览

```
simd/
├── SimdConfig.h          编译期架构宏（RB_SIMD_X86 / RB_SIMD_ARM）
├── SimdCaps.h/.cpp       运行时 ISA 检测（AVX2 / NEON / Scalar）
├── SimdAPI.h/.cpp        统一入口 + 运行时 dispatch
├── common/               跨模块共享 kernel
│   └── HistKernel.*      直方图 + 均值/方差/极值
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
     └─ 老旧 x86 (无 AVX2)    → Scalar（纯 C 兜底）
```

调用方只需调用 `simd::computeHistogram(in, out)`，内部自动路由。

## ISA 策略

按用户要求简化，不考虑老旧机器：

| 平台       | 最优 ISA | 老旧机器回退 |
|------------|----------|-------------|
| ARM64 Mac  | NEON     | N/A（强制标配）|
| x86-64 Win | AVX2     | Scalar      |

## 已实现 kernel

### HistKernel（common/）

单次遍历计算：256/1024 桶直方图 + sum/sumSq/min/max → 均值/方差/标准差。

**输入** `HistInput`：平面数据指针 + 宽高/stride/位深/交错标志
**输出** `HistOutput`：bins 数组 + 统计量

**优化策略**：sum/sumSq/min/max 用 SIMD 并行，bins 标量收集（scatter 难以向量化）。

| ISA     | 处理粒度 | 实测加速比 (1080p Y) |
|---------|---------|---------------------|
| Scalar  | 1 像素  | 1× (基准 ~2ms)      |
| AVX2    | 32 像素 | ~4× (~0.5ms)        |
| NEON    | 16 像素 | ~5× (~0.4ms)        |

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

// 原来：手写 for 循环
// 改为：
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

// 填充 PlaneHistogram
hist.bins = std::move(out.bins);
hist.mean = out.mean;
hist.stddev = out.stddev;
// ...
```
