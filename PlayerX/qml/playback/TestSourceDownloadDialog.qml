import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Popup {
    id: testSourceDownloadDialog
    property var root: null
    modal: true
    anchors.centerIn: parent
    closePolicy: Popup.NoAutoClose
    implicitWidth: 380
    implicitHeight: contentCol.implicitHeight + 48

    // 内部状态
    property string _url: ""
    property string _fileName: ""
    property string _configName: ""
    property string _savePath: ""       // 最终保存路径（下载完成后设置）
    property string _status: "idle"     // idle | downloading | done | error
    property string _statusText: ""
    property real   _progress: 0        // 0.0 ~ 1.0

    // 监听 C++ Downloader 信号
    Connections {
        target: (typeof Downloader !== "undefined") ? Downloader : null
        function onProgress(ratio, received, total) {
            if (testSourceDownloadDialog._status !== "downloading") return
            if (ratio >= 0)
                testSourceDownloadDialog._progress = ratio
            // 显示已下载大小
            var mb = (received / 1048576).toFixed(1)
            var totalMb = total > 0 ? " / " + (total / 1048576).toFixed(1) + " MB" : ""
            testSourceDownloadDialog._statusText = "正在下载… " + mb + totalMb + " MB"
        }
        function onFinished(ok, savePath, errorMsg) {
            // 自动化流水线（root._tsAuto 非空）由 root 侧的 Connections 接管后续状态
            //（解压 → 导入 → 启动），这里直接让路，避免状态文本互相覆盖。
            if (root._tsAuto) return
            if (testSourceDownloadDialog._status !== "downloading") return
            if (ok) {
                testSourceDownloadDialog._savePath   = savePath
                testSourceDownloadDialog._progress   = 1.0
                testSourceDownloadDialog._status     = "done"
                testSourceDownloadDialog._statusText = "下载完成，已保存到 Downloads 目录"
            } else {
                testSourceDownloadDialog._status     = "error"
                testSourceDownloadDialog._statusText = errorMsg.length > 0 ? errorMsg : "下载失败"
            }
        }
    }

    // 弹窗仅作进度/状态展示；下载由 root 的测试源自动化流水线直接驱动
    //（需要尊重 testSource.workDir 配置，不走固定的 ~/Downloads）。
    Overlay.modal: Rectangle { color: "#aa000000" }

    background: Rectangle {
        color: "#1e1e22"
        border.color: "#3a3a42"
        border.width: 1
        radius: 8
    }

    Column {
        id: contentCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 24 }
        spacing: 14

        // 标题
        Text {
            text: "📦 下载测试源"
            color: "#e8e8ec"
            font.pixelSize: 15
            font.bold: true
        }

        // 配置名
        Text {
            text: testSourceDownloadDialog._configName ? ("配置：" + testSourceDownloadDialog._configName) : ""
            color: "#9aa0a6"
            font.pixelSize: 12
            visible: testSourceDownloadDialog._configName.length > 0
        }

        // 文件名
        Text {
            text: "文件：" + testSourceDownloadDialog._fileName
            color: "#9aa0a6"
            font.pixelSize: 12
            elide: Text.ElideMiddle
            width: parent.width
        }

        // 状态文字
        Text {
            text: testSourceDownloadDialog._statusText
            color: testSourceDownloadDialog._status === "error" ? "#f5222d"
                 : testSourceDownloadDialog._status === "done"  ? "#52c41a"
                 : "#e8e8ec"
            font.pixelSize: 13
            wrapMode: Text.WordWrap
            width: parent.width
        }

        // 进度条（下载中显示）：胶囊式 —— 深色底 + 极光渐变填充 + 前沿辉光，
        // 左侧静态标签、右侧大号百分比（参考"画境观屿"生成进度胶囊样式）。
        Rectangle {
            id: tsProgressCapsule
            width: parent.width
            height: 30
            radius: height / 2
            color: "#0b0b10"
            border.color: "#2e2e3a"
            border.width: 1
            visible: testSourceDownloadDialog._status === "downloading"

            // ── 填充层：横向渐变（深海蓝 → 青 → 薄荷绿），圆角随胶囊 ──
            Rectangle {
                id: tsProgressFill
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height - 4
                // 宽度最小保持一个圆头，0% 时隐藏避免露出小圆点
                width: Math.max(parent.height - 4,
                                (parent.width - 4) * testSourceDownloadDialog._progress)
                visible: testSourceDownloadDialog._progress > 0.005
                radius: height / 2
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.00; color: "#16213e" }
                    GradientStop { position: 0.55; color: "#14506e" }
                    GradientStop { position: 0.85; color: "#1b9e8f" }
                    GradientStop { position: 1.00; color: "#4ef0c0" }
                }
                Behavior on width { NumberAnimation { duration: 120 } }

                // ── 前沿辉光（两层叠：宽软光晕 + 窄亮芯，模拟极光边缘）──
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: -2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 42; height: parent.height - 10
                    radius: width / 2
                    opacity: 0.35
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: "#7fffd4" }
                    }
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14; height: parent.height - 16
                    radius: width / 2
                    opacity: 0.9
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: "#d8fff2" }
                    }
                }
            }

            // ── 文字层（压在填充层之上）──
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                text: "测试源下载中"
                color: "#cfe8e0"
                font.pixelSize: 11
                font.bold: true
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                text: Math.round(testSourceDownloadDialog._progress * 100) + "%"
                color: "#ffffff"
                font.pixelSize: 15
                font.bold: true
            }
        }

        // 底部按钮
        Row {
            spacing: 8
            anchors.right: parent.right

            // 打开文件夹按钮（下载完成后显示）
            // 关闭按钮
            Rectangle {
                width: 72; height: 28; radius: 4
                color: closeMouse2.containsMouse ? "#3a3a44" : "#2a2a34"
                border.color: "#44ffffff"; border.width: 1
                Text { anchors.centerIn: parent; text: "关闭"; color: "#aaaabc"; font.pixelSize: 12 }
                MouseArea {
                    id: closeMouse2
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: testSourceDownloadDialog.close()
                }
            }
        }

        Item { height: 4; width: 1 }
    }
}
