import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

MenuBar {
    id: appMenuBar
    property var root: null
    property var shortcutsAboutDialogs: null
    property var updateDialog: null
    property var restoreDefaultConfirmDialog: null
    property var clearHistoryConfirmDialog: null
    property var addDialog: null
    property var multiGroupDialog: null
    property var ratingsDialog: null
    property var imageView: null

    // ─── Windows 标题栏模式 ────────────────────────────────────────
    // 窗口已设 ExpandedClientAreaHint：menuBar 被布局在窗口 y=0，
    // 即标题栏条内。把它撑满标题栏高度（32px，与 Qt 自绘的三枚
    // 系统按钮等高），右侧 140px 留给系统按钮，菜单项垂直居中。
    // macOS / Linux 保持原 26px 经典菜单栏。
    readonly property bool inTitleBar: Qt.platform.os === "windows"
    // 显式 height（不用 implicitHeight）：实测 implicitHeight 赋值在某些
    // 场景下不生效（menuBar 高度变 0 → 子项居中错位/不可见），显式 height 最稳。
    height: inTitleBar ? 32 : 26
    topPadding: inTitleBar ? 3 : 0       // (32 - 26) / 2，菜单项与系统按钮垂直对齐
    leftPadding: inTitleBar ? 8 : 0      // 菜单左对齐，仅避开左上角圆角
    rightPadding: inTitleBar ? 140 : 0   // 给右侧系统三键留位

    Component.onCompleted: {
        // 标题栏模式：内部 ListView 不再拦截空白区鼠标事件，
        // 让事件穿透到 background 上的拖拽 / 双击处理器
        if (inTitleBar && contentItem && contentItem.interactive !== undefined)
            contentItem.interactive = false
    }

    // ─── MenuBar 下拉菜单样式 ───────────────────────────────────────
    // Windows/Linux：使用同目录下的 DarkMenu / DarkMenuItem / DarkMenuSeparator
    // 三件套，呈现半透明深色 + 白字 + 蓝底 hover，与全局 ToolTip / 通知
    // 卡片 / phoneAspectPopup 一致。
    // macOS：MenuBar 走系统全局菜单（NSMenu），会自动忽略上述自定义
    // 组件对 background / contentItem 的覆盖，继续显示原生外观。
    //
    // 【重要】Qt 6.x Menu.delegate 只对"动态创建"的项生效，对源码里
    // inline 的 MenuItem 不生效 —— 所以必须把 MenuItem 逐一换成
    // DarkMenuItem（组件内已在自身层面覆盖 contentItem/background 等）。

    background: Rectangle {
        implicitHeight: 26
        // 标题栏模式与窗口底色一致，系统三键浮在上面看不出接缝
        color: appMenuBar.inTitleBar ? "#101012" : "#1a1a1d"

        // ─── 标题栏模式（Windows 无边框）：空白处按住拖动窗口、双击最大化/还原 ───
        // 事件来源：菜单项以外的空白（内部 ListView 已设 interactive:false，
        // 事件穿透到这里）；自绘三键区域有各自 MouseArea，不会误触拖拽。
        DragHandler {
            enabled: appMenuBar.inTitleBar
            target: null
            onActiveChanged: if (active) root.startSystemMove()
        }
        TapHandler {
            enabled: appMenuBar.inTitleBar
            onDoubleTapped: {
                root.visibility = (root.visibility === Window.Maximized)
                                  ? Window.Windowed : Window.Maximized
            }
        }

        // ─── 无边框标题栏内容（仅 Windows）：自绘窗口控制三键（右侧） ───
        Row {
            visible: appMenuBar.inTitleBar
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            z: 10

            // ─── 自绘按钮：右侧栏切换（在个人中心左侧）──
            // 圆角方框 + 中间竖线；激活时方框右侧填色。
            // 状态：open 直接绑定到 root.rightSidebarOpen → 主程序 toggle 时按钮自动填色。
            Rectangle {
                id: capSidebarBtn
                width: 32; height: parent.height
                color: sbMa.containsMouse ? "#2a2a32" : "transparent"
                property bool open: root.rightSidebarOpen

                Item {
                    anchors.centerIn: parent
                    width: 16; height: 16

                    // 外框（始终显示）
                    Rectangle {
                        anchors.fill: parent
                        radius: 3
                        color: "transparent"
                        border.color: "#cfcfd2"
                        border.width: 1.5
                    }
                    // 中间竖线（始终显示）：撑满高度，将方框一分为二
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 1.5
                        color: "#cfcfd2"
                    }
                    // 激活态：右半填色（覆盖到竖线右侧 + 右侧圆角）
                    Rectangle {
                        visible: capSidebarBtn.open
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width / 2
                        radius: 3
                        color: "#cfcfd2"
                    }
                }

                MouseArea {
                    id: sbMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // accepted=true 阻止双击冒泡到外层 TapHandler
                    onClicked: root._onTitleBarSidebarToggle()
                }
            }

            // ─── 自绘按钮：个人中心（在右侧栏按钮右侧 → 更靠近系统三键）──
            // 圆头 + 半月肩 + 嘴；激活时头+身填色（嘴留白）。
            // 状态：open 直接绑定到 root.loginDialogOpen → 打开对话框时按钮自动填色。
            Rectangle {
                id: capProfileBtn
                width: 32; height: parent.height
                color: pfMa.containsMouse ? "#2a2a32" : "transparent"
                property bool open: root.loginDialogOpen

                Item {
                    anchors.centerIn: parent
                    width: 18; height: 18

                    // ── 头部：圆头 r=4 ──
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 1
                        width: 8; height: 8; radius: 4
                        color: capProfileBtn.open ? "#cfcfd2" : "transparent"
                        border.color: "#cfcfd2"
                        border.width: 1.3
                    }

                    // ── 身体：半月肩（半圆：宽 16 / 高 8，半径 8）──
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        width: 16; height: 8; radius: 8
                        color: capProfileBtn.open ? "#cfcfd2" : "transparent"
                        border.color: "#cfcfd2"
                        border.width: 1.3
                    }

                    // ── 反白嘴（仅激活态：与按钮背景同色，画在身体弧线之上）──
                    Rectangle {
                        visible: capProfileBtn.open
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: 2
                        width: 3; height: 1.6
                        color: "#101012"
                    }
                }

                MouseArea {
                    id: pfMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // accepted=true 阻止双击冒泡到外层 TapHandler
                    onClicked: root._openLoginDialogFromNative()
                }
            }

            // 最小化
            Rectangle {
                id: capMinBtn
                width: 46
                height: parent.height
                color: capMinMa.containsMouse ? "#2a2a32" : "transparent"
                Rectangle { width: 10; height: 1.5; anchors.centerIn: parent; color: "#cfcfd2" }
                MouseArea { id: capMinMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.showMinimized() }
            }
            // 最大化 / 还原
            Rectangle {
                id: capMaxBtn
                width: 46
                height: parent.height
                color: capMaxMa.containsMouse ? "#2a2a32" : "transparent"
                // 最大化图标：单方框
                Rectangle {
                    visible: root.visibility !== Window.Maximized
                    width: 10; height: 10; anchors.centerIn: parent
                    color: "transparent"; border.color: "#cfcfd2"; border.width: 1.2
                }
                // 还原图标：前后双方框（后框右上、前框左下）
                Rectangle {
                    visible: root.visibility === Window.Maximized
                    x: 21; y: 8; width: 9; height: 9
                    color: capMaxBtn.color; border.color: "#cfcfd2"; border.width: 1.2
                }
                Rectangle {
                    visible: root.visibility === Window.Maximized
                    x: 17; y: 13; width: 9; height: 9
                    color: capMaxBtn.color; border.color: "#cfcfd2"; border.width: 1.2
                }
                MouseArea { id: capMaxMa; anchors.fill: parent; hoverEnabled: true
                    onClicked: root.visibility = (root.visibility === Window.Maximized) ? Window.Windowed : Window.Maximized }
            }
            // 关闭
            Rectangle {
                id: capCloseBtn
                width: 46
                height: parent.height
                color: capCloseMa.containsMouse ? "#e81123" : "transparent"
                Rectangle { width: 12; height: 1.5; anchors.centerIn: parent; rotation: 45;  color: capCloseMa.containsMouse ? "#ffffff" : "#cfcfd2" }
                Rectangle { width: 12; height: 1.5; anchors.centerIn: parent; rotation: -45; color: capCloseMa.containsMouse ? "#ffffff" : "#cfcfd2" }
                MouseArea { id: capCloseMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.close() }
            }
        }

        // ─── 无边框：窗口顶边 + 顶部左右角的缩放条（其余边在 root 层） ───
        ResizeEdge { root: root; edges: Qt.TopEdge; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.leftMargin: 10; anchors.rightMargin: 10; height: 5; z: 20; visible: appMenuBar.inTitleBar }
        ResizeEdge { root: root; edges: Qt.TopEdge | Qt.LeftEdge;  anchors.left: parent.left;  anchors.top: parent.top; width: 10; height: 10; z: 21; visible: appMenuBar.inTitleBar }
        ResizeEdge { root: root; edges: Qt.TopEdge | Qt.RightEdge; anchors.right: parent.right; anchors.top: parent.top; width: 10; height: 10; z: 21; visible: appMenuBar.inTitleBar }

        // 底部 1px 细分隔线，与下方内容区过渡
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: "#2c2c32"
        }
    }

    delegate: MenuBarItem {
        id: mbItem
        implicitHeight: 26
        padding: 0
        // 调试：标题栏菜单输入可达性（Windows 无边框排查用）
        onPressed: console.log("[TitleBar] 菜单按钮按下:", mbItem.text)
        leftPadding: 10
        rightPadding: 10
        topPadding: 0
        bottomPadding: 0

        // 【禁止悬停切换下拉】Qt 的 MenuBar 内部连接了
        // hoveredChanged → onItemHovered：一旦有菜单展开，鼠标滑过相邻项
        // 就会自动切换下拉。把 hoverEnabled 关掉后该链路失效，
        // 展开/收起/切换完全由点击驱动（C++ triggered → onItemTriggered）。
        // 视觉 hover 反馈由下方自有 HoverHandler 提供，不受影响。
        hoverEnabled: false
        HoverHandler { id: mbHover }

        // 登录项特判：点击直接弹登录/个人信息对话框（其下拉在 loginMenu 的
        // aboutToShow 中被即时收起，永不展示）。
        // 其余菜单【不要】手动 toggle：C++ MenuBar 已连接
        // triggered → onItemTriggered 负责展开/收起；QML 再手动 open/close
        // 会双重触发，表现为"点击后菜单立即缩回去"（Windows 实测）。
        // 【macOS 保护】本 delegate 只在 Windows 自绘菜单栏下生效（inTitleBar=true）。
        // macOS 顶部菜单栏走系统 NSMenu，MenuBarItem.onClicked 永远不会被触发；
        // 但加 !inTitleBar 守卫避免 macOS 误触任何菜单的回调。
        onClicked: {
            if (mbItem.menu === loginMenu && inTitleBar)
                root._toggleLoginDialog()
        }

        contentItem: Text {
            text: mbItem.text
            color: mbItem.highlighted || mbHover.hovered ? "#ffffff" : "#cfcfd2"
            font.pixelSize: 12
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            // 去掉 Qt 默认的 "&" 助记键下划线样式带来的视觉噪点
            textFormat: Text.PlainText
            renderType: Text.NativeRendering
        }

        background: Rectangle {
            implicitHeight: 26
            // highlighted = 当前 Menu 已展开；mbHover.hovered = 鼠标悬停
            //（hoverEnabled 已关闭，视觉悬停改走自有 HoverHandler）
            color: mbItem.highlighted ? "#3a3a45"
                   : mbHover.hovered  ? "#2a2a32"
                                      : "transparent"
            radius: 3
        }
    }

    DarkMenu {
        title: qsTr("文件")
        DarkMenuItem {
            id: miQuit
            text: qsTr("退出 PlayerX")
            onTriggered: Qt.quit()
        }
    }

    // 顶部菜单按模块平铺（每个模块一个顶级 DarkMenu，最深两级）：
    //   文件 / 播放对比 / YUV 分析 / 码流分析 / 通用（开发者模式 + 自动更新） / 帮助 / 登录
    // 系统菜单为原生 NSMenu / Win32 菜单渲染，不接受自定义深色 delegate —— 这是
    // macOS 标准外观，与系统其他应用一致。

    // ═══ 播放对比（模块设置 + 打开入口 + 评分数据）═══════════════════════════════
    DarkMenu {
        id: playCompareMenu
        title: qsTr("播放对比")

        // 打开视频文件（多路视频，进入播放对比）
        DarkMenuItem {
            id: miOpenFile
            text: qsTr("打开文件…")
            enabled: Engine.fileCount < 9
            onTriggered: addDialog.open()
        }
        // 合并入口：单入口同时支持"打开文件夹"（勾选1路）和"多组对比"（勾选≥2路）
        DarkMenuItem {
            id: miOpenFolder
            text: qsTr("打开文件夹…")
            onTriggered: multiGroupDialog.showAndRefresh()
        }
        DarkMenuSeparator {}

        // ── 布局 ▶ ──（4 种多路布局，互斥单选）
        // 不用 Repeater：macOS 全局菜单对动态实例化的 MenuItem 支持不稳定，
        // 显式声明每一项最稳，且和 multiLayoutNames/Values（[1,2,3,4]）一一对应。
        DarkMenu {
            title: qsTr("布局")
            DarkMenuItem {
                text: qsTr("1×N 横排")
                checkable: true
                checked: Engine.layoutMode === 1
                onTriggered: { Engine.layoutMode = 1; root.lastMultiLayout = 1 }
            }
            DarkMenuItem {
                text: qsTr("2×2")
                checkable: true
                checked: Engine.layoutMode === 2
                onTriggered: { Engine.layoutMode = 2; root.lastMultiLayout = 2 }
            }
            DarkMenuItem {
                text: qsTr("2×3")
                checkable: true
                checked: Engine.layoutMode === 3
                onTriggered: { Engine.layoutMode = 3; root.lastMultiLayout = 3 }
            }
            DarkMenuItem {
                text: qsTr("3×3")
                checkable: true
                checked: Engine.layoutMode === 4
                onTriggered: { Engine.layoutMode = 4; root.lastMultiLayout = 4 }
            }
        }

        // ── 播放速度 ▶ ──（5 个常用档位 + 减速/加速/重置）
        // 同样不用 Repeater，原因同上。
        DarkMenu {
            title: qsTr("播放速度")
            DarkMenuItem {
                text: qsTr("0.25x")
                checkable: true
                checked: Math.abs(Engine.speed - 0.25) < 1e-3
                enabled: Engine.fileCount > 0
                onTriggered: Engine.setSpeed(0.25)
            }
            DarkMenuItem {
                text: qsTr("0.5x")
                checkable: true
                checked: Math.abs(Engine.speed - 0.5) < 1e-3
                enabled: Engine.fileCount > 0
                onTriggered: Engine.setSpeed(0.5)
            }
            DarkMenuItem {
                text: qsTr("1.0x （正常）")
                checkable: true
                checked: Math.abs(Engine.speed - 1.0) < 1e-3
                enabled: Engine.fileCount > 0
                onTriggered: Engine.setSpeed(1.0)
            }
            DarkMenuItem {
                text: qsTr("1.5x")
                checkable: true
                checked: Math.abs(Engine.speed - 1.5) < 1e-3
                enabled: Engine.fileCount > 0
                onTriggered: Engine.setSpeed(1.5)
            }
            DarkMenuItem {
                text: qsTr("2.0x")
                checkable: true
                checked: Math.abs(Engine.speed - 2.0) < 1e-3
                enabled: Engine.fileCount > 0
                onTriggered: Engine.setSpeed(2.0)
            }
            DarkMenuSeparator {}
            DarkMenuItem {
                text: qsTr("减速 ( - )")
                enabled: Engine.fileCount > 0
                onTriggered: Engine.adjustSpeed(-1)
            }
            DarkMenuItem {
                text: qsTr("加速 ( = )")
                enabled: Engine.fileCount > 0
                onTriggered: Engine.adjustSpeed(+1)
            }
            DarkMenuItem {
                text: qsTr("重置为 1.0x ( 0 )")
                enabled: Engine.fileCount > 0
                onTriggered: Engine.resetSpeed()
            }
        }

        // ── 测试配置 ▶ ──（评分测试相关配置）
        //  · 自定义：功能待定，先占位（置灰不可点）；
        //  · 恢复默认：把当前模式远程"接受"来的临时覆盖清掉，
        //    回到跟随软件的内置默认配置（Resources/default_configs/<mode>.json），
        //    带二次确认对话框，确认后右下角 toast 反馈。
        DarkMenu {
            title: qsTr("测试配置")
            DarkMenuItem {
                text: qsTr("自定义")
                enabled: false   // 功能待定义，先占位
            }
            DarkMenuItem {
                text: qsTr("恢复默认")
                enabled: (typeof Rating !== "undefined") && Rating.currentMode && Rating.currentMode !== "off"
                onTriggered: restoreDefaultConfirmDialog.open()
            }
            DarkMenuSeparator {}
            // 清空「播放对比 / 多组对比」记住的全部文件夹历史（所有模式），
            // 避免历史堆积到上限后新导入的路被静默丢弃。带二次确认。
            DarkMenuItem {
                text: qsTr("清除多路历史记录")
                onTriggered: clearHistoryConfirmDialog.open()
            }
        }

        DarkMenuSeparator {}

        // ── 滑动对比（仅 2 路视频可用，B 快捷键联动）──
        DarkMenuItem {
            text: qsTr("滑动对比 (B)")
            checkable: true
            checked: root.compareSliderActive
            enabled: root.compareSliderAvailable || root.compareSliderActive
            onTriggered: RatingLogic._toggleCompareSlider()
        }

        // ── 通道信息显示（C 快捷键联动）──
        DarkMenuItem {
            text: qsTr("通道信息 (C)")
            checkable: true
            checked: root.globalChannelVisible
            onTriggered: {
                if (root.fullscreenSuppressChannel) {
                    root.fullscreenSuppressChannel = false
                    root.globalChannelVisible = true
                } else {
                    root.globalChannelVisible = !root.globalChannelVisible
                }
            }
        }

        // ── 视频信息显示（V 快捷键联动）──
        DarkMenuItem {
            text: qsTr("视频信息 (V)")
            checkable: true
            checked: root.globalInfoVisible
            onTriggered: {
                if (root.fullscreenSuppressInfo) {
                    root.fullscreenSuppressInfo = false
                    root.globalInfoVisible = true
                } else {
                    root.globalInfoVisible = !root.globalInfoVisible
                }
            }
        }

        // ── 单路悬停控制条（与下方自绘菜单同步，无快捷键）──
        DarkMenuItem {
            text: qsTr("单路悬停控制条")
            checkable: true
            checked: root.singleControlsHoverEnabled
            onTriggered: root.singleControlsHoverEnabled = !root.singleControlsHoverEnabled
        }

        // ── 自动重播（播放结束后无缝从头继续）──
        // 默认开启；关闭时回退到旧行为：播放结束停在最后一帧。
        DarkMenuItem {
            text: qsTr("自动重播")
            checkable: true
            checked: Engine.loopEnabled
            onTriggered: Engine.loopEnabled = !Engine.loopEnabled
        }

        DarkMenuSeparator {}

        // 评分数据：查看/导出/清空本地 CSV（播放对比模块的评测数据）
        DarkMenuItem {
            id: miRatings
            text: qsTr("评分数据…")
            onTriggered: ratingsDialog.open()
        }
    }

    // ═══ YUV 分析（模块打开入口 + 设置）══════════════
    DarkMenu {
        id: yuvMenu
        title: qsTr("YUV 分析")
        // 打开 .yuv / .y4m 裸数据文件（带分辨率/格式参数，进入 YUV 分析）
        DarkMenuItem {
            text: qsTr("打开 YUV 文件…")
            onTriggered: root.openYuvFileDialog()
        }
        // 打开文件夹并递归扫描 .yuv / .y4m
        DarkMenuItem {
            text: qsTr("打开 YUV 文件夹…")
            onTriggered: root.openYuvFolderDialog()
        }
        DarkMenuSeparator {}

        // ── 块大小 ▶ ──（像素块统计 / 悬浮矩阵的对齐块大小，4 档互斥单选）
        // 全局设置，不依赖右侧栏统计面板是否打开；同样绑定 YuvBridge.blockSize，
        // 用法与"播放速度 ▶"一致（不用 Repeater，逐项声明最稳）。
        DarkMenu {
            title: qsTr("块大小")
            DarkMenuItem {
                text: qsTr("8×8")
                checkable: true
                checked: YuvBridge.blockSize === 8
                onTriggered: YuvBridge.blockSize = 8
            }
            DarkMenuItem {
                text: qsTr("16×16")
                checkable: true
                checked: YuvBridge.blockSize === 16
                onTriggered: YuvBridge.blockSize = 16
            }
            DarkMenuItem {
                text: qsTr("32×32")
                checkable: true
                checked: YuvBridge.blockSize === 32
                onTriggered: YuvBridge.blockSize = 32
            }
            DarkMenuItem {
                text: qsTr("64×64")
                checkable: true
                checked: YuvBridge.blockSize === 64
                onTriggered: YuvBridge.blockSize = 64
            }
        }

        DarkMenuSeparator {}

        // ── 内嵌操作 ▶ ──（渲染区底部内嵌控制条的可见性开关）
        // 默认不勾选 = 隐藏内嵌控制条（避免遮挡画面），让用户专注分析；
        // 勾选后，hover 画面时控制条淡入显示。
        // （语义：checked = "悬浮控制条可见"，与设置项 inlineControlsHidden 取反）
        DarkMenuItem {
            text: qsTr("内嵌悬浮控制条")
            checkable: false
            checked: !YuvBridge.inlineControlsHidden
            onTriggered: YuvBridge.inlineControlsHidden = !checked
        }

        // ── YUV 值面板 ──（hover 视频时弹出的像素矩阵浮窗 + avg/min/max 统计）
        // 默认勾选 = 显示；V 快捷键也可切换。
        DarkMenuItem {
            text: qsTr("YUV 值面板")
            checkable: true
            checked: YuvBridge.pixelInfoVisible
            onTriggered: YuvBridge.pixelInfoVisible = !checked
        }

        // ── 色度插值 ▶ ──（4:2:0/4:2:2 色度上采样算法，3 档互斥单选）
        // 默认 Nearest Neighbor = 像素级分析标准（展示编码器实际存储的原始色度值）
        DarkMenu {
            title: qsTr("色度插值")
            DarkMenuItem {
                text: qsTr("Nearest Neighbor")
                checkable: true
                checked: YuvBridge.chromaInterpolation === 0
                onTriggered: YuvBridge.chromaInterpolation = 0
            }
            DarkMenuItem {
                text: qsTr("Bilinear")
                checkable: true
                checked: YuvBridge.chromaInterpolation === 1
                onTriggered: YuvBridge.chromaInterpolation = 1
            }
            DarkMenuItem {
                text: qsTr("Bicubic")
                checkable: true
                checked: YuvBridge.chromaInterpolation === 2
                onTriggered: YuvBridge.chromaInterpolation = 2
            }
        }

        // ── 颜色转换 ▶ ──（YUV→RGB 色彩矩阵与值域范围，6 档互斥单选）
        // 默认 ITU-R BT.709 limited range = 现代高清标准
        DarkMenu {
            title: qsTr("颜色转换")
            DarkMenuItem {
                text: qsTr("ITU-R BT.709")
                checkable: true
                checked: YuvBridge.colorConversion === 0
                onTriggered: YuvBridge.colorConversion = 0
            }
            DarkMenuItem {
                text: qsTr("ITU-R BT.709 Full Range")
                checkable: true
                checked: YuvBridge.colorConversion === 1
                onTriggered: YuvBridge.colorConversion = 1
            }
            DarkMenuItem {
                text: qsTr("ITU-R BT.601")
                checkable: true
                checked: YuvBridge.colorConversion === 2
                onTriggered: YuvBridge.colorConversion = 2
            }
            DarkMenuItem {
                text: qsTr("ITU-R BT.601 Full Range")
                checkable: true
                checked: YuvBridge.colorConversion === 3
                onTriggered: YuvBridge.colorConversion = 3
            }
            DarkMenuItem {
                text: qsTr("ITU-R BT.2020")
                checkable: true
                checked: YuvBridge.colorConversion === 4
                onTriggered: YuvBridge.colorConversion = 4
            }
            DarkMenuItem {
                text: qsTr("ITU-R BT.2020 Full Range")
                checkable: true
                checked: YuvBridge.colorConversion === 5
                onTriggered: YuvBridge.colorConversion = 5
            }
        }
    }

    // ═══ 图片分析（模块打开入口 + 设置）══════════════
    DarkMenu {
        id: imageMenu
        title: qsTr("图片分析")
        // 打开图片文件
        DarkMenuItem {
            text: qsTr("打开图片文件…")
            onTriggered: root.openImageFileDialog()
        }
        // 打开文件夹并递归扫描图片
        DarkMenuItem {
            text: qsTr("打开图片文件夹…")
            onTriggered: root.openImageFolderDialog()
        }

        DarkMenuSeparator {}

        // ── 内嵌信息条 ──（画面内侧绝对路径+分辨率 overlay，C 快捷键也可切换）
        // 默认勾选 = 显示
        // 注意：checkable MenuItem 在 onTriggered 触发前已自动翻转 checked，
        // 所以不能用 !checked（会翻回原值），必须直接用 imageView.imageInfoVisible 取反。
        DarkMenuItem {
            text: qsTr("内嵌信息条")
            checkable: true
            checked: imageView.imageInfoVisible
            onTriggered: imageView.imageInfoVisible = !imageView.imageInfoVisible
        }

        // ── 渲染模式 ──（顶部下拉切换，默认 standard = 物理像素级渲染）
        DarkMenu {
            title: qsTr("渲染模式")
            DarkMenuItem {
                text: qsTr("标准（物理像素级，默认）")
                checkable: true
                checked: imageView.renderMode === "standard"
                onTriggered: imageView.renderMode = "standard"
            }
            DarkMenuItem {
                text: qsTr("平滑（双三次插值）")
                checkable: true
                checked: imageView.renderMode === "smooth"
                onTriggered: imageView.renderMode = "smooth"
            }
            DarkMenuItem {
                text: qsTr("像素级（最近邻，逐像素分析）")
                checkable: true
                checked: imageView.renderMode === "pixel"
                onTriggered: imageView.renderMode = "pixel"
            }
        }

        // ── 布局方式 ──（多路图片的排列模式）
        DarkMenu {
            title: qsTr("布局方式")
            DarkMenuItem {
                text: qsTr("自动（1路单显，多路网格，默认）")
                checkable: true
                checked: imageView.layoutMode === "auto"
                onTriggered: imageView.layoutMode = "auto"
            }
            DarkMenuItem {
                text: qsTr("轮播（单通道，左右键切换）")
                checkable: true
                checked: imageView.layoutMode === "carousel"
                onTriggered: imageView.layoutMode = "carousel"
            }
            DarkMenuItem {
                text: qsTr("横排（水平排列，可滚动）")
                checkable: true
                checked: imageView.layoutMode === "horizontal"
                onTriggered: imageView.layoutMode = "horizontal"
            }
            DarkMenuItem {
                text: qsTr("网格（块状排列）")
                checkable: true
                checked: imageView.layoutMode === "grid"
                onTriggered: imageView.layoutMode = "grid"
            }

            DarkMenuSeparator {}

            // 网格列数设置（仅对网格模式有效，0=自动）
            DarkMenu {
                title: qsTr("网格列数")
                DarkMenuItem {
                    text: qsTr("自动（≤4两列，>4三列）")
                    checkable: true
                    checked: imageView.gridColumns === 0
                    onTriggered: imageView.gridColumns = 0
                }
                DarkMenuItem {
                    text: qsTr("2 列")
                    checkable: true
                    checked: imageView.gridColumns === 2
                    onTriggered: imageView.gridColumns = 2
                }
                DarkMenuItem {
                    text: qsTr("3 列")
                    checkable: true
                    checked: imageView.gridColumns === 3
                    onTriggered: imageView.gridColumns = 3
                }
                DarkMenuItem {
                    text: qsTr("4 列")
                    checkable: true
                    checked: imageView.gridColumns === 4
                    onTriggered: imageView.gridColumns = 4
                }
            }
        }
    }

    // ═══ 码流分析（暂未实现，仅留占位提示）══════════════
    DarkMenu {
        id: streamMenu
        title: qsTr("码流分析")
        DarkMenuItem {
            text: qsTr("暂未实现")
            enabled: false
        }
    }

    // ═══ 通用（跨模块：关闭视频 + 日志 + 开发者模式 + 自动更新）══════════════
    DarkMenu {
        id: generalMenu
        title: qsTr("通用")

        // 一次性关闭所有视频（与单路 ✕ 一致；已去除二次确认，直接清空）
        DarkMenuItem {
            id: miCloseAll
            text: qsTr("关闭所有视频")
            enabled: Engine.fileCount > 0
            onTriggered: Engine.closeAll()
        }
        // 打开日志目录（排查问题用：每次启动在 <CacheLocation>/logs/ 下生成日志）
        DarkMenuItem {
            text: qsTr("打开日志目录")
            onTriggered: Fs.revealInFileManager(Fs.appLogDir())
        }
        DarkMenuSeparator {}

        // ── 开发者模式 ──（每次启动一律不勾选，不记忆）
        // 勾选后：模式选择菜单 / 评分数据面板 Tab 中显示「测试模式」；
        // 不勾选：测试模式隐藏。仅本次会话有效，重启恢复不勾选。
        DarkMenuItem {
            text: qsTr("开发者模式")
            checkable: true
            checked: root.developerMode
            onTriggered: root._setDeveloperMode(!root.developerMode)
        }

        // ── 自动更新 ──（默认不勾选）
        // 勾选：重启软件后自动检测并下载安装新版本，全程无需点击；
        // 不勾选：维持原逻辑 —— 右上角胶囊提醒，用户手动选择更新。
        DarkMenuItem {
            text: qsTr("自动更新")
            checkable: true
            checked: root.autoUpdate
            onTriggered: root._setAutoUpdate(!root.autoUpdate)
        }
    }

    DarkMenu {
        id: helpMenu
        title: qsTr("帮助")
        // 动态首项：仅在检测到新版本时显示，作为"系统全局菜单"下的兜底入口
        // —— macOS 顶端原生菜单不允许塞自定义控件，所以这里给一份纯 MenuItem。
        DarkMenuItem {
            id: miUpdateAvailable
            visible: Updater.updateAvailable
            height: visible ? implicitHeight : 0
            text: qsTr("⬆ 安装新版本 %1…").arg(Updater.latestVersion)
            onTriggered: updateDialog.open()
        }
        DarkMenuSeparator { visible: miUpdateAvailable.visible }
        DarkMenuItem {
            text: qsTr("检查更新…")
            onTriggered: { updateDialog.userInitiated = true; Updater.checkForUpdates(false) }
        }
        DarkMenuSeparator {}
        DarkMenuItem {
            text: qsTr("快捷键…")
            onTriggered: shortcutsAboutDialogs.openShortcuts()
        }
        DarkMenuSeparator {}
        DarkMenuItem {
            text: qsTr("教程…")
            // 占位 URL 见 root.tutorialUrl；点击后用系统默认浏览器打开
            onTriggered: {
                if (!Qt.openUrlExternally(root.tutorialUrl)) {
                    console.warn("[Help] 无法打开教程链接：", root.tutorialUrl)
                }
            }
        }
        DarkMenuSeparator {}
        DarkMenuItem {
            text: qsTr("关于 PlayerX")
            onTriggered: shortcutsAboutDialogs.openAbout()
        }
    }

    // ─── 登录 ────────────────────────────────────────────────
    // 未登录显示「登录」，已登录显示评分人名字。
    // 点击直接弹登录/个人信息对话框、永不出下拉：
    //   · macOS：C++ 在 NSMenu 即将展开时 cancelTracking 拦截
    //     （src/qt/MacAppearance.mm installLoginMenuSuppressor）；
    //   · Windows/Linux：menuBar delegate 特判点击直弹。
    // 菜单项仅作兜底（拦截失效时仍可点开对话框）。
    // 评分人即 Rating.currentUser，与评分数据面板顶部输入框同一份数据。
    DarkMenu {
        id: loginMenu
        title: root._loggedIn ? Rating.currentUser : qsTr("登录")
        // Windows/Linux（QML 菜单）：C++ MenuBar 点击菜单项时会无条件 popup
        // 本菜单，这里在 aboutToShow 阶段立即收起 → 永不出现下拉，
        // 与 macOS 原生 NSMenuDelegate cancelTracking 拦截同语义。
        // aboutToShow 于弹窗实际显示前发出，此时收起不会产生可见闪烁。
        onAboutToShow: close()
        DarkMenuItem {
            text: root._loggedIn ? qsTr("个人信息…") : qsTr("登录…")
            onTriggered: root._toggleLoginDialog()
        }
    }
}
