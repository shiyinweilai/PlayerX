import QtQuick

// 自绘简约线稿图标：垃圾桶（删除），hover 点亮为红色
Canvas {
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
        // 盖线
        ctx.beginPath()
        ctx.moveTo(2.6, 3.7)
        ctx.lineTo(10.4, 3.7)
        ctx.stroke()
        // 提手
        ctx.beginPath()
        ctx.moveTo(5.2, 2.2)
        ctx.lineTo(7.8, 2.2)
        ctx.stroke()
        // 桶身
        ctx.beginPath()
        ctx.moveTo(3.9, 3.5)
        ctx.lineTo(4.6, 11.0)
        ctx.lineTo(8.4, 11.0)
        ctx.lineTo(9.1, 3.5)
        ctx.stroke()
    }
}
