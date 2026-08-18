import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: quickUploadOverwriteDialog
    property var root: null
    property var ratingsDialog: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 460

    property string _msg: ""
    function showConflict(message) {
        _msg = message || qsTr("同 (评分人, tag) 已存在上传记录")
        open()
    }

    Overlay.modal: Rectangle { color: "#aa000000" }
    background: Rectangle {
        color: "#1e1e22"
        border.color: "#7a5a3a"     // 警示色（琥珀）
        border.width: 1
        radius: 8
        Rectangle {
            z: -1; anchors.fill: parent; anchors.margins: -6
            radius: parent.radius + 4
            color: "transparent"; border.color: "#80000000"; border.width: 1
            opacity: 0.5
        }
    }
    header: Rectangle {
        color: "transparent"; implicitHeight: 44
        Text {
            anchors.left: parent.left; anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("⚠ 服务器已存在同名上传")
            color: "#ffcc80"; font.pixelSize: 15; font.bold: true
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1; color: "#2a2a32"
        }
    }
    contentItem: ColumnLayout {
        spacing: 10
        Text {
            Layout.fillWidth: true
            text: quickUploadOverwriteDialog._msg
            color: "#c8c8cc"; font.pixelSize: 13
            wrapMode: Text.WordWrap; lineHeight: 1.3
        }
        Text {
            Layout.fillWidth: true
            text: qsTr("是否要覆盖旧记录？\n（覆盖后旧文件会被服务端自动归档到旧版备份中，可事后追回。）")
            color: "#9aa0a6"; font.pixelSize: 12
            wrapMode: Text.WordWrap; lineHeight: 1.3
        }
    }
    footer: Rectangle {
        color: "transparent"; implicitHeight: 56
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.top: parent.top
            height: 1; color: "#2a2a32"
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14; anchors.rightMargin: 14
            anchors.topMargin: 12; anchors.bottomMargin: 12
            spacing: 8
            Item { Layout.fillWidth: true }
            FlatButton {
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("取消")
                onClicked: {
                    // 用户放弃覆盖：把 quickUploadInProgress 关闭，
                    // 避免下一次上传结果被误路由。
                    if (typeof ratingsDialog !== "undefined")
                        ratingsDialog._quickUploadInProgress = false
                    quickUploadOverwriteDialog.close()
                }
            }
            FlatButton {
                implicitWidth: 130
                implicitHeight: 30
                text: qsTr("☁ 覆盖上传")
                textColor: "#4fc3f7"
                onClicked: {
                    quickUploadOverwriteDialog.close()
                    // 覆盖上传：force=true，走同一条 uploadToCloud 通路，
                    // 上传结果仍会经 onQuickUploadFinished 回来（quickUploadInProgress 仍为 true）。
                    if (typeof Rating !== "undefined"
                            && typeof ratingsDialog !== "undefined") {
                        var folders = ratingsDialog._lastUploadFolders || []
                        if (ratingsDialog._lastUploadKind === "archive") {
                            Rating.uploadArchiveBatchToCloud(
                                ratingsDialog._selectedMode,
                                ratingsDialog._lastUploadArchiveBatch,
                                true, folders)
                        } else {
                            Rating.uploadToCloud(true, folders)
                        }
                    }
                }
            }
        }
    }
}
