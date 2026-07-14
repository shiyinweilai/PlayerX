// ─────────────────────────────────────────────────────────────
// DarkMenuSeparator.qml —— MenuBar 下拉菜单专用的深色分隔线
//
// 说明：QtQuick.Controls 默认 MenuSeparator 在 Basic style 下是
//       粗白色实线，在半透明深色底上过于抢眼。本组件把它换成
//       1px 白 20% α 细线，两侧留 8px 边距。
// ─────────────────────────────────────────────────────────────
import QtQuick
import QtQuick.Controls

MenuSeparator {
    id: root

    padding: 4
    topPadding: 4
    bottomPadding: 4
    leftPadding: 8
    rightPadding: 8

    contentItem: Rectangle {
        implicitWidth: 200
        implicitHeight: 1
        color: "#33ffffff"
    }

    background: Item {}
}
