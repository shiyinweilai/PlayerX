import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: quickUploadConfirmDialog
    property var root: null
    property var ratingsDialog: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 620

    Overlay.modal: Rectangle { color: "#cc000000" }

    // ── 预览数据（openWithPreview 填充；关闭后不清空，方便调试）──
    property string _mode: ""
    property string _modeLabel: ""
    property string _rater: ""
    property string _tag: ""
    property var    _folders: []
    property int    _recordCount: 0
    property bool   _canUpload: false
    property string _blockReason: ""
    property string _fromArchiveBatch: ""
    property string _sourceLabel: ""

    function openWithPreview() {
        console.log("[QuickUpload] openWithPreview() start")
        _mode = ""; _modeLabel = ""; _rater = ""; _tag = ""
        _folders = []; _recordCount = 0
        _canUpload = false; _blockReason = ""
        _fromArchiveBatch = ""
        _sourceLabel = ""

        try {
            if (typeof ratingsDialog !== "undefined"
                    && typeof ratingsDialog.previewCurrentUpload === "function") {
                var p = ratingsDialog.previewCurrentUpload() || {}
                _mode        = p.mode        || ""
                _modeLabel   = p.modeLabel   || _mode
                _rater       = p.rater       || ""
                _tag         = p.tag         || ""
                _folders     = p.folders     || []
                _recordCount = p.recordCount || 0
                _canUpload   = !!p.canUpload
                _blockReason = p.blockReason || ""
                _fromArchiveBatch = p.fromArchiveBatch || ""
                _sourceLabel = p.sourceLabel || ""
                console.log("[QuickUpload] preview ok:",
                            "mode=", _mode, "rater=", _rater, "tag=", _tag,
                            "folders=", _folders.length, "canUpload=", _canUpload)
            } else {
                _blockReason = qsTr("评分数据面板尚未就绪，请点「去修改」打开面板")
                console.log("[QuickUpload] ratingsDialog or preview fn missing")
            }
        } catch (e) {
            _canUpload = false
            _blockReason = qsTr("预览失败：") + String(e)
            console.log("[QuickUpload] preview threw:", e)
        }
        console.log("[QuickUpload] calling open()...")
        open()
    }

    // ── 背景 ───────────────────────────────────────────────────
    background: Rectangle {
        color: "#1a1a1f"
        border.color: "#44444e"
        border.width: 1
        radius: 8
    }

    // ── 标题栏 ─────────────────────────────────────────────────
    header: Rectangle {
        color: "#22222a"
        implicitHeight: 52
        radius: 8
        // 只上圆角
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: parent.radius; color: parent.color
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 18; anchors.rightMargin: 18
            spacing: 10
            Text {
                text: "☁"
                font.pixelSize: 18
                color: "#4fc3f7"
            }
            Text {
                text: qsTr("上传评分数据到云端")
                color: "#f0f0f4"
                font.pixelSize: 15
                font.bold: true
                Layout.fillWidth: true
            }
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1; color: "#33333c"
        }
    }

    // ── 内容区 ─────────────────────────────────────────────────
    contentItem: ColumnLayout {
        spacing: 0

        // ── 摘要信息块（2×2 网格：评分模式/评分人/备注tag/评分记录）──
        // 用 Item+anchors 实现，规避 AOT 下 Layout.preferredWidth 兼容问题
        Item {
            id: summaryBlock
            Layout.fillWidth: true
            Layout.topMargin: 4
            implicitHeight: gridBg.implicitHeight

            Rectangle {
                id: gridBg
                anchors.fill: parent
                color: "#1f1f26"
                radius: 6
                implicitHeight: Math.max(cellTL.implicitHeight, cellTR.implicitHeight)
                              + Math.max(cellBL.implicitHeight, cellBR.implicitHeight)
                              + 52   // 上下边距 + 行间距
            }

            // 竖分隔线
            Rectangle {
                id: vDivider
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: 12; anchors.bottomMargin: 12
                width: 1; color: "#2a2a34"
            }
            // 横分隔线
            Rectangle {
                id: hDivider
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: parent.implicitHeight / 2
                anchors.leftMargin: 16; anchors.rightMargin: 16
                height: 1; color: "#2a2a34"
            }

            // 左上：评分模式
            Column {
                id: cellTL
                anchors.left: parent.left
                anchors.right: vDivider.left
                anchors.top: parent.top
                anchors.leftMargin: 18; anchors.rightMargin: 14
                anchors.topMargin: 18
                spacing: 5
                Text {
                    text: qsTr("评分模式")
                    color: "#585e68"; font.pixelSize: 11
                }
                    Text {
                        width: parent.width
                        text: quickUploadConfirmDialog._modeLabel || "—"
                        color: "#ffd27a"
                        font.pixelSize: 17
                        elide: Text.ElideRight
                    }
            }

            // 右上：评分人
            Column {
                id: cellTR
                anchors.left: vDivider.right
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 14; anchors.rightMargin: 18
                anchors.topMargin: 18
                spacing: 5
                Text {
                    text: qsTr("评分人")
                    color: "#585e68"; font.pixelSize: 11
                }
                Text {
                    width: parent.width
                    text: quickUploadConfirmDialog._rater.length > 0
                          ? quickUploadConfirmDialog._rater
                          : qsTr("（未填写）")
                    color: quickUploadConfirmDialog._rater.length > 0 ? "#ffd27a" : "#e07070"
                    font.pixelSize: 20
                    font.bold: true
                    elide: Text.ElideRight
                }
            }

            // 左下：备注 tag
            Column {
                id: cellBL
                anchors.left: parent.left
                anchors.right: vDivider.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: 18; anchors.rightMargin: 14
                anchors.bottomMargin: 18
                spacing: 5
                Text {
                    text: qsTr("备注 tag")
                    color: "#585e68"; font.pixelSize: 11
                }
                Text {
                    width: parent.width
                    text: quickUploadConfirmDialog._tag.length > 0
                          ? quickUploadConfirmDialog._tag
                          : qsTr("（未填写）")
                    color: quickUploadConfirmDialog._tag.length > 0 ? "#ffd27a" : "#e07070"
                    font.pixelSize: 20
                    font.bold: true
                    elide: Text.ElideRight
                }
            }

            // 右下：评分记录
            Column {
                id: cellBR
                anchors.left: vDivider.right
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 14; anchors.rightMargin: 18
                anchors.bottomMargin: 18
                spacing: 5
                Text {
                    text: qsTr("评分记录")
                    color: "#585e68"; font.pixelSize: 11
                }
                Text {
                    width: parent.width
                    text: quickUploadConfirmDialog._folders.length + qsTr(" 个文件夹  ·  ") +
                          quickUploadConfirmDialog._recordCount + qsTr(" 条评分")
                    color: "#ffd27a"
                    font.pixelSize: 20
                    font.bold: true
                    elide: Text.ElideRight
                }
            }
        }

        // ── 校验失败 banner ─────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 10
            visible: !quickUploadConfirmDialog._canUpload
                     && quickUploadConfirmDialog._blockReason.length > 0
            color: "#2e1a1a"
            border.color: "#6a3030"; border.width: 1
            radius: 6
            implicitHeight: blockText.implicitHeight + 18
            RowLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8
                Text {
                    text: "⚠"
                    color: "#ff8080"
                    font.pixelSize: 14
                    verticalAlignment: Text.AlignTop
                }
                Text {
                    id: blockText
                    Layout.fillWidth: true
                    text: quickUploadConfirmDialog._blockReason
                    color: "#f0a0a0"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
            }
        }

        // ── 脚注说明 ────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 10
            visible: footNoteText.text.length > 0
            color: "#0d2140"
            border.color: "#1976d2"
            border.width: 1
            radius: 6
            implicitHeight: footNoteText.implicitHeight + 16

            RowLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8
                Text {
                    text: "📂"
                    font.pixelSize: 13
                    color: "#4fc3f7"
                    verticalAlignment: Text.AlignVCenter
                }
                Text {
                    id: footNoteText
                    Layout.fillWidth: true
                    text: quickUploadConfirmDialog._fromArchiveBatch.length > 0
                          ? qsTr("已归档在 归档/%1 目录，上传后不会重复归档。")
                            .arg(quickUploadConfirmDialog._tag)
                          : (quickUploadConfirmDialog._canUpload
                             ? qsTr("上传成功后自动归档到 归档/%1 目录。")
                               .arg(quickUploadConfirmDialog._tag)
                             : "")
                    color: "#90caf9"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
            }
        }

        Item { implicitHeight: 4 }
    }

    // ── 底部按钮 ───────────────────────────────────────────────
    footer: Rectangle {
        color: "#1e1e26"
        implicitHeight: 58
        radius: 8
        // 只下圆角
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.top: parent.top
            height: parent.radius; color: parent.color
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.top: parent.top
            height: 1; color: "#33333c"
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16; anchors.rightMargin: 16
            anchors.topMargin: 12; anchors.bottomMargin: 12
            spacing: 8

            Item { Layout.fillWidth: true }

            // 取消
            FlatButton {
                implicitWidth: 80
                implicitHeight: 32
                text: qsTr("取消")
                onClicked: quickUploadConfirmDialog.close()
            }

            // 去修改
            FlatButton {
                implicitWidth: 108
                implicitHeight: 32
                text: qsTr("✏️ 去修改")
                textColor: "#d0d4dc"
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("打开评分数据面板，人工核对/修改后再上传")
                onClicked: {
                    quickUploadConfirmDialog.close()
                    ratingsDialog.open()
                }
            }

            // 确认上传
            Rectangle {
                implicitWidth: 120
                implicitHeight: 32
                radius: 5
                color: quickUploadConfirmDialog._canUpload
                       ? (confirmUploadBtn.pressed ? "#1565a8" : confirmUploadBtn.hovered ? "#1a7acc" : "#1976d2")
                       : "#2a2a32"
                border.color: quickUploadConfirmDialog._canUpload ? "transparent" : "#3a3a44"
                border.width: 1

                Behavior on color { ColorAnimation { duration: 120 } }

                MouseArea {
                    id: confirmUploadBtn
                    anchors.fill: parent
                    enabled: quickUploadConfirmDialog._canUpload
                    hoverEnabled: true
                    property bool hovered: false
                    property bool pressed: false
                    onEntered: hovered = true
                    onExited:  hovered = false
                    onPressed: pressed = true
                    onReleased: pressed = false
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        quickUploadConfirmDialog.close()
                        if (typeof ratingsDialog !== "undefined"
                                && typeof ratingsDialog.triggerQuickUploadForCurrentTab === "function") {
                            ratingsDialog.triggerQuickUploadForCurrentTab()
                        }
                    }

                    ToolTip.visible: hovered && !quickUploadConfirmDialog._canUpload
                    ToolTip.delay: 400
                    ToolTip.text: quickUploadConfirmDialog._blockReason
                }
                RowLayout {
                    anchors.centerIn: parent
                    spacing: 5
                    Text {
                        text: "☁"
                        font.pixelSize: 14
                        color: quickUploadConfirmDialog._canUpload ? "#ffffff" : "#50505a"
                    }
                    Text {
                        text: qsTr("确认上传")
                        font.pixelSize: 13
                        font.bold: true
                        color: quickUploadConfirmDialog._canUpload ? "#ffffff" : "#50505a"
                    }
                }
            }
        }
    }
}
