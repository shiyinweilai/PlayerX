import QtQuick

// 自绘简约线稿图标：铅笔（编辑），hover 点亮为蓝色
Canvas {
    id: root
    property color lineColor: "#767681"
    width: 13
    height: 13
    antialiasing: true
    onLineColorChanged: requestPaint()
    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.strokeStyle = lineColor
        ctx.lineWidth = 1.2
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        // 斜置笔身轮廓
        ctx.beginPath()
        ctx.moveTo(1.8, 11.2)
        ctx.lineTo(2.8, 8.2)
        ctx.lineTo(9.6, 1.4)
        ctx.lineTo(11.6, 3.4)
        ctx.lineTo(4.8, 10.2)
        ctx.closePath()
        ctx.stroke()
        // 笔尖分界
        ctx.beginPath()
        ctx.moveTo(2.2, 10.1)
        ctx.lineTo(3.3, 10.9)
        ctx.stroke()
    }
}
