#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse
import os
import subprocess
import sys
import shutil


def run(cmd, cwd=None, capture_output=True):
    print(f"\033[33m>>>\033[0m {' '.join(cmd)}  (cwd={cwd or os.getcwd()})\n")
    result = subprocess.run(cmd, cwd=cwd, capture_output=capture_output, text=True)
    if result.returncode != 0:
        print(f"\033[31m!!! 命令执行失败: {' '.join(cmd)}\033[0m")
        if capture_output:
            print(f"\033[31m错误输出:\n{result.stderr}\033[0m")
        sys.exit(1)
    return result


def get_absolute_path(path):
    if os.path.isabs(path):
        return path
    return os.path.abspath(path)


def make(cmake_args):
    try:
        run(cmake_args, cwd=build_dir)
        run(['make', '-j', str(os.cpu_count() or 1)], cwd=build_dir)
        run(['make', 'install'], cwd=build_dir)
    except SystemExit:
        sys.exit(1)


def build_ffmpeg(args):
    configure = os.path.join(source_dir, 'configure')
    cmake_args = [configure, f'--prefix={install_dir}']
    if args.mode == 'shared':
        cmake_args += ['--enable-shared', '--disable-static']
    elif args.mode == 'static':
        cmake_args += ['--disable-shared', '--enable-static']
    else:
        cmake_args += ['--enable-shared', '--enable-static']
    make(cmake_args)


def build_sdl(args):
    cmake_args = [
        'cmake', source_dir,
        f'-B{build_dir}',
        f'-DCMAKE_BUILD_TYPE=Release',
        f'-DCMAKE_INSTALL_PREFIX={install_dir}',
    ]
    if args.target == 'sdl2_ttf':
        external_dir = os.path.join(source_dir, 'external')
        freetype_dir = os.path.join(external_dir, 'freetype')
        harfbuzz_dir = os.path.join(external_dir, 'harfbuzz')
        download_script = os.path.join(external_dir, 'download.sh')
        os.chdir(f"{script_dir}/../sdl_ttf")
        os.system("git checkout release-2.24.x")
        os.chdir(script_dir)
        need_download = False
        if not os.path.exists(freetype_dir) or not os.listdir(freetype_dir):
            need_download = True
        if not os.path.exists(harfbuzz_dir) or not os.listdir(harfbuzz_dir):
            need_download = True
        if need_download:
            if os.path.exists(download_script):
                run(['sh', download_script], cwd=source_dir)
            else:
                sys.exit(1)
        cmake_args += [f'-DSDL2TTF_SAMPLES=OFF',
                       f'-DSDL2TTF_INSTALL=ON',
                       f'-DSDL2TTF_VENDORED=ON',
                       f'-DSDL2TTF_HARFBUZZ=ON'
                       ]
    if args.target == 'sdl3_ttf':
        os.chdir(f"{script_dir}/../sdl_ttf")
        os.system("git checkout release-3.2.x")
        os.chdir(script_dir)
        sdl_install_dir = os.path.join(script_dir, 'sdl3/install')
        cmake_args += [f'-DSDL3TTF_SAMPLES=OFF',
                       f'-DSDL3TTF_INSTALL=ON',
                       f'-DSDL3TTF_VENDORED=ON',
                       f'-DSDL3TTF_HARFBUZZ=ON',
                       f'-DCMAKE_PREFIX_PATH={sdl_install_dir}',
                       ]
    if args.target == 'sdl2':
        os.chdir(f"{script_dir}/../sdl")
        os.system("git checkout release-2.24.x")
        os.chdir(script_dir)
    if args.mode == 'static':
        cmake_args += ['-DBUILD_SHARED_LIBS=OFF']
    elif args.mode == 'both':
        cmake_args += ['-DBUILD_SHARED_LIBS=ON']
    make(cmake_args)


def build_video_compare(args):
    shutil.copy(f"{script_dir}/CMakeLists.txt", f"{source_dir}/CMakeLists.txt")
    ffmpeg_install_dir = os.path.join(script_dir, 'ffmpeg/install')
    sdl_ttf_install_dir = os.path.join(script_dir, 'sdl2_ttf/install')
    cmake_args = [
        'cmake', source_dir,
        f'-B{build_dir}',
        f'-DCMAKE_BUILD_TYPE=Release',
        f'-DCMAKE_INSTALL_PREFIX={install_dir}',
        f"-DFFMPEG_INSTALL_DIR={ffmpeg_install_dir}",
        f"-DSDL_TTF_INSTALL_DIR={sdl_ttf_install_dir}"
    ]
    make(cmake_args)
    os.system(f'rm -rf {source_dir}/CMakeLists.txt')


def main():
    print(f"\033[34m开始构建目标: {args.target}\033[0m")
    if args.target == 'ffmpeg':
        build_ffmpeg(args)
    elif args.target == 'sdl2' or args.target == 'sdl3' or args.target == 'sdl2_ttf' or args.target == 'sdl3_ttf':
        build_sdl(args)
    elif args.target == 'video_compare':
        build_video_compare(args)
    else:
        print("\033[31m错误: 未指定有效的构建目标\033[0m")
        sys.exit(1)
    print("\033[32m构建完成\033[0m")
    print(f"\033[32m安装目录: {install_dir}\033[0m")


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
    parser.add_argument('--target', choices=['ffmpeg', 'sdl2', 'sdl3', 'sdl2_ttf', 'sdl3_ttf', 'video_compare'], help='构建目标')
    parser.add_argument('-s', '--source', required=True, help='源码目录路径')
    parser.add_argument('-m', '--mode', default='shared', choices=['shared', 'static', 'both'], help='构建模式')

    args = parser.parse_args()
    source_dir = get_absolute_path(args.source)
    src_basename = os.path.basename(source_dir.rstrip('/'))
    script_dir = os.path.dirname(__file__)
    build_dir = f"{script_dir}/{args.target}/obj"
    install_dir = f"{script_dir}/{args.target}/install"
    init()
    main()
