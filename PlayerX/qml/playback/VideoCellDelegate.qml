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
import "../common/MainLogic.js" as Logic
import "RatingLogic.js" as RatingLogic

Rectangle {
    // 顶层属性（抽离唯一新增）：playerIdx / viewRoot；其余沿用原 cell 内属性。
    property int  playerIdx: -1
    property var  viewRoot:  null
    property var  multiGroupDialog: null
    property var  ratingsDialog: null
    property var  ratingToast: null

    id: cell

    // 【星星打分失效 / checklist 不弹出的根因】RatingLogic.js 没有 `.pragma library`，
    // 每个 import 它的 QML **组件实例**都会拿到一份独立的模块状态副本（Grid 里最多
    // 9 个 VideoCellDelegate 实例，就是 9 份互不相干的 _root/_multiGroupDialog/
    // _ratingsDialog）。本文件此前从未调用过 `RatingLogic._initRating(...)`，
    // 于是每个 cell 自己那份 `_root` 一直是模块顶部兜底的空对象 `{}`：
    //   · 点星星 -> _writeRating 里 `_root.cellRatings.slice()` 直接抛
    //     TypeError: Cannot call method 'slice' of undefined -> 打分失效；
    //   · 抛异常导致后面 `_multiGroupDialog._bumpState()` / checklist 联动
    //     统统没机会执行 -> checklist 弹窗也不会跳出来。
    // 这里补上初始化，让每个 cell 实例的模块副本都指向真正的共享对象。
    Component.onCompleted: {
        RatingLogic._initRating({
            root: viewRoot,
            multiGroupDialog: multiGroupDialog,
            ratingsDialog: ratingsDialog,
            ratingToast: ratingToast
        })
    }
    width:  (parent.width  - parent.spacing * (parent.columns - 1)) / Math.max(1, parent.columns)
    height: (parent.height - parent.spacing * (parent.rows    - 1)) / Math.max(1, parent.rows)
    color: "#000"
    // 手机固定尺寸模式下 videoBox 可能比 cell 还大（以保持"任何窗口大小都等于真机像素"），
    // 必须裁剪到 cell 边界，避免溢出绘到隔壁 cell。常态下 clip 也无功能副作用。
    clip: true
    // 选中边框：跟随 viewRoot.selectedIdx（QML 层显式选中状态），不跟
    // Engine.activeIndex —— 这样默认 selectedIdx=-1 时不会有任何
    // cell 被高亮，避免视觉干扰；点击空白也能取消选中。
    //   - 配色用低饱和雾蓝 #4a6fa5：辨识度足够，但比 #3a7afe 柔和
    //   - 未选中保持深灰 #222，与原视觉一致
    //   - 120ms 过渡，切换 / 评分时观感顺滑
    readonly property bool _isActive: viewRoot.selectedIdx === cell.playerIdx
    // 锁定手机比例时，cell 自身边框淡化为黑（黑边里看不见），选中框由内框 videoBox 绘制；
    // 未锁定时 cell 边框 = 选中框（保持原视觉）。
    readonly property bool _phoneLocked: viewRoot && (viewRoot.phoneFixedActive || viewRoot.phoneAspectRatio > 0)
    border.color: cell._phoneLocked ? "#000"
                : (cell._isActive ? "#4a6fa5" : "#222")
    border.width: 2
    Behavior on border.color { ColorAnimation { duration: 120 } }


    // ─── 单路状态（依赖 Engine 每帧 tick 时发出的 positionChanged）──
    // 通过函数代替属性绑定，强制每次 Engine.position 变化都重新求值，
    // 这样单路时间/进度条与该路真实播放位置保持同步。
    function _pos() { Engine.position; return Engine.positionAt(cell.playerIdx) }
    function _dur() { Engine.duration; return Engine.durationAt(cell.playerIdx) }
    function _playing() { Engine.playing; return Engine.playingAt(cell.playerIdx) }

    // 单路首/末帧判定：与 Main.qml 全局工具栏使用同一半帧容差策略。
    // 用途：本 cell 独立工具条上的 << / < / > / >> 灰化，避免用户在末帧
    // 处连按下一帧让底层单路播放器空跑造成卡顿。
    // 依赖 Engine.position/duration，会随 Engine 60Hz tick 自动重求值。
    function _cellFrameDur() {
        var fd = (typeof Engine.frameDurationAt === "function")
                 ? Engine.frameDurationAt(cell.playerIdx) : 0
        return (fd && fd > 0) ? fd : (1.0 / 30.0)
    }
    function _atFirstFrameLocal() {
        var d = _dur()
        if (d <= 0) return false
        return _pos() <= _cellFrameDur() * 0.5
    }
    function _atLastFrameLocal() {
        var d = _dur()
        if (d <= 0) return false
        return (d - _pos()) <= _cellFrameDur() * 0.5
    }

    // ─── 内容内框（手机比例 / 固定尺寸锁定）───────────────────
    // 三种模式（与 Main.qml root 上的属性保持一致）：
    //   1) viewRoot.phoneFixedActive (W>0 && H>0)：固定像素尺寸；
    //      videoBox 永远 = (phoneFixedWidth × phoneFixedHeight)，
    //      与 cell 大小完全无关。窗口缩放时蓝框尺寸保持不变；
    //      若 cell 比 videoBox 小，则由 cell.clip 裁掉超出部分。
    //   2) viewRoot.phoneAspectRatio > 0：按比例（宽÷高）居中开框，
    //      videoBox 在 cell 内做"contain"适配（保持比例不裁剪）。
    //   3) 都 = 0：videoBox 退化为整个 cell（行为同改造前）。
    // 所有 HUD（序号、路径、控制条、选中框）都锚定到 videoBox。
    // 视频内部的滚轮缩放/右键拖拽/Ctrl+双击复位作用在 Engine 视图变换上，
    // 不会改变 videoBox 自身尺寸。
    Item {
        id: videoBox
        readonly property real _cellAspect: Math.max(0.0001, cell.width / Math.max(1, cell.height))
        readonly property bool _fixed: viewRoot && viewRoot.phoneFixedActive
        // 屏幕校准系数：把 CSS px 标准预设缩放到当前显示器上接近真机大小。
        // 保护：viewRoot 可能为空、属性可能为 undefined / 0 / NaN，统统回退到 1.0。
        readonly property real _scale: {
            if (!viewRoot) return 1.0
            var s = viewRoot.phoneDisplayScale
            if (typeof s !== "number" || isNaN(s) || s <= 0) return 1.0
            return s
        }
        readonly property real _fixW: _fixed ? viewRoot.phoneFixedWidth  * _scale : 0
        readonly property real _fixH: _fixed ? viewRoot.phoneFixedHeight * _scale : 0
        readonly property real _lock: _fixed
                                       ? (_fixW / Math.max(1, _fixH))
                                       : ((viewRoot && viewRoot.phoneAspectRatio > 0)
                                          ? viewRoot.phoneAspectRatio : 0)
        // 固定尺寸模式：尺寸恒等于真机像素，与 cell 大小解耦。
        readonly property real _w: _fixed
                                    ? _fixW
                                    : (_lock <= 0
                                        ? cell.width
                                        : (_cellAspect > _lock ? cell.height * _lock : cell.width))
        readonly property real _h: _fixed
                                    ? _fixH
                                    : (_lock <= 0
                                        ? cell.height
                                        : (_cellAspect > _lock ? cell.height : cell.width / _lock))
        width:  _w
        height: _h
        anchors.centerIn: parent

        // 锁定态下，由内框绘制选中框（与 cell.border 二选一，避免双层框）
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            visible: cell._phoneLocked
            border.color: cell._isActive ? "#4a6fa5" : "#222"
            border.width: 2
            Behavior on border.color { ColorAnimation { duration: 120 } }
            z: 100   // 压过视频帧，但低于上层 HUD/控制条
        }
    }

    VideoFrameProvider {
        id: vp
        anchors.fill: videoBox
        anchors.margins: 2
        engine: Engine
        playerIndex: cell.playerIdx
        // 关闭 QtQuick 场景图对本 Item 的纹理插值。本 Item 内部
        // 已经用 sws Lanczos 把帧缩到屏幕物理像素并 1:1 上屏，
        // QtQuick 再做双线性会引入二次重采样 → 网格伪影/字模糊。
        smooth: false
        antialiasing: false
    }

    // ─── 底部居中帧号 overlay（多通道同步对比用）──────────────────────────
    // 右上 channelBar 的 #frame 字号仅 11px、与按钮/时间戳挤在一行，
    // 多通道并排时很难一眼对比各路帧号是否同步。
    // 此 overlay 在画面底部居中显示大号帧号，字号 22px + 半透明深色底，
    // 多通道下一扫即知各路帧差。
    // 显隐：与 channelBar 共用 effectiveChannelVisible（C 键控制）。
    Rectangle {
        id: frameNumOverlay
        anchors.bottom: videoBox.bottom
        anchors.horizontalCenter: videoBox.horizontalCenter
        anchors.bottomMargin: 8
        radius: 6
        color: "#88000000"
        border.width: 0
        z: 5
        visible: viewRoot.effectiveChannelVisible
        width: frameNumOverlayText.implicitWidth + 20
        height: frameNumOverlayText.implicitHeight + 8

        property var _info: ({})
        function refreshInfo() {
            if (visible) _info = Engine.videoInfoAt(cell.playerIdx)
        }
        Connections {
            target: Engine
            function onPositionChanged() { frameNumOverlay.refreshInfo() }
        }
        onVisibleChanged: refreshInfo()
        Component.onCompleted: refreshInfo()

        Text {
            id: frameNumOverlayText
            anchors.centerIn: parent
            color: "#ffffff"
            font.pixelSize: 22
            font.bold: true
            font.family: "Menlo, Monaco, Courier New, monospace"
            text: frameNumOverlay._info.frameNum !== undefined
                  ? "# " + frameNumOverlay._info.frameNum
                  : "# —"
        }
    }

    // ─── 滚轮缩放（独立 WheelHandler，挂在 cell 根 Item 上）────────────────
    // 不依赖任何 MouseArea，避免与左/右键 MouseArea 的层级竞争。
    WheelHandler {
        id: wheelZoom
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        target: null
        onWheel: function(event) {
            if (Engine.fileCount <= 0) return
            var dy = event.angleDelta.y
            if (dy === 0) return
            var step = dy / 120.0
            if (Math.abs(step) < 1e-3) step = (dy > 0 ? 0.05 : -0.05)
            var factor = Math.pow(2.0, step / 12.0)
            // 以 videoBox（画面区）归一化：锁定手机比例后，黑边上滚轮也能合理定位
            // （黑边区域被 clamp 到画面边界）。
            var w = Math.max(1, videoBox.width)
            var h = Math.max(1, videoBox.height)
            var lx = (event.x - videoBox.x) / w
            var ly = (event.y - videoBox.y) / h
            Engine.zoomBy(factor,
                Math.max(0, Math.min(1, lx)),
                Math.max(0, Math.min(1, ly)))
            event.accepted = true
        }
    }

    // 序号徽标（受全局"通道信息"开关控制，默认显示）
    Rectangle {
        id: idxBadge
        anchors.left: videoBox.left
        anchors.top: videoBox.top
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
            Math.max(80, videoBox.width - (idxBadge.width + 6) - 6 - _channelOccupiedW)
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
        anchors.right: videoBox.right
        anchors.top: videoBox.top
        anchors.margins: 6
        radius: 6
        // 【苹果深色玻璃观感】(Vibrancy Dark 风格，参考 macOS 视频播放器悬浮控件)
        //   底色：#66101014  ≈ 40% α 的近黑，比原 #55000000 略透一点，让下方视频
        //          画面能"渗"上来一点色彩，形成深色玻璃的通透感。
        //   无描边：与图 2 悬浮按钮观感一致，去掉勾边让胶囊融入视频。
        //   圆角：保留 6，与全局深色 Popup / ToolTip 主题的圆角对齐。
        // 注意：Qt Quick 的 Rectangle 无法真正对下层做高斯模糊（需要 MultiEffect/FastBlur
        // 每帧采样视频纹理，性能代价大且不好裁剪），此处走"半透明深色"路线，
        // 与项目现有 phoneAspectPopup / ToolTip 深色主题一致。
        color: "#66101014"
        border.width: 0
        z: 5
        visible: viewRoot.effectiveChannelVisible
        // 宽/高按内容自适应；同时设"可用上限"避免文件名过长把胶囊条
        // 撑出本路 cell 边界（参考图：右路 ours_hysj.../1.mp4 越界到下一路）。
        // 上限 = cell 宽 − 右锚 margin (6) − 左上角序号徽标占位 (22+6 margin+6 安全间距 = 34) ≈ cell.width − 40。
        // 当 implicitWidth 超过上限时，width 收敛到上限，channelRow 在 anchors.fill
        // 下被同步压缩，唯一可压缩项 pathLabelWrap 触发 ElideLeft 省略。
        readonly property int _maxAvailWidth: Math.max(120, videoBox.width - 40)
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
        //   第 3 行：多维评分星条（multi_dim 模式，每个维度一行，位于时间戳下方）
        // 整体右对齐，channelBar 宽度由各行 implicitWidth 的较大者决定。
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

                // 评分星条：非 multi_dim 模式且无维度配置时显示（有维度时走 multiDimBlock）
                // 【恒定隐藏】原设计里"无维度配置"时把星星塞在顶部行末尾作为兜底；
                // 但软件启动时远程配置尚未拉回 → cellReviewDimensions.length === 0，
                // 会先在顶部露一排星星；几百毫秒后拉到维度 → 切换到下方"总分"行，
                // 视觉上星星"从上方跳到下方"很突兀（见 issue：启动跳变）。
                // 由于所有正式模式（quality/qualityAB/quality_slide/multi_dim 等）
                // 都必然配置了维度，"无维度"只可能出现在"远程配置永远拉不到"的极端场景，
                // 此时用户本就无法评分，索性不显示这个孤儿星条，让 UI 稳定不跳。
                // 保留完整实现以便未来需要时可通过恢复 visible 条件复用。
                Row {
                    id: inlineStarRow
                    spacing: 2
                    visible: false
                    Layout.alignment: Qt.AlignVCenter
                    property int hoverRating: 0
                    readonly property int currentRating: {
                        var arr = viewRoot.cellRatings
                        var i = cell.playerIdx
                        if (i < 0 || i >= arr.length) return 0
                        var v = arr[i]
                        return (typeof v === "number" && v > 0) ? v : 0
                    }
                    Repeater {
                        model: viewRoot.reviewMaxStars > 0 ? viewRoot.reviewMaxStars : 5
                        delegate: Item {
                            width: 18
                            height: 18
                            property int starIndex: index + 1
                            property bool active: inlineStarRow.hoverRating > 0
                                ? starIndex <= inlineStarRow.hoverRating
                                : starIndex <= inlineStarRow.currentRating
                            Text {
                                anchors.centerIn: parent
                                text: parent.active ? "★" : "☆"
                                // 空心星星：深色玻璃底 + 纯白 + 加粗，深浅视频底都清晰可辨。
                                // 点亮的实心星星保持金黄 #f5c518。
                                color: parent.active ? "#f5c518" : "#ffffff"
                                font.pixelSize: 15
                                font.bold: true
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
                                        RatingLogic._writeRating(cell.playerIdx, 0)
                                    } else {
                                        RatingLogic._writeRating(cell.playerIdx, parent.starIndex)
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

                // 【cell hover 工具按钮】⋯ 替换本路、⤢ 放大/还原、✕ 关闭本路
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
            // 复用 RatingLogic._toggleOne(idx)，与数字键完全同一套行为，不重复实现。
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
                    onClicked: RatingLogic._toggleOne(cell.playerIdx)
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
                // 深色玻璃底 + 白字加粗，在任何视频画面下都清晰可辨。
                Text {
                    color: "#ffffff"
                    font.pixelSize: 11
                    font.bold: true
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
                    // 分隔小竖线：深色玻璃底上用半透明白
                    color: "#55ffffff"
                }
                // 时间戳（固定最小宽度，避免抖动）
                Text {
                    color: "#ffffff"
                    font.pixelSize: 11
                    font.bold: true
                    font.family: "Menlo, Monaco, Courier New, monospace"
                    horizontalAlignment: Text.AlignRight
                    Layout.minimumWidth: 70
                    Layout.preferredWidth: 70
                    text: channelBar.info.pts !== undefined
                          ? channelBar.info.pts.toFixed(3) + "s"
                          : "—"
                }
            }
            // ────── 第 3 行：多维评分行（multi_dim 模式，或其他模式有维度配置时）──────
            Column {
                id: multiDimBlock
                visible: viewRoot.reviewMode && (viewRoot.isMultiDimMode || viewRoot.cellReviewDimensions.length > 0)
                spacing: 1
                Layout.alignment: Qt.AlignRight

                Repeater {
                    id: dimRepeater
                    // 【关键】直接把整个数组作为 model：
                    // 当 root.reviewDimensions = _dims 时数组引用变化，Repeater 会完全销毁重建所有 delegate，
                    // 内层 Repeater 也随之全部重建，从新的 modelData 直接读 starCount，
                    // 彻底避免 QML var 惰性求值 / binding 依赖建立失败等问题。
                    model: viewRoot.cellReviewDimensions
                    delegate: Row {
                        id: dimRow
                        spacing: 2
                        layoutDirection: Qt.LeftToRight
                        // 直接从 modelData 拿维度对象（delegate 重建时会带上最新数据）
                        readonly property var dimData: modelData || null
                        property string dimKey: dimData ? (dimData.key || "") : ""
                        property int dimHover: 0

                        Text {
                            text: dimRow.dimKey
                            // 维度名（"总分/动作/物理/商品"等）：深色玻璃底 + 纯白 + 加粗，
                            // 字号 12、宽度 26 保持不变，避免撑开原布局。
                            color: "#ffffff"
                            font.pixelSize: 12
                            font.bold: true
                            width: 24
                            horizontalAlignment: Text.AlignRight
                            anchors.verticalCenter: parent.verticalCenter
                        }

                            Repeater {
                            // 直接从外层 delegate 的 dimData 取 starCount：
                            // delegate 由外层 Repeater 重建时创建，dimData 就是最新维度对象
                            model: {
                                var d = dimRow.dimData
                                if (!d) return 5
                                if (d.starCount > 0) return d.starCount
                                return (d.levels && d.levels.length > 0) ? d.levels.length : 5
                            }
                            delegate: Item {
                                id: dimStarItem
                                width: 16; height: 16
                                property int starIdx: index + 1
                                property int curScore: {
                                    var arr = viewRoot.cellRatings
                                    var i = cell.playerIdx
                                    if (!arr || i < 0 || i >= arr.length) return 0
                                    var v = arr[i]
                                    return (typeof v === "object" && v !== null) ? (v[dimRow.dimKey] || 0) : 0
                                }
                                property bool lit: dimRow.dimHover > 0
                                    ? dimStarItem.starIdx <= dimRow.dimHover
                                    : dimStarItem.starIdx <= dimStarItem.curScore
                                Text {
                                    anchors.centerIn: parent
                                    text: dimStarItem.lit ? "★" : "☆"
                                    // 空心星与维度名保持同色系（纯白 + 加粗），
                                    // 在深色玻璃底 + 各种视频底色下稳定可见；
                                    // 点亮的实心星保持金黄 #f5c518。
                                    color: dimStarItem.lit ? "#f5c518" : "#ffffff"
                                    font.pixelSize: 14
                                    font.bold: true
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onEntered: dimRow.dimHover = dimStarItem.starIdx
                                    onExited:  dimRow.dimHover = 0
                                    onClicked: function(mouse) {
                                        if (mouse.button === Qt.RightButton) {
                                            RatingLogic._writeRating(cell.playerIdx, 0, dimRow.dimKey)
                                        } else {
                                            RatingLogic._writeRating(cell.playerIdx, dimStarItem.starIdx, dimRow.dimKey)
                                            // 打完任意维度后弹出 checklist（有 checklist 配置即弹，不限评分模式）
                                            console.log("[Checklist] 星星点击 dimKey=" + dimRow.dimKey
                                                + " starIdx=" + dimStarItem.starIdx
                                                + " reviewChecklist=" + JSON.stringify(viewRoot.reviewChecklist)
                                                + " length=" + (viewRoot.reviewChecklist ? viewRoot.reviewChecklist.length : "null"))
                                            if (viewRoot.reviewChecklist
                                                    && viewRoot.reviewChecklist.length > 0) {
                                                var fp = Engine.filePathAt(cell.playerIdx)
                                                console.log("[Checklist] 准备弹窗 fp=" + fp
                                                    + " popup.parent=" + checklistPopup.parent
                                                    + " popup.visible=" + checklistPopup.visible)
                                                checklistPopup._filePath = fp || ""
                                                checklistPopup._loadChecked()
                                                // 定位到 dimRow 左侧，避免遮挡星星
                                                var mapped = dimRow.mapToItem(cell, 0, 0)
                                                var popH = checklistPopup.implicitHeight
                                                var popW = checklistPopup.width
                                                // 优先显示在左侧；若左侧空间不足则显示在右侧
                                                var px = mapped.x - popW - 6
                                                if (px < 0) px = mapped.x + dimRow.width + 6
                                                // 垂直居中对齐 dimRow
                                                var py = mapped.y + (dimRow.height - popH) / 2
                                                py = Math.max(4, Math.min(py, cell.height - popH - 4))
                                                checklistPopup.x = px
                                                checklistPopup.y = py
                                                checklistPopup.open()
                                                console.log("[Checklist] open() 已调用 popup.visible=" + checklistPopup.visible)
                                            } else {
                                                console.warn("[Checklist] 条件不满足，不弹窗：reviewChecklist=",
                                                    JSON.stringify(viewRoot.reviewChecklist))
                                            }
                                        }
                                        dimRow.dimHover = 0
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }   // ← end of channelCol（ColumnLayout 三行布局）
    }

    // ─── Checklist Popup（打完总分后弹出，多维评分模式专用）──────────────
    Popup {
        id: checklistPopup
        width: 160
        padding: 0
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        z: 210

        property string _filePath: ""
        // 当前勾选的 key 集合（JS 对象当 Set 用）
        property var _checked: ({})

        // 从持久化读取已勾选项
        function _loadChecked() {
            var key = "checklist:" + _filePath
            if (_filePath.length === 0 || typeof Rating === "undefined") {
                _checked = {}
                return
            }
            var raw = Rating.loadString(key, "")
            if (raw.length === 0) { _checked = {}; return }
            try {
                var arr = JSON.parse(raw)
                var obj = {}
                for (var i = 0; i < arr.length; i++) obj[arr[i]] = true
                _checked = obj
            } catch(e) { _checked = {} }
        }

        // 保存勾选项到持久化
        function _saveChecked() {
            if (_filePath.length === 0 || typeof Rating === "undefined") return
            var key = "checklist:" + _filePath
            var arr = Object.keys(_checked).filter(function(k){ return _checked[k] })
            Rating.saveString(key, JSON.stringify(arr))
        }

        // 切换某个 key 的勾选状态（含互斥逻辑）
        function _toggle(key) {
            var excl = viewRoot.reviewChecklistExclusiveKey
            var newChecked = Object.assign({}, _checked)
            if (newChecked[key]) {
                // 已勾选 → 取消
                delete newChecked[key]
            } else {
                if (key === excl) {
                    // 勾选互斥项 → 清空其他所有
                    newChecked = {}
                    newChecked[key] = true
                } else {
                    // 勾选普通项 → 取消互斥项
                    delete newChecked[excl]
                    newChecked[key] = true
                }
            }
            _checked = newChecked
            _saveChecked()
            // 通知 Main.qml：checklist 勾选变化 → 触发 allGroupsRated 响应式重算，
            // 让"下一组"按钮亮/灰状态与"下一组切换未评分校验"同步生效。
            if (viewRoot && typeof RatingLogic._onChecklistChanged === "function") {
                try { RatingLogic._onChecklistChanged() } catch (e) {}
            }
        }

        background: Rectangle {
            color: "#cc1a1a1f"
            border.color: "#33ffffff"
            border.width: 1
            radius: 6
        }

        Column {
            id: checklistCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 0 }
            spacing: 0

            // 标题
            Item {
                width: parent.width
                height: 28
                Text {
                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    text: "问题标记"
                    color: "#e8e8ec"
                    font.pixelSize: 12
                    font.bold: true
                }
                // 关闭按钮
                Text {
                    anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    text: "✕"
                    color: "#888"
                    font.pixelSize: 11
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: checklistPopup.close()
                    }
                }
                // 分隔线
                Rectangle {
                    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                    height: 1
                    color: "#33ffffff"
                }
            }

            // checklist 列表
            Repeater {
                model: viewRoot.reviewChecklist || []
                delegate: Item {
                    id: clItem
                    width: checklistCol.width
                    height: 28
                    readonly property var clData: modelData || {}
                    readonly property string clKey: clData.key || ""
                    readonly property bool clChecked: checklistPopup._checked[clKey] === true

                    // hover 背景
                    Rectangle {
                        anchors.fill: parent
                        color: clHover.containsMouse ? "#0a64f0" : "transparent"
                        Behavior on color { ColorAnimation { duration: 80 } }
                    }

                    // 勾选框
                    Rectangle {
                        id: clCheckBox
                        anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                        width: 13; height: 13
                        radius: 3
                        color: clItem.clChecked ? "#0a64f0" : "transparent"
                        border.color: clItem.clChecked ? "#0a64f0" : "#888888"
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 80 } }
                        Text {
                            anchors.centerIn: parent
                            text: "✓"
                            color: "white"
                            font.pixelSize: 9
                            font.bold: true
                            visible: clItem.clChecked
                        }
                    }

                    // label 文字
                    Text {
                        anchors { left: clCheckBox.right; leftMargin: 6; right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                        text: clItem.clData.label || clItem.clKey
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }

                    // 点击区域
                    MouseArea {
                        id: clHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: checklistPopup._toggle(clItem.clKey)
                    }

                    // 悬浮 definition 提示（自定义 Popup，限宽换行，避免横跨屏幕）
                    Popup {
                        id: defTip
                        visible: clHover.containsMouse && (clItem.clData.definition || "").length > 0
                        width: 220
                        padding: 8
                        modal: false
                        closePolicy: Popup.NoAutoClose
                        x: -width - 6
                        y: (clItem.height - implicitHeight) / 2
                        z: 300
                        background: Rectangle {
                            color: "#cc1a1a1f"
                            border.color: "#33ffffff"
                            border.width: 1
                            radius: 6
                        }
                        Text {
                            width: 204
                            text: clItem.clData.definition || ""
                            color: "#e8e8ec"
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            // 底部留白
            Item { width: 1; height: 6 }
        }

        // 动态高度：标题28 + 每行28 + 底部6
        implicitHeight: 28 + (viewRoot.reviewChecklist ? viewRoot.reviewChecklist.length * 28 : 0) + 6
    }

    // ─── 主交互层：左键选中/双击暂停 + 右键拖拽平移/单击信息面板 ──────────
    // 设计说明：
    //   · 单一 MouseArea 同时接 LeftButton | RightButton，彻底消除层级竞争。
    //   · 左键单击：选中本路（Engine.activeIndex + selectedIdx）。
    //     【绝对不允许】切换信息面板，信息面板仅右键单击或快捷键 V 触发。
    //   · 左键双击：仅在 singleControlsHoverEnabled 开启时切换该路暂停。
    //   · 右键按住拖拽：Engine.panBy() 平移（zoom>1 时平移放大画面，zoom==1 时同步偏移）。
    //   · 右键单击（未拖拽）：切换本 cell 信息面板。
    //   · Ctrl+左键双击：TapHandler 负责复位视图变换。
    MouseArea {
        id: cellMouse
        anchors.fill: parent
        z: 2
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: (pressed && pressedButtons & Qt.RightButton) ? Qt.ClosedHandCursor : Qt.ArrowCursor

        property real _rLastX: 0
        property real _rLastY: 0
        property bool _rMoved: false

        onPressed: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                _rLastX = mouse.x
                _rLastY = mouse.y
                _rMoved = false
            }
        }
        onPositionChanged: function(mouse) {
            if (!(pressedButtons & Qt.RightButton)) return
            var dx = mouse.x - _rLastX
            var dy = mouse.y - _rLastY
            _rLastX = mouse.x
            _rLastY = mouse.y
            if (Math.abs(dx) + Math.abs(dy) < 0.5) return
            _rMoved = true
            // 以 videoBox（画面区）归一化：锁定手机比例后拖拽在黑边/画面中表现一致。
            var w = Math.max(1, videoBox.width)
            var h = Math.max(1, videoBox.height)
            Engine.panBy(dx / w, dy / h)
        }
        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton) {
                Engine.activeIndex = cell.playerIdx
                viewRoot.selectedIdx = cell.playerIdx
                viewRoot.focusVideoArea()
            }
            // 右键单击由 onReleased 处理（需区分是否拖拽）
        }
        onReleased: function(mouse) {
            if (mouse.button === Qt.RightButton && !_rMoved) {
                cell.localInfoVisible = !cell.localInfoVisible
            }
        }
        onDoubleClicked: function(mouse) {
            // 仅在「单路悬停控制条」开关开启时，双击才切换该路暂停。
            if (mouse.button === Qt.LeftButton
                    && viewRoot && viewRoot.singleControlsHoverEnabled) {
                Engine.togglePauseAt(cell.playerIdx)
            }
        }

        // Ctrl + 左键双击 → 复位所有路视图变换。
        TapHandler {
            acceptedButtons: Qt.LeftButton
            acceptedModifiers: Qt.ControlModifier
            onDoubleTapped: Engine.resetViewTransform()
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
        anchors.left: videoBox.left
        anchors.top: videoBox.top
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
                value: {
                    var name = (infoPanel.info.codec || "—").toUpperCase()
                    var tag  = infoPanel.info.codecTag || ""
                    return tag ? name + " (" + tag + ")" : name
                }
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
        anchors.left: videoBox.left
        anchors.right: videoBox.right
        anchors.bottom: videoBox.bottom
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
                    text: Logic.fmtTime(cell._pos()) + " / " + Logic.fmtTime(cell._dur())
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
                        // 首帧短路：不改变按钮视觉，仅阻断点击流水线避免解码器空跑
                        onClicked: {
                            if (cell._atFirstFrameLocal()) return
                            Engine.seekAt(cell.playerIdx,
                                    Math.max(0, cell._pos() - 5))
                        }
                    }
                    FlatToolButton {
                        text: "<"
                        implicitWidth: 28
                        onClicked: {
                            if (cell._atFirstFrameLocal()) return
                            Engine.stepFrameAt(cell.playerIdx, -1)
                        }
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
                        // 末帧短路：核心场景——不改按钮观感，只阻止连点造成的卡顿
                        onClicked: {
                            if (cell._atLastFrameLocal()) return
                            Engine.stepFrameAt(cell.playerIdx, 1)
                        }
                    }
                    FlatToolButton {
                        text: ">>"
                        implicitWidth: 32
                        onClicked: {
                            if (cell._atLastFrameLocal()) return
                            Engine.seekAt(cell.playerIdx,
                                    Math.min(cell._dur(), cell._pos() + 5))
                        }
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
