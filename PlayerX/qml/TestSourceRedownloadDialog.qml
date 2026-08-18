import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0
import "MainLogic.js" as Logic

Dialog {
    id: testSourceRedownloadDialog
    property var root: null
    property var testSourceDownloadDialog: null
    property var testSourceGroupDialog: null
    property var multiGroupDialog: null
    property var updateToast: null

    // 【"重新下载"/"直接开始"点了没反应的根因】本文件此前根本没有
    // `import "MainLogic.js" as Logic`，footer 按钮 onClicked 里的
    // `Logic._tsBeginDownload(...)` / `Logic._tsGateGroup(...)` / `Logic._tsImportAndStart(...)`
    // 直接抛 ReferenceError: Logic is not defined（日志可见）。
    // startNow() 里异常发生在 `d.open()`（弹出"跳过下载，正在导入…" 100% 的下载框）
    // 之后、`d.close()` 之前，于是那个框永远停在"正在导入…"，自动化流程根本没被
    // 触发——表现上就是"点了直接开始/重新下载，卡住不动，只能手动删文件重下才有效"。
    // 这里补上 import，并同 TaskUpdateCard.qml 一样做一次独立模块副本的初始化
    // （MainLogic.js 没有 `.pragma library`，每个 import 它的 QML 文件都有自己
    // 独立的一份模块状态，必须各自 _init 一次，否则 _root/_multiGroupDialog 等
    // 内部变量仍是初始的空值）。
    Component.onCompleted: {
        Logic._init({
            root: root,
            updateToast: updateToast,
            testSourceDownloadDialog: testSourceDownloadDialog,
            testSourceGroupDialog: testSourceGroupDialog,
            testSourceRedownloadDialog: testSourceRedownloadDialog,
            multiGroupDialog: multiGroupDialog,
            dimReloadTimer: null,
            ratingsDialog: null,
            ratingToast: null
        })
        console.log("[TestSource] TestSourceRedownloadDialog 自身的 MainLogic.js 模块副本已初始化，重新下载/直接开始应可正常工作")
    }
    modal: true
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    implicitWidth: 560

    property var _pending: null
    property int _countdown: 0
    // 自动跳过时长（秒）
    readonly property int autoSkipSeconds: 5

    function openWith(data) {
        _pending = data
        _countdown = autoSkipSeconds
        tsRedlSkipTimer.restart()
        cdPulse.restart()
        open()
    }
    onOpened: {
        // 进度条需在布局完成后才有宽度：打开后再启动平滑缩减动画
        cdProgressAnim.from = cdProgress.parent.width
        cdProgressAnim.restart()
    }
    onClosed: {
        tsRedlSkipTimer.stop()
        cdPulse.stop()
        cdProgressAnim.stop()
    }

    // 「直接开始」的实际动作（按钮点击与倒计时归零共用）
    function startNow() {
        tsRedlSkipTimer.stop()
        close()
        var st = _pending
        if (!st) return
        console.log("[TestSource] 跳过下载，直接导入:", st.fileName)
        var d = testSourceDownloadDialog
        d._url        = ""
        d._fileName   = st.fileName
        d._configName = st.configName
        d._savePath   = st.zipPath
        d._progress   = 1.0
        d._status     = "downloading"
        d._statusText = "跳过下载，正在导入…"
        d.open()
        var _stObj = { ts: st.ts, configName: st.configName,
                       zipPath: st.zipPath, extractTarget: st.extractTarget }
        // 组别门：跳过下载同样可能遇到多组别包，先弹窗选组
        if (Logic._tsGateGroup(_stObj, st.extractTarget)) { d.close(); return }
        var err = Logic._tsImportAndStart(_stObj, st.extractTarget)
        if (err.length > 0) {
            d._status = "error"
            d._statusText = err
            return
        }
        // 跳过下载成功：同样静默关闭（直接进入打分界面）
        d.close()
    }

    // 倒计时：每秒 -1，归零自动「直接开始」
    Timer {
        id: tsRedlSkipTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (testSourceRedownloadDialog._countdown <= 1) {
                testSourceRedownloadDialog.startNow()
            } else {
                testSourceRedownloadDialog._countdown -= 1
            }
        }
    }

    Overlay.modal: Rectangle { color: "#aa000000" }

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 6
        Rectangle { z: -1; anchors.fill: parent; anchors.margins: -8; radius: parent.radius + 4; color: "transparent"; border.color: "#80000000"; border.width: 1; opacity: 0.45 }
        Rectangle { z: -1; anchors.fill: parent; anchors.margins: -4; radius: parent.radius + 2; color: "transparent"; border.color: "#a0000000"; border.width: 1; opacity: 0.55 }
    }

    header: Rectangle {
        color: "#26e8b339"          // 琥珀 15% 底，与倒计时卡片同色系
        implicitHeight: 48
        // 左侧琥珀强调条：让"已下载过"这个关键状态一眼可辨
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 4
            color: "#e8b339"
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            text: "📦 " + qsTr("测试源已下载过")
            color: "#f5b83d"          // 琥珀强调色（重点信息）
            font.pixelSize: 18
            font.bold: true
        }
        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: "#66e8b339" }
    }

    contentItem: ColumnLayout {
        spacing: 14
        Text {
            Layout.fillWidth: true
            text: testSourceRedownloadDialog._pending
                  ? qsTr("「%1」此前已下载并解压完成，配置未变化。\n可直接开始（跳过下载）；若服务端内容已更新，请选「重新下载」。")
                    .arg(testSourceRedownloadDialog._pending.fileName)
                  : ""
            color: "#c8c8cc"
            font.pixelSize: 15
            wrapMode: Text.WordWrap
            lineHeight: 1.35
        }
        Text {
            Layout.fillWidth: true
            visible: testSourceRedownloadDialog._pending !== null
            text: testSourceRedownloadDialog._pending ? testSourceRedownloadDialog._pending.zipPath : ""
            color: "#7a7a84"
            font.pixelSize: 12
            elide: Text.ElideMiddle
        }

        // ── 动态倒计时提醒：大号跳秒（脉冲缩放）+ 平滑缩减进度条 ──
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 74
            radius: 8
            color: "#26e8b339"          // 琥珀色 15% 底
            border.color: "#66e8b339"
            border.width: 1

            Row {
                anchors.centerIn: parent
                spacing: 12
                Text {
                    id: cdNum
                    text: testSourceRedownloadDialog._countdown
                    color: "#e8b339"
                    font.pixelSize: 34
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: qsTr("秒后将自动「直接开始」\n需要更新内容请点「重新下载」")
                    color: "#e8c98a"
                    font.pixelSize: 14
                    lineHeight: 1.25
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // 底部进度条：autoSkipSeconds 秒内从满格平滑缩减到 0
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 1
                height: 4
                radius: 2
                color: "transparent"
                clip: true
                Rectangle {
                    id: cdProgress
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    color: "#e8b339"
                    width: 0
                }
            }
        }

        // 大号秒数脉冲动画（随倒计时循环）
        SequentialAnimation {
            id: cdPulse
            loops: Animation.Infinite
            NumberAnimation { target: cdNum; property: "scale"; to: 1.25; duration: 140; easing.type: Easing.OutCubic }
            NumberAnimation { target: cdNum; property: "scale"; to: 1.0;  duration: 160; easing.type: Easing.InCubic }
            PauseAnimation { duration: 700 }
        }
        // 进度条平滑缩减动画（时长 = 倒计时总秒数）
        NumberAnimation {
            id: cdProgressAnim
            target: cdProgress
            property: "width"
            to: 0
            duration: testSourceRedownloadDialog.autoSkipSeconds * 1000
        }
    }

    footer: Rectangle {
        color: "transparent"
        implicitHeight: 64
        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: "#2a2a32" }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.topMargin: 14
            anchors.bottomMargin: 14
            spacing: 10
            Item { Layout.fillWidth: true }
            FlatButton {
                implicitWidth: 88
                implicitHeight: 34
                text: qsTr("取消")
                font.pixelSize: 14
                onClicked: testSourceRedownloadDialog.close()
            }
            FlatButton {
                implicitWidth: 108
                implicitHeight: 34
                text: qsTr("重新下载")
                textColor: "#e8b339"
                font.pixelSize: 14
                onClicked: {
                    testSourceRedownloadDialog.close()
                    var st = testSourceRedownloadDialog._pending
                    if (!st) return
                    console.log("[TestSource] 用户选择强制重新下载:", st.fileName)
                    Logic._tsBeginDownload(st.ts, st.configName, st.fileName, st.zipPath, st.extractTarget)
                }
            }
            FlatButton {
                implicitWidth: 124
                implicitHeight: 34
                text: qsTr("直接开始 (%1s)").arg(testSourceRedownloadDialog._countdown)
                textColor: "#3fb950"   // 推荐动作 → 绿色文字
                font.pixelSize: 14
                onClicked: testSourceRedownloadDialog.startNow()
            }
        }
    }
}
