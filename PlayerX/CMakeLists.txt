cmake_minimum_required(VERSION 3.18)
# 应用版本号：单点维护处。会通过 APP_VERSION_STR 注入到 C++（Updater 用作
# currentVersion）和 QML（关于对话框 / 更新弹窗显示）。
# 发新版本时只改这一行，不要在源码里另写硬编码版本。
project(PlayerX VERSION 3.1.6 LANGUAGES CXX C)

# 在 macOS 上启用 Objective-C++（用于 ScreenProbe 直接调用 NSScreen / 注册
# NSApplicationDidChangeScreenParametersNotification —— 绕开 Qt screen 子系统
# 在外接屏切档位时缓存不刷新的长期问题）。
if(APPLE)
    enable_language(OBJCXX)
endif()

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
# 注：Widgets 仅在非 macOS 平台上才需要 —— 原生多选目录对话框在
# macOS 用 NSOpenPanel（FsUtils_mac.mm），完全不依赖 QtWidgets。
# Windows / Linux 等平台依赖 Qt 自绘 QFileDialog 作为多选目录对话框的实现，
# 需要链入 Qt6::Widgets。
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 Network)
if(NOT APPLE)
    find_package(Qt6 6.2 REQUIRED COMPONENTS Widgets)
endif()

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
    # YUV 分析窗口 QML（独立 qrc，不参与 qt_add_qml_module AOT 编译）
    resources/yuv/yuv_window.qrc
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
    # YUV 裸数据分析工具（独立模块，复用 sws_scale 但不依赖播放管线）
    src/yuv/YuvAnalyzer.cpp
    src/yuv/YuvBridge.cpp
    src/yuv/YuvDisplayItem.cpp
    # 异步文件下载器（供 QML 测试源下载使用，不阻塞 UI 线程）
    src/qt/FileDownloader.cpp
    # 平台原生多选文件夹对话框：仅 macOS 走 NSOpenPanel。
    # Windows / Linux 走 FsUtils.cpp 内部的 Qt 自绘 QFileDialog 兜底实现。
    $<$<PLATFORM_ID:Darwin>:src/qt/FsUtils_mac.mm>
    # 视频评分本地持久化（CSV，与播放内核解耦）
    src/qt/RatingStore.cpp
    # 文件夹参考图本地持久化（ini，与播放内核解耦）
    src/qt/ReferenceStore.cpp
    # 应用自动更新（远端 latest.json 比对 + 下载 + relaunch；与播放内核解耦）
    src/qt/Updater.cpp
    # 屏幕状态主动探测（绕开 macOS 外接屏 Screen 附加属性缓存问题）
    # macOS 走 ScreenProbe.mm（Cocoa NSScreen + CoreGraphics + 系统通知，事件驱动）
    # 其他平台走 ScreenProbe.cpp（Qt QScreen 回退）
    $<$<PLATFORM_ID:Darwin>:src/qt/ScreenProbe.mm>
    $<$<NOT:$<PLATFORM_ID:Darwin>>:src/qt/ScreenProbe.cpp>
    # macOS 外观定制（强制 Dark Aqua：系统标题栏 / 原生菜单深色化）
    $<$<PLATFORM_ID:Darwin>:src/qt/MacAppearance.mm>
    # Windows 标题栏深色化（DWM 沉浸式深色 + Win11 精确配色）
    $<$<PLATFORM_ID:Windows>:src/qt/WinTitleBar.cpp>
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
        # 视频宫格单元格组件：从 Main.qml 抽离，便于后续按媒体类型扩展
        # （未来加 ImageCellDelegate.qml 等只需在此追加，宫格容器无需改动）。
        qml/VideoCellDelegate.qml
        # 视频信息面板块：从 VideoCellDelegate.infoPanel 抽离为可复用组件，
        # 供"右键浮层 / 播放对比右侧栏"等任意容器展示当前 player 的元信息。
        qml/VideoInfoBlock.qml
        # 扁平工具按钮：从 Main.qml inline component 抽出，便于跨文件复用。
        # （inline component 仅在定义文件内可见，独立 .qml 才能被外部引用）
        qml/FlatToolButton.qml
        # 扁平按钮：深色主题通用按钮组件
        qml/FlatButton.qml
        # 快捷键速查对话框行/分组渲染器
        qml/ScRow.qml
        qml/ScSection.qml
        # ── 从 Main.qml 拆分的功能模块 ──
        qml/ShortcutsAboutDialogs.qml
        qml/RefLightbox.qml
        qml/YuvSetupView.qml
        qml/HomeView.qml
        # ── MenuBar 下拉菜单深色主题三件套 ──
        # Windows/Linux 上 Basic style 的下拉菜单是白底黑字，与应用整体
        # 深色半透明风格严重冲突。这里把 Menu / MenuItem / MenuSeparator
        # 封装成 Dark* 变体，统一预设配色。macOS 走原生 NSMenu，
        # 自动忽略这些自定义（保持系统一致的原生外观）。
        qml/DarkMenu.qml
        qml/DarkMenuItem.qml
        qml/DarkMenuSeparator.qml
        # ── 从 Main.qml 拆分的窗口级组件 / 对话框 ──
        qml/AppMenuBar.qml
        qml/LoginDialog.qml
        qml/UpdateDialog.qml
        qml/UpdateToast.qml
        qml/TaskUpdateDismissArea.qml
        qml/TaskUpdateCard.qml
        qml/TestSourceDownloadDialog.qml
        qml/TestSourceGroupDialog.qml
        qml/TestSourceRedownloadDialog.qml
        qml/ConfirmCloseAllDialog.qml
        qml/RestoreDefaultConfirmDialog.qml
        qml/ClearHistoryConfirmDialog.qml
        qml/QuickUploadConfirmDialog.qml
        qml/QuickUploadResultDialog.qml
        qml/QuickUploadOverwriteDialog.qml
        qml/FileDialogs.qml
        qml/GlobalShortcuts.qml
        qml/ResizeEdge.qml
        # ── 主界面布局区块 ──
        qml/TopBar.qml
        qml/RefSidebar.qml
        qml/CsvBottomBar.qml
        qml/RefSidebarHSplitter.qml
        qml/CsvBottomVSplitter.qml
        qml/VideoArea.qml
        qml/LeftNavBar.qml
        qml/YuvStatsPanel.qml
        # ── Main.qml 拆出的纯逻辑 JS ──
        qml/MainLogic.js
        qml/RatingLogic.js
)

