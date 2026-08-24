// YuvSliderCompareView.qml — YUV 双路滑动对比视图（独立组件）
//
// 设计：
//   - 完全独立的 QML 组件，仅在 YuvWindow 中 cmpActive（2 路）且
//     sliderCompareActive 时通过 Loader 加载显示。
//   - 内部使用 YuvSliderCompareItem 渲染两路 YUV 画面，鼠标 x 实时更新 splitRatio。
//   - 不接管播放 / 帧导航控制，仍由 YuvWindow 底部总控栏统一操作。
//   - 右键拖拽平移（panX/panY）、滚轮缩放（YuvBridge.bumpScale）。
//   - 两侧通道信息条（L / R：帧号 + 文件名），顶部"滑动对比"标识。
//   - 与播放对比的 SliderCompareView 完全隔离，不复用其任何状态或组件。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX.YuvTools

Item {
    id: view

    // ── 内部状态 ──
    property int frameVer: 0          // 帧刷新版本号，驱动 leftImage/rightImage 绑定
    property real splitRatio: 0.5     // 分割比例 [0, 1]
    property bool infoVisible: true   // L/R 通道信息条显隐（C 键切换）

    // 监听 YuvBridge 帧/通道变化，递增 frameVer 使 image 绑定重新求值
    // 同时监听 toggleSlotInfoRequested 信号，与多窗口模式同步显隐
    Connections {
        target: YuvBridge
        function onFrameChanged(slot) { view.frameVer++ }
        function onDisplayModeChanged(slot) { view.frameVer++ }
        function onPlayStateChanged(slot) { view.frameVer++ }
        function onToggleSlotInfoRequested() { view.infoVisible = !view.infoVisible }
    }

    // ─── 渲染主体 ─────────────────────────────────────────────────────
    YuvSliderCompareItem {
        id: compareItem
        anchors.fill: parent
        leftImage: {
            const _ = view.frameVer
            return YuvBridge.frameImage(0)
        }
        rightImage: {
            const _ = view.frameVer
            return YuvBridge.frameImage(1)
        }
        splitRatio: view.splitRatio

        // 监听全局缩放变化，与 YuvDisplayItem 同步
        Connections {
            target: YuvBridge
            function onGlobalScaleChanged() {
                compareItem.onGlobalScaleChanged(YuvBridge.globalScale)
            }
            function onResetViewChanged() {
                compareItem.panX = 0
                compareItem.panY = 0
            }
        }
    }

    // ─── 鼠标跟随：hover 即跟随分割条 ──────────────────────────────────
    MouseArea {
        id: tracker
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onPositionChanged: {
            if (view.width <= 0) return
            view.splitRatio = Math.max(0, Math.min(1, mouseX / view.width))
        }
        onPressed: {
            if (view.width <= 0) return
            view.splitRatio = Math.max(0, Math.min(1, mouseX / view.width))
        }
    }

    // ─── 右键拖拽平移 + 滚轮缩放 ──────────────────────────────────────
    MouseArea {
        id: xformLayer
        anchors.fill: parent
        z: 4   // 高于 tracker，但低于通道信息条 (z:5)
        acceptedButtons: Qt.RightButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.ArrowCursor

        property real lastX: 0
        property real lastY: 0
        onPressed: function(mouse) {
            lastX = mouse.x
            lastY = mouse.y
            mouse.accepted = true
        }
        onPositionChanged: function(mouse) {
            if (!pressed) return
            compareItem.panX += mouse.x - lastX
            compareItem.panY += mouse.y - lastY
            lastX = mouse.x
            lastY = mouse.y
        }
        // 右键双击：重置平移归位
        onDoubleClicked: {
            compareItem.panX = 0
            compareItem.panY = 0
        }

        // 滚轮缩放：与 YuvWindow 的全局缩放联动
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            target: null
            onWheel: function(event) {
                var dy = event.angleDelta.y
                if (dy === 0) return
                if (dy > 0) YuvBridge.bumpScale(1)
                else YuvBridge.bumpScale(-1)
                event.accepted = true
            }
        }

        // Ctrl+双击：重置视图（缩放回 1X + 平移归零）
        TapHandler {
            acceptedButtons: Qt.LeftButton
            acceptedModifiers: Qt.ControlModifier
            onDoubleTapped: YuvBridge.resetView()
        }
    }

    // ─── 左侧通道信息条 ──────────────────────────────────────────────
    Rectangle {
        id: leftBar
        visible: view.infoVisible
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 8
        radius: 3
        color: "#aa000000"
        z: 5
        implicitWidth:  leftRow.implicitWidth + 12
        implicitHeight: leftRow.implicitHeight + 4
        width:  implicitWidth
        height: implicitHeight

        RowLayout {
            id: leftRow
            anchors.centerIn: parent
            spacing: 8

            Text {
                color: "#a8d8ff"; font.pixelSize: 11; font.bold: true
                text: "L"
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#e8e8ec"
                font.pixelSize: 11
                font.family: "Menlo, Monaco, Courier New, monospace"
                horizontalAlignment: Text.AlignRight
                Layout.minimumWidth: 56
                Layout.preferredWidth: 56
                text: {
                    const _ = view.frameVer
                    if (YuvBridge.slotCount > 0)
                        return "#" + (YuvBridge.currentFrame(0) + 1)
                    return "#—"
                }
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#e8e8ec"
                font.pixelSize: 11
                font.family: "Menlo, Monaco, Courier New, monospace"
                horizontalAlignment: Text.AlignRight
                Layout.minimumWidth: 70
                Layout.preferredWidth: 70
                text: {
                    const _ = view.frameVer
                    if (YuvBridge.slotCount > 0) {
                        var total = YuvBridge.totalFrames(0)
                        return total > 0 ? total + " 帧" : "—"
                    }
                    return "—"
                }
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#dcdcde"
                font.pixelSize: 11
                text: {
                    const _ = view.frameVer
                    if (YuvBridge.slotCount > 0)
                        return YuvBridge.fileName(0)
                    return ""
                }
                elide: Text.ElideMiddle
                Layout.maximumWidth: Math.max(120, view.width / 3)
            }
        }
    }

    // ─── 右侧通道信息条 ──────────────────────────────────────────────
    Rectangle {
        id: rightBar
        visible: view.infoVisible
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        radius: 3
        color: "#aa000000"
        z: 5
        implicitWidth:  rightRow.implicitWidth + 12
        implicitHeight: rightRow.implicitHeight + 4
        width:  implicitWidth
        height: implicitHeight

        RowLayout {
            id: rightRow
            anchors.centerIn: parent
            spacing: 8

            Text {
                color: "#ffd0a8"; font.pixelSize: 11; font.bold: true
                text: "R"
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#e8e8ec"
                font.pixelSize: 11
                font.family: "Menlo, Monaco, Courier New, monospace"
                horizontalAlignment: Text.AlignRight
                Layout.minimumWidth: 56
                Layout.preferredWidth: 56
                text: {
                    const _ = view.frameVer
                    if (YuvBridge.slotCount > 1)
                        return "#" + (YuvBridge.currentFrame(1) + 1)
                    return "#—"
                }
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#e8e8ec"
                font.pixelSize: 11
                font.family: "Menlo, Monaco, Courier New, monospace"
                horizontalAlignment: Text.AlignRight
                Layout.minimumWidth: 70
                Layout.preferredWidth: 70
                text: {
                    const _ = view.frameVer
                    if (YuvBridge.slotCount > 1) {
                        var total = YuvBridge.totalFrames(1)
                        return total > 0 ? total + " 帧" : "—"
                    }
                    return "—"
                }
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#dcdcde"
                font.pixelSize: 11
                text: {
                    const _ = view.frameVer
                    if (YuvBridge.slotCount > 1)
                        return YuvBridge.fileName(1)
                    return ""
                }
                elide: Text.ElideMiddle
                Layout.maximumWidth: Math.max(120, view.width / 3)
            }
        }
    }

    // ─── 顶部中央"滑动对比"标识 ────────────────────────────────────────
    Rectangle {
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 8
        radius: 3
        color: "#88000000"
        implicitWidth: tag.implicitWidth + 14
        implicitHeight: tag.implicitHeight + 4
        Text {
            id: tag
            anchors.centerIn: parent
            text: "⇆ 滑动对比 (B 退出)"
            color: "#cfcfd2"
            font.pixelSize: 11
        }
    }
}
