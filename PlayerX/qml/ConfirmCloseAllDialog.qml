import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: confirmCloseAllDialog
    property var root: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 380

    Overlay.modal: Rectangle { color: "#aa000000" }

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
        // 双层外阴影（与 aboutDialog/shortcutsDialog 一致）
        Rectangle {
            z: -1
            anchors.fill: parent
            anchors.margins: -8
            radius: parent.radius + 4
            color: "transparent"
            border.color: "#80000000"
            border.width: 1
            opacity: 0.45
        }
        Rectangle {
            z: -1
            anchors.fill: parent
            anchors.margins: -4
            radius: parent.radius + 2
            color: "transparent"
            border.color: "#a0000000"
            border.width: 1
            opacity: 0.55
        }
    }

    header: Rectangle {
        color: "transparent"
        implicitHeight: 40
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("关闭所有视频？")
            color: "#e8e8ec"
            font.pixelSize: 15
            font.bold: true
        }
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: "#2a2a32"
        }
    }

    contentItem: ColumnLayout {
        spacing: 10
        Text {
            Layout.fillWidth: true
            text: qsTr("此操作将关闭当前所有 %1 路视频，本次播放进度不会保留。\n本地评分（ratings.csv）不受影响。")
                   .arg(Engine.fileCount)
            color: "#c8c8cc"
            font.pixelSize: 13
            wrapMode: Text.WordWrap
            lineHeight: 1.3
        }
    }

    footer: Rectangle {
        color: "transparent"
        implicitHeight: 56
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: "#2a2a32"
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            anchors.topMargin: 12
            anchors.bottomMargin: 12
            spacing: 8
            Item { Layout.fillWidth: true }
            FlatButton {
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("取消")
                onClicked: confirmCloseAllDialog.close()
            }
            FlatButton {
                implicitWidth: 110
                implicitHeight: 30
                text: qsTr("关闭全部")
                textColor: "#e07070"   // 危险动作 → 红色文字
                onClicked: {
                    confirmCloseAllDialog.close()
                    Engine.closeAll()
                }
            }
        }
    }
}
