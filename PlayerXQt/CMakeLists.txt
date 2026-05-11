cmake_minimum_required(VERSION 3.18)
project(PlayerXQt VERSION 1.0.0 LANGUAGES CXX)

# ─── C++ 标准 ────────────────────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ─── 构建类型默认 Release ─────────────────────────────────────────────────────
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
message(STATUS "[PlayerXQt] Build type: ${CMAKE_BUILD_TYPE}")

# ─── 产物输出目录（严格与源码分离） ───────────────────────────────────────────
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# Qt 自动处理：moc / rcc / uic
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# ─── 外部依赖（由 build.py 通过 -D 注入）─────────────────────────────────────
foreach(_dep FFMPEG_INSTALL_DIR)
    if(NOT DEFINED ${_dep})
        message(FATAL_ERROR "[PlayerXQt] ${_dep} is not set. Run build.py instead of cmake directly.")
    endif()
endforeach()

# Qt 路径：build.py 用 brew --prefix qt@6 / Qt 在线安装路径自动注入 CMAKE_PREFIX_PATH
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2)

qt_standard_project_setup(REQUIRES 6.5)

# ─── 可执行目标 ───────────────────────────────────────────────────────────────
qt_add_executable(PlayerXQt
    src/main.cpp
    # 共享核心（与旧 SDL 版同源，已拷贝到 PlayerXQt/src/core 与 player）
    src/core/rb_demuxer.cpp
    src/core/rb_decoder.cpp
    src/core/rb_frame_queue.cpp
    src/player/rb_video_player.cpp
    # Qt 桥接层
    src/qt/VideoFrameProvider.cpp
)

# ─── QML 模块 ─────────────────────────────────────────────────────────────────
qt_add_qml_module(PlayerXQt
    URI PlayerXQt
    VERSION 1.0
    QML_FILES
        qml/Main.qml
)

# ─── 头文件搜索路径 ───────────────────────────────────────────────────────────
target_include_directories(PlayerXQt PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/core
    ${CMAKE_CURRENT_SOURCE_DIR}/src/player
    ${CMAKE_CURRENT_SOURCE_DIR}/src/qt
    ${FFMPEG_INSTALL_DIR}/include
)

# ─── 链接目录 ─────────────────────────────────────────────────────────────────
target_link_directories(PlayerXQt PRIVATE
    ${FFMPEG_INSTALL_DIR}/lib
)

# ─── macOS 系统框架（FFmpeg 静态库依赖） ──────────────────────────────────────
if(APPLE)
    find_library(COREFOUNDATION_LIB       CoreFoundation       REQUIRED)
    find_library(COREGRAPHICS_LIB         CoreGraphics         REQUIRED)
    find_library(COREVIDEO_LIB            CoreVideo            REQUIRED)
    find_library(COREMEDIA_LIB            CoreMedia            REQUIRED)
    find_library(AUDIOTOOLBOX_LIB         AudioToolbox         REQUIRED)
    find_library(COREAUDIO_LIB            CoreAudio            REQUIRED)
    find_library(AVFOUNDATION_LIB         AVFoundation         REQUIRED)
    find_library(VIDEOTOOLBOX_LIB         VideoToolbox         REQUIRED)
    find_library(SECURITY_LIB             Security             REQUIRED)
    find_library(FOUNDATION_LIB           Foundation           REQUIRED)

    set(APPLE_FFMPEG_FRAMEWORKS
        ${COREFOUNDATION_LIB} ${COREGRAPHICS_LIB} ${COREVIDEO_LIB}
        ${COREMEDIA_LIB} ${AUDIOTOOLBOX_LIB} ${COREAUDIO_LIB}
        ${AVFOUNDATION_LIB} ${VIDEOTOOLBOX_LIB} ${SECURITY_LIB}
        ${FOUNDATION_LIB}
    )
endif()

# ─── 链接 ─────────────────────────────────────────────────────────────────────
target_link_libraries(PlayerXQt PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    # FFmpeg 静态库
    avformat avcodec avfilter avutil swscale swresample
)

if(APPLE)
    target_link_libraries(PlayerXQt PRIVATE
        ${APPLE_FFMPEG_FRAMEWORKS}
        -liconv
        -lz
        -lbz2
    )
elseif(WIN32)
    target_link_libraries(PlayerXQt PRIVATE
        ws2_32 bcrypt secur32 crypt32 ncrypt winmm
    )
endif()

# ─── 编译选项 ─────────────────────────────────────────────────────────────────
target_compile_options(PlayerXQt PRIVATE
    $<$<AND:$<CONFIG:Release>,$<NOT:$<CXX_COMPILER_ID:MSVC>>>:-O3>
    $<$<AND:$<CONFIG:Debug>,$<NOT:$<CXX_COMPILER_ID:MSVC>>>:-O0 -g>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -Wextra -Wno-unused-parameter>
)

target_compile_definitions(PlayerXQt PRIVATE
    $<$<CONFIG:Debug>:RB_DEBUG>
)

# ─── 安装 ─────────────────────────────────────────────────────────────────────
install(TARGETS PlayerXQt
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION bin
)
