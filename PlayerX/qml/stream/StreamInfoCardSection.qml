// StreamInfoCardSection.qml — 码流分析右侧卡片的"表头+数值行"段
//
// 风格对齐 YuvStatsPanel 中 PlaneGradientCard 的子项：
//   - 圆角 4，背景 #1a1a22，边框 #2a2e33
//   - 标题：浅灰 #bbbbbb，bold
//   - 数值行：左标签 #9aa0a6，右值 #cccccc 等宽字体
//
// 简化为一列：label / value 配对（不画 histogram / canvas），用于本模块的
// 帧信息、码流统计等纯文本卡片。

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

        // 表头
        Text {
            Layout.fillWidth: true
            text: section.title
            color: "#bbbbbb"
            font.pixelSize: 12
            font.bold: true
        }

        // 数值行
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
                }
            }
        }
    }
}
