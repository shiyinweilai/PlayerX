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
    src/ui/rb_slider_view.cpp
    src/ui/rb_player_ui.cpp
    src/utils/rb_utils.cpp
)

# ─── 平台原生文件对话框（macOS=NSOpenPanel / Windows=GetOpenFileNameW）───────
if(APPLE)
    target_sources(PlayerX PRIVATE
        src/utils/rb_file_dialog_mac.mm
        src/utils/rb_macos_silence.mm
    )
    # 仅为 .mm 启用 ARC（其他 .cpp 不受影响）
    set_source_files_properties(
        src/utils/rb_file_dialog_mac.mm
        src/utils/rb_macos_silence.mm
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")
elseif(WIN32)
    target_sources(PlayerX PRIVATE
        src/utils/rb_file_dialog_win.cpp
        src/utils/rb_macos_silence_win.cpp
    )

    # ── 嵌入 Windows 资源（含 Per-Monitor V2 DPI Aware manifest）──────────────
    # 让 Windows 在 PE 加载阶段就识别本进程为 DPI Aware，避免 DWM 对窗口做
    # bilinear 二次拉伸（→ 视频帧/字体被磨毛边）。
    # 必须显式启用 RC 语言 + 用 windres/llvm-rc 编译资源脚本。
    # windres 默认会在 .rc 文件所在目录查找 #include 与资源引用（PlayerX.manifest），
    # 因此不需要额外的 -I 选项。
    enable_language(RC)
    target_sources(PlayerX PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/res/win/PlayerX.rc
    )
    set_source_files_properties(
        ${CMAKE_CURRENT_SOURCE_DIR}/res/win/PlayerX.rc
        PROPERTIES LANGUAGE RC)
endif()

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
    find_library(UTTYPE_LIB               UniformTypeIdentifiers REQUIRED)

    set(APPLE_FRAMEWORKS
        ${COCOA_LIB} ${COREFOUNDATION_LIB} ${COREGRAPHICS_LIB}
        ${COREVIDEO_LIB} ${COREMEDIA_LIB} ${IOKIT_LIB} ${CARBON_LIB}
        ${FORCEFEEDBACK_LIB} ${METAL_LIB} ${QUARTZCORE_LIB}
        ${AUDIOTOOLBOX_LIB} ${COREAUDIO_LIB} ${GAMECONTROLLER_LIB}
        ${COREHAPTICS_LIB} ${AVFOUNDATION_LIB} ${VIDEOTOOLBOX_LIB}
        ${SECURITY_LIB} ${FOUNDATION_LIB} ${APPLICATIONSERVICES_LIB}
        ${COREIMAGE_LIB} ${OPENGL_LIB} ${UTTYPE_LIB}
    )
endif()

# ─── 链接 ─────────────────────────────────────────────────────────────────────
# 平台无关核心：FFmpeg（来自 link_directories）。
# SDL2 / SDL2_ttf 在不同平台用不同链接方式，各自分支处理。

if(APPLE)
    # macOS：所有依赖均为静态库 .a，直接全路径精确链接，避免与系统同名库冲突。
    target_link_libraries(PlayerX PRIVATE
        # SDL2_ttf（静态）+ 它依赖的 freetype/harfbuzz
        ${SDL2_TTF_INSTALL_DIR}/lib/libSDL2_ttf.a
        ${SDL2_TTF_INSTALL_DIR}/lib/libfreetype.a
        ${SDL2_TTF_INSTALL_DIR}/lib/libharfbuzz.a
        # SDL2（静态）
        ${SDL2_INSTALL_DIR}/lib/libSDL2.a
        # FFmpeg（静态）
        avformat avcodec avfilter avutil swscale swresample
        # macOS 系统框架
        ${APPLE_FRAMEWORKS}
        -liconv
        -lz
        -lbz2
    )
elseif(WIN32)
    # Windows (MinGW)：依赖均为 .a 静态库。MinGW 的链接器对 -l<name> 友好，
    # 由 link_directories 提供查找路径即可。同时探测 sdl2_ttf 附带的可选静态依赖。
    set(_TTF_LIBDIR ${SDL2_TTF_INSTALL_DIR}/lib)
    set(_TTF_OPTIONAL_DEPS
        freetype
        harfbuzz
        bz2
        brotlidec
        brotlicommon
        png
        png16
        z
    )
    set(_WIN_TTF_EXTRA_LIBS "")
    foreach(_lib ${_TTF_OPTIONAL_DEPS})
        if(EXISTS ${_TTF_LIBDIR}/lib${_lib}.a)
            list(APPEND _WIN_TTF_EXTRA_LIBS ${_TTF_LIBDIR}/lib${_lib}.a)
        endif()
    endforeach()

    target_link_libraries(PlayerX PRIVATE
        # SDL2_ttf 主库 + 探测到的可选依赖
        SDL2_ttf
        ${_WIN_TTF_EXTRA_LIBS}
        # SDL2 主库（SDL_MAIN_HANDLED 已定义，无需 SDL2main）
        SDL2
        # FFmpeg
        avformat avcodec avfilter avutil swscale swresample
        # SDL2 / FFmpeg 在 Windows 下需要的系统库
        ws2_32 bcrypt secur32 crypt32 ncrypt
        winmm imm32 setupapi version
        gdi32 user32 advapi32 shell32 uuid
        ole32 oleaut32 comdlg32
    )

    # Release 子系统改为 GUI（双击不弹控制台）；Debug 保留控制台便于查看日志
    target_link_options(PlayerX PRIVATE
        $<$<CONFIG:Release>:-mwindows>
    )
else()
    # Linux 等其他平台
    target_link_libraries(PlayerX PRIVATE
        ${SDL2_TTF_INSTALL_DIR}/lib/libSDL2_ttf.a
        ${SDL2_TTF_INSTALL_DIR}/lib/libfreetype.a
        ${SDL2_TTF_INSTALL_DIR}/lib/libharfbuzz.a
        ${SDL2_INSTALL_DIR}/lib/libSDL2.a
        avformat avcodec avfilter avutil swscale swresample
        pthread dl m
    )
endif()

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
