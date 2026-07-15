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
import time

IS_MACOS_HOST = platform.system() == "Darwin"

# ─── 路径配置 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIR = SCRIPT_DIR                                # PlayerX/
BUILD_ROOT = os.path.join(SOURCE_DIR, "build")         # PlayerX/build/

# PlayerX 自包含依赖目录（独立后默认位置）
THIRD_PARTY_DIR = os.path.join(SOURCE_DIR, "third_party")
SCRIPTS_DIR     = os.path.join(SOURCE_DIR, "scripts")

# 旧仓库结构兼容（独立前 PlayerX 是子目录，FFmpeg 在 PlayerX/../build/ffmpeg）
REPO_ROOT_LEGACY    = os.path.dirname(SOURCE_DIR)
PARENT_BUILD_LEGACY = os.path.join(REPO_ROOT_LEGACY, "build")

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
    """探测 FFmpeg 静态库安装目录。

    搜索优先级：
      1) 环境变量 FFMPEG_INSTALL_DIR（最高优先级，CI/外部最干净）
      2) PlayerX/third_party/ffmpeg/build/install[_win]（独立后默认位置）
      3) PlayerX/../build/ffmpeg/install[_win]（旧仓库结构向后兼容）
    """
    sub = "install_win" if target == "windows" else "install"

    # 1) 环境变量
    env_p = os.environ.get("FFMPEG_INSTALL_DIR")
    if env_p:
        if os.path.isdir(env_p) and os.path.isdir(os.path.join(env_p, "lib")):
            return env_p
        warn(f"FFMPEG_INSTALL_DIR={env_p} 无效，将继续在默认位置搜索")

    # 2) 内置 third_party（产物在 PlayerX/build/third_party/ffmpeg/install[_win]）
    builtin = os.path.join(BUILD_ROOT, "third_party", "ffmpeg", sub)
    # 3) 旧路径（兼容迁移过渡期）
    legacy  = os.path.join(PARENT_BUILD_LEGACY, "ffmpeg", sub)

    candidates = [builtin, legacy]
    for p in candidates:
        if os.path.isdir(p) and os.path.isdir(os.path.join(p, "lib")):
            return p

    error("未找到 FFmpeg 安装目录，已尝试以下路径：")
    error(f"  环境变量 FFMPEG_INSTALL_DIR = {os.environ.get('FFMPEG_INSTALL_DIR', '<未设置>')}")
    for p in candidates:
        error(f"  {p}")
    error("请先在 PlayerX 内置的依赖脚本里构建 FFmpeg：")
    plat = "windows" if target == "windows" else "macos"
    error(f"  python3 scripts/build_deps.py -p {plat}")
    error("或单独构建 FFmpeg：")
    error(f"  python3 scripts/build_ffmpeg.py -p {plat}")
    error("如果尚未拉取 FFmpeg 源码（third_party/ffmpeg 为空），先执行：")
    error("  git submodule update --init --recursive")
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


# ─── 应用图标生成 ─────────────────────────────────────────────────────────────
#
# 单一图源：PlayerX/resources/icon/icon-1024.png
# 派生产物：
#   * icon.icns —— macOS bundle 图标（CMake 通过 MACOSX_BUNDLE_ICON_FILE 引用）
#   * icon.ico  —— Windows exe 嵌入图标（resources/app.rc 引用）+ NSIS 安装器图标
# 设计原则：图源换了只需重新跑 build.py，无需任何手工同步；CMake/NSIS 永远引用
# 派生产物的固定文件名（icon.icns / icon.ico），不感知图源改动。
# ──────────────────────────────────────────────────────────────────────────────
def prepare_icons():
    """按需从 icon-1024.png 生成 icon.icns 与 icon.ico；已是最新则跳过。

    macOS：用系统自带 sips + iconutil（零依赖）。
    Windows .ico：先用 sips 生成 16/32/48/64/128/256 六个尺寸 PNG，然后用 Python
                  zlib 标准库手写最小可用 ICO 头（PNG-in-ICO，Vista+ 支持）。
                  这样不引入 Pillow 依赖，与现有工具栈一致。
    """
    icon_dir = os.path.join(SOURCE_DIR, "resources", "icon")
    src_png  = os.path.join(icon_dir, "icon-1024.png")
    icns_out = os.path.join(icon_dir, "icon.icns")
    ico_out  = os.path.join(icon_dir, "icon.ico")

    if not os.path.isfile(src_png):
        warn(f"未找到图源 {src_png}，跳过图标生成（应用将无自定义图标）")
        return

    src_mtime = os.path.getmtime(src_png)

    # ── 1) macOS .icns（仅在 macOS 主机上生成；Windows 交叉编译也是从 macOS 跑的，
    #     所以这里不做平台过滤，反正 sips/iconutil 都是 macOS 工具）──
    if IS_MACOS_HOST and (
        not os.path.isfile(icns_out) or os.path.getmtime(icns_out) < src_mtime
    ):
        info(f"生成 macOS 图标: {icns_out}")
        # iconutil 需要标准命名的 .iconset 目录
        iconset = os.path.join(icon_dir, "_icon.iconset")
        if os.path.isdir(iconset):
            shutil.rmtree(iconset)
        os.makedirs(iconset)
        # Apple 要求的 9 个尺寸（含 @2x）
        sizes = [
            (16,  "icon_16x16.png"),     (32,  "icon_16x16@2x.png"),
            (32,  "icon_32x32.png"),     (64,  "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),   (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),   (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),   (1024,"icon_512x512@2x.png"),
        ]
        for sz, name in sizes:
            subprocess.run(
                ["sips", "-z", str(sz), str(sz), src_png, "--out",
                 os.path.join(iconset, name)],
                check=True, capture_output=True,
            )
        subprocess.run(
            ["iconutil", "-c", "icns", iconset, "-o", icns_out],
            check=True, capture_output=True,
        )
        shutil.rmtree(iconset)
        success(f"已生成 {os.path.basename(icns_out)}")

    # ── 2) Windows .ico（多尺寸 PNG-in-ICO，Vista+ 支持） ──
    if not os.path.isfile(ico_out) or os.path.getmtime(ico_out) < src_mtime:
        info(f"生成 Windows 图标: {ico_out}")
        ico_sizes = [16, 32, 48, 64, 128, 256]
        png_blobs = []
        for sz in ico_sizes:
            tmp = os.path.join(icon_dir, f"_icon_{sz}.png")
            subprocess.run(
                ["sips", "-z", str(sz), str(sz), src_png, "--out", tmp],
                check=True, capture_output=True,
            )
            with open(tmp, "rb") as f:
                png_blobs.append((sz, f.read()))
            os.remove(tmp)

        # 手写 ICO 文件头（参见 https://en.wikipedia.org/wiki/ICO_(file_format)）
        # ICONDIR (6 bytes): reserved=0, type=1(ICO), count=N
        # ICONDIRENTRY (16 bytes each):
        #   width(1, 0=256), height(1, 0=256), colors(1)=0, reserved(1)=0,
        #   planes(2)=1, bpp(2)=32, size(4), offset(4)
        import struct
        n = len(png_blobs)
        header = struct.pack("<HHH", 0, 1, n)
        entries = b""
        offset = 6 + 16 * n
        for sz, blob in png_blobs:
            w = h = 0 if sz == 256 else sz
            entries += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32,
                                   len(blob), offset)
            offset += len(blob)
        with open(ico_out, "wb") as f:
            f.write(header)
            f.write(entries)
            for _, blob in png_blobs:
                f.write(blob)
        success(f"已生成 {os.path.basename(ico_out)}")


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


