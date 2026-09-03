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
    implicitWidth: 520

    Overlay.modal: Rectangle { color: "#aa000000" }

    // ── 预览数据（openWithPreview 填充；关闭后不清空，方便调试）──
    property string _mode: ""
    property string _modeLabel: ""
    property string _rater: ""
    property string _tag: ""
    property var    _folders: []         // [{name, path, ratedCount, totalVideos, ckMissing, totalItems}]
    property int    _recordCount: 0
    property bool   _canUpload: false
    property string _blockReason: ""
    // 非空 → 本次上传的数据取自该归档批次（当前 Tab 已无记录）
    property string _fromArchiveBatch: ""
    // 数据源显示文案（如"当前评分数据（12 条）"或"归档批次 test_xxx（85 条）"）
    property string _sourceLabel: ""

    // 打开前从 RatingsDialog 拉取预览信息，填充后再 open()
    // 关键：任何 preview 内部异常都不能阻止 open()，否则用户会感觉按钮"点了没反应"。
    // 因此这里用 try-catch 包裹 preview 调用，失败时退化为"信息为空，用户去修改"。
    function openWithPreview() {
        console.log("[QuickUpload] openWithPreview() start")
        // 先重置成空态，避免上一次残留信息误导
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

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
        Rectangle {
            z: -1; anchors.fill: parent; anchors.margins: -8
            radius: parent.radius + 4
            color: "transparent"; border.color: "#80000000"; border.width: 1
            opacity: 0.45
        }
        Rectangle {
            z: -1; anchors.fill: parent; anchors.margins: -4
            radius: parent.radius + 2
            color: "transparent"; border.color: "#a0000000"; border.width: 1
            opacity: 0.55
        }
    }

    header: Rectangle {
        color: "transparent"
        implicitHeight: 42
        Text {
            anchors.left: parent.left; anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("上传评分数据到云端？")
            color: "#e8e8ec"
            font.pixelSize: 15
            font.bold: true
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1; color: "#2a2a32"
        }
    }

    contentItem: ColumnLayout {
        spacing: 12

        // ── 摘要块（模式 / 评分人 / tag / 条数）────────────────
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 12
            rowSpacing: 6

            Text {
                text: qsTr("评分模式：")
                color: "#9aa0a6"; font.pixelSize: 12
            }
            Text {
                Layout.fillWidth: true
                text: quickUploadConfirmDialog._modeLabel || "—"
                color: "#e8e8ec"; font.pixelSize: 13
                elide: Text.ElideRight
            }
            Text {
                text: qsTr("评分人：")
                color: "#9aa0a6"; font.pixelSize: 12
            }
            Text {
                Layout.fillWidth: true
                text: quickUploadConfirmDialog._rater.length > 0
                      ? quickUploadConfirmDialog._rater
                      : qsTr("（未填写）")
                color: quickUploadConfirmDialog._rater.length > 0 ? "#e8e8ec" : "#e07070"
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Text {
                text: qsTr("备注 tag：")
                color: "#9aa0a6"; font.pixelSize: 12
            }
            Text {
                Layout.fillWidth: true
                text: quickUploadConfirmDialog._tag.length > 0
                      ? quickUploadConfirmDialog._tag
                      : qsTr("（未填写）")
                color: quickUploadConfirmDialog._tag.length > 0 ? "#e8e8ec" : "#e07070"
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            // ── 数据源（只读）：当前评分数据 / 由 tag 唯一定位的归档批次 ──
            // 归档 csv 命名固定为 playerx_<rater>_<mode>__<batch>_<group>.csv，
            // group 即 tag，因此给定 tag 时归档文件唯一，无需用户下拉选择。
            Text {
                text: qsTr("数据源：")
                color: "#9aa0a6"; font.pixelSize: 12
            }
            Text {
                Layout.fillWidth: true
                text: quickUploadConfirmDialog._sourceLabel
                color: quickUploadConfirmDialog._fromArchiveBatch.length > 0
                      ? "#7ec8ff" : "#e8e8ec"
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Text {
                text: qsTr("评分记录：")
                color: "#9aa0a6"; font.pixelSize: 12
            }
            Text {
                Layout.fillWidth: true
                text: qsTr("%1 个文件夹 · %2 条评分")
                        .arg(quickUploadConfirmDialog._folders.length)
                        .arg(quickUploadConfirmDialog._recordCount)
                color: "#e8e8ec"; font.pixelSize: 13
            }
        }

        // ── 文件夹列表（最多显示 6 行；超过用"…还有 N 个"折叠）──
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: Math.min(
                quickUploadConfirmDialog._folders.length * 22 + 16, 168)
            color: "#141418"
            border.color: "#2a2a32"; border.width: 1
            radius: 4
            visible: quickUploadConfirmDialog._folders.length > 0

            ListView {
                anchors.fill: parent
                anchors.margins: 8
                clip: true
                interactive: contentHeight > height
                model: quickUploadConfirmDialog._folders
                delegate: Row {
                    width: ListView.view.width
                    height: 22
                    spacing: 8
                    Text {
                        // 完成度小标
                        width: 48
                        text: (modelData.ratedCount === modelData.totalVideos
                               && modelData.ckMissing === 0)
                              ? "✓ " + modelData.ratedCount + "/" + modelData.totalVideos
                              : "⚠ " + modelData.ratedCount + "/" + modelData.totalVideos
                        color: (modelData.ratedCount === modelData.totalVideos
                                && modelData.ckMissing === 0) ? "#5fd17a" : "#ffb05c"
                        font.pixelSize: 12
                    }
                    Text {
                        width: parent.width - 48 - 8
                        text: modelData.name || "—"
                        color: "#cfcfd4"
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                }
            }
        }

        // ── 未通过校验时的原因提示（红色 banner）────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: !quickUploadConfirmDialog._canUpload
                     && quickUploadConfirmDialog._blockReason.length > 0
            color: "#3a1f22"
            border.color: "#7a3a3a"; border.width: 1
            radius: 4
            implicitHeight: blockText.implicitHeight + 16
            Text {
                id: blockText
                anchors.fill: parent
                anchors.margins: 8
                text: "⚠ " + quickUploadConfirmDialog._blockReason
                color: "#ffb0b0"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
        }

        // ── 说明脚注 ──────────────────────────────────────────
        Text {
            Layout.fillWidth: true
            text: quickUploadConfirmDialog._fromArchiveBatch.length > 0
                  ? qsTr("当前 Tab 已归档清空，将上传 tag「%1」对应的归档文件（%2 条）。数据已在归档中，上传后不会重复归档。")
                    .arg(quickUploadConfirmDialog._tag)
                    .arg(quickUploadConfirmDialog._recordCount)
                  : (quickUploadConfirmDialog._canUpload
                     ? qsTr("上传完成后，这些评分记录会自动归档，「当前」Tab 将不再显示。")
                     : qsTr("请点「去修改」在评分数据面板里补齐后再上传。"))
            font.pixelSize: 11
            wrapMode: Text.WordWrap
            lineHeight: 1.3
        }
    }

    footer: Rectangle {
        color: "transparent"
        implicitHeight: 56
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
                onClicked: quickUploadConfirmDialog.close()
            }
            FlatButton {
                implicitWidth: 110
                implicitHeight: 30
                text: qsTr("✏️ 去修改")
                textColor: "#e8e8ec"
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: qsTr("打开评分数据面板，人工核对/修改后再上传")
                onClicked: {
                    quickUploadConfirmDialog.close()
                    ratingsDialog.open()
                }
            }
            FlatButton {
                implicitWidth: 120
                implicitHeight: 30
                text: qsTr("☁ 确认上传")
                textColor: enabled ? "#4fc3f7" : "#5a5a60"
                // 校验未通过时禁用上传按钮，强制走"去修改"。
                // 额外规则：选了"当前评分数据"但它是 0 条 → 也禁用
                // （此时应改选归档批次或去面板补齐），避免上传空数据。
                enabled: quickUploadConfirmDialog._canUpload
                ToolTip.visible: hovered && !enabled
                ToolTip.delay: 400
                ToolTip.text: quickUploadConfirmDialog._blockReason
                onClicked: {
                    quickUploadConfirmDialog.close()
                    // 数据源已由 previewCurrentUpload() 按 tag 唯一定位好
                    // （当前 Tab 有记录就用当前，否则自动用该 tag 对应的归档文件），
                    // 这里直接触发即可。
                    if (typeof ratingsDialog !== "undefined"
                            && typeof ratingsDialog.triggerQuickUploadForCurrentTab === "function") {
                        ratingsDialog.triggerQuickUploadForCurrentTab()
                    }
                }
            }
        }
    }
}
