import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Rectangle {
    id: refSidebarHSplitter
    property var root: null
    property Item refSidebar: null
    property Item csvBottomBar: null
    visible: root.refSidebarVisible
    z: 100
    anchors.top: parent.top
    anchors.bottom: csvBottomBar.top
    // 中心对齐到 refSidebar 的右边缘上，分隔条本身 6px 宽
    x: refSidebar.x + refSidebar.width - 3
    width: 6
    color: refSidebarHSplitterMA.containsMouse || refSidebarHSplitterMA.pressed
           ? "#2a2a32" : "transparent"
    // 中线小提示
    Column {
        anchors.centerIn: parent
        spacing: 4
        Repeater {
            model: 3
            Rectangle { width: 3; height: 3; radius: 1.5; color: "#5a5a66" }
        }
    }
    MouseArea {
        id: refSidebarHSplitterMA
        anchors.fill: parent
        anchors.leftMargin: -2
        anchors.rightMargin: -2
        hoverEnabled: true
        cursorShape: Qt.SplitHCursor
        property real _grabX: 0
        onPressed: function(mouse) { _grabX = mouse.x }
        onPositionChanged: function(mouse) {
            if (!pressed) return
            var newW = root.refSidebarUserWidth + (mouse.x - _grabX)
            // 限制 [200, 600]：避免栏太窄/太宽
            var maxW = Math.max(200, root.width - 400) // 至少给视频留 400
            root.refSidebarUserWidth = Math.max(200, Math.min(Math.min(600, maxW), newW))
        }
        onDoubleClicked: root.refSidebarUserWidth = 320
    }
}
