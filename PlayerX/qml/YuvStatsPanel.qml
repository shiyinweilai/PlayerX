import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX 1.0

// ─── YUV 分析右侧栏：直方图统计面板 ───────────────────────────────────
// 风格：专业示波器风格。Y=白、U=蓝、V=红，红色 TV Range 虚线，水平网格。
// 桶数按位深自适应（8bit=256, 10bit=1024）。
// 支持 帧级别 / 块级别 两种统计模式：
//   - 帧级别（默认）：统计整帧数据，随 frameChanged 更新（ver）。
//   - 块级别：统计鼠标悬浮处的像素块（块大小 = YuvBridge.blockSize，顶部菜单
//     "YUV 分析→块大小"设置），随鼠标移动实时刷新（hoverVer）。
//     悬浮坐标由 YuvWindow.qml 的像素悬浮 MouseArea 通过
//     YuvBridge.setHoverPixel() 上报，跨窗口全局共享。
Rectangle {
    id: panel
    color: "#121417"
    anchors.fill: parent

    property int activeSlot: 0
    property int ver: 0
    property int hoverVer: 0
    property int statsMode: 0   // 0=帧级别, 1=块级别, 2=差异总览（仅双路时可用）
    property int diffPlane: 0   // 差异总览通道：0=Y / 1=U / 2=V
    property int viewMode: 0    // 二级 tab：0=直方图 / 1=梯度纹理 / 2=编码参考
    readonly property bool cmpAvailable: YuvBridge.slotCount === 2

    // 差异总览数据（切到该 tab / 帧变化 / 块大小变化 / 通道切换时重新拉取）
    property var diffData: null
    property int diffVer: 0
    function refreshDiffOverview() {
        if (!panel.cmpAvailable) { panel.diffData = null; return }
        panel.diffData = YuvBridge.blockDiffOverview(0, 1, panel.diffPlane)
        panel.diffVer++
    }

    // 根据当前 statsMode 取对应的统计数据（bins/mean/stddev/min/max）
    function statsFor(plane) {
        if (panel.statsMode === 1) {
            if (!YuvBridge.hoverValid()) return null
            return YuvBridge.blockHistogram(YuvBridge.hoverSlot(), plane,
                                             YuvBridge.hoverPixelX(), YuvBridge.hoverPixelY())
        }
        return YuvBridge.histogram(panel.activeSlot, plane)
    }

    Connections {
        target: YuvBridge
        function onFrameChanged(slot) {
            if (slot === panel.activeSlot) panel.ver++
            if (panel.statsMode === 2 && (slot === 0 || slot === 1)) panel.refreshDiffOverview()
        }
        function onFileOpened(slot) { panel.ver++; if (panel.statsMode === 2) panel.refreshDiffOverview() }
        function onSlotCountChanged() {
            panel.ver++
            if (!panel.cmpAvailable && panel.statsMode === 2) panel.statsMode = 0
            if (panel.statsMode === 2) panel.refreshDiffOverview()
        }
        function onHoverChanged() { panel.hoverVer++ }
        function onBlockSizeChanged() { if (panel.statsMode === 2) panel.refreshDiffOverview() }
    }
    onStatsModeChanged: {
        // 切到非帧级别模式时，把二级 tab 重置到"直方图"，避免"梯度纹理/编码参考"
        // 在块级别下显示空白（这两类视图仅帧级别有数据）。
        if (statsMode !== 0) viewMode = 0
        if (statsMode === 2) refreshDiffOverview()
    }
    onDiffPlaneChanged: if (statsMode === 2) refreshDiffOverview()

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

            // ── 帧级别 / 块级别 / 差异总览 切换 tab（差异总览仅双路打开时可用）──
            Row {
                id: modeTabRow
                width: parent.width
                spacing: 4
                readonly property var tabLabels: panel.cmpAvailable ? ["帧级别", "块级别", "差异总览"] : ["帧级别", "块级别"]
                Repeater {
                    model: modeTabRow.tabLabels
                    delegate: Rectangle {
                        required property int index
                        required property string modelData
                        width: (col.width - (modeTabRow.tabLabels.length - 1) * 4) / modeTabRow.tabLabels.length
                        height: 24
                        radius: 4
                        color: panel.statsMode === index ? "#2a3a55" : "#1e1e26"
                        border.color: panel.statsMode === index ? "#3a6fd8" : "#2a2a32"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            color: panel.statsMode === index ? "#ffffff" : "#a0a4ac"
                            font.pixelSize: 11
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.statsMode = index
                        }
                    }
                }
            }

            // 块级别模式下：提示当前悬浮的块坐标 / 无悬浮时的引导文案
            Text {
                width: parent.width
                visible: panel.statsMode === 1
                text: {
                    const _ = panel.hoverVer
                    const __ = YuvBridge.blockSize
                    if (!YuvBridge.hoverValid()) return "将鼠标移动到画面上查看块级统计"
                    const bs = YuvBridge.blockSize
                    const bx = Math.floor(YuvBridge.hoverPixelX() / bs) * bs
                    const by = Math.floor(YuvBridge.hoverPixelY() / bs) * bs
                    return "块 [" + bx + "," + by + "] ~ [" + (bx + bs - 1) + "," + (by + bs - 1) + "]（" + bs + "×" + bs + "）"
                }
                color: "#9aa0a6"; font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            // ── 差异总览（整帧块级差异热力图，快速定位第一个不同的块）──
            Column {
                width: parent.width
                visible: panel.statsMode === 2
                spacing: 10

                // Y/U/V 通道切换（决定按哪个通道计算差异）
                Row {
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: ["Y", "U", "V"]
                        delegate: Rectangle {
                            required property int index
                            required property string modelData
                            width: (col.width - 8) / 3
                            height: 22
                            radius: 4
                            color: panel.diffPlane === index ? "#2a3a55" : "#1e1e26"
                            border.color: panel.diffPlane === index ? "#3a6fd8" : "#2a2a32"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: modelData
                                color: panel.diffPlane === index ? "#ffffff" : "#a0a4ac"
                                font.pixelSize: 11
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: panel.diffPlane = index
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: {
                        const _ = panel.diffVer
                        const d = panel.diffData
                        if (!d || !d.cols) return "暂无差异数据"
                        if (d.firstDiffCol < 0) return "两路完全一致（当前通道无差异）"
                        const bs = d.blockSize
                        return "首个差异块 [" + d.firstDiffCol + "," + d.firstDiffRow + "]" +
                               "（像素坐标约 " + (d.firstDiffCol * bs) + "," + (d.firstDiffRow * bs) + "）" +
                               "  最大差异 " + Number(d.maxDiff).toFixed(1)
                    }
                    color: "#9aa0a6"; font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }

                // 热力图 Canvas：cols×rows 网格，每格颜色按 |avgDiff| 归一化到 maxDiff
                Canvas {
                    id: diffCanvas
                    width: parent.width
                    height: {
                        const d = panel.diffData
                        if (!d || !d.cols || !d.rows) return 160
                        const w = parent.width
                        const cellW = w / d.cols
                        return Math.max(80, Math.min(420, cellW * d.rows))
                    }
                    property real hoverFx: -1
                    property real hoverFy: -1

                    Connections {
                        target: panel
                        function onDiffVerChanged() { diffCanvas.requestPaint() }
                    }

                    onPaint: {
                        const ctx = getContext("2d")
                        const w = diffCanvas.width
                        const h = diffCanvas.height
                        ctx.clearRect(0, 0, w, h)
                        ctx.fillStyle = "#0c0d10"
                        ctx.fillRect(0, 0, w, h)

                        const d = panel.diffData
                        if (!d || !d.cols || !d.rows) {
                            ctx.fillStyle = "#5a5f66"
                            ctx.font = "10px sans-serif"
                            ctx.fillText("需打开两路 YUV 才能查看差异总览", 8, h / 2)
                            return
                        }
                        const cols = d.cols, rows = d.rows
                        const vals = d.values
                        const maxDiff = Math.max(1e-6, Number(d.maxDiff))
                        const cellW = w / cols
                        const cellH = h / rows
                        for (let ry = 0; ry < rows; ry++) {
                            for (let rx = 0; rx < cols; rx++) {
                                const v = Number(vals[ry * cols + rx]) || 0
                                const t = Math.max(0, Math.min(1, v / maxDiff))
                                // 蓝(无差异) → 黄 → 红(差异大)，直观区分"完全一致"与"有差异"区域
                                let r, g, b
                                if (t < 0.5) {
                                    const k = t / 0.5
                                    r = Math.round(20 + k * 200); g = Math.round(40 + k * 170); b = Math.round(70 - k * 40)
                                } else {
                                    const k = (t - 0.5) / 0.5
                                    r = Math.round(220 + k * 35); g = Math.round(210 - k * 180); b = Math.round(30 - k * 20)
                                }
                                ctx.fillStyle = "rgb(" + r + "," + g + "," + b + ")"
                                ctx.fillRect(rx * cellW, ry * cellH, Math.ceil(cellW), Math.ceil(cellH))
                            }
                        }

                        // 首个差异块描边标记
                        if (d.firstDiffCol >= 0) {
                            ctx.strokeStyle = "#ffffff"
                            ctx.lineWidth = 1.5
                            ctx.strokeRect(d.firstDiffCol * cellW + 0.5, d.firstDiffRow * cellH + 0.5,
                                           Math.max(1, cellW - 1), Math.max(1, cellH - 1))
                        }

                        // hover 高亮
                        if (diffCanvas.hoverFx >= 0 && diffCanvas.hoverFy >= 0) {
                            const hc = Math.min(cols - 1, Math.floor(diffCanvas.hoverFx / cellW))
                            const hr = Math.min(rows - 1, Math.floor(diffCanvas.hoverFy / cellH))
                            ctx.strokeStyle = "#3a6fd8"
                            ctx.lineWidth = 2
                            ctx.strokeRect(hc * cellW + 1, hr * cellH + 1,
                                           Math.max(1, cellW - 2), Math.max(1, cellH - 2))
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPositionChanged: function(mouse) {
                            diffCanvas.hoverFx = mouse.x
                            diffCanvas.hoverFy = mouse.y
                            diffCanvas.requestPaint()
                        }
                        onExited: {
                            diffCanvas.hoverFx = -1
                            diffCanvas.hoverFy = -1
                            diffCanvas.requestPaint()
                        }
                        onClicked: function(mouse) {
                            const d = panel.diffData
                            if (!d || !d.cols || !d.rows) return
                            const cellW = diffCanvas.width / d.cols
                            const cellH = diffCanvas.height / d.rows
                            const cx = Math.min(d.cols - 1, Math.floor(mouse.x / cellW))
                            const cy = Math.min(d.rows - 1, Math.floor(mouse.y / cellH))
                            const bs = d.blockSize
                            // 通知左侧对比浮窗跳转并固定到该块（块中心像素坐标）
                            YuvBridge.requestPixelInspect(cx * bs + Math.floor(bs / 2), cy * bs + Math.floor(bs / 2))
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: "深蓝=一致 · 黄红=差异较大 · 白框=首个差异块位置 · 点击任意块可在左侧打开该处的像素对比浮窗。"
                    color: "#6a6f76"; font.pixelSize: 10
                    wrapMode: Text.WordWrap
                }
            }

            // ── slot 选择 tabs（多路时，仅帧级别模式下有意义）──
            Row {
                width: parent.width
                visible: YuvBridge.slotCount > 1 && panel.statsMode === 0
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

            // ── 二级 tabs：帧级别 / 块级别 都显示，差异总览（statsMode === 2）独立处理 ──
            //   三视图互斥，避免堆叠遮挡：
            //     0=直方图：Y/U/V 直方图 + 基础统计 + 方差/对比度（帧/块级别都可用）
            //     1=梯度纹理：Y/U/V 全方向梯度 + Laplacian + Tenengrad（仅帧级别有意义）
            //     2=编码参考：基于 Y 平面的编码指导（仅帧级别有意义；块级别下自动隐藏）
            Row {
                id: viewTabRow
                width: parent.width
                visible: panel.statsMode !== 2
                spacing: 4
                readonly property var tabLabels: ["直方图", "梯度纹理", "编码参考"]
                Repeater {
                    model: viewTabRow.tabLabels
                    delegate: Rectangle {
                        required property int index
                        required property string modelData
                        width: (col.width - (viewTabRow.tabLabels.length - 1) * 4) / viewTabRow.tabLabels.length
                        height: 22
                        radius: 4
                        color: panel.viewMode === index ? "#2a3a55" : "#1e1e26"
                        border.color: panel.viewMode === index ? "#3a6fd8" : "#2a2a32"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            color: panel.viewMode === index ? "#ffffff" : "#a0a4ac"
                            font.pixelSize: 11
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.viewMode = index
                        }
                    }
                }
            }

            // ── 直方图视图（viewMode === 0）──
            //   帧级别与块级别都展示：直方图是基础统计，无论哪个模式都该可见。
            //   spacing 较大以便"方差/对比度"行与下一通道标题之间留出呼吸空间，
            //   避免在小窗口下被相邻通道标题遮挡。
            //   每个通道包成独立卡片（与"梯度纹理"视图一致），便于一眼区分通道，
            //   并把数值列做右对齐、整体呼吸感统一。
            Column {
                width: parent.width
                visible: panel.statsMode !== 2 && panel.viewMode === 0
                spacing: 16

                // 单平面直方图卡片：暗色背景 + 圆角 + 通道色圆点 + 居中布局
                component HistCard: Rectangle {
                    id: histCard
                    width: parent.width
                    color: "#1a1d22"
                    radius: 4
                    border.color: "#2a2e33"
                    border.width: 1
                    height: histCardCol.implicitHeight + 12

                    property string title: ""
                    property color drawColor: "#ffffff"
                    property int plane: 0

                    Column {
                        id: histCardCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 6
                        spacing: 3

                        // 标题行：色点 + 通道名
                        Row {
                            width: parent.width
                            spacing: 6
                            Rectangle {
                                width: 8; height: 8; radius: 2
                                anchors.verticalCenter: parent.verticalCenter
                                color: histCard.drawColor
                            }
                            Text {
                                text: histCard.title
                                color: "#ffffff"
                                font.pixelSize: 12
                                font.bold: true
                            }
                        }

                        // 直方图绘图（实际柱状图绘制交由 HistItem 处理，这里仅作占位容器，
                        // 真正的 Canvas/Canvas 绘制走嵌入的 HistItem）
                        HistItem {
                            id: histItem
                            width: parent.width
                            title: histCard.title
                            drawColor: histCard.drawColor
                            plane: histCard.plane
                            // 直方图绘图区固定高度；HistItem 内部 Canvas 自适应宽度
                            height: 180
                            // 去掉 HistItem 自身顶部标题（标题已由外层卡片绘制）
                            showInlineTitle: false
                            // 去掉 HistItem 自身底部统计文本（已挪到下方"统计行"）
                            showInlineStats: false
                            showInlineVariance: false
                        }

                        // 基础统计行：表格式呈现（表头行 + 数值行，列对齐）
                        GridLayout {
                            width: parent.width
                            columns: 4
                            columnSpacing: 4
                            rowSpacing: 2
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "均值"; color: "#8a8f96"; font.pixelSize: 10 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "标准差"; color: "#8a8f96"; font.pixelSize: 10 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "最小"; color: "#8a8f96"; font.pixelSize: 10 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "最大"; color: "#8a8f96"; font.pixelSize: 10 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: histItem.mean; color: "#cccccc"; font.pixelSize: 12; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: histItem.stdDev; color: "#cccccc"; font.pixelSize: 12; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: histItem.minVal; color: "#cccccc"; font.pixelSize: 12; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: histItem.maxVal; color: "#cccccc"; font.pixelSize: 12; font.family: "Monospace" }
                        }
                        GridLayout {
                            width: parent.width
                            columns: panel.statsMode === 0 && histItem.varianceVal !== "—" ? 3 : 1
                            columnSpacing: 4
                            rowSpacing: 2
                            Text {
                                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                text: "极差"; color: "#8a8f96"; font.pixelSize: 10
                            }
                            Text {
                                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                visible: panel.statsMode === 0 && histItem.varianceVal !== "—"
                                text: "方差"; color: "#8a8f96"; font.pixelSize: 10
                            }
                            Text {
                                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                visible: panel.statsMode === 0 && histItem.varianceVal !== "—"
                                text: "对比度"; color: "#8a8f96"; font.pixelSize: 10
                            }
                            Text {
                                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                text: histItem.rangeVal; color: "#cccccc"; font.pixelSize: 12; font.family: "Monospace"
                            }
                            Text {
                                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                visible: panel.statsMode === 0 && histItem.varianceVal !== "—"
                                text: histItem.varianceVal; color: "#cccccc"; font.pixelSize: 12; font.family: "Monospace"
                            }
                            Text {
                                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                visible: panel.statsMode === 0 && histItem.varianceVal !== "—"
                                text: histItem.rangeVal; color: "#cccccc"; font.pixelSize: 12; font.family: "Monospace"
                            }
                        }
                    }
                }

                HistCard {
                    title: "Y 直方图"
                    drawColor: "#ffffff"
                    plane: 0
                }
                HistCard {
                    title: "U 直方图"
                    drawColor: "#42A5FF"
                    plane: 1
                }
                HistCard {
                    title: "V 直方图"
                    drawColor: "#FF4888"
                    plane: 2
                }
            }

            // Y / U / V 直方图（已并入上方"直方图视图" Column；下方是历史兼容占位，已不再渲染）

            // ── 梯度纹理视图（viewMode === 1）──
            //   单卡渲染三平面：每个平面一张"指标卡片"，整齐对齐便于横向对比。
            //   复用 HistItem 的 planeStatsData 派生（仅帧级别下有数据；
            //   块级别下数据缺失，因此该视图仅帧级别生效）。
            Column {
                width: parent.width
                visible: panel.statsMode === 0 && panel.viewMode === 1
                spacing: 10

                // 顶部说明
                Text {
                    width: parent.width
                    text: "四方向一阶差分 + Laplacian 锐利度 + Sobel/Tenengrad 纹理复杂度。" +
                          "仅基于 Y/U/V 全帧扫描得出，与编码器的 CU 划分 / QP 决策正相关。"
                    color: "#9aa0a6"; font.pixelSize: 12
                    wrapMode: Text.WordWrap
                }

                // 复用一个 component：单平面梯度卡片
                component PlaneGradientCard: Rectangle {
                    id: gradCard
                    width: parent.width
                    color: "#1a1d22"
                    radius: 4
                    border.color: "#2a2e33"
                    border.width: 1
                    height: planeCardCol.implicitHeight + 16

                    property string planeLabel: ""
                    property color planeColor: "#ffffff"
                    property int planeIndex: 0

                    readonly property var ps: {
                        const _ = panel.ver
                        if (YuvBridge.slotCount <= 0) return null
                        return YuvBridge.planeStats(panel.activeSlot, gradCard.planeIndex)
                    }
                    readonly property string mean: {
                        const s = gradCard.ps
                        if (!s) return "—"
                        if (s.mean === undefined) return "—"
                        return Number(s.mean).toFixed(1)
                    }
                    readonly property string stdDev: {
                        const s = gradCard.ps
                        if (!s || s.stddev === undefined) return "—"
                        return Number(s.stddev).toFixed(1)
                    }
                    readonly property string variance: {
                        const s = gradCard.ps
                        if (!s || s.variance === undefined) return "—"
                        return Number(s.variance).toFixed(1)
                    }
                    readonly property string rangeV: {
                        const s = gradCard.ps
                        if (!s || s.range === undefined) return "—"
                        return String(s.range)
                    }
                    readonly property string gH: {
                        const s = gradCard.ps
                        if (!s || s.gradHorizMean === undefined) return "—"
                        return Number(s.gradHorizMean).toFixed(2)
                    }
                    readonly property string gV: {
                        const s = gradCard.ps
                        if (!s || s.gradVertMean === undefined) return "—"
                        return Number(s.gradVertMean).toFixed(2)
                    }
                    readonly property string g45: {
                        const s = gradCard.ps
                        if (!s || s.gradDiag45Mean === undefined) return "—"
                        return Number(s.gradDiag45Mean).toFixed(2)
                    }
                    readonly property string g135: {
                        const s = gradCard.ps
                        if (!s || s.gradDiag135Mean === undefined) return "—"
                        return Number(s.gradDiag135Mean).toFixed(2)
                    }
                    readonly property string gMean: {
                        const s = gradCard.ps
                        if (!s || s.gradMean === undefined) return "—"
                        return Number(s.gradMean).toFixed(2)
                    }
                    readonly property string lap: {
                        const s = gradCard.ps
                        if (!s || s.laplacianEnergy === undefined) return "—"
                        return Number(s.laplacianEnergy).toFixed(1)
                    }
                    readonly property string tg: {
                        const s = gradCard.ps
                        if (!s || s.tenengrad === undefined) return "—"
                        return Number(s.tenengrad).toFixed(1)
                    }

                    Column {
                        id: planeCardCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 8
                        spacing: 4

                        Row {
                            width: parent.width
                            spacing: 6
                            Rectangle {
                                width: 8; height: 8; radius: 2
                                anchors.verticalCenter: parent.verticalCenter
                                color: gradCard.planeColor
                            }
                            Text {
                                text: gradCard.planeLabel + " 平面"
                                color: "#ffffff"
                                font.pixelSize: 15
                                font.bold: true
                            }
                        }

                        // 基础统计行：表格式呈现（一行表头 + 一行数值，列对齐）
                        GridLayout {
                            width: parent.width
                            columns: 4
                            columnSpacing: 4
                            rowSpacing: 2
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "均值"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "标准差"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "极差"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "方差"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.mean; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.stdDev; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.rangeV; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.variance; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                        }

                        // 梯度 / 纹理指标：同样按"表头行 + 数值行"的表格样式对齐呈现
                        Text {
                            width: parent.width
                            text: "▾ 梯度（方向幅值均值）"
                            color: gradCard.planeColor
                            font.pixelSize: 12
                            font.bold: true
                        }
                        GridLayout {
                            width: parent.width
                            columns: 5
                            columnSpacing: 4
                            rowSpacing: 2
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "水平"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "垂直"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "45°"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "135°"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "平均"; color: gradCard.planeColor; font.pixelSize: 11; font.bold: true }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.gH; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.gV; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.g45; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.g135; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.gMean; color: gradCard.planeColor; font.pixelSize: 13; font.family: "Monospace"; font.bold: true }
                        }

                        // 锐利度 / 纹理复杂度
                        Text {
                            width: parent.width
                            text: "▾ 锐利度 / 纹理复杂度"
                            color: gradCard.planeColor
                            font.pixelSize: 12
                            font.bold: true
                        }
                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: 4
                            rowSpacing: 2
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "Laplacian能量"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: "Tenengrad"; color: "#8a8f96"; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.lap; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: gradCard.tg; color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace" }
                        }
                    }
                }

                PlaneGradientCard {
                    planeLabel: "Y"
                    planeColor: "#ffffff"
                    planeIndex: 0
                }
                PlaneGradientCard {
                    planeLabel: "U"
                    planeColor: "#42A5FF"
                    planeIndex: 1
                }
                PlaneGradientCard {
                    planeLabel: "V"
                    planeColor: "#FF4888"
                    planeIndex: 2
                }
            }

            // ── 编码参考视图（viewMode === 2）──
            //   阈值基于经验值，参考 H.264/HEVC/VVC 编码器内部的纹理能量判断逻辑；
            //   仅作"参考性提示"，不替代实际编码器内部的率失真优化决策。
            //   基于 Y 平面梯度/纹理数据（仅帧级别有意义）；块级别模式下不显示。
            Column {
                width: parent.width
                visible: panel.statsMode === 0 && panel.viewMode === 2
                spacing: 8

                Rectangle {
                    width: parent.width
                    color: "#1a1d22"
                    radius: 4
                    border.color: "#2a2e33"
                    border.width: 1
                    height: codingHintCol.implicitHeight + 16

                    Column {
                        id: codingHintCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 8
                        spacing: 4

                        Row {
                            width: parent.width
                            spacing: 6
                            Rectangle {
                                width: 6; height: 6; radius: 3
                                anchors.verticalCenter: parent.verticalCenter
                                color: "#3a6fd8"
                            }
                            Text {
                                text: "编码参考（基于 Y 平面）"
                                color: "#bbbbbb"
                                font.pixelSize: 13
                                font.bold: true
                            }
                        }

                        Text {
                            width: parent.width
                            text: {
                                const _ = panel.ver
                                const s = YuvBridge.planeStats(panel.activeSlot, 0)
                                if (!s || s.gradMean === undefined) return "暂无数据"
                                const gm = Number(s.gradMean)
                                const lap = Number(s.laplacianEnergy)
                                const ten = Number(s.tenengrad)
                                // 纹理复杂度（决定 CU 划分倾向）
                                let complexity
                                if (gm < 3)        complexity = "平坦（适合大块量化）"
                                else if (gm < 8)   complexity = "中等（默认编码参数即可）"
                                else               complexity = "复杂（建议更细 CU 划分 / 提高 QP 容差）"
                                // 清晰度（决定是否需要预处理锐化 / 是否失焦）
                                let sharpness
                                if (lap < 100)        sharpness = "较模糊"
                                else if (lap < 1000)  sharpness = "一般"
                                else                  sharpness = "锐利"
                                return "纹理：" + complexity +
                                       "\n清晰度：" + sharpness +
                                       "（Laplacian " + lap.toFixed(1) + "）" +
                                       "\n综合（Tenengrad）：" + ten.toFixed(1) +
                                       "（值越高纹理越丰富，编码需分配更多码率）"
                            }
                            color: "#bbbbbb"
                            font.pixelSize: 13
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                // 阈值说明（让用户理解阈值来源）
                Rectangle {
                    width: parent.width
                    color: "#16181c"
                    radius: 4
                    border.color: "#25282d"
                    border.width: 1
                    height: codingThreshCol.implicitHeight + 16

                    Column {
                        id: codingThreshCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 8
                        spacing: 3

                        Text {
                            text: "阈值说明"
                            color: "#bbbbbb"; font.pixelSize: 13; font.bold: true
                        }
                        Text {
                            width: parent.width
                            text: "纹理（平均梯度 ｜g｜）：< 3 平坦 / 3~8 中等 / ≥ 8 复杂\n" +
                                  "清晰度（Laplacian 能量）：< 100 较模糊 / 100~1000 一般 / ≥ 1000 锐利\n" +
                                  "综合（Tenengrad）：越大代表纹理越丰富，编码需分配更多码率"
                            color: "#9aa0a6"; font.pixelSize: 12
                            wrapMode: Text.WordWrap
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

                // 可选：让外层卡片接管标题/统计文本时关闭内部展示
                property bool showInlineTitle: true
                property bool showInlineStats: true
                property bool showInlineVariance: true

                readonly property color bgColor: "#121417"
                readonly property color gridColor: "#2c3036"
                readonly property color thresholdColor: "#ff3a3a"
                readonly property color textColor: "#bbbbbb"

                // 当前使用的统计数据（帧级别 or 块级别，取决于 panel.statsMode）
                readonly property var statsData: {
                    const _ = panel.ver
                    if (panel.statsMode === 1) {
                        const __ = panel.hoverVer
                        return panel.statsFor(histRoot.plane)
                    }
                    return YuvBridge.histogram(panel.activeSlot, histRoot.plane)
                }

                // 帧级梯度 / 纹理指标，仅帧级别模式有数据。
                // 与直方图共用同一个"frameChanged"信号触发的 ver 计数。
                readonly property var planeStatsData: {
                    const _ = panel.ver
                    if (panel.statsMode !== 0) return null
                    if (YuvBridge.slotCount <= 0) return null
                    return YuvBridge.planeStats(panel.activeSlot, histRoot.plane)
                }

                // 直方图 bins 数据（来自 statsData.bins）
                property var histData: {
                    const d = histRoot.statsData
                    if (!d || !d.bins) return []
                    // 显式转为 JS 纯数字数组（QVariantList 在 JS 里访问可能成
                    // QVariant 对象，直接 Number() 转一下避免绘制时 NaN）
                    const r = []
                    const src = d.bins
                    for (let i = 0; i < src.length; i++) r.push(Number(src[i]))
                    return r
                }
                onHistDataChanged: cv.requestPaint()

                readonly property string mean: {
                    const d = histRoot.statsData
                    return (d && d.mean !== undefined) ? Number(d.mean).toFixed(1) : "—"
                }
                readonly property string stdDev: {
                    const d = histRoot.statsData
                    return (d && d.stddev !== undefined) ? Number(d.stddev).toFixed(1) : "—"
                }
                readonly property var minVal: {
                    const d = histRoot.statsData
                    return (d && d.min !== undefined) ? d.min : "—"
                }
                readonly property var maxVal: {
                    const d = histRoot.statsData
                    return (d && d.max !== undefined) ? d.max : "—"
                }
                // 方差与极差：直方图数据里已经返回了 variance / range，
                // 在帧级别模式与块级别模式都给出（块级别则体现该块的方差与动态范围）。
                readonly property var varianceVal: {
                    const d = histRoot.statsData
                    return (d && d.variance !== undefined) ? Number(d.variance).toFixed(1) : "—"
                }
                readonly property var rangeVal: {
                    const d = histRoot.statsData
                    return (d && d.range !== undefined) ? d.range : "—"
                }

                // ── 梯度 / 纹理 派生（仅帧级别，来源于 planeStatsData） ──
                readonly property string gradHoriz: {
                    const s = histRoot.planeStatsData
                    return (s && s.gradHorizMean !== undefined) ? Number(s.gradHorizMean).toFixed(2) : "—"
                }
                readonly property string gradVert: {
                    const s = histRoot.planeStatsData
                    return (s && s.gradVertMean !== undefined) ? Number(s.gradVertMean).toFixed(2) : "—"
                }
                readonly property string grad45: {
                    const s = histRoot.planeStatsData
                    return (s && s.gradDiag45Mean !== undefined) ? Number(s.gradDiag45Mean).toFixed(2) : "—"
                }
                readonly property string grad135: {
                    const s = histRoot.planeStatsData
                    return (s && s.gradDiag135Mean !== undefined) ? Number(s.gradDiag135Mean).toFixed(2) : "—"
                }
                readonly property string gradMean: {
                    const s = histRoot.planeStatsData
                    return (s && s.gradMean !== undefined) ? Number(s.gradMean).toFixed(2) : "—"
                }
                readonly property string lapEnergy: {
                    const s = histRoot.planeStatsData
                    return (s && s.laplacianEnergy !== undefined) ? Number(s.laplacianEnergy).toFixed(1) : "—"
                }
                readonly property string tenengrad: {
                    const s = histRoot.planeStatsData
                    return (s && s.tenengrad !== undefined) ? Number(s.tenengrad).toFixed(1) : "—"
                }

                // 标题行：色块 + 标题
                Row {
                    width: parent.width
                    spacing: 6
                    visible: histRoot.showInlineTitle
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

                        // 3. 取直方图数据（帧级别 / 块级别，取决于 panel.statsMode）
                        const histObj = panel.statsFor(histRoot.plane)
                        const rawBins = histObj && histObj.bins ? histObj.bins : []
                        const N = rawBins.length
                        if (N === 0) {
                            ctx.fillStyle = "#5a5f66"
                            ctx.font = "10px sans-serif"
                            ctx.fillText(panel.statsMode === 1 ? "将鼠标移到画面上" : "无数据", 8, h / 2)
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

                            // min/max 数字标签往两条竖线外侧绘制（min 标签靠左线左侧右对齐，
                            // max 标签靠右线右侧左对齐），避免两条线靠得很近时文字互相重叠
                            ctx.fillStyle = "#ff7070"
                            ctx.font = "9px sans-serif"
                            ctx.textAlign = "right"
                            ctx.fillText(lo.toString(), xMin - 3, 9)
                            ctx.textAlign = "left"
                            ctx.fillText(hi.toString(), xMax + 3, 9)
                            ctx.textAlign = "left"
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

                // 底部统计文本（帧级别 / 块级别 共用）
                Text {
                    width: parent.width
                    visible: histRoot.showInlineStats
                    text: "均值 " + histRoot.mean +
                          "  标准差 " + histRoot.stdDev +
                          "  最小 " + histRoot.minVal +
                          "  最大 " + histRoot.maxVal +
                          (histRoot.rangeVal !== "—"
                              ? "  极差 " + histRoot.rangeVal
                              : "")
                    color: histRoot.textColor
                    font.pixelSize: 12
                    font.family: "Monospace"
                }

                // 方差 + 对比度（C = max-min），仅帧级别展示
                //   · 方差反映整体能量分布，离散度越高纹理越复杂
                //   · 对比度衡量画面动态范围，是 H.264/HEVC 决定码率分配的关键参考
                Text {
                    width: parent.width
                    visible: histRoot.showInlineVariance && panel.statsMode === 0 && histRoot.varianceVal !== "—"
                    text: "方差 " + histRoot.varianceVal +
                          "  对比度 " + histRoot.rangeVal
                    color: "#9aa0a6"
                    font.pixelSize: 11
                    font.family: "Monospace"
                    // 给本行下方留点间距，避免与下一通道"X 直方图"标题贴在一起
                    //（尤其是小窗宽下，spacing 也会被压缩）。
                    bottomPadding: 6
                }
            }

            // Y / U / V 直方图（已挪到上方 viewMode===0 的"直方图视图" Column 中渲染）

            Item { width: parent.width; height: 8 }
        }
    }
}
