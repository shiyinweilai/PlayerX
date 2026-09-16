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
            slot: cardRoot.slot

            // 参数集组数变化（换文件 / 重新解析）后 Tab 复位到第一个
            onSyntaxVerChanged: {
                if (panel.syntaxTab >= panel.syntaxGroups.order.length)
                    panel.syntaxTab = 0
            }

            // ── 数据刷新信号（沿用 ver / syntaxVer 强制重算机制）──
            // 帧变化不做 slot 过滤：后端 currentFrameChanged 携带的 slot 号
            // 可能与 UI 的 effectiveSlot 时序对不上，过滤会漏刷导致卡初值。
            Connections {
                target: StreamBridge
                function onCurrentFrameChanged(changedSlot) { panel.ver++ }
                function onFileOpened(openedSlot) {
                    if (openedSlot === panel.slot) panel.ver++
                }
                function onFileClosed(closedSlot) {
                    if (closedSlot === panel.slot) panel.ver++
                }
                function onSlotCountChanged() { panel.ver++ }
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

            // ── 数据属性（原实现原样保留）──
            readonly property bool   slotActive:    { const _ = ver; return StreamBridge.hasFile(slot) }
            readonly property var    info:          { const _ = ver; return slotActive ? StreamBridge.streamInfo(slot) : ({}) }
            readonly property int    curFrame:      { const _ = ver; return slotActive ? StreamBridge.currentFrame(slot) : 0 }
            readonly property var    frameList:     { const _ = ver; return slotActive ? StreamBridge.frameList(slot) : [] }
            readonly property var    currentFrameItem: {
                const _ = ver
                return (slotActive && curFrame >= 0 && curFrame < frameList.length)
                       ? frameList[curFrame] : null
            }
            readonly property var    hrd:           { const _ = ver; return slotActive ? StreamBridge.hrdEstimate(slot) : ({}) }
            readonly property var    gopList:       { const _ = ver; return slotActive ? StreamBridge.gopList(slot) : [] }
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
                    { label: "码率",          value: (Number(inf.bitrate) / 1e6).toFixed(2) + " Mbps" },
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
                        { label: "码率",     value: (Number(panel.info.bitrate) / 1e6).toFixed(2) + " Mbps" },
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

            // ── 上半区内容：当前 Tab 的面板 ──
            Loader {
                id: upperLoader
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: mainTabBar.bottom
                anchors.bottom: syntaxSection.top
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.topMargin: 8
                anchors.bottomMargin: 8
                // 行数据由 currentRows 注入（文件 / 帧 / 统计共用文本面板）
                property var currentRows: panel.mainTab === 0 ? panel.fileInfoRows
                                : panel.mainTab === 1 ? panel.frameInfoRows
                                : panel.streamStatsRows
                sourceComponent: textTabComp

                // 文本面板（文件 / 帧 / 统计共用，可滚动防溢出）
                Component {
                    id: textTabComp
                    Flickable {
                        anchors.fill: parent
                        contentWidth: width
                        contentHeight: sectCard.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
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

            // ── 下半区：语法元素（VPS / SPS / PPS，固定占约 45%）──
            Item {
                id: syntaxSection
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.bottomMargin: 8
                height: Math.max(170, panel.height * 0.45)

                // ── 小标题行 ──
                Row {
                    id: synHeader
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 18
                    Text {
                        text: "语法元素"
                        color: "#bbbbbb"; font.pixelSize: 12; font.bold: true
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        text: {
                            const _ = panel.syntaxVer
                            if (!StreamBridge.hasFile(panel.slot)) return "—"
                            if (!panel.syntaxReady) return "解析中…"
                            return panel.syntaxEntries.length + " 项"
                        }
                        color: "#9aa0a6"; font.pixelSize: 10
                        font.family: "Monospace"
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
                        ListView {
                            id: syntaxList
                            width: parent.width
                            height: parent.height - synTabFlick.height - parent.spacing
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                            onModelChanged: positionViewAtBeginning()

                            model: {
                                const _ = panel.syntaxVer
                                if (!panel.syntaxReady) return []
                                const order = panel.syntaxGroups.order
                                if (panel.syntaxTab < 0 || panel.syntaxTab >= order.length)
                                    return []
                                return panel.syntaxGroups.map[order[panel.syntaxTab]] || []
                            }

                            delegate: Row {
                                width: syntaxList.width
                                height: 18
                                spacing: 6
                                Text {
                                    width: parent.width - 84
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: String(modelData.name)
                                    color: "#9aa0a6"; font.pixelSize: 10
                                    font.family: "Monospace"
                                    elide: Text.ElideRight
                                    ToolTip.visible: hovNameMa.containsMouse
                                    ToolTip.text: String(modelData.name)
                                    MouseArea {
                                        id: hovNameMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        acceptedButtons: Qt.NoButton
                                    }
                                }
                                Text {
                                    width: 78
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    text: String(modelData.value)
                                    color: "#cccccc"; font.pixelSize: 10
                                    font.family: "Monospace"
                                    elide: Text.ElideLeft
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
