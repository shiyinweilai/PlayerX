// StreamInfoCard.qml — 码流分析右侧统计卡片
//
// 风格对齐 YuvStatsPanel.qml / YuvWindow 主题：
//   - 背景 #121417，左侧 1px #2a2e33 分隔线
//   - 卡片表头 + 数值行（"标签 / 值" 两列），等宽字体用于数值
//   - 数值用 #cccccc，标签用 #9aa0a6，弱提示用 #6a6f76
//
// 内容（与参考截图一致的三段）：
//   1. 帧信息：帧号 / POC / 帧类型 / 参考帧 / 显示顺序 / 解码顺序 / 时间戳
//   2. 码流统计：帧大小 / 码率 / QP 均值 / QP 最小最大 / CU 总数 / 跳过 CU 占比
//   3. 码率曲线（Mbps）：折线图 + HRD 越限区间半透明暗红背景
//
// 布局双模式（2026-09-16 改造）：
//   · floating = false（默认）→ 腾位栏：填满 Main.qml 的 rightSidebarLoader
//     （320px，画面整体左移让位），左侧 1px 分隔线，实底 #121417。
//   · floating = true → 悬浮卡：固定宽 304，右侧/顶部留 12px 边距，圆角 8，
//     半透明底 #f0121417 + 边框 #2a2e33，浮在播放画面上层。
//   两种模式内容与数据源完全一致，由内部 Loader 复用同一份内容组件。

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

    // 内容组件：两种布局模式共用的数据源 + UI 主体。id 仍为 panel。
    // slot 直接绑 cardRoot.slot（同文件 id 引用），Main.qml 只需设置
    // cardRoot 的 slot / floating 即可，无需向内容传参。
    // ═══════════════════════════════════════════════════════════════
    Component {
        id: cardContentComp
        Item {
            id: panel
            required property int slot
            property int ver: 0
            property int syntaxVer: 0
            slot: cardRoot.slot

            Connections {
            target: StreamBridge
            // 对齐图2「帧统计」面板的成功做法：帧变化不做 slot 过滤，
            // 无条件 ver++。后端 currentFrameChanged 携带的 slot 号可能与 UI 的
            // effectiveSlot 因时序对不上，一旦过滤就会漏刷，导致帧号卡在初值不动。
            // 多 slot 时最多多刷新几次，curFrame 内部仍按 slot 取值，无副作用。
            function onCurrentFrameChanged(changedSlot) { panel.ver++ }
            function onFileOpened(openedSlot) {
                if (openedSlot === panel.slot) panel.ver++
            }
            function onFileClosed(closedSlot) {
                if (closedSlot === panel.slot) panel.ver++
            }
            function onSlotCountChanged() { panel.ver++ }
        }
        // 语法解析后台就绪后刷新（VPS/SPS/PPS 名值对，与 slot 对应）
        Connections {
            target: StreamBridge
            function onSyntaxReadyChanged(readySlot) {
                if (readySlot === panel.slot) panel.syntaxVer++
            }
            // 文件打开/关闭时也刷新，避免右侧栏挂载早于文件打开导致的绑定失效
            function onFileOpened(openedSlot) {
                if (openedSlot === panel.slot) panel.syntaxVer++
            }
            function onFileClosed(closedSlot) {
                if (closedSlot === panel.slot) panel.syntaxVer++
            }
        }

        // slotActive 依赖 ver：Q_INVOKABLE 的 hasFile 不会自动响应内部状态变化，
        // 必须靠 ver（随 fileOpened/fileClosed/slotCountChanged 递增）强制重算，
        // 否则右侧栏挂载早于文件打开时会永久卡在初值 false，导致各段全显示"—"。
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
        // 块级统计（{ valid, avgQp, minQp, maxQp, blockCount }）：随帧切换重取
        readonly property var    blockStats:    { const _ = ver; return slotActive ? StreamBridge.blockStats(slot, curFrame) : ({ valid: false }) }
        // 语法元素（VPS/SPS/PPS 名值对）：后台一次 CBS 解析，就绪后只读缓存
        // 独立于 slotActive：syntaxVer 变化时强制重算，避免绑定卡在初值 false
        readonly property bool   syntaxReady:    { const _ = syntaxVer; return StreamBridge.hasFile(slot) && StreamBridge.syntaxReady(slot) }
        readonly property var    syntaxEntries:  { const _ = syntaxVer; return StreamBridge.hasFile(slot) ? StreamBridge.syntaxEntries(slot) : [] }
        // 按参数集分组：{ "VPS": [...], "SPS": [...], "PPS": [...] }，保持解析顺序
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
        // 码率采样（Mbps）：取 frameList，每 16 帧一个采样点（minimap 思想）
        readonly property var    bitrateSamples: {
            const _ = ver
            if (!frameList || frameList.length === 0) return []
            const out = []
            const n = frameList.length
            const bucket = Math.max(1, Math.floor(n / 200))   // 最多 200 个采样点
            for (let i = 0; i < n; i += bucket) {
                let sumBytes = 0, cnt = 0
                for (let j = i; j < Math.min(i + bucket, n); ++j) {
                    sumBytes += Number(frameList[j].sizeBytes)
                    cnt++
                }
                // Mbps = (bytes * 8) / (bucket 帧数 * 帧间隔) / 1e6
                const fps = Number(info.fps) > 0 ? Number(info.fps) : 30
                const sec = cnt / fps
                out.push(sec > 0 ? (sumBytes * 8.0 / sec / 1e6) : 0)
            }
            return out
        }

        Flickable {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 12
            contentWidth: width
            contentHeight: col.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
                id: col
                width: parent.width
                spacing: 12

                // ── 标题栏 ──
                Row {
                    width: parent.width
                    Text {
                        text: "码流信息"
                        color: "#bbbbbb"; font.pixelSize: 14; font.bold: true
                    }
                    // 模式切换按钮：悬浮 ⇄ 腾位（icon-only，悬浮预览 tooltip）
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
                                   ? (panel.curFrame + 1) + " / " + frameList.length
                                   : "—"
                        }
                        color: "#9aa0a6"; font.pixelSize: 11
                        font.family: "Monospace"
                    }
                }

                // ── 文件信息卡片（从原顶栏移入，全部复用已缓存 streamInfo，零开销）──
                StreamInfoCardSection {
                    title: "文件信息"
                    rows: {
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
                }

                // ── 帧信息卡片 ──
                StreamInfoCardSection {
                    title: "帧信息"
                    rows: panel.slotActive && panel.currentFrameItem
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

                // ── 码流统计卡片 ──
                // 块级统计来自 blockStats(slot, curFrame)：HEVC 补丁导出每 CU 真实 QP 后，
                // avgQp/minQp/maxQp/blockCount 才有效（H.264/VVC 同理）；不可用时显示"—"。
                StreamInfoCardSection {
                    title: "码流统计（当前帧）"
                    rows: panel.slotActive && panel.currentFrameItem
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

                // ── 码率曲线 ──
                Column {
                    width: parent.width
                    spacing: 6
                    Row {
                        width: parent.width
                        Text {
                            text: "码率曲线 (Mbps)"
                            color: "#bbbbbb"; font.pixelSize: 12; font.bold: true
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            text: "HRD 越限区间"
                            color: "#9aa0a6"; font.pixelSize: 10
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 86
                            width: 10; height: 10; radius: 2
                            color: "#301a1a"
                            border.color: "#b85a5a"; border.width: 1
                        }
                    }
                    Canvas {
                        id: chartCanvas
                        width: parent.width
                        height: 120
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            const w = width, h = height
                            ctx.fillStyle = "#0a0a0e"
                            ctx.fillRect(0, 0, w, h)
                            // 水平网格
                            ctx.strokeStyle = "#1a1d22"
                            ctx.lineWidth = 1
                            for (let g = 0; g <= 4; ++g) {
                                const y = (h * g / 4) | 0
                                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke()
                            }
                            const samples = panel.bitrateSamples
                            if (!samples || samples.length === 0) {
                                ctx.fillStyle = "#6a6f76"
                                ctx.font = "11px sans-serif"
                                ctx.textAlign = "center"
                                ctx.fillText("未加载文件", w / 2, h / 2)
                                return
                            }
                            // 归一化：max
                            let mx = 0
                            for (let i = 0; i < samples.length; ++i) if (samples[i] > mx) mx = samples[i]
                            if (mx <= 0) mx = 1
                            // 折线
                            ctx.strokeStyle = "#42A5FF"
                            ctx.lineWidth = 1.5
                            ctx.beginPath()
                            for (let i = 0; i < samples.length; ++i) {
                                const x = (w * i / Math.max(1, samples.length - 1))
                                const y = h - (h * 0.9 * (samples[i] / mx)) - 2
                                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                            }
                            ctx.stroke()
                            // 渐变填充
                            const grad = ctx.createLinearGradient(0, 0, 0, h)
                            grad.addColorStop(0, "rgba(66,165,255,0.30)")
                            grad.addColorStop(1, "rgba(66,165,255,0.02)")
                            ctx.fillStyle = grad
                            ctx.lineTo(w, h); ctx.lineTo(0, h); ctx.closePath(); ctx.fill()
                            // Y 轴 max 标签
                            ctx.fillStyle = "#6a6f76"
                            ctx.font = "9px sans-serif"
                            ctx.textAlign = "left"
                            ctx.fillText(mx.toFixed(1), 4, 12)
                            ctx.fillText("0", 4, h - 4)
                        }
                    }
                    Connections {
                        target: panel
                        function onVerChanged() { chartCanvas.requestPaint() }
                    }
                    Connections {
                        target: StreamBridge
                        function onCurrentFrameChanged() { chartCanvas.requestPaint() }
                        function onFileOpened() { chartCanvas.requestPaint() }
                    }
                }

                // ── 语法元素（VPS / SPS / PPS，Tab 切换，仅当前组内滚动）──
                Column {
                    id: syntaxSection
                    width: parent.width
                    spacing: 6

                    // 当前选中的 Tab 索引（对应 syntaxGroups.order 下标）
                    property int curTab: 0
                    // 解析就绪 / 换文件后 Tab 复位到第一个
                    Connections {
                        target: panel
                        function onSyntaxVerChanged() {
                            if (syntaxSection.curTab >= panel.syntaxGroups.order.length)
                                syntaxSection.curTab = 0
                        }
                    }

                    Row {
                        width: parent.width
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

                    // 未就绪 / 无数据降级提示
                    Text {
                        width: parent.width
                        visible: {
                            const _ = panel.syntaxVer
                            return !StreamBridge.hasFile(panel.slot)
                                   || !panel.syntaxReady
                                   || panel.syntaxEntries.length === 0
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

                    // ── Tab 行（参数集名，横向；组多时可横向滚动）──
                    Flickable {
                        id: tabFlick
                        width: parent.width
                        height: (panel.syntaxReady && panel.syntaxEntries.length > 0) ? 26 : 0
                        visible: panel.syntaxReady && panel.syntaxEntries.length > 0
                        contentWidth: tabRow.width
                        contentHeight: height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.HorizontalFlick

                        Row {
                            id: tabRow
                            height: 26
                            spacing: 4
                            Repeater {
                                model: (panel.syntaxReady && panel.syntaxEntries.length > 0)
                                       ? panel.syntaxGroups.order : []
                                delegate: Rectangle {
                                    width: tabLabel.implicitWidth + 18
                                    height: 24
                                    radius: 4
                                    color: (index === syntaxSection.curTab) ? "#2a3f5a" : "#1a1d22"
                                    border.color: (index === syntaxSection.curTab) ? "#42A5FF" : "#2a2e33"
                                    border.width: 1
                                    Text {
                                        id: tabLabel
                                        anchors.centerIn: parent
                                        text: modelData
                                        color: (index === syntaxSection.curTab) ? "#e6f0ff" : "#9aa0a6"
                                        font.pixelSize: 11
                                        font.bold: (index === syntaxSection.curTab)
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: syntaxSection.curTab = index
                                    }
                                }
                            }
                        }
                    }

                    // ── 当前 Tab 的名值对表（固定高度，仅本区域内竖向滚动）──
                    Rectangle {
                        width: parent.width
                        height: (panel.syntaxReady && panel.syntaxEntries.length > 0) ? 340 : 0
                        visible: panel.syntaxReady && panel.syntaxEntries.length > 0
                        color: "#0e1013"
                        radius: 3
                        border.color: "#1f2329"; border.width: 1

                        ListView {
                            id: syntaxList
                            anchors.fill: parent
                            anchors.margins: 4
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                            // 切 Tab 时回到顶部
                            onModelChanged: positionViewAtBeginning()

                            model: {
                                const _ = panel.syntaxVer
                                if (!panel.syntaxReady) return []
                                const order = panel.syntaxGroups.order
                                if (syntaxSection.curTab < 0 || syntaxSection.curTab >= order.length)
                                    return []
                                return panel.syntaxGroups.map[order[syntaxSection.curTab]] || []
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
}
