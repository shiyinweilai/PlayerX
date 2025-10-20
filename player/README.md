# PlayerX - VideoCompare Player

一个基于SDL3的图形界面应用程序，用于选择并比较两个视频文件，使用video-compare作为后端播放器。

## 功能特性

- 🖼️ 基于SDL3的现代图形界面
- 📁 支持文件浏览器，自动扫描视频文件
- 🎬 集成video-compare视频比较工具
- 🖱️ 鼠标操作，简单易用
- 🎨 美观的UI设计
- 🔧 支持多种视频格式

## 支持的视频格式

- MP4 (.mp4)
- AVI (.avi)
- MKV (.mkv)
- MOV (.mov)
- WMV (.wmv)
- FLV (.flv)
- WebM (.webm)
- M4V (.m4v)
- 3GP (.3gp)
- MPEG (.mpeg, .mpg)
- TS (.ts, .mts, .m2ts)
- 以及其他常见视频格式

## 系统要求

### 依赖项

- CMake 3.15+
- C++14兼容编译器 (GCC 7+, Clang 5+, MSVC 2017+)
- SDL3库
- SDL3_ttf库
- video-compare项目

### 平台支持

- Linux
- macOS
- Windows (需要额外配置)

## 快速开始

### 1. 构建依赖项

首先确保SDL3和SDL3_ttf库已构建：

```bash
cd /Users/rbyang/Documents/UGit/private/PlayerX
./build_tools.py  # 构建SDL库
```

### 2. 构建PlayerX

```bash
cd player
chmod +x build.sh
./build.sh build
```

### 3. 运行程序

```bash
./build.sh run
```

## 详细构建说明

### 手动构建

如果您想手动构建项目：

```bash
# 创建构建目录
mkdir -p build/player
cd build/player

# 配置项目
cmake ../../player \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="../sdl/install;../sdl3_ttf/install" \
    -DCMAKE_INSTALL_PREFIX="install"

# 编译
make -j$(nproc)

# 安装
make install

# 运行
cd install/bin
./playerx
```

### 构建选项

- `./build.sh build` - 构建所有组件
- `./build.sh build-vc` - 仅构建video-compare
- `./build.sh build-player` - 仅构建player
- `./build.sh run` - 运行程序
- `./build.sh clean` - 清理构建文件
- `./build.sh help` - 显示帮助信息

## 使用方法

### 界面说明

1. **标题栏** - 显示程序名称
2. **当前目录** - 显示当前浏览的目录路径
3. **文件列表** - 显示当前目录下的视频文件
4. **选择状态** - 显示已选中的文件
5. **操作按钮** - Compare（比较）和Exit（退出）

### 操作指南

1. **选择文件**：
   - 点击文件列表中的视频文件进行选择
   - 需要选择两个不同的文件进行比较
   - 再次点击已选文件可取消选择

2. **比较视频**：
   - 选择两个文件后，Compare按钮将变为可用
   - 点击Compare按钮启动video-compare进行比较
   - 在video-compare中可以使用各种控制键进行操作

3. **退出程序**：
   - 点击Exit按钮或按ESC键退出程序

### video-compare控制键

当启动video-compare后，可以使用以下控制键：

- `空格键` - 播放/暂停
- `左/右箭头` - 快退/快进
- `上/下箭头` - 音量控制
- `F` - 全屏切换
- `ESC` - 退出video-compare
- `H` - 显示帮助信息

## 项目结构

```
player/
├── CMakeLists.txt          # CMake构建配置
├── build.sh                # 构建脚本
├── README.md               # 项目说明
└── src/
    └── playerx.cpp         # 主程序源代码
```

## 故障排除

### 常见问题

1. **SDL库未找到**
   ```
   错误：SDL库未找到，请先构建SDL库
   运行：cd /Users/rbyang/Documents/UGit/private/PlayerX && ./build_tools.py
   ```

2. **video-compare未找到**
   ```
   警告：video-compare可执行文件未找到，某些功能可能不可用
   ```
   确保video-compare项目已正确构建。

3. **字体加载失败**
   如果系统缺少Arial字体，程序将尝试使用默认字体。

### 调试信息

程序会在控制台输出调试信息，包括：
- 加载的目录路径
- 发现的视频文件数量
- 运行的video-compare命令
- 错误信息

## 开发说明

### 代码结构

- `main()` - 程序入口点，初始化SDL和主循环
- `init_sdl()` - 初始化SDL窗口、渲染器和字体
- `render()` - 渲染UI界面
- `handle_click()` - 处理鼠标点击事件
- `run_video_compare()` - 调用video-compare可执行文件

### 扩展功能

可以轻松扩展以下功能：

1. **文件导航**：添加目录浏览功能
2. **缩略图**：为视频文件生成缩略图
3. **播放列表**：支持播放列表管理
4. **设置界面**：添加配置选项
5. **主题切换**：支持不同的UI主题

## 许可证

本项目基于MIT许可证开源。

## 贡献

欢迎提交Issue和Pull Request来改进这个项目。

## 联系方式

如有问题或建议，请通过项目仓库提交Issue。