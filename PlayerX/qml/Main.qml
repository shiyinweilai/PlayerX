// Main.qml — PlayerX 第 2 阶段：多路视频 + 主时钟同步
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
import PlayerX 1.0

ApplicationWindow {
    id: root
    width: 1440
    height: 900
    visible: true
    title: "PlayerX"
    color: "#101012"

    // ─── 系统菜单栏（macOS 全局菜单 / Windows 窗口菜单） ──────────────────
    // 仅作为系统级入口，与现有 ToolBar 上的"打开 ▾ / ⚙ 设置 ▾"按钮共存。
    // macOS：自动适配为顶部全局菜单栏（系统原生样式，不接受自定义 background）。
    // Windows / Linux：在窗口标题栏下方显示一行经典菜单栏。
    // 设计原则：MenuBar 仅承担高频常用入口（打开/退出/设置/关于），
    //            完整的细粒度设置仍由现有 settingsMenu 自定义弹窗承担，
    //            "偏好设置…"会直接弹出现有的 settingsMenu，零功能影响。
    menuBar: MenuBar {
        Menu {
            title: qsTr("文件")
            MenuItem {
                id: miOpenFile
                text: qsTr("打开文件…")
                enabled: Engine.fileCount < 9
                onTriggered: addDialog.open()
            }
            // 合并入口：单入口同时支持"打开文件夹"（勾选1路）和"多组对比"（勾选≥2路）
            MenuItem {
                id: miOpenFolder
                text: qsTr("打开文件夹…")
                onTriggered: multiGroupDialog.show()
            }
            MenuSeparator {}
            MenuItem {
                id: miQuit
                text: qsTr("退出 PlayerX")
                onTriggered: Qt.quit()
            }
        }

        // 【设置】顶层菜单（macOS / Windows 系统菜单）
        //  · 直接镜像下方自绘 settingsMenu 的全部子项：布局 ▶ / 播放速度 ▶ /
        //    滑动对比 / 通道信息 / 视频信息；行为与状态完全等价（共享 Engine / root 属性）。
        //  · 系统菜单为原生 NSMenu / Win32 菜单渲染，不接受自定义深色 delegate —— 这是
        //    macOS 标准外观，与系统其他应用一致。
        //  · "偏好设置…"作为兜底入口，仍能弹出原深色自绘面板（与右键面板/快捷键一致）。
        Menu {
            id: settingsTopMenu
            title: qsTr("设置")

            // ── 布局 ▶ ──（4 种多路布局，互斥单选）
            // 不用 Repeater：macOS 全局菜单对动态实例化的 MenuItem 支持不稳定，
            // 显式声明每一项最稳，且和 multiLayoutNames/Values（[1,2,3,4]）一一对应。
            Menu {
                title: qsTr("布局")
                MenuItem {
                    text: qsTr("1×N 横排")
                    checkable: true
                    checked: Engine.layoutMode === 1
                    onTriggered: { Engine.layoutMode = 1; root.lastMultiLayout = 1 }
                }
                MenuItem {
                    text: qsTr("2×2")
                    checkable: true
                    checked: Engine.layoutMode === 2
                    onTriggered: { Engine.layoutMode = 2; root.lastMultiLayout = 2 }
                }
                MenuItem {
                    text: qsTr("2×3")
                    checkable: true
                    checked: Engine.layoutMode === 3
                    onTriggered: { Engine.layoutMode = 3; root.lastMultiLayout = 3 }
                }
                MenuItem {
                    text: qsTr("3×3")
                    checkable: true
                    checked: Engine.layoutMode === 4
                    onTriggered: { Engine.layoutMode = 4; root.lastMultiLayout = 4 }
                }
            }

            // ── 播放速度 ▶ ──（5 个常用档位 + 减速/加速/重置）
            // 同样不用 Repeater，原因同上。
            Menu {
                title: qsTr("播放速度")
                MenuItem {
                    text: qsTr("0.25x")
                    checkable: true
                    checked: Math.abs(Engine.speed - 0.25) < 1e-3
                    enabled: Engine.fileCount > 0
                    onTriggered: Engine.setSpeed(0.25)
                }
                MenuItem {
                    text: qsTr("0.5x")
                    checkable: true
                    checked: Math.abs(Engine.speed - 0.5) < 1e-3
                    enabled: Engine.fileCount > 0
                    onTriggered: Engine.setSpeed(0.5)
                }
                MenuItem {
                    text: qsTr("1.0x （正常）")
                    checkable: true
                    checked: Math.abs(Engine.speed - 1.0) < 1e-3
                    enabled: Engine.fileCount > 0
                    onTriggered: Engine.setSpeed(1.0)
                }
                MenuItem {
                    text: qsTr("1.5x")
                    checkable: true
                    checked: Math.abs(Engine.speed - 1.5) < 1e-3
                    enabled: Engine.fileCount > 0
                    onTriggered: Engine.setSpeed(1.5)
                }
                MenuItem {
                    text: qsTr("2.0x")
                    checkable: true
                    checked: Math.abs(Engine.speed - 2.0) < 1e-3
                    enabled: Engine.fileCount > 0
                    onTriggered: Engine.setSpeed(2.0)
                }
                MenuSeparator {}
                MenuItem {
                    text: qsTr("减速 ( - )")
                    enabled: Engine.fileCount > 0
                    onTriggered: Engine.adjustSpeed(-1)
                }
                MenuItem {
                    text: qsTr("加速 ( = )")
                    enabled: Engine.fileCount > 0
                    onTriggered: Engine.adjustSpeed(+1)
                }
                MenuItem {
                    text: qsTr("重置为 1.0x ( 0 )")
                    enabled: Engine.fileCount > 0
                    onTriggered: Engine.resetSpeed()
                }
            }

            MenuSeparator {}

            // ── 滑动对比（仅 2 路视频可用，B 快捷键联动）──
            MenuItem {
                text: qsTr("滑动对比 (B)")
                checkable: true
                checked: root.compareSliderActive
                enabled: root.compareSliderAvailable || root.compareSliderActive
                onTriggered: root._toggleCompareSlider()
            }

            // ── 通道信息显示（C 快捷键联动）──
            MenuItem {
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
            MenuItem {
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

            MenuSeparator {}

            // 兜底：弹出原深色自绘设置面板（与快捷键 ⌘, 一致）
            MenuItem {
                text: qsTr("偏好设置…")
                onTriggered: root._popupSettingsMenu()
            }
        }

        Menu {
            title: qsTr("帮助")
            MenuItem {
                text: qsTr("关于 PlayerX")
                onTriggered: aboutDialog.open()
            }
        }
    }

    // 统一的"弹出设置菜单"入口：把原来锚到 settingsBtn 的逻辑收敛到一处。
    // 因为 settingsBtn 已被移除，这里改为锚到窗口右上角（与原 ⚙ 按钮位置近似）。
    function _popupSettingsMenu() {
        var menuW = settingsMenu.width > 0 ? settingsMenu.width : 180
        // x = 距窗口右边 10px；y = 工具栏下方一点（菜单栏 + ToolBar 大约 64px，留余量到 56）
        settingsMenu.popup(root, root.width - menuW - 10, 56)
    }

    // ─── 顶层快捷键（与 MenuBar 解耦） ────────────────────────────────
    // QtQuick.Controls 的 MenuItem 没有 shortcut 属性，必须用独立 Shortcut。
    // 这些快捷键是窗口级（context: ApplicationShortcut），无论焦点在哪都可触发。
    Shortcut {
        sequences: [StandardKey.Open]                 // macOS: ⌘O / Win: Ctrl+O
        context: Qt.ApplicationShortcut
        enabled: Engine.fileCount < 9
        onActivated: addDialog.open()
    }
    Shortcut {
        sequence: "Ctrl+Shift+O"                      // 打开文件夹 / 多组对比（统一入口）
        context: Qt.ApplicationShortcut
        onActivated: multiGroupDialog.show()
    }
    Shortcut {
        sequence: "Ctrl+M"                            // 打开文件夹 / 多组对比（别名快捷键）
        context: Qt.ApplicationShortcut
        onActivated: multiGroupDialog.show()
    }
    Shortcut {
        sequences: [StandardKey.Preferences]          // macOS: ⌘,
        context: Qt.ApplicationShortcut
        onActivated: root._popupSettingsMenu()
    }
    Shortcut {
        sequences: [StandardKey.Quit]                 // macOS: ⌘Q / Win: Ctrl+Q
        context: Qt.ApplicationShortcut
        onActivated: Qt.quit()
    }

    // 简单的"关于"对话框（深色风格，与全局 UI 一致）
    Dialog {
        id: aboutDialog
        title: qsTr("关于 PlayerX")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok
        background: Rectangle {
            color: "#1e1e22"
            border.color: "#3a3a42"
            border.width: 1
            radius: 6
        }
        contentItem: ColumnLayout {
            spacing: 8
            Text {
                text: "PlayerX"
                color: "#e8e8ec"
                font.pixelSize: 18
                font.bold: true
            }
            Text {
                text: qsTr("基于 Qt 6 + QML + FFmpeg 的多路视频对比播放器")
                color: "#c8c8cc"
                font.pixelSize: 13
            }
            Text {
                text: qsTr("版本 1.0.0")
                color: "#888"
                font.pixelSize: 12
            }
        }
    }

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

    // 记住上一次使用的"多路布局"，让按下 0 键可以准确回到该布局。
    // 默认 SideBySide=1。仅在 ComboBox 交互、S 键循环、打开多个文件后同步。
    property int lastMultiLayout: 1

    // 全局"显示所有视频信息"开关（设置菜单 / 快捷键 V 控制）。
    // cell 自身仍保留右键的局部开关（localInfoVisible），二者取或。
    property bool globalInfoVisible: false

    // 全局"通道信息"开关（设置菜单 / 快捷键 C 控制）。
    // 控制每个窗口左上角的序号徽标 + 右上角的文件名。默认 true。
    property bool globalChannelVisible: true

    // 全屏抑制：按 F 进入全屏后，V/C 对应的叠加元素默认隐藏，但仍可
    // 再按 V/C 售起。本质是一个"临时抑制"标志，被Pick V/C 按下时会被清除。
    // 退出全屏时也会被清除。
    property bool fullscreenSuppressInfo:    false
    property bool fullscreenSuppressChannel: false

    // 实际是否显示：全局开关 且 不处于全屏抑制状态。
    readonly property bool effectiveInfoVisible:    globalInfoVisible    && !fullscreenSuppressInfo
    readonly property bool effectiveChannelVisible: globalChannelVisible && !fullscreenSuppressChannel

    // ─── 滑动对比模式（仅在恰好两路视频时可启用）────────────────────
    // 完全独立于 Grid 视图：开启时隐藏 Grid，显示 SliderCompareView；
    // 所有播放控制（空格/方向键/数字键/底部进度/cell 工具条）继续走
    // Engine.* 接口，不会因为切到滑动模式而改变行为。
    property bool compareSliderActive: false
    readonly property bool compareSliderAvailable: Engine.fileCount === 2

    // cell 右上角 🔁 "替换本路"按钮 ↔ replaceDialog 的中转变量：
    // FileDialog 是全局只一份，不能随 cell 上下文变化；点按钮时先写入该值，
    // 对话框 onAccepted 里读取它去调 Engine.replaceAt(idx, url)。初值 -1 表示未选中。
    property int pendingReplaceIdx: -1

    // ── 视频评分（纯 UI/会话级，不入引擎）────────────────────────────
    // 用 var 数组，按 playerIdx 索引存 1-5 分；0 / undefined 视为未评分。
    // 关闭某路（fileCount 减少）时简单地把数组裁到当前 fileCount，避免序号
    // 收拢后评分错位串到下一路。打开新文件时也清掉残留。
    // 注意：本数据完全游离于 Engine 之外，关闭再打开同名文件评分会丢失，
    //       这是当前最小实现的明确取舍——后续若要持久化再扩展即可。
    property var cellRatings: []
    function ratingAt(idx) {
        if (idx < 0 || idx >= cellRatings.length) return 0
        var v = cellRatings[idx]
        return (typeof v === "number" && v >= 1 && v <= 5) ? v : 0
    }
    function setRatingAt(idx, score) {
        if (idx < 0) return
        // 复制后整体赋值，确保 onCellRatingsChanged 能触发到 UI 绑定
        var arr = cellRatings.slice()
        while (arr.length <= idx) arr.push(0)
        // 再次点击当前分数 = 取消评分
        arr[idx] = (arr[idx] === score) ? 0 : score
        cellRatings = arr
    }
    Connections {
        target: Engine
        function onFileCountChanged() {
            // 简单裁剪：fileCount 缩小后，保留前 N 项；扩大无需处理
            if (root.cellRatings.length > Engine.fileCount) {
                root.cellRatings = root.cellRatings.slice(0, Engine.fileCount)
            }
        }
    }

    // 切换函数：仅在 fileCount === 2 时允许进入；离开 2 路场景时强制关闭
    function _toggleCompareSlider() {
        if (compareSliderActive) {
            compareSliderActive = false
        } else if (compareSliderAvailable) {
            compareSliderActive = true
        }
    }
    // fileCount 变化时若不再满足 2 路条件，自动退出滑动模式
    Connections {
        target: Engine
        function onFileCountChanged() {
            if (root.compareSliderActive && Engine.fileCount !== 2)
                root.compareSliderActive = false
        }
    }

    // ─── 文件 / 文件夹 选择 ──────────────────────────────────────────
    // 下拉菜单合并后只保留两个入口：「添加文件」/「添加文件夹」。
    //   - fileCount == 0 时，主按钮文案为 "打开"，此时"添加"与「打开」语义一致；
    //   - fileCount > 0 时，主按钮文案为 "新打开"，点进去还是「添加」。
    //   - 要重新载入一组 → 在各 cell 右上角 ✕ 关闭后再添加。
    // 文件夹路径在 QML 侧用 Fs.scanVideoFolder 展开为文件列表后再调。
    FileDialog {
        id: addDialog
        title: "添加视频文件（可多选）"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv)",
            "所有文件 (*)"
        ]
        onAccepted: {
            // fileCount==0 采用批量 openFiles、效果 == 打开；否则逐个 addFile
            if (Engine.fileCount === 0) {
                var arr = selectedFiles
                if (arr.length > 9) arr = arr.slice(0, 9)
                Engine.openFiles(arr)
            } else {
                for (var i = 0; i < selectedFiles.length; ++i) {
                    if (Engine.fileCount >= 9) break
                    Engine.addFile(selectedFiles[i])
                }
            }
        }
    }
    // 「替换本路」对话框：单选文件，原地调用 Engine.replaceAt(idx, url)。
    // 使用 root.pendingReplaceIdx 传递"哪一路要被替换"——FileDialog 不能绑定变量，
    // 在 cell 点 🔁 时先写入该 idx，然后 open() 。
    FileDialog {
        id: replaceDialog
        title: "替换本路视频文件"
        fileMode: FileDialog.OpenFile
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv)",
            "所有文件 (*)"
        ]
        onAccepted: {
            var idx = root.pendingReplaceIdx
            if (idx < 0 || idx >= Engine.fileCount) return
            Engine.replaceAt(idx, selectedFile)
        }
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

            // 打开 / 多组对比 入口已统一收纳到顶部系统菜单栏【文件】。
            // 这里只保留一个 fillWidth 的 spacer，把后面的播放控制组推到工具栏右端。

            // 把所有"播放控制"统一推到工具栏右侧：
            // 仅当已添加视频（Engine.fileCount > 0）时显示这一整组；
            // 没有视频的"空状态"下，工具栏整体保持空白（顶部菜单栏接管入口）。
            Item { Layout.fillWidth: true }

            // 第一根分隔线：把"打开"与"播放控制组"隔开（仅有视频时存在）
            Rectangle {
                width: 1
                Layout.fillHeight: true
                color: "#2a2a30"
                Layout.topMargin: 6
                Layout.bottomMargin: 6
                visible: Engine.fileCount > 0
            }
            // 快退 5 秒
            FlatButton {
                text: "<<"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                enabled: Engine.duration > 0
                // 相对快退：每路在自己当前位置 -5s，独立时钟的路不被对齐到主时钟
                onClicked: Engine.seekRelative(-5)
            }
            // 上一帧
            FlatButton {
                text: "<"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                enabled: Engine.duration > 0
                onClicked: Engine.stepFrame(-1)
            }
            // 播放/暂停按钮：固定宽度，避免图标切换时旁边按钮抖动
            FlatButton {
                id: playPauseBtn
                visible: Engine.fileCount > 0
                enabled: Engine.fileCount > 0
                Layout.preferredWidth: visible ? 56 : 0
                text: Engine.playing ? "⏸" : "▶"
                font.pixelSize: 16
                onClicked: Engine.togglePause()
            }
            // 下一帧
            FlatButton {
                text: ">"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                enabled: Engine.duration > 0
                onClicked: Engine.stepFrame(1)
            }
            // 快进 5 秒
            FlatButton {
                text: ">>"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                enabled: Engine.duration > 0
                // 相对快进：每路在自己当前位置 +5s，独立时钟的路不被对齐到主时钟
                onClicked: Engine.seekRelative(5)
            }
            // 全局重置：所有路 seek 回 0（与快捷键 R 等价）
            FlatButton {
                text: "⟲"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 16
                enabled: Engine.fileCount > 0
                onClicked: Engine.seek(0)
            }

            // ── 多组对比模式专用：上一组 / 下一组 + 组号指示 ──
            // 仅在 multiGroupDialog.active = true 时可见，默认 false → 单组模式下完全不占位。
            FlatButton {
                text: "⏮"
                visible: multiGroupDialog.active
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 14
                enabled: multiGroupDialog.active
                onClicked: multiGroupDialog.prevGroup()
            }
            FlatButton {
                text: "⏭"
                visible: multiGroupDialog.active
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 14
                enabled: multiGroupDialog.active
                onClicked: multiGroupDialog.nextGroup()
            }
            Label {
                visible: multiGroupDialog.active
                color: "#9a9aa8"
                font.pixelSize: 11
                text: {
                    if (!multiGroupDialog.active) return ""
                    var n = multiGroupDialog.groupCount()
                    var i = multiGroupDialog.groupIndex()
                    if (n <= 0 || i < 0) return "— / —"
                    return (i + 1) + " / " + n
                }
            }

            Rectangle {
                width: 1
                Layout.fillHeight: true
                color: "#2a2a30"
                Layout.topMargin: 6
                Layout.bottomMargin: 6
                visible: Engine.fileCount > 0
            }

            // ── 当前倍速指示（只在非 1.0x 时显示；点击复位；不占额外宽度）──
            // 设计目标：日常 1.0x 时完全隐藏不占位；进入慢/快速时给一个紧凑的高亮提示，
            // 单击即可回到 1.0x。详细控制仍走 ⚙ → 播放速度 子菜单。
            Item {
                id: speedBadge
                visible: Math.abs(Engine.speed - 1.0) > 1e-6
                Layout.preferredWidth: visible ? speedBadgeLabel.implicitWidth + 14 : 0
                Layout.fillHeight: true
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 22
                    radius: 11
                    color: "#1f3a33"           // 深绿底，和高亮色 #00c0a0 同色系
                    border.color: "#00c0a0"
                    border.width: 1
                    Label {
                        id: speedBadgeLabel
                        anchors.centerIn: parent
                        color: "#00c0a0"
                        font.pixelSize: 12
                        font.bold: true
                        text: {
                            var s = Engine.speed
                            if (s >= 1.0) return s.toFixed(s >= 10 ? 0 : 2).replace(/\.?0+$/,"") + "x"
                            return s.toFixed(2).replace(/0+$/,"").replace(/\.$/,"") + "x"
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onClicked: Engine.resetSpeed()
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 600
                        ToolTip.text: "当前倍速 " + speedBadgeLabel.text + "，点击重置为 1.0x ( 0 )"
                    }
                }
            }

            // 设置按钮已收纳到顶部系统菜单栏【设置】▸ 偏好设置…
            // 这里保留 settingsMenu 的定义，由顶部菜单触发其 popup（锚到窗口右上角）。

            // ── 设置一级菜单（深色，自绘）──
            //  ▸ 仍由顶部菜单栏【设置】▸ 偏好设置… 弹出（锚点改为窗口右上角）。
            //  ▸ 内部保留所有原有自绘 delegate / 子菜单（布局、播放速度、滑动对比、通道信息…），
            //    与之前的体验完全一致；macOS 上 popup() 走 Qt Quick 自绘菜单，深色样式生效。
            Menu {
                id: settingsMenu
                padding: 4
                width: 180
                // 之前依赖 ToolBar 上 settingsBtn._menuClosedAtMs 来吃掉「再点同一按钮收起」的二次点击；
                // 现在按钮已删除，触发源是顶部 MenuBar 的 MenuItem（Qt 内部已保证不会有这种二次抖动），
                // 因此 onClosed 不再需要做额外处理。

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
                        // 子菜单箭头：当此项是子菜单入口时显示 ▶
                        Text {
                            text: (settingsItem.text === "布局" || settingsItem.text.indexOf("播放速度") === 0) ? "▶" : ""
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

                // ── 二级菜单：播放速度（参考 video-compare：每档 2^(1/6)，约 1.122x）──
                // 列出常用档位 + 减速/加速/重置三项；快捷键 - = 0 仍然全局可用。
                Menu {
                    id: speedSubMenu
                    title: "播放速度"
                    padding: 4
                    width: 170

                    background: Rectangle {
                        color: "#1e1e22"
                        border.color: "#3a3a42"
                        border.width: 1
                        radius: 6
                    }

                    delegate: MenuItem {
                        id: speedItem
                        implicitHeight: 30
                        background: Rectangle {
                            radius: 4
                            color: speedItem.highlighted ? "#33333a" : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 0
                            Text {
                                leftPadding: 10
                                text: speedItem.checked ? "✓" : ""
                                color: "#6a9fd8"
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                Layout.minimumWidth: 22
                            }
                            Text {
                                text: speedItem.text
                                color: speedItem.enabled ? "#e8e8ec" : "#666"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                                Layout.fillWidth: true
                            }
                        }
                    }

                    // 常用档位（直接 setSpeed；checked 用近似比较，避免按 - = 落到非常用档时全部不亮）
                    Repeater {
                        model: [0.25, 0.5, 1.0, 1.5, 2.0]
                        MenuItem {
                            id: presetItem
                            required property real modelData
                            text: {
                                var v = modelData
                                if (Math.abs(v - 1.0) < 1e-6) return "1.0x （正常）"
                                return (v < 1.0 ? v.toFixed(2).replace(/0+$/,"").replace(/\.$/,"")
                                                : v.toFixed(v >= 10 ? 0 : 1).replace(/\.0$/,"")) + "x"
                            }
                            checkable: true
                            checked: Math.abs(Engine.speed - modelData) < 1e-3
                            enabled: Engine.fileCount > 0
                            onTriggered: Engine.setSpeed(modelData)
                            implicitHeight: 30
                            background: Rectangle {
                                radius: 4
                                color: presetItem.highlighted ? "#33333a" : "transparent"
                            }
                            contentItem: RowLayout {
                                spacing: 0
                                Text {
                                    leftPadding: 10
                                    text: presetItem.checked ? "✓" : ""
                                    color: "#6a9fd8"
                                    font.pixelSize: 12
                                    verticalAlignment: Text.AlignVCenter
                                    Layout.minimumWidth: 22
                                }
                                Text {
                                    text: presetItem.text
                                    color: presetItem.enabled ? "#e8e8ec" : "#666"
                                    font.pixelSize: 13
                                    verticalAlignment: Text.AlignVCenter
                                    Layout.fillWidth: true
                                }
                            }
                        }
                    }

                    MenuSeparator {
                        contentItem: Rectangle { implicitHeight: 1; color: "#3a3a42" }
                    }

                    // 步进式（与快捷键 - / = / 0 对齐）
                    // 注意：必须给 contentItem/background 用与上面档位项一致的深色 delegate，
                    // 否则会落到系统默认（白底 + 浅灰禁用色），在深色面板里几乎看不见。
                    MenuItem {
                        id: speedDecItem
                        text: "减速 ( - )"
                        enabled: Engine.fileCount > 0
                        onTriggered: Engine.adjustSpeed(-1)
                        implicitHeight: 30
                        background: Rectangle {
                            radius: 4
                            color: speedDecItem.highlighted ? "#33333a" : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 0
                            Text { leftPadding: 10; text: ""; Layout.minimumWidth: 22 }
                            Text {
                                text: speedDecItem.text
                                color: speedDecItem.enabled ? "#e8e8ec" : "#666"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                                Layout.fillWidth: true
                            }
                        }
                    }
                    MenuItem {
                        id: speedIncItem
                        text: "加速 ( = )"
                        enabled: Engine.fileCount > 0
                        onTriggered: Engine.adjustSpeed(+1)
                        implicitHeight: 30
                        background: Rectangle {
                            radius: 4
                            color: speedIncItem.highlighted ? "#33333a" : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 0
                            Text { leftPadding: 10; text: ""; Layout.minimumWidth: 22 }
                            Text {
                                text: speedIncItem.text
                                color: speedIncItem.enabled ? "#e8e8ec" : "#666"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                                Layout.fillWidth: true
                            }
                        }
                    }
                    MenuItem {
                        id: speedResetItem
                        text: "重置为 1.0x ( 0 )"
                        enabled: Engine.fileCount > 0
                        onTriggered: Engine.resetSpeed()
                        implicitHeight: 30
                        background: Rectangle {
                            radius: 4
                            color: speedResetItem.highlighted ? "#33333a" : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 0
                            Text { leftPadding: 10; text: ""; Layout.minimumWidth: 22 }
                            Text {
                                text: speedResetItem.text
                                color: speedResetItem.enabled ? "#e8e8ec" : "#666"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                                Layout.fillWidth: true
                            }
                        }
                    }
                }

                // ── 滑动对比（仅 2 路视频可用，B 快捷键联动）──
                MenuItem {
                    id: compareItem
                    text: "滑动对比 (B)"
                    checkable: true
                    checked: root.compareSliderActive
                    enabled: root.compareSliderAvailable || root.compareSliderActive
                    onTriggered: root._toggleCompareSlider()
                    implicitHeight: 30
                    background: Rectangle {
                        radius: 4
                        color: compareItem.highlighted ? "#33333a" : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 0
                        Text {
                            leftPadding: 10
                            text: compareItem.checked ? "✓" : ""
                            color: "#6a9fd8"
                            font.pixelSize: 12
                            verticalAlignment: Text.AlignVCenter
                            Layout.minimumWidth: 22
                        }
                        Text {
                            text: compareItem.text
                            color: compareItem.enabled ? "#e8e8ec" : "#666"
                            font.pixelSize: 13
                            verticalAlignment: Text.AlignVCenter
                            Layout.fillWidth: true
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

        }
    }

    // ─── 全局快捷键（ApplicationShortcut，与焦点无关）────────────────────
    // 用 Shortcut 而非 Keys.onPressed，避免焦点跑到 ToolBar/Slider/ComboBox
    // 后空格、左右键等"全局控制"快捷键失效。
    Shortcut {
        sequence: "Space"; context: Qt.ApplicationShortcut
        onActivated: Engine.togglePause()
    }
    // V：切换全局显示视频信息。全屏抑制状下会先清抑制再强制显示。
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
    // C：切换全局通道信息（序号+文件名）。全屏抑制状下会先清抑制再强制显示。
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
            // 进入全屏：默认抑制 V/C 的叠加显示，但保留开关本身的值，
            // 用户可以再按 V/C 售起。退出全屏：清除抑制，恢复平常表现。
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
    // B：切换"滑动对比"模式（仅 2 路视频可用）
    Shortcut {
        sequence: "B"; context: Qt.ApplicationShortcut
        onActivated: root._toggleCompareSlider()
    }
    // 倍速快捷键（参考 video-compare）：- 慢、= 快、0 复位
    // 同时支持小键盘 + / - 与主键盘 + 的常见组合
    Shortcut { sequence: "-";          context: Qt.ApplicationShortcut; onActivated: Engine.adjustSpeed(-1) }
    Shortcut { sequence: "=";          context: Qt.ApplicationShortcut; onActivated: Engine.adjustSpeed(+1) }
    Shortcut { sequence: "+";          context: Qt.ApplicationShortcut; onActivated: Engine.adjustSpeed(+1) }
    Shortcut { sequence: "0";          context: Qt.ApplicationShortcut; onActivated: Engine.resetSpeed() }
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

    // ── 多组对比专用快捷键：上组 / 下组。仅在 multiGroupDialog.active 时生效。
    // 选用 Ctrl+↑/↓，避免与现有 ←→（快进快退） / "."","（帧步进）冲突。
    Shortcut {
        sequence: "Ctrl+Up";   context: Qt.ApplicationShortcut
        enabled: multiGroupDialog.active
        onActivated: multiGroupDialog.prevGroup()
    }
    Shortcut {
        sequence: "Ctrl+Down"; context: Qt.ApplicationShortcut
        enabled: multiGroupDialog.active
        onActivated: multiGroupDialog.nextGroup()
    }

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
            // 滑动对比模式启用时隐藏 Grid（Grid 内的所有子项与控制逻辑保持不变）
            visible: !root.compareSliderActive
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
                        // 关闭 QtQuick 场景图对本 Item 的纹理插值。本 Item 内部
                        // 已经用 sws Lanczos 把帧缩到屏幕物理像素并 1:1 上屏，
                        // QtQuick 再做双线性会引入二次重采样 → 网格伪影/字模糊。
                        smooth: false
                        antialiasing: false
                    }

                    // 序号徽标（受全局"通道信息"开关控制，默认显示）
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

                    // 顶部右侧"通道信息"胶囊条：帧号 · 时间戳 · 文件名。
                    // 受全局"通道信息"开关控制，默认显示；帧号/时间戳随 Engine.position 自动刷新。
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

                            // 帧号（固定最小宽度，避免 1/2/3/4 位数字之间抖动）
                            Text {
                                color: "#e8e8ec"
                                font.pixelSize: 11
                                font.family: "Menlo, Monaco, Courier New, monospace"
                                horizontalAlignment: Text.AlignRight
                                Layout.minimumWidth: 56
                                Layout.preferredWidth: 56
                                text: channelBar.info.frameNum !== undefined
                                      ? "#" + channelBar.info.frameNum
                                      : "#—"
                            }
                            Rectangle {
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 12
                                color: "#55ffffff"
                            }
                            // 时间戳（固定最小宽度，避免抖动）
                            Text {
                                color: "#e8e8ec"
                                font.pixelSize: 11
                                font.family: "Menlo, Monaco, Courier New, monospace"
                                horizontalAlignment: Text.AlignRight
                                Layout.minimumWidth: 70
                                Layout.preferredWidth: 70
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
                            // 【cell hover 工具按钮】两个同风格的圆点：⋯ 更多操作、✕ 关闭本路。
                            // 仅 hover 本 cell 时可见，不污染观影画面。
                            //  - ⋯：弹出 cellMenu，内含「评分（1-5 星）」与「替换本路视频…」
                            //         （新增一路已在顶部工具栏／下拉菜单提供，cell 内不再重复）
                            //  - ✕：调 Engine.closeAt(idx)，fileCount 变化会触发 visibleCount/Repeater
                            //         重新求值，UI 自动收拢。
                            Rectangle {
                                id: moreBtn
                                Layout.preferredWidth: 18
                                Layout.preferredHeight: 18
                                Layout.leftMargin: 2
                                radius: 9
                                visible: cellHover.hovered || cellMenu.opened
                                color: replaceArea.containsMouse || cellMenu.opened ? "#3a78c8"
                                      : replaceArea.pressed     ? "#2a5994"
                                                                : "#55ffffff"
                                Behavior on color { ColorAnimation { duration: 90 } }
                                Text {
                                    anchors.centerIn: parent
                                    // 用水平三点 ⋯（macOS/iOS/Material 通用的"更多/打开选项"语义），
                                    // 避开 ↻ 与"重置/重新加载"视觉撞车。需要靠下半像素才视觉居中。
                                    anchors.verticalCenterOffset: -1
                                    text: "⋯"
                                    color: "white"
                                    font.pixelSize: 14
                                    font.bold: true
                                }
                                MouseArea {
                                    id: replaceArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        // 打开本 cell 的菜单（评分 + 替换）
                                        if (cellMenu.opened) cellMenu.close()
                                        else cellMenu.open()
                                    }
                                }
                                ToolTip.visible: replaceArea.containsMouse && !cellMenu.opened
                                ToolTip.delay: 600
                                ToolTip.timeout: 3000
                                ToolTip.text: "更多：评分 / 替换本路视频"
                            }
                            // 关闭本路的 ✕ 按钮：常驻显示（不随 hover 消失），仅当用户按 C
                            // 关闭通道信息条 / 全屏抑制角标时才隐藏，与同一行的 #idx·时间·文件名
                            // 信息条共用一套可见性，避免 cellMenu 弹出时鼠标移出 cell 导致 ✕
                            // 闪掉、菜单边缘抖动。
                            // 调用 Engine.closeAt(idx) 后，fileCount 变化会触发 visibleCount/Repeater
                            // 重新求值，UI 自动收拢 —— 不需要额外手动刷新。
                            Rectangle {
                                Layout.preferredWidth: 18
                                Layout.preferredHeight: 18
                                Layout.leftMargin: 2
                                radius: 9
                                visible: root.effectiveChannelVisible
                                color: closeArea.containsMouse ? "#e0454d"
                                      : closeArea.pressed     ? "#a83239"
                                                              : "#55ffffff"
                                Behavior on color { ColorAnimation { duration: 90 } }
                                Text {
                                    anchors.centerIn: parent
                                    text: "✕"
                                    color: "white"
                                    font.pixelSize: 11
                                    font.bold: true
                                }
                                MouseArea {
                                    id: closeArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Engine.closeAt(cell.playerIdx)
                                }
                                ToolTip.visible: closeArea.containsMouse
                                ToolTip.delay: 600
                                ToolTip.timeout: 3000
                                ToolTip.text: "关闭本路视频"
                            }
                        }
                    }

                    // ── 更多菜单（⋯ 按钮触发）──────────────────────────────
                    // 用 Popup 而非 Menu：可自定义评分星条、风格与顶部信息条一致。
                    // 锚定到 moreBtn 下方右对齐；菜单打开时 moreBtn 保持高亮显示。
                    // 关闭/替换 / 评分均不动 Engine 文件序号，因此对其他逻辑零侵入。
                    Popup {
                        id: cellMenu
                        // 父对象用 moreBtn，可获得相对该按钮的坐标系
                        parent: moreBtn
                        // 弹在按钮正下方，向左对齐到按钮右边缘（避免溢出 cell 右侧）
                        x: moreBtn.width - width
                        y: moreBtn.height + 4
                        padding: 8
                        modal: false
                        focus: true
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                        background: Rectangle {
                            color: "#1f2227"
                            radius: 8
                            border.color: "#3a3f47"
                            border.width: 1
                        }

                        // 评分状态绑定：从 root.cellRatings 读取，写入用 root.setRatingAt
                        readonly property int currentRating: root.ratingAt(cell.playerIdx)
                        // 鼠标 hover 预览分值（0 表示未 hover）
                        property int hoverRating: 0

                        ColumnLayout {
                            spacing: 8

                            // 顶部：当前文件名（只读，便于确认操作的是哪一路）
                            RowLayout {
                                spacing: 6
                                Layout.fillWidth: true
                                Text {
                                    text: Engine.fileNameAt(cell.playerIdx)
                                    color: "#dcdcde"
                                    font.pixelSize: 12
                                    elide: Text.ElideMiddle
                                    Layout.maximumWidth: 220
                                }
                            }

                            // 分隔线
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                color: "#33ffffff"
                            }

                            // 评分行：标题 + 5 颗星 + 当前分值文本
                            RowLayout {
                                spacing: 6
                                Text {
                                    text: "评分"
                                    color: "#dcdcde"
                                    font.pixelSize: 12
                                }
                                Row {
                                    spacing: 2
                                    Repeater {
                                        model: 5
                                        delegate: Item {
                                            width: 20
                                            height: 20
                                            property int starIndex: index + 1
                                            property bool active: cellMenu.hoverRating > 0
                                                ? starIndex <= cellMenu.hoverRating
                                                : starIndex <= cellMenu.currentRating
                                            Text {
                                                anchors.centerIn: parent
                                                text: parent.active ? "★" : "☆"
                                                color: parent.active ? "#f5c518" : "#9aa0a6"
                                                font.pixelSize: 16
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onEntered: cellMenu.hoverRating = parent.starIndex
                                                onExited: cellMenu.hoverRating = 0
                                                onClicked: {
                                                    root.setRatingAt(cell.playerIdx, parent.starIndex)
                                                    cellMenu.hoverRating = 0
                                                }
                                            }
                                        }
                                    }
                                }
                                Text {
                                    text: cellMenu.currentRating > 0
                                          ? (cellMenu.currentRating + " / 5")
                                          : "未评分"
                                    color: "#9aa0a6"
                                    font.pixelSize: 11
                                    Layout.leftMargin: 4
                                }
                            }

                            // 分隔线
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                color: "#33ffffff"
                            }

                            // 替换本路视频按钮（原 ⋯ 直跳替换 → 现作为菜单项）
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 28
                                radius: 4
                                color: replaceItemArea.containsMouse ? "#2a5994" : "transparent"
                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "🔁  替换本路视频…"
                                    color: "#dcdcde"
                                    font.pixelSize: 12
                                }
                                MouseArea {
                                    id: replaceItemArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        cellMenu.close()
                                        root.pendingReplaceIdx = cell.playerIdx
                                        replaceDialog.open()
                                    }
                                }
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
                    // 全局部分走 effectiveInfoVisible，全屏抑制后不显示。局部右键仍以实体为准。
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
                            InfoRow {
                                label: "像素格式"
                                value: infoPanel.info.pixFmt || "—"
                            }
                            InfoRow {
                                label: "色彩空间"
                                value: infoPanel.info.colorSpace || "—"
                            }
                            InfoRow {
                                label: "色彩范围"
                                value: infoPanel.info.colorRange || "—"
                            }
                            InfoRow {
                                label: "解码器"
                                value: infoPanel.info.decoder || "—"
                            }
                            InfoRow {
                                label: "硬件加速"
                                value: infoPanel.info.hwAccel === undefined
                                       ? "—"
                                       : (infoPanel.info.hwAccel ? "是 (VideoToolbox)" : "否")
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

                                    // 与"快进/快退/帧步进"分组，避免误点。窄 cell 下也能保留这条线。
                                    Rectangle {
                                        Layout.preferredWidth: 1
                                        Layout.preferredHeight: 16
                                        Layout.leftMargin: 2
                                        Layout.rightMargin: 2
                                        color: "#2a2a30"
                                    }

                                    // 单路重置：把本路 seek 回 0。图标与底部全局重置 ⟲ 完全一致，
                                    // 让"当前路重置 / 全部重置"在视觉语义上对齐。
                                    // 仅复用既有 Engine.seekAt 接口，零新增后端代码。
                                    FlatToolButton {
                                        id: cellResetBtn
                                        text: "⟲"
                                        font.pixelSize: 14
                                        implicitWidth: 28
                                        enabled: cell._dur() > 0
                                        onClicked: Engine.seekAt(cell.playerIdx, 0)

                                        ToolTip.visible: hovered
                                        ToolTip.delay: 600
                                        ToolTip.timeout: 3000
                                        ToolTip.text: "重置本路到开头（不影响其他路）"
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

        // ─── 滑动对比视图（独立组件，仅在 compareSliderActive 时显示）──
        // 完全独立于上方 Grid 视图，不与 cell / VideoFrameProvider 共享任何
        // 状态。所有播放控制继续走 Engine.* 接口（顶部 ToolBar / Shortcut /
        // 底部进度条），与 Grid 模式行为一致。
        SliderCompareView {
            anchors.fill: parent
            visible: root.compareSliderActive && Engine.fileCount === 2
            engine: Engine
            leftIndex: 0
            rightIndex: 1
            channelVisible: root.effectiveChannelVisible
        }
    }

    // ─── 多组对比模式配置面板（独立窗口，默认隐藏）──────────
    // 只有用户在 "打开 ▾" 菜单点 "多组对比模式…" 才会 show()。
    // 未 show 时完全不会调用 Engine 任何接口 → 与旧逻辑零交互。
    MultiGroupDialog {
        id: multiGroupDialog
        visible: false
        // 作为给 root 的子窗口，关闭主窗时一起退出
        transientParent: root
    }

    // 全局进度条已移除：多路场景下各路独立播放控制，全局进度条语义
    // 不明。进度跳转请使用各路 cell 悬浮工具条上的单路进度条。
}
