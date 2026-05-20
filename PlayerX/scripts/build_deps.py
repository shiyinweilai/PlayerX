#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PlayerX 第三方依赖统一构建入口

本脚本是 PlayerX 自包含构建的"依赖准备阶段"——把 third_party/ 下所有需要
预编译的依赖一次性构建好，构建产物放到各自子目录的 build/install[_win] 下，
供 PlayerX 主工程的 build.py / CMake 直接使用。

当前依赖：
    * FFmpeg 8.0  (third_party/ffmpeg) ─ 由 scripts/build_ffmpeg.py 编译

未来要加新依赖（例如 SDL、x264、libde265 等），只需：
    1) 在 third_party/ 下加 submodule
    2) 在 scripts/ 下加 build_<name>.py 单独脚本
    3) 在本脚本的 STAGES 列表里追加一项即可

用法:
    python3 scripts/build_deps.py -p macos
    python3 scripts/build_deps.py -p windows
    python3 scripts/build_deps.py -p macos --clean    # 全清理重建
    python3 scripts/build_deps.py -p macos --force    # 即使已存在也重编
"""

import argparse
import os
import subprocess
import sys
import time


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def _c(code, msg):
    return f"\033[{code}m{msg}\033[0m" if sys.stdout.isatty() else msg


def info(msg):    print(_c("34", f"[DEPS]    {msg}"))
def success(msg): print(_c("32", f"[DEPS]    {msg}"))
def warn(msg):    print(_c("33", f"[DEPS]    {msg}"))
def error(msg):   print(_c("31", f"[DEPS]    {msg}"), file=sys.stderr)


# 每一项 = (人类可读名, 子脚本路径, 额外参数)
# 子脚本统一接受 -p <macos|windows>、--clean、--skip-if-exists
STAGES = [
    ("FFmpeg", os.path.join(SCRIPT_DIR, "build_ffmpeg.py"), ["-m", "static"]),
]


def run_stage(name: str, script: str, extra_args, target: str, clean: bool, force: bool):
    if not os.path.isfile(script):
        error(f"找不到子构建脚本：{script}")
        sys.exit(1)

    cmd = [sys.executable, script, "-p", target] + list(extra_args)
    if clean:
        cmd.append("--clean")
    if not force:
        cmd.append("--skip-if-exists")

    info(f"=== 开始构建依赖：{name} ===")
    t0 = time.time()
    rc = subprocess.run(cmd).returncode
    if rc != 0:
        error(f"{name} 构建失败")
        sys.exit(rc)
    success(f"=== {name} 完成（耗时 {time.time() - t0:.1f}s） ===")


def main():
    parser = argparse.ArgumentParser(description="PlayerX 第三方依赖统一构建入口")
    parser.add_argument("-p", "--platform", required=True, choices=["macos", "windows"],
                        help="目标平台")
    parser.add_argument("--clean", action="store_true",
                        help="清理后重建所有依赖")
    parser.add_argument("--force", action="store_true",
                        help="即使产物已存在也强制重编（默认会跳过已构建的依赖）")
    args = parser.parse_args()

    info(f"目标平台: {args.platform}")
    info(f"待构建依赖: {', '.join(name for name, _, _ in STAGES)}")

    t_total = time.time()
    for name, script, extra in STAGES:
        run_stage(name, script, extra, args.platform, args.clean, args.force)

    success(f"全部依赖构建完成（总耗时 {time.time() - t_total:.1f}s）")


if __name__ == "__main__":
    main()
