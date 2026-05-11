#!/usr/bin/env python3
"""
PlayerX build.py — 构建脚本（macOS 原生 / macOS→Windows 交叉编译）

用法:
    python3 build.py                       # 默认：构建本机平台（macOS）
    python3 build.py -p macos              # 显式指定 macOS
    python3 build.py -p windows            # macOS 上交叉编译 Windows
    python3 build.py --debug               # Debug 构建
    python3 build.py --clean               # 清理构建目录后重新构建
    python3 build.py --clean-only          # 仅清理

平台说明:
    * macos  : 依赖目录 build/<dep>/install     ；产物 PlayerX
    * windows: 依赖目录 build/<dep>/install_win ；产物 PlayerX.exe
               需要 mingw-w64 交叉工具链 (x86_64-w64-mingw32-gcc/g++)
               brew install mingw-w64
"""

import os
import sys
import shutil
import subprocess
import argparse
import platform

IS_MACOS_HOST = platform.system() == "Darwin"

# ─── 路径配置 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIR  = SCRIPT_DIR                              # PlayerX/PlayerX/
BUILD_ROOT  = os.path.join(SOURCE_DIR, "build")       # PlayerX/PlayerX/build/

# build 目录与 install 目录都按平台分开，避免相互覆盖
def build_dir_for(target_platform: str) -> str:
    suffix = "_win" if target_platform == "windows" else ""
    return os.path.join(BUILD_ROOT, f"out{suffix}")

def install_dir_for(target_platform: str) -> str:
    suffix = "_win" if target_platform == "windows" else ""
    return os.path.join(BUILD_ROOT, f"install{suffix}")

# 上层 build/<dep>/install[_win] —— 复用旧 build 系统产物
_PARENT_BUILD = os.path.join(os.path.dirname(SOURCE_DIR), "build")

def _dep(name: str, target_platform: str) -> str:
    """根据目标平台选择依赖产物目录。"""
    sub = "install_win" if target_platform == "windows" else "install"
    local  = os.path.join(BUILD_ROOT,    name, sub)
    parent = os.path.join(_PARENT_BUILD, name, sub)
    return local if os.path.isdir(local) else parent

# ─── 颜色输出 ──────────────────────────────────────────────────────────────────
def _c(code, msg): return f"\033[{code}m{msg}\033[0m" if sys.stdout.isatty() else msg
def info(msg):    print(_c("34", f"[INFO]    {msg}"))
def success(msg): print(_c("32", f"[SUCCESS] {msg}"))
def warn(msg):    print(_c("33", f"[WARN]    {msg}"))
def error(msg):   print(_c("31", f"[ERROR]   {msg}"), file=sys.stderr)

