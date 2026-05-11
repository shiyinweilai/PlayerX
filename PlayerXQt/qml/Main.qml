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
    header: ToolBar {
        RowLayout {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 8

            Button {
                text: Engine.fileCount > 0 ? "新打开" : "打开"
                focusPolicy: Qt.NoFocus  // 避免点击后拿走焦点并吞掉 Space 快捷键
                onClicked: openDialog.open()
            }
            Button {
                text: "添加"
                focusPolicy: Qt.NoFocus
                enabled: Engine.fileCount > 0 && Engine.fileCount < 9
                onClicked: addDialog.open()
            }
            ToolSeparator {}
            Button {
                text: "<<"
                focusPolicy: Qt.NoFocus
                enabled: Engine.duration > 0
                ToolTip.text: "后退 5 秒"
                ToolTip.visible: hovered
                onClicked: Engine.seek(Math.max(0, Engine.position - 5))
            }
            Button {
                text: "<"
                focusPolicy: Qt.NoFocus
                enabled: Engine.duration > 0
                ToolTip.text: "上一帧"
                ToolTip.visible: hovered
                onClicked: Engine.stepFrame(-1)
            }
            // 播放/暂停按钮：保持默认黑白风格，仅靠 ⏸/▶ 图标本身的差异区分状态
            Button {
                id: playPauseBtn
                focusPolicy: Qt.NoFocus
                enabled: Engine.fileCount > 0
                // 固定宽度，避免图标切换时旁边按钮位置抖动
                Layout.preferredWidth: 48
                text: Engine.playing ? "⏸" : "▶"
                font.pixelSize: 16
                ToolTip.text: Engine.playing ? "暂停 (Space)" : "播放 (Space)"
                ToolTip.visible: hovered
                ToolTip.delay: 400
                onClicked: Engine.togglePause()
            }
            Button {
                text: ">"
                focusPolicy: Qt.NoFocus
                enabled: Engine.duration > 0
                ToolTip.text: "下一帧"
                ToolTip.visible: hovered
                onClicked: Engine.stepFrame(1)
            }
            Button {
                text: ">>"
                focusPolicy: Qt.NoFocus
                enabled: Engine.duration > 0
                ToolTip.text: "前进 5 秒"
                ToolTip.visible: hovered
                onClicked: Engine.seek(Math.min(Engine.duration, Engine.position + 5))
            }

            ToolSeparator {}

            Label { text: "布局:"; color: "#bbb" }
            ComboBox {
                id: layoutCombo
                model: root.multiLayoutNames
                // 根据当前 Engine.layoutMode 反查在 multiLayoutValues 中的位置；
                // Single 模式不在下拉列表，此时展示“进入 Single 之前”的布局。
                currentIndex: {
                    var idx = root.multiLayoutValues.indexOf(Engine.layoutMode)
                    return idx >= 0 ? idx : 0
                }
                onActivated: {
                    var v = root.multiLayoutValues[currentIndex]
                    Engine.layoutMode = v
                    root.lastMultiLayout = v
                }
                Layout.preferredWidth: 130
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
        onActivated: root.visibility = (root.visibility === Window.FullScreen)
                     ? Window.AutomaticVisibility : Window.FullScreen
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
    Item {
        id: videoArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
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
                    border.color: (videoArea.slotPlayerIndex(index) === Engine.activeIndex) ? "#3a8bff" : "#222"
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

                    // 序号徽标
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.margins: 6
                        width: 22; height: 22; radius: 4
                        color: "#cc000000"
                        z: 5
                        Label {
                            anchors.centerIn: parent
                            text: cell.playerIdx + 1
                            color: "white"
                            font.bold: true
                        }
                    }

                    // 文件名（顶部右侧，避免和底部工具条重叠）
                    Label {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 6
                        text: Engine.fileNameAt(cell.playerIdx)
                        color: "#dcdcde"
                        background: Rectangle { color: "#aa000000"; radius: 3 }
                        leftPadding: 6; rightPadding: 6; topPadding: 2; bottomPadding: 2
                        z: 5
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
                        acceptedButtons: Qt.LeftButton
                        onClicked: {
                            Engine.activeIndex = cell.playerIdx
                            videoArea.forceActiveFocus()
                        }
                        onDoubleClicked: Engine.togglePauseAt(cell.playerIdx)
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
                        height: 56
                        radius: 6
                        color: "#cc101014"
                        border.color: "#22ffffff"
                        border.width: 1
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
                            spacing: 2

                            // 第一行：单路进度条 + 时间
                            RowLayout {
                                Layout.fillWidth: true
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
                            RowLayout {
                                Layout.alignment: Qt.AlignHCenter
                                spacing: 4

                                ToolButton {
                                    text: "<<"
                                    focusPolicy: Qt.NoFocus
                                    onClicked: Engine.seekAt(cell.playerIdx,
                                                Math.max(0, cell._pos() - 5))
                                }
                                ToolButton {
                                    text: "<"
                                    focusPolicy: Qt.NoFocus
                                    onClicked: Engine.stepFrameAt(cell.playerIdx, -1)
                                }
                                // 单路播放/暂停按钮：保持默认黑白风格，仅靠 ⏸/▶ 图标差异区分状态
                                ToolButton {
                                    id: cellPlayBtn
                                    focusPolicy: Qt.NoFocus
                                    text: cell._playing() ? "⏸" : "▶"
                                    onClicked: Engine.togglePauseAt(cell.playerIdx)
                                }
                                ToolButton {
                                    text: ">"
                                    focusPolicy: Qt.NoFocus
                                    onClicked: Engine.stepFrameAt(cell.playerIdx, 1)
                                }
                                ToolButton {
                                    text: ">>"
                                    focusPolicy: Qt.NoFocus
                                    onClicked: Engine.seekAt(cell.playerIdx,
                                                Math.min(cell._dur(), cell._pos() + 5))
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
