import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Rectangle {
    id: csvBottomVSplitter
    property var root: null
    property Item csvBottomBar: null
    visible: csvBottomBar.showFull && csvBottomBar.height > 0
    z: 100
    anchors.left: csvBottomBar.left
    anchors.right: csvBottomBar.right
    // 中心贴到 csvBottomBar 顶边
    y: csvBottomBar.y - 3
    height: 6
    color: csvBottomVSplitterMA.containsMouse || csvBottomVSplitterMA.pressed
           ? "#2a2a32" : "transparent"
    Row {
        anchors.centerIn: parent
        spacing: 4
        Repeater {
            model: 3
            Rectangle { width: 3; height: 3; radius: 1.5; color: "#5a5a66" }
        }
    }
    MouseArea {
        id: csvBottomVSplitterMA
        anchors.fill: parent
        anchors.topMargin: -2
        anchors.bottomMargin: -2
        hoverEnabled: true
        cursorShape: Qt.SplitVCursor
        property real _grabY: 0
        onPressed: function(mouse) { _grabY = mouse.y }
        onPositionChanged: function(mouse) {
            if (!pressed) return
            // 鼠标向上拖 -> 高度增大
            var newH = root.csvBottomBarUserHeight - (mouse.y - _grabY)
            // 限制 [60, 280]：太低看不清，太高挤压视频
            var maxH = Math.max(60, root.height - 200) // 至少给视频留 200
            root.csvBottomBarUserHeight = Math.max(60, Math.min(Math.min(280, maxH), newH))
        }
        onDoubleClicked: root.csvBottomBarUserHeight = 88
    }
}
