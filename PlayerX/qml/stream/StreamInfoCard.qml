// StreamInfoCard.qml — 码流分析右侧统计卡片
//
// 风格对齐 YuvStatsPanel.qml / YuvWindow 主题（背景 #121417 / 边框 #2a2e33）。
//
// 布局双模式（2026-09-16）：
//   · floating = false（默认）→ 腾位栏：填满 Main.qml 的 rightSidebarLoader
//     （320px，画面整体左移让位），左侧 1px 分隔线，实底 #121417。
//   · floating = true → 悬浮卡：固定宽 304，右侧/顶部 12px 边距，圆角 8，
//     半透明底 #f0121417 + 边框 #2a2e33，浮在播放画面上层。
//   两种模式内容与数据源完全一致，由内部 Loader 复用同一份内容组件。
//
// 内容结构（2026-09-16 二次改造：一分为二 + Tab 化）：
//   · 上半区：Tab 切换「文件 / 帧 / 统计」三个面板（面板名缩短）。
//     码率曲线已迁至 StreamView 底部 StreamBitrateChart.qml（GOP 栏「码率」
//     按钮向上展开，悬浮/挤占双模式），右侧栏不再受宽度限制。
//   · 下半区：语法元素（VPS / SPS / PPS）固定占约 45% 高度，独立滚动。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: cardRoot

    // 外部属性：当前选中的 slot（从 main.qml 透传，1:1 跟随 StreamView）
    property int slot: 0
    property int ver: 0
    // 布局模式开关：true=悬浮卡（浮在画面上层）；false=腾位栏（画面左移让位）
    property bool floating: false
    // 模式切换：通知外层（Main.qml onFloatingChanged 处理画面让位）
    function toggleFloating() { cardRoot.floating = !cardRoot.floating }

    // ── 腾位模式容器：撑满父容器，实底 + 左侧分隔线 ──
    Rectangle {
        visible: !cardRoot.floating
        anchors.fill: parent
        color: "#121417"

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: "#2a2e33"
        }

        Loader {
            anchors.fill: parent
            active: !cardRoot.floating
            sourceComponent: cardContentComp
        }
    }

    // ── 悬浮模式容器：固定宽 304，圆角半透明，右侧/顶部 12px 边距 ──
    Rectangle {
        visible: cardRoot.floating
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.top: parent.top
        anchors.topMargin: 12
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 12
        width: 304
        radius: 8
        color: "#f0121417"
        border.color: "#2a2e33"; border.width: 1

        Loader {
            anchors.fill: parent
            active: cardRoot.floating
            sourceComponent: cardContentComp
        }
    }

    // ── 内容组件（两种布局模式共用）：一分为二 + Tab 化布局 ──────────
    //   · 上半区：Tab 切换「文件 / 帧 / 统计 / 码率」四个面板
    //     （面板名从"文件信息/帧信息/码流统计（当前帧）/码率曲线"缩短）。
    //   · 下半区：语法元素（VPS / SPS / PPS）固定占约 45% 高度，独立滚动。
    //   · 码率曲线为整文件静态采样（≤200 桶）；播放时叠加当前帧指示线
    //     与实时码率读数，因此随播放可见变化。
    Component {
        id: cardContentComp
        Item {
            id: panel
            required property int slot
            property int ver: 0
            property int syntaxVer: 0
            // 上半区选中 Tab：0 文件 / 1 帧 / 2 统计（码率曲线已迁至底部面板）
            property int mainTab: 0
            // 下半区参数集 Tab 下标（对应 syntaxGroups.order）
            property int syntaxTab: 0
            // 语法元素搜索文本（大小写不敏感，name/value 任一命中即保留）
            property string syntaxFilter: ""
            slot: cardRoot.slot

            // ── 剪贴板辅助（隐藏 TextEdit + 一次性写入方法）────────────
            // Qt Quick 需要一个真实的 TextEdit 承载 selectAll()/copy()，
            // 见 YuvWindow.qml 的 copyMatrixToClipboard 同款套路。
            TextEdit {
                id: clipHelper
                visible: false
                width: 0; height: 0
            }
            function copyToClipboard(text) {
                if (text === undefined || text === null) text = ""
                clipHelper.text = String(text)
                clipHelper.selectAll()
                clipHelper.copy()
                clipHelper.deselect()
                clipHelper.text = ""
            }

            // 参数集组数变化（换文件 / 重新解析）后 Tab 复位到第一个
            onSyntaxVerChanged: {
                if (panel.syntaxTab >= panel.syntaxGroups.order.length)
                    panel.syntaxTab = 0
            }

            // ── 数据刷新信号（ver / syntaxVer 强制重算机制）──
            // 2026-09-16 性能修复：信号分级，避免 265 播放时每帧全量重拷 frameList：
            //   · ver（帧级）：仅游标/当前帧项刷新，轻量
            //   · structVer（文件级）：frameList / gopList / 码率采样重取
            // 后端 currentFrameChanged 携带的 slot 号可能与 UI 时序对不上，
            // 故帧级信号不做 slot 过滤（防漏刷），文件级信号按 slot 过滤。
            property int structVer: 0
            Connections {
                target: StreamBridge
                function onCurrentFrameChanged(changedSlot) { panel.ver++ }
                function onFileOpened(openedSlot) {
                    if (openedSlot === panel.slot) { panel.ver++; panel.structVer++ }
                }
                function onFileClosed(closedSlot) {
                    if (closedSlot === panel.slot) { panel.ver++; panel.structVer++ }
                }
                function onSlotCountChanged() { panel.ver++; panel.structVer++ }
            }
            // 帧结构缓存（文件级）：播放中每帧不再重拷 frameList（265 大列表拷贝是
            // 播放卡顿主因之一）。仅在文件打开/关闭/槽位变化时重取。
            property var frameCache: []
            property var gopCache: []
            onStructVerChanged: {
                frameCache = panel.slotActive ? StreamBridge.frameList(panel.slot) : []
                gopCache   = panel.slotActive ? StreamBridge.gopList(panel.slot) : []
            }
            // 初始化兜底：structVer 初始为 0 不触发 handler；面板创建时若文件
            // 已打开（悬浮/腾位切换重建 Loader），主动重取一次。
            Component.onCompleted: {
                if (StreamBridge.hasFile(panel.slot)) {
                    frameCache = StreamBridge.frameList(panel.slot)
                    gopCache   = StreamBridge.gopList(panel.slot)
                }
            }
            Connections {
                target: StreamBridge
                function onSyntaxReadyChanged(readySlot) {
                    if (readySlot === panel.slot) panel.syntaxVer++
                }
                function onFileOpened(openedSlot) {
                    if (openedSlot === panel.slot) panel.syntaxVer++
                }
                function onFileClosed(closedSlot) {
                    if (closedSlot === panel.slot) panel.syntaxVer++
                }
            }

            // ── 数据属性 ──
            // frameList/gopList 为文件级缓存（structVer 变化时重取），播放每帧不重拷
            readonly property bool   slotActive:    { const _ = ver; return StreamBridge.hasFile(slot) }
            readonly property var    info:          { const _ = ver; return slotActive ? StreamBridge.streamInfo(slot) : ({}) }
            readonly property int    curFrame:      { const _ = ver; return slotActive ? StreamBridge.currentFrame(slot) : 0 }
            readonly property var    frameList:     frameCache
            readonly property var    currentFrameItem: {
                const _ = ver
                return (slotActive && curFrame >= 0 && curFrame < frameCache.length)
                       ? frameCache[curFrame] : null
            }
            readonly property var    hrd:           { const _ = ver; return slotActive ? StreamBridge.hrdEstimate(slot) : ({}) }
            readonly property var    gopList:       gopCache
            readonly property var    blockStats:    { const _ = ver; return slotActive ? StreamBridge.blockStats(slot, curFrame) : ({ valid: false }) }
            readonly property bool   syntaxReady:    { const _ = syntaxVer; return StreamBridge.hasFile(slot) && StreamBridge.syntaxReady(slot) }
            readonly property var    syntaxEntries:  { const _ = syntaxVer; return StreamBridge.hasFile(slot) ? StreamBridge.syntaxEntries(slot) : [] }
            readonly property var    syntaxGroups: {
                const _ = syntaxVer
                const groups = {}
                const order = []
                const arr = syntaxEntries
                for (let i = 0; i < arr.length; ++i) {
                    const set = String(arr[i].set || "OTHER")
                    if (!groups[set]) { groups[set] = []; order.push(set) }
                    groups[set].push(arr[i])
                }
                return { map: groups, order: order }
            }
            // 整文件平均码率（Mbps）：容器报的 bitrate 为 0（裸 ES 流无容器头）时，
            // 按 frameCache 帧大小总和 / fps 自算。仅依赖 structVer（文件级），
            // 播放中每帧不重算（265 大列表求和是卡顿源之一）。
            readonly property real fileBitrateMbps: {
                const _ = panel.structVer
                const br = Number(panel.info.bitrate)
                if (br > 0) return br / 1e6
                if (!panel.slotActive || !panel.frameCache || panel.frameCache.length === 0) return 0
                let totalBytes = 0
                const n = panel.frameCache.length
                for (let i = 0; i < n; ++i)
                    totalBytes += Number(panel.frameCache[i].sizeBytes)
                const fps = Number(panel.info.fps) > 0 ? Number(panel.info.fps) : 30
                const durSec = n / fps
                return durSec > 0 ? (totalBytes * 8.0 / durSec / 1e6) : 0
            }
            // 当前帧瞬时码率（Mbps）：与底部码率曲线头部读数完全同口径——
            // 当前帧所在采样桶（≤200 桶）的平均码率，随播放帧变化。
            // 依赖 frameCache（文件级）+ curFrame（帧级），播放中只算一个桶。
            readonly property real curFrameBitrateMbps: {
                const _ = panel.ver
                if (!panel.slotActive || !panel.frameCache || panel.frameCache.length === 0) return 0
                const n = panel.frameCache.length
                const bucket = Math.max(1, Math.floor(n / 200))
                let sumBytes = 0, cnt = 0
                for (let j = panel.curFrame; j < Math.min(panel.curFrame + bucket, n); ++j) {
                    sumBytes += Number(panel.frameCache[j].sizeBytes)
                    ++cnt
                }
                const fps = Number(panel.info.fps) > 0 ? Number(panel.info.fps) : 30
                const sec = cnt / fps
                return sec > 0 ? (sumBytes * 8.0 / sec / 1e6) : 0
            }
            // ── 文本面板行数据（原三个 Section 的 rows 原样迁移）──
            readonly property var fileInfoRows: {
                const _ = panel.ver
                if (!panel.slotActive) {
                    return [
                        { label: "分辨率",        value: "—" },
                        { label: "帧率",          value: "—" },
                        { label: "编码格式",      value: "—" },
                        { label: "Profile / Level", value: "—" },
                        { label: "码率",          value: "—" },
                        { label: "总帧数 / GOP",  value: "—" },
                        { label: "时长",          value: "—" },
                        { label: "文件名",        value: "—" }
                    ]
                }
                const inf = panel.info
                const w = Number(inf.width), h = Number(inf.height)
                const dur = Number(inf.duration)
                let durText = "—"
                if (dur > 0) {
                    const mm = Math.floor(dur / 60)
                    const ss = Math.floor(dur % 60)
                    const ms = Math.floor((dur % 1) * 1000)
                    durText = (mm < 10 ? "0" : "") + mm + ":"
                            + (ss < 10 ? "0" : "") + ss + "."
                            + (ms < 100 ? (ms < 10 ? "00" : "0") : "") + ms
                }
                return [
                    { label: "分辨率",        value: (w > 0 && h > 0) ? (w + " × " + h) : "未知" },
                    { label: "帧率",          value: Number(inf.fps).toFixed(2) + " fps" },
                    { label: "编码格式",      value: String(inf.codecLong || "—") },
                    { label: "Profile / Level", value: String(inf.profile) + " | Level " + String(inf.level) },
 { label: "平均码率",      value: panel.fileBitrateMbps.toFixed(2) + " Mbps" },
                    { label: "总帧数 / GOP",  value: String(panel.frameList.length) + " · " + String(panel.gopList.length) },
                    { label: "时长",          value: durText },
                    { label: "文件名",        value: String(inf.fileName || "—") }
                ]
            }
            readonly property var frameInfoRows: {
                const _ = panel.ver
                return panel.slotActive && panel.currentFrameItem
                    ? [
                        { label: "帧号 / POC",      value: String(panel.curFrame + 1) + " / " + String(panel.currentFrameItem.poc) },
                        { label: "帧类型",          value: String(panel.currentFrameItem.type) },
                        { label: "参考帧",          value: panel.curFrame === 0 ? "1" : "1" },
                        { label: "显示顺序",        value: String(panel.curFrame + 1) },
                        { label: "解码顺序",        value: String(panel.curFrame + 1) },
                        { label: "时间戳",
                          value: (Number(panel.currentFrameItem.pts)).toFixed(3) }
                      ]
                    : [
                        { label: "帧号 / POC",  value: "—" },
                        { label: "帧类型",      value: "—" },
                        { label: "参考帧",      value: "—" },
                        { label: "显示顺序",    value: "—" },
                        { label: "解码顺序",    value: "—" },
                        { label: "时间戳",      value: "—" }
                      ]
            }
            readonly property var streamStatsRows: {
                const _ = panel.ver
                return panel.slotActive && panel.currentFrameItem
                    ? [
                        { label: "帧大小",   value: (Number(panel.currentFrameItem.sizeBytes) / 1024).toFixed(1) + " KB" },
                        { label: "码率",     value: panel.curFrameBitrateMbps.toFixed(2) + " Mbps" },
                        { label: "QP 均值",  value: panel.blockStats.valid
                                                 ? Number(panel.blockStats.avgQp).toFixed(1) : "—" },
                        { label: "QP 最小 / 最大", value: panel.blockStats.valid
                                                 ? (panel.blockStats.minQp + " / " + panel.blockStats.maxQp) : "— / —" },
                        { label: "CU 总数",  value: panel.blockStats.valid
                                                 ? String(panel.blockStats.blockCount) : "—" },
                        { label: "跳过 CU 占比", value: "—" }
                      ]
                    : [
                        { label: "帧大小",   value: "—" },
                        { label: "码率",     value: "—" },
                        { label: "QP 均值",  value: "—" },
                        { label: "QP 最小 / 最大", value: "—" },
                        { label: "CU 总数",  value: "—" },
                        { label: "跳过 CU 占比", value: "—" }
                      ]
            }

            // ═════════════════ 布局 ═════════════════

            // ── 标题栏 ──
            Row {
                id: headerRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.topMargin: 12
                height: 24

                Text {
                    text: "码流信息"
                    color: "#bbbbbb"; font.pixelSize: 14; font.bold: true
                }
                // 模式切换按钮：悬浮 ⇄ 腾位
                Rectangle {
                    id: modeSwitchBtn
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: frameCountText.left
                    anchors.rightMargin: 8
                    width: 22; height: 22
                    radius: 4
                    color: modeMa.pressed ? "#2a3f5a" : "#1a1d22"
                    border.color: "#2a2e33"; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: cardRoot.floating ? "◫" : "▣"
                        color: "#9aa0a6"; font.pixelSize: 12
                    }
                    MouseArea {
                        id: modeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: cardRoot.toggleFloating()
                        ToolTip.visible: containsMouse
                        ToolTip.text: cardRoot.floating
                                       ? "切换为腾位模式（画面左移让出空间）"
                                       : "切换为悬浮模式（卡片浮于画面上层）"
                    }
                }
                Text {
                    id: frameCountText
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    text: {
                        const _ = panel.ver
                        return panel.slotActive
                               ? (panel.curFrame + 1) + " / " + panel.frameList.length
                               : "—"
                    }
                    color: "#9aa0a6"; font.pixelSize: 11
                    font.family: "Monospace"
                }
            }

            // ── 上半区 Tab 条：文件 / 帧 / 统计 ──
            Row {
                id: mainTabBar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: headerRow.bottom
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.topMargin: 8
                spacing: 4

                Repeater {
                    model: ["文件", "帧", "统计"]
                    delegate: Rectangle {
                        width: (mainTabBar.width - mainTabBar.spacing * 2) / 3
                        height: 24
                        radius: 4
                        color: index === panel.mainTab ? "#2a3f5a" : "#1a1d22"
                        border.color: index === panel.mainTab ? "#42A5FF" : "#2a2e33"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            color: index === panel.mainTab ? "#e6f0ff" : "#9aa0a6"
                            font.pixelSize: 11
                            font.bold: index === panel.mainTab
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.mainTab = index
                        }
                    }
                }
            }

            // ── 上半区内容：当前 Tab 的面板（高度=内容自适应，行少不撑满）──
            // 2026-09-16：原实现 Loader 锚到 syntaxSection.top 且 syntaxSection
            // 固定占 45%，导致"等分两部分"。现改为：Loader 高度由面板内容决定
            // （fileInfoRows 仅 8 行），语法区锚到 Loader 实际底边，拿走全部剩余。
            Loader {
                id: upperLoader
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: mainTabBar.bottom
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.topMargin: 2
                // 高度跟随内容（textTabComp 面板的 implicitHeight），不锚 syntaxSection
                height: item ? item.implicitHeight : 0

                // 行数据由 currentRows 注入（文件 / 帧 / 统计共用文本面板）
                property var currentRows: panel.mainTab === 0 ? panel.fileInfoRows
                                : panel.mainTab === 1 ? panel.frameInfoRows
                                : panel.streamStatsRows
                sourceComponent: textTabComp

                // 文本面板（文件 / 帧 / 统计共用；行数不足时不留白，
                // 高度随内容自适应，面板从 Tab 条下方顶格排布）
                Component {
                    id: textTabComp
                    Item {
                        id: textPanelItem
                        implicitHeight: sectCard.implicitHeight
                        StreamInfoCardSection {
                            id: sectCard
                            x: 0; y: 0
                            width: parent.width
                            title: ""
                            rows: upperLoader.currentRows
                        }
                    }
                }
            }

            // ── 下半区：语法元素（VPS / SPS / PPS，锚到上半区底边，占满剩余）──
            Item {
                id: syntaxSection
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.top: upperLoader.bottom
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.bottomMargin: 8
                anchors.topMargin: 8
                // 标题行（单行紧凑布局）：
                //   [语法元素]  [🔍 搜索框（stretch）]  [N/M 项]
                // 搜索框只在解析出语法项后显示，未加载/解析中时该处留空，
                // 让标题+计数保持原有的极简观感。
                Item {
                    id: synHeader
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 22

                    Text {
                        id: synTitle
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        text: "语法元素"
                        color: "#bbbbbb"; font.pixelSize: 12; font.bold: true
                    }

                    Text {
                        id: synCount
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        text: {
                            const _ = panel.syntaxVer
                            const tab = panel.syntaxTab
                            if (!StreamBridge.hasFile(panel.slot)) return "—"
                            if (!panel.syntaxReady) return "解析中…"
                            const order = panel.syntaxGroups.order
                            const src = (tab >= 0 && tab < order.length)
                                        ? (panel.syntaxGroups.map[order[tab]] || [])
                                        : []
                            const tabTotal = src.length
                            if (!panel.syntaxFilter || panel.syntaxFilter.length === 0)
                                return tabTotal + " 项"
                            const kw = panel.syntaxFilter.toLowerCase()
                            let hit = 0
                            for (let i = 0; i < src.length; ++i) {
                                const e = src[i]
                                const nm = String(e.name || "").toLowerCase()
                                const vl = String(e.value || "").toLowerCase()
                                if (nm.indexOf(kw) >= 0 || vl.indexOf(kw) >= 0) ++hit
                            }
                            return hit + " / " + tabTotal + " 项"
                        }
                        color: (panel.syntaxFilter && panel.syntaxFilter.length > 0)
                               ? "#42A5FF" : "#9aa0a6"
                        font.pixelSize: 10
                        font.family: "Monospace"
                    }

                    // 搜索框（子串筛选，name/value 任一命中即保留），紧凑塞在标题与计数之间
                    Rectangle {
                        id: synSearchBox
                        anchors.left: synTitle.right
                        anchors.leftMargin: 8
                        anchors.right: synCount.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        height: 20
                        visible: panel.syntaxReady && panel.syntaxEntries.length > 0
                        radius: 3
                        color: "#0e1013"
                        border.color: synFilterField.activeFocus ? "#42A5FF" : "#1f2329"
                        border.width: 1

                        // 前缀图标（放大镜）
                        Text {
                            id: searchIcon
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 5
                            text: "🔍"
                            color: "#6a6f76"; font.pixelSize: 9
                        }

                        TextField {
                            id: synFilterField
                            anchors.left: searchIcon.right
                            anchors.leftMargin: 3
                            anchors.right: clearBtn.visible ? clearBtn.left : parent.right
                            anchors.rightMargin: 3
                            anchors.verticalCenter: parent.verticalCenter
                            height: 18
                            placeholderText: "搜索"
                            placeholderTextColor: "#5a5f66"
                            color: "#e6e6e6"
                            selectionColor: "#2a5fc0"
                            selectedTextColor: "#ffffff"
                            font.pixelSize: 10
                            font.family: "Monospace"
                            selectByMouse: true
                            // 去掉 QtQuick.Controls 默认 background 的白底/边框（不同 style
                            // 对 background:null 支持不一，用一个透明矩形更稳），
                            // 与外层 Rectangle 视觉合一。
                            background: Rectangle { color: "transparent" }
                            padding: 0
                            leftPadding: 0; rightPadding: 0
                            topPadding: 0; bottomPadding: 0
                            text: panel.syntaxFilter
                            onTextChanged: {
                                if (panel.syntaxFilter !== text) panel.syntaxFilter = text
                            }
                            Keys.onEscapePressed: function(event) {
                                panel.syntaxFilter = ""
                                text = ""
                                focus = false
                                event.accepted = true
                            }
                            Keys.onReturnPressed: function(event) {
                                focus = false
                                event.accepted = true
                            }
                            Keys.onEnterPressed: function(event) {
                                focus = false
                                event.accepted = true
                            }
                        }

                        // 清空按钮（有输入时才显示）
                        Rectangle {
                            id: clearBtn
                            visible: panel.syntaxFilter && panel.syntaxFilter.length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 3
                            width: 14; height: 14
                            radius: 7
                            color: clearMa.containsMouse ? "#2a2e33" : "transparent"
                            Text {
                                anchors.centerIn: parent
                                text: "✕"
                                color: "#9aa0a6"; font.pixelSize: 8
                            }
                            MouseArea {
                                id: clearMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    panel.syntaxFilter = ""
                                    synFilterField.text = ""
                                    synFilterField.forceActiveFocus()
                                }
                            }
                        }
                    }
                }

                // ── 内容框（未就绪时居中提示，就绪后 Tab + 名值对表）──
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: synHeader.bottom
                    anchors.topMargin: 6
                    anchors.bottom: parent.bottom
                    color: "#0e1013"
                    radius: 3
                    border.color: "#1f2329"; border.width: 1

                    Text {
                        anchors.centerIn: parent
                        visible: {
                            const _ = panel.syntaxVer
                            return !panel.syntaxReady || panel.syntaxEntries.length === 0
                        }
                        text: {
                            const _ = panel.syntaxVer
                            if (!StreamBridge.hasFile(panel.slot)) return "未加载文件"
                            if (!panel.syntaxReady) return "后台解析中，请稍候…"
                            return "该码流暂无可解析的参数集"
                        }
                        color: "#6a6f76"; font.pixelSize: 11
                        wrapMode: Text.WordWrap
                    }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 4
                        visible: panel.syntaxReady && panel.syntaxEntries.length > 0
                        spacing: 6

                        // 参数集 Tab 行（组多时横向滚动）
                        Flickable {
                            id: synTabFlick
                            width: parent.width
                            height: 26
                            contentWidth: synTabRow.width
                            contentHeight: height
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            flickableDirection: Flickable.HorizontalFlick

                            Row {
                                id: synTabRow
                                height: 26
                                spacing: 4
                                Repeater {
                                    model: (panel.syntaxReady && panel.syntaxEntries.length > 0)
                                           ? panel.syntaxGroups.order : []
                                    delegate: Rectangle {
                                        width: synTabLabel.implicitWidth + 18
                                        height: 24
                                        radius: 4
                                        color: (index === panel.syntaxTab) ? "#2a3f5a" : "#1a1d22"
                                        border.color: (index === panel.syntaxTab) ? "#42A5FF" : "#2a2e33"
                                        border.width: 1
                                        Text {
                                            id: synTabLabel
                                            anchors.centerIn: parent
                                            text: modelData
                                            color: (index === panel.syntaxTab) ? "#e6f0ff" : "#9aa0a6"
                                            font.pixelSize: 11
                                            font.bold: (index === panel.syntaxTab)
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: panel.syntaxTab = index
                                        }
                                    }
                                }
                            }
                        }

                        // 当前 Tab 的名值对表（占满剩余高度，区域内滚动）
                        // 过滤策略：syntaxFilter 非空时，name / value 任一命中子串（大小写不敏感）即保留。
                        // 空结果时显示"无匹配项"提示，避免用户以为面板炸了。
                        ListView {
                            id: syntaxList
                            width: parent.width
                            height: parent.height - synTabFlick.height - parent.spacing
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                            onModelChanged: positionViewAtBeginning()

                            // 复制反馈：记录最近一次拷贝的 index + 一个短暂 flash 时间戳
                            property int flashIndex: -1
                            Timer {
                                id: flashTimer
                                interval: 900
                                onTriggered: syntaxList.flashIndex = -1
                            }
                            function flashRow(i) {
                                syntaxList.flashIndex = i
                                flashTimer.restart()
                            }

                            model: {
                                const _ = panel.syntaxVer
                                if (!panel.syntaxReady) return []
                                const order = panel.syntaxGroups.order
                                if (panel.syntaxTab < 0 || panel.syntaxTab >= order.length)
                                    return []
                                const src = panel.syntaxGroups.map[order[panel.syntaxTab]] || []
                                const kw = (panel.syntaxFilter || "").toLowerCase()
                                if (kw.length === 0) return src
                                const out = []
                                for (let i = 0; i < src.length; ++i) {
                                    const nm = String(src[i].name || "").toLowerCase()
                                    const vl = String(src[i].value || "").toLowerCase()
                                    if (nm.indexOf(kw) >= 0 || vl.indexOf(kw) >= 0)
                                        out.push(src[i])
                                }
                                return out
                            }

                            // 空提示（过滤后无命中）
                            Text {
                                anchors.centerIn: parent
                                visible: syntaxList.count === 0
                                         && panel.syntaxFilter && panel.syntaxFilter.length > 0
                                text: "无匹配项：\"" + panel.syntaxFilter + "\""
                                color: "#6a6f76"; font.pixelSize: 10
                            }

                            delegate: Item {
                                id: synRow
                                width: syntaxList.width
                                height: 18
                                property bool isFlash: syntaxList.flashIndex === index
                                required property int index
                                required property var modelData

                                // 底层背景：hover / flash / 右键菜单打开时高亮
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.leftMargin: -2
                                    anchors.rightMargin: -2
                                    radius: 2
                                    color: synRow.isFlash
                                           ? "#2a5fc0"
                                           : (rowMa.containsMouse || rowMenu.visible ? "#1a1d22" : "transparent")
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                }

                                // 名称列（左，尽量占满，右对齐值列 78px）
                                Text {
                                    id: nameText
                                    anchors.left: parent.left
                                    anchors.leftMargin: 2
                                    anchors.right: valueText.left
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: String(synRow.modelData.name)
                                    color: synRow.isFlash ? "#e6f0ff" : "#9aa0a6"
                                    font.pixelSize: 10
                                    font.family: "Monospace"
                                    elide: Text.ElideRight
                                }

                                // 数值列（右）
                                Text {
                                    id: valueText
                                    width: 78
                                    anchors.right: parent.right
                                    anchors.rightMargin: 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    text: String(synRow.modelData.value)
                                    color: synRow.isFlash ? "#ffffff" : "#cccccc"
                                    font.pixelSize: 10
                                    font.family: "Monospace"
                                    elide: Text.ElideLeft
                                }

                                // 行覆盖 MouseArea：
                                //   · 左键单击 → 复制 "name = value" + 短暂高亮反馈
                                //   · 右键 → 弹出上下文菜单（复制名称 / 数值 / name=value）
                                //   · 悬停 → 显示 tooltip（完整 name = value，兜底长文本被 elide 情况）
                                MouseArea {
                                    id: rowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: function(mouse) {
                                        if (mouse.button === Qt.RightButton) {
                                            rowMenu.popup()
                                            return
                                        }
                                        // 左键：快速复制 name = value
                                        panel.copyToClipboard(
                                            String(synRow.modelData.name) + " = "
                                            + String(synRow.modelData.value))
                                        syntaxList.flashRow(synRow.index)
                                    }
                                    ToolTip.visible: containsMouse && !rowMenu.visible
                                    ToolTip.delay: 500
                                    ToolTip.text: String(synRow.modelData.name)
                                                  + " = " + String(synRow.modelData.value)
                                                  + "\n（左键复制 · 右键菜单）"
                                }

                                // 右键上下文菜单（暗色风格，与 StreamView.qml 排序菜单一致）
                                // 默认 Qt Quick Controls Menu 是浅色（白底），需覆盖
                                // background / MenuItem.contentItem+background 实现暗色。
                                Menu {
                                    id: rowMenu
                                    width: 200
                                    topPadding: 6; bottomPadding: 6
                                    leftPadding: 4; rightPadding: 4

                                    background: Rectangle {
                                        implicitWidth: 200
                                        implicitHeight: 32
                                        color: "#cc1a1a1f"
                                        border.color: "#33ffffff"
                                        border.width: 1
                                        radius: 6
                                    }

                                    // 复制名称
                                    MenuItem {
                                        text: "复制名称"
                                        height: 28
                                        contentItem: Text {
                                            text: parent.text
                                            color: "#e8e8ec"
                                            font.pixelSize: 12
                                            leftPadding: 12
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            color: parent.hovered ? "#803a3a3d" : "transparent"
                                            radius: 4
                                        }
                                        onTriggered: {
                                            panel.copyToClipboard(String(synRow.modelData.name))
                                            syntaxList.flashRow(synRow.index)
                                        }
                                    }
                                    // 复制数值
                                    MenuItem {
                                        text: "复制数值"
                                        height: 28
                                        contentItem: Text {
                                            text: parent.text
                                            color: "#e8e8ec"
                                            font.pixelSize: 12
                                            leftPadding: 12
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            color: parent.hovered ? "#803a3a3d" : "transparent"
                                            radius: 4
                                        }
                                        onTriggered: {
                                            panel.copyToClipboard(String(synRow.modelData.value))
                                            syntaxList.flashRow(synRow.index)
                                        }
                                    }
                                    // 复制 name = value
                                    MenuItem {
                                        text: "复制 name = value"
                                        height: 28
                                        contentItem: Text {
                                            text: parent.text
                                            color: "#e8e8ec"
                                            font.pixelSize: 12
                                            leftPadding: 12
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            color: parent.hovered ? "#803a3a3d" : "transparent"
                                            radius: 4
                                        }
                                        onTriggered: {
                                            panel.copyToClipboard(
                                                String(synRow.modelData.name) + " = "
                                                + String(synRow.modelData.value))
                                            syntaxList.flashRow(synRow.index)
                                        }
                                    }
                                    MenuSeparator {
                                        height: 1; topPadding: 4; bottomPadding: 4
                                        contentItem: Rectangle { color: "#33ffffff"; implicitHeight: 1 }
                                        background: Rectangle { color: "transparent" }
                                    }
                                    // 复制当前分组（TSV）
                                    MenuItem {
                                        text: "复制当前分组（TSV）"
                                        height: 28
                                        contentItem: Text {
                                            text: parent.text
                                            color: "#e8e8ec"
                                            font.pixelSize: 12
                                            leftPadding: 12
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            color: parent.hovered ? "#803a3a3d" : "transparent"
                                            radius: 4
                                        }
                                        onTriggered: {
                                            // 复制当前 ListView 可见（已过滤）的全部行
                                            // 每行 "name<TAB>value"，可粘贴到 Excel/Numbers 自动分列
                                            const m = syntaxList.model
                                            let lines = []
                                            for (let i = 0; i < m.length; ++i)
                                                lines.push(String(m[i].name) + "\t" + String(m[i].value))
                                            panel.copyToClipboard(lines.join("\n"))
                                            syntaxList.flashRow(synRow.index)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 点侧栏其它区域时收起搜索焦点，避免空格/方向键仍被输入框吃掉
            MouseArea {
                anchors.fill: parent
                z: 1000
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                propagateComposedEvents: true
                onPressed: function(mouse) {
                    if (!synFilterField.activeFocus) {
                        mouse.accepted = false
                        return
                    }
                    const p = mapToItem(synSearchBox, mouse.x, mouse.y)
                    const inside = synSearchBox.visible
                                   && p.x >= 0 && p.y >= 0
                                   && p.x < synSearchBox.width
                                   && p.y < synSearchBox.height
                    if (!inside)
                        synFilterField.focus = false
                    mouse.accepted = false
                }
            }
        }
    }
}