def install(target: str, deploy_qt: bool = False):
    """cmake --install 到 install_dir。

    deploy_qt=False（本地快速测试，不带 --package）：
        直接 cmake --install，不清空旧目录。
        等同于早期 test.py 的行为，速度快、产物可直接 open .app 调试。
        如果 install 目录已经是上次 macdeployqt 处理过的产物（rpath 都被剥光），
        cmake 的 install_name_tool -delete_rpath 会找不到目标而失败 —— 
        这种情况只会出现在「上次 --package 跑过、这次普通跑」时，本地测试本就
        不需要重新 install，直接跳过即可。

    deploy_qt=True（--package / --package-only）：
        必须清空旧 install 目录后再 cmake --install。
        因为下一步 post_build 会用 macdeployqt 改写产物里的 rpath，下一轮打包时
        若不清掉残留，cmake install 阶段的 install_name_tool 改写一定失败。
    """
    bdir = build_dir_for(target)
    idir = install_dir_for(target)

    if not deploy_qt:
        # 本地测试模式：install 目录已存在就跳过，避免 rpath 改写出错；
        # 否则做一次干净的 cmake --install（首次构建用得到）。
        if os.path.isdir(idir):
            info("本地测试模式：检测到 install 目录已存在，跳过 cmake --install")
            return
        run(["cmake", "--install", bdir])
        return

    # 打包模式：每次安装前必须把旧的 install 目录清掉。
    # 原因：CMake 在 install 阶段会用 install_name_tool 改写 LC_RPATH（删除构建机
    # 的 brew Qt / ffmpeg 绝对路径，加 @executable_path/../Frameworks）。这套改写
    # 只对「build tree → 干净的 install tree」这种全新拷贝才正确：
    #   * 第一次安装：源 binary 里有 /opt/homebrew/opt/qt/lib 这条 rpath，OK；
    #   * 第二次安装：install 目录里已是上次部署后的 binary，rpath 已被剥空，
    #     install_name_tool -delete_rpath 找不到目标，cmake --install 直接 abort：
    #       error: install_name_tool: no LC_RPATH load command with path:
    #              /opt/homebrew/opt/qt/lib found ...
    if os.path.isdir(idir):
        info(f"清理旧的 install 目录: {idir}")
        shutil.rmtree(idir, ignore_errors=True)

    run(["cmake", "--install", bdir])


def _detect_local_ip() -> str:
    """探测本机所在内网 IP（LAN 地址）。

    实现原理：向公网 IP:port 发起一个 UDP "connect"（不实际发包），让内核根据路由表
    选出出口网卡的地址，再读 socket.getsockname() 拿到它。这套做法在 macOS/Linux
    上都是标准解法，且无需真的联网、无需查 DNS，速度快、无副作用。

    换电脑/换 WiFi 每次会自动跟随当前网卡地址变化，符合"本地编译动态识别 IP"的诉求。
    完全离线（无路由）时会兜底为 127.0.0.1，走 loopback 也能连本机 server。
    """
    import socket
    ip = "127.0.0.1"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.settimeout(0.5)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        pass
    finally:
        try:
            s.close()
        except Exception:
            pass
    return ip


