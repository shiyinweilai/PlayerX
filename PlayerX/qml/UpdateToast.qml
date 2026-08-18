import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Popup {
    id: updateToast
    property var root: null
    property string text: ""
    modal: false
    focus: false
    closePolicy: Popup.NoAutoClose
    // 锚到右下角；ApplicationWindow 内 popup 默认坐标系 = window
    x: root.width - width - 24
    y: root.height - height - 36
    padding: 0
    background: Rectangle {
        color: "#222226"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
    }
    contentItem: Text {
        text: updateToast.text
        color: "#e8e8ec"
        font.pixelSize: 12
        padding: 12
    }
    Timer {
        running: updateToast.opened
        interval: 2400
        onTriggered: updateToast.close()
    }
}
