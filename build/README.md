# 统一构建工具使用说明

## 概述

`build_tools.py` 是一个简化的统一构建工具脚本。

## 主要改进

1. **参数统一**: 统一使用 `--source` 参数指定源码目录
2. **自动目录生成**: 输出目录基于源码目录名自动生成
3. **简化接口**: 更简洁的命令行参数设计

## 使用方法

### 构建FFmpeg
``` bash
python build_tools.py -s ../ffmpeg --target ffmpeg
```
### 构建sdl
- [sdl下载源码](https://github.com/libsdl-org/SDL_ttf/releases)
``` bash
python build_tools.py -s ../sdl_ttf --target sdl_ttf
```
### 构建video-compare
``` bash
python build_tools.py -s ../video-compare --target video_compare
```