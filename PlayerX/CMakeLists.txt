cmake_minimum_required(VERSION 3.18)
project(PlayerX VERSION 1.0.0 LANGUAGES CXX)

# ─── C++ 标准 ────────────────────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ─── 构建类型默认 Release ─────────────────────────────────────────────────────
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
message(STATUS "[PlayerX] Build type: ${CMAKE_BUILD_TYPE}")

# ─── 产物输出目录（严格与源码分离）──────────────────────────────────────────
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# ─── 外部依赖路径（由 build.py 通过 -D 注入）─────────────────────────────────
foreach(_dep FFMPEG_INSTALL_DIR SDL2_INSTALL_DIR SDL2_TTF_INSTALL_DIR)
    if(NOT DEFINED ${_dep})
        message(FATAL_ERROR "[PlayerX] ${_dep} is not set. Run build.py instead of cmake directly.")
    endif()
endforeach()

# ─── 可执行目标 ───────────────────────────────────────────────────────────────
add_executable(PlayerX
    src/main.cpp
    src/core/rb_demuxer.cpp
    src/core/rb_decoder.cpp
    src/core/rb_frame_queue.cpp
    src/player/rb_video_player.cpp
    src/ui/rb_video_cell.cpp
    src/ui/rb_player_ui.cpp
    src/utils/rb_utils.cpp
)

# ─── 包含目录（头文件与 cpp 同目录，各子目录均加入）─────────────────────────
target_include_directories(PlayerX PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/core
    ${CMAKE_CURRENT_SOURCE_DIR}/src/player
    ${CMAKE_CURRENT_SOURCE_DIR}/src/ui
    ${CMAKE_CURRENT_SOURCE_DIR}/src/utils
    ${FFMPEG_INSTALL_DIR}/include
    ${SDL2_INSTALL_DIR}/include
    ${SDL2_INSTALL_DIR}/include/SDL2
    ${SDL2_TTF_INSTALL_DIR}/include
    ${SDL2_TTF_INSTALL_DIR}/include/SDL2
)

# ─── 链接目录 ─────────────────────────────────────────────────────────────────
target_link_directories(PlayerX PRIVATE
    ${FFMPEG_INSTALL_DIR}/lib
    ${SDL2_INSTALL_DIR}/lib
    ${SDL2_TTF_INSTALL_DIR}/lib
)

# ─── macOS 系统框架 ───────────────────────────────────────────────────────────
if(APPLE)
    find_library(COCOA_LIB                Cocoa                REQUIRED)
    find_library(COREFOUNDATION_LIB       CoreFoundation       REQUIRED)
    find_library(COREGRAPHICS_LIB         CoreGraphics         REQUIRED)
    find_library(COREVIDEO_LIB            CoreVideo            REQUIRED)
    find_library(COREMEDIA_LIB            CoreMedia            REQUIRED)
    find_library(IOKIT_LIB                IOKit                REQUIRED)
    find_library(CARBON_LIB               Carbon               REQUIRED)
    find_library(FORCEFEEDBACK_LIB        ForceFeedback        REQUIRED)
    find_library(METAL_LIB                Metal                REQUIRED)
    find_library(QUARTZCORE_LIB           QuartzCore           REQUIRED)
    find_library(AUDIOTOOLBOX_LIB         AudioToolbox         REQUIRED)
    find_library(COREAUDIO_LIB            CoreAudio            REQUIRED)
    find_library(GAMECONTROLLER_LIB       GameController       REQUIRED)
    find_library(COREHAPTICS_LIB          CoreHaptics          REQUIRED)
    find_library(AVFOUNDATION_LIB         AVFoundation         REQUIRED)
    find_library(VIDEOTOOLBOX_LIB         VideoToolbox         REQUIRED)
    find_library(SECURITY_LIB             Security             REQUIRED)
    find_library(FOUNDATION_LIB           Foundation           REQUIRED)
    find_library(APPLICATIONSERVICES_LIB  ApplicationServices  REQUIRED)
    find_library(COREIMAGE_LIB            CoreImage            REQUIRED)
    find_library(OPENGL_LIB               OpenGL               REQUIRED)

    set(APPLE_FRAMEWORKS
        ${COCOA_LIB} ${COREFOUNDATION_LIB} ${COREGRAPHICS_LIB}
        ${COREVIDEO_LIB} ${COREMEDIA_LIB} ${IOKIT_LIB} ${CARBON_LIB}
        ${FORCEFEEDBACK_LIB} ${METAL_LIB} ${QUARTZCORE_LIB}
        ${AUDIOTOOLBOX_LIB} ${COREAUDIO_LIB} ${GAMECONTROLLER_LIB}
        ${COREHAPTICS_LIB} ${AVFOUNDATION_LIB} ${VIDEOTOOLBOX_LIB}
        ${SECURITY_LIB} ${FOUNDATION_LIB} ${APPLICATIONSERVICES_LIB}
        ${COREIMAGE_LIB} ${OPENGL_LIB}
    )
endif()

# ─── 链接 ─────────────────────────────────────────────────────────────────────
target_link_libraries(PlayerX PRIVATE
    # SDL2_ttf（静态）
    ${SDL2_TTF_INSTALL_DIR}/lib/libSDL2_ttf.a
    ${SDL2_TTF_INSTALL_DIR}/lib/libfreetype.a
    ${SDL2_TTF_INSTALL_DIR}/lib/libharfbuzz.a
    # SDL2（静态）
    ${SDL2_INSTALL_DIR}/lib/libSDL2.a
    # FFmpeg（静态）
    avformat avcodec avfilter avutil swscale swresample
    # macOS 框架
    $<$<BOOL:${APPLE}>:${APPLE_FRAMEWORKS}>
    $<$<BOOL:${APPLE}>:-liconv>
    $<$<BOOL:${APPLE}>:-lz>
    $<$<BOOL:${APPLE}>:-lbz2>
    # Linux
    $<$<PLATFORM_ID:Linux>:pthread>
    $<$<PLATFORM_ID:Linux>:dl>
    $<$<PLATFORM_ID:Linux>:m>
)

# ─── 编译选项 ─────────────────────────────────────────────────────────────────
target_compile_options(PlayerX PRIVATE
    $<$<AND:$<CONFIG:Release>,$<NOT:$<CXX_COMPILER_ID:MSVC>>>:-O3>
    $<$<AND:$<CONFIG:Debug>,$<NOT:$<CXX_COMPILER_ID:MSVC>>>:-O0 -g>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -Wextra -Wno-unused-parameter>
)

target_compile_definitions(PlayerX PRIVATE
    SDL_MAIN_HANDLED
    $<$<CONFIG:Debug>:RB_DEBUG>
)

# ─── 安装 ─────────────────────────────────────────────────────────────────────
install(TARGETS PlayerX RUNTIME DESTINATION bin)
