#!/usr/bin/env python3
"""
PlayerXQt build.py — Qt + QML 版本构建脚本

第 1 阶段：仅支持 macOS 原生构建（验证 Qt 工程通路）。
第 5 阶段会扩展到 macOS → Windows 交叉编译。

用法:
    python3 build.py                # 默认 Release，macOS 原生
    python3 build.py --debug        # Debug 构建
    python3 build.py --clean        # 清理后重新构建
    python3 build.py --clean-only   # 仅清理

依赖:
    1. Qt 6（推荐 brew install qt@6）
    2. FFmpeg（复用上层 PlayerX/build/ffmpeg/install）
    3. Ninja（推荐，brew install ninja）

设计要点:
    * 产物严格分离：所有产物输出到 PlayerXQt/build/out/
    * 自动探测 Qt 路径：依次尝试 brew --prefix qt@6 / qt6 / qt
    * 自动复用上层 FFmpeg（因为 PlayerXQt 解码后端与旧版完全一致）
"""

import os
import sys
import shutil
import subprocess
import argparse
import platform

IS_MACOS_HOST = platform.system() == "Darwin"

# ─── 路径配置 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIR = SCRIPT_DIR                                # PlayerX/PlayerXQt/
BUILD_ROOT = os.path.join(SOURCE_DIR, "build")         # PlayerX/PlayerXQt/build/

REPO_ROOT      = os.path.dirname(SOURCE_DIR)            # PlayerX/
PARENT_BUILD   = os.path.join(REPO_ROOT, "build")       # PlayerX/build/
OLD_PLAYERX_BUILD = os.path.join(REPO_ROOT, "PlayerX", "build")  # PlayerX/PlayerX/build/

def build_dir_for(target: str) -> str:
    suffix = "_win" if target == "windows" else ""
    return os.path.join(BUILD_ROOT, f"out{suffix}")

def install_dir_for(target: str) -> str:
    suffix = "_win" if target == "windows" else ""
    return os.path.join(BUILD_ROOT, f"install{suffix}")


# ─── 颜色输出 ──────────────────────────────────────────────────────────────────
def _c(code, msg): return f"\033[{code}m{msg}\033[0m" if sys.stdout.isatty() else msg
def info(msg):    print(_c("34", f"[INFO]    {msg}"))
def success(msg): print(_c("32", f"[SUCCESS] {msg}"))
def warn(msg):    print(_c("33", f"[WARN]    {msg}"))
def error(msg):   print(_c("31", f"[ERROR]   {msg}"), file=sys.stderr)

