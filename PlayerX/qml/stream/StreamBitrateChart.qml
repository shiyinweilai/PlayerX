// StreamBitrateChart.qml — 底部向上展开的码率曲线面板
//
// 由 StreamView.qml GOP 栏左侧「码率」按钮触发展开（2026-09-16）：
//   · floating = false（默认，挤占模式）→ StreamView 的 bitrateChartHost
//     高度 180，mainDisplay 底部上移让位；本面板实底 #141418 填满 host。
//   · floating = true（悬浮模式）→ host 高度 0，视频区不让位；本面板以
//     host 底边（GOP 栏顶）为基线向上悬浮 180px，半透明 #f0121417 圆角浮层。
//   两种模式内容与数据源完全一致，由内部 Loader 复用同一份内容组件。
//
// 图表内容（自 StreamInfoCard.qml 原「码率」Tab 迁入并加宽）：
//   · 整文件码率采样（≤200 桶，Mbps 折线 + 渐变填充）
//   · 当前帧黄色指示线 + 顶部三角，随播放移动；头部实时桶码率读数
//   · 点击图表任意位置跳转对应帧（与 GOP 结构条一致）
//   · 头部按钮：◫/▣ 悬浮⇄挤占模式切换、× 关闭
//
// 完全独立模块：不引用 StreamInfoCard / StreamView 内部状态，只依赖
// StreamBridge 公开接口（frameList / streamInfo / currentFrame / gotoFrame）。

import QtQuick
import QtQuick.Controls

