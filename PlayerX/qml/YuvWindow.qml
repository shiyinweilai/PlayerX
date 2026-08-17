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

                            YuvDisplayItem {
                                id: yuvDisp
                                anchors.fill: parent
                                image: {
                                    const _ = slotWin.ver
                                    return YuvBridge.frameImage(slotWin.index)
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

                                onPositionChanged: function(mouse) {
                                    // 将鼠标坐标映射到图像坐标
                                    // YuvDisplayItem 使用 1:1 原尺寸居中（不缩放）
                                    const imgW = YuvBridge.width(slotWin.index)
                                    const imgH = YuvBridge.height(slotWin.index)
                                    if (imgW <= 0 || imgH <= 0) return

                                    const dispW = pixelHoverArea.width
                                    const dispH = pixelHoverArea.height

                                    // 1:1 居中偏移（与 YuvDisplayItem::paint 一致）
                                    const offX = (dispW - imgW) / 2.0
                                    const offY = (dispH - imgH) / 2.0

                                    const ix = Math.floor(mouse.x - offX)
                                    const iy = Math.floor(mouse.y - offY)

                                    if (ix >= 0 && ix < imgW && iy >= 0 && iy < imgH) {
                                        pixelX = ix
                                        pixelY = iy
                                        showPixelGrid = true
                                        pixelData = YuvBridge.pixelBlock8x8(slotWin.index, ix, iy)
                                    } else {
                                        showPixelGrid = false
                                    }
                                }
                                onExited: showPixelGrid = false
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
                                    const offX = (dispW - imgW) / 2.0
                                    const blockX = Math.floor(pixelHoverArea.pixelX / 8) * 8
                                    return offX + blockX
                                }
                                y: {
                                    const imgH = YuvBridge.height(slotWin.index)
                                    const dispH = pixelHoverArea.height
                                    const offY = (dispH - imgH) / 2.0
                                    const blockY = Math.floor(pixelHoverArea.pixelY / 8) * 8
                                    return offY + blockY
                                }
                            }

                            // ── 8×8 像素矩阵浮窗 ──
                            Rectangle {
                                id: pixelGridPopup
                                visible: pixelHoverArea.showPixelGrid && pixelHoverArea.pixelData.length === 64
                                width: 320
                                height: 290
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

                                    // 通道选择 tabs
                                    Row {
                                        spacing: 2
                                        property int channel: 0  // 0=Y, 1=U, 2=V

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
                                                    onClicked: parent.parent.channel = index
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

                                        property int channel: parent.children[1].channel !== undefined
                                                              ? parent.children[1].channel : 0

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
                                                    const val = ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                                    // 根据值映射背景色
                                                    const t = val / 255.0
                                                    const r = Math.round(30 + t * 60)
                                                    const g = Math.round(30 + t * 80)
                                                    const b = Math.round(40 + t * 100)
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
                                                    color: "#e0e0e0"
                                                    font.pixelSize: 9
                                                    font.family: "Menlo, Monaco, Consolas, monospace"
                                                }
                                            }
                                        }
                                    }

                                    // 当前像素坐标值
                                    Text {
                                        text: {
                                            if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length === 0)
                                                return ""
                                            const px = pixelHoverArea.pixelX
                                            const py = pixelHoverArea.pixelY
                                            // 找到鼠标所在的那个像素在 block 中的位置
                                            const bx = Math.floor(px / 8) * 8
                                            const by = Math.floor(py / 8) * 8
                                            const lx = px - bx
                                            const ly = py - by
                                            const idx = ly * 8 + lx
                                            if (idx >= 0 && idx < pixelHoverArea.pixelData.length) {
                                                const p = pixelHoverArea.pixelData[idx]
                                                return "(" + px + "," + py + ")  Y=" + p.y + " U=" + p.u + " V=" + p.v
                                            }
                                            return ""
                                        }
                                        color: "#8af"; font.pixelSize: 10
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

                                // 帧导航按钮
                                Row {
                                    spacing: 2

                                    // 首帧
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navFirstMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "⏮"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navFirstMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.firstFrame(slotWin.index)
                                        }
                                    }
                                    // 上一帧
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
                                    // 跳转输入
                                    Rectangle {
                                        width: 44; height: 22; radius: 3
                                        color: "#1e1e24"; border.color: "#3a3a44"; border.width: 1
                                        TextInput {
                                            id: jumpInput
                                            anchors.fill: parent; anchors.margins: 3
                                            color: "#e0e0e0"; font.pixelSize: 10
                                            horizontalAlignment: TextInput.AlignHCenter
                                            validator: IntValidator { bottom: 1 }
                                        }
                                    }
                                    Rectangle {
                                        width: 30; height: 22; radius: 3
                                        color: jumpGoMa.containsMouse ? "#3a6fd8" : "#2a5fc0"
                                        Text { anchors.centerIn: parent; text: "GO"; color: "#fff"; font.pixelSize: 10; font.bold: true }
                                        MouseArea {
                                            id: jumpGoMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                const n = parseInt(jumpInput.text)
                                                if (n >= 1 && n <= YuvBridge.totalFrames(slotWin.index))
                                                    YuvBridge.gotoFrame(slotWin.index, n - 1)
                                            }
                                        }
                                    }
                                    // 下一帧
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
                                    // 末帧
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navLastMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "⏭"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navLastMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.lastFrame(slotWin.index)
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
