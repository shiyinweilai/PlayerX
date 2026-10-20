// ─── 教程视频面板（播放对比页空态 · 公告/教学区） ─────────────────────
// 设计参考专业视频软件（Premiere / DaVinci Resolve 的"学习"面板）：
//   · 未打开视频时，主空态区显示一个自动播放的教程视频渲染窗口；
//   · 视频静音、循环播放，不抢焦点、不接收快捷键；
//   · 视频文件不存在时优雅回退为标题 + 提示文案（不报错）。
// 视频源：应用资源目录下 tutorials/tutorial.mp4（qrc 不可流式 seek 的场景
// 也满足循环播放；若后续要换网络教程可改 source 为 url）。
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia

Rectangle {
    id: root
    color: "#101014"
    radius: 10
    border.color: "#2a2a32"
    border.width: 1

    // 教程视频路径：默认打包资源；可在外部覆盖（如未来在线教程 url）
    property string tutorialSource: ""

    MediaPlayer {
        id: tutorialPlayer
        source: root.tutorialSource
        playbackRate: 1.0
        loops: MediaPlayer.Infinite
        audioOutput: AudioOutput { muted: true }
        videoOutput: tutorialOutput
        // 资源就绪后自动播放；出错静默降级（显示占位文案）
        onMediaStatusChanged: {
            if (tutorialPlayer.mediaStatus === MediaPlayer.LoadedMedia
                    || tutorialPlayer.mediaStatus === MediaPlayer.BufferedMedia)
                tutorialPlayer.play()
        }
        onErrorOccurred: function(error, errorString) {
            console.warn("[TutorialVideo] 播放失败:", error, errorString)
            fallbackItem.visible = true
            videoHost.visible = false
        }
    }

    VideoOutput {
        id: tutorialOutput
        anchors.fill: parent
        visible: false
        // 初始隐藏，加载成功后再显示
        Component.onCompleted: visible = Qt.binding(function() {
            return tutorialPlayer.mediaStatus === MediaPlayer.LoadedMedia
                    || tutorialPlayer.mediaStatus === MediaPlayer.BufferedMedia
        })
    }

    // 加载成功前的视频宿主（撑布局）
    Item { id: videoHost; anchors.fill: parent }

    // 回退占位：视频缺失 / 加载失败
    ColumnLayout {
        id: fallbackItem
        anchors.centerIn: parent
        spacing: 8
        visible: !tutorialOutput.visible
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "🎬"
            font.pixelSize: 40
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "软件操作教程"
            color: "#e8e8ec"
            font.pixelSize: 16
            font.bold: true
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "教程视频准备中（放置 tutorials/tutorial.mp4 即可自动播放）"
            color: "#7a7f86"
            font.pixelSize: 12
        }
    }

    // 左上角标题角标（类似专业软件"学习"标签）
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 10
        width: tutorLabel.implicitWidth + 16
        height: 22
        radius: 4
        color: "#cc1a1a20"
        border.color: "#33ffffff"
        visible: tutorialOutput.visible
        Text {
            id: tutorLabel
            anchors.centerIn: parent
            text: "操作教程"
            color: "#cfd2d6"
            font.pixelSize: 11
        }
    }
}