def emit_dev_upload_config(target: str):
    """在 build tree 的 .app（macOS）或 install/bin（Windows）里写入开发者上传直连配置。

    动机：
      - 我每次都用 `python3 build.py` 编本地版，产物直接 open .app 调试；
      - 服务端就跑在同一台开发机的 http://<内网 IP>:8765/（token=10086）；
      - 换电脑内网 IP 会变，端口不变；不想每次都手动 export 一长串环境变量。
    因此把"开发者本机 URL"作为编译期动态数据，落到 .app 内 Resources/dev-upload.conf。
    C++ RatingStore 构造时读这个文件即可拿到 dev URL；优先级排在环境变量之下、
    远端 clientConfig 之上。

    文件位置：
      - macOS   : <build/out/bin/PlayerX.app>/Contents/Resources/dev-upload.conf
      - Windows : <build/out_win/bin>/dev-upload.conf
    文件格式（简单 KV，每行一个）：
        url=http://10.35.17.93:8765/
        token=10086

    关键行为：
      - 打包模式（--package/--package-only）不会调用本函数，因此正式分发产物永远不会带该文件；
      - 只写 build tree（build/out/bin），不写 install 目录，避免污染 `cmake --install` 产物；
      - 目标目录不存在时安静返回，不阻断构建。
    """
    ip    = _detect_local_ip()
    url   = f"http://{ip}:8765/"
    token = "10086"
    content = f"url={url}\ntoken={token}\n"

    if target == "windows":
        # Windows：exe 同目录（install/bin 由 post_build 部署完成，这里挑 build tree 的 bin，
        # 因为普通模式不清空 install 目录，写 install 反而可能落到已部署产物里）
        bin_dir = os.path.join(build_dir_for(target), "bin")
        if not os.path.isdir(bin_dir):
            return
        conf_path = os.path.join(bin_dir, "dev-upload.conf")
        with open(conf_path, "w", encoding="utf-8") as f:
            f.write(content)
        info(f"[dev-upload] 已写入 {conf_path}  → {url}  token={token}")
        return

    # macOS：找到 build tree 的 .app，写进 Contents/Resources/
    bin_dir = os.path.join(build_dir_for(target), "bin")
    if not os.path.isdir(bin_dir):
        return
    app_path = None
    for entry in os.listdir(bin_dir):
        if entry.endswith(".app"):
            app_path = os.path.join(bin_dir, entry); break
    if not app_path:
        return
    res_dir = os.path.join(app_path, "Contents", "Resources")
    os.makedirs(res_dir, exist_ok=True)
    conf_path = os.path.join(res_dir, "dev-upload.conf")
    with open(conf_path, "w", encoding="utf-8") as f:
        f.write(content)
    info(f"[dev-upload] 已写入 {conf_path}  → {url}  token={token}")


