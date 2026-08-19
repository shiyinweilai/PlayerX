import QtQuick
import QtQuick.Controls
import PlayerX 1.0

// ─── YUV 分析右侧栏：直方图统计面板 ───────────────────────────────────
// 风格：专业示波器风格。Y=白、U=蓝、V=红，红色 TV Range 虚线，水平网格。
// 桶数按位深自适应（8bit=256, 10bit=1024）。
Rectangle {
    id: panel
    color: "#121417"
    anchors.fill: parent

    property int activeSlot: 0
    property int ver: 0

    Connections {
        target: YuvBridge
        function onFrameChanged(slot) { if (slot === panel.activeSlot) panel.ver++ }
        function onFileOpened(slot) { panel.ver++ }
        function onSlotCountChanged() { panel.ver++ }
    }

    // 左侧分隔线
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: "#2a2e33"
    }

    Flickable {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.topMargin: 12
        contentWidth: width - 24
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
            id: col
            width: parent.width - 24
            spacing: 12

            // ── 标题栏 ──
            Row {
                width: parent.width
                Text {
                    text: "YUV 统计"
                    color: "#bbbbbb"; font.pixelSize: 14; font.bold: true
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    text: {
                        const _ = panel.ver
                        if (YuvBridge.slotCount <= 0) return ""
                        return "帧 " + (YuvBridge.currentFrame(panel.activeSlot) + 1) +
                               " / " + YuvBridge.totalFrames(panel.activeSlot)
                    }
                    color: "#9aa0a6"; font.pixelSize: 11
                }
            }

            // ── slot 选择 tabs（多路时）──
            Row {
                width: parent.width
                visible: YuvBridge.slotCount > 1
                spacing: 4
                Repeater {
                    model: YuvBridge.slotCount
                    delegate: Rectangle {
                        required property int index
                        width: Math.max(44, (col.width - 8) / YuvBridge.slotCount)
                        height: 22
                        radius: 4
                        color: panel.activeSlot === index ? "#2a3a55" : "#1e1e26"
                        border.color: panel.activeSlot === index ? "#3a6fd8" : "#2a2a32"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "槽 " + (index + 1)
                            color: panel.activeSlot === index ? "#ffffff" : "#a0a4ac"
                            font.pixelSize: 11
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { panel.activeSlot = index; panel.ver++ }
                        }
                    }
                }
            }

            // ── 直方图组件（专业示波器风格）──
            component HistItem: Column {
                id: histRoot
                width: parent.width
                spacing: 4
                property string title: ""
                property color drawColor: "#ffffff"
                property int plane: 0
                property real mean: 0
                property real stdDev: 0
                property real minVal: 0
                property real maxVal: 0

                readonly property color bgColor: "#121417"
                readonly property color gridColor: "#2c3036"
                readonly property color thresholdColor: "#ff3a3a"
                readonly property color textColor: "#bbbbbb"

                // 直方图 bins 数据（来自 YuvBridge.histogram().bins）
                property var histData: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, histRoot.plane)
                    if (!d || !d.bins) return []
                    // 显式转为 JS 纯数字数组（QVariantList 在 JS 里访问可能成
                    // QVariant 对象，直接 Number() 转一下避免绘制时 NaN）
                    const r = []
                    const src = d.bins
                    for (let i = 0; i < src.length; i++) r.push(Number(src[i]))
                    return r
                }
                onHistDataChanged: cv.requestPaint()

                // 标题行：色块 + 标题
                Row {
                    width: parent.width
                    spacing: 6
                    Rectangle {
                        width: 10; height: 10; radius: 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: histRoot.drawColor
                    }
                    Text {
                        text: histRoot.title
                        color: histRoot.drawColor
                        font.pixelSize: 14; font.bold: true
                    }
                }

                // 直方图绘制 Canvas
                Canvas {
                    id: cv
                    width: parent.width
                    height: 160
                    Component.onCompleted: cv.requestPaint()
                    Connections {
                        target: histRoot
                        function onHistDataChanged() { cv.requestPaint() }
                    }
                    onPaint: {
                        const ctx = getContext("2d")
                        const w = cv.width
                        const h = cv.height
                        ctx.clearRect(0, 0, w, h)

                        // 1. 绘图区背景
                        ctx.fillStyle = histRoot.bgColor
                        ctx.fillRect(0, 0, w, h)

                        // 2. 水平网格线
                        ctx.strokeStyle = histRoot.gridColor
                        ctx.lineWidth = 1
                        ctx.globalAlpha = 0.4
                        for (let i = 1; i <= 4; i++) {
                            const y = h * i / 4
                            ctx.beginPath()
                            ctx.moveTo(0, y)
                            ctx.lineTo(w, y)
                            ctx.stroke()
                        }
                        ctx.globalAlpha = 1

                        // 3. 取直方图数据
                        const histObj = YuvBridge.histogram(panel.activeSlot, histRoot.plane)
                        const rawBins = histObj && histObj.bins ? histObj.bins : []
                        const N = rawBins.length
                        if (N === 0) {
                            ctx.fillStyle = "#5a5f66"
                            ctx.font = "10px sans-serif"
                            ctx.fillText("无数据", 8, h / 2)
                            return
                        }
                        // 转纯 number 数组 + 求 max
                        let bins = new Array(N)
                        let maxC = 1
                        for (let i = 0; i < N; i++) {
                            const v = Number(rawBins[i]) || 0
                            bins[i] = v
                            if (v > maxC) maxC = v
                        }
                        if (maxC <= 0) maxC = 1

                        // 4. 离散单像素柱子（每根 1px 宽，柱间留 1px 间隙，参考图风格）
                        const plotTop = 2
                        const plotBottom = h - 16
                        const plotH = plotBottom - plotTop
                        ctx.fillStyle = histRoot.drawColor
                        ctx.globalAlpha = 0.65
                        const colW = w / N
                        // 柱子宽度 = colW - 1px（让网格线穿过柱间）
                        const barW = Math.max(1, colW - 1)
                        for (let i = 0; i < N; i++) {
                            const v = bins[i] / maxC
                            if (v <= 0) continue
                            const px = i * colW
                            const barH = v * plotH
                            ctx.fillRect(px, plotBottom - barH, barW, barH)
                        }
                        ctx.globalAlpha = 1

                        // 5. 左右红色阈值虚线
                        const lo = histRoot.minVal
                        const hi = histRoot.maxVal
                        if (lo >= 0 && lo < N && hi > 0 && hi < N) {
                            ctx.setLineDash([4, 4])
                            ctx.strokeStyle = histRoot.thresholdColor
                            ctx.lineWidth = 1
                            const xMin = lo / (N - 1) * w
                            const xMax = hi / (N - 1) * w
                            ctx.beginPath()
                            ctx.moveTo(xMin, plotTop); ctx.lineTo(xMin, plotBottom)
                            ctx.moveTo(xMax, plotTop); ctx.lineTo(xMax, plotBottom)
                            ctx.stroke()
                            ctx.setLineDash([])

                            ctx.fillStyle = "#ff7070"
                            ctx.font = "9px sans-serif"
                            ctx.fillText(lo.toString(), xMin + 2, 9)
                            ctx.fillText(hi.toString(), xMax - 14, 9)
                        }

                        // 6. X 轴刻度
                        ctx.fillStyle = "#9aa0a6"
                        ctx.font = "9px sans-serif"
                        const ticks = (N > 256)
                            ? [0, 256, 512, 768, 1023]
                            : [0, 64, 128, 192, 255]
                        for (let t = 0; t < ticks.length; t++) {
                            const tx = ticks[t] / (N - 1) * w
                            ctx.textAlign = (t === 0) ? "left"
                                          : (t === ticks.length - 1) ? "right"
                                          : "center"
                            ctx.fillText(ticks[t].toString(), tx, h - 4)
                        }
                        ctx.textAlign = "left"
                    }

                    // 数据来源在 HistItem.histData（外层 property，便于 AOT 追踪依赖）
                }

                // 底部统计文本
                Text {
                    width: parent.width
                    text: "均值 " + histRoot.mean +
                          "  标准差 " + histRoot.stdDev +
                          "  最小 " + histRoot.minVal +
                          "  最大 " + histRoot.maxVal
                    color: histRoot.textColor
                    font.pixelSize: 12
                    font.family: "Monospace"
                }
            }

            // Y / U / V 直方图
            HistItem {
                title: "Y 直方图"
                drawColor: "#ffffff"
                plane: 0
                height: 200
                mean: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 0)
                    return d && d.mean !== undefined ? d.mean.toFixed(1) : "—"
                }
                stdDev: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 0)
                    return d && d.stddev !== undefined ? d.stddev.toFixed(1) : "—"
                }
                minVal: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 0)
                    return d && d.min !== undefined ? d.min : "—"
                }
                maxVal: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 0)
                    return d && d.max !== undefined ? d.max : "—"
                }
            }
            HistItem {
                title: "U 直方图"
                drawColor: "#42A5FF"
                plane: 1
                height: 200
                mean: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 1)
                    return d && d.mean !== undefined ? d.mean.toFixed(1) : "—"
                }
                stdDev: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 1)
                    return d && d.stddev !== undefined ? d.stddev.toFixed(1) : "—"
                }
                minVal: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 1)
                    return d && d.min !== undefined ? d.min : "—"
                }
                maxVal: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 1)
                    return d && d.max !== undefined ? d.max : "—"
                }
            }
            HistItem {
                title: "V 直方图"
                drawColor: "#FF4888"
                plane: 2
                height: 200
                mean: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 2)
                    return d && d.mean !== undefined ? d.mean.toFixed(1) : "—"
                }
                stdDev: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 2)
                    return d && d.stddev !== undefined ? d.stddev.toFixed(1) : "—"
                }
                minVal: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 2)
                    return d && d.min !== undefined ? d.min : "—"
                }
                maxVal: {
                    const _ = panel.ver
                    const d = YuvBridge.histogram(panel.activeSlot, 2)
                    return d && d.max !== undefined ? d.max : "—"
                }
            }

            Item { width: parent.width; height: 8 }
        }
    }
}
