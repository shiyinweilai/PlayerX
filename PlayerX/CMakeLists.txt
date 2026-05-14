cmake_minimum_required(VERSION 3.18)
# 应用版本号：单点维护处。会通过 APP_VERSION_STR 注入到 C++（Updater 用作
# currentVersion）和 QML（关于对话框 / 更新弹窗显示）。
# 发新版本时只改这一行，不要在源码里另写硬编码版本。
project(PlayerX VERSION 2.0.14 LANGUAGES CXX C)

# ─── C++ 标准 ────────────────────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ─── 构建类型默认 Release ─────────────────────────────────────────────────────
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
message(STATUS "[PlayerX] Build type: ${CMAKE_BUILD_TYPE}")

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
        message(FATAL_ERROR "[PlayerX] ${_dep} is not set. Run build.py instead of cmake directly.")
    endif()
endforeach()

# Qt 路径：build.py 用 brew --prefix qt@6 / Qt 在线安装路径自动注入 CMAKE_PREFIX_PATH
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 Network)

qt_standard_project_setup(REQUIRES 6.5)

# ─── 应用图标 ─────────────────────────────────────────────────────────────────
# 单一图源：resources/icon/icon-1024.png，由 build.py prepare-icons 步骤
# 自动派生出 macOS 的 .icns 与 Windows 的 .ico（无需手工维护多份资源）。
#   * macOS：把 .icns 作为 bundle Resources，写 MACOSX_BUNDLE_ICON_FILE
#   * Windows：用 app.rc 把 .ico 嵌入 exe（任务栏 / Alt-Tab 自动读取）
set(APP_ICON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/resources/icon")
set(APP_ICON_ICNS "${APP_ICON_DIR}/icon.icns")
set(APP_ICON_RC   "${CMAKE_CURRENT_SOURCE_DIR}/resources/app.rc")

set(_PLATFORM_ICON_SOURCES "")
if(APPLE)
    if(EXISTS "${APP_ICON_ICNS}")
        list(APPEND _PLATFORM_ICON_SOURCES "${APP_ICON_ICNS}")
        set_source_files_properties("${APP_ICON_ICNS}" PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources")
    else()
        message(WARNING "[PlayerX] ${APP_ICON_ICNS} not found — bundle 不会带应用图标。"
                        "请先运行 build.py（会自动从 icon-1024.png 生成）。")
    endif()
elseif(WIN32)
    if(EXISTS "${APP_ICON_RC}")
        list(APPEND _PLATFORM_ICON_SOURCES "${APP_ICON_RC}")
    else()
        message(WARNING "[PlayerX] ${APP_ICON_RC} not found — exe 不会带应用图标。"
                        "请先运行 build.py（会自动生成 .ico 并启用 app.rc）。")
    endif()
endif()

# ─── 可执行目标 ───────────────────────────────────────────────────────────────
# WIN32     → Windows 下使用 GUI 子系统，避免启动时弹出黑色控制台窗口
# MACOSX_BUNDLE → macOS 下产出 .app bundle（这个 qt_add_executable 默认就会做，显式更稳妥）
qt_add_executable(PlayerX WIN32 MACOSX_BUNDLE
    src/main.cpp
    ${_PLATFORM_ICON_SOURCES}
    # 运行时窗口图标资源：QGuiApplication::setWindowIcon(":/icon/app.png")
    # 让 Windows 任务栏 / Alt-Tab / Linux WM 都能拿到图标（exe 内 .rsrc 只管
    # 静态文件图标，不管运行中窗口的 HICON）。CMake 已开 AUTORCC 自动处理。
    resources/app_icon.qrc
    # 共享核心（与旧 SDL 版同源，已拷贝到 PlayerX/src/core 与 player）
    src/core/rb_demuxer.cpp
    src/core/rb_decoder.cpp
    src/core/rb_frame_queue.cpp
    src/player/rb_video_player.cpp
    src/player/rb_player_engine.cpp
    # Qt 桥接层
    src/qt/VideoFrameProvider.cpp
    src/qt/EngineBridge.cpp
    # 滑动对比模式（独立组件，不影响 Grid 视图与播放内核）
    src/qt/SliderCompareItem.cpp
    # 多组对比模式辅助工具（仅供 QML 配置面板使用，不触达播放内核）
    src/qt/FsUtils.cpp
    # 视频评分本地持久化（CSV，与播放内核解耦）
    src/qt/RatingStore.cpp
    # 文件夹参考图本地持久化（ini，与播放内核解耦）
    src/qt/ReferenceStore.cpp
    # 应用自动更新（远端 latest.json 比对 + 下载 + relaunch；与播放内核解耦）
    src/qt/Updater.cpp
)

# ─── QML 模块 ─────────────────────────────────────────────────────────────────
qt_add_qml_module(PlayerX
    URI PlayerX
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/SliderCompareView.qml
        qml/MultiGroupRow.qml
        qml/MultiGroupDialog.qml
        qml/RatingsDialog.qml
)

# ─── 头文件搜索路径 ───────────────────────────────────────────────────────────
target_include_directories(PlayerX PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/core
    ${CMAKE_CURRENT_SOURCE_DIR}/src/player
    ${CMAKE_CURRENT_SOURCE_DIR}/src/qt
    ${FFMPEG_INSTALL_DIR}/include
)

# ─── 链接目录 ─────────────────────────────────────────────────────────────────
target_link_directories(PlayerX PRIVATE
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
target_link_libraries(PlayerX PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Network
    # FFmpeg 静态库
    avformat avcodec avfilter avutil swscale swresample
)

if(APPLE)
    target_link_libraries(PlayerX PRIVATE
        ${APPLE_FFMPEG_FRAMEWORKS}
        -liconv
        -lz
        -lbz2
    )
elseif(WIN32)
    # 注意：MinGW 的 GUI 子系统下，libmingw32 必须排在 Qt6EntryPoint 之前。
    # 通过 LINK_OPTIONS 注入 -lmingw32 -lQt6EntryPoint 确保链接顺序，
    # 同时显式列出 FFmpeg 静态库需要的 Win32 系统库。
    target_link_options(PlayerX PRIVATE "-lmingw32")
    target_link_libraries(PlayerX PRIVATE
        ws2_32 bcrypt secur32 crypt32 ncrypt winmm
    )
endif()

# ─── 编译选项 ─────────────────────────────────────────────────────────────────
target_compile_options(PlayerX PRIVATE
    $<$<AND:$<CONFIG:Release>,$<NOT:$<CXX_COMPILER_ID:MSVC>>>:-O3>
    $<$<AND:$<CONFIG:Debug>,$<NOT:$<CXX_COMPILER_ID:MSVC>>>:-O0 -g>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -Wextra -Wno-unused-parameter>
)

target_compile_definitions(PlayerX PRIVATE
    $<$<CONFIG:Debug>:RB_DEBUG>
    # 把 CMake project(... VERSION x.y.z) 的版本号注入到 C++ 与 QML
    # （Updater 与关于对话框共用同一份版本字符串，单点维护）
    APP_VERSION_STR="${PROJECT_VERSION}"
)

# ─── macOS bundle 元数据 ─────────────────────────────────────────────────────
# MACOSX_BUNDLE_ICON_FILE：Finder/Dock 识别 .app 图标的关键键，值为 Resources
# 目录下的 .icns 文件名（不带路径、不带扩展名也可，这里给完整名最稳）。
# 没设置的话，即使 .icns 已经被打进 bundle 也不会显示。
if(APPLE AND EXISTS "${APP_ICON_ICNS}")
    set_target_properties(PlayerX PROPERTIES
        MACOSX_BUNDLE_ICON_FILE "icon.icns"
    )
endif()

# ─── 安装 ─────────────────────────────────────────────────────────────────────
install(TARGETS PlayerX
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION bin
)
