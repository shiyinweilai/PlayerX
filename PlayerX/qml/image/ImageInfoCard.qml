// ImageInfoCard.qml — 图片分析右侧统计卡片
//
// 风格对齐 StreamInfoCard.qml / YuvStatsPanel.qml：
//   - 背景 #121417，左侧 1px #2a2e33 分隔线
//   - 卡片表头 + 数值行（"标签 / 值" 两列），等宽字体用于数值

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

    readonly property bool slotActive: ImageBridge.hasFile(slot)
    readonly property var info: slotActive ? ImageBridge.imageInfo(slot) : ({})

    // 左侧 1px 分隔线
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
                    text: "图片信息"
                    color: "#bbbbbb"; font.pixelSize: 14; font.bold: true
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    text: {
                        const _ = panel.ver
                        return panel.slotActive
                               ? (panel.info.fileName || "—")
                               : "—"
                    }
                    color: "#9aa0a6"; font.pixelSize: 11
                    font.family: "Monospace"
                    elide: Text.ElideRight
                }
            }

            // ── 基本信息卡片 ──
            ImageInfoCardSection {
                title: "基本信息"
                rows: panel.slotActive ? [
                    { label: "文件名",     value: String(panel.info.fileName || "—") },
                    { label: "分辨率",     value: (Number(panel.info.width) > 0 && Number(panel.info.height) > 0)
                                           ? (panel.info.width + " × " + panel.info.height)
                                           : "—" },
                    { label: "格式",       value: String(panel.info.formatLong || panel.info.format || "—") },
                    { label: "位深",       value: Number(panel.info.bitDepth) > 0
                                           ? (panel.info.bitDepth + " bit") : "—" },
                    { label: "色彩类型",   value: String(panel.info.colorType || "—") },
                    { label: "色彩空间",   value: String(panel.info.colorSpace || "—") },
                    { label: "Alpha 通道", value: panel.info.hasAlpha ? "有" : "无" },
                    { label: "DPI",        value: Number(panel.info.dpiX) > 0
                                           ? (panel.info.dpiX + " × " + panel.info.dpiY)
                                           : "—" }
                ] : [
                    { label: "文件名",     value: "—" },
                    { label: "分辨率",     value: "—" },
                    { label: "格式",       value: "—" },
                    { label: "位深",       value: "—" },
                    { label: "色彩类型",   value: "—" },
                    { label: "色彩空间",   value: "—" },
                    { label: "Alpha 通道", value: "—" },
                    { label: "DPI",        value: "—" }
                ]
            }

            // ── 文件信息卡片 ──
            ImageInfoCardSection {
                title: "文件信息"
                rows: panel.slotActive ? [
                    { label: "文件大小",   value: _formatFileSize(Number(panel.info.fileSize)) },
                    { label: "修改时间",   value: String(panel.info.fileModified || "—") },
                    { label: "帧数",       value: Number(panel.info.frameCount) > 1
                                           ? String(panel.info.frameCount) : "1（静态）" },
                    { label: "文件路径",   value: String(panel.info.filePath || "—") }
                ] : [
                    { label: "文件大小",   value: "—" },
                    { label: "修改时间",   value: "—" },
                    { label: "帧数",       value: "—" },
                    { label: "文件路径",   value: "—" }
                ]
            }
        }
    }

    function _formatFileSize(bytes) {
        if (bytes <= 0) return "—"
        if (bytes >= 1048576) return (bytes / 1048576).toFixed(2) + " MB"
        if (bytes >= 1024)    return (bytes / 1024).toFixed(1) + " KB"
        return bytes + " B"
    }
}
