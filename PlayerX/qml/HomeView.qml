// HomeView.qml — 首页视图（码流占位段已迁移到独立 StreamView.qml）
// 用法：在 Main.qml 中实例化，外部设置 anchors 和 visible。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX 1.0

Item {
    id: homeViewRoot

    // ── 外部接口 ──
    property string currentTab: "home"
    signal requestOpenFile()
    signal requestMultiGroup()
    signal switchTab(string tab)

    // ══════════════ 首页视图 ══════════════
    Item {
        id: homeView
        anchors.fill: parent
        visible: homeViewRoot.currentTab === "home"

        Rectangle {
            anchors.fill: parent
            color: "#101012"
        }

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 26
            width: Math.min(parent.width - 100, 680)

            // ── 标题组 ──
            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 10
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 2
                    Text { text: "Player"; color: "#f4f6fa"; font.pixelSize: 40; font.bold: true }
                    Text { text: "X"; color: "#3b8ef2"; font.pixelSize: 40; font.bold: true }
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "视频播放对比 · 同步播放 · 评分采集 · 码流分析"
                    color: "#9aa0a6"
                    font.pixelSize: 14
                }
            }

            // ── 功能入口卡片（点击跳转到对应 Tab）──
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 16

                // 播放对比
                Rectangle {
                    Layout.preferredWidth: 190
                    Layout.preferredHeight: 120
                    radius: 10
                    color: homeCardPlayMA.containsMouse ? "#2a3a55" : "#1e1e24"
                    border.color: homeCardPlayMA.containsMouse ? "#3a78c8" : "#3a3a44"
                    border.width: 1
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        Text { Layout.alignment: Qt.AlignHCenter; text: "🎬"; font.pixelSize: 34 }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "播放对比"; color: "#e8e8ec"; font.pixelSize: 15; font.bold: true }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "多路视频同步播放"; color: "#9aa0a6"; font.pixelSize: 12 }
                    }
                    MouseArea {
                        id: homeCardPlayMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: homeViewRoot.switchTab("play")
                    }
                }

                // YUV 分析
                Rectangle {
                    Layout.preferredWidth: 190
                    Layout.preferredHeight: 120
                    radius: 10
                    color: homeCardYuvMA.containsMouse ? "#2a3a55" : "#1e1e24"
                    border.color: homeCardYuvMA.containsMouse ? "#3a78c8" : "#3a3a44"
                    border.width: 1
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        Text { Layout.alignment: Qt.AlignHCenter; text: "🎞"; font.pixelSize: 34 }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "YUV 分析"; color: "#e8e8ec"; font.pixelSize: 15; font.bold: true }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "裸数据逐帧查看"; color: "#9aa0a6"; font.pixelSize: 12 }
                    }
                    MouseArea {
                        id: homeCardYuvMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: homeViewRoot.switchTab("yuv")
                    }
                }

                // 码流分析
                Rectangle {
                    Layout.preferredWidth: 190
                    Layout.preferredHeight: 120
                    radius: 10
                    color: homeCardStreamMA.containsMouse ? "#2a3a55" : "#1e1e24"
                    border.color: homeCardStreamMA.containsMouse ? "#3a78c8" : "#3a3a44"
                    border.width: 1
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        Text { Layout.alignment: Qt.AlignHCenter; text: "📡"; font.pixelSize: 34 }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "码流分析"; color: "#e8e8ec"; font.pixelSize: 15; font.bold: true }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "裸码流解析（开发中）"; color: "#9aa0a6"; font.pixelSize: 12 }
                    }
                    MouseArea {
                        id: homeCardStreamMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: homeViewRoot.switchTab("stream")
                    }
                }
            }

            // ── 快速打开 ──
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 16

                Rectangle {
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: 40
                    radius: 8
                    color: homeOpenFileMA.containsMouse ? "#3a6fd8" : "#2a5fc0"
                    Text {
                        anchors.centerIn: parent
                        text: "打开文件"
                        color: "#fff"
                        font.pixelSize: 14
                        font.bold: true
                    }
                    MouseArea {
                        id: homeOpenFileMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: homeViewRoot.requestOpenFile()
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: 40
                    radius: 8
                    color: homeOpenFolderMA.containsMouse ? "#3a3a46" : "#2a2a32"
                    border.color: "#4a4a56"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "打开文件夹"
                        color: "#e8e8ec"
                        font.pixelSize: 14
                    }
                    MouseArea {
                        id: homeOpenFolderMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: homeViewRoot.requestMultiGroup()
                    }
                }
            }
        }
    }

    // ══════════════ 码流分析视图（迁移至独立 StreamView.qml） ══════════════
    // 本组件在 Main.qml 中与 homeView 平行；homeViewRoot 仍保留 currentTab
    // 路由，但 streamView 的实际渲染由 main.qml 直接装载 StreamView.qml。
    // 这里仅保留一个空 Item 占位，避免破坏 currentTab 逻辑；实际显示由
    // main.qml 内部的 streamView 节点负责（见 Main.qml）。
}
