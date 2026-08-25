// ImageInfoCard.qml — 图片分析右侧统计卡片
//
// 风格对齐 StreamInfoCard.qml / YuvStatsPanel.qml：
//   - 背景 #121417，左侧 1px #2a2e33 分隔线
//   - 卡片表头 + 数值行（"标签 / 值" 两列），等宽字体用于数值
//   - 渲染阶段额外显示像素统计 + 直方图

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: panel
    color: "#121417"
    anchors.fill: parent

    property int slot: 0
    property int ver: 0
    Connections {
        target: ImageBridge
        function onSlotCountChanged() { panel.ver++ }
        function onFileOpened(s) { if (s === panel.slot) panel.ver++ }
        function onFileClosed(s) { if (s === panel.slot) panel.ver++ }
    }

    readonly property bool slotActive: ver >= 0 && ImageBridge.hasFile(slot)
    // 关键：ver 必须出现在表达式中，否则 Q_INVOKABLE 调用不会因 ver 变化而重新求值
    readonly property var info: {
        if (ver < 0) return ({})
        if (!ImageBridge.hasFile(slot)) return ({})
        return ImageBridge.imageInfo(slot)
    }

    // 像素统计数据
    property var pixelData: ({})
    property bool statsLoading: false

    // 左侧 1px 分隔线
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: "#2a2e33"
    }

    // 当 slot/ver 变化时重新获取统计
    onSlotChanged: _fetchStats()
    onVerChanged: _fetchStats()
    Component.onCompleted: _fetchStats()

    function _fetchStats() {
        console.log("[ImageInfoCard] _fetchStats slot=" + slot + " hasFile=" + ImageBridge.hasFile(slot) + " ver=" + ver)
        if (!ImageBridge.hasFile(slot)) {
            pixelData = ({})
            statsLoading = false
            return
        }
        statsLoading = true
        // 延迟 200ms 确保文件完全加载后再统计
        statsTimer.start()
    }

    Timer {
        id: statsTimer
        interval: 200; repeat: false
        onTriggered: {
            // 再次检查 hasFile，避免竞态
            console.log("[ImageInfoCard] statsTimer triggered slot=" + slot + " hasFile=" + ImageBridge.hasFile(slot))
            if (ImageBridge.hasFile(slot)) {
                var data = ImageBridge.pixelStats(slot)
                console.log("[ImageInfoCard] pixelStats returned keys=" + (data ? Object.keys(data).length : 0))
                if (data && Object.keys(data).length > 0) {
                    pixelData = data
                }
            }
            statsLoading = false
        }
    }

    Flickable {
        anchors.fill: parent
        anchors.leftMargin: 0
        anchors.rightMargin: 0
        anchors.topMargin: 0
        contentWidth: width
        contentHeight: contentCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: contentCol
            width: parent.width
            spacing: 0

            // ── 标题栏 ──
            RowLayout {
                Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                Layout.topMargin: 12; Layout.bottomMargin: 8; spacing: 8
                Rectangle { Layout.preferredWidth: 3; Layout.preferredHeight: 16; radius: 1; color: "#5b8def" }
                Text { text: "图片信息"; color: "#e8e8ec"; font.pixelSize: 14; font.bold: true }
                Item { Layout.fillWidth: true }
                // 通道指示
                Rectangle {
                    Layout.preferredWidth: chanIndicator.implicitWidth + 10; Layout.preferredHeight: 16; radius: 8
                    color: "#223a5fc0"; border.color: "#3a5fc0"; border.width: 1
                    Text {
                        id: chanIndicator; anchors.centerIn: parent
                        text: "CH" + (slot + 1) + "/" + ImageBridge.slotCount
                        color: "#6fa0ff"; font.pixelSize: 9; font.bold: true
                    }
                }
            }

            // 文件名
            Text {
                Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 2
                text: slotActive ? (info.fileName || "—") : "—"
                color: "#cccccc"; font.pixelSize: 13; font.family: "Monospace"; elide: Text.ElideMiddle
            }
            Text {
                Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 8
                text: slotActive ? (info.filePath || "") : ""
                color: "#5a5f66"; font.pixelSize: 10; elide: Text.ElideLeft
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#2a2e33"; Layout.bottomMargin: 8 }

            // ════ 基本信息组 ════
            SectionHeader {
                Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 6
                text: "基本信息"
            }

            Repeater {
                model: slotActive ? [
                    { label: "分辨率",   value: (Number(info.width) > 0 && Number(info.height) > 0)
                                         ? (info.width + " × " + info.height) : "—",
                      highlight: false },
                    { label: "像素数",   value: Number(info.pixelCount) > 0 ? info.pixelCount.toLocaleString() : "—",
                      highlight: false },
                    { label: "宽高比",   value: info.aspectRatio || "—", highlight: false },
                    { label: "格式",     value: info.formatLong || info.format || "—", highlight: false },
                    { label: "位深",     value: Number(info.bitDepth) > 0 ? (info.bitDepth + " bit") : "—",
                      highlight: false },
                    { label: "帧数",     value: Number(info.frameCount) > 1 ? (String(info.frameCount) + " (动画)") : "1 (静态)",
                      highlight: false },
                    { label: "文件大小", value: Number(info.fileSize) > 0 ? _formatFileSize(Number(info.fileSize)) : "—",
                      highlight: false },
                    { label: "修改时间", value: info.fileModified || "—", highlight: false }
                ] : []
                InfoRow {
                    Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                    label: modelData.label; value: modelData.value; highlight: modelData.highlight
                }
            }

            // ════ 色彩与 ICC 组 ════
            SectionHeader {
                Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.topMargin: 14; Layout.bottomMargin: 6
                text: "色彩与 ICC"
            }

            Repeater {
                model: slotActive ? [
                    { label: "色彩类型", value: info.colorType || "—", color: "#c8c8d0" },
                    { label: "色彩空间", value: info.colorSpace || "—", color: "#c8c8d0" },
                    { label: "ICC Profile", value: info.iccProfile || "—",
                      color: info.hasICC ? "#7eb0ff" : "#c8c8d0" },
                    { label: "原色", value: info.primaries || "—",
                      color: (info.primaries && info.primaries !== "—" && info.primaries !== "Custom") ? "#7ee0d0" : "#c8c8d0" },
                    { label: "白点", value: info.whitePoint || "—", color: "#c8c8d0" },
                    { label: "传输函数", value: info.gamma || "—", color: "#c8c8d0" },
                    { label: "色彩范围", value: info.colorRange || "—",
                      color: info.colorRange ? "#6fcf97" : "#c8c8d0" },
                    { label: "Alpha", value: info.hasAlpha ? "有" : "无",
                      color: info.hasAlpha ? "#e8c84a" : "#8a8a8e" }
                ] : []
                InfoRow {
                    Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                    label: modelData.label; value: modelData.value; valueColor: modelData.color
                }
            }

            // ── 色彩标签行 ──
            RowLayout {
                Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                Layout.topMargin: 6; Layout.bottomMargin: 4; spacing: 4

                // ICC 标签
                Rectangle {
                    visible: slotActive && !!info.hasICC
                    Layout.preferredWidth: iccTag.implicitWidth + 12; Layout.preferredHeight: 16; radius: 3
                    color: "#183a5fc0"; border.color: "#3a5fc0"; border.width: 1
                    Text { id: iccTag; anchors.centerIn: parent; text: "ICC"; color: "#6fa0ff"; font.pixelSize: 9; font.bold: true }
                }
                // 色彩范围标签
                Rectangle {
                    visible: slotActive && !!info.colorRange
                    Layout.preferredWidth: crTag.implicitWidth + 12; Layout.preferredHeight: 16; radius: 3
                    color: "#183a8a3a"; border.color: "#3a8a5a"; border.width: 1
                    Text { id: crTag; anchors.centerIn: parent; text: "Full Range"; color: "#6fcf97"; font.pixelSize: 9; font.bold: true }
                }
                // Alpha 标签
                Rectangle {
                    visible: slotActive && !!info.hasAlpha
                    Layout.preferredWidth: alphaTag.implicitWidth + 12; Layout.preferredHeight: 16; radius: 3
                    color: "#18c89a3a"; border.color: "#c8a23a"; border.width: 1
                    Text { id: alphaTag; anchors.centerIn: parent; text: "Alpha"; color: "#e8c84a"; font.pixelSize: 9; font.bold: true }
                }
                // 无 Alpha 标签
                Rectangle {
                    visible: slotActive && !info.hasAlpha
                    Layout.preferredWidth: noAlphaTag.implicitWidth + 12; Layout.preferredHeight: 16; radius: 3
                    color: "#18404044"; border.color: "#404044"; border.width: 1
                    Text { id: noAlphaTag; anchors.centerIn: parent; text: "No Alpha"; color: "#8a8a8e"; font.pixelSize: 9 }
                }
                Item { Layout.fillWidth: true }
            }

            // ════ 元信息组 ════
            SectionHeader {
                Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.topMargin: 14; Layout.bottomMargin: 6
                text: "元信息"
            }

            Repeater {
                model: slotActive ? [
                    { label: "DPI", value: Number(info.dpiX) > 0 ? (info.dpiX + " × " + info.dpiY) : "—", color: "#c8c8d0" },
                    { label: "EXIF 方向", value: info.exifOrientationDesc || "—", color: "#c8c8d0" }
                ] : []
                InfoRow {
                    Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                    label: modelData.label; value: modelData.value; valueColor: modelData.color
                }
            }

            // ════ 像素统计 ════
            SectionHeader {
                Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.topMargin: 14; Layout.bottomMargin: 6
                text: "像素统计"
            }

            // 平均亮度
            InfoRow {
                Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                label: "平均亮度"; labelWidth: 56
                value: pixelData && pixelData.meanLum !== undefined ? (pixelData.meanLum + " / 255") : "—"
            }

            // RGB 均值
            RowLayout {
                Layout.fillWidth: true; Layout.preferredHeight: 20; Layout.leftMargin: 12; Layout.rightMargin: 12; spacing: 8
                Text { text: "RGB 均值"; color: "#7a8088"; font.pixelSize: 11; Layout.preferredWidth: 56 }
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Text { text: "R"; color: "#e0656a"; font.pixelSize: 10; font.bold: true }
                    Text { text: pixelData && pixelData.meanR !== undefined ? pixelData.meanR : "—"; color: "#c8c8d0"; font.pixelSize: 11; Layout.preferredWidth: 24 }
                    Text { text: "G"; color: "#6fcf97"; font.pixelSize: 10; font.bold: true }
                    Text { text: pixelData && pixelData.meanG !== undefined ? pixelData.meanG : "—"; color: "#c8c8d0"; font.pixelSize: 11; Layout.preferredWidth: 24 }
                    Text { text: "B"; color: "#5b8def"; font.pixelSize: 10; font.bold: true }
                    Text { text: pixelData && pixelData.meanB !== undefined ? pixelData.meanB : "—"; color: "#c8c8d0"; font.pixelSize: 11; Layout.preferredWidth: 24 }
                    Item { Layout.fillWidth: true }
                }
            }

            // RGB 标准差
            RowLayout {
                Layout.fillWidth: true; Layout.preferredHeight: 20; Layout.leftMargin: 12; Layout.rightMargin: 12; spacing: 8
                Text { text: "RGB 标准差"; color: "#7a8088"; font.pixelSize: 11; Layout.preferredWidth: 56 }
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Text { text: "R"; color: "#e0656a"; font.pixelSize: 10; font.bold: true }
                    Text { text: pixelData && pixelData.stdR !== undefined ? pixelData.stdR : "—"; color: "#a0a0a8"; font.pixelSize: 11; Layout.preferredWidth: 24 }
                    Text { text: "G"; color: "#6fcf97"; font.pixelSize: 10; font.bold: true }
                    Text { text: pixelData && pixelData.stdG !== undefined ? pixelData.stdG : "—"; color: "#a0a0a8"; font.pixelSize: 11; Layout.preferredWidth: 24 }
                    Text { text: "B"; color: "#5b8def"; font.pixelSize: 10; font.bold: true }
                    Text { text: pixelData && pixelData.stdB !== undefined ? pixelData.stdB : "—"; color: "#a0a0a8"; font.pixelSize: 11; Layout.preferredWidth: 24 }
                    Item { Layout.fillWidth: true }
                }
            }

            // 动态范围
            InfoRow {
                Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                label: "动态范围"; labelWidth: 56
                value: pixelData && pixelData.minR !== undefined
                       ? ("R[" + pixelData.minR + "-" + pixelData.maxR + "] "
                        + "G[" + pixelData.minG + "-" + pixelData.maxG + "] "
                        + "B[" + pixelData.minB + "-" + pixelData.maxB + "]")
                       : "—"
            }

            // Alpha 比例
            InfoRow {
                Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                visible: slotActive && !!info.hasAlpha
                label: "透明像素"; labelWidth: 56
                value: pixelData && pixelData.alphaRatio !== undefined
                       ? (pixelData.alphaRatio > 0 ? (pixelData.alphaRatio * 100).toFixed(1) + "%" : "0%")
                       : "—"
                valueColor: "#e8c84a"
            }

            // ════ 亮度直方图 ════
            SectionHeader {
                Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.topMargin: 12; Layout.bottomMargin: 6
                text: "亮度直方图"
            }

            Canvas {
                id: lumHistCanvas
                Layout.fillWidth: true; Layout.preferredHeight: 70
                Layout.leftMargin: 12; Layout.rightMargin: 12

                property var histData: pixelData && pixelData.histLum ? pixelData.histLum : null

                onHistDataChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var w = width, h = height
                    ctx.fillStyle = "#12121a"
                    ctx.fillRect(0, 0, w, h)

                    if (!histData || histData.length === 0) return

                    var maxVal = 1
                    for (var i = 1; i < 255; ++i)
                        if (histData[i] > maxVal) maxVal = histData[i]

                    var barW = w / 256.0
                    for (var j = 0; j < 256; ++j) {
                        var bh = (histData[j] / maxVal) * (h - 2)
                        var gray = j
                        ctx.fillStyle = "rgb(" + gray + "," + gray + "," + gray + ")"
                        ctx.fillRect(j * barW, h - bh - 1, Math.max(barW, 1), bh)
                    }

                    ctx.strokeStyle = "#22262b"
                    ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke()
                }
            }

            // ════ RGB 通道直方图 ════
            SectionHeader {
                Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.topMargin: 10; Layout.bottomMargin: 6
                text: "RGB 直方图"
            }

            Canvas {
                id: rgbHistCanvas
                Layout.fillWidth: true; Layout.preferredHeight: 70
                Layout.leftMargin: 12; Layout.rightMargin: 12

                property var histR: pixelData && pixelData.histR ? pixelData.histR : null
                property var histG: pixelData && pixelData.histG ? pixelData.histG : null
                property var histB: pixelData && pixelData.histB ? pixelData.histB : null

                onHistRChanged: requestPaint()
                onHistGChanged: requestPaint()
                onHistBChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var w = width, h = height
                    ctx.fillStyle = "#12121a"
                    ctx.fillRect(0, 0, w, h)

                    if (!histR && !histG && !histB) return

                    var maxVal = 1
                    for (var i = 1; i < 255; ++i) {
                        if (histR && histR[i] > maxVal) maxVal = histR[i]
                        if (histG && histG[i] > maxVal) maxVal = histG[i]
                        if (histB && histB[i] > maxVal) maxVal = histB[i]
                    }

                    var barW = w / 256.0
                    ctx.globalCompositeOperation = "screen"

                    if (histR) {
                        ctx.fillStyle = "rgba(224, 101, 106, 0.5)"
                        ctx.beginPath()
                        ctx.moveTo(0, h)
                        for (var r = 0; r < 256; ++r) {
                            var rh = (histR[r] / maxVal) * (h - 2)
                            ctx.lineTo(r * barW, h - rh - 1)
                        }
                        ctx.lineTo(w, h); ctx.fill()
                    }
                    if (histG) {
                        ctx.fillStyle = "rgba(111, 207, 151, 0.5)"
                        ctx.beginPath()
                        ctx.moveTo(0, h)
                        for (var g = 0; g < 256; ++g) {
                            var gh = (histG[g] / maxVal) * (h - 2)
                            ctx.lineTo(g * barW, h - gh - 1)
                        }
                        ctx.lineTo(w, h); ctx.fill()
                    }
                    if (histB) {
                        ctx.fillStyle = "rgba(91, 141, 239, 0.5)"
                        ctx.beginPath()
                        ctx.moveTo(0, h)
                        for (var b = 0; b < 256; ++b) {
                            var bh = (histB[b] / maxVal) * (h - 2)
                            ctx.lineTo(b * barW, h - bh - 1)
                        }
                        ctx.lineTo(w, h); ctx.fill()
                    }

                    ctx.globalCompositeOperation = "source-over"
                    ctx.strokeStyle = "#22262b"
                    ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke()
                }
            }

            // 通道图例
            RowLayout {
                Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12
                Layout.topMargin: 4; Layout.bottomMargin: 12; spacing: 10
                Row { spacing: 3; Rectangle { width: 8; height: 8; radius: 2; color: "#e0656a" } Text { text: "R"; color: "#8a8a8e"; font.pixelSize: 9 } }
                Row { spacing: 3; Rectangle { width: 8; height: 8; radius: 2; color: "#6fcf97" } Text { text: "G"; color: "#8a8a8e"; font.pixelSize: 9 } }
                Row { spacing: 3; Rectangle { width: 8; height: 8; radius: 2; color: "#5b8def" } Text { text: "B"; color: "#8a8a8e"; font.pixelSize: 9 } }
                Item { Layout.fillWidth: true }
                Text {
                    visible: panel.statsLoading
                    text: "统计中…"; color: "#5a5f66"; font.pixelSize: 9
                }
            }
        }
    }

    // ── 子组件：段落标题 ──
    component SectionHeader : RowLayout {
        property string text: ""
        spacing: 6
        Text { text: parent.text; color: "#7a8290"; font.pixelSize: 10; font.bold: true; font.capitalization: Font.AllUppercase }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#22262b" }
    }

    // ── 子组件：信息行 ──
    component InfoRow : RowLayout {
        property string label: ""
        property string value: ""
        property color valueColor: "#c8c8d0"
        property int labelWidth: 64
        property bool highlight: false
        Layout.preferredHeight: 22; spacing: 8
        Text { text: label; color: "#7a8088"; font.pixelSize: 11; Layout.preferredWidth: labelWidth }
        Text {
            text: value; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideRight
            color: valueColor
        }
    }

    function _formatFileSize(bytes) {
        if (bytes <= 0) return "—"
        if (bytes >= 1048576) return (bytes / 1048576).toFixed(2) + " MB"
        if (bytes >= 1024)    return (bytes / 1024).toFixed(1) + " KB"
        return bytes + " B"
    }
}
