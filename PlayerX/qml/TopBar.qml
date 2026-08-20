import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0
import "MainLogic.js" as Logic

ToolBar {
    id: topBar
    property var root: null
    property var updateDialog: null
    property var confirmCloseAllDialog: null
    property var multiGroupDialog: null
    property var quickUploadConfirmDialog: null
    property var updateToast: null
    property var testSourceDownloadDialog: null
    property var testSourceGroupDialog: null
    property var testSourceRedownloadDialog: null
    property var dimReloadTimer: null
    property var ratingsDialog: null
    property var ratingToast: null

    // 【铃铛失效根因修复】MainLogic.js 没有加 `.pragma library`，按 QML 规范，
    // 每个 import 它的 QML 文件都会拿到一份独立的模块状态副本（各自的 _root /
    // _initialized 等模块级变量）。Main.qml 的 Component.onCompleted 只调用了
    // Logic._init()，初始化的是 Main.qml 自己 import 进来的那一份；TopBar.qml
    // 这里 `import "MainLogic.js" as Logic` 是另一份完全独立的状态，从未被
    // _init 过，因此 _root 一直是兜底的空对象 {}，_checkRemoteConfigUpdate()
    // 一进来判断 _root 未初始化就直接 return —— 这才是铃铛点击无效的真正原因
    // （与 Windows/macOS 时序无关，只是两平台运行方式差异导致误判为平台问题）。
    // 这里对 TopBar 自己这份 Logic 副本也做一次同样的初始化即可修复。
    Component.onCompleted: {
        Logic._init({
            root: root,
            updateToast: updateToast,
            testSourceDownloadDialog: testSourceDownloadDialog,
            testSourceGroupDialog: testSourceGroupDialog,
            testSourceRedownloadDialog: testSourceRedownloadDialog,
            multiGroupDialog: multiGroupDialog,
            dimReloadTimer: dimReloadTimer,
            ratingsDialog: ratingsDialog,
            ratingToast: ratingToast
        })
        console.log("[TaskUpdate] TopBar 自身的 MainLogic.js 模块副本已初始化，铃铛应可正常工作")
    }

    height: 44
    // 底部工具栏属于「播放」tab：切换到首页/YUV/码流分析时整条隐藏。
    visible: root.currentTab === "play"
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

        // ── 任务更新常驻入口按钮（🔔）紧贴 📱 按钮左侧 ──────────
        Button {
            id: taskUpdateEntryBtn
            // 始终常驻显示
            visible: true
            Layout.preferredWidth: 32
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            hoverEnabled: true

            // 有待更新：切换面板；无待更新：主动抓取一次并打开卡片展示全部配置
            property bool _checking: false

            onPressed: console.log("[TaskUpdate] 铃铛按钮按下（输入事件已到达按钮）")

            onClicked: {
                // 卡片已展开 → 再次点击直接收起（无论有无更新）
                if (root._taskUpdateVisible) {
                    root._taskUpdateVisible = false
                    return
                }
                // 卡片未展开 → 展开：有更新直接开；无更新则主动检测并打开卡片。
                // hasPending 需按可见性过滤：pending 可能全是测试模式，
                // 未开开发者模式时直接开卡片会是一张空卡片。
                var hasPending = Array.isArray(root._pendingRemoteConfig)
                    && root._pendingRemoteConfig.some(function(it) { return root.developerMode || it.mode !== "test" })
                if (hasPending) {
                    root._taskUpdateVisible = true
                } else {
                    if (_checking) return
                    _checking = true
                    Logic._checkRemoteConfigUpdate(function() {
                        taskUpdateEntryBtn._checking = false
                    }, true)  // openCardOnNoUpdate=true：无更新也打开卡片展示全部配置 + 应用按钮
                    Qt.callLater(function() { taskUpdateEntryBtn._checking = false })
                }
            }

            ToolTip.visible: hovered
            ToolTip.delay: 400
            ToolTip.text: {
                var _pend = Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig : []
                // 计数同样过滤「测试模式」（开发者模式未开启时对普通用户不可见）
                var cnt = root.developerMode ? _pend.length
                                             : _pend.filter(function(it) { return it.mode !== "test" }).length
                return cnt > 0 ? "远程有 " + cnt + " 个任务更新（点击查看）" : "点击检测远程任务更新"
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
                // 与 ToolTip / 卡片显示一致：开发者模式未开启时，测试模式任务
                // 不计入角标数字（不显示、不提醒），让普通用户不被打扰。
                Rectangle {
                    visible: {
                        var _pend = Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig : []
                        var _cnt = root.developerMode ? _pend.length
                                                      : _pend.filter(function(it) { return it.mode !== "test" }).length
                        return _cnt > 0
                    }
                    x: bellIcon.x + bellIcon.width - 4
                    y: bellIcon.y - 3
                    width: 13
                    height: 13
                    radius: 7
                    color: "#e05050"
                    Text {
                        anchors.centerIn: parent
                        text: {
                            var _pend = Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig : []
                            return root.developerMode ? _pend.length
                                                      : _pend.filter(function(it) { return it.mode !== "test" }).length
                        }
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
                                    onTriggered: Logic._stepPhoneScale(phoneScaleStepper._holdDelta)
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
                                            Logic._stepPhoneScale(+0.01)
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
                                            Logic._stepPhoneScale(-0.01)
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
                                    Logic._applyAutoPhoneScale()
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

        // ── 评分完成快捷入口（放在"评分规则"左侧）────────────────────────────
        // 设计动机：
        //   · 评分数据入口和评分规则一样，属于「评分域」按钮，不属于播放器通用控件，
        //     所以整体挪到分隔线左侧非播放器区，和"评分规则"并列，语义分组清晰。
        //   · 可见性沿用旧规则：仅在评分模式下 + 多组已启动 + 所有组评分完成时浮现，
        //     其余情况占位宽度归 0，不干扰其他按钮布局。
        //   · 保留原有的淡入淡出动画（opacity 过渡），避免评分刚完就突然多出一个按钮。
        FlatButton {
            id: allRatedShortcutBtn
            text: "📤 上传数据"
            visible: root.reviewMode && multiGroupDialog.active && multiGroupDialog.allGroupsRated
            Layout.preferredWidth: visible ? implicitWidth : 0
            Layout.alignment: Qt.AlignVCenter
            font.pixelSize: 12
            textColor: "#4fc3f7"
            ToolTip.visible: hovered
            ToolTip.delay: 400
            ToolTip.text: qsTr("所有评分已完成，点击直接上传当前评分数据")
            onClicked: {
                console.log("[QuickUpload] allRatedShortcutBtn clicked")
                quickUploadConfirmDialog.openWithPreview()
            }

            Behavior on opacity { NumberAnimation { duration: 300 } }
            opacity: visible ? 1.0 : 0.0
        }
        // ── 评分规则按钮（放在"第一根分隔线"左侧）────────────────────────────
        // 设计动机：
        //   · 评分规则属于「评分域」入口，语义上不属于播放器通用控件；
        //     所以放在分隔线【左侧】的"非播放器控件区"，与右侧的 1x/<<>>/多组切换分开。
        //   · 与 MultiGroupDialog 顶部的"查看规则 ↗"按钮完全同源：点击后
        //     Qt.openUrlExternally 到后端 /#tasks/<configName>。
        //   · 可见性双重守卫：仅当有视频（fileCount>0）且当前 mode 已绑定后端配置
        //     （_rulesPageUrl 非空）时才显示；否则宽度 0 不留空白。
        //   · 样式沿用 MultiGroupDialog viewRulesBtn 的深蓝底+浅蓝字方案，
        //     视觉上与"多维评分"那一套呼应，用户能一眼认出这是评分域按钮。
        Button {
            id: viewRulesToolbarBtn
            visible: Engine.fileCount > 0 && Logic._rulesPageUrl().length > 0
            Layout.preferredWidth: visible ? implicitWidth : 0
            Layout.preferredHeight: 22
            Layout.alignment: Qt.AlignVCenter
            hoverEnabled: true
            padding: 0
            leftPadding: 9
            rightPadding: 9
            onClicked: {
                var url = Logic._rulesPageUrl()
                if (url.length > 0) Qt.openUrlExternally(url)
            }
            ToolTip.visible: hovered
            ToolTip.delay: 400
            ToolTip.text: {
                // 解析当前模式的展示名（label）：优先用 Rating.modeList 里的 label，
                // 拿不到时兜底展示 mode id，避免出现空白。
                var modeId = (typeof Rating !== "undefined") ? Rating.currentMode : ""
                var modeLabel = modeId
                var ml = (typeof Rating !== "undefined") ? (Rating.modeList || []) : []
                for (var i = 0; i < ml.length; ++i) {
                    if (ml[i].id === modeId) { modeLabel = ml[i].label || modeId; break }
                }
                var cfg = Logic._boundConfigName()
                if (Logic._rulesPageUrl().length === 0) {
                    // 兜底：当前模式尚未绑定评测类型（按钮此时其实是隐藏的，这里仅为鲁棒）
                    return qsTr("当前模式「%1」未绑定评分规则").arg(modeLabel || qsTr("未选择"))
                }
                // ── 富文本着色：标签灰、值按语义分色，末行提示再弱一档 ──
                // （全局 ToolTip 已在启动时开启 RichText；动态值先转义防 HTML 注入）
                function esc(s) {
                    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                }
                var C_LABEL = "#9aa0a6"   // 标签：灰
                var C_MODE  = "#7ab8f5"   // 当前模式：蓝（与按钮主色呼应）
                var C_CFG   = "#4ef0c0"   // 评测类型：薄荷绿
                var C_TAG   = "#ffc069"   // 备注 tag：暖橙
                var C_HINT  = "#6f6f7c"   // 末行提示：弱灰
                var vMode = esc(modeLabel || qsTr("未选择"))
                var vCfg  = esc(cfg || qsTr("未绑定"))
                var lines = [
                    "<font color=\"" + C_LABEL + "\">当前模式：</font><font color=\"" + C_MODE + "\">" + vMode + "</font>",
                    "<font color=\"" + C_LABEL + "\">评测类型：</font><font color=\"" + C_CFG + "\">" + vCfg + "</font>"
                ]
                var tag = root._remoteTag
                if (tag.length > 0) {
                    lines.push("<font color=\"" + C_LABEL + "\">备注 tag：</font><font color=\"" + C_TAG + "\">" + esc(tag) + "</font>")
                }
                lines.push("<font color=\"" + C_HINT + "\">点击查看完整评分规则</font>")
                return lines.join("\n")
            }
            background: Rectangle {
                radius: 11
                color: viewRulesToolbarBtn.down     ? "#0a4a8a"
                     : viewRulesToolbarBtn.hovered  ? "#1a5faa"
                                                    : "#152a4a"
                border.color: "#2a6abf"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
            }
            contentItem: Text {
                text: "📋 评分规则 ↗"
                color: "#7ab8f5"
                font.pixelSize: 11
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        // 第一根分隔线：把"打开"与"播放控制组"隔开（仅有视频时存在）
        Rectangle {
            width: 1
            Layout.fillHeight: true
            color: "#2a2a30"
            Layout.topMargin: 6
            Layout.bottomMargin: 6
            visible: Engine.fileCount > 0
        }
        // ── 常驻"播放速度"按钮（放在 << 快退左侧）─────────────────────────
        // 设计要点：
        //  1) 与顶部菜单栏【设置】▸【播放速度】语义完全一致，底层都调
        //     Engine.setSpeed / adjustSpeed / resetSpeed，快捷键 - / = / 0
        //     不受影响；这里只是把功能做成常驻可点入口。同时它已经替代了
        //     早期只在非 1.0x 时才出现的右侧 speedBadge 胶囊（已移除，避免重复）。
        //  2) 遵循项目 UI 铁律：macOS 上 QtQuick.Controls 的 Menu 会被替换为 native
        //     NSMenu，自定义 background/delegate 全部失效，会漏出系统白底黑字。
        //     所以【必须】用 Popup + Repeater 自绘。此处深色主题与 phoneAspectPopup、
        //     全局 ToolTip 完全对齐（#cc1a1a1f / #33ffffff / #e8e8ec）。
        //  3) 按钮文案实时显示当前倍速（例 "1.00x" / "1.5x"），非 1.0x 时用高亮色
        //     提醒用户，一眼就能识别当前是否处于非常规速率。
        FlatButton {
            id: speedToolbarBtn
            visible: Engine.fileCount > 0
            Layout.preferredWidth: visible ? implicitWidth : 0
            enabled: Engine.fileCount > 0
            // 记录 speedPopup 上一次关闭的时间戳（ms）。用于吃掉"点外面关掉→onClicked 又打开"
            // 的两连击：外部点击关闭 popup 时 CloseOnPressOutsideParent 先触发，
            // Qt 随后仍会把该次 press 派发给下方按钮的 onClicked。若不做闸门，会立即再次
            // 打开，用户视觉上表现为"点 1x 关不掉菜单"。
            // 参考做法与 settingsBtn._menuClosedAtMs 完全一致。
            property double _menuClosedAtMs: 0
            // 展示当前倍速：与已移除的 speedBadgeLabel 采用同一格式化规则，保持观感稳定
            text: {
                var s = Engine.speed
                if (s >= 1.0)
                    return s.toFixed(s >= 10 ? 0 : 2).replace(/\.?0+$/,"") + "x"
                return s.toFixed(2).replace(/0+$/,"").replace(/\.$/,"") + "x"
            }
            // 非 1.0x 时高亮，视觉与右侧胶囊呼应
            textColor: (Math.abs(Engine.speed - 1.0) < 1e-6) ? "#e8e8ec" : "#00c0a0"
            onClicked: {
                // 若 popup 处于打开状态，直接收起（toggle 语义）。
                if (speedPopup.visible) { speedPopup.close(); return }
                // 若刚刚（<250ms）因外部点击关闭过，则这次点击其实是"关闭态"的收尾，
                // 吃掉它，避免立刻二次打开。
                if (Date.now() - _menuClosedAtMs < 250) return
                speedPopup.openAt(speedToolbarBtn)
            }
            ToolTip.visible: hovered
            ToolTip.delay: 400
            ToolTip.text: qsTr("播放速度（点击选择档位；快捷键 - / = / 0）")
        }
        // 播放速度下拉：自绘深色 Popup，主题对齐全局 ToolTip / phoneAspectPopup
        Popup {
            id: speedPopup
            // 尺寸由内容决定，避免超长文案被裁；含分隔线共 9 项
            implicitWidth: 190
            implicitHeight: speedListCol.implicitHeight + 12
            padding: 6
            modal: false
            focus: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

            // 关闭时打时间戳，供 speedToolbarBtn.onClicked 判断"是否刚被外部点击关闭"，
            // 从而吃掉紧随其后的按钮点击，避免立即再次打开（=> 支持"再点一次收起"）。
            onClosed: {
                if (speedToolbarBtn)
                    speedToolbarBtn._menuClosedAtMs = Date.now()
            }

            // 定位在锚点按钮的正上方（弹层与按钮的间隙 2px，符合项目 UI 铁律）
            function openAt(anchorBtn) {
                var p = anchorBtn.mapToItem(parent, 0, 0)
                x = p.x
                y = p.y - implicitHeight - 2
                open()
            }

            background: Rectangle {
                color: "#cc1a1a1f"
                border.color: "#33ffffff"
                border.width: 1
                radius: 6
            }

            // 用 Column + Repeater 自绘，杜绝任何 native 化风险
            contentItem: Column {
                id: speedListCol
                spacing: 0

                // 常用档位区
                Repeater {
                    model: [0.25, 0.5, 1.0, 1.5, 2.0]
                    delegate: Rectangle {
                        required property real modelData
                        readonly property bool isCurrent: Math.abs(Engine.speed - modelData) < 1e-3
                        width: parent.width
                        height: 28
                        radius: 4
                        color: rowHover.hovered ? "#0a64f0" : "transparent"
                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 6
                            Text {
                                width: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: isCurrent ? "✓" : ""
                                color: "#e8e8ec"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: {
                                    var v = modelData
                                    if (Math.abs(v - 1.0) < 1e-6) return "1.0x （正常）"
                                    return (v < 1.0
                                            ? v.toFixed(2).replace(/0+$/,"").replace(/\.$/,"")
                                            : v.toFixed(v >= 10 ? 0 : 1).replace(/\.0$/,"")) + "x"
                                }
                                color: "#e8e8ec"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                Engine.setSpeed(modelData)
                                speedPopup.close()
                            }
                        }
                    }
                }

                // 分隔线（1px，白 20% α，与项目其它弹层一致）
                Rectangle {
                    width: parent.width
                    height: 1
                    color: "#33ffffff"
                }

                // 步进/重置区：语义与快捷键 - = 0 完全等价
                Repeater {
                    model: [
                        { label: "减速 ( - )",         act: "dec"   },
                        { label: "加速 ( = )",         act: "inc"   },
                        { label: "重置为 1.0x ( 0 )",  act: "reset" }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        width: parent.width
                        height: 28
                        radius: 4
                        color: stepHover.hovered ? "#0a64f0" : "transparent"
                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 6
                            Text {
                                width: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: ""
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                color: "#e8e8ec"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                        HoverHandler { id: stepHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                var a = modelData.act
                                if (a === "dec")        Engine.adjustSpeed(-1)
                                else if (a === "inc")   Engine.adjustSpeed(+1)
                                else if (a === "reset") Engine.resetSpeed()
                                speedPopup.close()
                            }
                        }
                    }
                }
            }
        }
        // 快退 5 秒
        FlatButton {
            text: "<<"
            visible: Engine.fileCount > 0
            Layout.preferredWidth: visible ? implicitWidth : 0
            enabled: Engine.duration > 0
            // 相对快退：每路在自己当前位置 -5s，独立时钟的路不被对齐到主时钟
            // 首帧短路：不改变按钮外观，用户连点也不会触发无效 seek，避免解码器空跑卡顿
            onClicked: {
                if (Logic._isAtFirstFrameNow()) return
                Engine.seekRelative(-5)
            }
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
            // 首帧短路：外观保持一致，但阻止内核在 pts=0 附近反复尝试回退造成卡顿
            onClicked: {
                if (Logic._isAtFirstFrameNow()) return
                Engine.stepFrame(-1)
            }
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
            // 末帧短路（核心场景）：不改变按钮视觉，仅阻断点击流水线——避免
            // 用户在最后一帧继续点"下一帧"让解码器被反复驱动去请求超出末端
            // 的帧，累积后出现明显卡顿。
            onClicked: {
                if (Logic._isAtLastFrameNow()) return
                Engine.stepFrame(1)
            }
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
            // 末帧短路：外观保持一致，用户连点也不会触发无效 seek
            onClicked: {
                if (Logic._isAtLastFrameNow()) return
                Engine.seekRelative(5)
            }
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
            onClicked: RatingLogic._toggleCompareSlider()
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

        // ── 关闭全部视频（一次性清空所有路）──
        // 设计：
        //   · 只在 fileCount > 0 时显示，与单路 ✕ 一致；
        //   · 文案 "✕ 返回" 用红色调色，悬停加深，与单路关闭按钮的语义/视觉对齐；
        //   · 点击先弹深色二次确认弹窗，避免误触一次性丢失全部正在比较的视频；
        //   · 也可通过【文件】▸ 关闭所有视频 / ⌘W 触发。
        FlatButton {
            id: closeAllBtn
            text: "✕ 返回"
            visible: Engine.fileCount > 0
            Layout.preferredWidth: visible ? implicitWidth : 0
            font.pixelSize: 12
            textColor: "#e07070"
            ToolTip.visible: hovered
            ToolTip.delay: 600
            ToolTip.text: qsTr("关闭所有视频（⌘W / Ctrl+W）")
            onClicked: confirmCloseAllDialog.open()
        }

        // 说明：早期这里有一个"当前倍速胶囊 speedBadge"（仅非 1.0x 时显示、点击复位）。
        // 现已被工具栏左侧常驻的 speedToolbarBtn 完全替代——后者始终显示当前倍速，
        // 且提供档位下拉，语义/交互更完整。为避免右下重复展示同一信息，此处移除。


    }
}
