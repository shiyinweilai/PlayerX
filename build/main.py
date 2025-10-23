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
    os.system(cmd_sdl)
    os.system(cmd_sdl_ttf)
    os.system(cmd_ffmpeg)
    os.system(cmd_video_compare)
    print(f"\033[33m>>>> 所有构建完成!\033[0m")
    end_time = time.time()
    elapsed_time = end_time - start_time
    print(f"\033[32m>>>> 总用时: {elapsed_time:.2f} 秒\033[0m")
