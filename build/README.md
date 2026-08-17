# FFmpeg 构建工具

## 使用方法

```bash
# macOS 静态库（默认）
python3 build_ffmpeg.py -p macos

# macOS 动态库
python3 build_ffmpeg.py -p macos -m shared

# Windows 交叉编译静态库
python3 build_ffmpeg.py -p windows

# 指定自定义源码路径
python3 build_ffmpeg.py -p macos -s /path/to/ffmpeg
```

## 产物目录

- macOS: `build/ffmpeg/install/`
- Windows: `build/ffmpeg/install_win/`
