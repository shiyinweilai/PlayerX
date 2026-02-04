import os
import time
import argparse

if __name__ == "__main__":
    print("\033c", end="")
    parser = argparse.ArgumentParser(description="构建工具")
    parser.add_argument('-p','--platform', choices=['windows', 'macos', 'linux'], required=True, help='目标平台')
    args = parser.parse_args()
    cmd_sdl = f"python3 build_tools.py --target sdl2 -s ../sdl -p {args.platform} -m static"
    cmd_sdl_ttf = f"python3 build_tools.py --target sdl2_ttf -s ../sdl_ttf -p {args.platform} -m static"
    cmd_ffmpeg = f"python3 build_tools.py --target ffmpeg -s ../ffmpeg -p {args.platform} -m static"
    cmd_video_compare = f"python3 build_tools.py --target video_compare -s ../video-compare -p {args.platform} -m static"
    start_time = time.time()
    print(f"\033[33m>>>> 开始构建...\033[0m")
    # os.system(cmd_sdl)
    # os.system(cmd_sdl_ttf)
    # os.system(cmd_ffmpeg)
    os.system(cmd_video_compare)

    # 自动复制构建产物到 src/external
    import shutil
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.join(os.path.dirname(script_dir), "app", "src", "external")
    
    if args.platform == 'windows':
        vc_src = os.path.join(script_dir, 'video_compare', 'install_win', 'bin', 'video-compare.exe')
        vc_dst_dir = os.path.join(project_root, 'win-inner')
        ff_src = os.path.join(script_dir, 'ffmpeg', 'install_win', 'bin', 'ffprobe.exe')
        
        if os.path.exists(vc_src):
            os.makedirs(vc_dst_dir, exist_ok=True)
            shutil.copy2(vc_src, vc_dst_dir)
            print(f"\033[32m>>>> 已复制 video-compare.exe 到 {vc_dst_dir}\033[0m")
        
        if os.path.exists(ff_src):
            os.makedirs(vc_dst_dir, exist_ok=True)
            shutil.copy2(ff_src, vc_dst_dir)
            print(f"\033[32m>>>> 已复制 ffprobe.exe 到 {vc_dst_dir}\033[0m")

    elif args.platform == 'macos':
        vc_src = os.path.join(script_dir, 'video_compare', 'install', 'bin', 'video-compare')
        vc_dst_dir = os.path.join(project_root, 'mac-inner')
        ff_src = os.path.join(script_dir, 'ffmpeg', 'install', 'bin', 'ffprobe')
        
        if os.path.exists(vc_src):
            os.makedirs(vc_dst_dir, exist_ok=True)
            shutil.copy2(vc_src, vc_dst_dir)
            print(f"\033[32m>>>> 已复制 video-compare 到 {vc_dst_dir}\033[0m")
            
        if os.path.exists(ff_src):
            os.makedirs(vc_dst_dir, exist_ok=True)
            shutil.copy2(ff_src, vc_dst_dir)
            print(f"\033[32m>>>> 已复制 ffprobe 到 {vc_dst_dir}\033[0m")

    print(f"\033[33m>>>> 所有构建完成!\033[0m")
    end_time = time.time()
    elapsed_time = end_time - start_time
    print(f"\033[32m>>>> 总用时: {elapsed_time:.2f} 秒\033[0m")
