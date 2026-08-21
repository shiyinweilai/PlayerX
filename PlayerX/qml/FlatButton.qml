// FlatButton.qml — 通用扁平按钮组件（从 Main.qml 拆分）
// 深色主题风格的轻量按钮：下沉缩放反馈、三态（normal/hover/pressed/disabled）配色。

import QtQuick

Rectangle {
    id: fb
    // 公共 API（兼容原 Button 用法）
    property string text: ""
    property bool   enabled: true
    property alias  font: fbText.font
    property bool   hovered: fbHover.hovered
    property bool   down: fbMouse.pressed && fb.enabled
    // 文字颜色（可选）：外部不设时走默认配色；设了则覆盖（按下/悬停/禁用三态自动派生）。
    // 主要给"危险动作"按钮用（如 ✕ 全部 → 红色），不影响普通按钮。
    property color  textColor: "transparent"   // 透明 = 走默认逻辑
    // 背景/描边三态可选覆盖：不传则走下方默认配色，任何既有调用方不传这些
    // 属性时也能拿到统一的新外观（下面这套默认值本身就是本次改版的目标风格）。
    // 默认值对齐 YUV 分析模块全局总控栏（YuvWindow.qml 最下方那条）的按钮
    // 配色体系：无描边的纯色圆角胶囊、灰底为主，hover 提亮一档；
    // 播放/复位/危险等"关键按钮"通过覆盖这些属性单独换成蓝/红，具体见调用处。
    property color  bgNormal:     "#80252528"
    property color  bgHover:      "#803a3a3d"
    property color  bgDown:       "#804a4a55"
    // 描边默认与背景同色 = 视觉上无描边，纯色胶囊（呼应 YUV 按钮的 flat 风格）
    property color  borderNormal: bgNormal
    property color  borderHover:  bgHover
    property color  borderDown:   bgDown
    signal clicked()

    // 尺寸：根据文字自适应；外部仍可 Layout.preferredWidth 覆盖
    implicitWidth:  Math.max(56, fbText.implicitWidth + 24)
    implicitHeight: 28
    radius: 4

    // 颜色分层：down(明亮) > hovered(中间态) > normal(默认) > disabled(几乎隐隐)
    color: !fb.enabled ? "#1a1a1d"
          : fb.down    ? fb.bgDown
          : fb.hovered ? fb.bgHover
                       : fb.bgNormal
    border.color: !fb.enabled ? "#252528"
                 : fb.down    ? fb.borderDown
                 : fb.hovered ? fb.borderHover
                              : fb.borderNormal
    border.width: 1
    Behavior on color        { ColorAnimation  { duration: 90 } }
    Behavior on border.color { ColorAnimation  { duration: 90 } }

    // 按下缩放 0.94，给出明确物理反馈
    scale: down ? 0.94 : 1.0
    Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

    Text {
        id: fbText
        anchors.centerIn: parent
        text: fb.text
        font.pixelSize: 13
        // 默认配色 vs 外部覆盖：fb.textColor 透明（默认值）则走原逻辑。
        color: !fb.enabled
               ? "#555"
               : (fb.textColor.a > 0
                    ? (fb.down    ? Qt.lighter(fb.textColor, 1.25)
                      : fb.hovered ? Qt.lighter(fb.textColor, 1.10)
                                   : fb.textColor)
                    : (fb.down    ? "#ffffff"
                                  : "#e8e8ec"))
        Behavior on color { ColorAnimation { duration: 90 } }
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
        hoverEnabled: false   // hover 已交给 HoverHandler
        onClicked: fb.clicked()
    }
    opacity: enabled ? 1.0 : 0.5
}