def run(cmd, cwd=None, check=True, env=None):
    info(f"$ {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    return subprocess.run(cmd, cwd=cwd, check=check, env=env).returncode

def cpu_count() -> int:
    return os.cpu_count() or 4


# ─── 依赖探测 ──────────────────────────────────────────────────────────────────
def find_ffmpeg(target: str) -> str:
    """复用上层（旧 build 系统）已经构建好的 FFmpeg 静态库。"""
    sub = "install_win" if target == "windows" else "install"

    # 优先 PlayerX/build/ffmpeg/install
    candidates = [
        os.path.join(PARENT_BUILD, "ffmpeg", sub),
        os.path.join(OLD_PLAYERX_BUILD, "ffmpeg", sub),
    ]
    for p in candidates:
        if os.path.isdir(p):
            return p
    error("未找到 FFmpeg 安装目录，已尝试以下路径：")
    for p in candidates:
        error(f"  {p}")
    error("请先在仓库根 PlayerX/build/ 下运行 main.py 构建 FFmpeg：")
    error("  python3 main.py -p macos    # 或 -p windows")
    sys.exit(1)


def find_qt6() -> str:
    """探测 Qt 6 安装路径，返回 CMAKE_PREFIX_PATH 用的目录。"""
    # 1. 用户显式指定
    env_p = os.environ.get("QT6_DIR") or os.environ.get("QT_DIR")
    if env_p and os.path.isdir(env_p):
        return env_p

    # 2. brew 包名优先级：qt@6 > qt6 > qt（最新 brew 的 qt 即为 qt6）
    if shutil.which("brew"):
        for pkg in ("qt@6", "qt6", "qt"):
            try:
                r = subprocess.run(["brew", "--prefix", pkg],
                                   capture_output=True, text=True, check=True)
                p = r.stdout.strip()
                if p and os.path.isdir(p) and os.path.isfile(os.path.join(p, "bin", "qmake6")):
                    return p
                if p and os.path.isdir(p) and os.path.isfile(os.path.join(p, "bin", "qmake")):
                    # 验证下 qmake 真的是 Qt6
                    rr = subprocess.run([os.path.join(p, "bin", "qmake"), "-query", "QT_VERSION"],
                                        capture_output=True, text=True)
                    if rr.returncode == 0 and rr.stdout.strip().startswith("6."):
                        return p
            except subprocess.CalledProcessError:
                continue

    # 3. 常见 Qt 在线安装路径
    home = os.path.expanduser("~")
    for base in (
        os.path.join(home, "Qt"),
        "/opt/Qt",
        "/Applications/Qt",
    ):
        if os.path.isdir(base):
            # 找形如 6.x.y/macos
            for v in sorted(os.listdir(base), reverse=True):
                if v.startswith("6."):
                    candidate = os.path.join(base, v, "macos")
                    if os.path.isdir(candidate):
                        return candidate

    error("未找到 Qt 6 安装路径，请通过以下方式之一安装：")
    error("  方式 A（推荐）: brew install qt@6")
    error("  方式 B（官方）: 从 https://www.qt.io/download-qt-installer 下载安装")
    error("安装后可再次运行本脚本，或显式设置环境变量 QT6_DIR=/path/to/qt6")
    sys.exit(1)


# ─── 构建步骤 ──────────────────────────────────────────────────────────────────
def clean(target: str):
    bdir = build_dir_for(target)
    if os.path.isdir(bdir):
        info(f"清理: {bdir}")
        shutil.rmtree(bdir)
        success("清理完成")
    else:
        info("构建目录不存在，无需清理")


def configure(target: str, build_type: str, ffmpeg_dir: str, qt_dir: str):
    bdir = build_dir_for(target)
    idir = install_dir_for(target)
    os.makedirs(bdir, exist_ok=True)

    has_ninja = shutil.which("ninja") is not None

    cmake_args = [
        "cmake",
        SOURCE_DIR,
        f"-DCMAKE_BUILD_TYPE={build_type}",
        f"-DCMAKE_INSTALL_PREFIX={idir}",
        f"-DCMAKE_PREFIX_PATH={qt_dir}",
        f"-DFFMPEG_INSTALL_DIR={ffmpeg_dir}",
    ]
    if has_ninja:
        cmake_args += ["-G", "Ninja"]
    if target == "macos":
        cmake_args += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0"]

    run(cmake_args, cwd=bdir)


def build(target: str):
    bdir = build_dir_for(target)
    run(["cmake", "--build", bdir, "--parallel", str(cpu_count())])


def install(target: str):
    bdir = build_dir_for(target)
    run(["cmake", "--install", bdir])


def post_build(target: str):
    """macOS：ad-hoc 签名；后续阶段加 macdeployqt 打包。"""
    if target == "macos" and IS_MACOS_HOST:
        bdir = build_dir_for(target)
        # qt_add_executable 默认产 .app bundle
        # 找出 .app 路径
        bin_dir = os.path.join(bdir, "bin")
        if os.path.isdir(bin_dir):
            for entry in os.listdir(bin_dir):
                if entry.endswith(".app"):
                    app_path = os.path.join(bin_dir, entry)
                    info(f"对 {entry} 进行 ad-hoc 签名...")
                    subprocess.run(
                        ["codesign", "--sign", "-", "--force", "--deep", app_path],
                        check=False
                    )
                    success("签名完成")
                    return


def output_path(target: str) -> str:
    bdir = build_dir_for(target)
    bin_dir = os.path.join(bdir, "bin")
    if os.path.isdir(bin_dir):
        for entry in os.listdir(bin_dir):
            if entry.endswith(".app"):
                return os.path.join(bin_dir, entry)
        # 未找到 .app（可能 Linux/Win），直接给可执行文件名
        exe = "PlayerXQt.exe" if target == "windows" else "PlayerXQt"
        return os.path.join(bin_dir, exe)
    return ""


# ─── 主入口 ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="PlayerXQt 构建脚本")
    parser.add_argument("-p", "--platform", choices=["macos", "windows"],
                        default="macos", help="目标平台（当前仅支持 macos）")
    parser.add_argument("--debug",      action="store_true", help="Debug 构建")
    parser.add_argument("--clean",      action="store_true", help="清理后重新构建")
    parser.add_argument("--clean-only", action="store_true", help="仅清理")
    args = parser.parse_args()

    target     = args.platform
    build_type = "Debug" if args.debug else "Release"

    if target == "windows":
        error("Windows 交叉编译尚未在第 1 阶段启用，敬请期待。")
        sys.exit(2)

    if not IS_MACOS_HOST:
        warn(f"当前主机 {platform.system()}，第 1 阶段仅在 macOS 验证；将尽量继续。")

    if args.clean_only:
        clean(target); return
    if args.clean:
        clean(target)

    ffmpeg_dir = find_ffmpeg(target)
    qt_dir     = find_qt6()

    info(f"开始构建 PlayerXQt [{build_type}] target={target}")
    info(f"  源码:    {SOURCE_DIR}")
    info(f"  构建:    {build_dir_for(target)}")
    info(f"  安装:    {install_dir_for(target)}")
    info(f"  FFmpeg:  {ffmpeg_dir}")
    info(f"  Qt6:     {qt_dir}")

    configure(target, build_type, ffmpeg_dir, qt_dir)
    build(target)
    install(target)
    post_build(target)

    success("PlayerXQt 构建完成！")
    out = output_path(target)
    if out:
        success(f"产物: {out}")
        if out.endswith(".app"):
            success(f"启动: open '{out}'")

if __name__ == "__main__":
    main()