def post_build(target: str, qt_dir: str, deploy_qt: bool = False):
    """平台相关后处理：
    macOS  → ad-hoc 签名 .app
    Windows→ strip 调试符号 + 复制 Qt 运行时 DLL（若 Qt 安装目录可见）
    """
    if target == "macos" and IS_MACOS_HOST and not deploy_qt:
        # ── 本地测试模式（不带 --package） ──
        # 等同早期 test.py 的行为：直接对 build tree 的 .app 跑 ad-hoc 签名，
        # 让本机能 open .app 调试。不跑 macdeployqt（耗时长且会改写 rpath，
        # 影响下次打包链路），不动 install 目录。
        bdir = build_dir_for(target)
        bin_dir = os.path.join(bdir, "bin")
        if os.path.isdir(bin_dir):
            for entry in os.listdir(bin_dir):
                if entry.endswith(".app"):
                    app_path = os.path.join(bin_dir, entry)
                    info(f"对 {entry} 进行 ad-hoc 签名（本地测试模式）...")
                    subprocess.run(
                        ["codesign", "--sign", "-", "--force", "--deep", app_path],
                        check=False,
                    )
                    success("签名完成")
                    return
        return

    if target == "macos" and IS_MACOS_HOST and deploy_qt:
        # ── 打包模式：macdeployqt 必须跑在 install 目录的 .app 上 ──
        # build 目录的 .app 在 cmake --install 后已被 install_name_tool 改写过
        # LC_RPATH，再让 macdeployqt 处理会找不到 brew Qt：
        #     ERROR: Cannot resolve rpath "@rpath/QtQml.framework/..."
        # install 目录是每次 install() 重新清空+全量拷贝出来的，binary 里仍然
        # 保留 brew Qt 的绝对路径，macdeployqt 才能正确解析依赖。
        idir = install_dir_for(target)
        bin_dir = idir
        if os.path.isdir(bin_dir):
            for entry in os.listdir(bin_dir):
                if entry.endswith(".app"):
                    app_path = os.path.join(bin_dir, entry)

                    # ── 关键步骤：用 macdeployqt 把 Qt 框架/插件/QML 模块内嵌进 .app ──
                    # 不做这一步，主程序依赖会残留 /opt/homebrew/.../Qt*.framework
                    # 之类的绝对路径。开发机本地能跑（brew Qt 在 /opt/homebrew 下），
                    # 但分发到没装 brew Qt 的用户机上，dyld 会因
                    #   "Library not loaded: /opt/homebrew/.../QtQuickControls2.framework"
                    # 在启动期 SIGABRT。macdeployqt 会把 framework 复制到
                    # Contents/Frameworks/ 并把依赖改写为 @rpath/...，使 .app 自包含。
                    macdeploy = os.path.join(qt_dir, "bin", "macdeployqt") if qt_dir else ""
                    if not macdeploy or not os.path.isfile(macdeploy):
                        macdeploy = shutil.which("macdeployqt") or ""
                    if not macdeploy:
                        error("未找到 macdeployqt，无法生成可分发的 .app；"
                              "请确认 Qt6 安装完整（brew install qt 或设置 QT6_DIR）")
                        sys.exit(1)

                    qml_src = os.path.join(SOURCE_DIR, "qml")
                    info(f"运行 macdeployqt 内嵌 Qt 运行时: {entry}")
                    deploy_cmd = [
                        macdeploy, app_path,
                        "-always-overwrite",
                        "-verbose=1",
                    ]
                    # 项目使用了大量 QtQuick.Controls / 自定义 QML，
                    # 必须显式 -qmldir 让 macdeployqt 扫到所有 import 并打包对应 QML 模块。
                    if os.path.isdir(qml_src):
                        deploy_cmd.append(f"-qmldir={qml_src}")
                    r = subprocess.run(deploy_cmd)
                    if r.returncode != 0:
                        error("macdeployqt 失败，生成的 .app 在其他机器上无法启动")
                        sys.exit(1)
                    success("macdeployqt 完成（Qt 已内嵌到 .app）")

                    # macdeployqt 会改写大量二进制依赖，旧的 ad-hoc 签名随之失效，
                    # 必须重新整体签一次（--deep 覆盖所有内嵌 framework / dylib / 插件）。
                    info(f"对 {entry} 进行 ad-hoc 签名...")
                    subprocess.run(
                        ["codesign", "--sign", "-", "--force", "--deep",
                         "--timestamp=none", app_path],
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
    #    tls 子目录是 Qt 6.2+ 的关键变化：HTTPS 走 QNetworkAccessManager 时，
    #    必须能加载到至少一个 TLS 后端（schannel/openssl/certonly），
    #    否则 QSslSocket 直接报 "TLS initialization failed"，
    #    自动更新 GET https://.../latest.json 会瞬间挂掉。
    #    策略：tls/ 整目录复制（一共就几个 dll），一并兼容 schannel 和 openssl。
    plugin_groups = {
        "platforms": ["qwindows.dll"],
        "imageformats": ["qico.dll", "qjpeg.dll", "qsvg.dll", "qwebp.dll"],
        "iconengines": ["qsvgicon.dll"],
        "styles": ["qmodernwindowsstyle.dll", "qwindowsvistastyle.dll"],
        # "*" 表示该目录下所有 dll 整目录复制
        "tls": ["*"],
        # networkinformation 提供 "在线/离线" 检测，Qt 6.6+ 上 Network 模块
        # 在某些路径会去 load 这些后端；带上以防万一（仅当目录存在时拷贝）
        "networkinformation": ["*"],
    }
    for group, dlls in plugin_groups.items():
        sg = os.path.join(plugins_src, group)
        if not os.path.isdir(sg):
            continue
        dg = os.path.join(bin_dst, "plugins", group)
        os.makedirs(dg, exist_ok=True)
        if dlls == ["*"]:
            for name in os.listdir(sg):
                if not name.lower().endswith(".dll"):
                    continue
                # 注意：这里**不能**用 endswith("d.dll") 当 debug 过滤条件，
                # Qt 的 plugins/tls/ 下三个 dll 名字都以 "backend.dll" 结尾
                # （qopensslbackend.dll / qschannelbackend.dll /
                # qcertonlybackend.dll），会全部误命中导致 TLS 后端被全部跳过，
                # 客户端表现为 "TLS initialization failed"，HTTPS 完全不可用。
                # 我们装的是 Release Qt SDK，plugins 目录里本来就没有 debug 版，
                # 直接全量复制最稳妥。
                shutil.copy2(os.path.join(sg, name), dg)
        else:
            for name in dlls:
                sp = os.path.join(sg, name)
                if os.path.isfile(sp):
                    shutil.copy2(sp, dg)
    info(f"已复制平台/图像/样式/TLS 插件 → {os.path.join(bin_dst, 'plugins')}")

    # ── 2.1 OpenSSL 运行时（必需，用于 HTTPS / 自动更新）──
    #    aqt 装的 win64_llvm_mingw 包里 tls/qopensslbackend.dll 存在，
    #    但 OpenSSL 的 libssl-3-x64.dll / libcrypto-3-x64.dll 要单独装：
    #        ~/.local/bin/aqt install-tool windows desktop tools_opensslv3_x64
    #    默认装到 ~/Qt/Tools/OpenSSLv3/Win_x64/bin/。
    #    qopensslbackend.dll 找不到这两个 dll 时会加载失败，导致
    #    QSslSocket 没有可用 TLS 后端，QNetworkAccessManager 一发 HTTPS
    #    就报 "TLS initialization failed"，自动更新拉不到 latest.json。
    openssl_candidates = [
        "libssl-3-x64.dll", "libcrypto-3-x64.dll",      # OpenSSL 3.x
        "libssl-1_1-x64.dll", "libcrypto-1_1-x64.dll",  # OpenSSL 1.1.x
    ]
    # 候选搜索路径（按优先级）：
    #   1. 环境变量 OPENSSL_WIN_DIR（用户显式指定的 OpenSSL 安装根，要求 bin/ 子目录里有 dll）
    #   2. Qt 包自身的 bin/（极少见，部分自编译 SDK 会附带）
    #   3. aqt 标准位置：~/Qt/Tools/OpenSSLv3/Win_x64/bin/
    home = os.path.expanduser("~")
    openssl_dirs: list[str] = []
    env_p = os.environ.get("OPENSSL_WIN_DIR")
    if env_p:
        openssl_dirs.append(os.path.join(env_p, "bin"))
        openssl_dirs.append(env_p)
    openssl_dirs.append(bin_src)
    openssl_dirs.append(os.path.join(home, "Qt", "Tools", "OpenSSLv3", "Win_x64", "bin"))

    found_openssl = 0
    for name in openssl_candidates:
        for d in openssl_dirs:
            sp = os.path.join(d, name)
            if os.path.isfile(sp):
                shutil.copy2(sp, bin_dst)
                info(f"已复制 OpenSSL 运行时: {name}  (来自 {d})")
                found_openssl += 1
                break
    if found_openssl < 2:
        warn(
            "未找到 OpenSSL 运行时（libssl-3-x64.dll / libcrypto-3-x64.dll），"
            "Windows 端 HTTPS 将失败（TLS initialization failed）。\n"
            "    请执行：~/.local/bin/aqt install-tool --outputdir ~/Qt windows desktop tools_opensslv3_x64\n"
            "    或显式设置：export OPENSSL_WIN_DIR=/path/to/openssl_root"
        )

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


# ─── 分发包打包 ────────────────────────────────────────────────────────────────
#
#  macOS  → dist/PlayerX-x.y.z-arm64-mac.zip   （ditto 保留 .app 元数据/签名）
#  Windows→ dist/PlayerX-Setup-x.y.z.exe       （NSIS 安装版）
#         + dist/PlayerX-x.y.z-portable.exe    （单文件 portable，自带 7z SFX）
#  同时输出 release/latest.json 模板与 sha256，便于上传 CDN。
#
#  自动更新通道命名严格对应 Updater::platformKey()：
#     mac-arm64 / mac-x64 / win-install / win-portable
# ──────────────────────────────────────────────────────────────────────────────
def _read_app_version() -> str:
    """从 CMakeLists.txt 的 project(PlayerX VERSION x.y.z ...) 提取版本号。
    单点维护：所有打包/发布脚本都以 CMakeLists 为准，不在多处复制版本号。"""
    cmake = os.path.join(SOURCE_DIR, "CMakeLists.txt")
    import re
    with open(cmake, "r", encoding="utf-8") as f:
        for line in f:
            m = re.search(r"project\s*\(\s*PlayerX\s+VERSION\s+([0-9.]+)", line)
            if m:
                return m.group(1)
    return "0.0.0"


def _bump_app_version(new_version: str, allow_overwrite: bool = False) -> str:
    """原地修改 CMakeLists.txt 的 project(PlayerX VERSION x.y.z ...) 行。

    - new_version 必须形如 X.Y.Z（三段数字），否则报错退出；
    - 默认要求新版本严格大于当前版本（语义版本比较），避免误降级；
    - allow_overwrite=True 时跨过递增检查，用于：
        * 同版本重打包（未上传过，只是同一版本号重新出包）→检测后跳过写文件；
        * 主动降级（发现新版重大缺陷需要带给用户临时回退）→重写 + warn。
    - 写回时保留行尾其它内容（LANGUAGES CXX C 等）。
    返回写入后的版本号。"""
    import re
    if not re.fullmatch(r"\d+\.\d+\.\d+", new_version):
        error(f"--bump 版本号格式错误，应为 X.Y.Z（如 2.0.5），收到: {new_version}")
        sys.exit(1)

    cur     = _read_app_version()
    new_t   = tuple(int(x) for x in new_version.split("."))
    cur_t   = tuple(int(x) for x in cur.split("."))
    if new_t < cur_t:
        if not allow_overwrite:
            error(f"新版本 {new_version} 小于当前 {cur}（避免误降级）；如确需回退请加 --force")
            sys.exit(1)
        warn(f"⚠ 正在将版本号从 {cur} **回退** 到 {new_version}（--force 已启用）")
    elif new_t == cur_t:
        if not allow_overwrite:
            error(f"新版本 {new_version} 必须严格大于当前 {cur}（避免误降级）；如需同版本号重打包请加 --force")
            sys.exit(1)
        info(f"同版本号重打包: {new_version}（跳过写 CMakeLists.txt）")
        return cur

    cmake = os.path.join(SOURCE_DIR, "CMakeLists.txt")
    with open(cmake, "r", encoding="utf-8") as f:
        text = f.read()
    new_text, n = re.subn(
        r"(project\s*\(\s*PlayerX\s+VERSION\s+)[0-9.]+",
        r"\g<1>" + new_version,
        text, count=1,
    )
    if n != 1:
        error(f"未在 {cmake} 中匹配到 project(PlayerX VERSION ...) 行")
        sys.exit(1)
    with open(cmake, "w", encoding="utf-8") as f:
        f.write(new_text)
    success(f"版本号已更新: {cur} → {new_version}  ({cmake})")
    return new_version


def _sha256_file(path: str) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _ensure_dist_dir() -> str:
    # 产物目录与 build.py 同级，避免污染父工程根目录
    # dist/ 仅放每次构建重新生成的二进制产物（zip / Setup.exe），可随时整目录删除
    d = os.path.join(SOURCE_DIR, "dist")
    os.makedirs(d, exist_ok=True)
    return d


def _ensure_release_dir() -> str:
    """发布元数据目录：长期保留、累积演进，**不**应被 `rm -rf dist` 误删。

    放置内容：
      - latest.json（自动更新清单：版本号 / sha256 / 真实 CDN url / notes ...）
    与 dist/ 严格分离，对齐业界做法（npm pack 输出 vs package.json）。
    """
    d = os.path.join(SOURCE_DIR, "release")
    os.makedirs(d, exist_ok=True)
    return d


def package_macos(version: str) -> dict:
    """打 macOS .zip 分发包（ditto 保留签名/扩展属性，行业标准做法）。"""
    # 必须从 install 目录取 .app，而不是 build/out/bin。
    # 因为 macdeployqt 是在 post_build 阶段对 install 目录的 .app 做的内嵌处理，
    # build/out/bin/PlayerX.app 仍依赖构建机本地的 brew Qt，分发到别人机器上必崩。
    idir = install_dir_for("macos")
    bin_dir = idir
    app = None
    for entry in os.listdir(bin_dir) if os.path.isdir(bin_dir) else []:
        if entry.endswith(".app"):
            app = os.path.join(bin_dir, entry); break
    if not app:
        error("未找到 .app 产物，请先执行常规构建")
        sys.exit(1)

    arch = "arm64" if platform.machine() == "arm64" else "x64"
    dist = _ensure_dist_dir()
    zip_path = os.path.join(dist, f"PlayerX-{version}-{arch}-mac.zip")
    if os.path.exists(zip_path):
        os.remove(zip_path)
    info(f"打包 .app → {zip_path}")

    # ── 打包前防御性清理（避免构建机历史 xattr / 只读权限污染分发包）──
    # 0) 剔除开发者调试文件：若此前跑过 `python3 build.py`（非 --package），
    #    install 目录里可能残留 Contents/Resources/dev-upload.conf；正式分发包
    #    绝对不能带上"开发机内网 IP + token" 泄露到用户机，这里主动删干净。
    dev_conf = os.path.join(app, "Contents", "Resources", "dev-upload.conf")
    if os.path.isfile(dev_conf):
        info(f"[dev-upload] 打包前剔除调试配置: {dev_conf}")
        try:
            os.remove(dev_conf)
        except OSError as e:
            warn(f"删除 {dev_conf} 失败（可能被锁定，请手动清理）: {e}")
    # 1) 补全 owner 写权限：ditto 不会改权限，只读文件会让用户端二次操作（rm/mv）失败
    run(["chmod", "-R", "u+w", app], check=False)
    # 2) 清掉所有扩展属性（quarantine / provenance / 资源派生属性等）
    run(["xattr", "-rc", app], check=False)
    # 3) xattr 改动会让原 ad-hoc 签名失效，重签一次保证用户端启动不被 Gatekeeper 拦
    run(["codesign", "--force", "--deep", "--sign", "-", app], check=False)

    # ditto 是 macOS 官方推荐方式：保留 codesign 签名、xattr、符号链接
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path])
    sha = _sha256_file(zip_path)
    success(f"macOS zip: {zip_path}  sha256={sha[:16]}…")
    return {f"mac-{arch}": {"path": zip_path, "sha256": sha}}


