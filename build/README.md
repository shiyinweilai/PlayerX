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

``` bash
export PATH="/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64:$PATH"
call "C:/Program Files/Microsoft Visual Studio/2022/Enterprise/Common7/Tools/VsDevCmd.bat" -arch=amd64
"D:/software/Git/bin/bash.exe" --login -i  或 "D:/software/mysys2/msys2_shell.cmd"

D:/UGit/private/PlayerX/ffmpeg
./configure --prefix=/mnt/d/UGit/private/PlayerX/build/ffmpeg/install --enable-gpl --enable-version3 --enable-shared --disable-static --toolchain=msvc --disable-x86asm
make -j 32 --prefix=/mnt/d/UGit/private/PlayerX/build/ffmpeg/install/obj

#windows
./configure --enable-gpl --enable-version3 --enable-shared --disable-static --toolchain=msvc --disable-x86asm 
make -j 32 
```

D:/UGit/private/PlayerX/build/video_compare/install_win/bin/video-compare.exe "C:/Users/rbyang/Videos/video.mp4" "C:/Users/rbyang/Videos/video.mp4"

D:/UGit/private/PlayerX/build/ffmpeg/install_win/bin/ffprobe.exe C:/Users/rbyang/Videos/video.mp4