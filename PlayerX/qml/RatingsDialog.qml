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
 *   - 中部：表格（时间 / 评分人 / 星数 / 文件名）
 *     · 文件名一列展示带通道号前缀的形式（如 "1_xxx.mp4"），
 *       鼠标悬停时通过 ToolTip 显示该文件的完整绝对路径；
 *     · 不再单独保留"文件路径"列——多人汇总评分时路径属于环境噪音；
 *     · 导出 CSV 也只保留 updated_at / rater / file_name / stars 四列，
 *       updated_at 会格式化成 "yyyy-MM-dd HH:mm:ss" 方便人眼对齐。
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
    // 时间列排序方向：true = 新→旧（默认，与 C++ 端 getAllRatings 一致），false = 旧→新
    property bool _sortDesc: true

    // 按 _sortDesc 排 updated_at 字段；在 JS 里用字符串比较即可（ISO8601 字典序==时间序）。
    function _applySort(rows) {
        var arr = (rows || []).slice()  // 拷贝，避免就地改 C++ 返回的 list
        arr.sort(function(a, b) {
            var ta = a.updated_at || ""
            var tb = b.updated_at || ""
            if (ta === tb) return 0
            if (root._sortDesc) return ta < tb ? 1 : -1
            return ta < tb ? -1 : 1
        })
        return arr
    }
    function _refresh() {
        var raw = (typeof Rating !== "undefined") ? Rating.getAllRatings() : []
        _rows = _applySort(raw)
    }
    function _toggleTimeSort() {
        _sortDesc = !_sortDesc
        _rows = _applySort(_rows)
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
                    Layout.preferredWidth: 200
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
                // 备注 tag：同一评分人多轮提交时的区分标签。
                // 后端会按 (rater, tag) 检测重复上传，重复时弹“是否覆盖”。
                Text {
                    text: qsTr("备注 tag")
                    color: "#9aa0a6"
                    font.pixelSize: 12
                }
                TextField {
                    id: tagField
                    Layout.preferredWidth: 160
                    text: (typeof Rating !== "undefined") ? Rating.uploadTag : ""
                    placeholderText: qsTr("例如 test1 / 终评")
                    color: "#e8e8ec"
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        border.color: tagField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: 1
                        radius: 4
                    }
                    // 实时同步：每次键入都立刻写回 Rating.uploadTag，
                    // 避免“改完 tag 直接点上传按钮，但首次点击还在用旧值”的时序问题
                    // （旧逻辑只在 editingFinished 即失焦/回车时才同步）。
                    onTextChanged: {
                        if (typeof Rating !== "undefined"
                                && Rating.uploadTag !== text.trim()) {
                            Rating.uploadTag = text.trim()
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
                        // sortable=true 的列支持点击切换排序；目前只有"时间"列。
                        // 表头改为"文件名"——展示带 "<通道号>_" 前缀的名字，鼠标悬停可见绝对路径；
                        // 不再保留"文件路径"列：多人汇总场景下路径是环境噪音，文件名带通道号已足够区分。
                        { t: qsTr("时间"),     w: 170, sortable: true  },
                        { t: qsTr("评分人"),   w: 110, sortable: false },
                        { t: qsTr("星数"),     w: 70 , sortable: false },
                        { t: qsTr("文件名"),   w: -1 , sortable: false }   // -1 = 占满剩余
                    ]
                    delegate: Rectangle {
                        id: headerCell
                        width: modelData.w === -1
                               ? Math.max(120, header.width
                                                - 170 - 110 - 70)
                               : modelData.w
                        height: 28
                        // 时间列在 hover/pressed 时给一点反馈；其他列保持原色
                        color: {
                            if (!modelData.sortable) return "#2a2a30"
                            if (timeSortMA.pressed) return "#34343c"
                            if (timeSortMA.containsMouse) return "#30303a"
                            return "#2a2a30"
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            // 当前排序列附加 ▼ / ▲ 指示
                            text: modelData.sortable
                                  ? (modelData.t + "  " + (root._sortDesc ? "▼" : "▲"))
                                  : modelData.t
                            color: modelData.sortable ? "#ffffff" : "#dcdcde"
                            font.pixelSize: 12
                            font.bold: true
                        }
                        Rectangle {  // 列分割
                            anchors.right: parent.right
                            width: 1
                            height: parent.height
                            color: "#1e1e22"
                        }
                        // 仅 sortable 列才挂 MouseArea；点一下翻转排序方向。
                        MouseArea {
                            id: timeSortMA
                            anchors.fill: parent
                            enabled: modelData.sortable === true
                            visible: modelData.sortable === true
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._toggleTimeSort()
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
                        // 文件名（占满剩余；显示带 "<通道号>_" 前缀的名字，悬停时 ToolTip 显示绝对路径）
                        CellText {
                            w: listView.width - 170 - 110 - 70
                            text: modelData.file_name || ""
                            rtl: true     // 名字过长时左侧省略，扩展名 / 关键尾段一定可见
                            tooltipText: modelData.file_path || ""
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
                id: exportBtn
                text: qsTr("📤 导出 CSV…")
                emphasized: true
                onClicked: exportDialog.open()
                // 闪烁复位：flash=true 后 1.6s 自动关闭
                Timer {
                    id: exportFlashTimer
                    interval: 1600
                    onTriggered: exportBtn.flash = false
                }
            }
            PillBtn {
                // 上传到后端服务器：
                //   ・ 未配置地址时 → 先弹设置对话框让用户填 URL/Token
                //   ・ 配置后点击 → 直接走上传。上传中 disable，避免连点重复提交
                // 鼠标右键 → 进设置对话框，取不到菜单 API 只能用双击代替：双击也走设置
                id: uploadBtn
                text: (typeof Rating !== "undefined" && Rating.uploading)
                      ? qsTr("☁ 上传中…")
                      : qsTr("☁ 上传到云端")
                enabled: typeof Rating !== "undefined"
                         && !Rating.uploading
                         && root._rows.length > 0
                onClicked: {
                    if (typeof Rating === "undefined") return
                    // 防御性兜底：把焦点中的输入框（tag / 评分人）强制提交，
                    // 避免“刚改完 tag 直接点上传”时旧值仍在使用。
                    // 现 tagField 已做实时同步，但 userField 仍依赖 editingFinished，
                    // 触发一次 focus 切换可让两者都把当前值落地到 Rating。
                    if (userField.activeFocus) userField.focus = false
                    if (tagField.activeFocus)  tagField.focus  = false
                    if (!Rating.uploadServerUrl || Rating.uploadServerUrl.length === 0) {
                        uploadConfigDialog.open()
                    } else {
                        Rating.uploadToCloud()
                    }
                }
                // 双击 → 重新配置地址/Token
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton  // 不抢单击，只接双击
                    onDoubleClicked: uploadConfigDialog.open()
                }
                // 闪烁复位定时器
                Timer {
                    id: uploadFlashTimer
                    interval: 1600
                    onTriggered: uploadBtn.flash = false
                }
            }
            PillBtn {
                // “⚙ 设置”：独立入口，避免“双击上传按钮”这种隐藏交互被错过
                text: qsTr("⚙ 上传设置")
                onClicked: uploadConfigDialog.open()
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
        // 默认弹到系统"下载"目录（macOS: ~/Downloads，Windows: %USERPROFILE%\Downloads）。
        // 注意 Qt6 FileDialog 的坑：currentFile 若是绝对 URL（如 "file:///foo.csv"），
        // 会被解析成"根目录下 foo.csv"，进而**覆盖** currentFolder → 实际弹到 /。
        // 修法：把文件名直接拼到下载目录 URL 后面，组成完整路径 URL。
        currentFolder: (typeof Rating !== "undefined") ? Rating.defaultExportDir : ""
        currentFile: {
            var name = "PlayerX_ratings"
            var u = (typeof Rating !== "undefined") ? Rating.currentUser : ""
            if (u && u.length > 0) name += "_" + u
            // 时间戳 yyyyMMdd_HHmm
            var d = new Date()
            function pad(n) { return (n < 10 ? "0" : "") + n }
            name += "_" + d.getFullYear() + pad(d.getMonth()+1) + pad(d.getDate())
                  + "_" + pad(d.getHours()) + pad(d.getMinutes())
            // 拼接到下载目录 URL 后面，例如：file:///Users/xxx/Downloads/PlayerX_ratings_xxx.csv
            var dir = (typeof Rating !== "undefined") ? Rating.defaultExportDir.toString() : ""
            if (dir.length > 0) {
                if (dir.charAt(dir.length - 1) !== "/") dir += "/"
                return dir + name + ".csv"
            }
            return name + ".csv"  // 极端兜底：目录拿不到时只给文件名
        }
        onAccepted: {
            if (typeof Rating === "undefined") return
            // selectedFile 是 QUrl
            var path = selectedFile.toString().replace(/^file:\/\//, "")
            // Windows: file:///C:/foo → /C:/foo，去掉前导 /
            if (path.match(/^\/[A-Za-z]:/)) path = path.substring(1)
            var ok = Rating.exportToFile(path)
            if (ok) {
                // 成功：toast + 按钮闪绿
                var name = path.split(/[\\/]/).pop()
                actionToast.show(true, qsTr("已导出到 %1").arg(name))
                exportBtn.flash = true
                exportFlashTimer.restart()
            } else {
                actionToast.show(false, qsTr("导出失败：%1").arg(path))
            }
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

    // ── 上传设置对话框（服务器地址 / 可选 Token）────────────────────────────
    Dialog {
        id: uploadConfigDialog
        modal: true
        anchors.centerIn: parent
        width: 480
        padding: 0
        title: ""   // 自绘 header

        property string _urlBuf: ""
        property string _tokBuf: ""

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#2e2e34"
            border.width: 1
            radius: 8
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: Text.AlignVCenter
                text: qsTr("☁ 上传设置")
                color: "#f0f0f3"
                font.pixelSize: 14
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a30"
            }
        }

        contentItem: ColumnLayout {
            anchors.margins: 0
            spacing: 10

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 12
                text: qsTr("填入后端服务地址，点“保存并上传”后会将当前评分 CSV 推送过去。\n局域网示例：http://192.168.x.x:8765/upload")
                color: "#cfcfd4"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            GridLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                columns: 2
                columnSpacing: 10
                rowSpacing: 8

                Text { text: qsTr("服务地址"); color: "#9aa0a6"; font.pixelSize: 12 }
                TextField {
                    id: urlField
                    Layout.fillWidth: true
                    text: uploadConfigDialog._urlBuf
                    onTextChanged: uploadConfigDialog._urlBuf = text
                    placeholderText: "http://<host>:<port>/upload"
                    color: "#e8e8ec"
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        border.color: urlField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: 1
                        radius: 4
                    }
                }

                Text { text: qsTr("Token"); color: "#9aa0a6"; font.pixelSize: 12 }
                TextField {
                    id: tokField
                    Layout.fillWidth: true
                    text: uploadConfigDialog._tokBuf
                    onTextChanged: uploadConfigDialog._tokBuf = text
                    placeholderText: qsTr("可选；服务未启 PLAYERX_TOKEN 时留空即可")
                    color: "#e8e8ec"
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        border.color: tokField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: 1
                        radius: 4
                    }
                }
            }

            Item { Layout.preferredHeight: 4 }
        }

        footer: Rectangle {
            color: "transparent"
            implicitHeight: 56
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
                PillBtn {
                    text: qsTr("仅保存")
                    onClicked: {
                        if (typeof Rating !== "undefined") {
                            Rating.uploadServerUrl = uploadConfigDialog._urlBuf.trim()
                            Rating.uploadToken     = uploadConfigDialog._tokBuf
                        }
                        uploadConfigDialog.close()
                    }
                }
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("取消")
                    onClicked: uploadConfigDialog.close()
                }
                PillBtn {
                    text: qsTr("保存并上传")
                    emphasized: true
                    enabled: uploadConfigDialog._urlBuf.trim().length > 0
                    onClicked: {
                        if (typeof Rating !== "undefined") {
                            Rating.uploadServerUrl = uploadConfigDialog._urlBuf.trim()
                            Rating.uploadToken     = uploadConfigDialog._tokBuf
                            Rating.uploadToCloud()
                        }
                        uploadConfigDialog.close()
                    }
                }
            }
        }

        // 打开时预填当前配置
        onOpened: {
            if (typeof Rating !== "undefined") {
                _urlBuf = Rating.uploadServerUrl || ""
                _tokBuf = Rating.uploadToken     || ""
            }
        }
    }

    // ── 通用操作反馈 Toast（导出成功 / 上传成功都走这里）───────────────
    // 锡在对话框右下角，加轻微上滑动画，~3.5s 后深出。
    Item {
        id: actionToast
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 18
        width: toastBg.width
        height: toastBg.height
        opacity: 0
        visible: opacity > 0.01
        transform: Translate { id: toastSlide; y: 12 }
        z: 1000

        property bool _ok: true
        property string _msg: ""

        function show(ok, msg) {
            _ok = ok
            _msg = msg
            // 重点击时重启动画与计时
            fadeOut.stop()
            slideIn.restart()
            fadeIn.restart()
            hideTimer.restart()
        }

        Rectangle {
            id: toastBg
            radius: 8
            color: "#1e1e22"
            border.color: actionToast._ok ? "#52c41a" : "#f5222d"
            border.width: 1
            implicitWidth: Math.min(420, Math.max(220, toastLabel.implicitWidth + 32))
            width: implicitWidth
            height: toastLabel.implicitHeight + 22
            // 轻微阴影，提高在深色背景上的漂浮感
            Rectangle {
                anchors.fill: parent
                anchors.margins: -4
                z: -1
                radius: parent.radius + 3
                color: "#80000000"
                opacity: 0.45
            }
            Text {
                id: toastLabel
                anchors.fill: parent
                anchors.margins: 12
                text: (actionToast._ok ? "✅ " : "❌ ") + actionToast._msg
                color: "#e8e8ec"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
            }
        }

        NumberAnimation on opacity {
            id: fadeIn
            from: 0; to: 1; duration: 180
            easing.type: Easing.OutCubic
            running: false
        }
        NumberAnimation on opacity {
            id: fadeOut
            from: 1; to: 0; duration: 280
            easing.type: Easing.InCubic
            running: false
        }
        NumberAnimation {
            id: slideIn
            target: toastSlide
            property: "y"
            from: 12; to: 0; duration: 220
            easing.type: Easing.OutCubic
        }
        Timer {
            id: hideTimer
            interval: 3500
            onTriggered: fadeOut.restart()
        }
    }

    // 接上传结果信号跳 toast（导出的反馈在 exportDialog.onAccepted 里直接调发）
    Connections {
        target: (typeof Rating !== "undefined") ? Rating : null
        ignoreUnknownSignals: true
        function onUploadFinished(ok, message) {
            actionToast.show(ok, message)
            if (ok) {
                uploadBtn.flash = true
                uploadFlashTimer.restart()
            }
        }
        // 服务端返回 409：(rater, tag) 重复上传 → 弹覆盖确认
        function onUploadConflict(message) {
            uploadConflictDialog._msg = message
            uploadConflictDialog.open()
        }
    }

    // 覆盖确认对话框：同 (评分人, tag) 已存在时询问是否覆盖。
    // 确认后调 Rating.uploadToCloud(true) 带 force=1 重走。
    Dialog {
        id: uploadConflictDialog
        modal: true
        anchors.centerIn: parent
        width: 460
        padding: 0

        property string _msg: ""

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#2e2e34"
            border.width: 1
            radius: 8
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: Text.AlignVCenter
                text: qsTr("上传冲突：是否覆盖？")
                color: "#f0f0f3"
                font.pixelSize: 14
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a30"
            }
        }

        contentItem: Item {
            implicitHeight: _conflictCol.implicitHeight + 32
            ColumnLayout {
                id: _conflictCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: uploadConflictDialog._msg
                    color: "#e6e6ea"
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("覆盖将自动归档旧版本（每个槽位最多保留 20 份）")
                    color: "#8a8a90"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
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
                    onClicked: uploadConflictDialog.close()
                }
                PillBtn {
                    text: qsTr("覆盖上传")
                    danger: true
                    onClicked: {
                        uploadConflictDialog.close()
                        if (typeof Rating !== "undefined") Rating.uploadToCloud(true)
                    }
                }
            }
        }
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
        property string tooltipText: ""   // 非空时鼠标悬停 ~600ms 弹出（典型用法：文件名→绝对路径）
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
        // 悬停 ToolTip：仅在显式提供了 tooltipText 时启用，避免空 tooltip 干扰其他单元格
        MouseArea {
            id: _cellMA
            anchors.fill: parent
            hoverEnabled: parent.tooltipText.length > 0
            acceptedButtons: Qt.NoButton          // 不抢点击事件，纯 hover
            ToolTip.visible: containsMouse && parent.tooltipText.length > 0
            ToolTip.delay: 500
            ToolTip.timeout: 8000
            ToolTip.text: parent.tooltipText
        }
    }

    // 圆角胶囊按钮（与项目深色风格一致）
    component PillBtn: Rectangle {
        property string text: ""
        property bool enabled: true
        property bool emphasized: false
        property bool danger: false
        // 瞬态成功闪烁：设为 true 后按钮变绿、文案前加 ✅，外部负责起定时器退出
        property bool flash: false
        signal clicked()

        implicitWidth:  Math.max(72, _t.implicitWidth + 22)
        implicitHeight: 28
        radius: 5
        color: !enabled ? "#1a1a1d"
              : flash       ? (_ma.containsMouse ? "#37a169" : "#2f855a")
              : danger      ? (_ma.containsMouse ? "#a23a3a" : "#3a2326")
              : emphasized  ? (_ma.containsMouse ? "#3a7afe" : "#2a5994")
              :               (_ma.containsMouse ? "#3a3a44" : "#2a2a30")
        border.color: flash ? "#52c41a"
                            : (danger ? "#5a2a2e" : "#3a3a42")
        border.width: flash ? 1 : 1
        Behavior on color {
            ColorAnimation { duration: 180 }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180 }
        }
        Text {
            id: _t
            anchors.centerIn: parent
            text: (parent.flash ? "✅ " : "") + parent.text
            color: parent.enabled ? "#ffffff" : "#555"
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
