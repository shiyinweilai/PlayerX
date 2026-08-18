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
    property var shortcutsAboutDialogs: null
    property var addDialog: null
    property Item refSidebar: null
    property Item csvBottomBar: null
    property var multiGroupDialog: null
    property var ratingsDialog: null
    property Item leftNavBar: null
    // videoArea 始终跟随 refSidebar 右侧（refSidebar 折叠时宽度=0，等价于贴 leftNavBar.right）。
    // immersive 模式下 leftNavBar 宽度变为 0，refSidebar 自然贴左边。
    anchors.left: refSidebar.right
    anchors.right: parent.right
    anchors.top: parent.top
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
    function slotPlayerIndex(slot) {
        if (Engine.layoutMode === 0) return Engine.activeIndex
        return slot
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
            anchors.centerIn: parent
            spacing: 24
            width: Math.min(parent.width - 80, 720)

            // ── 标题组（参考设计稿）：PlayerX（X 品牌蓝）+ 蓝色发光装饰线 ──
            //   装饰线：水平渐变（两端透明、中间饱和）+ 微弱外发光，
            //   纤细不抢眼，仅用于衬托 X 标识，宽度略小于文字总宽。
            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 10

                Row {
                    id: titleRow
                    Layout.alignment: Qt.AlignHCenter
                    Text { text: "Player"; color: "#f4f6fa"; font.pixelSize: 36; font.bold: true }
                    Text { text: "X";      color: "#3b8ef2"; font.pixelSize: 36; font.bold: true }
                }

                // 装饰线本体 + 光晕：三层同中心渐变线叠出"发光"观感
                //（Qt5Compat.GraphicalEffects 的运行库在本应用部署中不可用，
                //  Glow 会导致启动失败；改用零依赖叠层模拟，效果等价）
                Item {
                    Layout.alignment: Qt.AlignHCenter
                    implicitWidth: titleRow.implicitWidth * 0.9
                    implicitHeight: 10

                    // 外层光晕（最宽最淡）
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: 10
                        radius: 5
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#003b8ef2" }
                            GradientStop { position: 0.3; color: "#223b8ef2" }
                            GradientStop { position: 0.7; color: "#223b8ef2" }
                            GradientStop { position: 1.0; color: "#003b8ef2" }
                        }
                    }
                    // 中层光晕
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: 6
                        radius: 3
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#003b8ef2" }
                            GradientStop { position: 0.3; color: "#553b8ef2" }
                            GradientStop { position: 0.7; color: "#553b8ef2" }
                            GradientStop { position: 1.0; color: "#003b8ef2" }
                        }
                    }
                    // 核心亮线
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width
                        height: 3
                        radius: 1.5
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#003b8ef2" }
                            GradientStop { position: 0.3; color: "#3b8ef2" }
                            GradientStop { position: 0.7; color: "#3b8ef2" }
                            GradientStop { position: 1.0; color: "#003b8ef2" }
                        }
                    }
                }
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "多路视频对比 · 同步播放 · 评分采集"
                color: "#9aa0a6"
                font.pixelSize: 14
            }

            // ── 两个大按钮 ─────────────────────────────────────
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 18

                // ① 打开文件
                Rectangle {
                    id: heroBtnFile
                    Layout.preferredWidth: 240
                    Layout.preferredHeight: 132
                    radius: 10
                    color: heroBtnFileMA.containsMouse ? "#2a3a55"
                          : heroBtnFileMA.pressed     ? "#1e2a40"
                                                      : "#1e1e22"
                    border.color: heroBtnFileMA.containsMouse ? "#3a78c8" : "#3a3a42"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "🎬"
                            font.pixelSize: 36
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "打开文件"
                            color: "#e8e8ec"
                            font.pixelSize: 16
                            font.bold: true
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "选择 1-9 个视频文件"
                            color: "#9aa0a6"
                            font.pixelSize: 12
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
                    Layout.preferredWidth: 240
                    Layout.preferredHeight: 132
                    radius: 10
                    color: heroBtnFolderMA.containsMouse ? "#2a3a55"
                          : heroBtnFolderMA.pressed     ? "#1e2a40"
                                                        : "#1e1e22"
                    border.color: heroBtnFolderMA.containsMouse ? "#3a78c8" : "#3a3a42"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "📁"
                            font.pixelSize: 36
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "打开文件夹"
                            color: "#e8e8ec"
                            font.pixelSize: 16
                            font.bold: true
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "整文件夹载入 / 多组对比"
                            color: "#9aa0a6"
                            font.pixelSize: 12
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

            // ── 操作说明 ──────────────────────────────────────
            // 设计说明（图1 → 当前版本）：
            //   旧版仅展示 4 行"打开 / 播放 / 视图 / 路·速"的极简速览，再用一个
            //   「查看全部快捷键 →（F1）」链接跳转到 shortcutsDialog。
            //   现在快捷键数量稳定（≤5 组、共十几行），首页空态有足够留白，干脆
            //   直接平铺展示全部分组，无需二次跳转；同时保留 F1 入口，便于
            //   未来扩展更多快捷键时仍可单独打开速查面板。
            //   组件复用：直接使用 root 顶层定义的 ScSection / ScRow，与 F1
            //   对话框 100% 一致；这样以后只要维护一份内容，两处自动同步。
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                // 宽度 720：与 shortcutsDialog 的两列网格留白接近，
                // 单行最长描述「切换通道信息叠加（序号 + 文件名）」也能一行放下。
                Layout.preferredWidth: 720
                color: "#14141820"
                radius: 8
                border.color: "#2a2a32"
                border.width: 1
                implicitHeight: tipsCol.implicitHeight + 24

                ColumnLayout {
                    id: tipsCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 6

                    Text {
                        text: emptyHero.dragHover
                              ? "🎯 松开鼠标即可载入"
                              : "💡 也可以直接把视频文件或文件夹 拖入此窗口"
                        color: emptyHero.dragHover ? "#6aa8ff" : "#cfd2d6"
                        font.pixelSize: 13
                        font.bold: emptyHero.dragHover
                    }
                    Text {
                        text: "·  支持 mp4 / mov / mkv / avi / webm / flv / ts / m4v / wmv，最多同时载入 9 路"
                        color: "#9aa0a6"
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }

                    // 分隔线：让"拖拽提示文案"与"快捷键分组"的视觉层级清晰一些
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        Layout.bottomMargin: 2
                        height: 1
                        color: "#2a2a32"
                    }

                    // ── 全量快捷键：两列 × 多分组（与 F1 对话框完全一致）──
                    //   左列：播放 / 倍速 / 多组对比
                    //   右列：视图 / 单路 · 多路
                    //   使用 ScSection + ScRow（root 顶层 inline component），
                    //   保证视觉与 shortcutsDialog 完全一致；后续扩展只需改两处之一。
                    GridLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        columns: 2
                        columnSpacing: 28
                        rowSpacing: 12

                        // 左列 1：播放
                        ScSection {
                            title: qsTr("播放")
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            ScRow { keys: "Space";    desc: qsTr("暂停 / 继续") }
                            ScRow { keys: "←  /  →";  desc: qsTr("后退 / 前进 5 秒") }
                            ScRow { keys: ",  /  .";  desc: qsTr("上一帧 / 下一帧") }
                            ScRow { keys: "R";        desc: qsTr("回到开头") }
                        }
                        // 右列 1：视图
                        ScSection {
                            title: qsTr("视图")
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            ScRow { keys: "F"; desc: qsTr("切换全屏") }
                            ScRow { keys: "V"; desc: qsTr("切换视频信息叠加") }
                            ScRow { keys: "C"; desc: qsTr("切换通道信息叠加（序号 + 文件名）") }
                            ScRow { keys: "S"; desc: qsTr("多路视频时切换布局如1xN / 2x2 / 3x3") }
                            ScRow { keys: "B"; desc: qsTr("滑动对比模式（仅 2 路）") }
                        }
                        // 左列 2：倍速
                        ScSection {
                            title: qsTr("倍速")
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            ScRow { keys: "-";        desc: qsTr("减速一档") }
                            ScRow { keys: "=  /  +";  desc: qsTr("加速一档") }
                            ScRow { keys: "0";        desc: qsTr("复位为 1.0×") }
                        }
                        // 右列 2：单路 / 多路
                        ScSection {
                            title: qsTr("单路 / 多路")
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            ScRow { keys: "1 … 9"; desc: qsTr("切到第 N 路单路；再次按下回到上次的多路布局") }
                            ScRow { keys: "⤢ / ⤡"; desc: qsTr("放大 / 还原本路（每路 hover 工具栏，等同数字键）") }
                            ScRow { keys: "⋯";     desc: qsTr("替换本路视频（hover 显示完整路径）") }
                            ScRow { keys: "✕";     desc: qsTr("关闭本路视频") }
                        }
                        // 左列 3：多组对比
                        ScSection {
                            title: qsTr("多组对比（仅当多组对比窗口激活时）")
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            ScRow { keys: "Ctrl+↑"; desc: qsTr("上一组") }
                            ScRow { keys: "Ctrl+↓"; desc: qsTr("下一组") }
                        }
                        // 右列 3：视图缩放 / 平移（所有路同步）
                        ScSection {
                            title: qsTr("视图缩放 / 平移（所有路同步）")
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            ScRow { keys: qsTr("鼠标滚轮");    desc: qsTr("以鼠标位置为锚点缩放（0.2× ~ 8×）") }
                            ScRow { keys: qsTr("右键拖拽");    desc: qsTr("同步平移所有路（画面跟随鼠标方向）") }
                            ScRow { keys: qsTr("Ctrl+双击");   desc: qsTr("视图复位（缩放/平移归零）") }
                            ScRow { keys: "⊙";              desc: qsTr("底部工具栏 视图复位按钮") }
                        }
                    }

                    // 入口：跳转到「快捷键…」对话框
                    // 当前所有快捷键已经在上方平铺展示，这里仍保留 F1 入口，
                    // 一是兼容老用户的 F1 习惯，二是为将来"快捷键变多需要滚动的弹窗"留出口。
                    Item {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        implicitHeight: 18
                        Text {
                            id: shortcutsLink
                            anchors.right: parent.right
                            text: "查看全部快捷键 →   (F1)"
                            color: shortcutsLinkMA.containsMouse ? "#6aa8ff" : "#7a7f86"
                            font.pixelSize: 12
                            font.underline: shortcutsLinkMA.containsMouse
                        }
                        MouseArea {
                            id: shortcutsLinkMA
                            anchors.fill: shortcutsLink
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: shortcutsAboutDialogs.openShortcuts()
                        }
                    }
                }
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
                var fileFromDirs = []   // 文件夹展开后的视频文件路径（散文件兜底用）
                var standaloneFiles = []  // 直接拖入的视频散文件 url

                for (var i = 0; i < drop.urls.length; ++i) {
                    var u = drop.urls[i]
                    var s = String(u)
                    var scanned = []
                    try { scanned = Fs.scanVideoFolder(u, true) } catch (e) { scanned = [] }

                    if (scanned && scanned.length > 0) {
                        folderUrls.push(u)
                        for (var j = 0; j < scanned.length; ++j) fileFromDirs.push("file://" + scanned[j])
                    } else if (hasVideoExt(s)) {
                        standaloneFiles.push(s)
                    }
                }

                // ── 拖入含文件夹 → 直接打开 MultiGroupDialog（等同点击"打开文件夹"）──
                //   · 拖入的文件夹默认勾选；历史文件夹默认不勾选（由 addFoldersAndShow 保证）
                //   · 不再静默 "loadFolders 立即播放"，而是把选择权交给用户：
                //     在 Dialog 里确认勾选后点击"开始/确认"再启动播放。
                //   · 混合（文件夹 + 散文件）时，文件夹优先 → 走 Dialog；散文件被忽略（语义不明）。
                if (folderUrls.length > 0) {
                    try { multiGroupDialog.addFoldersAndShow(folderUrls) } catch (e) {}
                    return
                }

                // ── 仅散文件场景：保留"直接铺开播放"的旧体验 ──
                var collected = []
                for (var m = 0; m < standaloneFiles.length && collected.length < 9; ++m) {
                    collected.push(standaloneFiles[m])
                }

                if (collected.length === 0) return
                if (collected.length > 9) collected = collected.slice(0, 9)
                Engine.openFiles(collected)
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
        setSlideRatingFn: function(side, score) { Logic.setSlideRating(side, score) }
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
}
