// MultiGroupRow.qml — 多组对比模式配置面板的一行（即一路）
//
// 职责：
//   - 显示并管理"该路"的：文件夹路径 / 过滤关键字 / 命中数 / 当前选中索引；
//   - 提供：选择文件夹、清空、上一项/下一项；
//   - 不直接调 Engine，对外通过 property + signal 暴露状态变化；
//
// 完全独立组件：单组模式下根本不会被实例化（Dialog 不弹出即可），
// 因此对主体功能 0 影响。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import PlayerX 1.0

Rectangle {
    id: row

    // ─── 对外属性 ───────────────────────────────────────────────────
    property int laneIndex: 0                // 序号（从 0 开始，仅显示用 +1）
    // 是否参与启动：勾选 = 参与。外层根据勾选数决定走"单文件夹打开"还是"多组对比"。
    property bool selected: true
    property string folderPath: ""           // 选中的文件夹（空字符串 = 未选）
    property string keyword: ""              // 过滤关键字
    property var allFiles: []                // 该路扫描到的全部视频（绝对路径，已排序）
    property var visibleFiles: []            // 经 keyword 过滤后的列表
    property int currentIndex: -1            // 在 visibleFiles 中的索引（-1 = 无选中）
    // 排序模式：0=名称升序（默认，与 Fs 扫描结果一致）  1=名称降序
    property int sortMode: 0

    // 动作：删除本行（laneIndex 为 0 时通常隐藏删除按钮）
    property bool removable: true

    // 弹"📁 选择文件夹"对话框时使用的初始目录（QUrl）。
    // 由父级（MultiGroupDialog）注入"全局上一次成功导入目录"，
    // 这样 1. 已导入的行：再次点 📁 还是从上次目录起步（与 Qt 默认一致）；
    //      2. 全新行：也能跳到全局上次目录，而不是回到 Macintosh HD 根。
    // 空字符串 / 无效 url 时 Qt 会回退到平台默认目录（HOME），保持向下兼容。
    property url defaultFolderUrl: ""

    // ─── 对外信号 ─────────────────────────────────
    signal removeRequested()
    // 任意输入变化时触发，让父级重新计算 canStart 等
    // 注：QML Item 自带 state 属性（并附带 stateChanged 信号），故这里不能再叫 stateChanged。
    signal laneChanged()
    // 通过 📁 对话框成功选择了文件夹（accepted）。父级据此固化"全局上次目录"，
    // 让后续新增行/再次打开此对话框都从这里起步。
    signal folderImported(url folderUrl)
    // 通过 📁 对话框选择了文件夹但「尚未应用」：把决策交给父级。
    //   · folderUrl: 用户选择的目录 URL；
    //   · apply:     一个 callable —— 父级在「不重复 / 用户确认」时调用，
    //                即可真正写入本路 folderPath/allFiles 并触发 folderImported。
    // 父级若不调 apply 即视为"取消"，本路保持原状。
    signal folderRequested(url folderUrl, var apply)
    // ─── 视觉 ───────────────────────────────────────────────────────
    color: "#1a1a1d"
    border.color: "#2c2c32"
    border.width: 1
    radius: 6
    implicitHeight: 40

    // 自然序字符串比较：把串切成"文本/数字"片段，文本按字典序（忽略大小写），
    // 数字按数值比，从而保证 "1 < 2 < 10 < 11"，与 Finder/Explorer 一致。
    // 注：这里**不**用 String.prototype.localeCompare(b, undefined, {numeric:true})，
    //     因为 Qt QML 的 V4 引擎并未实现 ECMA-402 Intl 选项，{numeric:true} 会被
    //     静默忽略，结果退化为字典序（1, 10, 11, 2, 20, 3 …）。
    function _natCompare(a, b) {
        // 拆分为段：数字段 与 非数字段（按 ASCII 数字判断；中文等按文本走）
        var re = /(\d+)|(\D+)/g
        var pa = a.toLowerCase().match(re) || []
        var pb = b.toLowerCase().match(re) || []
        var n = Math.min(pa.length, pb.length)
        for (var i = 0; i < n; ++i) {
            var sa = pa[i], sb = pb[i]
            var na = /^\d+$/.test(sa)
            var nb = /^\d+$/.test(sb)
            if (na && nb) {
                // 都是数字 → 比数值
                var va = parseInt(sa, 10)
                var vb = parseInt(sb, 10)
                if (va !== vb) return va < vb ? -1 : 1
                // 数值相等但前导零不同（"01" vs "1"）：长的排后面，保证稳定
                if (sa.length !== sb.length) return sa.length < sb.length ? -1 : 1
            } else if (na !== nb) {
                // 数字段 vs 文本段 → 数字段排前面（"img2" < "imga"）
                return na ? -1 : 1
            } else {
                // 都是文本 → 字典序
                if (sa !== sb) return sa < sb ? -1 : 1
            }
        }
        return pa.length - pb.length
    }

    // 内部：根据 keyword 重新计算 visibleFiles + currentIndex
    function _recomputeVisible() {
        var kw = keyword.trim().toLowerCase()
        var src = allFiles
        if (kw.length === 0) {
            // 复制一份，避免直接引用 allFiles
            src = allFiles.slice()
        } else {
            var arr = []
            for (var i = 0; i < allFiles.length; ++i) {
                if (allFiles[i].toLowerCase().indexOf(kw) >= 0) arr.push(allFiles[i])
            }
            src = arr
        }
        // 应用排序（仅在 QML 层做，不依赖 Fs）。
        // 走 _natCompare 自然序：1, 2, 10, 11 —— 与 Finder/Explorer、图集帧号一致。
        if (sortMode === 1) {
            // 按文件名（不含目录）降序
            src.sort(function(a, b) {
                return -row._natCompare(Fs.fileName(a), Fs.fileName(b))
            })
        } else {
            // 按文件名升序
            src.sort(function(a, b) {
                return row._natCompare(Fs.fileName(a), Fs.fileName(b))
            })
        }
        visibleFiles = src
        if (visibleFiles.length === 0) {
            currentIndex = -1
        } else {
            // 关键字变化后默认回到第一项；
            // 但若当前 currentIndex 已是 visibleFiles 内的有效索引，则保留
            // —— 这样外部（如 MultiGroupDialog 持久化恢复）首次注入 allFiles 时
            //    可以保留指定的 currentIndex，不会被强制重置为 0。
            if (currentIndex < 0 || currentIndex >= visibleFiles.length) {
                currentIndex = 0
            }
        }
        laneChanged()
    }

    // 关键字 / allFiles / 排序模式 变化时自动重算
    onKeywordChanged: _recomputeVisible()
    onAllFilesChanged: _recomputeVisible()
    onSortModeChanged: _recomputeVisible()
    onCurrentIndexChanged: laneChanged()
    onSelectedChanged: laneChanged()

    // 当前选中文件名（仅展示用）
    function currentName() {
        if (currentIndex < 0 || currentIndex >= visibleFiles.length) return "—"
        var p = visibleFiles[currentIndex]
        return Fs.fileName(p)
    }
    function currentPath() {
        if (currentIndex < 0 || currentIndex >= visibleFiles.length) return ""
        return visibleFiles[currentIndex]
    }

    // ─── 文件夹选择对话框 ───────────────────────────────────────────
    FolderDialog {
        id: folderDlg
        title: "为「路 " + (row.laneIndex + 1) + "」选择文件夹"
        // 起始目录优先级：
        //   1) 本路已选过的 folderPath（用户最直观期待）；
        //   2) 父级注入的 defaultFolderUrl —— 全局上一次成功导入的目录；
        //   3) 都没有 → 留空（Qt 自行落到 HOME）。
        // 注：QML 里给 url 属性赋空串等价于无效 url，Qt 会忽略并回退默认。
        // 本路 folderPath 是绝对本地路径，用 file:// 前缀转 URL（Windows 上需要 file:/// 前缀，
        // 但绝对路径已带 "C:/..."，拼成 "file:///C:/..." 也满足）。
        currentFolder: {
            if (row.folderPath && row.folderPath.length > 0) {
                var p = row.folderPath
                if (p.charAt(0) === "/") return "file://" + p          // *nix / mac
                return "file:///" + p                                   // Windows "C:/..."
            }
            return row.defaultFolderUrl
        }
        onAccepted: {
            // 把"真正的应用"封装为闭包，交给父级决定是否调用：
            //   · 父级若发现该路径已被其它路占用 → 弹确认；
            //   · 用户确认 / 不重复 → 父级会调 apply()；用户取消 → 不调用。
            var folderUrl = selectedFolder
            var apply = function() {
                // 注意：Windows 上 selectedFolder 形如 "file:///C:/Users/..."，
                //       直接 substring(7) 会得到 "/C:/Users/..." 多一个前导斜杠
                //       导致 QFileInfo 判定不存在 → 扫描结果为空。
                //       必须通过 Fs.urlToLocalFile() 让 Qt 自己处理跨平台 URL → path 转换。
                row.folderPath = Fs.urlToLocalFile(folderUrl)
                // 直接传 QUrl 给 C++ 端，避免 QML 侧再做字符串处理。
                row.allFiles = Fs.scanVideoFolder(folderUrl, true)
                // 通知父级固化"全局上次目录"，供后续新行/再次点 📁 复用
                row.folderImported(folderUrl)
            }
            // 发给父级（MultiGroupDialog._onRowPickedFolder 会路由到确认逻辑）
            row.folderRequested(folderUrl, apply)
        }
    }

    // 注：参考图绑定入口已统一收敛到主窗左侧「参考资料」侧边栏，
    // 这里不再提供 🖼 按钮 / 文件选择对话框 / 弹出菜单。

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.topMargin: 6
        anchors.bottomMargin: 6
        spacing: 8

        // 勾选框：仅勾选的行参与启动。外层根据勾选数分流：
        //   1 行 → 等同"打开文件夹"；≥2 行 → 多组对比。
        CheckBox {
            id: selectChk
            Layout.preferredWidth: 24
            Layout.preferredHeight: 24
            Layout.alignment: Qt.AlignVCenter
            checked: row.selected
            onToggled: row.selected = checked
            ToolTip.visible: hovered
            ToolTip.delay: 400
            ToolTip.text: row.selected ? "已参与启动（取消勾选可忽略本路）"
                                       : "未参与启动（勾选后将参与）"
            // 极简样式，与整体深色风格一致
            indicator: Rectangle {
                implicitWidth: 16
                implicitHeight: 16
                x: (selectChk.width - width) / 2
                y: (selectChk.height - height) / 2
                radius: 3
                color: selectChk.checked ? "#0fa085" : "#101013"
                border.color: selectChk.checked ? "#0fa085"
                             : (selectChk.hovered ? "#5a8fd8" : "#3a3a45")
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    visible: selectChk.checked
                    text: "✓"
                    color: "#ffffff"
                    font.pixelSize: 12
                    font.bold: true
                }
            }
        }

        // 路号徽标（统一 26x26）
        Rectangle {
            Layout.preferredWidth: 26
            Layout.preferredHeight: 26
            Layout.alignment: Qt.AlignVCenter
            radius: 4
            color: "#2a2a32"
            border.color: "#3a3a45"
            border.width: 1
            Label {
                anchors.centerIn: parent
                text: row.laneIndex + 1
                color: "#cfcfd2"
                font.bold: true
                font.pixelSize: 13
            }
        }

        // 文件夹选择（极简：纯图标按钮 28×28）
        // 未选 → 蓝色描边引导；已选 → 普通描边。
        Button {
            id: folderBtn
            text: "📁"
            Layout.preferredHeight: 28
            Layout.preferredWidth: 28
            Layout.alignment: Qt.AlignVCenter
            onClicked: folderDlg.open()
            hoverEnabled: true
            background: Rectangle {
                color: folderBtn.down ? "#4a4a55"
                      : folderBtn.hovered ? "#33333a"
                                          : "#202024"
                border.color: row.folderPath.length === 0 ? "#5a8fd8" : "#3a3a42"
                border.width: 1
                radius: 3
            }
            contentItem: Text {
                text: folderBtn.text
                color: row.folderPath.length === 0 ? "#9ec1ee" : "#e8e8ec"
                font.pixelSize: 14
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        // 列分隔
        Rectangle {
            Layout.preferredWidth: 1
            Layout.preferredHeight: 22
            Layout.alignment: Qt.AlignVCenter
            color: "#2a2a32"
        }

        // 过滤关键字（固定宽度，方便所有行对齐；缩短宽度以让位给文件名）
        TextField {
            id: kwField
            Layout.preferredWidth: 110
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            placeholderText: "过滤 (_a)"
            text: row.keyword
            color: "#e8e8ec"
            font.pixelSize: 12
            selectByMouse: true
            verticalAlignment: TextInput.AlignVCenter
            background: Rectangle {
                color: "#101013"
                border.color: kwField.activeFocus ? "#5a8fd8" : "#2c2c32"
                border.width: 1
                radius: 3
            }
            onTextChanged: row.keyword = text
        }

        // 命中数量徽标（紧凑，不参与 elide，宽度自适应内容）
        Label {
            color: "#9a9aa8"
            font.pixelSize: 11
            Layout.alignment: Qt.AlignVCenter
            text: {
                if (row.allFiles.length === 0) return "（未导入）"
                if (row.visibleFiles.length === 0) return "0 / " + row.allFiles.length
                return (row.currentIndex + 1) + " / " + row.visibleFiles.length
                      + "  · 共 " + row.allFiles.length
            }
        }

        // 当前文件名（Item 包裹：外层高亮背景 + 内层 Label + 顶层 MouseArea）
        // 整个区域可点击 → 弹出本路完整文件列表（fileListPopup）。
        Item {
            id: nameWrap
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter

            Rectangle {
                id: nameBg
                anchors.fill: parent
                anchors.topMargin: 2
                anchors.bottomMargin: 2
                radius: 3
                color: nameHover.containsMouse && row.visibleFiles.length > 0
                       ? "#262630" : "transparent"
                border.color: nameHover.containsMouse && row.visibleFiles.length > 0
                              ? "#3a3a45" : "transparent"
                border.width: 1
            }
            Label {
                id: nameLabel
                anchors.fill: parent
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                color: "#cfcfd2"
                font.pixelSize: 12
                verticalAlignment: Text.AlignVCenter
                // 显示绝对路径，过长时从开头省略（保留更具辨识度的尾部文件名 + 末级目录）
                elide: Text.ElideLeft
                text: {
                    var p = row.currentPath()
                    return p.length > 0 ? p : row.currentName()
                }
            }
            MouseArea {
                id: nameHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: row.visibleFiles.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (row.visibleFiles.length > 0) fileListPopup.open()
                }
            }
            ToolTip.visible: nameHover.containsMouse && row.currentPath().length > 0
            ToolTip.delay: 400
            ToolTip.text: row.currentPath()
        }

        // 排序切换按钮：A↑ / A↓
        Button {
            id: sortBtn
            text: row.sortMode === 1 ? "A↓" : "A↑"
            Layout.preferredWidth: 32
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            hoverEnabled: true
            ToolTip.visible: hovered
            ToolTip.delay: 400
            ToolTip.text: row.sortMode === 1 ? "当前：名称降序（点击切换为升序）"
                                              : "当前：名称升序（点击切换为降序）"
            onClicked: row.sortMode = (row.sortMode === 1 ? 0 : 1)
            background: Rectangle {
                color: sortBtn.down ? "#4a4a55"
                      : sortBtn.hovered ? "#33333a"
                                         : "#202024"
                border.color: "#3a3a42"
                border.width: 1
                radius: 3
            }
            contentItem: Text {
                text: sortBtn.text
                color: "#e8e8ec"
                font.pixelSize: 11
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        // 列分隔
        Rectangle {
            Layout.preferredWidth: 1
            Layout.preferredHeight: 22
            Layout.alignment: Qt.AlignVCenter
            color: "#2a2a32"
        }

        // 上一项 / 下一项
        Button {
            text: "↑"
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            enabled: row.visibleFiles.length > 0 && row.currentIndex > 0
            onClicked: row.currentIndex = Math.max(0, row.currentIndex - 1)
            background: Rectangle {
                color: !parent.enabled ? "#1a1a1d"
                      : parent.down ? "#4a4a55"
                      : parent.hovered ? "#33333a"
                                        : "#202024"
                border.color: "#3a3a42"
                border.width: 1
                radius: 3
            }
            contentItem: Text {
                text: parent.text
                color: parent.enabled ? "#e8e8ec" : "#555"
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
        Button {
            text: "↓"
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            enabled: row.visibleFiles.length > 0 && row.currentIndex < row.visibleFiles.length - 1
            onClicked: row.currentIndex = Math.min(row.visibleFiles.length - 1, row.currentIndex + 1)
            background: Rectangle {
                color: !parent.enabled ? "#1a1a1d"
                      : parent.down ? "#4a4a55"
                      : parent.hovered ? "#33333a"
                                        : "#202024"
                border.color: "#3a3a42"
                border.width: 1
                radius: 3
            }
            contentItem: Text {
                text: parent.text
                color: parent.enabled ? "#e8e8ec" : "#555"
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        // 删除本行
        Button {
            text: "🗑"
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            visible: row.removable
            onClicked: row.removeRequested()
            background: Rectangle {
                color: parent.down ? "#5a2a2a"
                      : parent.hovered ? "#3a2228"
                                        : "#202024"
                border.color: "#3a3a42"
                border.width: 1
                radius: 3
            }
            contentItem: Text {
                text: parent.text
                color: "#e8b0b0"
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    // ─── 文件列表弹出（点击当前文件名时弹出，方便查看/选择） ─────────
    Popup {
        id: fileListPopup
        // 锚定在文件名区域下方
        x: nameWrap.x
        y: nameWrap.y + nameWrap.height + 4
        width: Math.max(420, nameWrap.width)
        height: 320
        modal: false
        focus: true
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

        background: Rectangle {
            color: "#15151a"
            border.color: "#3a3a45"
            border.width: 1
            radius: 6
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 0
            spacing: 0

            // 标题栏
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                color: "#1c1c22"
                radius: 6
                Label {
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: "路 " + (row.laneIndex + 1) + "  ·  " +
                          row.visibleFiles.length + " / " + row.allFiles.length +
                          (row.keyword.length > 0 ? "  ·  关键字：" + row.keyword : "")
                    color: "#cfcfd2"
                    font.pixelSize: 12
                    font.bold: true
                }
                Label {
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✕"
                    color: "#9a9aa8"
                    font.pixelSize: 14
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: fileListPopup.close()
                    }
                }
            }

            // 列表
            ListView {
                id: fileListView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: row.visibleFiles
                currentIndex: row.currentIndex
                ScrollBar.vertical: ScrollBar {}

                delegate: Rectangle {
                    width: ListView.view.width
                    height: 26
                    color: ListView.isCurrentItem
                           ? "#2a3a55"
                           : (mouseDel.containsMouse ? "#22222a" : "transparent")
                    Label {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: idxLabel.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: Fs.fileName(modelData)
                        color: parent.ListView.isCurrentItem ? "#ffffff" : "#cfcfd2"
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                    Label {
                        id: idxLabel
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "#" + (index + 1)
                        color: "#7a7a85"
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: mouseDel
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: row.currentIndex = index
                        onDoubleClicked: {
                            row.currentIndex = index
                            fileListPopup.close()
                        }
                    }
                }
            }

            // 底部提示
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                color: "#1c1c22"
                Label {
                    anchors.centerIn: parent
                    text: "单击选中，双击选中并关闭"
                    color: "#7a7a85"
                    font.pixelSize: 10
                }
            }
        }

        // 弹出时滚动到当前项
        onOpened: {
            if (fileListView.currentIndex >= 0)
                fileListView.positionViewAtIndex(fileListView.currentIndex, ListView.Center)
        }
    }
}
