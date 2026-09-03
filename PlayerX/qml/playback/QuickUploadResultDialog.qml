import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: quickUploadResultDialog
    property var root: null
    property var quickUploadConfirmDialog: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 480

    property bool _ok: true
    property string _msg: ""
    property string _viewUrl: ""
    // 上传成功后自动归档产生的批次名；为空表示本次未自动归档
    property string _archivedBatch: ""
    // 展示上下文（成功时用）
    property string _modeLabel: ""
    property string _rater: ""
    property string _tag: ""
    property var    _folderPaths: []

    // 从 quickUploadConfirmDialog 里"复用"上一次预览时的上下文信息，
    // 避免重新收集：这些字段在点"确认上传"→ 触发上传时已经确定，
    // 上传的中间过程也不会改变它们的语义。
    function _fillContextFromConfirm() {
        _modeLabel = quickUploadConfirmDialog._modeLabel || ""
        _rater     = quickUploadConfirmDialog._rater     || ""
        _tag       = quickUploadConfirmDialog._tag       || ""
        // 文件夹路径列表转为 ~ 前缀相对路径展示
        var raw = []
        var fs = quickUploadConfirmDialog._folders || []
        for (var i = 0; i < fs.length; ++i) {
            var p = String(fs[i].path || "")
            var m = p.match(/^(\/Users\/[^\/]+)(\/.*)?$/)
            if (m) p = "~" + (m[2] || "")
            raw.push(p)
        }
        _folderPaths = raw
    }
    function showSuccess(message, archivedBatch) {
        _ok = true
        _msg = message || qsTr("上传成功")
        _archivedBatch = (archivedBatch === undefined) ? "" : (archivedBatch || "")
        var srvBase = (typeof Rating !== "undefined" && Rating.uploadServerUrl)
                      ? Rating.uploadServerUrl.trim() : ""
        var m = srvBase.match(/^(https?:\/\/[^/]+)/)
        _viewUrl = m ? m[1] + "/#results" : ""
        _fillContextFromConfirm()
        open()
        // 成功后自动关闭并跳转「查看结果」；用户也可以在此之前手动点击。
        _autoCloseTimer.restart()
    }
    function showFailure(message) {
        _ok = false
        _msg = message || qsTr("上传失败")
        _viewUrl = ""
        _archivedBatch = ""
        _fillContextFromConfirm()
        // 失败弹窗不自动关闭，等用户看清错误信息
        _autoCloseTimer.stop()
        open()
    }

    // 自动关闭定时器：仅上传成功时启用，超时后关闭弹窗并跳转结果页
    Timer {
        id: _autoCloseTimer
        interval: 2000
        repeat: false
        onTriggered: {
            if (!quickUploadResultDialog._ok) return
            var url = quickUploadResultDialog._viewUrl
            quickUploadResultDialog.close()
            if (url && url.length > 0) Qt.openUrlExternally(url)
        }
    }
    // 用户主动关闭（点"确定"、Esc、点外部）时终止定时器，避免二次触发跳转
    onClosed: _autoCloseTimer.stop()

    Overlay.modal: Rectangle { color: "#aa000000" }
    background: Rectangle {
        color: "#1e1e22"
        border.color: quickUploadResultDialog._ok ? "#3a7a4d" : "#7a3a3a"
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
            text: quickUploadResultDialog._ok
                  ? qsTr("✅ 上传成功")
                  : qsTr("❌ 上传失败")
            color: quickUploadResultDialog._ok ? "#7ce495" : "#ff8a8a"
            font.pixelSize: 16; font.bold: true
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1; color: "#2a2a32"
        }
    }
    contentItem: ColumnLayout {
        spacing: 10

        // 成功时展示上下文明细（模式 / tag / 评分人 / 文件夹清单）
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 12
            rowSpacing: 6
            visible: quickUploadResultDialog._ok

            Text { text: qsTr("评分模式："); color: "#9aa0a6"; font.pixelSize: 12 }
            Text {
                Layout.fillWidth: true
                text: quickUploadResultDialog._modeLabel || "—"
                color: "#e8e8ec"; font.pixelSize: 13; elide: Text.ElideRight
            }
            Text { text: qsTr("备注 tag："); color: "#9aa0a6"; font.pixelSize: 12 }
            Text {
                Layout.fillWidth: true
                text: quickUploadResultDialog._tag || "—"
                color: "#4fc3f7"; font.pixelSize: 13; elide: Text.ElideRight
            }
            Text { text: qsTr("评分人："); color: "#9aa0a6"; font.pixelSize: 12 }
            Text {
                Layout.fillWidth: true
                text: quickUploadResultDialog._rater || "—"
                color: "#e8e8ec"; font.pixelSize: 13; elide: Text.ElideRight
            }
            // 上传成功后自动归档的批次（仅自动归档成功时显示）
            Text {
                visible: quickUploadResultDialog._archivedBatch.length > 0
                text: qsTr("已自动归档：")
                color: "#9aa0a6"; font.pixelSize: 12
            }
            Text {
                visible: quickUploadResultDialog._archivedBatch.length > 0
                Layout.fillWidth: true
                text: (quickUploadResultDialog._archivedBatch.length > 0)
                      ? ("✅ " + quickUploadResultDialog._archivedBatch
                         + qsTr("（已从当前列表移入归档）"))
                      : "—"
                color: "#8ad4ff"; font.pixelSize: 13; elide: Text.ElideRight
            }
            Text {
                text: qsTr("文件夹：")
                color: "#9aa0a6"; font.pixelSize: 12
                Layout.alignment: Qt.AlignTop
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Repeater {
                    model: quickUploadResultDialog._folderPaths
                    Text {
                        Layout.fillWidth: true
                        text: modelData || ""
                        color: "#e8e8ec"; font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                }
            }
        }

        // 失败时只展示错误消息
        Text {
            Layout.fillWidth: true
            visible: !quickUploadResultDialog._ok
            text: quickUploadResultDialog._msg
            color: "#ffb0b0"; font.pixelSize: 13
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
            FlatButton {
                implicitWidth: 110
                implicitHeight: 30
                text: qsTr("🔗 查看结果")
                textColor: "#4fc3f7"
                visible: quickUploadResultDialog._ok
                         && quickUploadResultDialog._viewUrl.length > 0
                onClicked: Qt.openUrlExternally(quickUploadResultDialog._viewUrl)
            }
            Item { Layout.fillWidth: true }
            FlatButton {
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("确定")
                onClicked: quickUploadResultDialog.close()
            }
        }
    }
}
