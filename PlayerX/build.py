#!/usr/bin/env python3
"""
PlayerX build.py — 构建脚本
用法:
    python3 build.py              # Release 构建
    python3 build.py --debug      # Debug 构建
    python3 build.py --clean      # 清理构建目录后重新构建
    python3 build.py --clean-only # 仅清理
"""

import os
import sys
import shutil
import subprocess
import argparse
import platform

# ─── 路径配置 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIR   = SCRIPT_DIR                                    # PlayerX/PlayerX/
BUILD_ROOT   = os.path.join(SOURCE_DIR, "build")             # PlayerX/PlayerX/build/
BUILD_DIR    = os.path.join(BUILD_ROOT, "out")               # PlayerX/PlayerX/build/out/
INSTALL_DIR  = os.path.join(BUILD_ROOT, "install")           # PlayerX/PlayerX/build/install/

# 依赖安装目录（由旧 build 系统产出，复用；支持同级 build/ 或上级 build/）
_PARENT_BUILD = os.path.join(os.path.dirname(SOURCE_DIR), "build")
def _dep(name):
    # 优先找本项目 build/ 下，再找上级 build/（兼容旧工程）
    local = os.path.join(BUILD_ROOT, name, "install")
    parent = os.path.join(_PARENT_BUILD, name, "install")
    return local if os.path.isdir(local) else parent

FFMPEG_INSTALL_DIR   = _dep("ffmpeg")
SDL2_INSTALL_DIR     = _dep("sdl2")
SDL2_TTF_INSTALL_DIR = _dep("sdl2_ttf")

# ─── 颜色输出 ──────────────────────────────────────────────────────────────────
def _c(code, msg): return f"\033[{code}m{msg}\033[0m" if sys.stdout.isatty() else msg
def info(msg):    print(_c("34", f"[INFO]    {msg}"))
def success(msg): print(_c("32", f"[SUCCESS] {msg}"))
def warn(msg):    print(_c("33", f"[WARN]    {msg}"))
def error(msg):   print(_c("31", f"[ERROR]   {msg}"), file=sys.stderr)

# ─── 工具函数 ──────────────────────────────────────────────────────────────────
def run(cmd, cwd=None, check=True):
    """执行命令，实时输出"""
    info(f"$ {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    result = subprocess.run(cmd, cwd=cwd, check=check)
    return result.returncode

def cpu_count():
    return os.cpu_count() or 4

def check_deps():
    """检查依赖目录是否存在"""
    missing = []
    for name, path in [
        ("FFmpeg",   FFMPEG_INSTALL_DIR),
        ("SDL2",     SDL2_INSTALL_DIR),
        ("SDL2_ttf", SDL2_TTF_INSTALL_DIR),
    ]:
        if not os.path.isdir(path):
            missing.append(f"  {name}: {path}")
    if missing:
        error("以下依赖目录不存在，请先运行旧的 build 系统构建依赖：")
        for m in missing: error(m)
        sys.exit(1)

# ─── 构建步骤 ──────────────────────────────────────────────────────────────────
def clean():
    if os.path.isdir(BUILD_DIR):
        info(f"清理构建目录: {BUILD_DIR}")
        shutil.rmtree(BUILD_DIR)
        success("清理完成")
    else:
        info("构建目录不存在，无需清理")

def configure(build_type: str):
    os.makedirs(BUILD_DIR, exist_ok=True)
    cmake_args = [
        "cmake",
        SOURCE_DIR,
        f"-DCMAKE_BUILD_TYPE={build_type}",
        f"-DCMAKE_INSTALL_PREFIX={INSTALL_DIR}",
        f"-DFFMPEG_INSTALL_DIR={FFMPEG_INSTALL_DIR}",
        f"-DSDL2_INSTALL_DIR={SDL2_INSTALL_DIR}",
        f"-DSDL2_TTF_INSTALL_DIR={SDL2_TTF_INSTALL_DIR}",
    ]
    # macOS：优先使用 Ninja（如果有）
    if platform.system() == "Darwin":
        if shutil.which("ninja"):
            cmake_args += ["-G", "Ninja"]
    run(cmake_args, cwd=BUILD_DIR)

def build():
    run(["cmake", "--build", BUILD_DIR, "--parallel", str(cpu_count())])

def install():
    run(["cmake", "--install", BUILD_DIR])

def codesign_macos():
    """macOS：对产物进行 ad-hoc 签名，避免 Gatekeeper 拦截"""
    if platform.system() != "Darwin":
        return
    bin_path = os.path.join(INSTALL_DIR, "bin", "PlayerX")
    if os.path.isfile(bin_path):
        info("对 PlayerX 进行 ad-hoc 签名...")
        subprocess.run(
            ["codesign", "--sign", "-", "--force", "--preserve-metadata=entitlements", bin_path],
            check=False
        )
        success("签名完成")

# ─── 主入口 ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="PlayerX 构建脚本")
    parser.add_argument("--debug",      action="store_true", help="Debug 构建")
    parser.add_argument("--clean",      action="store_true", help="清理后重新构建")
    parser.add_argument("--clean-only", action="store_true", help="仅清理，不构建")
    args = parser.parse_args()

    build_type = "Debug" if args.debug else "Release"

    if args.clean_only:
        clean()
        return

    if args.clean:
        clean()

    check_deps()

    info(f"开始构建 PlayerX [{build_type}]")
    info(f"  源码目录:  {SOURCE_DIR}")
    info(f"  构建目录:  {BUILD_DIR}")
    info(f"  安装目录:  {INSTALL_DIR}")

    configure(build_type)
    build()
    install()
    codesign_macos()

    success(f"PlayerX 构建完成！")
    success(f"可执行文件: {os.path.join(INSTALL_DIR, 'bin', 'PlayerX')}")

if __name__ == "__main__":
    main()
