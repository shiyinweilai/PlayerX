# PlayerXQt

基于 **Qt 6 + QML + FFmpeg** 的视频播放器（PlayerX 的 Qt 重构版本）。

> 本目录可独立从仓库中抽出，不依赖 PlayerX/ 与 video-compare/ 等任何兄弟目录的源代码。
> 构建期会复用 `../build/ffmpeg/install` 的 FFmpeg 静态库；解耦时只需把对应 install 目录拷到自己的位置即可。

## 目录结构

```
PlayerXQt/
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

```bash
python3 build.py            # Release 构建
python3 build.py --debug    # Debug 构建
python3 build.py --clean    # 清理后重新构建
```

构建产物：
- `build/out/bin/PlayerXQt.app`（macOS）

启动：
```bash
open build/out/bin/PlayerXQt.app
```

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
