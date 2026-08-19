import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX.YuvTools

/**
 * YuvWindow.qml — YUV 多窗口渲染子界面
 *
 * 布局：顶部仅有返回按钮和标题，中间为画面区域，底部为控制栏。
 * 每个 slot 独立：通道切换 + 帧导航 + 8×8 像素矩阵悬浮显示。
 */

Item {
    id: yuvView
    signal closeRequested()

    property int openSlotCount: YuvBridge.slotCount

    Rectangle {
        anchors.fill: parent
        color: "#101012"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── 顶部栏：返回 + 标题 ─────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: "#18181c"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 12

                Rectangle {
                    width: 72; height: 28; radius: 4
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

                Text {
                    text: "YUV 渲染 · " + yuvView.openSlotCount + " 路"
                    color: "#e0e0e0"; font.pixelSize: 15; font.bold: true
                }

                Item { Layout.fillWidth: true }
            }
        }

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

                        // ── 画面区域 ──
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
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

                            // 鼠标悬浮区域，用于显示 8×8 像素块
                            MouseArea {
                                id: pixelHoverArea
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                                propagateComposedEvents: true

                                property bool showPixelGrid: false
                                property int pixelX: 0
                                property int pixelY: 0
                                property var pixelData: []
                                // 8×8 块的统计值：{ yAvg,yMin,yMax, uAvg,uMin,uMax, vAvg,vMin,vMax }
                                property var pixelStats: ({})

                                onPositionChanged: function(mouse) {
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
                                        pixelX = ix
                                        pixelY = iy
                                        showPixelGrid = true
                                        pixelData = YuvBridge.pixelBlock8x8(slotWin.index, ix, iy)
                                        pixelStats = YuvBridge.pixelBlockStats8x8(slotWin.index, ix, iy)
                                        // 上报全局悬浮像素坐标，供右侧栏"块级别"统计实时跟随
                                        YuvBridge.setHoverPixel(slotWin.index, ix, iy, true)
                                    } else {
                                        showPixelGrid = false
                                        YuvBridge.setHoverPixel(slotWin.index, 0, 0, false)
                                    }
                                }
                                onExited: {
                                    showPixelGrid = false
                                    YuvBridge.setHoverPixel(slotWin.index, 0, 0, false)
                                }
                            }

                            // ── 8×8 像素块 hover 高亮边框 ──
                            Rectangle {
                                id: blockHighlight
                                visible: pixelHoverArea.showPixelGrid
                                width: 8
                                height: 8
                                color: "transparent"
                                border.color: "#00FF88"
                                border.width: 2
                                radius: 1

                                // 定位到当前像素所在的8×8块（对齐到块边界）
                                x: {
                                    const imgW = YuvBridge.width(slotWin.index)
                                    const dispW = pixelHoverArea.width
                                    const offX = (dispW - imgW) / 2.0 + yuvDisp.panX
                                    const blockX = Math.floor(pixelHoverArea.pixelX / 8) * 8
                                    return offX + blockX
                                }
                                y: {
                                    const imgH = YuvBridge.height(slotWin.index)
                                    const dispH = pixelHoverArea.height
                                    const offY = (dispH - imgH) / 2.0 + yuvDisp.panY
                                    const blockY = Math.floor(pixelHoverArea.pixelY / 8) * 8
                                    return offY + blockY
                                }
                            }

                            // ── 8×8 像素矩阵浮窗 ──
                            Rectangle {
                                id: pixelGridPopup
                                visible: pixelHoverArea.showPixelGrid && pixelHoverArea.pixelData.length === 64
                                width: 320
                                height: 295
                                radius: 6
                                color: "#1a1a22"
                                border.color: "#3a3a4a"
                                border.width: 1
                                opacity: 0.95

                                // 定位：智能避让，确保不遮挡鼠标附近的视频内容
                                // X轴：优先放右侧，放不下则放左侧
                                x: {
                                    const mx = pixelHoverArea.mouseX
                                    const pw = parent.width
                                    const rightX = mx + 20
                                    const leftX = mx - width - 20
                                    // 右侧能完整显示则放右侧，否则放左侧
                                    if (rightX + width + 8 <= pw) {
                                        return rightX
                                    } else if (leftX >= 8) {
                                        return leftX
                                    } else {
                                        // 两侧都放不下时，贴右边界
                                        return pw - width - 8
                                    }
                                }
                                // Y轴：优先放上方，放不下则放下方
                                y: {
                                    const my = pixelHoverArea.mouseY
                                    const ph = parent.height
                                    const topY = my - height - 20
                                    const bottomY = my + 20
                                    // 上方能完整显示则放上方，否则放下方
                                    if (topY >= 8) {
                                        return topY
                                    } else if (bottomY + height + 8 <= ph) {
                                        return bottomY
                                    } else {
                                        // 都放不下时，贴顶部
                                        return 8
                                    }
                                }

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 4

                                    // 标题
                                    Text {
                                        text: {
                                            const bx = Math.floor(pixelHoverArea.pixelX / 8) * 8
                                            const by = Math.floor(pixelHoverArea.pixelY / 8) * 8
                                            return "像素块 [" + bx + "," + by + "] ~ [" + (bx+7) + "," + (by+7) + "]"
                                        }
                                        color: "#aaa"; font.pixelSize: 10
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
                                                    color: parent.parent.parent.channel === index ? "#fff" : "#888"
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

                                    // 8×8 网格
                                    Grid {
                                        id: pixelGrid
                                        columns: 8
                                        rows: 8
                                        spacing: 1
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true

                                        property int channel: channelTabs ? channelTabs.channel : 0

                                        // 当前通道下、当前 8×8 块的原始值域（不用位深，按真实数据自适应）
                                        //   - 8bit 块：0-255
                                        //   - 10bit 块：0-1023
                                        //   - 极端全黑/全亮：min==max，span=1，"t" 退化为 0（保证不出错）
                                        property int blockMin: 0
                                        property int blockMax: 1
                                        function recomputeRange() {
                                            if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length !== 64) {
                                                blockMin = 0; blockMax = 1; return
                                            }
                                            const ch = channel
                                            let mn = 65535, mx = -1
                                            for (let i = 0; i < 64; ++i) {
                                                const v = ch === 0 ? pixelHoverArea.pixelData[i].y
                                                                  : (ch === 1 ? pixelHoverArea.pixelData[i].u
                                                                              : pixelHoverArea.pixelData[i].v)
                                                if (v < mn) mn = v
                                                if (v > mx) mx = v
                                            }
                                            if (mn === mx) { blockMin = mn; blockMax = mn + 1 }
                                            else           { blockMin = mn; blockMax = mx }
                                        }
                                        // 通道/数据任一变化都要重算
                                        onChannelChanged: recomputeRange()
                                        Component.onCompleted: recomputeRange()
                                        Connections {
                                            target: pixelHoverArea
                                            function onPixelDataChanged() { pixelGrid.recomputeRange() }
                                        }

                                        Repeater {
                                            model: 64
                                            delegate: Rectangle {
                                                required property int index
                                                width: (pixelGrid.width - 7) / 8
                                                height: (pixelGrid.height - 7) / 8
                                                radius: 2
                                                color: {
                                                    if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length <= index)
                                                        return "#222"
                                                    const pix = pixelHoverArea.pixelData[index]
                                                    const ch = pixelGrid.channel
                                                    const raw = ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                                    // ── 自适应背景色 ──
                                                    // 像素值按"位深未知"处理：直接拿当前 8×8 块的动态范围 (min..max) 归一化。
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
                                                    font.pixelSize: 9
                                                    font.family: "Menlo, Monaco, Consolas, monospace"
                                                    font.bold: true
                                                }
                                            }
                                        }
                                    }

                                    // 8×8 块 YUV 统计：avg / min / max 三行合一，用 | 分隔
                                    Column {
                                        spacing: 1
                                        property var s: pixelHoverArea.pixelStats || {}
                                        property bool ready: (typeof s.yAvg === "number")

                                        Text {
                                            visible: parent.ready
                                            text: "<span style=\"color:#6cf\">avg</span> (" + parent.s.yAvg + ", " + parent.s.uAvg + ", " + parent.s.vAvg + ")"
                                                + "  <span style=\"color:#6c8\">min</span> (" + parent.s.yMin + ", " + parent.s.uMin + ", " + parent.s.vMin + ")"
                                                + "  <span style=\"color:#e86\">max</span> (" + parent.s.yMax + ", " + parent.s.uMax + ", " + parent.s.vMax + ")"
                                            color: "#dde"; font.pixelSize: 10; font.bold: true
                                            font.family: "Menlo, Monaco, Consolas, monospace"
                                            textFormat: Text.RichText
                                        }
                                    }
                                }
                            }
                        }

                        // ── 底部控制栏 ──
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            color: "#18181c"

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
                        }
                    }
                }
            }
        }
    }
}
