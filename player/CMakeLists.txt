cmake_minimum_required(VERSION 3.15)
project(playerx VERSION 1.0.0 LANGUAGES CXX)

# 设置C++标准
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 设置构建类型
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# 设置输出目录
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# 添加ffmpeg库路径和包含目录
link_directories(${FFMPEG_INSTALL_DIR}/lib)
include_directories(${FFMPEG_INSTALL_DIR}/include)

# 添加SDL2_ttf包含目录和库路径
link_directories(${SDL2_TTF_INSTALL_DIR}/lib)
include_directories(${SDL2_TTF_INSTALL_DIR}/include)
include_directories(${SDL2_TTF_INSTALL_DIR}/include/SDL2)
message(STATUS "SDL2_TTF_INCLUDE_DIR: ${SDL2_TTF_INSTALL_DIR}/include")
# 添加SDL2库路径和包含目录
link_directories(${SDL2_INSTALL_DIR}/lib)
include_directories(${SDL2_INSTALL_DIR}/include)
include_directories(${SDL2_INSTALL_DIR}/include/SDL2)


# 添加可执行文件
add_executable(playerx
    src/playerx.cpp
)

# 查找系统框架
find_library(COCOA_LIBRARY Cocoa)
find_library(COREFOUNDATION_LIBRARY CoreFoundation)
find_library(COREGRAPHICS_LIBRARY CoreGraphics)
find_library(COREVIDEO_LIBRARY CoreVideo)
find_library(IOKIT_LIBRARY IOKit)
find_library(CARBON_LIBRARY Carbon)
find_library(FORCEFEEDBACK_LIBRARY ForceFeedback)
find_library(METAL_LIBRARY Metal)
find_library(QUARTZCORE_LIBRARY QuartzCore)
find_library(AUDIOTOOLBOX_LIBRARY AudioToolbox)
find_library(COREAUDIO_LIBRARY CoreAudio)
find_library(GAMECONTROLLER_LIBRARY GameController)
find_library(COREHAPTICS_LIBRARY CoreHaptics)

# 链接库
target_link_libraries(playerx
    ${SDL2_TTF_INSTALL_DIR}/lib/libSDL2_ttf.a
    ${SDL2_INSTALL_DIR}/lib/libSDL2.a
    ${SDL2_TTF_INSTALL_DIR}/lib/libfreetype.a
    ${SDL2_TTF_INSTALL_DIR}/lib/libharfbuzz.a
    ${COCOA_LIBRARY}
    ${COREFOUNDATION_LIBRARY}
    ${COREGRAPHICS_LIBRARY}
    ${COREVIDEO_LIBRARY}
    ${IOKIT_LIBRARY}
    ${CARBON_LIBRARY}
    ${FORCEFEEDBACK_LIBRARY}
    ${METAL_LIBRARY}
    ${QUARTZCORE_LIBRARY}
    ${AUDIOTOOLBOX_LIBRARY}
    ${COREAUDIO_LIBRARY}
    ${GAMECONTROLLER_LIBRARY}
    ${COREHAPTICS_LIBRARY}
    -liconv
)

# 设置目标属性
target_compile_definitions(playerx PRIVATE
    $<$<CONFIG:Debug>:DEBUG>
)

target_compile_options(playerx PRIVATE
    $<$<CXX_COMPILER_ID:GNU>:-Wall -Wextra -Wpedantic>
    $<$<CXX_COMPILER_ID:Clang>:-Wall -Wextra -Wpedantic>
    $<$<CXX_COMPILER_ID:AppleClang>:-Wall -Wextra -Wpedantic>
)

# 安装目标
install(TARGETS playerx
    RUNTIME DESTINATION bin
)

# 复制video-compare可执行文件到构建目录
add_custom_command(TARGET playerx POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${VIDEO_COMPARE_EXECUTABLE}
        ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/video-compare
    COMMENT "Copying video-compare executable"
)