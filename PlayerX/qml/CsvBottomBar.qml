import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Rectangle {
    id: csvBottomBar
    property var root: null
    property Item refSidebar: null
    property var refSidebarCsvDlg: null
    property var videoArea: null
    // 与视频窗口同宽：左侧紧贴 refSidebar 右边，避开左栏图片区域。
    //   - 这样左栏的「图1 / 图2」可以上下均分撑满整个高度，没有黑色空白；
    //   - prompt 文本只占视频区下方的横向空间，与视频画面始终对齐。
    // 与「参考图侧边栏」作为一个整体出现/隐藏（用户工作流：要么同时看图+词，
    // 要么都不看），由 refSidebarVisible 一并控制。
    // 与 videoArea 保持一致，始终跟随 refSidebar 右侧。
    anchors.left: refSidebar.right
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    readonly property bool hasContent: root.refTextHasCurrent
    readonly property bool hasBinding: root.refTextKind === "csv"
    // 展开/折叠完全由用户意图控制（csvBottomBarExpanded），与"是否有内容"解耦：
    //   旧逻辑 showFull = expanded && hasContent，导致清除 CSV 后 hasContent=false，
    //   底栏被锁死在 24px 折叠态，无法再展开 → 也就看不到「CSV」选择按钮，
    //   用户陷入"清除即不可恢复"的死循环。
    //   现在展开态在无内容时会展示"未绑定 CSV"占位提示 + 右上角「CSV」按钮，
    //   点击「CSV」即可重新选择文件。
    readonly property bool showFull: root.csvBottomBarExpanded
    // 高度：仅当侧边栏可见 + 有视频时才占位；展开使用用户拖拽值、折叠 24
    height: (!root.refSidebarVisible || Engine.fileCount <= 0) ? 0
          : (showFull ? root.csvBottomBarUserHeight : 24)
    visible: height > 0 && root.currentTab === "play"
    color: "#15151a"

    // 顶部 1px 分隔线
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: "#2c2c32"
    }

    // ── 折叠态：仅一行标题条（展开箭头 + 进度文字）──────────────
    Item {
        id: csvBottomCollapsedRow
        visible: !csvBottomBar.showFull
        anchors.fill: parent
        anchors.topMargin: 1
        // 折叠箭头（▶ 展开）
        Rectangle {
            id: csvExpandBtn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 6
            width: 22; height: 18
            radius: 3
            color: csvExpandBtnMA.containsMouse ? "#2a2a32" : "transparent"
            Text {
                anchors.centerIn: parent
                text: "▶"
                color: "#9a9aa8"
                font.pixelSize: 10
            }
            MouseArea {
                id: csvExpandBtnMA
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.csvBottomBarExpanded = true
                ToolTip.visible: containsMouse
                ToolTip.delay: 400
                ToolTip.text: "展开参考文本"
            }
        }
        Label {
            anchors.left: csvExpandBtn.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 6
            anchors.rightMargin: 10
            elide: Text.ElideRight
            font.pixelSize: 11
            color: csvBottomBar.hasBinding ? "#7fe5cc" : "#6a6a78"
            text: {
                if (!csvBottomBar.hasBinding) return "📝 未绑定参考文本（CSV）— 点击展开后选择"
                var p = root.refTextProgress
                var imgName = root.refTextData && root.refTextData.image ? root.refTextData.image : ""
                var pre = "📝 跟随对比组"
                if (p.length > 0) pre += "   ·   " + p
                if (imgName.length > 0) pre += "   ·   " + imgName
                return pre
            }
        }
    }

    // ── 展开态：完整 prompt + 控件区 ──────────────────────────────
    Item {
        id: csvBottomFullRow
        visible: csvBottomBar.showFull
        anchors.fill: parent
        anchors.topMargin: 1

        // 第一行：折叠箭头 + 进度标签
        Item {
            id: csvBottomTitleRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 22
            Rectangle {
                id: csvCollapseBtn
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 6
                width: 22; height: 18
                radius: 3
                color: csvCollapseBtnMA.containsMouse ? "#2a2a32" : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "▼"
                    color: "#9a9aa8"
                    font.pixelSize: 10
                }
                MouseArea {
                    id: csvCollapseBtnMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.csvBottomBarExpanded = false
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "折叠参考文本"
                }
            }

            Label {
                anchors.left: csvCollapseBtn.right
                anchors.right: csvBottomCtrlRow.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 6
                anchors.rightMargin: 8
                elide: Text.ElideRight
                font.pixelSize: 11
                color: "#7fe5cc"
                text: {
                    var p = root.refTextProgress
                    var imgName = root.refTextData && root.refTextData.image ? root.refTextData.image : ""
                    var pre = "📝 跟随对比组"
                    if (p.length > 0) pre += "   ·   " + p
                    if (imgName.length > 0) pre += "   ·   " + imgName
                    return pre
                }
            }

            // 第一行右侧：◀ ▶ 翻行 + 重置 + 中/英 + CSV + 清除
            Row {
                id: csvBottomCtrlRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: 8
                spacing: 4

                // ◀ 上一行
                Rectangle {
                    id: csvPrevBtn
                    width: 24; height: 18
                    radius: 3
                    visible: root.refTextKind === "csv" && root.refTextRowCount > 1
                    property bool enabled: root.refTextCurrentRow > 0
                    color: csvPrevMA.pressed ? "#3a3a45"
                          : csvPrevMA.containsMouse ? "#2a2a32"
                          : "#1a1a1d"
                    border.color: csvPrevBtn.enabled ? "#5a5a65" : "#2a2a32"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "◀"
                        font.pixelSize: 10
                        color: csvPrevBtn.enabled ? "#e8e8ec" : "#555"
                    }
                    MouseArea {
                        id: csvPrevMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: csvPrevBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: { if (csvPrevBtn.enabled) root._refTextOffset -= 1 }
                    }
                    ToolTip.visible: csvPrevMA.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "上一行"
                }
                // ▶ 下一行
                Rectangle {
                    id: csvNextBtn
                    width: 24; height: 18
                    radius: 3
                    visible: root.refTextKind === "csv" && root.refTextRowCount > 1
                    property bool enabled: root.refTextRowCount > 0
                                            && root.refTextCurrentRow >= 0
                                            && root.refTextCurrentRow < root.refTextRowCount - 1
                    color: csvNextMA.pressed ? "#3a3a45"
                          : csvNextMA.containsMouse ? "#2a2a32"
                          : "#1a1a1d"
                    border.color: csvNextBtn.enabled ? "#5a5a65" : "#2a2a32"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "▶"
                        font.pixelSize: 10
                        color: csvNextBtn.enabled ? "#e8e8ec" : "#555"
                    }
                    MouseArea {
                        id: csvNextMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: csvNextBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: { if (csvNextBtn.enabled) root._refTextOffset += 1 }
                    }
                    ToolTip.visible: csvNextMA.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "下一行"
                }
                // ⟳ 复位
                Rectangle {
                    id: csvResetBtn
                    width: 24; height: 18
                    radius: 3
                    visible: root._refTextOffset !== 0
                    color: csvResetMA.pressed ? "#3a3a45"
                          : csvResetMA.containsMouse ? "#2a2a32"
                          : "#1a1a1d"
                    border.color: "#7fe5cc"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "⟳"
                        font.pixelSize: 11
                        color: "#7fe5cc"
                    }
                    MouseArea {
                        id: csvResetMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._refTextOffset = 0
                    }
                    ToolTip.visible: csvResetMA.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "回到自动同步行"
                }
                // 中/英
                Rectangle {
                    id: csvLangBtn
                    width: 28; height: 18
                    radius: 3
                    visible: root.refTextHasBothLangs
                    color: csvLangMA.pressed ? "#3a3a45"
                          : csvLangMA.containsMouse ? "#2a2a32"
                          : "#1a1a1d"
                    border.color: "#3a3a45"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: root.refTextLang === "zh" ? "中" : "EN"
                        font.pixelSize: 10
                        color: "#e8e8ec"
                    }
                    MouseArea {
                        id: csvLangMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.refTextLang = (root.refTextLang === "zh" ? "en" : "zh")
                    }
                    ToolTip.visible: csvLangMA.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "切换中文 / 英文"
                }
                // CSV 选择
                Rectangle {
                    id: csvPickBtn
                    width: 38; height: 18
                    radius: 3
                    readonly property bool active: root.refTextKind === "csv"
                    color: csvPickMA.pressed ? "#3a3a45"
                          : csvPickMA.containsMouse ? "#2a2a32"
                          : (active ? "#1f2e2a" : "#1a1a1d")
                    border.color: active ? "#0fa085" : "#3a3a45"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "CSV"
                        font.pixelSize: 10
                        color: csvPickBtn.active ? "#7fe5cc" : "#e8e8ec"
                    }
                    MouseArea {
                        id: csvPickMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: refSidebarCsvDlg.open()
                    }
                    ToolTip.visible: csvPickMA.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "选择 CSV 文件"
                }
                // 字号调节 A- / A+
                Row {
                    spacing: 2
                    Rectangle {
                        width: 22; height: 18
                        radius: 3
                        color: csvFontDecMA.pressed ? "#3a3a45"
                              : csvFontDecMA.containsMouse ? "#2a2a32"
                              : "#1a1a1d"
                        border.color: "#3a3a45"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "A-"
                            font.pixelSize: 10
                            color: "#e8e8ec"
                        }
                        MouseArea {
                            id: csvFontDecMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (root.refTextFontSize > 10) root.refTextFontSize -= 1
                        }
                        ToolTip.visible: csvFontDecMA.containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "缩小字号"
                    }
                    Rectangle {
                        width: 22; height: 18
                        radius: 3
                        color: csvFontIncMA.pressed ? "#3a3a45"
                              : csvFontIncMA.containsMouse ? "#2a2a32"
                              : "#1a1a1d"
                        border.color: "#3a3a45"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "A+"
                            font.pixelSize: 10
                            color: "#e8e8ec"
                        }
                        MouseArea {
                            id: csvFontIncMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (root.refTextFontSize < 32) root.refTextFontSize += 1
                        }
                        ToolTip.visible: csvFontIncMA.containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "放大字号"
                    }
                }
                // 清除
                Rectangle {
                    id: csvClearBtn
                    width: 38; height: 18
                    radius: 3
                    visible: root.refTextKind === "csv"
                    color: csvClearMA.pressed ? "#5a2a2a"
                          : csvClearMA.containsMouse ? "#3a2228"
                          : "#1a1a1d"
                    border.color: "#3a3a42"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "清除"
                        font.pixelSize: 10
                        color: "#e8b0b0"
                    }
                    MouseArea {
                        id: csvClearMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.refCurrentFolder.length > 0)
                                Reference.clearText(root.refCurrentFolder)
                        }
                    }
                }
            }
        }

