// RefSidebarSlot.qml — 参考图侧边栏「单窗口」组件（从 RefSidebar.qml 拆出）
//
// 设计目标：把原上下两个固定窗口（槽位 1/2）拆成可复用的单窗口组件，
// 供 RefSidebar 在纵向 Flickable 中按槽位数实例化 N 份（1..9）。
// 每个窗口独立：绑定（图片/文件夹/分组多图）、翻图偏移、清除、放大查看。
//
// 对外接口（全部由 RefSidebar 动态绑定）：
//   property var root          — 主窗（取 refCurrentFolder / 视频等全局态）
//   property int slot          — 本窗口的槽位号（1 起始，用于数字角标与 Reference.*At API）
//   property url  currentUrl   — 当前显示图（Main 层按槽位算好传入）
//   property bool hasCurrent   — 是否有可显示图
//   property string mode       — "image" / "folder" / "grouped" / ""
//   property int   imageCount  — folder/grouped 模式下总数
//   property string progressText — "N / M" 进度文本
//   property var fileDlg / dirDlg / groupedDlg — 三个文件对话框（动态槽位版）
//   property var refLightbox   — 放大查看 Lightbox
//   signal bumpOffset(int delta) — ◀▶ 翻图（RefSidebar 转发给 Main 层对应槽位偏移）
//   signal requestClear()      — ✕ 清除（RefSidebar 转发给 Reference.clearReferenceAt）

import QtQuick
import QtQuick.Controls
import PlayerX 1.0

