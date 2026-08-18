import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

MouseArea {
    id: taskUpdateDismissArea
    property var root: null
    anchors.fill: parent
    z: 9999
    visible: root._taskUpdateVisible
    hoverEnabled: false
    cursorShape: Qt.ArrowCursor
    onClicked: root._taskUpdateVisible = false
}
