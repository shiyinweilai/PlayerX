# Video Compare - 跨平台视频比较工具

一个基于 Electron 的跨平台 GUI 应用程序，用于比较两个视频文件。

## 功能特性

- 🖥️ 跨平台支持：Windows、macOS、Linux
- 🎬 视频文件比较：支持 MP4、MKV、AVI、MOV 等格式
- 🎯 简洁界面：左右分栏布局，直观易用
- ⚡ 快速启动：调用原生视频比较工具

## 安装依赖

```bash
npm install
```

## 开发模式运行

```bash
npm start
```

## 打包发布

### 自动检测平台打包
```bash
npm run pack
```

### 指定平台打包
```bash
# Windows
npm run pack:win

# macOS
npm run pack:mac

# Linux
npm run pack:linux
```

### 直接使用 electron-builder
```bash
npm run build
```

## 跨平台支持说明

### Windows 平台
- 将 `video-compare.exe` 和相关 DLL 文件放入 `win-inner` 目录
- 打包后生成 NSIS 安装包

### macOS 平台
- 将 macOS 版本的视频比较工具放入 `mac-inner` 目录
- 可执行文件命名为 `video-compare`
- 打包后生成 DMG 镜像文件

### Linux 平台
- 将 Linux 版本的视频比较工具放入 `linux-inner` 目录
- 可执行文件命名为 `video-compare`
- 打包后生成 AppImage 文件

## 目录结构

```
app/
├── main.js              # 主进程文件
├── index.html           # 渲染进程界面
├── preload.js           # 预加载脚本
├── pack.js              # 打包脚本
├── package.json         # 项目配置
├── win-inner/           # Windows 平台可执行文件
├── mac-inner/           # macOS 平台可执行文件（待创建）
└── linux-inner/         # Linux 平台可执行文件（待创建）
```

## 使用说明

1. 启动应用程序
2. 在左侧选择第一个视频文件
3. 在右侧选择第二个视频文件
4. 点击"比较视频"按钮启动外部视频比较工具

## 注意事项

- 确保对应平台的可执行文件和相关依赖已放入正确的目录
- 打包前会自动检查必要文件是否存在
- 如果缺少必要文件，打包过程会中止并提示缺失文件列表

## 开发环境要求

- Node.js 16+
- npm 或 yarn
- Electron 38.3.0+

## 许可证

ISC License
