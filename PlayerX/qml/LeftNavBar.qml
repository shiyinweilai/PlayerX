import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Rectangle {
    id: leftNavBar
    property var root: null
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: root.immersive ? 0 : 184
    color: "#141419"
    z: 200
    // 沉浸模式：播放有视频 / YUV render 阶段时隐藏整个侧栏，最大化工作区。
    visible: !root.immersive

    // 右侧 1px 分隔线
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: "#26262e"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── 顶部品牌区 ──
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 22
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text { text: "Player"; color: "#f4f6fa"; font.pixelSize: 20; font.bold: true }
                Text { text: "X"; color: "#3b8ef2"; font.pixelSize: 20; font.bold: true }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: "#26262e" }

        // ── 4 个导航 Tab ──
        Repeater {
            model: [
                { key: "home",   label: "首页" },
                { key: "play",   label: "播放对比" },
                { key: "yuv",    label: "YUV 分析" },
                { key: "stream", label: "码流分析" }
            ]
            delegate: Rectangle {
                id: navItem
                required property string key
                required property string label
                readonly property bool active: root.currentTab === navItem.key
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                color: navItemMA.containsMouse ? "#22222c" : (navItem.active ? "#1c2536" : "transparent")

                // 选中指示条
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 3
                    color: navItem.active ? "#3b8ef2" : "transparent"
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14

                    // 自绘矢量图标
                    Canvas {
                        width: 20; height: 20
                        anchors.verticalCenter: parent.verticalCenter
                        property color iconColor: navItem.active ? "#6ba3f7" : "#787884"
                        onIconColorChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            ctx.lineWidth = 1.6
                            ctx.strokeStyle = iconColor
                            ctx.fillStyle = iconColor
                            ctx.lineCap = "round"
                            ctx.lineJoin = "round"

                            if (navItem.key === "home") {
                                // 房子图标：尖顶 + 方形主体
                                ctx.beginPath()
                                ctx.moveTo(10, 2.5)
                                ctx.lineTo(3, 9)
                                ctx.lineTo(5, 9)
                                ctx.lineTo(5, 17)
                                ctx.lineTo(8.5, 17)
                                ctx.lineTo(8.5, 12.5)
                                ctx.lineTo(11.5, 12.5)
                                ctx.lineTo(11.5, 17)
                                ctx.lineTo(15, 17)
                                ctx.lineTo(15, 9)
                                ctx.lineTo(17, 9)
                                ctx.closePath()
                                ctx.stroke()
                            } else if (navItem.key === "play") {
                                // 双窗对比图标：两个并排矩形
                                ctx.strokeRect(2, 3.5, 7, 13)
                                ctx.strokeRect(11, 3.5, 7, 13)
                                // 左窗播放三角
                                ctx.beginPath()
                                ctx.moveTo(4.5, 8)
                                ctx.lineTo(4.5, 12.5)
                                ctx.lineTo(7.5, 10.25)
                                ctx.closePath()
                                ctx.fill()
                                // 右窗播放三角
                                ctx.beginPath()
                                ctx.moveTo(13.5, 8)
                                ctx.lineTo(13.5, 12.5)
                                ctx.lineTo(16.5, 10.25)
                                ctx.closePath()
                                ctx.fill()
                            } else if (navItem.key === "yuv") {
                                // 胶片帧图标：方形+齿孔
                                ctx.strokeRect(3, 3, 14, 14)
                                // 上排齿孔
                                ctx.fillRect(5, 3, 2, 2.5)
                                ctx.fillRect(9, 3, 2, 2.5)
                                ctx.fillRect(13, 3, 2, 2.5)
                                // 下排齿孔
                                ctx.fillRect(5, 14.5, 2, 2.5)
                                ctx.fillRect(9, 14.5, 2, 2.5)
                                ctx.fillRect(13, 14.5, 2, 2.5)
                                // 内画面
                                ctx.strokeRect(5.5, 7, 9, 6)
                            } else if (navItem.key === "stream") {
                                // 波形/信号图标：三条弧线 + 圆点
                                ctx.beginPath()
                                ctx.arc(6, 10, 2, 0, Math.PI * 2)
                                ctx.fill()
                                ctx.beginPath()
                                ctx.arc(6, 10, 5, -0.8, 0.8)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.arc(6, 10, 8, -0.7, 0.7)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.arc(6, 10, 11, -0.6, 0.6)
                                ctx.stroke()
                            }
                        }
                    }

                    Text {
                        text: navItem.label
                        color: navItem.active ? "#ffffff" : "#a8a8b2"
                        font.pixelSize: 14
                        font.bold: navItem.active
                    }
                }

                MouseArea {
                    id: navItemMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.currentTab = navItem.key
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
