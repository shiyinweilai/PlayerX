// Main.qml — PlayerXQt 第 2 阶段：多路视频 + 主时钟同步
//
// 功能：
//   - 顶部工具栏：Open（支持多选）/ Add / 播放暂停 / 帧步进 / Layout 切换 / 时间
//   - 视频区根据 Engine.layoutMode 与 Engine.fileCount 自动布局
//   - 每路视频窗口：序号徽标、单击聚焦（蓝边框 = activeIndex）、双击切换该路暂停
//   - 全局快捷键：Space 全局暂停 / ←→ 全局 ±5s / , . 全局帧步进 / F 全局 / S 切多路 layout
//                  数字键 1..9 切到 Single 模式并聚焦该路（只显示该请求序号的请求）//   - 底部进度条作用于全局主时钟
//
// 注意：仍保留 Engine 为 contextProperty（C++ 端 setContextProperty）。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerXQt 1.0

ApplicationWindow {
    id: root
    width: 1440
    height: 900
    visible: true
    title: "PlayerXQt"
    color: "#101012"

    // ─── 统一的扁平按钮 / 工具按钮 ──────────────────────────────────────
    // 完全用 Rectangle + MouseArea 自绘，不依赖 Qt Quick Controls 的全局
    // 风格设置（macOS 上 setStyle("Basic") 在某些 Qt 版本下不生效，会
    // fallback 到 native 风格，导致 background/contentItem 委托失效）。
    // 这里直接自绘可保证 hover/pressed 反馈在所有平台一致可见。
    component FlatButton: Rectangle {
        id: fb
        // 公共 API（兼容原 Button 用法）
        property string text: ""
        property bool   enabled: true
        property alias  font: fbText.font
        property bool   hovered: fbHover.hovered
        property bool   down: fbMouse.pressed && fb.enabled
        signal clicked()

        // 尺寸：根据文字自适应；外部仍可 Layout.preferredWidth 覆盖
        implicitWidth:  Math.max(56, fbText.implicitWidth + 24)
        implicitHeight: 28
        radius: 5

        // 颜色分层：down(明亮灰) > hovered(中灰) > normal(深灰) > disabled(几乎隐隐)
        color: !fb.enabled ? "#1a1a1d"
              : fb.down    ? "#4a4a55"   // 按下：明显的亮灰
              : fb.hovered ? "#33333a"   // 悬停：中灰
                           : "#202024"   // 默认：深灰
        border.color: !fb.enabled ? "#252528"
                     : fb.down    ? "#6a6a78"
                     : fb.hovered ? "#3d3d46"
                                  : "#2c2c32"
        border.width: 1
        Behavior on color        { ColorAnimation  { duration: 90 } }
        Behavior on border.color { ColorAnimation  { duration: 90 } }

        // 按下缩放 0.94，给出明确物理反馈
        scale: down ? 0.94 : 1.0
        Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

        Text {
            id: fbText
            anchors.centerIn: parent
            text: fb.text
            font.pixelSize: 13
            color: !fb.enabled ? "#555"
                  : fb.down    ? "#ffffff"
                                : "#e8e8ec"
            Behavior on color { ColorAnimation { duration: 90 } }
        }

        HoverHandler {
            id: fbHover
            cursorShape: fb.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: fb.enabled
        }
        MouseArea {
            id: fbMouse
            anchors.fill: parent
            enabled: fb.enabled
            hoverEnabled: false   // hover 已交给 HoverHandler
            onClicked: fb.clicked()
        }
        opacity: enabled ? 1.0 : 0.5
    }

    component FlatToolButton: Rectangle {
        id: ftb
        property string text: ""
        property bool   enabled: true
        property alias  font: ftbText.font
        property bool   hovered: ftbHover.hovered
        property bool   down: ftbMouse.pressed && ftb.enabled
        signal clicked()

        implicitWidth:  Math.max(34, ftbText.implicitWidth + 16)
        implicitHeight: 26
        radius: 4

        color: !ftb.enabled ? "transparent"
              : ftb.down    ? "#55ffffff"   // 按下：半透明白
              : ftb.hovered ? "#33ffffff"   // 悬停：更淡的半透明白
                            : "transparent"
        border.color: ftb.down ? "#88ffffff" : "transparent"
        border.width: 1
        Behavior on color { ColorAnimation { duration: 90 } }

        scale: down ? 0.92 : 1.0
        Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

        Text {
            id: ftbText
            anchors.centerIn: parent
            text: ftb.text
            font.pixelSize: 13
            color: !ftb.enabled ? "#555"
                  : ftb.down    ? "#ffffff"
                                : "#e8e8ec"
        }

        HoverHandler {
            id: ftbHover
            cursorShape: ftb.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: ftb.enabled
        }
        MouseArea {
            id: ftbMouse
            anchors.fill: parent
            enabled: ftb.enabled
            hoverEnabled: false
            onClicked: ftb.clicked()
        }
        opacity: enabled ? 1.0 : 0.5
    }

    // ─── 工具：把秒数格式化为 HH:MM:SS ───────────────────────────────────
    function fmtTime(sec) {
        if (!isFinite(sec) || sec < 0) sec = 0
        var h = Math.floor(sec / 3600)
        var m = Math.floor((sec % 3600) / 60)
        var s = Math.floor(sec % 60)
        function pad(n) { return n < 10 ? "0" + n : "" + n }
        return (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(s)
    }

    // Layout 名称：与 EngineBridge::LayoutMode 同序
    //   0 = Single、1 = SideBySide(1×N 横排，默认)、2 = 2x2、3 = 2x3、4 = 3x3
    // Single 模式不在 ComboBox 里选择（通过数字键 1..9 进入）。
    readonly property var layoutNames: ["Single", "1×N 横排", "2×2", "2×3", "3×3"]
    // ComboBox 限定选项（不包含 Single）
    readonly property var multiLayoutNames: ["1×N 横排", "2×2", "2×3", "3×3"]
    readonly property var multiLayoutValues: [1, 2, 3, 4]

    // 记住上一次使用的“多路布局”，让按下 0 键可以准确回到该布局。
    // 默认 SideBySide=1。仅在 ComboBox 交互、S 键循环、打开多个文件后同步。
    property int lastMultiLayout: 1

    // 全局“显示所有视频信息”开关（设置菜单 / 快捷键 V 控制）。
    // cell 自身仍保留右键的局部开关（localInfoVisible），二者取或。
    property bool globalInfoVisible: false

    // 全局“通道信息”开关（设置菜单 / 快捷键 C 控制）。
    // 控制每个窗口左上角的序号徽标 + 右上角的文件名。默认 true。
    property bool globalChannelVisible: true

    // 全屏拑制：按 F 进入全屏后，V/C 对应的叠加元素默认隐藏，但仍可
    // 再按 V/C 售起。本质是一个“临时压制”标志，被Pick V/C 按下时会被清除。
    // 退出全屏时也会被清除。
    property bool fullscreenSuppressInfo:    false
    property bool fullscreenSuppressChannel: false

    // 实际是否显示：全局开关 且 不处于全屏拑制状态。
    readonly property bool effectiveInfoVisible:    globalInfoVisible    && !fullscreenSuppressInfo
    readonly property bool effectiveChannelVisible: globalChannelVisible && !fullscreenSuppressChannel

    // ─── 文件选择 ────────────────────────────────────────────────────────
    FileDialog {
        id: openDialog
        title: "选择视频文件（可多选）"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv)",
            "所有文件 (*)"
        ]
        onAccepted: Engine.openFiles(selectedFiles)
    }
    FileDialog {
        id: addDialog
        title: "添加视频文件"
        fileMode: FileDialog.OpenFile
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv)",
            "所有文件 (*)"
        ]
        onAccepted: Engine.addFile(selectedFile)
    }

    // ─── 顶部工具栏 ──────────────────────────────────────────────────────
    // 自绘 background：深色填充 + 底部 1px 分隔线，与视频区在视觉上彻底
    // 切开。原先 ToolBar 用系统主题色，与视频黑底界限模糊，按钮按下时还
    // 会引起整体重绘抖动。
    header: ToolBar {
        id: topBar
        height: 44
        background: Rectangle {
            color: "#17171a"
            // 底部分隔线
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#000"
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 10
            anchors.topMargin: 5
            anchors.bottomMargin: 6
            spacing: 6

            FlatButton {
                text: Engine.fileCount > 0 ? "新打开" : "打开"
                onClicked: openDialog.open()
            }
            FlatButton {
                text: "添加"
                enabled: Engine.fileCount > 0 && Engine.fileCount < 9
                onClicked: addDialog.open()
            }
            Rectangle { width: 1; Layout.fillHeight: true; color: "#2a2a30"; Layout.topMargin: 6; Layout.bottomMargin: 6 }
            FlatButton {
                text: "<<"
                enabled: Engine.duration > 0
                // 相对快退：每路在自己当前位置 -5s，独立时钟的路不被对齐到主时钟
                onClicked: Engine.seekRelative(-5)
            }
            FlatButton {
                text: "<"
                enabled: Engine.duration > 0
                onClicked: Engine.stepFrame(-1)
            }
            // 播放/暂停按钮：固定宽度，避免图标切换时旁边按钮抖动
            FlatButton {
                id: playPauseBtn
                enabled: Engine.fileCount > 0
                Layout.preferredWidth: 56
                text: Engine.playing ? "⏸" : "▶"
                font.pixelSize: 16
                onClicked: Engine.togglePause()
            }
            FlatButton {
                text: ">"
                enabled: Engine.duration > 0
                onClicked: Engine.stepFrame(1)
            }
            FlatButton {
                text: ">>"
                enabled: Engine.duration > 0
                // 相对快进：每路在自己当前位置 +5s，独立时钟的路不被对齐到主时钟
                onClicked: Engine.seekRelative(5)
            }
            // 全局重置：所有路 seek 回 0（与快捷键 R 等价）
            FlatButton {
                text: "⟲"
                font.pixelSize: 16
                enabled: Engine.fileCount > 0
                onClicked: Engine.seek(0)
            }

            Rectangle { width: 1; Layout.fillHeight: true; color: "#2a2a30"; Layout.topMargin: 6; Layout.bottomMargin: 6 }

            // ─── 设置按钮（多级菜单）────────────────────────────────────
            FlatButton {
                id: settingsBtn
                text: "⚙ 设置 ▾"
                Layout.preferredWidth: 86
                onClicked: settingsMenu.popup(settingsBtn, 0, settingsBtn.height + 2)
            }

            // ── 设置一级菜单（深色，自绘）──
            Menu {
                id: settingsMenu
                padding: 4
                width: 180

                background: Rectangle {
                    color: "#1e1e22"
                    border.color: "#3a3a42"
                    border.width: 1
                    radius: 6
                }

                // 自绘统一的菜单项 delegate（深色 + 悬停灰底，不会出现 macOS 默认白底）
                delegate: MenuItem {
                    id: settingsItem
                    implicitHeight: 30
                    background: Rectangle {
                        radius: 4
                        color: settingsItem.highlighted ? "#33333a" : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 0
                        Text {
                            leftPadding: 10
                            text: settingsItem.checkable && settingsItem.checked ? "✓" : ""
                            color: "#6a9fd8"
                            font.pixelSize: 12
                            verticalAlignment: Text.AlignVCenter
                            Layout.minimumWidth: 22
                        }
                        Text {
                            text: settingsItem.text
                            color: "#e8e8ec"
                            font.pixelSize: 13
                            verticalAlignment: Text.AlignVCenter
                            Layout.fillWidth: true
                        }
                        // 子菜单箭头：当此项是「布局」入口时显示 ▶
                        Text {
                            text: settingsItem.text === "布局" ? "▶" : ""
                            color: "#888"
                            font.pixelSize: 11
                            verticalAlignment: Text.AlignVCenter
                            rightPadding: 10
                        }
                    }
                }

                // ── 二级菜单：布局（Qt 原生嵌套 Menu，悬停自动展开）──
                Menu {
                    id: layoutSubMenu
                    title: "布局"
                    padding: 4
                    width: 140

                    background: Rectangle {
                        color: "#1e1e22"
                        border.color: "#3a3a42"
                        border.width: 1
                        radius: 6
                    }

                    delegate: MenuItem {
                        id: layoutItem
                        implicitHeight: 30
                        background: Rectangle {
                            radius: 4
                            color: layoutItem.highlighted ? "#33333a" : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 0
                            Text {
                                leftPadding: 10
                                text: layoutItem.checked ? "✓" : ""
                                color: "#6a9fd8"
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                Layout.minimumWidth: 22
                            }
                            Text {
                                text: layoutItem.text
                                color: "#e8e8ec"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                                Layout.fillWidth: true
                            }
                        }
                    }

                    Repeater {
                        model: root.multiLayoutNames
                        MenuItem {
                            id: layoutRepItem
                            required property string modelData
                            required property int index
                            text: modelData
                            checkable: true
                            checked: Engine.layoutMode === root.multiLayoutValues[index]
                            onTriggered: {
                                var v = root.multiLayoutValues[index]
                                Engine.layoutMode = v
                                root.lastMultiLayout = v
                            }
                            implicitHeight: 30
                            background: Rectangle {
                                radius: 4
                                color: layoutRepItem.highlighted ? "#33333a" : "transparent"
                            }
                            contentItem: RowLayout {
                                spacing: 0
                                Text {
                                    leftPadding: 10
                                    text: layoutRepItem.checked ? "✓" : ""
                                    color: "#6a9fd8"
                                    font.pixelSize: 12
                                    verticalAlignment: Text.AlignVCenter
                                    Layout.minimumWidth: 22
                                }
                                Text {
                                    text: layoutRepItem.text
                                    color: "#e8e8ec"
                                    font.pixelSize: 13
                                    verticalAlignment: Text.AlignVCenter
                                    Layout.fillWidth: true
                                }
                            }
                        }
                    }
                }

                MenuSeparator {
                    contentItem: Rectangle { implicitHeight: 1; color: "#3a3a42" }
                }

                // ── 通道信息显示（全局开关，快捷键 C，默认开启）──
                // 控制每个窗口的左上角序号徽标 + 右上角文件名 Label。
                MenuItem {
                    id: channelItem
                    text: "通道信息 (C)"
                    checkable: true
                    checked: root.globalChannelVisible
                    onTriggered: {
                        // 处于全屏抑制态时：先清掉抑制并强制显示
                        if (root.fullscreenSuppressChannel) {
                            root.fullscreenSuppressChannel = false
                            root.globalChannelVisible = true
                        } else {
                            root.globalChannelVisible = !root.globalChannelVisible
                        }
                    }
                    implicitHeight: 30
                    background: Rectangle {
                        radius: 4
                        color: channelItem.highlighted ? "#33333a" : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 0
                        Text {
                            leftPadding: 10
                            text: channelItem.checked ? "✓" : ""
                            color: "#6a9fd8"
                            font.pixelSize: 12
                            verticalAlignment: Text.AlignVCenter
                            Layout.minimumWidth: 22
                        }
                        Text {
                            text: channelItem.text
                            color: "#e8e8ec"
                            font.pixelSize: 13
                            verticalAlignment: Text.AlignVCenter
                            Layout.fillWidth: true
                        }
                    }
                }

                // ── 视频信息显示（全局开关，快捷键 V）──
                MenuItem {
                    id: infoItem
                    text: "视频信息 (V)"
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
                    implicitHeight: 30
                    background: Rectangle {
                        radius: 4
                        color: infoItem.highlighted ? "#33333a" : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 0
                        Text {
                            leftPadding: 10
                            text: infoItem.checked ? "✓" : ""
                            color: "#6a9fd8"
                            font.pixelSize: 12
                            verticalAlignment: Text.AlignVCenter
                            Layout.minimumWidth: 22
                        }
                        Text {
                            text: infoItem.text
                            color: "#e8e8ec"
                            font.pixelSize: 13
                            verticalAlignment: Text.AlignVCenter
                            Layout.fillWidth: true
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            Label {
                color: "#cfcfd2"
                text: fmtTime(Engine.position) + " / " + fmtTime(Engine.duration)
            }
        }
    }

    // ─── 全局快捷键（ApplicationShortcut，与焦点无关）────────────────────
    // 用 Shortcut 而非 Keys.onPressed，避免焦点跑到 ToolBar/Slider/ComboBox
    // 后空格、左右键等"全局控制"快捷键失效。
    Shortcut {
        sequence: "Space"; context: Qt.ApplicationShortcut
        onActivated: Engine.togglePause()
    }
    // V：切换全局显示视频信息。全屏拑制状下会先清拑再强制显示。
    Shortcut {
        sequence: "V"; context: Qt.ApplicationShortcut
        onActivated: {
            if (root.fullscreenSuppressInfo) {
                root.fullscreenSuppressInfo = false
                root.globalInfoVisible = true
            } else {
                root.globalInfoVisible = !root.globalInfoVisible
            }
        }
    }
    // C：切换全局通道信息（序号+文件名）。全屏拑制状下会先清拑再强制显示。
    Shortcut {
        sequence: "C"; context: Qt.ApplicationShortcut
        onActivated: {
            if (root.fullscreenSuppressChannel) {
                root.fullscreenSuppressChannel = false
                root.globalChannelVisible = true
            } else {
                root.globalChannelVisible = !root.globalChannelVisible
            }
        }
    }
    Shortcut {
        sequence: "Left"; context: Qt.ApplicationShortcut
        onActivated: Engine.seek(Math.max(0, Engine.position - 5))
    }
    Shortcut {
        sequence: "Right"; context: Qt.ApplicationShortcut
        onActivated: Engine.seek(Math.min(Engine.duration, Engine.position + 5))
    }
    Shortcut {
        sequence: ","; context: Qt.ApplicationShortcut
        onActivated: Engine.stepFrame(-1)
    }
    Shortcut {
        sequence: "."; context: Qt.ApplicationShortcut
        onActivated: Engine.stepFrame(1)
    }
    Shortcut {
        sequence: "F"; context: Qt.ApplicationShortcut
        onActivated: {
            var goingFullscreen = (root.visibility !== Window.FullScreen)
            root.visibility = goingFullscreen
                ? Window.FullScreen : Window.AutomaticVisibility
            // 进入全屏：默认拑制 V/C 的叠加显示，但保留开关本身的值，
            // 用户可以再按 V/C 售起。退出全屏：清除拑制，恢复平常表现。
            if (goingFullscreen) {
                root.fullscreenSuppressInfo    = true
                root.fullscreenSuppressChannel = true
            } else {
                root.fullscreenSuppressInfo    = false
                root.fullscreenSuppressChannel = false
            }
        }
    }
    Shortcut {
        sequence: "S"; context: Qt.ApplicationShortcut
        // 在多路布局之间循环切换（不包含 Single）
        onActivated: {
            var arr = root.multiLayoutValues
            var i = arr.indexOf(Engine.layoutMode)
            if (i < 0) i = 0
            var v = arr[(i + 1) % arr.length]
            Engine.layoutMode = v
            root.lastMultiLayout = v
        }
    }
    Shortcut {
        sequence: "R"; context: Qt.ApplicationShortcut
        onActivated: Engine.seek(0)
    }
    // 数字键 1..9：toggle 单路/多路。
    //   - 当前不是 Single，或 activeIndex != n-1：进入 Single 并显示对应窗口
    //   - 当前已经是 Single 且 activeIndex == n-1（再次按下相同数字）：
    //     切回上一次使用的多路布局（lastMultiLayout，默认 1×N）
    //
    // 注意：原先用 Repeater { Shortcut {...} } 并不会工作 —— Repeater 的
    // delegate 必须是 Item/可视类型，非可视的 Shortcut 不会被实例化，所以
    // 数字键根本不会触发。改成展开 9 个独立的 Shortcut。
    function _toggleOne(idx) {
        if (idx < 0 || idx >= Engine.fileCount) return
        // 已经在该单路视图：再次按下 -> 回多路
        if (Engine.layoutMode === 0 && Engine.activeIndex === idx) {
            var v = root.lastMultiLayout
            if (v === 0) v = 1   // 保险：永远不会回到 Single
            Engine.layoutMode = v
            return
        }
        // 否则进入 Single 并聚焦到该窗口
        Engine.activeIndex = idx
        Engine.layoutMode  = 0  // LayoutSingle
    }
    Shortcut { sequence: "1"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(0) }
    Shortcut { sequence: "2"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(1) }
    Shortcut { sequence: "3"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(2) }
    Shortcut { sequence: "4"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(3) }
    Shortcut { sequence: "5"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(4) }
    Shortcut { sequence: "6"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(5) }
    Shortcut { sequence: "7"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(6) }
    Shortcut { sequence: "8"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(7) }
    Shortcut { sequence: "9"; context: Qt.ApplicationShortcut; onActivated: root._toggleOne(8) }

    // ─── 视频网格容器 ────────────────────────────────────────────────────
    // 顶部留 2px 余白，避免与 ToolBar 视觉粘连；同时让 cell 的 2px 选中边
    // 框不被 ToolBar 阴影/分隔线压住。
    Item {
        id: videoArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 2
        anchors.bottom: parent.bottom

        focus: true

        // ── Grid 计算行列 ──
        // SideBySide = 单行 N 列（1×N 横排）；其他是固定网格。
        function gridCols() {
            var n = videoArea.visibleCount()
            if (n <= 0) return 1
            switch (Engine.layoutMode) {
            case 0: return 1                          // Single
            case 1: return n                          // SideBySide = 1×N
            case 2: return 2                          // 2x2
            case 3: return 3                          // 2x3
            case 4: return 3                          // 3x3
            }
            return 1
        }
        function gridRows() {
            var c = gridCols()
            return Math.max(1, Math.ceil(visibleCount() / c))
        }
        function visibleCount() {
            if (Engine.fileCount <= 0) return 0
            switch (Engine.layoutMode) {
            case 0: return 1                                     // Single
            case 1: return Math.min(9, Engine.fileCount)         // SideBySide (1×N)
            case 2: return Math.min(4, Engine.fileCount)         // 2x2
            case 3: return Math.min(6, Engine.fileCount)         // 2x3
            case 4: return Math.min(9, Engine.fileCount)         // 3x3
            }
            return Engine.fileCount
        }
        // 第 i 个槽位实际对应的 player 索引
        function slotPlayerIndex(slot) {
            if (Engine.layoutMode === 0) return Engine.activeIndex
            return slot
        }

        Grid {
            id: grid
            anchors.fill: parent
            columns: videoArea.gridCols()
            rows: videoArea.gridRows()
            spacing: 4

            Repeater {
                model: videoArea.visibleCount()

                delegate: Rectangle {
                    id: cell
                    width:  (grid.width  - grid.spacing * (grid.columns - 1)) / Math.max(1, grid.columns)
                    height: (grid.height - grid.spacing * (grid.rows    - 1)) / Math.max(1, grid.rows)
                    color: "#000"
                    // 不显示选中边框：鼠标悬停时悬浮控制条已提供足够的视觉反馈
                    border.color: "#222"
                    border.width: 2

                    property int playerIdx: videoArea.slotPlayerIndex(index)

                    // ─── 单路状态（依赖 Engine 每帧 tick 时发出的 positionChanged）──
                    // 通过函数代替属性绑定，强制每次 Engine.position 变化都重新求值，
                    // 这样单路时间/进度条与该路真实播放位置保持同步。
                    function _pos() { Engine.position; return Engine.positionAt(cell.playerIdx) }
                    function _dur() { Engine.duration; return Engine.durationAt(cell.playerIdx) }
                    function _playing() { Engine.playing; return Engine.playingAt(cell.playerIdx) }

                    VideoFrameProvider {
                        id: vp
                        anchors.fill: parent
                        anchors.margins: 2
                        engine: Engine
                        playerIndex: cell.playerIdx
                    }

                    // 序号徽标（受全局“通道信息”开关控制，默认显示）
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.margins: 6
                        width: 22; height: 22; radius: 4
                        color: "#cc000000"
                        z: 5
                        visible: root.effectiveChannelVisible
                        Label {
                            anchors.centerIn: parent
                            text: cell.playerIdx + 1
                            color: "white"
                            font.bold: true
                        }
                    }

                    // 顶部右侧“通道信息”胶囊条：帧号 · 时间戳 · 文件名。
                    // 受全局“通道信息”开关控制，默认显示；帧号/时间戳随 Engine.position 自动刷新。
                    Rectangle {
                        id: channelBar
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 6
                        radius: 3
                        color: "#aa000000"
                        z: 5
                        visible: root.effectiveChannelVisible
                        // 宽/高按内容自适应
                        implicitWidth:  channelRow.implicitWidth + 12
                        implicitHeight: channelRow.implicitHeight + 4
                        width:  implicitWidth
                        height: implicitHeight

                        // 动态信息（帧号/时间戳）随引擎位置变化刷新
                        property var info: ({})
                        function refreshInfo() {
                            if (visible) info = Engine.videoInfoAt(cell.playerIdx)
                        }
                        Connections {
                            target: Engine
                            function onPositionChanged() { channelBar.refreshInfo() }
                        }
                        onVisibleChanged: refreshInfo()
                        Component.onCompleted: refreshInfo()

                        RowLayout {
                            id: channelRow
                            anchors.centerIn: parent
                            spacing: 8

                            // 帧号
                            Text {
                                color: "#e8e8ec"
                                font.pixelSize: 11
                                font.family: "Menlo, Monaco, Courier New, monospace"
                                text: channelBar.info.frameNum !== undefined
                                      ? "#" + channelBar.info.frameNum
                                      : "#—"
                            }
                            Rectangle {
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 12
                                color: "#55ffffff"
                            }
                            // 时间戳
                            Text {
                                color: "#e8e8ec"
                                font.pixelSize: 11
                                font.family: "Menlo, Monaco, Courier New, monospace"
                                text: channelBar.info.pts !== undefined
                                      ? channelBar.info.pts.toFixed(3) + "s"
                                      : "—"
                            }
                            Rectangle {
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 12
                                color: "#55ffffff"
                            }
                            // 文件名
                            Text {
                                color: "#dcdcde"
                                font.pixelSize: 11
                                text: Engine.fileNameAt(cell.playerIdx)
                                elide: Text.ElideMiddle
                                Layout.maximumWidth: Math.max(80, cell.width / 2)
                            }
                        }
                    }

                    // 鼠标交互：单击选中、双击切换该路暂停
                    // 注意：_pos / _dur / _playing 在上面已定义，这里不重复
                    // 注意：MouseArea 仅用于点击/双击。hover 检测改用下面的 HoverHandler，
                    // 因为 MouseArea.containsMouse 会被子项（ToolButton 等）截获，
                    // 导致鼠标移到工具条按钮上时 cellMouse.containsMouse 变 false → 工具条隐藏
                    // → 按钮也消失 → 鼠标又"回到"cell → 工具条出现……陷入抖动闪烁。
                    MouseArea {
                        id: cellMouse
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                // 右键：刷新信息并切换信息面板显示
                                cell.localInfoVisible = !cell.localInfoVisible
                            } else {
                                Engine.activeIndex = cell.playerIdx
                                videoArea.forceActiveFocus()
                            }
                        }
                        onDoubleClicked: (mouse) => {
                            if (mouse.button === Qt.LeftButton)
                                Engine.togglePauseAt(cell.playerIdx)
                        }
                    }

                    // 右键信息面板开关状态：局部（右键）+ 全局（设置菜单/V）。
                    // 全局部分走 effectiveInfoVisible，全屏拑制后不显示。局部右键仍以实体为准。
                    property bool localInfoVisible: false
                    readonly property bool infoVisible: localInfoVisible || root.effectiveInfoVisible

                    // ─── 右键视频信息面板 ──────────────────────────────────
                    // 固定显示在 cell 左上角（序号徽标下方），右键再次点击关闭。
                    // 每次 positionChanged 时自动刷新帧号/帧类型/pts。
                    Rectangle {
                        id: infoPanel
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.leftMargin: 6
                        anchors.topMargin: 34   // 序号徽标(22px) + 6px margin + 6px gap
                        width: infoPanelCol.implicitWidth + 20
                        height: infoPanelCol.implicitHeight + 16
                        radius: 6
                        color: "#dd0d0d10"
                        border.color: "#33ffffff"
                        border.width: 1
                        z: 20
                        visible: cell.infoVisible
                        clip: true

                        // 每次 position 变化时刷新动态信息（帧号/帧类型/pts）
                        property var info: ({})
                        function refreshInfo() {
                            info = Engine.videoInfoAt(cell.playerIdx)
                        }
                        Connections {
                            target: Engine
                            function onPositionChanged() {
                                if (infoPanel.visible) infoPanel.refreshInfo()
                            }
                        }
                        // 面板变为可见时立刻刷新一次
                        onVisibleChanged: { if (visible) refreshInfo() }

                        ColumnLayout {
                            id: infoPanelCol
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.leftMargin: 10
                            anchors.topMargin: 8
                            spacing: 3

                            // 标题行
                            Text {
                                text: "视频信息"
                                color: "#ffffff"
                                font.pixelSize: 11
                                font.bold: true
                                opacity: 0.9
                            }
                            // 分隔线
                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: "#44ffffff"
                                Layout.rightMargin: 10
                            }

                            // 信息行组件（复用）
                            component InfoRow: RowLayout {
                                property string label: ""
                                property string value: ""
                                spacing: 6
                                Text {
                                    text: label + ":"
                                    color: "#9a9aa8"
                                    font.pixelSize: 11
                                    Layout.minimumWidth: 52
                                }
                                Text {
                                    text: value
                                    color: "#e8e8ec"
                                    font.pixelSize: 11
                                    font.family: "Menlo, Monaco, Courier New, monospace"
                                }
                            }

                            InfoRow {
                                label: "编解码"
                                value: (infoPanel.info.codec || "—").toUpperCase()
                            }
                            InfoRow {
                                label: "分辨率"
                                value: (infoPanel.info.width && infoPanel.info.height)
                                       ? (infoPanel.info.width + " × " + infoPanel.info.height)
                                       : "—"
                            }
                            InfoRow {
                                label: "FPS"
                                value: infoPanel.info.fps
                                       ? infoPanel.info.fps.toFixed(3)
                                       : "—"
                            }
                            InfoRow {
                                label: "帧类型"
                                value: infoPanel.info.frameType || "—"
                            }

                            // 底部提示
                            Text {
                                text: "右键关闭"
                                color: "#555560"
                                font.pixelSize: 10
                                Layout.topMargin: 2
                                Layout.rightMargin: 10
                            }
                        }
                    }

                    // 用 HoverHandler 检测整个 cell 的 hover 状态：
                    // 它不会被子项（ToolButton/Slider）的 hover 截获，
                    // 鼠标在 cell 任何位置（包含按钮上）都稳定为 true，彻底消除闪烁。
                    HoverHandler {
                        id: cellHover
                        // 默认作用范围 = parent（即 cell），无需额外配置
                    }

                    // ─── 单路悬浮控制条 ────────────────────────────────────
                    // 鼠标进入 cell 或工具条本身时浮现；离开淡出。
                    // 所有控制只作用于 cell.playerIdx 对应的单路。
                    Rectangle {
                        id: cellBar
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 6
                        height: 68
                        radius: 6
                        color: "#cc101014"
                        border.color: "#22ffffff"
                        border.width: 1
                        clip: true   // 防止窄 cell 下子项溢出越界绘制
                        z: 10

                        // hover 联动：使用 HoverHandler.hovered，
                        // 鼠标在 cell 任意位置（包含工具条/按钮上）都稳定为 true。
                        property bool hovered: cellHover.hovered
                        opacity: hovered ? 1.0 : 0.0
                        visible: opacity > 0.01
                        Behavior on opacity { NumberAnimation { duration: 150 } }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            anchors.topMargin: 4
                            anchors.bottomMargin: 4
                            spacing: 4

                            // 第一行：单路进度条 + 时间
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 24
                                spacing: 8

                                Slider {
                                    id: cellSlider
                                    Layout.fillWidth: true
                                    from: 0
                                    to: Math.max(0.001, cell._dur())
                                    // 不用 `value: pressed ? value : cell._pos()` 这种自引用三元绑定 —— Slider
                                    // 内部在用户拖动 / Tap 时会命令式写 value，会彻底打破属性绑定，导致播放
                                    // 时滑块不再跟随 position 推进。改用 Connections 主动写入：仅当用户没
                                    // 在拖动时才同步引擎位置，拖动期间完全不打扰用户。
                                    Connections {
                                        target: Engine
                                        function onPositionChanged() {
                                            if (!cellSlider.pressed) cellSlider.value = cell._pos()
                                        }
                                        function onDurationChanged() {
                                            if (!cellSlider.pressed) cellSlider.value = cell._pos()
                                        }
                                    }
                                    onMoved: Engine.seekAt(cell.playerIdx, value)

                                    // 自绘轨道：左侧（已播放）= 亮白；右侧（未播放）= 暗灰
                                    background: Rectangle {
                                        x: cellSlider.leftPadding
                                        y: cellSlider.topPadding + cellSlider.availableHeight / 2 - height / 2
                                        implicitWidth: 200
                                        implicitHeight: 4
                                        width: cellSlider.availableWidth
                                        height: implicitHeight
                                        radius: 2
                                        color: "#3a3a40"   // 未播放（右侧）暗灰
                                        Rectangle {
                                            width: cellSlider.visualPosition * parent.width
                                            height: parent.height
                                            color: "#f0f0f3"   // 已播放（左侧）亮白
                                            radius: 2
                                        }
                                    }

                                    handle: Rectangle {
                                        x: cellSlider.leftPadding + cellSlider.visualPosition * (cellSlider.availableWidth - width)
                                        y: cellSlider.topPadding + cellSlider.availableHeight / 2 - height / 2
                                        implicitWidth: 14
                                        implicitHeight: 14
                                        radius: 7
                                        color: cellSlider.pressed ? "#ffffff" : "#f0f0f3"
                                        border.color: "#80000000"
                                        border.width: 1
                                    }
                                }

                                Label {
                                    color: "#cfcfd2"
                                    font.pixelSize: 11
                                    text: fmtTime(cell._pos()) + " / " + fmtTime(cell._dur())
                                }
                            }

                            // 第二行：按钮组
                            // 注：按钮文本本身已足够直观（<< < ⏯ > >>），不再使用 ToolTip。
                            // ToolTip 弹出层会覆盖在按钮之上 → 触发 hover 抖动闪烁，体验极差。
                            // 使用 Item + RowLayout 包裹 + Layout.fillWidth + clip 防止在窄 cell 下溢出。
                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 28
                                clip: true
                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: 4

                                    FlatToolButton {
                                        text: "<<"
                                        implicitWidth: 32
                                        onClicked: Engine.seekAt(cell.playerIdx,
                                                    Math.max(0, cell._pos() - 5))
                                    }
                                    FlatToolButton {
                                        text: "<"
                                        implicitWidth: 28
                                        onClicked: Engine.stepFrameAt(cell.playerIdx, -1)
                                    }
                                    // 单路播放/暂停按钮：保持图标差异区分状态
                                    FlatToolButton {
                                        id: cellPlayBtn
                                        text: cell._playing() ? "⏸" : "▶"
                                        implicitWidth: 36
                                        onClicked: Engine.togglePauseAt(cell.playerIdx)
                                    }
                                    FlatToolButton {
                                        text: ">"
                                        implicitWidth: 28
                                        onClicked: Engine.stepFrameAt(cell.playerIdx, 1)
                                    }
                                    FlatToolButton {
                                        text: ">>"
                                        implicitWidth: 32
                                        onClicked: Engine.seekAt(cell.playerIdx,
                                                    Math.min(cell._dur(), cell._pos() + 5))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 占位提示
        Label {
            anchors.centerIn: parent
            visible: Engine.fileCount <= 0
            text: "点击左上角「打开」选择一个或多个视频"
            color: "#888"
            font.pixelSize: 18
        }
    }

    // 全局进度条已移除：多路场景下各路独立播放控制，全局进度条语义
    // 不明。进度跳转请使用各路 cell 悬浮工具条上的单路进度条。
}
