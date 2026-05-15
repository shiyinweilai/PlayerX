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

    // 教程文档链接（占位 URL，后续替换为正式地址即可，无需改任何调用方）
    // 用法：菜单「帮助 → 教程…」点击时，会通过 Qt.openUrlExternally(tutorialUrl) 打开默认浏览器
    property url tutorialUrl: "https://iwiki.woa.com/p/4020492089"

    // ─── 系统菜单栏（macOS 全局菜单 / Windows 窗口菜单） ──────────────────
    // 仅作为系统级入口，与现有 ToolBar 上的"打开 ▾ / ⚙ 设置 ▾"按钮共存。
    // macOS：自动适配为顶部全局菜单栏（系统原生样式，不接受自定义 background）。
    // Windows / Linux：在窗口标题栏下方显示一行经典菜单栏。
    // 设计原则：MenuBar 仅承担高频常用入口（打开/退出/设置/关于），
    //            完整的细粒度设置仍由现有 settingsMenu 自定义弹窗承担，
    //            "偏好设置…"会直接弹出现有的 settingsMenu，零功能影响。
    menuBar: MenuBar {
        id: appMenuBar

        // ─── 深色主题 + 紧凑高度 ───────────────────────────────────────
        // 仅 Windows/Linux 走这套自定义外观；macOS 使用系统全局菜单栏，
        // 自动忽略 background/delegate，不受影响。
        // 配色与应用整体一致：底 #1a1a1d、分隔 #2c2c32、hover #2a2a32、
        // 按下/打开态 #3a3a45，正文 #e8e8ec、未 hover 次级 #cfcfd2。
        background: Rectangle {
            implicitHeight: 26
            color: "#1a1a1d"
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
            leftPadding: 10
            rightPadding: 10
            topPadding: 0
            bottomPadding: 0

            contentItem: Text {
                text: mbItem.text
                color: mbItem.highlighted || mbItem.hovered ? "#ffffff" : "#cfcfd2"
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                // 去掉 Qt 默认的 "&" 助记键下划线样式带来的视觉噪点
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
            }

            background: Rectangle {
                implicitHeight: 26
                // highlighted = 当前 Menu 已展开；hovered = 鼠标悬停
                color: mbItem.highlighted ? "#3a3a45"
                       : mbItem.hovered   ? "#2a2a32"
                                          : "transparent"
                radius: 3
            }
        }

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
                onTriggered: multiGroupDialog.showAndRefresh()
            }
            MenuSeparator {}
            // 一次性关闭所有视频（与单路 ✕ 一致；带二次确认）
            MenuItem {
                id: miCloseAll
                text: qsTr("关闭所有视频")
                enabled: Engine.fileCount > 0
                onTriggered: confirmCloseAllDialog.open()
            }
            MenuSeparator {}
            // 评分数据：查看/导出/清空本地 CSV（与播放完全解耦）
            MenuItem {
                id: miRatings
                text: qsTr("评分数据…")
                onTriggered: ratingsDialog.open()
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
            id: helpMenu
            title: qsTr("帮助")
            // 动态首项：仅在检测到新版本时显示，作为"系统全局菜单"下的兜底入口
            // —— macOS 顶端原生菜单不允许塞自定义控件，所以这里给一份纯 MenuItem。
            MenuItem {
                id: miUpdateAvailable
                visible: Updater.updateAvailable
                height: visible ? implicitHeight : 0
                text: qsTr("⬆ 安装新版本 %1…").arg(Updater.latestVersion)
                onTriggered: updateDialog.open()
            }
            MenuSeparator { visible: miUpdateAvailable.visible }
            MenuItem {
                text: qsTr("检查更新…")
                onTriggered: { updateDialog.userInitiated = true; Updater.checkForUpdates(false) }
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("快捷键…")
                onTriggered: shortcutsDialog.open()
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("教程…")
                // 占位 URL 见 root.tutorialUrl；点击后用系统默认浏览器打开
                onTriggered: {
                    if (!Qt.openUrlExternally(root.tutorialUrl)) {
                        console.warn("[Help] 无法打开教程链接：", root.tutorialUrl)
                    }
                }
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("关于 PlayerX")
                onTriggered: aboutDialog.open()
            }
        }
    }

    // ─── 右上角"更新可用"胶囊按钮（VS Code 风格） ───────────────────────
    //  · 仅在 Updater.updateAvailable=true 时显示
    //  · 点击 → 弹 updateDialog（深色面板 + 进度条）
    //  · 视觉上落在菜单栏下方右侧 8px 处，保证不遮挡内容；macOS 全局菜单
    //    在屏幕顶端、本按钮位于窗口顶端，互不冲突且双入口冗余更可靠。
    Rectangle {
        id: updateBadge
        z: 100
        visible: Updater.updateAvailable
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: 10
        anchors.topMargin: Qt.platform.os === "osx" ? 6 : 32   // mac 全局菜单栏不在窗口内
        implicitHeight: 22
        implicitWidth: badgeRow.implicitWidth + 18
        radius: 11
        // VS Code 蓝色调 #0e639c，与深色主题统一
        color: badgeMA.pressed ? "#0a4f7d"
                               : badgeMA.containsMouse ? "#1177bb" : "#0e639c"
        border.color: "#1f8ad9"
        border.width: 1
        Behavior on color { ColorAnimation { duration: 120 } }

        Row {
            id: badgeRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "⬆"
                color: "#ffffff"
                font.pixelSize: 12
                font.bold: true
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("更新 %1").arg(Updater.latestVersion || "")
                color: "#ffffff"
                font.pixelSize: 11
            }
        }

        MouseArea {
            id: badgeMA
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { updateDialog.userInitiated = false; updateDialog.open() }
        }

        ToolTip.visible: badgeMA.containsMouse
        ToolTip.delay: 400
        ToolTip.text: qsTr("有新版本 %1 可用，点击查看").arg(Updater.latestVersion || "")
    }

    // ─── 启动 5 秒后静默自检；同时连接 Updater 信号驱动 UI ───────────────
    Timer {
        id: updateAutoCheckTimer
        interval: 5000
        running: true
        repeat: false
        onTriggered: Updater.checkForUpdates(true)
    }

    Connections {
        target: Updater
        // 状态切换到 available 时，如果是手动触发的检查则自动弹窗；
        // 如果是静默自检，则只显示右上角胶囊按钮，不打扰用户。
        function onStateChanged() {
            if (Updater.state === "available" && updateDialog.userInitiated) {
                updateDialog.open()
            }
            if (Updater.state === "error" && updateDialog.userInitiated) {
                updateDialog.open()
            }
        }
        // 已是最新版 / 网络错误：仅在用户手动点了"检查更新"时弹 toast
        function onCheckFailed(reason) {
            if (updateDialog.userInitiated) {
                updateToast.text = reason
                updateToast.open()
            }
        }
    }

    // 平台修饰键显示文本：mac 显示 ⌘，其它显示 Ctrl+。
    // 用于欢迎页速览 / 快捷键对话框中的显示拼接，不影响 Shortcut 实际绑定
    //（QtQuick 的 Shortcut 会自动把 Ctrl 在 mac 映射为 ⌘）。
    readonly property string _modKey: Qt.platform.os === "osx" ? "⌘" : "Ctrl+"

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
        onActivated: multiGroupDialog.showAndRefresh()
    }
    Shortcut {
        sequence: "Ctrl+M"                            // 打开文件夹 / 多组对比（别名快捷键）
        context: Qt.ApplicationShortcut
        onActivated: multiGroupDialog.showAndRefresh()
    }
    // 关闭所有视频：⌘W / Ctrl+W（行业惯例的"关闭文档"键，对我们等价于清空所有路）
    Shortcut {
        sequences: [StandardKey.Close]
        context: Qt.ApplicationShortcut
        enabled: Engine.fileCount > 0
        onActivated: confirmCloseAllDialog.open()
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

    // F1 / ? 全局打开「快捷键」对话框（行业惯例：F1 = Help，? = 速查）
    Shortcut {
        sequence: "F1"
        context: Qt.ApplicationShortcut
        onActivated: shortcutsDialog.open()
    }
    Shortcut {
        sequence: "?"
        context: Qt.ApplicationShortcut
        onActivated: shortcutsDialog.open()
    }

    // ─── 快捷键对话框专用小组件（必须在 root 顶层作用域、且在使用方之前定义）─────────
    //   行渲染器：按键徽章（等宽字体 + 深色边框） + 描述。
    //   徽章宽度跟随内容自适应：最小 64（保证 "F"/"R"/"0" 这种单字符键也有足够点击/视觉宽度），
    //   最大 120（避免 "Ctrl+↓" 这类组合键被截，又不会因为某行特别长而把整列拉宽）。
    component ScRow: RowLayout {
        property string keys: ""
        property string desc: ""
        Layout.fillWidth: true
        spacing: 10
        Rectangle {
            Layout.preferredWidth: Math.max(64, Math.min(120, kbdText.implicitWidth + 18))
            Layout.preferredHeight: kbdText.implicitHeight + 6
            radius: 4
            color: "#14141a"
            border.color: "#2a2a32"
            border.width: 1
            Text {
                id: kbdText
                anchors.centerIn: parent
                text: keys
                color: "#e8e8ec"
                font.pixelSize: 12
                font.family: "Menlo, Consolas, monospace"
            }
        }
        Text {
            Layout.fillWidth: true
            text: desc
            color: "#cfd2d6"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
    }

    // 分组渲染器：小号大写标题 + 一组 ScRow。
    //   采用 default property 显式接收行子项，避免 "title 后面的行不会被渲染" 的隐性问题。
    component ScSection: ColumnLayout {
        property string title: ""
        default property alias _rows: scRows.data
        Layout.fillWidth: true
        spacing: 6
        Text {
            text: title
            color: "#9aa0a6"
            font.pixelSize: 11
            font.bold: true
            font.capitalization: Font.AllUppercase
        }
        ColumnLayout {
            id: scRows
            Layout.fillWidth: true
            spacing: 4
        }
    }

    // ─── 快捷键速查对话框 ────────────────────────────────────────────
    //   行业标准做法：分组列表（File / Playback / Speed / View / Channel /
    //   MultiGroup），左列按键徽章（等宽字体），右列描述。
    //   修饰键显示用 `_modKey` 自动适配 mac (⌘) / Win·Linux (Ctrl+)。
    //   全部内容与本文件中真实绑定的 Shortcut 一一对应，不做夸张承诺。
    Dialog {
        id: shortcutsDialog
        title: qsTr("快捷键")
        modal: true
        anchors.centerIn: parent
        // 不使用 standardButtons，改为完全自绘 footer，避免 Qt Basic style
        // 给 DialogButtonBox 渲染白底浅色按钮，与对话框深色基调冲突。
        standardButtons: Dialog.NoButton
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        // 用 implicitWidth 让对话框自适应到一个稳定宽度，避免随窗口变化抖动
        // 880 是经验值：两列分组横向并列时，每列约 420（含内边距），既能放下
        // "切换通道信息叠加（序号 + 文件名）"这类较长描述，又不会让短描述行
        // 出现大段空白；同时一屏就能装下全部分组，无需滚动条。
        implicitWidth: 880
        // 背景：深色面板 + 内描边 + 外阴影（用半透明描边模拟，零依赖）
        background: Rectangle {
            color: "#1e1e22"
            border.color: "#3a3a42"
            border.width: 1
            radius: 8
            // 外阴影：在 Rectangle 外围画一圈渐隐方框（layer 模拟 box-shadow）
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -8
                radius: parent.radius + 4
                color: "transparent"
                border.color: "#80000000"   // 50% 黑
                border.width: 1
                opacity: 0.45
            }
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 2
                color: "transparent"
                border.color: "#a0000000"
                border.width: 1
                opacity: 0.55
            }
        }
        // 自定义标题颜色（默认标题在深色背景下偏黑，肉眼难辨）
        header: Rectangle {
            color: "transparent"
            implicitHeight: 40
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("快捷键")
                color: "#e8e8ec"
                font.pixelSize: 15
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a32"
            }
        }
        // 自定义页脚：深色背景 + 自绘"关闭"按钮（与全局 FlatButton 一致风格）
        footer: Rectangle {
            color: "transparent"
            implicitHeight: 52
            // 顶部 1px 分隔线
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a32"
            }
            FlatButton {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                Layout.preferredWidth: 88
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("关闭")
                onClicked: shortcutsDialog.close()
            }
        }

        // 内容：两列 GridLayout 横向并列，所有分组一屏直出，无需滚动。
        // 之所以放弃 Flickable：分组数量稳定（5-6 个）+ 单分组行数少（≤5），
        // 实测在 880×~360 内能完整容纳，强行加滚动反而让用户以为下方还有
        // 隐藏内容（默认状态滚动条不显示，容易漏看）。
        // 行业惯例：VS Code / iTerm2 / DaVinci 的快捷键速查都偏好"一屏直出 + 多列"。
        contentItem: GridLayout {
            id: scGrid
            columns: 2
            columnSpacing: 28
            rowSpacing: 14
            // 让两列等宽：通过 ScSection 的 Layout.fillWidth + Layout.preferredWidth
            // 在 GridLayout 列内自适应；这里只控行/列间距与对齐方式。
            // 注：原「文件」分组（⌘O / ⌘⇧O / ⌘M / ⌘W / ⌘, / ⌘Q）已从此对话框移除。
            // 这些快捷键的实际 Shortcut 绑定仍在前面的 ApplicationShortcut 区段中保留，
            // 功能不受影响；此处仅不在「快捷键速查」面板里展示，避免与系统菜单/常识冗余。

            // 左列 1：播放
            ScSection {
                title: qsTr("播放")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "Space";  desc: qsTr("暂停 / 继续") }
                ScRow { keys: "←  /  →"; desc: qsTr("后退 / 前进 5 秒") }
                ScRow { keys: ",  /  ."; desc: qsTr("上一帧 / 下一帧") }
                ScRow { keys: "R";       desc: qsTr("回到开头") }
            }
            // 右列 1：视图
            ScSection {
                title: qsTr("视图")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "F"; desc: qsTr("切换全屏") }
                ScRow { keys: "V"; desc: qsTr("切换视频信息叠加") }
                ScRow { keys: "C"; desc: qsTr("切换通道信息叠加（序号 + 文件名）") }
                ScRow { keys: "S"; desc: qsTr("在多路布局间循环切换") }
                ScRow { keys: "B"; desc: qsTr("滑动对比模式（仅 2 路）") }
            }
            // 左列 2：倍速
            ScSection {
                title: qsTr("倍速")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "-";   desc: qsTr("减速一档") }
                ScRow { keys: "=  /  +"; desc: qsTr("加速一档") }
                ScRow { keys: "0";   desc: qsTr("复位为 1.0×") }
            }
            // 右列 2：单路 / 多路
            ScSection {
                title: qsTr("单路 / 多路")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "1 … 9"; desc: qsTr("切到第 N 路单路；再次按下回到上次的多路布局") }
                // 顺带把"鼠标 hover 工具按钮"的提示放在这里，与数字键功能呼应：
                // ⤢/⤡ 与数字键 1-9 等价，⋯ 替换本路，✕ 关闭本路。
                ScRow { keys: "⤢ / ⤡"; desc: qsTr("放大 / 还原本路（每路 hover 工具栏，等同数字键）") }
                ScRow { keys: "⋯";     desc: qsTr("替换本路视频（hover 显示完整路径）") }
                ScRow { keys: "✕";     desc: qsTr("关闭本路视频") }
            }
            // 左列 3：多组对比
            ScSection {
                title: qsTr("多组对比（仅当多组对比窗口激活时）")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "Ctrl+↑"; desc: qsTr("上一组") }
                ScRow { keys: "Ctrl+↓"; desc: qsTr("下一组") }
            }
            // 右列 3 占位：让最后一组左对齐时另一列也保持网格结构稳定
            // （GridLayout 会自动对齐，这里留空 Item 让视觉更平衡）
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
            }
        }
    }

    // 简单的"关于"对话框（深色风格，与全局 UI 一致）
    Dialog {
        id: aboutDialog
        title: qsTr("关于 PlayerX")
        modal: true
        anchors.centerIn: parent
        // 同 shortcutsDialog：自绘 footer，避免默认 DialogButtonBox 的白底
        standardButtons: Dialog.NoButton
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        implicitWidth: 360
        background: Rectangle {
            color: "#1e1e22"
            border.color: "#3a3a42"
            border.width: 1
            radius: 6
            // 外阴影（与 shortcutsDialog 一致）
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -8
                radius: parent.radius + 4
                color: "transparent"
                border.color: "#80000000"
                border.width: 1
                opacity: 0.45
            }
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 2
                color: "transparent"
                border.color: "#a0000000"
                border.width: 1
                opacity: 0.55
            }
        }
        // 标题栏
        header: Rectangle {
            color: "transparent"
            implicitHeight: 40
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("关于 PlayerX")
                color: "#e8e8ec"
                font.pixelSize: 15
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a32"
            }
        }
        contentItem: ColumnLayout {
            spacing: 10
            Text {
                text: "PlayerX"
                color: "#e8e8ec"
                font.pixelSize: 18
                font.bold: true
            }
            Text {
                text: qsTr("一款简洁高效的多路视频对比播放器，\n支持最多 9 路同步播放、多组对比与逐帧分析。")
                color: "#c8c8cc"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.3
            }
            // 版本 + 作者（版本号由 Updater.currentVersion 单点维护，源自 CMake project VERSION）
            Text {
                text: qsTr("版本 %1").arg(Updater.currentVersion)
                color: "#9aa0a6"
                font.pixelSize: 12
            }
            Text {
                text: qsTr("作者 rbyang")
                color: "#9aa0a6"
                font.pixelSize: 12
            }
        }
        // 自绘页脚：右下角"确定"按钮
        footer: Rectangle {
            color: "transparent"
            implicitHeight: 52
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a32"
            }
            FlatButton {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("确定")
                onClicked: aboutDialog.close()
            }
        }
    }

    // ─── 应用自动更新：深色面板（与 aboutDialog 风格一致） ─────────────────
    //   状态机驱动 UI：
    //     idle / checking      → 顶部"正在检查更新…"
    //     available            → 显示新版本号 + 释放说明 + [稍后/立即更新] 按钮
    //     downloading          → 实时进度条 + 速率/剩余时间 + [取消]
    //     verifying / ready    → "校验中…" / "即将重启…"
    //     error                → 红字错误 + [关闭/重试]
    //
    //   userInitiated 标志：区分手动触发与启动后静默自检：
    //     · 手动：弹出对话框 + "已是最新版本"toast；
    //     · 静默：不打扰，仅刷新右上角胶囊按钮的可见性。
    Dialog {
        id: updateDialog
        title: qsTr("应用更新")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.NoButton
        // 下载中禁止 ESC / 点击外部关闭，避免误中断
        closePolicy: (Updater.state === "downloading" || Updater.state === "verifying")
                     ? Popup.NoAutoClose
                     : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
        implicitWidth: 460

        // 是否由用户主动触发（菜单"检查更新…"/胶囊按钮）。决定是否在异常路径下弹 toast。
        property bool userInitiated: false

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#3a3a42"
            border.width: 1
            radius: 6
            // 双层外阴影
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -8
                radius: parent.radius + 4
                color: "transparent"
                border.color: "#80000000"
                border.width: 1
                opacity: 0.45
            }
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 2
                color: "transparent"
                border.color: "#a0000000"
                border.width: 1
                opacity: 0.55
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 40
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: Updater.state === "checking"   ? qsTr("正在检查更新…")
                    : Updater.state === "available"  ? qsTr("发现新版本")
                    : Updater.state === "downloading"? qsTr("正在下载更新…")
                    : Updater.state === "verifying"  ? qsTr("正在校验…")
                    : Updater.state === "ready"      ? qsTr("即将重启应用")
                    : Updater.state === "error"      ? qsTr("更新失败")
                                                     : qsTr("应用更新")
                color: "#e8e8ec"
                font.pixelSize: 15
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a32"
            }
        }

        contentItem: ColumnLayout {
            spacing: 12
            // 版本号一行：当前 → 新版本
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    text: qsTr("当前版本")
                    color: "#9aa0a6"
                    font.pixelSize: 12
                }
                Text {
                    text: Updater.currentVersion
                    color: "#e8e8ec"
                    font.pixelSize: 13
                    font.bold: true
                }
                Text {
                    visible: Updater.latestVersion.length > 0
                    text: "→"
                    color: "#9aa0a6"
                    font.pixelSize: 12
                }
                Text {
                    visible: Updater.latestVersion.length > 0
                    text: qsTr("最新版本")
                    color: "#9aa0a6"
                    font.pixelSize: 12
                }
                Text {
                    visible: Updater.latestVersion.length > 0
                    text: Updater.latestVersion
                    color: "#5cb85c"
                    font.pixelSize: 13
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
            }

            // 释放说明
            Rectangle {
                visible: Updater.releaseNotes.length > 0 && Updater.state !== "downloading"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(notesText.implicitHeight + 16, 140)
                color: "#16161a"
                border.color: "#2a2a32"
                border.width: 1
                radius: 4
                Flickable {
                    anchors.fill: parent
                    anchors.margins: 8
                    contentHeight: notesText.implicitHeight
                    clip: true
                    Text {
                        id: notesText
                        width: parent.width
                        text: Updater.releaseNotes
                        color: "#c8c8cc"
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                        lineHeight: 1.3
                    }
                }
            }

            // 进度条（下载/校验阶段显示）
            ColumnLayout {
                visible: Updater.state === "downloading" || Updater.state === "verifying"
                Layout.fillWidth: true
                spacing: 6
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 6
                    color: "#16161a"
                    border.color: "#2a2a32"
                    border.width: 1
                    radius: 3
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.margins: 1
                        width: Math.max(2, (parent.width - 2) *
                               (Updater.state === "verifying" ? 1 : Updater.progress))
                        radius: 2
                        color: Updater.state === "verifying" ? "#9aa0a6" : "#0e639c"
                        Behavior on width { NumberAnimation { duration: 120 } }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: Updater.state === "verifying"
                          ? qsTr("正在校验文件完整性…")
                          : Updater.progressText
                    color: "#9aa0a6"
                    font.pixelSize: 11
                }
            }

            // 错误提示
            Text {
                visible: Updater.state === "error"
                Layout.fillWidth: true
                text: Updater.errorText
                color: "#e57373"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            // ready 提示
            Text {
                visible: Updater.state === "ready"
                Layout.fillWidth: true
                text: qsTr("更新已下载完成，应用将自动退出并安装新版本…")
                color: "#9aa0a6"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
        }

        footer: Rectangle {
            color: "transparent"
            implicitHeight: 52
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a32"
            }
            RowLayout {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                // 下载中：取消按钮
                FlatButton {
                    visible: Updater.state === "downloading"
                    implicitWidth: 88
                    implicitHeight: 30
                    text: qsTr("取消")
                    onClicked: Updater.cancel()
                }

                // 错误状态：关闭 + 重试
                FlatButton {
                    visible: Updater.state === "error"
                    implicitWidth: 88
                    implicitHeight: 30
                    text: qsTr("关闭")
                    onClicked: updateDialog.close()
                }
                FlatButton {
                    visible: Updater.state === "error"
                    implicitWidth: 88
                    implicitHeight: 30
                    text: qsTr("重试")
                    onClicked: {
                        if (Updater.updateAvailable) Updater.downloadAndApply()
                        else { updateDialog.userInitiated = true; Updater.checkForUpdates(false) }
                    }
                }

                // 可用状态：稍后 + 立即更新
                FlatButton {
                    visible: Updater.state === "available"
                    implicitWidth: 88
                    implicitHeight: 30
                    text: qsTr("稍后")
                    onClicked: updateDialog.close()
                }
                FlatButton {
                    visible: Updater.state === "available"
                    implicitWidth: 100
                    implicitHeight: 30
                    text: qsTr("立即更新")
                    onClicked: Updater.downloadAndApply()
                }

                // 检查中 / 校验中 / ready：仅显示一个不可点的"请稍候"
                FlatButton {
                    visible: Updater.state === "checking" ||
                             Updater.state === "verifying" ||
                             Updater.state === "ready"
                    implicitWidth: 100
                    implicitHeight: 30
                    text: qsTr("请稍候…")
                    enabled: false
                }
            }
        }
    }

    // 简易 toast：右下角短暂提示（用于"已是最新版本"等轻量信息）
    Popup {
        id: updateToast
        property string text: ""
        modal: false
        focus: false
        closePolicy: Popup.NoAutoClose
        // 锚到右下角；ApplicationWindow 内 popup 默认坐标系 = window
        x: root.width - width - 24
        y: root.height - height - 36
        padding: 0
        background: Rectangle {
            color: "#222226"
            border.color: "#3a3a42"
            border.width: 1
            radius: 6
        }
        contentItem: Text {
            text: updateToast.text
            color: "#e8e8ec"
            font.pixelSize: 12
            padding: 12
        }
        Timer {
            running: updateToast.opened
            interval: 2400
            onTriggered: updateToast.close()
        }
    }


    // ─── 关闭全部视频：二次确认（深色，与 about/shortcuts 风格一致）──
    //  · 触发源：工具栏【✕ 全部】、菜单【文件 ▸ 关闭所有视频】、快捷键 ⌘W/Ctrl+W
    //  · 设计：modal + 深色面板 + 阴影 + 自绘 footer（取消/确认清空），避免误触
    //  · 操作只调 Engine.closeAll()，不影响本地 ratings.csv（评分独立保存）
    Dialog {
        id: confirmCloseAllDialog
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.NoButton
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        implicitWidth: 380

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#3a3a42"
            border.width: 1
            radius: 6
            // 双层外阴影（与 aboutDialog/shortcutsDialog 一致）
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -8
                radius: parent.radius + 4
                color: "transparent"
                border.color: "#80000000"
                border.width: 1
                opacity: 0.45
            }
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 2
                color: "transparent"
                border.color: "#a0000000"
                border.width: 1
                opacity: 0.55
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 40
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("关闭所有视频？")
                color: "#e8e8ec"
                font.pixelSize: 15
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a32"
            }
        }

        contentItem: ColumnLayout {
            spacing: 10
            Text {
                Layout.fillWidth: true
                text: qsTr("此操作将关闭当前所有 %1 路视频，本次播放进度不会保留。\n本地评分（ratings.csv）不受影响。")
                       .arg(Engine.fileCount)
                color: "#c8c8cc"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.3
            }
        }

        footer: Rectangle {
            color: "transparent"
            implicitHeight: 56
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a32"
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 8
                Item { Layout.fillWidth: true }
                FlatButton {
                    implicitWidth: 88
                    implicitHeight: 30
                    text: qsTr("取消")
                    onClicked: confirmCloseAllDialog.close()
                }
                FlatButton {
                    implicitWidth: 110
                    implicitHeight: 30
                    text: qsTr("关闭全部")
                    textColor: "#e07070"   // 危险动作 → 红色文字
                    onClicked: {
                        confirmCloseAllDialog.close()
                        Engine.closeAll()
                    }
                }
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
        // 文字颜色（可选）：外部不设时走默认配色；设了则覆盖（按下/悬停/禁用三态自动派生）。
        // 主要给"危险动作"按钮用（如 ✕ 全部 → 红色），不影响普通按钮。
        property color  textColor: "transparent"   // 透明 = 走默认逻辑
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
            // 默认配色 vs 外部覆盖：fb.textColor 透明（默认值）则走原逻辑。
            color: !fb.enabled
                   ? "#555"
                   : (fb.textColor.a > 0
                        ? (fb.down    ? Qt.lighter(fb.textColor, 1.25)
                          : fb.hovered ? Qt.lighter(fb.textColor, 1.10)
                                       : fb.textColor)
                        : (fb.down    ? "#ffffff"
                                      : "#e8e8ec"))
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

    // 「评分模式」全局开关（UI 层）。
    // 真值由 MultiGroupDialog 内部「⚙️配置 → 开启评分」勾选项控制；
    // 这里通过 Binding 反向同步到主窗，使每个 cell 的顶部胶囊条
    // 能根据它决定是否常驻显示 5 颗星（未开启 → 仍只在 ⋯ 菜单的旧位置；
    // 已开启 → 直接把星条挂在 #帧号 · 时间戳 旁边，所有 cell 一眼可见）。
    // 默认 false：不打扰只看视频、不评分的常规使用。
    property bool reviewMode: false


    // -1 表示未选中——默认就是 -1，避免一打开应用就有一路被高亮，造成视觉干扰。
    // 设计动机：Engine.activeIndex 是底层渲染状态（Single 模式靠它选画面、数字键
    // toggle 也依赖它），不能轻易置 -1，否则会破坏既有逻辑。所以这里另起一个
    // QML 端属性，专门表达「用户主动选中了哪一路」：
    //   - 鼠标点击 cell  → 同时设置 selectedIdx 和 Engine.activeIndex（保留原行为）
    //   - 鼠标点击空白    → 仅清 selectedIdx（不动 Engine.activeIndex）
    //   - 数字键 1..9     → 二者同步
    //   - [ / ]            → 仅在 selectedIdx ≥ 0 时切换；为 -1 时按下 ] 进入 0
    //   - Shift+数字 评分 → 必须 selectedIdx ≥ 0 才生效（fileCount==1 时自动用 0）
    property int selectedIdx: -1

    // ─── 参考图侧边栏（左侧 Drawer 风格的常驻栏）─────────────────────
    // 设计目的：AI 生成视频常以同一张参考图为基准，或一组参考图按"对比组"切换。
    // 两种绑定模式（由 ReferenceStore 维护）：
    //   · image  ：一张固定图，整组对比始终显示这张；
    //   · folder ：一个图片文件夹，按"当前视频在其文件夹中的索引"取同序号图片，
    //              切到下一组（下一段视频）时自动跟着切到下一张参考图。
    // 与播放内核完全解耦：仅依赖 Engine.filePathAt / Reference.* 的 Q_INVOKABLE。
    property bool refSidebarVisible: false
    readonly property int refSidebarWidth: refSidebarVisible ? 320 : 0

    // 触发器：Reference.referenceChanged / 文件切换时 ++，让下面的 readonly 重算
    property int _refTick: 0
    Connections {
        target: typeof Reference !== "undefined" ? Reference : null
        function onReferenceChanged(folder)     { root._refTick++ }
        function onReferenceTextChanged(folder) { root._refTick++ }
    }
    Connections {
        target: Engine
        // 只在「换下一组对比」时刷新；
        // activeIndexChanged（数字键 1/2 切换聚焦）不再影响侧边栏图文。
        function onFilesChanged() { root._refTick++ }
    }

    // 取「当前对比组」的代表视频索引：
    //   设计目标：同一对比组里所有通道共享同一份"参考图 + 参考文本"，
    //   按数字键 1/2 切换聚焦、或鼠标点选某一通道时，侧边栏图文都不应变化。
    //   故这里永远返回该组的第一个有效视频索引（index 0），
    //   只有"换下一组对比"（Engine.filesChanged）才会重新计算。
    function _refTargetIdx() {
        return Engine.fileCount > 0 ? 0 : -1
    }
    function _refDirOf(fp) {
        if (!fp || fp.length === 0) return ""
        var p = String(fp)
        var i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
        return i > 0 ? p.substring(0, i) : ""
    }
    // 当前焦点视频的绝对路径（folder 模式下，参考图按它的文件夹序号同步切换）
    readonly property string refCurrentVideo: {
        _refTick;
        var i = _refTargetIdx()
        if (i < 0) return ""
        return Engine.filePathAt(i) || ""
    }
    // 当前焦点视频所在文件夹（写入参考图绑定时用作 key）
    readonly property string refCurrentFolder: {
        _refTick;
        return _refDirOf(root.refCurrentVideo)
    }
    // ─── 参考图：用户手动浏览偏移量 ───────────────────────────────────
    // 在 folder 模式下，◀ ▶ 按钮可临时偏离"自动同步"的索引。
    //   · 仅 folder 模式有意义；image 模式忽略。
    //   · 切到下一组对比时（filesChanged → _refTick++）自动归零，避免越过组边界。
    property int _refImgOffset: 0
    // 实际渲染用的图片 URL：
    //   · image 模式：固定图（offset 无效）；
    //   · folder 模式：按 refCurrentVideo 的同序号 + _refImgOffset 取图（C++ 端做边界裁剪）。
    readonly property url refCurrentUrl: {
        _refTick;
        if (typeof Reference === "undefined") return ""
        if (root.refCurrentVideo.length === 0) return ""
        return Reference.referenceUrlForVideoOffset(root.refCurrentVideo, root._refImgOffset)
    }
    readonly property bool refHasCurrent: String(root.refCurrentUrl).length > 0
    // "image" / "folder" / ""（未绑定）
    readonly property string refCurrentMode: {
        _refTick;
        if (typeof Reference === "undefined") return ""
        if (root.refCurrentFolder.length === 0) return ""
        return Reference.kindOf(root.refCurrentFolder)
    }
    // folder 模式下 "N / M" 的进度文本；image 模式 / 未绑定时为空
    readonly property string refProgressText: {
        _refTick;
        if (typeof Reference === "undefined") return ""
        if (root.refCurrentVideo.length === 0) return ""
        return Reference.referenceProgressForVideoOffset(root.refCurrentVideo, root._refImgOffset)
    }
    // folder 模式下参考图总数；image / 未绑定时为 0
    readonly property int refImageCount: {
        _refTick;
        if (typeof Reference === "undefined") return 0
        if (root.refCurrentVideo.length === 0) return 0
        return Reference.referenceImageCountForVideo(root.refCurrentVideo)
    }
    // 当前在参考图文件夹里的真实索引（0-based），用于 ◀ ▶ 按钮可用性判断
    readonly property int refCurrentImageIndex: {
        var t = root.refProgressText
        if (!t || t.length === 0) return -1
        var slash = t.indexOf("/")
        if (slash < 0) return -1
        var n = parseInt(t.substring(0, slash).trim(), 10)
        return isNaN(n) ? -1 : (n - 1)
    }
    // 切组时归零偏移
    Connections {
        target: Engine
        function onFilesChanged() { root._refImgOffset = 0 }
    }

    // ─── 参考文本（CSV）─────────────────────────────────────────────
    // 与参考图同样按"当前视频在其文件夹中的索引"取 csv 第 N 行。
    //   refTextData : { image, zh, en, raw, row, total }
    //   refTextLang : "zh" / "en"，UI 偏好（持久化在 Settings 里，session 内共享）
    property string refTextLang: "zh"
    readonly property var refTextData: {
        _refTick;
        if (typeof Reference === "undefined") return ({})
        if (root.refCurrentVideo.length === 0) return ({})
        return Reference.referenceTextForVideo(root.refCurrentVideo) || ({})
    }
    readonly property bool refTextHasCurrent: {
        var d = root.refTextData
        if (!d) return false
        var zh = d.zh || ""
        var en = d.en || ""
        return (zh.length > 0) || (en.length > 0)
    }
    readonly property string refTextKind: {
        _refTick;
        if (typeof Reference === "undefined") return ""
        if (root.refCurrentFolder.length === 0) return ""
        return Reference.textKindOf(root.refCurrentFolder)
    }
    readonly property string refTextProgress: {
        _refTick;
        if (typeof Reference === "undefined") return ""
        if (root.refCurrentVideo.length === 0) return ""
        return Reference.textProgressForVideo(root.refCurrentVideo)
    }
    // 当前展示的纯文本：按 refTextLang 优先，失败回退另一语言
    readonly property string refTextDisplay: {
        var d = root.refTextData
        if (!d) return ""
        var zh = d.zh || ""
        var en = d.en || ""
        if (root.refTextLang === "en") return en.length > 0 ? en : zh
        return zh.length > 0 ? zh : en
    }
    // 是否同时有中英两份（用于决定切换按钮可见）
    readonly property bool refTextHasBothLangs: {
        var d = root.refTextData
        if (!d) return false
        return (d.zh || "").length > 0 && (d.en || "").length > 0
    }

    // 评分提示 Toast（屏幕中央浮层）。HUD 由底部 Item 渲染；这里只放数据。
    //   - ratingToastText  : 主文本（星星 / 提示语）
    //   - ratingToastKind  : "score" / "clear" / "warn"，决定背景 & 边框色
    //   - ratingToastScore : 1～5（kind=="score" 时有意义），决定主色调
    property string ratingToastText: ""
    property string ratingToastKind: "score"
    property int    ratingToastScore: 0
    function _showRatingToast(idx, score) {
        var stars = ""
        for (var i = 0; i < 5; ++i) stars += (i < score ? "\u2605" : "\u2606")
        var cleared = (score === 0)
        ratingToastText = (cleared ? "已清除评分" : stars)
                          + "  \u00b7  \u901a\u9053 " + (idx + 1)
        ratingToastKind  = cleared ? "clear" : "score"
        ratingToastScore = score
        ratingToast.show()
    }
    function _showRatingWarn(text) {
        ratingToastText  = text
        ratingToastKind  = "warn"
        ratingToastScore = 0
        ratingToast.show()
    }

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

        // 持久化到本地 CSV（Rating = RatingStore 单例）。
        // 取消评分（arr[idx]===0）也写入，便于审计；按 file_path+rater 覆盖，
        // 因此重复点同一分数→0→3 等只会留下最新一条。
        if (typeof Rating !== "undefined") {
            var fp = Engine.filePathAt(idx)
            if (fp && fp.length > 0) {
                var fn = Engine.fileNameAt(idx)
                // idx = 宫格索引（0-based），传给 RatingStore 用于在 CSV 的 file_name
                // 字段前加 "<idx+1>_" 前缀，方便多组对比时一眼定位通道；
                // 不影响标题栏 / 文件列表弹窗等其他位置的文件名显示。
                Rating.recordRating(fp, fn, arr[idx], idx)
            }
        }
    }
    Connections {
        target: Engine
        function onFileCountChanged() {
            // 简单裁剪：fileCount 缩小后，保留前 N 项；扩大无需处理
            if (root.cellRatings.length > Engine.fileCount) {
                root.cellRatings = root.cellRatings.slice(0, Engine.fileCount)
            }
        }
        // 翻组 / 切宫格 / 重新打开文件后，按新文件路径重建 cellRatings —
        // 避免上一组的评分残留到下一组（同一 idx 但 path 已变）。
        // RatingStore.ratingFor(path) 命中返回 0-5、未命中返回 -1（视为未评分）。
        function onFilesChanged() {
            var n = Engine.fileCount
            var arr = []
            for (var i = 0; i < n; ++i) {
                var fp = Engine.filePathAt(i)
                var v = -1
                if (typeof Rating !== "undefined" && fp && fp.length > 0) {
                    v = Rating.ratingFor(fp)
                }
                arr.push((typeof v === "number" && v >= 1 && v <= 5) ? v : 0)
            }
            root.cellRatings = arr
            // 切换文件 / 翻组 / 改宫格后，主动复位 selectedIdx，避免上一组的
            // 选中（蓝边）残留误导。用户若需要再选中，单击或 [ / ] 即可。
            root.selectedIdx = -1
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
            // 从空状态打开 → 走 MultiGroupDialog.loadFlatFiles 接管，获得 N 宫格切换 / 翻页能力；
            // 已有视频时 → 维持原"逐个 addFile"的追加语义（不打断当前对比）。
            if (Engine.fileCount === 0) {
                if (selectedFiles.length === 1) {
                    // 单个文件：直接打开即可，不进 active 态（用户没想进队列模式）
                    Engine.openFiles(selectedFiles)
                } else if (selectedFiles.length > 1) {
                    // 多个文件：纳入 MultiGroupDialog 接管，默认以 1 宫格启动，
                    // 之后用底栏 ▦ 按钮切宫格、⏮⏭ 翻页。
                    if (!multiGroupDialog.loadFlatFiles(selectedFiles)) {
                        // 兜底：接管失败仍按老逻辑直开（截前 9 个）
                        var arr = selectedFiles
                        if (arr.length > 9) arr = arr.slice(0, 9)
                        Engine.openFiles(arr)
                    }
                }
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
    // ─── 底部工具栏 ──────────────────────────────────────────────────────
    // 自绘 background：深色填充 + 顶部 1px 分隔线，与视频区在视觉上彻底
    // 切开。原先 ToolBar 用系统主题色，与视频黑底界限模糊，按钮按下时还
    // 会引起整体重绘抖动。
    // 放在 footer：Windows 上避免"菜单栏 + 工具栏"的双顶栏观感；每路视频
    // 有各自的 OSD 进度条，这里承载的是全局播放控制（快进/快退/帧步进/
    // 播放暂停/重置/多组切换/倍速徽标），放到窗口底部更符合主流播放器习惯。
    footer: ToolBar {
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

            // ── 左侧"参考图侧边栏"切换 ──
            // 已展开 → 绿色描边作为状态指示；折叠 → 普通描边。
            // 用原生 Button + 自绘背景，与 ToolBar 风格统一；FlatButton 不带 ToolTip / checked。
            Button {
                id: refToggleBtn
                text: "🖼"
                Layout.preferredWidth: 32
                Layout.preferredHeight: 28
                Layout.alignment: Qt.AlignVCenter
                hoverEnabled: true
                onClicked: root.refSidebarVisible = !root.refSidebarVisible
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: root.refSidebarVisible
                              ? "隐藏参考图侧边栏"
                              : (root.refHasCurrent
                                 ? "显示参考图（当前文件夹已绑定）"
                                 : "显示参考图侧边栏")
                background: Rectangle {
                    color: refToggleBtn.down ? "#4a4a55"
                          : refToggleBtn.hovered ? "#33333a"
                          : (root.refSidebarVisible ? "#2a2a32" : "#202024")
                    border.color: root.refSidebarVisible ? "#0fa085"
                                  : (root.refHasCurrent ? "#3d6c66" : "#3a3a42")
                    border.width: 1
                    radius: 5
                }
                contentItem: Text {
                    text: refToggleBtn.text
                    color: root.refSidebarVisible ? "#7fe5cc" : "#e8e8ec"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

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
            // ── 单视频浏览模式专用：宫格切换（1/2/4/6/9） ──
            // 仅在 singleLaneMode（即来源为单文件夹或"添加文件"等单路情形）下显示。
            // 点击弹出菜单选择 N → 调 setViewCount(n)：从当前页起点连续取 N 个视频铺到 N 宫格里。
            FlatButton {
                id: viewCountBtn
                text: "▦ " + multiGroupDialog.viewCount
                visible: multiGroupDialog.singleLaneMode
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 13
                enabled: multiGroupDialog.singleLaneMode
                onClicked: viewCountMenu.popup(viewCountBtn, 0, viewCountBtn.height)
                Menu {
                    id: viewCountMenu
                    Repeater {
                        model: multiGroupDialog.supportedViewCounts
                        delegate: MenuItem {
                            text: {
                                var n = modelData
                                if (n === 1) return "1 · 单视图"
                                if (n === 2) return "2 · 横排"
                                if (n === 4) return "4 · 2×2 宫格"
                                if (n === 6) return "6 · 2×3 宫格"
                                if (n === 9) return "9 · 3×3 宫格"
                                return n + " 个"
                            }
                            checkable: true
                            checked: multiGroupDialog.viewCount === modelData
                            onTriggered: multiGroupDialog.setViewCount(modelData)
                        }
                    }
                }
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

            // ── 关闭全部视频（一次性清空所有路）──
            // 设计：
            //   · 只在 fileCount > 0 时显示，与单路 ✕ 一致；
            //   · 文案 "✕ 全部" 用红色调色，悬停加深，与单路关闭按钮的语义/视觉对齐；
            //   · 点击先弹深色二次确认弹窗，避免误触一次性丢失全部正在比较的视频；
            //   · 也可通过【文件】▸ 关闭所有视频 / ⌘W 触发。
            FlatButton {
                id: closeAllBtn
                text: "✕ 全部"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 12
                textColor: "#e07070"
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: qsTr("关闭所有视频（⌘W / Ctrl+W）")
                onClicked: confirmCloseAllDialog.open()
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
        // 否则进入 Single 并聚焦到该窗口；同时把 UI 选中态也设上，让快捷评分有目标
        Engine.activeIndex = idx
        Engine.layoutMode  = 0  // LayoutSingle
        root.selectedIdx   = idx
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

    // ── 快捷评分 / 选中通道切换 ─────────────────────────────────────
    // 设计要点：
    //   1. 数字键 1-9 已被占用为「toggle 单路/多路」，因此评分用 Shift+0..5
    //      避开冲突（Shift+0 = 清空，Shift+1..5 = 1..5 星）。
    //   2. [ / ] 用于在通道间切换 activeIndex（即"选中下一路 / 上一路"），
    //      不改变布局（layoutMode），只换"选中"——这点很重要，避免和数字键
    //      的 toggle 行为语义重叠。
    //   3. 全部走 root.setRatingAt() 已有逻辑：写入 cellRatings + 持久化到 CSV、
    //      "再按相同分数 = 取消"等行为完全复用，零重复实现。
    //   4. enabled 守卫：只有 fileCount > 0 才允许评分，防止空状态误触发。
    //   5. context 选 ApplicationShortcut：和现有数字键一致，确保仅当应用前台
    //      聚焦时生效；TextField/SpinBox 等控件聚焦时 Qt 会自动让控件优先吃键，
    //      所以"输入框场景下不打扰"的诉求天然满足。
    // 评分时确定目标通道：
    //   - 用户已显式选中（selectedIdx ≥ 0）→ 直接用
    //   - 仅有一路视频 → 自动落到 0（无歧义场景，省去先点击的麻烦）
    //   - 多路且未选中 → 返回 -1，调用方应给出提示，不要悄悄打到第 0 路造成误评
    function _resolveRatingTarget() {
        if (Engine.fileCount <= 0) return -1
        if (root.selectedIdx >= 0 && root.selectedIdx < Engine.fileCount)
            return root.selectedIdx
        if (Engine.fileCount === 1) return 0
        return -1
    }
    // 快捷键评分专用：不走 setRatingAt（那里含 toggle 语义，给鼠标点星条用），
    // 这里一律“强制覆盖写入”：不管以前是几星，按下 Shift+N 就是 N 星，
    // 避免“首次评分出现已清除评分”、“连按两下变 0 分”这些迷惑场景。
    function _writeRating(idx, score) {
        var arr = root.cellRatings.slice()
        while (arr.length <= idx) arr.push(0)
        arr[idx] = score
        root.cellRatings = arr
        if (typeof Rating !== "undefined") {
            var fp = Engine.filePathAt(idx)
            if (fp && fp.length > 0) {
                Rating.recordRating(fp, Engine.fileNameAt(idx), score, idx)
            }
        }
    }
    function _setRatingForActive(score) {
        var idx = root._resolveRatingTarget()
        if (idx < 0) {
            root._showRatingWarn("\u8bf7\u5148\u9009\u4e2d\u4e00\u4e2a\u901a\u9053\uff08\u5355\u51fb\u753b\u9762\u6216\u6309 [ / ]\uff09")
            return
        }
        root._writeRating(idx, score)
        root._showRatingToast(idx, score)
    }
    function _clearRatingForActive() {
        var idx = root._resolveRatingTarget()
        if (idx < 0) {
            root._showRatingWarn("\u8bf7\u5148\u9009\u4e2d\u4e00\u4e2a\u901a\u9053\uff08\u5355\u51fb\u753b\u9762\u6216\u6309 [ / ]\uff09")
            return
        }
        root._writeRating(idx, 0)
        root._showRatingToast(idx, 0)
    }
    function _shiftActive(dir) {
        // dir: -1 上一路 / +1 下一路；循环。
        // 同时同步 Engine.activeIndex，让 Single 模式下的渲染也跟着切。
        var n = Engine.fileCount
        if (n <= 0) return
        var cur = root.selectedIdx
        if (cur < 0) {
            // 未选中场景：进入选中态，从 0（往后切）或末尾（往前切）开始
            cur = (dir > 0) ? -1 : n   // 让下面 (cur+dir) 落到 0 / n-1
        }
        var nxt = ((cur + dir) % n + n) % n
        root.selectedIdx = nxt
        Engine.activeIndex = nxt
    }
    Shortcut { sequence: "Shift+0"; context: Qt.ApplicationShortcut; enabled: Engine.fileCount > 0
               onActivated: root._clearRatingForActive() }
    Shortcut { sequence: "Shift+1"; context: Qt.ApplicationShortcut; enabled: Engine.fileCount > 0
               onActivated: root._setRatingForActive(1) }
    Shortcut { sequence: "Shift+2"; context: Qt.ApplicationShortcut; enabled: Engine.fileCount > 0
               onActivated: root._setRatingForActive(2) }
    Shortcut { sequence: "Shift+3"; context: Qt.ApplicationShortcut; enabled: Engine.fileCount > 0
               onActivated: root._setRatingForActive(3) }
    Shortcut { sequence: "Shift+4"; context: Qt.ApplicationShortcut; enabled: Engine.fileCount > 0
               onActivated: root._setRatingForActive(4) }
    Shortcut { sequence: "Shift+5"; context: Qt.ApplicationShortcut; enabled: Engine.fileCount > 0
               onActivated: root._setRatingForActive(5) }
    // 选中切换（不改布局，仅改 selectedIdx + Engine.activeIndex）：[ 上一路 / ] 下一路，循环。
    // 即使 fileCount == 1，也允许按 ] 让 selectedIdx 从 -1 进入 0（"用键盘进入选中状态"）。
    Shortcut { sequence: "[";       context: Qt.ApplicationShortcut; enabled: Engine.fileCount >= 1
               onActivated: root._shiftActive(-1) }
    Shortcut { sequence: "]";       context: Qt.ApplicationShortcut; enabled: Engine.fileCount >= 1
               onActivated: root._shiftActive(+1) }

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

    // ─── 参考图侧边栏 ───────────────────────────────────────────────
    // 锚定：左侧贴边、上下与 videoArea 一致；宽度 = refSidebarWidth（折叠时 0）。
    // 折叠态完全不占位，且通过 visible 控制让其内部 binding 不参与求值，零开销。
    Rectangle {
        id: refSidebar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.topMargin: 2
        anchors.bottom: parent.bottom
        width: root.refSidebarWidth
        visible: root.refSidebarVisible && width > 0
        color: "#15151a"
        // 右侧 1px 分隔线，与视频区切开
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: "#2c2c32"
        }

        // 顶部标题栏（含关闭按钮）
        Rectangle {
            id: refHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 32
            color: "#1a1a1d"
            Label {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "参考资料"
                color: "#cfcfd2"
                font.pixelSize: 12
                font.bold: true
            }
            Label {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: "✕"
                color: closeMa.containsMouse ? "#ffffff" : "#9a9aa8"
                font.pixelSize: 14
                MouseArea {
                    id: closeMa
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.refSidebarVisible = false
                }
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2c2c32"
            }
        }

        // 当前文件夹名（只显示叶节点目录名，避免长路径挤压）
        Label {
            id: refFolderLabel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: refHeader.bottom
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            anchors.topMargin: 6
            height: 18
            // 文件名过长时左侧省略，关键后缀（叶节点名）始终可见
            LayoutMirroring.enabled: false
            horizontalAlignment: Text.AlignLeft
            elide: Text.ElideLeft
            // 用 rtl 让"…/leaf"中省略号在前
            text: {
                var f = root.refCurrentFolder
                if (!f || f.length === 0) return "（未选中通道）"
                // 抽取最后一段作为标题，hover 完整 tooltip
                var i = Math.max(f.lastIndexOf("/"), f.lastIndexOf("\\"))
                return i >= 0 ? f.substring(i + 1) : f
            }
            color: "#9a9aa8"
            font.pixelSize: 11
            ToolTip.visible: refFolderHover.containsMouse && root.refCurrentFolder.length > 0
            ToolTip.delay: 400
            ToolTip.text: root.refCurrentFolder
            MouseArea { id: refFolderHover; anchors.fill: parent; hoverEnabled: true }
        }

        // 上半："参考图"区
        Item {
            id: refTopPane
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: refFolderLabel.bottom
            anchors.topMargin: 4
            // 高度由"上下分隔条"控制；refSplitter 顶部即上半底部
            anchors.bottom: refSplitter.top
        }

        // 中央图片区 + 拖拽接收 + 占位提示
        Rectangle {
            id: refImageBox
            anchors.left: refTopPane.left
            anchors.right: refTopPane.right
            anchors.top: refTopPane.top
            anchors.bottom: refButtonsBar.top
            anchors.margins: 8
            color: "#0e0e10"
            border.color: refDrop.containsDrag ? "#5a8fd8" : "#2c2c32"
            border.width: 1
            radius: 4

            // 实际图片（使用文件 URL；自动 Retina 缩放，PreserveAspectFit 保持比例）
            Image {
                id: refImage
                anchors.fill: parent
                anchors.margins: 4
                source: root.refCurrentUrl
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                cache: true
                // sourceSize 让 Image 按目标尺寸解码，节省内存（大图也不卡）
                sourceSize.width:  width  > 0 ? width  * 2 : 512
                sourceSize.height: height > 0 ? height * 2 : 512
                visible: root.refHasCurrent && status === Image.Ready
                asynchronous: true
            }

            // 加载中 / 失败 / 未绑定占位
            Label {
                anchors.centerIn: parent
                width: parent.width - 24
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: !refImage.visible
                color: "#6a6a78"
                font.pixelSize: 12
                text: {
                    if (root.refCurrentFolder.length === 0)
                        return "请选中任一通道，\n或在「打开文件夹」对话框中为该路绑定参考图"
                    if (!root.refHasCurrent)
                        return "该文件夹未绑定参考图\n\n点击下方「图片」选一张固定图\n或「文件夹」让参考图随对比组切换\n（也可直接把图片或图片文件夹拖进来）"
                    if (refImage.status === Image.Loading)  return "加载中…"
                    if (refImage.status === Image.Error)    return "图片无法加载（可能已被移动或删除）"
                    return ""
                }
            }

            // 拖拽接收：
            //   · 拖入文件夹 → folder 模式（参考图按对比组同步切换）
            //   · 拖入图片  → image 模式（固定图）
            //   · 多选时优先文件夹；都不命中再尝试每个 URL 当图片
            DropArea {
                id: refDrop
                anchors.fill: parent
                onDropped: function(drop) {
                    if (root.refCurrentFolder.length === 0) {
                        drop.accepted = false
                        return
                    }
                    if (!drop.hasUrls) { drop.accepted = false; return }
                    // 1) 优先识别文件夹
                    for (var i = 0; i < drop.urls.length; ++i) {
                        var u = drop.urls[i]
                        if (Fs.isDirectory(u)) {
                            if (Reference.setReferenceFolderUrl(root.refCurrentFolder, u)) {
                                drop.accepted = true
                                return
                            }
                        }
                    }
                    // 2) 否则尝试图片文件
                    for (var j = 0; j < drop.urls.length; ++j) {
                        var u2 = drop.urls[j]
                        if (Reference.setReferenceUrl(root.refCurrentFolder, u2)) {
                            drop.accepted = true
                            return
                        }
                    }
                    drop.accepted = false
                }
            }

            // ◀ ▶ 浮层切换按钮（仅 folder 模式 / 总数>1 时可见）
            //   ◀：在自动索引上 -1（夹紧到 0）
            //   ▶：在自动索引上 +1（夹紧到 N-1）
            //   悬浮在图片右下角，不占按钮条；点击时图片自动重新加载。
            Row {
                id: refImgNavBar
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 6
                spacing: 4
                visible: root.refCurrentMode === "folder" && root.refImageCount > 1

                // ── 上一张 ───────────────────────────────────────
                Rectangle {
                    id: refPrevBtn
                    width: 28; height: 24
                    radius: 3
                    color: prevMA.pressed ? "#3a3a45"
                          : prevMA.containsMouse ? "#2a2a32"
                          : "#1a1a1da0"   // 半透明深底，避免遮挡图片
                    border.color: refPrevBtn.enabled ? "#5a5a65" : "#2a2a32"
                    border.width: 1
                    property bool enabled: root.refCurrentImageIndex > 0
                    Text {
                        anchors.centerIn: parent
                        text: "◀"
                        font.pixelSize: 12
                        color: refPrevBtn.enabled ? "#e8e8ec" : "#555"
                    }
                    MouseArea {
                        id: prevMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: refPrevBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (!refPrevBtn.enabled) return
                            root._refImgOffset -= 1
                        }
                    }
                    ToolTip.visible: prevMA.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "上一张参考图（手动浏览）"
                }

                // ── 下一张 ───────────────────────────────────────
                Rectangle {
                    id: refNextBtn
                    width: 28; height: 24
                    radius: 3
                    color: nextMA.pressed ? "#3a3a45"
                          : nextMA.containsMouse ? "#2a2a32"
                          : "#1a1a1da0"
                    border.color: refNextBtn.enabled ? "#5a5a65" : "#2a2a32"
                    border.width: 1
                    property bool enabled: root.refImageCount > 0
                                            && root.refCurrentImageIndex >= 0
                                            && root.refCurrentImageIndex < root.refImageCount - 1
                    Text {
                        anchors.centerIn: parent
                        text: "▶"
                        font.pixelSize: 12
                        color: refNextBtn.enabled ? "#e8e8ec" : "#555"
                    }
                    MouseArea {
                        id: nextMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: refNextBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (!refNextBtn.enabled) return
                            root._refImgOffset += 1
                        }
                    }
                    ToolTip.visible: nextMA.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "下一张参考图（手动浏览）"
                }

                // ── 复位按钮（仅 offset!=0 时显示，让用户回到"自动同步"状态）─────
                Rectangle {
                    id: refResetBtn
                    width: 28; height: 24
                    radius: 3
                    visible: root._refImgOffset !== 0
                    color: resetMA.pressed ? "#3a3a45"
                          : resetMA.containsMouse ? "#2a2a32"
                          : "#1a1a1da0"
                    border.color: "#7fe5cc"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "⟳"
                        font.pixelSize: 13
                        color: "#7fe5cc"
                    }
                    MouseArea {
                        id: resetMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._refImgOffset = 0
                    }
                    ToolTip.visible: resetMA.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "回到自动同步索引"
                }
            }
        }

        // 模式 / 进度小标签：folder 模式时显示 "📂 跟随对比组 · N / M"，image 模式时显示 "🖼 固定图"
        // 紧贴在按钮区上方，不占图片显示区。
        Rectangle {
            id: refModeBar
            anchors.left: refTopPane.left
            anchors.right: refTopPane.right
            anchors.bottom: refButtonsBar.top
            height: visible ? 22 : 0
            visible: root.refHasCurrent
            color: "transparent"
            Label {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignLeft
                elide: Text.ElideRight
                font.pixelSize: 11
                color: root.refCurrentMode === "folder" ? "#7fe5cc" : "#9a9aa8"
                text: {
                    if (root.refCurrentMode === "folder") {
                        return "📂 跟随对比组" + (root.refProgressText.length > 0
                                                  ? "   ·   " + root.refProgressText
                                                  : "")
                    }
                    if (root.refCurrentMode === "image") return "🖼 固定图"
                    return ""
                }
            }
        }

        // 底部按钮：图片（image 模式）/ 文件夹（folder 模式）/ 清除
        Rectangle {
            id: refButtonsBar
            anchors.left: refTopPane.left
            anchors.right: refTopPane.right
            anchors.bottom: refTopPane.bottom
            height: 40
            color: "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                // 图片按钮：单图 image 模式（已在 image 模式时高亮）
                Button {
                    id: refPickImgBtn
                    text: "图片"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 24
                    enabled: root.refCurrentFolder.length > 0
                    hoverEnabled: true
                    onClicked: refSidebarFileDlg.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择一张固定参考图（整组对比始终显示这张）"
                    background: Rectangle {
                        readonly property bool active: root.refCurrentMode === "image"
                        color: !refPickImgBtn.enabled ? "#1a1a1d"
                              : refPickImgBtn.down ? "#4a4a55"
                              : refPickImgBtn.hovered ? "#33333a"
                              : (active ? "#2a2a32" : "#202024")
                        border.color: !refPickImgBtn.enabled ? "#2a2a32"
                                      : (active ? "#5a8fd8" : "#3a3a45")
                        border.width: 1
                        radius: 3
                    }
                    contentItem: Text {
                        text: refPickImgBtn.text
                        color: refPickImgBtn.enabled ? "#e8e8ec" : "#555"
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // 文件夹按钮：folder 模式（已在 folder 模式时绿色高亮）
                Button {
                    id: refPickDirBtn
                    text: "文件夹"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 24
                    enabled: root.refCurrentFolder.length > 0
                    hoverEnabled: true
                    onClicked: refSidebarDirDlg.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择一个图片文件夹\n参考图按当前视频在其文件夹中的序号自动同步"
                    background: Rectangle {
                        readonly property bool active: root.refCurrentMode === "folder"
                        color: !refPickDirBtn.enabled ? "#1a1a1d"
                              : refPickDirBtn.down ? "#4a4a55"
                              : refPickDirBtn.hovered ? "#33333a"
                              : (active ? "#1f2e2a" : "#202024")
                        border.color: !refPickDirBtn.enabled ? "#2a2a32"
                                      : (active ? "#0fa085" : "#3a3a45")
                        border.width: 1
                        radius: 3
                    }
                    contentItem: Text {
                        text: refPickDirBtn.text
                        color: !refPickDirBtn.enabled ? "#555"
                               : (root.refCurrentMode === "folder" ? "#7fe5cc" : "#e8e8ec")
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: refClearBtn
                    text: "清除"
                    Layout.preferredWidth: 56
                    Layout.preferredHeight: 24
                    visible: root.refHasCurrent
                    hoverEnabled: true
                    onClicked: {
                        if (root.refCurrentFolder.length > 0)
                            Reference.clearReference(root.refCurrentFolder)
                    }
                    background: Rectangle {
                        color: refClearBtn.down ? "#5a2a2a"
                              : refClearBtn.hovered ? "#3a2228"
                                                     : "#202024"
                        border.color: "#3a3a42"
                        border.width: 1
                        radius: 3
                    }
                    contentItem: Text {
                        text: refClearBtn.text
                        color: "#e8b0b0"
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // ─── 上下分隔条（可拖动调整上下两栏比例）─────────────────────
        // 用 fraction 表示上半占"内容区"剩余高度的比例（0.18 ~ 0.85），
        // 拖动时实时改变，但不持久化（保持轻量）。
        property real refTopFraction: 0.55
        // 内容区起点 = refFolderLabel 底部 + 4；终点 = refSidebar 底部
        readonly property real _refContentTop: refFolderLabel.y + refFolderLabel.height + 4
        readonly property real _refContentBottom: height
        readonly property real _refContentH: Math.max(120, _refContentBottom - _refContentTop)

        Rectangle {
            id: refSplitter
            anchors.left: parent.left
            anchors.right: parent.right
            // y = 内容起点 + 上半占比 * 总高
            y: refSidebar._refContentTop + Math.round(refSidebar._refContentH * refSidebar.refTopFraction)
            height: 6
            color: refSplitterMa.containsMouse || refSplitterMa.pressed ? "#2a2a32" : "transparent"
            // 中线：3 个浅色"・"作为视觉提示
            Row {
                anchors.centerIn: parent
                spacing: 4
                Repeater {
                    model: 3
                    Rectangle { width: 3; height: 3; radius: 1.5; color: "#5a5a66" }
                }
            }
            MouseArea {
                id: refSplitterMa
                anchors.fill: parent
                anchors.topMargin: -2
                anchors.bottomMargin: -2
                hoverEnabled: true
                cursorShape: Qt.SplitVCursor
                drag.target: null  // 自己用 onPositionChanged 计算，避免位移到上下边界外
                property real _grabOffset: 0
                onPressed: function(mouse) {
                    _grabOffset = mouse.y
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var newY = refSplitter.y + (mouse.y - _grabOffset)
                    var topMin = refSidebar._refContentTop + 80    // 上半至少 80
                    var topMax = refSidebar.height - 120           // 下半至少 120
                    newY = Math.max(topMin, Math.min(topMax, newY))
                    refSidebar.refTopFraction = (newY - refSidebar._refContentTop) / refSidebar._refContentH
                }
                onDoubleClicked: refSidebar.refTopFraction = 0.55  // 双击复位
            }
        }

        // ─── 下半："参考文本"区 ─────────────────────────────────────
        Item {
            id: refBottomPane
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: refSplitter.bottom
            anchors.bottom: parent.bottom
        }

        // 文本视图框（带滚动）
        Rectangle {
            id: refTextBox
            anchors.left: refBottomPane.left
            anchors.right: refBottomPane.right
            anchors.top: refBottomPane.top
            anchors.bottom: refTextModeBar.top
            anchors.margins: 8
            color: "#0e0e10"
            border.color: refTextDrop.containsDrag ? "#5a8fd8" : "#2c2c32"
            border.width: 1
            radius: 4

            Flickable {
                id: refTextScroll
                anchors.fill: parent
                anchors.margins: 8
                clip: true
                contentWidth: width
                contentHeight: refTextLabel.implicitHeight
                visible: root.refTextHasCurrent
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                Text {
                    id: refTextLabel
                    width: refTextScroll.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: root.refTextDisplay
                    color: "#d8d8e0"
                    font.pixelSize: 12
                    lineHeight: 1.45
                    // 中文文本左右对齐更耐看；纯英文也兼容
                    horizontalAlignment: Text.AlignLeft
                }
            }

            // 占位提示
            Label {
                anchors.centerIn: parent
                width: parent.width - 24
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: !refTextScroll.visible
                color: "#6a6a78"
                font.pixelSize: 12
                text: {
                    if (root.refCurrentFolder.length === 0)
                        return "请选中任一通道"
                    if (root.refTextKind === "")
                        return "未绑定参考文本（CSV）\n\n点击下方「CSV」选择文件\n或把 .csv 直接拖进来\n\n建议表头包含：Image, prompt, en_prompt"
                    return "已绑定 CSV，但当前行为空 / 越界\n（视频序号超出 CSV 行数）"
                }
            }

            // 拖拽接收：仅识别 .csv
            DropArea {
                id: refTextDrop
                anchors.fill: parent
                onDropped: function(drop) {
                    if (root.refCurrentFolder.length === 0) {
                        drop.accepted = false; return
                    }
                    if (!drop.hasUrls) { drop.accepted = false; return }
                    for (var i = 0; i < drop.urls.length; ++i) {
                        var u = drop.urls[i]
                        var s = String(u).toLowerCase()
                        if (s.endsWith(".csv")) {
                            if (Reference.setReferenceCsvUrl(root.refCurrentFolder, u)) {
                                drop.accepted = true; return
                            }
                        }
                    }
                    drop.accepted = false
                }
            }
        }

        // 文本进度 / 模式标签
        Rectangle {
            id: refTextModeBar
            anchors.left: refBottomPane.left
            anchors.right: refBottomPane.right
            anchors.bottom: refTextButtonsBar.top
            height: visible ? 22 : 0
            visible: root.refTextHasCurrent
            color: "transparent"
            Label {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignLeft
                elide: Text.ElideRight
                font.pixelSize: 11
                color: "#7fe5cc"
                text: {
                    var p = root.refTextProgress
                    var imgName = root.refTextData && root.refTextData.image ? root.refTextData.image : ""
                    var pre = "📝 跟随对比组"
                    if (p.length > 0) pre += "   ·   " + p
                    if (imgName.length > 0) pre += "   ·   " + imgName
                    return pre
                }
            }
        }

        // 文本区底部按钮：CSV / 中/英 / 清除
        Rectangle {
            id: refTextButtonsBar
            anchors.left: refBottomPane.left
            anchors.right: refBottomPane.right
            anchors.bottom: refBottomPane.bottom
            height: 40
            color: "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                // CSV 按钮：选 csv（已绑定时绿色高亮）
                Button {
                    id: refPickCsvBtn
                    text: "CSV"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 24
                    enabled: root.refCurrentFolder.length > 0
                    hoverEnabled: true
                    onClicked: refSidebarCsvDlg.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择一个 CSV 文件\n参考文本按当前视频在其文件夹中的序号自动同步"
                    background: Rectangle {
                        readonly property bool active: root.refTextKind === "csv"
                        color: !refPickCsvBtn.enabled ? "#1a1a1d"
                              : refPickCsvBtn.down ? "#4a4a55"
                              : refPickCsvBtn.hovered ? "#33333a"
                              : (active ? "#1f2e2a" : "#202024")
                        border.color: !refPickCsvBtn.enabled ? "#2a2a32"
                                      : (active ? "#0fa085" : "#3a3a45")
                        border.width: 1
                        radius: 3
                    }
                    contentItem: Text {
                        text: refPickCsvBtn.text
                        color: !refPickCsvBtn.enabled ? "#555"
                               : (root.refTextKind === "csv" ? "#7fe5cc" : "#e8e8ec")
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // 中 / 英语言切换：仅当两种语言都有时显示
                Button {
                    id: refLangBtn
                    text: root.refTextLang === "zh" ? "中" : "EN"
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 24
                    visible: root.refTextHasBothLangs
                    hoverEnabled: true
                    onClicked: root.refTextLang = (root.refTextLang === "zh" ? "en" : "zh")
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "切换中文 / 英文 prompt"
                    background: Rectangle {
                        color: refLangBtn.down ? "#4a4a55"
                              : refLangBtn.hovered ? "#33333a"
                                                    : "#202024"
                        border.color: "#3a3a45"
                        border.width: 1
                        radius: 3
                    }
                    contentItem: Text {
                        text: refLangBtn.text
                        color: "#e8e8ec"
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // 清除文本绑定
                Button {
                    id: refTextClearBtn
                    text: "清除"
                    Layout.preferredWidth: 56
                    Layout.preferredHeight: 24
                    visible: root.refTextKind === "csv"
                    hoverEnabled: true
                    onClicked: {
                        if (root.refCurrentFolder.length > 0)
                            Reference.clearText(root.refCurrentFolder)
                    }
                    background: Rectangle {
                        color: refTextClearBtn.down ? "#5a2a2a"
                              : refTextClearBtn.hovered ? "#3a2228"
                                                       : "#202024"
                        border.color: "#3a3a42"
                        border.width: 1
                        radius: 3
                    }
                    contentItem: Text {
                        text: refTextClearBtn.text
                        color: "#e8b0b0"
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    // 侧边栏：选择 CSV
    FileDialog {
        id: refSidebarCsvDlg
        title: "选择参考文本 CSV"
        nameFilters: [ "CSV (*.csv)" ]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            Reference.setReferenceCsvUrl(root.refCurrentFolder, selectedFile)
        }
    }

    // 侧边栏：选择单张参考图（image 模式）
    FileDialog {
        id: refSidebarFileDlg
        title: "选择参考图（固定图）"
        nameFilters: [ "图片 (*.png *.jpg *.jpeg *.webp *.bmp *.gif)" ]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            Reference.setReferenceUrl(root.refCurrentFolder, selectedFile)
        }
    }

    // 侧边栏：选择参考图文件夹（folder 模式 → 跟随对比组同步切换）
    FolderDialog {
        id: refSidebarDirDlg
        title: "选择参考图文件夹（跟随对比组）"
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            // 不传 selectedFolder（QUrl）字符串截取，统一用 C++ 端的 URL → path 转换
            if (!Reference.setReferenceFolderUrl(root.refCurrentFolder, selectedFolder)) {
                // 选错了空文件夹时静默失败；提示文字过多反而干扰。
                // 用户能从「占位提示」直接看到"未绑定"再次操作。
            }
        }
    }

    // ─── 视频网格容器 ────────────────────────────────────────────────────
    // 顶部留 2px 余白，避免与 ToolBar 视觉粘连；同时让 cell 的 2px 选中边
    // 框不被 ToolBar 阴影/分隔线压住。
    Item {
        id: videoArea
        anchors.left: refSidebar.right
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

        // 「空白处点击取消选中」底层 MouseArea。
        // 实现思路：与 Grid 同级铺满 videoArea，z=-1 让它垫在最底下；cell 内部的
        // MouseArea 会优先吃掉落在画面里的点击，落到 cell 外（spacing/letterbox/
        // 工具栏下方空白）的点击则会穿到这里 → 清空 selectedIdx。
        // 注意：滑动对比模式下也允许点击取消（无 cell，全空白），无副作用。
        MouseArea {
            anchors.fill: parent
            z: -1
            acceptedButtons: Qt.LeftButton
            onClicked: root.selectedIdx = -1
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
                    // 选中边框：跟随 root.selectedIdx（QML 层显式选中状态），不跟
                    // Engine.activeIndex —— 这样默认 selectedIdx=-1 时不会有任何
                    // cell 被高亮，避免视觉干扰；点击空白也能取消选中。
                    //   - 配色用低饱和雾蓝 #4a6fa5：辨识度足够，但比 #3a7afe 柔和
                    //   - 未选中保持深灰 #222，与原视觉一致
                    //   - 120ms 过渡，切换 / 评分时观感顺滑
                    readonly property bool _isActive: root.selectedIdx === cell.playerIdx
                    border.color: cell._isActive ? "#4a6fa5" : "#222"
                    border.width: 2
                    Behavior on border.color { ColorAnimation { duration: 120 } }

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

                            // 内联评分星条（仅在 root.reviewMode 开启时显示，否则整段 0 宽不占位）：
                            //  · 单击第 N 颗星 → 写入 N 分（与原 cellMenu 内星条一致逻辑）
                            //  · 右键任意位置  → 清空（0 分），方便误评后修正
                            //  · 鼠标悬停时整条变成"预览态"，移开还原当前真实分值
                            // 设计意图：开启评分模式后，5 颗星和"是否已评分"应该在 cell
                            // 上一眼可见，而不是要点 ⋯ 菜单才看见——这条要求来自图 1 / 图 2。
                            Rectangle {
                                visible: root.reviewMode
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 12
                                color: "#55ffffff"
                            }
                            Row {
                                id: inlineStarRow
                                visible: root.reviewMode
                                spacing: 1
                                // 鼠标悬停预览（0 = 未悬停，显示真实分值）。
                                property int hoverRating: 0
                                // 实时读取真实分值；ratingAt 依赖 cellRatings 数组属性，
                                // 整体替换写入会触发绑定刷新。
                                readonly property int currentRating: {
                                    // 显式引用 root.cellRatings 让本绑定依赖它，
                                    // 写分（_writeRating 整体替换数组）后能自动重算。
                                    var arr = root.cellRatings
                                    var i = cell.playerIdx
                                    if (i < 0 || i >= arr.length) return 0
                                    var v = arr[i]
                                    return (typeof v === "number" && v > 0) ? v : 0
                                }
                                Repeater {
                                    model: 5
                                    delegate: Item {
                                        width: 14
                                        height: 14
                                        property int starIndex: index + 1
                                        property bool active: inlineStarRow.hoverRating > 0
                                            ? starIndex <= inlineStarRow.hoverRating
                                            : starIndex <= inlineStarRow.currentRating
                                        Text {
                                            anchors.centerIn: parent
                                            text: parent.active ? "★" : "☆"
                                            color: parent.active ? "#f5c518" : "#bfc4ca"
                                            font.pixelSize: 13
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            onEntered: inlineStarRow.hoverRating = parent.starIndex
                                            onExited:  inlineStarRow.hoverRating = 0
                                            onClicked: function(mouse) {
                                                if (mouse.button === Qt.RightButton) {
                                                    // 右键清空评分（0 = 未评）
                                                    root._writeRating(cell.playerIdx, 0)
                                                } else {
                                                    // 左键写入 N 分（强制覆盖，与 Shift+N 快捷键一致）
                                                    root._writeRating(cell.playerIdx, parent.starIndex)
                                                }
                                                inlineStarRow.hoverRating = 0
                                            }
                                        }
                                    }
                                }
                                ToolTip.visible: inlineStarRow.hoverRating > 0
                                ToolTip.delay: 200
                                ToolTip.timeout: 1500
                                ToolTip.text: "左键打分 · 右键清空"
                            }
                            // 文件名已从胶囊条移除：
                            //   ▸ ⋯ 按钮 hover 时的 ToolTip 直接显示完整路径，区分同名不同目录；
                            //   ▸ 评分入口已迁到顶部内联星条（reviewMode 开启时常驻）。
                            // 【cell hover 工具按钮】两个同风格的圆点：⋯ 替换本路、✕ 关闭本路。
                            // 二者均常驻显示（不随鼠标移出 cell 消失），仅在用户按 C
                            // 关闭通道信息条 / 全屏抑制角标时才隐藏，避免按钮闪烁或定位丢失。
                            //  - ⋯：单击直接进入「替换本路视频」流程；hover 显示完整路径
                            //         （新增一路已在顶部工具栏／下拉菜单提供，cell 内不再重复）
                            //  - ✕：调 Engine.closeAt(idx)，fileCount 变化会触发 visibleCount/Repeater
                            //         重新求值，UI 自动收拢。
                            // ⋯ 按钮：单击直接进入「替换本路视频」流程；
                            // 评分入口已迁到顶部内联星条（reviewMode 开启时常驻），
                            // 不再需要弹出菜单，避免「2.mp4」这类短文件名让弹窗右侧出现大片空白。
                            // hover 时 ToolTip 显示当前路的完整绝对路径，便于在「同名不同目录」场景下区分。
                            Rectangle {
                                id: moreBtn
                                Layout.preferredWidth: 18
                                Layout.preferredHeight: 18
                                Layout.leftMargin: 2
                                radius: 9
                                visible: root.effectiveChannelVisible
                                color: replaceArea.containsMouse ? "#3a78c8"
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
                                        // 直接走替换流程：记下要替换的 idx，弹出文件选择对话框。
                                        root.pendingReplaceIdx = cell.playerIdx
                                        replaceDialog.open()
                                    }
                                }
                                ToolTip.visible: replaceArea.containsMouse
                                ToolTip.delay: 400
                                ToolTip.timeout: 8000
                                // 显示完整路径；用 Engine.titles 作响应式依赖（titles 带 NOTIFY filesChanged），
                                // 切换 / 替换视频后 ToolTip 文本会自动刷新；路径取不到时回退到文件名。
                                ToolTip.text: {
                                    var arr = Engine.titles
                                    var i = cell.playerIdx
                                    var p = Engine.filePathAt(i)
                                    if (p && p.length > 0) return p
                                    return (i >= 0 && i < arr.length) ? arr[i] : "替换本路视频"
                                }
                            }
                            // 【cell hover 工具按钮】放大/还原本路：等价于按数字键 1..9。
                            //   · 当前不是单路视图，或单路视图但聚焦的不是本路 → 进入单路并聚焦本路（=放大）
                            //   · 当前是单路视图且聚焦的就是本路           → 回到上次的多路布局（=还原）
                            // 复用 root._toggleOne(idx)，与数字键完全同一套行为，不重复实现。
                            // 用方框图标 ⤢ / ⤡ 区分两态：放大态显示 ⤡（视觉上"缩回"），多路态显示 ⤢。
                            Rectangle {
                                id: zoomBtn
                                Layout.preferredWidth: 18
                                Layout.preferredHeight: 18
                                Layout.leftMargin: 2
                                radius: 9
                                visible: root.effectiveChannelVisible
                                // 当前是否处于"本路单路放大"态
                                readonly property bool isSolo:
                                    Engine.layoutMode === 0
                                    && Engine.activeIndex === cell.playerIdx
                                color: zoomArea.containsMouse ? "#3a78c8"
                                      : zoomArea.pressed     ? "#2a5994"
                                                             : "#55ffffff"
                                Behavior on color { ColorAnimation { duration: 90 } }
                                Text {
                                    anchors.centerIn: parent
                                    // ⤢ = 放大（four arrows out）；⤡ = 缩回（arrows in）
                                    // 这两个 Unicode 在大部分平台都有完整字形，无需依赖 SF Symbols。
                                    text: zoomBtn.isSolo ? "⤡" : "⤢"
                                    color: "white"
                                    font.pixelSize: 12
                                    font.bold: true
                                }
                                MouseArea {
                                    id: zoomArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root._toggleOne(cell.playerIdx)
                                }
                                ToolTip.visible: zoomArea.containsMouse
                                ToolTip.delay: 400
                                ToolTip.timeout: 3000
                                ToolTip.text: zoomBtn.isSolo
                                              ? "还原多路布局（同：再按数字键）"
                                              : "放大本路（等同按数字键 " + (cell.playerIdx + 1) + "）"
                            }
                            // 关闭本路的 ✕ 按钮：常驻显示（不随 hover 消失），仅当用户按 C
                            // 关闭通道信息条 / 全屏抑制角标时才隐藏，与同一行的 #idx·时间·文件名
                            // 信息条共用一套可见性，避免鼠标在 ⋯/✕ 与 cell 边缘之间
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

                    // 评分入口已迁至顶部胶囊条 channelBar 的内联星条（reviewMode 开启时常驻显示），
                    // ⋯ 按钮单击即触发替换流程，不再需要中间的 Popup 菜单。
                    // 这样可避免短文件名（如 "2.mp4"）导致弹窗右侧大片空白；
                    // 同时三点按钮的 ToolTip 已直接显示完整路径，便于区分同名不同目录。

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
                                root.selectedIdx   = cell.playerIdx   // 同步 UI 选中态
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

        // ─── 空状态欢迎面板 ─────────────────────────────────────────
        //   仅在 Engine.fileCount <= 0 时显示；一旦有视频自动隐藏，
        //   不与 Grid 视图、SliderCompareView 共享任何状态，零功能侵入。
        //
        //   组成：
        //     · 大标题 / 副标题（说明软件用途）
        //     · 两个大按钮：① 打开文件   ② 打开文件夹 / 多组对比
        //       直接复用顶部菜单同款入口（addDialog.open / multiGroupDialog.show），
        //       不重复任何打开逻辑。
        //     · DropArea 全覆盖：支持文件 + 文件夹拖拽
        //         - 视频文件：直接进入 selectedFiles 队列
        //         - 文件夹：用 Fs.scanVideoFolder 递归展开为视频文件
        //         - 混合：一起合并、最多取前 9 个，调 Engine.openFiles
        //     · 操作说明（快捷键、批量上限提示等）
        Item {
            id: emptyHero
            anchors.fill: parent
            visible: Engine.fileCount <= 0 && !root.compareSliderActive

            // 拖拽高亮态：DropArea 进入时整块面板加柔和高亮边框
            property bool dragHover: dropZone.containsDrag

            // 半透明遮罩：让欢迎面板与窗口主体的纯黑稍稍区分开
            Rectangle {
                anchors.fill: parent
                color: emptyHero.dragHover ? "#1a3a78c8" : "transparent"
                Behavior on color { ColorAnimation { duration: 140 } }
            }

            // 拖入时的虚线高亮边框（不挡点击，纯视觉反馈）
            Rectangle {
                anchors.fill: parent
                anchors.margins: 12
                color: "transparent"
                radius: 12
                border.color: emptyHero.dragHover ? "#3a78c8" : "transparent"
                border.width: 2
                Behavior on border.color { ColorAnimation { duration: 140 } }
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 24
                width: Math.min(parent.width - 80, 720)

                // 标题
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "PlayerX"
                    color: "#e8e8ec"
                    font.pixelSize: 36
                    font.bold: true
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "多路视频对比 · 同步播放 · 评分采集"
                    color: "#9aa0a6"
                    font.pixelSize: 14
                }

                // ── 两个大按钮 ─────────────────────────────────────
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 18

                    // ① 打开文件
                    Rectangle {
                        id: heroBtnFile
                        Layout.preferredWidth: 240
                        Layout.preferredHeight: 132
                        radius: 10
                        color: heroBtnFileMA.containsMouse ? "#2a3a55"
                              : heroBtnFileMA.pressed     ? "#1e2a40"
                                                          : "#1e1e22"
                        border.color: heroBtnFileMA.containsMouse ? "#3a78c8" : "#3a3a42"
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Behavior on border.color { ColorAnimation { duration: 120 } }

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 8
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "🎬"
                                font.pixelSize: 36
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "打开文件"
                                color: "#e8e8ec"
                                font.pixelSize: 16
                                font.bold: true
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "选择 1-9 个视频文件"
                                color: "#9aa0a6"
                                font.pixelSize: 12
                            }
                        }

                        MouseArea {
                            id: heroBtnFileMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: addDialog.open()
                        }
                    }

                    // ② 打开文件夹 / 多组对比
                    Rectangle {
                        id: heroBtnFolder
                        Layout.preferredWidth: 240
                        Layout.preferredHeight: 132
                        radius: 10
                        color: heroBtnFolderMA.containsMouse ? "#2a3a55"
                              : heroBtnFolderMA.pressed     ? "#1e2a40"
                                                            : "#1e1e22"
                        border.color: heroBtnFolderMA.containsMouse ? "#3a78c8" : "#3a3a42"
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Behavior on border.color { ColorAnimation { duration: 120 } }

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 8
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "📁"
                                font.pixelSize: 36
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "打开文件夹"
                                color: "#e8e8ec"
                                font.pixelSize: 16
                                font.bold: true
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "整文件夹载入 / 多组对比"
                                color: "#9aa0a6"
                                font.pixelSize: 12
                            }
                        }

                        MouseArea {
                            id: heroBtnFolderMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: multiGroupDialog.showAndRefresh()
                        }
                    }
                }

                // ── 操作说明 ──────────────────────────────────────
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 498   // 240*2 + 18 ，与按钮组对齐
                    color: "#14141820"
                    radius: 8
                    border.color: "#2a2a32"
                    border.width: 1
                    implicitHeight: tipsCol.implicitHeight + 24

                    ColumnLayout {
                        id: tipsCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        spacing: 6

                        Text {
                            text: emptyHero.dragHover
                                  ? "🎯 松开鼠标即可载入"
                                  : "💡 也可以直接把视频文件或文件夹 拖入此窗口"
                            color: emptyHero.dragHover ? "#6aa8ff" : "#cfd2d6"
                            font.pixelSize: 13
                            font.bold: emptyHero.dragHover
                        }
                        Text {
                            text: "·  支持 mp4 / mov / mkv / avi / webm / flv / ts / m4v / wmv，最多同时载入 9 路"
                            color: "#9aa0a6"
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                        // ── 速览：四组高频快捷键（分组 + 等宽按键徽章）──
                        //    完整列表见「帮助 → 快捷键…」或按 F1 / ?。
                        //    `_modKey` 在 macOS 上自动显示 ⌘，其它平台显示 Ctrl。
                        GridLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            columns: 2
                            columnSpacing: 28
                            rowSpacing: 6

                            // 文件
                            RowLayout {
                                spacing: 8
                                Text { text: "打开";       color: "#cfd2d6"; font.pixelSize: 12; Layout.preferredWidth: 56 }
                                Text { text: root._modKey + "O"; color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                                Text { text: "·"; color: "#5a5a62"; font.pixelSize: 12 }
                                Text { text: root._modKey + "⇧O"; color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                            }
                            // 播放
                            RowLayout {
                                spacing: 8
                                Text { text: "播放";       color: "#cfd2d6"; font.pixelSize: 12; Layout.preferredWidth: 56 }
                                Text { text: "Space";       color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                                Text { text: "·"; color: "#5a5a62"; font.pixelSize: 12 }
                                Text { text: "← →";        color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                                Text { text: "·"; color: "#5a5a62"; font.pixelSize: 12 }
                                Text { text: ", .";         color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                            }
                            // 视图
                            RowLayout {
                                spacing: 8
                                Text { text: "视图";       color: "#cfd2d6"; font.pixelSize: 12; Layout.preferredWidth: 56 }
                                Text { text: "F";  color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                                Text { text: "·"; color: "#5a5a62"; font.pixelSize: 12 }
                                Text { text: "V/C"; color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                                Text { text: "·"; color: "#5a5a62"; font.pixelSize: 12 }
                                Text { text: "S";  color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                                Text { text: "·"; color: "#5a5a62"; font.pixelSize: 12 }
                                Text { text: "B";  color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                            }
                            // 路数 / 倍速
                            RowLayout {
                                spacing: 8
                                Text { text: "路 / 速";   color: "#cfd2d6"; font.pixelSize: 12; Layout.preferredWidth: 56 }
                                Text { text: "1…9"; color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                                Text { text: "·"; color: "#5a5a62"; font.pixelSize: 12 }
                                Text { text: "− = 0"; color: "#9aa0a6"; font.pixelSize: 12; font.family: "Menlo, Consolas, monospace" }
                            }
                        }
                        // 入口：跳转到「快捷键…」对话框
                        Item {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            implicitHeight: 18
                            Text {
                                id: shortcutsLink
                                anchors.right: parent.right
                                text: "查看全部快捷键 →   (F1)"
                                color: shortcutsLinkMA.containsMouse ? "#6aa8ff" : "#7a7f86"
                                font.pixelSize: 12
                                font.underline: shortcutsLinkMA.containsMouse
                            }
                            MouseArea {
                                id: shortcutsLinkMA
                                anchors.fill: shortcutsLink
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: shortcutsDialog.open()
                            }
                        }
                    }
                }
            }

            // ── 拖拽落区：必须放在最后（z 序最高），覆盖整个空状态区域 ──
            //   只在 fileCount==0 时存在，载入视频后该 Item 整体 visible=false。
            //   既不会在播放期间误触发，也不会与 Grid 内的事件抢截。
            DropArea {
                id: dropZone
                anchors.fill: parent

                // 仅接受带 url 的拖拽（文件/文件夹）
                onEntered: function(drag) {
                    if (!drag.hasUrls) { drag.accepted = false; return }
                    drag.accept(Qt.CopyAction)
                }

                onDropped: function(drop) {
                    if (!drop.hasUrls) return

                    // 视频扩展名白名单（与 FileDialog 保持一致）
                    var exts = ["mp4","mov","mkv","avi","webm","flv","ts","m4v","wmv"]
                    function hasVideoExt(p) {
                        var s = String(p).toLowerCase()
                        var dot = s.lastIndexOf(".")
                        if (dot < 0) return false
                        var ext = s.substring(dot + 1)
                        return exts.indexOf(ext) >= 0
                    }

                    // ── 第一遍：把拖入项分流为「文件夹组」与「散文件组」──
                    // 文件夹判定方式：先用 Fs.scanVideoFolder 试扫，能扫出视频则认定为文件夹。
                    // 这样既覆盖目录拖拽，又不会把"含视频后缀但实际是文件"的项误判为文件夹。
                    var folderUrls   = []   // 仅"扫出视频"的文件夹的 url 原样
                    var fileFromDirs = []   // 文件夹展开后的视频文件路径（散文件兜底用）
                    var standaloneFiles = []  // 直接拖入的视频散文件 url

                    for (var i = 0; i < drop.urls.length; ++i) {
                        var u = drop.urls[i]
                        var s = String(u)
                        var scanned = []
                        try { scanned = Fs.scanVideoFolder(u, true) } catch (e) { scanned = [] }

                        if (scanned && scanned.length > 0) {
                            folderUrls.push(u)
                            for (var j = 0; j < scanned.length; ++j) fileFromDirs.push("file://" + scanned[j])
                        } else if (hasVideoExt(s)) {
                            standaloneFiles.push(s)
                        }
                    }

                    // ── 拖入含文件夹 → 直接打开 MultiGroupDialog（等同点击"打开文件夹"）──
                    //   · 拖入的文件夹默认勾选；历史文件夹默认不勾选（由 addFoldersAndShow 保证）
                    //   · 不再静默 "loadFolders 立即播放"，而是把选择权交给用户：
                    //     在 Dialog 里确认勾选后点击"开始/确认"再启动播放。
                    //   · 混合（文件夹 + 散文件）时，文件夹优先 → 走 Dialog；散文件被忽略（语义不明）。
                    if (folderUrls.length > 0) {
                        try { multiGroupDialog.addFoldersAndShow(folderUrls) } catch (e) {}
                        return
                    }

                    // ── 仅散文件场景：保留"直接铺开播放"的旧体验 ──
                    var collected = []
                    for (var m = 0; m < standaloneFiles.length && collected.length < 9; ++m) {
                        collected.push(standaloneFiles[m])
                    }

                    if (collected.length === 0) return
                    if (collected.length > 9) collected = collected.slice(0, 9)
                    Engine.openFiles(collected)
                }
            }
        }

        // ─── 播放期间拖拽落区：仅"加入历史"，不打断当前播放 ─────────
        //   场景：用户在视频已经播放时把若干文件夹从 Finder/Explorer 拖进来，
        //         期望"打开文件夹/多组对比"对话框里能看到这些新文件夹。
        //   设计：
        //     · 仅在 Engine.fileCount > 0（即播放中）启用，与 emptyHero/dropZone 互斥；
        //     · 仅识别"文件夹"，散视频文件不进历史（与产品需求一致）；
        //     · 不调用 Engine.openFiles 也不切换正在播放的视频，仅追加到 MultiGroupDialog
        //       的 lanes 历史并持久化（addFoldersToHistory 内部去重）；
        //     · 完成后用 _showRatingWarn 给一个轻量 toast 反馈（复用现有 toast 通道）。
        //   注意：DropArea 默认对鼠标事件透明，覆盖整个 videoArea 不会影响点击/滚动。
        DropArea {
            id: liveDropZone
            anchors.fill: parent
            visible: Engine.fileCount > 0
            enabled: visible
            z: 50  // 高于 cell 网格但低于 ratingToast(z:999)，纯拖拽用，不影响鼠标

            onEntered: function(drag) {
                if (!drag.hasUrls) { drag.accepted = false; return }
                drag.accept(Qt.CopyAction)
            }

            onDropped: function(drop) {
                if (!drop.hasUrls) return

                // 仅采集"能扫出视频"的文件夹；散文件忽略（不入历史也不打断当前播放）
                var folderUrls = []
                for (var i = 0; i < drop.urls.length; ++i) {
                    var u = drop.urls[i]
                    var scanned = []
                    try { scanned = Fs.scanVideoFolder(u, true) } catch (e) { scanned = [] }
                    if (scanned && scanned.length > 0) folderUrls.push(u)
                }

                if (folderUrls.length === 0) {
                    // 拖进来的全是散文件 / 空文件夹 / 无视频 → 静默忽略
                    return
                }

                // 拖入文件夹 → 直接打开 MultiGroupDialog（等同点击"打开文件夹"）：
                //   · 拖入的文件夹默认勾选；历史文件夹默认不勾选；
                //   · 不打断当前正在播放的视频，由用户在 Dialog 里确认后再启动新播放。
                try { multiGroupDialog.addFoldersAndShow(folderUrls) } catch (e) {}
            }
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

        // ─── 评分提示 Toast（屏幕中央浮层）───────────────────
        // 快捷键评分时在屏幕中央弹一个带颜色的圆角卡片，让用户一眼识别：
        //   - 打了几星、落到哪一路（避免在多路网格中误诸6）
        //   - 分数高低用语义色区分：金色=5、绿=4、蓝=3、橙=2、红=1（与集成市场上
        //     常见的评分卡一致）
        //   - "清除"用中性灰、"提示未选中"用警警色（橙色）
        // 仅装饰性，不拦截鼠标；show() 重置定时，连按不闪烁。
        Item {
            id: ratingToast
            anchors.centerIn: parent
            width: toastBg.implicitWidth
            height: toastBg.implicitHeight
            opacity: 0
            visible: opacity > 0.01
            z: 999

            function show() {
                hideTimer.restart()
                fadeIn.restart()
            }

            // 根据 kind/score 计算主色（边框+文字）与背景调。
            // dd 前缀 = ~87% 透明度的 ARGB，不遮住背后画面。
            readonly property color _accent: {
                if (root.ratingToastKind === "warn")  return "#fa8c16"
                if (root.ratingToastKind === "clear") return "#9aa0a6"
                switch (root.ratingToastScore) {
                case 5: return "#ffcc33"  // 金
                case 4: return "#52c41a"  // 绿
                case 3: return "#4a8fe7"  // 蓝
                case 2: return "#fa8c16"  // 橙
                case 1: return "#f5222d"  // 红
                }
                return "#9aa0a6"
            }

            Rectangle {
                id: toastBg
                anchors.centerIn: parent
                radius: 12
                // 背景 = 主色其于二成透明叠在深黑上：发光感 + 保证可读
                color: "#e61b1b22"
                border.color: ratingToast._accent
                border.width: 2
                implicitWidth:  toastLabel.implicitWidth + 40
                implicitHeight: toastLabel.implicitHeight + 24

                // 内部柔和色晕：用与边框同色、低透明度的 Rectangle 模拟染色背景。
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: 10
                    color: ratingToast._accent
                    opacity: 0.16
                }

                Label {
                    id: toastLabel
                    anchors.centerIn: parent
                    text: root.ratingToastText
                    color: ratingToast._accent
                    font.pixelSize: 22
                    font.bold: true
                    // 轻微阴影让彩色文字在染色背景上仍足够锐利
                    style: Text.Raised
                    styleColor: "#000000"
                }
            }
            NumberAnimation on opacity {
                id: fadeIn
                from: 0; to: 1
                duration: 140
                easing.type: Easing.OutCubic
                running: false
            }
            NumberAnimation on opacity {
                id: fadeOut
                from: 1; to: 0
                duration: 280
                easing.type: Easing.InCubic
                running: false
            }
            Timer {
                id: hideTimer
                interval: 880
                repeat: false
                onTriggered: fadeOut.restart()
            }
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

        // ── 评分模式回调注入 ───────────────────────────────────
        // 由 dlg 内部在 reviewMode=true 时调用，决定当前组未评分的通道索引列表。
        // 这里复用主窗 cellRatings + Engine.fileCount，安全且零侵入。
        unratedChecker: function() {
            var miss = []
            var n = Engine.fileCount
            for (var i = 0; i < n; ++i) {
                if (root.ratingAt(i) <= 0) miss.push(i)
            }
            return miss
        }
        // 提示弹窗用：把 idx 转成"通道 N · 文件名"展示
        getCellLabel: function(idx) {
            var name = ""
            try { name = Engine.fileNameAt(idx) || "" } catch (e) { name = "" }
            return "通道 " + (idx + 1) + (name ? " · " + name : "")
        }
        // 用户点"去评分"时：关闭对话框后聚焦主窗，方便立即按 Shift+1~5 评分
        onGoToRate: function() {
            // 主窗在最前 → 快捷键能直接命中
            try { root.requestActivate() } catch (e) {}
        }
        // 提醒弹窗内联评分写入：复用主窗 _writeRating，自动持久化 + Toast 反馈也走同一条路。
        setRatingAt: function(idx, score) {
            try { root._writeRating(idx, score) } catch (e) {}
        }
    }

    // 把对话框里的「开启评分」勾选项反向同步到主窗 root.reviewMode：
    // 这是单向绑定（dlg → root），目的是让顶部胶囊条 channelBar 能据此
    // 切换"是否常驻显示 5 颗星"。Binding 比 Connections 更直观、且能在
    // dlg 还未实例化时安全求值（initial false → 默认隐藏星条）。
    Binding {
        target: root
        property: "reviewMode"
        value: multiGroupDialog.reviewMode
    }

    // ─── 评分数据查看 / 导出 / 清空面板 ───────────────────────
    // 仅在「文件 ▸ 评分数据…」时 open()；与播放完全解耦。
    RatingsDialog {
        id: ratingsDialog
        visible: false
        transientParent: root
    }

    // 全局进度条已移除：多路场景下各路独立播放控制，全局进度条语义
    // 不明。进度跳转请使用各路 cell 悬浮工具条上的单路进度条。
}
