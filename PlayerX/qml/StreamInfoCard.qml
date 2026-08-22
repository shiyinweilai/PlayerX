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
// 一期 P0：
//   - 帧信息全部从 RBStreamBridge 真实数据读（除了 CU / QP 走"未启用"降级）
//   - 码率曲线使用真实 frameSizes 数组（每帧字节数）做折线
//   - HRD 越限区间：StreamBridge.hrdEstimate() available=false 时不画

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: panel
    color: "#121417"
    anchors.fill: parent

    // 外部属性：当前选中的 slot（从 main.qml 透传，1:1 跟随 StreamView）
    property int slot: 0
    property int ver: 0
    Connections {
        target: StreamBridge
        function onCurrentFrameChanged(changedSlot) {
            if (changedSlot === panel.slot) panel.ver++
        }
        function onFileOpened(openedSlot) {
            if (openedSlot === panel.slot) panel.ver++
        }
        function onFileClosed(closedSlot) {
            if (closedSlot === panel.slot) panel.ver++
        }
        function onSlotCountChanged() { panel.ver++ }
    }

    readonly property bool   slotActive:    StreamBridge.hasFile(slot)
    readonly property var    info:          slotActive ? StreamBridge.streamInfo(slot) : ({})
    readonly property int    curFrame:      slotActive ? StreamBridge.currentFrame(slot) : 0
    readonly property var    frameList:     slotActive ? StreamBridge.frameList(slot) : []
    readonly property var    currentFrameItem:
        (slotActive && curFrame >= 0 && curFrame < frameList.length)
        ? frameList[curFrame] : null
    readonly property var    hrd:           slotActive ? StreamBridge.hrdEstimate(slot) : ({})
    readonly property var    gopList:       slotActive ? StreamBridge.gopList(slot) : []
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

    // 左侧 1px 分隔线
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: "#2a2e33"
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
                    text: "码流统计"
                    color: "#bbbbbb"; font.pixelSize: 14; font.bold: true
                }
                Text {
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
            StreamInfoCardSection {
                title: "码流统计（当前帧）"
                rows: panel.slotActive && panel.currentFrameItem
                    ? [
                        { label: "帧大小",   value: (Number(panel.currentFrameItem.sizeBytes) / 1024).toFixed(1) + " KB" },
                        { label: "码率",     value: (Number(panel.info.bitrate) / 1e6).toFixed(2) + " Mbps" },
                        { label: "QP 均值",  value: Number(panel.currentFrameItem.avgQp) >= 0
                                                 ? Number(panel.currentFrameItem.avgQp).toFixed(1) : "—" },
                        { label: "QP 最小 / 最大", value: "— / —" },
                        { label: "CU 总数",  value: "—" },
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
        }
    }
}
