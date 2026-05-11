// Main.qml — PlayerXQt 第 1 阶段最小可用 UI
//
// 功能：
//   - Open 按钮：打开本地视频文件
//   - 居中视频区域（VideoFrameProvider 渲染）
//   - 底部进度条 + 时间显示
//   - 空格：暂停/播放；左右：±5s；逗号/句号：帧步进；F：全屏
//
// UI 故意做得极简，验证内核打通即可。后续会做美化。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import PlayerXQt 1.0

ApplicationWindow {
    id: root
    width: 1280
    height: 800
    visible: true
    title: "PlayerXQt"
    color: "#101012"

    // ─── 工具：把秒数格式化为 HH:MM:SS ───────────────────────────────────
    function fmtTime(sec) {
        if (!isFinite(sec) || sec < 0) sec = 0
        var h = Math.floor(sec / 3600)
        var m = Math.floor((sec % 3600) / 60)
        var s = Math.floor(sec % 60)
        function pad(n) { return n < 10 ? "0" + n : "" + n }
        return (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(s)
    }

    // ─── 文件选择 ────────────────────────────────────────────────────────
    FileDialog {
        id: openDialog
        title: "选择视频文件"
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv)",
            "所有文件 (*)"
        ]
        onAccepted: video.source = selectedFile
    }

    // ─── 顶部工具栏 ──────────────────────────────────────────────────────
    header: ToolBar {
        RowLayout {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 8

            Button {
                text: "打开"
                onClicked: openDialog.open()
            }
            Button {
                text: video.playing ? "暂停" : "播放"
                enabled: video.duration > 0
                onClicked: video.togglePause()
            }
            Button {
                text: "<"
                enabled: video.duration > 0
                ToolTip.text: "上一帧"
                ToolTip.visible: hovered
                onClicked: video.stepFrame(-1)
            }
            Button {
                text: ">"
                enabled: video.duration > 0
                ToolTip.text: "下一帧"
                ToolTip.visible: hovered
                onClicked: video.stepFrame(1)
            }

            Item { Layout.fillWidth: true }

            Label {
                color: "#cfcfd2"
                text: fmtTime(video.position) + " / " + fmtTime(video.duration)
            }
        }
    }

    // ─── 视频区域 ────────────────────────────────────────────────────────
    VideoFrameProvider {
        id: video
        anchors.fill: parent
        anchors.bottomMargin: progressBar.height + 16

        focus: true
        Keys.onPressed: function(event) {
            switch (event.key) {
            case Qt.Key_Space:
                video.togglePause(); event.accepted = true; break
            case Qt.Key_Left:
                video.seek(Math.max(0, video.position - 5)); event.accepted = true; break
            case Qt.Key_Right:
                video.seek(Math.min(video.duration, video.position + 5)); event.accepted = true; break
            case Qt.Key_Comma:
                video.stepFrame(-1); event.accepted = true; break
            case Qt.Key_Period:
                video.stepFrame(1); event.accepted = true; break
            case Qt.Key_F:
                root.visibility = (root.visibility === Window.FullScreen)
                    ? Window.AutomaticVisibility : Window.FullScreen
                event.accepted = true
                break
            }
        }

        // 双击切换暂停（与旧版一致）
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onDoubleClicked: video.togglePause()
            onClicked: video.forceActiveFocus()
        }
    }

    // ─── 占位提示 ────────────────────────────────────────────────────────
    Label {
        anchors.centerIn: parent
        visible: video.duration <= 0
        text: "点击左上角「打开」选择视频"
        color: "#888"
        font.pixelSize: 18
    }

    // ─── 底部进度条 ──────────────────────────────────────────────────────
    Slider {
        id: progressBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 8
        from: 0
        to: Math.max(0.001, video.duration)
        // 拖动时不被 position 反向覆盖
        value: pressed ? value : video.position
        onMoved: video.seek(value)
    }
}
