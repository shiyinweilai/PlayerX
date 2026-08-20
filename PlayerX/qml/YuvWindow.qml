import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX.YuvTools

/**
 * YuvWindow.qml — YUV 多窗口渲染子界面
 *
 * 布局：顶部仅有返回按钮和标题，中间为画面区域，底部为控制栏。
 * 每个 slot 独立：通道切换 + 帧导航 + 像素矩阵悬浮显示（块大小可在顶部菜单
 * "YUV 分析→块大小"调整；悬浮矩阵固定视口/单元格尺寸，左键点击可"固定"弹窗
 * 并拖动滚动查看完整块，参见 pixelHoverArea/pixelGridPopup）。
 */

Item {
    id: yuvView
    signal closeRequested()

    property int openSlotCount: YuvBridge.slotCount

    // ── 双路对比模式（正好打开 2 路时启用）────────────────────────────────
    // 悬浮/固定任意一路视频的像素块，联动显示 [YUV-A / YUV-B / 差异Δ] 三个
    // 挨在一起的悬浮矩阵浮窗；拖动任意一个浮窗的网格，三者共享同一滚动位置
    // 同步滚动；两路视频的同坐标块同时描边高亮。
    property bool cmpActive: openSlotCount === 2
    property bool cmpShow: false
    property bool cmpPinned: false
    property int cmpSlotA: 0
    property int cmpSlotB: 1
    property int cmpPixelX: 0
    property int cmpPixelY: 0
    property var cmpDataA: []
    property var cmpDataB: []
    property var cmpStatsA: ({})
    property var cmpStatsB: ({})
    property int cmpChannel: 0     // 0=Y / 1=U / 2=V，三个浮窗共享
    property real cmpScrollX: 0    // 三个浮窗共享的网格滚动位置（拖任一个都同步）
    property real cmpScrollY: 0
    property real cmpGroupX: 0     // 固定态下，浮窗组冻结的屏幕坐标
    property real cmpGroupY: 0
    property real cmpMouseX: 0     // 未固定时，跟随鼠标计算浮窗组位置用
    property real cmpMouseY: 0

    // 按当前 (ix,iy) 拉取两路块数据（对比模式悬浮/块大小变化时共用）
    function cmpFetchAt(ix, iy) {
        cmpPixelX = ix
        cmpPixelY = iy
        cmpShow = true
        cmpDataA = YuvBridge.pixelBlock8x8(cmpSlotA, ix, iy)
        cmpDataB = YuvBridge.pixelBlock8x8(cmpSlotB, ix, iy)
        cmpStatsA = YuvBridge.pixelBlockStats8x8(cmpSlotA, ix, iy)
        cmpStatsB = YuvBridge.pixelBlockStats8x8(cmpSlotB, ix, iy)
    }

    // 浮窗组智能避让定位（与单路悬浮矩阵的 computePopupX/Y 逻辑一致，作用于整组宽高）
    function cmpComputeGroupX(mx) {
        const gw = cmpGroup.width
        const areaW = yuvView.width
        const rightX = mx + 20
        const leftX = mx - gw - 20
        if (rightX + gw + 8 <= areaW) return rightX
        else if (leftX >= 8) return leftX
        else return Math.max(8, areaW - gw - 8)
    }
    function cmpComputeGroupY(my) {
        const gh = cmpGroup.height
        const areaH = yuvView.height
        const topY = my - gh - 20
        const bottomY = my + 20
        if (topY >= 8) return topY
        else if (bottomY + gh + 8 <= areaH) return bottomY
        else return Math.max(8, areaH - gh - 8)
    }

    onCmpActiveChanged: {
        // 打开/关闭对比模式（第三路打开或关闭时）复位状态，避免残留数据/滚动位置
        cmpShow = false
        cmpPinned = false
        cmpScrollX = 0
        cmpScrollY = 0
    }
    onCmpPinnedChanged: {
        if (!cmpPinned) {
            cmpScrollX = 0
            cmpScrollY = 0
        }
    }

    // 块大小变化（顶部菜单"YUV 分析→块大小"）时，对比模式下若正展示中，按新块大小重新拉取
    Connections {
        target: YuvBridge
        function onBlockSizeChanged() {
            if (yuvView.cmpActive && yuvView.cmpShow) {
                yuvView.cmpFetchAt(yuvView.cmpPixelX, yuvView.cmpPixelY)
                yuvView.cmpScrollX = 0
                yuvView.cmpScrollY = 0
            }
        }
        // 右侧栏"差异总览"热力图点击某块 → 左侧联动固定弹出该像素坐标的对比浮窗组
        // （居中定位展示，不依赖具体某路视频的屏幕几何，避免因缩放/平移导致定位偏差）
        function onPixelInspectRequested(px, py) {
            if (!yuvView.cmpActive) return
            yuvView.cmpFetchAt(px, py)
            yuvView.cmpScrollX = 0
            yuvView.cmpScrollY = 0
            yuvView.cmpGroupX = Math.max(8, (yuvView.width - cmpGroup.width) / 2)
            yuvView.cmpGroupY = Math.max(8, (yuvView.height - cmpGroup.height) / 2)
            yuvView.cmpPinned = true
        }
    }

    // ── 对比模式悬浮矩阵浮窗（单个面板：YUV-A / YUV-B / 差异Δ 复用同一组件）──
    component CompareMatrixPanel: Rectangle {
        id: cmpPanel
        property string title: ""
        property string mode: "a"   // "a" | "b" | "diff"

        readonly property int bs: YuvBridge.blockSize
        readonly property var dataA: yuvView.cmpDataA
        readonly property var dataB: yuvView.cmpDataB
        readonly property int channel: yuvView.cmpChannel
        readonly property bool ready: dataA.length === bs * bs && dataB.length === bs * bs

        readonly property int rulerSize: 8
        readonly property int cellSize: 30
        readonly property int cellSpacing: 1
        readonly property int viewCells: 8
        readonly property int gridSpan: viewCells * cellSize + (viewCells - 1) * cellSpacing

        width: rulerSize + gridSpan + 16
        height: contentCol.implicitHeight + 16
        radius: 6
        color: "#1a1a22"
        border.color: mode === "diff" ? "#5a3a3a" : "#3a3a4a"
        border.width: 1
        opacity: 0.97

        // 吞掉面板内除拖拽区域外的点击/悬浮事件，避免穿透到下层视频的
        // pixelHoverArea（否则会被误判为"点击视频"，导致固定态被意外取消）。
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onClicked: {}
        }

        function valueAt(idx, src) {
            const pix = src[idx]
            if (!pix) return 0
            return channel === 0 ? pix.y : (channel === 1 ? pix.u : pix.v)
        }
        // 当前 cell 显示值：a/b 为原始通道值，diff 为有符号差值（A − B）
        function cellValue(idx) {
            if (!ready) return 0
            if (mode === "a") return valueAt(idx, dataA)
            if (mode === "b") return valueAt(idx, dataB)
            return valueAt(idx, dataA) - valueAt(idx, dataB)
        }

        property real rangeMin: 0
        property real rangeMax: 1
        function recomputeRange() {
            if (!ready) { rangeMin = 0; rangeMax = 1; return }
            const n = bs * bs
            let mn = 1e9, mx = -1e9
            for (let i = 0; i < n; ++i) {
                const v = cellValue(i)
                if (v < mn) mn = v
                if (v > mx) mx = v
            }
            if (mn === mx) { rangeMin = mn; rangeMax = mn + 1 } else { rangeMin = mn; rangeMax = mx }
        }
        onChannelChanged: recomputeRange()
        onModeChanged: recomputeRange()
        Component.onCompleted: recomputeRange()
        Connections {
            target: yuvView
            function onCmpDataAChanged() { cmpPanel.recomputeRange() }
            function onCmpDataBChanged() { cmpPanel.recomputeRange() }
        }

        // 底部 avg/min/max（diff 模式下统计的是 |差值|）
        readonly property var statsSrc: mode === "a" ? yuvView.cmpStatsA : (mode === "b" ? yuvView.cmpStatsB : null)
        function fieldFor(kind) {
            if (mode !== "diff") {
                const s = statsSrc || {}
                const key = (channel === 0 ? "y" : (channel === 1 ? "u" : "v")) + kind
                const v = s[key]
                return (v === undefined) ? "—" : v
            }
            if (!ready) return "—"
            const n = bs * bs
            let sum = 0, mn = 1e9, mx = -1e9
            for (let i = 0; i < n; ++i) {
                const v = Math.abs(cellValue(i))
                sum += v
                if (v < mn) mn = v
                if (v > mx) mx = v
            }
            if (kind === "Avg") return (sum / n).toFixed(1)
            if (kind === "Min") return mn
            return mx
        }

        ColumnLayout {
            id: contentCol
            anchors.fill: parent
            anchors.margins: 8
            spacing: 4

            Text {
                Layout.fillWidth: true
                text: cmpPanel.title
                color: cmpPanel.mode === "diff" ? "#ff8a80" : "#9fc1ff"
                font.pixelSize: 11; font.bold: true
                elide: Text.ElideRight
            }

            Item {
                id: viewport
                Layout.preferredWidth: cmpPanel.rulerSize + cmpPanel.gridSpan
                Layout.preferredHeight: cmpPanel.rulerSize + cmpPanel.gridSpan

                // 顶部列刻度
                Item {
                    x: cmpPanel.rulerSize; y: 0
                    width: cmpPanel.gridSpan; height: cmpPanel.rulerSize
                    clip: true
                    Row {
                        x: -yuvView.cmpScrollX
                        spacing: cmpPanel.cellSpacing
                        Repeater {
                            model: cmpPanel.bs
                            delegate: Text {
                                required property int index
                                width: cmpPanel.cellSize; height: cmpPanel.rulerSize
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                text: index; color: "#6a6f76"; font.pixelSize: 9
                                font.family: "Menlo, Monaco, Consolas, monospace"
                            }
                        }
                    }
                }

                // 左侧行刻度
                Item {
                    x: 0; y: cmpPanel.rulerSize
                    width: cmpPanel.rulerSize; height: cmpPanel.gridSpan
                    clip: true
                    Column {
                        y: -yuvView.cmpScrollY
                        spacing: cmpPanel.cellSpacing
                        Repeater {
                            model: cmpPanel.bs
                            delegate: Text {
                                required property int index
                                width: cmpPanel.rulerSize; height: cmpPanel.cellSize
                                horizontalAlignment: Text.AlignLeft
                                leftPadding: 0
                                verticalAlignment: Text.AlignVCenter
                                text: index; color: "#6a6f76"; font.pixelSize: 9
                                font.family: "Menlo, Monaco, Consolas, monospace"
                            }
                        }
                    }
                }

                // 主网格视口：拖拽此区域会更新共享 cmpScrollX/cmpScrollY（三个浮窗任一拖动都同步）
                Item {
                    id: gridViewport
                    x: cmpPanel.rulerSize; y: cmpPanel.rulerSize
                    width: cmpPanel.gridSpan; height: cmpPanel.gridSpan
                    clip: true

                    Grid {
                        id: cmpGrid
                        x: -yuvView.cmpScrollX
                        y: -yuvView.cmpScrollY
                        columns: cmpPanel.bs
                        rows: cmpPanel.bs
                        spacing: cmpPanel.cellSpacing

                        Repeater {
                            model: cmpPanel.bs * cmpPanel.bs
                            delegate: Rectangle {
                                required property int index
                                width: cmpPanel.cellSize; height: cmpPanel.cellSize
                                radius: 2
                                color: {
                                    if (!cmpPanel.ready) return "#222"
                                    const v = cmpPanel.cellValue(index)
                                    if (cmpPanel.mode === "diff") {
                                        const scale = Math.max(1, Math.max(Math.abs(cmpPanel.rangeMin), Math.abs(cmpPanel.rangeMax)))
                                        const absT = Math.max(0, Math.min(1, Math.abs(v) / scale))
                                        const r = Math.round(26 + absT * 205)
                                        const g = Math.round(26 + absT * 20)
                                        const b = Math.round(30 + absT * 20)
                                        return Qt.rgba(r/255, g/255, b/255, 1.0)
                                    }
                                    const refMin = cmpPanel.rangeMin, refMax = cmpPanel.rangeMax
                                    const span = Math.max(1, refMax - refMin)
                                    const t = Math.max(0, Math.min(1, (v - refMin) / span))
                                    const r = Math.round(15 + t * 55)
                                    const g = Math.round(18 + t * 60)
                                    const b = Math.round(24 + t * 72)
                                    return Qt.rgba(r/255, g/255, b/255, 1.0)
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: {
                                        if (!cmpPanel.ready) return ""
                                        const v = cmpPanel.cellValue(index)
                                        return (cmpPanel.mode === "diff" && v > 0) ? ("+" + v) : v
                                    }
                                    color: {
                                        if (!cmpPanel.ready) return "#e0e0e0"
                                        const v = cmpPanel.cellValue(index)
                                        if (cmpPanel.mode === "diff") {
                                            const scale = Math.max(1, Math.max(Math.abs(cmpPanel.rangeMin), Math.abs(cmpPanel.rangeMax)))
                                            return Math.abs(v) > scale * 0.5 ? "#fff" : "#ddd"
                                        }
                                        const refMin = cmpPanel.rangeMin, refMax = cmpPanel.rangeMax
                                        const span = Math.max(1, refMax - refMin)
                                        const t = Math.max(0, Math.min(1, (v - refMin) / span))
                                        const lum = (0.299*(15+t*55) + 0.587*(18+t*60) + 0.114*(24+t*72)) / 255
                                        return lum > 0.55 ? "#0a0a0a" : "#f0f0f0"
                                    }
                                    font.pixelSize: 10; font.bold: true
                                    font.family: "Menlo, Monaco, Consolas, monospace"
                                }
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: yuvView.cmpPinned
                        property real lastX: 0
                        property real lastY: 0
                        onPressed: function(mouse) { lastX = mouse.x; lastY = mouse.y }
                        onPositionChanged: function(mouse) {
                            if (!pressed) return
                            const bs = cmpPanel.bs
                            const contentSpan = bs * cmpPanel.cellSize + (bs - 1) * cmpPanel.cellSpacing
                            const maxScroll = Math.max(0, contentSpan - cmpPanel.gridSpan)
                            const nx = yuvView.cmpScrollX - (mouse.x - lastX)
                            const ny = yuvView.cmpScrollY - (mouse.y - lastY)
                            yuvView.cmpScrollX = Math.max(0, Math.min(maxScroll, nx))
                            yuvView.cmpScrollY = Math.max(0, Math.min(maxScroll, ny))
                            lastX = mouse.x; lastY = mouse.y
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    Layout.fillWidth: true; Layout.alignment: Qt.AlignHCenter
                    text: (cmpPanel.mode === "diff" ? "<span style=\"color:#ff8a80\">avgΔ</span> " : "<span style=\"color:#6cf\">avg</span> ") + cmpPanel.fieldFor("Avg")
                    color: "#dde"; font.pixelSize: 10; font.bold: true
                    font.family: "Menlo, Monaco, Consolas, monospace"; textFormat: Text.RichText
                }
                Text {
                    Layout.fillWidth: true; Layout.alignment: Qt.AlignHCenter
                    text: (cmpPanel.mode === "diff" ? "<span style=\"color:#6c8\">minΔ</span> " : "<span style=\"color:#6c8\">min</span> ") + cmpPanel.fieldFor("Min")
                    color: "#dde"; font.pixelSize: 10; font.bold: true
                    font.family: "Menlo, Monaco, Consolas, monospace"; textFormat: Text.RichText
                }
                Text {
                    Layout.fillWidth: true; Layout.alignment: Qt.AlignHCenter
                    text: (cmpPanel.mode === "diff" ? "<span style=\"color:#e86\">maxΔ</span> " : "<span style=\"color:#e86\">max</span> ") + cmpPanel.fieldFor("Max")
                    color: "#dde"; font.pixelSize: 10; font.bold: true
                    font.family: "Menlo, Monaco, Consolas, monospace"; textFormat: Text.RichText
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#101012"
    }

    // 全局刷新版本号：任意 slot 的帧/播放状态/通道变化都 ++，驱动最下方"总控"栏的
    // 按钮态（如通道高亮、播放/暂停图标）跟随刷新。
    property int globalVer: 0
    Connections {
        target: YuvBridge
        function onFrameChanged(slot) { yuvView.globalVer++ }
        function onDisplayModeChanged(slot) { yuvView.globalVer++ }
        function onPlayStateChanged(slot) { yuvView.globalVer++ }
    }

    // ── 总控：同时作用于所有已打开 slot 的批量操作 ──────────────────────
    signal centerAllRequested()   // 通知各 slot 复位平移（画面居中），纯 QML 端状态，无法通过 YuvBridge 统一处理
    function globalSetDisplayMode(mode) {
        for (let i = 0; i < yuvView.openSlotCount; ++i) YuvBridge.setDisplayMode(i, mode)
    }
    function globalTogglePlayPause() {
        for (let i = 0; i < yuvView.openSlotCount; ++i) YuvBridge.togglePlayPause(i)
    }
    function globalPrevFrame() {
        for (let i = 0; i < yuvView.openSlotCount; ++i) YuvBridge.prevFrame(i)
    }
    function globalNextFrame() {
        for (let i = 0; i < yuvView.openSlotCount; ++i) YuvBridge.nextFrame(i)
    }
    function globalSkipBackward() {
        for (let i = 0; i < yuvView.openSlotCount; ++i) YuvBridge.skipBackward(i, 15)
    }
    function globalSkipForward() {
        for (let i = 0; i < yuvView.openSlotCount; ++i) YuvBridge.skipForward(i, 15)
    }
    function globalResetFrame() {
        for (let i = 0; i < yuvView.openSlotCount; ++i) YuvBridge.resetFrame(i)
    }
    function globalToggleReverse() {
        for (let i = 0; i < yuvView.openSlotCount; ++i) {
            if (YuvBridge.isReversing(i)) YuvBridge.pause(i)
            else YuvBridge.playReverse(i)
        }
    }
    function globalAnyPlaying() {
        for (let i = 0; i < yuvView.openSlotCount; ++i) if (YuvBridge.isPlaying(i)) return true
        return false
    }
    function globalAllModeIs(mode) {
        if (yuvView.openSlotCount <= 0) return false
        for (let i = 0; i < yuvView.openSlotCount; ++i) if (YuvBridge.displayMode(i) !== mode) return false
        return true
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── 中间：多窗口画面区域 ─────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 2

            Repeater {
                model: yuvView.openSlotCount
                delegate: Rectangle {
                    id: slotWin
                    required property int index
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "#0c0c0e"

                    property int ver: 0
                    Connections {
                        target: YuvBridge
                        function onFrameChanged(slot) {
                            if (slot === slotWin.index) ver++
                        }
                        function onPlayStateChanged(slot) {
                            if (slot === slotWin.index) ver++
                        }
                        function onDisplayModeChanged(slot) {
                            if (slot === slotWin.index) ver++
                        }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ── 顶部信息条：序号 + 文件名 + 关闭 ──
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 28
                            color: "#14141a"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 6

                                // 序号标签
                                Rectangle {
                                    width: 20; height: 18; radius: 3
                                    color: "#3a6fd8"
                                    Text {
                                        anchors.centerIn: parent
                                        text: (slotWin.index + 1).toString()
                                        color: "#fff"; font.pixelSize: 11; font.bold: true
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: YuvBridge.fileName(slotWin.index)
                                    color: "#c8c8d0"; font.pixelSize: 11
                                    elide: Text.ElideMiddle
                                }

                                // 关闭按钮
                                Rectangle {
                                    width: 18; height: 18; radius: 9
                                    color: slotCloseMa.containsMouse ? "#b85a5a" : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"; color: "#f5a3a3"; font.pixelSize: 12; font.bold: true
                                    }
                                    MouseArea {
                                        id: slotCloseMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: YuvBridge.closeFile(slotWin.index)
                                    }
                                }
                            }
                        }

                        // ── 画面区域（画面 + 悬浮内嵌控制条，鼠标悬浮画面时显示控制条）──
                        Item {
                            id: slotStage
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            // 悬浮检测覆盖整个画面+控制条区域，用于淡入淡出内嵌控制条；
                            // HoverHandler 非独占抓取，不影响下方已有 MouseArea 的事件响应。
                            HoverHandler { id: slotStageHover }

                            // 响应最下方"全局总控"栏的一键居中：复位本 slot 的画面平移
                            Connections {
                                target: yuvView
                                function onCenterAllRequested() {
                                    yuvDisp.panX = 0
                                    yuvDisp.panY = 0
                                }
                            }

                        Item {
                            id: slotScreen
                            anchors.fill: parent
                            clip: true

                            YuvDisplayItem {
                                id: yuvDisp
                                anchors.fill: parent
                                image: {
                                    const _ = slotWin.ver
                                    return YuvBridge.frameImage(slotWin.index)
                                }
                            }

                            // ── 右键按住拖拽平移 ──
                            MouseArea {
                                id: panArea
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                property real lastX: 0
                                property real lastY: 0

                                onPressed: function(mouse) {
                                    lastX = mouse.x
                                    lastY = mouse.y
                                    cursorShape = Qt.ClosedHandCursor
                                }
                                onReleased: {
                                    cursorShape = Qt.ArrowCursor
                                }
                                onPositionChanged: function(mouse) {
                                    if (pressed) {
                                        yuvDisp.panX += mouse.x - lastX
                                        yuvDisp.panY += mouse.y - lastY
                                        lastX = mouse.x
                                        lastY = mouse.y
                                    }
                                }
                                // 右键双击：重置平移归位
                                onDoubleClicked: {
                                    yuvDisp.panX = 0
                                    yuvDisp.panY = 0
                                }
                            }

                            // ── 鼠标悬浮矩阵浮窗交互 ────────────────────────────────
                            // 悬浮态：固定视口尺寸（viewCells×viewCells）+ 固定单元格大小，
                            // 跟随鼠标显示当前块左上角部分；块越大只露出可视区域内的内容。
                            // 左键点击后进入"固定"态：弹窗停止跟随鼠标（冻结屏幕坐标与内容），
                            // 内部 Flickable 允许上下左右拖动查看块的其余部分；再次点击视频
                            // 区域（弹窗外）或点击弹窗右上角 × 取消固定、恢复跟随。
                            MouseArea {
                                id: pixelHoverArea
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton
                                propagateComposedEvents: true

                                property bool showPixelGrid: false
                                property bool pinned: false
                                property int pixelX: 0
                                property int pixelY: 0
                                property var pixelData: []
                                // 块统计值：{ yAvg,yMin,yMax, uAvg,uMin,uMax, vAvg,vMin,vMax }
                                property var pixelStats: ({})

                                // 固定时冻结的弹窗屏幕坐标（点击瞬间算好存这里，不再跟随鼠标）
                                property real pinnedPopupX: 0
                                property real pinnedPopupY: 0

                                // 按当前块大小（YuvBridge.blockSize）拉取一次悬浮矩阵数据，
                                // hover 移动 / 块大小切换共用此函数。
                                function fetchAt(ix, iy) {
                                    pixelX = ix
                                    pixelY = iy
                                    showPixelGrid = true
                                    pixelData = YuvBridge.pixelBlock8x8(slotWin.index, ix, iy)
                                    pixelStats = YuvBridge.pixelBlockStats8x8(slotWin.index, ix, iy)
                                    // 上报全局悬浮像素坐标，供右侧栏"块级别"统计实时跟随
                                    YuvBridge.setHoverPixel(slotWin.index, ix, iy, true)
                                }

                                // 弹窗智能避让定位（"跟随鼠标"实时计算 与 "固定瞬间"取快照共用）
                                function computePopupX(mx) {
                                    const pw = pixelHoverArea.width
                                    const pgw = pixelGridPopup.width
                                    const rightX = mx + 20
                                    const leftX = mx - pgw - 20
                                    if (rightX + pgw + 8 <= pw) return rightX
                                    else if (leftX >= 8) return leftX
                                    else return pw - pgw - 8
                                }
                                function computePopupY(my) {
                                    const ph = pixelHoverArea.height
                                    const pgh = pixelGridPopup.height
                                    const topY = my - pgh - 20
                                    const bottomY = my + 20
                                    if (topY >= 8) return topY
                                    else if (bottomY + pgh + 8 <= ph) return bottomY
                                    else return 8
                                }

                                onPositionChanged: function(mouse) {
                                    // ── 双路对比模式：悬浮任一路视频，联动三窗口浮窗组 ──
                                    if (yuvView.cmpActive) {
                                        if (yuvView.cmpPinned) return
                                        const imgWc = YuvBridge.width(slotWin.index)
                                        const imgHc = YuvBridge.height(slotWin.index)
                                        if (imgWc <= 0 || imgHc <= 0) return
                                        const dispWc = pixelHoverArea.width
                                        const dispHc = pixelHoverArea.height
                                        const offXc = (dispWc - imgWc) / 2.0 + yuvDisp.panX
                                        const offYc = (dispHc - imgHc) / 2.0 + yuvDisp.panY
                                        const ixc = Math.floor(mouse.x - offXc)
                                        const iyc = Math.floor(mouse.y - offYc)
                                        if (ixc >= 0 && ixc < imgWc && iyc >= 0 && iyc < imgHc) {
                                            yuvView.cmpFetchAt(ixc, iyc)
                                            const gp = pixelHoverArea.mapToItem(yuvView, mouse.x, mouse.y)
                                            yuvView.cmpMouseX = gp.x
                                            yuvView.cmpMouseY = gp.y
                                        } else {
                                            yuvView.cmpShow = false
                                        }
                                        return
                                    }
                                    if (pinned) return   // 已固定：不再跟随鼠标刷新
                                    // 将鼠标坐标映射到图像坐标
                                    // YuvDisplayItem 使用 1:1 原尺寸居中 + panX/panY 偏移
                                    const imgW = YuvBridge.width(slotWin.index)
                                    const imgH = YuvBridge.height(slotWin.index)
                                    if (imgW <= 0 || imgH <= 0) return

                                    const dispW = pixelHoverArea.width
                                    const dispH = pixelHoverArea.height

                                    // 1:1 居中偏移 + 平移偏移（与 YuvDisplayItem::paint 一致）
                                    const offX = (dispW - imgW) / 2.0 + yuvDisp.panX
                                    const offY = (dispH - imgH) / 2.0 + yuvDisp.panY

                                    const ix = Math.floor(mouse.x - offX)
                                    const iy = Math.floor(mouse.y - offY)

                                    if (ix >= 0 && ix < imgW && iy >= 0 && iy < imgH) {
                                        fetchAt(ix, iy)
                                    } else {
                                        showPixelGrid = false
                                        YuvBridge.setHoverPixel(slotWin.index, 0, 0, false)
                                    }
                                }
                                onExited: {
                                    if (yuvView.cmpActive) {
                                        if (!yuvView.cmpPinned) yuvView.cmpShow = false
                                        return
                                    }
                                    if (pinned) return   // 已固定：鼠标移出视频区域也不收起弹窗
                                    showPixelGrid = false
                                    YuvBridge.setHoverPixel(slotWin.index, 0, 0, false)
                                }
                                onClicked: function(mouse) {
                                    if (yuvView.cmpActive) {
                                        if (yuvView.cmpPinned) {
                                            // 点击视频区域（浮窗组之外）→ 取消固定，恢复跟随鼠标
                                            yuvView.cmpPinned = false
                                        } else if (yuvView.cmpShow) {
                                            const gp = pixelHoverArea.mapToItem(yuvView, mouse.x, mouse.y)
                                            yuvView.cmpGroupX = yuvView.cmpComputeGroupX(gp.x)
                                            yuvView.cmpGroupY = yuvView.cmpComputeGroupY(gp.y)
                                            yuvView.cmpPinned = true
                                        }
                                        return
                                    }
                                    if (pinned) {
                                        // 点击视频区域（弹窗之外）→ 取消固定，恢复跟随鼠标
                                        pinned = false
                                    } else if (showPixelGrid) {
                                        // 冻结当前弹窗的屏幕位置与内容 → 进入固定态
                                        pinnedPopupX = computePopupX(mouse.x)
                                        pinnedPopupY = computePopupY(mouse.y)
                                        pinned = true
                                    }
                                }
                                onPinnedChanged: {
                                    if (!pinned) {
                                        // 取消固定后复位滚动位置，下次悬浮从块左上角开始显示
                                        gridFlick.contentX = 0
                                        gridFlick.contentY = 0
                                    }
                                }
                            }

                            // 块大小变化（顶部菜单"YUV 分析→块大小"）时，若当前有展示中的
                            // 块（悬浮或固定），立即按新块大小重新拉取，保持浮窗内容同步。
                            Connections {
                                target: YuvBridge
                                function onBlockSizeChanged() {
                                    if (pixelHoverArea.showPixelGrid) {
                                        pixelHoverArea.fetchAt(pixelHoverArea.pixelX, pixelHoverArea.pixelY)
                                        gridFlick.contentX = 0
                                        gridFlick.contentY = 0
                                    }
                                }
                            }

                            // ── 像素块 hover 高亮边框（尺寸跟随 YuvBridge.blockSize）──
                            // 对比模式下：A/B 两路同坐标块同时高亮，联动效果由 cmpPixelX/Y 驱动。
                            Rectangle {
                                id: blockHighlight
                                visible: yuvView.cmpActive ? yuvView.cmpShow : pixelHoverArea.showPixelGrid
                                width: YuvBridge.blockSize
                                height: YuvBridge.blockSize
                                color: "transparent"
                                border.color: (yuvView.cmpActive ? yuvView.cmpPinned : pixelHoverArea.pinned) ? "#3a6fd8" : "#00FF88"
                                border.width: 2
                                radius: 1

                                // 定位到当前像素所在的块（对齐到块边界）
                                x: {
                                    const imgW = YuvBridge.width(slotWin.index)
                                    const dispW = pixelHoverArea.width
                                    const offX = (dispW - imgW) / 2.0 + yuvDisp.panX
                                    const bs = YuvBridge.blockSize
                                    const px = yuvView.cmpActive ? yuvView.cmpPixelX : pixelHoverArea.pixelX
                                    const blockX = Math.floor(px / bs) * bs
                                    return offX + blockX
                                }
                                y: {
                                    const imgH = YuvBridge.height(slotWin.index)
                                    const dispH = pixelHoverArea.height
                                    const offY = (dispH - imgH) / 2.0 + yuvDisp.panY
                                    const bs = YuvBridge.blockSize
                                    const py = yuvView.cmpActive ? yuvView.cmpPixelY : pixelHoverArea.pixelY
                                    const blockY = Math.floor(py / bs) * bs
                                    return offY + blockY
                                }
                            }

                            // ── 像素矩阵浮窗（固定视口尺寸 + 固定单元格大小，块越大越靠滚动查看）──
                            // 对比模式下改由顶层共享的 cmpGroup（YUV-A/YUV-B/差异Δ 三联窗）展示，此处隐藏。
                            Rectangle {
                                id: pixelGridPopup
                                readonly property int bs: YuvBridge.blockSize
                                visible: !yuvView.cmpActive && pixelHoverArea.showPixelGrid && pixelHoverArea.pixelData.length === bs * bs
                                // 左对齐（不再水平居中），避免弹窗宽度 > 网格实际宽度时产生大片左侧空白
                                width: 271
                                height: contentCol.implicitHeight + 16
                                radius: 6
                                color: "#1a1a22"
                                border.color: pixelHoverArea.pinned ? "#3a6fd8" : "#3a3a4a"
                                border.width: pixelHoverArea.pinned ? 2 : 1
                                opacity: 0.97

                                // 定位：未固定时智能避让跟随鼠标；固定后使用点击瞬间冻结的坐标
                                x: pixelHoverArea.pinned ? pixelHoverArea.pinnedPopupX
                                                          : pixelHoverArea.computePopupX(pixelHoverArea.mouseX)
                                y: pixelHoverArea.pinned ? pixelHoverArea.pinnedPopupY
                                                          : pixelHoverArea.computePopupY(pixelHoverArea.mouseY)

                                // 吞掉弹窗区域内的点击/悬浮事件，避免穿透到下层视频的
                                // pixelHoverArea（否则鼠标停在弹窗上方时会被误判为"点击视频"，
                                // 导致固定态被意外取消，或未固定态下反复错误重新定位）。
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton
                                    onClicked: {}
                                }

                                // 一键拷贝：把当前通道（Y/U/V）的 bs×bs 矩阵 + avg/min/max 汇总
                                // 以 Tab 分隔（TSV）写入系统剪贴板 —— 可直接粘贴进 Excel / Numbers /
                                // Google Sheets 自动分列成表格，比逗号/空格分隔更适合"矩阵"场景。
                                property bool copyFlash: false
                                TextEdit {
                                    id: copyHelper
                                    visible: false
                                    // 隐藏但仍需存在于场景中才能执行 selectAll()/copy()
                                }
                                Timer {
                                    id: copyFlashTimer
                                    interval: 1200
                                    onTriggered: pixelGridPopup.copyFlash = false
                                }
                                function copyMatrixToClipboard() {
                                    const bs = pixelGridPopup.bs
                                    const data = pixelHoverArea.pixelData
                                    if (!data || data.length !== bs * bs) return
                                    const ch = channelTabs ? channelTabs.channel : 0
                                    const pick = (pix) => ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                    let lines = []
                                    for (let r = 0; r < bs; ++r) {
                                        let cols = []
                                        for (let c = 0; c < bs; ++c) cols.push(pick(data[r * bs + c]))
                                        lines.push(cols.join("\t"))
                                    }
                                    const s = pixelHoverArea.pixelStats || {}
                                    const avg = ch === 0 ? s.yAvg : (ch === 1 ? s.uAvg : s.vAvg)
                                    const min = ch === 0 ? s.yMin : (ch === 1 ? s.uMin : s.vMin)
                                    const max = ch === 0 ? s.yMax : (ch === 1 ? s.uMax : s.vMax)
                                    lines.push("")
                                    lines.push("avg\tmin\tmax")
                                    lines.push(avg + "\t" + min + "\t" + max)

                                    copyHelper.text = lines.join("\n")
                                    copyHelper.selectAll()
                                    copyHelper.copy()
                                    copyHelper.deselect()

                                    copyFlash = true
                                    copyFlashTimer.restart()
                                }

                                ColumnLayout {
                                    id: contentCol
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 4

                                    // 标题行：坐标范围 + 固定态提示 + 关闭按钮
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Text {
                                            Layout.fillWidth: true
                                            text: {
                                                const bs = pixelGridPopup.bs
                                                const bx = Math.floor(pixelHoverArea.pixelX / bs) * bs
                                                const by = Math.floor(pixelHoverArea.pixelY / bs) * bs
                                                return "像素块 [" + bx + "," + by + "] ~ [" + (bx+bs-1) + "," + (by+bs-1) + "]"
                                            }
                                            color: "#aaa"; font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            visible: pixelHoverArea.pinned
                                            text: "📌"
                                            font.pixelSize: 11
                                        }
                                        // 一键拷贝当前通道矩阵（Tab 分隔，可直接粘贴进 Excel/Numbers/Sheets 自动分列）
                                        Rectangle {
                                            id: copyBtn
                                            width: 16; height: 16; radius: 8
                                            color: copyMa.containsMouse ? "#3a6fd8" : "#2a2a34"
                                            Text {
                                                anchors.centerIn: parent
                                                text: "⧉"; color: copyMa.containsMouse ? "#fff" : "#9aa"; font.pixelSize: 10
                                            }
                                            MouseArea {
                                                id: copyMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: pixelGridPopup.copyMatrixToClipboard()
                                            }
                                        }
                                        Rectangle {
                                            visible: pixelHoverArea.pinned
                                            width: 16; height: 16; radius: 8
                                            color: closeMa.containsMouse ? "#b85a5a" : "#2a2a34"
                                            Text {
                                                anchors.centerIn: parent
                                                text: "×"; color: "#f5a3a3"; font.pixelSize: 11; font.bold: true
                                            }
                                            MouseArea {
                                                id: closeMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: pixelHoverArea.pinned = false
                                            }
                                        }
                                    }

                                    // 固定态操作提示（未固定时提示可点击固定，固定后提示可滚动/取消）；
                                    // 拷贝成功后短暂替换成"已复制"提示，1.2s 后自动恢复。
                                    Text {
                                        Layout.fillWidth: true
                                        text: pixelGridPopup.copyFlash
                                              ? "✓ 已复制到剪贴板（Tab 分隔，可直接粘贴到 Excel/表格）"
                                              : (pixelHoverArea.pinned
                                                  ? "已固定 · 拖动查看完整块 · 点击 × 或视频空白处取消"
                                                  : "点击可固定窗口，支持滚动查看完整块")
                                        color: pixelGridPopup.copyFlash ? "#7ee787" : (pixelHoverArea.pinned ? "#7fd3ff" : "#6a6f76")
                                        font.pixelSize: 9
                                        wrapMode: Text.WordWrap
                                    }

                                    // 通道选择 tabs — 与底部 YUV/Y/U/V 按钮同步
                                    //  YUV 模式（displayMode=0）默认显示 Y 平面
                                    //  Y / U / V 模式 → 矩阵自动切到对应通道
                                    //  矩阵里点击则反向同步回 YuvBridge（用户在悬浮窗里手动切换）
                                    Row {
                                        id: channelTabs
                                        spacing: 2
                                        property int channel: {
                                            const dm = YuvBridge.displayMode(slotWin.index)
                                            const _ = slotWin.ver   // 触发 displayMode 变化时刷新
                                            if (dm === 2) return 1  // U
                                            if (dm === 3) return 2  // V
                                            return 0               // YUV / Y → Y
                                        }

                                        Repeater {
                                            model: ["Y", "U", "V"]
                                            delegate: Rectangle {
                                                required property int index
                                                required property string modelData
                                                width: 30; height: 18; radius: 3
                                                color: parent.channel === index ? "#3a6fd8" : "#2a2a34"
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: modelData
                                                    color: parent.parent.channel === index ? "#fff" : "#888"
                                                    font.pixelSize: 10; font.bold: true
                                                }
                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        // 1) 立即更新本地 channel（让 UI 立刻响应）
                                                        parent.parent.channel = index
                                                        // 2) 同步到 YuvBridge 的显示模式
                                                        //    matrix Y → displayMode 1 (Y)
                                                        //    matrix U → displayMode 2 (U)
                                                        //    matrix V → displayMode 3 (V)
                                                        const dm = (index === 0) ? 1 : (index === 1 ? 2 : 3)
                                                        YuvBridge.setDisplayMode(slotWin.index, dm)
                                                    }
                                                }
                                            }
                                        }

                                        // 用于外部引用
                                        function getChannel() { return channel }
                                    }

                                    // 固定尺寸视口 + 行/列偏移刻度：
                                    //   顶部刻度＝列偏移（块内 x，0 起），左侧刻度＝行偏移（块内 y，0 起）；
                                    //   随 gridFlick 的 contentX/contentY 同步滚动，方便对照当前滑到了块内哪个位置。
                                    // 注：用 Item + 显式 x/y/width/height 硬定位（而非 Layout 自动协商尺寸），
                                    //   避免刻度与主网格互相引用尺寸形成绑定环、也避免括号计数出错。
                                    Item {
                                        id: gridWithRulers
                                        readonly property int rulerSize: 8
                                        readonly property int cellSize: 30
                                        readonly property int cellSpacing: 1
                                        readonly property int viewCells: 8
                                        readonly property int gridSpan: viewCells * cellSize + (viewCells - 1) * cellSpacing

                                        // 左对齐（不再水平居中），避免弹窗宽度 > 网格实际宽度时产生大片左侧空白
                                        Layout.alignment: Qt.AlignLeft
                                        Layout.preferredWidth: rulerSize + gridSpan
                                        Layout.preferredHeight: rulerSize + gridSpan

                                        // 顶部刻度：列偏移（跟随 gridFlick 水平滚动）
                                        Flickable {
                                            id: hRuler
                                            x: gridWithRulers.rulerSize
                                            y: 0
                                            width: gridWithRulers.gridSpan
                                            height: gridWithRulers.rulerSize
                                            clip: true
                                            interactive: false
                                            boundsBehavior: Flickable.StopAtBounds
                                            contentX: gridFlick.contentX
                                            contentWidth: pixelGrid.width
                                            contentHeight: height

                                            Row {
                                                spacing: gridWithRulers.cellSpacing
                                                Repeater {
                                                    model: pixelGrid.bs
                                                    delegate: Text {
                                                        required property int index
                                                        width: gridWithRulers.cellSize
                                                        height: hRuler.height
                                                        horizontalAlignment: Text.AlignHCenter
                                                        verticalAlignment: Text.AlignVCenter
                                                        text: index
                                                        color: "#6a6f76"
                                                        font.pixelSize: 9
                                                        font.family: "Menlo, Monaco, Consolas, monospace"
                                                    }
                                                }
                                            }
                                        }

                                        // 左侧刻度：行偏移（跟随 gridFlick 垂直滚动）
                                        Flickable {
                                            id: vRuler
                                            x: 0
                                            y: gridWithRulers.rulerSize
                                            width: gridWithRulers.rulerSize
                                            height: gridWithRulers.gridSpan
                                            clip: true
                                            interactive: false
                                            boundsBehavior: Flickable.StopAtBounds
                                            contentY: gridFlick.contentY
                                            contentWidth: width
                                            contentHeight: pixelGrid.height

                                            Column {
                                                spacing: gridWithRulers.cellSpacing
                                                Repeater {
                                                    model: pixelGrid.bs
                                                    delegate: Text {
                                                        required property int index
                                                        width: vRuler.width
                                                        height: gridWithRulers.cellSize
                                                        // 贴左对齐：让数字紧贴右侧（紧挨主网格），而不是刻度容器中央
                                                        horizontalAlignment: Text.AlignLeft
                                                        leftPadding: 0
                                                        verticalAlignment: Text.AlignVCenter
                                                        text: index
                                                        color: "#6a6f76"
                                                        font.pixelSize: 9
                                                        font.family: "Menlo, Monaco, Consolas, monospace"
                                                    }
                                                }
                                            }
                                        }

                                        // 固定尺寸视口：单元格大小恒定（不随块大小自适应缩小），
                                        // 块越大只展示可视区域，需固定后拖动查看其余部分。
                                        Flickable {
                                            id: gridFlick
                                            x: gridWithRulers.rulerSize
                                            y: gridWithRulers.rulerSize
                                            width: gridWithRulers.gridSpan
                                            height: gridWithRulers.gridSpan
                                            readonly property int cellSize: gridWithRulers.cellSize
                                            readonly property int cellSpacing: gridWithRulers.cellSpacing
                                            readonly property int viewCells: gridWithRulers.viewCells
                                            clip: true
                                            interactive: pixelHoverArea.pinned
                                            boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: pixelGrid.width
                                            contentHeight: pixelGrid.height
                                            ScrollBar.vertical: ScrollBar {
                                                policy: pixelHoverArea.pinned ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                                            }
                                            ScrollBar.horizontal: ScrollBar {
                                                policy: pixelHoverArea.pinned ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                                            }

                                        Grid {
                                            id: pixelGrid
                                            readonly property int bs: YuvBridge.blockSize
                                            columns: bs
                                            rows: bs
                                            spacing: gridFlick.cellSpacing

                                            property int channel: channelTabs ? channelTabs.channel : 0

                                            // 当前通道下、当前块的原始值域（不用位深，按真实数据自适应）
                                            //   - 8bit 块：0-255
                                            //   - 10bit 块：0-1023
                                            //   - 极端全黑/全亮：min==max，span=1，"t" 退化为 0（保证不出错）
                                            property int blockMin: 0
                                            property int blockMax: 1
                                            function recomputeRange() {
                                                const n = bs * bs
                                                if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length !== n) {
                                                    blockMin = 0; blockMax = 1; return
                                                }
                                                const ch = channel
                                                let mn = 65535, mx = -1
                                                for (let i = 0; i < n; ++i) {
                                                    const v = ch === 0 ? pixelHoverArea.pixelData[i].y
                                                                      : (ch === 1 ? pixelHoverArea.pixelData[i].u
                                                                                  : pixelHoverArea.pixelData[i].v)
                                                    if (v < mn) mn = v
                                                    if (v > mx) mx = v
                                                }
                                                if (mn === mx) { blockMin = mn; blockMax = mn + 1 }
                                                else           { blockMin = mn; blockMax = mx }
                                            }
                                            // 通道/块大小/数据任一变化都要重算
                                            onChannelChanged: recomputeRange()
                                            onBsChanged: recomputeRange()
                                            Component.onCompleted: recomputeRange()
                                            Connections {
                                                target: pixelHoverArea
                                                function onPixelDataChanged() { pixelGrid.recomputeRange() }
                                            }

                                            Repeater {
                                                model: pixelGrid.bs * pixelGrid.bs
                                                delegate: Rectangle {
                                                    required property int index
                                                    width: gridFlick.cellSize
                                                    height: gridFlick.cellSize
                                                    radius: 2
                                                    color: {
                                                        if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length <= index)
                                                            return "#222"
                                                        const pix = pixelHoverArea.pixelData[index]
                                                        const ch = pixelGrid.channel
                                                        const raw = ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                                        // ── 自适应背景色 ──
                                                        // 像素值按"位深未知"处理：直接拿当前块的动态范围 (min..max) 归一化。
                                                        // 这样 8bit (0-255) 和 10bit (0-1023) 都能用，亮块/暗块都能看清。
                                                        const refMin = pixelGrid.blockMin || 0
                                                        const refMax = pixelGrid.blockMax || 1
                                                        const span = Math.max(1, refMax - refMin)
                                                        const t = Math.max(0, Math.min(1, (raw - refMin) / span))
                                                        // 背景：暗端 #0f1218 → 亮端 #4a5268（中等灰蓝），永远不和文字撞色
                                                        const r = Math.round(15 + t * 55)
                                                        const g = Math.round(18 + t * 60)
                                                        const b = Math.round(24 + t * 72)
                                                        return Qt.rgba(r/255, g/255, b/255, 1.0)
                                                    }

                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: {
                                                            if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length <= index)
                                                                return ""
                                                            const pix = pixelHoverArea.pixelData[index]
                                                            const ch = pixelGrid.channel
                                                            return ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                                        }
                                                        // 文字：按"靠近 0 还是靠近 255"自动反色，做绝对对比
                                                        // 改用感知亮度公式 (luma) 判定：阈值 0.5
                                                        color: {
                                                            if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length <= index)
                                                                return "#e0e0e0"
                                                            const pix = pixelHoverArea.pixelData[index]
                                                            const ch = pixelGrid.channel
                                                            const raw = ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                                            const refMin = pixelGrid.blockMin || 0
                                                            const refMax = pixelGrid.blockMax || 1
                                                            const span = Math.max(1, refMax - refMin)
                                                            const t = Math.max(0, Math.min(1, (raw - refMin) / span))
                                                            // 背景的近似亮度曲线（与上面同步）
                                                            const lum = (0.299 * (15 + t*55) + 0.587 * (18 + t*60) + 0.114 * (24 + t*72)) / 255
                                                            return lum > 0.55 ? "#0a0a0a" : "#f0f0f0"
                                                        }
                                                        font.pixelSize: 10
                                                        font.family: "Menlo, Monaco, Consolas, monospace"
                                                        font.bold: true
                                                    }
                                                }
                                            }
                                        } // end Grid pixelGrid
                                        } // end Flickable gridFlick
                                    } // end Item gridWithRulers

                                    // 块 YUV 统计：avg / min / max 三行合一
                                    //   - YUV 模式：三个通道值都显示，便于一眼对比差异
                                    //   - 单通道模式（Y / U / V）：只显示当前通道的数值，更聚焦
                                    Column {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        property var s: pixelHoverArea.pixelStats || {}
                                        property bool ready: (typeof s.yAvg === "number")
                                        // 跟随 matrix 的通道 tab：0=Y / 1=U / 2=V（与 channelTabs.channel 对齐）
                                        property int ch: channelTabs ? channelTabs.channel : 0

                                        // 三组指标三等分布局：avg | min | max 各占 1/3 宽度，水平居中
                                        //   - Y / U / V 单通道模式：显示当前通道的 avg / min / max
                                        //   - YUV 模式（兜底）：显示三通道的 (y,u,v)
                                        //   - avg 标签按通道上色（Y 蓝 / U V 紫），min 绿 / max 橙
                                        RowLayout {
                                            visible: parent.ready
                                            // 注意：父级是普通 Column（非 ColumnLayout），Column 不支持
                                            // 子项的 Layout.fillWidth 附加属性，必须显式 width 才能撑满，
                                            // 否则子 Text 的 Layout.fillWidth 会因为本身没有宽度可分配而失效。
                                            width: parent.width
                                            spacing: 0

                                            // avg
                                            Text {
                                                Layout.fillWidth: true
                                                Layout.alignment: Qt.AlignHCenter
                                                text: {
                                                    const s = parent.parent.s
                                                    const ch = parent.parent.ch
                                                    const label = (ch === 0) ? "<span style=\"color:#6cf\">avg</span>"
                                                              : (ch === 1 || ch === 2) ? "<span style=\"color:#c8a\">avg</span>"
                                                              : "<span style=\"color:#6cf\">avg</span>"
                                                    const val = (ch === 0) ? s.yAvg
                                                              : (ch === 1) ? s.uAvg
                                                              : (ch === 2) ? s.vAvg
                                                              : "(" + s.yAvg + ", " + s.uAvg + ", " + s.vAvg + ")"
                                                    return label + " " + val
                                                }
                                                color: "#dde"; font.pixelSize: 10; font.bold: true
                                                font.family: "Menlo, Monaco, Consolas, monospace"
                                                textFormat: Text.RichText
                                            }
                                            // min
                                            Text {
                                                Layout.fillWidth: true
                                                Layout.alignment: Qt.AlignHCenter
                                                text: {
                                                    const s = parent.parent.s
                                                    const ch = parent.parent.ch
                                                    const val = (ch === 0) ? s.yMin
                                                              : (ch === 1) ? s.uMin
                                                              : (ch === 2) ? s.vMin
                                                              : "(" + s.yMin + ", " + s.uMin + ", " + s.vMin + ")"
                                                    return "<span style=\"color:#6c8\">min</span> " + val
                                                }
                                                color: "#dde"; font.pixelSize: 10; font.bold: true
                                                font.family: "Menlo, Monaco, Consolas, monospace"
                                                textFormat: Text.RichText
                                            }
                                            // max
                                            Text {
                                                Layout.fillWidth: true
                                                Layout.alignment: Qt.AlignHCenter
                                                text: {
                                                    const s = parent.parent.s
                                                    const ch = parent.parent.ch
                                                    const val = (ch === 0) ? s.yMax
                                                              : (ch === 1) ? s.uMax
                                                              : (ch === 2) ? s.vMax
                                                              : "(" + s.yMax + ", " + s.uMax + ", " + s.vMax + ")"
                                                    return "<span style=\"color:#e86\">max</span> " + val
                                                }
                                                color: "#dde"; font.pixelSize: 10; font.bold: true
                                                font.family: "Menlo, Monaco, Consolas, monospace"
                                                textFormat: Text.RichText
                                            }
                                        }
                                    }
                                }
                            }
                        } // end Item slotScreen

                        // ── 内嵌悬浮控制条：叠加在画面底部，鼠标悬浮画面区域时淡入，
                        //    移出后淡出。样式沿用原底部控制栏（胶囊通道按钮 + 播放控制组）。
                        Rectangle {
                            id: slotFloatBar
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 36
                            color: "#cc18181c"
                            opacity: (slotStageHover.hovered || pixelHoverArea.pinned) ? 1.0 : 0.0
                            visible: opacity > 0.01
                            Behavior on opacity { NumberAnimation { duration: 160 } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 4

                                // 通道切换按钮（紧凑胶囊样式）
                                Row {
                                    spacing: 0

                                    Repeater {
                                        model: ["YUV", "Y", "U", "V"]
                                        delegate: Rectangle {
                                            required property int index
                                            required property string modelData

                                            property bool isActive: {
                                                const _ = slotWin.ver
                                                return YuvBridge.displayMode(slotWin.index) === index
                                            }

                                            width: index === 0 ? 38 : 28
                                            height: 22
                                            radius: index === 0 ? 4 : (index === 3 ? 4 : 0)

                                            // 胶囊左右圆角
                                            Rectangle {
                                                visible: index === 0
                                                anchors.right: parent.right
                                                width: parent.radius
                                                height: parent.height
                                                color: parent.color
                                            }
                                            Rectangle {
                                                visible: index === 3
                                                anchors.left: parent.left
                                                width: parent.radius
                                                height: parent.height
                                                color: parent.color
                                            }

                                            color: isActive ? "#e05050" : "#2a2a34"
                                            border.color: isActive ? "#e05050" : "#3a3a44"
                                            border.width: isActive ? 0 : 1

                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData
                                                color: isActive ? "#fff" : "#aaa"
                                                font.pixelSize: 10
                                                font.bold: isActive
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: YuvBridge.setDisplayMode(slotWin.index, index)
                                            }
                                        }
                                    }
                                }

                                Item { width: 8 }

                                // 帧号显示
                                Text {
                                    text: {
                                        const _ = slotWin.ver
                                        return (YuvBridge.currentFrame(slotWin.index) + 1) + "/" +
                                               YuvBridge.totalFrames(slotWin.index)
                                    }
                                    color: "#9aa0a6"; font.pixelSize: 11
                                }

                                Item { Layout.fillWidth: true }

                                // 帧导航 + 播放控制按钮
                                Row {
                                    spacing: 2

                                    // 快退 15 帧
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navSkipBackMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "⏮"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navSkipBackMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.skipBackward(slotWin.index, 15)
                                        }
                                    }
                                    // 帧后退（上一帧）
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navPrevMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "◀"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navPrevMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.prevFrame(slotWin.index)
                                        }
                                    }
                                    // 播放/暂停
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navPlayMa.containsMouse ? "#3a6fd8" : "#2a5fc0"
                                        Text {
                                            anchors.centerIn: parent
                                            text: {
                                                const _ = slotWin.ver
                                                return YuvBridge.isPlaying(slotWin.index) ? "⏸" : "▶"
                                            }
                                            color: "#fff"; font.pixelSize: 11
                                        }
                                        MouseArea {
                                            id: navPlayMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.togglePlayPause(slotWin.index)
                                        }
                                    }
                                    // 帧前进（下一帧）
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navNextMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "▶"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navNextMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.nextFrame(slotWin.index)
                                        }
                                    }
                                    // 快进 15 帧
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navSkipFwdMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "⏭"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navSkipFwdMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.skipForward(slotWin.index, 15)
                                        }
                                    }

                                    Item { width: 8 }

                                    // 重置（回首帧）
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navResetMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "↺"; color: "#ccc"; font.pixelSize: 14 }
                                        MouseArea {
                                            id: navResetMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.resetFrame(slotWin.index)
                                        }
                                    }
                                    // 倒放
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: {
                                            const _ = slotWin.ver
                                            if (YuvBridge.isReversing(slotWin.index)) return "#b85a5a"
                                            return navRevMa.containsMouse ? "#3a3a3d" : "#252528"
                                        }
                                        Text { anchors.centerIn: parent; text: "◀◀"; color: "#ccc"; font.pixelSize: 9 }
                                        MouseArea {
                                            id: navRevMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (YuvBridge.isReversing(slotWin.index))
                                                    YuvBridge.pause(slotWin.index)
                                                else
                                                    YuvBridge.playReverse(slotWin.index)
                                            }
                                        }
                                    }

                                    Item { width: 8 }

                                    // 一键居中（重置平移）
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navCenterMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "⊙"; color: "#ccc"; font.pixelSize: 13 }
                                        MouseArea {
                                            id: navCenterMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                yuvDisp.panX = 0
                                                yuvDisp.panY = 0
                                            }
                                        }
                                    }
                                }
                            }
                        } // end Rectangle slotFloatBar
                        } // end Item slotStage
                    }
                }
            }
        }

        // ── 最下方：返回 + 全局总控（同时作用于所有已打开 slot）──────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: "#18181c"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 6

                // 返回
                Rectangle {
                    width: 68; height: 26; radius: 4
                    color: backBtnMa.containsMouse ? "#3a3a3d" : "#252528"
                    Text {
                        anchors.centerIn: parent
                        text: "← 返回"
                        color: "#ccc"; font.pixelSize: 12
                    }
                    MouseArea {
                        id: backBtnMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: yuvView.closeRequested()
                    }
                }

                Rectangle { width: 1; height: 20; color: "#333" }

                Text {
                    text: "总控 · " + yuvView.openSlotCount + " 路"
                    color: "#9aa0a6"; font.pixelSize: 11
                }

                // 通道切换（作用于所有 slot）
                Row {
                    spacing: 0
                    Repeater {
                        model: ["YUV", "Y", "U", "V"]
                        delegate: Rectangle {
                            required property int index
                            required property string modelData
                            property bool isActive: {
                                const _ = yuvView.globalVer
                                return yuvView.globalAllModeIs(index)
                            }
                            width: index === 0 ? 38 : 28
                            height: 22
                            radius: index === 0 ? 4 : (index === 3 ? 4 : 0)

                            Rectangle {
                                visible: index === 0
                                anchors.right: parent.right
                                width: parent.radius
                                height: parent.height
                                color: parent.color
                            }
                            Rectangle {
                                visible: index === 3
                                anchors.left: parent.left
                                width: parent.radius
                                height: parent.height
                                color: parent.color
                            }

                            color: isActive ? "#e05050" : "#2a2a34"
                            border.color: isActive ? "#e05050" : "#3a3a44"
                            border.width: isActive ? 0 : 1

                            Text {
                                anchors.centerIn: parent
                                text: modelData
                                color: isActive ? "#fff" : "#aaa"
                                font.pixelSize: 10
                                font.bold: isActive
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: yuvView.globalSetDisplayMode(index)
                            }
                        }
                    }
                }

                Item { width: 8 }

                // 播放控制（作用于所有 slot）
                Row {
                    spacing: 2

                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gSkipBackMa.containsMouse ? "#3a3a3d" : "#252528"
                        Text { anchors.centerIn: parent; text: "⏮"; color: "#ccc"; font.pixelSize: 11 }
                        MouseArea {
                            id: gSkipBackMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: yuvView.globalSkipBackward()
                        }
                    }
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gPrevMa.containsMouse ? "#3a3a3d" : "#252528"
                        Text { anchors.centerIn: parent; text: "◀"; color: "#ccc"; font.pixelSize: 11 }
                        MouseArea {
                            id: gPrevMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: yuvView.globalPrevFrame()
                        }
                    }
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gPlayMa.containsMouse ? "#3a6fd8" : "#2a5fc0"
                        Text {
                            anchors.centerIn: parent
                            text: {
                                const _ = yuvView.globalVer
                                return yuvView.globalAnyPlaying() ? "⏸" : "▶"
                            }
                            color: "#fff"; font.pixelSize: 11
                        }
                        MouseArea {
                            id: gPlayMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: yuvView.globalTogglePlayPause()
                        }
                    }
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gNextMa.containsMouse ? "#3a3a3d" : "#252528"
                        Text { anchors.centerIn: parent; text: "▶"; color: "#ccc"; font.pixelSize: 11 }
                        MouseArea {
                            id: gNextMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: yuvView.globalNextFrame()
                        }
                    }
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gSkipFwdMa.containsMouse ? "#3a3a3d" : "#252528"
                        Text { anchors.centerIn: parent; text: "⏭"; color: "#ccc"; font.pixelSize: 11 }
                        MouseArea {
                            id: gSkipFwdMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: yuvView.globalSkipForward()
                        }
                    }

                    Item { width: 8 }

                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gResetMa.containsMouse ? "#3a3a3d" : "#252528"
                        Text { anchors.centerIn: parent; text: "↺"; color: "#ccc"; font.pixelSize: 14 }
                        MouseArea {
                            id: gResetMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: yuvView.globalResetFrame()
                        }
                    }
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: {
                            const _ = yuvView.globalVer
                            return gRevMa.containsMouse ? "#3a3a3d" : "#252528"
                        }
                        Text { anchors.centerIn: parent; text: "◀◀"; color: "#ccc"; font.pixelSize: 9 }
                        MouseArea {
                            id: gRevMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: yuvView.globalToggleReverse()
                        }
                    }

                    Item { width: 8 }

                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gCenterMa.containsMouse ? "#3a3a3d" : "#252528"
                        Text { anchors.centerIn: parent; text: "⊙"; color: "#ccc"; font.pixelSize: 13 }
                        MouseArea {
                            id: gCenterMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: yuvView.centerAllRequested()
                        }
                    }
                }

                Item { Layout.fillWidth: true }
            }
        }
    }

    // ── 对比模式浮窗组：YUV-A / YUV-B / 差异Δ 三个面板挨在一起 ─────────────
    // 顶层放置（z 最高），不受任何 slot 的 clip:true 裁剪；跟随鼠标或固定后
    // 冻结在 cmpGroupX/Y；拖动其中任一面板的网格都会更新共享的
    // cmpScrollX/cmpScrollY，故三者始终同步滚动。
    Row {
        id: cmpGroup
        visible: yuvView.cmpActive && yuvView.cmpShow
        spacing: 8
        z: 1000
        x: yuvView.cmpPinned ? yuvView.cmpGroupX : yuvView.cmpComputeGroupX(yuvView.cmpMouseX)
        y: yuvView.cmpPinned ? yuvView.cmpGroupY : yuvView.cmpComputeGroupY(yuvView.cmpMouseY)

        CompareMatrixPanel { title: "YUV-A · slot " + yuvView.cmpSlotA; mode: "a" }
        CompareMatrixPanel { title: "YUV-B · slot " + yuvView.cmpSlotB; mode: "b" }
        CompareMatrixPanel { title: "差异 Δ = A − B"; mode: "diff" }
    }
}
