import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Dialog {
    id: loginDialog
    property var root: null
    property var updateToast: null
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    // 退出方式：Esc / 点击面板外任意处 / 头部 ✕ / 再次点击菜单入口（见 _toggleLoginDialog）
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 400
    padding: 0

    // 编辑态：true=显示姓名输入框；未登录时恒为编辑态（即登录框）
    property bool _editing: false
    readonly property bool _showProfile: root._loggedIn && !_editing

    Overlay.modal: Rectangle { color: "#aa000000" }

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
    }

    header: Rectangle {
        color: "#22303f"
        implicitHeight: 46
        radius: 6
        // 盖住 header 底部圆角，与内容区平直衔接
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 6
            color: "#22303f"
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: loginDialog._showProfile ? "👤 个人信息" : "👤 登录"
            color: "#f0f0f3"
            font.pixelSize: 14
            font.bold: true
        }
        // 已登录徽章（让位给 ✕ 关闭按钮）
        Rectangle {
            visible: root._loggedIn
            anchors.right: loginCloseX.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: loginStateText.width + 14
            height: 20
            radius: 10
            color: "#1f4d3f"
            Text {
                id: loginStateText
                anchors.centerIn: parent
                text: "已登录"
                color: "#5dd8b0"
                font.pixelSize: 10
            }
        }
        // 头部 ✕ 关闭按钮
        Text {
            id: loginCloseX
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: "✕"
            color: loginCloseXMa.containsMouse ? "#ffffff" : "#9a9aa8"
            font.pixelSize: 14
            MouseArea {
                id: loginCloseXMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: loginDialog.close()
            }
        }
    }

    contentItem: Item {
        implicitWidth: 368
        implicitHeight: loginDialog._showProfile ? profileCol.implicitHeight : editCol.implicitHeight

        // ════ 个人信息页 ════
        Column {
            id: profileCol
            anchors.fill: parent
            visible: loginDialog._showProfile
            spacing: 0
            topPadding: 22
            bottomPadding: 16

            // 头像：姓名首字符
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 60
                height: 60
                radius: 30
                color: "#0fa085"
                Text {
                    anchors.centerIn: parent
                    text: {
                        var n = (typeof Rating !== "undefined" ? String(Rating.currentUser || "") : "").trim()
                        return n.length > 0 ? n.charAt(0).toUpperCase() : "?"
                    }
                    color: "#ffffff"
                    font.pixelSize: 26
                    font.bold: true
                }
            }
            Item { width: 1; height: 10 }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: (typeof Rating !== "undefined" ? Rating.currentUser : "")
                color: "#f0f0f3"
                font.pixelSize: 18
                font.bold: true
            }
            Item { width: 1; height: 4 }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    var su = ""
                    try { if (typeof Rating !== "undefined") su = String(Rating.currentUser || "") } catch (e) {}
                    if (su.length === 0) {
                        try { if (typeof Rating !== "undefined") su = String(Rating.systemUserName() || "") } catch (e) {}
                    }
                    return "系统用户：" + (su.length > 0 ? su : "未知")
                }
                color: "#9a9aa8"
                font.pixelSize: 12
            }
            Item { width: 1; height: 16 }
            Rectangle {
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                height: 1
                color: "#2c2c32"
            }
            // 信息行：上传服务器
            Item {
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                height: 38
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "上传服务器"
                    color: "#9a9aa8"
                    font.pixelSize: 12
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        var u = (typeof Rating !== "undefined" ? String(Rating.uploadServerUrl || "") : "")
                        return u.length > 0 ? u : "未配置"
                    }
                    color: "#c8c8cc"
                    font.pixelSize: 12
                }
            }
            Rectangle {
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                height: 1
                color: "#2c2c32"
            }
            // 信息行：Token（与「上传设置」对话框共用同一份配置）
            Item {
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                height: 38
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Token"
                    color: "#9a9aa8"
                    font.pixelSize: 12
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        var t = (typeof Rating !== "undefined" ? String(Rating.uploadToken || "") : "")
                        return t.length > 0 ? t : "未配置"
                    }
                    color: "#c8c8cc"
                    font.pixelSize: 12
                }
            }
            Rectangle {
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                height: 1
                color: "#2c2c32"
            }
            Item { width: 1; height: 16 }
            // 按钮行：退出登录（左，警示色） / 修改资料（右，主色）
            Item {
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                height: 30
                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 88
                    height: 30
                    radius: 5
                    color: logoutMa.containsMouse ? "#3a2630" : "#26262c"
                    border.color: logoutMa.containsMouse ? "#8a4040" : "#3a3a45"
                    border.width: 1
                    Text { anchors.centerIn: parent; text: "退出登录"; color: "#e07870"; font.pixelSize: 12 }
                    MouseArea {
                        id: logoutMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { loginDialog.close(); root._logout() }
                    }
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 88
                    height: 30
                    radius: 5
                    color: editMa.containsMouse ? "#0db092" : "#0fa085"
                    Text { anchors.centerIn: parent; text: "修改资料"; color: "#ffffff"; font.pixelSize: 12; font.bold: true }
                    MouseArea {
                        id: editMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            loginNameField.text = (typeof Rating !== "undefined") ? Rating.currentUser : ""
                            uploadUrlField.text = (typeof Rating !== "undefined") ? (Rating.uploadServerUrl || "") : ""
                            uploadTokenField.text = (typeof Rating !== "undefined") ? (Rating.uploadToken || "") : ""
                            loginDialog._editing = true
                            loginNameField.forceActiveFocus()
                            loginNameField.selectAll()
                        }
                    }
                }
            }
        }

        // ════ 登录 / 编辑页 ════
        Column {
            id: editCol
            anchors.fill: parent
            visible: !loginDialog._showProfile
            spacing: 10
            topPadding: 16
            bottomPadding: 14

            Text {
                width: parent.width
                text: "评分人：用于评分数据上传署名；若后台配置了组别分配，接受测试源时按评分人自动选组。"
                color: "#c8c8cc"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            Rectangle {
                width: parent.width
                height: 34
                radius: 5
                color: "#101013"
                border.color: loginNameField.activeFocus ? "#5a8fd8" : "#2c2c32"
                border.width: 1
                TextInput {
                    id: loginNameField
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#e8e8ec"
                    font.pixelSize: 13
                    selectByMouse: true
                    Keys.onReturnPressed: loginSaveMa.clicked(null)
                    Keys.onEnterPressed: loginSaveMa.clicked(null)
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: loginNameField.text.length === 0
                        text: "请输入姓名，如 张三"
                        color: "#55555e"
                        font.pixelSize: 12
                    }
                }
            }

            // 上传服务器地址 / Token：与「上传设置」对话框共用同一份配置
            // （Rating.uploadServerUrl / Rating.uploadToken），首次登录时暂不
            // 展示，避免登录表单过重；已登录后「修改资料」时一并编辑。
            Column {
                width: parent.width
                visible: root._loggedIn
                spacing: 10

                Text {
                    width: parent.width
                    text: "上传服务器地址（可选）"
                    color: "#9a9aa8"
                    font.pixelSize: 11
                }
                Rectangle {
                    width: parent.width
                    height: 34
                    radius: 5
                    color: "#101013"
                    border.color: uploadUrlField.activeFocus ? "#5a8fd8" : "#2c2c32"
                    border.width: 1
                    TextInput {
                        id: uploadUrlField
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        color: "#e8e8ec"
                        font.pixelSize: 13
                        selectByMouse: true
                        Keys.onReturnPressed: loginSaveMa.clicked(null)
                        Keys.onEnterPressed: loginSaveMa.clicked(null)
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: uploadUrlField.text.length === 0
                            text: "http://<host>:<port>/"
                            color: "#55555e"
                            font.pixelSize: 12
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: "Token（可选，服务未启 PLAYERX_TOKEN 时留空）"
                    color: "#9a9aa8"
                    font.pixelSize: 11
                }
                Rectangle {
                    width: parent.width
                    height: 34
                    radius: 5
                    color: "#101013"
                    border.color: uploadTokenField.activeFocus ? "#5a8fd8" : "#2c2c32"
                    border.width: 1
                    TextInput {
                        id: uploadTokenField
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        color: "#e8e8ec"
                        font.pixelSize: 13
                        selectByMouse: true
                        Keys.onReturnPressed: loginSaveMa.clicked(null)
                        Keys.onEnterPressed: loginSaveMa.clicked(null)
                    }
                }
            }

            Item {
                width: parent.width
                height: 32
                // 取消：已登录的编辑态 → 返回个人信息页；未登录 → 关闭
                Rectangle {
                    anchors.right: loginSaveBtn.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 76
                    height: 30
                    radius: 5
                    color: loginCancelMa.containsMouse ? "#33333c" : "#26262c"
                    border.color: "#3a3a45"
                    border.width: 1
                    Text { anchors.centerIn: parent; text: "取消"; color: "#c8c8cc"; font.pixelSize: 12 }
                    MouseArea {
                        id: loginCancelMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root._loggedIn) loginDialog._editing = false
                            else loginDialog.close()
                        }
                    }
                }
                // 登录 / 保存（姓名必填，空则聚焦不提交）
                Rectangle {
                    id: loginSaveBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 76
                    height: 30
                    radius: 5
                    color: loginSaveMa.containsMouse ? "#0db092" : "#0fa085"
                    Text {
                        anchors.centerIn: parent
                        text: root._loggedIn ? "保存" : "登录"
                        color: "#ffffff"
                        font.pixelSize: 12
                        font.bold: true
                    }
                    MouseArea {
                        id: loginSaveMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var v = loginNameField.text.trim()
                            if (v.length === 0) { loginNameField.forceActiveFocus(); return }
                            var firstLogin = !root._loggedIn
                            if (typeof Rating !== "undefined") {
                                Rating.currentUser = v
                                if (root._loggedIn) {
                                    Rating.uploadServerUrl = uploadUrlField.text.trim()
                                    Rating.uploadToken = uploadTokenField.text
                                }
                            }
                            console.log("[Login]", firstLogin ? "登录:" : "评分人更新为:", v)
                            updateToast.text = firstLogin
                                    ? "已登录，欢迎「" + v + "」"
                                    : "评分人已更新为「" + v + "」"
                            updateToast.open()
                            loginDialog.close()
                        }
                    }
                }
            }
        }
    }

    onOpened: {
        _editing = !root._loggedIn
        loginNameField.text = (typeof Rating !== "undefined" && Rating.currentUser)
                              ? Rating.currentUser : ""
        if (_editing) {
            loginNameField.forceActiveFocus()
            loginNameField.selectAll()
        }
    }
    onClosed: _editing = false
}
