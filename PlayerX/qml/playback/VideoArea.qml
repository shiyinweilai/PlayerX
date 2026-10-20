import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Item {
    id: videoArea
    property alias ratingToast: ratingToast
    property var root: null
    // 滑动对比评分回调，由 Main.qml 传入 Logic.setSlideRating，避免 VideoArea 内引用不到 Logic
    property var setSlideRatingFn: null
    property var shortcutsAboutDialogs: null
    property var addDialog: null
    property Item refSidebar: null
    property Item csvBottomBar: null
    property var multiGroupDialog: null
    property var ratingsDialog: null
    property Item leftNavBar: null
    // 顶部公告条（NoticeBar）引用：用于把视频网格顶部让出公告条高度。
    // 由 Main.qml 传入；未传入（null）时让位高度按 0 处理，不影响其它 tab。
    property Item noticeBarRef: null
    // videoArea 始终跟随 refSidebar 右侧（refSidebar 折叠时宽度=0，等价于贴 leftNavBar.right）。
    // immersive 模式下 leftNavBar 宽度变为 0，refSidebar 自然贴左边。
    anchors.left: refSidebar.right
    anchors.right: parent.right
    anchors.top: parent.top
    // 顶部余白 2px（避免与上方元素视觉粘连 + 给 cell 2px 选中边框留位）；
    // 播放 tab 顶部还有一条公告条（noticeBar，自绘黄色滚动文字），
    // 这里额外让出它的高度，避免视频网格被公告条盖住。
    anchors.topMargin: 2
    anchors.bottom: csvBottomBar.top
    visible: root.currentTab === "play"

    focus: true

    // ── Grid 计算行列 ──
    // SideBySide = 单行 N 列（1×N 横排）；其他是固定网格。
    function gridCols() {
        var n = videoArea.visibleCount()
        if (n <= 0) return 1
        switch (Engine.layoutMode) {
        case 0: return 1                          // Single
        case 1: return n                          // SideBySide = 1×N
        case 2: return 2                          // 2x2
        case 3: return 3                          // 2x3
        case 4: return 3                          // 3x3
        }
        return 1
    }
    function gridRows() {
        var c = gridCols()
        return Math.max(1, Math.ceil(visibleCount() / c))
    }
    function visibleCount() {
        if (Engine.fileCount <= 0) return 0
        switch (Engine.layoutMode) {
        case 0: return 1                                     // Single
        case 1: return Math.min(9, Engine.fileCount)         // SideBySide (1×N)
        case 2: return Math.min(4, Engine.fileCount)         // 2x2
        case 3: return Math.min(6, Engine.fileCount)         // 2x3
        case 4: return Math.min(9, Engine.fileCount)         // 3x3
        }
        return Engine.fileCount
    }
    // 第 i 个槽位实际对应的 player 索引
    //
    // 【REF 置顶显示重映射】(2026-10-10)
    //   参考视频(REF)路底层作为最后一路 player 追加，但显示上要求固定在
    //   最左（参考图侧栏右边、通道1 左边）。这里只做「显示位置 → player
    //   索引」的重排，不改动底层 player 索引、评分、seek 等任何逻辑：
    //     · 存在 REF 路时：显示槽 0 → REF 的 player 索引；
    //       显示槽 1..N → 跳过 REF 后的其余 player 顺序填充。
    //     · 无 REF 路时：原样返回 slot（恒等映射）。
    function _refPlayerIndex() {
        var n = Engine.fileCount
        for (var i = 0; i < n; ++i) {
            var fp = Engine.filePathAt(i) || ""
            var dir = fp.substring(0, fp.lastIndexOf("/"))
            if (dir.length > 0 && dir.split("/").pop() === "REF") return i
            var rp = (videoArea.multiGroupDialog && videoArea.multiGroupDialog.refVideoPath) || ""
            if (rp.length > 0 && dir === rp) return i
        }
        return -1
    }
    // ── 【通道拖拽重排】显示槽位 → player 索引的自定义映射 ──
    // 默认恒等（显示槽 i 显示 player i）；用户拖拽交换后记录新的对应关系。
    // 仅作用于"显示层"（宫格顺序 + 外部通道号/路径），不改动底层 player
    // 索引、评分、seek、快捷键等任何逻辑——评分按 player 索引存储，
    // 交换位置不会导致评分错位。翻组/换文件列表时自动重置为恒等。
    property var _laneOrder: []
    property int _laneOrderBump: 0   // 惰性求值依赖：交换后 +1 触发重渲染

    // ── 【拖拽抬起缩影】拖拽通道重排时，生成跟随鼠标的半透明缩略图 ──
    // 快照来源 = 被拖 cell 的 videoBox（ShaderEffectSource 拍静态帧），
    // 微缩(0.85) + 柔和阴影 + 半透明，营造"视频被抬起来"的手感；
    // 原格子同时变暗作为占位。松手后缩影快速淡出。
    property bool  _ghostActive: false
    property real  _ghostX: 0     // scene 坐标（cell.mapToItem(null) 产物）
    property real  _ghostY: 0
    property var   _ghostSource: null
    property int   _ghostChannel: 0   // 被拖的通道号（1 起），缩略图徽标用

    function _startDragGhost(srcItem, channelNo) {
        videoArea._ghostChannel = channelNo
        videoArea._ghostSource = srcItem
        videoArea._ghostActive = true
        // 防止拖起瞬间缩影闪现在上次拖拽的旧位置：先藏起来，
        // 等 delegate 第一次 _moveDragGhost 传入真实鼠标位置后再显示
        videoArea._ghostX = -9999
        videoArea._ghostY = -9999
    }
    function _moveDragGhost(sx, sy) {
        // delegate 传入的是 scene 坐标（mapToItem(null) 产物），而 dragGhost
        // 的 x/y 是 videoArea 本地坐标——VideoArea 在窗口中不位于原点
        // （左侧有通道栏等），直接混用会导致缩影整体向右下错位。
        var p = videoArea.mapFromItem(null, sx, sy)
        videoArea._ghostX = p.x
        videoArea._ghostY = p.y
    }
    function _endDragGhost() {
        videoArea._ghostActive = false
        ghostClear.restart()         // 淡出动画播完后再清引用
    }

    // 构建/重建 laneOrder：REF 仍固定占显示槽 0，其余 player 按当前
    // _laneOrder 中"非 REF 部分"的旧顺序（若有）或默认顺序填充。
    // 语义：重排只针对"非 REF 路"；REF 永远第一。
    function _rebuildLaneOrder() {
        var n = Engine.fileCount
        var refIdx = _refPlayerIndex()
        var old = videoArea._laneOrder || []
        // 从旧顺序里取出"仍然存在且非 REF"的 player 索引（保持旧相对顺序）
        var kept = []
        for (var i = 0; i < old.length; ++i) {
            var p = old[i]
            if (typeof p === "number" && p >= 0 && p < n && p !== refIdx
                    && kept.indexOf(p) < 0)
                kept.push(p)
        }
        // 补上新增的（旧顺序里没有的）非 REF player
        for (var j = 0; j < n; ++j) {
            if (j !== refIdx && kept.indexOf(j) < 0) kept.push(j)
        }
        var arr = []
        if (refIdx >= 0) arr.push(refIdx)
        for (var k = 0; k < kept.length; ++k) arr.push(kept[k])
        videoArea._laneOrder = arr
    }

    // 显示槽 slotA ↔ slotB 交换（拖拽落点判定后调用）。
    // REF 槽（0）不可拖走：若任一为 REF 槽则直接忽略。
    // 返回值：成功 → [playerA, playerB]（两路 player 索引，供交换特效广播）；
    //         失败/被拒 → null。
    function swapLaneOrder(slotA, slotB) {
        if (slotA === slotB) return null
        if (slotA < 0 || slotB < 0) return null
        var arr = videoArea._laneOrder
        if (!arr || arr.length === 0) return null
        if (slotA >= arr.length || slotB >= arr.length) return null
        var refIdx = _refPlayerIndex()
        if (refIdx >= 0 && (arr[slotA] === refIdx || arr[slotB] === refIdx)) {
            console.log("[LaneDrag] swap 被拒：涉及 REF 槽 slot" + slotA + "↔slot" + slotB)
            return null
        }
        var t = arr[slotA]
        arr[slotA] = arr[slotB]
        arr[slotB] = t
        videoArea._laneOrder = arr
        videoArea._laneOrderBump++
        console.log("[LaneDrag] SWAP 完成: slot" + slotA + "↔slot" + slotB
            + " 新顺序=" + JSON.stringify(arr))
        _persistLaneOrder()
        return [arr[slotA], arr[slotB]]
    }

    // 持久化：写入 Rating QSettings（跨重启保留；不同模式独立）。
    function _persistLaneOrder() {
        try {
            if (typeof Rating !== "undefined" && Rating
                && typeof Rating.saveString === "function")
                Rating.saveString("playbackLaneOrder/" + Engine.layoutMode,
                                  JSON.stringify(videoArea._laneOrder))
        } catch (e) { /* 持久化失败不影响本次会话 */ }
    }
    function _loadLaneOrder() {
        try {
            if (typeof Rating !== "undefined" && Rating
                && typeof Rating.loadString === "function") {
                var s = Rating.loadString("playbackLaneOrder/" + Engine.layoutMode, "")
                if (s && s.length > 0) {
                    var arr = JSON.parse(s)
                    if (arr && arr.length > 0) return arr
                }
            }
        } catch (e) {}
        return null
    }

    function slotPlayerIndex(slot) {
        videoArea._laneOrderBump   // 依赖：交换后强制重求值
        if (Engine.layoutMode === 0) return Engine.activeIndex
        var arr = videoArea._laneOrder
        if (arr && arr.length > 0 && slot >= 0 && slot < arr.length)
            return arr[slot]
        return slot
    }

    // 【通道拖拽重排】文件列表/布局变化时重建映射：
    //   · filesChanged（翻组/换文件/关通道）：保留旧相对顺序，REF 仍置顶。
    //     若无持久化旧顺序则默认恒等。
    //   · layoutMode 变化：不同布局的持久化顺序各自独立，切换时按
    //     该布局自己的存档恢复（无存档则恒等）。
    // Component.onCompleted：首次进入时尝试恢复上次布局的存档。
    Connections {
        target: Engine
        function onFilesChanged() { videoArea._rebuildLaneOrder() }
        function onLayoutModeChanged() {
            var saved = videoArea._loadLaneOrder()
            videoArea._laneOrder = saved ? saved : []
            videoArea._laneOrderBump++
            if (!saved) videoArea._rebuildLaneOrder()
        }
    }
    Component.onCompleted: {
        var saved = videoArea._loadLaneOrder()
        videoArea._laneOrder = saved ? saved : []
        if (!saved) videoArea._rebuildLaneOrder()
    }

    // 「空白处点击取消选中」底层 MouseArea。
    // 实现思路：与 Grid 同级铺满 videoArea，z=-1 让它垫在最底下；cell 内部的
    // MouseArea 会优先吃掉落在画面里的点击，落到 cell 外（spacing/letterbox/
    // 工具栏下方空白）的点击则会穿到这里 → 清空 selectedIdx。
    // 注意：滑动对比模式下也允许点击取消（无 cell，全空白），无副作用。
    MouseArea {
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.LeftButton
        onClicked: root.selectedIdx = -1
    }

    Grid {
        id: grid
        anchors.fill: parent
        // 滑动对比模式启用时隐藏 Grid（Grid 内的所有子项与控制逻辑保持不变）
        visible: !root.compareSliderActive
        columns: videoArea.gridCols()
        rows: videoArea.gridRows()
        spacing: 4

        Repeater {
            model: videoArea.visibleCount()

            delegate: VideoCellDelegate {
                // 把宫格内 cell 抽离为独立组件，便于将来按媒体类型扩展（图片模式等）。
                // 行为/视觉与原内联 delegate 100% 等价；
                //   · playerIdx：通过 viewRoot 上的透传函数把 Repeater 的 index 映射到真正的 player 索引
                //   · viewRoot ：把 ApplicationWindow root 整个传入，子组件通过它访问 fmtTime / 评分 / 选中等共享状态
                playerIdx: viewRoot.slotPlayerIndex(index)
                viewRoot: root
                videoAreaRef: videoArea
                multiGroupDialog: videoArea.multiGroupDialog
                ratingsDialog: videoArea.ratingsDialog
                ratingToast: videoArea.ratingToast
            }
        }
    }

    // ─── 空状态欢迎面板 ─────────────────────────────────────────
    //   仅在 Engine.fileCount <= 0 时显示；一旦有视频自动隐藏，
    //   不与 Grid 视图、SliderCompareView 共享任何状态，零功能侵入。
    //
    //   组成：
    //     · 大标题 / 副标题（说明软件用途）
    //     · 两个大按钮：① 打开文件   ② 打开文件夹 / 多组对比
    //       直接复用顶部菜单同款入口（addDialog.open / multiGroupDialog.show），
    //       不重复任何打开逻辑。
    //     · DropArea 全覆盖：支持文件 + 文件夹拖拽
    //         - 视频文件：直接进入 selectedFiles 队列
    //         - 文件夹：用 Fs.scanVideoFolder 递归展开为视频文件
    //         - 混合：一起合并、最多取前 9 个，调 Engine.openFiles
    //     · 操作说明（快捷键、批量上限提示等）
    Item {
        id: emptyHero
        anchors.fill: parent
        visible: Engine.fileCount <= 0 && !root.compareSliderActive

        // 拖拽高亮态：DropArea 进入时整块面板加柔和高亮边框
        property bool dragHover: dropZone.containsDrag

        // 半透明遮罩：让欢迎面板与窗口主体的纯黑稍稍区分开
        Rectangle {
            anchors.fill: parent
            color: emptyHero.dragHover ? "#1a3a78c8" : "transparent"
            Behavior on color { ColorAnimation { duration: 140 } }
        }

        // 拖入时的虚线高亮边框（不挡点击，纯视觉反馈）
        Rectangle {
            anchors.fill: parent
            anchors.margins: 12
            color: "transparent"
            radius: 12
            border.color: emptyHero.dragHover ? "#3a78c8" : "transparent"
            border.width: 2
            Behavior on border.color { ColorAnimation { duration: 140 } }
        }

        ColumnLayout {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 28
            anchors.bottomMargin: 24
            spacing: 18
            // 宽度随窗口自适应：占可用宽的 ~88%，上限 1280，窄屏时留 80px 边距
            width: Math.min(parent.width - 80, Math.max(560, parent.width * 0.88))

            // ── 标题组（压缩版）：品牌标识靠上，把面积让给教程窗口 ──
            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 6

                Row {
                    id: titleRow
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 2
                    Text { text: "Player"; color: "#f4f6fa"; font.pixelSize: 24; font.bold: true }
                    Text { text: "X";      color: "#3b8ef2"; font.pixelSize: 24; font.bold: true }
                }

                // 装饰线：标题正下方的渐变下划线（两端透明、中间饱和）
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    width: titleRow.implicitWidth * 0.9
                    height: 3
                    radius: 1.5
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#003b8ef2" }
                        GradientStop { position: 0.5; color: "#883b8ef2" }
                        GradientStop { position: 1.0; color: "#003b8ef2" }
                    }
                }
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "多路视频对比 · 同步播放 · 评分采集"
                color: "#9aa0a6"
                font.pixelSize: 12
            }

            // ── 两个入口按钮（压缩为紧凑横向小按钮）─────────────
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 12

                // ① 打开文件
                Rectangle {
                    id: heroBtnFile
                    Layout.preferredWidth: 190
                    Layout.preferredHeight: 84
                    radius: 8
                    color: heroBtnFileMA.containsMouse ? "#2a3a55"
                          : heroBtnFileMA.pressed     ? "#1e2a40"
                                                      : "#1e1e22"
                    border.color: heroBtnFileMA.containsMouse ? "#3a78c8" : "#3a3a42"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 10
                        Text { text: "🎬"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Text { text: "打开文件"; color: "#e8e8ec"; font.pixelSize: 13; font.bold: true }
                            Text { text: "选择 1-9 个视频文件"; color: "#9aa0a6"; font.pixelSize: 11 }
                        }
                    }

                    MouseArea {
                        id: heroBtnFileMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: addDialog.open()
                    }
                }

                // ② 打开文件夹 / 多组对比
                Rectangle {
                    id: heroBtnFolder
                    Layout.preferredWidth: 190
                    Layout.preferredHeight: 84
                    radius: 8
                    color: heroBtnFolderMA.containsMouse ? "#2a3a55"
                          : heroBtnFolderMA.pressed     ? "#1e2a40"
                                                        : "#1e1e22"
                    border.color: heroBtnFolderMA.containsMouse ? "#3a78c8" : "#3a3a42"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 10
                        Text { text: "📁"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Text { text: "打开文件夹"; color: "#e8e8ec"; font.pixelSize: 13; font.bold: true }
                            Text { text: "整文件夹载入 / 多组对比"; color: "#9aa0a6"; font.pixelSize: 11 }
                        }
                    }

                    MouseArea {
                        id: heroBtnFolderMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: multiGroupDialog.showAndRefresh()
                    }
                }
            }

            // ── 教程视频渲染窗口（主体，最大化占据剩余面积） ──
            //   专业软件（Premiere / Resolve）的空态做法：放一个自动播放的
            //   教程视频（静音、循环），比静态图/GIF 更清晰、体积更小、可换源。
            //   视频缺失时组件内部自动回退为标题占位，不报错。
            TutorialVideoPanel {
                id: tutorialPanel
                Layout.alignment: Qt.AlignHCenter
                Layout.fillHeight: true
                // 宽度：尽量占满列宽（列已限制为窗口-80、最大880）
                Layout.preferredWidth: parent.width
                // 教程视频在线源：首次访问自动缓存到本地实现秒开，
                // 之后启动直接播本地缓存，后台检测远端更新
                tutorialSource: "https://tvp-76917.gzc.vod.tencent-cloud.com/rbyang/PlayerX/%E6%92%AD%E6%94%BE%E5%AF%B9%E6%AF%94_%E6%97%A0%E8%BE%B9%E6%A1%86%E7%89%88.mp4"
            }
        }

        // ── 拖拽落区：必须放在最后（z 序最高），覆盖整个空状态区域 ──
        //   只在 fileCount==0 时存在，载入视频后该 Item 整体 visible=false。
        //   既不会在播放期间误触发，也不会与 Grid 内的事件抢截。
        DropArea {
            id: dropZone
            anchors.fill: parent

            // 仅接受带 url 的拖拽（文件/文件夹）
            onEntered: function(drag) {
                if (!drag.hasUrls) { drag.accepted = false; return }
                drag.accept(Qt.CopyAction)
            }

            onDropped: function(drop) {
                if (!drop.hasUrls) return

                // 视频扩展名白名单（与 FileDialog 保持一致）
                var exts = ["mp4","mov","mkv","avi","webm","flv","ts","m4v","wmv"]
                function hasVideoExt(p) {
                    var s = String(p).toLowerCase()
                    var dot = s.lastIndexOf(".")
                    if (dot < 0) return false
                    var ext = s.substring(dot + 1)
                    return exts.indexOf(ext) >= 0
                }

                // ── 第一遍：把拖入项分流为「文件夹组」与「散文件组」──
                // 文件夹判定方式：先用 Fs.scanVideoFolder 试扫，能扫出视频则认定为文件夹。
                // 这样既覆盖目录拖拽，又不会把"含视频后缀但实际是文件"的项误判为文件夹。
                var folderUrls   = []   // 仅"扫出视频"的文件夹的 url 原样
                var standaloneFiles = []  // 直接拖入的视频散文件 url（字符串形式）

                console.log("[dropZone] drop.urls.length =", drop.urls.length)
                for (var i = 0; i < drop.urls.length; ++i) {
                    var u = drop.urls[i]
                    var s = String(u)
                    var scanned = []
                    try { scanned = Fs.scanVideoFolder(u, true) } catch (e) { scanned = [] }

                    if (scanned && scanned.length > 0) {
                        folderUrls.push(u)
                        console.log("[dropZone]  [", i, "] folder (", scanned.length, "videos):", s)
                    } else if (hasVideoExt(s)) {
                        standaloneFiles.push(s)
                        console.log("[dropZone]  [", i, "] standalone file:", s)
                    } else {
                        console.log("[dropZone]  [", i, "] skipped (not a video / not a folder with videos):", s)
                    }
                }
                console.log("[dropZone] summary: folderUrls=", folderUrls.length,
                            " standaloneFiles=", standaloneFiles.length)

                if (folderUrls.length === 0 && standaloneFiles.length === 0) return

                // ── 仅文件夹 → 走 MultiGroupDialog（等同点击"打开文件夹"）──
                //   拖入的文件夹默认勾选；历史文件夹默认不勾选（由 addFoldersAndShow 保证）。
                //   不再静默 "loadFolders 立即播放"，把选择权交给用户。
                if (folderUrls.length > 0 && standaloneFiles.length === 0) {
                    try { multiGroupDialog.addFoldersAndShow(folderUrls) } catch (e) {}
                    return
                }

                // ── 仅散文件 → 保留"直接铺开播放"的旧体验（最多 9 路）──
                if (folderUrls.length === 0 && standaloneFiles.length > 0) {
                    var collected = []
                    for (var m = 0; m < standaloneFiles.length && collected.length < 9; ++m) {
                        collected.push(standaloneFiles[m])
                    }
                    if (collected.length === 0) return
                    if (collected.length > 9) collected = collected.slice(0, 9)
                    console.log("[dropZone] Engine.openFiles collected:", collected)
                    Engine.openFiles(collected)
                    return
                }

                // ── 混合（文件夹 + 散文件）→ 合并展示在 MultiGroupDialog ──
                //   · 文件夹走 addFoldersWithConfirm（默认勾选 / 重复提示）
                //   · 散文件走 addAnonymousFiles（作为 folderPath="" 的匿名 lane，
                //     默认勾选、不入文件夹历史）
                //   · 一次性 show + raise，避免分两次调用带来的闪烁
                // 旧逻辑：混合时散文件被静默丢弃 —— 用户拖 5 个 mp4 + 1 个文件夹，
                //   只会看到 1 个文件夹 lane，对比时只剩 1 路。已修复。
                console.log("[dropZone] mixed drop: folders + files → MultiGroupDialog")
                try { multiGroupDialog.addFoldersAndShow(folderUrls, standaloneFiles) } catch (e) {
                    // 兜底：极端异常时退化为"仅文件夹"路径，至少保证可用
                    try { multiGroupDialog.addFoldersAndShow(folderUrls) } catch (e2) {}
                }
            }
        }
    }

    // ─── 播放期间拖拽落区：仅"加入历史"，不打断当前播放 ─────────
    //   场景：用户在视频已经播放时把若干文件夹从 Finder/Explorer 拖进来，
    //         期望"打开文件夹/多组对比"对话框里能看到这些新文件夹。
    //   设计：
    //     · 仅在 Engine.fileCount > 0（即播放中）启用，与 emptyHero/dropZone 互斥；
    //     · 仅识别"文件夹"，散视频文件不进历史（与产品需求一致）；
    //     · 不调用 Engine.openFiles 也不切换正在播放的视频，仅追加到 MultiGroupDialog
    //       的 lanes 历史并持久化（addFoldersToHistory 内部去重）；
    //     · 完成后用 _showRatingWarn 给一个轻量 toast 反馈（复用现有 toast 通道）。
    //   注意：DropArea 默认对鼠标事件透明，覆盖整个 videoArea 不会影响点击/滚动。
    DropArea {
        id: liveDropZone
        anchors.fill: parent
        visible: Engine.fileCount > 0
        enabled: visible
        z: 50  // 高于 cell 网格但低于 ratingToast(z:999)，纯拖拽用，不影响鼠标

        onEntered: function(drag) {
            if (!drag.hasUrls) { drag.accepted = false; return }
            drag.accept(Qt.CopyAction)
        }

        onDropped: function(drop) {
            if (!drop.hasUrls) return

            // 仅采集"能扫出视频"的文件夹；散文件忽略（不入历史也不打断当前播放）
            var folderUrls = []
            for (var i = 0; i < drop.urls.length; ++i) {
                var u = drop.urls[i]
                var scanned = []
                try { scanned = Fs.scanVideoFolder(u, true) } catch (e) { scanned = [] }
                if (scanned && scanned.length > 0) folderUrls.push(u)
            }

            if (folderUrls.length === 0) {
                // 拖进来的全是散文件 / 空文件夹 / 无视频 → 静默忽略
                return
            }

            // 拖入文件夹 → 直接打开 MultiGroupDialog（等同点击"打开文件夹"）：
            //   · 拖入的文件夹默认勾选；历史文件夹默认不勾选；
            //   · 不打断当前正在播放的视频，由用户在 Dialog 里确认后再启动新播放。
            try { multiGroupDialog.addFoldersAndShow(folderUrls) } catch (e) {}
        }
    }

    // ─── 滑动对比视图（独立组件，仅在 compareSliderActive 时显示）──
    // 完全独立于上方 Grid 视图，不与 cell / VideoFrameProvider 共享任何
    // 状态。所有播放控制继续走 Engine.* 接口（顶部 ToolBar / Shortcut /
    // 底部进度条），与 Grid 模式行为一致。
    SliderCompareView {
        anchors.fill: parent
        visible: root.compareSliderActive && Engine.fileCount === 2
        engine: Engine
        leftIndex: 0
        rightIndex: 1
        channelVisible: root.effectiveChannelVisible
        // ── 质量比较 2 专用：左右 N 星评分条与本地状态双向同步 ──
        slideRatingEnabled: root.isQualitySlideMode
        slideRatingL: root.slideRatingL
        slideRatingR: root.slideRatingR
        slideMaxStars: root.slideMaxStars
        slideDimLabel: root.slideDimLabel
        setSlideRatingFn: videoArea.setSlideRatingFn
    }

    // ─── 评分提示 Toast（屏幕中央浮层）───────────────────
    // 快捷键评分时在屏幕中央弹一个带颜色的圆角卡片，让用户一眼识别：
    //   - 打了几星、落到哪一路（避免在多路网格中误诸6）
    //   - 分数高低用语义色区分：金色=5、绿=4、蓝=3、橙=2、红=1（与集成市场上
    //     常见的评分卡一致）
    //   - "清除"用中性灰、"提示未选中"用警警色（橙色）
    // 仅装饰性，不拦截鼠标；show() 重置定时，连按不闪烁。
    Item {
        id: ratingToast
        anchors.centerIn: parent
        width: toastBg.implicitWidth
        height: toastBg.implicitHeight
        opacity: 0
        visible: opacity > 0.01
        z: 999

        // 字号：默认 22（打分快闪）；长文案提示由 show() 第二参数调小
        property int toastFontPx: 22
        // sticky：true 时不自动消失，改由「知道了」按钮手动关闭（仅重要提示用）
        property bool sticky: false

        // durationMs：可选显示时长（默认 880ms 快闪；重要提示可传更长）
        // fontPx：可选字号（默认 22；两行长文案建议 16，更精致不撑满屏）
        // sticky：可选，true = 不自动消失，显示「知道了」按钮
        function show(durationMs, fontPx, sticky) {
            hideTimer.interval = (typeof durationMs === "number" && durationMs > 0) ? durationMs : 880
            toastFontPx = (typeof fontPx === "number" && fontPx > 0) ? fontPx : 22
            ratingToast.sticky = (sticky === true)
            if (ratingToast.sticky)
                hideTimer.stop()        // 常驻，等用户点「知道了」
            else
                hideTimer.restart()     // 打分快闪/短警示：自动消失（不受影响）
            fadeIn.restart()
        }

        // 根据 kind/score 计算主色（边框+文字）与背景调。
        // dd 前缀 = ~87% 透明度的 ARGB，不遮住背后画面。
        readonly property color _accent: {
            if (root.ratingToastKind === "warn")  return "#fa8c16"
            if (root.ratingToastKind === "clear") return "#9aa0a6"
            switch (root.ratingToastScore) {
            case 5: return "#ffcc33"  // 金
            case 4: return "#52c41a"  // 绿
            case 3: return "#4a8fe7"  // 蓝
            case 2: return "#fa8c16"  // 橙
            case 1: return "#f5222d"  // 红
            }
            return "#9aa0a6"
        }

        Rectangle {
            id: toastBg
            anchors.centerIn: parent
            radius: 12
            // 背景 = 主色其于二成透明叠在深黑上：发光感 + 保证可读
            color: "#e61b1b22"
            border.color: ratingToast._accent
            border.width: 2
            implicitWidth:  toastContent.implicitWidth + 40
            implicitHeight: toastContent.implicitHeight + 24

            // 内部柔和色晕：用与边框同色、低透明度的 Rectangle 模拟染色背景。
            Rectangle {
                anchors.fill: parent
                anchors.margins: 2
                radius: 10
                color: ratingToast._accent
                opacity: 0.16
            }

            Column {
                id: toastContent
                anchors.centerIn: parent
                spacing: 7   // 两行间隔稍大，阅读更舒适

                Label {
                    id: toastLabel
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.ratingToastText
                    // 有两行时第一行用浅色（标题感）；单行保持 kind 主色（打分快闪原样）
                    color: root.ratingToastText2.length > 0 ? "#f0f0f3" : ratingToast._accent
                    font.pixelSize: ratingToast.toastFontPx
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    // 轻微阴影让彩色文字在染色背景上仍足够锐利
                    style: Text.Raised
                    styleColor: "#000000"
                }
                Label {
                    id: toastLabel2
                    visible: text.length > 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.ratingToastText2
                    color: ratingToast._accent   // 第二行用 kind 主色（warn=橙）
                    font.pixelSize: ratingToast.toastFontPx
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    style: Text.Raised
                    styleColor: "#000000"
                }

                // 「知道了」按钮：仅 sticky 常驻模式显示，点击手动关闭
                Rectangle {
                    visible: ratingToast.sticky
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 84
                    height: 28
                    radius: 5
                    color: toastOkMa.containsMouse ? "#3a3a46" : "#2a2a34"
                    border.color: "#55ffffff"
                    border.width: 1

                    Text {
                        anchors.centerIn: parent
                        text: "知道了"
                        color: "#e8e8ec"
                        font.pixelSize: 13
                    }
                    MouseArea {
                        id: toastOkMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            ratingToast.sticky = false
                            fadeOut.restart()
                        }
                    }
                }
            }
        }
        NumberAnimation on opacity {
            id: fadeIn
            from: 0; to: 1
            duration: 140
            easing.type: Easing.OutCubic
            running: false
        }
        NumberAnimation on opacity {
            id: fadeOut
            from: 1; to: 0
            duration: 280
            easing.type: Easing.InCubic
            running: false
        }
        Timer {
            id: hideTimer
            interval: 880
            repeat: false
            onTriggered: fadeOut.restart()
        }
    }

    // ─── 拖拽抬起缩影（跟随鼠标的小缩略图）─────────────
    //   拖起某 cell 时对其 videoBox 拍静态快照，按固定小宽度（120px）、
    //   保持画面比例缩放成小缩略图，挂在鼠标右下侧（不挡原格与目标格）。
    //   带通道序号徽标，一眼可辨"手里拿的是哪一路"。松手后淡出。
    //   不拦截鼠标事件（无 MouseArea），拖拽交互仍由原 cell 处理。
    Item {
        id: dragGhost
        z: 1000
        // 小缩略图固定宽度，高度按源画面比例换算
        readonly property real thumbW: 120
        width:  thumbW
        height: videoArea._ghostSource
                ? thumbW * videoArea._ghostSource.height / Math.max(1, videoArea._ghostSource.width)
                : 0
        // 以鼠标为中心定位（伪影块中心跟随光标）
        x: Math.max(0, Math.min(videoArea.width  - width,
                                videoArea._ghostX - width / 2))
        y: Math.max(0, Math.min(videoArea.height - height,
                                videoArea._ghostY - height / 2))
        visible: videoArea._ghostActive && videoArea._ghostSource !== null
        // 透明度由拖拽状态直接驱动：拖起时立即不透明，松手时 150ms 淡出。
        // （此前用 NumberAnimation on opacity + running 绑定，应用启动时
        //   动画会先跑完一遍把 opacity 永久定格为 0，导致缩影完全看不见）
        opacity: videoArea._ghostActive ? 0.95 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: videoArea._ghostActive ? 0 : 150
                easing.type: Easing.InCubic
            }
        }

        // 柔和投影：小卡片的悬浮感
        Rectangle {
            anchors.centerIn: parent
            width: parent.width  + 12
            height: parent.height + 12
            radius: 8
            color: "#4d000000"
        }

        // 快照本体：对被拖 cell 的 videoBox 拍一帧静态快照，缩到小卡片里
        ShaderEffectSource {
            id: ghostSnap
            anchors.fill: parent
            sourceItem: videoArea._ghostActive ? videoArea._ghostSource : null
            live: false
            // 拖起瞬间拍一次；之后纹理不随视频刷新（拖拽中画面冻结即可）
            onSourceItemChanged: scheduleUpdate()
        }

        // 通道序号徽标：缩略图左上角，标明"手里拿的是哪一路"
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: -4
            width: chanBadgeText.width + 12
            height: chanBadgeText.height + 6
            radius: 4
            color: "#e63b8ef2"
            z: 2
            Text {
                id: chanBadgeText
                anchors.centerIn: parent
                text: qsTr("%1 号").arg(videoArea._ghostChannel)
                color: "#ffffff"
                font.pixelSize: 11
                font.bold: true
            }
        }
    }
    // 淡出后清空快照引用（释放纹理）
    Timer {
        id: ghostClear
        interval: 180
        onTriggered: { videoArea._ghostSource = null; videoArea._ghostChannel = 0 }
    }
}
