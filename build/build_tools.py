#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse
import os
import subprocess
import sys
import shutil
import deps_manager  # 导入新的依赖管理模块
import datetime


def run(cmd, cwd=None, capture_output=True, log_file=None):
    """运行命令并可选地记录日志"""
    print(f"\033[33m>>>\033[0m {' '.join(cmd)}  (cwd={cwd or os.getcwd()})\n")
    
    # 如果指定了日志文件，则记录命令和输出
    if log_file:
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(f"=== {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ===\n")
            f.write(f"Command: {' '.join(cmd)}\n")
            f.write(f"Working directory: {cwd or os.getcwd()}\n")
            f.write("-" * 80 + "\n")
    
    result = subprocess.run(cmd, cwd=cwd, capture_output=capture_output, text=True, encoding='utf-8', errors='replace')
    
    # 记录输出到日志文件
    if log_file and capture_output:
        with open(log_file, 'a', encoding='utf-8') as f:
            if result.stdout:
                f.write("STDOUT:\n")
                f.write(result.stdout)
                f.write("\n")
            if result.stderr:
                f.write("STDERR:\n")
                f.write(result.stderr)
                f.write("\n")
            f.write("=" * 80 + "\n\n")
    
    if result.returncode != 0:
        print(f"\033[31m!!! 命令执行失败: {' '.join(cmd)}\033[0m")
        if capture_output:
            print(f"\033[31m错误输出:\n{result.stderr}\033[0m")
            print(f"日志文件: {log_file}\033[0m")
        sys.exit(1)
    return result


def get_absolute_path(path):
    if os.path.isabs(path):
        return path
    return os.path.abspath(path)


def make(cmake_args, log_file=None):
    try:
        run(cmake_args, cwd=build_dir, log_file=log_file)
        run(['make', '-j', str(os.cpu_count() or 1)], cwd=build_dir, log_file=log_file)
        run(['make', 'install'], cwd=build_dir, log_file=log_file)
    except SystemExit:
        sys.exit(1)


def build_ffmpeg(args, log_file=None):
    configure = os.path.join(source_dir, 'configure')
    cmake_args = [configure, f'--prefix={install_dir}']
    if args.mode == 'shared':
        cmake_args += ['--enable-shared', '--disable-static']
    elif args.mode == 'static':
        cmake_args += ['--disable-shared', '--enable-static']
    else:
        cmake_args += ['--enable-shared', '--enable-static']
    if args.platform == 'windows':
        cmake_args += [
            '--enable-cross-compile',
            '--target-os=mingw32',
            '--arch=x86_64',
            '--cross-prefix=x86_64-w64-mingw32-',
        ]
        # 在 Windows 下禁用会引入额外系统库依赖的特性，避免后续链接 video-compare 时出现未解析符号
        # - mediafoundation: 避免 mfenc.o 需要 IID_ICodecAPI/mfplat/mfuuid/strmiids
        # - schannel 以及 tls/https 协议：避免 ncrypt/crypt32/Cert* 等依赖
        cmake_args += [
            '--disable-mediafoundation',
            '--disable-schannel',
            '--disable-protocol=tls',
            '--disable-protocol=https',
            '--disable-dxva2',
            '--disable-d3d11va',
            '--disable-indev=dshow',
            '--disable-outdev=sdl',
        ]
        # 静态库优先：附加静态相关标志（尽量少改动）
        if args.mode == 'static':
            cmake_args += [
                '--pkg-config-flags=--static',
                '--extra-ldflags=-static -static-libgcc -static-libstdc++',
            ]
    make(cmake_args, log_file)


def build_sdl(args, log_file=None):
    cmake_args = [
        'cmake', source_dir,
        f'-B{build_dir}',
        f'-DCMAKE_BUILD_TYPE=Release',
        f'-DCMAKE_INSTALL_PREFIX={install_dir}',
    ]

    if args.platform == 'windows':
        cmake_args += [
            '-DCMAKE_SYSTEM_NAME=Windows',
            '-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc',
            '-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++',
        ]
        if args.mode == 'static':
            cmake_args += [
                '-DBUILD_SHARED_LIBS=OFF',
                '-DCMAKE_FIND_LIBRARY_SUFFIXES=.a',
            ]

    if args.target == 'sdl2_ttf':
        subprocess.run(["git", "checkout", "release-2.24.x"], cwd=f"{script_dir}/../sdl_ttf", check=True)
        freetype_install_dir = deps_manager.setup_sdl_ttf_dependencies(source_dir, script_dir)
        # 为交叉编译选择正确的 SDL2 前缀路径
        sdl2_install_dir = os.path.join(script_dir, 'sdl2/install')
        if args.platform == 'windows':
            sdl2_install_dir = os.path.join(script_dir, 'sdl2/install_win')
        cmake_args += [
            f'-DSDL2TTF_SAMPLES=OFF',
            f'-DSDL2TTF_INSTALL=ON',
            f'-DSDL2TTF_VENDORED=ON',
            f'-DSDL2TTF_HARFBUZZ=ON',
            f'-DCMAKE_PREFIX_PATH={sdl2_install_dir};{freetype_install_dir}'
        ]
        if args.platform == 'windows':
            cmake_args += ['-DSDL2TTF_HARFBUZZ=OFF']
            cmake_args += ['-DCMAKE_FIND_LIBRARY_SUFFIXES=.a']

    if args.target == 'sdl3_ttf':
        subprocess.run(["git", "checkout", "release-3.2.x"], cwd=f"{script_dir}/../sdl_ttf", check=True)
        sdl_install_dir = os.path.join(script_dir, 'sdl3/install')
        cmake_args += [
            f'-DSDL3TTF_SAMPLES=OFF',
            f'-DSDL3TTF_INSTALL=ON',
            f'-DSDL3TTF_VENDORED=ON',
            f'-DSDL3TTF_HARFBUZZ=ON',
            f'-DCMAKE_PREFIX_PATH={sdl_install_dir}'
        ]
        if args.platform == 'windows':
            cmake_args += ['-DSDL3TTF_HARFBUZZ=OFF']

    if args.target == 'sdl2':
        subprocess.run(["git", "checkout", "release-2.28.x"], cwd=f"{script_dir}/../sdl", check=True)
    if args.target == 'sdl3':
        subprocess.run(["git", "checkout", "release-3.2.x"], cwd=f"{script_dir}/../sdl", check=True)

    if args.mode == 'static':
        cmake_args += ['-DBUILD_SHARED_LIBS=OFF']
    elif args.mode == 'both':
        cmake_args += ['-DBUILD_SHARED_LIBS=ON']

    make(cmake_args, log_file)


