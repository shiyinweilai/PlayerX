// ScSection.qml — 快捷键分组渲染器（从 Main.qml 拆分）
// 小号大写标题 + 一组 ScRow 子项。

import QtQuick
import QtQuick.Layouts

ColumnLayout {
    property string title: ""
    default property alias _rows: scRows.data
    Layout.fillWidth: true
    spacing: 6
    Text {
        text: title
        color: "#9aa0a6"
        font.pixelSize: 11
        font.bold: true
        font.capitalization: Font.AllUppercase
    }
    ColumnLayout {
        id: scRows
        Layout.fillWidth: true
        spacing: 4
    }
}
