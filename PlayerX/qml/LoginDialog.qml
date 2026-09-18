import QtQuick
import QtQuick.Controls
import PlayerX 1.0

// ═══════════════════════════════════════════════════════════════════════
// 用户中心下拉菜单（右上角用户名按钮弹出，窄面板 200）
//   · 头部：当前登录用户 / 服务器 / Token（url/token 各账号基本共用，
//     仅展示当前选中账号的值；切换账号时同步为该账号存储的值）
//   · 账户列表：只显示用户名；单击行直接切换账号，
//     行右侧 hover 显示自绘线稿铅笔 / 垃圾桶小按钮
//   · 尾部：添加账号 / 退出登录
// ═══════════════════════════════════════════════════════════════════════
Popup {
    id: loginDialog

    property var root: null
    property var updateToast: null

    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: 6
    width: 200
    x: parent ? parent.width - width - 16 : 0
    // 紧贴标题栏/菜单栏下方弹出（macOS 菜单栏 26px；Windows 自绘标题栏 32px）。
    // macOS 原生菜单栏与窗口标题区有约 2px 融合，取 28 让面板顶端几乎贴住菜单文字底缘。
    y: 28

    // formMode："" = 菜单；"add" = 添加账号；"edit" = 修改资料
    property string formMode: ""
    // 正在编辑资料的账户名
    property string editingName: ""
    readonly property bool _loggedIn: root ? root._loggedIn : false
    readonly property bool _hasRating: typeof Rating !== "undefined"

    // 面板每次打开：立即发起一次服务器在线探测（HEAD，3s 超时，不真实上传）。
    // Rating.serverOnline: "online"/"offline"/"probing"/"unset"，头部状态点绑定显示。
    onVisibleChanged: {
        if (visible && _hasRating && root && root._loggedIn)
            Rating.probeServerOnline()
    }

    Overlay.modal: null

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 10
    }

    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 120 }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 100 }
    }

    function maskToken(t) {
        var s = String(t || "")
        if (s.length === 0) return "未设置"
        if (s.length <= 18) return s
        return s.substring(0, 8) + "…" + s.substring(s.length - 4)
    }

    function findAccount(nm) {
        if (!_hasRating || !Rating.savedAccounts) return null
        for (var i = 0; i < Rating.savedAccounts.length; ++i)
            if (Rating.savedAccounts[i].name === nm) return Rating.savedAccounts[i]
        return null
    }

    function openAddForm() {
        loginNameField.text = ""
        // url / Token 各账号基本共用：预填当前全局值，可直接修改
        uploadUrlField.text = _hasRating ? String(Rating.uploadServerUrl || "") : ""
        tokenField.text = _hasRating ? String(Rating.uploadToken || "") : ""
        formMode = "add"
        loginNameField.forceActiveFocus()
    }

    function openEditForm(nm) {
        loginDialog.editingName = nm
        var acc = findAccount(nm)
        loginNameField.text = acc ? acc.name : ""
        uploadUrlField.text = acc ? (acc.url || "") : ""
        tokenField.text = acc ? (acc.token || "") : ""
        formMode = "edit"
        loginNameField.forceActiveFocus()
    }

    contentItem: Item {
        implicitWidth: 200
        implicitHeight: formMode !== "" ? formCol.implicitHeight : menuCol.implicitHeight

        // ════ 菜单 ════
        Column {
            id: menuCol
            visible: formMode === ""
            anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
            topPadding: 4; bottomPadding: 4
            spacing: 1

            // ── 头部：当前登录用户 / 服务器 / Token ──
            Column {
                width: menuCol.width
                spacing: 1

                Text {
                    width: parent.width
                    leftPadding: 10; topPadding: 5
                    text: {
                        var n = _loggedIn && _hasRating ? String(Rating.currentUser || "") : ""
                        return n.length > 0 ? n : "当前未登录"
                    }
                    color: "#f0f0f3"; font.pixelSize: 13; font.bold: true
                    elide: Text.ElideRight
                }
                // 服务器行：状态点 + 地址 + 在线状态徽标。
                // Rating.serverOnline: "online"/"offline"/"probing"/"unset"
                Row {
                    visible: _loggedIn
                    width: menuCol.width - 20
                    x: 10; bottomPadding: 0
                    spacing: 5
                    leftPadding: 0

                    // 状态点：probing 黄 / online 绿 / offline 红 / unset 灰
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6; height: 6; radius: 3
                        color: {
                            var s = _hasRating ? String(Rating.serverOnline) : "unset"
                            if (s === "online")  return "#5ec269"
                            if (s === "probing") return "#e8b93e"
                            if (s === "offline") return "#e0566b"
                            return "#6a6a72"
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 6 - statusLabel.width - parent.spacing * 2
                        text: {
                            var u = _hasRating ? String(Rating.uploadServerUrl || "") : ""
                            return u.length > 0 ? u : "未配置"
                        }
                        color: "#8a8a96"; font.pixelSize: 10
                        elide: Text.ElideMiddle
                    }
                    Text {
                        id: statusLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            var s = _hasRating ? String(Rating.serverOnline) : "unset"
                            if (s === "online")  return "在线"
                            if (s === "probing") return "检测中"
                            if (s === "offline") return "离线"
                            return "未配置"
                        }
                        color: {
                            var s = _hasRating ? String(Rating.serverOnline) : "unset"
                            if (s === "online")  return "#5ec269"
                            if (s === "probing") return "#e8b93e"
                            if (s === "offline") return "#e0566b"
                            return "#6a6a72"
                        }
                        font.pixelSize: 10
                    }
                }
                Text {
                    visible: _loggedIn
                    width: parent.width
                    leftPadding: 10; bottomPadding: 5
                    text: "Token：" + (_hasRating ? maskToken(Rating.uploadToken) : "未设置")
                    color: "#8a8a96"; font.pixelSize: 10
                }
            }

            Rectangle {
                width: menuCol.width; height: 1
                color: "#2c2c32"
            }

            // ── 账户列表：单击行切换；hover 行尾出现编辑/删除 ──
            Repeater {
                model: _hasRating && Rating.savedAccounts ? Rating.savedAccounts : []

                delegate: Rectangle {
                    id: accountItem
                    width: menuCol.width; height: 30; radius: 6
                    color: accountItem.isCurrent
                           ? "#1a2f2a"
                           : (accountItem.rowHovered ? "#26262c" : "transparent")

                    readonly property string accName: modelData.name
                    readonly property bool isCurrent: _hasRating && accName === Rating.currentUser
                    // hover 判定需合并行与两个按钮：按钮 MouseArea 与行 MouseArea 是兄弟节点，
                    // hover 会被顶层按钮抢走（不沿父链传播），若只看 rowMa.containsMouse，
                    // 按钮会陷入“出现→抢走hover→隐藏→复现”的闪烁循环
                    readonly property bool rowHovered:
                        rowMa.containsMouse || editBtnMa.containsMouse || delBtnMa.containsMouse

                    Text {
                        anchors.left: parent.left; anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 58
                        text: accountItem.accName + (accountItem.isCurrent ? "  ✓" : "")
                        color: accountItem.isCurrent ? "#7fd8c0" : "#e8e8ec"
                        font.pixelSize: 12
                        font.bold: accountItem.isCurrent
                        elide: Text.ElideRight
                    }

                    // 整行单击 → 直接切换账号（当前账号无操作）
                    MouseArea {
                        id: rowMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!accountItem.isCurrent && _hasRating) {
                                Rating.switchAccount(accountItem.accName)
                                updateToast.text = "已切换到「" + accountItem.accName + "」"
                                updateToast.open()
                            }
                        }
                    }

                    // hover 行尾出现的编辑 / 删除 小按钮（位于 rowMa 上层，可独立点击）
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        visible: accountItem.rowHovered

                        // 编辑（自绘铅笔线稿）
                        Rectangle {
                            width: 20; height: 20; radius: 4
                            color: editBtnMa.containsMouse ? "#2b2b33" : "transparent"
                            PencilIcon {
                                anchors.centerIn: parent
                                lineColor: editBtnMa.containsMouse ? "#8ab4e8" : "#767681"
                            }
                            MouseArea {
                                id: editBtnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: openEditForm(accountItem.accName)
                            }
                        }

                        // 删除（自绘垃圾桶线稿）
                        Rectangle {
                            width: 20; height: 20; radius: 4
                            color: delBtnMa.containsMouse ? "#33242a" : "transparent"
                            TrashIcon {
                                anchors.centerIn: parent
                                lineColor: delBtnMa.containsMouse ? "#e07870" : "#767681"
                            }
                            MouseArea {
                                id: delBtnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Rating.removeAccount(accountItem.accName)
                                    if (loginDialog.editingName === accountItem.accName)
                                        loginDialog.editingName = ""
                                    if (accountItem.isCurrent)
                                        root._logout()
                                    updateToast.text = "已删除「" + accountItem.accName + "」"
                                    updateToast.open()
                                }
                            }
                        }
                    }
                }
            }

            // 空列表提示
            Text {
                visible: !_hasRating || !Rating.savedAccounts || Rating.savedAccounts.length === 0
                width: menuCol.width
                horizontalAlignment: Text.AlignHCenter
                topPadding: 10; bottomPadding: 10
                text: "暂无账户"
                color: "#55555e"; font.pixelSize: 12
            }

            Rectangle {
                width: menuCol.width; height: 1
                color: "#2c2c32"
            }

            // ── 添加账号 ──
            Rectangle {
                width: menuCol.width; height: 30; radius: 6
                color: addMa.containsMouse ? "#26262c" : "transparent"
                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: Text.AlignVCenter
                    text: "添加账号"
                    color: "#e8e8ec"; font.pixelSize: 12
                }
                MouseArea {
                    id: addMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: openAddForm()
                }
            }

            // ── 退出登录 ──
            Rectangle {
                visible: _loggedIn
                width: menuCol.width; height: 30; radius: 6
                color: logoutMa.containsMouse ? "#3a2630" : "transparent"
                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: Text.AlignVCenter
                    text: "退出登录"
                    color: "#e07870"; font.pixelSize: 12
                }
                MouseArea {
                    id: logoutMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (_hasRating && Rating.logoutAccount)
                            Rating.logoutAccount()
                        root._logout()
                        loginDialog.close()
                    }
                }
            }
        }

        // ════ 添加账号 / 修改资料 表单 ════
        Column {
            id: formCol
            visible: formMode !== ""
            anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
            topPadding: 8; bottomPadding: 8
            spacing: 8

            Text {
                width: parent.width - 12
                anchors.horizontalCenter: parent.horizontalCenter
                text: formMode === "edit" ? "修改资料 — " + loginDialog.editingName : "添加账号"
                color: "#f0f0f3"; font.pixelSize: 13; font.bold: true
                elide: Text.ElideRight
            }
            Text {
                width: parent.width - 12
                anchors.horizontalCenter: parent.horizontalCenter
                wrapMode: Text.WordWrap
                text: formMode === "edit"
                      ? "可修改姓名及 url / Token。"
                      : "姓名用于评分上传署名；url / Token 各账号基本共用。"
                color: "#8a8a96"; font.pixelSize: 10
            }

            // 姓名
            Text { width: parent.width - 12; anchors.horizontalCenter: parent.horizontalCenter; text: "姓名（必填）"; color: "#8a8a96"; font.pixelSize: 10 }
            Rectangle {
                width: parent.width - 12
                anchors.horizontalCenter: parent.horizontalCenter
                height: 30; radius: 5
                color: "#101013"
                border.color: loginNameField.activeFocus ? "#5a8fd8" : "#2c2c32"
                border.width: 1
                TextInput {
                    id: loginNameField
                    anchors.fill: parent
                    anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#e8e8ec"; font.pixelSize: 12
                    selectByMouse: true
                    Keys.onReturnPressed: saveBtnMa.clicked(null)
                    Keys.onEnterPressed: saveBtnMa.clicked(null)
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: loginNameField.text.length === 0
                        text: "请输入姓名"
                        color: "#55555e"; font.pixelSize: 11
                    }
                }
            }

            // 上传服务器
            Text { width: parent.width - 12; anchors.horizontalCenter: parent.horizontalCenter; text: "上传服务器地址（可选）"; color: "#8a8a96"; font.pixelSize: 10 }
            Rectangle {
                width: parent.width - 12
                anchors.horizontalCenter: parent.horizontalCenter
                height: 30; radius: 5
                color: "#101013"
                border.color: uploadUrlField.activeFocus ? "#5a8fd8" : "#2c2c32"
                border.width: 1
                TextInput {
                    id: uploadUrlField
                    anchors.fill: parent
                    anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#e8e8ec"; font.pixelSize: 12
                    selectByMouse: true
                    Keys.onReturnPressed: saveBtnMa.clicked(null)
                    Keys.onEnterPressed: saveBtnMa.clicked(null)
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: uploadUrlField.text.length === 0
                        text: "http://<host>:<port>/"
                        color: "#55555e"; font.pixelSize: 11
                    }
                }
            }

            // Token
            Text { width: parent.width - 12; anchors.horizontalCenter: parent.horizontalCenter; text: "Token（可选）"; color: "#8a8a96"; font.pixelSize: 10 }
            Rectangle {
                width: parent.width - 12
                anchors.horizontalCenter: parent.horizontalCenter
                height: 30; radius: 5
                color: "#101013"
                border.color: tokenField.activeFocus ? "#5a8fd8" : "#2c2c32"
                border.width: 1
                TextInput {
                    id: tokenField
                    anchors.fill: parent
                    anchors.leftMargin: 8; anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#e8e8ec"; font.pixelSize: 12
                    selectByMouse: true
                    Keys.onReturnPressed: saveBtnMa.clicked(null)
                    Keys.onEnterPressed: saveBtnMa.clicked(null)
                }
            }

            Item { width: 1; height: 2 }

            // 取消 / 保存
            Item {
                width: parent.width - 12
                anchors.horizontalCenter: parent.horizontalCenter
                height: 30
                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 68; height: 28; radius: 5
                    color: cancelMa.containsMouse ? "#33333c" : "#26262c"
                    border.color: "#3a3a45"; border.width: 1
                    Text { anchors.centerIn: parent; text: "取消"; color: "#c8c8cc"; font.pixelSize: 11 }
                    MouseArea {
                        id: cancelMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: formMode = ""
                    }
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 68; height: 28; radius: 5
                    color: saveBtnMa.containsMouse ? "#0db092" : "#0fa085"
                    Text {
                        anchors.centerIn: parent
                        text: formMode === "edit" ? "保存" : "添加"
                        color: "#ffffff"; font.pixelSize: 11; font.bold: true
                    }
                    MouseArea {
                        id: saveBtnMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var v = loginNameField.text.trim()
                            if (v.length === 0) { loginNameField.forceActiveFocus(); return }
                            if (_hasRating) {
                                if (formMode === "edit") {
                                    Rating.updateAccount(loginDialog.editingName, v,
                                                          uploadUrlField.text.trim(), tokenField.text)
                                    loginDialog.editingName = ""
                                    updateToast.text = "资料已更新"
                                } else {
                                    Rating.loginAccount(v, uploadUrlField.text.trim(), tokenField.text)
                                    updateToast.text = "已登录，欢迎「" + v + "」"
                                }
                                updateToast.open()
                            }
                            formMode = ""
                            loginDialog.close()
                        }
                    }
                }
            }
        }
    }

    onAboutToShow: {
        formMode = ""
        editingName = ""
        if (!_loggedIn && _hasRating && Rating.savedAccounts && Rating.savedAccounts.length === 0)
            openAddForm()
    }
}
