// ShortcutsAboutDialogs.qml — 从 Main.qml 中拆分的快捷键速查对话框 + 关于对话框
// 用法：在 Main.qml 中实例化此组件即可，不需要任何额外属性传递。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX 1.0

Item {
    id: dialogsRoot

    // ── 对外暴露的方法 ──
    function openShortcuts() { shortcutsDialog.open() }
    function openAbout() { aboutDialog.open() }

    // ─── 快捷键速查对话框 ────────────────────────────────────────────
    //   行业标准做法：分组列表（File / Playback / Speed / View / Channel /
    //   MultiGroup），左列按键徽章（等宽字体），右列描述。
    //   修饰键显示用 `_modKey` 自动适配 mac (⌘) / Win·Linux (Ctrl+)。
    //   全部内容与本文件中真实绑定的 Shortcut 一一对应，不做夸张承诺。
    Dialog {
        id: shortcutsDialog
        title: qsTr("快捷键")
        modal: true
        anchors.centerIn: parent
        // 不使用 standardButtons，改为完全自绘 footer，避免 Qt Basic style
        // 给 DialogButtonBox 渲染白底浅色按钮，与对话框深色基调冲突。
        standardButtons: Dialog.NoButton
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        // 用 implicitWidth 让对话框自适应到一个稳定宽度，避免随窗口变化抖动
        implicitWidth: 880
        // 背景：深色面板 + 内描边 + 外阴影（用半透明描边模拟，零依赖）
        background: Rectangle {
            color: "#1e1e22"
            border.color: "#3a3a42"
            border.width: 1
            radius: 8
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -8
                radius: parent.radius + 4
                color: "transparent"
                border.color: "#80000000"
                border.width: 1
                opacity: 0.45
            }
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 2
                color: "transparent"
                border.color: "#a0000000"
                border.width: 1
                opacity: 0.55
            }
        }
        // 自定义标题颜色
        header: Rectangle {
            color: "transparent"
            implicitHeight: 40
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("快捷键")
                color: "#e8e8ec"
                font.pixelSize: 15
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a32"
            }
        }
        // 自定义页脚
        footer: Rectangle {
            color: "transparent"
            implicitHeight: 52
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a32"
            }
            FlatButton {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                Layout.preferredWidth: 88
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("关闭")
                onClicked: shortcutsDialog.close()
            }
        }

        // 内容：两列 GridLayout 横向并列
        contentItem: GridLayout {
            id: scGrid
            columns: 2
            columnSpacing: 28
            rowSpacing: 14

            // 左列 1：播放
            ScSection {
                title: qsTr("播放")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "Space";  desc: qsTr("暂停 / 继续") }
                ScRow { keys: "←  /  →"; desc: qsTr("后退 / 前进 5 秒") }
                ScRow { keys: ",  /  ."; desc: qsTr("上一帧 / 下一帧") }
                ScRow { keys: "R";       desc: qsTr("回到开头") }
            }
            // 右列 1：视图
            ScSection {
                title: qsTr("视图")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "F"; desc: qsTr("切换全屏") }
                ScRow { keys: "V"; desc: qsTr("切换视频信息叠加") }
                ScRow { keys: "C"; desc: qsTr("切换通道/路径信息叠加（播放对比：序号+文件名；YUV：画面内侧路径条）") }
                ScRow { keys: "S"; desc: qsTr("多路视频时切换布局如1xN / 2x2 / 3x3") }
                ScRow { keys: "B"; desc: qsTr("滑动对比模式（播放对比 / YUV 分析，仅 2 路）") }
            }
            // 左列 2：倍速
            ScSection {
                title: qsTr("倍速")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "-";   desc: qsTr("减速一档") }
                ScRow { keys: "=  /  +"; desc: qsTr("加速一档") }
                ScRow { keys: "0";   desc: qsTr("复位为 1.0×") }
            }
            // 右列 2：单路 / 多路
            ScSection {
                title: qsTr("单路 / 多路")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "1 … 9"; desc: qsTr("切到第 N 路单路；再次按下回到上次的多路布局") }
                ScRow { keys: "⤢ / ⤡"; desc: qsTr("放大 / 还原本路（每路 hover 工具栏，等同数字键）") }
                ScRow { keys: "⋯";     desc: qsTr("替换本路视频（hover 显示完整路径）") }
                ScRow { keys: "✕";     desc: qsTr("关闭本路视频") }
            }
            // 左列 3：多组对比
            ScSection {
                title: qsTr("多组对比（仅当多组对比窗口激活时）")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: "Ctrl+↑"; desc: qsTr("上一组 windows是command+↑") }
                ScRow { keys: "Ctrl+↓"; desc: qsTr("下一组 windows是command+↓") }
            }
            // 右列 3：视图缩放 / 平移
            ScSection {
                title: qsTr("视图缩放 / 平移（所有路同步）")
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                ScRow { keys: qsTr("鼠标滚轮");    desc: qsTr("以鼠标位置为锚点缩放（0.2× ~ 8×）") }
                ScRow { keys: qsTr("右键拖拽");    desc: qsTr("同步平移所有路（画面跟随鼠标方向）") }
                ScRow { keys: qsTr("Ctrl+双击");   desc: qsTr("视图复位（缩放/平移归零）") }
                ScRow { keys: "⊙";              desc: qsTr("底部工具栏 视图复位按钮") }
            }
        }
    }

    // 简单的"关于"对话框（深色风格，与全局 UI 一致）
    Dialog {
        id: aboutDialog
        title: qsTr("关于 PlayerX")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.NoButton
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        implicitWidth: 360
        background: Rectangle {
            color: "#1e1e22"
            border.color: "#3a3a42"
            border.width: 1
            radius: 6
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -8
                radius: parent.radius + 4
                color: "transparent"
                border.color: "#80000000"
                border.width: 1
                opacity: 0.45
            }
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 2
                color: "transparent"
                border.color: "#a0000000"
                border.width: 1
                opacity: 0.55
            }
        }
        header: Rectangle {
            color: "transparent"
            implicitHeight: 40
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("关于 PlayerX")
                color: "#e8e8ec"
                font.pixelSize: 15
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a32"
            }
        }
        contentItem: ColumnLayout {
            spacing: 10
            Text {
                text: "PlayerX"
                color: "#e8e8ec"
                font.pixelSize: 18
                font.bold: true
            }
            Text {
                text: qsTr("一款简洁高效的多路视频对比播放器，\n支持最多 9 路同步播放、多组对比与逐帧分析。")
                color: "#c8c8cc"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.3
            }
            Text {
                text: qsTr("版本 %1").arg(Updater.currentVersion)
                color: "#9aa0a6"
                font.pixelSize: 12
            }
            Text {
                text: qsTr("作者 rbyang")
                color: "#9aa0a6"
                font.pixelSize: 12
            }
        }
        footer: Rectangle {
            color: "transparent"
            implicitHeight: 52
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a32"
            }
            FlatButton {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 88
                implicitHeight: 30
                text: qsTr("确定")
                onClicked: aboutDialog.close()
            }
        }
    }
}
