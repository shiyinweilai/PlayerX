import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: updateDialog
    property var root: null
    title: qsTr("应用更新")
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    // 下载中禁止 ESC / 点击外部关闭，避免误中断
    closePolicy: (Updater.state === "downloading" || Updater.state === "verifying")
                 ? Popup.NoAutoClose
                 : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
    implicitWidth: 460

    // 是否由用户主动触发（菜单"检查更新…"/胶囊按钮）。决定是否在异常路径下弹 toast。
    property bool userInitiated: false

    Overlay.modal: Rectangle { color: "#aa000000" }

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
        // 双层外阴影
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
            text: Updater.state === "checking"   ? qsTr("正在检查更新…")
                : Updater.state === "available"  ? qsTr("发现新版本")
                : Updater.state === "downloading"? qsTr("正在下载更新…")
                : Updater.state === "verifying"  ? qsTr("正在校验…")
                : Updater.state === "ready"      ? qsTr("即将重启应用")
                : Updater.state === "error"      ? qsTr("更新失败")
                                                 : qsTr("应用更新")
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
        spacing: 12
        // 版本号一行：当前 → 新版本
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                text: qsTr("当前版本")
                color: "#9aa0a6"
                font.pixelSize: 12
            }
            Text {
                text: Updater.currentVersion
                color: "#e8e8ec"
                font.pixelSize: 13
                font.bold: true
            }
            Text {
                visible: Updater.latestVersion.length > 0
                text: "→"
                color: "#9aa0a6"
                font.pixelSize: 12
            }
            Text {
                visible: Updater.latestVersion.length > 0
                text: qsTr("最新版本")
                color: "#9aa0a6"
                font.pixelSize: 12
            }
            Text {
                visible: Updater.latestVersion.length > 0
                text: Updater.latestVersion
                color: "#5cb85c"
                font.pixelSize: 13
                font.bold: true
            }
            Item { Layout.fillWidth: true }
        }

        // 释放说明
        Rectangle {
            visible: Updater.releaseNotes.length > 0 && Updater.state !== "downloading"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(notesText.implicitHeight + 16, 140)
            color: "#16161a"
            border.color: "#2a2a32"
            border.width: 1
            radius: 4
            Flickable {
                anchors.fill: parent
                anchors.margins: 8
                contentHeight: notesText.implicitHeight
                clip: true
                Text {
                    id: notesText
                    width: parent.width
                    text: Updater.releaseNotes
                    color: "#c8c8cc"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    lineHeight: 1.3
                }
            }
        }

        // 进度条（下载/校验阶段显示）
        ColumnLayout {
            visible: Updater.state === "downloading" || Updater.state === "verifying"
            Layout.fillWidth: true
            spacing: 6
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 6
                color: "#16161a"
                border.color: "#2a2a32"
                border.width: 1
                radius: 3
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.margins: 1
                    width: Math.max(2, (parent.width - 2) *
                           (Updater.state === "verifying" ? 1 : Updater.progress))
                    radius: 2
                    color: Updater.state === "verifying" ? "#9aa0a6" : "#0e639c"
                    Behavior on width { NumberAnimation { duration: 120 } }
                }
            }
            Text {
                Layout.fillWidth: true
                text: Updater.state === "verifying"
                      ? qsTr("正在校验文件完整性…")
                      : Updater.progressText
                color: "#9aa0a6"
                font.pixelSize: 11
            }
        }

        // 错误提示
        Text {
            visible: Updater.state === "error"
            Layout.fillWidth: true
            text: Updater.errorText
            color: "#e57373"
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        // ready 提示
        Text {
            visible: Updater.state === "ready"
            Layout.fillWidth: true
            text: qsTr("更新已下载完成，应用将自动退出并安装新版本…")
            color: "#9aa0a6"
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }
    }

    footer: Rectangle {
        color: "transparent"
        implicitHeight: 52
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: "#2a2a32"
        }
        RowLayout {
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            // 下载中：取消按钮
            FlatButton {
                visible: Updater.state === "downloading"
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("取消")
                onClicked: Updater.cancel()
            }

            // 错误状态：关闭 + 重试
            FlatButton {
                visible: Updater.state === "error"
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("关闭")
                onClicked: updateDialog.close()
            }
            FlatButton {
                visible: Updater.state === "error"
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("重试")
                onClicked: {
                    if (Updater.updateAvailable) Updater.downloadAndApply()
                    else { updateDialog.userInitiated = true; Updater.checkForUpdates(false) }
                }
            }

            // 可用状态：稍后 + 立即更新
            FlatButton {
                visible: Updater.state === "available"
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("稍后")
                onClicked: updateDialog.close()
            }
            FlatButton {
                visible: Updater.state === "available"
                implicitWidth: 100
                implicitHeight: 30
                text: qsTr("立即更新")
                onClicked: Updater.downloadAndApply()
            }

            // 检查中 / 校验中 / ready：仅显示一个不可点的"请稍候"
            FlatButton {
                visible: Updater.state === "checking" ||
                         Updater.state === "verifying" ||
                         Updater.state === "ready"
                implicitWidth: 100
                implicitHeight: 30
                text: qsTr("请稍候…")
                enabled: false
            }
        }
    }
}