Rectangle {
    id: slotPane
    property var root: null
    property int slot: 1
    property url currentUrl: ""
    property bool hasCurrent: false
    property string mode: ""
    property int imageCount: 0
    property string progressText: ""
    property var fileDlg: null
    property var dirDlg: null
    property var groupedDlg: null
    property var refLightbox: null
    signal bumpOffset(int delta)
    signal requestClear()

    // 是否可翻页（folder / grouped 模式）
    readonly property bool canNav: (mode === "folder" || mode === "grouped")

    // 高度由外部 ListView/Flickable 分配；宽度自适应
    color: "transparent"

    // 数字角标：左上角仅显示数字（无外框无圆圈）
    Text {
        id: slotBadge
        z: 5
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: 6
        anchors.topMargin: 4
        text: String(slotPane.slot)
        color: slotPane.hasCurrent ? "#7ec8ff" : "#8a8a95"
        font.pixelSize: 11
        font.bold: true
        style: Text.Outline
        styleColor: "#000000"
    }

    // 中央图片区 + 拖拽接收 + 占位提示
    Rectangle {
        id: slotImageBox
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: 0
        color: "#0e0e10"
        border.color: slotDrop.containsDrag ? "#5a8fd8" : "#2c2c32"
        border.width: 1
        radius: 4

        // 实际图片（与原 refImage 策略一致：固定 1024 解码上限 + Loading 续显旧图）
        Image {
            id: slotImage
            anchors.fill: parent
            anchors.margins: 4
            source: slotPane.currentUrl
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            cache: true
            sourceSize.width:  1024
            sourceSize.height: 1024
            visible: slotPane.hasCurrent && status !== Image.Error
            asynchronous: true

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onDoubleClicked: slotPane.refLightbox.openSlot(slotPane.slot)
                ToolTip.visible: containsMouse
                ToolTip.delay: 800
                ToolTip.text: "双击放大查看"
            }
        }

        // 右上角操作按钮组：⋯ 重选 / ⤢ 放大 / ✕ 清除
        Row {
            z: 2
            anchors.top: slotImage.top
            anchors.right: slotImage.right
            anchors.topMargin: 6
            anchors.rightMargin: 6
            spacing: 3
            visible: slotImage.visible

            // ⋯ 重选菜单
            Rectangle {
                width: 20; height: 20
                radius: 3
                color: moreMA.pressed ? "#3a3a45"
                     : moreMA.containsMouse ? "#2a2a32cc"
                     : "#1a1a1d99"
                border.color: moreMA.containsMouse ? "#5a8fd8" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -1
                    text: "⋯"
                    color: moreMA.containsMouse ? "#ffffff" : "#d0d0d8"
                    font.pixelSize: 13
                    font.bold: true
                }
                MouseArea {
                    id: moreMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: moreMenu.open()
                    ToolTip.visible: containsMouse && !moreMenu.visible
                    ToolTip.delay: 400
                    ToolTip.text: {
                        var u = String(slotPane.currentUrl)
                        if (u.length === 0) return "更多操作（重新选择图片 / 文件夹 / 分组多图）"
                        if (slotPane.mode === "grouped") {
                            var rootDir = Reference.groupedRootOfAt(root.refCurrentFolder, slotPane.slot) || ""
                            var cur = decodeURIComponent(u.replace(/^file:\/\//, ""))
                            if (rootDir.length > 0) return "[分组多图] 根目录: " + rootDir + "\n当前: " + cur
                            return cur
                        }
                        return decodeURIComponent(u.replace(/^file:\/\//, ""))
                    }
                }
                Menu {
                    id: moreMenu
                    y: 28 + 2
                    padding: 4
                    background: Rectangle {
                        implicitWidth: 110
                        color: "#1a1a1dcc"
                        border.color: "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    MenuItem {
                        id: menuImgItem
                        text: "图片"
                        implicitHeight: 28
                        onTriggered: slotPane.fileDlg.openForSlot(slotPane.slot)
                        contentItem: Text {
                            leftPadding: 10; rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: menuImgItem.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: menuImgItem.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                    MenuItem {
                        id: menuDirItem
                        text: "文件夹"
                        implicitHeight: 28
                        onTriggered: slotPane.dirDlg.openForSlot(slotPane.slot)
                        contentItem: Text {
                            leftPadding: 10; rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: menuDirItem.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: menuDirItem.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                    MenuItem {
                        id: menuGroupedItem
                        text: "多文件夹"
                        implicitHeight: 28
                        onTriggered: slotPane.groupedDlg.openForSlot(slotPane.slot)
                        contentItem: Text {
                            leftPadding: 10; rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: menuGroupedItem.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: menuGroupedItem.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                }
            }

            // ⤢ 放大
            Rectangle {
                width: 20; height: 20
                radius: 3
                color: zoomMA.pressed ? "#3a3a45"
                     : zoomMA.containsMouse ? "#2a2a32cc"
                     : "#1a1a1d99"
                border.color: zoomMA.containsMouse ? "#5a8fd8" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    text: "⤢"
                    color: zoomMA.containsMouse ? "#ffffff" : "#d0d0d8"
                    font.pixelSize: 12
                    font.bold: true
                }
                MouseArea {
                    id: zoomMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: slotPane.refLightbox.openSlot(slotPane.slot)
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "放大查看（滚轮缩放，← → 翻页，Esc 关闭）"
                }
            }

            // ✕ 清除当前绑定
            Rectangle {
                width: 20; height: 20
                radius: 3
                color: clearMA.pressed ? "#5a2a2a"
                     : clearMA.containsMouse ? "#3a2228cc"
                     : "#1a1a1d99"
                border.color: clearMA.containsMouse ? "#e0454d" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: clearMA.containsMouse ? "#ffffff" : "#e8b0b0"
                    font.pixelSize: 11
                    font.bold: true
                }
                MouseArea {
                    id: clearMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: slotPane.requestClear()
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "清除当前参考图绑定"
                }
            }
        }

        // 加载失败 / 未绑定占位（与原侧栏文案一致）
        Column {
            anchors.centerIn: parent
            width: parent.width - 24
            spacing: 12
            visible: !slotImage.visible

            Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: "#6a6a78"
                font.pixelSize: 12
                text: {
                    if (root.refCurrentFolder.length === 0)
                        return "请选中任一通道，\n或在「打开文件夹」对话框中为该路绑定参考图"
                    if (!slotPane.hasCurrent)
                        return "该文件夹未绑定第 " + slotPane.slot + " 张参考图\n\n选一张固定图，或让参考图随对比组切换\n（也可直接把图片或图片文件夹拖进来）"
                    if (slotImage.status === Image.Error)
                        return "图片无法加载（可能已被移动或删除）"
                    return ""
                }
            }

            // 未绑定时中央选择按钮
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                visible: root.refCurrentFolder.length > 0 && !slotPane.hasCurrent
                Button {
                    id: pickImgBtn
                    text: "📷 图片"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: slotPane.fileDlg.openForSlot(slotPane.slot)
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择一张固定参考图（整组对比始终显示这张）"
                    background: Rectangle {
                        color: pickImgBtn.down ? "#4a4a55"
                             : pickImgBtn.hovered ? "#33333a"
                             : "#202024"
                        border.color: pickImgBtn.hovered ? "#5a8fd8" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: pickImgBtn.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    id: pickDirBtn
                    text: "📁 文件夹"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: slotPane.dirDlg.openForSlot(slotPane.slot)
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择图片文件夹（参考图按对比组自动同步）"
                    background: Rectangle {
                        color: pickDirBtn.down ? "#4a4a55"
                             : pickDirBtn.hovered ? "#33333a"
                             : "#202024"
                        border.color: pickDirBtn.hovered ? "#0fa085" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: pickDirBtn.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    id: pickGroupedBtn
                    text: "🗂 分组多图"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: slotPane.groupedDlg.openForSlot(slotPane.slot)
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择两级文件夹：root/组A/图... · root/组B/图...\n跟随对比组跳到同名子组首图；◀▶递归跨组翻图"
                    background: Rectangle {
                        color: pickGroupedBtn.down ? "#4a4a55"
                             : pickGroupedBtn.hovered ? "#33333a"
                             : "#202024"
                        border.color: pickGroupedBtn.hovered ? "#c89020" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: pickGroupedBtn.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // 拖拽接收：文件夹 → folder 模式；图片 → image 模式
        DropArea {
            id: slotDrop
            anchors.fill: parent
            onDropped: function(drop) {
                if (root.refCurrentFolder.length === 0) {
                    drop.accepted = false
                    return
                }
                if (!drop.hasUrls) { drop.accepted = false; return }
                for (var i = 0; i < drop.urls.length; ++i) {
                    var u = drop.urls[i]
                    if (Fs.isDirectory(u)) {
                        if (Reference.setReferenceFolderUrlAt(root.refCurrentFolder, u, slotPane.slot)) {
                            drop.accepted = true
                            return
                        }
                    }
                }
                for (var j = 0; j < drop.urls.length; ++j) {
                    var u2 = drop.urls[j]
                    if (Reference.setReferenceUrlAt(root.refCurrentFolder, u2, slotPane.slot)) {
                        drop.accepted = true
                        return
                    }
                }
                drop.accepted = false
            }
        }
    }

        // 底部内嵌翻页指示：无外层矩形，仅 ◀ 数字 ▶ 悬浮显示（folder/grouped 且总数>1）
        Item {
            id: slotNavBar
            z: 3
            anchors.left: slotImageBox.left
            anchors.right: slotImageBox.right
            anchors.bottom: slotImageBox.bottom
            anchors.margins: 6
            height: 18
            visible: slotPane.canNav && slotPane.imageCount > 1
            opacity: slotImage.hovered || navHover.hovered ? 0.95 : 0.55
            Behavior on opacity { NumberAnimation { duration: 150 } }

            // hover 检测扩到整条区域（含按钮间隙）
            MouseArea {
                id: navHover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
            }

            Text {
                id: prevBtn
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "◀"
                font.pixelSize: 12
                color: prevMA.containsMouse ? "#ffffff" : "#c8c8d0"
                Behavior on color { ColorAnimation { duration: 120 } }
                MouseArea {
                    id: prevMA
                    anchors.fill: parent
                    anchors.margins: -6
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: slotPane.bumpOffset(-1)
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "上一张参考图（手动浏览）"
                }
            }

            Label {
                anchors.centerIn: parent
                text: slotPane.progressText
                color: "#e0e0e8"
                font.pixelSize: 11
                font.bold: true
            }

            Text {
                id: nextBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "▶"
                font.pixelSize: 12
                color: nextMA.containsMouse ? "#ffffff" : "#c8c8d0"
                Behavior on color { ColorAnimation { duration: 120 } }
                MouseArea {
                    id: nextMA
                    anchors.fill: parent
                    anchors.margins: -6
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: slotPane.bumpOffset(+1)
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "下一张参考图（手动浏览）"
                }
            }
        }
}
