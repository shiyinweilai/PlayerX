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

    // ─── 全局 ToolTip 主题（深色半透明 + 浅字 + 圆角，统一观感）──────────────
    // Qt 的 ToolTip.attached 共享同一个全局 popup 实例（QQuickToolTipAttached.sharedTip）。
    // 因此只要在窗口创建时一次性修改其 background.color 与 contentItem.color，
    // 后续 50+ 处的 `ToolTip.text/visible` 附加属性都会自动套用此暗色主题，
    // 不需要逐处改写 background/contentItem，最大限度避免破坏既有功能。
    Component.onCompleted: {
        try {
            var tip = ToolTip.toolTip
            if (tip) {
                if (tip.background) {
                    tip.background.color = "#cc1a1a1f"           // 半透明深色（伪毛玻璃）
                    if (tip.background.border !== undefined) {
                        tip.background.border.color = "#33ffffff"
                        tip.background.border.width = 1
                    }
                    tip.background.radius = 6
                }
                if (tip.contentItem) {
                    tip.contentItem.color = "#e8e8ec"            // 浅色文字
                }
            }
        } catch (e) {
            console.log("[ToolTip][theme] init failed:", e)
        }
        // 初始化手机模式校准系数（按当前 Screen.width 查表，跟随系统显示档位变化）
        root._applyAutoPhoneScale()

        // 加载多维度评分配置
        // 策略：优先从本地缓存文件加载（零延迟，不阻塞启动），
        //       加载完成后立即后台静默检测远程配置是否有更新。
        //       有更新时弹出通知卡片，用户主动点击后才应用，不阻塞任何操作。
        // macOS: PlayerX.app/Contents/Resources/dimensions.json
        // 其他:  可执行文件同级目录 dimensions.json
        function _loadDimensions(url, fallbackUrl) {
            var xhr2 = new XMLHttpRequest()
            xhr2.onreadystatechange = function() {
                if (xhr2.readyState !== XMLHttpRequest.DONE) return
                if (xhr2.status === 200 || xhr2.status === 0) {
                    try {
                        var obj = JSON.parse(xhr2.responseText)
                        if (obj && Array.isArray(obj.dimensions) && obj.dimensions.length > 0) {
                            // 预注入 starCount，避免 Repeater delegate 依赖深层 levels.length 动态计算
                            var _dims0 = obj.dimensions.map(function(d) {
                                var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                                return Object.assign({}, d, { starCount: sc })
                            })
                            root.reviewDimensions = _dims0
                            // 同步 tag
                            if (obj.tag && typeof Rating !== "undefined") {
                                Rating.uploadTag = obj.tag
                            }
                            root._remoteTag = obj.tag || ""
                            return
                        }
                    } catch (e) {}
                }
                // 加载失败且还有 fallback，尝试 fallback
                if (fallbackUrl) _loadDimensions(fallbackUrl, null)
                // 本地无缓存，configInitCheckTimer 会在 1.5s 后触发首次检测
            }
            xhr2.open("GET", url)
            xhr2.send()
        }
        // 构建 bundle Resources 路径
        var exePath = Qt.application.arguments[0]  // 如 .../PlayerX.app/Contents/MacOS/PlayerX
        var resourcesUrl = ""
        if (Qt.platform.os === "osx") {
            var macosDir = exePath.substring(0, exePath.lastIndexOf("/"))  // .../Contents/MacOS
            var contentsDir = macosDir.substring(0, macosDir.lastIndexOf("/"))  // .../Contents
            resourcesUrl = "file://" + contentsDir + "/Resources/dimensions.json"
        } else {
            var binDir = exePath.substring(0, exePath.lastIndexOf("/"))
            resourcesUrl = "file://" + binDir + "/dimensions.json"
        }
        // 直接从本地缓存加载（不再优先走网络），后台差异检测由 _checkRemoteConfigUpdate 负责
        _loadDimensions(resourcesUrl, null)
    }

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

            // ── 单路悬停控制条（与下方自绘菜单同步，无快捷键）──
            MenuItem {
                text: qsTr("单路悬停控制条")
                checkable: true
                checked: root.singleControlsHoverEnabled
                onTriggered: root.singleControlsHoverEnabled = !root.singleControlsHoverEnabled
            }

            // ── 自动重播（播放结束后无缝从头继续，与下方自绘菜单同步）──
            // 默认开启；关闭时回退到旧行为：播放结束停在最后一帧。
            MenuItem {
                text: qsTr("自动重播")
                checkable: true
                checked: Engine.loopEnabled
                onTriggered: Engine.loopEnabled = !Engine.loopEnabled
            }

            MenuSeparator {}

            // ── 打开日志目录 ──（与下方自绘菜单同名条目联动；调用同一个 Fs API）
            MenuItem {
                text: qsTr("打开日志目录")
                onTriggered: Fs.revealInFileManager(Fs.appLogDir())
            }

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

    // ─── "更新可用"胶囊按钮已迁移到底部工具栏（参考图按钮右侧），
    //      避免浮在右上角遮挡视频画面/控制条。具体实现见 RowLayout 内 refUpdateBtn。

    // ─── 启动自检策略：500ms 首次尝试，失败后 3s 自动重试一次 ──────────────
    // 设计：首次 500ms 发起（UI 已渲染完成），若网络未就绪导致失败，
    //       retryTimer 会在 3s 后补发一次；成功或用户手动触发后不再重试。
    property bool _autoCheckRetried: false   // 是否已重试过，防止无限重试

    Timer {
        id: updateAutoCheckTimer
        interval: 500
        running: true
        repeat: false
        onTriggered: Updater.checkForUpdates(true)
    }

    // 首次失败后的重试定时器（仅触发一次）
    Timer {
        id: updateRetryTimer
        interval: 3000
        running: false
        repeat: false
        onTriggered: {
            root._autoCheckRetried = true
            Updater.checkForUpdates(true)
        }
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
        // 已是最新版 / 网络错误：仅在用户手动点了"检查更新"时弹 toast；
        // 静默自检失败且尚未重试过 → 启动重试定时器
        function onCheckFailed(reason) {
            if (updateDialog.userInitiated) {
                updateToast.text = reason
                updateToast.open()
            } else if (!root._autoCheckRetried) {
                // 静默首次失败，3s 后重试一次
                updateRetryTimer.restart()
            }
        }
        // 远端 latest.json 下发了新的客户端上传配置 → 静默更新本地存储
        function onClientConfigChanged() {
            if (typeof Rating === "undefined") return
            var newUrl   = Updater.clientUploadUrl
            var newToken = Updater.clientToken
            if (!newUrl || newUrl.trim().length === 0) return
            // 只在有实际变化时才写入，避免无意义的持久化触发
            if (newUrl.trim()   !== (Rating.uploadServerUrl || "").trim() ||
                newToken.trim() !== (Rating.uploadToken     || "").trim()) {
                Rating.uploadServerUrl = newUrl.trim()
                Rating.uploadToken     = newToken.trim()
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
                ScRow { keys: "S"; desc: qsTr("多路视频时切换布局如1xN / 2x2 / 3x3") }
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
                ScRow { keys: "Ctrl+↑"; desc: qsTr("上一组 windows是command+↑") }
                ScRow { keys: "Ctrl+↓"; desc: qsTr("下一组 windows是command+↓") }
            }
            // 右列 3：视图缩放 / 平移（所有路同步）
            //   滚轮以鼠标位置为锚点缩放；右键按住拖拽同步平移；
            //   Ctrl+双击 或 底部 ⊙ 按钮 复位（缩放/平移归零）。
            ScSection {
                title: qsTr("视图缩放 / 平移（所有路同步）")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: qsTr("鼠标滚轮");    desc: qsTr("以鼠标位置为锚点缩放（0.2× ~ 8×）") }
                ScRow { keys: qsTr("右键拖拽");    desc: qsTr("同步平移所有路（画面跟随鼠标方向）") }
                ScRow { keys: qsTr("Ctrl+双击");   desc: qsTr("视图复位（缩放/平移归零）") }
                ScRow { keys: "⊙";              desc: qsTr("底部工具栏 视图复位按钮") }
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

    // ─── 任务配置更新通知卡片 ─────────────────────────────────────────────
    // 后台检测到远程配置有更新时浮现，用户点击后逐条应用，不阻塞任何操作。
    // 位置：左下角，常驻按钮上方。
    Popup {
        id: taskUpdateCard
        visible: root._taskUpdateVisible
        modal: false
        focus: false
        closePolicy: Popup.NoAutoClose
        x: 16
        y: root.height - height - 56
        padding: 0
        implicitWidth: 280

        background: Rectangle {
            color: "#cc1a1a1f"
            border.color: "#33ffffff"
            border.width: 1
            radius: 6
        }

        contentItem: Column {
            spacing: 0

            // 标题行
            RowLayout {
                width: 280
                height: 36
                spacing: 6

                Item { width: 12 }  // 左边距

                Text {
                    text: "🔔"
                    font.pixelSize: 14
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    text: "远程有新任务配置"
                    color: "#e8e8ec"
                    font.pixelSize: 13
                    font.bold: true
                    Layout.alignment: Qt.AlignVCenter
                    Layout.fillWidth: true
                }
                // 关闭按钮（只隐藏，不清空数据，可通过常驻按钮再次打开）
                Text {
                    text: "✕"
                    color: "#888"
                    font.pixelSize: 12
                    Layout.alignment: Qt.AlignVCenter
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._taskUpdateVisible = false
                    }
                }
                Item { width: 8 }  // 右边距
            }

            // 分隔线
            Rectangle { width: 280; height: 1; color: "#33ffffff" }

            // 每个待更新配置一行：左边类型+tag，右边独立应用按钮
            Repeater {
                model: Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig : []
                delegate: Item {
                    width: 280
                    height: 44

                    // 悬停背景
                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: 1
                        anchors.rightMargin: 1
                        color: rowHover.containsMouse ? "#14ffffff" : "transparent"
                        radius: 3
                    }
                    HoverHandler { id: rowHover }

                    // 左侧：类型 + tag
                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: applyBtn.left
                        anchors.rightMargin: 8
                        spacing: 2

                        Text {
                            width: parent.width
                            text: {
                                var obj  = modelData.obj || {}
                                var type = obj.type || ""
                                var tag  = obj.tag  || ""
                                if (type.length > 0 && tag.length > 0) return type + "  ·  " + tag
                                if (type.length > 0) return type
                                if (tag.length  > 0) return tag
                                return modelData.mode
                            }
                            color: "#e8e8ec"
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            text: {
                                var ml = (typeof Rating !== "undefined" && Rating.modeList) ? Rating.modeList : []
                                for (var i = 0; i < ml.length; i++) {
                                    if (ml[i].id === modelData.mode) return ml[i].label
                                }
                                return modelData.mode
                            }
                            color: "#6a6a7c"
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }

                    // 右侧：应用按钮
                    Rectangle {
                        id: applyBtn
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 52
                        height: 26
                        radius: 4
                        color: applyMouse.containsMouse ? "#0db092" : "#0fa085"

                        Text {
                            anchors.centerIn: parent
                            text: "应用"
                            color: "#ffffff"
                            font.pixelSize: 11
                            font.bold: true
                        }

                        MouseArea {
                            id: applyMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._applyRemoteConfigItem(modelData)
                        }
                    }

                    // 行分隔线（最后一行不显示）
                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        height: 1
                        color: "#22ffffff"
                        visible: index < (Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig.length - 1 : 0)
                    }
                }
            }

            // 底部间距
            Item { width: 280; height: 6 }
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

    // ─── 子组件透传接口（为 VideoCellDelegate 等抽离组件提供稳定入口） ──
    //   抽离子组件后，子组件通过 viewRoot.* 访问 Main 内部 id。这里把
    //   "替换本路 / slot→player 索引 / 视频区抢焦点" 三个最常用的内部
    //   交互封装成纯函数，避免子组件直接依赖 videoArea / replaceDialog 这些
    //   Main 私有 id。新增图片模式 / 其他媒体模式时复用同一组接口即可。
    function openReplaceFor(idx) {
        // 等价于原 delegate 内的两步：root.pendingReplaceIdx = idx; replaceDialog.open()
        pendingReplaceIdx = idx
        replaceDialog.open()
    }
    function slotPlayerIndex(slot) {
        // 等价于原 delegate 内 videoArea.slotPlayerIndex(index)
        return videoArea.slotPlayerIndex(slot)
    }
    function focusVideoArea() {
        // 等价于原 delegate 内 videoArea.forceActiveFocus()
        videoArea.forceActiveFocus()
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

    // 全局"单路悬停控制条"开关（设置菜单控制，无快捷键）。
    // 默认 false：鼠标悬停在某路视频上时，**不**显示该路自己的悬浮播放
    // 控制条（避免在多路对比时遮挡画面）。仅在用户主动开启此开关后，
    // VideoCellDelegate 内的 cellBar（单路 ◀▶/进度条/帧步/重置）才会
    // 在 hover 时浮现。底部的全局控制条不受此开关影响。
    property bool singleControlsHoverEnabled: false

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
    // 真值由 Rating.currentMode 派生：mode != "off" 即为评分态；
    // 这里通过 readonly + 访问 Rating.currentMode 让顶部胶囊条 channelBar
    // 能根据它决定是否常驻显示星条（未开启 → 隐藏；已开启 → 直接把星条挂在
    // #帧号 · 时间戳 旁边，所有 cell 一眼可见）。
    // 默认 false：不打扰只看视频、不评分的常规使用。
    readonly property bool reviewMode:
        (typeof Rating !== "undefined") && Rating.currentMode !== "off"
    // 当前评分模式的星级上限（UI 渲染与快捷键均依赖它）。
    // off 模式 maxStars=0，但本处仅供UI使用；UI 上 reviewMode=false 会隐藏星条。
    readonly property int reviewMaxStars:
        (typeof Rating !== "undefined") ? Rating.maxStars : 5

    // ── 多维评分（multi_dim）专用 ──
    // 是否处于多维评分模式
    readonly property bool isMultiDimMode:
        (typeof Rating !== "undefined") && Rating.currentMode === "multi_dim"
    // 维度列表（启动时从服务器/本地文件动态加载，初始为空）
    property var reviewDimensions: []
    // 远程激活配置的 tag（加载维度时同步写入，供上传时校验用）
    property string _remoteTag: ""

    // ── 任务配置后台差异检测 ──────────────────────────────────────────────
    // 设计：启动时先用本地缓存初始化（零延迟），后台静默拉取远程配置做指纹对比。
    // 有差异时弹出通知卡片，用户主动点击后才应用远程配置，不阻塞任何操作。
    // 轮询间隔：5 分钟（软件运行期间持续检测）。

    // 本地已应用配置的指纹映射 { mode -> fingerprint }（用于与远程对比）
    property var    _localConfigFingerprint: ({})
    // 待应用的远程配置列表（检测到差异时暂存，等用户点击通知卡片后才应用）
    // 每项：{ mode, obj, configName }
    property var    _pendingRemoteConfig: null
    // 通知卡片是否可见
    property bool   _taskUpdateVisible: false

    // 计算配置指纹：全量 JSON 序列化，任何字段变化都能检测到
    function _configFingerprint(obj) {
        if (!obj) return ""
        try {
            return JSON.stringify(obj)
        } catch (e) { return "" }
    }

    // 后台静默检测所有模式的远程配置是否有更新（不影响当前已加载的配置）
    // 流程：先拉 /api/active-config 获取所有模式绑定，再并发请求每个配置内容，
    //       任意一个模式与本地指纹不同，就弹出通知卡片。
    function _checkRemoteConfigUpdate(onNoUpdate) {
        var base = root._dimApiUrl()
        if (base.length === 0) return  // 未配置服务器，跳过

        // 第一步：拉取所有模式绑定
        var activeUrl = base.replace(/\/api\/dimensions.*$/, '') + "/api/active-config"
        var xhr0 = new XMLHttpRequest()
        var _done0 = false
        var _t0 = Qt.createQmlObject('import QtQuick 2.0; Timer { interval: 8000; repeat: false }', root)
        _t0.triggered.connect(function() { if (!_done0) { _done0 = true; xhr0.abort() } _t0.destroy() })
        _t0.start()
        xhr0.onreadystatechange = function() {
            if (xhr0.readyState !== XMLHttpRequest.DONE) return
            if (_done0) return
            _done0 = true
            _t0.stop()
            if (xhr0.status !== 200 && xhr0.status !== 0) return
            try {
                var activeObj = JSON.parse(xhr0.responseText)
                if (!activeObj || !activeObj.bindings) return
                var bindings = activeObj.bindings  // { mode -> configName }
                var modes = Object.keys(bindings)
                if (modes.length === 0) return

                // 对比绑定关系是否发生变化（用 JSON.stringify 排序后对比）
                var sortedBindings = {}
                modes.slice().sort().forEach(function(m) { sortedBindings[m] = bindings[m] })
                var bindingsFp = JSON.stringify(sortedBindings)
                var localBindingsFp = (root._localConfigFingerprint || {})["__bindings__"] || ""

                // 第二步：并发请求每个绑定配置的内容
                var configBase = base.replace(/\/api\/dimensions.*$/, '') + "/api/configs/"
                var pending = []   // 收集有差异的 { mode, obj, configName }
                var total = modes.length
                var finished = 0

                function onAllDone() {
                    if (pending.length === 0) {
                        // 无更新：回调通知调用方
                        if (typeof onNoUpdate === "function") onNoUpdate()
                        return
                    }
                    // 有差异：合并到已有列表（避免覆盖用户已部分应用的条目）
                    var existing = Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig : []
                    var merged = existing.slice()
                    pending.forEach(function(newItem) {
                        var found = false
                        for (var k = 0; k < merged.length; k++) {
                            if (merged[k].mode === newItem.mode) { merged[k] = newItem; found = true; break }
                        }
                        if (!found) merged.push(newItem)
                    })
                    root._pendingRemoteConfig = merged
                    root._taskUpdateVisible = true
                    console.log("[ConfigCheck] 检测到", pending.length, "个模式配置有更新，当前待应用", merged.length, "个")
                }

                modes.forEach(function(mode) {
                    var configName = bindings[mode]
                    var cfgUrl = configBase + encodeURIComponent(configName)
                    // 指纹 key = "mode:configName"
                    var fpKey = mode + ":" + configName
                    var xhr1 = new XMLHttpRequest()
                    var _done1 = false
                    var _t1 = Qt.createQmlObject('import QtQuick 2.0; Timer { interval: 8000; repeat: false }', root)
                    _t1.triggered.connect(function() { if (!_done1) { _done1 = true; xhr1.abort() } _t1.destroy() })
                    _t1.start()
                    xhr1.onreadystatechange = function() {
                        if (xhr1.readyState !== XMLHttpRequest.DONE) return
                        if (_done1) return
                        _done1 = true
                        _t1.stop()
                        finished++
                        if (xhr1.status === 200 || xhr1.status === 0) {
                            try {
                                var rawText = xhr1.responseText
                                var obj = JSON.parse(rawText)
                                if (obj && Array.isArray(obj.dimensions) && obj.dimensions.length > 0) {
                                    var remoteFp = rawText
                                    var localFp  = (root._localConfigFingerprint || {})[fpKey] || ""

                                    // 判断是否为绑定切换：绑定关系指纹变了，且该 mode 的 configName 发生了变化
                                    var bindingChanged = (localBindingsFp.length > 0) && (bindingsFp !== localBindingsFp) &&
                                        (function() {
                                            try {
                                                var oldBindings = JSON.parse(localBindingsFp)
                                                return oldBindings[mode] !== configName
                                            } catch(e) { return false }
                                        })()

                                    if (localFp.length === 0 && localBindingsFp.length === 0) {
                                        // 真正首次启动（无任何历史），建基线静默
                                        var fp2 = JSON.parse(JSON.stringify(root._localConfigFingerprint || {}))
                                        fp2[fpKey] = remoteFp
                                        fp2["__bindings__"] = bindingsFp
                                        root._localConfigFingerprint = fp2
                                        root._saveFingerprintToFile()
                                    } else if (bindingChanged) {
                                        // 绑定切换了（运行中或重启后），视为变化，弹通知
                                        console.log("[ConfigCheck] 绑定切换检测到：mode=", mode, "旧配置→新配置=", configName)
                                        pending.push({ mode: mode, obj: obj, configName: configName, rawText: rawText, fpKey: fpKey, bindingsFp: bindingsFp })
                                    } else if (localFp.length === 0) {
                                        // 新增绑定（之前该 mode 没有绑定），建基线静默
                                        var fp3 = JSON.parse(JSON.stringify(root._localConfigFingerprint || {}))
                                        fp3[fpKey] = remoteFp
                                        fp3["__bindings__"] = bindingsFp
                                        root._localConfigFingerprint = fp3
                                        root._saveFingerprintToFile()
                                    } else if (remoteFp !== localFp) {
                                        // 同一绑定，内容发生了变化
                                        pending.push({ mode: mode, obj: obj, configName: configName, rawText: rawText, fpKey: fpKey, bindingsFp: bindingsFp })
                                    }
                                }
                            } catch (e) {
                                console.warn("[ConfigCheck] 解析配置失败 mode=", mode, e)
                            }
                        }
                        if (finished >= total) {
                            // 所有模式检测完毕后，更新绑定关系指纹基线
                            if (pending.length === 0 && bindingsFp !== localBindingsFp) {
                                // 绑定有变化但没有内容差异（不太可能，保险起见更新基线）
                                var fpUpd = JSON.parse(JSON.stringify(root._localConfigFingerprint || {}))
                                fpUpd["__bindings__"] = bindingsFp
                                root._localConfigFingerprint = fpUpd
                                root._saveFingerprintToFile()
                            }
                            onAllDone()
                        }
                    }
                    xhr1.open("GET", cfgUrl)
                    xhr1.send()
                })
            } catch (e) {
                console.warn("[ConfigCheck] 解析 active-config 失败：", e)
            }
        }
        xhr0.open("GET", activeUrl)
        xhr0.send()
    }

    // 用户点击通知卡片后，应用所有待更新的远程配置
    // 应用单条远程配置，并自动切换到对应评分模式
    function _applyRemoteConfigItem(item) {
        if (!item || !item.obj) return
        try {
            var obj = item.obj

            // 更新指纹基线（key = mode:configName，与检测时保持一致；深拷贝后赋值确保 binding 触发）
            var fp2 = JSON.parse(JSON.stringify(root._localConfigFingerprint || {}))
            var _fpKey = item.fpKey || (item.mode + ":" + item.configName)
            fp2[_fpKey] = item.rawText || root._configFingerprint(obj)
            // 同步更新绑定关系指纹，防止下次轮询再次触发 bindingChanged
            if (item.bindingsFp) fp2["__bindings__"] = item.bindingsFp
            root._localConfigFingerprint = fp2
            root._saveFingerprintToFile()

            // 热更新播放器维度
            var _dims = obj.dimensions.map(function(d) {
                var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                return Object.assign({}, d, { starCount: sc })
            })
            root.reviewDimensions = _dims
            if (obj.tag && typeof Rating !== "undefined") Rating.uploadTag = obj.tag
            root._remoteTag = obj.tag || ""

            // 自动切换到对应评分模式
            if (typeof Rating !== "undefined" && item.mode && item.mode !== "off") {
                Rating.currentMode = item.mode
            }

            // 持久化到本地缓存文件
            var localPath = root._resourcesDir() + "/dimensions.json"
            if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
                EngineBridge.writeTextFile(localPath, JSON.stringify(obj))
            }
            console.log("[ConfigCheck] 已应用配置并切换模式，mode:", item.mode, "tag:", obj.tag)

            // 从待更新列表中移除该条
            var remaining = (root._pendingRemoteConfig || []).filter(function(x) {
                return x.mode !== item.mode
            })
            root._pendingRemoteConfig = remaining.length > 0 ? remaining : null
            if (!root._pendingRemoteConfig) root._taskUpdateVisible = false
        } catch (e) {
            console.warn("[ConfigCheck] 应用单条配置失败：", e)
        }
    }

    function _applyPendingRemoteConfig() {
        var list = root._pendingRemoteConfig
        if (!list || !Array.isArray(list) || list.length === 0) return
        try {
            var currentMode = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
            // 深拷贝后修改再赋值，确保 QML property var binding 触发更新
            var fp2 = JSON.parse(JSON.stringify(root._localConfigFingerprint || {}))

            list.forEach(function(item) {
                var obj = item.obj
                // 更新指纹基线（key = mode:configName，与检测时保持一致）
                var _fpKey = item.fpKey || (item.mode + ":" + item.configName)
                fp2[_fpKey] = item.rawText || root._configFingerprint(obj)
                // 同步更新绑定关系指纹，防止下次轮询再次触发 bindingChanged
                if (item.bindingsFp) fp2["__bindings__"] = item.bindingsFp
                // 只有当前播放器模式匹配时，才热更新播放器维度
                if (item.mode === currentMode || list.length === 1) {
                    var _dims = obj.dimensions.map(function(d) {
                        var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                        return Object.assign({}, d, { starCount: sc })
                    })
                    root.reviewDimensions = _dims
                    if (obj.tag && typeof Rating !== "undefined") Rating.uploadTag = obj.tag
                    root._remoteTag = obj.tag || ""
                    // 持久化到本地缓存文件
                    var localPath = root._resourcesDir() + "/dimensions.json"
                    if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
                        EngineBridge.writeTextFile(localPath, JSON.stringify(obj))
                    }
                    console.log("[ConfigCheck] 已热更新播放器维度，mode:", item.mode, "tag:", obj.tag)
                } else {
                    console.log("[ConfigCheck] 已更新指纹基线（非当前模式），mode:", item.mode)
                }
            })

            root._localConfigFingerprint = fp2
            root._saveFingerprintToFile()
            root._pendingRemoteConfig = null
            root._taskUpdateVisible = false
        } catch (e) {
            console.warn("[ConfigCheck] 应用配置失败：", e)
        }
    }

    // 启动后立即触发第一次差异检测（等待 0.5s 让本地配置和 Rating 模块完成初始化）
    Timer {
        id: configInitCheckTimer
        interval: 500
        repeat: false
        running: true
        onTriggered: {
            // 先加载本地持久化指纹，再做差异检测，确保重启后绑定切换能被检测到
            root._loadFingerprintFromFile(function() {
                root._checkRemoteConfigUpdate()
            })
        }
    }

    // 后台轮询定时器（调试：5 秒检测一次）
    Timer {
        id: configPollTimer
        interval: 5 * 1000
        repeat: true
        running: typeof Rating !== "undefined" && Rating.uploadServerUrl && Rating.uploadServerUrl.trim().length > 0
        onTriggered: root._checkRemoteConfigUpdate()
    }

    // ── 维度配置网络加载 ──────────────────────────────────────────────────

    // 推导本地 Resources 目录路径（与 Component.onCompleted 逻辑一致）
    function _resourcesDir() {
        var exe = Qt.application.arguments[0]
        if (Qt.platform.os === "osx") {
            var macosDir   = exe.substring(0, exe.lastIndexOf("/"))
            var contentsDir = macosDir.substring(0, macosDir.lastIndexOf("/"))
            return contentsDir + "/Resources"
        } else {
            return exe.substring(0, exe.lastIndexOf("/"))
        }
    }

    // 持久化指纹到本地文件，重启后仍能检测绑定切换
    function _saveFingerprintToFile() {
        var fpPath = root._resourcesDir() + "/config_fingerprint.json"
        if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
            EngineBridge.writeTextFile(fpPath, JSON.stringify(root._localConfigFingerprint || {}))
        }
    }

    // 从本地文件加载指纹（启动时调用，callback 在加载完成后触发）
    function _loadFingerprintFromFile(callback) {
        var fpUrl = "file://" + root._resourcesDir() + "/config_fingerprint.json"
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200 || xhr.status === 0) {
                try {
                    var obj = JSON.parse(xhr.responseText)
                    if (obj && typeof obj === "object") {
                        root._localConfigFingerprint = obj
                        console.log("[ConfigCheck] 已从文件加载指纹，共", Object.keys(obj).length, "条")
                    }
                } catch (e) {}
            }
            if (typeof callback === "function") callback()
        }
        xhr.open("GET", fpUrl)
        xhr.send()
    }

    // 从任意 URL（file:// 或 https://）加载维度配置并热重载，无需重启
    // callback(ok: bool) 在请求完成后调用（成功或失败均调用，ok 表示是否成功更新了维度）
    function loadDimensionsFromUrl(url, callback) {
        var xhr = new XMLHttpRequest()
        var _done = false
        // 5秒超时兜底：防止网络不通时 callback 永远不触发导致评分面板空白
        var _timer = Qt.createQmlObject('import QtQuick 2.0; Timer { interval: 5000; repeat: false }', root)
        _timer.triggered.connect(function() {
            if (!_done) {
                _done = true
                console.warn("[DimLoad] 请求超时（5s），使用本地缓存维度")
                xhr.abort()
                if (typeof callback === "function") callback(false)
            }
            _timer.destroy()
        })
        _timer.start()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (_done) return  // 已超时，忽略
            _done = true
            _timer.stop()
            if (xhr.status === 200 || xhr.status === 0) {
                try {
                    var obj = JSON.parse(xhr.responseText)
                    if (obj && Array.isArray(obj.dimensions) && obj.dimensions.length > 0) {
                        // 1. 热重载维度（预注入 starCount，避免 Repeater delegate 依赖深层 levels.length 动态计算）
                        var _dims1 = obj.dimensions.map(function(d) {
                            var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                            return Object.assign({}, d, { starCount: sc })
                        })
                        root.reviewDimensions = _dims1
                        // 1b. 同步远程配置的 tag 到备注 tag 输入框（用户可手动覆盖）
                        if (obj.tag && typeof Rating !== "undefined") {
                            Rating.uploadTag = obj.tag
                        }
                        // 存储远程 tag，供上传时校验
                        root._remoteTag = obj.tag || ""
                        // 2. 持久化到本地 Resources/dimensions.json（覆盖写）
                        var localPath = root._resourcesDir() + "/dimensions.json"
                        if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
                            EngineBridge.writeTextFile(localPath, xhr.responseText)
                        }
                        if (typeof callback === "function") callback(true)
                        return
                    }
                } catch (e) {
                    console.warn("[DimLoad] JSON 解析失败：", e)
                }
            } else {
                console.warn("[DimLoad] 加载失败（HTTP", xhr.status, "）")
            }
            // 加载失败：仍调用 callback，让启动流程继续（用本地缓存维度）
            if (typeof callback === "function") callback(false)
        }
        xhr.open("GET", url)
        xhr.send()
    }

    // 从 Rating.uploadServerUrl 推导维度 API 地址（去掉路径，拼上 /api/dimensions）
    function _dimApiUrl() {
        var base = (typeof Rating !== "undefined" && Rating.uploadServerUrl) ? Rating.uploadServerUrl.trim() : ""
        if (base.length === 0) return ""
        // 取 origin 部分：http://host:port
        var m = base.match(/^(https?:\/\/[^/]+)/)
        return m ? m[1] + "/api/dimensions" : ""
    }

    // 切换到多维模式或维度配置变化时，重新初始化 cellRatings
    // 有维度配置（不限于 multi_dim）时初始化为对象数组；无维度时恢复为数字数组
    function _rebuildCellRatingsForDims() {
        var n = Engine.fileCount
        if (n <= 0) return
        var hasDims = reviewDimensions && reviewDimensions.length > 0
        var arr = []
        for (var i = 0; i < n; ++i) {
            if (hasDims) {
                var obj = {}
                for (var d = 0; d < reviewDimensions.length; ++d)
                    obj[reviewDimensions[d].key] = 0
                arr.push(obj)
            } else {
                arr.push(0)
            }
        }
        cellRatings = arr
    }
    onIsMultiDimModeChanged: {
        // 切换模式时仅重新初始化 cellRatings，维度配置在点击「启动对比」时加载
        _rebuildCellRatingsForDims()
    }
    onReviewDimensionsChanged: {
        // 维度配置更新时（启动对比加载远程配置后），重建 cellRatings 结构
        _rebuildCellRatingsForDims()
    }
    //   · 实时写入 ratings_quality_slide_slide.csv（与普通打分文件完全隔离）
    //   · 与普通 quality 评分（cellRatings）解耦，互不覆盖
    //   · 切到下一组后必须清空（_resetSlideRatings），下一组重新进入再评
    readonly property bool isQualitySlideMode:
        (typeof Rating !== "undefined") && Rating.currentMode === "quality_slide"
    property bool slideEnteredOnce: false   // 本组中是否进入过滑动对比
    property int  slideRatingL: 0           // 滑动模式左侧评分（0=未打，1/2）
    property int  slideRatingR: 0           // 滑动模式右侧评分（0=未打，1/2）
    function _resetSlideRatings() {
        slideEnteredOnce = false
        slideRatingL = 0
        slideRatingR = 0
    }
    // 切换到新一组后，从 CSV 恢复该组已有的滑动评分（避免循环切组时评分被清零）
    function _restoreSlideRatings() {
        if (!isQualitySlideMode) return
        if (typeof Rating === "undefined" || Engine.fileCount < 2) return
        var fpL = Engine.filePathAt(0)
        var fpR = Engine.filePathAt(1)
        if (!fpL || !fpR) return
        var fnL = Engine.fileNameAt(0)
        var fnR = Engine.fileNameAt(1)
        // file_name 存储时加了 ch+1_ 前缀：L侧="1_xxx"，R侧="2_xxx"
        var storedNameL = "1_" + fnL
        var storedNameR = "2_" + fnR
        var rows = Rating.getSlideRatings()
        var rL = 0, rR = 0
        for (var i = 0; i < rows.length; ++i) {
            var r = rows[i]
            if (r.file_path === fpL && r.file_name === storedNameL) rL = r.stars || 0
            else if (r.file_path === fpR && r.file_name === storedNameR) rR = r.stars || 0
        }
        slideRatingL = rL
        slideRatingR = rR
        // 如果任意一侧已有评分，说明本组曾经进入过滑动对比
        if (rL > 0 || rR > 0) slideEnteredOnce = true
    }
    function setSlideRating(side, score) {
        if (score < 0) score = 0
        if (score > 2) score = 2
        if (side === "L") slideRatingL = (slideRatingL === score ? 0 : score)
        else if (side === "R") slideRatingR = (slideRatingR === score ? 0 : score)

        // 立即持久化到 ratings_quality_slide_slide.csv（与普通打分隔离）
        if (typeof Rating !== "undefined" && Engine.fileCount >= 2) {
            var fpL = Engine.filePathAt(0)
            var fpR = Engine.filePathAt(1)
            var fnL = Engine.fileNameAt(0)
            var fnR = Engine.fileNameAt(1)
            Rating.recordSlideRating(fpL, fnL, slideRatingL, fpR, fnR, slideRatingR)
        }
    }

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
    // 用户拖拽后的侧边栏宽度（仅在 refSidebarVisible 为 true 时生效）
    // 限制 [200, 600]：太窄会让图1/图2 缩成一团；太宽会挤压视频区
    property int refSidebarUserWidth: 320
    readonly property int refSidebarWidth: refSidebarVisible ? refSidebarUserWidth : 0
    // 用户拖拽后的底栏（提示词）展开高度，仅在 csvBottomBarExpanded 时生效
    // 限制 [60, 280]：低于 60 看不见文字；高于 280 视频区太矮
    property int csvBottomBarUserHeight: 88

    // 触发器：Reference.referenceChanged / 文件切换时 ++，让下面的 readonly 重算
    property int _refTick: 0
    Connections {
        target: typeof Reference !== "undefined" ? Reference : null
        function onReferenceChanged(folder)     { root._refTick++ }
        function onReferenceTextChanged(folder) { root._refTick++ }
        function onReference2Changed(folder)    { root._refTick++ }
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
    // ◀ ▶ / Lightbox 「可翻页」语义：
    //   folder 模式：能在同一文件夹里翻图；
    //   grouped 模式：能在「长队列」里跨组递归翻图（主要需求）。
    //   image / 未绑定：不可翻。
    readonly property bool refCanNav: (root.refCurrentMode === "folder"
                                       || root.refCurrentMode === "grouped")
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
        function onFilesChanged() {
            root._refImgOffset = 0
            root._refTextOffset = 0
            root._refImgOffset2 = 0
        }
    }

    // ─── 参考图（槽位 2）─────────────────────────────────────────────
    // 与槽位 1 完全镜像，作为下半区的独立参考图。
    // 持久化由 Reference.kindOf2 / setReference*2 / clearReference2 提供。
    property int _refImgOffset2: 0
    readonly property url refCurrentUrl2: {
        _refTick;
        if (typeof Reference === "undefined") return ""
        if (root.refCurrentVideo.length === 0) return ""
        return Reference.referenceUrlForVideoOffset2(root.refCurrentVideo, root._refImgOffset2)
    }
    readonly property bool refHasCurrent2: String(root.refCurrentUrl2).length > 0
    readonly property string refCurrentMode2: {
        _refTick;
        if (typeof Reference === "undefined") return ""
        if (root.refCurrentFolder.length === 0) return ""
        return Reference.kindOf2(root.refCurrentFolder)
    }
    readonly property string refProgressText2: {
        _refTick;
        if (typeof Reference === "undefined") return ""
        if (root.refCurrentVideo.length === 0) return ""
        return Reference.referenceProgressForVideoOffset2(root.refCurrentVideo, root._refImgOffset2)
    }
    readonly property int refImageCount2: {
        _refTick;
        if (typeof Reference === "undefined") return 0
        if (root.refCurrentVideo.length === 0) return 0
        return Reference.referenceImageCountForVideo2(root.refCurrentVideo)
    }
    // 跳 nav 语义（槽位 2）
    readonly property bool refCanNav2: (root.refCurrentMode2 === "folder"
                                        || root.refCurrentMode2 === "grouped")
    readonly property int refCurrentImageIndex2: {
        var t = root.refProgressText2
        if (!t || t.length === 0) return -1
        var slash = t.indexOf("/")
        if (slash < 0) return -1
        var n = parseInt(t.substring(0, slash).trim(), 10)
        return isNaN(n) ? -1 : (n - 1)
    }

    // ─── 参考文本（CSV）─────────────────────────────────────────────
    // 与参考图同样按"当前视频在其文件夹中的索引"取 csv 第 N 行。
    //   refTextData : { image, zh, en, raw, row, total }
    //   refTextLang : "zh" / "en"，UI 偏好（持久化在 Settings 里，session 内共享）
    property string refTextLang: "zh"
    property int refTextFontSize: 16   // CSV 提示词显示字号，A-/A+ 按钮调节，不随切组重置

    // ─── 视频显示比例 / 固定尺寸锁定（手机屏预览，类浏览器调试器）──────────
    // 三种状态（优先级：fixed > ratio > 关闭）：
    //   1) phoneFixedWidth>0 && phoneFixedHeight>0  → 固定像素尺寸模式：
    //      cell 内视频显示区按 (W,H) 像素显示；若 cell 装不下则等比缩放至 cell 内。
    //   2) phoneAspectRatio>0                       → 仅锁定宽高比模式（旧行为）。
    //   3) 全部 = 0                                 → 关闭，视频按原宽高比铺满 cell。
    //
    // 仅 session 内生效，切换对比组不重置（与字号一致）。
    //
    // 常用尺寸预设见 phonePresetModel（点击预设会同时写入 W/H 与 ratio）。
    property real phoneAspectRatio: 0
    property int  phoneFixedWidth: 0    // 0=未启用固定尺寸
    property int  phoneFixedHeight: 0   // 0=未启用固定尺寸
    // 显示器校准系数：所有手机模式下的渲染尺寸 = phoneFixedWidth × phoneDisplayScale。
    //   预设值（如 iPhone 17 Pro Max = 440×956）保留 CSS px 标准口径，不被污染；
    //   每台显示器的物理 PPI 不同（macOS Retina 不同型号有差异），用一次校准把蓝框
    //   屏显大小拉到接近真机即可。
    //   合法范围 0.1 ~ 5.0（外接低 PPI 显示器可能需要明显大于 1.0）；<=0 视为无效，回退到 1.0。
    //
    // 自动跟随 macOS 系统设置 → 显示器 → 缩放档位（更大字体 / … / 默认 / … / 更多空间）：
    //   不同档位下 Screen.width（逻辑 px）会变，用查表得到对应校准系数。
    //   表内未命中则取最近邻；用户一旦在校准框手动输入，关闭自动跟随。
    property real phoneDisplayScale: 1.0
    property bool phoneScaleAutoTrack: true
    // 校准预设：按显示器名归类，每张表条目为 [逻辑宽 px, 校准系数]。
    //   不同显示器物理 PPI 不同，仅靠 logicalWidth 不足以唯一确定校准值
    //   （例如内建屏 1728 与某些外接屏的逻辑宽度可能重叠）。因此用 Screen.name 选表。
    //
    //   内建（16" MBP, 内建视网膜显示器）实测 5 档：
    //     1168=更大字体 / 1312 / 1496 / 1728=默认 / 2056=更多空间
    //   外接（PHL 278B1, 27" 4K）实测 5 档：
    //     1920=更大字体 / 2560 / 3008 / 3360=默认 / 3840=更多空间
    //
    //   未匹配到的显示器走 _phoneScalePresetsDefault（同内建表，按最近邻取值）。
    readonly property var _phoneScalePresetsByScreen: ({
        "内建视网膜显示器": [
            [1168, 0.60],
            [1312, 0.68],
            [1496, 0.77],
            [1728, 0.88],
            [2056, 1.06]
        ],
        "PHL 278B1": [
            [1920, 0.57],
            [2560, 0.76],
            [3008, 0.90],
            [3360, 1.00],
            [3840, 1.14]
        ]
    })
    // 默认表：未在 _phoneScalePresetsByScreen 命中的显示器走这里，按 Screen.width
    // 最近邻取值。
    //   · 这 5 项来自 macOS 内建视网膜显示器实测，是历史校准值，**不要改**。
    //   · Windows 的实测点不放这里 —— Windows 上 Qt 的 Screen.width 是
    //     "物理像素 / dpr"，同一台显示器切换缩放档位会让逻辑宽落到完全不同
    //     的数值（如 2560×1440 物理屏：100%→2560，125%→2048，150%→1707），
    //     单纯按 Screen.width 一维近邻无法区分"低分高缩放"和"高分低缩放"
    //     的两种状态。Windows 实测点见下方 _phoneScalePresetsWindows，按
    //     (物理宽, dpr) 二元组精确匹配。
    readonly property var _phoneScalePresetsDefault: [
        [1168, 0.60],
        [1312, 0.68],
        [1496, 0.77],
        [1728, 0.88],
        [2056, 1.06]
    ]
    // ─── Windows 实测校准表（按物理屏列基准）───────────────────────────
    // 关键观察（用户实测得出）：同一台物理显示器，切换系统缩放档位时
    //   scale(dpr=x) = baseScale × baseDpr / x
    // 严格成立。物理意义：物理屏宽是常量，物理像素也是常量，逻辑宽 =
    // 物理像素宽 / dpr 反比于 dpr，要让"蓝框 ~77.7mm"恒定，scale 必然反
    // 比于 dpr。
    //
    // 因此 Windows 表只需要每台物理屏一行"基准记录"（统一归一到 dpr=1.0
    // 即 100% 档位下的系数），任意其它缩放档位都用上面公式反推。这避免
    // 了用户给的 (分辨率, 推荐缩放%) 散点实际上是同一物理屏的不同采样、
    // 但 200% / 125% 等档位没采样到时表查不到、再退化到不可靠的 Qt
    // physicalDotsPerInch 公式的链路（实测 3840×2160@200% 会错算成 0.28，
    // 正确值 0.57，差了一个 dpr=2 因子）。
    //
    // 字段：[物理宽, 基准dpr=1.0, 基准scale@100%档]
    // 物理宽匹配容差 ±8 px（OEM EDID 四舍五入）。
    readonly property var _phoneScalePresetsWindows: [
        // [物理宽, 基准dpr, 基准scale@100%, 备注]
        [1920, 1.00, 0.57],   // 1920×1080 物理屏（@100%=0.57，@150%=0.38，@200%=0.285）
        [2560, 1.00, 0.76],   // 2560×1440 物理屏（@100%=0.76）
        [3008, 1.00, 0.90],   // 3008×1692 物理屏（@100%=0.90）
        [3360, 1.00, 1.00],   // 3360×1890 物理屏（@100%=1.00）
        [3840, 1.00, 1.14],   // 3840×2160 物理屏（@100%=1.14，@150%=0.76，@200%=0.57）
        [3200, 1.00, 0.945],  // 3200×1800 物理屏（@150%=0.63 → 归一 ×1.5 = 0.945）
        [3072, 1.00, 0.90],   // 3072×1728 物理屏（@125%=0.72 → 归一 ×1.25 = 0.90）
        [2048, 1.00, 0.80],   // 2048×1536 物理屏（@125%=0.64 → 归一 ×1.25 = 0.80）
        [3120, 1.00, 1.80]    // 3120×2080 物理屏（@200%=0.90 → 归一 ×2.0 = 1.80）
    ]
    // 公式自适应目标：让"手机蓝框"在屏幕上的物理宽度恒为 ~77.7mm（iPhone 17 Pro Max
    // 实测物理宽 77.6mm，与已校准的内建/PHL 5 档预设完全吻合，误差 < 0.5mm）。
    //
    //   phoneDisplayScale = TARGET_MM / (phoneFixedWidth × mmPerLogicalPx)
    //
    // 其中 mmPerLogicalPx 由 QML Screen 的 pixelDensity（物理像素/mm）和 devicePixelRatio
    // 反推：mmPerLogicalPx = devicePixelRatio / pixelDensity。
    // 该公式与显示器型号无关——任何 macOS / Windows 显示器、任何缩放档位都成立。
    readonly property real _phoneTargetPhysicalMm: 77.7
    function _phoneScalePresetsForScreen(name) {
        var map = root._phoneScalePresetsByScreen
        if (name && map.hasOwnProperty(name)) return map[name]
        return null
    }
    function _autoPhoneScaleByFormula() {
        // 优先用 QML Screen 暴露的物理像素密度
        var pd = Screen.pixelDensity   // 物理像素 / mm
        var dpr = Screen.devicePixelRatio || 1
        // 主动从 ScreenProbe 拿一次实时值。该路径不走 QML Screen 缓存，
        // 在 macOS 外接屏切档位时能拿到刷新后的真值（关键修复点）。
        if (typeof ScreenProbe !== "undefined") {
            var st = ScreenProbe.currentForWindow(root)
            if (st && st.pixelDensity > 0) {
                pd  = st.pixelDensity
                dpr = st.devicePixelRatio > 0 ? st.devicePixelRatio : dpr
            }
        }
        if (pd && pd > 0) {
            var mmPerLogicalPx = dpr / pd
            var fw = root.phoneFixedWidth > 0 ? root.phoneFixedWidth : 440
            var s = root._phoneTargetPhysicalMm / (fw * mmPerLogicalPx)
            if (s > 0) return s
        }
        return -1
    }
    function _autoPhoneScaleNearestPreset(w, presets) {
        if (!presets || presets.length === 0) return -1
        var best = presets[0]
        var bestDiff = Math.abs(w - best[0])
        for (var i = 1; i < presets.length; ++i) {
            var d = Math.abs(w - presets[i][0])
            if (d < bestDiff) { best = presets[i]; bestDiff = d }
        }
        return best[1]
    }
    // Windows 单维查表 + dpr 反比反推：
    //   1) 按物理宽（±8 容差）匹配到一行基准记录 [物理宽, baseDpr, baseScale]；
    //   2) 当前档位系数 = baseScale × baseDpr / curDpr。
    // 这覆盖任何缩放档位（100/125/150/175/200/250%…），不再依赖逐档采样。
    // 命中返回反推后的系数；未命中（陌生物理屏）返回 -1，让上层走公式 →
    // 默认表兜底。
    function _autoPhoneScaleWindowsPreset(physWidth, dpr) {
        var t = root._phoneScalePresetsWindows
        if (!t || t.length === 0) return -1
        if (!(physWidth > 0) || !(dpr > 0)) return -1
        for (var i = 0; i < t.length; ++i) {
            var pw        = t[i][0]
            var baseDpr   = t[i][1]
            var baseScale = t[i][2]
            if (Math.abs(physWidth - pw) <= 8) {
                // dpr 反比反推：scale ∝ 1 / dpr
                return baseScale * baseDpr / dpr
            }
        }
        return -1
    }
    function _applyAutoPhoneScale() {
        if (!root.phoneScaleAutoTrack) return
        // 优先从 ScreenProbe 取实时屏幕状态（绕开 QML Screen 在 macOS 外接屏
        // 切档位时的缓存问题）；探测失败时回退到 QML Screen 附加属性。
        var w = Screen.width
        var nm = Screen.name
        var dpr = Screen.devicePixelRatio || 1
        if (typeof ScreenProbe !== "undefined") {
            var st = ScreenProbe.currentForWindow(root)
            if (st && st.width > 0) {
                w   = st.width
                nm  = st.name || nm
                dpr = st.devicePixelRatio > 0 ? st.devicePixelRatio : dpr
            }
        }
        if (!w || w <= 0) return
        // 1) 已知显示器：完全走预设表（保护已校准的内建/PHL 体验，不动）
        //   注意：by-name 分支只在 **非 Windows** 平台启用。
        //   原因：同一台外接显示器（如 PHL 278B1）在 macOS / Windows 下
        //   Screen.name 一致，但 Windows 还会叠加"分辨率档位 × 推荐缩放"，
        //   单凭显示器名无法区分；继续走 by-name 会拿到 macOS 校准的
        //   单一系数，与 Windows 实测值不符（用户报 3200×1800@150%
        //   命中 PHL 278B1 → 0.57，实际应=0.63）。
        //   Windows 一律落到 2-Win) 物理宽+dpr 实测表 → 公式 → 默认表。
        var presets = (Qt.platform.os === "windows")
                    ? null
                    : root._phoneScalePresetsForScreen(nm)
        var s = -1
        if (presets) {
            s = root._autoPhoneScaleNearestPreset(w, presets)
        } else if (Qt.platform.os === "windows") {
            // 2-Win) Windows 平台未知显示器：先按 (物理宽, dpr) 二元组查实测表。
            //
            //   背景：Windows 上 Qt 的 Screen.pixelDensity 取自 EDID 物理尺寸，
            //   切换分辨率档位时**不会变** → 公式
            //     scale = TARGET_MM / (fw × dpr / pd)
            //   的输出在不同档位下几乎一样，公式自适应在 Windows 失效。
            //
            //   实测表覆盖用户提供的若干 (分辨率, 推荐缩放) 组合（见
            //   _phoneScalePresetsWindows）。命中返回精确系数；未命中
            //   （用户用了非推荐分辨率/缩放档位）回退公式自适应；公式
            //   再失败才用默认表近邻兜底。
            //
            //   关键：(物理宽, dpr) 二元组天然区分了 Windows 上的"缩放档位"
            //   ——同一物理屏不同推荐缩放下 dpr 不同，会落到不同行；同一
            //   逻辑宽不同物理宽组合也不会互相误命中。
            //
            //   注意：Screen.width 在 Windows 上是"物理宽 / dpr"（已除过缩放），
            //   要还原回物理宽必须乘 dpr 后四舍五入。
            var physW = Math.round(w * dpr)
            s = root._autoPhoneScaleWindowsPreset(physW, dpr)
            if (s <= 0) {
                s = root._autoPhoneScaleByFormula()
                if (s <= 0)
                    s = root._autoPhoneScaleNearestPreset(w, root._phoneScalePresetsDefault)
            }
        } else {
            // 2) 未知显示器（macOS / Linux）：物理 mm 公式自适应（保持原行为，
            //    macOS 已验证可靠）；公式失效兜底用默认表最近邻。
            s = root._autoPhoneScaleByFormula()
            if (s <= 0)
                s = root._autoPhoneScaleNearestPreset(w, root._phoneScalePresetsDefault)
        }
        if (s <= 0) return
        // 与 SpinBox 校准框范围一致（0.1 ~ 5.0）
        if (s < 0.1) s = 0.1
        else if (s > 5.0) s = 5.0
        if (Math.abs(s - root.phoneDisplayScale) > 0.001)
            root.phoneDisplayScale = s
    }
    // 手动微调系数（被尺寸弹窗里 ▲/▼ 步进按钮调用）。
    //   · delta 通常是 ±0.01；
    //   · 用 Math.round(v*100)/100 抹掉浮点抖动（0.77+0.01=0.7800000000000001）；
    //   · 严格夹紧到 [0.1, 5.0] —— 与 phoneScaleInput 的 DoubleValidator 一致；
    //   · 自动关闭 phoneScaleAutoTrack，防止下次屏幕参数变化把刚校准的值覆盖。
    function _stepPhoneScale(delta) {
        var v = root.phoneDisplayScale + delta
        v = Math.round(v * 100) / 100
        if (v < 0.1) v = 0.1
        if (v > 5.0) v = 5.0
        root.phoneScaleAutoTrack = false
        root.phoneDisplayScale = v
    }
    Connections {
        target: Screen
        function onWidthChanged()  { root._applyAutoPhoneScale() }
        function onHeightChanged() { root._applyAutoPhoneScale() }
        function onNameChanged()   { root._applyAutoPhoneScale() }
        function onPixelDensityChanged() { root._applyAutoPhoneScale() }
        function onDevicePixelRatioChanged() { root._applyAutoPhoneScale() }
    }
    // ─── 外接显示器切换缩放档位的兜底刷新 ────────────────────────────────
    //   背景：在 macOS 上切换"系统设置 → 显示器 → 缩放档位"时：
    //     · 内建屏：Screen.* 一系列 changed 信号正常发 → 上面 Connections
    //       触发 _applyAutoPhoneScale → 自适应 OK；
    //     · 外接屏（如 PHL 278B1）：Qt 在 macOS 上长期存在"QScreen 不发
    //       physicalDotsPerInchChanged / geometryChanged"丢信号问题，
    //       QML 端 Screen.* 的 changed 信号也不会触发 → _applyAutoPhoneScale
    //       不会被调用 → 蓝框尺寸"卡"在切档位前的旧值。
    //
    //   主修复路径（事件驱动）：C++ 端 ScreenProbe 通过订阅 macOS 系统级
    //     NSApplicationDidChangeScreenParametersNotification
    //   通知，转发为 Qt 信号 screenParamsChanged() —— 用户只要在系统设置里
    //   切了任何一台显示器的档位/分辨率/接拔显示器，QML 这里都能立刻收到。
    //   ScreenProbe.currentForWindow() 内部直接走 NSScreen 原生 API，与 Qt
    //   QScreen 缓存路径独立，能正确反映最新值。
    //
    //   兜底 1：窗口本身的 screenChanged / 尺寸变化（跨屏 / 拖动 / 档位变化
    //          导致窗口逻辑尺寸变化时也会触发）。
    //   兜底 2：低频轮询（2s）—— 极端情况下（系统通知未发或窗口未激活）的
    //          最后一道保险。开销可忽略。
    Connections {
        target: ScreenProbe
        function onScreenParamsChanged() {
            // 通知抵达时 NSScreen 数值已是最新；callLater 让本帧渲染先完成
            // 再重算（避免与 Qt 内部正在进行的 screen 更新交叉）。
            Qt.callLater(root._applyAutoPhoneScale)
        }
    }

    onScreenChanged: {
        root._applyAutoPhoneScale()
        Qt.callLater(root._applyAutoPhoneScale)
    }
    onWidthChanged: {
        if (root.phoneScaleAutoTrack) Qt.callLater(root._applyAutoPhoneScale)
    }
    onHeightChanged: {
        if (root.phoneScaleAutoTrack) Qt.callLater(root._applyAutoPhoneScale)
    }

    // 轮询兜底：直接对比 ScreenProbe 实时快照，发现任一关键字段变化就强制
    // 重算。注意"上次快照"也存 ScreenProbe 给的值（不是 QML Screen.*），
    // 这样即使 QML Screen 缓存永不更新，比较也能准确发现差异。
    property real    _lastScreenW:    -1
    property real    _lastScreenH:    -1
    property real    _lastScreenPd:   -1
    property real    _lastScreenDpr:  -1
    property string  _lastScreenName: ""
    Timer {
        id: _screenPollTimer
        interval: 2000
        running: true
        repeat: true
        onTriggered: {
            var w, h, pd, dpr, nm
            var got = false
            if (typeof ScreenProbe !== "undefined") {
                var st = ScreenProbe.currentForWindow(root)
                if (st && st.width > 0) {
                    w   = st.width
                    h   = st.height
                    pd  = st.pixelDensity
                    dpr = st.devicePixelRatio
                    nm  = st.name
                    got = true
                }
            }
            if (!got) {
                w   = Screen.width
                h   = Screen.height
                pd  = Screen.pixelDensity
                dpr = Screen.devicePixelRatio
                nm  = Screen.name
            }
            if (w   !== root._lastScreenW   ||
                h   !== root._lastScreenH   ||
                pd  !== root._lastScreenPd  ||
                dpr !== root._lastScreenDpr ||
                nm  !== root._lastScreenName) {
                root._lastScreenW    = w
                root._lastScreenH    = h
                root._lastScreenPd   = pd
                root._lastScreenDpr  = dpr
                root._lastScreenName = nm
                root._applyAutoPhoneScale()
            }
        }
    }

    // 切换手机尺寸预设（440×956 / 402×874 …）时，若仍在自动跟随，重算系数
    onPhoneFixedWidthChanged: _applyAutoPhoneScale()
    readonly property bool phoneFixedActive: phoneFixedWidth > 0 && phoneFixedHeight > 0
    readonly property string phoneAspectLabel: {
        if (root.phoneFixedActive) {
            return root.phoneFixedWidth + "×" + root.phoneFixedHeight
        }
        var r = root.phoneAspectRatio
        if (r <= 0) return "原始"
        if (Math.abs(r - 9/19.5) < 0.001) return "9:19.5"
        if (Math.abs(r - 9/16)   < 0.001) return "9:16"
        if (Math.abs(r - 3/4)    < 0.001) return "3:4"
        return r.toFixed(3)
    }
    // 文本端    // 文本端"手动浏览"偏移：与参考图 _refImgOffset 一一对应。
    //   ◀ ▶ 在自动同步行的基础上 ±1（C++ 端做边界裁剪）；
    //   切换对比组（onFilesChanged）时归零，回到自动同步状态。
    property int _refTextOffset: 0
    readonly property var refTextData: {
        _refTick;
        if (typeof Reference === "undefined") return ({})
        if (root.refCurrentVideo.length === 0) return ({})
        return Reference.referenceTextForVideoOffset(root.refCurrentVideo, root._refTextOffset) || ({})
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
        return Reference.textProgressForVideoOffset(root.refCurrentVideo, root._refTextOffset)
    }
    // csv 模式下文本总行数（用于 ◀ ▶ 边界判断）
    readonly property int refTextRowCount: {
        _refTick;
        if (typeof Reference === "undefined") return 0
        if (root.refCurrentVideo.length === 0) return 0
        return Reference.textRowCountForVideo(root.refCurrentVideo)
    }
    // 当前展示行号（0-based）：解析 refTextProgress 里的 "N / M"，无则返回 -1
    readonly property int refTextCurrentRow: {
        var t = root.refTextProgress
        if (!t || t.length === 0) return -1
        var slash = t.indexOf("/")
        if (slash < 0) return -1
        var n = parseInt(t.substring(0, slash).trim(), 10)
        return isNaN(n) ? -1 : (n - 1)
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

    function ratingAt(idx, dimKey) {
        if (idx < 0 || idx >= cellRatings.length) return 0
        var v = cellRatings[idx]
        if (typeof v === "object" && v !== null) {
            // 多维模式：返回指定维度的分数
            return (dimKey && v[dimKey]) ? v[dimKey] : 0
        }
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
        // 评分变更后 bump，让 allGroupsRated 响应式重算
        multiGroupDialog._bumpState()
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
            var dims = root.reviewDimensions
            var hasDims = dims && dims.length > 0
            for (var i = 0; i < n; ++i) {
                var fp = Engine.filePathAt(i)
                if (hasDims) {
                    // 有维度配置时（不限于 multi_dim 模式）：每项初始化为对象，从 CSV 按 slide_type 回填各维度
                    var obj = {}
                    for (var d = 0; d < dims.length; ++d) {
                        var dimKey = dims[d].key
                        var saved = -1
                        if (typeof Rating !== "undefined" && fp && fp.length > 0) {
                            saved = Rating.ratingFor(fp, "multi_" + dimKey)
                        }
                        obj[dimKey] = (typeof saved === "number" && saved >= 1 && saved <= 5) ? saved : 0
                    }
                    arr.push(obj)
                } else {
                    var v = -1
                    if (typeof Rating !== "undefined" && fp && fp.length > 0) {
                        v = Rating.ratingFor(fp)
                    }
                    arr.push((typeof v === "number" && v >= 1 && v <= 5) ? v : 0)
                }
            }
            root.cellRatings = arr
            // 切换文件 / 翻组 / 改宫格后，主动复位 selectedIdx，避免上一组的
            // 选中（蓝边）残留误导。用户若需要再选中，单击或 [ / ] 即可。
            root.selectedIdx = -1
            // quality_slide：先清零再从 CSV 恢复本组已有的滑动评分，
            // 避免循环切组时评分被清零，同时防止上一组评分残留。
            root._resetSlideRatings()
            root._restoreSlideRatings()
        }
    }

    // 切换函数：仅在 fileCount === 2 时允许进入；离开 2 路场景时强制关闭
    function _toggleCompareSlider() {
        if (compareSliderActive) {
            compareSliderActive = false
        } else if (compareSliderAvailable) {
            compareSliderActive = true
            // quality_slide：用户进入过滑动对比即记一次；切组时清空（见 onFilesChanged）。
            if (root.isQualitySlideMode) root.slideEnteredOnce = true
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

        // ── 全局进度条（贴 ToolBar 顶边，跨整宽，3px 细条）──────────────────
        // 设计要点：
        //   · 数据源直接用 Engine.duration（C++ 已是所有路 duration 的 max，
        //     正好满足"以当前打开视频的最长时长为准"的需求；短视频先到末尾
        //     不参与计算，只看最长那条的时间线）；进度用 Engine.position 取
        //     主时钟位置，与现有"播放/暂停/快进/帧步"等控制天然同步。
        //   · 仅当有视频且 duration>0 时显示；空状态/纯图片/未识别封装格式时
        //     自动隐藏，不占视觉空间。
        //   · 高度仅 3px，hover/拖拽期间涨到 5px，给用户即时反馈，不打扰画面对比。
        //   · 点击 / 拖拽都通过 Engine.seek(s) 完成，与现有键盘 ←/→ 行为完全一致；
        //     拖拽期间用本地 _dragValue 做"手不松不重置"的视觉锁定，避免抖动。
        //   · 不破坏循环播放、单路 OSD、hover 控制条等任何已有功能（这条只 read
        //     Engine.duration / position + 写 Engine.seek，无副作用）。
        Item {
            id: globalProgressBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            // 默认 3px，hover/拖拽时涨到 5px
            height: (progressHover.hovered || progressDrag.active) ? 5 : 3
            visible: Engine.fileCount > 0 && Engine.duration > 0
            z: 10
            Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

            // 拖拽时的"手不松不重置"位置（秒）；-1 表示未拖拽，使用 Engine.position
            property real _dragValue: -1
            // 当前用于绘制的位置（秒）
            readonly property real _curPos: _dragValue >= 0 ? _dragValue : Engine.position
            readonly property real _ratio: Engine.duration > 0
                ? Math.max(0, Math.min(1, _curPos / Engine.duration))
                : 0

            // 底色（未播放）
            Rectangle {
                anchors.fill: parent
                color: "#2a2a30"
            }
            // 已播放部分
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * parent._ratio
                color: "#0a64f0"
            }

            HoverHandler { id: progressHover }
            // DragHandler 仅用来取 active 状态（让条变高），实际的鼠标位置 → seek
            // 走 MouseArea，避免 DragHandler 的 axis 约束与"瞬时点击"语义冲突。
            DragHandler {
                id: progressDrag
                target: null
                enabled: false  // 仅占位，真正交互在 MouseArea 中
            }
            MouseArea {
                id: progressMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                property bool _pressing: false
                onPressed: function(mouse) {
                    if (Engine.duration <= 0) return
                    _pressing = true
                    var r = Math.max(0, Math.min(1, mouse.x / width))
                    globalProgressBar._dragValue = r * Engine.duration
                    Engine.seek(globalProgressBar._dragValue)
                }
                onPositionChanged: function(mouse) {
                    if (!_pressing || Engine.duration <= 0) return
                    var r = Math.max(0, Math.min(1, mouse.x / width))
                    globalProgressBar._dragValue = r * Engine.duration
                    Engine.seek(globalProgressBar._dragValue)
                }
                onReleased: {
                    _pressing = false
                    globalProgressBar._dragValue = -1
                }
                onCanceled: {
                    _pressing = false
                    globalProgressBar._dragValue = -1
                }
            }

            // 悬停时显示当前时刻 / 总时长 tooltip
            ToolTip.visible: progressHover.hovered || progressMouse._pressing
            ToolTip.delay: 200
            ToolTip.text: {
                function fmt(t) {
                    if (!isFinite(t) || t < 0) t = 0
                    var s = Math.floor(t)
                    var m = Math.floor(s / 60)
                    var sec = s % 60
                    var h = Math.floor(m / 60)
                    m = m % 60
                    function pad(n) { return n < 10 ? "0" + n : "" + n }
                    return h > 0 ? (h + ":" + pad(m) + ":" + pad(sec))
                                 : (m + ":" + pad(sec))
                }
                return fmt(_curPos) + " / " + fmt(Engine.duration)
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

            // ── 任务配置更新常驻入口按钮（🔔）紧贴 📱 按钮左侧 ──────────
            Button {
                id: taskUpdateEntryBtn
                // 始终常驻显示
                visible: true
                Layout.preferredWidth: 32
                Layout.preferredHeight: 28
                Layout.alignment: Qt.AlignVCenter
                hoverEnabled: true

                // 有待更新：切换面板；无待更新：主动抓取一次，无变化则提示
                property bool _checking: false
                property bool _showNoUpdate: false

                onClicked: {
                    var hasPending = Array.isArray(root._pendingRemoteConfig) && root._pendingRemoteConfig.length > 0
                    if (hasPending) {
                        root._taskUpdateVisible = !root._taskUpdateVisible
                    } else {
                        if (_checking) return
                        _checking = true
                        _showNoUpdate = false
                        root._checkRemoteConfigUpdate(function() {
                            // 检测完毕，仍无更新
                            taskUpdateEntryBtn._checking = false
                            taskUpdateEntryBtn._showNoUpdate = true
                            noUpdateHideTimer.restart()
                        })
                        // 请求发出后重置 _checking（网络回调里再置 false）
                        // 用一个保底定时器防止卡住
                        Qt.callLater(function() { taskUpdateEntryBtn._checking = false })
                    }
                }

                // 无更新提示自动消失
                Timer {
                    id: noUpdateHideTimer
                    interval: 2500
                    repeat: false
                    onTriggered: taskUpdateEntryBtn._showNoUpdate = false
                }

                ToolTip.visible: hovered || _showNoUpdate
                ToolTip.delay: hovered ? 400 : 0
                ToolTip.text: {
                    if (_showNoUpdate) return "✅ 远程没有任务配置更新"
                    var cnt = Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig.length : 0
                    return cnt > 0 ? "远程有 " + cnt + " 个任务配置更新（点击查看）" : "点击检测远程任务配置更新"
                }

                background: Rectangle {
                    color: taskUpdateEntryBtn.down ? "#4a4a55"
                          : taskUpdateEntryBtn.hovered ? "#33333a" : "#202024"
                    border.color: "#33ffffff"
                    border.width: 1
                    radius: 5
                }
                contentItem: Item {
                    Text {
                        id: bellIcon
                        anchors.centerIn: parent
                        text: "🔔"
                        font.pixelSize: 14
                        opacity: taskUpdateEntryBtn._checking ? 0.5 : 1.0
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }
                    // 红色数字角标，贴在 🔔 右上角
                    Rectangle {
                        visible: Array.isArray(root._pendingRemoteConfig) && root._pendingRemoteConfig.length > 0
                        x: bellIcon.x + bellIcon.width - 4
                        y: bellIcon.y - 3
                        width: 13
                        height: 13
                        radius: 7
                        color: "#e05050"
                        Text {
                            anchors.centerIn: parent
                            text: Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig.length : 0
                            color: "#ffffff"
                            font.pixelSize: 8
                            font.bold: true
                        }
                    }
                }
            }

            // ── 手机比例锁定按钮（📱）紧贴 🖼 按钮左侧 ─────────────────
            // 锁定后每路视频按选定宽高比 (= 宽÷高) 居中显示，模拟手机屏形状，
            // 方便多路对比时画面尺寸与移动端实机一致。常用预设：9:19.5（iPhone）、
            // 9:16（安卓）、3:4（iPad）。状态写到 root.phoneAspectRatio，session 内常驻。
            // 视觉风格与右侧 🖼 按钮保持一致：原生 Button + 自绘背景；锁定时
            // 描边/底色高亮，与 🖼 展开态用同一套配色（#0fa085 / #2a2a32）。
            Button {
                id: phoneAspectBtn
                text: "📱"
                Layout.preferredWidth: 32
                Layout.preferredHeight: 28
                Layout.alignment: Qt.AlignVCenter
                hoverEnabled: true
                onClicked: phoneAspectPopup.openAt(phoneAspectBtn)
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: (root.phoneFixedActive || root.phoneAspectRatio > 0)
                              ? ("已锁定显示尺寸：" + root.phoneAspectLabel + "（点击切换/关闭）")
                              : "锁定视频显示尺寸（点击选择常见手机机型或自定义 W×H）"
                background: Rectangle {
                    color: phoneAspectBtn.down ? "#4a4a55"
                          : phoneAspectBtn.hovered ? "#33333a"
                          : ((root.phoneFixedActive || root.phoneAspectRatio > 0) ? "#2a2a32" : "#202024")
                    border.color: (root.phoneFixedActive || root.phoneAspectRatio > 0) ? "#0fa085" : "#3a3a42"
                    border.width: 1
                    radius: 5
                }
                contentItem: Text {
                    text: phoneAspectBtn.text
                    color: (root.phoneFixedActive || root.phoneAspectRatio > 0) ? "#7fe5cc" : "#e8e8ec"
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                // 视频显示尺寸预设面板：浏览器调试器（Chrome DevTools / Safari）风格。
                // 顶部 W×H 数字输入（实时改 root.phoneFixedWidth/Height），
                // 中部常见手机机型预设（点击即应用），底部"关闭锁定"。
                //
                // 完全自绘的 Popup（不用 Menu，规避 macOS 上 QtQuick.Controls 把
                // Menu 转成原生 NSMenu 导致 background/delegate 全部失效、出现
                // "白底黑字"的问题）。
                //
                // ── 视觉规范：与全局 ToolTip 主题一致（半透明深色 + 浅字）──────
                //  · 背景 #cc1a1a1f（伪毛玻璃，AARRGGBB：α≈80% / 色 #1a1a1f）
                //  · 描边 #33ffffff（白 20% α），圆角 6
                //  · 行高 28，字色 #e8e8ec，font.pixelSize 13
                //  · 悬停整行蓝底 #0a64f0 + 白字（macOS 原生选择观感）
                //  · 已勾选项左侧 ✓（白色 #e8e8ec），不用蓝色（蓝色让位 hover）
                //  · 分隔线 1px #33ffffff
                Popup {
                    id: phoneAspectPopup
                    padding: 6
                    width: 320
                    implicitHeight: phonePopupContent.implicitHeight + padding * 2
                    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

                    // 由按钮触发：相对 ToolBar 弹在按钮顶部上方
                    function openAt(anchorBtn) {
                        var p = anchorBtn.mapToItem(phoneAspectPopup.parent, 0, 0)
                        phoneAspectPopup.x = p.x
                        phoneAspectPopup.y = p.y - phoneAspectPopup.implicitHeight - 2
                        phoneAspectPopup.open()
                    }

                    background: Rectangle {
                        color: "#cc1a1a1f"
                        border.color: "#33ffffff"
                        border.width: 1
                        radius: 6
                    }

                    // 常见机型预设（来源：各厂商官网公开规格 mm 数据，截至 2026-05）。
                    // ⚠ 数据口径：【整机外壳】像素比例（按 W:H mm 换算），不是 Chrome DevTools
                    // 的 CSS 视口尺寸。原因：本工具是视频对比播放器，主要场景是"模拟真机
                    // 实物大小"，CSS 视口比整机更瘦长（不含上下边框），按视口对齐时蓝框
                    // 高度会比真机多约 4%。
                    //   规则：保留 DevTools 标准宽度 W，高度 H 按 (mm_H / mm_W) × W 重算。
                    //   想做 H5 调试参考的同学可以乘上约 1.04 心算补回视口高度。
                    //
                    // header: true 表示分组小标题（不可点击，仅作视觉分组）。
                    ListModel {
                        id: phonePresetModel
                        // ── Apple iPhone ──
                        ListElement { label: "Apple iPhone";                header: true;  w: 0;   h: 0 }
                        ListElement { label: "iPhone 17 Pro Max";           header: false; w: 440; h: 922 }
                        ListElement { label: "iPhone 17 Pro";               header: false; w: 402; h: 839 }
                        ListElement { label: "iPhone 17";                   header: false; w: 402; h: 841 }
                        ListElement { label: "iPhone 16 Pro Max";           header: false; w: 440; h: 924 }
                        ListElement { label: "iPhone 16 Pro";               header: false; w: 402; h: 841 }
                        ListElement { label: "iPhone 16 Plus";              header: false; w: 430; h: 889 }
                        ListElement { label: "iPhone 16";                   header: false; w: 393; h: 810 }
                        ListElement { label: "iPhone 15 Pro Max";           header: false; w: 430; h: 897 }
                        ListElement { label: "iPhone 15 / 14 Pro";          header: false; w: 393; h: 816 }
                        ListElement { label: "iPhone 13 / 12";              header: false; w: 390; h: 800 }
                        ListElement { label: "iPhone SE (3rd gen)";         header: false; w: 375; h: 771 }
                        // ── Huawei 华为 ──
                        ListElement { label: "华为 Huawei";                 header: true;  w: 0;   h: 0 }
                        ListElement { label: "Huawei Mate 70 Pro";          header: false; w: 412; h: 851 }
                        ListElement { label: "Huawei Mate 60 Pro";          header: false; w: 412; h: 882 }
                        ListElement { label: "Huawei Pura 70 Pro";          header: false; w: 412; h: 851 }
                        ListElement { label: "Huawei Pura 70";              header: false; w: 412; h: 877 }
                        // ── Xiaomi 小米 ──
                        ListElement { label: "小米 Xiaomi";                 header: true;  w: 0;   h: 0 }
                        ListElement { label: "Xiaomi 15 Pro";               header: false; w: 412; h: 883 }
                        ListElement { label: "Xiaomi 15";                   header: false; w: 393; h: 841 }
                        ListElement { label: "Xiaomi 14 Pro";               header: false; w: 412; h: 883 }
                        ListElement { label: "Xiaomi 14";                   header: false; w: 393; h: 840 }
                        ListElement { label: "Redmi K70 Pro";               header: false; w: 412; h: 881 }
                        // ── OPPO ──
                        ListElement { label: "OPPO";                        header: true;  w: 0;   h: 0 }
                        ListElement { label: "OPPO Find X8 Pro";            header: false; w: 412; h: 871 }
                        ListElement { label: "OPPO Find X8";                header: false; w: 393; h: 847 }
                        ListElement { label: "OPPO Find X7 Ultra";          header: false; w: 412; h: 883 }
                        // ── vivo ──
                        ListElement { label: "vivo";                        header: true;  w: 0;   h: 0 }
                        ListElement { label: "vivo X200 Pro";               header: false; w: 412; h: 894 }
                        ListElement { label: "vivo X200";                   header: false; w: 412; h: 899 }
                        ListElement { label: "vivo X100 Pro";               header: false; w: 412; h: 897 }
                        // ── Honor 荣耀 ──
                        ListElement { label: "荣耀 Honor";                  header: true;  w: 0;   h: 0 }
                        ListElement { label: "Honor Magic 6 Pro";           header: false; w: 412; h: 883 }
                        ListElement { label: "Honor Magic 5 Pro";           header: false; w: 412; h: 875 }
                        // ── Samsung / Google（保留参考）──
                        ListElement { label: "Samsung / Google";            header: true;  w: 0;   h: 0 }
                        ListElement { label: "Samsung Galaxy S24 Ultra";    header: false; w: 412; h: 846 }
                        ListElement { label: "Samsung Galaxy S20+";         header: false; w: 384; h: 844 }
                        ListElement { label: "Google Pixel 8 Pro";          header: false; w: 412; h: 876 }
                        ListElement { label: "Google Pixel 7";              header: false; w: 412; h: 876 }
                        // ── 平板 ──
                        ListElement { label: "平板 Tablet";                 header: true;  w: 0;   h: 0 }
                        ListElement { label: "iPad mini";                   header: false; w: 768; h: 1114 }
                        ListElement { label: "iPad Pro 11\"";               header: false; w: 834; h: 1167 }
                    }

                    contentItem: ColumnLayout {
                        id: phonePopupContent
                        spacing: 0
                        width: phoneAspectPopup.width - phoneAspectPopup.padding * 2

                        // ── 顶部：单行  [宽] × [高]  × [scale] [▲▼]   [↻] ─────
                        // 设计取舍：
                        //   · 去掉"尺寸/校准"两个语义 Label（图标布局已自解释）；
                        //   · 去掉旋转按钮（低频功能，挤占宽度且与列表预设功能重复）；
                        //   · 左半段 W × H × scale ▲▼ 一气呵成紧凑排列，× 不再被
                        //     fillWidth spacer 推到右边（之前 × 前出现大块空白）；
                        //   · 弹性 spacer 移到 ▲▼ 与 ↻ 之间，让"恢复自动跟随"按钮
                        //     仍能贴右；不显示时整组只在右侧留余白，符合阅读习惯；
                        //   · ▲▼ 紧贴 scale 输入框右侧，做成上下半高的细长按钮，
                        //     视觉上像一个"数字步进器"组件，整组宽度更紧凑。
                        // Popup 总宽 320 - padding 12 = 308 可用；
                        // 内部留 6+6=12 横向 margin → RowLayout 实际可放 296px。
                        // 控件总宽预算（spacing 4、共 6 个间隙 = 24px）：
                        //   64(W) + 8(×) + 64(H) + 8(×) + 50(scale) + 18(▲▼) + 26(↻) = 238
                        //   238 + 24(spacing) + 4(stepper.leftMargin) = 266，余 30px 给
                        //   字体度量浮动与 ↻ 显示时的弹性 spacer，避免再次溢出。
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 6
                            Layout.rightMargin: 6
                            Layout.preferredHeight: 30
                            spacing: 4

                                // 宽度
                                TextField {
                                    id: phoneWInput
                                    Layout.preferredWidth: 64
                                    Layout.preferredHeight: 26
                                    text: root.phoneFixedWidth > 0 ? root.phoneFixedWidth.toString() : ""
                                    placeholderText: "宽"
                                    placeholderTextColor: "#6c7079"
                                    color: "#e8e8ec"
                                    selectionColor: "#0a64f0"
                                    selectedTextColor: "#e8e8ec"
                                    font.pixelSize: 13
                                    horizontalAlignment: TextInput.AlignHCenter
                                    validator: IntValidator { bottom: 0; top: 8192 }
                                    background: Rectangle {
                                        color: "#22ffffff"
                                        border.color: phoneWInput.activeFocus ? "#0a64f0" : "#33ffffff"
                                        border.width: 1
                                        radius: 4
                                    }
                                    onEditingFinished: {
                                        var v = parseInt(text || "0", 10)
                                        if (isNaN(v) || v <= 0) {
                                            root.phoneFixedWidth = 0
                                        } else {
                                            root.phoneFixedWidth = v
                                        }
                                        // 若两边都设了，自动同步比例
                                        if (root.phoneFixedWidth > 0 && root.phoneFixedHeight > 0) {
                                            root.phoneAspectRatio = root.phoneFixedWidth / root.phoneFixedHeight
                                        }
                                    }
                                }
                                Label {
                                    text: "×"
                                    color: "#9aa0a6"
                                    font.pixelSize: 13
                                }
                                // 高度
                                TextField {
                                    id: phoneHInput
                                    Layout.preferredWidth: 64
                                    Layout.preferredHeight: 26
                                    text: root.phoneFixedHeight > 0 ? root.phoneFixedHeight.toString() : ""
                                    placeholderText: "高"
                                    placeholderTextColor: "#6c7079"
                                    color: "#e8e8ec"
                                    selectionColor: "#0a64f0"
                                    selectedTextColor: "#e8e8ec"
                                    font.pixelSize: 13
                                    horizontalAlignment: TextInput.AlignHCenter
                                    validator: IntValidator { bottom: 0; top: 8192 }
                                    background: Rectangle {
                                        color: "#22ffffff"
                                        border.color: phoneHInput.activeFocus ? "#0a64f0" : "#33ffffff"
                                        border.width: 1
                                        radius: 4
                                    }
                                    onEditingFinished: {
                                        var v = parseInt(text || "0", 10)
                                        if (isNaN(v) || v <= 0) {
                                            root.phoneFixedHeight = 0
                                        } else {
                                            root.phoneFixedHeight = v
                                        }
                                        if (root.phoneFixedWidth > 0 && root.phoneFixedHeight > 0) {
                                            root.phoneAspectRatio = root.phoneFixedWidth / root.phoneFixedHeight
                                        }
                                    }
                                }
                                Item { Layout.preferredWidth: 1 }
                                // ── 显示器校准系数：× [scale] [▲▼] ───────────────
                                // 分隔符 "×" 暗示"乘以系数"，无需额外文字 Label。
                                // 间距与左侧 [宽] × [高] 的 × 完全一致（仅靠 RowLayout
                                // 的 spacing: 4 留白，前面的 1px 微调用于视觉对齐）。
                                Label {
                                    text: "×"
                                    color: "#9aa0a6"
                                    font.pixelSize: 13
                                    ToolTip.visible: phoneScaleLabelHover.hovered
                                    ToolTip.delay: 400
                                    ToolTip.text: "屏幕校准系数（蓝框尺寸 = W×H × 此系数）\n仅影响渲染显示，预设 W/H 不变"
                                    HoverHandler { id: phoneScaleLabelHover }
                                }
                                TextField {
                                    id: phoneScaleInput
                                    Layout.preferredWidth: 50
                                    Layout.preferredHeight: 26
                                    text: root.phoneDisplayScale.toFixed(2)
                                    placeholderText: "1.00"
                                    placeholderTextColor: "#6c7079"
                                    color: "#e8e8ec"
                                    selectionColor: "#0a64f0"
                                    selectedTextColor: "#e8e8ec"
                                    font.pixelSize: 13
                                    horizontalAlignment: TextInput.AlignHCenter
                                    validator: DoubleValidator { bottom: 0.1; top: 5.0; decimals: 2; notation: DoubleValidator.StandardNotation }
                                    background: Rectangle {
                                        color: "#22ffffff"
                                        border.color: phoneScaleInput.activeFocus ? "#0a64f0" : "#33ffffff"
                                        border.width: 1
                                        radius: 4
                                    }
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 400
                                    ToolTip.text: "屏幕校准系数（0.1 ~ 5.0）\n蓝框尺寸 = W×H × 此系数\n预设值保持 CSS px 标准不变"
                                    onEditingFinished: {
                                        var v = parseFloat(text || "1")
                                        if (isNaN(v) || v <= 0) v = 1.0
                                        if (v < 0.1) v = 0.1
                                        if (v > 5.0) v = 5.0
                                        root.phoneScaleAutoTrack = false
                                        root.phoneDisplayScale = v
                                        text = v.toFixed(2)
                                    }
                                    // 同步 phoneDisplayScale 外部变化到输入框文本
                                    // （onEditingFinished 里的 `text = ...` 会破坏声明式
                                    // 绑定，需用 Connections 显式补回这条链路）。
                                    Connections {
                                        target: root
                                        function onPhoneDisplayScaleChanged() {
                                            if (!phoneScaleInput.activeFocus)
                                                phoneScaleInput.text = root.phoneDisplayScale.toFixed(2)
                                        }
                                    }
                                }
                                // ── 系数微调步进器（紧贴 scale 输入框）──────────
                                // 设计：上下两个 13px 高的小按钮叠成 26px 步进器，
                                //   宽 18px，整体像数字输入框自带的 spinner，
                                //   单击 ±0.01；长按 500ms 后以 60ms 间隔重复（≈16Hz）；
                                //   严格夹紧到 [0.1, 5.0]；自动关闭 phoneScaleAutoTrack。
                                // 实现：用 MouseArea + Rectangle 而非 Button —— Button
                                //   默认 padding ≈ 6px，把 preferredHeight 设到 13 时
                                //   contentItem 被压扁，且 hover/pressed 状态切换会触
                                //   发 implicitHeight 重算导致"第二次点击不响应"的诡
                                //   异现象。MouseArea 直接锁死命中矩形，行为最稳。
                                Item {
                                    id: phoneScaleStepper
                                    Layout.preferredWidth: 18
                                    Layout.preferredHeight: 26
                                    Layout.leftMargin: 1

                                    // 共享的"持续 ±0.01"Timer（按下时 500ms 延迟启动，
                                    // 之后 60ms 一次；按下方向由 _holdDelta 决定）。
                                    // 放在 Item 层而非每个按钮内：避免两个按钮各自一份
                                    // 状态机互相打架，按下另一个时会自动覆盖方向。
                                    property real _holdDelta: 0
                                    Timer {
                                        id: phoneScaleHoldDelay
                                        interval: 500; repeat: false
                                        onTriggered: phoneScaleHoldRepeat.start()
                                    }
                                    Timer {
                                        id: phoneScaleHoldRepeat
                                        interval: 60; repeat: true
                                        onTriggered: root._stepPhoneScale(phoneScaleStepper._holdDelta)
                                    }

                                    // ▲ 上半区
                                    Rectangle {
                                        id: phoneScaleUpBtn
                                        anchors { left: parent.left; right: parent.right; top: parent.top }
                                        height: 13
                                        radius: 3
                                        border.color: "#33ffffff"
                                        border.width: 1
                                        color: phoneScaleUpMA.pressed ? "#44ffffff"
                                              : phoneScaleUpMA.containsMouse ? "#33ffffff" : "#22ffffff"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "▲"; color: "#e8e8ec"; font.pixelSize: 8
                                        }
                                        MouseArea {
                                            id: phoneScaleUpMA
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            ToolTip.visible: containsMouse
                                            ToolTip.delay: 400
                                            ToolTip.text: "系数 +0.01（长按加速）"
                                            onPressed: {
                                                root._stepPhoneScale(+0.01)
                                                phoneScaleStepper._holdDelta = +0.01
                                                phoneScaleHoldDelay.restart()
                                            }
                                            onReleased: {
                                                phoneScaleHoldDelay.stop()
                                                phoneScaleHoldRepeat.stop()
                                            }
                                            onCanceled: {
                                                phoneScaleHoldDelay.stop()
                                                phoneScaleHoldRepeat.stop()
                                            }
                                        }
                                    }
                                    // ▼ 下半区
                                    Rectangle {
                                        id: phoneScaleDownBtn
                                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                        height: 13
                                        radius: 3
                                        border.color: "#33ffffff"
                                        border.width: 1
                                        color: phoneScaleDownMA.pressed ? "#44ffffff"
                                              : phoneScaleDownMA.containsMouse ? "#33ffffff" : "#22ffffff"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "▼"; color: "#e8e8ec"; font.pixelSize: 8
                                        }
                                        MouseArea {
                                            id: phoneScaleDownMA
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            ToolTip.visible: containsMouse
                                            ToolTip.delay: 400
                                            ToolTip.text: "系数 −0.01（长按加速）"
                                            onPressed: {
                                                root._stepPhoneScale(-0.01)
                                                phoneScaleStepper._holdDelta = -0.01
                                                phoneScaleHoldDelay.restart()
                                            }
                                            onReleased: {
                                                phoneScaleHoldDelay.stop()
                                                phoneScaleHoldRepeat.stop()
                                            }
                                            onCanceled: {
                                                phoneScaleHoldDelay.stop()
                                                phoneScaleHoldRepeat.stop()
                                            }
                                        }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                // 恢复自动跟随（仅在已手动调过时显示）
                                Button {
                                    id: phoneScaleAutoBtn
                                    visible: !root.phoneScaleAutoTrack
                                    Layout.preferredWidth: 26
                                    Layout.preferredHeight: 26
                                    Layout.leftMargin: 0
                                    hoverEnabled: true
                                    focusPolicy: Qt.NoFocus
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 400
                                    ToolTip.text: "恢复自动跟随（按当前显示器重新匹配预设系数）"
                                    background: Rectangle {
                                        color: phoneScaleAutoBtn.hovered ? "#33ffffff" : "transparent"
                                        radius: 4
                                    }
                                    contentItem: Text {
                                        text: "↻"
                                        color: "#e8e8ec"
                                        font.pixelSize: 14
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    onClicked: {
                                        root.phoneScaleAutoTrack = true
                                        root._applyAutoPhoneScale()
                                        phoneScaleInput.text = root.phoneDisplayScale.toFixed(2)
                                    }
                                }
                        }

                        // 分隔线
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.leftMargin: 6
                            Layout.rightMargin: 6
                            Layout.preferredHeight: 1
                            color: "#33ffffff"
                        }

                        // ── 中部：常见机型预设（可滚动）────────────────────
                        // 列表条目较多，用 ListView 自带滚动而非 Repeater，整体高度封顶。
                        ListView {
                            id: phonePresetList
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.min(360, contentHeight)
                            clip: true
                            interactive: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: phonePresetModel
                            spacing: 0

                            ScrollBar.vertical: ScrollBar {
                                policy: ScrollBar.AsNeeded
                                width: 6
                                contentItem: Rectangle {
                                    implicitWidth: 6
                                    radius: 3
                                    color: "#55ffffff"
                                }
                            }

                            delegate: Item {
                                width: phonePresetList.width
                                height: model.header ? 24 : 28

                                // ── 分组小标题（不可点击）──────────────────
                                Text {
                                    visible: model.header
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: 8
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    text: model.label
                                    color: "#9aa0a6"
                                    font.pixelSize: 11
                                    font.bold: true
                                    elide: Text.ElideRight
                                    verticalAlignment: Text.AlignVCenter
                                }

                                // ── 机型行 ─────────────────────────────────
                                Rectangle {
                                    visible: !model.header
                                    anchors.fill: parent
                                    radius: 4
                                    color: presetHover.hovered ? "#0a64f0" : "transparent"

                                    readonly property bool _picked: root.phoneFixedWidth === model.w
                                                                  && root.phoneFixedHeight === model.h

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.left: parent.left
                                        anchors.leftMargin: 8
                                        width: 14
                                        text: parent._picked ? "✓" : ""
                                        color: "#e8e8ec"
                                        font.pixelSize: 12
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.left: parent.left
                                        anchors.leftMargin: 28
                                        text: model.label
                                        color: "#e8e8ec"
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.right: parent.right
                                        anchors.rightMargin: 12
                                        text: model.w + " × " + model.h
                                        color: presetHover.hovered ? "#e8e8ec" : "#9aa0a6"
                                        font.pixelSize: 12
                                        verticalAlignment: Text.AlignVCenter
                                    }

                                    HoverHandler {
                                        id: presetHover
                                        cursorShape: Qt.PointingHandCursor
                                    }
                                    TapHandler {
                                        onTapped: {
                                            root.phoneFixedWidth = model.w
                                            root.phoneFixedHeight = model.h
                                            root.phoneAspectRatio = model.w / model.h
                                            phoneAspectPopup.close()
                                        }
                                    }
                                }
                            }
                        }

                        // 分隔线
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.leftMargin: 6
                            Layout.rightMargin: 6
                            Layout.preferredHeight: 1
                            color: "#33ffffff"
                        }

                        // ── 底部：关闭锁定 ─────────────────────────────────
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 28
                            radius: 4
                            color: clearHover.hovered ? "#0a64f0" : "transparent"

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                width: 14
                                text: (root.phoneFixedWidth <= 0 && root.phoneFixedHeight <= 0
                                       && root.phoneAspectRatio <= 0) ? "✓" : ""
                                color: "#e8e8ec"
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 28
                                text: "原始（关闭锁定）"
                                color: "#e8e8ec"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                            }
                            HoverHandler {
                                id: clearHover
                                cursorShape: Qt.PointingHandCursor
                            }
                            TapHandler {
                                onTapped: {
                                    root.phoneFixedWidth = 0
                                    root.phoneFixedHeight = 0
                                    root.phoneAspectRatio = 0
                                    phoneAspectPopup.close()
                                }
                            }
                        }
                    }
                }
            }

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
                              ? "隐藏参考图侧边栏与提示词底栏"
                              : (root.refHasCurrent
                                 ? "显示参考图与提示词（当前文件夹已绑定）"
                                 : "显示参考图侧边栏与提示词底栏")
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

            // ── "更新可用"胶囊按钮（紧邻参考图按钮右侧）──
            // 设计：原本浮在窗口右上角，会遮挡视频画面/控制条；改为常驻在底部
            //       工具栏左侧，与"参考图"切换按钮同行。仅在 Updater.updateAvailable
            //       时占位（visible=false 时 preferredWidth=0，不留空白）。
            //       点击 → 弹 updateDialog，与原右上角胶囊行为一致。
            Button {
                id: refUpdateBtn
                visible: Updater.updateAvailable
                Layout.preferredWidth: visible ? implicitWidth : 0
                Layout.preferredHeight: 22
                Layout.alignment: Qt.AlignVCenter
                hoverEnabled: true
                padding: 0
                leftPadding: 9
                rightPadding: 9
                onClicked: { updateDialog.userInitiated = false; updateDialog.open() }
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("有新版本 %1 可用，点击查看").arg(Updater.latestVersion || "")
                background: Rectangle {
                    radius: 11
                    // VS Code 蓝色调，与原右上角胶囊一致
                    color: refUpdateBtn.down       ? "#0a4f7d"
                         : refUpdateBtn.hovered    ? "#1177bb"
                                                   : "#0e639c"
                    border.color: "#1f8ad9"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                }
                contentItem: Row {
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
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("快退 5 秒（←）")
            }
            // 上一帧
            FlatButton {
                text: "<"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                enabled: Engine.duration > 0
                onClicked: Engine.stepFrame(-1)
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("上一帧（,）")
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
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: Engine.playing ? qsTr("暂停（Space）")
                                              : qsTr("播放（Space）")
            }
            // 下一帧
            FlatButton {
                text: ">"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                enabled: Engine.duration > 0
                onClicked: Engine.stepFrame(1)
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("下一帧（.）")
            }
            // 快进 5 秒
            FlatButton {
                text: ">>"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                enabled: Engine.duration > 0
                // 相对快进：每路在自己当前位置 +5s，独立时钟的路不被对齐到主时钟
                onClicked: Engine.seekRelative(5)
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("快进 5 秒（→）")
            }
            // 全局重置：所有路 seek 回 0（与快捷键 R 等价）
            FlatButton {
                text: "⟲"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 16
                enabled: Engine.fileCount > 0
                onClicked: Engine.seek(0)
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("全部重置到开头（R）")
            }
            // 视图复位：缩放 + 平移一并归零（同：Ctrl + 鼠标双击）
            // 仅在已有缩放/平移状态时高亮启用，否则置灰但仍占位，避免界面跳动。
            FlatButton {
                id: viewResetBtn
                text: "⊙"
                visible: Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 16
                enabled: Engine.viewTransformed
                opacity: enabled ? 1.0 : 0.45
                onClicked: Engine.resetViewTransform()
                // 用 HoverHandler 独立检测 hover：FlatButton.hovered 在 disabled 时不会
                // 触发，会导致按钮被置灰时无 tooltip，用户不知道这是什么按钮。
                // HoverHandler 不受 enabled 影响，且不会抢走点击事件。
                HoverHandler { id: viewResetHover }
                ToolTip.visible: hovered || viewResetHover.hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("视图复位（缩放/平移归零，同 Ctrl+双击）")
            }

            // ── 多组对比模式专用：上一组 / 下一组 + 组号指示 ──
            // 仅在 multiGroupDialog.active = true 且当前确实有视频时可见；
            // 否则默认完全不占位（包括用户关闭多组对比窗口、清空所有视频回到欢迎页等场景）。
            FlatButton {
                text: "⏮"
                visible: multiGroupDialog.active && Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 14
                enabled: multiGroupDialog.active && Engine.fileCount > 0
                onClicked: { if (root.compareSliderActive) root.compareSliderActive = false; multiGroupDialog.prevGroup() }
                onVisibleChanged: console.log("[MGD][debug] ⏮ btn visible=", visible, "active=", multiGroupDialog.active, "fileCount=", Engine.fileCount)
                Component.onCompleted: console.log("[MGD][debug] ⏮ btn init visible=", visible, "active=", multiGroupDialog.active, "fileCount=", Engine.fileCount)
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("上一组（Ctrl+↑）")
            }
            FlatButton {
                text: "⏭"
                visible: multiGroupDialog.active && Engine.fileCount > 0
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 14
                enabled: multiGroupDialog.active && Engine.fileCount > 0
                onClicked: { if (root.compareSliderActive) root.compareSliderActive = false; multiGroupDialog.nextGroup() }
                onVisibleChanged: console.log("[MGD][debug] ⏭ btn visible=", visible, "active=", multiGroupDialog.active, "fileCount=", Engine.fileCount)
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("下一组（Ctrl+↓）")
            }
            // ── 滑动对比模式切换按钮（质量模式2 且恰好2路时显示，等价于快捷键B）──
            FlatButton {
                text: root.compareSliderActive ? qsTr("⊟ 普通") : qsTr("⊞ 滑动")
                visible: root.isQualitySlideMode && root.compareSliderAvailable
                Layout.preferredWidth: visible ? implicitWidth : 0
                enabled: visible
                onClicked: root._toggleCompareSlider()
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: root.compareSliderActive ? qsTr("退出滑动对比，回到普通模式（B）") : qsTr("进入滑动对比模式（B）")
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
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("切换宫格数量（1 / 2 / 4 / 6 / 9）")
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
                visible: multiGroupDialog.active && Engine.fileCount > 0
                color: "#9a9aa8"
                font.pixelSize: 11
                text: {
                    // 显式触达 stateBumper：MultiGroupDialog 内部状态变更（增删路、勾选、
                    // 重新扫描文件夹等）都会 _bumpState()，从而让本绑定重算，避免出现
                    // "行内 1/2 共 2，底部却 2/20" 这类历史残留导致的不一致。
                    var _bump = multiGroupDialog.stateBumper
                    if (!multiGroupDialog.active) return ""
                    if (Engine.fileCount <= 0) return ""
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

            // ── 评分完成快捷入口：所有组评分完成后浮现，点击打开评分数据面板 ──
            FlatButton {
                id: allRatedShortcutBtn
                text: "📤 评分数据"
                visible: root.reviewMode && multiGroupDialog.active && multiGroupDialog.allGroupsRated
                Layout.preferredWidth: visible ? implicitWidth : 0
                font.pixelSize: 12
                textColor: "#4fc3f7"
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("所有评分已完成，点击查看 / 导出评分数据")
                onClicked: ratingsDialog.open()

                Behavior on opacity { NumberAnimation { duration: 300 } }
                opacity: visible ? 1.0 : 0.0
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

                // ── 单路悬停控制条（全局开关，无快捷键，默认关闭）──
                // 关闭：鼠标悬停在某路视频上时不显示该路的播放控制条，
                //       视野更纯净，专注画面对比。底部全局控制条不受影响。
                // 开启：鼠标悬停时该路浮现进度条 + 帧步 / 重置按钮，
                //       便于对单路做精细控制。
                MenuItem {
                    id: singleControlsHoverItem
                    text: "单路悬停控制条"
                    checkable: true
                    checked: root.singleControlsHoverEnabled
                    onTriggered: root.singleControlsHoverEnabled = !root.singleControlsHoverEnabled
                    implicitHeight: 30
                    background: Rectangle {
                        radius: 4
                        color: singleControlsHoverItem.highlighted ? "#33333a" : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 0
                        Text {
                            leftPadding: 10
                            text: singleControlsHoverItem.checked ? "✓" : ""
                            color: "#6a9fd8"
                            font.pixelSize: 12
                            verticalAlignment: Text.AlignVCenter
                            Layout.minimumWidth: 22
                        }
                        Text {
                            text: singleControlsHoverItem.text
                            color: "#e8e8ec"
                            font.pixelSize: 13
                            verticalAlignment: Text.AlignVCenter
                            Layout.fillWidth: true
                        }
                    }
                }

                // ── 自动重播（默认开启）──
                // 开启：播放到末尾后无缝 seek 回 0 继续播放，画面不停顿。
                // 关闭：保留旧行为，播放结束停在最后一帧（用户可主动按
                //       空格触发 replay）。两套策略共存、互不影响。
                MenuItem {
                    id: autoLoopItem
                    text: "自动重播"
                    checkable: true
                    checked: Engine.loopEnabled
                    onTriggered: Engine.loopEnabled = !Engine.loopEnabled
                    implicitHeight: 30
                    background: Rectangle {
                        radius: 4
                        color: autoLoopItem.highlighted ? "#33333a" : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 0
                        Text {
                            leftPadding: 10
                            text: autoLoopItem.checked ? "✓" : ""
                            color: "#6a9fd8"
                            font.pixelSize: 12
                            verticalAlignment: Text.AlignVCenter
                            Layout.minimumWidth: 22
                        }
                        Text {
                            text: autoLoopItem.text
                            color: "#e8e8ec"
                            font.pixelSize: 13
                            verticalAlignment: Text.AlignVCenter
                            Layout.fillWidth: true
                        }
                    }
                }

                MenuSeparator {
                    contentItem: Rectangle { implicitHeight: 1; color: "#3a3a42" }
                }

                // ── 打开日志目录 ──
                // 用于排查问题：每次启动都会在 <CacheLocation>/logs/ 下生成
                //   playerx_YYYYMMDD_HHmmss.log
                // 包含 fprintf(stderr,...) 与所有 qDebug/qInfo/qWarning/... 输出。
                // 点击此项调用 Fs.revealInFileManager 直接在系统文件管理器里
                // 打开该目录（macOS Finder / Windows Explorer / Linux Files），
                // 用户可手动复制/查看。
                MenuItem {
                    id: openLogDirItem
                    text: "打开日志目录"
                    onTriggered: Fs.revealInFileManager(Fs.appLogDir())
                    implicitHeight: 30
                    background: Rectangle {
                        radius: 4
                        color: openLogDirItem.highlighted ? "#33333a" : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 0
                        Text { leftPadding: 10; text: ""; Layout.minimumWidth: 22 }
                        Text {
                            text: openLogDirItem.text
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
    // 超过当前模式 maxStars 的会被自动钉到上限（如主观模式 Shift+5 → 实际写 3）。
    function _writeRating(idx, score, dimKey) {
        // 超出当前模式上限时仅 UI 层钉一下，避免 cellRatings 写出 "5" 但后端实际存为 3
        // 造成"UI 与实际不一致"。RatingStore::recordRating 内部也会再截一次、双保险。
        // 有维度配置时，上限从该维度的 levels.length 取（每个维度可独立配置星数）；
        // 无维度时才用 Rating.maxStars（C++ 层按模式设定的全局上限）。
        var cap = root.reviewMaxStars
        if (dimKey && root.reviewDimensions && root.reviewDimensions.length > 0) {
            // 找到对应维度，取其 levels 数组长度作为上限
            for (var di = 0; di < root.reviewDimensions.length; ++di) {
                var dim = root.reviewDimensions[di]
                if (dim && dim.key === dimKey && dim.levels && dim.levels.length > 0) {
                    cap = dim.levels.length
                    break
                }
            }
        }
        if (cap > 0 && score > cap) score = cap
        if (score < 0) score = 0
        var arr = root.cellRatings.slice()
        // 有维度配置时（不限于 multi_dim 模式），走多维写入路径
        var hasDims = root.reviewDimensions && root.reviewDimensions.length > 0
        if (hasDims && dimKey) {
            // 多维模式：写入对象的指定维度字段
            while (arr.length <= idx) {
                var emptyObj = {}
                var dims = root.reviewDimensions
                for (var d = 0; d < dims.length; ++d) emptyObj[dims[d].key] = 0
                arr.push(emptyObj)
            }
            // 必须创建新对象才能触发QML属性变更通知
            var oldObj = arr[idx]
            var newObj = (typeof oldObj === "object" && oldObj !== null) ? Object.assign({}, oldObj) : {}
            newObj[dimKey] = score
            arr[idx] = newObj
            root.cellRatings = arr
            // 持久化：file_name 用原始文件名，slide_type 传 "multi_<维度>" 区分各维度
            if (typeof Rating !== "undefined") {
                var fp = Engine.filePathAt(idx)
                if (fp && fp.length > 0) {
                    Rating.recordRating(fp, Engine.fileNameAt(idx), score, idx, "multi_" + dimKey)
                }
            }
        } else {
            // 单维模式：原有逻辑
            while (arr.length <= idx) arr.push(0)
            arr[idx] = score
            root.cellRatings = arr
            if (typeof Rating !== "undefined") {
                var fp2 = Engine.filePathAt(idx)
                if (fp2 && fp2.length > 0) {
            Rating.recordRating(fp2, Engine.fileNameAt(idx), score, idx)
                }
            }
        }
        // 评分变更后 bump，让 allGroupsRated 响应式重算
        multiGroupDialog._bumpState()
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
    Shortcut { sequence: "Shift+1"; context: Qt.ApplicationShortcut
               enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 1
               onActivated: root._setRatingForActive(1) }
    Shortcut { sequence: "Shift+2"; context: Qt.ApplicationShortcut
               enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 2
               onActivated: root._setRatingForActive(2) }
    Shortcut { sequence: "Shift+3"; context: Qt.ApplicationShortcut
               enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 3
               onActivated: root._setRatingForActive(3) }
    // 主观模式 maxStars=3，4/5 这两个快捷键会被 disable，避免误操作写出超限评分。
    Shortcut { sequence: "Shift+4"; context: Qt.ApplicationShortcut
               enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 4
               onActivated: root._setRatingForActive(4) }
    Shortcut { sequence: "Shift+5"; context: Qt.ApplicationShortcut
               enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 5
               onActivated: root._setRatingForActive(5) }
    // 选中切换（不改布局，仅改 selectedIdx + Engine.activeIndex）：[ 上一路 / ] 下一路，循环。
    // 即使 fileCount == 1，也允许按 ] 让 selectedIdx 从 -1 进入 0（"用键盘进入选中状态"）。
    Shortcut { sequence: "[";       context: Qt.ApplicationShortcut; enabled: Engine.fileCount >= 1
               onActivated: root._shiftActive(-1) }
    Shortcut { sequence: "]";       context: Qt.ApplicationShortcut; enabled: Engine.fileCount >= 1
               onActivated: root._shiftActive(+1) }

    // ── 多组对比专用快捷键：上组 / 下组。仅在 multiGroupDialog.active 且当前确实有视频时生效。
    // 选用 Ctrl+↑/↓，避免与现有 ←→（快进快退） / "."","（帧步进）冲突。
    Shortcut {
        sequence: "Ctrl+Up";   context: Qt.ApplicationShortcut
        enabled: multiGroupDialog.active && Engine.fileCount > 0
        onActivated: { if (root.compareSliderActive) root.compareSliderActive = false; multiGroupDialog.prevGroup() }
    }
    Shortcut {
        sequence: "Ctrl+Down"; context: Qt.ApplicationShortcut
        enabled: multiGroupDialog.active && Engine.fileCount > 0
        onActivated: { if (root.compareSliderActive) root.compareSliderActive = false; multiGroupDialog.nextGroup() }
    }

    // ─── 参考图侧边栏 ───────────────────────────────────────────────
    // 锚定：左侧贴边、上下与 videoArea 一致；宽度 = refSidebarWidth（折叠时 0）。
    // 折叠态完全不占位，且通过 visible 控制让其内部 binding 不参与求值，零开销。
    Rectangle {
        id: refSidebar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.topMargin: 2
        // 撑满到窗口底部：让左栏的图1/图2两个区域上下均分整个高度，
        // 不再为底部 CSV 提示词条让位（CSV 底栏只占视频区下方）。
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

        // 当前文件夹名：已隐藏（路径信息转移到侧栏右上角 ⋯ 按钮 ToolTip）
        // 保留 id，refTopPane.anchors.top 与 _refContentTop 计算均依赖它。height:0 不占位。
        Label {
            id: refFolderLabel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: refHeader.bottom
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            anchors.topMargin: 0
            height: 0
            visible: false
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
                // sourceSize 锁成稳定值（不再随容器尺寸变化）
                //   · 历史问题：之前写 width*2 / height*2，会随窗口尺寸变动
                //     按 F / 双击切全屏时，refImageBox 的 width/height 会经历瞬时中间值，
                //     导致 sourceSize 跳变 → Qt 重新解码 → status 回到 Loading → "加载中…"闪现
                //   · 解决：固定 1024×1024，对侧栏参考图（最大也就几百 px 宽）足够清晰；
                //     PreserveAspectFit 保留比例显示，sourceSize 只是解码上限不强制比例
                //   · 副作用：内存略升（从动态变为常驻 1024 上限），但侧栏只 1 张图，可忽略
                sourceSize.width:  1024
                sourceSize.height: 1024
                // 切换图片时不闪"加载中…"：
                //   · Image 在 source 变更但新图未 Ready 时，仍持有上一张已解码的纹理；
                //     只要保持 visible:true，这一张旧图就会原地停留到新图 Ready 才被替换。
                //   · 之前用 status === Ready 作为 visible 条件，会在 Loading 瞬间把图隐藏，
                //     让位给"加载中…"占位 → 视觉上一闪。
                //   · 现在改为"未出错就一直显示"：Ready 显新图、Loading 续旧图、Error/Null 让位占位。
                visible: root.refHasCurrent && status !== Image.Error
                asynchronous: true

                // 双击图片本体也能放大查看（与右上角 ⤢ 按钮等价）
                //   · 设计：常见图片查看器的"双击查看原图"惯用手势，无视觉打扰
                //   · 单击不做任何事（避免误触），仅 onDoubleClicked 触发 Lightbox
                //   · z 默认 0，低于 refImageZoomBtn(z:2)，按钮区域不会被这层吃掉
                //   · cursorShape 给个手型，暗示可点击；ToolTip 第一次 hover 时提示双击
                MouseArea {
                    id: refImageDblMA
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.PointingHandCursor
                    onDoubleClicked: refLightbox.open()
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 800
                    ToolTip.text: "双击放大查看"
                }
            }

            // 右上角操作按钮组：⋯ 重选 / ⤢ 放大 / ✕ 清除
            //   · 仅在已绑定参考图时显示（与视频窗口右上角同风格、同语义）
            //   · 释放底部按钮条空间，让图片预览区获得更大显示面积
            //   · z:2 置顶，覆盖于 DropArea 之上；按钮自身只吃点击，不影响整体拖拽接收
            Row {
                id: refImageBtnRow
                z: 2
                anchors.top: refImage.top
                anchors.right: refImage.right
                anchors.topMargin: 8
                anchors.rightMargin: 8
                spacing: 4
                visible: refImage.visible

                // ⋯ 重选菜单（弹出小菜单：重选图片 / 重选文件夹）
                Rectangle {
                    id: refImageMoreBtn
                    width: 28; height: 28
                    radius: 4
                    color: refImageMoreBtnMA.pressed ? "#3a3a45"
                         : refImageMoreBtnMA.containsMouse ? "#2a2a32cc"
                         : "#1a1a1d99"
                    border.color: refImageMoreBtnMA.containsMouse ? "#5a8fd8" : "#3a3a45"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -2
                        text: "⋯"
                        color: refImageMoreBtnMA.containsMouse ? "#ffffff" : "#d0d0d8"
                        font.pixelSize: 18
                        font.bold: true
                    }
                    MouseArea {
                        id: refImageMoreBtnMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton
                        onClicked: refImageMoreMenu.open()
                        // ToolTip 直接显示当前参考图完整路径（去掉 file:// 前缀），
                        // 未绑定时回退为"更多操作"提示。
                        ToolTip.visible: containsMouse && !refImageMoreMenu.visible
                        ToolTip.delay: 400
                        ToolTip.text: {
                            var u = String(root.refCurrentUrl)
                            if (u.length === 0) return "更多操作（重新选择图片 / 文件夹 / 分组多图）"
                            // grouped 模式优先显示「根目录 + 当前图」，便于诊断
                            if (root.refCurrentMode === "grouped") {
                                var rootDir = Reference.groupedRootOf(root.refCurrentFolder) || ""
                                var cur = decodeURIComponent(u.replace(/^file:\/\//, ""))
                                if (rootDir.length > 0) return "[分组多图] 根目录: " + rootDir + "\n当前: " + cur
                                return cur
                            }
                            return decodeURIComponent(u.replace(/^file:\/\//, ""))
                        }
                    }
                    // 重选菜单：深色主题，与侧栏胶囊按钮同调。
                    //   · Menu.background：不透明深色背景 + 薄边框，区别于底层画面
                    //   · MenuItem.background / contentItem：hover 高亮、文字颜色与控件主题一致
                    Menu {
                        id: refImageMoreMenu
                        y: refImageMoreBtn.height + 2
                        padding: 4
                        background: Rectangle {
                            // 文案由“重新选择图片”简化为“图片/文件夹/多文件夹”，
                            // 宽度同步收窄，避免右侧出现大片空白。
                            // 背景与头部“三个点”按钮保持一致的玻璃半透明风格：
                            //   · 颜色给 cc 约 80% alpha，边框与按钮同款 #3a3a45。
                            implicitWidth: 110
                            color: "#1a1a1dcc"
                            border.color: "#3a3a45"
                            border.width: 1
                            radius: 4
                        }
                        delegate: MenuItem {
                            id: refImageMoreMenuItem
                            implicitHeight: 28
                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: 10
                                verticalAlignment: Text.AlignVCenter
                                text: refImageMoreMenuItem.text
                                color: refImageMoreMenuItem.highlighted ? "#ffffff" : "#d0d0d8"
                                font.pixelSize: 12
                            }
                            background: Rectangle {
                                radius: 3
                                color: refImageMoreMenuItem.highlighted ? "#2a2a32" : "transparent"
                            }
                        }
                        // 注意：直接子 MenuItem 不会走上面的 delegate（delegate 只对
                        // 通过 model/Repeater 实例化的项生效），所以样式必须写在每个
                        // MenuItem 自身。需求：纯深色底 + 白字，去掉所有 highlight 变色，
                        // 鼠标悬停/选中均不变色，点击直接 onTriggered 起效。
                        // 样式说明：默认透明底；hover 时整行加一个深灰底，文字保持不变，
                        // 不再使用下划线，避免视觉过重。
                        MenuItem {
                            id: refImageMoreItem1
                            text: "图片"
                            implicitHeight: 28
                            onTriggered: refSidebarFileDlg.open()
                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: 10
                                verticalAlignment: Text.AlignVCenter
                                text: refImageMoreItem1.text
                                color: "#e8e8ec"
                                font.pixelSize: 12
                            }
                            background: Rectangle {
                                radius: 3
                                color: refImageMoreItem1.hovered ? "#2a2a32cc" : "transparent"
                            }
                            arrow: Item {}
                            indicator: Item {}
                        }
                        MenuItem {
                            id: refImageMoreItem2
                            text: "文件夹"
                            implicitHeight: 28
                            onTriggered: refSidebarDirDlg.open()
                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: 10
                                verticalAlignment: Text.AlignVCenter
                                text: refImageMoreItem2.text
                                color: "#e8e8ec"
                                font.pixelSize: 12
                            }
                            background: Rectangle {
                                radius: 3
                                color: refImageMoreItem2.hovered ? "#2a2a32cc" : "transparent"
                            }
                            arrow: Item {}
                            indicator: Item {}
                        }
                        // 分组多图根目录：root/组A/图... · root/组B/图...
                        // 跟随对比组跳到同名子组的「组首」；◀▶递归跨组翻图。
                        MenuItem {
                            id: refImageMoreItem3
                            text: "多文件夹"
                            implicitHeight: 28
                            onTriggered: refSidebarGroupedDlg.open()
                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: 10
                                verticalAlignment: Text.AlignVCenter
                                text: refImageMoreItem3.text
                                color: "#e8e8ec"
                                font.pixelSize: 12
                            }
                            background: Rectangle {
                                radius: 3
                                color: refImageMoreItem3.hovered ? "#2a2a32cc" : "transparent"
                            }
                            arrow: Item {}
                            indicator: Item {}
                        }
                    }
                }

                // ⤢ 放大查看（弹 Lightbox）
                Rectangle {
                    id: refImageZoomBtn
                    width: 28; height: 28
                    radius: 4
                    color: refImageZoomBtnMA.pressed ? "#3a3a45"
                         : refImageZoomBtnMA.containsMouse ? "#2a2a32cc"
                         : "#1a1a1d99"
                    border.color: refImageZoomBtnMA.containsMouse ? "#5a8fd8" : "#3a3a45"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "⤢"
                        color: refImageZoomBtnMA.containsMouse ? "#ffffff" : "#d0d0d8"
                        font.pixelSize: 16
                        font.bold: true
                    }
                    MouseArea {
                        id: refImageZoomBtnMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton
                        onClicked: refLightbox.open()
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "放大查看（滚轮缩放，← → 翻页，Esc 关闭）"
                    }
                }

                // ✕ 清除当前绑定
                Rectangle {
                    id: refImageClearBtn
                    width: 28; height: 28
                    radius: 4
                    color: refImageClearBtnMA.pressed ? "#5a2a2a"
                         : refImageClearBtnMA.containsMouse ? "#3a2228cc"
                         : "#1a1a1d99"
                    border.color: refImageClearBtnMA.containsMouse ? "#e0454d" : "#3a3a45"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: refImageClearBtnMA.containsMouse ? "#ffffff" : "#e8b0b0"
                        font.pixelSize: 14
                        font.bold: true
                    }
                    MouseArea {
                        id: refImageClearBtnMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton
                        onClicked: {
                            if (root.refCurrentFolder.length > 0)
                                Reference.clearReference(root.refCurrentFolder)
                        }
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "清除当前参考图绑定"
                    }
                }
            }

            // 加载中 / 失败 / 未绑定占位
            //   · 未绑定时：占位文案 + 居中两按钮（📷 图片 / 📁 文件夹），
            //     替代原先底部按钮条的入口，让图片区铺满更多空间。
            Column {
                anchors.centerIn: parent
                width: parent.width - 24
                spacing: 12
                visible: !refImage.visible

                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: "#6a6a78"
                    font.pixelSize: 12
                    text: {
                        if (root.refCurrentFolder.length === 0)
                            return "请选中任一通道，\n或在「打开文件夹」对话框中为该路绑定参考图"
                        if (!root.refHasCurrent)
                            return "该文件夹未绑定参考图\n\n选一张固定图，或让参考图随对比组切换\n（也可直接把图片或图片文件夹拖进来）"
                        // Loading 分支移除：Image 在 Loading 期间仍 visible 显示旧图，占位根本不会出现。
                        if (refImage.status === Image.Error)    return "图片无法加载（可能已被移动或删除）"
                        return ""
                    }
                }

                // 中央两个选择按钮：仅在"未绑定但已选中通道"时出现
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8
                    visible: root.refCurrentFolder.length > 0 && !root.refHasCurrent
                    Button {
                        id: refPickImgBtnCenter
                        text: "📷 图片"
                        implicitWidth: 96
                        implicitHeight: 28
                        hoverEnabled: true
                        onClicked: refSidebarFileDlg.open()
                        ToolTip.visible: hovered
                        ToolTip.delay: 400
                        ToolTip.text: "选择一张固定参考图（整组对比始终显示这张）"
                        background: Rectangle {
                            color: refPickImgBtnCenter.down ? "#4a4a55"
                                 : refPickImgBtnCenter.hovered ? "#33333a"
                                 : "#202024"
                            border.color: refPickImgBtnCenter.hovered ? "#5a8fd8" : "#3a3a45"
                            border.width: 1
                            radius: 4
                        }
                        contentItem: Text {
                            text: refPickImgBtnCenter.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    Button {
                        id: refPickDirBtnCenter
                        text: "📁 文件夹"
                        implicitWidth: 96
                        implicitHeight: 28
                        hoverEnabled: true
                        onClicked: refSidebarDirDlg.open()
                        ToolTip.visible: hovered
                        ToolTip.delay: 400
                        ToolTip.text: "选择图片文件夹（参考图按对比组自动同步）"
                        background: Rectangle {
                            color: refPickDirBtnCenter.down ? "#4a4a55"
                                 : refPickDirBtnCenter.hovered ? "#33333a"
                                 : "#202024"
                            border.color: refPickDirBtnCenter.hovered ? "#0fa085" : "#3a3a45"
                            border.width: 1
                            radius: 4
                        }
                        contentItem: Text {
                            text: refPickDirBtnCenter.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    // 「分组多图」入口：root/组A/图... · root/组B/图...
                    // 跟随对比组跳到同名子组首图；◀▶递归跨组翻图。
                    Button {
                        id: refPickGroupedBtnCenter
                        text: "🗂 分组多图"
                        implicitWidth: 96
                        implicitHeight: 28
                        hoverEnabled: true
                        onClicked: refSidebarGroupedDlg.open()
                        ToolTip.visible: hovered
                        ToolTip.delay: 400
                        ToolTip.text: "选择两级文件夹：root/组A/图... · root/组B/图...\n跟随对比组跳到同名子组首图；◀▶递归跨组翻图"
                        background: Rectangle {
                            color: refPickGroupedBtnCenter.down ? "#4a4a55"
                                 : refPickGroupedBtnCenter.hovered ? "#33333a"
                                 : "#202024"
                            border.color: refPickGroupedBtnCenter.hovered ? "#c89020" : "#3a3a45"
                            border.width: 1
                            radius: 4
                        }
                        contentItem: Text {
                            text: refPickGroupedBtnCenter.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
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
                visible: root.refCanNav && root.refImageCount > 1

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
                    // 循环切换：只要≥2 张图就可用（越过头/尾会装回）。
                    property bool enabled: root.refImageCount > 1
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
                    // 循环切换：与 ◀ 保持一致。
                    property bool enabled: root.refImageCount > 1
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
            }
        }

        // 模式 / 进度小标签：已隐藏（信息与 CSV 底栏重复，这里不再占用侧栏高度）
        Rectangle {
            id: refModeBar
            anchors.left: refTopPane.left
            anchors.right: refTopPane.right
            anchors.bottom: refButtonsBar.top
            height: 0
            visible: false
            color: "transparent"
        }

        // 底部按钮条：已移除（选择入口合并到右上角 ⋯ 菜单 + 未绑定时中央两按钮）
        // 保留空壳，让 anchors.bottom: refButtonsBar.top 这类既有引用继续生效；
        // height: 0 / visible: false 不占任何高度。
        Rectangle {
            id: refButtonsBar
            anchors.left: refTopPane.left
            anchors.right: refTopPane.right
            anchors.bottom: refTopPane.bottom
            height: 0
            visible: false
            color: "transparent"
        }

        // ─── 上下分隔条（可拖动调整上下两栏比例）─────────────────────
        // 用 fraction 表示上半占"内容区"剩余高度的比例（0.18 ~ 0.85），
        // 拖动时实时改变，但不持久化（保持轻量）。
        property real refTopFraction: 0.5
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
                onDoubleClicked: refSidebar.refTopFraction = 0.5  // 双击复位（上下均分）
            }
        }

        // ─── 下半："参考图 2" 区（与上半完全镜像）───────────────────
        Item {
            id: refBottomPane
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: refSplitter.bottom
            anchors.bottom: parent.bottom
        }

        // 中央图片区 + 拖拽接收 + 占位提示（与 refImageBox 完全对齐，但操作的是 slot2）
        Rectangle {
            id: refImageBox2
            anchors.left: refBottomPane.left
            anchors.right: refBottomPane.right
            anchors.top: refBottomPane.top
            anchors.bottom: refButtonsBar2.top
            anchors.margins: 8
            color: "#0e0e10"
            border.color: refDrop2.containsDrag ? "#5a8fd8" : "#2c2c32"
            border.width: 1
            radius: 4

            Image {
                id: refImage2
                anchors.fill: parent
                anchors.margins: 4
                source: root.refCurrentUrl2
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                cache: true
                sourceSize.width:  1024
                sourceSize.height: 1024
                // 与 refImage 同策略：Loading 期间续显旧图，避免"加载中…"闪现。
                visible: root.refHasCurrent2 && status !== Image.Error
                asynchronous: true

                MouseArea {
                    id: refImage2DblMA
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.PointingHandCursor
                    onDoubleClicked: refLightbox.openSlot(2)
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 800
                    ToolTip.text: "双击放大查看"
                }
            }

            // 右上角操作按钮组：⋯ 重选 / ⤢ 放大 / ✕ 清除（slot2 版）
            Row {
                id: refImageBtnRow2
                z: 2
                anchors.top: refImage2.top
                anchors.right: refImage2.right
                anchors.topMargin: 8
                anchors.rightMargin: 8
                spacing: 4
                visible: refImage2.visible

                // ⋯ 重选菜单
                Rectangle {
                    id: refImageMoreBtn2
                    width: 28; height: 28
                    radius: 4
                    color: refImageMoreBtn2MA.pressed ? "#3a3a45"
                         : refImageMoreBtn2MA.containsMouse ? "#2a2a32cc"
                         : "#1a1a1d99"
                    border.color: refImageMoreBtn2MA.containsMouse ? "#5a8fd8" : "#3a3a45"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -2
                        text: "⋯"
                        color: refImageMoreBtn2MA.containsMouse ? "#ffffff" : "#d0d0d8"
                        font.pixelSize: 18
                        font.bold: true
                    }
                    MouseArea {
                        id: refImageMoreBtn2MA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton
                        onClicked: refImageMoreMenu2.open()
                        ToolTip.visible: containsMouse && !refImageMoreMenu2.visible
                        ToolTip.delay: 400
                        ToolTip.text: {
                            var u = String(root.refCurrentUrl2)
                            if (u.length === 0) return "更多操作（重新选择图片 / 文件夹 / 分组多图）"
                            if (root.refCurrentMode2 === "grouped") {
                                var rootDir = Reference.groupedRootOf2(root.refCurrentFolder) || ""
                                var cur = decodeURIComponent(u.replace(/^file:\/\//, ""))
                                if (rootDir.length > 0) return "[分组多图] 根目录: " + rootDir + "\n当前: " + cur
                                return cur
                            }
                            return decodeURIComponent(u.replace(/^file:\/\//, ""))
                        }
                    }
                    // 重选菜单（slot2 版）：玻璃半透明主题，与三个点按钮一致。
                    Menu {
                        id: refImageMoreMenu2
                        y: refImageMoreBtn2.height + 2
                        padding: 4
                        background: Rectangle {
                            implicitWidth: 110
                            color: "#1a1a1dcc"
                            border.color: "#3a3a45"
                            border.width: 1
                            radius: 4
                        }
                        delegate: MenuItem {
                            id: refImageMoreMenu2Item
                            implicitHeight: 28
                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: 10
                                verticalAlignment: Text.AlignVCenter
                                text: refImageMoreMenu2Item.text
                                color: refImageMoreMenu2Item.highlighted ? "#ffffff" : "#d0d0d8"
                                font.pixelSize: 12
                            }
                            background: Rectangle {
                                radius: 3
                                color: refImageMoreMenu2Item.highlighted ? "#2a2a32" : "transparent"
                            }
                        }
                        // 同图1：直接 MenuItem 不走 delegate，样式写在自身。
                        MenuItem {
                            id: refImageMoreItem2_1
                            text: "图片"
                            implicitHeight: 28
                            onTriggered: refSidebarFileDlg2.open()
                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: 10
                                verticalAlignment: Text.AlignVCenter
                                text: refImageMoreItem2_1.text
                                color: "#e8e8ec"
                                font.pixelSize: 12
                            }
                            background: Rectangle {
                                radius: 3
                                color: refImageMoreItem2_1.hovered ? "#2a2a32cc" : "transparent"
                            }
                            arrow: Item {}
                            indicator: Item {}
                        }
                        MenuItem {
                            id: refImageMoreItem2_2
                            text: "文件夹"
                            implicitHeight: 28
                            onTriggered: refSidebarDirDlg2.open()
                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: 10
                                verticalAlignment: Text.AlignVCenter
                                text: refImageMoreItem2_2.text
                                color: "#e8e8ec"
                                font.pixelSize: 12
                            }
                            background: Rectangle {
                                radius: 3
                                color: refImageMoreItem2_2.hovered ? "#2a2a32cc" : "transparent"
                            }
                            arrow: Item {}
                            indicator: Item {}
                        }
                        MenuItem {
                            id: refImageMoreItem2_3
                            text: "多文件夹"
                            implicitHeight: 28
                            onTriggered: refSidebarGroupedDlg2.open()
                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: 10
                                verticalAlignment: Text.AlignVCenter
                                text: refImageMoreItem2_3.text
                                color: "#e8e8ec"
                                font.pixelSize: 12
                            }
                            background: Rectangle {
                                radius: 3
                                color: refImageMoreItem2_3.hovered ? "#2a2a32cc" : "transparent"
                            }
                            arrow: Item {}
                            indicator: Item {}
                        }
                    }
                }

                // ⤢ 放大
                Rectangle {
                    id: refImageZoomBtn2
                    width: 28; height: 28
                    radius: 4
                    color: refImageZoomBtn2MA.pressed ? "#3a3a45"
                         : refImageZoomBtn2MA.containsMouse ? "#2a2a32cc"
                         : "#1a1a1d99"
                    border.color: refImageZoomBtn2MA.containsMouse ? "#5a8fd8" : "#3a3a45"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "⤢"
                        color: refImageZoomBtn2MA.containsMouse ? "#ffffff" : "#d0d0d8"
                        font.pixelSize: 16
                        font.bold: true
                    }
                    MouseArea {
                        id: refImageZoomBtn2MA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton
                        onClicked: refLightbox.openSlot(2)
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "放大查看（滚轮缩放，← → 翻页，Esc 关闭）"
                    }
                }

                // ✕ 清除当前绑定
                Rectangle {
                    id: refImageClearBtn2
                    width: 28; height: 28
                    radius: 4
                    color: refImageClearBtn2MA.pressed ? "#5a2a2a"
                         : refImageClearBtn2MA.containsMouse ? "#3a2228cc"
                         : "#1a1a1d99"
                    border.color: refImageClearBtn2MA.containsMouse ? "#e0454d" : "#3a3a45"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: refImageClearBtn2MA.containsMouse ? "#ffffff" : "#e8b0b0"
                        font.pixelSize: 14
                        font.bold: true
                    }
                    MouseArea {
                        id: refImageClearBtn2MA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton
                        onClicked: {
                            if (root.refCurrentFolder.length > 0)
                                Reference.clearReference2(root.refCurrentFolder)
                        }
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "清除当前参考图绑定"
                    }
                }
            }

            // 占位 + 未绑定时居中两按钮（slot2 版）
            Column {
                anchors.centerIn: parent
                width: parent.width - 24
                spacing: 12
                visible: !refImage2.visible

                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: "#6a6a78"
                    font.pixelSize: 12
                    text: {
                        if (root.refCurrentFolder.length === 0)
                            return "请选中任一通道，\n或在「打开文件夹」对话框中为该路绑定参考图"
                        if (!root.refHasCurrent2)
                            return "该文件夹未绑定第 2 张参考图\n\n选一张固定图，或让参考图随对比组切换\n（也可直接把图片或图片文件夹拖进来）"
                // Loading 分支移除：理由同 refImage 占位文案。
                        if (refImage2.status === Image.Error)   return "图片无法加载（可能已被移动或删除）"
                        return ""
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8
                    visible: root.refCurrentFolder.length > 0 && !root.refHasCurrent2
                    Button {
                        id: refPickImgBtnCenter2
                        text: "📷 图片"
                        implicitWidth: 96
                        implicitHeight: 28
                        hoverEnabled: true
                        onClicked: refSidebarFileDlg2.open()
                        ToolTip.visible: hovered
                        ToolTip.delay: 400
                        ToolTip.text: "选择一张固定参考图（整组对比始终显示这张）"
                        background: Rectangle {
                            color: refPickImgBtnCenter2.down ? "#4a4a55"
                                 : refPickImgBtnCenter2.hovered ? "#33333a"
                                 : "#202024"
                            border.color: refPickImgBtnCenter2.hovered ? "#5a8fd8" : "#3a3a45"
                            border.width: 1
                            radius: 4
                        }
                        contentItem: Text {
                            text: refPickImgBtnCenter2.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    Button {
                        id: refPickDirBtnCenter2
                        text: "📁 文件夹"
                        implicitWidth: 96
                        implicitHeight: 28
                        hoverEnabled: true
                        onClicked: refSidebarDirDlg2.open()
                        ToolTip.visible: hovered
                        ToolTip.delay: 400
                        ToolTip.text: "选择图片文件夹（参考图按对比组自动同步）"
                        background: Rectangle {
                            color: refPickDirBtnCenter2.down ? "#4a4a55"
                                 : refPickDirBtnCenter2.hovered ? "#33333a"
                                 : "#202024"
                            border.color: refPickDirBtnCenter2.hovered ? "#0fa085" : "#3a3a45"
                            border.width: 1
                            radius: 4
                        }
                        contentItem: Text {
                            text: refPickDirBtnCenter2.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    // 「分组多图」入口（slot2 版）
                    Button {
                        id: refPickGroupedBtnCenter2
                        text: "🗂 分组多图"
                        implicitWidth: 96
                        implicitHeight: 28
                        hoverEnabled: true
                        onClicked: refSidebarGroupedDlg2.open()
                        ToolTip.visible: hovered
                        ToolTip.delay: 400
                        ToolTip.text: "选择两级文件夹：root/组A/图... · root/组B/图...\n跟随对比组跳到同名子组首图；◀▶ 递归跨组翻图"
                        background: Rectangle {
                            color: refPickGroupedBtnCenter2.down ? "#4a4a55"
                                 : refPickGroupedBtnCenter2.hovered ? "#33333a"
                                 : "#202024"
                            border.color: refPickGroupedBtnCenter2.hovered ? "#c89020" : "#3a3a45"
                            border.width: 1
                            radius: 4
                        }
                        contentItem: Text {
                            text: refPickGroupedBtnCenter2.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            // 拖拽接收（slot2 版）
            DropArea {
                id: refDrop2
                anchors.fill: parent
                onDropped: function(drop) {
                    if (root.refCurrentFolder.length === 0) { drop.accepted = false; return }
                    if (!drop.hasUrls) { drop.accepted = false; return }
                    for (var i = 0; i < drop.urls.length; ++i) {
                        var u = drop.urls[i]
                        if (Fs.isDirectory(u)) {
                            if (Reference.setReferenceFolderUrl2(root.refCurrentFolder, u)) {
                                drop.accepted = true; return
                            }
                        }
                    }
                    for (var j = 0; j < drop.urls.length; ++j) {
                        var u2 = drop.urls[j]
                        if (Reference.setReferenceUrl2(root.refCurrentFolder, u2)) {
                            drop.accepted = true; return
                        }
                    }
                    drop.accepted = false
                }
            }

            // ◀ ▶ 浮层切换按钮（slot2 版，仅 folder 模式 / 总数>1 时可见）
            Row {
                id: refImgNavBar2
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 6
                spacing: 4
                visible: root.refCanNav2 && root.refImageCount2 > 1

                Rectangle {
                    id: refPrevBtn2
                    width: 28; height: 24
                    radius: 3
                    color: prevMA2.pressed ? "#3a3a45"
                          : prevMA2.containsMouse ? "#2a2a32"
                          : "#1a1a1da0"
                    border.color: refPrevBtn2.enabled ? "#5a5a65" : "#2a2a32"
                    border.width: 1
                    // 循环切换：只要≥2 张图就可用。
                    property bool enabled: root.refImageCount2 > 1
                    Text {
                        anchors.centerIn: parent
                        text: "◀"
                        font.pixelSize: 12
                        color: refPrevBtn2.enabled ? "#e8e8ec" : "#555"
                    }
                    MouseArea {
                        id: prevMA2
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: refPrevBtn2.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: { if (refPrevBtn2.enabled) root._refImgOffset2 -= 1 }
                    }
                    ToolTip.visible: prevMA2.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "上一张参考图（手动浏览）"
                }

                Rectangle {
                    id: refNextBtn2
                    width: 28; height: 24
                    radius: 3
                    color: nextMA2.pressed ? "#3a3a45"
                          : nextMA2.containsMouse ? "#2a2a32"
                          : "#1a1a1da0"
                    border.color: refNextBtn2.enabled ? "#5a5a65" : "#2a2a32"
                    border.width: 1
                    // 循环切换。
                    property bool enabled: root.refImageCount2 > 1
                    Text {
                        anchors.centerIn: parent
                        text: "▶"
                        font.pixelSize: 12
                        color: refNextBtn2.enabled ? "#e8e8ec" : "#555"
                    }
                    MouseArea {
                        id: nextMA2
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: refNextBtn2.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: { if (refNextBtn2.enabled) root._refImgOffset2 += 1 }
                    }
                    ToolTip.visible: nextMA2.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "下一张参考图（手动浏览）"
                }
            }
        }

        // 模式 / 进度小标签（slot2 版）：已隐藏（信息与 CSV 底栏冗余）
        Rectangle {
            id: refModeBar2
            anchors.left: refBottomPane.left
            anchors.right: refBottomPane.right
            anchors.bottom: refButtonsBar2.top
            height: 0
            visible: false
            color: "transparent"
        }

        // 底部按钮条（slot2 版）：已移除（选择入口合并到右上角 ⋯ 菜单 + 未绑定时中央两按钮）
        // 保留空壳，让 anchors.bottom: refButtonsBar2.top 这类既有引用继续生效。
        Rectangle {
            id: refButtonsBar2
            anchors.left: refBottomPane.left
            anchors.right: refBottomPane.right
            anchors.bottom: refBottomPane.bottom
            height: 0
            visible: false
            color: "transparent"
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

    // 侧边栏：选择「分组多图」根目录（grouped 模式）
    //   预期结构：root/组A/图1.jpg · root/组A/图2.jpg · root/组B/图1.jpg ...
    //   跟随对比组切换时：按名称/索引对齐到同名子组的「组首」；◀▶在长队列上递归跨组。
    FolderDialog {
        id: refSidebarGroupedDlg
        title: "选择参考图根目录（分组多图、两级文件夹）"
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            if (!Reference.setGroupedFolderUrl(root.refCurrentFolder, selectedFolder)) {
                // 路径结构不符合（无子目录 / 子目录里无图片）时静默失败。
            }
        }
    }

    // 侧边栏（槽位 2）：选择单张参考图
    FileDialog {
        id: refSidebarFileDlg2
        title: "选择参考图（固定图）"
        nameFilters: [ "图片 (*.png *.jpg *.jpeg *.webp *.bmp *.gif)" ]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            Reference.setReferenceUrl2(root.refCurrentFolder, selectedFile)
        }
    }

    // 侧边栏（槽位 2）：选择参考图文件夹
    FolderDialog {
        id: refSidebarDirDlg2
        title: "选择第 2 张参考图文件夹（跟随对比组）"
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            if (!Reference.setReferenceFolderUrl2(root.refCurrentFolder, selectedFolder)) {
                // 静默失败
            }
        }
    }

    // 侧边栏（槽位 2）：选择「分组多图」根目录
    FolderDialog {
        id: refSidebarGroupedDlg2
        title: "选择第 2 张参考图根目录（分组多图、两级文件夹）"
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            if (!Reference.setGroupedFolderUrl2(root.refCurrentFolder, selectedFolder)) {
                // 静默失败
            }
        }
    }

    // ─── 全局 CSV 文本底栏 ────────────────────────────────────────────
    //
    // 设计动机：
    //   把原侧边栏「下半区 CSV 文本」搬到窗口最底（位于 videoArea 之下、
    //   ApplicationWindow 底部）。原因有三：
    //     1) prompt 是横向长文本，窄竖侧栏不适合阅读，横向底栏天然适配；
    //     2) 看视频时希望 prompt 与画面"始终同步可见"，底栏不与视频争空间；
    //     3) 与窗口底部其他全局元素对齐，符合常见编辑器/查看器布局。
    //
    // 折叠机制：
    //   csvBottomBarExpanded 控制展开/折叠：
    //     · 展开：完整显示 prompt + 中/英 / ◀▶ / 重置 / CSV / 清除按钮（约 88px 高）
    //     · 折叠：仅显示一行高度的标题条（含展开箭头 + 进度，约 24px 高）
    //   都没绑定 CSV / 没视频时整个底栏隐藏，零占位。
    //   注：当前为 session 内状态（重启后回到默认展开），保持轻量；
    //       后续如需持久化可加 Qt.labs.settings 模块。
    property bool csvBottomBarExpanded: true

    Rectangle {
        id: csvBottomBar
        // 与视频窗口同宽：左侧紧贴 refSidebar 右边，避开左栏图片区域。
        //   - 这样左栏的「图1 / 图2」可以上下均分撑满整个高度，没有黑色空白；
        //   - prompt 文本只占视频区下方的横向空间，与视频画面始终对齐。
        // 与「参考图侧边栏」作为一个整体出现/隐藏（用户工作流：要么同时看图+词，
        // 要么都不看），由 refSidebarVisible 一并控制。
        anchors.left: refSidebar.right
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        readonly property bool hasContent: root.refTextHasCurrent
        readonly property bool hasBinding: root.refTextKind === "csv"
        // 展开/折叠完全由用户意图控制（csvBottomBarExpanded），与"是否有内容"解耦：
        //   旧逻辑 showFull = expanded && hasContent，导致清除 CSV 后 hasContent=false，
        //   底栏被锁死在 24px 折叠态，无法再展开 → 也就看不到「CSV」选择按钮，
        //   用户陷入"清除即不可恢复"的死循环。
        //   现在展开态在无内容时会展示"未绑定 CSV"占位提示 + 右上角「CSV」按钮，
        //   点击「CSV」即可重新选择文件。
        readonly property bool showFull: root.csvBottomBarExpanded
        // 高度：仅当侧边栏可见 + 有视频时才占位；展开使用用户拖拽值、折叠 24
        height: (!root.refSidebarVisible || Engine.fileCount <= 0) ? 0
              : (showFull ? root.csvBottomBarUserHeight : 24)
        visible: height > 0
        color: "#15151a"

        // 顶部 1px 分隔线
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: "#2c2c32"
        }

        // ── 折叠态：仅一行标题条（展开箭头 + 进度文字）──────────────
        Item {
            id: csvBottomCollapsedRow
            visible: !csvBottomBar.showFull
            anchors.fill: parent
            anchors.topMargin: 1
            // 折叠箭头（▶ 展开）
            Rectangle {
                id: csvExpandBtn
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 6
                width: 22; height: 18
                radius: 3
                color: csvExpandBtnMA.containsMouse ? "#2a2a32" : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "▶"
                    color: "#9a9aa8"
                    font.pixelSize: 10
                }
                MouseArea {
                    id: csvExpandBtnMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.csvBottomBarExpanded = true
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "展开参考文本"
                }
            }
            Label {
                anchors.left: csvExpandBtn.right
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 6
                anchors.rightMargin: 10
                elide: Text.ElideRight
                font.pixelSize: 11
                color: csvBottomBar.hasBinding ? "#7fe5cc" : "#6a6a78"
                text: {
                    if (!csvBottomBar.hasBinding) return "📝 未绑定参考文本（CSV）— 点击展开后选择"
                    var p = root.refTextProgress
                    var imgName = root.refTextData && root.refTextData.image ? root.refTextData.image : ""
                    var pre = "📝 跟随对比组"
                    if (p.length > 0) pre += "   ·   " + p
                    if (imgName.length > 0) pre += "   ·   " + imgName
                    return pre
                }
            }
        }

        // ── 展开态：完整 prompt + 控件区 ──────────────────────────────
        Item {
            id: csvBottomFullRow
            visible: csvBottomBar.showFull
            anchors.fill: parent
            anchors.topMargin: 1

            // 第一行：折叠箭头 + 进度标签
            Item {
                id: csvBottomTitleRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 22
                Rectangle {
                    id: csvCollapseBtn
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 6
                    width: 22; height: 18
                    radius: 3
                    color: csvCollapseBtnMA.containsMouse ? "#2a2a32" : "transparent"
                    Text {
                        anchors.centerIn: parent
                        text: "▼"
                        color: "#9a9aa8"
                        font.pixelSize: 10
                    }
                    MouseArea {
                        id: csvCollapseBtnMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.csvBottomBarExpanded = false
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "折叠参考文本"
                    }
                }

                Label {
                    anchors.left: csvCollapseBtn.right
                    anchors.right: csvBottomCtrlRow.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 6
                    anchors.rightMargin: 8
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

                // 第一行右侧：◀ ▶ 翻行 + 重置 + 中/英 + CSV + 清除
                Row {
                    id: csvBottomCtrlRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: 8
                    spacing: 4

                    // ◀ 上一行
                    Rectangle {
                        id: csvPrevBtn
                        width: 24; height: 18
                        radius: 3
                        visible: root.refTextKind === "csv" && root.refTextRowCount > 1
                        property bool enabled: root.refTextCurrentRow > 0
                        color: csvPrevMA.pressed ? "#3a3a45"
                              : csvPrevMA.containsMouse ? "#2a2a32"
                              : "#1a1a1d"
                        border.color: csvPrevBtn.enabled ? "#5a5a65" : "#2a2a32"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "◀"
                            font.pixelSize: 10
                            color: csvPrevBtn.enabled ? "#e8e8ec" : "#555"
                        }
                        MouseArea {
                            id: csvPrevMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: csvPrevBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: { if (csvPrevBtn.enabled) root._refTextOffset -= 1 }
                        }
                        ToolTip.visible: csvPrevMA.containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "上一行"
                    }
                    // ▶ 下一行
                    Rectangle {
                        id: csvNextBtn
                        width: 24; height: 18
                        radius: 3
                        visible: root.refTextKind === "csv" && root.refTextRowCount > 1
                        property bool enabled: root.refTextRowCount > 0
                                                && root.refTextCurrentRow >= 0
                                                && root.refTextCurrentRow < root.refTextRowCount - 1
                        color: csvNextMA.pressed ? "#3a3a45"
                              : csvNextMA.containsMouse ? "#2a2a32"
                              : "#1a1a1d"
                        border.color: csvNextBtn.enabled ? "#5a5a65" : "#2a2a32"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "▶"
                            font.pixelSize: 10
                            color: csvNextBtn.enabled ? "#e8e8ec" : "#555"
                        }
                        MouseArea {
                            id: csvNextMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: csvNextBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: { if (csvNextBtn.enabled) root._refTextOffset += 1 }
                        }
                        ToolTip.visible: csvNextMA.containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "下一行"
                    }
                    // ⟳ 复位
                    Rectangle {
                        id: csvResetBtn
                        width: 24; height: 18
                        radius: 3
                        visible: root._refTextOffset !== 0
                        color: csvResetMA.pressed ? "#3a3a45"
                              : csvResetMA.containsMouse ? "#2a2a32"
                              : "#1a1a1d"
                        border.color: "#7fe5cc"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "⟳"
                            font.pixelSize: 11
                            color: "#7fe5cc"
                        }
                        MouseArea {
                            id: csvResetMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._refTextOffset = 0
                        }
                        ToolTip.visible: csvResetMA.containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "回到自动同步行"
                    }
                    // 中/英
                    Rectangle {
                        id: csvLangBtn
                        width: 28; height: 18
                        radius: 3
                        visible: root.refTextHasBothLangs
                        color: csvLangMA.pressed ? "#3a3a45"
                              : csvLangMA.containsMouse ? "#2a2a32"
                              : "#1a1a1d"
                        border.color: "#3a3a45"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: root.refTextLang === "zh" ? "中" : "EN"
                            font.pixelSize: 10
                            color: "#e8e8ec"
                        }
                        MouseArea {
                            id: csvLangMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.refTextLang = (root.refTextLang === "zh" ? "en" : "zh")
                        }
                        ToolTip.visible: csvLangMA.containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "切换中文 / 英文"
                    }
                    // CSV 选择
                    Rectangle {
                        id: csvPickBtn
                        width: 38; height: 18
                        radius: 3
                        readonly property bool active: root.refTextKind === "csv"
                        color: csvPickMA.pressed ? "#3a3a45"
                              : csvPickMA.containsMouse ? "#2a2a32"
                              : (active ? "#1f2e2a" : "#1a1a1d")
                        border.color: active ? "#0fa085" : "#3a3a45"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "CSV"
                            font.pixelSize: 10
                            color: csvPickBtn.active ? "#7fe5cc" : "#e8e8ec"
                        }
                        MouseArea {
                            id: csvPickMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: refSidebarCsvDlg.open()
                        }
                        ToolTip.visible: csvPickMA.containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "选择 CSV 文件"
                    }
                    // 字号调节 A- / A+
                    Row {
                        spacing: 2
                        Rectangle {
                            width: 22; height: 18
                            radius: 3
                            color: csvFontDecMA.pressed ? "#3a3a45"
                                  : csvFontDecMA.containsMouse ? "#2a2a32"
                                  : "#1a1a1d"
                            border.color: "#3a3a45"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: "A-"
                                font.pixelSize: 10
                                color: "#e8e8ec"
                            }
                            MouseArea {
                                id: csvFontDecMA
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (root.refTextFontSize > 10) root.refTextFontSize -= 1
                            }
                            ToolTip.visible: csvFontDecMA.containsMouse
                            ToolTip.delay: 400
                            ToolTip.text: "缩小字号"
                        }
                        Rectangle {
                            width: 22; height: 18
                            radius: 3
                            color: csvFontIncMA.pressed ? "#3a3a45"
                                  : csvFontIncMA.containsMouse ? "#2a2a32"
                                  : "#1a1a1d"
                            border.color: "#3a3a45"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: "A+"
                                font.pixelSize: 10
                                color: "#e8e8ec"
                            }
                            MouseArea {
                                id: csvFontIncMA
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (root.refTextFontSize < 32) root.refTextFontSize += 1
                            }
                            ToolTip.visible: csvFontIncMA.containsMouse
                            ToolTip.delay: 400
                            ToolTip.text: "放大字号"
                        }
                    }
                    // 清除
                    Rectangle {
                        id: csvClearBtn
                        width: 38; height: 18
                        radius: 3
                        visible: root.refTextKind === "csv"
                        color: csvClearMA.pressed ? "#5a2a2a"
                              : csvClearMA.containsMouse ? "#3a2228"
                              : "#1a1a1d"
                        border.color: "#3a3a42"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "清除"
                            font.pixelSize: 10
                            color: "#e8b0b0"
                        }
                        MouseArea {
                            id: csvClearMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.refCurrentFolder.length > 0)
                                    Reference.clearText(root.refCurrentFolder)
                            }
                        }
                    }
                }
            }

    // 第二行：完整 prompt 文本（一整行带横向滚动 / wrap）
            Rectangle {
                id: csvBottomTextBox
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: csvBottomTitleRow.bottom
                anchors.bottom: parent.bottom
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.topMargin: 2
                anchors.bottomMargin: 6
                color: "#0e0e10"
                border.color: csvBottomTextDrop.containsDrag ? "#5a8fd8" : "#2c2c32"
                border.width: 1
                radius: 4

                Flickable {
                    id: csvBottomScroll
                    anchors.fill: parent
                    anchors.margins: 6
                    clip: true
                    contentWidth: width
                    contentHeight: csvBottomLabel.implicitHeight
                    visible: root.refTextHasCurrent
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    Text {
                        id: csvBottomLabel
                        width: csvBottomScroll.width
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: root.refTextDisplay
                        color: "#d8d8e0"
                        font.pixelSize: root.refTextFontSize
                        lineHeight: 1.1
                    }
                }
                Label {
                    anchors.centerIn: parent
                    width: parent.width - 16
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    visible: !csvBottomScroll.visible
                    color: "#6a6a78"
                    font.pixelSize: 11
                    text: {
                        if (root.refCurrentFolder.length === 0)
                            return "请选中任一通道"
                        if (root.refTextKind === "")
                            return "未绑定参考文本（CSV）— 点击右侧「CSV」选择文件，或拖入 .csv"
                        return "已绑定 CSV，但当前行为空 / 越界（视频序号超出 CSV 行数）"
                    }
                }

                // 拖拽接收：CSV 文件
                DropArea {
                    id: csvBottomTextDrop
                    anchors.fill: parent
                    onDropped: function(drop) {
                        if (root.refCurrentFolder.length === 0) { drop.accepted = false; return }
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
        }
    }

    // ─── 可拖拽分隔条：竖向（拖动调整左侧参考栏宽度）──────────────────
    // 设计要点：
    //   1) 仅当 refSidebarVisible 为 true 时显示并接收事件，关闭后零占位；
    //   2) 与视频/播放内核完全解耦——只通过 root.refSidebarUserWidth 一个属性
    //      与 refSidebar.width 联动，videoArea 的左边界本来就 anchors 跟随；
    //   3) z:100 抬到视频上方，避免被 GridView 的 cell 抢走鼠标事件；
    //   4) 双击复位到 320 默认宽度。
    Rectangle {
        id: refSidebarHSplitter
        visible: root.refSidebarVisible
        z: 100
        anchors.top: parent.top
        anchors.bottom: csvBottomBar.top
        // 中心对齐到 refSidebar 的右边缘上，分隔条本身 6px 宽
        x: refSidebar.x + refSidebar.width - 3
        width: 6
        color: refSidebarHSplitterMA.containsMouse || refSidebarHSplitterMA.pressed
               ? "#2a2a32" : "transparent"
        // 中线小提示
        Column {
            anchors.centerIn: parent
            spacing: 4
            Repeater {
                model: 3
                Rectangle { width: 3; height: 3; radius: 1.5; color: "#5a5a66" }
            }
        }
        MouseArea {
            id: refSidebarHSplitterMA
            anchors.fill: parent
            anchors.leftMargin: -2
            anchors.rightMargin: -2
            hoverEnabled: true
            cursorShape: Qt.SplitHCursor
            property real _grabX: 0
            onPressed: function(mouse) { _grabX = mouse.x }
            onPositionChanged: function(mouse) {
                if (!pressed) return
                var newW = root.refSidebarUserWidth + (mouse.x - _grabX)
                // 限制 [200, 600]：避免栏太窄/太宽
                var maxW = Math.max(200, root.width - 400) // 至少给视频留 400
                root.refSidebarUserWidth = Math.max(200, Math.min(Math.min(600, maxW), newW))
            }
            onDoubleClicked: root.refSidebarUserWidth = 320
        }
    }

    // ─── 可拖拽分隔条：横向（拖动调整底部提示词栏高度）─────────────────
    // 仅当 csvBottomBar 处于"展开 + 有内容"状态时显示；折叠或无视频时隐藏。
    Rectangle {
        id: csvBottomVSplitter
        visible: csvBottomBar.showFull && csvBottomBar.height > 0
        z: 100
        anchors.left: csvBottomBar.left
        anchors.right: csvBottomBar.right
        // 中心贴到 csvBottomBar 顶边
        y: csvBottomBar.y - 3
        height: 6
        color: csvBottomVSplitterMA.containsMouse || csvBottomVSplitterMA.pressed
               ? "#2a2a32" : "transparent"
        Row {
            anchors.centerIn: parent
            spacing: 4
            Repeater {
                model: 3
                Rectangle { width: 3; height: 3; radius: 1.5; color: "#5a5a66" }
            }
        }
        MouseArea {
            id: csvBottomVSplitterMA
            anchors.fill: parent
            anchors.topMargin: -2
            anchors.bottomMargin: -2
            hoverEnabled: true
            cursorShape: Qt.SplitVCursor
            property real _grabY: 0
            onPressed: function(mouse) { _grabY = mouse.y }
            onPositionChanged: function(mouse) {
                if (!pressed) return
                // 鼠标向上拖 -> 高度增大
                var newH = root.csvBottomBarUserHeight - (mouse.y - _grabY)
                // 限制 [60, 280]：太低看不清，太高挤压视频
                var maxH = Math.max(60, root.height - 200) // 至少给视频留 200
                root.csvBottomBarUserHeight = Math.max(60, Math.min(Math.min(280, maxH), newH))
            }
            onDoubleClicked: root.csvBottomBarUserHeight = 88
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
        anchors.bottom: csvBottomBar.top

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

                delegate: VideoCellDelegate {
                    // 把宫格内 cell 抽离为独立组件，便于将来按媒体类型扩展（图片模式等）。
                    // 行为/视觉与原内联 delegate 100% 等价；
                    //   · playerIdx：通过 viewRoot 上的透传函数把 Repeater 的 index 映射到真正的 player 索引
                    //   · viewRoot ：把 ApplicationWindow root 整个传入，子组件通过它访问 fmtTime / 评分 / 选中等共享状态
                    playerIdx: viewRoot.slotPlayerIndex(index)
                    viewRoot: root
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
                // 设计说明（图1 → 当前版本）：
                //   旧版仅展示 4 行"打开 / 播放 / 视图 / 路·速"的极简速览，再用一个
                //   「查看全部快捷键 →（F1）」链接跳转到 shortcutsDialog。
                //   现在快捷键数量稳定（≤5 组、共十几行），首页空态有足够留白，干脆
                //   直接平铺展示全部分组，无需二次跳转；同时保留 F1 入口，便于
                //   未来扩展更多快捷键时仍可单独打开速查面板。
                //   组件复用：直接使用 root 顶层定义的 ScSection / ScRow，与 F1
                //   对话框 100% 一致；这样以后只要维护一份内容，两处自动同步。
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    // 宽度 720：与 shortcutsDialog 的两列网格留白接近，
                    // 单行最长描述「切换通道信息叠加（序号 + 文件名）」也能一行放下。
                    Layout.preferredWidth: 720
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

                        // 分隔线：让"拖拽提示文案"与"快捷键分组"的视觉层级清晰一些
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            Layout.bottomMargin: 2
                            height: 1
                            color: "#2a2a32"
                        }

                        // ── 全量快捷键：两列 × 多分组（与 F1 对话框完全一致）──
                        //   左列：播放 / 倍速 / 多组对比
                        //   右列：视图 / 单路 · 多路
                        //   使用 ScSection + ScRow（root 顶层 inline component），
                        //   保证视觉与 shortcutsDialog 完全一致；后续扩展只需改两处之一。
                        GridLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            columns: 2
                            columnSpacing: 28
                            rowSpacing: 12

                            // 左列 1：播放
                            ScSection {
                                title: qsTr("播放")
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                ScRow { keys: "Space";    desc: qsTr("暂停 / 继续") }
                                ScRow { keys: "←  /  →";  desc: qsTr("后退 / 前进 5 秒") }
                                ScRow { keys: ",  /  .";  desc: qsTr("上一帧 / 下一帧") }
                                ScRow { keys: "R";        desc: qsTr("回到开头") }
                            }
                            // 右列 1：视图
                            ScSection {
                                title: qsTr("视图")
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                ScRow { keys: "F"; desc: qsTr("切换全屏") }
                                ScRow { keys: "V"; desc: qsTr("切换视频信息叠加") }
                                ScRow { keys: "C"; desc: qsTr("切换通道信息叠加（序号 + 文件名）") }
                                ScRow { keys: "S"; desc: qsTr("多路视频时切换布局如1xN / 2x2 / 3x3") }
                                ScRow { keys: "B"; desc: qsTr("滑动对比模式（仅 2 路）") }
                            }
                            // 左列 2：倍速
                            ScSection {
                                title: qsTr("倍速")
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                ScRow { keys: "-";        desc: qsTr("减速一档") }
                                ScRow { keys: "=  /  +";  desc: qsTr("加速一档") }
                                ScRow { keys: "0";        desc: qsTr("复位为 1.0×") }
                            }
                            // 右列 2：单路 / 多路
                            ScSection {
                                title: qsTr("单路 / 多路")
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                ScRow { keys: "1 … 9"; desc: qsTr("切到第 N 路单路；再次按下回到上次的多路布局") }
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
                            // 右列 3：视图缩放 / 平移（所有路同步）
                            ScSection {
                                title: qsTr("视图缩放 / 平移（所有路同步）")
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                ScRow { keys: qsTr("鼠标滚轮");    desc: qsTr("以鼠标位置为锚点缩放（0.2× ~ 8×）") }
                                ScRow { keys: qsTr("右键拖拽");    desc: qsTr("同步平移所有路（画面跟随鼠标方向）") }
                                ScRow { keys: qsTr("Ctrl+双击");   desc: qsTr("视图复位（缩放/平移归零）") }
                                ScRow { keys: "⊙";              desc: qsTr("底部工具栏 视图复位按钮") }
                            }
                        }

                        // 入口：跳转到「快捷键…」对话框
                        // 当前所有快捷键已经在上方平铺展示，这里仍保留 F1 入口，
                        // 一是兼容老用户的 F1 习惯，二是为将来"快捷键变多需要滚动的弹窗"留出口。
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
            // ── 质量比较 2 专用：左右 2 星评分条与本地状态双向同步 ──
            slideRatingEnabled: root.isQualitySlideMode
            slideRatingL: root.slideRatingL
            slideRatingR: root.slideRatingR
            setSlideRatingFn: function(side, score) { root.setSlideRating(side, score) }
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
            var dims = root.reviewDimensions
            var hasDims = dims && dims.length > 0
            if (hasDims) {
                // 有维度配置时（不限于 multi_dim 模式）：每个通道的所有维度都 > 0 才算已评分
                for (var i = 0; i < n; ++i) {
                    var v = root.cellRatings[i]
                    var allDone = true
                    if (typeof v !== "object" || v === null) {
                        allDone = false
                    } else {
                        for (var d = 0; d < dims.length; ++d) {
                            if (!(v[dims[d].key] > 0)) { allDone = false; break }
                        }
                    }
                    if (!allDone) miss.push(i)
                }
            } else {
                for (var j = 0; j < n; ++j) {
                    if (root.ratingAt(j) <= 0) miss.push(j)
                }
                // quality_slide：仅当 fileCount===2 时滑动对比才有意义；
                // 多于 2 路的场景退化回普通 quality 校验，避免误拦。
                if (root.isQualitySlideMode && Engine.fileCount === 2) {
                    if (root.slideRatingL <= 0) miss.push(-2)
                    if (root.slideRatingR <= 0) miss.push(-3)
                }
            }
            return miss
        }
        // 提示弹窗用：把 idx 转成"通道 N · 文件名"展示
        getCellLabel: function(idx) {
            // quality_slide 引入的负值 sentinel：渲染为友好提示
            if (idx === -2) return "⇆ 滑动 L · 待打分（请进入滑动对比后打分）"
            if (idx === -3) return "⇆ 滑动 R · 待打分（请进入滑动对比后打分）"
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
        setRatingAt: function(idx, score, dimKey) {
            try { root._writeRating(idx, score, dimKey) } catch (e) {}
        }
        // 获取指定通道当前评分（用于弹窗打开时预填已有评分）
        getCellRating: function(idx) {
            if (idx < 0 || idx >= root.cellRatings.length) return null
            return root.cellRatings[idx]
        }
        // 多维评分模式注入
        isMultiDimMode: root.isMultiDimMode
        reviewDimensions: root.reviewDimensions
        // 点击「启动对比」时，先从网络加载当前模式对应的激活配置，完成后再启动
        onDimLoadNeeded: function(mode, callback) {
            var base = root._dimApiUrl()
            if (base.length > 0) {
                var url = base + (mode ? ("?mode=" + encodeURIComponent(mode)) : "")
                root.loadDimensionsFromUrl(url, callback)
            } else {
                // 未配置服务器地址，直接用本地缓存维度启动
                console.warn("[DimLoad] 未配置服务器地址，跳过远程加载")
                if (typeof callback === "function") callback(false)
            }
        }
        // 后端服务器地址 + 本地配置指纹：用于「查看规则」按钮构造跳转 URL
        uploadServerUrl: (typeof Rating !== "undefined" && Rating.uploadServerUrl) ? Rating.uploadServerUrl : ""
        localConfigFingerprint: root._localConfigFingerprint
    }

    // dlg.reviewMode 现在是 readonly 并从 Rating.currentMode 直接派生，
    // 主窗 root.reviewMode 也从 Rating.currentMode 直接派生，不再需要 Binding 中转。

    // ─── 评分数据查看 / 导出 / 清空面板 ───────────────────────
    // 仅在「文件 ▸ 评分数据…」时 open()；与播放完全解耦。
    RatingsDialog {
        id: ratingsDialog
        visible: false
        transientParent: root
        remoteTag: root._remoteTag
    }

    // 全局进度条已移除：多路场景下各路独立播放控制，全局进度条语义
    // 不明。进度跳转请使用各路 cell 悬浮工具条上的单路进度条。

    // ─── 参考图放大查看 Lightbox ──────────────────────────────────
    // 设计目标：
    //   · 不破坏画质：用独立的 Image 元素，sourceSize 跟随显示尺寸自适应，不复用侧栏小图缓存
    //   · 不创建新原生窗口：覆盖在主窗之上，避免抢焦点 / 多屏跳屏 / 窗口创建销毁开销
    //   · 操作直觉：滚轮缩放（以鼠标为锚点）、拖拽平移、双击切换 Fit↔100%、Esc 关闭、← → 翻页
    //   · 与播放器内核完全解耦：纯 QML/Image 层，零崩溃风险
    //
        // 触发：侧栏「参考资料」面板 refImage 右上角"放大"按钮（refImageZoomBtn）→ refLightbox.open()
    Item {
        id: refLightbox
        anchors.fill: parent
        visible: false
        z: 999  // 盖过一切（菜单栏除外，Qt 顶部菜单仍在最上）
        focus: visible

        // ── 缩放与平移状态 ────────────────────────────────────────
        property real zoom: 1.0           // 1.0 = 适配窗口（Fit）；其它值 = 倍率（相对 fitScale）
        property real fitScale: 1.0       // Fit 时图片的实际缩放（用于"100%"判断与归一化）
        property real panX: 0
        property real panY: 0
        readonly property real minZoom: 1.0
        readonly property real maxZoom: 10.0
        // 当前查看的是哪一槽位的参考图：1 = 上半（默认），2 = 下半
        property int currentSlot: 1
        readonly property url currentSrc: currentSlot === 2 ? root.refCurrentUrl2 : root.refCurrentUrl
        readonly property bool currentHas: currentSlot === 2 ? root.refHasCurrent2 : root.refHasCurrent
        // 翻图相关属性按当前槽位路由：避免 Lightbox 里 ◀ ▶ 永远只动槽位 1 的偏移。
        //   · 之前 Bug：从下半图（slot=2）点 ⤢ 放大后，Lightbox 内 ◀ ▶ / ←/→ 改的是
        //     _refImgOffset（槽位 1），但显示的是 refCurrentUrl2（槽位 2），所以
        //     底层窗口看着切了，放大窗口却纹丝不动。
        readonly property int    currentCount: currentSlot === 2 ? root.refImageCount2 : root.refImageCount
        readonly property int    currentIndex: currentSlot === 2 ? root.refCurrentImageIndex2 : root.refCurrentImageIndex
        readonly property bool   currentCanNav: currentSlot === 2 ? root.refCanNav2 : root.refCanNav
        // 推进当前槽位的偏移；Lightbox 内的 ◀ ▶ 与键盘 ←/→ 都走这一个出口。
        function bumpOffset(delta) {
            if (currentSlot === 2) root._refImgOffset2 += delta
            else                   root._refImgOffset  += delta
        }
        // 是否处于"100%（实际像素）"状态（用于切换标签 / 高亮按钮）
        readonly property bool atFit:    Math.abs(zoom - 1.0) < 0.001
        readonly property bool atActual: refLightboxImg.sourceSize.width > 0
                                         && Math.abs(zoom * fitScale - 1.0) < 0.001

        function open() { openSlot(1) }
        function openSlot(slot) {
            currentSlot = (slot === 2 ? 2 : 1)
            if (!currentHas) return
            zoom = 1.0; panX = 0; panY = 0
            visible = true
            forceActiveFocus()
            autoHideTimer.restart()
        }
        function close() {
            visible = false
        }
        function setZoom(newZoom, anchorX, anchorY) {
            // 以 (anchorX, anchorY)（光标在覆盖层内坐标）为锚点缩放，避免画面"漂走"
            var z0 = zoom
            var z1 = Math.max(minZoom, Math.min(maxZoom, newZoom))
            if (Math.abs(z1 - z0) < 0.0001) return
            // 锚点相对于图片中心的偏移（含已有平移）
            var cx = width  / 2 + panX
            var cy = height / 2 + panY
            var dx = anchorX - cx
            var dy = anchorY - cy
            // 缩放后保持锚点相对图片不变：dx' = dx * (z1/z0)
            panX += dx - dx * (z1 / z0)
            panY += dy - dy * (z1 / z0)
            zoom = z1
            clampPan()
        }
        function clampPan() {
            // 仅当图片放大到比窗口还大时允许拖动，否则强制居中
            var w = refLightboxImg.paintedWidth  * zoom
            var h = refLightboxImg.paintedHeight * zoom
            var maxX = Math.max(0, (w - width)  / 2)
            var maxY = Math.max(0, (h - height) / 2)
            panX = Math.max(-maxX, Math.min(maxX, panX))
            panY = Math.max(-maxY, Math.min(maxY, panY))
        }
        function fitToWindow() { zoom = 1.0; panX = 0; panY = 0 }
        function actualSize() {
            if (refLightboxImg.sourceSize.width <= 0) return
            zoom = Math.max(minZoom, Math.min(maxZoom, 1.0 / Math.max(fitScale, 0.0001)))
            panX = 0; panY = 0
        }

        // ── 半透明深色背景 + 点击空白关闭 ─────────────────────────
        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: 0.92
        }
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // 鼠标在覆盖层任意位置移动 → 唤回工具条（自动隐藏计时器重置）
            hoverEnabled: true
            onPositionChanged: refLightbox.autoHideTimer.restart()
            // 滚轮缩放（macOS 触控板捏合也走 wheel）
            onWheel: function(wheel) {
                var delta = wheel.angleDelta.y / 120.0
                if (delta === 0) delta = wheel.angleDelta.x / 120.0
                if (delta === 0) return
                var factor = Math.pow(1.15, delta)
                refLightbox.setZoom(refLightbox.zoom * factor, wheel.x, wheel.y)
                refLightbox.autoHideTimer.restart()
            }
            // 拖拽平移：仅在 zoom>1（图片大于窗口）时启用
            property real _lastX: 0
            property real _lastY: 0
            property bool _dragging: false
            onPressed: function(mouse) {
                _lastX = mouse.x; _lastY = mouse.y
                _dragging = (refLightbox.zoom > 1.0)
                cursorShape = _dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
            }
            onReleased: {
                _dragging = false
                cursorShape = (refLightbox.zoom > 1.0) ? Qt.OpenHandCursor : Qt.ArrowCursor
            }
            onMouseXChanged: {
                if (!_dragging) return
                refLightbox.panX += mouseX - _lastX
                _lastX = mouseX
                refLightbox.clampPan()
            }
            onMouseYChanged: {
                if (!_dragging) return
                refLightbox.panY += mouseY - _lastY
                _lastY = mouseY
                refLightbox.clampPan()
            }
            // 双击：Fit ↔ 100% 切换
            onDoubleClicked: {
                if (refLightbox.atFit) refLightbox.actualSize()
                else                   refLightbox.fitToWindow()
            }
            // 单击空白（不在图片上）→ 关闭
            onClicked: function(mouse) {
                if (mouse.button === Qt.RightButton) { refLightbox.close(); return }
                // 命中检测：若点击落在 paintedRect 之外才关闭
                var pw = refLightboxImg.paintedWidth  * refLightbox.zoom
                var ph = refLightboxImg.paintedHeight * refLightbox.zoom
                var cx = refLightbox.width  / 2 + refLightbox.panX
                var cy = refLightbox.height / 2 + refLightbox.panY
                var inside = mouse.x >= cx - pw/2 && mouse.x <= cx + pw/2
                          && mouse.y >= cy - ph/2 && mouse.y <= cy + ph/2
                if (!inside) refLightbox.close()
            }
            cursorShape: refLightbox.zoom > 1.0 ? Qt.OpenHandCursor : Qt.ArrowCursor
        }

        // ── 实际放大显示的 Image ──────────────────────────────────
        // 关键设计：
        //   · sourceSize 用"固定上限"，仅在图片切换时解码一次；缩放/平移完全由 transform 承担。
        //     避免之前 sourceSize 跟随 zoom 变化导致每滚一格滚轮就触发整张重解码 → 一闪一闪。
        //   · 8192 像素上限：远高于绝大多数显示器（4K/5K），放大到 10× 也保留充足细节；
        //     原图小于 8192 时按原始像素全解，原图超大时一次性 downscale 到 8192，控制内存。
        //   · 切图（refCurrentUrl 变）时才会重新走 Loading；窗口 resize / 缩放 / 平移都不触发。
        Image {
            id: refLightboxImg
            source: refLightbox.currentSrc
            asynchronous: true
            cache: true
            smooth: true
            mipmap: true
            fillMode: Image.PreserveAspectFit
            // 居中布局，再用 transform 实现缩放和平移
            anchors.centerIn: parent
            width:  parent.width
            height: parent.height
            // 固定解码上限：不依赖 zoom / parent 尺寸，避免重解码闪烁
            //   8192 已超 8K，对放大查看场景足够；超大图被一次性缩到此上限，控制内存
            sourceSize.width:  8192
            sourceSize.height: 8192

            transform: [
                Scale {
                    id: lbScale
                    origin.x: refLightboxImg.width  / 2
                    origin.y: refLightboxImg.height / 2
                    xScale: refLightbox.zoom
                    yScale: refLightbox.zoom
                },
                Translate {
                    x: refLightbox.panX
                    y: refLightbox.panY
                }
            ]

            // 计算 fitScale（Fit 时图片到窗口的实际像素比，用于"100%"换算）
            //   paintedWidth 是 PreserveAspectFit 后的显示尺寸；
            //   sourceSize.width 是解码尺寸（≤8192），fitScale = painted / decoded。
            //   注：原图被 downscale 到 8192 时，"100%"语义是"解码后的实际像素"，
            //       对人眼来说与原图无差别（屏幕也显示不出超 8K 细节）。
            onPaintedWidthChanged: _refreshFit()
            onPaintedHeightChanged: _refreshFit()
            onSourceSizeChanged: _refreshFit()
            function _refreshFit() {
                if (sourceSize.width > 0 && paintedWidth > 0) {
                    refLightbox.fitScale = paintedWidth / sourceSize.width
                }
            }

            // 加载状态：用 Timer 延迟显示，过滤掉 <300ms 的瞬时 Loading（缓存命中、resize 等）
            //   只有真正长耗时的解码才会让指示器出现，避免视觉上"一闪一闪"
            Timer {
                id: lbLoadingDelay
                interval: 300
                repeat: false
                onTriggered: lbBusy.shown = (refLightboxImg.status === Image.Loading)
            }
            Connections {
                target: refLightboxImg
                function onStatusChanged() {
                    if (refLightboxImg.status === Image.Loading) {
                        lbLoadingDelay.restart()
                    } else {
                        lbLoadingDelay.stop()
                        lbBusy.shown = false
                    }
                }
            }
            BusyIndicator {
                id: lbBusy
                anchors.centerIn: parent
                property bool shown: false
                running: shown
                visible: shown
            }
            Label {
                anchors.centerIn: parent
                text: "图片无法加载"
                color: "#bbb"
                font.pixelSize: 14
                visible: refLightboxImg.status === Image.Error
            }
        }

        // ── 顶部信息栏（标题 / 序号 / 操作按钮） ──────────────────
        Rectangle {
            id: refLightboxTopBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 44
            color: "#101014cc"
            opacity: refLightboxToolsVisible ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 180 } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 10
                spacing: 12

                Label {
                    text: {
                        // 跟随当前查看的槽位显示文件名，而非永远显示槽位 1。
                        var p = String(refLightbox.currentSrc)
                        if (p.length === 0) return ""
                        var i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
                        return i >= 0 ? decodeURIComponent(p.substring(i + 1)) : p
                    }
                    color: "#e8e8ec"
                    font.pixelSize: 13
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
                Label {
                    visible: refLightbox.currentCount > 1
                    text: (refLightbox.currentIndex + 1) + " / " + refLightbox.currentCount
                    color: "#9a9aa8"
                    font.pixelSize: 12
                }
                // 关闭：与「⋯」「⤢」按钮统一的玻璃半透明风格，
                // 不再使用 ToolButton 默认主题色（避免出现实心方块底色）。
                Rectangle {
                    id: lbCloseBtn
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 28
                    radius: 4
                    color: lbCloseBtnMA.pressed ? "#3a3a45"
                         : lbCloseBtnMA.containsMouse ? "#2a2a32cc"
                         : "#1a1a1d99"
                    border.color: lbCloseBtnMA.containsMouse ? "#5a8fd8" : "#3a3a45"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: lbCloseBtnMA.containsMouse ? "#ffffff" : "#d0d0d8"
                        font.pixelSize: 14
                        font.bold: true
                    }
                    MouseArea {
                        id: lbCloseBtnMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton
                        onClicked: refLightbox.close()
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "关闭（Esc）"
                    }
                }
            }
        }

        // ── 底部翻页（folder 模式 N>1 才显示） ────────────────────
        Row {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottomMargin: 24
            spacing: 16
            visible: refLightboxToolsVisible
                     && refLightbox.currentCanNav
                     && refLightbox.currentCount > 1
            opacity: visible ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 180 } }

            Rectangle {
                width: 44; height: 44; radius: 22
                color: lbPrevMA.pressed ? "#3a3a45"
                      : lbPrevMA.containsMouse ? "#2a2a32"
                      : "#1a1a1de0"
                id: lbPrev
                property bool canGo: refLightbox.currentCount > 1
                border.color: lbPrev.canGo ? "#5a5a65" : "#2a2a32"
                border.width: 1
                Text { anchors.centerIn: parent; text: "◀"; font.pixelSize: 16; color: lbPrev.canGo ? "#e8e8ec" : "#555" }
                MouseArea {
                    id: lbPrevMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: lbPrev.canGo ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (!lbPrev.canGo) return
                        refLightbox.bumpOffset(-1)
                        refLightbox.fitToWindow()
                        refLightbox.autoHideTimer.restart()
                    }
                }
            }
            Rectangle {
                width: 44; height: 44; radius: 22
                color: lbNextMA.pressed ? "#3a3a45"
                      : lbNextMA.containsMouse ? "#2a2a32"
                      : "#1a1a1de0"
                id: lbNext
                property bool canGo: refLightbox.currentCount > 1
                border.color: lbNext.canGo ? "#5a5a65" : "#2a2a32"
                border.width: 1
                Text { anchors.centerIn: parent; text: "▶"; font.pixelSize: 16; color: lbNext.canGo ? "#e8e8ec" : "#555" }
                MouseArea {
                    id: lbNextMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: lbNext.canGo ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (!lbNext.canGo) return
                        refLightbox.bumpOffset(+1)
                        refLightbox.fitToWindow()
                        refLightbox.autoHideTimer.restart()
                    }
                }
            }
        }

        // ── 工具条自动隐藏（鼠标静止 2.5s 后淡出） ────────────────
        property bool refLightboxToolsVisible: true
        Timer {
            id: autoHideTimer
            interval: 2500
            repeat: false
            onTriggered: refLightbox.refLightboxToolsVisible = false
        }
        onVisibleChanged: {
            if (visible) { refLightboxToolsVisible = true; autoHideTimer.restart() }
        }
        // 任何按键 / 滚轮 / 鼠标移动都会触发上面 restart()，这里再加一个统一的 restart 钩子
        onZoomChanged: { refLightboxToolsVisible = true; autoHideTimer.restart() }

        // ── 键盘快捷键 ────────────────────────────────────────────
        Keys.onPressed: function(event) {
            if (!visible) return
            switch (event.key) {
                case Qt.Key_Escape: refLightbox.close(); event.accepted = true; break
                case Qt.Key_Plus:
                case Qt.Key_Equal:
                    refLightbox.setZoom(refLightbox.zoom * 1.25, width/2, height/2)
                    event.accepted = true; break
                case Qt.Key_Minus:
                    refLightbox.setZoom(refLightbox.zoom / 1.25, width/2, height/2)
                    event.accepted = true; break
                // 注意：0 / 1 / F 故意不处理，交还给全局快捷键
                //   · 数字键 0~9 用于调整窗口布局/速度等全局功能
                //   · F 用于切换整窗全屏
                //   Lightbox 内的"适配/100%"切换仍可通过双击图片完成
                case Qt.Key_Left:
                    if (refLightbox.currentCanNav && refLightbox.currentCount > 1) {
                        refLightbox.bumpOffset(-1)
                        refLightbox.fitToWindow()
                    }
                    event.accepted = true; break
                case Qt.Key_Right:
                    if (refLightbox.currentCanNav && refLightbox.currentCount > 1) {
                        refLightbox.bumpOffset(+1)
                        refLightbox.fitToWindow()
                    }
                    event.accepted = true; break
            }
            autoHideTimer.restart()
        }
    }
}
