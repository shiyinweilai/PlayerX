// VideoCellDelegate.qml — 视频宫格单元格组件
//
// 设计目标
// --------
// 把原 Main.qml > Grid > Repeater 内联展开的 cell delegate 抽离为独立组件，
// 行为/视觉与原内联实现 100% 等价（仅做"挪窝"，不动逻辑）。这样做的好处：
//   1. Main.qml 体积大幅缩小（从 4757 行降到 ~4100 行），可读性提升；
//   2. 后续接入图片模式 / 其他媒体模式时，只需新增一个同形态的 *CellDelegate.qml，
//      Repeater 用 Loader 按当前媒体类型切换 sourceComponent 即可，宫格容器
//      （Grid/视频区/HUD/快捷键）完全不用改；
//   3. 独立组件天然可单独测试 / 热重载，迭代成本更低。
//
// 对外接口
// --------
//   property int  playerIdx — 当前 cell 对应的 player 索引（由 Repeater 通过
//                              viewRoot.slotPlayerIndex(index) 计算后传入）。
//   property var  viewRoot   — Main.qml 的 ApplicationWindow root。子组件通过它
//                              访问 fmtTime / 评分 / 选中态 / 可见性等共享状态，
//                              以及 openReplaceFor / focusVideoArea 等透传函数。
//
// 注意：Engine / Reference / Rating 等 QML 单例可全局直接引用，无需注入；
//       FlatToolButton 是 Main.qml 内 inline component，会通过组件父级上下文继承。
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import PlayerX 1.0