# ─── 工具函数 ──────────────────────────────────────────────────────────────────
def run(cmd, cwd=None, check=True, env=None):
    info(f"$ {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    result = subprocess.run(cmd, cwd=cwd, check=check, env=env)
    return result.returncode

def cpu_count() -> int:
    # 避免 CPU 超订阅：单层构建用全核
    return os.cpu_count() or 4

def check_deps(target_platform: str, deps: dict):
    missing = []
    for label, path in deps.items():
        if not os.path.isdir(path):
            missing.append(f"  {label}: {path}")
    if missing:
        error(f"以下依赖目录不存在（target={target_platform}），请先运行依赖构建：")
        for m in missing: error(m)
        if target_platform == "windows":
            error("可在 PlayerX/build 目录下使用旧 build 系统：")
            error("  python3 main.py -p windows")
        else:
            error("可在 PlayerX/build 目录下使用旧 build 系统：")
            error("  python3 main.py -p macos")
        sys.exit(1)

def find_mingw_toolchain():
    """返回 (cc, cxx, ar, ranlib, strip, rc)，全部为绝对路径。缺一不可。"""
    triplet = "x86_64-w64-mingw32"
    needed = {
        "cc":     f"{triplet}-gcc",
        "cxx":    f"{triplet}-g++",
        "ar":     f"{triplet}-ar",
        "ranlib": f"{triplet}-ranlib",
        "strip":  f"{triplet}-strip",
        "rc":     f"{triplet}-windres",
    }
    found = {}
    missing = []
    for k, name in needed.items():
        p = shutil.which(name)
        if not p:
            missing.append(name)
        else:
            found[k] = p
    if missing:
        error("未找到 mingw-w64 交叉工具链，缺失以下程序：")
        for m in missing: error(f"  {m}")
        error("macOS 安装方式： brew install mingw-w64")
        sys.exit(1)
    return found

# ─── 构建步骤 ──────────────────────────────────────────────────────────────────
def clean(target_platform: str):
    bdir = build_dir_for(target_platform)
    if os.path.isdir(bdir):
        info(f"清理构建目录: {bdir}")
        shutil.rmtree(bdir)
        success("清理完成")
    else:
        info("构建目录不存在，无需清理")

def configure(target_platform: str, build_type: str, deps: dict):
    bdir = build_dir_for(target_platform)
    idir = install_dir_for(target_platform)
    os.makedirs(bdir, exist_ok=True)

    cmake_args = [
        "cmake",
        SOURCE_DIR,
        f"-DCMAKE_BUILD_TYPE={build_type}",
        f"-DCMAKE_INSTALL_PREFIX={idir}",
        f"-DFFMPEG_INSTALL_DIR={deps['FFmpeg']}",
        f"-DSDL2_INSTALL_DIR={deps['SDL2']}",
        f"-DSDL2_TTF_INSTALL_DIR={deps['SDL2_ttf']}",
    ]

    has_ninja = shutil.which("ninja") is not None

    if target_platform == "windows":
        # macOS → Windows 交叉编译：使用 mingw-w64 工具链
        tc = find_mingw_toolchain()
        info(f"工具链: {tc['cxx']}")
        cmake_args += [
            "-DCMAKE_SYSTEM_NAME=Windows",
            f"-DCMAKE_C_COMPILER={tc['cc']}",
            f"-DCMAKE_CXX_COMPILER={tc['cxx']}",
            f"-DCMAKE_AR={tc['ar']}",
            f"-DCMAKE_RANLIB={tc['ranlib']}",
            f"-DCMAKE_RC_COMPILER={tc['rc']}",
            "-DCMAKE_FIND_LIBRARY_SUFFIXES=.a",
            # 链接静态运行时，消除目标机对 mingw dll 的依赖
            "-DCMAKE_EXE_LINKER_FLAGS=-static -static-libgcc -static-libstdc++",
            # 仅在工具链路径下查找库
            "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER",
            "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY",
            "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY",
            "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY",
        ]
        # Windows 交叉编译用 Ninja 或 Unix Makefiles，不要用 macOS 默认的生成器歧义
        cmake_args += ["-G", "Ninja"] if has_ninja else ["-G", "Unix Makefiles"]
    else:
        # macOS 原生
        if has_ninja:
            cmake_args += ["-G", "Ninja"]
        # 与依赖产物保持一致的部署目标
        cmake_args += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0"]

    run(cmake_args, cwd=bdir)

def build(target_platform: str):
    bdir = build_dir_for(target_platform)
    run(["cmake", "--build", bdir, "--parallel", str(cpu_count())])

def install(target_platform: str):
    bdir = build_dir_for(target_platform)
    run(["cmake", "--install", bdir])

def post_build(target_platform: str):
    """平台相关的后处理（macOS 签名 / Windows strip）。"""
    idir = install_dir_for(target_platform)
    if target_platform == "macos":
        if not IS_MACOS_HOST:
            return
        bin_path = os.path.join(idir, "bin", "PlayerX")
        if os.path.isfile(bin_path):
            info("对 PlayerX 进行 ad-hoc 签名...")
            subprocess.run(
                ["codesign", "--sign", "-", "--force",
                 "--preserve-metadata=entitlements", bin_path],
                check=False
            )
            success("签名完成")
    elif target_platform == "windows":
        exe_path = os.path.join(idir, "bin", "PlayerX.exe")
        strip_bin = shutil.which("x86_64-w64-mingw32-strip")
        if strip_bin and os.path.isfile(exe_path):
            info(f"strip 调试符号: {exe_path}")
            r = subprocess.run([strip_bin, exe_path], capture_output=True, text=True)
            if r.returncode == 0:
                success("strip 完成")
            else:
                warn(f"strip 失败（可忽略）: {r.stderr.strip()}")

def output_binary_path(target_platform: str) -> str:
    idir = install_dir_for(target_platform)
    name = "PlayerX.exe" if target_platform == "windows" else "PlayerX"
    return os.path.join(idir, "bin", name)

# ─── 主入口 ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="PlayerX 构建脚本（macOS / macOS→Windows 交叉）")
    parser.add_argument("-p", "--platform", choices=["macos", "windows"],
                        default="macos", help="目标平台（默认 macos）")
    parser.add_argument("--debug",      action="store_true", help="Debug 构建")
    parser.add_argument("--clean",      action="store_true", help="清理后重新构建")
    parser.add_argument("--clean-only", action="store_true", help="仅清理，不构建")
    args = parser.parse_args()

    target_platform = args.platform
    build_type = "Debug" if args.debug else "Release"

    if not IS_MACOS_HOST:
        warn(f"当前主机为 {platform.system()}，本脚本目前仅在 macOS 上验证；将尽量继续。")

    if args.clean_only:
        clean(target_platform)
        return

    if args.clean:
        clean(target_platform)

    deps = {
        "FFmpeg":   _dep("ffmpeg",   target_platform),
        "SDL2":     _dep("sdl2",     target_platform),
        "SDL2_ttf": _dep("sdl2_ttf", target_platform),
    }
    check_deps(target_platform, deps)

    info(f"开始构建 PlayerX [{build_type}] target={target_platform}")
    info(f"  源码目录:  {SOURCE_DIR}")
    info(f"  构建目录:  {build_dir_for(target_platform)}")
    info(f"  安装目录:  {install_dir_for(target_platform)}")
    info(f"  FFmpeg:    {deps['FFmpeg']}")
    info(f"  SDL2:      {deps['SDL2']}")
    info(f"  SDL2_ttf:  {deps['SDL2_ttf']}")

    configure(target_platform, build_type, deps)
    build(target_platform)
    install(target_platform)
    post_build(target_platform)

    success("PlayerX 构建完成！")
    success(f"可执行文件: {output_binary_path(target_platform)}")

if __name__ == "__main__":
    main()
