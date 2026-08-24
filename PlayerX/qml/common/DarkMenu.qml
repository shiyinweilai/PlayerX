// ─────────────────────────────────────────────────────────────
// DarkMenu.qml —— MenuBar 下拉菜单容器（半透明深底 + 白描边 + 圆角）
//
// 【为什么需要它】
//   直接用 QtQuick.Controls 原生 Menu，Basic style 会给 contentItem
//   加白色 ListView 背景，与"打开文件…"这种"当前项白底"高亮效果重叠，
//   看起来很丑。这里显式接管 background / topPadding / bottomPadding /
//   spacing / overlap，去掉一切系统默认间距和高亮，只留我们自己的样式。
//
// 【平台影响】
//   · macOS：MenuBar 走系统 NSMenu，本文件的 background/contentItem
//            会被系统忽略，继续显示原生外观。
//   · Windows / Linux：呈现半透明深色 + 6px 圆角 + 白描边的下拉容器。
// ─────────────────────────────────────────────────────────────
import QtQuick
import QtQuick.Controls

Menu {
    id: root

    // ─── 子菜单入口项的样式 ───────────────────────────────────────
    // 【关键】Qt 6 QQC2 中，当一个 Menu 嵌套在父 Menu 里作为子菜单时，
    // 父菜单里代表"子菜单入口"的那个 MenuItem 是 Qt 内部【动态创建】的，
    // 不是源码里的 inline MenuItem —— 因此它不会走 DarkMenuItem。
    // 而 Menu.delegate 恰好【只作用于动态创建的项】，正好用来给这个
    // 入口项接管样式。inline 声明的项已经全换成 DarkMenuItem，两者互补，
    // 不会互相冲突。
    //
    // 效果：子菜单入口（如"布局 ▶"/"播放速度 ▶"）文字变白、右侧箭头变白、
    // hover 蓝底，与其它 DarkMenuItem 一致。
    delegate: MenuItem {
        id: dmiEntry
        implicitHeight: 28
        padding: 0
        leftPadding: 0
        rightPadding: 0
        topPadding: 0
        bottomPadding: 0

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
                visible: dmiEntry.checkable && dmiEntry.checked
                renderType: Text.QtRendering
            }
        }

        contentItem: Text {
            leftPadding: 28
            rightPadding: 20
            text: dmiEntry.text
            color: dmiEntry.enabled ? "#e8e8ec" : "#7a7a80"
            font.pixelSize: 13
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            renderType: Text.QtRendering
            elide: Text.ElideRight
        }

        arrow: Text {
            x: dmiEntry.width - width - 10
            anchors.verticalCenter: parent.verticalCenter
            text: "▸"
            color: dmiEntry.enabled ? "#e8e8ec" : "#7a7a80"
            font.pixelSize: 12
            visible: dmiEntry.subMenu
            renderType: Text.QtRendering
        }

        background: Rectangle {
            implicitWidth: 220
            implicitHeight: 28
            // 与 DarkMenuItem 一致：disabled 项不响应 hover/highlighted 蓝底
            color: (dmiEntry.enabled && (dmiEntry.hovered || dmiEntry.highlighted)) ? "#0a64f0" : "transparent"
            radius: 4
        }
    }

    // 弹出容器的深色半透明背景
    background: Rectangle {
        implicitWidth: 220
        implicitHeight: 32
        color: "#cc1a1a1f"
        border.color: "#33ffffff"
        border.width: 1
        radius: 6
    }

    // 上下留白 + 项间零间隙，避免默认 style 挤出大空隙
    topPadding: 6
    bottomPadding: 6
    leftPadding: 4
    rightPadding: 4
    spacing: 0

    // 弹出层与 MenuBarItem 的间隙（默认 -1 会重叠遮住 MenuBar 描边）
    overlap: 0
}
