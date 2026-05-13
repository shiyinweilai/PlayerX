#!/usr/bin/env python3
"""
PlayerX build.py — Qt + QML 版本构建脚本（macOS 原生 / macOS→Windows 交叉）

用法:
    python3 build.py                       # 默认 Release，macOS 原生
    python3 build.py -p macos              # 显式 macOS
    python3 build.py -p windows            # macOS 上交叉编译 Windows
    python3 build.py --debug               # Debug 构建
    python3 build.py --clean               # 清理后重新构建
    python3 build.py --clean-only          # 仅清理

依赖:
    1) FFmpeg：复用上层 PlayerX/build/ffmpeg/install[_win]
       （由 PlayerX/build/main.py 构建，本工程不重复构建依赖）

    2) Qt 6（按目标平台分别提供）
       * macOS:   brew install qt   或 官方在线安装器 (~/Qt/6.x.y/macos)
       * Windows: Qt6 win64_llvm_mingw（UCRT + libc++）
                    pip3 install --user aqtinstall
                    ~/.local/bin/aqt install-qt --outputdir ~/Qt windows desktop 6.9.3 win64_llvm_mingw
                  默认装到 ~/Qt/6.x.y/llvm-mingw_64
                  也可显式设置 QT6_WIN_DIR=/path/to/qt6/llvm-mingw_64

    3) Windows 交叉工具链：llvm-mingw（clang + libc++ + UCRT，与 Qt 包 ABI 一致）
         mkdir -p ~/Qt/llvm-mingw-tools && cd ~/Qt/llvm-mingw-tools \
           && curl -LO https://github.com/mstorsjo/llvm-mingw/releases/download/20260505/llvm-mingw-20260505-ucrt-macos-universal.tar.xz \
           && tar -xf llvm-mingw-20260505-ucrt-macos-universal.tar.xz
         也可显式设置 LLVM_MINGW_DIR=/path/to/llvm-mingw 根目录
         注意：brew 的 mingw-w64 是 GCC + libstdc++，与 Qt llvm-mingw_64 包
              （clang + libc++）STL ABI 不兼容，不能用。

    4) Ninja（推荐）：brew install ninja

设计要点:
    * 产物严格分离：
        macOS   → PlayerX/build/out/      install/
        Windows → PlayerX/build/out_win/  install_win/
    * 自动探测各平台 Qt 路径，找不到时给出明确指引而非沉默失败
    * Windows 交叉编译统一走 llvm-mingw 工具链 + Qt win64_llvm_mingw 包
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
SOURCE_DIR = SCRIPT_DIR                                # PlayerX/PlayerX/
BUILD_ROOT = os.path.join(SOURCE_DIR, "build")         # PlayerX/PlayerX/build/

REPO_ROOT      = os.path.dirname(SOURCE_DIR)            # PlayerX/
PARENT_BUILD   = os.path.join(REPO_ROOT, "build")       # PlayerX/build/

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

    # PlayerX/build/ffmpeg/install[_win]
    candidates = [
        os.path.join(PARENT_BUILD, "ffmpeg", sub),
    ]
    for p in candidates:
        if os.path.isdir(p):
            return p
    error("未找到 FFmpeg 安装目录，已尝试以下路径：")
    for p in candidates:
        error(f"  {p}")
    error("请先在仓库根 PlayerX/build/ 下运行 main.py 构建 FFmpeg：")
    if target == "windows":
        error("  python3 main.py -p windows")
    else:
        error("  python3 main.py -p macos")
    sys.exit(1)


def _find_qt6_macos(must: bool = True) -> str:
    """探测 macOS 版 Qt 6，返回 CMAKE_PREFIX_PATH 用的目录。

    must=False 时找不到只返回 ""，便于 Windows 交叉编译时尝试性获取 host Qt。
    """
    # 1) 用户显式指定（macOS 优先用 QT6_DIR / QT_DIR）
    env_p = os.environ.get("QT6_DIR") or os.environ.get("QT_DIR")
    if env_p and os.path.isdir(env_p):
        return env_p

    # 2) brew 包名优先级：qt@6 > qt6 > qt（最新 brew 的 qt 即为 qt6）
    if shutil.which("brew"):
        for pkg in ("qt@6", "qt6", "qt"):
            try:
                r = subprocess.run(["brew", "--prefix", pkg],
                                   capture_output=True, text=True, check=True)
                p = r.stdout.strip()
                if p and os.path.isdir(p) and os.path.isfile(os.path.join(p, "bin", "qmake6")):
                    return p
                if p and os.path.isdir(p) and os.path.isfile(os.path.join(p, "bin", "qmake")):
                    rr = subprocess.run([os.path.join(p, "bin", "qmake"), "-query", "QT_VERSION"],
                                        capture_output=True, text=True)
                    if rr.returncode == 0 and rr.stdout.strip().startswith("6."):
                        return p
            except subprocess.CalledProcessError:
                continue

    # 3) 常见 Qt 在线安装路径
    home = os.path.expanduser("~")
    for base in (os.path.join(home, "Qt"), "/opt/Qt", "/Applications/Qt"):
        if os.path.isdir(base):
            for v in sorted(os.listdir(base), reverse=True):
                if v.startswith("6."):
                    candidate = os.path.join(base, v, "macos")
                    if os.path.isdir(candidate):
                        return candidate

    if not must:
        return ""

    error("未找到 macOS 版 Qt 6 安装路径，请通过以下方式之一安装：")
    error("  方式 A（推荐）: brew install qt")
    error("  方式 B（官方）: https://www.qt.io/download-qt-installer")
    error("或显式设置环境变量 QT6_DIR=/path/to/qt6")
    sys.exit(1)


def _find_qt6_windows() -> str:
    """探测 Windows 版 Qt 6（win64_llvm_mingw 包），用于 macOS→Windows 交叉编译。

    必须用 llvm-mingw 包（UCRT + libc++），才能与本仓库使用的 llvm-mingw 工具链
    ABI 一致。Qt 的 mingw_64（MSVCRT）和 brew 的 macOS qt 都不行。
    """
    # 1) 用户显式指定
    env_p = os.environ.get("QT6_WIN_DIR")
    if env_p and os.path.isdir(env_p):
        return env_p

    # 2) 常见 Qt 在线安装路径下的 llvm-mingw_64
    home = os.path.expanduser("~")
    for base in (os.path.join(home, "Qt"), "/opt/Qt", "/Applications/Qt"):
        if not os.path.isdir(base):
            continue
        for v in sorted(os.listdir(base), reverse=True):
            if not v.startswith("6."):
                continue
            for d in ("llvm-mingw_64", "llvm_mingw_64"):
                c = os.path.join(base, v, d)
                if os.path.isfile(os.path.join(c, "lib", "cmake", "Qt6", "Qt6Config.cmake")):
                    return c

    error("未找到 Windows 版 Qt 6（win64_llvm_mingw 包），交叉编译需要它。")
    error("安装方法：")
    error("  pip3 install --user aqtinstall")
    error("  ~/.local/bin/aqt install-qt --outputdir ~/Qt windows desktop 6.9.3 win64_llvm_mingw")
    error("安装后默认路径为 ~/Qt/6.9.3/llvm-mingw_64")
    error("也可显式设置环境变量：export QT6_WIN_DIR=/path/to/qt6/llvm-mingw_64")
    sys.exit(1)


def find_qt6(target: str) -> str:
    """按目标平台派发 Qt 探测（target Qt，链接库用）。"""
    return _find_qt6_windows() if target == "windows" else _find_qt6_macos(must=True)


def _find_llvm_mingw_root() -> str:
    """探测 llvm-mingw 工具链根目录（其下有 bin/x86_64-w64-mingw32-clang 等）。

    搜索顺序：
      1) 环境变量 LLVM_MINGW_DIR
      2) ~/Qt/llvm-mingw-tools/llvm-mingw-*-ucrt-macos-* （我们脚本默认安装位置）
      3) /opt/llvm-mingw、/usr/local/llvm-mingw
    返回根目录路径，找不到返回 ""。
    """
    env_p = os.environ.get("LLVM_MINGW_DIR")
    if env_p and os.path.isfile(os.path.join(env_p, "bin", "x86_64-w64-mingw32-clang")):
        return env_p

    home = os.path.expanduser("~")
    search_bases = [
        os.path.join(home, "Qt", "llvm-mingw-tools"),
        "/opt/llvm-mingw",
        "/usr/local/llvm-mingw",
    ]
    for base in search_bases:
        if not os.path.isdir(base):
            continue
        # 直接是工具链根
        if os.path.isfile(os.path.join(base, "bin", "x86_64-w64-mingw32-clang")):
            return base
        # 形如 llvm-mingw-YYYYMMDD-ucrt-macos-universal 子目录
        for d in sorted(os.listdir(base), reverse=True):
            sub = os.path.join(base, d)
            if d.startswith("llvm-mingw") and os.path.isfile(
                    os.path.join(sub, "bin", "x86_64-w64-mingw32-clang")):
                return sub
    return ""


def find_mingw_toolchain():
    """返回 (cc, cxx, ar, ranlib, strip, rc)，全部为绝对路径。

    必须用 llvm-mingw（clang + libc++ + UCRT），与 Qt win64_llvm_mingw 包 ABI 一致。
    brew 的 mingw-w64（GCC + libstdc++）STL 不兼容，会链接失败，不在此处考虑。
    """
    triplet = "x86_64-w64-mingw32"
    llvm_root = _find_llvm_mingw_root()
    if not llvm_root:
        error("未找到 llvm-mingw 工具链。安装方法：")
        error("  mkdir -p ~/Qt/llvm-mingw-tools && cd ~/Qt/llvm-mingw-tools \\")
        error("    && curl -LO https://github.com/mstorsjo/llvm-mingw/releases/download/20260505/llvm-mingw-20260505-ucrt-macos-universal.tar.xz \\")
        error("    && tar -xf llvm-mingw-20260505-ucrt-macos-universal.tar.xz")
        error("或显式设置 LLVM_MINGW_DIR=/path/to/llvm-mingw 根目录")
        sys.exit(1)

    bin_dir = os.path.join(llvm_root, "bin")
    found = {
        "cc":     os.path.join(bin_dir, f"{triplet}-clang"),
        "cxx":    os.path.join(bin_dir, f"{triplet}-clang++"),
        "ar":     os.path.join(bin_dir, "llvm-ar"),
        "ranlib": os.path.join(bin_dir, "llvm-ranlib"),
        "strip":  os.path.join(bin_dir, "llvm-strip"),
        "rc":     os.path.join(bin_dir, f"{triplet}-windres"),
    }
    for k in ("cc", "cxx", "ar", "rc"):
        if not os.path.isfile(found[k]):
            error(f"llvm-mingw 工具链不完整，缺少 {found[k]}")
            sys.exit(1)
    info(f"使用 llvm-mingw 工具链: {llvm_root}")
    return found


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

    if target == "windows":
        # macOS → Windows 交叉编译：mingw-w64 工具链 + Windows 版 Qt6（mingw 构建）
        tc = find_mingw_toolchain()
        info(f"工具链: {tc['cxx']}")

        # Qt 交叉编译关键：QT_HOST_PATH 指向 macOS 版 Qt6
        # 因为 Windows 版 Qt 自带的 moc/rcc/qmlimportscanner 等工具是 PE 程序，
        # 在 macOS 上无法执行，必须借用 host(macOS) 端的同版本工具来跑这些任务。
        host_qt = _find_qt6_macos(must=False)
        if not host_qt:
            error("Windows 交叉编译需要 host(macOS) 端的 Qt6 来跑 moc/rcc/qmlimportscanner。")
            error("请安装 macOS 版 Qt6：brew install qt")
            sys.exit(1)
        info(f"Host Qt: {host_qt}")

        cmake_args += [
            "-DCMAKE_SYSTEM_NAME=Windows",
            f"-DCMAKE_C_COMPILER={tc['cc']}",
            f"-DCMAKE_CXX_COMPILER={tc['cxx']}",
            f"-DCMAKE_AR={tc['ar']}",
            f"-DCMAKE_RANLIB={tc['ranlib']}",
            f"-DCMAKE_RC_COMPILER={tc['rc']}",
            "-DCMAKE_FIND_LIBRARY_SUFFIXES=.a;.dll.a;.lib",
            # 静态链接 libgcc / libstdc++ / winpthread，避免目标机依赖 mingw runtime DLL。
            # 用 -static 总开关 + 显式三件套，与 PlayerX/build.py 风格一致；
            # 之前的 --whole-archive winpthread 写法会破坏 mingw 隐式库（libmingw32/libmsvcrt）
            # 的链接顺序，导致 GUI 子系统下 Qt6EntryPoint.a 找不到 __imp___argc/__argv。
            "-DCMAKE_EXE_LINKER_FLAGS=-static -static-libgcc -static-libstdc++",
            # 关键：mingw 工具链的 sysroot 与 Windows 版 Qt6 都要可被搜索
            # PROGRAM=NEVER → 仍用主机端 cmake/qmake/moc 等工具
            # LIBRARY/INCLUDE/PACKAGE=BOTH → 同时在 host 和 target 路径下找，
            #     这样 Qt6 (CMAKE_PREFIX_PATH=Windows 版 Qt) 才能被 find_package 命中
            "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER",
            "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH",
            "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH",
            "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH",
            f"-DCMAKE_FIND_ROOT_PATH={qt_dir}",
            # Qt host tools（必需）
            f"-DQT_HOST_PATH={host_qt}",
            # 静默 QTP0004 提示（我们的 qml 子目录就在 module URI 根，无需额外 qmldir）
            "-DQT_POLICY_QTP0004=NEW",
        ]
        # Windows 交叉编译用 Ninja 或 Unix Makefiles，不要让 CMake 落到 macOS 默认生成器
        cmake_args += ["-G", "Ninja"] if has_ninja else ["-G", "Unix Makefiles"]
    else:
        # macOS 原生
        if has_ninja:
            cmake_args += ["-G", "Ninja"]
        cmake_args += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0"]

    run(cmake_args, cwd=bdir)


def build(target: str):
    bdir = build_dir_for(target)
    run(["cmake", "--build", bdir, "--parallel", str(cpu_count())])


def install(target: str):
    bdir = build_dir_for(target)
    run(["cmake", "--install", bdir])


def post_build(target: str, qt_dir: str):
    """平台相关后处理：
    macOS  → ad-hoc 签名 .app
    Windows→ strip 调试符号 + 复制 Qt 运行时 DLL（若 Qt 安装目录可见）
    """
    if target == "macos" and IS_MACOS_HOST:
        bdir = build_dir_for(target)
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

    if target == "windows":
        idir = install_dir_for(target)
        exe_path = os.path.join(idir, "bin", "PlayerX.exe")
        if not os.path.isfile(exe_path):
            return

        # strip 调试符号（Release 下显著缩小体积）
        strip_bin = shutil.which("x86_64-w64-mingw32-strip")
        if strip_bin:
            info(f"strip 调试符号: {exe_path}")
            r = subprocess.run([strip_bin, exe_path], capture_output=True, text=True)
            if r.returncode == 0:
                success("strip 完成")
            else:
                warn(f"strip 失败（可忽略）: {r.stderr.strip()}")

        # Qt 运行时部署：交叉环境下没有 windeployqt.exe 可跑（那是 Windows 工具），
        # 我们在 macOS 上手动按"最小依赖集"复制 DLL + plugins + qml 模块。
        deploy_qt_for_windows(qt_dir, idir)


def deploy_qt_for_windows(qt_dir: str, install_dir: str):
    """把 Qt6 mingw 版运行所需的 DLL / 平台插件 / QML 模块复制到 install/bin 旁。

    交付到 install_win/bin/ 之后，在 Windows 机器上拷贝整个 install_win 目录就可直接运行，
    无需额外 windeployqt。覆盖范围按本工程实际链接的 Qt 模块来定，而不是全量复制。
    """
    bin_src = os.path.join(qt_dir, "bin")
    plugins_src = os.path.join(qt_dir, "plugins")
    qml_src = os.path.join(qt_dir, "qml")

    bin_dst = os.path.join(install_dir, "bin")
    if not os.path.isdir(bin_dst):
        warn(f"未找到 install bin 目录: {bin_dst}，跳过 Qt 运行时部署")
        return

    # ── 1. 核心 DLL ──
    # 策略：复制 Qt 包 bin/ 下**所有非调试** Qt6*.dll，避免 QML 模块/插件
    # chain-load 时遇到缺失依赖。Windows 加载器是按 import 表静态校验的，只
    # 要任何被加载的 DLL 引用了缺失依赖就会失败（之前 libunwind.dll 的报错就
    # 属于这种情况）。这里宁可多带几 MB，也比每次手动补 DLL 强。
    qt6_dlls = []
    if os.path.isdir(bin_src):
        for name in sorted(os.listdir(bin_src)):
            if not name.lower().endswith(".dll"):
                continue
            # 跳过调试版（mingw 习惯 ...d.dll）和符号文件（.pdb 已被 .dll 过滤）
            if name.endswith("d.dll") and name.startswith("Qt6"):
                continue
            if name.startswith("Qt6"):
                qt6_dlls.append(name)

    # ── llvm-mingw 运行时（Qt 是用 clang/libc++ 编译的） ──
    # libc++.dll       : LLVM C++ 标准库；所有 Qt6*.dll 都直接依赖
    # libunwind.dll    : LLVM 异常展开库；Qt6Core.dll 直接依赖（即使 exe
    #                    自身没用异常也必须有，否则 LoadLibrary Qt6Core 失败）
    # d3dcompiler_47.dll : Qt RHI Direct3D 后端运行时编译 HLSL 用
    # opengl32sw.dll   : 软件 OpenGL 回退（当 GPU 驱动缺失/损坏时 Qt 使用）
    runtime_dlls = [
        "libc++.dll", "libunwind.dll",
        "d3dcompiler_47.dll", "opengl32sw.dll",
    ]

    core_dlls = qt6_dlls + runtime_dlls
    copied = 0
    for name in core_dlls:
        src = os.path.join(bin_src, name)
        if os.path.isfile(src):
            shutil.copy2(src, bin_dst)
            copied += 1
    info(f"已复制 {copied}/{len(core_dlls)} 个核心 DLL → {bin_dst}")

    # ── 2. 平台插件（必需）──
    #    Qt 在运行时按 ./plugins/platforms/qwindows.dll 这样的相对路径找
    plugin_groups = {
        "platforms": ["qwindows.dll"],
        "imageformats": ["qico.dll", "qjpeg.dll", "qsvg.dll", "qwebp.dll"],
        "iconengines": ["qsvgicon.dll"],
        "styles": ["qmodernwindowsstyle.dll", "qwindowsvistastyle.dll"],
    }
    for group, dlls in plugin_groups.items():
        sg = os.path.join(plugins_src, group)
        if not os.path.isdir(sg):
            continue
        dg = os.path.join(bin_dst, "plugins", group)
        os.makedirs(dg, exist_ok=True)
        for name in dlls:
            sp = os.path.join(sg, name)
            if os.path.isfile(sp):
                shutil.copy2(sp, dg)
    info(f"已复制平台/图像/样式插件 → {os.path.join(bin_dst, 'plugins')}")

    # ── 3. QML 模块（QtQuick 全家桶）──
    #    Main.qml 用了 QtQuick / QtQuick.Controls / QtQuick.Layouts /
    #    QtQuick.Dialogs / QtQuick.Window，再加 QtQml / QtCore 等隐式依赖。
    #    Qt 的 QML 模块互相 import 关系很复杂（Controls 依赖 Templates，
    #    Templates 依赖 Window，Dialogs 又拉 QuickDialogs2Impl 等），
    #    白名单维护成本高且容易漏。这里直接整目录复制 Qt 自带的 qml/，
    #    增加约 30MB 但保证万无一失。
    qml_dst = os.path.join(bin_dst, "qml")
    if os.path.isdir(qml_dst):
        shutil.rmtree(qml_dst)
    if os.path.isdir(qml_src):
        # 复制时跳过明显无关的大模块（如 QtCharts、QtWebEngine 等）以减小体积
        skip_dirs = {"QtCharts", "QtWebEngine", "QtWebEngineQuick",
                     "QtWebChannel", "QtWebChannelQuick",
                     "Qt5Compat", "QtTest", "QtBluetooth", "QtNfc",
                     "QtPositioning", "QtLocation", "QtSensors",
                     "QtSerialBus", "QtSerialPort", "Qt3D"}
        os.makedirs(qml_dst, exist_ok=True)
        for entry in os.listdir(qml_src):
            if entry in skip_dirs:
                continue
            src = os.path.join(qml_src, entry)
            dst = os.path.join(qml_dst, entry)
            if os.path.isdir(src):
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)
    info(f"已复制 QML 模块（按需，已跳过大型可选模块）→ {qml_dst}")

    # ── 4. 写一个 qt.conf，告诉 Qt 插件/QML 都在 exe 同目录下 ──
    #    没这个文件 Qt 会去找 build 时的绝对路径（macOS 上的 qt_dir），目标机当然没有
    qt_conf = os.path.join(bin_dst, "qt.conf")
    with open(qt_conf, "w") as f:
        f.write("[Paths]\nPrefix = .\nPlugins = plugins\nQml2Imports = qml\n")
    info(f"已写入 {qt_conf}")

    success("Qt 运行时部署完成，install_win 目录可直接拷贝到 Windows 运行")


def output_path(target: str) -> str:
    bdir = build_dir_for(target)
    bin_dir = os.path.join(bdir, "bin")
    if os.path.isdir(bin_dir):
        for entry in os.listdir(bin_dir):
            if entry.endswith(".app"):
                return os.path.join(bin_dir, entry)
        exe = "PlayerX.exe" if target == "windows" else "PlayerX"
        return os.path.join(bin_dir, exe)
    return ""


# ─── 主入口 ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="PlayerX 构建脚本（macOS / macOS→Windows 交叉）")
    parser.add_argument("-p", "--platform", choices=["macos", "windows"],
                        default="macos", help="目标平台（默认 macos）")
    parser.add_argument("--debug",      action="store_true", help="Debug 构建")
    parser.add_argument("--clean",      action="store_true", help="清理后重新构建")
    parser.add_argument("--clean-only", action="store_true", help="仅清理")
    args = parser.parse_args()

    target     = args.platform
    build_type = "Debug" if args.debug else "Release"

    if not IS_MACOS_HOST:
        warn(f"当前主机 {platform.system()}，本脚本目前仅在 macOS 上验证；将尽量继续。")

    if args.clean_only:
        clean(target); return
    if args.clean:
        clean(target)

    ffmpeg_dir = find_ffmpeg(target)
    qt_dir     = find_qt6(target)

    info(f"开始构建 PlayerX [{build_type}] target={target}")
    info(f"  源码:    {SOURCE_DIR}")
    info(f"  构建:    {build_dir_for(target)}")
    info(f"  安装:    {install_dir_for(target)}")
    info(f"  FFmpeg:  {ffmpeg_dir}")
    info(f"  Qt6:     {qt_dir}")

    configure(target, build_type, ffmpeg_dir, qt_dir)
    build(target)
    install(target)
    post_build(target, qt_dir)

    success("PlayerX 构建完成！")
    out = output_path(target)
    if out:
        success(f"产物: {out}")
        if out.endswith(".app"):
            success(f"启动: open '{out}'")

if __name__ == "__main__":
    main()
