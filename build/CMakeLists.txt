cmake_minimum_required(VERSION 3.10)
project(video-compare VERSION 1.0.0 LANGUAGES CXX)

# 设置C++标准
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 编译选项
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g3 -Ofast -D__STDC_CONSTANT_MACROS")

# 警告选项
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wno-deprecated -Wno-deprecated-declarations")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wdisabled-optimization -Wctor-dtor-privacy -Woverloaded-virtual")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-unused -Wno-missing-field-initializers")

# 查找所有源文件
file(GLOB SOURCES "*.cpp")

# 设置包含目录
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# 添加ffmpeg库路径和包含目录
link_directories(${FFMPEG_INSTALL_DIR}/lib)
include_directories(${FFMPEG_INSTALL_DIR}/include)

# 添加SDL2_ttf包含目录和库路径
link_directories(${SDL_TTF_INSTALL_DIR}/lib)
include_directories(${SDL_TTF_INSTALL_DIR}/include)

# 查找SDL2库
find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 sdl2)

if(NOT SDL2_FOUND)
    message(FATAL_ERROR "SDL2 not found! Please install SDL2 development package.")
endif()

# 设置包含目录
include_directories(${SDL2_INCLUDE_DIRS})

# 链接库配置 - 使用完整的库路径和macOS框架
set(FFMPEG_LIBS avformat avcodec avfilter avutil swscale swresample)
set(LIBS ${FFMPEG_LIBS} ${SDL2_LDFLAGS} ${SDL_TTF_INSTALL_DIR}/lib/libSDL2_ttf.a pthread)

# macOS特定框架和库
if(APPLE)
    find_library(COCOA_LIBRARY Cocoa)
    find_library(COREVIDEO_LIBRARY CoreVideo)
    find_library(VIDEOTOOLBOX_LIBRARY VideoToolbox)
    find_library(COREMEDIA_LIBRARY CoreMedia)
    find_library(COREFOUNDATION_LIBRARY CoreFoundation)
    find_library(SECURITY_LIBRARY Security)
    find_library(ZLIB_LIBRARY z)
    find_library(BZ2_LIBRARY bz2)
    find_library(ICONV_LIBRARY iconv)
    find_library(AUDIOTOOLBOX_LIBRARY AudioToolbox)
    find_library(METAL_LIBRARY Metal)
    find_library(COREIMAGE_LIBRARY CoreImage)
    find_library(OPENGL_LIBRARY OpenGL)
    find_library(QUARTZCORE_LIBRARY QuartzCore)
    find_library(APPLICATIONSERVICES_LIBRARY ApplicationServices)
    
    # SDL2_ttf依赖的库
    list(APPEND LIBS 
        ${SDL_TTF_INSTALL_DIR}/lib/libfreetype.a
        ${SDL_TTF_INSTALL_DIR}/lib/libharfbuzz.a
    )
    
    set(MACOS_FRAMEWORKS 
        ${COCOA_LIBRARY}
        ${COREVIDEO_LIBRARY} 
        ${VIDEOTOOLBOX_LIBRARY}
        ${COREMEDIA_LIBRARY}
        ${COREFOUNDATION_LIBRARY}
        ${SECURITY_LIBRARY}
        ${ZLIB_LIBRARY}
        ${BZ2_LIBRARY}
        ${ICONV_LIBRARY}
        ${AUDIOTOOLBOX_LIBRARY}
        ${METAL_LIBRARY}
        ${COREIMAGE_LIBRARY}
        ${OPENGL_LIBRARY}
        ${QUARTZCORE_LIBRARY}
        ${APPLICATIONSERVICES_LIBRARY}
    )
    
    list(APPEND LIBS ${MACOS_FRAMEWORKS})
endif()

# 创建可执行文件
add_executable(video-compare ${SOURCES})

# 链接库
target_link_libraries(video-compare ${LIBS})

# 安装目标（可选）
install(TARGETS video-compare DESTINATION bin)