// 第二行：完整 prompt 文本（一整行带横向滚动 / wrap）
        Rectangle {
            id: csvBottomTextBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: csvBottomTitleRow.bottom
            anchors.bottom: parent.bottom
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 6
            color: "#0e0e10"
            border.color: csvBottomTextDrop.containsDrag ? "#5a8fd8" : "#2c2c32"
            border.width: 1
            radius: 4

            Flickable {
                id: csvBottomScroll
                anchors.fill: parent
                anchors.margins: 6
                clip: true
                contentWidth: width
                contentHeight: csvBottomLabel.implicitHeight
                visible: root.refTextHasCurrent
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                Text {
                    id: csvBottomLabel
                    width: csvBottomScroll.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: root.refTextDisplay
                    color: "#d8d8e0"
                    font.pixelSize: root.refTextFontSize
                    lineHeight: 1.1
                }
            }
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                visible: !csvBottomScroll.visible
                color: "#6a6a78"
                font.pixelSize: 11
                text: {
                    if (root.refCurrentFolder.length === 0)
                        return "请选中任一通道"
                    if (root.refTextKind === "")
                        return "未绑定参考文本（CSV）— 点击右侧「CSV」选择文件，或拖入 .csv"
                    return "已绑定 CSV，但当前行为空 / 越界（视频序号超出 CSV 行数）"
                }
            }

            // 拖拽接收：CSV 文件
            DropArea {
                id: csvBottomTextDrop
                anchors.fill: parent
                onDropped: function(drop) {
                    if (root.refCurrentFolder.length === 0) { drop.accepted = false; return }
                    if (!drop.hasUrls) { drop.accepted = false; return }
                    for (var i = 0; i < drop.urls.length; ++i) {
                        var u = drop.urls[i]
                        var s = String(u).toLowerCase()
                        if (s.endsWith(".csv")) {
                            if (Reference.setReferenceCsvUrl(root.refCurrentFolder, u)) {
                                drop.accepted = true; return
                            }
                        }
                    }
                    drop.accepted = false
                }
            }
        }
    }
}
