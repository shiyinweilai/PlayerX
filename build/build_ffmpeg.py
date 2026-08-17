#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FFmpeg 静态/动态库构建脚本

用法：
    python3 build_ffmpeg.py -p macos              # macOS 动态库（默认）
    python3 build_ffmpeg.py -p macos -m static    # macOS 静态库
    python3 build_ffmpeg.py -p windows -m static  # Windows 交叉编译静态库

产物目录：
    macOS:   build/ffmpeg/install/
    Windows: build/ffmpeg/install_win/
"""

import argparse
import os
import subprocess
import sys
import shutil
import datetime
import time


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FFMPEG_SOURCE = os.path.join(os.path.dirname(SCRIPT_DIR), "ffmpeg")


def _c(code, msg):
    return f"\033[{code}m{msg}\033[0m" if sys.stdout.isatty() else msg

def info(msg):    print(_c("34", f"[INFO] {msg}"))
def success(msg): print(_c("32", f"[OK]   {msg}"))
def error(msg):   print(_c("31", f"[ERR]  {msg}"), file=sys.stderr)


def run(cmd, cwd=None, log_file=None):
    """运行命令并可选地记录日志"""
    print(f"\033[33m>>>\033[0m {' '.join(cmd)}  (cwd={cwd or os.getcwd()})\n")

    if log_file:
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(f"=== {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ===\n")
            f.write(f"Command: {' '.join(cmd)}\n")
            f.write(f"Working directory: {cwd or os.getcwd()}\n")
            f.write("-" * 80 + "\n")

    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                            encoding='utf-8', errors='replace')

    if log_file:
        with open(log_file, 'a', encoding='utf-8') as f:
            if result.stdout:
                f.write("STDOUT:\n" + result.stdout + "\n")
            if result.stderr:
                f.write("STDERR:\n" + result.stderr + "\n")
            f.write("=" * 80 + "\n\n")

    if result.returncode != 0:
        error(f"命令执行失败: {' '.join(cmd)}")
        error(f"错误输出:\n{result.stderr}")
        if log_file:
            error(f"日志文件: {log_file}")
        sys.exit(1)
    return result


def build(source_dir, build_dir, install_dir, platform, mode, log_file):
    """配置并编译 FFmpeg"""
    configure = os.path.join(source_dir, 'configure')
    cfg = [configure, f'--prefix={install_dir}']

    # 构建模式
    if mode == 'shared':
        cfg += ['--enable-shared', '--disable-static']
    elif mode == 'static':
        cfg += ['--disable-shared', '--enable-static']
    else:
        cfg += ['--enable-shared', '--enable-static']

    # Windows 交叉编译
    if platform == 'windows':
        cfg += [
            '--enable-cross-compile',
            '--target-os=mingw32',
            '--arch=x86_64',
            '--cross-prefix=x86_64-w64-mingw32-',
            '--disable-mediafoundation',
            '--enable-schannel',
            '--enable-protocol=tls',
            '--enable-protocol=https',
            '--disable-dxva2',
            '--disable-d3d11va',
            '--disable-indev=dshow',
            '--disable-outdev=sdl',
        ]
        if mode == 'static':
            cfg += [
                '--pkg-config-flags=--static',
                '--extra-ldflags=-static -static-libgcc -static-libstdc++',
            ]

    # 执行 configure + make + make install
    run(cfg, cwd=build_dir, log_file=log_file)
    run(['make', '-j', str(os.cpu_count() or 4)], cwd=build_dir, log_file=log_file)
    run(['make', 'install'], cwd=build_dir, log_file=log_file)


def main():
    parser = argparse.ArgumentParser(description="FFmpeg 构建工具")
    parser.add_argument('-s', '--source', default=FFMPEG_SOURCE,
                        help=f'FFmpeg 源码目录（默认: {FFMPEG_SOURCE}）')
    parser.add_argument('-m', '--mode', default='static',
                        choices=['shared', 'static', 'both'], help='构建模式（默认: static）')
    parser.add_argument('-p', '--platform', required=True,
                        choices=['windows', 'macos'], help='目标平台')
    args = parser.parse_args()

    source_dir = os.path.abspath(args.source)
    if not os.path.isfile(os.path.join(source_dir, 'configure')):
        error(f"FFmpeg 源码目录无效（找不到 configure）: {source_dir}")
        error("请确认 ffmpeg 源码已存在，或用 -s 指定路径")
        sys.exit(1)

    suffix = "_win" if args.platform == 'windows' else ""
    build_dir   = os.path.join(SCRIPT_DIR, f"ffmpeg/obj{suffix}")
    install_dir = os.path.join(SCRIPT_DIR, f"ffmpeg/install{suffix}")

    # 清理旧产物
    for d in [build_dir, install_dir]:
        if os.path.exists(d):
            shutil.rmtree(d)
        os.makedirs(d, exist_ok=True)

    log_file = os.path.join(build_dir,
                            f"build_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.log")

    info(f"源码:   {source_dir}")
    info(f"构建:   {build_dir}")
    info(f"安装:   {install_dir}")
    info(f"平台:   {args.platform}")
    info(f"模式:   {args.mode}")
    print()

    start = time.time()
    build(source_dir, build_dir, install_dir, args.platform, args.mode, log_file)
    elapsed = time.time() - start

    success(f"FFmpeg 构建完成！耗时 {elapsed:.1f} 秒")
    success(f"安装目录: {install_dir}")
    success(f"日志文件: {log_file}")


if __name__ == '__main__':
    main()
