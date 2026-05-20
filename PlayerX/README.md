# PlayerX

基于 **Qt 6 + QML + FFmpeg** 的视频播放器（旧 SDL 版 PlayerX 的 Qt 重构版本）。

> 本工程已自包含：所有第三方依赖通过 `third_party/` 子模块管理，
> 编译脚本位于 `scripts/`，独立克隆即可构建，不依赖外部仓库。

## 目录结构

```
PlayerX/
├── CMakeLists.txt          # CMake 主脚本
├── build.py                # 主构建脚本（macOS 原生 / 交叉编译 Windows）
├── README.md               # 本文档
├── src/
│   ├── main.cpp            # Qt 应用入口
│   ├── core/               # 解复用 / 解码 / 帧队列（纯 FFmpeg+STL）
│   ├── player/             # RBVideoPlayer 播放器封装
│   └── qt/                 # Qt 桥接层（QQuickItem 把内核暴露给 QML）
├── qml/                    # QML 界面
├── resources/              # 图标 / qrc
├── installer/              # Windows NSIS 打包脚本
├── release/                # 发布元信息（latest.json 等）
│
├── third_party/            # 第三方依赖（git submodule）
│   └── ffmpeg/             # FFmpeg 源码
│
└── scripts/                # 依赖构建脚本
    ├── build_deps.py       # 总入口（编译所有依赖）
    └── build_ffmpeg.py     # FFmpeg 单独构建脚本
```

## 环境依赖一览

下表覆盖**从零开始、独立克隆本仓库**所需的全部外部依赖。FFmpeg 已通过 `third_party/` 子模块自包含，无需手动安装。

### macOS 主机（构建 macOS 版）