# ─── 头文件搜索路径 ───────────────────────────────────────────────────────────
target_include_directories(PlayerX PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/core
    ${CMAKE_CURRENT_SOURCE_DIR}/src/player
    ${CMAKE_CURRENT_SOURCE_DIR}/src/qt
    ${CMAKE_CURRENT_SOURCE_DIR}/src/yuv
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
    # AppKit：ScreenProbe.mm 用 NSScreen / NSNotificationCenter
    find_library(APPKIT_LIB               AppKit               REQUIRED)

    set(APPLE_FFMPEG_FRAMEWORKS
        ${COREFOUNDATION_LIB} ${COREGRAPHICS_LIB} ${COREVIDEO_LIB}
        ${COREMEDIA_LIB} ${AUDIOTOOLBOX_LIB} ${COREAUDIO_LIB}
        ${AVFOUNDATION_LIB} ${VIDEOTOOLBOX_LIB} ${SECURITY_LIB}
        ${FOUNDATION_LIB} ${APPKIT_LIB}
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

# 非 macOS 平台需要 Qt6::Widgets 作为 FsUtils::pickMultipleFolders 的
# Qt 自绘 QFileDialog 实现（Windows / Linux）。macOS 走平台原生 NSOpenPanel，
# 不需要 Widgets，包体可以减 5–7 MB。
if(NOT APPLE)
    target_link_libraries(PlayerX PRIVATE Qt6::Widgets)
endif()

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
        # DwmSetWindowAttribute（WinTitleBar.cpp 深色标题栏）
        dwmapi
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

# ─── dimensions.json 动态配置文件（不打进 qrc，运行时从 Resources 目录读取）──
# 构建时：把 doc/dimensions.json 复制到 .app/Contents/Resources/（macOS bundle）
# 或 bin/ 目录（非 bundle 平台），使 App 运行时可直接读取，修改文件无需重新编译。
if(APPLE)
    # macOS bundle：复制到 PlayerX.app/Contents/Resources/dimensions.json
    add_custom_command(TARGET PlayerX POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/doc/dimensions.json"
            "$<TARGET_BUNDLE_DIR:PlayerX>/Contents/Resources/dimensions.json"
        COMMENT "Copying dimensions.json to app bundle Resources"
    )
else()
    # 非 bundle 平台：复制到可执行文件同级目录
    add_custom_command(TARGET PlayerX POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/doc/dimensions.json"
            "$<TARGET_FILE_DIR:PlayerX>/dimensions.json"
        COMMENT "Copying dimensions.json next to executable"
    )
endif()

# ─── default_configs/ 内置默认评分配置（出厂配置，跟随软件发布）──
# 每模式一份 <mode>.json（subjective / quality / quality_slide / multi_dim / test），
# 运行时从 Resources/default_configs/ 读取。远程"接受"只写覆盖层
# （dimsByMode.json / checklistByMode.json / tagByMode.json），永不改写本目录，
# 因此任何时刻都能"恢复默认配置"；用户升级软件即拿到最新内置默认。
if(APPLE)
    add_custom_command(TARGET PlayerX POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/doc/default_configs"
            "$<TARGET_BUNDLE_DIR:PlayerX>/Contents/Resources/default_configs"
        COMMENT "Copying default_configs/ to app bundle Resources"
    )
else()
    add_custom_command(TARGET PlayerX POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/doc/default_configs"
            "$<TARGET_FILE_DIR:PlayerX>/default_configs"
        COMMENT "Copying default_configs/ next to executable"
    )
endif()

# ─── 安装 ─────────────────────────────────────────────────────────────────────
install(TARGETS PlayerX
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION bin
)
# 安装时同步带上 dimensions.json
if(APPLE)
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/doc/dimensions.json"
        DESTINATION "PlayerX.app/Contents/Resources"
    )
else()
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/doc/dimensions.json"
        DESTINATION bin
    )
endif()
# 安装时同步带上内置默认评分配置目录（跟随软件的出厂配置）
if(APPLE)
    install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/doc/default_configs"
        DESTINATION "PlayerX.app/Contents/Resources"
    )
else()
    install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/doc/default_configs"
        DESTINATION bin
    )
endif()
