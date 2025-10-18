#!/bin/bash

# PlayerX构建脚本
# 自动构建video-compare和player项目

set -e

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
PLAYER_DIR="$SCRIPT_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 构建player
build_player() {
    print_info "构建player..."
    
    local build_dir="$BUILD_DIR/player"
    
    # 创建构建目录
    mkdir -p "$build_dir"
    
    cd "$build_dir"
    
    # 配置player
    print_info "配置player..."
    cmake "$PLAYER_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$BUILD_DIR/sdl2/install;$BUILD_DIR/sdl2_ttf/install" \
        -DCMAKE_INSTALL_PREFIX="$build_dir/install" \
        -DFFMPEG_INSTALL_DIR="$BUILD_DIR/ffmpeg/install" \
        -DSDL2_INSTALL_DIR="$BUILD_DIR/sdl2/install" \
        -DSDL2_TTF_INSTALL_DIR="$BUILD_DIR/sdl2_ttf/install" \
        -DVIDEO_COMPARE_EXECUTABLE="$BUILD_DIR/video-compare/install/bin/video-compare"
    
    # 编译player
    print_info "编译player..."
    make -j$(nproc)
    
    # 安装player
    print_info "安装player..."
    make install
    
    # 复制video-compare可执行文件
    if [ -f "$BUILD_DIR/video-compare/install/bin/video-compare" ]; then
        cp "$BUILD_DIR/video-compare/install/bin/video-compare" "$build_dir/install/bin/"
        print_success "已复制video-compare可执行文件"
    fi
    
    print_success "player构建完成"
}

# 清理构建文件
clean_build() {
    print_info "清理构建文件..."
    
    if [ -d "$BUILD_DIR/player" ]; then
        rm -rf "$BUILD_DIR/player"
        print_success "清理player构建文件"
    fi
    
    if [ -d "$BUILD_DIR/video_compare" ]; then
        rm -rf "$BUILD_DIR/video_compare"
        print_success "清理video-compare构建文件"
    fi
    
    print_success "清理完成"
}

# 主函数
main() {
    local action="build"
    
    if [ $# -gt 0 ]; then
        action="$1"
    fi
    
    case "$action" in
        "build")
            clean_build
            build_player
            print_success "所有组件构建完成"
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            print_error "未知操作: $action"
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"