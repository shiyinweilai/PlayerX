// ImageInfoCardSection.qml — 图片分析右侧卡片的"表头+数值行"段
//
// 与 StreamInfoCardSection.qml 完全同款风格，独立文件以避免跨目录 import。

import QtQuick
import QtQuick.Layouts

Rectangle {
    id: section
    property string title: ""
    property var rows: []   // [{label, value}]

    width: parent ? parent.width : 200
    implicitHeight: col.implicitHeight + 16
    radius: 4
    color: "#1a1a22"
    border.color: "#2a2e33"
    border.width: 1

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        spacing: 4

        Text {
            Layout.fillWidth: true
            text: section.title
            color: "#bbbbbb"
            font.pixelSize: 12
            font.bold: true
        }

        Repeater {
            model: section.rows
            delegate: RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    text: modelData.label
                    color: "#9aa0a6"
                    font.pixelSize: 11
                    Layout.preferredWidth: 96
                }
                Text {
                    text: modelData.value
                    color: "#cccccc"
                    font.pixelSize: 11
                    font.family: "Monospace"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                }
            }
        }
    }
}
