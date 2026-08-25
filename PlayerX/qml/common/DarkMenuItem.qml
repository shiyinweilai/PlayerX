// ─────────────────────────────────────────────────────────────
// DarkMenuItem.qml —— MenuBar 下拉菜单专用的深色 MenuItem
//
// 【为什么需要它】
//   · Qt 6.x QtQuick.Controls 的 Menu.delegate 只对"从 Action / 模型动态创建"
//     的项生效，对源码里 inline 声明的 `MenuItem { ... }` 不生效。
//   · 因此要给下拉菜单换皮，必须对每一个 inline MenuItem 单独覆盖
//     contentItem/background/indicator/arrow。把这些覆盖抽成独立组件
//     （本文件），源码中把 `MenuItem` 逐一替换成 `DarkMenuItem` 即可。
//
// 【平台影响】
//   · macOS：MenuBar 走系统全局菜单（NSMenu），自定义样式会被系统忽略，
//            继续显示原生外观 —— 与系统其他 App 一致。
//   · Windows / Linux：本组件生效，呈现半透明深色 + 白字 + 蓝底 hover。
//
// 【配色遵循全局约定】（与 ToolTip / phoneAspectPopup 一致）
//   · 背景色：透明（承接 Menu 的 #cc1a1a1f 半透明深底）
//   · 文字：#e8e8ec；disabled 时 #7a7a80
//   · hover / highlighted：整行蓝底 #0a64f0，文字仍为 #e8e8ec
//   · 勾选标记 ✓：白色
//   · 子菜单箭头 ▸：白色
// ─────────────────────────────────────────────────────────────
import QtQuick
import QtQuick.Controls

MenuItem {
    id: root

    implicitHeight: 28
    padding: 0
    leftPadding: 0
    rightPadding: 0
    topPadding: 0
    bottomPadding: 0

    // ── 勾选标记 ✓ ──（左侧固定留白 26px，让 checkable/非 checkable 项文字对齐）
    indicator: Item {
        x: 8
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: 14
        implicitHeight: 14
        Text {
            anchors.centerIn: parent
            text: "✓"
            color: "#e8e8ec"
            font.pixelSize: 12
            // checked 为 true 即显示 ✓，不强制要求 checkable。
            // 这样互斥单选项（checkable:false + checked:绑定）也能正确显示勾选标记，
            // 且不会因 Qt 自动 toggle checked 而出现多选。
            visible: root.checked
            renderType: Text.QtRendering
        }
    }

    // ── 正文文字 ──
    contentItem: Text {
        leftPadding: 28    // 让位给 indicator（8 + 14 + 6）
        rightPadding: 20   // 让位给右侧 arrow
        text: root.text
        color: root.enabled ? "#e8e8ec" : "#7a7a80"
        font.pixelSize: 13
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        renderType: Text.QtRendering
        elide: Text.ElideRight
    }

    // ── 子菜单箭头 ▸ ──（仅当本项是子菜单入口时显示）
    arrow: Text {
        x: root.width - width - 10
        anchors.verticalCenter: parent.verticalCenter
        text: "▸"
        color: "#e8e8ec"
        font.pixelSize: 12
        visible: root.subMenu
        renderType: Text.QtRendering
    }

    // ── 整行背景 ──（hover / highlighted 蓝底）
    // 【重要】disabled 项【绝不】响应 hover/highlighted 蓝底，永远保持透明。
    // 原因：当鼠标从"播放速度 ▶"（highlighted=true，展开中）滑到下方 disabled
    // 项时，如果 disabled 也变蓝，会出现两条同时蓝底的视觉冲突 —— disabled
    // 本就是"不可交互"的语义，不该给出任何交互反馈。
    background: Rectangle {
        implicitWidth: 220
        implicitHeight: 28
        color: (root.enabled && (root.hovered || root.highlighted)) ? "#0a64f0" : "transparent"
        radius: 4
    }
}
