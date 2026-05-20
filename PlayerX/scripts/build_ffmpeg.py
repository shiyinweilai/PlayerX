#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PlayerX 内置 FFmpeg 静态库构建脚本
（从原 build/build_tools.py 中"FFmpeg 部分"提取并精简，剔除 SDL/SDL_ttf/video-compare）

用法（一般由 build_deps.py 自动调起，也支持单独调用）：
    python3 scripts/build_ffmpeg.py -p macos
    python3 scripts/build_ffmpeg.py -p windows

源码：
    PlayerX/third_party/ffmpeg     ← FFmpeg submodule
产物：
    PlayerX/third_party/ffmpeg/build/<obj|install>          (macOS)
    PlayerX/third_party/ffmpeg/build/<obj_win|install_win>  (Windows 交叉)
"""

import argparse
import datetime
import os
import shutil
import subprocess
import sys


# ─── 颜色输出 ──────────────────────────────────────────────────────────────────
def _c(code, msg):
    return f"\033[{code}m{msg}\033[0m" if sys.stdout.isatty() else msg


def info(msg):    print(_c("34", f"[FFMPEG]  {msg}"))
def success(msg): print(_c("32", f"[FFMPEG]  {msg}"))
def warn(msg):    print(_c("33", f"[FFMPEG]  {msg}"))
def error(msg):   print(_c("31", f"[FFMPEG]  {msg}"), file=sys.stderr)


def run(cmd, cwd=None, log_file=None):
    """运行命令，可选地把过程记录到 log_file。失败直接 sys.exit(1)。"""
    info("$ " + (" ".join(cmd) if isinstance(cmd, list) else cmd))

    if log_file:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"=== {datetime.datetime.now():%Y-%m-%d %H:%M:%S} ===\n")
            f.write(f"Command: {' '.join(cmd) if isinstance(cmd, list) else cmd}\n")
            f.write(f"Working directory: {cwd or os.getcwd()}\n")
            f.write("-" * 80 + "\n")

    result = subprocess.run(
        cmd, cwd=cwd, capture_output=bool(log_file),
        text=True, encoding="utf-8", errors="replace",
    )

    if log_file and result.stdout is not None:
        with open(log_file, "a", encoding="utf-8") as f:
            if result.stdout:
                f.write("STDOUT:\n" + result.stdout + "\n")
            if result.stderr:
                f.write("STDERR:\n" + result.stderr + "\n")
            f.write("=" * 80 + "\n\n")

    if result.returncode != 0:
        error(f"命令执行失败: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
        if result.stderr:
            error(f"错误输出:\n{result.stderr}")
        if log_file:
            error(f"详细日志: {log_file}")
        sys.exit(1)
    return result


# ─── 路径配置 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)                       # PlayerX/
FFMPEG_SRC   = os.path.join(PROJECT_ROOT, "third_party", "ffmpeg")
# 产物放在项目顶层 build/third_party/ffmpeg/ 下，避免污染 submodule 源码目录
FFMPEG_BUILD = os.path.join(PROJECT_ROOT, "build", "third_party", "ffmpeg")


def dirs_for(platform_name: str):
    """根据目标平台返回 (build_dir, install_dir)。"""
    suffix = "_win" if platform_name == "windows" else ""
    build_dir   = os.path.join(FFMPEG_BUILD, f"obj{suffix}")
    install_dir = os.path.join(FFMPEG_BUILD, f"install{suffix}")
    return build_dir, install_dir


# ─── 子模块自检 ────────────────────────────────────────────────────────────────
def ensure_submodule_ready():
    """如果 third_party/ffmpeg 是空目录，提醒用户先 init submodule。"""
    if not os.path.isdir(FFMPEG_SRC) or not os.path.isfile(os.path.join(FFMPEG_SRC, "configure")):
        error(f"未找到 FFmpeg 源码：{FFMPEG_SRC}")
        error("请先初始化子模块：")
        error("  git submodule update --init --recursive")
        sys.exit(1)


# ─── FFmpeg 编译 ──────────────────────────────────────────────────────────────
def build_ffmpeg(target: str, mode: str, log_file: str):
    """调用 FFmpeg 自带 configure 进行编译。

    target : "macos" | "windows"
    mode   : "static" | "shared" | "both"
    """
    build_dir, install_dir = dirs_for(target)

    configure = os.path.join(FFMPEG_SRC, "configure")
    cfg_args = [configure, f"--prefix={install_dir}"]

    if mode == "shared":
        cfg_args += ["--enable-shared", "--disable-static"]
    elif mode == "static":
        cfg_args += ["--disable-shared", "--enable-static"]
    else:
        cfg_args += ["--enable-shared", "--enable-static"]

    if target == "windows":
        cfg_args += [
            "--enable-cross-compile",
            "--target-os=mingw32",
            "--arch=x86_64",
            "--cross-prefix=x86_64-w64-mingw32-",
            # 避免链接 video-compare/PlayerX 时的额外 Win32 系统库依赖
            "--disable-mediafoundation",
            "--enable-schannel",
            "--enable-protocol=tls",
            "--enable-protocol=https",
            "--disable-dxva2",
            "--disable-d3d11va",
            "--disable-indev=dshow",
            "--disable-outdev=sdl",
        ]
        if mode == "static":
            cfg_args += [
                "--pkg-config-flags=--static",
                "--extra-ldflags=-static -static-libgcc -static-libstdc++",
            ]

    run(cfg_args, cwd=build_dir, log_file=log_file)
    run(["make", "-j", str(os.cpu_count() or 1)], cwd=build_dir, log_file=log_file)
    run(["make", "install"], cwd=build_dir, log_file=log_file)


def init_dirs(build_dir: str, install_dir: str, clean: bool):
    if clean:
        for d in (build_dir, install_dir):
            if os.path.isdir(d):
                shutil.rmtree(d)
    os.makedirs(build_dir, exist_ok=True)
    os.makedirs(install_dir, exist_ok=True)


def main():
    parser = argparse.ArgumentParser(description="PlayerX 内置 FFmpeg 构建脚本")
    parser.add_argument("-p", "--platform", required=True, choices=["macos", "windows"],
                        help="目标平台")
    parser.add_argument("-m", "--mode", default="static", choices=["static", "shared", "both"],
                        help="链接模式（PlayerX 默认 static）")
    parser.add_argument("--clean", action="store_true",
                        help="构建前清理 build/install 目录")
    parser.add_argument("--skip-if-exists", action="store_true",
                        help="如果 install 已存在 libavformat.a/libavformat.lib 则直接跳过")
    args = parser.parse_args()

    ensure_submodule_ready()

    build_dir, install_dir = dirs_for(args.platform)

    # 探测是否已有可用产物（避免每次重编）
    if args.skip_if_exists:
        lib_dir = os.path.join(install_dir, "lib")
        for name in ("libavformat.a", "avformat.lib"):
            if os.path.isfile(os.path.join(lib_dir, name)):
                success(f"已存在 FFmpeg 安装：{install_dir}（跳过编译）")
                return

    init_dirs(build_dir, install_dir, args.clean)

    log_filename = f"build_ffmpeg_{datetime.datetime.now():%Y%m%d_%H%M%S}.log"
    log_file = os.path.join(build_dir, log_filename)

    info(f"开始构建 FFmpeg ({args.platform}, {args.mode})")
    info(f"  源码:     {FFMPEG_SRC}")
    info(f"  构建目录: {build_dir}")
    info(f"  安装目录: {install_dir}")
    info(f"  日志文件: {log_file}")

    build_ffmpeg(args.platform, args.mode, log_file)

    success(f"FFmpeg 构建完成：{install_dir}")


if __name__ == "__main__":
    main()
