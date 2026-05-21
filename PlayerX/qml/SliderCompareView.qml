// SliderCompareView.qml — 双路视频"滑动比较"视图（独立组件）
//
// 设计：
//   - 完全独立的 QML 组件，不与 Main.qml 中的 Grid 视图共享任何状态。
//   - 仅在 fileCount === 2 时被 Main.qml 启用显示。
//   - 内部：
//       * SliderCompareItem 铺满，根据鼠标 x 实时更新 splitRatio
//       * 两侧各一个"通道信息"胶囊条（帧号 / 时间戳 / 文件名）—— 复用
//         Main.qml 中 channelBar 的视觉规格，但分别绑定 leftIndex / rightIndex
//   - 不接管任何播放控制：播放 / 暂停 / 快进快退 / 帧步进 / 数字键 / R / F / V / C 等
//     仍由 Main.qml 现有 Shortcut + ToolBar 实现 —— 行为与 Grid 模式 100% 一致。

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import PlayerX 1.0

Item {
    id: view

    // ─── 对外属性 ─────────────────────────────────────────────────────
    // engine: EngineBridge 单例（Main.qml 中以 contextProperty `Engine` 暴露）
    property var engine: null
    // 左右路索引（默认 0/1）
    property int leftIndex: 0
    property int rightIndex: 1
    // 是否显示两侧通道信息条（与 Main.qml 的 effectiveChannelVisible 联动）
    property bool channelVisible: true

    // 当前分割比（0~1），由 hover 跟随鼠标 x 更新
    property real splitRatio: 0.5

    // ─── 渲染主体 ─────────────────────────────────────────────────────
    SliderCompareItem {
        id: compareItem
        anchors.fill: parent
        engine: view.engine
        leftIndex: view.leftIndex
        rightIndex: view.rightIndex
        splitRatio: view.splitRatio
        // 关闭 QtQuick 场景图二次插值（与 VideoFrameProvider 一致）
        smooth: false
        antialiasing: false
    }

    // 鼠标跟随：hover 即跟随，无需按下 —— 与旧 PlayerX 工程 RBSliderView 行为一致
    MouseArea {
        id: tracker
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        // hover 移动 → 同步 splitRatio
        onPositionChanged: {
            if (view.width <= 0) return
            view.splitRatio = Math.max(0, Math.min(1, mouseX / view.width))
        }
        // 鼠标按下也同步一次（点中即移动到该处）
        onPressed: {
            if (view.width <= 0) return
            view.splitRatio = Math.max(0, Math.min(1, mouseX / view.width))
        }
        // 鼠标离开时保持上一次位置（不强制回中），符合 video-compare 习惯
    }

    // ─── 全局缩放/平移交互层（与 VideoCellDelegate 用同一组 Engine 状态）────────
    // 关键设计：把 MouseArea + WheelHandler + TapHandler 装在同一容器上，避免
    // QML 中"两层 MouseArea 嵌套" + "WheelHandler 在 Item 上"的事件丢失问题。
    // 与左键跟随分割条互不冲突：本 MouseArea 只接 RightButton；左键事件继续透传给 tracker。
    MouseArea {
        id: viewXformLayer
        anchors.fill: parent
        z: 4   // 高于 tracker 的左键跟随，但低于左右通道信息条 (z:5)
        acceptedButtons: Qt.RightButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.ArrowCursor

        function _normMouse(mx, my) {
            var w = Math.max(1, viewXformLayer.width)
            var h = Math.max(1, viewXformLayer.height)
            return Qt.point(Math.max(0, Math.min(1, mx / w)),
                            Math.max(0, Math.min(1, my / h)))
        }

        property real _lastX: 0
        property real _lastY: 0
        onPressed: function(mouse) {
            _lastX = mouse.x
            _lastY = mouse.y
            mouse.accepted = true
        }
        onPositionChanged: function(mouse) {
            if (!view.engine) return
            if (view.engine.viewZoom <= 1.0001) return
            var dx = mouse.x - _lastX
            var dy = mouse.y - _lastY
            _lastX = mouse.x
            _lastY = mouse.y
            if (Math.abs(dx) + Math.abs(dy) < 0.5) return
            var w = Math.max(1, viewXformLayer.width)
            var h = Math.max(1, viewXformLayer.height)
            view.engine.panBy(dx / w, dy / h)
        }

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            target: null
            onWheel: function(event) {
                if (!view.engine || view.engine.fileCount <= 0) return
                var dy = event.angleDelta.y
                if (dy === 0) return
                var step = dy / 120.0
                if (Math.abs(step) < 1e-3) step = (dy > 0 ? 0.05 : -0.05)
                var factor = Math.pow(2.0, step / 12.0)
                var n = viewXformLayer._normMouse(event.x, event.y)
                view.engine.zoomBy(factor, n.x, n.y)
                event.accepted = true
            }
        }

        TapHandler {
            acceptedButtons: Qt.LeftButton
            acceptedModifiers: Qt.ControlModifier
            onDoubleTapped: { if (view.engine) view.engine.resetViewTransform() }
        }
    }

    // ─── 左侧通道信息条 ──────────────────────────────────────────────
    Rectangle {
        id: leftBar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 8
        radius: 3
        color: "#aa000000"
        z: 5
        visible: view.channelVisible
        implicitWidth:  leftRow.implicitWidth + 12
        implicitHeight: leftRow.implicitHeight + 4
        width:  implicitWidth
        height: implicitHeight

        property var info: ({})
        function refreshInfo() {
            if (visible && view.engine) info = view.engine.videoInfoAt(view.leftIndex)
        }
        Connections {
            target: view.engine
            function onPositionChanged() { leftBar.refreshInfo() }
        }
        onVisibleChanged: refreshInfo()
        Component.onCompleted: refreshInfo()

        RowLayout {
            id: leftRow
            anchors.centerIn: parent
            spacing: 8

            // 标记 L
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
                text: leftBar.info.frameNum !== undefined
                      ? "#" + leftBar.info.frameNum
                      : "#—"
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#e8e8ec"
                font.pixelSize: 11
                font.family: "Menlo, Monaco, Courier New, monospace"
                horizontalAlignment: Text.AlignRight
                Layout.minimumWidth: 70
                Layout.preferredWidth: 70
                text: leftBar.info.pts !== undefined
                      ? leftBar.info.pts.toFixed(3) + "s"
                      : "—"
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#dcdcde"
                font.pixelSize: 11
                // 走 titles[idx] 响应式绑定，fileNameAt() 是函数调用不能随 Engine 切视频刷新
                text: {
                    if (!view.engine) return ""
                    var arr = view.engine.titles
                    var i = view.leftIndex
                    return (i >= 0 && i < arr.length) ? arr[i] : ""
                }
                elide: Text.ElideMiddle
                Layout.maximumWidth: Math.max(120, view.width / 3)
            }
        }
    }

    // ─── 右侧通道信息条 ──────────────────────────────────────────────
    Rectangle {
        id: rightBar
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        radius: 3
        color: "#aa000000"
        z: 5
        visible: view.channelVisible
        implicitWidth:  rightRow.implicitWidth + 12
        implicitHeight: rightRow.implicitHeight + 4
        width:  implicitWidth
        height: implicitHeight

        property var info: ({})
        function refreshInfo() {
            if (visible && view.engine) info = view.engine.videoInfoAt(view.rightIndex)
        }
        Connections {
            target: view.engine
            function onPositionChanged() { rightBar.refreshInfo() }
        }
        onVisibleChanged: refreshInfo()
        Component.onCompleted: refreshInfo()

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
                text: rightBar.info.frameNum !== undefined
                      ? "#" + rightBar.info.frameNum
                      : "#—"
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#e8e8ec"
                font.pixelSize: 11
                font.family: "Menlo, Monaco, Courier New, monospace"
                horizontalAlignment: Text.AlignRight
                Layout.minimumWidth: 70
                Layout.preferredWidth: 70
                text: rightBar.info.pts !== undefined
                      ? rightBar.info.pts.toFixed(3) + "s"
                      : "—"
            }
            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
            Text {
                color: "#dcdcde"
                font.pixelSize: 11
                text: {
                    if (!view.engine) return ""
                    var arr = view.engine.titles
                    var i = view.rightIndex
                    return (i >= 0 && i < arr.length) ? arr[i] : ""
                }
                elide: Text.ElideMiddle
                Layout.maximumWidth: Math.max(120, view.width / 3)
            }
        }
    }

    // ─── 顶部中央"滑动模式"小标识 ───────────────────────────────────
    Rectangle {
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 8
        radius: 3
        color: "#88000000"
        visible: view.channelVisible
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
