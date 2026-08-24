import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: restoreDefaultConfirmDialog
    property var root: null
    property var updateToast: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 400

    // 打开时解析当前模式的中文名，避免文案里出现 mode id
    property string _modeLabel: ""
    onOpened: {
        _modeLabel = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
        try {
            var ml = Rating.modeList
            for (var i = 0; i < ml.length; ++i) {
                if (ml[i].id === Rating.currentMode) { _modeLabel = ml[i].label; break }
            }
        } catch (e) {}
    }

    Overlay.modal: Rectangle { color: "#aa000000" }

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
        // 双层外阴影（深色对话框风格）
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
            text: qsTr("恢复默认配置？")
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
            text: qsTr("将清除「%1」当前远程接受的临时配置，恢复为跟随软件的内置默认配置。\n如需远程配置，之后可重新点 🔔 检测并接受。")
                   .arg(restoreDefaultConfirmDialog._modeLabel)
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
                onClicked: restoreDefaultConfirmDialog.close()
            }
            FlatButton {
                implicitWidth: 110
                implicitHeight: 30
                text: qsTr("恢复默认")
                textColor: "#e8b339"
                onClicked: {
                    restoreDefaultConfirmDialog.close()
                    var ok = Logic._restoreDefaultConfig(Rating.currentMode)
                    updateToast.text = ok ? ("已恢复「" + restoreDefaultConfirmDialog._modeLabel + "」的内置默认配置")
                                          : "恢复失败：没有内置默认配置"
                    updateToast.open()
                }
            }
        }
    }
}
