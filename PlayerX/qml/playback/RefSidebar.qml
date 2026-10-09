// RefSidebar.qml — 参考图侧边栏（纵向滚动多窗口版）
//
// v4 改造（2026-10-09）：
//   原布局为固定「上/下两个窗口」（槽位 1/2，中间可拖动分隔条）。
//   现改为纵向 Flickable + N 个 RefSidebarSlot 窗口（1..Reference.maxSlots()）：
//     · 每个窗口独立绑定参考图（图片/文件夹/分组多图），独立 ◀▶ 翻图；
//     · 窗口左上角有数字角标（1/2/3...），标识这是第几个参考图；
//     · 内容超高时可上下滚动（滚轮 / 触控板）；
//     · 底部「＋ 添加参考图」按钮：在当前窗口数 +1 的槽位上新建空窗口
//       （上限 Reference.maxSlots()=9）；
//     · 每个窗口 ✕ 按钮清除该槽位绑定；清除最后一个非空槽位后窗口自动收起。
//   窗口数 = slotVisibleCount（见下）：至少 1（未绑定时显示占位引导），
//   最多 = max(已绑定槽位数, 用户手动添加的窗口数)，由 Main.qml 状态驱动。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Rectangle {
    id: refSidebar
    property var root: null
    property var refSidebarFileDlg: null
    property var refSidebarDirDlg: null
    property var refSidebarGroupedDlg: null
    property var refLightbox: null
    property Item leftNavBar: null
    // 布局模式：false = 滚动（固定两窗高度，多了上下滑动）；true = 铺满（窗口等分侧栏高度）
    property bool fitLayout: false
    anchors.left: leftNavBar.right
    anchors.top: parent.top
    anchors.topMargin: 2
    anchors.bottom: parent.bottom
    width: root.refSidebarWidth
    visible: root.refSidebarVisible && width > 0 && root.currentTab === "play"
    color: "#15151a"

    // 右侧 1px 分隔线，与视频区切开
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: "#2c2c32"
    }

    // 顶部标题栏（添加按钮 + 模式切换 + 窗口计数；原底部添加栏已并入此处）
    Rectangle {
        id: refHeader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 32
        z: 10
        color: "#1a1a1d"
        // ＋ 添加按钮：展开一个新窗口（新槽位）
        Rectangle {
            id: addSlotBtn
            width: addSlotText.implicitWidth + 14
            height: 20
            radius: 3
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            visible: refSidebar.slotVisibleCount < Reference.maxSlots()
            color: addSlotMA.pressed ? "#3a3a45"
                 : addSlotMA.containsMouse ? "#2a2a32"
                 : "#202024"
            border.color: addSlotMA.containsMouse ? "#0fa085" : "#3a3a45"
            border.width: 1
            Text {
                id: addSlotText
                anchors.centerIn: parent
                text: "＋ 添加 " + refSidebar.slotVisibleCount + "/" + Reference.maxSlots()
                color: "#e8e8ec"
                font.pixelSize: 11
            }
            MouseArea {
                id: addSlotMA
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: refSidebar.root._refAddSlotWindow()
            }
            ToolTip.visible: addSlotMA.containsMouse
            ToolTip.delay: 400
            ToolTip.text: "添加一个参考图窗口（新槽位，可绑定另一组参考图，上限 " + Reference.maxSlots() + " 张）"
        }
        // 已到上限时的提示
        Label {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            visible: refSidebar.slotVisibleCount >= Reference.maxSlots()
            text: "已达上限 " + Reference.maxSlots() + " 张"
            color: "#6a6a78"
            font.pixelSize: 11
        }
        // 布局模式切换：滚动（固定两窗高度，多了上下滑动）/ 铺满（窗口等分侧栏）
        Rectangle {
            id: layoutToggleBtn
            width: 38; height: 20
            radius: 3
            anchors.left: addSlotBtn.right
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            color: layoutToggleMA.pressed ? "#3a3a45"
                 : layoutToggleMA.containsMouse ? "#2a2a32"
                 : "#202024"
            border.color: refSidebar.fitLayout ? "#0fa085"
                        : layoutToggleMA.containsMouse ? "#5a8fd8" : "#3a3a45"
            border.width: 1
            Text {
                anchors.centerIn: parent
                text: refSidebar.fitLayout ? "铺满" : "滚动"
                color: refSidebar.fitLayout ? "#7ee0c8" : "#9a9aa8"
                font.pixelSize: 10
            }
            MouseArea {
                id: layoutToggleMA
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: refSidebar.fitLayout = !refSidebar.fitLayout
            }
            ToolTip.visible: layoutToggleMA.containsMouse
            ToolTip.delay: 400
            ToolTip.text: refSidebar.fitLayout
                ? "当前：铺满（所有窗口等分侧栏高度）。点击切换为固定高度 + 上下滚动"
                : "当前：滚动（窗口固定为两窗平铺高度，多了上下滑动查看）。点击切换为铺满"
        }
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: "#2c2c32"
        }
    }

    // 当前已绑定的槽位数（驱动窗口数下限；0 时也保留 1 个占位窗口引导绑定）
    readonly property int _boundCount: {
        root._refTick;
        if (typeof Reference === "undefined" || !root.refCurrentFolder) return 0
        if (root.refCurrentFolder.length === 0) return 0
        return Reference.slotCountOf(root.refCurrentFolder)
    }

    // 可见窗口数 = max(已绑定槽位数, 用户手动展开的窗口数)，至少 1，至多 maxSlots()
    readonly property int slotVisibleCount: Math.max(1,
        Math.min(Reference.maxSlots(),
                 Math.max(refSidebar._boundCount, root._refSlotUiCount)))

    // 单个参考图窗口的高度：
    //   · 滚动模式：固定等于「两个窗口平铺」时的高度，新增窗口不缩小已有窗口；
    //   · 铺满模式：所有窗口等分侧栏高度（每窗至少 150px），全部一屏可见。
    readonly property real slotWindowHeight: fitLayout
        ? Math.max(150, Math.floor((slotFlick.height - 8) / slotVisibleCount))
        : Math.max(150, Math.floor((slotFlick.height - 8) / 2))

    // 布局模式切换时回到顶部，避免铺满模式下残留滚动偏移
    onFitLayoutChanged: slotFlick.contentY = 0

    // 纵向滚动区：N 个参考图窗口
    Flickable {
        id: slotFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: refHeader.bottom
        anchors.bottom: parent.bottom
        anchors.topMargin: 4
        anchors.bottomMargin: 4
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // 滚轮 / 触控板纵向滚动
        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            implicitWidth: 8
            contentItem: Rectangle {
                radius: 4
                color: parent.pressed ? "#5a5a65" : parent.hovered ? "#4a4a55" : "#3a3a45"
            }
        }

        // 内容高度：N 个窗口纵向紧挨排列（间隙 0，靠边框区分）
        contentHeight: refSidebar.slotVisibleCount * refSidebar.slotWindowHeight

        Column {
            id: slotColumn
            width: slotFlick.width
            spacing: 0

            Repeater {
                model: refSidebar.slotVisibleCount

                RefSidebarSlot {
                    id: slotItem
                    // Repeater 自动注入 index（0-based）；槽位号 = index + 1
                    width: parent.width
                    height: refSidebar.slotWindowHeight
                    root: refSidebar.root
                    slot: index + 1
                    currentUrl: refSidebar._slotUrl(index + 1)
                    hasCurrent: String(refSidebar._slotUrl(index + 1)).length > 0
                    mode: refSidebar._slotMode(index + 1)
                    imageCount: refSidebar._slotCount(index + 1)
                    progressText: refSidebar._slotProgress(index + 1)
                    fileDlg: refSidebar.refSidebarFileDlg
                    dirDlg: refSidebar.refSidebarDirDlg
                    groupedDlg: refSidebar.refSidebarGroupedDlg
                    refLightbox: refSidebar.refLightbox
                    onBumpOffset: function(delta) {
                        refSidebar.root._refBumpSlotOffset(index + 1, delta)
                    }
                    onRequestClear: {
                        if (refSidebar.root.refCurrentFolder.length > 0)
                            Reference.clearReferenceAt(refSidebar.root.refCurrentFolder, index + 1)
                    }
                }
            }
        }
    }

    // ── 每槽位状态查询（全部依赖 _refTick 触发重算）──────────────────
    function _slotUrl(slot) {
        root._refTick;
        if (typeof Reference === "undefined") return ""
        if (!root.refCurrentVideo || root.refCurrentVideo.length === 0) return ""
        return Reference.referenceUrlForVideoOffsetAt(root.refCurrentVideo, root._refSlotOffset(slot), slot)
    }
    function _slotMode(slot) {
        root._refTick;
        if (typeof Reference === "undefined") return ""
        if (!root.refCurrentFolder || root.refCurrentFolder.length === 0) return ""
        return Reference.kindOfAt(root.refCurrentFolder, slot)
    }
    function _slotCount(slot) {
        root._refTick;
        if (typeof Reference === "undefined") return 0
        if (!root.refCurrentVideo || root.refCurrentVideo.length === 0) return 0
        return Reference.referenceImageCountForVideoAt(root.refCurrentVideo, slot)
    }
    function _slotProgress(slot) {
        root._refTick;
        if (typeof Reference === "undefined") return ""
        if (!root.refCurrentVideo || root.refCurrentVideo.length === 0) return ""
        return Reference.referenceProgressForVideoOffsetAt(root.refCurrentVideo, root._refSlotOffset(slot), slot)
    }
}
