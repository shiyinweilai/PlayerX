# PlayerX

基于 **Qt 6 + QML + FFmpeg** 的视频播放器（旧 SDL 版 PlayerX 的 Qt 重构版本）。

> 本目录可独立从仓库中抽出，不依赖其它兄弟目录的源代码。
> 构建期会复用 `../build/ffmpeg/install` 的 FFmpeg 静态库；解耦时只需把对应 install 目录拷到自己的位置即可。

## 目录结构

```
PlayerX/
├── CMakeLists.txt          # CMake 主脚本
├── build.py                # 构建脚本（macOS 原生）
├── README.md               # 本文档
├── src/
│   ├── main.cpp            # Qt 应用入口
│   ├── core/               # 解复用 / 解码 / 帧队列（与旧版同源，纯 FFmpeg+STL）
│   ├── player/             # RBVideoPlayer 播放器封装（与旧版同源）
│   └── qt/                 # Qt 桥接层（QQuickItem 把内核暴露给 QML）
└── qml/
    └── Main.qml            # 主界面
```

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

第 1 阶段直接复用上层旧 build 系统已构建的 FFmpeg。在仓库根 `PlayerX/build/` 下运行过：
```bash
python3 main.py -p macos
```
即可生成 `PlayerX/build/ffmpeg/install/` 供本工程使用。

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

| 开关 | 作用 |
|---|---|
| `--deploy` | 不打 zip，但强制运行 `macdeployqt` 内嵌 Qt（用于本机模拟分发版本） |
| `--no-deploy` | 即使带了 `--package` 也跳过 `macdeployqt`（应急自用，会有警告，⚠ 勿对外发） |
| `--clean` / `--clean-only` | 清理后重建 / 仅清理 |
| `--bump X.Y.Z` | 打包前先把 `CMakeLists.txt` 里的版本号改成 `X.Y.Z`（默认要求严格递增） |
| `-f` / `--force` | 配合 `--bump` 允许相同或更低版本号（同版本重打包专用） |

行为速查：

| 命令 | 跑 `macdeployqt` | 适用场景 |
|---|:---:|---|
| `python3 build.py` | ❌ | 日常本地编译自测 |
| `python3 build.py --package` | ✅ | 给别人发版（自包含 zip） |
| `python3 build.py --deploy` | ✅ | 不出 zip 也想模拟分发版本 |
| `python3 build.py --package --no-deploy` | ❌ | 应急：自己机器上"假打包"，⚠ 勿外发 |
| `python3 build.py --package-only` | ✅ | 只重打包（自动补一次 deploy） |

## 当前进度

第 1 阶段（验证内核打通）：
- [x] Qt + QML 工程骨架
- [x] RBVideoPlayer 桥接为 QML `VideoFrameProvider`
- [x] 极简 UI：打开 / 播放暂停 / 帧步进 / 进度条
- [x] 快捷键：空格、←/→、,/. 、F
- [ ] 多窗口（多个 VideoCell）
- [ ] 同步 slider
- [ ] UI 美化
- [ ] Windows 交叉编译
- [ ] 发布产物（.dmg / .exe 安装包）
