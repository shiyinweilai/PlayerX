// StreamFlatButton.qml — 码流分析视图专用扁平按钮（仿 YUV 总控栏风格）
//
// 与 FlatButton 区别：高度 22（YUV 总控栏 22px 风格），圆角 3，
// 默认配色直接对齐 #80252528 / hover #803a3a3d，省得每次手动覆盖。
// 文字默认 11px（YUV 总控栏风格）。

import QtQuick

Rectangle {
    id: fb
    property string text: ""
    property bool   enabled: true
    property alias  font: fbText.font
    property color  textColor: "#cccccc"

    // 可覆盖的三态底色（与 YuvWindow 总控栏的#80XXXXXX 半透明风格同源）
    property color bgNormal:     "#80252528"
    property color bgHover:      "#803a3a3d"
    property color bgDown:       "#804a4a55"
    property color bgDisabled:   "#1a1a1d"

    signal clicked()

    implicitWidth:  Math.max(48, fbText.implicitWidth + 16)
    implicitHeight: 22
    radius: 3

    readonly property bool   _hovered:  fbHover.hovered
    readonly property bool   _down:     fbMouse.pressed && fb.enabled
    color: !fb.enabled ? fb.bgDisabled
          : fb._down   ? fb.bgDown
          : fb._hovered ? fb.bgHover
                        : fb.bgNormal
    border.color: !fb.enabled ? "#252528" : "#803a3a44"
    border.width: 1
    Behavior on color        { ColorAnimation { duration: 90 } }
    Behavior on border.color { ColorAnimation { duration: 90 } }
    scale: _down ? 0.94 : 1.0
    Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

    Text {
        id: fbText
        anchors.centerIn: parent
        text: fb.text
        font.pixelSize: 11
        color: !fb.enabled
               ? "#555"
               : (fb._down   ? Qt.lighter(fb.textColor, 1.20)
                 : fb._hovered ? Qt.lighter(fb.textColor, 1.10)
                               : fb.textColor)
    }
    HoverHandler {
        id: fbHover
        cursorShape: fb.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: fb.enabled
    }
    MouseArea {
        id: fbMouse
        anchors.fill: parent
        enabled: fb.enabled
        hoverEnabled: false
        onClicked: fb.clicked()
    }
    opacity: enabled ? 1.0 : 0.5
}
