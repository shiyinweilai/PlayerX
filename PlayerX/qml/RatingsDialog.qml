/**
 * RatingsDialog.qml — 视频评分数据查看 / 导出 / 清空
 *
 * 数据来源：C++ 单例 `Rating`（rbqt::RatingStore），CSV 持久化在
 *   AppDataLocation/PlayerX/ratings.csv
 *
 * 设计风格：与项目其他面板一致——深色底（#1e1e22）、亮白字、极简、排版优先。
 *
 * 关键交互：
 *   - 顶部：评分人输入框（写入 QSettings，立即生效；新评分都会带上这个名字）
 *           数据文件路径只读显示 + 在 Finder/资源管理器中显示
 *   - 中部：表格（时间 / 评分人 / 文件名 / 星数 / 文件路径）
 *   - 底部：导出 CSV（保存对话框）/ 清空（二次确认）/ 关闭
 */
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window

Window {
    id: root
    title: qsTr("评分数据")
    width: 880
    height: 560
    minimumWidth: 640
    minimumHeight: 380
    flags: Qt.Dialog
    color: "#1a1a1d"
    modality: Qt.WindowModal

    // 当前用户名输入的临时缓冲（防止每按一键都触发 setCurrentUser）
    property string _userBuffer: ""

    // 表格数据：弹窗每次打开 / Rating.changed 时刷新
    property var _rows: []

    function _refresh() {
        _rows = (typeof Rating !== "undefined") ? Rating.getAllRatings() : []
    }
    function open() { show() }

    onVisibleChanged: {
        if (visible) {
            _userBuffer = (typeof Rating !== "undefined") ? Rating.currentUser : ""
            _refresh()
        }
    }

    Connections {
        target: (typeof Rating !== "undefined") ? Rating : null
        ignoreUnknownSignals: true
        function onChanged() { root._refresh() }
    }

    // ── 总体布局：上(配置区) / 中(表格) / 下(操作栏) ────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        // ── 标题 ────
        Text {
            text: "📊  " + qsTr("视频评分数据")
            color: "#e8e8ec"
            font.pixelSize: 16
            font.bold: true
        }

        // ── 评分人 / 数据文件路径 ────
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 10
            rowSpacing: 6

            Text { text: qsTr("评分人"); color: "#9aa0a6"; font.pixelSize: 12 }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: userField
                    Layout.fillWidth: true
                    text: root._userBuffer
                    placeholderText: (typeof Rating !== "undefined")
                                     ? qsTr("未设置（默认使用系统用户名：%1）").arg(Rating.systemUserName())
                                     : ""
                    color: "#e8e8ec"
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        border.color: userField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: 1
                        radius: 4
                    }
                    onEditingFinished: {
                        if (typeof Rating !== "undefined") {
                            Rating.currentUser = text.trim()
                        }
                    }
                }
                Text {
                    text: qsTr("回车保存")
                    color: "#6a6a72"
                    font.pixelSize: 11
                }
            }

            Text { text: qsTr("数据文件"); color: "#9aa0a6"; font.pixelSize: 12 }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    Layout.fillWidth: true
                    readOnly: true
                    text: (typeof Rating !== "undefined") ? Rating.dataFilePath : ""
                    color: "#c8c8cc"
                    selectByMouse: true
                    // 文件名/路径过长时让左侧显示省略，确保末尾的 ratings.csv 可见
                    horizontalAlignment: TextInput.AlignRight
                    background: Rectangle {
                        color: "#222226"
                        border.color: "#2e2e34"
                        border.width: 1
                        radius: 4
                    }
                }
                PillBtn {
                    text: qsTr("在文件夹中显示")
                    onClicked: { if (typeof Rating !== "undefined") Rating.revealInFolder() }
                }
            }
        }

        // ── 分隔线 ──
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#2e2e34" }

        // ── 统计行 ──
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Text {
                text: qsTr("共 %1 条记录").arg(root._rows.length)
                color: "#c8c8cc"
                font.pixelSize: 12
            }
            Item { Layout.fillWidth: true }
            PillBtn {
                text: qsTr("刷新")
                onClicked: root._refresh()
            }
        }

        // ── 表格区 ──
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#222226"
            border.color: "#2e2e34"
            border.width: 1
            radius: 4

            // 表头
            Row {
                id: header
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 1
                height: 28
                spacing: 0
                Repeater {
                    model: [
                        { t: qsTr("时间"),     w: 170 },
                        { t: qsTr("评分人"),   w: 110 },
                        { t: qsTr("星数"),     w: 70  },
                        { t: qsTr("文件名"),   w: 240 },
                        { t: qsTr("文件路径"), w: -1  }   // -1 = 占满剩余
                    ]
                    delegate: Rectangle {
                        width: modelData.w === -1
                               ? Math.max(120, header.width
                                                - 170 - 110 - 70 - 240)
                               : modelData.w
                        height: 28
                        color: "#2a2a30"
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            text: modelData.t
                            color: "#dcdcde"
                            font.pixelSize: 12
                            font.bold: true
                        }
                        Rectangle {  // 列分割
                            anchors.right: parent.right
                            width: 1
                            height: parent.height
                            color: "#1e1e22"
                        }
                    }
                }
            }

            // 数据行（ListView）
            ListView {
                id: listView
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: header.bottom
                anchors.bottom: parent.bottom
                anchors.margins: 1
                clip: true
                model: root._rows
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Rectangle {
                    width: listView.width
                    height: 26
                    color: index % 2 === 0 ? "#222226" : "#26262a"

                    Row {
                        anchors.fill: parent
                        spacing: 0
                        // 时间
                        CellText { w: 170; text: (modelData.updated_at || "").replace("T", " ").substring(0, 19) }
                        // 评分人
                        CellText { w: 110; text: modelData.rater || "" }
                        // 星数
                        Rectangle {
                            width: 70; height: parent.height
                            color: "transparent"
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                text: {
                                    var s = parseInt(modelData.stars) || 0
                                    if (s <= 0) return "—"
                                    var out = ""
                                    for (var i = 0; i < s; ++i) out += "★"
                                    for (var j = s; j < 5; ++j) out += "☆"
                                    return out
                                }
                                color: (parseInt(modelData.stars) || 0) > 0 ? "#f5c518" : "#666"
                                font.pixelSize: 12
                            }
                        }
                        // 文件名
                        CellText { w: 240; text: modelData.file_name || ""; rtl: true }
                        // 文件路径（占满）
                        CellText {
                            w: listView.width - 170 - 110 - 70 - 240
                            text: modelData.file_path || ""
                            rtl: true
                            dim: true
                        }
                    }
                }

                // 空状态
                Text {
                    anchors.centerIn: parent
                    visible: root._rows.length === 0
                    text: qsTr("暂无评分数据\n在视频窗的 ⋯ 菜单中选择星级即可记录")
                    horizontalAlignment: Text.AlignHCenter
                    color: "#6a6a72"
                    font.pixelSize: 12
                }
            }
        }

        // ── 底部操作栏 ────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            PillBtn {
                text: qsTr("📤 导出 CSV…")
                emphasized: true
                onClicked: exportDialog.open()
            }
            PillBtn {
                text: qsTr("🗑 清空")
                danger: true
                enabled: root._rows.length > 0
                onClicked: confirmClearDialog.open()
            }
            Item { Layout.fillWidth: true }
            PillBtn {
                text: qsTr("关闭")
                onClicked: root.close()
            }
        }
    }

    // ── 导出对话框 ────
    FileDialog {
        id: exportDialog
        title: qsTr("导出评分数据为 CSV")
        fileMode: FileDialog.SaveFile
        nameFilters: ["CSV (*.csv)"]
        defaultSuffix: "csv"
        currentFile: {
            var name = "PlayerX_ratings"
            var u = (typeof Rating !== "undefined") ? Rating.currentUser : ""
            if (u && u.length > 0) name += "_" + u
            // 时间戳 yyyyMMdd_HHmm
            var d = new Date()
            function pad(n) { return (n < 10 ? "0" : "") + n }
            name += "_" + d.getFullYear() + pad(d.getMonth()+1) + pad(d.getDate())
                  + "_" + pad(d.getHours()) + pad(d.getMinutes())
            return "file:///" + name + ".csv"
        }
        onAccepted: {
            if (typeof Rating === "undefined") return
            // selectedFile 是 QUrl
            var path = selectedFile.toString().replace(/^file:\/\//, "")
            // Windows: file:///C:/foo → /C:/foo，去掉前导 /
            if (path.match(/^\/[A-Za-z]:/)) path = path.substring(1)
            Rating.exportToFile(path)
        }
    }

    // ── 清空确认对话框（深色主题，全自定义 header/footer，避免 Basic 主题白底）────
    Dialog {
        id: confirmClearDialog
        modal: true
        anchors.centerIn: parent
        width: 380
        padding: 0

        // 半透明遮罩，凸显前景
        Overlay.modal: Rectangle { color: "#aa000000" }

        // 弹窗主体：深色卡片 + 阴影
        background: Rectangle {
            color: "#1e1e22"
            border.color: "#2e2e34"
            border.width: 1
            radius: 8
            // 简易阴影：用一层放大的、半透明 Rectangle 模拟（Qt6 Basic 不带 DropShadow）
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        // 自定义标题栏
        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: qsTr("清空所有评分？")
                color: "#f0f0f3"
                font.pixelSize: 14
                font.bold: true
                elide: Text.ElideRight
            }
            // 标题与正文分隔线
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a30"
            }
        }

        // 正文
        contentItem: Item {
            implicitHeight: _msg.implicitHeight + 32
            Text {
                id: _msg
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: qsTr("此操作将清空本地 ratings.csv 中的全部记录，无法恢复。\n是否继续？")
                color: "#cfcfd4"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }
        }

        // 自定义底部按钮区（用 PillBtn，跟其他按钮风格一致）
        footer: Rectangle {
            color: "transparent"
            implicitHeight: 56
            // 顶部分隔线
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a30"
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 8
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("取消")
                    onClicked: confirmClearDialog.reject()
                }
                PillBtn {
                    text: qsTr("确认清空")
                    danger: true
                    onClicked: confirmClearDialog.accept()
                }
            }
        }

        onAccepted: { if (typeof Rating !== "undefined") Rating.clearAll() }
    }

    // ════════════════════════════════════════════════════════════════════
    // 内部组件
    // ════════════════════════════════════════════════════════════════════

    // 单元格
    component CellText: Rectangle {
        property int w: 100
        property string text: ""
        property bool dim: false
        property bool rtl: false   // 路径/文件名过长时左侧省略，确保后缀可见
        width: w
        height: 26
        color: "transparent"
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            text: parent.text
            color: parent.dim ? "#9aa0a6" : "#dcdcde"
            font.pixelSize: 12
            elide: parent.rtl ? Text.ElideLeft : Text.ElideRight
            horizontalAlignment: Text.AlignLeft
        }
    }

    // 圆角胶囊按钮（与项目深色风格一致）
    component PillBtn: Rectangle {
        property string text: ""
        property bool enabled: true
        property bool emphasized: false
        property bool danger: false
        signal clicked()

        implicitWidth:  Math.max(72, _t.implicitWidth + 22)
        implicitHeight: 28
        radius: 5
        color: !enabled ? "#1a1a1d"
              : danger      ? (_ma.containsMouse ? "#a23a3a" : "#3a2326")
              : emphasized  ? (_ma.containsMouse ? "#3a7afe" : "#2a5994")
              :               (_ma.containsMouse ? "#3a3a44" : "#2a2a30")
        border.color: danger ? "#5a2a2e" : "#3a3a42"
        border.width: 1
        Text {
            id: _t
            anchors.centerIn: parent
            text: parent.text
            color: parent.enabled ? "#e8e8ec" : "#555"
            font.pixelSize: 12
        }
        MouseArea {
            id: _ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: parent.enabled
            onClicked: parent.clicked()
        }
    }
}