def build_video_compare(args, log_file=None):
    shutil.copy(f"{script_dir}/config/CMakeLists.txt", f"{source_dir}/CMakeLists.txt")
    shutil.copy(f"{script_dir}/config/display.cpp", f"{source_dir}/display.cpp")
    ffmpeg_install_dir = os.path.join(script_dir, 'ffmpeg/install')
    sdl_ttf_install_dir = os.path.join(script_dir, 'sdl2_ttf/install')
    sdl_install_dir = os.path.join(script_dir, 'sdl2/install')
    if args.platform == 'windows':
        ffmpeg_install_dir = os.path.join(script_dir, 'ffmpeg/install_win')
        # 在 Windows 交叉编译时，确保 SDL2/SDL2_ttf 指向 install_win 目录
        sdl_ttf_install_dir = os.path.join(script_dir, 'sdl2_ttf/install_win')
        sdl_install_dir = os.path.join(script_dir, 'sdl2/install_win')
    cmake_args = [
        'cmake', source_dir,
        f'-B{build_dir}',
        f'-DCMAKE_BUILD_TYPE=Release',
        f'-DCMAKE_INSTALL_PREFIX={install_dir}',
        f"-DFFMPEG_INSTALL_DIR={ffmpeg_install_dir}",
        f"-DSDL_TTF_INSTALL_DIR={sdl_ttf_install_dir}",
        f"-DSDL_INSTALL_DIR={sdl_install_dir}",
    ]
    # Windows 静态链接：为可执行程序添加最小静态标志（不改源码）
    if args.platform == 'windows' and args.mode == 'static':
        cmake_args += [
            '-DCMAKE_SYSTEM_NAME=Windows',
            '-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc',
            '-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++',
            '-DCMAKE_FIND_LIBRARY_SUFFIXES=.a',
            '-DCMAKE_EXE_LINKER_FLAGS=-static -static-libgcc -static-libstdc++'
        ]
    # macOS：传入SDK路径与部署目标，确保框架解析正常
    if args.platform == 'macos':
        try:
            sdk_path = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            if sdk_path:
                cmake_args += [f'-DCMAKE_OSX_SYSROOT={sdk_path}']
        except Exception:
            pass
        # 设定一个合理的部署目标，避免不同库编译目标版本不一致导致的链接问题
        cmake_args += ['-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0']
        # 默认开启输入相关能力屏蔽，减少对旧框架的依赖
        cmake_args += ['-DVC_DISABLE_INPUT_FEATURES=ON']
        # 精简符号，尽可能去除未使用引用
        cmake_args += ['-DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip']
    make(cmake_args, log_file)
    subprocess.run("git restore . && git clean -fdx", check=True, cwd=source_dir, shell=True)

def main():
    log_filename = f"build_{args.target}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    log_file = os.path.join(build_dir, log_filename)
    print(f"\033[34m>>>> 开始构建: {args.target}...\033[0m")
    os.makedirs(os.path.dirname(log_file), exist_ok=True)
    
    if args.target == 'ffmpeg':
        build_ffmpeg(args, log_file)
    elif args.target == 'sdl2' or args.target == 'sdl3' or args.target == 'sdl2_ttf' or args.target == 'sdl3_ttf':
        build_sdl(args, log_file)
    elif args.target == 'video_compare':
        build_video_compare(args, log_file)
    else:
        print("\033[31m错误: 未指定有效的构建目标\033[0m")
        sys.exit(1)
    print("\033[32m构建完成!\033[0m")
    print(f"\033[32m安装目录: {install_dir}\033[0m")
    print(f"\033[32m日志文件: {log_file}\033[0m")


def init():
    for directory in [build_dir, install_dir]:
        if os.path.exists(directory):
            shutil.rmtree(directory)
    os.makedirs(build_dir, exist_ok=True)
    os.makedirs(install_dir, exist_ok=True)
    return build_dir, install_dir


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="简化的统一构建工具")
    parser.add_argument('--target', choices=['ffmpeg', 'sdl2', 'sdl3',
                        'sdl2_ttf', 'sdl3_ttf', 'video_compare'], help='构建目标')
    parser.add_argument('-s', '--source', required=True, help='源码目录路径')
    parser.add_argument('-m', '--mode', default='shared', choices=['shared', 'static', 'both'], help='构建模式')
    parser.add_argument('-p', '--platform', default='host', choices=['windows', 'macos'], help='目标平台')
    args = parser.parse_args()
    source_dir = get_absolute_path(args.source)
    script_dir = os.path.dirname(__file__)
    build_dir = f"{script_dir}/{args.target}/obj"
    install_dir = f"{script_dir}/{args.target}/install"
    if args.platform == 'windows':
        build_dir = f"{build_dir}_win"
        install_dir = f"{install_dir}_win"
    init()
    main()
