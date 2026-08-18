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
import "MainLogic.js" as Logic
import "RatingLogic.js" as RatingLogic

ApplicationWindow {
    id: root
    width: 1440
    height: 900
    visible: true
    title: "PlayerX"
    color: "#101012"

    // 【Windows 标题栏一体化】无边框全自绘（FramelessWindowHint，VS Code 在 Windows 同款路线）。
    // 注：曾尝试 Qt 6.9 ExpandedClientAreaHint，但 Windows QPA 把标题栏条内输入
    // 全部按 HTCAPTION（拖拽）处理，菜单等交互控件收不到鼠标事件 → 改全自绘：
    // 图标 / 菜单 / 自绘三键 / 拖拽 / 边缘缩放全在 QML（见 menuBar 块与下方），
    // DWM 阴影与 Win11 圆角在 WinTitleBar.cpp 补回。macOS / Linux 不加此 flag。
    flags: Qt.Window | (Qt.platform.os === "windows" ? Qt.FramelessWindowHint : 0)


    // Windows 无边框：窗口左 / 右 / 下边缘 + 底部两角的缩放条
    //（顶边与顶部两角在 menuBar 背景里，因为 menuBar 占据窗口 y=0 区域）
    ResizeEdge { root: root; edges: Qt.LeftEdge;   anchors.left: parent.left;   anchors.top: parent.top; anchors.bottom: parent.bottom; width: 5;  z: 998 }
    ResizeEdge { root: root; edges: Qt.RightEdge;  anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 5;  z: 998 }
    ResizeEdge { root: root; edges: Qt.BottomEdge; anchors.left: parent.left;   anchors.right: parent.right; anchors.bottom: parent.bottom; height: 5; z: 998 }
    ResizeEdge { root: root; edges: Qt.BottomEdge | Qt.LeftEdge;  anchors.left: parent.left;  anchors.bottom: parent.bottom; width: 12; height: 12; z: 999 }
    ResizeEdge { root: root; edges: Qt.BottomEdge | Qt.RightEdge; anchors.right: parent.right; anchors.bottom: parent.bottom; width: 12; height: 12; z: 999 }

    // ─── 全局 ToolTip 主题（深色半透明 + 浅字 + 圆角，统一观感）──────────────
    // Qt 的 ToolTip.attached 共享同一个全局 popup 实例（QQuickToolTipAttached.sharedTip）。
    // 因此只要在窗口创建时一次性修改其 background.color 与 contentItem.color，
    // 后续 50+ 处的 `ToolTip.text/visible` 附加属性都会自动套用此暗色主题，
    // 不需要逐处改写 background/contentItem，最大限度避免破坏既有功能。
    // 兜底：某些平台（Windows）Component.onCompleted 可能延迟或不触发
    // 用 Component.onDestruction 的反面——在对象创建时立即注册 root 到 Qt 对象
    // QML 中 property 绑定是惰性求值，所以改用 Component.onCompleted 的 Timer 0ms 立即执行
    Timer {
        id: _rootRegisterTimer
        interval: 0
        repeat: false
        running: true
        onTriggered: {
            Qt._playerXRoot = root
            console.log("[Init] Qt._playerXRoot 已注册（Timer 0ms）")
        }
    }

    Component.onCompleted: {
        // 立即注册 root 到 Qt 对象（供 MainLogic.js 自动初始化）
        Qt._playerXRoot = root
        console.log("[Init] Qt._playerXRoot 已注册（Component.onCompleted）")
        Logic._init({
            root: root,
            updateToast: updateToast,
            testSourceDownloadDialog: testSourceDownloadDialog,
            testSourceGroupDialog: testSourceGroupDialog,
            testSourceRedownloadDialog: testSourceRedownloadDialog,
            multiGroupDialog: multiGroupDialog,
            dimReloadTimer: _dimReloadTimer,
            ratingsDialog: ratingsDialog,
            ratingToast: videoArea.ratingToast
        })
        RatingLogic._initRating({
            root: root,
            multiGroupDialog: multiGroupDialog,
            ratingsDialog: ratingsDialog,
            ratingToast: videoArea.ratingToast
        })
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
                    // 允许个别 tooltip 用 <font color> 做局部着色（如"评分规则"悬浮提示）。
                    // 已排查：现有全部 tooltip 文本不含 < / &，开 RichText 不影响纯文本渲染。
                    tip.contentItem.textFormat = Text.RichText
                }
            }
        } catch (e) {
            console.log("[ToolTip][theme] init failed:", e)
        }
        RatingLogic._boot()
    }

    // 教程文档链接（占位 URL，后续替换为正式地址即可，无需改任何调用方）
    // 用法：菜单「帮助 → 教程…」点击时，会通过 Qt.openUrlExternally(tutorialUrl) 打开默认浏览器
    property url tutorialUrl: "https://iwiki.woa.com/p/4020492089"

    // ─── 左侧主导航当前选中的 Tab ──────────────────────────────────────
    // 取值：home(首页) / play(播放) / yuv(YUV 分析) / stream(码流分析)
    // 默认停留在「播放」tab，与旧版主界面行为一致；设置入口保留在顶栏菜单。
    // 各内容区（refSidebar/videoArea/csvBottomBar/yuvView/homeView/streamView）
    // 以及底部工具栏（footer topBar）都据此决定是否显示，逻辑互不侵入。
    property string currentTab: "play"

    // ─── 沉浸模式 ───────────────────────────────────────────────────────
    // true 表示已进入"独立子界面"：左右导航栏 / 参考图栏 全部隐藏，
    // 对应内容区（videoArea / yuvView / streamView）与 CSV 底栏铺满整个
    // contentItem，真正满屏。
    // 触发条件：
    //   · 播放 tab 加载了视频
    //   · YUV tab 已加载文件（render 阶段）—— setup 阶段（参数输入）不沉浸，
    //     保留左侧导航栏方便用户在 tab 间顺畅切换
    //   · 码流分析 tab
    // 退出方式：播放 tab 用底部"×关闭"清空视频；YUV / 码流分析 tab 用"← 返回"。
    readonly property bool immersive:
        (root.currentTab === "play" && Engine.fileCount > 0)
        || (root.currentTab === "yuv" && YuvBridge.slotCount > 0)
        || root.currentTab === "stream"

    // ─── 系统菜单栏（macOS 全局菜单 / Windows 窗口菜单） ──────────────────
    // 仅作为系统级入口，与现有 ToolBar 上的"打开 ▾ / ⚙ 设置 ▾"按钮共存。
    // macOS：自动适配为顶部全局菜单栏（系统原生样式，不接受自定义 background）。
    // Windows / Linux：在窗口标题栏下方显示一行经典菜单栏。
    // 设计原则：MenuBar 承担全部高频入口（打开/退出/设置/关于）。
    menuBar: AppMenuBar {
        id: appMenuBar
        root: root
        shortcutsAboutDialogs: shortcutsAboutDialogs
        updateDialog: updateDialog
        confirmCloseAllDialog: confirmCloseAllDialog
        restoreDefaultConfirmDialog: restoreDefaultConfirmDialog
        clearHistoryConfirmDialog: clearHistoryConfirmDialog
        addDialog: fileDialogs.addDialog
        multiGroupDialog: multiGroupDialog
        ratingsDialog: ratingsDialog
    }

    // 登录态：评分人已设置（Rating.currentUser 非空）
    readonly property bool _loggedIn: (typeof Rating !== "undefined")
                                      && String(Rating.currentUser || "").trim().length > 0

    function _logout() {
        if (typeof Rating !== "undefined") Rating.currentUser = ""
        console.log("[Login] 已退出登录")
        updateToast.text = "已退出登录"
        updateToast.open()
    }

    // 登录面板开关切换：所有入口（macOS 原生拦截回调 / Windows delegate 特判 /
    // 菜单兜底项）统一走这里 —— 再次点击入口即关闭面板
    function _toggleLoginDialog() {
        if (loginDialog.visible) loginDialog.close()
        else loginDialog.open()
    }

    // macOS 原生菜单拦截回调入口（C++ menuWillOpen 阶段触发）
    function _openLoginDialogFromNative() {
        root._toggleLoginDialog()
    }

    // macOS 标题栏「右侧栏」按钮点击回调（原生 AppKit 触发）
    function _onTitleBarSidebarToggle() {
        root.rightSidebarOpen = !root.rightSidebarOpen
    }
    property bool rightSidebarOpen: false
    // 登录/个人信息对话框开关状态：供 Windows 自绘按钮绑定填色状态。
    property bool loginDialogOpen: loginDialog.visible

    // ─── 登录 / 个人信息对话框 ──────────────────────────────────────
    // 未登录：登录框（输入评分人姓名）；
    // 已登录：个人信息页（头像 / 姓名 / 系统用户 / 上传服务器），
    // 支持「修改资料」进入编辑态、「退出登录」清除身份。
    LoginDialog {
        id: loginDialog
        root: root
        updateToast: updateToast
    }

    // 注：Windows 标题栏左上角曾尝试放窗口图标（bg 内 / parent:appMenuBar /
    // parent:root.contentItem 三种挂载），日志显示 Image 创建成功且位置正确，
    // 但 Windows 场景图始终不发起绘制（status 永远 Null），决定放弃该图标。
    // 菜单直接左对齐，主界面空状态本身有图标，辨识度不受影响。

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
        onTriggered: {
            // 开发者 override（dev-upload.conf / PLAYERX_UPLOAD_URL_DEV）激活时跳过
            // 自动更新：否则 dev 构建会被 CDN 新版静默替换（开发中的 .app 直接被
            // 删了换掉，实测反复发生）；手动「帮助 → 检查更新…」不受影响。
            if (typeof Rating !== "undefined" && Rating.uploadUrlOverridden) {
                console.log("[Updater] 开发者 override 激活，跳过自动更新检查")
                return
            }
            Updater.checkForUpdates(true)
        }
    }

    // 首次失败后的重试定时器（仅触发一次）
    Timer {
        id: updateRetryTimer
        interval: 3000
        running: false
        repeat: false
        onTriggered: {
            if (typeof Rating !== "undefined" && Rating.uploadUrlOverridden) return
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
            // 【自动更新】勾选（默认）且为启动静默自检发现新版本：
            // 直接弹进度窗并自动开始下载安装，全程无需用户点击；
            // 未勾选 → 维持原逻辑（仅显示右上角胶囊，用户点击后才更新）。
            if (Updater.state === "available" && !updateDialog.userInitiated && root.autoUpdate) {
                console.log("[Updater] 自动更新开启，静默发现新版本 → 直接下载安装 v" + Updater.latestVersion)
                updateDialog.open()
                Updater.downloadAndApply()
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
            // 【开发者本地 override 生效时，忽略远端下发】
            //   PLAYERX_UPLOAD_URL_DEV 命中后，进程期内 uploadServerUrl/uploadToken 由
            //   环境变量决定，远端 latest.json 的 clientConfig 不应再回写本地。
            //   （即使这里调 setUploadServerUrl，C++ 端 setter 也会被 override 短路，
            //    这里提前 return 只是为了避免在日志里制造"看起来在切换"的噪音。）
            if (Rating.uploadUrlOverridden === true) {
                console.log("[UploadCfg] 开发者 override 生效，忽略远端 clientConfig 下发")
                return
            }
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

    // ── 开发者模式（默认不勾选）──────────────────────────────────────
    // 勾选后：模式选择菜单 / 评分数据面板 Tab 中显示「测试模式」；
    // 不勾选（默认）：测试模式隐藏。
    // 状态持久化到 QSettings（ui/developerMode），重启保持。
    property bool developerMode: false

    // 自动更新（默认不勾选）：勾选时启动静默自检发现新版本后直接自动下载安装，
    // 全程无需用户点击；不勾选则维持原逻辑（右上角胶囊提醒，手动更新）。
    // 持久化 QSettings（ui/autoUpdate），重启保持。
    property bool autoUpdate: false
    function _setAutoUpdate(on) {
        if (root.autoUpdate === on) return
        root.autoUpdate = on
        try { Rating.saveString("ui/autoUpdate", on ? "1" : "0") } catch (e) {}
        console.log("[ConfigLoad] 自动更新 =", on)
    }
    function _setDeveloperMode(on) {
        if (root.developerMode === on) return
        root.developerMode = on
        // 不持久化：仅本次会话有效，重启后一律恢复不勾选（见启动处）
        // 取消勾选开发者模式时，若当前正处于测试模式，立即回退为「关闭评分」
        if (!on && typeof Rating !== "undefined" && Rating.currentMode === "test") {
            console.log("[DevMode] 开发者模式关闭，当前模式为 test → 回退为 off")
            Rating.currentMode = "off"
        }
        console.log("[DevMode] 开发者模式:", on ? "勾选（显示测试模式）" : "未勾选（隐藏测试模式）")
    }

    // ─── 顶层快捷键（与 MenuBar 解耦） ────────────────────────────────
    // QtQuick.Controls 的 MenuItem 没有 shortcut 属性，必须用独立 Shortcut。
    // 这些快捷键是窗口级（context: ApplicationShortcut），无论焦点在哪都可触发。
    Shortcut {
        sequences: [StandardKey.Open]                 // macOS: ⌘O / Win: Ctrl+O
        context: Qt.ApplicationShortcut
        enabled: Engine.fileCount < 9
        onActivated: fileDialogs.addDialog.open()
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
        sequences: [StandardKey.Quit]                 // macOS: ⌘Q / Win: Ctrl+Q
        context: Qt.ApplicationShortcut
        onActivated: Qt.quit()
    }

    // F1 / ? 全局打开「快捷键」对话框（行业惯例：F1 = Help，? = 速查）
    Shortcut {
        sequence: "F1"
        context: Qt.ApplicationShortcut
        onActivated: shortcutsAboutDialogs.openShortcuts()
    }
    Shortcut {
        sequence: "?"
        context: Qt.ApplicationShortcut
        onActivated: shortcutsAboutDialogs.openShortcuts()
    }

    // ScRow / ScSection 组件已拆分至 ScRow.qml / ScSection.qml


    // ─── 快捷键 + 关于对话框（拆分至 ShortcutsAboutDialogs.qml） ──────
    ShortcutsAboutDialogs {
        id: shortcutsAboutDialogs
        anchors.fill: parent
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
    UpdateDialog {
        id: updateDialog
        root: root
    }

    // 简易 toast：右下角短暂提示（用于"已是最新版本"等轻量信息）
    UpdateToast {
        id: updateToast
        root: root
    }

    // ─── 任务更新通知卡片 ─────────────────────────────────────────────
    // 后台检测到远程配置有更新时浮现，用户点击后逐条应用，不阻塞任何操作。
    // 位置：左下角，常驻按钮上方。

    // 全窗透明遮罩：卡片展开时点击卡片外任意位置即收起。
    // 实现说明：Popup 在 overlay 层渲染，永远高于普通内容；该 MouseArea 以高 z
    // 盖住窗口内其它元素（含铃铛按钮，避免"按下关闭→onClicked 又重开"的打架），
    // 但始终位于 Popup 之下——点卡片内部正常交互，点外部任意处关闭。
    // 滚轮事件 MouseArea 不处理，自然穿透到下层。
    TaskUpdateDismissArea {
        id: taskUpdateDismissArea
        root: root
    }

    TaskUpdateCard {
        id: taskUpdateCard
        root: root
        updateToast: updateToast
        testSourceDownloadDialog: testSourceDownloadDialog
        testSourceGroupDialog: testSourceGroupDialog
        testSourceRedownloadDialog: testSourceRedownloadDialog
        dimReloadTimer: _dimReloadTimer
        ratingsDialog: ratingsDialog
        ratingToast: videoArea.ratingToast
    }


    // ─── 测试源下载弹窗 ──────────────────────────────────────────────────────
    //  · 应用配置后若携带 testSource 对象，自动化流水线弹出此弹窗展示进度：
    //    下载 → 解压 → 导入 → 进入打分（全程自动，完成后自动收起）
    TestSourceDownloadDialog {
        id: testSourceDownloadDialog
        root: root
    }


    // ─── 关闭全部视频：二次确认（深色，与 about/shortcuts 风格一致）──
    //  · 触发源：工具栏【✕ 全部】、菜单【文件 ▸ 关闭所有视频】、快捷键 ⌘W/Ctrl+W
    //  · 设计：modal + 深色面板 + 阴影 + 自绘 footer（取消/确认清空），避免误触
    //  · 操作只调 Engine.closeAll()，不影响本地 ratings.csv（评分独立保存）
    ConfirmCloseAllDialog {
        id: confirmCloseAllDialog
        root: root
    }

    // ─── 恢复默认配置确认对话框 ─────────────────────────────────────────
    // 触发源：顶部菜单【设置 ▸ 测试配置 ▸ 恢复默认】。
    // 确认后清掉当前模式的远程临时覆盖（dimsByMode / checklistByMode /
    // tagByMode 中该模式条目），回到跟随软件的内置默认配置
    // （Resources/default_configs/<mode>.json）；成功后右下角 toast 轻量反馈。
    RestoreDefaultConfirmDialog {
        id: restoreDefaultConfirmDialog
        root: root
        updateToast: updateToast
        confirmCloseAllDialog: confirmCloseAllDialog
    }

    ClearHistoryConfirmDialog {
        id: clearHistoryConfirmDialog
        root: root
        updateToast: updateToast
        multiGroupDialog: multiGroupDialog
    }

    // ─── 统一的扁平按钮 / 工具按钮 ──────────────────────────────────────
    // 完全用 Rectangle + MouseArea 自绘，不依赖 Qt Quick Controls 的全局
    // 风格设置（macOS 上 setStyle("Basic") 在某些 Qt 版本下不生效，会
    // fallback 到 native 风格，导致 background/contentItem 委托失效）。
    // 这里直接自绘可保证 hover/pressed 反馈在所有平台一致可见。
    // FlatButton 组件已拆分至 FlatButton.qml


    // FlatToolButton 组件已拆分至 FlatToolButton.qml


    // ─── 工具：把秒数格式化为 HH:MM:SS ───────────────────────────────────

    // ─── 子组件透传接口（为 VideoCellDelegate 等抽离组件提供稳定入口） ──
    //   抽离子组件后，子组件通过 viewRoot.* 访问 Main 内部 id。这里把
    //   "替换本路 / slot→player 索引 / 视频区抢焦点" 三个最常用的内部
    //   交互封装成纯函数，避免子组件直接依赖 videoArea / replaceDialog 这些
    //   Main 私有 id。新增图片模式 / 其他媒体模式时复用同一组接口即可。
    function openReplaceFor(idx) {
        // 等价于原 delegate 内的两步：root.pendingReplaceIdx = idx; fileDialogs.replaceDialog.open()
        pendingReplaceIdx = idx
        fileDialogs.replaceDialog.open()
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

    // ─── 播放器"首末帧守卫"派生属性 ──────────────────────────────────────
    // 用途：底部工具栏 `<<`/`<`/`>`/`>>` 与键盘 ←/→/,/. 判断是否已到首/末帧，
    //       到达时把对应按钮置灰、快捷键短路，避免用户连按导致解码器空跑卡顿。
    // 单帧时长 fd：优先取 C++ 侧 Engine.frameDuration()（多路取最小值，与
    //   rbStepFrame 内部推进步长同一口径）；未打开视频时兜底 1/30 秒。
    // 阈值取半帧（fd*0.5）：视频末帧的 PTS 是 duration - fd，若严格用 duration
    //   判断会把最后一帧永远视为"未到末尾"。用半帧容差刚好覆盖 PTS 精度误差，
    //   同时不会误伤中间任意一帧。
    // 依赖变化：Engine.position / Engine.duration / Engine.fileCount。这些 property
    //   的信号都会正常触发本 readonly property 重算，无需手动 emit。
    readonly property real _playerFrameDur: {
        if (Engine.fileCount <= 0) return 1.0 / 30.0
        var fd = (typeof Engine.frameDuration === "function") ? Engine.frameDuration() : 0
        return (fd && fd > 0) ? fd : (1.0 / 30.0)
    }
    readonly property bool _atFirstFrame:
        Engine.fileCount > 0
        && Engine.duration > 0
        && Engine.position <= root._playerFrameDur * 0.5
    readonly property bool _atLastFrame:
        Engine.fileCount > 0
        && Engine.duration > 0
        && (Engine.duration - Engine.position) <= root._playerFrameDur * 0.5

    // 点击/快捷键守卫用的"即时判定"函数：
    // 属性绑定 _atFirstFrame/_atLastFrame 在极少数场景（例如 seek 后 QML 端
    // 属性重求值稍有滞后、或多路独立时钟场景下派生依赖没及时刷新）可能出现
    // "视觉已回退但 _atLastFrame 仍为 true"的窗口，导致快退后立刻点"下一帧"
    // 又被短路，用户体验成"卡死了"。这里在每次点击/快捷键触发时【当场】重新
    // 读取 Engine.position / duration / frameDuration()，绕开任何属性缓存/
    // 绑定链，保证只要用户看到位置已经回退，"下一帧/快进"就能立刻恢复可用。

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
    // 每次维度更新时递增，供 VideoCellDelegate 内层 Repeater 强制重新求值
    property int reviewDimensionsVersion: 0
    // checklist 列表（来自配置 checklists 字段，多维评分模式下打完总分后弹出）
    property var reviewChecklist: []
    // checklist 互斥 key（exclusive_key 字段，勾选后自动取消其他选项）
    property string reviewChecklistExclusiveKey: ""

    // ── checklist 互斥 key 解析（兼容两种配置落盘形态）────────────────
    // 现行管理端（"互斥"徽标 / 选项编辑弹窗）会同时写
    //   checklist_config.exclusive_key = "<key>" 和 checklists[i].exclusive = true；
    // 但旧版管理端 / 手工编辑的 JSON 只会在选项上标 exclusive: true，
    // 此时 checklist_config 整个缺失，若只认 exclusive_key 就会导致
    // "后台明配置了互斥，弹窗里却能全部勾选"。因此两种形态都认：
    // 优先 exclusive_key，缺省时取 checklists 里第一个 exclusive === true 的选项。

    // ── 同步"当前模式合法 checklist keys"到 C++（用于导出/上传 CSV 时按白名单过滤）──
    // 【问题背景】checklist 勾选数据存 QSettings 的 "checklist:<filePath>" key，
    //   跨模式共享（不带 mode 前缀）。用户先在 A 模式勾选后切到 B 模式重新评分，
    //   B 模式的配置里若没有对应 checklist，导出 CSV 时旧勾选会被带出去（图1 的
    //   "测试模式却上传了 physics_issue" 就是这样来的）。
    // 【修复方式】QML 侧在每次 reviewChecklist 变化时（模式切换 / 应用远程配置 /
    //   加载持久化），把当前模式的合法 keys 集合同步给 C++；C++ 导出时按此白名单
    //   过滤 checklist 列。空数组 = 当前模式无 checklist，CSV 里 checklist 列全部为空。
    // 【为什么用 active=true 而不是 clear】：切换到"没有 checklist 的模式"时
    //   reviewChecklist 是 []，我们要显式过滤成空字符串输出——而不是恢复到
    //   "不过滤"（那样又会串回旧数据）。因此这里始终 active=true，仅用 keys 长度
    //   区分"过滤成空" vs "过滤保留特定 keys"。
    onReviewChecklistChanged: Logic._syncChecklistWhitelist()
    property real _bootT0: 0
    // quality_slide 模式下：reviewDimensions[1] 专用于滑动对比，不在 cell 评分条中显示；
    // 其余维度（第 1 维 + 第 3 维起的全部维度）都进 cell 评分条。
    // 其他模式下与 reviewDimensions 完全一致。
    readonly property var cellReviewDimensions: {
        if (!isQualitySlideMode || !reviewDimensions || reviewDimensions.length < 2)
            return reviewDimensions
        var out = []
        for (var i = 0; i < reviewDimensions.length; ++i) {
            if (i === 1) continue // 跳过滑动对比专用维度
            out.push(reviewDimensions[i])
        }
        return out
    }
    // 按 mode 缓存各自的维度列表，避免多 mode 应用时互相覆盖
    property var _dimsByMode: ({})
    // 按 mode 缓存各自的 checklist（checklists + checklist_config），模式切换时同步更新 reviewChecklist
    // 没有 checklist 的模式存 null，切换时会清空 reviewChecklist，避免旧模式数据残留
    property var _checklistByMode: ({})

    // ── 内置默认配置（出厂配置，跟随软件发布，永远在）────────────────────
    // 每模式一份 JSON：Resources/default_configs/<mode>.json，结构与服务端配置一致
    // （{ type, tag, task, scale, dimensions, checklists, checklist_config }）。
    // 运行时拆成三张内置表；查询配置统一走 _dimsForMode/_checklistForMode/_tagForMode，
    // 规则是"远程覆盖层优先、内置默认兜底"：
    //   - _dimsByMode/_checklistByMode/_tagByMode 是【覆盖层】，只存远程"接受"来的
    //     临时配置（持久化在 dimsByMode.json / checklistByMode.json / tagByMode.json）；
    //   - 内置表只读、永不落盘 → 任何时刻都能 _restoreDefaultConfig 回到出厂状态；
    //   - 升级软件即拿到最新内置默认（启动时 _pruneOverridesEqualToBuiltin 会把
    //     覆盖层里"内容等于旧默认"的僵尸条目清掉，避免遮蔽新默认）。
    property var _builtinDimsByMode: ({})
    property var _builtinChecklistByMode: ({})
    property var _builtinTagByMode: ({})


    // 生效配置查询：覆盖层优先、内置默认兜底

    // 把某模式的生效配置（覆盖层优先、内置兜底）应用到当前 UI。
    // 仅在 mode === Rating.currentMode 的场景调用（启动恢复 / 恢复默认）。

    // 恢复某模式为内置默认配置：清掉远程"接受"留下的临时覆盖层并立即生效。
    // 覆盖层文件里只保留真正的远程覆盖，因此恢复后重启也依旧是默认配置。

    // 规范化序列化（忽略 starCount 等运行时注入字段），用于判断覆盖层条目与内置默认是否内容一致

    // 启动时清理：覆盖层里与内置默认内容完全一致的条目（历史版本落盘的旧默认）直接删除，
    // 否则旧默认会永远遮蔽新版本软件携带的新内置默认。

    // 【按 mode 独立持久化】把 _dimsByMode 整体写入 Resources/dimsByMode.json，
    // 供下次启动加载。这是保证多 mode 配置互不覆盖的关键落盘。

    // 【按 mode 独立持久化 checklist】与 tagByMode.json 完全平行

    // 【按 mode 独立缓存 tag】各评分模式对应各自远程配置的 tag（如 "0.0.8_subj_0714"）。
    // 之所以必须"按 mode 分"：Rating.uploadTag 是全局单值，如果多个 mode 都往它/_remoteTag
    // 上写，最后加载的那个 mode 会覆盖前面所有 mode 的 tag，导致 RatingsDialog 右上角
    // 输入框、上传逻辑无法区分各 mode 各自的 tag。
    // 持久化文件：Resources/tagByMode.json，形如 { "multi_dim": "0.0.8_subj_0714", ... }。
    property var _tagByMode: ({})


    // 【统一入口】把某个 mode 的 tag 写入按 mode 缓存并落盘。
    // 使用深拷贝赋值以确保 property var 的响应式通知（与 _dimsByMode 保持一致的写法）。

    // 远程激活配置的 tag（加载维度时同步写入，供上传时校验用）
    // 【语义】始终等于"当前 Rating.currentMode 对应的 tag"（跟随 mode 切换而变化），
    // 由 _tagByMode + onCurrentModeChanged 保证。上传时 RatingStore 读的是 Rating.uploadTag，
    // 我们在切 mode 时也同步刷新 Rating.uploadTag，保证 UI/上传/校验三者一致。
    property string _remoteTag: ""

    // 标志位：_applyRemoteConfigItem 正在处理维度，onCurrentModeChanged 应跳过，避免两处竞争
    property bool _applyingConfig: false

    // 【强制维度刷新】暂存待生效的维度数组，Timer 触发时赋值
    property var _pendingDimsToApply: null
    property string _pendingTagToApply: ""

    // 【强制维度刷新】两阶段刷新 Timer：先清空 reviewDimensions（销毁所有星星 delegate），
    // 延迟一小段时间后再赋新值（重建全部 delegate，从新的 modelData 读 starCount）。
    // 这是解决"数量不变但 starCount 变化时 Repeater 不重建"的最可靠方式。
    Timer {
        id: _dimReloadTimer
        interval: 60
        repeat: false
        onTriggered: {
            var dims = root._pendingDimsToApply
            if (!dims || !Array.isArray(dims)) return
            root.reviewDimensions = dims
            root.reviewDimensionsVersion = root.reviewDimensionsVersion + 1
            if (root._pendingTagToApply && typeof Rating !== "undefined") {
                Rating.uploadTag = root._pendingTagToApply
            }
            root._remoteTag = root._pendingTagToApply || ""
            root._applyingConfig = false
            console.log("[DimReload] 强制重建完成，维度：",
                dims.map(function(d){return d.key + "(" + (d.starCount || (d.levels && d.levels.length) || 5) + "星)"}).join(", "))
            // 【关键修复】维度到位后，若已有文件加载，主动重跑一次评分回填。
            //   原因：启动 / 应用远程配置期间会经历「reviewDimensions = []」的空
            //   窗期（阶段 1 → Timer 阶段 2 之间约 60ms）。如果这段时间用户刚好
            //   打开了文件夹（onFilesChanged 触发），回填逻辑会走 !hasDims 分支，
            //   cellRatings 结构错误（标量而非对象），星星显示全空。
            //   到这里 reviewDimensions 已经重建完毕，重跑一次幂等回填即可修正 UI。
            if (typeof Engine !== "undefined" && Engine.fileCount > 0) {
                Logic._rebuildCellRatingsFromCsv("dimReload")
            }
        }
    }

    // 【评分回填】用当前 reviewDimensions 从 CSV 重建 cellRatings + 滑动评分。
    //   幂等：多次调用结果一致；不触碰 selectedIdx，避免干扰用户选中状态。
    //   两个调用点：
    //     · onFilesChanged（翻组 / 切宫格 / 打开文件）
    //     · _dimReloadTimer.onTriggered（远程配置应用完成后 / 启动首次加载完成后）

    // 【强制维度刷新】外部统一入口：先清空 → 定时器触发 → 赋新值
    // dims:      维度数组（必须已预注入 starCount）
    // tag:       远程 tag（可选）
    // forMode:   本次刷新面向的 mode（可选，二重防线：与 Rating.currentMode 不同则拒绝执行）
    // reason:    调用来源标签（日志用）

    // 监听 Rating.currentMode 变化：自动从 _dimsByMode 加载对应 mode 的维度
    // 这样无论是通知卡片应用、手动切换 mode，reviewDimensions 都能跟随 mode 正确切换
    Connections {
        target: Rating
        function onCurrentModeChanged() {
            // _applyRemoteConfigItem 正在处理，跳过（由它统一负责维度更新）
            if (root._applyingConfig) return
            var mode = Rating.currentMode
            if (!mode || mode === "off") return
            // 【checklist 跟随 mode 切换】从 _checklistByMode 读取新 mode 的 checklist，
            // 没有配置（null / 空数组）则清空，避免旧模式的 checklist 残留导致所有模式都弹窗。
            // 【QML 陷阱】property var 里的数组读出来 Array.isArray() 返回 false，必须用 length duck-typing
            var _ckForMode = Logic._checklistForMode(mode)
            var _hasCkMode = _ckForMode && _ckForMode.items
                    && typeof _ckForMode.items.length === "number"
                    && _ckForMode.items.length > 0
            if (_hasCkMode) {
                var _plainCkMode = []
                for (var _cki = 0; _cki < _ckForMode.items.length; _cki++) _plainCkMode.push(_ckForMode.items[_cki])
                root.reviewChecklist = _plainCkMode
                root.reviewChecklistExclusiveKey = _ckForMode.exclusiveKey || ""
                console.log("[ChecklistModeChange] mode=", mode, "同步 checklist 条数:", _plainCkMode.length)
            } else {
                root.reviewChecklist = []
                root.reviewChecklistExclusiveKey = ""
                console.log("[ChecklistModeChange] mode=", mode, "无 checklist，已清空")
            }
            // 【tag 跟随 mode 切换】先把该 mode 对应的 tag 灌回 _remoteTag + Rating.uploadTag，
            // 这样 RatingsDialog 显示的备注 tag、上传时的 tag 都能正确反映            // 若该 mode 还没缓存 tag（历史遗留 / 未同步过），沿用旧 _remoteTag 兜底，避免误清空。
            var tagForMode = Logic._tagForMode(mode)
            if (tagForMode.length > 0) {
                root._remoteTag = tagForMode
                if (typeof Rating !== "undefined" && Rating.uploadTag !== tagForMode) {
                    Rating.uploadTag = tagForMode
                }
            }
            var cachedRaw = Logic._dimsForMode(mode)
            // 【关键】QML property var 里的数组读出来可能是 QJSValue/QVariantList，Array.isArray=false。
            // 用 length 做 duck-typing 判断，并转成纯 JS 数组再传给 _forceApplyDimensions，
            // 避免函数入口的 Array.isArray 校验静默拒绝。
            if (cachedRaw && typeof cachedRaw.length === "number" && cachedRaw.length > 0) {
                var cached = []
                for (var _k = 0; _k < cachedRaw.length; _k++) cached.push(cachedRaw[_k])
                // 【强制两阶段刷新】切换 mode 时也强制清空后重建，保证 starCount 生效
                Logic._forceApplyDimensions(cached, root._remoteTag, mode, "modeChange")
                console.log("[DimSync] mode 切换到", mode, "，_dimsByMode 全部 keys:",
                    Object.keys(root._dimsByMode).join(","),
                    "，本 mode 加载维度：",
                    cached.map(function(d){return d.key + "(" + d.starCount + "星)"}).join(", "))
            } else {
                console.log("[DimSync] mode 切换到", mode, "，但 _dimsByMode[", mode, "] 为空/未设置，keys:",
                    Object.keys(root._dimsByMode).join(","))
            }
        }
    }

    // ── 任务后台差异检测 ──────────────────────────────────────────────
    // 设计：启动时先用本地缓存初始化（零延迟），后台静默拉取远程配置做指纹对比。
    // 有差异时弹出通知卡片，用户主动点击后才应用远程配置，不阻塞任何操作。
    // 轮询间隔：5 分钟（软件运行期间持续检测）。

    // 本地已应用配置的指纹映射 { mode -> fingerprint }（用于与远程对比）
    property var    _localConfigFingerprint: ({})
    // 待应用的远程配置列表（检测到差异时暂存，等用户点击通知卡片后才应用）
    // 每项：{ mode, obj, configName }
    property var    _pendingRemoteConfig: null
    // 【手动应用】远程当前绑定的全部配置（含已是最新的），结构同 _pendingRemoteConfig。
    // 由 _checkRemoteConfigUpdate 在 onAllDone 里填充（无论有无差异）；
    // 卡片用它展示完整列表，每条带"应用"按钮，让用户能主动选远程配置作为启动项。
    property var    _remoteAllConfigs: []
    // 卡片标题状态标志：true=有更新（"远程有新任务"），false=无更新但展示全部（"远程任务"）
    property bool   _remoteHasUpdate: false
    // 【手动应用】卡片真正展示的合并列表：
    //   · 优先放 _pendingRemoteConfig（有差异的，标注"有更新"）；
    //   · 再把 _remoteAllConfigs 里有、但不在 pending 的配置补进来（标注"当前最新"）。
    //   用 mode:configName 去重，避免同一条显示两次。
    readonly property var _remoteConfigCardList: {
        var pending = Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig : []
        var all = Array.isArray(root._remoteAllConfigs) ? root._remoteAllConfigs : []
        var out = []
        var seen = {}
        function _key(it) { return (it.mode || "") + ":" + (it.configName || "") }
        pending.forEach(function(it) { var k = _key(it); seen[k] = true; out.push(it) })
        all.forEach(function(it) {
            var k = _key(it)
            if (!seen[k]) { seen[k] = true; out.push(it) }
        })
        // 开发者模式未开启时，过滤掉「测试模式」的远程任务（测试配置仅开发者可见，避免影响用户）
        if (!root.developerMode) {
            out = out.filter(function(it) { return it.mode !== "test" })
        }
        return out
    }
    // 通知卡片是否可见
    property bool   _taskUpdateVisible: false

    // 计算配置指纹：全量 JSON 序列化，任何字段变化都能检测到

    // 手动点🔔后可见列表为空时的轻提示（右下角 toast）：
    //   · hiddenCount > 0：服务器有任务但全是「测试模式」且未开开发者模式 → 引导开启
    //   · hiddenCount = 0：服务器确实没有任务
    // 避免弹出一张空卡片让用户以为"点了没反应"。

    // 后台静默检测所有模式的远程配置是否有更新（不影响当前已加载的配置）
    // 流程：先拉 /api/active-config 获取所有模式绑定，再并发请求每个配置内容，
    //       任意一个模式与本地指纹不同，就弹出通知卡片。
    // openCardOnNoUpdate：无差异时是否打开卡片展示全部远程配置。
    //   · 后台静默轮询/启动装载：默认 false（不打扰用户，仅静默刷新 _remoteAllConfigs 数据）
    //   · 用户手动点 🔔 按钮检测：传 true（弹出卡片展示完整列表 + 应用按钮）

    // ─── 测试源全自动流水线（点「接受」后一键就绪）────────────────────────────
    // 评分配置 JSON 中新增 testSource 对象字段：
    //   "testSource": {
    //     "url":          "https://.../bench_xxx.zip",  // 必填：测试源压缩包地址
    //     "workDir":      "~/Downloads",                 // 可选：下载+解压目录（默认系统 Downloads；支持 ~ 开头）
    //     "rootDir":      "bench_xxx",                   // 可选：内容根目录（相对 workDir，"/" 开头
    //                                                    //   视为绝对路径；即 zip 内的顶层目录名）
    //     "laneDirs":     ["A", "B"],                    // 必填：参与对比的子目录（按顺序对应第 1..N 路）
    //     "referenceDirs":["first_frames","second_frames"], // 可选：参考图目录（相对内容根，最多 2 个，
    //                                                    //   按顺序对应侧栏两个参考图窗口；旧写法 referenceDir 单串仍兼容）
    //     "promptCsv":    "prompt.csv"                   // 可选：提示词 CSV（相对内容根）
    //   }
    // 流水线：下载（复用下载弹窗显示进度）→ 解压（Fs.extractZipAsync）→
    //         按配置定位内容根（纯配置驱动，不做目录探测）→ 绑定参考图/提示词 →
    //         multiGroupDialog.loadFolders 导入并直接启动 → 进入打分界面。
    // _tsAuto 非空表示流水线进行中（同时是下面两组 Connections 的使能开关）。
    property var _tsAuto: null


    // ── 重复下载检测 ──
    // 判重依据（三重条件同时满足才允许"跳过下载"）：
    //   ① 归一化后的 testSource 配置与上次完全一致（url/workDir/rootDir/laneDirs/referenceDirs/promptCsv）；
    //   ② 上次的 zip 仍在磁盘上；
    //   ③ 上次解压出的内容根目录仍在。
    // 满足则弹「直接开始 / 重新下载 / 取消」；任一不满足（配置变了 / 产物被删）→ 静默走完整下载。


    // 内容根绝对路径（与 _tsImportAndStart 的解析规则一致）

    // 解析测试源 url：
    //   · 绝对地址（http/https，如 COS 外链）→ 原样使用；
    //   · 相对路径（/testsrc/xxx.zip）→ 按当前配置服务器的 origin 拼接 ——
    //     配置可原样拷贝迁移服务器，url 永远不用手改；
    //   · 其他形态（file:// 等）→ 原样交给下载器。


    // 真正开始下载（普通路径与「重新下载」强制路径共用）

    // 解压完成后：定位测试源根目录 → 绑定参考图/提示词 → 导入多路并启动。
    // 返回 "" 表示成功；非空为错误描述（显示在下载弹窗上）。

    // 暂存目录名（workDir 内）：测试源先解压到这里，校验/适配后再原子换名到位
    readonly property string _tsStagingName: ".playerx_ts_staging"

    // ─── 组别（g1/g2 二级目录）─────────────────────────────────────
    // 选组挂起时的上下文（st + extractTarget）；用户最近选择的组（会话内记忆）
    property var    _tsGroupCtx: null
    property string _tsLastGroup: ""

    // 检测内容根下的「组别」子目录：包含全部 laneDirs 的二级目录（如 g1/g2）。
    // 返回组名数组（仅名字）。__MACOSX 等杂质目录天然不含 laneDirs，自动排除。

    // 解析「评分人→组别」映射，命中返回组别名，否则返回 ""。
    // 新结构：ts.groups 为对象 {"g1": ["张三","李四"], "g2": []}（空组 = 空数组）；
    // 旧结构：ts.groupMap 为 "张三:g1, 李四:g2" 字符串（老后台/老配置写入），
    // 两种格式自动识别，老客户端读新结构时查不到映射则安全降级为手动选组。

    // 组别门：内容根下检测到组别目录时，弹窗让用户选择要导入的组，
    // 选定后由 _tsOnGroupChosen 继续原导入流程。
    // 返回 true = 已挂起等用户选择（调用方应直接 return）；false = 无需选组。

    // 选组确认：把所选组挂到 st 上，继续原导入流程（错误回显到下载弹窗）



    // 把暂存目录里的解压结果放到最终内容根目录（extractTarget/rootDir）。
    // 适配规则：
    //   ① staging/rootDir 存在 → 正常路径（zip 结构与配置一致）；
    //   ② 不存在但 staging 里只有 1 个顶层目录 → zip 被改过名（内部顶层目录名
    //      与 rootDir 配置不一致），自动把该目录当内容根并改名为 rootDir；
    //   ③ 其他 → 报错并列出实际解压出的顶层目录，引导修正配置。
    // 就位前才清理旧内容根（护栏：必须严格位于 extractTarget 内部），
    // 因此解压/适配失败时旧内容原样保留，不会像"先删再解"那样丢内容。
    // 返回 "" 成功；非空为错误描述。

    // ── 测试源自动化：下载完成 → 解压 ──
    Connections {
        target: (typeof Downloader !== "undefined") ? Downloader : null
        enabled: root._tsAuto !== null
        function onFinished(ok, savePath, errorMsg) {
            var st = root._tsAuto
            if (!st) return
            if (!ok) {
                testSourceDownloadDialog._status = "error"
                testSourceDownloadDialog._statusText = "下载失败：" + (errorMsg || "网络错误")
                root._tsAuto = null
                return
            }
            testSourceDownloadDialog._progress = 1.0
            testSourceDownloadDialog._status = "downloading"   // 保持进度条满格可见
            testSourceDownloadDialog._statusText = "下载完成，正在解压…"
            // rootDir 为非空相对路径（常规）：先解压到暂存目录，由 onZipExtracted
            // 校验/适配后原子换名到位 —— zip 文件名随便改不影响（按 zip 内实际
            // 顶层目录适配），且 ditto/Expand-Archive 的"合并覆盖"不会再残留污染；
            // 解压失败时旧内容根目录原样保留。
            // rootDir 为空 / 绝对路径（少见）：保持旧行为直接解压到 workDir。
            var _rootRel = String(st.ts.rootDir || "").trim()
            var _dest = st.extractTarget
            if (_rootRel.length > 0 && _rootRel.charAt(0) !== "/") {
                _dest = st.extractTarget + "/" + root._tsStagingName
                if (Fs.isDirectoryPath(_dest)) Fs.removeDirRecursively(_dest)
            }
            Fs.extractZipAsync(st.zipPath, _dest)
        }
    }

    // ── 测试源自动化：解压完成 → 导入 + 绑定 + 启动 ──
    Connections {
        target: (typeof Fs !== "undefined") ? Fs : null
        enabled: root._tsAuto !== null
        function onZipExtracted(ok, destDir, errorMsg) {
            var st = root._tsAuto
            if (!st) return
            root._tsAuto = null
            if (!ok) {
                testSourceDownloadDialog._status = "error"
                testSourceDownloadDialog._statusText = "解压失败：" + (errorMsg || "无法解压 zip")
                return
            }
            testSourceDownloadDialog._statusText = "解压完成，正在导入…"
            // 走了暂存目录的，先把内容校验/适配并换名到最终内容根目录
            var _suffix = "/" + root._tsStagingName
            if (destDir.slice(-_suffix.length) === _suffix) {
                var _placeErr = Logic._tsPlaceStagedContent(st, destDir)
                if (_placeErr.length > 0) {
                    testSourceDownloadDialog._status = "error"
                    testSourceDownloadDialog._statusText = _placeErr
                    return
                }
            }
            // 组别门：内容根下含 g1/g2 等组别时，先弹窗让用户选组再继续
            if (Logic._tsGateGroup(st, st.extractTarget)) return
            var err = Logic._tsImportAndStart(st, st.extractTarget)
            if (err.length > 0) {
                testSourceDownloadDialog._status = "error"
                testSourceDownloadDialog._statusText = err
                return
            }
            // 记录本次产物（配置指纹 + zip 路径 + 解压目标），供下次「跳过下载」判重
            Logic._tsSaveLastAuto(st)
            // 成功：静默关闭下载弹窗（直接进入打分界面）；
            // 弹窗只保留给下载/解压/导入过程和失败场景。
            testSourceDownloadDialog.close()
        }
    }

    // ─── 测试源组别选择对话框 ─────────────────────────────────────────
    // 测试源内容根下检测到多个组别（g1/g2…）时，接受后弹出让用户选择要导入的一组，
    // 选定后按该组继续原流程；取消则中止本次自动化。
    TestSourceGroupDialog {
        id: testSourceGroupDialog
        root: root
    }

    // ─── 测试源重复下载确认对话框 ─────────────────────────────────────
    // 同一份 testSource 配置且 zip/解压产物都在时弹出：
    //   [直接开始] 跳过下载/解压，直接绑定 + 导入 + 进入打分；
    //   [重新下载] 强制走完整流水线（服务端内容更新时用）；
    //   [取消]     什么都不做。
    // 打开后启动 5 秒倒计时：期间点「重新下载」/「取消」中断；
    // 倒计时归零自动走「直接开始」（不打断用户的连续工作流）。
    TestSourceRedownloadDialog {
        id: testSourceRedownloadDialog
        root: root
        testSourceDownloadDialog: testSourceDownloadDialog
        testSourceGroupDialog: testSourceGroupDialog
        multiGroupDialog: multiGroupDialog
        updateToast: updateToast
    }

    // 用户点击通知卡片后，应用所有待更新的远程配置
    // 应用单条远程配置，并自动切换到对应评分模式
    // 【关键】用户点应用时【现拉一次】远程最新数据，用最新 obj 而不是差异检测阶段缓存的 item.obj
    // 保证"远程是啥，本地就是啥"
    // onDone：应用流程结束（成功/失败/兜底）后的回调，用于复位按钮的"应用中"状态


    // 启动后立即触发第一次差异检测。
    // 【无感启动优化】interval=0 表示"下一 event loop tick 立即触发"，比原来 500ms 快很多：
    //   - QML 就绪瞬间 → 立刻发起 /api/active-config + /api/configs/* 两轮 HTTP 请求；
    //   - 用户从"看到主窗口"到"选完文件夹点开始对比"通常要几秒，
    //     这几秒里远程配置往返早已完成，_dimsByMode 也已回填；
    //   - 于是"打开对比 → 星星立即渲染"，不会再有"过一会儿才弹出星星"的钝感。
    // 之所以敢去掉 500ms 缓冲：本地指纹用 EngineBridge 异步读文件（自己会等就绪），
    // Rating 模块的属性是 QQmlEngine 注册时就已经就绪的单例属性，不需要额外等待。
    // _checkRemoteConfigUpdate 内部对 Logic._dimApiUrl() 为空也做了 return 守护，
    // 即便极端时序下 Rating.uploadServerUrl 尚未就绪，也只是这一次跳过，
    // 后续 5s 的 configPollTimer 会自然把它补回来，不会破坏功能。
    // 【启动不再主动拉取远程配置】
    // 新模型：内置默认配置（Resources/default_configs/）跟随软件、永远在；
    // 远程配置只在用户手动点 🔔 检测、并在通知卡片上点"接受"时才临时覆盖本地。
    // 因此启动时这里只加载本地持久化指纹（供手动检测时做差异对比），不发起网络请求。
    Timer {
        id: configInitCheckTimer
        interval: 0
        repeat: false
        running: true
        onTriggered: {
            Logic._loadFingerprintFromFile()
        }
    }

    // 【后台轮询已停用】与"启动不主动拉取"同一策略：远程配置不再自动弹卡片打扰，
    // 完全由用户手动点 🔔 触发 _checkRemoteConfigUpdate。保留定时器定义便于以后需要时打开。
    Timer {
        id: configPollTimer
        interval: 5 * 1000
        repeat: true
        running: false
        onTriggered: Logic._checkRemoteConfigUpdate()
    }

    // ── 维度配置网络加载 ──────────────────────────────────────────────────

    // 推导本地 Resources 目录路径（与 Component.onCompleted 逻辑一致）

    // 持久化指纹到本地文件，重启后仍能检测绑定切换

    // 从本地文件加载指纹（启动时调用，callback 在加载完成后触发）
    //
    // 【钝感优化 · 方案A】
    //   实测日志显示：启动时用 XMLHttpRequest 读本地 file:// 的
    //   config_fingerprint.json，从触发到 readyState===DONE 之间会耗时
    //   ~5 秒（疑似 Qt 网络栈对本地 file scheme 的某种超时/调度），
    //   直接把首拉后置了 5 秒，导致星星要 5s 之后才弹出。
    //
    //   优化：优先用 FsUtils 暴露给 QML 的 Fs.readTextFile 做「同步」读取
    //   （底层就是 QFile.readAll，几十 KB 的 JSON 是毫秒级）。
    //   同步成功 → 立即 callback，让 _checkRemoteConfigUpdate 紧接着起飞；
    //   同步失败（Fs 未注册 / 抛异常等极端场景）→ 保底回退原异步 XHR 路径，
    //   行为与老代码完全等价，不影响任何现有功能。

    // 从任意 URL（file:// 或 https://）加载维度配置并热重载，无需重启
    // callback(ok: bool) 在请求完成后调用（成功或失败均调用，ok 表示是否成功更新了维度）
    // 【重要】增加 forMode 参数（可选）：
    //   - 若传入且 _dimsByMode[forMode] 已有缓存，直接使用缓存，跳过网络请求（避免服务端返回反覆盖本地已应用的配置）
    //   - 若传入且拿到远程数据，会校验 forMode === Rating.currentMode，否则不动 UI

    // 从 Rating.uploadServerUrl 推导维度 API 地址（去掉路径，拼上 /api/dimensions）

    // ── 当前模式绑定的评分配置名 ──────────────────────────────
    // 与 MultiGroupDialog 中的 _boundConfigName 实现一致：
    //   优先从 _localConfigFingerprint["__bindings__"] 反查（JSON: mode -> configName）
    //   兜底：遍历指纹 key（格式 "mode:configName"）取最后一个匹配。
    // 用途：底部工具栏"评分规则"按钮据此判断当前 mode 是否有可查规则，并构造跳转 URL。

    // ── 构造后端规则页面 URL：origin + /#tasks/ + encodeURIComponent(configName) ──
    // 与 MultiGroupDialog._rulesPageUrl 一致；无绑定配置或服务器地址为空时返回 ""。

    // 切换到多维模式或维度配置变化时，重新初始化 cellRatings
    // 有维度配置（不限于 multi_dim）时初始化为对象数组；无维度时恢复为数字数组
    // quality_slide 模式下：reviewDimensions[0] 给左右对比，reviewDimensions[1] 给滑动对比
    // cellRatings 只使用第一个维度，避免滑动对比维度混入普通打分界面
    onIsMultiDimModeChanged: {
        // 切换 mode 时：重建 cellRatings 结构 + 立即从 CSV 回填当前维度评分。
        // 不能只清零（_rebuildCellRatingsForDims），否则切模式后需要再手动翻组 / 重开
        // 文件夹才能看到历史评分。
        Logic._rebuildCellRatingsFromCsv("isMultiDimModeChanged")
    }
    onReviewDimensionsChanged: {
        // 维度配置更新时（启动装载 / 远程配置应用 / 模式切换后异步加载维度）：
        //   直接调 _rebuildCellRatingsFromCsv 用当前 reviewDimensions 从 CSV 回填。
        //   【重要】曾经这里调的是 _rebuildCellRatingsForDims，它只会把 cellRatings
        //   全部清零，不读 CSV。结果是：用户打开文件夹后，只要 reviewDimensions 又
        //   被赋值一次（例如"无更新"轮询里的静默同步），历史评分就会被清零，
        //   造成"重启后星星全空、跳过再切回来才修好"的体感 bug。
        Logic._rebuildCellRatingsFromCsv("reviewDimensionsChanged")
    }
    //   · 实时写入 ratings_quality_slide_slide.csv（与普通打分文件完全隔离）
    //   · 与普通 quality 评分（cellRatings）解耦，互不覆盖
    //   · 切到下一组后必须清空（_resetSlideRatings），下一组重新进入再评
    readonly property bool isQualitySlideMode:
        (typeof Rating !== "undefined") && Rating.currentMode === "quality_slide"
    // quality_slide 模式下，第二个维度（reviewDimensions[1]）专用于滑动对比评分
    // 其他模式或维度不足 2 个时为 null，兜底使用 2 星制
    readonly property var slideDimension:
        (isQualitySlideMode && reviewDimensions && reviewDimensions.length >= 2)
        ? reviewDimensions[1] : null
    readonly property int  slideMaxStars:
        (slideDimension && slideDimension.levels && slideDimension.levels.length > 0)
        ? slideDimension.levels.length : 2
    readonly property string slideDimLabel:
        (slideDimension && slideDimension.name) ? slideDimension.name : ""
    property bool slideEnteredOnce: false   // 本组中是否进入过滑动对比
    property int  slideRatingL: 0           // 滑动模式左侧评分（0=未打，1..slideMaxStars）
    property int  slideRatingR: 0           // 滑动模式右侧评分（0=未打，1..slideMaxStars）
    // 切换到新一组后，从 CSV 恢复该组已有的滑动评分（避免循环切组时评分被清零）

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
    // 当前焦点视频的绝对路径（folder 模式下，参考图按它的文件夹序号同步切换）
    readonly property string refCurrentVideo: {
        _refTick;
        var i = Logic._refTargetIdx()
        if (i < 0) return ""
        return Engine.filePathAt(i) || ""
    }
    // 当前焦点视频所在文件夹（写入参考图绑定时用作 key）
    readonly property string refCurrentFolder: {
        _refTick;
        return Logic._refDirOf(root.refCurrentVideo)
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
    // Windows 单维查表 + dpr 反比反推：
    //   1) 按物理宽（±8 容差）匹配到一行基准记录 [物理宽, baseDpr, baseScale]；
    //   2) 当前档位系数 = baseScale × baseDpr / curDpr。
    // 这覆盖任何缩放档位（100/125/150/175/200/250%…），不再依赖逐档采样。
    // 命中返回反推后的系数；未命中（陌生物理屏）返回 -1，让上层走公式 →
    // 默认表兜底。
    // 手动微调系数（被尺寸弹窗里 ▲/▼ 步进按钮调用）。
    //   · delta 通常是 ±0.01；
    //   · 用 Math.round(v*100)/100 抹掉浮点抖动（0.77+0.01=0.7800000000000001）；
    //   · 严格夹紧到 [0.1, 5.0] —— 与 phoneScaleInput 的 DoubleValidator 一致；
    //   · 自动关闭 phoneScaleAutoTrack，防止下次屏幕参数变化把刚校准的值覆盖。
    Connections {
        target: Screen
        function onWidthChanged()  { Logic._applyAutoPhoneScale() }
        function onHeightChanged() { Logic._applyAutoPhoneScale() }
        function onNameChanged()   { Logic._applyAutoPhoneScale() }
        function onPixelDensityChanged() { Logic._applyAutoPhoneScale() }
        function onDevicePixelRatioChanged() { Logic._applyAutoPhoneScale() }
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
            Qt.callLater(Logic._applyAutoPhoneScale)
        }
    }

    onScreenChanged: {
        Logic._applyAutoPhoneScale()
        Qt.callLater(Logic._applyAutoPhoneScale)
    }
    onWidthChanged: {
        if (root.phoneScaleAutoTrack) Qt.callLater(Logic._applyAutoPhoneScale)
    }
    onHeightChanged: {
        if (root.phoneScaleAutoTrack) Qt.callLater(Logic._applyAutoPhoneScale)
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
                Logic._applyAutoPhoneScale()
            }
        }
    }

    // 切换手机尺寸预设（440×956 / 402×874 …）时，若仍在自动跟随，重算系数
    onPhoneFixedWidthChanged: Logic._applyAutoPhoneScale()
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
    // 可选第二行（与第一行异色：第一行白、第二行用 kind 主色），空串=单行
    property string ratingToastText2: ""
    property string ratingToastKind: "score"
    property int    ratingToastScore: 0
    // durationMs：可选显示时长（默认快闪 880ms；长文案提示传入更长时长）
    // fontPx：可选字号（默认 22；两行提示建议 18）
    // text2：可选第二行（与第一行异色：第一行浅白、第二行警示橙）
    // sticky：可选，true = 不自动消失，显示「知道了」按钮手动关闭

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
        // 具体回填逻辑抽到 Logic._rebuildCellRatingsFromCsv（供 _dimReloadTimer 复用）。
        function onFilesChanged() {
            Logic._rebuildCellRatingsFromCsv("filesChanged")
            // 切换文件 / 翻组 / 改宫格后，主动复位 selectedIdx，避免上一组的
            // 选中（蓝边）残留误导。用户若需要再选中，单击或 [ / ] 即可。
            // （注意 selectedIdx 复位不放进 _rebuildCellRatingsFromCsv：远程配置
            //  应用完成后的重跑不应该干扰用户当前选中状态。）
            root.selectedIdx = -1
            // 全部关闭回到主界面（fileCount 归零）：自动收起参考图侧栏 + 底部提示词栏，
            // 等价于点一次左下角「图片」按钮（两者显隐都跟随 refSidebarVisible）
            if (Engine.fileCount <= 0 && root.refSidebarVisible)
                root.refSidebarVisible = false
        }
    }

    // 切换函数：仅在 fileCount === 2 时允许进入；离开 2 路场景时强制关闭
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
    FileDialogs {
        id: fileDialogs
        root: root
        multiGroupDialog: multiGroupDialog
    }

    // ─── 底部工具栏 ──────────────────────────────────────────────────────
    // 自绘 background：深色填充 + 顶部 1px 分隔线，与视频区在视觉上彻底
    // 切开。原先 ToolBar 用系统主题色，与视频黑底界限模糊，按钮按下时还
    // 会引起整体重绘抖动。
    // 放在 footer：Windows 上避免"菜单栏 + 工具栏"的双顶栏观感；每路视频
    // 有各自的 OSD 进度条，这里承载的是全局播放控制（快进/快退/帧步进/
    // 播放暂停/重置/多组切换/倍速徽标），放到窗口底部更符合主流播放器习惯。
    footer: TopBar {
        id: topBar
        root: root
        updateDialog: updateDialog
        confirmCloseAllDialog: confirmCloseAllDialog
        multiGroupDialog: multiGroupDialog
        quickUploadConfirmDialog: quickUploadConfirmDialog
        updateToast: updateToast
        testSourceDownloadDialog: testSourceDownloadDialog
        testSourceGroupDialog: testSourceGroupDialog
        testSourceRedownloadDialog: testSourceRedownloadDialog
        dimReloadTimer: _dimReloadTimer
        ratingsDialog: ratingsDialog
        ratingToast: videoArea.ratingToast
    }

    GlobalShortcuts {
        id: globalShortcuts
        root: root
        multiGroupDialog: multiGroupDialog
        ratingToast: videoArea.ratingToast
    }

    // ─── 参考图侧边栏 ───────────────────────────────────────────────
    // 锚定：左侧贴边、上下与 videoArea 一致；宽度 = refSidebarWidth（折叠时 0）。
    // 折叠态完全不占位，且通过 visible 控制让其内部 binding 不参与求值，零开销。
    RefSidebar {
        id: refSidebar
        root: root
        refSidebarFileDlg: fileDialogs.refSidebarFileDlg
        refSidebarDirDlg: fileDialogs.refSidebarDirDlg
        refSidebarGroupedDlg: fileDialogs.refSidebarGroupedDlg
        refSidebarFileDlg2: fileDialogs.refSidebarFileDlg2
        refSidebarDirDlg2: fileDialogs.refSidebarDirDlg2
        refSidebarGroupedDlg2: fileDialogs.refSidebarGroupedDlg2
        refLightbox: refLightbox
        leftNavBar: leftNavBar
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

    CsvBottomBar {
        id: csvBottomBar
        root: root
        refSidebar: refSidebar
        refSidebarCsvDlg: fileDialogs.refSidebarCsvDlg
        videoArea: videoArea
    }

    // ─── 可拖拽分隔条：竖向（拖动调整左侧参考栏宽度）──────────────────
    // 设计要点：
    //   1) 仅当 refSidebarVisible 为 true 时显示并接收事件，关闭后零占位；
    //   2) 与视频/播放内核完全解耦——只通过 root.refSidebarUserWidth 一个属性
    //      与 refSidebar.width 联动，videoArea 的左边界本来就 anchors 跟随；
    //   3) z:100 抬到视频上方，避免被 GridView 的 cell 抢走鼠标事件；
    //   4) 双击复位到 320 默认宽度。
    RefSidebarHSplitter {
        id: refSidebarHSplitter
        root: root
        refSidebar: refSidebar
        csvBottomBar: csvBottomBar
    }

    // ─── 可拖拽分隔条：横向（拖动调整底部提示词栏高度）─────────────────
    // 仅当 csvBottomBar 处于"展开 + 有内容"状态时显示；折叠或无视频时隐藏。
    CsvBottomVSplitter {
        id: csvBottomVSplitter
        root: root
        csvBottomBar: csvBottomBar
    }

    // ─── 视频网格容器 ────────────────────────────────────────────────────
    // 顶部留 2px 余白，避免与 ToolBar 视觉粘连；同时让 cell 的 2px 选中边
    // 框不被 ToolBar 阴影/分隔线压住。
    VideoArea {
        id: videoArea
        root: root
        shortcutsAboutDialogs: shortcutsAboutDialogs
        addDialog: fileDialogs.addDialog
        refSidebar: refSidebar
        csvBottomBar: csvBottomBar
        multiGroupDialog: multiGroupDialog
        ratingsDialog: ratingsDialog
        leftNavBar: leftNavBar
    }

    // ─── 右侧栏（标题栏按钮控制，暂为占位） ─────────────────────────
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 320
        color: "#141419"
        visible: root.rightSidebarOpen
        z: 200
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: "#26262e"
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
        // 开发者模式：勾选时模式选择菜单显示「测试模式」
        developerMode: root.developerMode

        // ── 评分模式回调注入 ───────────────────────────────────
        // 由 dlg 内部在 reviewMode=true 时调用，决定当前组未评分的通道索引列表。
        // 这里复用主窗 cellRatings + Engine.fileCount，安全且零侵入。
        unratedChecker: function() {
            var miss = []
            var n = Engine.fileCount
            var dims = root.reviewDimensions
            // quality_slide 模式下只检查第一个维度（第二个维度是滑动对比专用）
            if (root.isQualitySlideMode && dims && dims.length >= 2)
                dims = [dims[0]]
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
                    if (RatingLogic.ratingAt(j) <= 0) miss.push(j)
                }
            }
            // 【Checklist 校验】仅当有 checklist 配置时才检查：
            // 每个通道必须至少勾选一项 checklist，否则视为未评分完成。
            // 已经因为维度未打分被加入 miss 的通道无需重复添加。
            var hasChecklist = root.reviewChecklist
                    && typeof root.reviewChecklist.length === "number"
                    && root.reviewChecklist.length > 0
            if (hasChecklist && typeof Rating !== "undefined") {
                for (var k = 0; k < n; ++k) {
                    if (miss.indexOf(k) >= 0) continue  // 已在 miss 里，跳过
                    var fp = ""
                    try { fp = Engine.filePathAt(k) || "" } catch (e) { fp = "" }
                    if (fp.length === 0) { miss.push(k); continue }
                    var raw = Rating.loadString("checklist:" + fp, "")
                    var checkedCount = 0
                    if (raw && raw.length > 0) {
                        try {
                            var arr = JSON.parse(raw)
                            if (arr && typeof arr.length === "number") checkedCount = arr.length
                        } catch (e) { checkedCount = 0 }
                    }
                    if (checkedCount === 0) miss.push(k)
                }
            }
            // quality_slide：仅当 fileCount===2 时滑动对比才有意义；
            // 多于 2 路的场景退化回普通 quality 校验，避免误拦。
            // 【关键修复】滑动检测必须在 hasDims/无维度 两种情况下都生效——
            // quality_slide 模式恰好是 hasDims=true（第一维度"并排"），
            // 之前把这段放在 else 里，导致 quality_slide 永远不检查滑动 L/R，
            // 切下一组时滑动没打也放行。
            if (root.isQualitySlideMode && Engine.fileCount === 2) {
                if (root.slideRatingL <= 0) miss.push(-2)
                if (root.slideRatingR <= 0) miss.push(-3)
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
            try { RatingLogic._writeRating(idx, score, dimKey) } catch (e) {}
        }
        // 获取指定通道当前评分（用于弹窗打开时预填已有评分）
        getCellRating: function(idx) {
            if (idx < 0 || idx >= root.cellRatings.length) return null
            return root.cellRatings[idx]
        }
        // 多维评分模式注入
        isMultiDimMode: root.isMultiDimMode
        reviewDimensions: root.cellReviewDimensions
        reviewDimensionsVersion: root.reviewDimensionsVersion
        dimsByMode: root._dimsByMode
        // quality_slide 模式下第二维度 key，供 allGroupsRated 判断滑动打分是否完整
        slideDimKey: (root.slideDimension && root.slideDimension.key) ? root.slideDimension.key : ""
        // Checklist 配置：非空时 allGroupsRated 会额外校验每个文件是否至少勾选一项
        reviewChecklist: root.reviewChecklist
        // 点击「启动对比」时，先从网络加载当前模式对应的激活配置，完成后再启动
        onDimLoadNeeded: function(mode, callback) {
            var base = Logic._dimApiUrl()
            if (base.length > 0) {
                var url = base + (mode ? ("?mode=" + encodeURIComponent(mode)) : "")
                console.log("[DimLoad] 启动对比触发 → mode:", mode, "url:", url)
                // 传入 mode，让 loadDimensionsFromUrl 走"缓存优先"路径，
                // 并对返回数据做 forMode === currentMode 二重校验，杜绝跨模式污染
                Logic.loadDimensionsFromUrl(url, callback, mode)
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
        // 开发者模式：勾选时模式切换 Tab 显示「测试模式」
        developerMode: root.developerMode
        // 让 RatingsDialog 能区分"哪个 slide_type 属于滑动打分（第二维度）"，
        // 从而正确分到"滑动对比打分"分组。非 quality_slide 模式或维度不足时为 ""。
        slideDimKey: (root.slideDimension && root.slideDimension.key) ? root.slideDimension.key : ""
        // 当前模式的 checklist 配置：用于"文件夹是否评完"判定；空数组时完全不启用。
        reviewChecklist: root.reviewChecklist

        // ── 外部"一键上传"的结果路由 ──
        // 目的：让"评分数据"按钮 → 二次确认 → 直接上传，全程不需要打开评分数据面板。
        //   评分数据面板是独立 Window，其内部 Popup 需要 Window 可见才能显示，
        //   所以 RatingsDialog 把三种上传结果通过 signal 抛出来，由主窗顶层
        //   对话框接手展示。
        onQuickUploadFinished: function(ok, message) {
            if (ok) {
                quickUploadResultDialog.showSuccess(message)
            } else {
                // 一般性失败（服务端 400/500 等）：也用同一个"结果对话框"展示
                quickUploadResultDialog.showFailure(message)
            }
        }
        onQuickUploadConflict: function(message) {
            quickUploadOverwriteDialog.showConflict(message)
        }
        onQuickUploadNetError: function(message) {
            quickUploadResultDialog.showFailure(message)
        }
    }

    // ─── 快速上传二次确认对话框 ────────────────────────────────────
    // 触发点：工具栏「📤 评分数据」按钮（所有评分完成后浮现的入口）。
    // 交互流程：
    //   点按钮 → openWithPreview() → 从 RatingsDialog.previewCurrentUpload()
    //   拉取"当前正在评分"的预览信息（模式、评分人、tag、文件夹清单、评分条数、
    //   有无未评完/校验不通过）→ 用户在本对话框上看到摘要 →
    //     · 点"☁ 确认上传"：调用 ratingsDialog.triggerQuickUploadForCurrentTab()
    //       复用面板内的上传主流程（含 tagMismatch / uploadConfig / uploadSuccess 弹窗）；
    //     · 点"✏️ 去修改"：仍打开完整的评分数据面板供用户手动调整。
    // 设计动机：让"评分完 → 一键上传"路径减少一次多余的面板打开操作，
    //   同时保留人工核对/修改的机会（防止误上传半成品或误 tag）。
    QuickUploadConfirmDialog {
        id: quickUploadConfirmDialog
        root: root
        ratingsDialog: ratingsDialog
    }

    // ─── 快速上传·结果反馈对话框（成功 / 失败共用一个） ─────────────
    // 作为"外部一键上传"（不打开评分数据面板）时的顶层反馈对话框：
    //   · 上传成功：绿色标题、"✅ 上传成功" + 附带模式/评分人/tag/文件夹列表
    //   · 上传失败：红色标题、"❌ 上传失败" + 服务端错误信息
    // 之所以放在主窗顶层：评分数据面板是独立 Window，未打开时其内部 Popup
    // 弹不出来；放主窗层次能保证任何时刻都能显示。
    QuickUploadResultDialog {
        id: quickUploadResultDialog
        root: root
        quickUploadConfirmDialog: quickUploadConfirmDialog
    }

    // ─── 快速上传·覆盖确认对话框 ────────────────────────────────
    // 服务端返回 409（同 rater+tag 已存在同名上传）时，让用户确认是否覆盖。
    // 确认 → 调 Rating.uploadToCloud(true, folderPaths) 携带 force=1 重发；
    // 取消 → 什么都不做，用户可以自己去改 tag 后再点上传。
    QuickUploadOverwriteDialog {
        id: quickUploadOverwriteDialog
        root: root
        ratingsDialog: ratingsDialog
    }

    // 全局进度条已移除：多路场景下各路独立播放控制，全局进度条语义
    // 不明。进度跳转请使用各路 cell 悬浮工具条上的单路进度条。

    // ─── 参考图放大查看 Lightbox（拆分至 RefLightbox.qml） ──────────
    RefLightbox {
        id: refLightbox
        anchors.fill: parent
        refCurrentUrl: root.refCurrentUrl
        refCurrentUrl2: root.refCurrentUrl2
        refHasCurrent: root.refHasCurrent
        refHasCurrent2: root.refHasCurrent2
        refImageCount: root.refImageCount
        refImageCount2: root.refImageCount2
        refCurrentImageIndex: root.refCurrentImageIndex
        refCurrentImageIndex2: root.refCurrentImageIndex2
        refCanNav: root.refCanNav
        refCanNav2: root.refCanNav2
        onRefImgOffsetChanged: root._refImgOffset = refImgOffset
        onRefImgOffset2Changed: root._refImgOffset2 = refImgOffset2
    }

    // ── YUV 分析视图（拆分至 YuvSetupView.qml） ──────────────────────
    YuvSetupView {
        id: yuvView
        // render 阶段铺满 contentItem（沉浸满屏），setup 阶段让出左侧导航栏
        anchors.left: (YuvBridge.slotCount > 0) ? parent.left : leftNavBar.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        visible: root.currentTab === "yuv"
    }

    // ══════════════ 左侧主导航栏 ══════════════
    // 常驻最左，纵向排列 4 个功能 Tab：首页 / 播放 / YUV 分析 / 码流分析。
    // 设置入口保留在顶栏菜单（settingsTopMenu），不占用导航位。
    // 内容区（videoArea/refSidebar/homeView/yuvView/streamView）均通过
    // anchors 避开本栏；本栏 z 高于内容区，确保永不遮挡。
    LeftNavBar {
        id: leftNavBar
        root: root
    }

    

    // ══════════════ 首页 + 码流分析视图（拆分至 HomeView.qml） ══════════════
    HomeView {
        id: homeStreamView
        anchors.left: leftNavBar.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        visible: root.currentTab === "home" || root.currentTab === "stream"
        currentTab: root.currentTab
        onSwitchTab: function(tab) { root.currentTab = tab }
        onRequestOpenFile: fileDialogs.addDialog.open()
        onRequestMultiGroup: multiGroupDialog.showAndRefresh()
    }
}