Rectangle {
    // 顶层属性（抽离唯一新增）：playerIdx / viewRoot；其余沿用原 cell 内属性。
    property int  playerIdx: -1
    property var  viewRoot:  null

    id: cell
    width:  (parent.width  - parent.spacing * (parent.columns - 1)) / Math.max(1, parent.columns)
    height: (parent.height - parent.spacing * (parent.rows    - 1)) / Math.max(1, parent.rows)
    color: "#000"
    // 选中边框：跟随 viewRoot.selectedIdx（QML 层显式选中状态），不跟
    // Engine.activeIndex —— 这样默认 selectedIdx=-1 时不会有任何
    // cell 被高亮，避免视觉干扰；点击空白也能取消选中。
    //   - 配色用低饱和雾蓝 #4a6fa5：辨识度足够，但比 #3a7afe 柔和
    //   - 未选中保持深灰 #222，与原视觉一致
    //   - 120ms 过渡，切换 / 评分时观感顺滑
    readonly property bool _isActive: viewRoot.selectedIdx === cell.playerIdx
    border.color: cell._isActive ? "#4a6fa5" : "#222"
    border.width: 2
    Behavior on border.color { ColorAnimation { duration: 120 } }


    // ─── 单路状态（依赖 Engine 每帧 tick 时发出的 positionChanged）──
    // 通过函数代替属性绑定，强制每次 Engine.position 变化都重新求值，
    // 这样单路时间/进度条与该路真实播放位置保持同步。
    function _pos() { Engine.position; return Engine.positionAt(cell.playerIdx) }
    function _dur() { Engine.duration; return Engine.durationAt(cell.playerIdx) }
    function _playing() { Engine.playing; return Engine.playingAt(cell.playerIdx) }

    VideoFrameProvider {
        id: vp
        anchors.fill: parent
        anchors.margins: 2
        engine: Engine
        playerIndex: cell.playerIdx
        // 关闭 QtQuick 场景图对本 Item 的纹理插值。本 Item 内部
        // 已经用 sws Lanczos 把帧缩到屏幕物理像素并 1:1 上屏，
        // QtQuick 再做双线性会引入二次重采样 → 网格伪影/字模糊。
        smooth: false
        antialiasing: false
    }

    // 序号徽标（受全局"通道信息"开关控制，默认显示）
    Rectangle {
        id: idxBadge
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 6
        width: 22; height: 22; radius: 4
        color: "#cc000000"
        z: 5
        visible: viewRoot.effectiveChannelVisible
        Label {
            anchors.centerIn: parent
            text: cell.playerIdx + 1
            color: "white"
            font.bold: true
        }
    }

    // 顶部左上角"路径胶囊"：紧贴序号徽标右侧，显性显示 父目录/文件名。
    //
    // 设计动机（方案 B）
    // -----------------
    //   原本路径塞在右上 channelBar 里，与 帧号/时间/星条/⋯/⤢/✕ 共抢一行；
    //   三宫格小窗下右侧固定占用 ≈270px，留给路径只剩 <100px，文件名经常被
    //   省略到只剩 "1…"，无法区分多路同名 1.mp4。
    //
    //   方案 B 把路径独立成左上角自有胶囊，与 channelBar 同 y、不增加遮挡高度，
    //   宽度上限独立计算（cell 宽 ≈55%），且不与右侧按钮区争夺空间。
    //
    //   左 = "是谁"（路径） | 右 = "是什么状态/能做什么"（数据 + 操作按钮）。
    //
    // 显隐与样式
    // -----------
    //   · 与 channelBar 共用 effectiveChannelVisible：按 C 一并隐藏；
    //   · 整体 hover 弹 ToolTip 显示完整路径，便于深层目录辨识；
    //   · 文件名末尾省略（ElideRight），目录段始终完整显示。
    Rectangle {
        id: pathBar
        anchors.left: idxBadge.right
        anchors.top: idxBadge.top
        anchors.leftMargin: 6
        radius: 3
        // 调稀透明度（0xaa≈67% → 0x33≈20%），在不遮挡画面的前提下
        // 保留一点点软遮罩，避免路径/文件名文字与同色底画面贴一起不可读。
        color: "#33000000"
        z: 5
        visible: viewRoot.effectiveChannelVisible && fileNameLabel.text !== "—"
        // 宽度上限：不再写死"扣 280"，而是动态跟随右上 channelBar 的实际宽度。
        // 公式： cell宽 − idxBadge右边 − leftMargin(6) − channelBar实宽 − channelBar右锁margin(6) − 安全间距(8)
        // 这样 HUD 变窄后 pathBar 可以跨越原本被 280 硕占的区域，三宫格中也能尽量完整显示。
        // channelBar 不可见时 (effectiveChannelVisible=false) 以 0 计，路径可独享整个顶部。
        readonly property int _channelOccupiedW: channelBar.visible ? (channelBar.width + 6 + 8) : 8
        readonly property int _maxAvailWidth:
            Math.max(80, cell.width - (idxBadge.x + idxBadge.width) - 6 - _channelOccupiedW)
        implicitWidth:  pathRow.implicitWidth + 12
        implicitHeight: pathRow.implicitHeight + 4
        width:  Math.min(implicitWidth, _maxAvailWidth)
        height: implicitHeight

        // 路径解析：拆出 dir / file 两段；显式引用 Engine.titles 让本绑定能在
        // 视频切换 / 替换时自动重算（titles 带 NOTIFY filesChanged）。
        readonly property var pathInfo: {
            var _dep = Engine.titles
            var p = Engine.filePathAt(cell.playerIdx)
            if (!p || p.length === 0) return { dir: "", file: "—" }
            var norm = p.replace(/\\/g, "/")
            var parts = norm.split("/")
            var fname = parts.length > 0 ? parts[parts.length - 1] : norm
            var parent = parts.length > 1 ? parts[parts.length - 2] : ""
            return { dir: parent, file: fname }
        }

        RowLayout {
            id: pathRow
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            spacing: 0

            Item {
                id: pathInner
                Layout.fillWidth: true
                Layout.preferredHeight: 14
                Layout.preferredWidth: dirPrefixLabel.implicitWidth + fileNameLabel.implicitWidth
                Layout.minimumWidth: Math.min(dirPrefixLabel.implicitWidth + 16, 160)

                // 目录段：永远完整显示（不省略），靠左
                Text {
                    id: dirPrefixLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#9fd3ff"          // 略偏冷色，让目录与文件名一眼可辨
                    font.pixelSize: 11
                    text: pathBar.pathInfo.dir.length > 0
                          ? (pathBar.pathInfo.dir + "/")
                          : ""
                }
                // 文件名段：占用剩余宽度，超出从尾部省略
                Text {
                    id: fileNameLabel
                    anchors.left: dirPrefixLabel.right
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#e8e8ec"
                    font.pixelSize: 11
                    elide: Text.ElideRight    // 文件名尾部省略
                    text: pathBar.pathInfo.file
                }
            }
        }

        ToolTip.visible: pathHover.containsMouse && fileNameLabel.text !== "—"
        ToolTip.delay: 400
        ToolTip.timeout: 8000
        ToolTip.text: {
            var _dep = Engine.titles
            var p = Engine.filePathAt(cell.playerIdx)
            return (p && p.length > 0) ? p : ""
        }
        MouseArea {
            id: pathHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton  // 仅悬停显示 ToolTip，不拦截点击
        }
    }

    // 顶部右侧"通道信息"胶囊条：帧号 · 时间戳 · 文件名。
    // 受全局"通道信息"开关控制，默认显示；帧号/时间戳随 Engine.position 自动刷新。
    Rectangle {
        id: channelBar
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 6
        radius: 3
        // 调稀透明度（0xaa≈67% → 0x33≈20%），与 pathBar 保持一致：
        // 足以让星字/帧号/时间/按钮从亮底视频中跨出来，又不会遮挡画面。
        color: "#22000000"
        z: 5
        visible: viewRoot.effectiveChannelVisible
        // 宽/高按内容自适应；同时设"可用上限"避免文件名过长把胶囊条
        // 撑出本路 cell 边界（参考图：右路 ours_hysj.../1.mp4 越界到下一路）。
        // 上限 = cell 宽 − 右锚 margin (6) − 左上角序号徽标占位 (22+6 margin+6 安全间距 = 34) ≈ cell.width − 40。
        // 当 implicitWidth 超过上限时，width 收敛到上限，channelRow 在 anchors.fill
        // 下被同步压缩，唯一可压缩项 pathLabelWrap 触发 ElideLeft 省略。
        readonly property int _maxAvailWidth: Math.max(120, cell.width - 40)
        implicitWidth:  channelCol.implicitWidth + 12
        implicitHeight: channelCol.implicitHeight + 6
        width:  Math.min(implicitWidth, _maxAvailWidth)
        height: implicitHeight

        // 动态信息（帧号/时间戳）随引擎位置变化刷新
        property var info: ({})
        function refreshInfo() {
            if (visible) info = Engine.videoInfoAt(cell.playerIdx)
        }
        Connections {
            target: Engine
            function onPositionChanged() { channelBar.refreshInfo() }
        }
        onVisibleChanged: refreshInfo()
        Component.onCompleted: refreshInfo()

        // 两行布局（ColumnLayout）：
        //   第 1 行：评分星条 + 操作按钮（⋯ ⤢ ✕）—— 用户高频交互的入口
        //   第 2 行：帧号 + 时间戳            —— 仅展示用的实时数据
        // 两行整体右对齐（每行内部 anchors.right→parent.right），
        // channelBar 宽度由两行 implicitWidth 的较大者决定。
        ColumnLayout {
            id: channelCol
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            spacing: 2

            // ────── 第 1 行：评分 + 操作按钮 ──────
            RowLayout {
                id: channelRowTop
                Layout.alignment: Qt.AlignRight
                spacing: 6

                // 内联评分星条（仅在 viewRoot.reviewMode 开启时显示，否则整段 0 宽不占位）：
                //  · 单击第 N 颗星 → 写入 N 分（与原 cellMenu 内星条一致逻辑）
                //  · 右键任意位置  → 清空（0 分），方便误评后修正
                //  · 鼠标悬停时整条变成"预览态"，移开还原当前真实分值
            // 设计意图：开启评分模式后，5 颗星和"是否已评分"应该在 cell
            // 上一眼可见，而不是要点 ⋯ 菜单才看见——这条要求来自图 1 / 图 2。
            Rectangle {
                visible: viewRoot.reviewMode
                Layout.preferredWidth: 1
                Layout.preferredHeight: 12
                color: "#55ffffff"
            }
            Row {
                id: inlineStarRow
                visible: viewRoot.reviewMode
                spacing: 1
                // 鼠标悬停预览（0 = 未悬停，显示真实分值）。
                property int hoverRating: 0
                // 实时读取真实分值；ratingAt 依赖 cellRatings 数组属性，
                // 整体替换写入会触发绑定刷新。
                readonly property int currentRating: {
                    // 显式引用 viewRoot.cellRatings 让本绑定依赖它，
                    // 写分（_writeRating 整体替换数组）后能自动重算。
                    var arr = viewRoot.cellRatings
                    var i = cell.playerIdx
                    if (i < 0 || i >= arr.length) return 0
                    var v = arr[i]
                    return (typeof v === "number" && v > 0) ? v : 0
                }
                Repeater {
                // 当前模式的星级上限：主观评分=5 / 质量比较=2；Rating 实例不在时兜底 5
                    model: viewRoot.reviewMaxStars > 0 ? viewRoot.reviewMaxStars : 5
                    delegate: Item {
                        width: 14
                        height: 14
                        property int starIndex: index + 1
                        property bool active: inlineStarRow.hoverRating > 0
                            ? starIndex <= inlineStarRow.hoverRating
                            : starIndex <= inlineStarRow.currentRating
                        Text {
                            anchors.centerIn: parent
                            text: parent.active ? "★" : "☆"
                            color: parent.active ? "#f5c518" : "#bfc4ca"
                            font.pixelSize: 13
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onEntered: inlineStarRow.hoverRating = parent.starIndex
                            onExited:  inlineStarRow.hoverRating = 0
                            onClicked: function(mouse) {
                                if (mouse.button === Qt.RightButton) {
                                    // 右键清空评分（0 = 未评）
                                    viewRoot._writeRating(cell.playerIdx, 0)
                                } else {
                                    // 左键写入 N 分（强制覆盖，与 Shift+N 快捷键一致）
                                    viewRoot._writeRating(cell.playerIdx, parent.starIndex)
                                }
                                inlineStarRow.hoverRating = 0
                            }
                        }
                    }
                }
                ToolTip.visible: inlineStarRow.hoverRating > 0
                ToolTip.delay: 200
                ToolTip.timeout: 1500
                ToolTip.text: "左键打分 · 右键清空"
            }
            // 文件名已从胶囊条移除：
            // 【cell hover 工具按钮】两个同风格的圆点：⋯ 替换本路、✕ 关闭本路。
            // 二者均常驻显示（不随鼠标移出 cell 消失），仅在用户按 C
            // 关闭通道信息条 / 全屏抑制角标时才隐藏，避免按钮闪烁或定位丢失。
            //  - ⋯：单击直接进入「替换本路视频」流程；hover 显示完整路径
            //         （新增一路已在顶部工具栏／下拉菜单提供，cell 内不再重复）
            //  - ✕：调 Engine.closeAt(idx)，fileCount 变化会触发 visibleCount/Repeater
            //         重新求值，UI 自动收拢。
            // ⋯ 按钮：单击直接进入「替换本路视频」流程；
            // 评分入口已迁到顶部内联星条（reviewMode 开启时常驻），
            // 不再需要弹出菜单，避免「2.mp4」这类短文件名让弹窗右侧出现大片空白。
            // hover 时 ToolTip 显示当前路的完整绝对路径，便于在「同名不同目录」场景下区分。
            Rectangle {
                id: moreBtn
                Layout.preferredWidth: 18
                Layout.preferredHeight: 18
                Layout.leftMargin: 2
                radius: 9
                visible: viewRoot.effectiveChannelVisible
                color: replaceArea.containsMouse ? "#3a78c8"
                      : replaceArea.pressed     ? "#2a5994"
                                                : "#55ffffff"
                Behavior on color { ColorAnimation { duration: 90 } }
                Text {
                    anchors.centerIn: parent
                    // 用水平三点 ⋯（macOS/iOS/Material 通用的"更多/打开选项"语义），
                    // 避开 ↻ 与"重置/重新加载"视觉撞车。需要靠下半像素才视觉居中。
                    anchors.verticalCenterOffset: -1
                    text: "⋯"
                    color: "white"
                    font.pixelSize: 14
                    font.bold: true
                }
                MouseArea {
                    id: replaceArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // 直接走替换流程：viewRoot 上的 openReplaceFor 包办两步
                        // (pendingReplaceIdx 写入 + replaceDialog.open())
                        viewRoot.openReplaceFor(cell.playerIdx)
                    }
                }
                ToolTip.visible: replaceArea.containsMouse
                ToolTip.delay: 400
                ToolTip.timeout: 8000
                // 显示完整路径；用 Engine.titles 作响应式依赖（titles 带 NOTIFY filesChanged），
                // 切换 / 替换视频后 ToolTip 文本会自动刷新；路径取不到时回退到文件名。
                ToolTip.text: {
                    var arr = Engine.titles
                    var i = cell.playerIdx
                    var p = Engine.filePathAt(i)
                    if (p && p.length > 0) return p
                    return (i >= 0 && i < arr.length) ? arr[i] : "替换本路视频"
                }
            }
            // 【cell hover 工具按钮】放大/还原本路：等价于按数字键 1..9。
            //   · 当前不是单路视图，或单路视图但聚焦的不是本路 → 进入单路并聚焦本路（=放大）
            //   · 当前是单路视图且聚焦的就是本路           → 回到上次的多路布局（=还原）
            // 复用 viewRoot._toggleOne(idx)，与数字键完全同一套行为，不重复实现。
            // 用方框图标 ⤢ / ⤡ 区分两态：放大态显示 ⤡（视觉上"缩回"），多路态显示 ⤢。
            Rectangle {
                id: zoomBtn
                Layout.preferredWidth: 18
                Layout.preferredHeight: 18
                Layout.leftMargin: 2
                radius: 9
                visible: viewRoot.effectiveChannelVisible
                // 当前是否处于"本路单路放大"态
                readonly property bool isSolo:
                    Engine.layoutMode === 0
                    && Engine.activeIndex === cell.playerIdx
                color: zoomArea.containsMouse ? "#3a78c8"
                      : zoomArea.pressed     ? "#2a5994"
                                             : "#55ffffff"
                Behavior on color { ColorAnimation { duration: 90 } }
                Text {
                    anchors.centerIn: parent
                    // ⤢ = 放大（four arrows out）；⤡ = 缩回（arrows in）
                    // 这两个 Unicode 在大部分平台都有完整字形，无需依赖 SF Symbols。
                    text: zoomBtn.isSolo ? "⤡" : "⤢"
                    color: "white"
                    font.pixelSize: 12
                    font.bold: true
                }
                MouseArea {
                    id: zoomArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: viewRoot._toggleOne(cell.playerIdx)
                }
                ToolTip.visible: zoomArea.containsMouse
                ToolTip.delay: 400
                ToolTip.timeout: 3000
                ToolTip.text: zoomBtn.isSolo
                              ? "还原多路布局（同：再按数字键）"
                              : "放大本路（等同按数字键 " + (cell.playerIdx + 1) + "）"
            }
            // 关闭本路的 ✕ 按钮：常驻显示（不随 hover 消失），仅当用户按 C
            // 关闭通道信息条 / 全屏抑制角标时才隐藏，与同一行的 #idx·时间·文件名
            // 信息条共用一套可见性，避免鼠标在 ⋯/✕ 与 cell 边缘之间
            // 闪掉、菜单边缘抖动。
            // 调用 Engine.closeAt(idx) 后，fileCount 变化会触发 visibleCount/Repeater
            // 重新求值，UI 自动收拢 —— 不需要额外手动刷新。
            Rectangle {
                Layout.preferredWidth: 18
                Layout.preferredHeight: 18
                Layout.leftMargin: 2
                radius: 9
                visible: viewRoot.effectiveChannelVisible
                color: closeArea.containsMouse ? "#e0454d"
                      : closeArea.pressed     ? "#a83239"
                                              : "#55ffffff"
                Behavior on color { ColorAnimation { duration: 90 } }
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: "white"
                    font.pixelSize: 11
                    font.bold: true
                }
                MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Engine.closeAt(cell.playerIdx)
                }
                ToolTip.visible: closeArea.containsMouse
                ToolTip.delay: 600
                ToolTip.timeout: 3000
                ToolTip.text: "关闭本路视频"
            }
            }   // ← end of channelRowTop（第 1 行：星条 + ⋯ + ⤢ + ✕）

            // ──────── 第 2 行：帧号 + 时间戳（实时数据） ────────
            // 仅展示用，不交互；右对齐贴齐 channelBar 右边界。
            // 单独成行后，避免与第 1 行的星条/按钮抢同一行的可用宽度，
            // 三宫格小窗下也能完整显示「#frame · 0.000s」。
            RowLayout {
                id: channelRowBottom
                Layout.alignment: Qt.AlignRight
                spacing: 8

                // 帧号（固定最小宽度，避免 1/2/3/4 位数字之间抖动）
                Text {
                    color: "#e8e8ec"
                    font.pixelSize: 11
                    font.family: "Menlo, Monaco, Courier New, monospace"
                    horizontalAlignment: Text.AlignRight
                    Layout.minimumWidth: 56
                    Layout.preferredWidth: 56
                    text: channelBar.info.frameNum !== undefined
                          ? "#" + channelBar.info.frameNum
                          : "#—"
                }
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 12
                    color: "#55ffffff"
                }
                // 时间戳（固定最小宽度，避免抖动）
                Text {
                    color: "#e8e8ec"
                    font.pixelSize: 11
                    font.family: "Menlo, Monaco, Courier New, monospace"
                    horizontalAlignment: Text.AlignRight
                    Layout.minimumWidth: 70
                    Layout.preferredWidth: 70
                    text: channelBar.info.pts !== undefined
                          ? channelBar.info.pts.toFixed(3) + "s"
                          : "—"
                }
            }
        }   // ← end of channelCol（ColumnLayout 两行布局）
    }

    // 评分入口已迁至顶部胶囊条 channelBar 的内联星条（reviewMode 开启时常驻显示），
    // ⋯ 按钮单击即触发替换流程，不再需要中间的 Popup 菜单。
    // 这样可避免短文件名（如 "2.mp4"）导致弹窗右侧大片空白；
    // 同时三点按钮的 ToolTip 已直接显示完整路径，便于区分同名不同目录。

    // 鼠标交互：单击选中、双击切换该路暂停
    // 注意：_pos / _dur / _playing 在上面已定义，这里不重复
    // 注意：MouseArea 仅用于点击/双击。hover 检测改用下面的 HoverHandler，
    // 因为 MouseArea.containsMouse 会被子项（ToolButton 等）截获，
    // 导致鼠标移到工具条按钮上时 cellMouse.containsMouse 变 false → 工具条隐藏
    // → 按钮也消失 → 鼠标又"回到"cell → 工具条出现……陷入抖动闪烁。
    MouseArea {
        id: cellMouse
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                // 右键：刷新信息并切换信息面板显示
                cell.localInfoVisible = !cell.localInfoVisible
            } else {
                Engine.activeIndex = cell.playerIdx
                viewRoot.selectedIdx   = cell.playerIdx   // 同步 UI 选中态
                viewRoot.focusVideoArea()
            }
        }
        onDoubleClicked: (mouse) => {
            // 仅在「单路悬停控制条」开关开启时，双击才切换该路暂停。
            // 关闭时（默认）双击不再触发单路暂停，避免与多路对比场景下
            // 的误操作冲突；用户仍可通过空格切换全局暂停。
            if (mouse.button === Qt.LeftButton
                    && viewRoot && viewRoot.singleControlsHoverEnabled) {
                Engine.togglePauseAt(cell.playerIdx)
            }
        }
    }

    // 右键信息面板开关状态：局部（右键）+ 全局（设置菜单/V）。
    // 全局部分走 effectiveInfoVisible，全屏抑制后不显示。局部右键仍以实体为准。
    property bool localInfoVisible: false
    readonly property bool infoVisible: localInfoVisible || viewRoot.effectiveInfoVisible

    // ─── 右键视频信息面板 ──────────────────────────────────
    // 固定显示在 cell 左上角（序号徽标下方），右键再次点击关闭。
    // 每次 positionChanged 时自动刷新帧号/帧类型/pts。
    Rectangle {
        id: infoPanel
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: 6
        anchors.topMargin: 34   // 序号徽标(22px) + 6px margin + 6px gap
        width: infoPanelCol.implicitWidth + 20
        height: infoPanelCol.implicitHeight + 16
        radius: 6
        color: "#dd0d0d10"
        border.color: "#33ffffff"
        border.width: 1
        z: 20
        visible: cell.infoVisible
        clip: true

        // 每次 position 变化时刷新动态信息（帧号/帧类型/pts）
        property var info: ({})
        function refreshInfo() {
            info = Engine.videoInfoAt(cell.playerIdx)
        }
        Connections {
            target: Engine
            function onPositionChanged() {
                if (infoPanel.visible) infoPanel.refreshInfo()
            }
        }
        // 面板变为可见时立刻刷新一次
        onVisibleChanged: { if (visible) refreshInfo() }

        ColumnLayout {
            id: infoPanelCol
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: 10
            anchors.topMargin: 8
            spacing: 3

            // 标题行
            Text {
                text: "视频信息"
                color: "#ffffff"
                font.pixelSize: 11
                font.bold: true
                opacity: 0.9
            }
            // 分隔线
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: "#44ffffff"
                Layout.rightMargin: 10
            }

            // 信息行组件（复用）
            component InfoRow: RowLayout {
                property string label: ""
                property string value: ""
                spacing: 6
                Text {
                    text: label + ":"
                    color: "#9a9aa8"
                    font.pixelSize: 11
                    Layout.minimumWidth: 52
                }
                Text {
                    text: value
                    color: "#e8e8ec"
                    font.pixelSize: 11
                    font.family: "Menlo, Monaco, Courier New, monospace"
                }
            }

            InfoRow {
                label: "编解码"
                value: (infoPanel.info.codec || "—").toUpperCase()
            }
            InfoRow {
                label: "分辨率"
                value: (infoPanel.info.width && infoPanel.info.height)
                       ? (infoPanel.info.width + " × " + infoPanel.info.height)
                       : "—"
            }
            InfoRow {
                label: "FPS"
                value: infoPanel.info.fps
                       ? infoPanel.info.fps.toFixed(3)
                       : "—"
            }
            InfoRow {
                label: "帧类型"
                value: infoPanel.info.frameType || "—"
            }
            InfoRow {
                label: "像素格式"
                value: infoPanel.info.pixFmt || "—"
            }
            InfoRow {
                label: "色彩空间"
                value: infoPanel.info.colorSpace || "—"
            }
            InfoRow {
                label: "色彩范围"
                value: infoPanel.info.colorRange || "—"
            }
            InfoRow {
                label: "解码器"
                value: infoPanel.info.decoder || "—"
            }
            InfoRow {
                label: "硬件加速"
                value: infoPanel.info.hwAccel === undefined
                       ? "—"
                       : (infoPanel.info.hwAccel ? "是 (VideoToolbox)" : "否")
            }

            // 底部提示
            Text {
                text: "右键关闭"
                color: "#555560"
                font.pixelSize: 10
                Layout.topMargin: 2
                Layout.rightMargin: 10
            }
        }
    }

    // 用 HoverHandler 检测整个 cell 的 hover 状态：
    // 它不会被子项（ToolButton/Slider）的 hover 截获，
    // 鼠标在 cell 任何位置（包含按钮上）都稳定为 true，彻底消除闪烁。
    HoverHandler {
        id: cellHover
        // 默认作用范围 = parent（即 cell），无需额外配置
    }

    // ─── 单路悬浮控制条 ────────────────────────────────────
    // 鼠标进入 cell 或工具条本身时浮现；离开淡出。
    // 所有控制只作用于 cell.playerIdx 对应的单路。
    Rectangle {
        id: cellBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 6
        height: 68
        radius: 6
        color: "#cc101014"
        border.color: "#22ffffff"
        border.width: 1
        clip: true   // 防止窄 cell 下子项溢出越界绘制
        z: 10

        // hover 联动：使用 HoverHandler.hovered，
        // 鼠标在 cell 任意位置（包含工具条/按钮上）都稳定为 true。
        //
        // 全局开关：viewRoot.singleControlsHoverEnabled = false（默认）时，
        // 即便鼠标悬停也保持隐藏——避免在多路对比时遮挡画面。用户可在
        // 顶部「设置 → 单路悬停控制条」开启。
        property bool hovered: cellHover.hovered
                               && (viewRoot ? viewRoot.singleControlsHoverEnabled : false)
        opacity: hovered ? 1.0 : 0.0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 150 } }

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 4
            anchors.bottomMargin: 4
            spacing: 4

            // 第一行：单路进度条 + 时间
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                spacing: 8

                Slider {
                    id: cellSlider
                    Layout.fillWidth: true
                    from: 0
                    to: Math.max(0.001, cell._dur())
                    // 不用 `value: pressed ? value : cell._pos()` 这种自引用三元绑定 —— Slider
                    // 内部在用户拖动 / Tap 时会命令式写 value，会彻底打破属性绑定，导致播放
                    // 时滑块不再跟随 position 推进。改用 Connections 主动写入：仅当用户没
                    // 在拖动时才同步引擎位置，拖动期间完全不打扰用户。
                    Connections {
                        target: Engine
                        function onPositionChanged() {
                            if (!cellSlider.pressed) cellSlider.value = cell._pos()
                        }
                        function onDurationChanged() {
                            if (!cellSlider.pressed) cellSlider.value = cell._pos()
                        }
                    }
                    onMoved: Engine.seekAt(cell.playerIdx, value)

                    // 自绘轨道：左侧（已播放）= 亮白；右侧（未播放）= 暗灰
                    background: Rectangle {
                        x: cellSlider.leftPadding
                        y: cellSlider.topPadding + cellSlider.availableHeight / 2 - height / 2
                        implicitWidth: 200
                        implicitHeight: 4
                        width: cellSlider.availableWidth
                        height: implicitHeight
                        radius: 2
                        color: "#3a3a40"   // 未播放（右侧）暗灰
                        Rectangle {
                            width: cellSlider.visualPosition * parent.width
                            height: parent.height
                            color: "#f0f0f3"   // 已播放（左侧）亮白
                            radius: 2
                        }
                    }

                    handle: Rectangle {
                        x: cellSlider.leftPadding + cellSlider.visualPosition * (cellSlider.availableWidth - width)
                        y: cellSlider.topPadding + cellSlider.availableHeight / 2 - height / 2
                        implicitWidth: 14
                        implicitHeight: 14
                        radius: 7
                        color: cellSlider.pressed ? "#ffffff" : "#f0f0f3"
                        border.color: "#80000000"
                        border.width: 1
                    }
                }

                Label {
                    color: "#cfcfd2"
                    font.pixelSize: 11
                    text: viewRoot.fmtTime(cell._pos()) + " / " + viewRoot.fmtTime(cell._dur())
                }
            }

            // 第二行：按钮组
            // 注：按钮文本本身已足够直观（<< < ⏯ > >>），不再使用 ToolTip。
            // ToolTip 弹出层会覆盖在按钮之上 → 触发 hover 抖动闪烁，体验极差。
            // 使用 Item + RowLayout 包裹 + Layout.fillWidth + clip 防止在窄 cell 下溢出。
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                clip: true
                RowLayout {
                    anchors.centerIn: parent
                    spacing: 4

                    FlatToolButton {
                        text: "<<"
                        implicitWidth: 32
                        onClicked: Engine.seekAt(cell.playerIdx,
                                    Math.max(0, cell._pos() - 5))
                    }
                    FlatToolButton {
                        text: "<"
                        implicitWidth: 28
                        onClicked: Engine.stepFrameAt(cell.playerIdx, -1)
                    }
                    // 单路播放/暂停按钮：保持图标差异区分状态
                    FlatToolButton {
                        id: cellPlayBtn
                        text: cell._playing() ? "⏸" : "▶"
                        implicitWidth: 36
                        onClicked: Engine.togglePauseAt(cell.playerIdx)
                    }
                    FlatToolButton {
                        text: ">"
                        implicitWidth: 28
                        onClicked: Engine.stepFrameAt(cell.playerIdx, 1)
                    }
                    FlatToolButton {
                        text: ">>"
                        implicitWidth: 32
                        onClicked: Engine.seekAt(cell.playerIdx,
                                    Math.min(cell._dur(), cell._pos() + 5))
                    }

                    // 与"快进/快退/帧步进"分组，避免误点。窄 cell 下也能保留这条线。
                    Rectangle {
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 16
                        Layout.leftMargin: 2
                        Layout.rightMargin: 2
                        color: "#2a2a30"
                    }

                    // 单路重置：把本路 seek 回 0。图标与底部全局重置 ⟲ 完全一致，
                    // 让"当前路重置 / 全部重置"在视觉语义上对齐。
                    // 仅复用既有 Engine.seekAt 接口，零新增后端代码。
                    FlatToolButton {
                        id: cellResetBtn
                        text: "⟲"
                        font.pixelSize: 14
                        implicitWidth: 28
                        enabled: cell._dur() > 0
                        onClicked: Engine.seekAt(cell.playerIdx, 0)

                        ToolTip.visible: hovered
                        ToolTip.delay: 600
                        ToolTip.timeout: 3000
                        ToolTip.text: "重置本路到开头（不影响其他路）"
                    }
                }
            }
        }
    }
}