def package_windows(version: str) -> dict:
    """打 Windows install / portable 双形态。"""
    idir = install_dir_for("windows")
    src_bin = os.path.join(idir, "bin")
    if not os.path.isdir(src_bin):
        error(f"未找到 Windows 安装产物目录: {src_bin}\n请先 python3 build.py -p windows")
        sys.exit(1)

    # 打包前防御性清理：正式分发包绝不能带开发者调试配置（内网 IP + token 泄露风险）。
    # dev-upload.conf 是 `python3 build.py` 非 --package 模式下写到 build tree 的
    # bin/ 里的；理论上 cmake --install 不会拷贝它，但保险起见双重清理。
    dev_conf = os.path.join(src_bin, "dev-upload.conf")
    if os.path.isfile(dev_conf):
        info(f"[dev-upload] 打包前剔除调试配置: {dev_conf}")
        try:
            os.remove(dev_conf)
        except OSError as e:
            warn(f"删除 {dev_conf} 失败: {e}")

    dist = _ensure_dist_dir()
    out = {}

    # 1) NSIS Setup
    makensis = shutil.which("makensis")
    if not makensis:
        warn("未找到 makensis，跳过安装版打包。安装方法：brew install makensis")
    else:
        nsi = os.path.join(SOURCE_DIR, "installer", "PlayerX.nsi")
        if not os.path.isfile(nsi):
            error(f"未找到 NSIS 脚本: {nsi}")
            sys.exit(1)
        info(f"调用 makensis 构建 Setup ...")
        # 通过 -D 把变量注入 NSI；OUT_DIR 必须是相对于 nsi 文件的路径
        rel_src = os.path.relpath(src_bin, os.path.dirname(nsi))
        rel_out = os.path.relpath(dist,    os.path.dirname(nsi))
        cmd = [
            makensis,
            f"-DAPP_VERSION={version}",
            f"-DSRC_DIR={rel_src}",
            f"-DOUT_DIR={rel_out}",
        ]
        # 安装/卸载器图标：build.py 已经把 .ico 派生好了，存在则注入
        ico_path = os.path.join(SOURCE_DIR, "resources", "icon", "icon.ico")
        if os.path.isfile(ico_path):
            rel_ico = os.path.relpath(ico_path, os.path.dirname(nsi))
            cmd.append(f"-DAPP_ICON={rel_ico}")
        cmd.append(nsi)
        run(cmd, cwd=os.path.dirname(nsi))
        setup_exe = os.path.join(dist, f"PlayerX-Setup-{version}.exe")
        if os.path.isfile(setup_exe):
            sha = _sha256_file(setup_exe)
            out["win-install"] = {"path": setup_exe, "sha256": sha}
            success(f"Windows Setup: {setup_exe}  sha256={sha[:16]}…")
        else:
            error(f"NSIS 输出未找到: {setup_exe}")

    # 2) Portable：直接打 ZIP 整包（行业标准做法，VS Code/JetBrains 同款）
    #    用户解压到任意目录，双击 PlayerX.exe 即可运行；
    #    自更新走 Updater 的 portable 分支：下载新 zip → 解压覆盖整个安装目录 → 重启。
    #    （早期方案曾尝试 7z SFX 单文件，但 SFX 是"解压器"而非 exe 本体，
    #     与"替换 exe"的自更新链路冲突，已废弃。）
    portable_zip = os.path.join(dist, f"PlayerX-{version}-win64-portable.zip")
    if os.path.exists(portable_zip):
        os.remove(portable_zip)
    info(f"打包 portable zip: {portable_zip}")

    # 用 Python 自带 zipfile，避免依赖 7z；compresslevel=9 体积最小
    import zipfile
    # 顶层目录**不带版本号**，固定为 "PlayerX/"。
    # 原因：portable 自更新会原地覆盖整个安装目录，若目录名跟版本绑定，
    #       用户从 2.0.7 升到 2.0.9 后还停在 PlayerX-2.0.7/，与程序内显示
    #       的版本不一致，桌面快捷方式也会因为目录改名而失效。
    #       业内主流做法（VS Code / JetBrains / Sublime）均是：
    #         - 文件名带版本（PlayerX-2.0.7-win64-portable.zip）便于多版本并存归档
    #         - 解压后的安装目录名固定（PlayerX/），随版本演进不变
    top = "PlayerX"
    with zipfile.ZipFile(portable_zip, "w",
                         compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as zf:
        for root, dirs, files in os.walk(src_bin):
            for name in files:
                fp = os.path.join(root, name)
                rel = os.path.relpath(fp, src_bin)
                zf.write(fp, arcname=os.path.join(top, rel))

    sha = _sha256_file(portable_zip)
    out["win-portable"] = {"path": portable_zip, "sha256": sha}
    success(f"Windows Portable: {portable_zip}  sha256={sha[:16]}…")

    return out


def _read_remote_url_template() -> str:
    """读取 release/remote-url.json 的 `url` 字段，返回带 `*` 占位的 URL 模板。

    设计动机：自动更新通道走真实 CDN 地址，但 CDN 域名/路径前缀和具体文件名
    解耦——base 由外部 JSON 配置（一次性维护，跟随 CDN 变更），文件名由打包
    流程动态生成。这样换 CDN 只改一处 JSON，不用动 build.py。

    文件格式（PlayerX/release/remote-url.json）：
        { "url": "https://example.com/path/*" }

    其中 `*` 会被替换成实际产物文件名（例如 PlayerX-3.0.7-arm64-mac.zip）。
    若 url 不含 `*`，回退到末尾拼 `/<fname>`。

    返回：
      - 模板字符串（成功）
      - "" （文件缺失 / 字段缺失 / 解析失败 —— 调用方回退到占位 URL）
    """
    import json
    cfg = os.path.join(_ensure_release_dir(), "remote-url.json")
    if not os.path.isfile(cfg):
        return ""
    try:
        with open(cfg, "r", encoding="utf-8") as f:
            obj = json.load(f) or {}
        u = (obj.get("url") or "").strip()
        return u
    except Exception as e:
        warn(f"读取 {cfg} 失败，将回退到占位 URL: {e}")
        return ""


def _resolve_download_url(template: str, fname: str) -> str:
    """按模板生成单个产物的下载 URL。

    - 模板含 `*`：替换为文件名（典型用法："https://cdn/path/*"）
    - 模板不含 `*` 但非空：当作 base 目录，末尾拼 `/<fname>`
    - 模板为空：返回占位 URL（旧行为，提醒上传 CDN 前手工替换）
    """
    if not template:
        return f"https://YOUR-CDN.example.com/PlayerX/{fname}"
    if "*" in template:
        return template.replace("*", fname)
    sep = "" if template.endswith("/") else "/"
    return f"{template}{sep}{fname}"


def write_latest_json(version: str, downloads: dict):
    """生成/合并 release/latest.json，给云端上传用。

    设计原则：脚本只**机械合并下载条目并刷新版本号 / sha256**，
    所有用户可读字段（notes / mandatory / minSupported / author / copyright /
    真实 CDN url）一律以现有文件为准——你手工编辑的内容永远不会被覆盖。

    - 同版本：合并 downloads（mac 跑一次更新 mac-* 字段，win 跑一次再补 win-*）；
    - 不同版本（CMakeLists 改了 VERSION）：保留 notes/mandatory 等元字段框架，
      但 downloads 字典清空重建（旧版本的 sha256 不可能匹配新包）。

    存放位置：`PlayerX/release/latest.json`（与 dist/ 分离，避免被 rm -rf dist 误删）。
    """
    import json
    release_dir = _ensure_release_dir()
    out_path = os.path.join(release_dir, "latest.json")

    # 一次性兼容迁移：若旧版本 latest.json 还在 dist/，搬到 release/，保留你手填的 notes
    legacy_path = os.path.join(_ensure_dist_dir(), "latest.json")
    if os.path.isfile(legacy_path) and not os.path.isfile(out_path):
        try:
            os.replace(legacy_path, out_path)
            info(f"已迁移旧 latest.json: dist/ → release/")
        except Exception as e:
            warn(f"迁移旧 latest.json 失败（将重建）: {e}")

    # 默认骨架：仅在 latest.json 完全不存在时使用
    base = {
        "version":      version,
        "minSupported": "1.0.0",
        "author":       "rbyang",
        "copyright":    "Copyright (c) 2025 PlayerX",
        "notes":        "",
        "mandatory":    False,
        "downloads":    {},
    }

    if os.path.isfile(out_path):
        try:
            with open(out_path, "r", encoding="utf-8") as f:
                old = json.load(f)
            # 元字段一律以旧文件为准（你手工维护）
            for k in ("minSupported", "author", "copyright", "notes", "mandatory", "clientConfig"):
                if k in old:
                    base[k] = old[k]
            # downloads：仅在版本号一致时合并，避免旧 sha256 跟新包混用
            if old.get("version") == version:
                base["downloads"] = dict(old.get("downloads") or {})
        except Exception as e:
            warn(f"读取旧 latest.json 失败，将重建: {e}")

    base["version"] = version

    # 计算"真实 CDN URL 模板"：优先读 release/remote-url.json 的 url 字段。
    # 这一步一旦拿到模板，本次写出的所有 downloads.url 都会被刷成模板生成的
    # 新地址（覆盖任何旧 url，包括用户手填的）——因为模板本身就是用户维护的
    # 单一真相源，重复维护两份地址只会带来不一致。
    # 模板缺失（文件不存在/字段空）才退回到旧逻辑："保留用户改过的真实 url，
    # 占位符按需重建"。
    url_tpl = _read_remote_url_template()
    if url_tpl:
        info(f"使用 CDN URL 模板: {url_tpl}")

    # 合并本次新生成的下载条目
    for chan, info_d in downloads.items():
        fname     = os.path.basename(info_d["path"])
        if url_tpl:
            new_url = _resolve_download_url(url_tpl, fname)
        else:
            old_entry = base["downloads"].get(chan) or {}
            old_url   = old_entry.get("url", "") if isinstance(old_entry, dict) else ""
            if old_url and "YOUR-CDN.example.com" not in old_url:
                new_url = old_url   # 用户已改为真实 CDN，保留之
            else:
                new_url = f"https://YOUR-CDN.example.com/PlayerX/{fname}"
        base["downloads"][chan] = {
            "url":    new_url,
            "sha256": info_d["sha256"],
        }

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(base, f, ensure_ascii=False, indent=2)
    success(f"已生成 {out_path}")
    if url_tpl:
        info("⚠ notes / mandatory 等字段请手工编辑 release/latest.json；下载 url 已按 release/remote-url.json 的模板生成")
    else:
        info("⚠ notes / mandatory 等字段请手工编辑 release/latest.json；url 占位符上传 CDN 前替换为真实域名（或在 release/remote-url.json 配置 url 模板自动生成")

def package(target: str):
    """对应 --package：常规 build/install 完成后生成分发包。"""
    version = _read_app_version()
    info(f"打包版本: {version} (target={target})")
    # 即便走 --package-only（跳过编译）也要保证 .ico 已存在，否则 NSIS 找不到
    prepare_icons()
    dl = {}
    if target == "macos":
        dl.update(package_macos(version))
    else:
        dl.update(package_windows(version))
    write_latest_json(version, dl)


# ─── 主入口 ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="PlayerX 构建脚本（macOS / macOS→Windows 交叉）")
    parser.add_argument("-p", "--platform", choices=["macos", "windows"],
                        default="macos", help="目标平台（默认 macos）")
    parser.add_argument("--debug",      action="store_true", help="Debug 构建")
    parser.add_argument("--clean",      action="store_true", help="清理后重新构建")
    parser.add_argument("--clean-only", action="store_true", help="仅清理")
    parser.add_argument("--package",    action="store_true",
                        help="构建后打分发包（macOS=.zip / Windows=Setup+portable）")
    parser.add_argument("--package-only", action="store_true",
                        help="跳过编译，仅基于现有 build/install 产物打分发包")
    parser.add_argument("--bump",       default="",
                        help="打包前先把 CMakeLists.txt 的版本号改成 X.Y.Z（默认要求严格递增）")
    parser.add_argument("-f", "--force", "--allow-version-overwrite",
                        dest="force", action="store_true",
                        help="允许 --bump 到与当前相同或更低的版本号（同版本重打包 / 临时回退专用）")
    # ── 开发者上传直连开关 ──
    # 每次本地 `python3 build.py`（macOS 非打包模式）默认会把开发者上传 URL
    # （http://<本机内网 IP>:8765/ + token=10086）写入 build tree 的 .app：
    #     <PlayerX.app>/Contents/Resources/dev-upload.conf
    # C++ 端 RatingStore 启动时会读这个文件，优先于远端 latest.json 的 clientConfig，
    # 让开发/联调本地打开的 .app 直连本机 server，换电脑无需改代码（每次编译动态取 IP）。
    # --no-dev-upload：偶尔想让本地编译版走"正式 URL"路径（比如复现线上问题）时使用。
    # --package/--package-only：自动跳过，不会往分发包里写这个文件。
    parser.add_argument("--no-dev-upload", action="store_true",
                        help="本地编译时不写入开发者上传直连配置（用于本地复现正式 URL 行为）")
    args = parser.parse_args()

    target     = args.platform
    build_type = "Debug" if args.debug else "Release"

    if not IS_MACOS_HOST:
        warn(f"当前主机 {platform.system()}，本脚本目前仅在 macOS 上验证；将尽量继续。")

    if args.clean_only:
        clean(target); return
    if args.bump:
        _bump_app_version(args.bump, allow_overwrite=args.force)
    elif args.force:
        warn("--force 仅在配合 --bump 时生效，已忽略")
    if args.package_only:
        package(target); return
    if args.clean:
        clean(target)

    ffmpeg_dir = find_ffmpeg(target)
    qt_dir     = find_qt6(target)

    # 派生 .icns / .ico（图源未改动则秒过；放在 configure 之前，CMake 才能把
    # .icns 加入 bundle Resources、windres 才能把 .ico 嵌入 exe）
    prepare_icons()

    info(f"开始构建 PlayerX [{build_type}] target={target}")
    info(f"  源码:    {SOURCE_DIR}")
    info(f"  构建:    {build_dir_for(target)}")
    info(f"  安装:    {install_dir_for(target)}")
    info(f"  FFmpeg:  {ffmpeg_dir}")
    info(f"  Qt6:     {qt_dir}")

    # 是否进入「打包级」流程（清空 install、跑 macdeployqt 内嵌 Qt 运行时）。
    # --package / --package-only 都需要；普通 `python3 build.py` 走轻量本地测试。
    deploy_qt = bool(args.package)

    configure(target, build_type, ffmpeg_dir, qt_dir)
    build(target)
    install(target, deploy_qt=deploy_qt)
    post_build(target, qt_dir, deploy_qt=deploy_qt)

    # 本地编译（非打包）时把开发者上传直连配置写入 build tree 的 .app，
    # 让 C++ RatingStore 启动时能读到、优先于远端 clientConfig。
    # --package/--package-only 会走 deploy_qt=True 分支，此处严格跳过，
    # 保证正式包永远干净不带调试配置。
    if not deploy_qt and not args.no_dev_upload:
        emit_dev_upload_config(target)

    success("PlayerX 构建完成！")
    out = output_path(target)
    if out:
        success(f"产物: {out}")
        if out.endswith(".app"):
            success(f"启动: open '{out}'")

    if args.package:
        package(target)

if __name__ == "__main__":
    start_time = time.time()
    main()
    end_time = time.time()
    print(f"构建完成，耗时 {end_time - start_time:.2f} 秒")
    print("完成时间:", time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(end_time)))
