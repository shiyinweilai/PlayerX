// MultiGroupDialog.qml — 多组对比模式配置面板
//
// 设计要点：
//   - 完全独立的 Dialog（root.MultiGroupDialog { ... }），平时不显示；
//   - 用户在「打开 ▾」二级菜单中点「多组对比模式…」时弹出；
//   - 内部维护一个 lanes[] 数组（每路独立 folderPath / keyword / allFiles / visibleFiles / currentIndex），
//     由若干 MultiGroupRow 渲染；
//   - 「启动对比」一次性把所有路的 currentPath 组成 QList<QUrl> 调 Engine.openFiles —— 完全复用旧接口；
//   - 暴露 active / canStart / start() / nextGroup() / prevGroup() 给 Main.qml 使用；
//   - 启动后保留 lanes 状态，便于「下一组」直接换 currentIndex 并再次 openFiles。
//
// 单组模式（Dialog 不弹 + active = false）下，以上一切不会触达 Engine，对主体功能 0 影响。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import PlayerX 1.0

ApplicationWindow {
    id: dlg
    title: "打开文件夹 / 多组对比"

    // 最多 9 路（与 Engine 上限一致）
    readonly property int kMaxLanes: 9
    // 旧语义：多组对比至少 2 路；新语义下作为「是否进入多组对比态」的阈值使用，
    //        当勾选数 < 2 时仅走单文件夹打开，不会把 active 置 true。
    readonly property int kMinLanes: 2

    // ─── 对外属性 ───────────────────────────────────────────────────
    // 多组模式是否处于"已启动"状态：用户至少成功 start() 过一次，
    // 且 lanes 仍是当前打开的那一批（lanes 内容若被用户改动会自动失效）。
    property bool active: false

    // 当前每路在自己 visibleFiles 中的索引（仅用于"上一组/下一组"导航；start() 时刷新）
    property var laneSnapshotPaths: []   // 上次启动时各路的 currentPath，用于检测是否需要重新 start
    property var laneSnapshotIndexes: [] // 上次启动时各路的 currentIndex

    // ─── 单路浏览模式的「N 宫格」状态 ───────────────────────────────
    // singleLaneMode = true 时，表示当前已启动且只有 1 路有效（来自单文件夹 / 添加文件）。
    // 此时支持把当前页同时显示 viewCount 个视频（1/2/4/6/9），
    // navigate(±1) 会以 viewCount 为步长翻页。
    // 多组对比模式（≥2 路文件夹）下 viewCount 始终视作 1，宫格切换按钮在主界面隐藏。
    readonly property var supportedViewCounts: [1, 2, 4, 6, 9]
    property int viewCount: 1
    // 当前激活路的索引（active 后；单路浏览/扁平文件来源时即唯一那一路；多组对比下取第一路）
    property int activeLaneIndex: -1

    // 是否处于「单路浏览」态：active=true 且只有 1 路在跑（含「添加文件」走 loadFlatFiles 创建的虚拟路）
    readonly property bool singleLaneMode: active && _isSingleLaneActive()

    function _isSingleLaneActive() {
        // 用启动时的快照判断：laneSnapshotPaths.length === 1 即单路
        return laneSnapshotPaths && laneSnapshotPaths.length === 1
    }

    // ─── 是否可启动 ─────────────────────────────────────────────────
    // 新语义：只要有 ≥1 路「勾选 + 已选文件夹且有命中」即可启动。
    //        「勾选但未选文件夹」的行会被启动逻辑自动忽略，不会阻塞其他已就绪的行。
    //        有效路数 == 1 → 单视频浏览；有效路数 >= 2 → 多组对比。
    readonly property bool canStart: _computeCanStart()
    // 当前勾选路数（含未选文件夹的）
    readonly property int selectedCount: _computeSelectedCount()
    // 当前「有效路数」：勾选 + currentPath 非空（真正会被启动的路数）
    readonly property int effectiveCount: _computeEffectiveCount()

    function _computeSelectedCount() {
        var _ = stateBumper
        var n = 0
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            if (lane && lane.selected) n++
        }
        return n
    }

    function _computeEffectiveCount() {
        var _ = stateBumper
        var n = 0
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            if (!lane || !lane.selected) continue
            if (!lane.currentPath || lane.currentPath.length === 0) continue
            n++
        }
        return n
    }

    function _computeCanStart() {
        // 显式触达 stateBumper，让 QML 绑定系统把它纳入依赖；每次 _bumpState() 后 canStart 会重算
        var _ = stateBumper
        // 只要任意一路「勾选 + 有 currentPath」就可以启动；
        // 「勾选但未选文件夹」的行会被 start() 自动忽略，不影响 canStart。
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            if (!lane || !lane.selected) continue
            if (lane.currentPath && lane.currentPath.length > 0) return true
        }
        return false
    }

    // ─── 内部小工具：根据 N 选 LayoutMode ──────────────────────────
    // Engine.LayoutMode：0=Single 1=SideBySide 2=Grid2x2 3=Grid2x3 4=Grid3x3
    function _layoutModeFor(n) {
        if (n <= 1) return 0
        if (n === 2) return 1
        if (n === 3 || n === 4) return 2
        if (n === 5 || n === 6) return 3
        return 4 // 7/8/9 → 3x3
    }

    // 触发 canStart 重新计算：修改一个有 changed 信号的普通属性即可让绑定重求。
    // 下划线开头的属性名会被 QML 视为“私有”但仍有 changed 信号，只是不能用
    // onXxxChanged 在同作用域写 handler。这里改为普通名字 stateBumper，不需要 handler。
    property int stateBumper: 0
    function _bumpState() { stateBumper = stateBumper + 1 }

    // ─── 数据模型：每路一个 ListModel 元素 ──────────────────────────
    ListModel {
        id: _rowsModel
        // 元素字段：selected / folderPath / keyword / currentPath / currentIndex / allCount / visibleCount
        // allFiles / visibleFiles 不存进 ListModel（QML ListModel 对 var 数组支持有限），
        // 改用并行的 _laneRuntime[] 数组，存运行时状态。
    }
    // 与 _rowsModel 并行的运行时数据（QML 中 ListModel 不便存 array 字段）。
    property var _laneRuntime: []

    function _ensureRuntimeLen(n) {
        while (_laneRuntime.length < n) _laneRuntime.push({ allFiles: [], visibleFiles: [] })
        if (_laneRuntime.length > n) _laneRuntime = _laneRuntime.slice(0, n)
    }

    // 增加一路（默认 keyword 用 _a / _b / _c …帮助快速配置）
    function addLane() {
        if (_rowsModel.count >= kMaxLanes) return
        var idx = _rowsModel.count
        var defaultKw = ""
        // 第二路开始默认给个递增字母提示，但不强制
        if (idx === 0) defaultKw = ""
        else defaultKw = ""   // 不预填，避免用户没改导致命中为 0
        _rowsModel.append({
            selected: true,
            folderPath: "",
            keyword: defaultKw,
            currentPath: "",
            currentIndex: -1,
            allCount: 0,
            visibleCount: 0
        })
        _laneRuntime.push({ allFiles: [], visibleFiles: [] })
        _bumpState()
    }

    function removeLane(i) {
        if (i < 0 || i >= _rowsModel.count) return
        if (_rowsModel.count <= 1) return  // 至少保留 1 行视觉占位
        _rowsModel.remove(i)
        _laneRuntime.splice(i, 1)
        _bumpState()
    }

    // 由 MultiGroupRow.laneChanged 调用，将当前行 UI 状态写回模型
    function _syncLaneFromRow(i, selected, folderPath, keyword, allFiles, visibleFiles, currentIndex) {
        if (i < 0 || i >= _rowsModel.count) return
        _ensureRuntimeLen(_rowsModel.count)
        _laneRuntime[i] = { allFiles: allFiles, visibleFiles: visibleFiles }
        var curPath = (currentIndex >= 0 && currentIndex < visibleFiles.length)
                      ? visibleFiles[currentIndex] : ""
        _rowsModel.set(i, {
            selected: selected,
            folderPath: folderPath,
            keyword: keyword,
            currentPath: curPath,
            currentIndex: currentIndex,
            allCount: allFiles.length,
            visibleCount: visibleFiles.length
        })
        _bumpState()
    }

    // ─── 对外动作：启动 / 切组 ──────────────────────────────────────
    // 新语义：
    //   · 勾选 1 路  → 单视频浏览模式（只打开 currentPath 这一个），active=true，
    //                  「上一组/下一组」在该路 visibleFiles 内循环切换
    //   · 勾选 >=2 路 → 多组对比（每路 currentPath 组 url 列表），active=true
    function start() {
        if (!canStart) return false

        // 只收集「有效路」：勾选 + currentPath 非空。
        // 勾选但未选文件夹的行（如默认第 2 行）会被静默忽略，不阻塞启动。
        var selIdx = []
        for (var i = 0; i < _rowsModel.count; ++i) {
            var l = _rowsModel.get(i)
            if (!l.selected) continue
            if (!l.currentPath || l.currentPath.length === 0) continue
            selIdx.push(i)
        }
        if (selIdx.length === 0) return false

        // 仅有效 1 路：单视频浏览模式 —— 只打开当前选中那个视频，可用上一组/下一组循环切换
        if (selIdx.length === 1) {
            var onlyI = selIdx[0]
            var rt = _laneRuntime[onlyI]
            if (!rt || !rt.visibleFiles || rt.visibleFiles.length === 0) return false
            var laneOnly = _rowsModel.get(onlyI)
            var urls1 = Fs.toFileUrls([ laneOnly.currentPath ])
            if (urls1.length === 0) return false
            var ok1 = Engine.openFiles(urls1)
            if (ok1) {
                // 进入 active 态，使「上一组/下一组」可以在 visibleFiles 内循环切换
                laneSnapshotPaths = [ laneOnly.currentPath ]
                laneSnapshotIndexes = [ laneOnly.currentIndex ]
                activeLaneIndex = onlyI
                viewCount = 1
                active = true
                // 单视频用单视图最合适
                if (Engine.layoutMode !== 0) Engine.layoutMode = 0
            }
            return ok1
        }

        // 有效路 >=2：多组对比
        var paths = []
        var indexes = []
        for (var k = 0; k < selIdx.length; ++k) {
            var lane = _rowsModel.get(selIdx[k])
            paths.push(lane.currentPath)
            indexes.push(lane.currentIndex)
        }
        var urls = Fs.toFileUrls(paths)
        if (urls.length < kMinLanes) return false
        var ok = Engine.openFiles(urls)
        if (ok) {
            laneSnapshotPaths = paths
            laneSnapshotIndexes = indexes
            activeLaneIndex = selIdx.length > 0 ? selIdx[0] : -1
            viewCount = 1   // 多组对比下 viewCount 概念不参与，强制 1
            active = true
            // 启动后默认把布局切到 1×N，避免 single 模式只看到一路
            if (Engine.layoutMode === 0 && urls.length > 1) Engine.layoutMode = 1
        }
        return ok
    }

    // ─── 「添加文件」走的扁平接管入口 ──────────────────────────────
    // 把一组离散视频文件 (urls / 也允许 path) 作为「单路浏览」的 visibleFiles 接管，
    // 启动后即可使用 N 宫格切换 + 翻页。
    //
    // 实现方式：把这批文件灌进一个新建的 lane（folderPath/keyword 留空，仅 allFiles/visibleFiles 有值），
    // 调用 Engine.openFiles 打开第 0 个，进入 active 态。
    // 所有翻页 / 宫格切换走 navigate / setViewCount，与单文件夹模式完全一致。
    function loadFlatFiles(urls) {
        if (!urls || urls.length === 0) return false
        // 统一成本地路径数组：file:// URL → 本地路径；普通字符串保持不变
        var localPaths = []
        for (var i = 0; i < urls.length; ++i) {
            var u = urls[i]
            var s = ""
            if (typeof u === "string") s = u
            else if (u !== undefined && u !== null) {
                // QUrl 或可 toString 的对象
                s = u.toString()
            }
            if (!s) continue
            if (s.indexOf("file://") === 0) {
                // 转本地路径
                s = Fs.urlToLocalFile(u)
            }
            if (s && s.length > 0) localPaths.push(s)
        }
        if (localPaths.length === 0) return false

        // 重置 lanes：只保留 1 路，把扁平文件灌进去
        while (_rowsModel.count > 1) removeLane(_rowsModel.count - 1)
        if (_rowsModel.count === 0) addLane()
        _ensureRuntimeLen(_rowsModel.count)
        _laneRuntime[0] = { allFiles: localPaths, visibleFiles: localPaths }
        _rowsModel.set(0, {
            selected: true,
            folderPath: "",         // 没有文件夹，纯文件来源
            keyword: "",
            currentPath: localPaths[0],
            currentIndex: 0,
            allCount: localPaths.length,
            visibleCount: localPaths.length
        })
        _bumpState()

        // 打开第 0 个，进入 active 态
        var u0 = Fs.toFileUrls([ localPaths[0] ])
        if (u0.length === 0) return false
        var ok = Engine.openFiles(u0)
        if (ok) {
            laneSnapshotPaths = [ localPaths[0] ]
            laneSnapshotIndexes = [ 0 ]
            activeLaneIndex = 0
            viewCount = 1
            active = true
            if (Engine.layoutMode !== 0) Engine.layoutMode = 0
        }
        return ok
    }

    // ─── 单路浏览：切换「同时显示 N 个」 ────────────────────────────
    // 从当前 currentIndex 起，连续取 N 个 visibleFiles 一并打开（不够则截断）。
    // 调用前提：singleLaneMode === true。多组对比下调用直接 no-op。
    function setViewCount(n) {
        if (!active) return false
        if (!singleLaneMode) return false
        if (supportedViewCounts.indexOf(n) < 0) return false
        var i = activeLaneIndex
        if (i < 0 || i >= _laneRuntime.length) return false
        var rt = _laneRuntime[i]
        if (!rt || !rt.visibleFiles || rt.visibleFiles.length === 0) return false
        var lane = _rowsModel.get(i)
        if (!lane) return false
        var total = rt.visibleFiles.length
        // 「页起点」对齐：以当前 currentIndex 所在的页起点重算（保证跨 N 切换时不抖）
        var oldN = Math.max(1, viewCount)
        var pageStart = Math.floor(Math.max(0, lane.currentIndex) / oldN) * oldN
        if (pageStart >= total) pageStart = 0
        // 取 N 个（末尾不够就截断）
        var take = Math.min(n, total - pageStart)
        if (take <= 0) return false
        var slice = rt.visibleFiles.slice(pageStart, pageStart + take)
        var urls = Fs.toFileUrls(slice)
        if (urls.length === 0) return false
        var ok = Engine.openFiles(urls)
        if (!ok) return false
        // 同步页起点 → currentIndex；snapshot/viewCount 更新
        _rowsModel.set(i, {
            selected: lane.selected,
            folderPath: lane.folderPath,
            keyword: lane.keyword,
            currentPath: rt.visibleFiles[pageStart],
            currentIndex: pageStart,
            allCount: rt.allFiles.length,
            visibleCount: total
        })
        viewCount = n
        // 单路 snapshot 仍记一路（path 跟踪页起点；indexes 跟踪页起点 index）
        laneSnapshotPaths = [ rt.visibleFiles[pageStart] ]
        laneSnapshotIndexes = [ pageStart ]
        Engine.layoutMode = _layoutModeFor(take)
        return true
    }

    // 上一组 / 下一组：
    //   · 单路浏览模式（singleLaneMode=true）：以 viewCount 为步长翻页（循环），一次性打开 N 个
    //   · 多组对比模式：每路 ±1 循环切换
    // dir = -1 / +1
    function navigate(dir) {
        if (!active) return false
        if (dir !== -1 && dir !== 1) return false

        // ── 单路浏览：按 viewCount 翻页 ──────────────────────────────
        if (singleLaneMode) {
            var i = activeLaneIndex
            if (i < 0 || i >= _laneRuntime.length) return false
            var rt = _laneRuntime[i]
            if (!rt || !rt.visibleFiles || rt.visibleFiles.length === 0) return false
            var lane = _rowsModel.get(i)
            if (!lane) return false
            var total = rt.visibleFiles.length
            var step = Math.max(1, viewCount)
            // 总页数：ceil(total / step)
            var pages = Math.ceil(total / step)
            var curPage = Math.floor(Math.max(0, lane.currentIndex) / step)
            var nextPage = ((curPage + dir) % pages + pages) % pages
            var pageStart = nextPage * step
            if (pageStart >= total) pageStart = 0
            var take = Math.min(step, total - pageStart)
            if (take <= 0) return false
            var slice = rt.visibleFiles.slice(pageStart, pageStart + take)
            var urls1 = Fs.toFileUrls(slice)
            if (urls1.length === 0) return false
            var ok1 = Engine.openFiles(urls1)
            if (!ok1) return false
            _rowsModel.set(i, {
                selected: lane.selected,
                folderPath: lane.folderPath,
                keyword: lane.keyword,
                currentPath: rt.visibleFiles[pageStart],
                currentIndex: pageStart,
                allCount: rt.allFiles.length,
                visibleCount: total
            })
            laneSnapshotPaths = [ rt.visibleFiles[pageStart] ]
            laneSnapshotIndexes = [ pageStart ]
            // 末页不足 N 时降级 layoutMode 兼容显示
            Engine.layoutMode = _layoutModeFor(take)
            return true
        }

        // ── 多组对比：每路 ±1 循环（保留旧逻辑） ────────────────────
        var anyMoved = false
        for (var k = 0; k < _rowsModel.count; ++k) {
            var laneM = _rowsModel.get(k)
            if (!laneM.selected) continue
            var rtM = _laneRuntime[k]
            if (!rtM || rtM.visibleFiles.length === 0) continue
            var nM = rtM.visibleFiles.length
            var curM = laneM.currentIndex
            var nextM = ((curM + dir) % nM + nM) % nM
            if (nextM !== curM) {
                anyMoved = true
                _rowsModel.set(k, {
                    selected: laneM.selected,
                    folderPath: laneM.folderPath,
                    keyword: laneM.keyword,
                    currentPath: rtM.visibleFiles[nextM],
                    currentIndex: nextM,
                    allCount: rtM.allFiles.length,
                    visibleCount: nM
                })
            }
        }
        if (!anyMoved) return false
        var paths = []
        for (var j = 0; j < _rowsModel.count; ++j) {
            var ln = _rowsModel.get(j)
            if (!ln.selected) continue
            if (!ln.currentPath || ln.currentPath.length === 0) continue
            paths.push(ln.currentPath)
        }
        var urls = Fs.toFileUrls(paths)
        if (urls.length < 1) return false
        return Engine.openFiles(urls)
    }
    function nextGroup() { return navigate(1) }
    function prevGroup() { return navigate(-1) }

    // 当前组号 / 总组数（仅显示用）
    //   · 单路浏览模式：按页计算，groupCount = ceil(total / viewCount), groupIndex = floor(cur / viewCount)
    //   · 多组对比模式：基于"最长那路的 visibleFiles"
    function groupCount() {
        if (singleLaneMode) {
            var i = activeLaneIndex
            if (i < 0 || i >= _laneRuntime.length) return 0
            var rt = _laneRuntime[i]
            if (!rt || !rt.visibleFiles) return 0
            var step = Math.max(1, viewCount)
            return Math.ceil(rt.visibleFiles.length / step)
        }
        var maxN = 0
        for (var k = 0; k < _laneRuntime.length; ++k) {
            var rtM = _laneRuntime[k]
            if (rtM && rtM.visibleFiles.length > maxN) maxN = rtM.visibleFiles.length
        }
        return maxN
    }
    function groupIndex() {
        if (singleLaneMode) {
            var i = activeLaneIndex
            if (i < 0 || i >= _rowsModel.count) return -1
            var lane = _rowsModel.get(i)
            if (!lane) return -1
            var step = Math.max(1, viewCount)
            return Math.floor(Math.max(0, lane.currentIndex) / step)
        }
        for (var j = 0; j < _rowsModel.count; ++j) {
            var ln = _rowsModel.get(j)
            if (ln && ln.selected) return ln.currentIndex
        }
        if (_rowsModel.count === 0) return -1
        return _rowsModel.get(0).currentIndex
    }

    // ─── 窗口外观 ─────────────────────────────────
    width: 920
    height: 520
    minimumWidth: 760
    minimumHeight: 360
    color: "#161619"
    flags: Qt.Dialog
    modality: Qt.NonModal

    Component.onCompleted: {
        // 默认 2 行（最常用：左右对比）
        if (_rowsModel.count === 0) {
            addLane()
            addLane()
        }
    }

    // ─── 内容布局 ───────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        // 标题
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Label {
                text: "🗂️ 打开文件夹 / 多组对比"
                color: "#e8e8ec"
                font.pixelSize: 16
                font.bold: true
            }
            Label {
                text: "勾选 1 路 = 单视频浏览（用上一组/下一组在该文件夹内循环切换）；勾选 ≥2 路 = 多组对比"
                color: "#888"
                font.pixelSize: 11
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }

        // 行列表
        ScrollView {
            id: rowsScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ColumnLayout {
                width: rowsScroll.availableWidth
                spacing: 8

                Repeater {
                    model: _rowsModel
                    delegate: MultiGroupRow {
                        Layout.fillWidth: true
                        laneIndex: index
                        selected: model.selected
                        folderPath: model.folderPath
                        keyword: model.keyword
                        currentIndex: model.currentIndex
                        removable: _rowsModel.count > 1
                        Component.onCompleted: {
                            // 还原 allFiles / visibleFiles（首次创建时为空，重新加载也无需重建）
                            var rt = _laneRuntime[index]
                            if (rt) {
                                allFiles = rt.allFiles
                            }
                        }
                        onLaneChanged: {
                            _syncLaneFromRow(index, selected, folderPath, keyword,
                                             allFiles, visibleFiles, currentIndex)
                        }
                        onRemoveRequested: removeLane(index)
                    }
                }

                // ➕ 新增一行
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    spacing: 12
                    Button {
                        id: addLaneBtn
                        text: "➕ 新增一路"
                        enabled: _rowsModel.count < kMaxLanes
                        onClicked: addLane()
                        background: Rectangle {
                            color: !addLaneBtn.enabled ? "#1a1a1d"
                                  : addLaneBtn.down ? "#4a4a55"
                                  : addLaneBtn.hovered ? "#33333a"
                                                    : "#202024"
                            border.color: "#3a3a42"
                            border.width: 1
                            radius: 4
                        }
                        contentItem: Text {
                            text: addLaneBtn.text
                            color: addLaneBtn.enabled ? "#e8e8ec" : "#555"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        Layout.preferredHeight: 30
                        Layout.preferredWidth: 110
                    }
                    Label {
                        text: "（最多 " + kMaxLanes + " 路）"
                        color: "#666"
                        font.pixelSize: 11
                        Layout.alignment: Qt.AlignVCenter
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        // 分隔线
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: "#2a2a32"
        }

        // 底部按钮栏
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                color: "#9a9aa8"
                font.pixelSize: 11
                text: {
                    if (active) return "已启动 · 当前组 " + (groupIndex() + 1) + " / " + groupCount()
                    if (canStart) {
                        if (effectiveCount === 1) return "✓ 已就绪：将打开当前选中视频，可用上一组/下一组循环切换"
                        return "✓ 已就绪：将启动 " + effectiveCount + " 路对比（未填文件夹的勾选行会自动忽略）"
                    }
                    if (selectedCount === 0) return "请至少勾选一路"
                    return "请为勾选的路选择文件夹并确保有命中文件"
                }
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            Button {
                text: "关闭"
                onClicked: dlg.close()
                background: Rectangle {
                    color: parent.down ? "#4a4a55"
                          : parent.hovered ? "#33333a"
                                            : "#202024"
                    border.color: "#3a3a42"
                    border.width: 1
                    radius: 4
                }
                contentItem: Text {
                    text: parent.text
                    color: "#e8e8ec"
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                implicitHeight: 30
                implicitWidth: 80
            }

            Button {
                id: startBtn
                text: {
                    if (active) return "重新启动"
                    if (effectiveCount === 1) return "打开视频"
                    return "启动对比"
                }
                enabled: canStart
                onClicked: {
                    if (start()) dlg.close()
                }
                background: Rectangle {
                    color: !startBtn.enabled ? "#1a1a1d"
                          : startBtn.down ? "#0a8f76"
                          : startBtn.hovered ? "#0db092"
                                              : "#0fa085"
                    border.color: startBtn.enabled ? "#0fa085" : "#2c2c32"
                    border.width: 1
                    radius: 4
                }
                contentItem: Text {
                    text: startBtn.text
                    color: startBtn.enabled ? "#ffffff" : "#555"
                    font.pixelSize: 12
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                implicitHeight: 30
                implicitWidth: 110
            }
        }
    }
}
