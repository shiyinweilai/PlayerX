// RefLightbox.qml — 参考图放大查看 Lightbox（从 Main.qml 拆分）
// 用法：在 Main.qml 中实例化，通过 required property 传入参考图相关状态。
//
// 设计目标：
//   · 不破坏画质：用独立的 Image 元素，sourceSize 跟随显示尺寸自适应，不复用侧栏小图缓存
//   · 不创建新原生窗口：覆盖在主窗之上，避免抢焦点 / 多屏跳屏 / 窗口创建销毁开销
//   · 操作直觉：滚轮缩放（以鼠标为锚点）、拖拽平移、双击切换 Fit↔100%、Esc 关闭、← → 翻页
//   · 与播放器内核完全解耦：纯 QML/Image 层，零崩溃风险

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: refLightbox
    anchors.fill: parent
    visible: false
    z: 999
    focus: visible

    // ── 外部传入的参考图状态（由 Main.qml 绑定） ──
    property url  refCurrentUrl: ""
    property url  refCurrentUrl2: ""
    property bool refHasCurrent: false
    property bool refHasCurrent2: false
    property int  refImageCount: 0
    property int  refImageCount2: 0
    property int  refCurrentImageIndex: 0
    property int  refCurrentImageIndex2: 0
    property bool refCanNav: false
    property bool refCanNav2: false
    // 偏移写入回调（外部绑定到 root._refImgOffset / root._refImgOffset2）
    property int  refImgOffset: 0
    property int  refImgOffset2: 0

    // ── 缩放与平移状态 ────────────────────────────────────────
    property real zoom: 1.0
    property real fitScale: 1.0
    property real panX: 0
    property real panY: 0
    readonly property real minZoom: 1.0
    readonly property real maxZoom: 10.0
    // 当前查看的是哪一槽位的参考图：1 = 上半（默认），2 = 下半
    property int currentSlot: 1
    readonly property url currentSrc: currentSlot === 2 ? refCurrentUrl2 : refCurrentUrl
    readonly property bool currentHas: currentSlot === 2 ? refHasCurrent2 : refHasCurrent
    readonly property int    currentCount: currentSlot === 2 ? refImageCount2 : refImageCount
    readonly property int    currentIndex: currentSlot === 2 ? refCurrentImageIndex2 : refCurrentImageIndex
    readonly property bool   currentCanNav: currentSlot === 2 ? refCanNav2 : refCanNav

    // 推进当前槽位的偏移
    function bumpOffset(delta) {
        if (currentSlot === 2) refImgOffset2 += delta
        else                   refImgOffset  += delta
    }
    // 是否处于"100%（实际像素）"状态
    readonly property bool atFit:    Math.abs(zoom - 1.0) < 0.001
    readonly property bool atActual: refLightboxImg.sourceSize.width > 0
                                     && Math.abs(zoom * fitScale - 1.0) < 0.001

    function open() { openSlot(1) }
    function openSlot(slot) {
        currentSlot = (slot === 2 ? 2 : 1)
        if (!currentHas) return
        zoom = 1.0; panX = 0; panY = 0
        visible = true
        forceActiveFocus()
        autoHideTimer.restart()
    }
    function close() {
        visible = false
    }
    function setZoom(newZoom, anchorX, anchorY) {
        var z0 = zoom
        var z1 = Math.max(minZoom, Math.min(maxZoom, newZoom))
        if (Math.abs(z1 - z0) < 0.0001) return
        var cx = width  / 2 + panX
        var cy = height / 2 + panY
        var dx = anchorX - cx
        var dy = anchorY - cy
        panX += dx - dx * (z1 / z0)
        panY += dy - dy * (z1 / z0)
        zoom = z1
        clampPan()
    }
    function clampPan() {
        var w = refLightboxImg.paintedWidth  * zoom
        var h = refLightboxImg.paintedHeight * zoom
        var maxX = Math.max(0, (w - width)  / 2)
        var maxY = Math.max(0, (h - height) / 2)
        panX = Math.max(-maxX, Math.min(maxX, panX))
        panY = Math.max(-maxY, Math.min(maxY, panY))
    }
    function fitToWindow() { zoom = 1.0; panX = 0; panY = 0 }
    function actualSize() {
        if (refLightboxImg.sourceSize.width <= 0) return
        zoom = Math.max(minZoom, Math.min(maxZoom, 1.0 / Math.max(fitScale, 0.0001)))
        panX = 0; panY = 0
    }

    // ── 半透明深色背景 + 点击空白关闭 ─────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: 0.92
    }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true
        onPositionChanged: refLightbox.autoHideTimer.restart()
        onWheel: function(wheel) {
            var delta = wheel.angleDelta.y / 120.0
            if (delta === 0) delta = wheel.angleDelta.x / 120.0
            if (delta === 0) return
            var factor = Math.pow(1.15, delta)
            refLightbox.setZoom(refLightbox.zoom * factor, wheel.x, wheel.y)
            refLightbox.autoHideTimer.restart()
        }
        property real _lastX: 0
        property real _lastY: 0
        property bool _dragging: false
        onPressed: function(mouse) {
            _lastX = mouse.x; _lastY = mouse.y
            _dragging = (refLightbox.zoom > 1.0)
            cursorShape = _dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
        }
        onReleased: {
            _dragging = false
            cursorShape = (refLightbox.zoom > 1.0) ? Qt.OpenHandCursor : Qt.ArrowCursor
        }
        onMouseXChanged: {
            if (!_dragging) return
            refLightbox.panX += mouseX - _lastX
            _lastX = mouseX
            refLightbox.clampPan()
        }
        onMouseYChanged: {
            if (!_dragging) return
            refLightbox.panY += mouseY - _lastY
            _lastY = mouseY
            refLightbox.clampPan()
        }
        onDoubleClicked: {
            if (refLightbox.atFit) refLightbox.actualSize()
            else                   refLightbox.fitToWindow()
        }
        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) { refLightbox.close(); return }
            var pw = refLightboxImg.paintedWidth  * refLightbox.zoom
            var ph = refLightboxImg.paintedHeight * refLightbox.zoom
            var cx = refLightbox.width  / 2 + refLightbox.panX
            var cy = refLightbox.height / 2 + refLightbox.panY
            var inside = mouse.x >= cx - pw/2 && mouse.x <= cx + pw/2
                      && mouse.y >= cy - ph/2 && mouse.y <= cy + ph/2
            if (!inside) refLightbox.close()
        }
        cursorShape: refLightbox.zoom > 1.0 ? Qt.OpenHandCursor : Qt.ArrowCursor
    }

    // ── 实际放大显示的 Image ──────────────────────────────────
    Image {
        id: refLightboxImg
        source: refLightbox.currentSrc
        asynchronous: true
        cache: true
        smooth: true
        mipmap: true
        fillMode: Image.PreserveAspectFit
        anchors.centerIn: parent
        width:  parent.width
        height: parent.height
        sourceSize.width:  8192
        sourceSize.height: 8192

        transform: [
            Scale {
                id: lbScale
                origin.x: refLightboxImg.width  / 2
                origin.y: refLightboxImg.height / 2
                xScale: refLightbox.zoom
                yScale: refLightbox.zoom
            },
            Translate {
                x: refLightbox.panX
                y: refLightbox.panY
            }
        ]

        onPaintedWidthChanged: _refreshFit()
        onPaintedHeightChanged: _refreshFit()
        onSourceSizeChanged: _refreshFit()
        function _refreshFit() {
            if (sourceSize.width > 0 && paintedWidth > 0) {
                refLightbox.fitScale = paintedWidth / sourceSize.width
            }
        }

        Timer {
            id: lbLoadingDelay
            interval: 300
            repeat: false
            onTriggered: lbBusy.shown = (refLightboxImg.status === Image.Loading)
        }
        Connections {
            target: refLightboxImg
            function onStatusChanged() {
                if (refLightboxImg.status === Image.Loading) {
                    lbLoadingDelay.restart()
                } else {
                    lbLoadingDelay.stop()
                    lbBusy.shown = false
                }
            }
        }
        BusyIndicator {
            id: lbBusy
            anchors.centerIn: parent
            property bool shown: false
            running: shown
            visible: shown
        }
        Label {
            anchors.centerIn: parent
            text: "图片无法加载"
            color: "#bbb"
            font.pixelSize: 14
            visible: refLightboxImg.status === Image.Error
        }
    }

    // ── 顶部信息栏（标题 / 序号 / 操作按钮） ──────────────────
    Rectangle {
        id: refLightboxTopBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 44
        color: "#101014cc"
        opacity: refLightboxToolsVisible ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 180 } }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 10
            spacing: 12

            Label {
                text: {
                    var p = String(refLightbox.currentSrc)
                    if (p.length === 0) return ""
                    var i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
                    return i >= 0 ? decodeURIComponent(p.substring(i + 1)) : p
                }
                color: "#e8e8ec"
                font.pixelSize: 13
                elide: Text.ElideMiddle
                Layout.fillWidth: true
            }
            Label {
                visible: refLightbox.currentCount > 1
                text: (refLightbox.currentIndex + 1) + " / " + refLightbox.currentCount
                color: "#9a9aa8"
                font.pixelSize: 12
            }
            Rectangle {
                id: lbCloseBtn
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                radius: 4
                color: lbCloseBtnMA.pressed ? "#3a3a45"
                     : lbCloseBtnMA.containsMouse ? "#2a2a32cc"
                     : "#1a1a1d99"
                border.color: lbCloseBtnMA.containsMouse ? "#5a8fd8" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: lbCloseBtnMA.containsMouse ? "#ffffff" : "#d0d0d8"
                    font.pixelSize: 14
                    font.bold: true
                }
                MouseArea {
                    id: lbCloseBtnMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: refLightbox.close()
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "关闭（Esc）"
                }
            }
        }
    }

    // ── 底部翻页（folder 模式 N>1 才显示） ────────────────────
    Row {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 24
        spacing: 16
        visible: refLightboxToolsVisible
                 && refLightbox.currentCanNav
                 && refLightbox.currentCount > 1
        opacity: visible ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 180 } }

        Rectangle {
            width: 44; height: 44; radius: 22
            color: lbPrevMA.pressed ? "#3a3a45"
                  : lbPrevMA.containsMouse ? "#2a2a32"
                  : "#1a1a1de0"
            id: lbPrev
            property bool canGo: refLightbox.currentCount > 1
            border.color: lbPrev.canGo ? "#5a5a65" : "#2a2a32"
            border.width: 1
            Text { anchors.centerIn: parent; text: "◀"; font.pixelSize: 16; color: lbPrev.canGo ? "#e8e8ec" : "#555" }
            MouseArea {
                id: lbPrevMA
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: lbPrev.canGo ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (!lbPrev.canGo) return
                    refLightbox.bumpOffset(-1)
                    refLightbox.fitToWindow()
                    refLightbox.autoHideTimer.restart()
                }
            }
        }
        Rectangle {
            width: 44; height: 44; radius: 22
            color: lbNextMA.pressed ? "#3a3a45"
                  : lbNextMA.containsMouse ? "#2a2a32"
                  : "#1a1a1de0"
            id: lbNext
            property bool canGo: refLightbox.currentCount > 1
            border.color: lbNext.canGo ? "#5a5a65" : "#2a2a32"
            border.width: 1
            Text { anchors.centerIn: parent; text: "▶"; font.pixelSize: 16; color: lbNext.canGo ? "#e8e8ec" : "#555" }
            MouseArea {
                id: lbNextMA
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: lbNext.canGo ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (!lbNext.canGo) return
                    refLightbox.bumpOffset(+1)
                    refLightbox.fitToWindow()
                    refLightbox.autoHideTimer.restart()
                }
            }
        }
    }

    // ── 工具条自动隐藏（鼠标静止 2.5s 后淡出） ────────────────
    property bool refLightboxToolsVisible: true
    Timer {
        id: autoHideTimer
        interval: 2500
        repeat: false
        onTriggered: refLightbox.refLightboxToolsVisible = false
    }
    onVisibleChanged: {
        if (visible) { refLightboxToolsVisible = true; autoHideTimer.restart() }
    }
    onZoomChanged: { refLightboxToolsVisible = true; autoHideTimer.restart() }

    // ── 键盘快捷键 ────────────────────────────────────────────
    Keys.onPressed: function(event) {
        if (!visible) return
        switch (event.key) {
            case Qt.Key_Escape: refLightbox.close(); event.accepted = true; break
            case Qt.Key_Plus:
            case Qt.Key_Equal:
                refLightbox.setZoom(refLightbox.zoom * 1.25, width/2, height/2)
                event.accepted = true; break
            case Qt.Key_Minus:
                refLightbox.setZoom(refLightbox.zoom / 1.25, width/2, height/2)
                event.accepted = true; break
            case Qt.Key_Left:
                if (refLightbox.currentCanNav && refLightbox.currentCount > 1) {
                    refLightbox.bumpOffset(-1)
                    refLightbox.fitToWindow()
                }
                event.accepted = true; break
            case Qt.Key_Right:
                if (refLightbox.currentCanNav && refLightbox.currentCount > 1) {
                    refLightbox.bumpOffset(+1)
                    refLightbox.fitToWindow()
                }
                event.accepted = true; break
        }
        autoHideTimer.restart()
    }
}
