import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

// 【设置 → 测试配置 → 清除多路历史记录】二次确认对话框，样式与 RestoreDefaultConfirmDialog 一致。
Dialog {
    id: clearHistoryConfirmDialog
    property var root: null
    property var updateToast: null
    property var multiGroupDialog: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 420

    Overlay.modal: Rectangle { color: "#aa000000" }

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
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
            text: qsTr("清除多路历史记录？")
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
            text: qsTr("将清除“播放对比 / 多组对比”记住的全部文件夹历史（所有评分模式），"
                       + "并重置为默认 2 路空槶。\n用于避免历史记录堆积导致新导入的路被静默丢弃。"
                       + "\n不会影响已保存的评分数据与参考图配置。")
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
                onClicked: clearHistoryConfirmDialog.close()
            }
            FlatButton {
                implicitWidth: 130
                implicitHeight: 30
                text: qsTr("清除历史记录")
                textColor: "#e8b339"
                onClicked: {
                    clearHistoryConfirmDialog.close()
                    var ok = multiGroupDialog ? multiGroupDialog.clearAllHistory() : false
                    if (updateToast) {
                        updateToast.text = ok ? "已清除全部多路历史记录，重置为默认 2 路"
                                              : "清除失败：多路对比模块未就绪"
                        updateToast.open()
                    }
                }
            }
        }
    }
}
