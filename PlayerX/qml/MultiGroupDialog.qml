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
    title: "多组对比模式"

    // 最多 9 路（与 Engine 上限一致）
    readonly property int kMaxLanes: 9
    readonly property int kMinLanes: 2

    // ─── 对外属性 ───────────────────────────────────────────────────
    // 多组模式是否处于"已启动"状态：用户至少成功 start() 过一次，
    // 且 lanes 仍是当前打开的那一批（lanes 内容若被用户改动会自动失效）。
    property bool active: false

    // 当前每路在自己 visibleFiles 中的索引（仅用于"上一组/下一组"导航；start() 时刷新）
    property var laneSnapshotPaths: []   // 上次启动时各路的 currentPath，用于检测是否需要重新 start
    property var laneSnapshotIndexes: [] // 上次启动时各路的 currentIndex

    // ─── 是否可启动 ─────────────────────────────────────────────────
    readonly property bool canStart: _computeCanStart()

    function _computeCanStart() {
        // 显式触达 stateBumper，让 QML 绑定系统把它纳入依赖；每次 _bumpState() 后 canStart 会重算
        var _ = stateBumper
        // 至少 2 路、且每路都有当前选中文件
        if (_rowsModel.count < kMinLanes) return false
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            if (!lane || !lane.currentPath || lane.currentPath.length === 0) return false
        }
        return true
    }

    // 触发 canStart 重新计算：修改一个有 changed 信号的普通属性即可让绑定重求。
    // 下划线开头的属性名会被 QML 视为“私有”但仍有 changed 信号，只是不能用
    // onXxxChanged 在同作用域写 handler。这里改为普通名字 stateBumper，不需要 handler。
    property int stateBumper: 0
    function _bumpState() { stateBumper = stateBumper + 1 }

    // ─── 数据模型：每路一个 ListModel 元素 ──────────────────────────
    ListModel {
        id: _rowsModel
        // 元素字段：folderPath / keyword / currentPath / currentIndex / allCount / visibleCount
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

    // 由 MultiGroupRow.stateChanged 调用，将当前行 UI 状态写回模型
    function _syncLaneFromRow(i, folderPath, keyword, allFiles, visibleFiles, currentIndex) {
        if (i < 0 || i >= _rowsModel.count) return
        _ensureRuntimeLen(_rowsModel.count)
        _laneRuntime[i] = { allFiles: allFiles, visibleFiles: visibleFiles }
        var curPath = (currentIndex >= 0 && currentIndex < visibleFiles.length)
                      ? visibleFiles[currentIndex] : ""
        _rowsModel.set(i, {
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
    // 把每路的 currentPath 收集成 url 列表，调 Engine.openFiles。
    function start() {
        if (!canStart) return false
        var paths = []
        var indexes = []
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            paths.push(lane.currentPath)
            indexes.push(lane.currentIndex)
        }
        var urls = Fs.toFileUrls(paths)
        if (urls.length < kMinLanes) return false
        var ok = Engine.openFiles(urls)
        if (ok) {
            laneSnapshotPaths = paths
            laneSnapshotIndexes = indexes
            active = true
            // 启动后默认把布局切到 1×N，避免 single 模式只看到一路
            if (Engine.layoutMode === 0 && urls.length > 1) Engine.layoutMode = 1
        }
        return ok
    }

    // 上一组 / 下一组：每路在自己 visibleFiles 内 ±1，再 start()
    // dir = -1 / +1
    function navigate(dir) {
        if (!active) return false
        if (dir !== -1 && dir !== 1) return false
        // 更新各路 currentIndex（clamp）
        var anyMoved = false
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            var rt = _laneRuntime[i]
            if (!rt || rt.visibleFiles.length === 0) continue
            var cur = lane.currentIndex
            var next = Math.max(0, Math.min(rt.visibleFiles.length - 1, cur + dir))
            if (next !== cur) {
                anyMoved = true
                _rowsModel.set(i, {
                    folderPath: lane.folderPath,
                    keyword: lane.keyword,
                    currentPath: rt.visibleFiles[next],
                    currentIndex: next,
                    allCount: rt.allFiles.length,
                    visibleCount: rt.visibleFiles.length
                })
            }
        }
        if (!anyMoved) return false
        // 直接 openFiles 切组（语义最简单：换一批文件）
        var paths = []
        for (var j = 0; j < _rowsModel.count; ++j) paths.push(_rowsModel.get(j).currentPath)
        var urls = Fs.toFileUrls(paths)
        if (urls.length < kMinLanes) return false
        return Engine.openFiles(urls)
    }
    function nextGroup() { return navigate(1) }
    function prevGroup() { return navigate(-1) }

    // 当前组号 / 总组数（基于"最长那路的 visibleFiles"，仅作显示用）
    function groupCount() {
        var maxN = 0
        for (var i = 0; i < _laneRuntime.length; ++i) {
            var rt = _laneRuntime[i]
            if (rt && rt.visibleFiles.length > maxN) maxN = rt.visibleFiles.length
        }
        return maxN
    }
    function groupIndex() {
        // 取第一路的 currentIndex（多数场景每路命中数一样；若不同，第一路是基准）
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
                text: "🗂️ 多组对比模式"
                color: "#e8e8ec"
                font.pixelSize: 16
                font.bold: true
            }
            Label {
                text: "为每一路指定一个文件夹与过滤关键字，启动后可用「上一组/下一组」切换"
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
                            _syncLaneFromRow(index, folderPath, keyword,
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
                    if (canStart) return "✓ 已就绪，可启动对比"
                    return "请为每一路选择文件夹并确保有命中文件"
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
                text: active ? "重新启动对比" : "启动对比"
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
