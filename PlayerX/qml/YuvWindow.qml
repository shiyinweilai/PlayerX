import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import PlayerX.YuvTools

/**
 * YuvWindow.qml — YUV 裸数据逐帧分析视图（内嵌式 Item）
 *
 * 由 Main.qml 嵌入主内容区使用，不与主播放器联动。提供：
 *   - YUV 文件参数输入（分辨率 / 像素格式 / 帧率）
 *   - Y/U/V 单平面显示模式切换
 *   - 逐帧导航（首帧 / 上一帧 / 下一帧 / 末帧）
 *   - 帧号跳转
 *
 * 通过 closeRequested 信号通知主界面隐藏本视图。
 */

Item {
    id: yuvView

    signal closeRequested()

    // ── 深色背景 ───────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#101012"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // ── 顶部：标题栏 + 返回按钮 ──────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            // 返回主界面按钮
            Rectangle {
                width: 80; height: 32; radius: 6
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
                id: statusText
                text: "YUV 分析工具"
                color: "#e0e0e0"
                font.pixelSize: 18
                font.bold: true
            }

            Item { Layout.fillWidth: true }
        }

        // ── 参数输入行 ────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Text { text: "文件:"; color: "#999"; font.pixelSize: 13 }
            Rectangle {
                Layout.fillWidth: true; height: 32; radius: 6
                color: "#1c1c20"; border.color: "#3a3a3d"; border.width: 1
                TextInput {
                    id: filePathInput
                    anchors.fill: parent; anchors.margins: 6
                    color: "#e0e0e0"; font.pixelSize: 13
                    clip: true; selectByMouse: true
                    text: YuvBridge.filePath || ""
                }
            }
            Rectangle {
                width: 60; height: 32; radius: 6
                color: fileBtnMa.containsMouse ? "#3a3a3d" : "#252528"
                Text {
                    anchors.centerIn: parent
                    text: "浏览"
                    color: "#ccc"; font.pixelSize: 13
                }
                MouseArea {
                    id: fileBtnMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: yuvFileDialog.open()
                }
            }
        }

        RowLayout {
            spacing: 10

            Text { text: "宽:"; color: "#999"; font.pixelSize: 13 }
            Rectangle {
                width: 80; height: 30; radius: 6
                color: "#1c1c20"; border.color: "#3a3a3d"; border.width: 1
                TextInput {
                    id: widthInput
                    anchors.fill: parent; anchors.margins: 4
                    color: "#e0e0e0"; font.pixelSize: 13
                    text: "1920"
                    validator: IntValidator { bottom: 1; top: 16384 }
                    horizontalAlignment: TextInput.AlignHCenter
                }
            }

            Text { text: "高:"; color: "#999"; font.pixelSize: 13 }
            Rectangle {
                width: 80; height: 30; radius: 6
                color: "#1c1c20"; border.color: "#3a3a3d"; border.width: 1
                TextInput {
                    id: heightInput
                    anchors.fill: parent; anchors.margins: 4
                    color: "#e0e0e0"; font.pixelSize: 13
                    text: "1080"
                    validator: IntValidator { bottom: 1; top: 16384 }
                    horizontalAlignment: TextInput.AlignHCenter
                }
            }

            Text { text: "格式:"; color: "#999"; font.pixelSize: 13 }
            ComboBox {
                id: fmtCombo
                width: 110; height: 30
                model: ["yuv420p", "yuv422p", "yuv444p", "nv12", "nv21"]
                currentIndex: 0
                background: Rectangle {
                    color: "#1c1c20"; radius: 6
                    border.color: "#3a3a3d"; border.width: 1
                }
                contentItem: Text {
                    text: fmtCombo.displayText
                    color: "#e0e0e0"; font.pixelSize: 13
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 8
                }
                // 下拉列表深色主题
                delegate: ItemDelegate {
                    width: fmtCombo.width
                    contentItem: Text {
                        text: modelData
                        color: "#e0e0e0"; font.pixelSize: 13
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: highlighted ? "#3a6fd8" : "#1c1c20"
                    }
                }
                popup: Popup {
                    y: fmtCombo.height
                    width: fmtCombo.width
                    padding: 2
                    background: Rectangle {
                        color: "#1c1c20"; radius: 6
                        border.color: "#3a3a3d"; border.width: 1
                    }
                    contentItem: ListView {
                        clip: true
                        implicitHeight: contentHeight
                        model: fmtCombo.popup.visible ? fmtCombo.delegateModel : null
                    }
                }
            }

            Text { text: "帧率:"; color: "#999"; font.pixelSize: 13 }
            Rectangle {
                width: 60; height: 30; radius: 6
                color: "#1c1c20"; border.color: "#3a3a3d"; border.width: 1
                TextInput {
                    id: fpsInput
                    anchors.fill: parent; anchors.margins: 4
                    color: "#e0e0e0"; font.pixelSize: 13
                    text: "30"
                    validator: DoubleValidator { bottom: 0.1; top: 240.0 }
                    horizontalAlignment: TextInput.AlignHCenter
                }
            }

            Item { Layout.fillWidth: true }

            // ── 打开按钮 ──────────────────────────────────────────────
            Rectangle {
                width: 80; height: 32; radius: 6
                color: openBtnMa.containsMouse ? "#4a7cf0" : "#3a6fd8"
                Text {
                    anchors.centerIn: parent
                    text: "打开"
                    color: "#fff"; font.pixelSize: 14; font.bold: true
                }
                MouseArea {
                    id: openBtnMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const w = parseInt(widthInput.text) || 1920
                        const h = parseInt(heightInput.text) || 1080
                        const fmt = fmtCombo.currentText || "yuv420p"
                        const fps = parseFloat(fpsInput.text) || 30.0
                        const path = filePathInput.text.trim()
                        if (!path) {
                            statusText.text = "YUV 分析工具 — 请先选择文件"
                            return
                        }
                        const ok = YuvBridge.openFile(path, w, h, fmt, fps)
                        if (ok) {
                            statusText.text = "YUV 分析工具 — " + path.split('/').pop()
                                        + "  " + w + "x" + h + " " + fmt
                        } else {
                            statusText.text = "YUV 分析工具 — 打开失败"
                        }
                    }
                }
            }
        }

        // ── 信息条 ────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            visible: YuvBridge.hasFile
            spacing: 16

            Text {
                text: "帧: " + (YuvBridge.currentFrame + 1) + " / " + YuvBridge.totalFrames
                color: "#aaa"; font.pixelSize: 13
            }
            Text {
                text: YuvBridge.width + "×" + YuvBridge.height
                color: "#aaa"; font.pixelSize: 13
            }
            Text {
                text: YuvBridge.fmtName + "  " + YuvBridge.fps.toFixed(1) + "fps"
                color: "#aaa"; font.pixelSize: 13
            }
        }

        // ── 显示模式切换 ──────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            visible: YuvBridge.hasFile
            spacing: 6

            Text { text: "显示:"; color: "#999"; font.pixelSize: 13 }

            Repeater {
                model: ["YUV全彩", "Y 仅", "U 仅", "V 仅"]
                Rectangle {
                    width: 72; height: 28; radius: 6
                    color: YuvBridge.displayMode === index
                           ? "#3a6fd8" : "#1c1c20"
                    border.color: YuvBridge.displayMode === index
                                  ? "#4a7cf0" : "#3a3a3d"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: YuvBridge.displayMode === index ? "#fff" : "#999"
                        font.pixelSize: 12
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: YuvBridge.displayMode = index
                    }
                }
            }
        }

        // ── 画面显示区域 ──────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#0a0a0e"
            radius: 8
            border.color: "#2a2a30"
            border.width: 1

            // 未打开时提示
            Text {
                anchors.centerIn: parent
                text: YuvBridge.hasFile ? "" : "选择 YUV 文件并设置参数后点击「打开」"
                color: "#555"
                font.pixelSize: 15
                visible: !YuvBridge.hasFile
            }

            // YUV 画面渲染（QQuickPaintedItem）
            YuvDisplayItem {
                id: yuvDisplay
                anchors.fill: parent
                anchors.margins: 4
                visible: YuvBridge.hasFile
                image: YuvBridge.frameImage
            }
        }

        // ── 底部控制栏 ────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            visible: YuvBridge.hasFile
            spacing: 8

            // 首帧
            Rectangle {
                width: 56; height: 32; radius: 6
                color: navBtnMa1.containsMouse ? "#3a3a3d" : "#252528"
                Text {
                    anchors.centerIn: parent
                    text: "⏮"
                    color: "#ccc"; font.pixelSize: 16
                }
                MouseArea {
                    id: navBtnMa1
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: YuvBridge.firstFrame()
                }
            }

            // 上一帧
            Rectangle {
                width: 56; height: 32; radius: 6
                color: navBtnMa2.containsMouse ? "#3a3a3d" : "#252528"
                Text {
                    anchors.centerIn: parent
                    text: "◀"
                    color: "#ccc"; font.pixelSize: 16
                }
                MouseArea {
                    id: navBtnMa2
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: YuvBridge.prevFrame()
                }
            }

            // 帧号跳转输入
            Text { text: "跳转到:"; color: "#999"; font.pixelSize: 13 }
            Rectangle {
                width: 70; height: 30; radius: 6
                color: "#1c1c20"; border.color: "#3a3a3d"; border.width: 1
                TextInput {
                    id: jumpInput
                    anchors.fill: parent; anchors.margins: 4
                    color: "#e0e0e0"; font.pixelSize: 13
                    horizontalAlignment: TextInput.AlignHCenter
                    validator: IntValidator { bottom: 1 }
                    Keys.onReturnPressed: {
                        const n = parseInt(jumpInput.text)
                        if (n >= 1 && n <= YuvBridge.totalFrames) {
                            YuvBridge.gotoFrame(n - 1)
                        }
                    }
                }
            }
            Rectangle {
                width: 44; height: 30; radius: 6
                color: jumpBtnMa.containsMouse ? "#3a6fd8" : "#2a5fc0"
                Text {
                    anchors.centerIn: parent
                    text: "GO"
                    color: "#fff"; font.pixelSize: 12; font.bold: true
                }
                MouseArea {
                    id: jumpBtnMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const n = parseInt(jumpInput.text)
                        if (n >= 1 && n <= YuvBridge.totalFrames) {
                            YuvBridge.gotoFrame(n - 1)
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            // 下一帧
            Rectangle {
                width: 56; height: 32; radius: 6
                color: navBtnMa3.containsMouse ? "#3a3a3d" : "#252528"
                Text {
                    anchors.centerIn: parent
                    text: "▶"
                    color: "#ccc"; font.pixelSize: 16
                }
                MouseArea {
                    id: navBtnMa3
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: YuvBridge.nextFrame()
                }
            }

            // 末帧
            Rectangle {
                width: 56; height: 32; radius: 6
                color: navBtnMa4.containsMouse ? "#3a3a3d" : "#252528"
                Text {
                    anchors.centerIn: parent
                    text: "⏭"
                    color: "#ccc"; font.pixelSize: 16
                }
                MouseArea {
                    id: navBtnMa4
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: YuvBridge.lastFrame()
                }
            }
        }
    }

    // ── 文件选择对话框 ────────────────────────────────────────────────
    FileDialog {
        id: yuvFileDialog
        title: "选择 YUV 文件"
        fileMode: FileDialog.OpenFile
        nameFilters: [
            "YUV 文件 (*.yuv)",
            "Y4M 文件 (*.y4m)",
            "所有文件 (*)"
        ]
        onAccepted: {
            filePathInput.text = selectedFile.toString().replace("file://", "")
        }
    }

}
