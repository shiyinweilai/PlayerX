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
        if os.name == 'nt':  # Windows系统
            run(['cmake', '--build', build_dir, '--config', 'Release', '-j', str(os.cpu_count() or 1)], cwd=build_dir, log_file=log_file)
            run(['cmake', '--build', build_dir, '--config', 'Release', '--target', 'install'], cwd=build_dir, log_file=log_file)
        else:  # Unix-like系统
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
            '--target-os=mingw32',
            '--arch=x86_64',
            '--cross-prefix=x86_64-w64-mingw32-',
        ]
    make(cmake_args, log_file)


def build_sdl(args, log_file=None):
    cmake_args = [
        'cmake', source_dir,
        f'-B{build_dir}',
        f'-DCMAKE_BUILD_TYPE=Release',
        f'-DCMAKE_INSTALL_PREFIX={install_dir}',
    ]

    if args.target == 'sdl2_ttf':
        subprocess.run(["git", "checkout", "release-2.24.x"], cwd=f"{script_dir}/../sdl_ttf", check=True)
        freetype_install_dir = deps_manager.setup_sdl_ttf_dependencies(source_dir, script_dir)
        sdl2_install_dir = os.path.join(script_dir, 'sdl2/install')
        cmake_args += [
            f'-DSDL2TTF_SAMPLES=OFF',
            f'-DSDL2TTF_INSTALL=ON',
            f'-DSDL2TTF_VENDORED=ON',
            f'-DSDL2TTF_HARFBUZZ=ON',
            f'-DCMAKE_PREFIX_PATH={sdl2_install_dir};{freetype_install_dir}'
        ]

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
    shutil.copy(f"{script_dir}/CMakeLists.txt", f"{source_dir}/CMakeLists.txt")
    ffmpeg_install_dir = os.path.join(script_dir, 'ffmpeg/install').replace('\\', '/')
    sdl_ttf_install_dir = os.path.join(script_dir, 'sdl2_ttf/install').replace('\\', '/')
    sdl_install_dir = os.path.join(script_dir, 'sdl2/install').replace('\\', '/')
    if args.platform == 'windows':
        ffmpeg_install_dir = os.path.join(script_dir, 'ffmpeg/install_win').replace('/', '\\')
    cmake_args = [
        'cmake', source_dir,
        f'-B{build_dir}',
        f'-DCMAKE_BUILD_TYPE=Release',
        f'-DCMAKE_INSTALL_PREFIX={install_dir}',
        f"-DFFMPEG_INSTALL_DIR={ffmpeg_install_dir}",
        f"-DSDL_TTF_INSTALL_DIR={sdl_ttf_install_dir}",
        f"-DSDL_INSTALL_DIR={sdl_install_dir}",
    ]
    make(cmake_args, log_file)
    
    os.system(f'cp {sdl_install_dir}/bin/SDL2.dll {install_dir}/bin/SDL2.dll')
    os.system(f'cp {sdl_ttf_install_dir}/bin/SDL2_ttf.dll {install_dir}/bin/SDL2_ttf.dll')
    os.system(f'cp {ffmpeg_install_dir}/bin/*.dll {install_dir}/bin/')

    os.system(f'rm -rf {source_dir}/CMakeLists.txt')


def main():
    log_filename = f"build_{args.target}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    log_file = os.path.join(build_dir, log_filename)
    print(f"\033[34m开始构建: {args.target}\033[0m")
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
    print("\033c", end="")
    parser = argparse.ArgumentParser(description="简化的统一构建工具")
    parser.add_argument('--target', choices=['ffmpeg', 'sdl2', 'sdl3',
                        'sdl2_ttf', 'sdl3_ttf', 'video_compare'], help='构建目标')
    parser.add_argument('-s', '--source', required=True, help='源码目录路径')
    parser.add_argument('-m', '--mode', default='shared', choices=['shared', 'static', 'both'], help='构建模式')
    parser.add_argument('-p', '--platform', default='host', choices=['windows', 'macos'], help='目标平台')
    args = parser.parse_args()
    source_dir = get_absolute_path(args.source).replace('\\', '/')
    script_dir = os.path.dirname(__file__).replace('\\', '/')
    build_dir = f"{script_dir}/{args.target}/obj"
    install_dir = f"{script_dir}/{args.target}/install"
    if args.platform == 'windows':
        build_dir = f"{build_dir}_win"
        install_dir = f"{install_dir}_win"
    init()
    main()
