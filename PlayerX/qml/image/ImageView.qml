// ImageView.qml — 图片分析视图（仿 StreamView / YuvSetupView 的两阶段结构）
//
// 阶段切换：
//   - setup 阶段：ImageBridge.slotCount === 0
//       · 让出左侧导航栏
//       · 显示「文件列表 + 添加/清空 + 当前选中文件信息」+「▶ 开始分析」按钮
//   - render 阶段：ImageBridge.slotCount > 0
//       · 沉浸满屏
//       · 顶部图片信息条 / 中部图片显示区 / 底部全局总控栏
//       · 2 路时支持滑动对比模式

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import PlayerX 1.0
import PlayerX.ImageTools 1.0

Item {
    id: imageView
    property int currentSlot: 0
    signal switchTab(string tab)

    // ── 文件列表（setup 阶段用） ──────────────────────────────────
    property var pendingFiles: []
    property int pendingSelectedIndex: -1
    property string pendingStatus: ""
    property bool _pendingLoaded: false

    // ── 文件探测 ──
    property var _probeCache: ({})
    property var _probeData: ({})
    property bool _probing: false

    // ── 多选 ──
    property var _selectedFiles: ({})
    property bool _selectAllChecked: false
    property int _anchorIndex: -1

    // ── 滑动对比模式 ──
    property bool sliderCompareActive: false
    property real splitRatio: 0.5

    // ── 内嵌信息条显隐（C 快捷键切换，默认显示）──
    property bool imageInfoVisible: true

    // ── 渲染模式（顶部菜单切换，默认"standard"=Mipmap+Smooth，最通用）──
    //   "standard"  → 整数倍放大 nearest-neighbor，缩小双三次（默认）
    //   "smooth"    → 始终双三次插值，放大柔和
    //   "pixel"     → 始终最近邻，像素精确，适合逐像素分析
    property string renderMode: "standard"

    // ── 逐通道变换状态（缩放/旋转/翻转/平移）──
    // 用对象存储，key = slot index，value = { scale, rotation, flipH, flipV, panX, panY }
    property var _transforms: ({})

    // ── 滚轮缩放累积量（参考 YuvWindow，凑满 120 才缩放一次）──
    property real _wheelAccum: 0

    // ── 排序 ──
    property string _sortMode: "default"
    property bool _dragHovering: false

    // ── 当前 slot 派生状态 ──
    readonly property int effectiveSlot: {
        if (ImageBridge.slotCount === 0) return 0
        if (currentSlot >= 0 && currentSlot < ImageBridge.slotCount
            && ImageBridge.hasFile(currentSlot)) return currentSlot
        for (let i = 0; i < ImageBridge.slotCount; ++i) {
            if (ImageBridge.hasFile(i)) return i
        }
        return 0
    }
    readonly property bool slotActive: ImageBridge.slotCount > 0 && ImageBridge.hasFile(effectiveSlot)
    property int globalVer: 0
    Connections {
        target: ImageBridge
        function onSlotCountChanged() { imageView.globalVer++ }
        function onFileOpened(s)       { imageView.globalVer++ }
        function onFileClosed(s)       { imageView.globalVer++ }
    }

    Rectangle { anchors.fill: parent; color: "#101012" }

    Component.onCompleted: {
        const saved = ImageBridge.imageFileList()
        if (saved && saved.length > 0) {
            imageView.pendingFiles = saved
            imageView.pendingSelectedIndex = 0
            imageView._batchProbe()
            imageView._onFileSelected(0)
            imageView._selectedFiles = ({})
            imageView._selectedFiles[saved[0]] = true
            imageView._anchorIndex = 0
            imageView._selectAllChecked = false
        }
        imageView._pendingLoaded = true
    }

    onPendingFilesChanged: {
        if (!imageView._pendingLoaded) return
        const seen = new Set()
        const clean = []
        for (let i = 0; i < imageView.pendingFiles.length; ++i) {
            const p = imageView.pendingFiles[i]
            if (!p || p.length === 0) continue
            if (seen.has(p)) continue
            seen.add(p)
            clean.push(p)
        }
        ImageBridge.setImageFileList(clean)
        var newSel = {}
        var changed = false
        for (var key in imageView._selectedFiles) {
            if (seen.has(key)) {
                newSel[key] = true
            } else {
                changed = true
            }
        }
        if (changed) {
            imageView._selectedFiles = newSel
            imageView._selectAllChecked = imageView._isAllSelected()
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // SETUP 阶段（slotCount === 0）
    // ═════════════════════════════════════════════════════════════════════
    Item {
        id: imageSetupView
        anchors.fill: parent
        visible: ImageBridge.slotCount === 0

        Menu {
            id: sortMenu
            width: 160
            background: Rectangle {
                implicitWidth: 160; implicitHeight: 32
                color: "#cc1a1a1f"; border.color: "#33ffffff"; border.width: 1; radius: 6
            }
            topPadding: 6; bottomPadding: 6; leftPadding: 4; rightPadding: 4; spacing: 0

            MenuItem {
                text: "默认（添加顺序）"
                height: 28
                onTriggered: imageView._sortFiles("default")
                contentItem: Text { text: parent.text; color: imageView._sortMode === "default" ? "#3d7adf" : "#e8e8ec"; font.pixelSize: 12; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#803a3a3d" : "transparent"; radius: 4 }
            }
            MenuSeparator { height: 1; topPadding: 4; bottomPadding: 4
                contentItem: Rectangle { color: "#33ffffff"; implicitHeight: 1 }
                background: Rectangle { color: "transparent" }
            }
            MenuItem {
                text: "名称 ↑ (A→Z)"
                height: 28
                onTriggered: imageView._sortFiles("name_asc")
                contentItem: Text { text: parent.text; color: imageView._sortMode === "name_asc" ? "#3d7adf" : "#e8e8ec"; font.pixelSize: 12; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#803a3a3d" : "transparent"; radius: 4 }
            }
            MenuItem {
                text: "名称 ↓ (Z→A)"
                height: 28
                onTriggered: imageView._sortFiles("name_desc")
                contentItem: Text { text: parent.text; color: imageView._sortMode === "name_desc" ? "#3d7adf" : "#e8e8ec"; font.pixelSize: 12; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#803a3a3d" : "transparent"; radius: 4 }
            }
            MenuSeparator { height: 1; topPadding: 4; bottomPadding: 4
                contentItem: Rectangle { color: "#33ffffff"; implicitHeight: 1 }
                background: Rectangle { color: "transparent" }
            }
            MenuItem {
                text: "大小 ↓ (大→小)"
                height: 28
                onTriggered: imageView._sortFiles("size_desc")
                contentItem: Text { text: parent.text; color: imageView._sortMode === "size_desc" ? "#3d7adf" : "#e8e8ec"; font.pixelSize: 12; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#803a3a3d" : "transparent"; radius: 4 }
            }
            MenuItem {
                text: "大小 ↑ (小→大)"
                height: 28
                onTriggered: imageView._sortFiles("size_asc")
                contentItem: Text { text: parent.text; color: imageView._sortMode === "size_asc" ? "#3d7adf" : "#e8e8ec"; font.pixelSize: 12; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#803a3a3d" : "transparent"; radius: 4 }
            }
            MenuSeparator { height: 1; topPadding: 4; bottomPadding: 4
                contentItem: Rectangle { color: "#33ffffff"; implicitHeight: 1 }
                background: Rectangle { color: "transparent" }
            }
            MenuItem {
                text: "分辨率 ↓ (高→低)"
                height: 28
                onTriggered: imageView._sortFiles("resolution_desc")
                contentItem: Text { text: parent.text; color: imageView._sortMode === "resolution_desc" ? "#3d7adf" : "#e8e8ec"; font.pixelSize: 12; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#803a3a3d" : "transparent"; radius: 4 }
            }
            MenuItem {
                text: "分辨率 ↑ (低→高)"
                height: 28
                onTriggered: imageView._sortFiles("resolution_asc")
                contentItem: Text { text: parent.text; color: imageView._sortMode === "resolution_asc" ? "#3d7adf" : "#e8e8ec"; font.pixelSize: 12; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#803a3a3d" : "transparent"; radius: 4 }
            }
        }

        // ── 主区：左侧文件列表 + 右侧文件信息面板 ──
        RowLayout {
            anchors.top: parent.top; anchors.bottom: parent.bottom
            anchors.left: parent.left; anchors.right: parent.right
            anchors.topMargin: 24; anchors.bottomMargin: 24
            anchors.leftMargin: 24; anchors.rightMargin: 24
            spacing: 16

            // 左：文件列表卡片
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 400
                radius: 10
                color: imageView._dragHovering ? "#1a1a22" : "#16161b"
                border.color: imageView._dragHovering ? "#3a78c8" : "#2a2e33"
                border.width: imageView._dragHovering ? 2 : 1
                Behavior on border.color { ColorAnimation { duration: 120 } }
                Behavior on color { ColorAnimation { duration: 120 } }

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 0; spacing: 0

                    // ── 卡片头部操作栏 ──
                    RowLayout {
                        Layout.fillWidth: true; Layout.preferredHeight: 44
                        Layout.leftMargin: 12; Layout.rightMargin: 8; spacing: 8

                        Rectangle {
                            width: 100; height: 28; radius: 6
                            color: startHeadMa.containsMouse ? "#3d7adf" : "#2a5fc0"
                            Text { anchors.centerIn: parent; text: "开始分析"; color: "#fff"; font.pixelSize: 12; font.bold: true }
                            MouseArea {
                                id: startHeadMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: imageView._startAnalysis()
                            }
                        }
                        Text {
                            visible: imageView._selectedCount() > 0
                            text: "已选 " + imageView._selectedCount() + " 个"
                            color: "#6a6f76"; font.pixelSize: 11
                        }

                        Item { Layout.fillWidth: true }

                        StreamFlatButton { text: imageView._sortLabel() + " ▾"; enabled: imageView.pendingFiles.length > 0; onClicked: sortMenu.open() }
                        StreamFlatButton { text: "+ 添加"; onClicked: imageView._openFile() }
                        StreamFlatButton { text: "+ 文件夹"; onClicked: imageView._openFolder() }
                        StreamFlatButton {
                            text: "清空"
                            bgNormal: "#807a2e2e"; bgHover: "#809c3c3c"; bgDown: "#80b84848"; textColor: "#f5c6c6"
                            enabled: imageView.pendingFiles.length > 0
                            onClicked: {
                                imageView.pendingFiles = []
                                imageView.pendingSelectedIndex = -1
                                imageView.pendingStatus = ""
                                imageView._selectedFiles = ({})
                                imageView._selectAllChecked = false
                                imageView._anchorIndex = -1
                            }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#2a2e33" }

                    ListView {
                        id: fileListView
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.margins: 8
                        clip: true; model: imageView.pendingFiles
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                        delegate: Rectangle {
                            required property int index
                            required property string modelData
                            width: ListView.view.width; height: 36; radius: 3
                            color: imageView._selectedFiles[modelData] ? "#2a3a55" : (rowMa.containsMouse ? "#1e1e24" : "transparent")
                            border.color: imageView._selectedFiles[modelData] ? "#3a78c8" : "transparent"
                            border.width: 1
                            RowLayout {
                                z: 1; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 10
                                Text { text: String.fromCharCode(0x2460 + index); color: "#9aa0a6"; font.pixelSize: 12; Layout.preferredWidth: 20 }
                                Text { text: imageView._fileBasename(modelData); color: "#e8e8ec"; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideMiddle }
                                Text { text: imageView._fileDir(modelData); color: "#6a6f76"; font.pixelSize: 10; Layout.maximumWidth: 200; elide: Text.ElideLeft }
                                Text {
                                    text: {
                                        var info = imageView._probeCache[modelData]
                                        if (info && info.fileSize > 0) return imageView._formatFileSize(info.fileSize)
                                        return "—"
                                    }
                                    color: "#6a6f76"; font.pixelSize: 10; Layout.preferredWidth: 64; horizontalAlignment: Text.AlignRight
                                }
                                Text {
                                    text: {
                                        var info = imageView._probeCache[modelData]
                                        if (info && info.fileModified) return info.fileModified
                                        return "—"
                                    }
                                    color: "#6a6f76"; font.pixelSize: 10; Layout.preferredWidth: 140
                                }
                                Rectangle {
                                    Layout.preferredWidth: 22; Layout.preferredHeight: 22; radius: 3
                                    color: revealFileMa.containsMouse ? "#803a3a44" : "transparent"
                                    Canvas {
                                        anchors.centerIn: parent; width: 14; height: 14
                                        onPaint: {
                                            var ctx = getContext("2d"); ctx.reset()
                                            ctx.strokeStyle = revealFileMa.containsMouse ? "#e8e8ec" : "#9aa0a6"; ctx.lineWidth = 1.3; ctx.fillStyle = "transparent"
                                            ctx.beginPath(); ctx.moveTo(1, 4); ctx.lineTo(5, 4); ctx.lineTo(6.5, 5.5); ctx.lineTo(13, 5.5); ctx.lineTo(13, 12); ctx.lineTo(1, 12); ctx.closePath(); ctx.stroke()
                                        }
                                    }
                                    MouseArea { id: revealFileMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Fs.revealInFileManager(modelData) }
                                }
                                Rectangle {
                                    Layout.preferredWidth: 22; Layout.preferredHeight: 22; radius: 3
                                    color: delFileMa.containsMouse ? "#80b84848" : "transparent"
                                    Text { anchors.centerIn: parent; text: "×"; color: delFileMa.containsMouse ? "#fff" : "#9aa0a6"; font.pixelSize: 14 }
                                    MouseArea {
                                        id: delFileMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            var arr = imageView.pendingFiles.slice()
                                            const removedPath = arr[index]
                                            arr.splice(index, 1)
                                            imageView.pendingFiles = arr
                                            if (imageView.pendingSelectedIndex >= arr.length)
                                                imageView.pendingSelectedIndex = arr.length - 1
                                            if (removedPath && imageView._probeCache[removedPath])
                                                delete imageView._probeCache[removedPath]
                                            if (removedPath && imageView._selectedFiles[removedPath]) {
                                                var s = Object.assign({}, imageView._selectedFiles)
                                                delete s[removedPath]
                                                imageView._selectedFiles = s
                                                imageView._selectAllChecked = imageView._isAllSelected()
                                            }
                                            if (imageView.pendingSelectedIndex >= 0)
                                                imageView._onFileSelected(imageView.pendingSelectedIndex)
                                        }
                                    }
                                }
                            }
                            MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; onClicked: (mouse) => imageView._onFileClicked(index, mouse.modifiers) }
                        }

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            visible: imageView.pendingFiles.length === 0
                            text: "拖拽图片到此处，或点右上「+ 添加」选择图片文件"
                            color: "#6a6f76"; font.pixelSize: 12
                        }
                    }

                    DropArea {
                        id: fileDropArea
                        anchors.fill: parent
                        onEntered: (drag) => { imageView._dragHovering = true; drag.accepted = true }
                        onExited: imageView._dragHovering = false
                        onDropped: (drop) => {
                            imageView._dragHovering = false; drop.accepted = true
                            var urls = drop.urls || []
                            if (urls.length > 0) { imageView._handleDroppedFiles(urls); return }
                            var txt = drop.text || ""
                            if (txt.length > 0) {
                                var lines = txt.split("\n"); var paths = []
                                for (var i = 0; i < lines.length; ++i) {
                                    var line = lines[i].trim()
                                    if (line.length > 0) paths.push(line)
                                }
                                if (paths.length > 0) imageView._handleDroppedFiles(paths)
                            }
                        }
                    }
                }
            }

            // 右：文件信息面板（固定宽度 320px）
            Rectangle {
                Layout.preferredWidth: 320; Layout.fillHeight: true; radius: 10
                color: "#16161b"; border.color: "#2a2e33"; border.width: 1

                ColumnLayout {
                    anchors.centerIn: parent; spacing: 10
                    visible: imageView.pendingFiles.length === 0 || imageView.pendingSelectedIndex < 0 || imageView.pendingSelectedIndex >= imageView.pendingFiles.length
                    Text { Layout.alignment: Qt.AlignHCenter; text: "🖼"; font.pixelSize: 40 }
                    Text { Layout.alignment: Qt.AlignHCenter; text: "点击左侧文件查看信息"; color: "#9aa0a6"; font.pixelSize: 12 }
                }

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 16; spacing: 0
                    visible: imageView.pendingFiles.length > 0 && imageView.pendingSelectedIndex >= 0 && imageView.pendingSelectedIndex < imageView.pendingFiles.length

                    Text { text: "文件信息"; color: "#e8e8ec"; font.pixelSize: 14; font.bold: true; Layout.bottomMargin: 12 }
                    Text { text: imageView._probeData.fileName || "—"; color: "#cccccc"; font.pixelSize: 12; font.family: "Monospace"; elide: Text.ElideMiddle; Layout.fillWidth: true; Layout.bottomMargin: 4 }
                    Text { text: imageView._probeData.filePath || ""; color: "#6a6f76"; font.pixelSize: 10; elide: Text.ElideLeft; Layout.fillWidth: true; Layout.bottomMargin: 16 }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#2a2e33"; Layout.bottomMargin: 12 }

                    Repeater {
                        model: [
                            { label: "分辨率",   value: (Number(imageView._probeData.width) > 0 && Number(imageView._probeData.height) > 0) ? (imageView._probeData.width + " × " + imageView._probeData.height) : "—" },
                            { label: "格式",     value: imageView._probeData.formatLong || imageView._probeData.format || "—" },
                            { label: "位深",     value: Number(imageView._probeData.bitDepth) > 0 ? (imageView._probeData.bitDepth + " bit") : "—" },
                            { label: "色彩类型", value: imageView._probeData.colorType || "—" },
                            { label: "色彩空间", value: imageView._probeData.colorSpace || "—" },
                            { label: "Alpha",   value: imageView._probeData.hasAlpha ? "有" : "无" },
                            { label: "DPI",     value: Number(imageView._probeData.dpiX) > 0 ? (imageView._probeData.dpiX + " × " + imageView._probeData.dpiY) : "—" },
                            { label: "帧数",     value: Number(imageView._probeData.frameCount) > 1 ? String(imageView._probeData.frameCount) : "1" },
                            { label: "文件大小", value: Number(imageView._probeData.fileSize) > 0 ? imageView._formatFileSize(imageView._probeData.fileSize) : "—" },
                            { label: "修改时间", value: imageView._probeData.fileModified || "—" }
                        ]
                        RowLayout {
                            Layout.fillWidth: true; Layout.preferredHeight: 24; spacing: 8
                            Text { text: modelData.label; color: "#9aa0a6"; font.pixelSize: 11; Layout.preferredWidth: 70 }
                            Text { text: modelData.value; color: "#e8e8ec"; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideRight }
                        }
                    }

                    Text { visible: imageView._probing; text: "正在解析…"; color: "#6a6f76"; font.pixelSize: 11; Layout.topMargin: 12 }
                    Item { Layout.fillHeight: true }
                    Text { text: imageView.pendingStatus; color: "#e05050"; font.pixelSize: 11; visible: imageView.pendingStatus.length > 0; Layout.bottomMargin: 8 }
                }
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // RENDER 阶段（slotCount > 0）—— 沉浸满屏
    // ═════════════════════════════════════════════════════════════════════
    Item {
        id: imageRenderView
        anchors.fill: parent
        visible: ImageBridge.slotCount > 0

        // ── 中部：图片显示区 ──
        Item {
            id: mainDisplay
            anchors.left: parent.left; anchors.right: parent.right
            anchors.top: parent.top; anchors.bottom: bottomBar.top
            clip: true

            Rectangle { anchors.fill: parent; color: "#0a0a0e" }

            // ── 单路 / 多路网格显示 ──
            Loader {
                anchors.fill: parent
                active: ImageBridge.slotCount > 0 && !imageView.sliderCompareActive
                sourceComponent: {
                    if (ImageBridge.slotCount === 1) return singleImageComp
                    return gridImageComp
                }
            }

            // ── 滑动对比模式 ──
            Loader {
                anchors.fill: parent
                active: ImageBridge.slotCount === 2 && imageView.sliderCompareActive
                sourceComponent: sliderCompareComp
            }

            // 单路图片显示
            Component {
                id: singleImageComp
                Item {
                    id: singleRoot
                    anchors.fill: parent
                    property var _t: {
                        const _ = imageView._transformVer
                        return imageView._getTransform(imageView.effectiveSlot)
                    }

                    ImageDisplayItem {
                        id: singleImg
                        anchors.fill: parent
                        image: {
                            const _ = imageView.globalVer
                            return imageView.slotActive ? ImageBridge.image(imageView.effectiveSlot) : undefined
                        }
                        panX: singleRoot._t ? singleRoot._t.panX : 0
                        panY: singleRoot._t ? singleRoot._t.panY : 0
                        imgScale: singleRoot._t ? singleRoot._t.scale : 1.0
                        imgRotation: singleRoot._t ? singleRoot._t.rotation : 0
                        flipH: singleRoot._t ? singleRoot._t.flipH : false
                        flipV: singleRoot._t ? singleRoot._t.flipV : false
                        renderMode: imageView.renderMode
                    }

                    // ── 滚轮缩放 + Ctrl+双击重置位置（参考 YuvWindow：累积 120 才缩放一次）──
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton  // 左键用于 Ctrl+双击；滚轮不受影响
                        onDoubleClicked: function(mouse) {
                            if ((mouse.modifiers & Qt.ControlModifier) && imageView.slotActive) {
                                imageView._zoomReset(imageView.effectiveSlot)
                            }
                        }
                        onWheel: function(wheel) {
                            if (!imageView.slotActive) return
                            imageView._wheelAccum += wheel.angleDelta.y
                            var zoomDir = 0
                            if (imageView._wheelAccum >= 120)      { zoomDir = 1;  imageView._wheelAccum -= 120 }
                            else if (imageView._wheelAccum <= -120) { zoomDir = -1; imageView._wheelAccum += 120 }
                            if (zoomDir !== 0)
                                imageView._zoomAtWheel(imageView.effectiveSlot, zoomDir)
                            wheel.accepted = true
                        }
                    }

                    // ── 右键拖拽平移 ──
                    MouseArea {
                        id: singlePanArea
                        anchors.fill: parent
                        acceptedButtons: Qt.RightButton
                        property real lastX: 0
                        property real lastY: 0
                        onPressed: function(mouse) {
                            lastX = mouse.x; lastY = mouse.y
                            cursorShape = Qt.ClosedHandCursor
                        }
                        onReleased: { cursorShape = Qt.ArrowCursor }
                        onPositionChanged: function(mouse) {
                            if (pressed && imageView.slotActive) {
                                imageView._panBy(imageView.effectiveSlot, mouse.x - lastX, mouse.y - lastY)
                                lastX = mouse.x; lastY = mouse.y
                            }
                        }
                    }

                    // ── 内嵌信息条（C 键切换显隐）──
                    Rectangle {
                        visible: imageView.imageInfoVisible && imageView.slotActive
                        anchors.left: parent.left; anchors.top: parent.top; anchors.margins: 8
                        radius: 3; color: "#aa000000"; z: 5
                        implicitWidth: singleInfoRow.implicitWidth + 14; implicitHeight: singleInfoRow.implicitHeight + 6
                        width: implicitWidth; height: implicitHeight

                        RowLayout {
                            id: singleInfoRow; anchors.centerIn: parent; spacing: 8
                            Rectangle { Layout.preferredWidth: 20; Layout.preferredHeight: 18; radius: 3; color: "#3a6fd8"
                                Text { anchors.centerIn: parent; text: "1"; color: "#fff"; font.pixelSize: 11; font.bold: true } }
                            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
                            Text { color: "#c8c8d0"; font.pixelSize: 11; elide: Text.ElideMiddle
                                Layout.maximumWidth: Math.max(200, singleRoot.width / 2)
                                text: {
                                    const _ = imageView.globalVer
                                    return imageView.slotActive ? (ImageBridge.filePath(imageView.effectiveSlot) || "—") : "—"
                                } }
                        }
                    }

                    // ── 内嵌工具栏（底部，缩放/旋转/翻转）──
                    // 风格对齐 YuvWindow 底部控制栏：28x22, radius 3, #80252528/#803a3a3d
                    Rectangle {
                        id: singleToolbar
                        visible: imageView.slotActive
                        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottomMargin: 8
                        radius: 4; color: "#8018181c"; z: 5
                        implicitWidth: singleToolRow.implicitWidth + 16; implicitHeight: singleToolRow.implicitHeight + 8
                        width: implicitWidth; height: implicitHeight

                        Row {
                            id: singleToolRow; anchors.centerIn: parent; spacing: 2

                            // 放大
                            Rectangle { width: 28; height: 22; radius: 3
                                color: sZoomInMa.containsMouse ? "#803a3a3d" : "#80252528"
                                border.color: "#803a3a44"; border.width: 1
                                Text { anchors.centerIn: parent; text: "+"; color: "#ccc"; font.pixelSize: 14 }
                                MouseArea { id: sZoomInMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: imageView._zoomIn(imageView.effectiveSlot) } }
                            // 缩小
                            Rectangle { width: 28; height: 22; radius: 3
                                color: sZoomOutMa.containsMouse ? "#803a3a3d" : "#80252528"
                                border.color: "#803a3a44"; border.width: 1
                                Text { anchors.centerIn: parent; text: "−"; color: "#ccc"; font.pixelSize: 14 }
                                MouseArea { id: sZoomOutMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: imageView._zoomOut(imageView.effectiveSlot) } }
                            // 重置（⊙原点，风格对齐 YuvWindow）
                            Rectangle { width: 28; height: 22; radius: 3
                                color: sResetMa.containsMouse ? "#803a3a3d" : "#80252528"
                                border.color: "#803a3a44"; border.width: 1
                                Text { anchors.centerIn: parent; text: "⊙"; color: "#ccc"; font.pixelSize: 13 }
                                MouseArea { id: sResetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: imageView._zoomReset(imageView.effectiveSlot) } }
                            // 分隔
                            Rectangle { width: 1; height: 14; color: "#33ffffff"; anchors.verticalCenter: parent.verticalCenter }
                            // 顺时针旋转
                            Rectangle { width: 28; height: 22; radius: 3
                                color: sRotCwMa.containsMouse ? "#803a3a3d" : "#80252528"
                                border.color: "#803a3a44"; border.width: 1
                                Text { anchors.centerIn: parent; text: "⟳"; color: "#ccc"; font.pixelSize: 13 }
                                MouseArea { id: sRotCwMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: imageView._rotateCW(imageView.effectiveSlot) } }
                            // 逆时针旋转
                            Rectangle { width: 28; height: 22; radius: 3
                                color: sRotCcwMa.containsMouse ? "#803a3a3d" : "#80252528"
                                border.color: "#803a3a44"; border.width: 1
                                Text { anchors.centerIn: parent; text: "⟲"; color: "#ccc"; font.pixelSize: 13 }
                                MouseArea { id: sRotCcwMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: imageView._rotateCCW(imageView.effectiveSlot) } }
                            // 分隔
                            Rectangle { width: 1; height: 14; color: "#33ffffff"; anchors.verticalCenter: parent.verticalCenter }
                            // 水平翻转
                            Rectangle { width: 28; height: 22; radius: 3
                                color: sFlipHMa.containsMouse ? "#803a3a3d" : "#80252528"
                                border.color: "#803a3a44"; border.width: 1
                                Text { anchors.centerIn: parent; text: "⇄"; color: "#ccc"; font.pixelSize: 12 }
                                MouseArea { id: sFlipHMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: imageView._flipH(imageView.effectiveSlot) } }
                            // 垂直翻转
                            Rectangle { width: 28; height: 22; radius: 3
                                color: sFlipVMa.containsMouse ? "#803a3a3d" : "#80252528"
                                border.color: "#803a3a44"; border.width: 1
                                Text { anchors.centerIn: parent; text: "⇅"; color: "#ccc"; font.pixelSize: 12 }
                                MouseArea { id: sFlipVMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: imageView._flipV(imageView.effectiveSlot) } }
                        }
                    }
                }
            }

            // 多路网格显示（2x2 / 3x3 自适应）
            Component {
                id: gridImageComp
                Item {
                    anchors.fill: parent
                    property int cols: ImageBridge.slotCount <= 1 ? 1 : (ImageBridge.slotCount <= 4 ? 2 : 3)
                    property int rows: Math.ceil(ImageBridge.slotCount / cols)

                    Repeater {
                        model: ImageBridge.slotCount
                        delegate: Rectangle {
                            id: gridCell
                            required property int index
                            x: (index % parent.cols) * (parent.width / parent.cols)
                            y: Math.floor(index / parent.cols) * (parent.height / parent.rows)
                            width: parent.width / parent.cols
                            height: parent.height / parent.rows
                            color: "#0a0a0e"
                            border.color: imageView.currentSlot === index ? "#3a78c8" : "#1a1a20"
                            border.width: imageView.currentSlot === index ? 2 : 1

                            property var _t: {
                                const _ = imageView._transformVer
                                return imageView._getTransform(index)
                            }

                            ImageDisplayItem {
                                id: gridImg
                                anchors.fill: parent
                                image: {
                                    const _ = imageView.globalVer
                                    return ImageBridge.image(index)
                                }
                                panX: gridCell._t ? gridCell._t.panX : 0
                                panY: gridCell._t ? gridCell._t.panY : 0
                                imgScale: gridCell._t ? gridCell._t.scale : 1.0
                                imgRotation: gridCell._t ? gridCell._t.rotation : 0
                                flipH: gridCell._t ? gridCell._t.flipH : false
                                flipV: gridCell._t ? gridCell._t.flipV : false
                                renderMode: imageView.renderMode
                            }

                            // 通道标签 + 绝对路径（C 键切换显隐）
                            Rectangle {
                                visible: imageView.imageInfoVisible
                                anchors.top: parent.top; anchors.left: parent.left
                                anchors.margins: 6
                                radius: 3; color: "#aa000000"; z: 5
                                implicitWidth: gridInfoRow.implicitWidth + 12; implicitHeight: gridInfoRow.implicitHeight + 4
                                width: implicitWidth; height: implicitHeight

                                RowLayout {
                                    id: gridInfoRow; anchors.centerIn: parent; spacing: 6
                                    Rectangle { Layout.preferredWidth: 20; Layout.preferredHeight: 18; radius: 3; color: "#3a6fd8"
                                        Text { anchors.centerIn: parent; text: String(index + 1); color: "#fff"; font.pixelSize: 10; font.bold: true } }
                                    Text { color: "#c8c8d0"; font.pixelSize: 10; elide: Text.ElideMiddle
                                        Layout.maximumWidth: Math.max(120, gridCell.width / 3)
                                        text: {
                                            const p = ImageBridge.filePath(index)
                                            return p ? p : "—"
                                        } }
                                }
                            }

                            // ── 内嵌工具栏（底部，风格对齐 YuvWindow 底部栏）──
                            Rectangle {
                                visible: imageView.imageInfoVisible
                                anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottomMargin: 4
                                radius: 3; color: "#8018181c"; z: 5
                                implicitWidth: gridToolRow.implicitWidth + 12; implicitHeight: gridToolRow.implicitHeight + 6
                                width: implicitWidth; height: implicitHeight

                                Row {
                                    id: gridToolRow; anchors.centerIn: parent; spacing: 1

                                    Rectangle { width: 22; height: 18; radius: 2
                                        color: gZoomInMa.containsMouse ? "#803a3a3d" : "#80252528"
                                        border.color: "#803a3a44"; border.width: 1
                                        Text { anchors.centerIn: parent; text: "+"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea { id: gZoomInMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: imageView._zoomIn(index) } }
                                    Rectangle { width: 22; height: 18; radius: 2
                                        color: gZoomOutMa.containsMouse ? "#803a3a3d" : "#80252528"
                                        border.color: "#803a3a44"; border.width: 1
                                        Text { anchors.centerIn: parent; text: "−"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea { id: gZoomOutMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: imageView._zoomOut(index) } }
                                    Rectangle { width: 22; height: 18; radius: 2
                                        color: gResetMa.containsMouse ? "#803a3a3d" : "#80252528"
                                        border.color: "#803a3a44"; border.width: 1
                                        Text { anchors.centerIn: parent; text: "⊙"; color: "#ccc"; font.pixelSize: 12 }
                                        MouseArea { id: gResetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: imageView._zoomReset(index) } }
                                    Rectangle { width: 1; height: 12; color: "#33ffffff"; anchors.verticalCenter: parent.verticalCenter }
                                    Rectangle { width: 22; height: 18; radius: 2
                                        color: gRotCwMa.containsMouse ? "#803a3a3d" : "#80252528"
                                        border.color: "#803a3a44"; border.width: 1
                                        Text { anchors.centerIn: parent; text: "⟳"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea { id: gRotCwMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: imageView._rotateCW(index) } }
                                    Rectangle { width: 22; height: 18; radius: 2
                                        color: gRotCcwMa.containsMouse ? "#803a3a3d" : "#80252528"
                                        border.color: "#803a3a44"; border.width: 1
                                        Text { anchors.centerIn: parent; text: "⟲"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea { id: gRotCcwMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: imageView._rotateCCW(index) } }
                                    Rectangle { width: 1; height: 12; color: "#33ffffff"; anchors.verticalCenter: parent.verticalCenter }
                                    Rectangle { width: 22; height: 18; radius: 2
                                        color: gFlipHMa.containsMouse ? "#803a3a3d" : "#80252528"
                                        border.color: "#803a3a44"; border.width: 1
                                        Text { anchors.centerIn: parent; text: "⇄"; color: "#ccc"; font.pixelSize: 10 }
                                        MouseArea { id: gFlipHMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: imageView._flipH(index) } }
                                    Rectangle { width: 22; height: 18; radius: 2
                                        color: gFlipVMa.containsMouse ? "#803a3a3d" : "#80252528"
                                        border.color: "#803a3a44"; border.width: 1
                                        Text { anchors.centerIn: parent; text: "⇅"; color: "#ccc"; font.pixelSize: 10 }
                                        MouseArea { id: gFlipVMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: imageView._flipV(index) } }
                                }
                            }

                            // ── 滚轮缩放 + 左键点击选中 + Ctrl+双击重置 ──
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton  // 只接受左键，右键交给平移区域
                                cursorShape: Qt.PointingHandCursor
                                onClicked: imageView.currentSlot = index
                                onDoubleClicked: function(mouse) {
                                    if (mouse.modifiers & Qt.ControlModifier) {
                                        imageView._zoomReset(index)
                                    }
                                }
                                onWheel: function(wheel) {
                                    imageView._wheelAccum += wheel.angleDelta.y
                                    var zoomDir = 0
                                    if (imageView._wheelAccum >= 120)      { zoomDir = 1;  imageView._wheelAccum -= 120 }
                                    else if (imageView._wheelAccum <= -120) { zoomDir = -1; imageView._wheelAccum += 120 }
                                    if (zoomDir !== 0)
                                        imageView._zoomAtWheel(index, zoomDir)
                                    wheel.accepted = true
                                }
                            }

                            // ── 右键拖拽平移 ──
                            MouseArea {
                                id: gridPanArea
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                property real lastX: 0
                                property real lastY: 0
                                onPressed: function(mouse) {
                                    lastX = mouse.x; lastY = mouse.y
                                    cursorShape = Qt.ClosedHandCursor
                                }
                                onReleased: { cursorShape = Qt.ArrowCursor }
                                onPositionChanged: function(mouse) {
                                    if (pressed) {
                                        imageView._panBy(index, mouse.x - lastX, mouse.y - lastY)
                                        lastX = mouse.x; lastY = mouse.y
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 滑动对比组件
            Component {
                id: sliderCompareComp
                Item {
                    anchors.fill: parent

                    // ── 双路滑动对比渲染（物理像素级，分割线两侧严格对齐）──
                    ImageSliderCompareItem {
                        id: sliderImg
                        anchors.fill: parent
                        leftImage: {
                            const _ = imageView.globalVer
                            return ImageBridge.image(0)
                        }
                        rightImage: {
                            const _ = imageView.globalVer
                            return ImageBridge.image(1)
                        }
                        splitRatio: imageView.splitRatio
                        renderMode: imageView.renderMode
                        // 平移和缩放绑定到 slot 0 的变换（两路共享同一变换）
                        panX: {
                            const _ = imageView._transformVer
                            var t = imageView._getTransform(0)
                            return t ? t.panX : 0
                        }
                        panY: {
                            const _ = imageView._transformVer
                            var t = imageView._getTransform(0)
                            return t ? t.panY : 0
                        }
                        imgScale: {
                            const _ = imageView._transformVer
                            var t = imageView._getTransform(0)
                            return t ? t.scale : 1.0
                        }
                    }

                    // ── 滚轮缩放 + Ctrl+双击重置位置 ──
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        onDoubleClicked: function(mouse) {
                            if (mouse.modifiers & Qt.ControlModifier) {
                                imageView._zoomReset(0)
                            }
                        }
                        onWheel: function(wheel) {
                            imageView._wheelAccum += wheel.angleDelta.y
                            var zoomDir = 0
                            if (imageView._wheelAccum >= 120)      { zoomDir = 1;  imageView._wheelAccum -= 120 }
                            else if (imageView._wheelAccum <= -120) { zoomDir = -1; imageView._wheelAccum += 120 }
                            if (zoomDir !== 0)
                                imageView._zoomAtWheel(0, zoomDir)
                            wheel.accepted = true
                        }
                    }

                    // ── 右键拖拽平移 ──
                    MouseArea {
                        id: sliderPanArea
                        anchors.fill: parent
                        acceptedButtons: Qt.RightButton
                        property real lastX: 0
                        property real lastY: 0
                        onPressed: function(mouse) {
                            lastX = mouse.x; lastY = mouse.y
                            cursorShape = Qt.ClosedHandCursor
                        }
                        onReleased: { cursorShape = Qt.ArrowCursor }
                        onPositionChanged: function(mouse) {
                            if (pressed) {
                                imageView._panBy(0, mouse.x - lastX, mouse.y - lastY)
                                lastX = mouse.x; lastY = mouse.y
                            }
                        }
                    }

                    // ── hover 跟随 + 左键拖拽调整分割比例 ──
                    MouseArea {
                        id: sliderTracker
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        cursorShape: Qt.SplitHCursor
                        onPositionChanged: function(mouse) {
                            if (parent.width <= 0) return
                            imageView.splitRatio = Math.max(0.02, Math.min(0.98, mouse.x / parent.width))
                        }
                        onPressed: function(mouse) {
                            if (parent.width <= 0) return
                            imageView.splitRatio = Math.max(0.02, Math.min(0.98, mouse.x / parent.width))
                        }
                    }

                    // ── 左侧通道信息条 ──
                    Rectangle {
                        visible: imageView.imageInfoVisible
                        anchors.left: parent.left; anchors.top: parent.top; anchors.margins: 8
                        radius: 3; color: "#aa000000"; z: 5
                        implicitWidth: leftRow.implicitWidth + 12; implicitHeight: leftRow.implicitHeight + 4
                        width: implicitWidth; height: implicitHeight

                        RowLayout {
                            id: leftRow; anchors.centerIn: parent; spacing: 8
                            Text { color: "#a8d8ff"; font.pixelSize: 11; font.bold: true; text: "L" }
                            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
                            Text {
                                color: "#dcdcde"; font.pixelSize: 11; elide: Text.ElideMiddle
                                Layout.maximumWidth: Math.max(200, imageView.width / 2)
                                text: {
                                    const p = ImageBridge.filePath(0)
                                    return p ? p : "—"
                                }
                            }
                        }
                    }

                    // ── 右侧通道信息条 ──
                    Rectangle {
                        visible: imageView.imageInfoVisible
                        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                        radius: 3; color: "#aa000000"; z: 5
                        implicitWidth: rightRow.implicitWidth + 12; implicitHeight: rightRow.implicitHeight + 4
                        width: implicitWidth; height: implicitHeight

                        RowLayout {
                            id: rightRow; anchors.centerIn: parent; spacing: 8
                            Text { color: "#ffd0a8"; font.pixelSize: 11; font.bold: true; text: "R" }
                            Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 12; color: "#55ffffff" }
                            Text {
                                color: "#dcdcde"; font.pixelSize: 11; elide: Text.ElideMiddle
                                Layout.maximumWidth: Math.max(200, imageView.width / 2)
                                text: {
                                    const p = ImageBridge.filePath(1)
                                    return p ? p : "—"
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── 底部全局总控栏 ──
        Rectangle {
            id: bottomBar
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: 36; color: "#8018181c"

            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 4

                Item { Layout.fillWidth: true }

                // ── 全局操作按钮组（同时控制所有通道）──
                Row {
                    spacing: 2; Layout.alignment: Qt.AlignVCenter

                    // 放大（所有通道）
                    Rectangle { width: 28; height: 22; radius: 3; color: aZoomInMa.containsMouse ? "#803a3a3d" : "#80252528"
                        border.color: "#803a3a44"; border.width: 1
                        Text { anchors.centerIn: parent; text: "+"; color: "#ccc"; font.pixelSize: 14 }
                        MouseArea { id: aZoomInMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: imageView._zoomInAll() } }
                    // 缩小（所有通道）
                    Rectangle { width: 28; height: 22; radius: 3; color: aZoomOutMa.containsMouse ? "#803a3a3d" : "#80252528"
                        border.color: "#803a3a44"; border.width: 1
                        Text { anchors.centerIn: parent; text: "−"; color: "#ccc"; font.pixelSize: 14 }
                        MouseArea { id: aZoomOutMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: imageView._zoomOutAll() } }
                    // 重置（⊙原点，所有通道，风格对齐 YuvWindow）
                    Rectangle { width: 28; height: 22; radius: 3; color: aResetMa.containsMouse ? "#803a3a3d" : "#80252528"
                        border.color: "#803a3a44"; border.width: 1
                        Text { anchors.centerIn: parent; text: "⊙"; color: "#ccc"; font.pixelSize: 13 }
                        MouseArea { id: aResetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: imageView._zoomResetAll() } }
                    // 分隔
                    Rectangle { width: 1; height: 14; color: "#33ffffff"; anchors.verticalCenter: parent.verticalCenter }
                    // 顺时针旋转（所有通道）
                    Rectangle { width: 28; height: 22; radius: 3; color: aRotCwMa.containsMouse ? "#803a3a3d" : "#80252528"
                        border.color: "#803a3a44"; border.width: 1
                        Text { anchors.centerIn: parent; text: "⟳"; color: "#ccc"; font.pixelSize: 13 }
                        MouseArea { id: aRotCwMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: imageView._rotateCWAll() } }
                    // 逆时针旋转（所有通道）
                    Rectangle { width: 28; height: 22; radius: 3; color: aRotCcwMa.containsMouse ? "#803a3a3d" : "#80252528"
                        border.color: "#803a3a44"; border.width: 1
                        Text { anchors.centerIn: parent; text: "⟲"; color: "#ccc"; font.pixelSize: 13 }
                        MouseArea { id: aRotCcwMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: imageView._rotateCCWAll() } }
                    // 分隔
                    Rectangle { width: 1; height: 14; color: "#33ffffff"; anchors.verticalCenter: parent.verticalCenter }
                    // 水平翻转（所有通道）
                    Rectangle { width: 28; height: 22; radius: 3; color: aFlipHMa.containsMouse ? "#803a3a3d" : "#80252528"
                        border.color: "#803a3a44"; border.width: 1
                        Text { anchors.centerIn: parent; text: "⇄"; color: "#ccc"; font.pixelSize: 12 }
                        MouseArea { id: aFlipHMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: imageView._flipHAll() } }
                    // 垂直翻转（所有通道）
                    Rectangle { width: 28; height: 22; radius: 3; color: aFlipVMa.containsMouse ? "#803a3a3d" : "#80252528"
                        border.color: "#803a3a44"; border.width: 1
                        Text { anchors.centerIn: parent; text: "⇅"; color: "#ccc"; font.pixelSize: 12 }
                        MouseArea { id: aFlipVMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: imageView._flipVAll() } }
                }

                // 清空按钮
                Row {
                    spacing: 6; Layout.alignment: Qt.AlignVCenter; Layout.leftMargin: 12

                    // 滑动对比切换按钮（仅 2 路时显示，等价于快捷键 B）
                    Rectangle {
                        visible: ImageBridge.slotCount === 2
                        width: 72; height: 22; radius: 3
                        color: imageView.sliderCompareActive
                               ? "#802a5fc0"
                               : (sliderCmpMa.containsMouse ? "#803a3a3d" : "#80252528")
                        border.color: "#803a3a44"; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: imageView.sliderCompareActive ? "退出 ⇆" : "⇆ 滑动"
                            color: "#fff"; font.pixelSize: 11
                        }
                        MouseArea {
                            id: sliderCmpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: imageView.sliderCompareActive = !imageView.sliderCompareActive
                        }
                    }

                    Rectangle {
                        width: 64; height: 22; radius: 3
                        color: clearMa.containsMouse ? "#80c87070" : "#80b85a5a"
                        border.color: "#803a3a44"; border.width: 1
                        Text { anchors.centerIn: parent; text: "清空"; color: "#fff"; font.pixelSize: 11 }
                        MouseArea {
                            id: clearMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                ImageBridge.closeAll()
                                imageView.currentSlot = 0
                                imageView.sliderCompareActive = false
                            }
                        }
                    }
                }
            }
        }
    }

    // ── 文件 / 文件夹对话框 ──
    FileDialog {
        id: addFileDialog
        title: "添加图片文件"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "图片文件 (*.png *.jpg *.jpeg *.bmp *.webp *.tiff *.tif *.gif *.svg *.heic *.heif)",
            "所有文件 (*)"
        ]
        onAccepted: {
            const newPaths = []
            for (let i = 0; i < selectedFiles.length; ++i) {
                newPaths.push(imageView._normalizeFilePath(selectedFiles[i]))
            }
            if (newPaths.length === 0) return

            // 已有图片打开时 → 直接追加为新通道
            if (ImageBridge.slotCount > 0) {
                ImageBridge.addFiles(newPaths)
                if (newPaths.length > 0)
                    ImageBridge.setLastOpenedFolder(imageView._fileDir(newPaths[0]))
                return
            }

            // SETUP 阶段 → 加入 pending 列表
            const merged = imageView.pendingFiles.slice()
            for (let i = 0; i < newPaths.length; ++i) {
                if (merged.indexOf(newPaths[i]) < 0) merged.push(newPaths[i])
            }
            imageView.pendingFiles = merged
            imageView.pendingSelectedIndex = merged.length - newPaths.length
            imageView.pendingStatus = ""
            imageView._batchProbe()
            imageView._onFileSelected(imageView.pendingSelectedIndex)
            imageView._selectedFiles = ({})
            imageView._selectedFiles[merged[imageView.pendingSelectedIndex]] = true
            imageView._anchorIndex = imageView.pendingSelectedIndex
            imageView._selectAllChecked = false
            // 记忆打开位置
            if (newPaths.length > 0)
                ImageBridge.setLastOpenedFolder(imageView._fileDir(newPaths[0]))
        }
    }
    FolderDialog {
        id: addFolderDialog
        title: "添加图片文件夹"
        onAccepted: {
            const folder = imageView._normalizeFilePath(selectedFolder)
            let found = []
            try { found = Fs.scanImageFolderPath(folder, true) || [] } catch (e) { found = [] }
            if (found.length === 0) {
                imageView.pendingStatus = "未在该文件夹中找到图片文件"
                return
            }

            // 已有图片打开时 → 直接追加为新通道
            if (ImageBridge.slotCount > 0) {
                ImageBridge.addFiles(found)
                ImageBridge.setLastOpenedFolder(folder)
                return
            }

            const merged = imageView.pendingFiles.slice()
            for (let i = 0; i < found.length; ++i) {
                if (merged.indexOf(found[i]) < 0) merged.push(found[i])
            }
            imageView.pendingFiles = merged
            imageView.pendingSelectedIndex = merged.length - found.length
            imageView.pendingStatus = ""
            imageView._batchProbe()
            imageView._onFileSelected(imageView.pendingSelectedIndex)
            imageView._selectedFiles = ({})
            imageView._selectedFiles[merged[imageView.pendingSelectedIndex]] = true
            imageView._anchorIndex = imageView.pendingSelectedIndex
            imageView._selectAllChecked = false
            ImageBridge.setLastOpenedFolder(folder)
        }
    }

    // ── 工具函数 ──
    function _startAnalysis() {
        var paths = imageView._selectedPaths()
        if (paths.length === 0 && imageView.pendingFiles.length > 0) {
            paths = [imageView.pendingFiles[0]]
        }
        if (paths.length === 0) {
            imageView.pendingStatus = "请先选择图片文件"
            return
        }
        if (paths.length > ImageBridge.maxSlots) {
            paths = paths.slice(0, ImageBridge.maxSlots)
        }
        var files = []
        for (var i = 0; i < paths.length; ++i) files.push(paths[i])
        ImageBridge.openFiles(files)
        imageView.currentSlot = 0
        imageView.sliderCompareActive = false
    }

    function _openFile() { addFileDialog.open() }
    function _openFolder() { addFolderDialog.open() }

    // 供顶部菜单栏「图片分析 ▸ 打开文件/文件夹」调用
    function openFileDialog() { _openFile() }
    function openFolderDialog() { _openFolder() }

    // ── 逐通道变换控制 ──
    function _ensureTransform(slot) {
        var t = imageView._transforms
        if (!t[slot]) {
            var nt = {}; nt[slot] = { scale: 1.0, rotation: 0, flipH: false, flipV: false, panX: 0, panY: 0 }
            imageView._transforms = Object.assign({}, t, nt)
        }
    }
    function _getTransform(slot) {
        imageView._ensureTransform(slot)
        return imageView._transforms[slot]
    }
    function _setTransform(slot, key, val) {
        imageView._ensureTransform(slot)
        var t = imageView._transforms
        var entry = Object.assign({}, t[slot])
        entry[key] = val
        var nt = {}; nt[slot] = entry
        imageView._transforms = Object.assign({}, t, nt)
        imageView._transformVer++
    }
    function _zoomIn(slot)  { imageView._ensureTransform(slot); var t = imageView._transforms[slot]; imageView._setTransform(slot, "scale", Math.min(8.0, t.scale * 1.25)) }
    function _zoomOut(slot) { imageView._ensureTransform(slot); var t = imageView._transforms[slot]; imageView._setTransform(slot, "scale", Math.max(0.1, t.scale / 1.25)) }
    function _zoomReset(slot) {
        imageView._ensureTransform(slot)
        imageView._setTransform(slot, "scale", 1.0)
        imageView._setTransform(slot, "rotation", 0)
        imageView._setTransform(slot, "flipH", false)
        imageView._setTransform(slot, "flipV", false)
        imageView._setTransform(slot, "panX", 0)
        imageView._setTransform(slot, "panY", 0)
    }
    // 平移（右键拖拽调用）
    function _panBy(slot, dx, dy) {
        imageView._ensureTransform(slot)
        var t = imageView._transforms[slot]
        imageView._setTransform(slot, "panX", t.panX + dx)
        imageView._setTransform(slot, "panY", t.panY + dy)
    }
    // 滚轮缩放（自动居中，不偏移）
    function _zoomAtWheel(slot, wheelDelta) {
        imageView._ensureTransform(slot)
        var t = imageView._transforms[slot]
        var oldScale = t.scale
        var factor = wheelDelta > 0 ? 1.1 : (1 / 1.1)
        var newScale = Math.max(0.1, Math.min(8.0, oldScale * factor))
        if (Math.abs(oldScale - newScale) < 1e-6) return
        imageView._setTransform(slot, "scale", newScale)
    }
    function _rotateCW(slot)  { imageView._ensureTransform(slot); var t = imageView._transforms[slot]; imageView._setTransform(slot, "rotation", (t.rotation + 90) % 360) }
    function _rotateCCW(slot) { imageView._ensureTransform(slot); var t = imageView._transforms[slot]; imageView._setTransform(slot, "rotation", (t.rotation + 270) % 360) }
    function _flipH(slot) { imageView._ensureTransform(slot); var t = imageView._transforms[slot]; imageView._setTransform(slot, "flipH", !t.flipH) }
    function _flipV(slot) { imageView._ensureTransform(slot); var t = imageView._transforms[slot]; imageView._setTransform(slot, "flipV", !t.flipV) }

    // ── 全局操作（同时控制所有通道）──
    function _zoomInAll()  { for (var i = 0; i < ImageBridge.slotCount; ++i) imageView._zoomIn(i) }
    function _zoomOutAll() { for (var i = 0; i < ImageBridge.slotCount; ++i) imageView._zoomOut(i) }
    function _zoomResetAll() { for (var i = 0; i < ImageBridge.slotCount; ++i) imageView._zoomReset(i) }
    function _rotateCWAll()  { for (var i = 0; i < ImageBridge.slotCount; ++i) imageView._rotateCW(i) }
    function _rotateCCWAll() { for (var i = 0; i < ImageBridge.slotCount; ++i) imageView._rotateCCW(i) }
    function _flipHAll() { for (var i = 0; i < ImageBridge.slotCount; ++i) imageView._flipH(i) }
    function _flipVAll() { for (var i = 0; i < ImageBridge.slotCount; ++i) imageView._flipV(i) }

    // ── 变换版本号（驱动 QML 绑定刷新）──
    property int _transformVer: 0

    function _onFileClicked(idx, modifiers) {
        if (idx < 0 || idx >= imageView.pendingFiles.length) return
        const path = imageView.pendingFiles[idx]
        const ctrl = (modifiers & Qt.ControlModifier) !== 0
        const shift = (modifiers & Qt.ShiftModifier) !== 0
        if (shift && imageView._anchorIndex >= 0) {
            var s = Object.assign({}, imageView._selectedFiles)
            var lo = Math.min(imageView._anchorIndex, idx), hi = Math.max(imageView._anchorIndex, idx)
            for (var i = lo; i <= hi; ++i) s[imageView.pendingFiles[i]] = true
            imageView._selectedFiles = s
        } else if (ctrl) {
            var s2 = Object.assign({}, imageView._selectedFiles)
            if (s2[path]) delete s2[path]; else s2[path] = true
            imageView._selectedFiles = s2
            imageView._anchorIndex = idx
        } else {
            var s3 = {}; s3[path] = true
            imageView._selectedFiles = s3
            imageView._anchorIndex = idx
        }
        imageView._selectAllChecked = imageView._isAllSelected()
        imageView._onFileSelected(idx)
    }

    function _onFileSelected(idx) {
        imageView.pendingSelectedIndex = idx
        if (idx < 0 || idx >= imageView.pendingFiles.length) { imageView._probeData = ({}); return }
        const path = imageView.pendingFiles[idx]
        if (imageView._probeCache[path]) { imageView._probeData = imageView._probeCache[path]; return }
        imageView._probeData = ({})
        imageView._probing = true
        const data = ImageBridge.probeFile(path)
        imageView._probing = false
        if (data && Object.keys(data).length > 0) {
            imageView._probeCache[path] = data
            imageView._probeCache = Object.assign({}, imageView._probeCache)
            imageView._probeData = data
        }
    }

    function _batchProbe() {
        for (let i = 0; i < imageView.pendingFiles.length; ++i) {
            const p = imageView.pendingFiles[i]
            if (!imageView._probeCache[p]) {
                const data = ImageBridge.probeFile(p)
                if (data && Object.keys(data).length > 0)
                    imageView._probeCache[p] = data
            }
        }
        imageView._probeCache = Object.assign({}, imageView._probeCache)
    }

    function _handleDroppedFiles(urls) {
        const imageExts = ["png","jpg","jpeg","bmp","webp","tiff","tif","gif","svg","heic","heif"]
        const newPaths = []
        for (let i = 0; i < urls.length; ++i) {
            var localPath = imageView._normalizeFilePath(urls[i])
            if (!localPath || localPath.length === 0) continue
            if (Fs.isDirectoryPath(localPath)) {
                var found = Fs.scanImageFolderPath(localPath, true) || []
                for (let j = 0; j < found.length; ++j) {
                    if (newPaths.indexOf(found[j]) < 0 && imageView.pendingFiles.indexOf(found[j]) < 0)
                        newPaths.push(found[j])
                }
                continue
            }
            const dotIdx = localPath.lastIndexOf(".")
            if (dotIdx < 0) continue
            const ext = localPath.substring(dotIdx + 1).toLowerCase()
            if (imageExts.indexOf(ext) < 0) continue
            if (newPaths.indexOf(localPath) < 0 && imageView.pendingFiles.indexOf(localPath) < 0)
                newPaths.push(localPath)
        }
        if (newPaths.length === 0) { imageView.pendingStatus = "拖入的文件中未找到支持的图片格式"; return }
        const merged = imageView.pendingFiles.slice()
        for (let i = 0; i < newPaths.length; ++i) merged.push(newPaths[i])
        imageView.pendingFiles = merged
        imageView.pendingSelectedIndex = merged.length - newPaths.length
        imageView.pendingStatus = ""
        imageView._batchProbe()
        imageView._onFileSelected(imageView.pendingSelectedIndex)
        imageView._selectedFiles = ({})
        imageView._selectedFiles[merged[imageView.pendingSelectedIndex]] = true
        imageView._anchorIndex = imageView.pendingSelectedIndex
        imageView._selectAllChecked = false
    }

    function _sortFiles(mode) {
        const files = imageView.pendingFiles.slice()
        if (files.length <= 1) { imageView._sortMode = mode; return }
        const items = []
        for (let i = 0; i < files.length; ++i) {
            const p = files[i]; let info = imageView._probeCache[p]
            if (!info) { info = ImageBridge.probeFile(p); if (info && Object.keys(info).length > 0) imageView._probeCache[p] = info }
            items.push({ path: p, info: info || {} })
        }
        switch (mode) {
            case "name_asc": items.sort((a,b) => imageView._fileBasename(a.path).toLowerCase().localeCompare(imageView._fileBasename(b.path).toLowerCase())); break
            case "name_desc": items.sort((a,b) => imageView._fileBasename(b.path).toLowerCase().localeCompare(imageView._fileBasename(a.path).toLowerCase())); break
            case "size_asc": items.sort((a,b) => (a.info.fileSize||0)-(b.info.fileSize||0)); break
            case "size_desc": items.sort((a,b) => (b.info.fileSize||0)-(a.info.fileSize||0)); break
            case "resolution_desc": items.sort((a,b) => ((b.info.width||0)*(b.info.height||0))-((a.info.width||0)*(a.info.height||0))); break
            case "resolution_asc": items.sort((a,b) => ((a.info.width||0)*(a.info.height||0))-((b.info.width||0)*(b.info.height||0))); break
        }
        const sorted = items.map(x => x.path)
        imageView._probeCache = ({})
        imageView.pendingFiles = sorted
        imageView._sortMode = mode
        imageView._batchProbe()
        imageView._onFileSelected(0)
    }

    function _sortLabel() {
        switch (imageView._sortMode) {
            case "name_asc": return "名称 ↑"; case "name_desc": return "名称 ↓"
            case "size_asc": return "大小 ↑"; case "size_desc": return "大小 ↓"
            case "resolution_asc": return "分辨率 ↑"; case "resolution_desc": return "分辨率 ↓"
            default: return "默认"
        }
    }

    function _isAllSelected() {
        if (imageView.pendingFiles.length === 0) return false
        for (var i = 0; i < imageView.pendingFiles.length; ++i) { if (!imageView._selectedFiles[imageView.pendingFiles[i]]) return false }
        return true
    }
    function _selectedCount() { return Object.keys(imageView._selectedFiles).length }
    function _selectedPaths() {
        var paths = []
        for (var i = 0; i < imageView.pendingFiles.length; ++i) { var p = imageView.pendingFiles[i]; if (imageView._selectedFiles[p]) paths.push(p) }
        return paths
    }

    function _normalizeFilePath(urlOrStr) {
        const s = String(urlOrStr)
        if (s.indexOf("file://") === 0) return Fs.urlToLocalFile(urlOrStr)
        return s.replace(/\\/g, "/")
    }
    function _fileBasename(path) { const p = String(path).replace(/\\/g, "/"); return p.substring(p.lastIndexOf("/") + 1) }
    function _fileDir(path) { const p = String(path).replace(/\\/g, "/"); return p.substring(0, p.lastIndexOf("/")) }
    function _formatFileSize(bytes) {
        if (bytes <= 0) return "—"
        if (bytes >= 1048576) return (bytes / 1048576).toFixed(2) + " MB"
        if (bytes >= 1024) return (bytes / 1024).toFixed(1) + " KB"
        return bytes + " B"
    }
}