Item {
    id: chartRoot

    // 外部属性：slot 跟随 StreamView.effectiveSlot
    property int slot: 0
    property bool open: false      // 是否展开（由 GOP 栏「码率」按钮控制）
    property bool floating: false  // true=悬浮画面上层；false=挤占（视频上移让位）

    // 面板高度（唯一数据源）：顶部把手上下拖拽调整，宿主高度绑定它。
    // 默认 200，与参考层级面板默认高度一致。
    property int panelHeight: 200
    readonly property int panelMinH: 120
    readonly property int panelMaxH: 640

    // 内部交互请求：open/floating 归 StreamView 所有，改状态走信号回调外层
    signal requestClose()
    signal requestToggleMode()

    // ── 挤占模式容器：实底填满 host（host 高度=panelHeight，视频已让位）──
    Rectangle {
        id: dockedBox
        visible: chartRoot.open && !chartRoot.floating
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: chartRoot.panelHeight
        color: "#141418"

        // 顶部分隔线（与 GOP 栏上下呼应）
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: "#2a2e33"
        }

        Loader {
            anchors.fill: parent
            active: chartRoot.open && !chartRoot.floating
            sourceComponent: chartContentComp
        }
    }

    // ── 悬浮模式容器：以 host 底边为基线向上悬浮，圆角半透明 ──
    Rectangle {
        id: floatBox
        visible: chartRoot.open && chartRoot.floating
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 4
        height: chartRoot.panelHeight
        radius: 8
        color: "#f0121417"
        border.color: "#2a2e33"; border.width: 1

        Loader {
            anchors.fill: parent
            active: chartRoot.open && chartRoot.floating
            sourceComponent: chartContentComp
        }
    }

    // ── 顶部拖拽把手：上下拖动调整面板高度（120~640），双击复位 200 ──
    // 用「屏幕全局坐标」计算位移：把手自身会随高度移动，若用 mouse.y（局部）
    // 会形成正反馈回路导致抖动、指针脱手，改用 mapToGlobal 后把手移动被抵消。
    Rectangle {
        id: resizeHandle
        readonly property bool forFloat: chartRoot.floating
        x: forFloat ? 12 : 0
        width: forFloat ? (chartRoot.width - 24) : chartRoot.width
        height: 10
        y: {
            const box = forFloat ? floatBox : dockedBox
            return box.y - 4
        }
        visible: chartRoot.open
        color: resizeMa.pressed ? "#42A5FF"
                                : (resizeMa.containsMouse ? "#2a3f5a" : "transparent")
        z: 30
        Text {
            anchors.centerIn: parent
            visible: resizeMa.pressed
            text: chartRoot.panelHeight + " px"
            color: "#42A5FF"; font.pixelSize: 8
        }
        MouseArea {
            id: resizeMa
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            cursorShape: pressed ? Qt.SizeVerCursor
                                 : (containsMouse ? Qt.SizeVerCursor : Qt.ArrowCursor)
            property real startGlobalY: 0
            property int startH: 0
            onPressed: {
                startGlobalY = mapToGlobal(mouse.x, mouse.y).y
                startH = chartRoot.panelHeight
                mouse.accepted = true
            }
            onPositionChanged: {
                if (!pressed) return
                // 向上拖动（dy<0）= 变高：面板底边固定，顶边随之上移
                let nh = startH - (mapToGlobal(mouse.x, mouse.y).y - startGlobalY)
                nh = Math.round(nh / 2) * 2   // 量化到 2px，减少视频区重排
                chartRoot.panelHeight = Math.max(chartRoot.panelMinH,
                                                 Math.min(chartRoot.panelMaxH, nh))
            }
            onDoubleClicked: chartRoot.panelHeight = 200
        }
    }

    // 内容组件：两种模式共用的数据源 + 图表主体
    Component {
        id: chartContentComp
        Item {
            id: chartPanel
            required property int slot
            property int ver: 0
            slot: chartRoot.slot

            // ── 数据刷新信号（2026-09-16 性能修复：信号分级）──
            // ver（帧级）只驱动画布重绘（游标）；structVer（文件级）才重取
            // frameList / 重算码率采样。265 播放时每帧不再整文件重采样。
            property int structVer: 0
            Connections {
                target: StreamBridge
                function onCurrentFrameChanged(changedSlot) { chartPanel.ver++ }
                function onFileOpened(openedSlot) {
                    if (openedSlot === chartPanel.slot) { chartPanel.ver++; chartPanel.structVer++ }
                }
                function onFileClosed(closedSlot) {
                    if (closedSlot === chartPanel.slot) { chartPanel.ver++; chartPanel.structVer++ }
                }
                function onSlotCountChanged() { chartPanel.ver++; chartPanel.structVer++ }
            }

            // ── 数据属性 ──
            readonly property bool slotActive: { const _ = ver; return StreamBridge.hasFile(slot) }
            readonly property var  info:      { const _ = structVer; return slotActive ? StreamBridge.streamInfo(slot) : ({}) }
            readonly property int  curFrame:  { const _ = ver; return slotActive ? StreamBridge.currentFrame(slot) : 0 }
            // 帧列表缓存（文件级）：播放中每帧不重拷
            property var frameCache: []
            onStructVerChanged: {
                frameCache = slotActive ? StreamBridge.frameList(slot) : []
            }
            // 初始化兜底：面板展开时文件已打开则主动重取一次
            Component.onCompleted: {
                if (StreamBridge.hasFile(slot)) {
                    frameCache = StreamBridge.frameList(slot)
                }
            }
            readonly property var  frameList: frameCache
            // 码率采样（Mbps）：整文件每桶平均码率，≤200 桶（文件级，播放中不重算）
            readonly property var bitrateSamples: {
                const _ = chartPanel.structVer
                if (!frameCache || frameCache.length === 0) return []
                const out = []
                const n = frameCache.length
                const bucket = Math.max(1, Math.floor(n / 200))
                for (let i = 0; i < n; i += bucket) {
                    let sumBytes = 0, cnt = 0
                    for (let j = i; j < Math.min(i + bucket, n); ++j) {
                        sumBytes += Number(frameCache[j].sizeBytes)
                        cnt++
                    }
                    const fps = Number(info.fps) > 0 ? Number(info.fps) : 30
                    const sec = cnt / fps
                    out.push(sec > 0 ? (sumBytes * 8.0 / sec / 1e6) : 0)
                }
                return out
            }
            // 当前帧所在采样桶的码率（Mbps）：头部实时读数（依赖帧级 curFrame）
            readonly property real curBucketMbps: {
                const _ = ver
                const arr = bitrateSamples
                if (!arr || arr.length === 0 || !frameCache || frameCache.length === 0) return 0
                const bucket = Math.max(1, Math.floor(frameCache.length / 200))
                const idx = Math.min(arr.length - 1, Math.floor(curFrame / bucket))
                return arr[idx] || 0
            }

            Column {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6

                // ── 头部：标题 + 实时读数 + 模式切换 + 关闭（Item 锚定布局）──
                Item {
                    width: parent.width
                    height: 20

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "码率曲线 (Mbps)"
                        color: "#bbbbbb"; font.pixelSize: 12; font.bold: true
                    }
                    Text {
                        id: curMbpsText
                        anchors.right: modeBtn.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            const _ = chartPanel.ver
                            return chartPanel.slotActive
                                   ? "当前 " + chartPanel.curBucketMbps.toFixed(2) + " Mbps"
                                   : "当前 —"
                        }
                        color: "#FFC857"; font.pixelSize: 10
                        font.family: "Monospace"
                    }
                    // 模式切换按钮：悬浮 ⇄ 挤占（icon-only，悬浮预览 tooltip）
                    Rectangle {
                        id: modeBtn
                        anchors.right: closeBtn.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22
                        radius: 4
                        color: modeMa.pressed ? "#2a3f5a" : "#1a1d22"
                        border.color: "#2a2e33"; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: chartRoot.floating ? "◫" : "▣"
                            color: "#9aa0a6"; font.pixelSize: 12
                        }
                        MouseArea {
                            id: modeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: chartRoot.requestToggleMode()
                            ToolTip.visible: containsMouse
                            ToolTip.text: chartRoot.floating
                                           ? "切换为挤占模式（视频上移让位）"
                                           : "切换为悬浮模式（浮于画面上层）"
                        }
                    }
                    // 关闭按钮
                    Rectangle {
                        id: closeBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22
                        radius: 4
                        color: closeMa.pressed ? "#2a3f5a" : "#1a1d22"
                        border.color: "#2a2e33"; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "×"
                            color: "#9aa0a6"; font.pixelSize: 13
                        }
                        MouseArea {
                            id: closeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: chartRoot.requestClose()
                            ToolTip.visible: containsMouse
                            ToolTip.text: "收起码率曲线"
                        }
                    }
                }

                // ── 码率曲线画布（整文件采样 + 当前帧指示线，点击跳帧）──
                Canvas {
                    id: chartCanvas
                    width: parent.width
                    height: parent.height - 26
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()

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
                        const samples = chartPanel.bitrateSamples
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
                        // Y 轴 max / 0 标签
                        ctx.fillStyle = "#6a6f76"
                        ctx.font = "9px sans-serif"
                        ctx.textAlign = "left"
                        ctx.fillText(mx.toFixed(1), 4, 12)
                        ctx.fillText("0", 4, h - 4)
                        // 当前帧指示线 + 顶部三角（随播放移动）
                        const n = chartPanel.frameList ? chartPanel.frameList.length : 0
                        if (chartPanel.slotActive && n > 1) {
                            const px = w * Math.min(1, Math.max(0, chartPanel.curFrame / (n - 1)))
                            ctx.strokeStyle = "#FFC857"
                            ctx.lineWidth = 1
                            ctx.beginPath(); ctx.moveTo(px, 0); ctx.lineTo(px, h); ctx.stroke()
                            ctx.fillStyle = "#FFC857"
                            ctx.beginPath()
                            ctx.moveTo(px - 4, 0); ctx.lineTo(px + 4, 0); ctx.lineTo(px, 5)
                            ctx.closePath(); ctx.fill()
                        }
                    }

                    // 点击跳帧（与 GOP 结构条一致）
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const n = chartPanel.frameList ? chartPanel.frameList.length : 0
                            if (n > 0) {
                                const idx = Math.floor(mouseX / width * n)
                                StreamBridge.gotoFrame(chartPanel.slot,
                                                       Math.max(0, Math.min(n - 1, idx)))
                            }
                        }
                    }

                    // 播放位置 / 数据变化时重绘
                    Connections {
                        target: chartPanel
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
}
