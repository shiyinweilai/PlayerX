import QtQuick
import QtQuick.Layouts

// ─── 视频信息面板（可复用面板块）──────────────────────────────────
// 作用：在独立的"右键浮层 / 右侧栏 / 任何容器"里展示当前 player 的视频元信息
//   · 编解码 / 分辨率 / FPS / 帧类型 / 像素格式 / 色彩空间 / 色彩范围 / 解码器 / 硬件加速
// 设计要点：
//   · playerIdx 是可绑定属性（prop）：调用方控制当前显示哪个 player 的信息
//   · 内部以 Engine.videoInfoAt(playerIdx) 实时拉取，positionChanged 时自动刷新
//   · 显示"右键关闭"底部提示文字可通过 property bool showCloseHint=false 关闭
//   · 不依赖任何外部 cell/cellBar/选中态，单独使用即工作
Item {
    id: root

    // 当前显示哪一路 player 的信息。调用方控制（外部激活 / 当前 activeIndex / 用户选择）
    property int  playerIdx: 0
    // 标题文字（默认"视频信息"，右侧栏/浮层可根据场景定制）
    property string title: qsTr("视频信息")
    // 显示右上角的"关闭提示"——浮层保留，右侧栏隐藏
    property bool showCloseHint: false
    // 是否显示底部文件名（需要调用方提供 filePath）
    property bool showFileName: true
    property string filePath: ""
    // 是否显示"信息体"（true 时显示全部行；false 时仅显示标题/空状态）
    property bool hasContent: true

    // 实时刷新：positionChanged 时刷新（与 VideoCellDelegate.infoPanel 行为一致）
    property var info: ({})
    function refreshInfo() {
        if (playerIdx < 0) { info = ({}); return }
        try { info = Engine.videoInfoAt(playerIdx) } catch (e) { info = ({}) }
    }
    Connections {
        target: Engine
        function onPositionChanged() { root.refreshInfo() }
        function onFileCountChanged() { root.refreshInfo() }
    }
    onPlayerIdxChanged: refreshInfo()
    Component.onCompleted: refreshInfo()

    // 单行渲染（label: value，右对齐 label 左对齐 value）
    component InfoRow: RowLayout {
        id: infoRow
        property string label: ""
        property string value: ""
        spacing: 6
        Text {
            text: infoRow.label + ":"
            color: "#9a9aa8"
            font.pixelSize: 11
            Layout.minimumWidth: 52
        }
        Text {
            text: infoRow.value
            color: "#e8e8ec"
            font.pixelSize: 11
            font.family: "Menlo, Monaco, Courier New, monospace"
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 4

        // 标题行
        Text {
            text: root.title
            color: "#ffffff"
            font.pixelSize: 13
            font.bold: true
            opacity: 0.95
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: "#33ffffff"
            Layout.rightMargin: 0
        }

        // 文件名（仅在提供且非空时显示）
        Text {
            visible: root.showFileName && root.filePath.length > 0
            Layout.fillWidth: true
            text: root.filePath
            color: "#c8c8d0"
            font.pixelSize: 10
            font.family: "Menlo, Monaco, Courier New, monospace"
            elide: Text.ElideMiddle
            wrapMode: Text.NoWrap
            Layout.bottomMargin: 2
        }

        // 信息行：仅在 hasContent=true 时显示全部
        Item {
            visible: root.hasContent && Engine.fileCount > 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: 3

                InfoRow {
                    label: qsTr("编解码")
                    value: {
                        var name = (root.info.codec || "—").toUpperCase()
                        var tag  = root.info.codecTag || ""
                        return tag ? name + " (" + tag + ")" : name
                    }
                }
                InfoRow {
                    label: qsTr("分辨率")
                    value: (root.info.width && root.info.height)
                           ? (root.info.width + " × " + root.info.height)
                           : "—"
                }
                InfoRow {
                    label: qsTr("FPS")
                    value: root.info.fps
                           ? root.info.fps.toFixed(3)
                           : "—"
                }
                InfoRow {
                    label: qsTr("帧类型")
                    value: root.info.frameType || "—"
                }
                InfoRow {
                    label: qsTr("像素格式")
                    value: root.info.pixFmt || "—"
                }
                InfoRow {
                    label: qsTr("色彩空间")
                    value: root.info.colorSpace || "—"
                }
                InfoRow {
                    label: qsTr("色彩范围")
                    value: root.info.colorRange || "—"
                }
                InfoRow {
                    label: qsTr("解码器")
                    value: root.info.decoder || "—"
                }
                InfoRow {
                    label: qsTr("硬件加速")
                    value: root.info.hwAccel === undefined
                           ? "—"
                           : (root.info.hwAccel ? "是 (VideoToolbox)" : "否")
                }
            }
        }

        // 空状态：fileCount=0 时给出占位文案
        Item {
            visible: !root.hasContent || Engine.fileCount <= 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            Column {
                anchors.centerIn: parent
                spacing: 4
                Text {
                    text: qsTr("暂无视频")
                    color: "#7a7f86"
                    font.pixelSize: 12
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: qsTr("打开文件 / 拖入视频后此处显示信息")
                    color: "#555560"
                    font.pixelSize: 10
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }

        // 底部提示（仅浮层模式开启）
        Text {
            visible: root.showCloseHint
            text: qsTr("右键关闭")
            color: "#555560"
            font.pixelSize: 10
            Layout.topMargin: 4
        }
    }
}