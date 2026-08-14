import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX.YuvTools

/**
 * YuvWindow.qml — YUV 多窗口渲染子界面
 *
 * 由 Main.qml 在 YUV tab 进入"有文件"状态时通过 Loader 加载。
 * 支持最多 3 个 YUV 文件同时渲染（与 YuvBridge.MaxSlots 一致），
 * 每个 slot 一个独立窗口：显示模式切换 + 画面 + 逐帧导航 + 单独关闭。
 *
 * 所有数据通过 YuvBridge.<method>(slot) 查询，并用 Connections 监听
 * frameChanged/displayModeChanged/slotCountChanged 信号驱动局部刷新。
 */

Item {
    id: yuvView
    signal closeRequested()

    // 跟踪当前打开的 slot 数（驱动 Repeater 重建）；
    // 直接绑定到 YuvBridge.slotCount 属性，自动跟随 slotCountChanged 更新。
    property int openSlotCount: YuvBridge.slotCount

    Rectangle {
        anchors.fill: parent
        color: "#101012"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        // ── 顶部：返回 + 标题 ──────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Rectangle {
                width: 84; height: 32; radius: 6
                color: backBtnMa.containsMouse ? "#3a3a3d" : "#252528"
                Text {
                    anchors.centerIn: parent
                    text: "← 返回"
                    color: "#ccc"; font.pixelSize: 13
                }
                MouseArea {
                    id: backBtnMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: yuvView.closeRequested()
                }
            }

            Text {
                text: "YUV 渲染 · " + yuvView.openSlotCount + " 路"
                color: "#e0e0e0"; font.pixelSize: 17; font.bold: true
            }

            Item { Layout.fillWidth: true }

            Text {
                text: "最多同时 3 路"
                color: "#6a6a78"; font.pixelSize: 12
            }
        }

        // ── 多窗口网格 ─────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 10

            Repeater {
                model: yuvView.openSlotCount
                delegate: Rectangle {
                    id: slotWin
                    required property int index   // slot 索引
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 8
                    color: "#14141a"
                    border.color: "#2c2c34"
                    border.width: 1

                    // 局部刷新版本号：frame/displayMode 变化时 +1，触发绑定重算
                    property int ver: 0
                    Connections {
                        target: YuvBridge
                        function onFrameChanged(slot) {
                            if (slot === slotWin.index) ver++
                        }
                        function onDisplayModeChanged(slot) {
                            if (slot === slotWin.index) ver++
                        }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 6

                        // ── 窗口顶部：文件名 + 关闭 ──
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                Layout.fillWidth: true
                                text: YuvBridge.fileName(slotWin.index)
                                color: "#e0e0e0"; font.pixelSize: 13; font.bold: true
                                elide: Text.ElideMiddle
                            }
                            Rectangle {
                                width: 22; height: 22; radius: 11
                                color: slotCloseMa.containsMouse ? "#b85a5a" : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: "×"; color: "#f5a3a3"; font.pixelSize: 14; font.bold: true
                                }
                                MouseArea {
                                    id: slotCloseMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: YuvBridge.closeFile(slotWin.index)
                                }
                            }
                        }

                        // ── 显示模式 + 信息 ──
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Repeater {
                                model: ["YUV", "Y", "U", "V"]
                                delegate: Rectangle {
                                    required property int index      // 模式索引 0-3
                                    required property string modelData
                                    width: 40; height: 22; radius: 4
                                    color: (YuvBridge.displayMode(slotWin.index) === index)
                                           ? "#3a6fd8" : "#1e1e24"
                                    border.color: "#3a3a44"; border.width: 1
                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData
                                        color: (YuvBridge.displayMode(slotWin.index) === index)
                                               ? "#fff" : "#999"
                                        font.pixelSize: 11
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: YuvBridge.setDisplayMode(slotWin.index, index)
                                    }
                                }
                            }

                            Item { Layout.fillWidth: true }

                            Text {
                                text: {
                                    const _ = ver
                                    return (YuvBridge.currentFrame(slotWin.index) + 1) + "/"
                                           + YuvBridge.totalFrames(slotWin.index)
                                }
                                color: "#9aa0a6"; font.pixelSize: 11
                            }
                        }

                        // ── 画面 ──
                        YuvDisplayItem {
                            id: yuvDisp
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            image: {
                                const _ = ver
                                return YuvBridge.frameImage(slotWin.index)
                            }
                        }

                        // ── 帧导航 ──
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            // 首帧
                            Rectangle {
                                width: 34; height: 26; radius: 4
                                color: navFirstMa.containsMouse ? "#3a3a3d" : "#252528"
                                Text {
                                    anchors.centerIn: parent
                                    text: "⏮"; color: "#ccc"; font.pixelSize: 13
                                }
                                MouseArea {
                                    id: navFirstMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: YuvBridge.firstFrame(slotWin.index)
                                }
                            }
                            // 上一帧
                            Rectangle {
                                width: 34; height: 26; radius: 4
                                color: navPrevMa.containsMouse ? "#3a3a3d" : "#252528"
                                Text {
                                    anchors.centerIn: parent
                                    text: "◀"; color: "#ccc"; font.pixelSize: 13
                                }
                                MouseArea {
                                    id: navPrevMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: YuvBridge.prevFrame(slotWin.index)
                                }
                            }
                            // 跳转输入
                            Rectangle {
                                width: 56; height: 26; radius: 4
                                color: "#1e1e24"; border.color: "#3a3a44"; border.width: 1
                                TextInput {
                                    id: jumpInput
                                    anchors.fill: parent; anchors.margins: 4
                                    color: "#e0e0e0"; font.pixelSize: 11
                                    horizontalAlignment: TextInput.AlignHCenter
                                    validator: IntValidator { bottom: 1 }
                                }
                            }
                            Rectangle {
                                width: 34; height: 26; radius: 4
                                color: jumpGoMa.containsMouse ? "#3a6fd8" : "#2a5fc0"
                                Text {
                                    anchors.centerIn: parent
                                    text: "GO"; color: "#fff"; font.pixelSize: 11; font.bold: true
                                }
                                MouseArea {
                                    id: jumpGoMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const n = parseInt(jumpInput.text)
                                        if (n >= 1 && n <= YuvBridge.totalFrames(slotWin.index)) {
                                            YuvBridge.gotoFrame(slotWin.index, n - 1)
                                        }
                                    }
                                }
                            }

                            Item { Layout.fillWidth: true }

                            // 下一帧
                            Rectangle {
                                width: 34; height: 26; radius: 4
                                color: navNextMa.containsMouse ? "#3a3a3d" : "#252528"
                                Text {
                                    anchors.centerIn: parent
                                    text: "▶"; color: "#ccc"; font.pixelSize: 13
                                }
                                MouseArea {
                                    id: navNextMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: YuvBridge.nextFrame(slotWin.index)
                                }
                            }
                            // 末帧
                            Rectangle {
                                width: 34; height: 26; radius: 4
                                color: navLastMa.containsMouse ? "#3a3a3d" : "#252528"
                                Text {
                                    anchors.centerIn: parent
                                    text: "⏭"; color: "#ccc"; font.pixelSize: 13
                                }
                                MouseArea {
                                    id: navLastMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: YuvBridge.lastFrame(slotWin.index)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
