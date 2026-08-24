import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

MouseArea {
    property var root: null
    property int edges: 0
    hoverEnabled: true
    cursorShape: {
        switch (edges) {
        case Qt.LeftEdge:
        case Qt.RightEdge:  return Qt.SizeHorCursor
        case Qt.TopEdge:
        case Qt.BottomEdge: return Qt.SizeVerCursor
        case Qt.TopEdge | Qt.LeftEdge:
        case Qt.BottomEdge | Qt.RightEdge: return Qt.SizeFDiagCursor
        default:            return Qt.SizeBDiagCursor
        }
    }
    onPressed: root.startSystemResize(edges)
}
