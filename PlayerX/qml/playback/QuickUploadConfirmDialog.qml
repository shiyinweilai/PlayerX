import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: dlg
    property var root: null
    property var ratingsDialog: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 500

    Overlay.modal: Rectangle { color: "#cc000000" }

    // ─── 状态机 ───────────────────────────────────────────────
    // checking    → 正在查云端记录（打开面板时自动触发）
    // confirm     → 无旧记录，正常上传
    // confirm_ow  → 有旧记录，按钮改为"覆盖上传"
    // uploading   → 上传进行中
    // done_ok     → 上传成功（原面板保留，底部加绿色提示）
    // done_fail   → 上传失败（原面板保留，底部加红色提示）
    property string _phase: "confirm"

    // ─── 数据 ─────────────────────────────────────────────────
    property string _modeLabel: ""
    property string _rater: ""
    property string _tag: ""
    property var    _folders: []
    property int    _recordCount: 0
    property bool   _canUpload: false
    property string _blockReason: ""
    property string _fromArchiveBatch: ""
    property bool   _wasOverwrite: false   // 记录本次是否是覆盖上传，done_ok 时展示

    // conflict 填充
    property string _conflictHint: ""

    // done_ok / done_fail 填充
    property string _viewUrl: ""
    property string _archivedBatch: ""
    property string _failMsg: ""

    // ─── 公开接口 ─────────────────────────────────────────────

    function openWithPreview() {
        _phase = "checking"
        _modeLabel = ""; _rater = ""; _tag = ""
        _folders = []; _recordCount = 0
        _canUpload = false; _blockReason = ""
        _fromArchiveBatch = ""; _conflictHint = ""
        _viewUrl = ""; _archivedBatch = ""; _failMsg = ""
        _wasOverwrite = false

        try {
            if (ratingsDialog && typeof ratingsDialog.previewCurrentUpload === "function") {
                var p = ratingsDialog.previewCurrentUpload() || {}
                _modeLabel        = p.modeLabel   || p.mode || ""
                _rater            = p.rater        || ""
                _tag              = p.tag          || ""
                _folders          = p.folders      || []
                _recordCount      = p.recordCount  || 0
                _canUpload        = !!p.canUpload
                _blockReason      = p.blockReason  || ""
                _fromArchiveBatch = p.fromArchiveBatch || ""
            } else {
                _blockReason = qsTr("评分数据面板尚未就绪，请点「去修改」打开面板")
                _phase = "confirm"
                open()
                return
            }
        } catch (e) {
            _canUpload = false
            _blockReason = qsTr("预览失败：") + String(e)
            _phase = "confirm"
            open()
            return
        }

        open()

        if (!_canUpload) {
            _phase = "confirm"
            return
        }

        if (_rater.length > 0 && _tag.length > 0 && typeof Rating !== "undefined") {
            Rating.checkCloudRecord(_rater, _tag,
                ratingsDialog ? (ratingsDialog._selectedMode || "") : "")
        } else {
            _phase = "confirm"
        }
    }

    function onCloudRecordChecked(hasRecord, message) {
        if (_phase !== "checking") return
        if (hasRecord) {
            _conflictHint = message
            _phase = "confirm_ow"
        } else {
            _phase = "confirm"
        }
    }

    function onConflict(message) {
        _conflictHint = message || qsTr("同 (评分人, tag) 已存在上传记录")
        _phase = "confirm_ow"
    }

    function onSuccess(message, archivedBatch) {
        _archivedBatch = archivedBatch || ""
        var srvBase = (typeof Rating !== "undefined" && Rating.uploadServerUrl)
                      ? String(Rating.uploadServerUrl).trim() : ""
        var m = srvBase.match(/^(https?:\/\/[^\/]+)/)
        _viewUrl = m ? m[1] + "/#results" : ""
        _phase = "done_ok"
        _autoClose.restart()
    }

    function onFailure(message) {
        _failMsg = message || qsTr("上传失败，请稍后重试")
        _phase = "done_fail"
    }

    // ─── 自动关闭（成功后 2s）────────────────────────────────
    Timer {
        id: _autoClose
        interval: 2000; repeat: false
        onTriggered: {
            if (dlg._phase !== "done_ok") return
            var url = dlg._viewUrl
            dlg.close()
            if (url) Qt.openUrlExternally(url)
        }
    }
    onClosed: _autoClose.stop()

    // ─── 背景 ─────────────────────────────────────────────────
    background: Rectangle {
        color: "#1a1a1f"
        radius: 8
        border.width: 1
        border.color: dlg._phase === "confirm_ow" ? "#5a4a20" : "#38383e"
        Behavior on border.color { ColorAnimation { duration: 180 } }
    }

    // ─── 标题 ─────────────────────────────────────────────────
    header: Rectangle {
        color: "transparent"
        implicitHeight: 48
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 18; anchors.rightMargin: 14
            spacing: 8
            Text {
                text: dlg._phase === "confirm_ow" ? "⚠" : "☁"
                font.pixelSize: 16
                color: dlg._phase === "confirm_ow" ? "#ffc060" : "#4fc3f7"
                Behavior on color { ColorAnimation { duration: 180 } }
            }
            Text {
                Layout.fillWidth: true
                text: dlg._phase === "confirm_ow"
                      ? qsTr("上传评分数据到云端（将覆盖旧记录）")
                      : qsTr("上传评分数据到云端")
                color: dlg._phase === "confirm_ow" ? "#ffc060" : "#e8e8ec"
                font.pixelSize: 14; font.bold: true
                Behavior on color { ColorAnimation { duration: 180 } }
            }
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1; color: "#2e2e36"
        }
    }

    // ─── 内容区 ───────────────────────────────────────────────
    contentItem: ColumnLayout {
        spacing: 10

        // ── 摘要格（全阶段都显示）────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            color: "#1f1f27"; radius: 6
            implicitHeight: summaryGrid.implicitHeight + 24

            GridLayout {
                id: summaryGrid
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                columns: 4; columnSpacing: 16; rowSpacing: 8

                Text { text: qsTr("评分模式"); color: "#5a6070"; font.pixelSize: 11 }
                Text { text: qsTr("评分人");   color: "#5a6070"; font.pixelSize: 11 }
                Text { text: qsTr("备注 tag"); color: "#5a6070"; font.pixelSize: 11 }
                Text { text: qsTr("评分记录"); color: "#5a6070"; font.pixelSize: 11 }

                Text {
                    text: dlg._modeLabel || "—"
                    color: "#ffd27a"; font.pixelSize: 15; elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Text {
                    text: dlg._rater.length > 0 ? dlg._rater : qsTr("未填写")
                    color: dlg._rater.length > 0 ? "#ffd27a" : "#e07070"
                    font.pixelSize: 15; font.bold: dlg._rater.length > 0; elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Text {
                    text: dlg._tag.length > 0 ? dlg._tag : qsTr("未填写")
                    color: dlg._tag.length > 0 ? "#ffd27a" : "#e07070"
                    font.pixelSize: 15; font.bold: dlg._tag.length > 0; elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Text {
                    text: dlg._folders.length + qsTr("个文件夹 · ") + dlg._recordCount + qsTr("条")
                    color: "#ffd27a"; font.pixelSize: 14; elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }

        // ── 云端检测中 loading ────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            visible: dlg._phase === "checking"
            spacing: 8
            BusyIndicator { running: dlg._phase === "checking"; implicitWidth: 18; implicitHeight: 18 }
            Text { text: qsTr("正在检测云端记录…"); color: "#7a8090"; font.pixelSize: 12 }
        }

        // ── 冲突提示（confirm_ow）────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: dlg._phase === "confirm_ow"
            color: "#2a1e08"; border.color: "#6a4e18"; border.width: 1; radius: 5
            implicitHeight: owText.implicitHeight + 16
            Text {
                id: owText
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 10
                text: dlg._conflictHint + "\n" + qsTr("点击「覆盖上传」将替换旧记录（旧数据由服务端自动备份，可追回）。")
                color: "#ffd090"; font.pixelSize: 12
                wrapMode: Text.WordWrap; lineHeight: 1.4
            }
        }

        // ── 校验失败提示 ──────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: (dlg._phase === "confirm" || dlg._phase === "confirm_ow")
                     && !dlg._canUpload && dlg._blockReason.length > 0
            color: "#2a1212"; border.color: "#6a2020"; border.width: 1; radius: 5
            implicitHeight: blockText.implicitHeight + 16
            Text {
                id: blockText
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 10
                text: "⚠  " + dlg._blockReason
                color: "#f0a0a0"; font.pixelSize: 12
                wrapMode: Text.WordWrap; lineHeight: 1.4
            }
        }

        // ── 归档提示（confirm / confirm_ow，可上传时）────────
        Rectangle {
            Layout.fillWidth: true
            visible: (dlg._phase === "confirm" || dlg._phase === "confirm_ow")
                     && dlg._canUpload
            color: "#0c1c30"; border.color: "#1a4a70"; border.width: 1; radius: 5
            implicitHeight: archText.implicitHeight + 14
            Text {
                id: archText
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 9
                text: dlg._fromArchiveBatch.length > 0
                      ? qsTr("📂  已归档在 归档/%1，上传后不重复归档。").arg(dlg._tag)
                      : qsTr("📂  上传成功后自动归档到 归档/%1。").arg(dlg._tag)
                color: "#80b8e0"; font.pixelSize: 12; wrapMode: Text.WordWrap
            }
        }

        // ── 上传中 loading ────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            visible: dlg._phase === "uploading"
            spacing: 10
            BusyIndicator { running: dlg._phase === "uploading"; implicitWidth: 22; implicitHeight: 22 }
            Text { text: qsTr("正在上传，请稍候…"); color: "#9aa0a6"; font.pixelSize: 13 }
        }

        // ── 成功提示条（done_ok）──────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: dlg._phase === "done_ok"
            color: "#0d2218"; border.color: "#2a6640"; border.width: 1; radius: 5
            implicitHeight: doneOkCol.implicitHeight + 16
            Column {
                id: doneOkCol
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 11
                spacing: 4
                RowLayout {
                    spacing: 6
                    Text { text: "✅"; font.pixelSize: 13 }
                    Text {
                        text: qsTr("上传成功")
                              + (dlg._wasOverwrite ? qsTr("（已覆盖旧记录）") : "")
                        color: "#7ce495"; font.pixelSize: 13; font.bold: true
                    }
                }
                Text {
                    visible: dlg._archivedBatch.length > 0
                    width: doneOkCol.width
                    text: qsTr("已归档到 归档/%1").arg(dlg._archivedBatch)
                    color: "#80d8ff"; font.pixelSize: 12
                }
                Text {
                    visible: dlg._viewUrl.length > 0
                    width: doneOkCol.width
                    text: qsTr("即将跳转到结果页…")
                    color: "#6a8090"; font.pixelSize: 11
                }
            }
        }

        // ── 失败提示条（done_fail）────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: dlg._phase === "done_fail"
            color: "#251010"; border.color: "#602020"; border.width: 1; radius: 5
            implicitHeight: failText.implicitHeight + 16
            Text {
                id: failText
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 10
                text: "❌  " + dlg._failMsg
                color: "#ffb0b0"; font.pixelSize: 12; wrapMode: Text.WordWrap; lineHeight: 1.4
            }
        }

        Item { implicitHeight: 2 }
    }

    // ─── 底部按钮 ─────────────────────────────────────────────
    footer: Rectangle {
        color: "transparent"
        implicitHeight: 54
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.top: parent.top; height: 1; color: "#2a2a34"
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14; anchors.rightMargin: 14
            anchors.topMargin: 11; anchors.bottomMargin: 11
            spacing: 8

            // 取消（checking / confirm / confirm_ow）
            FlatButton {
                visible: dlg._phase === "checking"
                         || dlg._phase === "confirm"
                         || dlg._phase === "confirm_ow"
                implicitWidth: 72; implicitHeight: 30
                text: qsTr("取消")
                onClicked: dlg.close()
            }

            // 去修改（confirm / confirm_ow）
            FlatButton {
                visible: dlg._phase === "confirm" || dlg._phase === "confirm_ow"
                implicitWidth: 96; implicitHeight: 30
                text: qsTr("去修改")
                textColor: "#c0c4cc"
                onClicked: { dlg.close(); ratingsDialog.open() }
            }

            // 关闭（done_ok / done_fail）
            FlatButton {
                visible: dlg._phase === "done_ok" || dlg._phase === "done_fail"
                implicitWidth: 72; implicitHeight: 30
                text: qsTr("关闭")
                onClicked: dlg.close()
            }

            Item { Layout.fillWidth: true }

            // ── 主操作按钮 ────────────────────────────────────
            Rectangle {
                visible: dlg._phase === "checking"
                         || dlg._phase === "confirm"
                         || dlg._phase === "confirm_ow"
                implicitWidth: dlg._phase === "checking" ? 100 : 112
                implicitHeight: 30
                radius: 5

                property bool _active: dlg._canUpload
                                       && (dlg._phase === "confirm" || dlg._phase === "confirm_ow")
                color: {
                    if (!_active) return "#28282e"
                    if (dlg._phase === "confirm_ow") return mainBtn.pressed ? "#5a3c00" : mainBtn.hovered ? "#7a5200" : "#6a4800"
                    return mainBtn.pressed ? "#1256a0" : mainBtn.hovered ? "#1769c4" : "#1976d2"
                }
                border.width: _active ? 0 : 1
                border.color: "#38383e"
                Behavior on color { ColorAnimation { duration: 120 } }

                MouseArea {
                    id: mainBtn
                    anchors.fill: parent
                    enabled: parent._active
                    hoverEnabled: true
                    property bool hovered: false; property bool pressed: false
                    onEntered: hovered = true; onExited: hovered = false
                    onPressed: pressed = true; onReleased: pressed = false
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        var isForce = (dlg._phase === "confirm_ow")
                        dlg._wasOverwrite = isForce
                        dlg._phase = "uploading"
                        if (ratingsDialog && typeof ratingsDialog.triggerQuickUploadForCurrentTab === "function") {
                            ratingsDialog.triggerQuickUploadForCurrentTab(isForce)
                        }
                    }
                }
                RowLayout {
                    anchors.centerIn: parent; spacing: 5
                    Text {
                        text: dlg._phase === "checking"    ? qsTr("检测中…")
                              : dlg._phase === "confirm_ow" ? "☁  " + qsTr("覆盖上传")
                              : "☁  " + qsTr("确认上传")
                        font.pixelSize: 13; font.bold: true
                        color: parent.parent._active ? "#ffffff" : "#484850"
                    }
                }
            }
        }
    }
}
