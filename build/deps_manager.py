#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os
import subprocess
import sys
import shutil


def run(cmd, cwd=None, capture_output=True):
    """运行命令的辅助函数"""
    print(f"\033[33m>>>\033[0m {' '.join(cmd)}  (cwd={cwd or os.getcwd()})\n")
    result = subprocess.run(cmd, cwd=cwd, capture_output=capture_output, text=True, encoding='utf-8', errors='replace')
    if result.returncode != 0:
        print(f"\033[31m!!! 命令执行失败: {' '.join(cmd)}\033[0m")
        if capture_output:
            print(f"\033[31m错误输出:\n{result.stderr}\033[0m")
        sys.exit(1)
    return result


def get_absolute_path(path):
    """获取绝对路径"""
    if os.path.isabs(path):
        return path
    return os.path.abspath(path)


def setup_sdl_ttf_dependencies(source_dir, script_dir):
    """设置SDL2_ttf的依赖库（freetype和harfbuzz）"""
    external_dir = os.path.join(source_dir, 'external')
    freetype_dir = os.path.join(external_dir, 'freetype')
    harfbuzz_dir = os.path.join(external_dir, 'harfbuzz')
    download_script = os.path.join(external_dir, 'download.sh')
    
    # 切换到SDL2_ttf源码目录并检出正确分支
    os.chdir(f"{script_dir}/../sdl_ttf")
    os.system("git checkout release-2.24.x")
    os.chdir(script_dir)
    
    # 检查是否需要下载依赖
    need_download = False
    if not os.path.exists(freetype_dir) or not os.listdir(freetype_dir):
        need_download = True
    if not os.path.exists(harfbuzz_dir) or not os.listdir(harfbuzz_dir):
        need_download = True
    
    if need_download:
        print("\033[34mUnix系统：使用download.sh下载依赖库...\033[0m")
        if os.path.exists(download_script):
            run(['sh', download_script], cwd=source_dir)
        else:
            print("\033[31m错误：找不到download.sh脚本\033[0m")
            sys.exit(1)
    
    # 构建Freetype库
    freetype_build_dir = os.path.join(script_dir, 'freetype/obj')
    freetype_install_dir = os.path.join(script_dir, 'freetype/install')
    
    if not os.path.exists(freetype_install_dir) or not os.listdir(freetype_install_dir):
        print(f"\033[34m构建Freetype库...\033[0m")
        if os.path.exists(freetype_build_dir):
            shutil.rmtree(freetype_build_dir)
        if os.path.exists(freetype_install_dir):
            shutil.rmtree(freetype_install_dir)
        os.makedirs(freetype_build_dir, exist_ok=True)
        os.makedirs(freetype_install_dir, exist_ok=True)
        
        freetype_cmake_args = [
            'cmake', freetype_dir,
            f'-B{freetype_build_dir}',
            f'-DCMAKE_BUILD_TYPE=Release',
            f'-DCMAKE_INSTALL_PREFIX={freetype_install_dir}',
            f'-DBUILD_SHARED_LIBS=OFF'  # 构建静态库
        ]
        
        try:
            run(freetype_cmake_args, cwd=freetype_build_dir)
            run(['make', '-j', str(os.cpu_count() or 1)], cwd=freetype_build_dir)
            run(['make', 'install'], cwd=freetype_build_dir)
        except SystemExit:
            print("\033[31mFreetype构建失败\033[0m")
            sys.exit(1)
    
    return freetype_install_dir


if __name__ == '__main__':
    print("这是一个依赖管理模块，请通过build_tools.py调用")