import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX.YuvTools

/**
 * YuvWindow.qml — YUV 多窗口渲染子界面
 *
 * 布局：顶部仅有返回按钮和标题，中间为画面区域，底部为控制栏。
 * 每个 slot 独立：通道切换 + 帧导航 + 像素矩阵悬浮显示（块大小可在顶部菜单
 * "YUV 分析→块大小"调整；悬浮矩阵固定视口/单元格尺寸，左键点击可"固定"弹窗
 * 并拖动滚动查看完整块，参见 pixelHoverArea/pixelGridPopup）。
 */

Item {
    id: yuvView
    signal closeRequested()

    property int openSlotCount: YuvBridge.slotCount

    Rectangle {
        anchors.fill: parent
        color: "#101012"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── 顶部栏：返回 + 标题 ─────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: "#18181c"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 12

                Rectangle {
                    width: 72; height: 28; radius: 4
                    color: backBtnMa.containsMouse ? "#3a3a3d" : "#252528"
                    Text {
                        anchors.centerIn: parent
                        text: "← 返回"
                        color: "#ccc"; font.pixelSize: 12
                    }
                    MouseArea {
                        id: backBtnMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: yuvView.closeRequested()
                    }
                }

                Text {
                    text: "YUV 渲染 · " + yuvView.openSlotCount + " 路"
                    color: "#e0e0e0"; font.pixelSize: 15; font.bold: true
                }

                Item { Layout.fillWidth: true }
            }
        }

        // ── 中间：多窗口画面区域 ─────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 2

            Repeater {
                model: yuvView.openSlotCount
                delegate: Rectangle {
                    id: slotWin
                    required property int index
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "#0c0c0e"

                    property int ver: 0
                    Connections {
                        target: YuvBridge
                        function onFrameChanged(slot) {
                            if (slot === slotWin.index) ver++
                        }
                        function onPlayStateChanged(slot) {
                            if (slot === slotWin.index) ver++
                        }
                        function onDisplayModeChanged(slot) {
                            if (slot === slotWin.index) ver++
                        }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ── 顶部信息条：序号 + 文件名 + 关闭 ──
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 28
                            color: "#14141a"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 6

                                // 序号标签
                                Rectangle {
                                    width: 20; height: 18; radius: 3
                                    color: "#3a6fd8"
                                    Text {
                                        anchors.centerIn: parent
                                        text: (slotWin.index + 1).toString()
                                        color: "#fff"; font.pixelSize: 11; font.bold: true
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: YuvBridge.fileName(slotWin.index)
                                    color: "#c8c8d0"; font.pixelSize: 11
                                    elide: Text.ElideMiddle
                                }

                                // 关闭按钮
                                Rectangle {
                                    width: 18; height: 18; radius: 9
                                    color: slotCloseMa.containsMouse ? "#b85a5a" : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"; color: "#f5a3a3"; font.pixelSize: 12; font.bold: true
                                    }
                                    MouseArea {
                                        id: slotCloseMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: YuvBridge.closeFile(slotWin.index)
                                    }
                                }
                            }
                        }

                        // ── 画面区域 ──
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true

                            YuvDisplayItem {
                                id: yuvDisp
                                anchors.fill: parent
                                image: {
                                    const _ = slotWin.ver
                                    return YuvBridge.frameImage(slotWin.index)
                                }
                            }

                            // ── 右键按住拖拽平移 ──
                            MouseArea {
                                id: panArea
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                property real lastX: 0
                                property real lastY: 0

                                onPressed: function(mouse) {
                                    lastX = mouse.x
                                    lastY = mouse.y
                                    cursorShape = Qt.ClosedHandCursor
                                }
                                onReleased: {
                                    cursorShape = Qt.ArrowCursor
                                }
                                onPositionChanged: function(mouse) {
                                    if (pressed) {
                                        yuvDisp.panX += mouse.x - lastX
                                        yuvDisp.panY += mouse.y - lastY
                                        lastX = mouse.x
                                        lastY = mouse.y
                                    }
                                }
                                // 右键双击：重置平移归位
                                onDoubleClicked: {
                                    yuvDisp.panX = 0
                                    yuvDisp.panY = 0
                                }
                            }

                            // ── 鼠标悬浮矩阵浮窗交互 ────────────────────────────────
                            // 悬浮态：固定视口尺寸（viewCells×viewCells）+ 固定单元格大小，
                            // 跟随鼠标显示当前块左上角部分；块越大只露出可视区域内的内容。
                            // 左键点击后进入"固定"态：弹窗停止跟随鼠标（冻结屏幕坐标与内容），
                            // 内部 Flickable 允许上下左右拖动查看块的其余部分；再次点击视频
                            // 区域（弹窗外）或点击弹窗右上角 × 取消固定、恢复跟随。
                            MouseArea {
                                id: pixelHoverArea
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton
                                propagateComposedEvents: true

                                property bool showPixelGrid: false
                                property bool pinned: false
                                property int pixelX: 0
                                property int pixelY: 0
                                property var pixelData: []
                                // 块统计值：{ yAvg,yMin,yMax, uAvg,uMin,uMax, vAvg,vMin,vMax }
                                property var pixelStats: ({})

                                // 固定时冻结的弹窗屏幕坐标（点击瞬间算好存这里，不再跟随鼠标）
                                property real pinnedPopupX: 0
                                property real pinnedPopupY: 0

                                // 按当前块大小（YuvBridge.blockSize）拉取一次悬浮矩阵数据，
                                // hover 移动 / 块大小切换共用此函数。
                                function fetchAt(ix, iy) {
                                    pixelX = ix
                                    pixelY = iy
                                    showPixelGrid = true
                                    pixelData = YuvBridge.pixelBlock8x8(slotWin.index, ix, iy)
                                    pixelStats = YuvBridge.pixelBlockStats8x8(slotWin.index, ix, iy)
                                    // 上报全局悬浮像素坐标，供右侧栏"块级别"统计实时跟随
                                    YuvBridge.setHoverPixel(slotWin.index, ix, iy, true)
                                }

                                // 弹窗智能避让定位（"跟随鼠标"实时计算 与 "固定瞬间"取快照共用）
                                function computePopupX(mx) {
                                    const pw = pixelHoverArea.width
                                    const pgw = pixelGridPopup.width
                                    const rightX = mx + 20
                                    const leftX = mx - pgw - 20
                                    if (rightX + pgw + 8 <= pw) return rightX
                                    else if (leftX >= 8) return leftX
                                    else return pw - pgw - 8
                                }
                                function computePopupY(my) {
                                    const ph = pixelHoverArea.height
                                    const pgh = pixelGridPopup.height
                                    const topY = my - pgh - 20
                                    const bottomY = my + 20
                                    if (topY >= 8) return topY
                                    else if (bottomY + pgh + 8 <= ph) return bottomY
                                    else return 8
                                }

                                onPositionChanged: function(mouse) {
                                    if (pinned) return   // 已固定：不再跟随鼠标刷新
                                    // 将鼠标坐标映射到图像坐标
                                    // YuvDisplayItem 使用 1:1 原尺寸居中 + panX/panY 偏移
                                    const imgW = YuvBridge.width(slotWin.index)
                                    const imgH = YuvBridge.height(slotWin.index)
                                    if (imgW <= 0 || imgH <= 0) return

                                    const dispW = pixelHoverArea.width
                                    const dispH = pixelHoverArea.height

                                    // 1:1 居中偏移 + 平移偏移（与 YuvDisplayItem::paint 一致）
                                    const offX = (dispW - imgW) / 2.0 + yuvDisp.panX
                                    const offY = (dispH - imgH) / 2.0 + yuvDisp.panY

                                    const ix = Math.floor(mouse.x - offX)
                                    const iy = Math.floor(mouse.y - offY)

                                    if (ix >= 0 && ix < imgW && iy >= 0 && iy < imgH) {
                                        fetchAt(ix, iy)
                                    } else {
                                        showPixelGrid = false
                                        YuvBridge.setHoverPixel(slotWin.index, 0, 0, false)
                                    }
                                }
                                onExited: {
                                    if (pinned) return   // 已固定：鼠标移出视频区域也不收起弹窗
                                    showPixelGrid = false
                                    YuvBridge.setHoverPixel(slotWin.index, 0, 0, false)
                                }
                                onClicked: function(mouse) {
                                    if (pinned) {
                                        // 点击视频区域（弹窗之外）→ 取消固定，恢复跟随鼠标
                                        pinned = false
                                    } else if (showPixelGrid) {
                                        // 冻结当前弹窗的屏幕位置与内容 → 进入固定态
                                        pinnedPopupX = computePopupX(mouse.x)
                                        pinnedPopupY = computePopupY(mouse.y)
                                        pinned = true
                                    }
                                }
                                onPinnedChanged: {
                                    if (!pinned) {
                                        // 取消固定后复位滚动位置，下次悬浮从块左上角开始显示
                                        gridFlick.contentX = 0
                                        gridFlick.contentY = 0
                                    }
                                }
                            }

                            // 块大小变化（顶部菜单"YUV 分析→块大小"）时，若当前有展示中的
                            // 块（悬浮或固定），立即按新块大小重新拉取，保持浮窗内容同步。
                            Connections {
                                target: YuvBridge
                                function onBlockSizeChanged() {
                                    if (pixelHoverArea.showPixelGrid) {
                                        pixelHoverArea.fetchAt(pixelHoverArea.pixelX, pixelHoverArea.pixelY)
                                        gridFlick.contentX = 0
                                        gridFlick.contentY = 0
                                    }
                                }
                            }

                            // ── 像素块 hover 高亮边框（尺寸跟随 YuvBridge.blockSize）──
                            Rectangle {
                                id: blockHighlight
                                visible: pixelHoverArea.showPixelGrid
                                width: YuvBridge.blockSize
                                height: YuvBridge.blockSize
                                color: "transparent"
                                border.color: pixelHoverArea.pinned ? "#3a6fd8" : "#00FF88"
                                border.width: 2
                                radius: 1

                                // 定位到当前像素所在的块（对齐到块边界）
                                x: {
                                    const imgW = YuvBridge.width(slotWin.index)
                                    const dispW = pixelHoverArea.width
                                    const offX = (dispW - imgW) / 2.0 + yuvDisp.panX
                                    const bs = YuvBridge.blockSize
                                    const blockX = Math.floor(pixelHoverArea.pixelX / bs) * bs
                                    return offX + blockX
                                }
                                y: {
                                    const imgH = YuvBridge.height(slotWin.index)
                                    const dispH = pixelHoverArea.height
                                    const offY = (dispH - imgH) / 2.0 + yuvDisp.panY
                                    const bs = YuvBridge.blockSize
                                    const blockY = Math.floor(pixelHoverArea.pixelY / bs) * bs
                                    return offY + blockY
                                }
                            }

                            // ── 像素矩阵浮窗（固定视口尺寸 + 固定单元格大小，块越大越靠滚动查看）──
                            Rectangle {
                                id: pixelGridPopup
                                readonly property int bs: YuvBridge.blockSize
                                visible: pixelHoverArea.showPixelGrid && pixelHoverArea.pixelData.length === bs * bs
                                width: 300
                                height: contentCol.implicitHeight + 16
                                radius: 6
                                color: "#1a1a22"
                                border.color: pixelHoverArea.pinned ? "#3a6fd8" : "#3a3a4a"
                                border.width: pixelHoverArea.pinned ? 2 : 1
                                opacity: 0.97

                                // 定位：未固定时智能避让跟随鼠标；固定后使用点击瞬间冻结的坐标
                                x: pixelHoverArea.pinned ? pixelHoverArea.pinnedPopupX
                                                          : pixelHoverArea.computePopupX(pixelHoverArea.mouseX)
                                y: pixelHoverArea.pinned ? pixelHoverArea.pinnedPopupY
                                                          : pixelHoverArea.computePopupY(pixelHoverArea.mouseY)

                                // 吞掉弹窗区域内的点击/悬浮事件，避免穿透到下层视频的
                                // pixelHoverArea（否则鼠标停在弹窗上方时会被误判为"点击视频"，
                                // 导致固定态被意外取消，或未固定态下反复错误重新定位）。
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton
                                    onClicked: {}
                                }

                                ColumnLayout {
                                    id: contentCol
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 4

                                    // 标题行：坐标范围 + 固定态提示 + 关闭按钮
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Text {
                                            Layout.fillWidth: true
                                            text: {
                                                const bs = pixelGridPopup.bs
                                                const bx = Math.floor(pixelHoverArea.pixelX / bs) * bs
                                                const by = Math.floor(pixelHoverArea.pixelY / bs) * bs
                                                return "像素块 [" + bx + "," + by + "] ~ [" + (bx+bs-1) + "," + (by+bs-1) + "]"
                                            }
                                            color: "#aaa"; font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            visible: pixelHoverArea.pinned
                                            text: "📌"
                                            font.pixelSize: 11
                                        }
                                        Rectangle {
                                            visible: pixelHoverArea.pinned
                                            width: 16; height: 16; radius: 8
                                            color: closeMa.containsMouse ? "#b85a5a" : "#2a2a34"
                                            Text {
                                                anchors.centerIn: parent
                                                text: "×"; color: "#f5a3a3"; font.pixelSize: 11; font.bold: true
                                            }
                                            MouseArea {
                                                id: closeMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: pixelHoverArea.pinned = false
                                            }
                                        }
                                    }

                                    // 固定态操作提示（未固定时提示可点击固定，固定后提示可滚动/取消）
                                    Text {
                                        Layout.fillWidth: true
                                        text: pixelHoverArea.pinned
                                              ? "已固定 · 拖动查看完整块 · 点击 × 或视频空白处取消"
                                              : "点击可固定窗口，支持滚动查看完整块"
                                        color: pixelHoverArea.pinned ? "#7fd3ff" : "#6a6f76"
                                        font.pixelSize: 9
                                        wrapMode: Text.WordWrap
                                    }

                                    // 通道选择 tabs — 与底部 YUV/Y/U/V 按钮同步
                                    //  YUV 模式（displayMode=0）默认显示 Y 平面
                                    //  Y / U / V 模式 → 矩阵自动切到对应通道
                                    //  矩阵里点击则反向同步回 YuvBridge（用户在悬浮窗里手动切换）
                                    Row {
                                        id: channelTabs
                                        spacing: 2
                                        property int channel: {
                                            const dm = YuvBridge.displayMode(slotWin.index)
                                            const _ = slotWin.ver   // 触发 displayMode 变化时刷新
                                            if (dm === 2) return 1  // U
                                            if (dm === 3) return 2  // V
                                            return 0               // YUV / Y → Y
                                        }

                                        Repeater {
                                            model: ["Y", "U", "V"]
                                            delegate: Rectangle {
                                                required property int index
                                                required property string modelData
                                                width: 30; height: 18; radius: 3
                                                color: parent.channel === index ? "#3a6fd8" : "#2a2a34"
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: modelData
                                                    color: parent.parent.channel === index ? "#fff" : "#888"
                                                    font.pixelSize: 10; font.bold: true
                                                }
                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        // 1) 立即更新本地 channel（让 UI 立刻响应）
                                                        parent.parent.channel = index
                                                        // 2) 同步到 YuvBridge 的显示模式
                                                        //    matrix Y → displayMode 1 (Y)
                                                        //    matrix U → displayMode 2 (U)
                                                        //    matrix V → displayMode 3 (V)
                                                        const dm = (index === 0) ? 1 : (index === 1 ? 2 : 3)
                                                        YuvBridge.setDisplayMode(slotWin.index, dm)
                                                    }
                                                }
                                            }
                                        }

                                        // 用于外部引用
                                        function getChannel() { return channel }
                                    }

                                    // 固定尺寸视口 + 行/列偏移刻度：
                                    //   顶部刻度＝列偏移（块内 x，0 起），左侧刻度＝行偏移（块内 y，0 起）；
                                    //   随 gridFlick 的 contentX/contentY 同步滚动，方便对照当前滑到了块内哪个位置。
                                    // 注：用 Item + 显式 x/y/width/height 硬定位（而非 Layout 自动协商尺寸），
                                    //   避免刻度与主网格互相引用尺寸形成绑定环、也避免括号计数出错。
                                    Item {
                                        id: gridWithRulers
                                        readonly property int rulerSize: 16
                                        readonly property int cellSize: 30
                                        readonly property int cellSpacing: 1
                                        readonly property int viewCells: 8
                                        readonly property int gridSpan: viewCells * cellSize + (viewCells - 1) * cellSpacing

                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: rulerSize + gridSpan
                                        Layout.preferredHeight: rulerSize + gridSpan

                                        // 顶部刻度：列偏移（跟随 gridFlick 水平滚动）
                                        Flickable {
                                            id: hRuler
                                            x: gridWithRulers.rulerSize
                                            y: 0
                                            width: gridWithRulers.gridSpan
                                            height: gridWithRulers.rulerSize
                                            clip: true
                                            interactive: false
                                            boundsBehavior: Flickable.StopAtBounds
                                            contentX: gridFlick.contentX
                                            contentWidth: pixelGrid.width
                                            contentHeight: height

                                            Row {
                                                spacing: gridWithRulers.cellSpacing
                                                Repeater {
                                                    model: pixelGrid.bs
                                                    delegate: Text {
                                                        required property int index
                                                        width: gridWithRulers.cellSize
                                                        height: hRuler.height
                                                        horizontalAlignment: Text.AlignHCenter
                                                        verticalAlignment: Text.AlignVCenter
                                                        text: index
                                                        color: "#6a6f76"
                                                        font.pixelSize: 9
                                                        font.family: "Menlo, Monaco, Consolas, monospace"
                                                    }
                                                }
                                            }
                                        }

                                        // 左侧刻度：行偏移（跟随 gridFlick 垂直滚动）
                                        Flickable {
                                            id: vRuler
                                            x: 0
                                            y: gridWithRulers.rulerSize
                                            width: gridWithRulers.rulerSize
                                            height: gridWithRulers.gridSpan
                                            clip: true
                                            interactive: false
                                            boundsBehavior: Flickable.StopAtBounds
                                            contentY: gridFlick.contentY
                                            contentWidth: width
                                            contentHeight: pixelGrid.height

                                            Column {
                                                spacing: gridWithRulers.cellSpacing
                                                Repeater {
                                                    model: pixelGrid.bs
                                                    delegate: Text {
                                                        required property int index
                                                        width: vRuler.width
                                                        height: gridWithRulers.cellSize
                                                        horizontalAlignment: Text.AlignHCenter
                                                        verticalAlignment: Text.AlignVCenter
                                                        text: index
                                                        color: "#6a6f76"
                                                        font.pixelSize: 9
                                                        font.family: "Menlo, Monaco, Consolas, monospace"
                                                    }
                                                }
                                            }
                                        }

                                        // 固定尺寸视口：单元格大小恒定（不随块大小自适应缩小），
                                        // 块越大只展示可视区域，需固定后拖动查看其余部分。
                                        Flickable {
                                            id: gridFlick
                                            x: gridWithRulers.rulerSize
                                            y: gridWithRulers.rulerSize
                                            width: gridWithRulers.gridSpan
                                            height: gridWithRulers.gridSpan
                                            readonly property int cellSize: gridWithRulers.cellSize
                                            readonly property int cellSpacing: gridWithRulers.cellSpacing
                                            readonly property int viewCells: gridWithRulers.viewCells
                                            clip: true
                                            interactive: pixelHoverArea.pinned
                                            boundsBehavior: Flickable.StopAtBounds
                                            contentWidth: pixelGrid.width
                                            contentHeight: pixelGrid.height
                                            ScrollBar.vertical: ScrollBar {
                                                policy: pixelHoverArea.pinned ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                                            }
                                            ScrollBar.horizontal: ScrollBar {
                                                policy: pixelHoverArea.pinned ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                                            }

                                        Grid {
                                            id: pixelGrid
                                            readonly property int bs: YuvBridge.blockSize
                                            columns: bs
                                            rows: bs
                                            spacing: gridFlick.cellSpacing

                                            property int channel: channelTabs ? channelTabs.channel : 0

                                            // 当前通道下、当前块的原始值域（不用位深，按真实数据自适应）
                                            //   - 8bit 块：0-255
                                            //   - 10bit 块：0-1023
                                            //   - 极端全黑/全亮：min==max，span=1，"t" 退化为 0（保证不出错）
                                            property int blockMin: 0
                                            property int blockMax: 1
                                            function recomputeRange() {
                                                const n = bs * bs
                                                if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length !== n) {
                                                    blockMin = 0; blockMax = 1; return
                                                }
                                                const ch = channel
                                                let mn = 65535, mx = -1
                                                for (let i = 0; i < n; ++i) {
                                                    const v = ch === 0 ? pixelHoverArea.pixelData[i].y
                                                                      : (ch === 1 ? pixelHoverArea.pixelData[i].u
                                                                                  : pixelHoverArea.pixelData[i].v)
                                                    if (v < mn) mn = v
                                                    if (v > mx) mx = v
                                                }
                                                if (mn === mx) { blockMin = mn; blockMax = mn + 1 }
                                                else           { blockMin = mn; blockMax = mx }
                                            }
                                            // 通道/块大小/数据任一变化都要重算
                                            onChannelChanged: recomputeRange()
                                            onBsChanged: recomputeRange()
                                            Component.onCompleted: recomputeRange()
                                            Connections {
                                                target: pixelHoverArea
                                                function onPixelDataChanged() { pixelGrid.recomputeRange() }
                                            }

                                            Repeater {
                                                model: pixelGrid.bs * pixelGrid.bs
                                                delegate: Rectangle {
                                                    required property int index
                                                    width: gridFlick.cellSize
                                                    height: gridFlick.cellSize
                                                    radius: 2
                                                    color: {
                                                        if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length <= index)
                                                            return "#222"
                                                        const pix = pixelHoverArea.pixelData[index]
                                                        const ch = pixelGrid.channel
                                                        const raw = ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                                        // ── 自适应背景色 ──
                                                        // 像素值按"位深未知"处理：直接拿当前块的动态范围 (min..max) 归一化。
                                                        // 这样 8bit (0-255) 和 10bit (0-1023) 都能用，亮块/暗块都能看清。
                                                        const refMin = pixelGrid.blockMin || 0
                                                        const refMax = pixelGrid.blockMax || 1
                                                        const span = Math.max(1, refMax - refMin)
                                                        const t = Math.max(0, Math.min(1, (raw - refMin) / span))
                                                        // 背景：暗端 #0f1218 → 亮端 #4a5268（中等灰蓝），永远不和文字撞色
                                                        const r = Math.round(15 + t * 55)
                                                        const g = Math.round(18 + t * 60)
                                                        const b = Math.round(24 + t * 72)
                                                        return Qt.rgba(r/255, g/255, b/255, 1.0)
                                                    }

                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: {
                                                            if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length <= index)
                                                                return ""
                                                            const pix = pixelHoverArea.pixelData[index]
                                                            const ch = pixelGrid.channel
                                                            return ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                                        }
                                                        // 文字：按"靠近 0 还是靠近 255"自动反色，做绝对对比
                                                        // 改用感知亮度公式 (luma) 判定：阈值 0.5
                                                        color: {
                                                            if (!pixelHoverArea.pixelData || pixelHoverArea.pixelData.length <= index)
                                                                return "#e0e0e0"
                                                            const pix = pixelHoverArea.pixelData[index]
                                                            const ch = pixelGrid.channel
                                                            const raw = ch === 0 ? pix.y : (ch === 1 ? pix.u : pix.v)
                                                            const refMin = pixelGrid.blockMin || 0
                                                            const refMax = pixelGrid.blockMax || 1
                                                            const span = Math.max(1, refMax - refMin)
                                                            const t = Math.max(0, Math.min(1, (raw - refMin) / span))
                                                            // 背景的近似亮度曲线（与上面同步）
                                                            const lum = (0.299 * (15 + t*55) + 0.587 * (18 + t*60) + 0.114 * (24 + t*72)) / 255
                                                            return lum > 0.55 ? "#0a0a0a" : "#f0f0f0"
                                                        }
                                                        font.pixelSize: 10
                                                        font.family: "Menlo, Monaco, Consolas, monospace"
                                                        font.bold: true
                                                    }
                                                }
                                            }
                                        } // end Grid pixelGrid
                                        } // end Flickable gridFlick
                                    } // end Item gridWithRulers

                                    // 块 YUV 统计：avg / min / max 三行合一，用 | 分隔
                                    Column {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        property var s: pixelHoverArea.pixelStats || {}
                                        property bool ready: (typeof s.yAvg === "number")

                                        Text {
                                            visible: parent.ready
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                            text: "<span style=\"color:#6cf\">avg</span> (" + parent.s.yAvg + ", " + parent.s.uAvg + ", " + parent.s.vAvg + ")"
                                                + "  <span style=\"color:#6c8\">min</span> (" + parent.s.yMin + ", " + parent.s.uMin + ", " + parent.s.vMin + ")"
                                                + "  <span style=\"color:#e86\">max</span> (" + parent.s.yMax + ", " + parent.s.uMax + ", " + parent.s.vMax + ")"
                                            color: "#dde"; font.pixelSize: 10; font.bold: true
                                            font.family: "Menlo, Monaco, Consolas, monospace"
                                            textFormat: Text.RichText
                                        }
                                    }
                                }
                            }
                        }

                        // ── 底部控制栏 ──
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            color: "#18181c"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 4

                                // 通道切换按钮（紧凑胶囊样式）
                                Row {
                                    spacing: 0

                                    Repeater {
                                        model: ["YUV", "Y", "U", "V"]
                                        delegate: Rectangle {
                                            required property int index
                                            required property string modelData

                                            property bool isActive: {
                                                const _ = slotWin.ver
                                                return YuvBridge.displayMode(slotWin.index) === index
                                            }

                                            width: index === 0 ? 38 : 28
                                            height: 22
                                            radius: index === 0 ? 4 : (index === 3 ? 4 : 0)

                                            // 胶囊左右圆角
                                            Rectangle {
                                                visible: index === 0
                                                anchors.right: parent.right
                                                width: parent.radius
                                                height: parent.height
                                                color: parent.color
                                            }
                                            Rectangle {
                                                visible: index === 3
                                                anchors.left: parent.left
                                                width: parent.radius
                                                height: parent.height
                                                color: parent.color
                                            }

                                            color: isActive ? "#e05050" : "#2a2a34"
                                            border.color: isActive ? "#e05050" : "#3a3a44"
                                            border.width: isActive ? 0 : 1

                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData
                                                color: isActive ? "#fff" : "#aaa"
                                                font.pixelSize: 10
                                                font.bold: isActive
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: YuvBridge.setDisplayMode(slotWin.index, index)
                                            }
                                        }
                                    }
                                }

                                Item { width: 8 }

                                // 帧号显示
                                Text {
                                    text: {
                                        const _ = slotWin.ver
                                        return (YuvBridge.currentFrame(slotWin.index) + 1) + "/" +
                                               YuvBridge.totalFrames(slotWin.index)
                                    }
                                    color: "#9aa0a6"; font.pixelSize: 11
                                }

                                Item { Layout.fillWidth: true }

                                // 帧导航 + 播放控制按钮
                                Row {
                                    spacing: 2

                                    // 快退 15 帧
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navSkipBackMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "⏮"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navSkipBackMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.skipBackward(slotWin.index, 15)
                                        }
                                    }
                                    // 帧后退（上一帧）
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navPrevMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "◀"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navPrevMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.prevFrame(slotWin.index)
                                        }
                                    }
                                    // 播放/暂停
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navPlayMa.containsMouse ? "#3a6fd8" : "#2a5fc0"
                                        Text {
                                            anchors.centerIn: parent
                                            text: {
                                                const _ = slotWin.ver
                                                return YuvBridge.isPlaying(slotWin.index) ? "⏸" : "▶"
                                            }
                                            color: "#fff"; font.pixelSize: 11
                                        }
                                        MouseArea {
                                            id: navPlayMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.togglePlayPause(slotWin.index)
                                        }
                                    }
                                    // 帧前进（下一帧）
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navNextMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "▶"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navNextMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.nextFrame(slotWin.index)
                                        }
                                    }
                                    // 快进 15 帧
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navSkipFwdMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "⏭"; color: "#ccc"; font.pixelSize: 11 }
                                        MouseArea {
                                            id: navSkipFwdMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.skipForward(slotWin.index, 15)
                                        }
                                    }

                                    Item { width: 8 }

                                    // 重置（回首帧）
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navResetMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "↺"; color: "#ccc"; font.pixelSize: 14 }
                                        MouseArea {
                                            id: navResetMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: YuvBridge.resetFrame(slotWin.index)
                                        }
                                    }
                                    // 倒放
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: {
                                            const _ = slotWin.ver
                                            if (YuvBridge.isReversing(slotWin.index)) return "#b85a5a"
                                            return navRevMa.containsMouse ? "#3a3a3d" : "#252528"
                                        }
                                        Text { anchors.centerIn: parent; text: "◀◀"; color: "#ccc"; font.pixelSize: 9 }
                                        MouseArea {
                                            id: navRevMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (YuvBridge.isReversing(slotWin.index))
                                                    YuvBridge.pause(slotWin.index)
                                                else
                                                    YuvBridge.playReverse(slotWin.index)
                                            }
                                        }
                                    }

                                    Item { width: 8 }

                                    // 一键居中（重置平移）
                                    Rectangle {
                                        width: 28; height: 22; radius: 3
                                        color: navCenterMa.containsMouse ? "#3a3a3d" : "#252528"
                                        Text { anchors.centerIn: parent; text: "⊙"; color: "#ccc"; font.pixelSize: 13 }
                                        MouseArea {
                                            id: navCenterMa; anchors.fill: parent
                                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                yuvDisp.panX = 0
                                                yuvDisp.panY = 0
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
