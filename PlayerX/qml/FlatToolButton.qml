// FlatToolButton.qml — 扁平风格工具按钮
//
// 从 Main.qml 内 inline component 抽出为独立组件，便于跨 QML 文件复用
// （VideoCellDelegate.qml 等抽离子组件需要直接引用，inline component 在
//  外部 qml 文件中不可见）。行为/视觉与原 inline 版本完全一致。
//
// 用法：
//   FlatToolButton { text: "▶"; onClicked: doSomething() }
//
// 暴露属性：
//   text     — 按钮文字
//   enabled  — 是否可用（false 时半透明且不响应点击）
//   font     — alias 到内部 Text.font，便于外部调字号
//   hovered  — 鼠标 hover 状态（只读，子项可绑定显示 ToolTip）
//   down     — 是否按下（只读，便于自定义视觉态）
// 信号：clicked()
import QtQuick

Rectangle {
    id: ftb
    property string text: ""
    property bool   enabled: true
    property alias  font: ftbText.font
    property bool   hovered: ftbHover.hovered
    property bool   down: ftbMouse.pressed && ftb.enabled
    signal clicked()

    implicitWidth:  Math.max(34, ftbText.implicitWidth + 16)
    implicitHeight: 26
    radius: 4

    color: !ftb.enabled ? "transparent"
          : ftb.down    ? "#55ffffff"   // 按下：半透明白
          : ftb.hovered ? "#33ffffff"   // 悬停：更淡的半透明白
                        : "transparent"
    border.color: ftb.down ? "#88ffffff" : "transparent"
    border.width: 1
    Behavior on color { ColorAnimation { duration: 90 } }

    scale: down ? 0.92 : 1.0
    Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

    Text {
        id: ftbText
        anchors.centerIn: parent
        text: ftb.text
        font.pixelSize: 13
        color: !ftb.enabled ? "#555"
              : ftb.down    ? "#ffffff"
                            : "#e8e8ec"
    }

    HoverHandler {
        id: ftbHover
        cursorShape: ftb.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: ftb.enabled
    }
    MouseArea {
        id: ftbMouse
        anchors.fill: parent
        enabled: ftb.enabled
        hoverEnabled: false
        onClicked: ftb.clicked()
    }
    opacity: enabled ? 1.0 : 0.5
}