| 依赖 | 用途 | 安装方式 | 检测/覆盖 |
|---|---|---|---|
| Xcode Command Line Tools | clang / `codesign` / `sips` / `iconutil` / `ditto` | `xcode-select --install` | 缺失会在 `cmake` 阶段直接报错 |
| Python 3.8+ | 构建脚本运行时 | macOS 自带 `python3` 即可 | — |
| **Qt 6**（≥ 6.5） | 主要 GUI/QML 框架 | `brew install qt`（推荐）或[官方安装器](https://www.qt.io/download-qt-installer) | 探测顺序：`QT6_DIR` / `QT_DIR` → `brew --prefix qt@6\|qt6\|qt` → `~/Qt/6.x.y/macos` |
| CMake ≥ 3.21 | 构建系统 | `brew install cmake` | — |
| Ninja（推荐） | 加速 CMake 构建 | `brew install ninja` | 缺失则回退到 Unix Makefiles |
| FFmpeg 编译依赖：`pkg-config`、`nasm`、`yasm` | 编译 FFmpeg 子模块 | `brew install pkg-config nasm yasm` | 缺失会在 `scripts/build_ffmpeg.py` 阶段报错 |
| Git ≥ 2.20 | 拉取 submodule | macOS 自带；如缺失 `brew install git` | — |

### macOS 主机额外依赖（交叉编译 Windows 版）

只有在跑 `python3 build.py -p windows` 时才需要这些；如只构建 macOS 版可全部跳过。

| 依赖 | 用途 | 安装方式 | 环境变量覆盖 |
|---|---|---|---|
| **llvm-mingw**（UCRT，macOS universal） | clang + libc++ 跨平台 PE 工具链；与 Qt llvm-mingw 包 ABI 一致 | <pre>mkdir -p ~/Qt/llvm-mingw-tools && cd ~/Qt/llvm-mingw-tools \\<br>  && curl -LO https://github.com/mstorsjo/llvm-mingw/releases/download/20260505/llvm-mingw-20260505-ucrt-macos-universal.tar.xz \\<br>  && tar -xf llvm-mingw-20260505-ucrt-macos-universal.tar.xz</pre> | `LLVM_MINGW_DIR` |
| **Qt 6 win64_llvm_mingw**（UCRT + libc++） | Windows 版链接库 + QML 模块来源 | <pre>pip3 install --user aqtinstall<br>~/.local/bin/aqt install-qt --outputdir ~/Qt windows desktop 6.9.3 win64_llvm_mingw</pre> | `QT6_WIN_DIR` |
| **OpenSSL v3 for Windows** | HTTPS / 自动更新所需的 TLS 后端 DLL | `~/.local/bin/aqt install-tool --outputdir ~/Qt windows desktop tools_opensslv3_x64` | `OPENSSL_WIN_DIR` |
| **NSIS** (`makensis`) | 生成 `PlayerX-Setup-x.y.z.exe` 安装包 | `brew install makensis` | — |

> ⚠ **不要用 `brew install mingw-w64`**——它是 GCC + libstdc++（MSVCRT），与 Qt `win64_llvm_mingw`（clang + libc++ + UCRT）的 STL ABI 不兼容，链接 Qt 必失败。一定要用 [llvm-mingw](https://github.com/mstorsjo/llvm-mingw)。

### Windows 主机能否反向编译 macOS 版？

**不能**。Apple 的 SDK 与签名工具链（`codesign` / `iconutil` / `sips` / `macdeployqt` / `ditto`）都是 macOS 独占，且 Apple SDK 的 EULA 也不允许在非 Apple 设备上分发。这是业界通例（VS Code、Slack、Electron 等都遵循同样规则）。

跨平台支持矩阵：

| Host \\ Target | macOS | Windows |
|---|:---:|:---:|
| **macOS**（你目前的环境） | ✅ 原生 | ✅ 交叉（llvm-mingw + Qt llvm-mingw + aqt） |
| **Windows** | ❌ 不支持 | ✅ 原生（需自行调整 build.py，目前主流程按 macOS 主机调试） |
| **Linux** | ❌ 不支持 | ✅（理论可行，未验证） |

**正确做法**：macOS 版必须在一台 Mac 上构建（自己开发机 / Mac mini / GitHub Actions `macos-latest` runner 三选一）。

---

## 构建

### 1. 安装 Qt 6

推荐用 Homebrew 安装：

```bash
brew install qt@6
```

或从 [Qt 官方安装器](https://www.qt.io/download-qt-installer) 安装 Qt 6.5+。

构建脚本会按以下顺序自动探测 Qt 路径：

1. 环境变量 `QT6_DIR` / `QT_DIR`
2. `brew --prefix qt@6` / `brew --prefix qt6` / `brew --prefix qt`
3. `~/Qt/<version>/macos`、`/opt/Qt/...`、`/Applications/Qt/...`

如果都找不到，可显式指定：

```bash
export QT6_DIR=/opt/homebrew/opt/qt@6
python3 build.py
```

### 2. 准备 FFmpeg

PlayerX 自带 FFmpeg 子模块和构建脚本，**首次构建**只需两步：

```bash
# 1) 拉取 FFmpeg 源码（仅首次需要）
git submodule update --init --recursive

# 2) 编译所有第三方依赖（默认会跳过已构建的依赖）
python3 scripts/build_deps.py -p macos       # macOS
python3 scripts/build_deps.py -p windows     # Windows 交叉编译
```

构建产物输出到 `build/third_party/ffmpeg/install[_win]/`，
后续 `build.py` 会自动找到，无需手工指定路径。

> 如果你希望使用**外部预编译**的 FFmpeg，可设置环境变量绕过内置构建：
> ```bash
> export FFMPEG_INSTALL_DIR=/path/to/ffmpeg/install
> ```
> 优先级：环境变量 > `build/third_party/ffmpeg/install` > 旧仓库结构兼容路径。

也支持单独重编 FFmpeg：

```bash
python3 scripts/build_ffmpeg.py -p macos --clean
```

### 3. 构建

构建脚本区分两种典型场景：**①开发自测**（追求快，依赖本机 Qt）和 **②分发打包**（产物自包含，可发给别人）。

#### 3.1 日常开发自测（推荐，秒级完成）

```bash
python3 build.py            # Release 构建
python3 build.py --debug    # Debug 构建
python3 build.py --clean    # 清理后重新构建
```

默认模式下会**跳过 `macdeployqt`**，生成的 `.app` 直接依赖本机 brew Qt 运行，因此增量编译通常 2~3 秒就能跑完，适合反复改代码自测。

构建产物：

- `build/out/bin/PlayerX.app`（macOS）
- `build/install/PlayerX.app`（cmake install 后的副本，发布前的中间产物）

启动：

```bash
open build/out/bin/PlayerX.app
```

> ⚠ 这种产物**只能在装了相同 Qt 的开发机上跑**，拷给别人会因找不到 Qt 框架而启动失败。

#### 3.2 分发打包（自包含，可发给别人）

```bash
python3 build.py --package              # 编译 + 内嵌 Qt + 打 zip
python3 build.py --package-only         # 跳过编译，仅基于现有产物重打包
python3 build.py --bump 2.0.18 --package  # 升版本号后再打包
python3 build.py --bump 2.0.18 -f --package  # 同版本号重打包（覆盖）
```

打包流程会自动运行 `macdeployqt` 把 Qt framework 内嵌进 `.app`，并把 FFmpeg dylib、QML 模块一并打入 `.app/Contents/Frameworks`，最终输出 zip 到 `build/dist/`。耗时通常 30 秒~2 分钟。

#### 3.3 其它开关

| 开关                           | 作用                                                                             |
| ------------------------------ | -------------------------------------------------------------------------------- |
| `--deploy`                   | 不打 zip，但强制运行 `macdeployqt` 内嵌 Qt（用于本机模拟分发版本）             |
| `--no-deploy`                | 即使带了 `--package` 也跳过 `macdeployqt`（应急自用，会有警告，⚠ 勿对外发） |
| `--clean` / `--clean-only` | 清理后重建 / 仅清理                                                              |
| `--bump X.Y.Z`               | 打包前先把 `CMakeLists.txt` 里的版本号改成 `X.Y.Z`（默认要求严格递增）       |
| `-f` / `--force`           | 配合 `--bump` 允许相同或更低版本号（同版本重打包专用）                         |

行为速查：

| 命令                                       | 跑 `macdeployqt` | 适用场景                            |
| ------------------------------------------ | :----------------: | ----------------------------------- |
| `python3 build.py`                       |         ❌         | 日常本地编译自测                    |
| `python3 build.py --package`             |         ✅         | 给别人发版（自包含 zip）            |
| `python3 build.py --deploy`              |         ✅         | 不出 zip 也想模拟分发版本           |
| `python3 build.py --package --no-deploy` |         ❌         | 应急：自己机器上"假打包"，⚠ 勿外发 |
| `python3 build.py --package-only`        |         ✅         | 只重打包（自动补一次 deploy）       |
