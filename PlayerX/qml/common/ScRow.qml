// ScRow.qml — 快捷键行渲染器（从 Main.qml 拆分）
// 按键徽章（等宽字体 + 深色边框）+ 描述文字。

import QtQuick
import QtQuick.Layouts

RowLayout {
    property string keys: ""
    property string desc: ""
    Layout.fillWidth: true
    spacing: 10
    Rectangle {
        Layout.preferredWidth: Math.max(64, Math.min(120, kbdText.implicitWidth + 18))
        Layout.preferredHeight: kbdText.implicitHeight + 6
        radius: 4
        color: "#14141a"
        border.color: "#2a2a32"
        border.width: 1
        Text {
            id: kbdText
            anchors.centerIn: parent
            text: keys
            color: "#e8e8ec"
            font.pixelSize: 12
            font.family: "Menlo, Consolas, monospace"
        }
    }
    Text {
        Layout.fillWidth: true
        text: desc
        color: "#cfd2d6"
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }
}
