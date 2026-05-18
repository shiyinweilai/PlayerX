/**
 * RatingsDialog.qml — 视频评分数据查看 / 导出 / 清空
 *
 * 数据来源：C++ 单例 `Rating`（rbqt::RatingStore），CSV 持久化在
 *   AppDataLocation/PlayerX/ratings.csv
 *
 * 设计风格：与项目其他面板一致——深色底（#1e1e22）、亮白字、极简、排版优先。
 *
 * 关键交互：
 *   - 顶部：评分人输入框（写入 QSettings，立即生效；新评分都会带上这个名字）
 *           数据文件路径只读显示 + 在 Finder/资源管理器中显示
 *   - 中部：表格（时间 / 评分人 / 星数 / 文件名）
 *     · 文件名一列展示带通道号前缀的形式（如 "1_xxx.mp4"），
 *       鼠标悬停时通过 ToolTip 显示该文件的完整绝对路径；
 *     · 不再单独保留"文件路径"列——多人汇总评分时路径属于环境噪音；
 *     · 导出 CSV 也只保留 updated_at / rater / file_name / stars 四列，
 *       updated_at 会格式化成 "yyyy-MM-dd HH:mm:ss" 方便人眼对齐。
 *   - 底部：导出 CSV（保存对话框）/ 清空（二次确认）/ 关闭
 */
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window

Window {
    id: root
    title: qsTr("评分数据")
    width: 880
    height: 560
    minimumWidth: 640
    minimumHeight: 380
    flags: Qt.Dialog
    color: "#1a1a1d"
    modality: Qt.WindowModal

    // 当前用户名输入的临时缓冲（防止每按一键都触发 setCurrentUser）
    property string _userBuffer: ""

    // ── 必填项校验：触发拒绝弹窗时，对应输入框红框闪烁 1.6s ──
    property bool _invalidUser: false
    property bool _invalidTag:  false
    Timer {
        id: _invalidResetTimer
        interval: 1600
        onTriggered: { root._invalidUser = false; root._invalidTag = false }
    }
    // 统一入口：弹"拒绝上传"模态 + 红框高亮 + 抢焦点
    function _rejectUpload(reason, focusTarget, kind) {
        if (kind === "user") root._invalidUser = true
        else if (kind === "tag") root._invalidTag = true
        _invalidResetTimer.restart()
        rejectDialog.openWith(qsTr("无法上传到云端"), reason)
        if (focusTarget) focusTarget.forceActiveFocus()
    }

    // 表格数据：弹窗每次打开 / Rating.changed 时刷新
    property var _rows: []
    // 时间列排序方向：true = 新→旧（默认，与 C++ 端 getAllRatings 一致），false = 旧→新
    property bool _sortDesc: true
    // 当前评分模式的星级上限（决定“有效评分”区间与子项星条渲染长度）。
    // off 模式下Rating.maxStars==0，本处兜底 5。
    readonly property int _maxStars:
        (typeof Rating !== "undefined" && Rating.maxStars > 0) ? Rating.maxStars : 5

    // ── 分组（VSCode 风格三层树：文件夹 → 文件 → 评分记录）─────────
    // _folders: [{ key:'dir:<dir>', name, path, files:[file...], latest, avg, totalItems }]
    //   file:    { key:'file:<file_path>', name, path, items:[row...], latest, avg }
    // _expanded: { key -> bool }，文件夹与文件用不同前缀互不冲突；刷新不丢失
    // _visibleRows: 当前 ListView 实际渲染的行数组，元素形态为：
    //   { kind:'folder', d:<folder> }
    //   { kind:'file',   d:<folder>, g:<file> }
    //   { kind:'item',   d:<folder>, g:<file>, r:<row> }
    property var _folders: []
    property var _expanded: ({})
    property var _visibleRows: []

    // 上传勾选：key = folder.key（如 "dir:/Users/x/a"），value = bool。
    // 默认全选；新增文件夹自动补 true，已删除的文件夹自动清理，避免脏 key 残留。
    // 仅用于"按文件夹勾选上传"功能，不影响导出 / 渲染。
    property var _checkedFolders: ({})

    // 上次发起上传时所携带的文件夹白名单。
    // 设置框"保存并上传"、覆盖确认"覆盖上传"都会复用它，
    // 避免“点上传 → 弹设置 → 保存”过程中把白名单丢了变成全量上传。
    property var _lastUploadFolders: []

    // 从 file_path 中提取所属目录（兼容 / 与 \）
    function _dirOf(fp) {
        if (!fp || fp.length === 0) return ""
        var p = String(fp)
        var i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
        return i > 0 ? p.substring(0, i) : ""
    }
    function _baseName(p) {
        if (!p || p.length === 0) return ""
        var s = String(p)
        var i = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"))
        return i >= 0 ? s.substring(i + 1) : s
    }
    // 仅用于「按文件夹分组」展示：剥掉 file_name 头部的「<通道号>_」前缀。
    // RatingStore 写库时会把 file_name 拼成 "<idx+1>_<原文件名>"（见 RatingStore.cpp 的多路宏格设计），
    // 但同一文件夹下所有文件来自同一通道，前缀此时是冗余视觉噪音；这里只剥树形展示用的副本，
    // 库里的原始 file_name、CSV 导出列均保持不变（保留可追溯性 / 跨组对齐能力）。
    function _stripChannelPrefix(name) {
        if (!name) return ""
        var s = String(name)
        // 仅匹配「数字 + 下划线」开头，最多 2 位（覆盖 1~99 路），避免误伤真实文件名
        var m = s.match(/^(\d{1,2})_(.+)$/)
        return m ? m[2] : s
    }

    // 按 _sortDesc 排 updated_at 字段；在 JS 里用字符串比较即可（ISO8601 字典序==时间序）。
    function _applySort(rows) {
        var arr = (rows || []).slice()  // 拷贝，避免就地改 C++ 返回的 list
        arr.sort(function(a, b) {
            var ta = a.updated_at || ""
            var tb = b.updated_at || ""
            if (ta === tb) return 0
            if (root._sortDesc) return ta < tb ? 1 : -1
            return ta < tb ? -1 : 1
        })
        return arr
    }
    // 把扁平 _rows 聚成三层树：文件夹 → 文件 → 评分记录。
    // _sortDesc 影响：
    //   · 同一文件下记录始终倒序（最新在前，便于一眼看到最近评分）
    //   · 文件之间、文件夹之间则按 _sortDesc 排（按各自组内最新时间）
    function _rebuildGroups() {
        var fileMap = {}
        var fileOrder = []
        // 第一轮：按 file_path 聚成「文件」组
        for (var i = 0; i < _rows.length; ++i) {
            var r = _rows[i]
            var fkey = r.file_path && r.file_path.length > 0
                       ? r.file_path
                       : ("name:" + (r.file_name || "(unknown)"))
            if (!fileMap[fkey]) {
                var rawName = r.file_name || _baseName(fkey)
                fileMap[fkey] = {
                    key: "file:" + fkey,
                    name: _stripChannelPrefix(rawName),  // 树形展示用的"干净名"
                    rawName: rawName,                     // 保留原始名（含通道前缀），Tooltip 可用
                    path: r.file_path || "",
                    items: [],
                    latest: "",
                    avg: 0
                }
                fileOrder.push(fkey)
            }
            fileMap[fkey].items.push(r)
        }
        // 文件内时间倒序 + 算文件汇总
        for (var k = 0; k < fileOrder.length; ++k) {
            var g = fileMap[fileOrder[k]]
            g.items.sort(function(a, b) {
                var ta = a.updated_at || "", tb = b.updated_at || ""
                if (ta === tb) return 0
                return ta < tb ? 1 : -1
            })
            g.latest = g.items.length > 0 ? (g.items[0].updated_at || "") : ""
            var sum = 0, cnt = 0
            for (var j = 0; j < g.items.length; ++j) {
                var s = parseInt(g.items[j].stars) || 0
                // 超出当前模式上限的钉到 maxStars（防御旧数据/手改误值）
                if (s >= 1) {
                    if (s > root._maxStars) s = root._maxStars
                    sum += s
                    ++cnt
                }
            }
            g.avg = cnt > 0 ? Math.round(sum / cnt * 10) / 10 : 0
        }
        // 第二轮：把「文件」按所在目录聚成「文件夹」
        var dirMap = {}
        var dirOrder = []
        for (var m = 0; m < fileOrder.length; ++m) {
            var f = fileMap[fileOrder[m]]
            var dir = _dirOf(f.path)
            var dkey = dir.length > 0 ? dir : "(未知文件夹)"
            if (!dirMap[dkey]) {
                dirMap[dkey] = {
                    key: "dir:" + dkey,
                    name: dir.length > 0 ? _baseName(dir) : qsTr("(未知文件夹)"),
                    path: dir,
                    files: [],
                    latest: "",
                    avg: 0,
                    totalItems: 0
                }
                dirOrder.push(dkey)
            }
            dirMap[dkey].files.push(f)
        }
        // 文件夹内文件按 _sortDesc 排，并算汇总指标
        var folders = []
        for (var n = 0; n < dirOrder.length; ++n) {
            var d = dirMap[dirOrder[n]]
            d.files.sort(function(a, b) {
                var ta = a.latest || "", tb = b.latest || ""
                if (ta === tb) return 0
                if (root._sortDesc) return ta < tb ? 1 : -1
                return ta < tb ? -1 : 1
            })
            // 汇总：合并文件夹下所有 items 来算平均分与最新时间
            var dSum = 0, dCnt = 0, dLatest = "", total = 0
            for (var p = 0; p < d.files.length; ++p) {
                var fg = d.files[p]
                total += fg.items.length
                if ((fg.latest || "") > dLatest) dLatest = fg.latest || ""
                for (var q = 0; q < fg.items.length; ++q) {
                    var sc = parseInt(fg.items[q].stars) || 0
                    if (sc >= 1) {
                        if (sc > root._maxStars) sc = root._maxStars
                        dSum += sc
                        ++dCnt
                    }
                }
            }
            d.totalItems = total
            d.latest = dLatest
            d.avg = dCnt > 0 ? Math.round(dSum / dCnt * 10) / 10 : 0
            // ── 进度统计：用于汇总文案 + 上传前校验 ──────────────────
            // ratedCount: 该文件夹下"已被评过分（至少 1 次）"的不同视频数 = 已聚合的文件条目数。
            // totalVideos: 该文件夹下视频文件总数（递归，扩展名口径与播放器一致），
            //              通过 Reference.videoCountInFolder() 实时枚举文件系统得到。
            //              当 path 为空（"(未知文件夹)" 兜底）或后端不可用时回退为 ratedCount，
            //              此时 fullyRated 必然为 true，不会误拦上传。
            d.ratedCount = d.files.length
            var tot = d.ratedCount
            if (d.path && d.path.length > 0 && typeof Reference !== "undefined"
                    && typeof Reference.videoCountInFolder === "function") {
                var n2 = Reference.videoCountInFolder(d.path)
                // 若枚举到的总数比已评数还小（极端情况：文件被移走 / 路径变更），
                // 至少要把"已评"也算进去，避免出现 1/0 这种诡异显示。
                if (n2 > tot) tot = n2
            }
            d.totalVideos = tot
            d.fullyRated = (d.totalVideos > 0) && (d.ratedCount >= d.totalVideos)
            folders.push(d)
        }
        // 文件夹之间按 _sortDesc 排（按文件夹内最新时间）
        folders.sort(function(a, b) {
            var ta = a.latest || "", tb = b.latest || ""
            if (ta === tb) return 0
            if (root._sortDesc) return ta < tb ? 1 : -1
            return ta < tb ? -1 : 1
        })
        _folders = folders

        // ── 同步 _checkedFolders：保留旧勾选，新增的文件夹默认勾上，已消失的清掉
        var nextChecked = {}
        for (var ci = 0; ci < folders.length; ++ci) {
            var ck = folders[ci].key
            // 没显式置 false 的都视作勾上（默认全选 + 保留用户手动勾上的）
            nextChecked[ck] = (root._checkedFolders[ck] === false) ? false : true
        }
        _checkedFolders = nextChecked

        _rebuildVisibleRows()
    }
    // 根据当前展开状态，把 _folders 展平为 ListView 数据源
    function _rebuildVisibleRows() {
        var out = []
        for (var i = 0; i < _folders.length; ++i) {
            var d = _folders[i]
            out.push({ kind: "folder", d: d })
            if (!_expanded[d.key]) continue
            for (var j = 0; j < d.files.length; ++j) {
                var g = d.files[j]
                out.push({ kind: "file", d: d, g: g })
                if (!_expanded[g.key]) continue
                for (var k = 0; k < g.items.length; ++k) {
                    out.push({ kind: "item", d: d, g: g, r: g.items[k] })
                }
            }
        }
        _visibleRows = out
    }
    function _toggleKey(key) {
        var ex = {}
        for (var k in _expanded) ex[k] = _expanded[k]
        ex[key] = !ex[key]
        _expanded = ex
        _rebuildVisibleRows()
    }
    function _expandAll(flag) {
        var ex = {}
        for (var i = 0; i < _folders.length; ++i) {
            var d = _folders[i]
            ex[d.key] = !!flag
            for (var j = 0; j < d.files.length; ++j) {
                ex[d.files[j].key] = !!flag
            }
        }
        _expanded = ex
        _rebuildVisibleRows()
    }
    // 累计文件总数（统计行用）
    function _totalFileCount() {
        var n = 0
        for (var i = 0; i < _folders.length; ++i) n += _folders[i].files.length
        return n
    }
    // ── 勾选相关 ─────────────────────────────────────────────────────
    function _isFolderChecked(key) {
        // 缺省视为已勾（默认全选）
        return _checkedFolders[key] !== false
    }
    function _toggleFolderChecked(key) {
        var c = {}
        for (var k in _checkedFolders) c[k] = _checkedFolders[k]
        c[key] = !_isFolderChecked(key)
        _checkedFolders = c
    }
    function _setAllFoldersChecked(flag) {
        var c = {}
        for (var i = 0; i < _folders.length; ++i) c[_folders[i].key] = !!flag
        _checkedFolders = c
    }
    function _invertFolderChecked() {
        var c = {}
        for (var i = 0; i < _folders.length; ++i) {
            var k = _folders[i].key
            c[k] = !_isFolderChecked(k)
        }
        _checkedFolders = c
    }
    function _checkedFolderCount() {
        var n = 0
        for (var i = 0; i < _folders.length; ++i) {
            if (_isFolderChecked(_folders[i].key)) ++n
        }
        return n
    }
    // 收集已勾选文件夹的绝对路径，传给 Rating.uploadToCloud(folderPaths)
    function _collectCheckedFolderPaths() {
        var out = []
        for (var i = 0; i < _folders.length; ++i) {
            var d = _folders[i]
            if (_isFolderChecked(d.key) && d.path && d.path.length > 0) {
                out.push(d.path)
            }
        }
        return out
    }
    // 收集已勾选、但还未评完的文件夹（用于上传前拦截）。
    // 返回元素：{ name, path, ratedCount, totalVideos }
    // 设计原则：不评完不让上传 → 避免云端出现"半成品"打分集合污染统计。
    function _collectCheckedIncomplete() {
        var out = []
        for (var i = 0; i < _folders.length; ++i) {
            var d = _folders[i]
            if (!_isFolderChecked(d.key)) continue
            // path 为空（"(未知文件夹)" 兜底）的不参与校验：它本来也不会上传
            if (!d.path || d.path.length === 0) continue
            var rated = (d.ratedCount === undefined ? d.files.length : d.ratedCount)
            var total = (d.totalVideos === undefined ? rated : d.totalVideos)
            if (total > 0 && rated < total) {
                out.push({
                    name: d.name,
                    path: d.path,
                    ratedCount: rated,
                    totalVideos: total
                })
            }
        }
        return out
    }
    function _refresh() {
        var raw = (typeof Rating !== "undefined") ? Rating.getAllRatings() : []
        _rows = _applySort(raw)
        _rebuildGroups()
    }
    function _toggleTimeSort() {
        _sortDesc = !_sortDesc
        _rows = _applySort(_rows)
        _rebuildGroups()
    }
    function open() { show() }

    onVisibleChanged: {
        if (visible) {
            _userBuffer = (typeof Rating !== "undefined") ? Rating.currentUser : ""
            _refresh()
        }
    }

    Connections {
        target: (typeof Rating !== "undefined") ? Rating : null
        ignoreUnknownSignals: true
        function onChanged() { root._refresh() }
        // 模式切换：重读该模式下的数据 + 重建表格（_refresh 内部会调 _rebuildGroups）
        function onCurrentModeChanged() { root._refresh() }
    }

    // ── 总体布局：上(配置区) / 中(表格) / 下(操作栏) ────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        // ── 标题 + 模式切换 ────
        // 设计动机：评分数据按“AIGC评分 / 传统主观评分”独立存储，应该让用户一眼看到当前正在看哪一份。
        // 这里用“胶囊 Tab”式切换器：默认从 Rating.modeList 动态生成，未来加新模式不需动 QML。
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Text {
                text: "📊  " + qsTr("视频评分数据")
                color: "#e8e8ec"
                font.pixelSize: 16
                font.bold: true
            }
            Item { Layout.fillWidth: true }
            // 模式切换器：Repeater 生成一组互斥胶囊开关
            Row {
                spacing: 6
                Repeater {
                    model: (typeof Rating !== "undefined") ? Rating.modeList : []
                    delegate: Rectangle {
                        property var modeData: modelData
                        property bool selected: (typeof Rating !== "undefined") && Rating.currentMode === modeData.id
                        radius: 14
                        height: 26
                        // 实际宽度由内容决定（使用 implicit）
                        implicitWidth: modeLabel.implicitWidth + 22
                        color: selected ? "#0fa085"
                              : modeMA.containsMouse ? "#2c2c34"
                                                     : "#222226"
                        border.color: selected ? "#0fa085" : "#3a3a42"
                        border.width: 1
                        Row {
                            anchors.centerIn: parent
                            spacing: 6
                            Text {
                                id: modeLabel
                                text: modeData.label + "  ·  " + modeData.maxStars + "星"
                                color: selected ? "#ffffff" : "#cfcfd4"
                                font.pixelSize: 12
                                font.bold: selected
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        MouseArea {
                            id: modeMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (typeof Rating !== "undefined" && Rating.currentMode !== modeData.id) {
                                    Rating.currentMode = modeData.id
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── 评分人 / 数据文件路径 ────
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 10
            rowSpacing: 6

            Text {
                textFormat: Text.RichText
                text: qsTr("评分人") + " <font color=\"#f5222d\">*</font>"
                color: "#9aa0a6"; font.pixelSize: 12
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: userField
                    Layout.preferredWidth: 200
                    Layout.fillWidth: true
                    text: root._userBuffer
                    placeholderText: (typeof Rating !== "undefined")
                                     ? qsTr("未设置（默认使用系统用户名：%1）").arg(Rating.systemUserName())
                                     : ""
                    color: "#e8e8ec"
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        // 无效高亮（红）优先于聚焦色（蓝）
                        border.color: root._invalidUser ? "#f5222d"
                                    : userField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: root._invalidUser ? 2 : 1
                        radius: 4
                        Behavior on border.color { ColorAnimation { duration: 160 } }
                    }
                    onEditingFinished: {
                        if (typeof Rating !== "undefined") {
                            Rating.currentUser = text.trim()
                        }
                    }
                    onTextChanged: {
                        // 用户开始输入即清掉无效态，避免一直闪红
                        if (root._invalidUser && text.trim().length > 0) root._invalidUser = false
                    }
                }
                // 备注 tag：同一评分人多轮提交时的区分标签。
                // 后端会按 (rater, tag) 检测重复上传，重复时弹“是否覆盖”。
                Text {
                    textFormat: Text.RichText
                    text: qsTr("备注 tag") + " <font color=\"#f5222d\">*</font>"
                    color: "#9aa0a6"
                    font.pixelSize: 12
                }
                TextField {
                    id: tagField
                    Layout.preferredWidth: 160
                    text: (typeof Rating !== "undefined") ? Rating.uploadTag : ""
                    placeholderText: qsTr("例如 test1 / 终评")
                    color: "#e8e8ec"
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        border.color: root._invalidTag ? "#f5222d"
                                    : tagField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: root._invalidTag ? 2 : 1
                        radius: 4
                        Behavior on border.color { ColorAnimation { duration: 160 } }
                    }
                    // 实时同步：每次键入都立刻写回 Rating.uploadTag，
                    // 避免“改完 tag 直接点上传按钮，但首次点击还在用旧值”的时序问题
                    // （旧逻辑只在 editingFinished 即失焦/回车时才同步）。
                    onTextChanged: {
                        if (typeof Rating !== "undefined"
                                && Rating.uploadTag !== text.trim()) {
                            Rating.uploadTag = text.trim()
                        }
                        // 用户开始输入即清掉无效态
                        if (root._invalidTag && text.trim().length > 0) root._invalidTag = false
                    }
                }
                Text {
                    text: qsTr("回车保存")
                    color: "#6a6a72"
                    font.pixelSize: 11
                }
            }

            Text { text: qsTr("数据文件"); color: "#9aa0a6"; font.pixelSize: 12 }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    Layout.fillWidth: true
                    readOnly: true
                    text: (typeof Rating !== "undefined") ? Rating.dataFilePath : ""
                    color: "#c8c8cc"
                    selectByMouse: true
                    // 文件名/路径过长时让左侧显示省略，确保末尾的 ratings.csv 可见
                    horizontalAlignment: TextInput.AlignRight
                    background: Rectangle {
                        color: "#222226"
                        border.color: "#2e2e34"
                        border.width: 1
                        radius: 4
                    }
                }
                PillBtn {
                    text: qsTr("在文件夹中显示")
                    onClicked: { if (typeof Rating !== "undefined") Rating.revealInFolder() }
                }
            }
        }

        // ── 分隔线 ──
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#2e2e34" }

        // ── 统计行 ──
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Text {
                text: qsTr("共 %1 个文件夹 · %2 个文件 · %3 条记录 · 已勾选 %4/%1 个文件夹")
                        .arg(root._folders.length)
                        .arg(root._totalFileCount())
                        .arg(root._rows.length)
                        .arg(root._checkedFolderCount())
                color: "#c8c8cc"
                font.pixelSize: 12
            }
            Item { Layout.fillWidth: true }
            PillBtn {
                text: qsTr("全选")
                enabled: root._folders.length > 0
                onClicked: root._setAllFoldersChecked(true)
            }
            PillBtn {
                text: qsTr("反选")
                enabled: root._folders.length > 0
                onClicked: root._invertFolderChecked()
            }
            PillBtn {
                text: qsTr("全部展开")
                onClicked: root._expandAll(true)
            }
            PillBtn {
                text: qsTr("全部折叠")
                onClicked: root._expandAll(false)
            }
            PillBtn {
                text: qsTr("刷新")
                onClicked: root._refresh()
            }
        }

        // ── 表格区 ──
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#222226"
            border.color: "#2e2e34"
            border.width: 1
            radius: 4

            // 表头：树形视图共两列——文件 / 最新评分时间（可排序）
            Row {
                id: header
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 1
                height: 28
                spacing: 0
                // 文件列（占主要宽度，不含右侧两个固定列）
                Rectangle {
                    width: header.width - 220 - 90
                    height: 28
                    color: "#2a2a30"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        text: qsTr("文件 / 评分记录")
                        color: "#dcdcde"
                        font.pixelSize: 12
                        font.bold: true
                    }
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: "#1e1e22" }
                }
                // 最新时间（可排序）
                Rectangle {
                    id: hTime
                    width: 220
                    height: 28
                    color: hTimeMA.pressed ? "#34343c"
                          : hTimeMA.containsMouse ? "#30303a"
                                                  : "#2a2a30"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        text: qsTr("最新评分时间") + "  " + (root._sortDesc ? "▼" : "▲")
                        color: "#ffffff"
                        font.pixelSize: 12
                        font.bold: true
                    }
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: "#1e1e22" }
                    MouseArea {
                        id: hTimeMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._toggleTimeSort()
                    }
                }
                // 汇总（次数 · 平均分）
                Rectangle {
                    width: 90
                    height: 28
                    color: "#2a2a30"
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        text: qsTr("汇总")
                        color: "#dcdcde"
                        font.pixelSize: 12
                        font.bold: true
                    }
                }
            }

            // 数据行（树形 ListView，单一 ListView 同时渲染分组行与子行）
            ListView {
                id: listView
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: header.bottom
                anchors.bottom: parent.bottom
                anchors.margins: 1
                clip: true
                model: root._visibleRows
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Loader {
                    id: rowLoader
                    width: listView.width
                    sourceComponent: modelData.kind === "folder" ? folderRowComp
                                   : modelData.kind === "file"   ? fileRowComp
                                                                  : itemRowComp
                    // 把当前行数据与索引推送给 sourceComponent 实例；
                    // Component 内部通过 parent.rowData / parent.rowIndex 读取。
                    property var rowData: modelData
                    property int rowIndex: index
                }

                // 空状态
                Text {
                    anchors.centerIn: parent
                    visible: root._rows.length === 0
                    text: qsTr("暂无评分数据\n在视频窗的 ⋯ 菜单中选择星级即可记录")
                    horizontalAlignment: Text.AlignHCenter
                    color: "#6a6a72"
                    font.pixelSize: 12
                }
            }

            // ── 一级：文件夹行（可点击展开/折叠该文件夹下所有文件）─────
            Component {
                id: folderRowComp
                Rectangle {
                    id: folderRoot
                    height: 32
                    width: parent ? parent.width : 0
                    color: folderMA.containsMouse ? "#2c2c34" : "#26262e"
                    Behavior on color { ColorAnimation { duration: 120 } }

                    // parent 是 Loader，从上面拿 rowData
                    property var d: parent.rowData ? parent.rowData.d : null
                    property bool open: d ? !!root._expanded[d.key] : false

                    // 左侧 4px 强调条，强化第一层级感
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 3
                        color: "#3a7afe"
                    }

                    // 文件列
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width - 220 - 90
                        color: "transparent"
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            spacing: 6
                            // 上传勾选：自绘深色方框，独立 MouseArea 吞掉事件，
                            // 避免被外层 folderMA 截走变成展开/折叠。
                            Item {
                                id: folderCheck
                                z: 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: 18; height: 18
                                property bool checked: folderRoot.d ? root._isFolderChecked(folderRoot.d.key) : false
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 4
                                    color: folderCheck.checked ? "#3a7afe"
                                                               : (folderCheckMA.containsMouse ? "#3a3a44" : "#2a2a32")
                                    border.width: 1
                                    border.color: folderCheck.checked ? "#3a7afe"
                                                                      : (folderCheckMA.containsMouse ? "#5a5a66" : "#4a4a54")
                                    Behavior on color       { ColorAnimation { duration: 100 } }
                                    Behavior on border.color { ColorAnimation { duration: 100 } }
                                    Text {
                                        anchors.centerIn: parent
                                        text: "✓"
                                        color: "#ffffff"
                                        font.pixelSize: 13
                                        font.bold: true
                                        visible: folderCheck.checked
                                    }
                                }
                                MouseArea {
                                    id: folderCheckMA
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton
                                    propagateComposedEvents: false
                                    onPressed: function(mouse) { mouse.accepted = true }
                                    onClicked: function(mouse) {
                                        mouse.accepted = true
                                        if (folderRoot.d) root._toggleFolderChecked(folderRoot.d.key)
                                    }
                                    ToolTip.visible: containsMouse
                                    ToolTip.delay: 600
                                    ToolTip.text: folderCheck.checked ? qsTr("已勾选：将参与上传")
                                                                      : qsTr("未勾选：上传时跳过该文件夹")
                                }
                            }
                            Text {
                                width: 14
                                horizontalAlignment: Text.AlignHCenter
                                text: folderRoot.open ? "▾" : "▸"
                                color: "#cfcfd4"
                                font.pixelSize: 13
                            }
                            Text {
                                text: folderRoot.open ? "📂" : "📁"
                                font.pixelSize: 13
                            }
                            Text {
                                text: folderRoot.d ? folderRoot.d.name : ""
                                color: "#ffffff"
                                font.pixelSize: 13
                                font.bold: true
                                elide: Text.ElideMiddle
                                width: Math.max(0, parent.width - 18 - 6 - 14 - 6 - 16 - 6)
                            }
                        }
                    }
                    // 最新时间
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: parent.width - 220 - 90 + 8
                        width: 220 - 16
                        text: folderRoot.d
                              ? (folderRoot.d.latest || "").replace("T", " ").substring(0, 19)
                              : ""
                        color: "#dcdcde"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    // 汇总：已评 X/Y · N 条 · 平均 4.2★
                    // 设计：把"已评分视频数 / 该文件夹视频总数"放在最前面（用户最关心进度），
                    //       未评完时用橙红色 + ⚠ 强提醒；评满后用绿色 ✓。
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: parent.width - 90 + 8
                        width: 90 - 16
                        text: {
                            if (!folderRoot.d) return ""
                            var d = folderRoot.d
                            var rated = (d.ratedCount === undefined ? d.files.length : d.ratedCount)
                            var total = (d.totalVideos === undefined ? rated : d.totalVideos)
                            var head = (d.fullyRated ? "✓ " : "⚠ ") + rated + "/" + total
                            var tail = " · " + d.totalItems + "条"
                                + (d.avg > 0 ? " · " + d.avg + "★" : "")
                            return head + tail
                        }
                        color: folderRoot.d
                                ? (folderRoot.d.fullyRated
                                    ? (folderRoot.d.avg > 0 ? "#f5c518" : "#5fd17a")
                                    : "#ffb05c")
                                : "#cfcfd4"
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        // 鼠标悬浮看完整解释（按列宽收窄时被 elide 截断）
                        ToolTip.visible: _sumMA.containsMouse && folderRoot.d !== null
                        ToolTip.delay: 600
                        ToolTip.timeout: 8000
                        ToolTip.text: folderRoot.d
                                ? qsTr("已评分视频：%1 / %2\n评分记录：%3 条\n平均：%4")
                                    .arg(folderRoot.d.ratedCount === undefined
                                            ? folderRoot.d.files.length
                                            : folderRoot.d.ratedCount)
                                    .arg(folderRoot.d.totalVideos === undefined
                                            ? folderRoot.d.files.length
                                            : folderRoot.d.totalVideos)
                                    .arg(folderRoot.d.totalItems)
                                    .arg(folderRoot.d.avg > 0 ? folderRoot.d.avg + " ★" : "—")
                                : ""
                        MouseArea {
                            id: _sumMA
                            anchors.fill: parent
                            hoverEnabled: true
                            // 不要吃点击：让父容器 folderMA 继续负责展开/收起
                            acceptedButtons: Qt.NoButton
                        }
                    }

                    // 底部分隔线
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: "#1e1e22"
                    }

                    MouseArea {
                        id: folderMA
                        // 让出最左侧 checkbox 区域（8 边距 + 18 方框 + 6 间距 = 32），
                        // 否则 fill: parent 会覆盖到 checkbox 上吃掉点击事件，导致点勾选变展开。
                        anchors.left: parent.left
                        anchors.leftMargin: 32
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        z: 0
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        ToolTip.visible: containsMouse && folderRoot.d && folderRoot.d.path.length > 0
                        ToolTip.delay: 600
                        ToolTip.timeout: 8000
                        ToolTip.text: folderRoot.d ? folderRoot.d.path : ""
                        onClicked: { if (folderRoot.d) root._toggleKey(folderRoot.d.key) }
                    }
                }
            }

            // ── 二级：文件行（可点击展开该文件下所有评分记录）──────────
            Component {
                id: fileRowComp
                Rectangle {
                    id: fileRoot
                    height: 28
                    width: parent ? parent.width : 0
                    color: fileMA.containsMouse ? "#2c2c34" : "#23232a"
                    Behavior on color { ColorAnimation { duration: 120 } }

                    property var g: parent.rowData ? parent.rowData.g : null
                    property bool open: g ? !!root._expanded[g.key] : false

                    // 文件列
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width - 220 - 90
                        color: "transparent"
                        // 左侧缩进区竖线，对应文件夹层级
                        Rectangle {
                            x: 12
                            width: 1
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            color: "#2e2e34"
                        }
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 22
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            spacing: 6
                            Text {
                                width: 14
                                horizontalAlignment: Text.AlignHCenter
                                text: fileRoot.open ? "▾" : "▸"
                                color: "#9aa0a6"
                                font.pixelSize: 12
                            }
                            Text {
                                text: "🎬"
                                font.pixelSize: 12
                            }
                            Text {
                                text: fileRoot.g ? fileRoot.g.name : ""
                                color: "#f0f0f3"
                                font.pixelSize: 12
                                font.bold: true
                                elide: Text.ElideMiddle
                                width: Math.max(0, parent.width - 22 - 14 - 6 - 12 - 6)
                            }
                        }
                    }
                    // 最新时间
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: parent.width - 220 - 90 + 8
                        width: 220 - 16
                        text: fileRoot.g
                              ? (fileRoot.g.latest || "").replace("T", " ").substring(0, 19)
                              : ""
                        color: "#c8c8cc"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    // 汇总：N 条 · 平均 4.2★
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: parent.width - 90 + 8
                        width: 90 - 16
                        text: fileRoot.g
                              ? (fileRoot.g.items.length + "条"
                                  + (fileRoot.g.avg > 0 ? " · " + fileRoot.g.avg + "★" : ""))
                              : ""
                        color: fileRoot.g && fileRoot.g.avg > 0 ? "#f5c518" : "#9aa0a6"
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: "#1e1e22"
                    }

                    MouseArea {
                        id: fileMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        ToolTip.visible: containsMouse && fileRoot.g
                                          && (fileRoot.g.path.length > 0
                                              || fileRoot.g.rawName !== fileRoot.g.name)
                        ToolTip.delay: 600
                        ToolTip.timeout: 8000
                        // 剥过前缀的话，把原始名也显示出来，避免歧义
                        ToolTip.text: fileRoot.g
                                      ? ((fileRoot.g.rawName && fileRoot.g.rawName !== fileRoot.g.name
                                          ? fileRoot.g.rawName + "\n" : "")
                                         + (fileRoot.g.path || ""))
                                      : ""
                        onClicked: { if (fileRoot.g) root._toggleKey(fileRoot.g.key) }
                    }
                }
            }

            // ── 三级：评分记录行（最深层级）─────────────────────
            Component {
                id: itemRowComp
                Rectangle {
                    id: itemRoot
                    height: 26
                    width: parent ? parent.width : 0
                    // parent 是 Loader，从上面拿 rowData / rowIndex
                    property var r: parent.rowData ? parent.rowData.r : null
                    property int rIndex: parent.rowIndex !== undefined ? parent.rowIndex : 0
                    color: itemMA.containsMouse
                          ? "#2a2a32"
                          : (rIndex % 2 === 0 ? "#1f1f24" : "#22222a")

                    // 子项缩进区（评分人 · 星数）
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width - 220 - 90
                        color: "transparent"
                        // 两条缩进竖线，对应文件夹/文件两层
                        Rectangle {
                            x: 12
                            width: 1
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            color: "#2e2e34"
                        }
                        Rectangle {
                            x: 28
                            width: 1
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            color: "#2e2e34"
                        }
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 44
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            spacing: 10
                            Text {
                                text: "👤 " + (itemRoot.r ? (itemRoot.r.rater || "") : "")
                                color: "#cfcfd4"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                width: 160
                            }
                            Text {
                                text: {
                                    if (!itemRoot.r) return ""
                                    var s = parseInt(itemRoot.r.stars) || 0
                                    if (s <= 0) return "—"
                                    var capN = root._maxStars
                                    if (s > capN) s = capN
                                    var out = ""
                                    for (var i = 0; i < s; ++i) out += "★"
                                    for (var j = s; j < capN; ++j) out += "☆"
                                    return out
                                }
                                color: itemRoot.r && (parseInt(itemRoot.r.stars) || 0) > 0
                                       ? "#f5c518" : "#666"
                                font.pixelSize: 12
                            }
                        }
                    }
                    // 时间
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: parent.width - 220 - 90 + 8
                        width: 220 - 16
                        text: itemRoot.r
                              ? (itemRoot.r.updated_at || "").replace("T", " ").substring(0, 19)
                              : ""
                        color: "#9aa0a6"
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    // 汇总列：子项不展示具体分数，留空保持对齐
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: parent.width - 90 + 8
                        width: 90 - 16
                        text: ""
                    }

                    MouseArea {
                        id: itemMA
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                        ToolTip.visible: containsMouse && itemRoot.r && (itemRoot.r.file_path || "").length > 0
                        ToolTip.delay: 600
                        ToolTip.timeout: 8000
                        ToolTip.text: itemRoot.r ? (itemRoot.r.file_path || "") : ""
                    }
                }
            }
        }

        // ── 底部操作栏 ────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            PillBtn {
                id: exportBtn
                text: qsTr("📤 导出 CSV…")
                emphasized: true
                onClicked: exportDialog.open()
                // 闪烁复位：flash=true 后 1.6s 自动关闭
                Timer {
                    id: exportFlashTimer
                    interval: 1600
                    onTriggered: exportBtn.flash = false
                }
            }
            PillBtn {
                // 上传到后端服务器：
                //   ・ 未配置地址时 → 先弹设置对话框让用户填 URL/Token
                //   ・ 配置后点击 → 直接走上传。上传中 disable，避免连点重复提交
                // 鼠标右键 → 进设置对话框，取不到菜单 API 只能用双击代替：双击也走设置
                id: uploadBtn
                text: (typeof Rating !== "undefined" && Rating.uploading)
                      ? qsTr("☁ 上传中…")
                      : qsTr("☁ 上传到云端")
                enabled: typeof Rating !== "undefined"
                         && !Rating.uploading
                         && root._rows.length > 0
                onClicked: {
                    if (typeof Rating === "undefined") return
                    // 防御性兜底：把焦点中的输入框（tag / 评分人）强制提交，
                    // 避免“刚改完 tag 直接点上传”时旧值仍在使用。
                    // 现 tagField 已做实时同步，但 userField 仍依赖 editingFinished，
                    // 触发一次 focus 切换可让两者都把当前值落地到 Rating。
                    if (userField.activeFocus) userField.focus = false
                    if (tagField.activeFocus)  tagField.focus  = false

                    // ── 上传前必填校验：评分人 + 备注 tag ───────────────────
                    // 评分人不能依赖 Rating.currentUser（它会用系统用户名兜底，
                    // 会把“未手动设置”误判为已填），所以只看输入框文本。
                    var raterText = userField.text.trim()
                    var tagText   = tagField.text.trim()
                    if (raterText.length === 0) {
                        // 升级：模态拒绝弹窗 + 输入框红框闪烁，避免右下角小 toast 被忽略
                        root._rejectUpload(
                            qsTr("「评分人」为必填项，未填写将无法识别上传来源。\n请在顶部「评分人 *」输入框填写后再点上传。"),
                            userField, "user")
                        return
                    }
                    if (tagText.length === 0) {
                        root._rejectUpload(
                            qsTr("「备注 tag」为必填项，用于在云端区分同一评分人的多次上传。\n请在顶部「备注 tag *」输入框填写后再点上传。"),
                            tagField, "tag")
                        return
                    }
                    // 校验通过：把评分人值落库（避免 onEditingFinished 还没触发）
                    if (Rating.currentUser !== raterText) {
                        Rating.currentUser = raterText
                    }

                    // ── 必须至少勾选一个文件夹再上传
                    var picked = root._collectCheckedFolderPaths()
                    if (picked.length === 0) {
                        rejectDialog.openWith(
                            qsTr("无法上传到云端"),
                            qsTr("还没有勾选任何文件夹，无法确定要上传哪些评分记录。\n请在列表里至少勾选一个文件夹后再点上传。"))
                        return
                    }

                    // ── 未评完拦截：勾选的文件夹必须每个都"已评分视频数 == 视频总数"
                    // 设计动机：云端汇总通常按"文件夹完整评分"维度做统计，
                    // 半成品上传会让别人无法判断该批数据是否可用。
                    var incomplete = root._collectCheckedIncomplete()
                    if (incomplete.length > 0) {
                        incompleteUploadDialog.openWith(incomplete)
                        return
                    }
                    // 缓存本次勾选，供"保存并上传"/"覆盖上传"等后续入口复用
                    root._lastUploadFolders = picked

                    if (!Rating.uploadServerUrl || Rating.uploadServerUrl.length === 0) {
                        uploadConfigDialog.open()
                    } else {
                        Rating.uploadToCloud(false, picked)
                    }
                }
                // 双击 → 重新配置地址/Token
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton  // 不抢单击，只接双击
                    onDoubleClicked: uploadConfigDialog.open()
                }
                // 闪烁复位定时器
                Timer {
                    id: uploadFlashTimer
                    interval: 1600
                    onTriggered: uploadBtn.flash = false
                }
            }
            PillBtn {
                // “⚙ 设置”：独立入口，避免“双击上传按钮”这种隐藏交互被错过
                text: qsTr("⚙ 上传设置")
                onClicked: uploadConfigDialog.open()
            }
            PillBtn {
                // 行业惯例：批量操作必须显式勾选目标行才能执行（参考 Finder/资源管理器、邮箱客户端）
                // 这里只删除"已勾选文件夹"下的评分；未勾选时按钮直接禁用，避免误触。
                id: removeSelectedBtn
                // 把已勾选数量直接拼到按钮文案里，比 ToolTip 更直观（PillBtn 是 Rectangle，没有
                // 标准 hovered 属性，外部用 ToolTip on hovered 会报 ReferenceError）。
                text: {
                    var _dep = root._checkedFolders   // 让文案绑定跟随 _checkedFolders 变化
                    var _dep2 = root._folders
                    var n = root._checkedFolderCount()
                    return n > 0
                            ? qsTr("🗑 删除勾选（%1）").arg(n)
                            : qsTr("🗑 删除勾选")
                }
                danger: true
                // 必须有至少 1 个勾选项才能点；既防误触，也避免与"全部清空"语义混淆
                // 注：_checkedFolderCount() 是函数，需在表达式里显式引用 root._checkedFolders
                // 、root._folders 这两个 property，才会在勾选变化时重新求值。
                enabled: (root._checkedFolders, root._folders, root._checkedFolderCount() > 0)
                onClicked: confirmClearDialog.open()
            }
            Item { Layout.fillWidth: true }
            PillBtn {
                text: qsTr("关闭")
                onClicked: root.close()
            }
        }
    }

    // ── 导出对话框 ────
    FileDialog {
        id: exportDialog
        title: qsTr("导出评分数据为 CSV")
        fileMode: FileDialog.SaveFile
        nameFilters: ["CSV (*.csv)"]
        defaultSuffix: "csv"
        // 默认弹到系统"下载"目录（macOS: ~/Downloads，Windows: %USERPROFILE%\Downloads）。
        // 注意 Qt6 FileDialog 的坑：currentFile 若是绝对 URL（如 "file:///foo.csv"），
        // 会被解析成"根目录下 foo.csv"，进而**覆盖** currentFolder → 实际弹到 /。
        // 修法：把文件名直接拼到下载目录 URL 后面，组成完整路径 URL。
        currentFolder: (typeof Rating !== "undefined") ? Rating.defaultExportDir : ""
        currentFile: {
            var name = "PlayerX_ratings"
            var u = (typeof Rating !== "undefined") ? Rating.currentUser : ""
            if (u && u.length > 0) name += "_" + u
            // 时间戳 yyyyMMdd_HHmm
            var d = new Date()
            function pad(n) { return (n < 10 ? "0" : "") + n }
            name += "_" + d.getFullYear() + pad(d.getMonth()+1) + pad(d.getDate())
                  + "_" + pad(d.getHours()) + pad(d.getMinutes())
            // 拼接到下载目录 URL 后面，例如：file:///Users/xxx/Downloads/PlayerX_ratings_xxx.csv
            var dir = (typeof Rating !== "undefined") ? Rating.defaultExportDir.toString() : ""
            if (dir.length > 0) {
                if (dir.charAt(dir.length - 1) !== "/") dir += "/"
                return dir + name + ".csv"
            }
            return name + ".csv"  // 极端兜底：目录拿不到时只给文件名
        }
        onAccepted: {
            if (typeof Rating === "undefined") return
            // selectedFile 是 QUrl
            var path = selectedFile.toString().replace(/^file:\/\//, "")
            // Windows: file:///C:/foo → /C:/foo，去掉前导 /
            if (path.match(/^\/[A-Za-z]:/)) path = path.substring(1)
            var ok = Rating.exportToFile(path)
            if (ok) {
                // 成功：toast + 按钮闪绿
                var name = path.split(/[\\/]/).pop()
                actionToast.show(true, qsTr("已导出到 %1").arg(name))
                exportBtn.flash = true
                exportFlashTimer.restart()
            } else {
                actionToast.show(false, qsTr("导出失败：%1").arg(path))
            }
        }
    }

    // ── 清空确认对话框（深色主题，全自定义 header/footer，避免 Basic 主题白底）────
    // ── 上传被拒绝（强提示）：评分人/tag/勾选缺失时弹这个，红边 + 模态 ──
    // 比起右下角小 toast，强制要求用户点"知道了"，避免漏看导致以为已上传。
    Dialog {
        id: rejectDialog
        modal: true
        anchors.centerIn: parent
        width: 420
        padding: 0

        property string _title: ""
        property string _msg: ""
        function openWith(title, msg) {
            _title = title || qsTr("无法继续")
            _msg = msg || ""
            open()
        }

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#f5222d"      // 红边强调"被拒绝"
            border.width: 1
            radius: 8
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 8
                Text {
                    text: "⛔"
                    color: "#f5222d"
                    font.pixelSize: 16
                }
                Text {
                    Layout.fillWidth: true
                    text: rejectDialog._title
                    color: "#f0f0f3"
                    font.pixelSize: 14
                    font.bold: true
                    elide: Text.ElideRight
                }
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a30"
            }
        }

        contentItem: Item {
            implicitHeight: rejMsg.implicitHeight + 32
            Text {
                id: rejMsg
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: rejectDialog._msg
                color: "#cfcfd4"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }
        }

        footer: Rectangle {
            color: "transparent"
            implicitHeight: 56
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a30"
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 8
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("知道了")
                    onClicked: rejectDialog.close()
                }
            }
        }
    }

    Dialog {
        id: confirmClearDialog
        modal: true
        anchors.centerIn: parent
        width: 380
        padding: 0

        // 半透明遮罩，凸显前景
        Overlay.modal: Rectangle { color: "#aa000000" }

        // 弹窗主体：深色卡片 + 阴影
        background: Rectangle {
            color: "#1e1e22"
            border.color: "#2e2e34"
            border.width: 1
            radius: 8
            // 简易阴影：用一层放大的、半透明 Rectangle 模拟（Qt6 Basic 不带 DropShadow）
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        // 自定义标题栏
        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: qsTr("删除已勾选文件夹的评分？")
                color: "#f0f0f3"
                font.pixelSize: 14
                font.bold: true
                elide: Text.ElideRight
            }
            // 标题与正文分隔线
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a30"
            }
        }

        // 正文
        contentItem: Item {
            implicitHeight: _msg.implicitHeight + 32
            Text {
                id: _msg
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                // 把"将删除哪些文件夹/多少条记录"在弹窗里讲清楚，避免用户怀疑是"全清"
                // 用 (root._checkedFolders, root._folders, ...) 让表达式跟随两个 property 变化重算。
                text: {
                    var _dep = root._checkedFolders   // 让绑定依赖到 _checkedFolders
                    var _dep2 = root._folders         // 同上
                    var nFolders = root._checkedFolderCount()
                    // 评分条数：直接累加 d.totalItems（_rebuildGroups 里已预计算）
                    var nRecs = 0
                    for (var i = 0; i < root._folders.length; ++i) {
                        var d = root._folders[i]
                        if (root._isFolderChecked(d.key)) nRecs += (d.totalItems || 0)
                    }
                    return qsTr("将从本地 ratings.csv 删除已勾选的 %1 个文件夹下的全部评分（共 %2 条），\n操作不可恢复，是否继续？")
                            .arg(nFolders).arg(nRecs)
                }
                color: "#cfcfd4"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }
        }

        // 自定义底部按钮区（用 PillBtn，跟其他按钮风格一致）
        footer: Rectangle {
            color: "transparent"
            implicitHeight: 56
            // 顶部分隔线
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a30"
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 8
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("取消")
                    onClicked: confirmClearDialog.reject()
                }
                PillBtn {
                    text: qsTr("确认删除")
                    danger: true
                    onClicked: confirmClearDialog.accept()
                }
            }
        }

        onAccepted: {
            if (typeof Rating === "undefined") return
            var picked = root._collectCheckedFolderPaths()
            if (picked.length === 0) {
                rejectDialog.openWith(qsTr("无法删除"), qsTr("请先勾选至少 1 个文件夹"))
                return
            }
            var ok = Rating.removeByFolders(picked)
            if (ok) {
                actionToast.show(true, qsTr("已删除 %1 个文件夹的评分").arg(picked.length))
            } else {
                actionToast.show(false, qsTr("删除失败：未命中任何记录"))
            }
        }
    }

    // ── 上传设置对话框（服务器地址 / 可选 Token）────────────────────────────
    Dialog {
        id: uploadConfigDialog
        modal: true
        anchors.centerIn: parent
        width: 480
        padding: 0
        title: ""   // 自绘 header

        property string _urlBuf: ""
        property string _tokBuf: ""

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#2e2e34"
            border.width: 1
            radius: 8
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: Text.AlignVCenter
                text: qsTr("☁ 上传设置")
                color: "#f0f0f3"
                font.pixelSize: 14
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a30"
            }
        }

        contentItem: ColumnLayout {
            anchors.margins: 0
            spacing: 10

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 12
                text: qsTr("填入后端服务地址，点“保存并上传”后会将当前评分 CSV 推送过去。\n局域网示例：http://192.168.x.x:8765/upload")
                color: "#cfcfd4"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            GridLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                columns: 2
                columnSpacing: 10
                rowSpacing: 8

                Text { text: qsTr("服务地址"); color: "#9aa0a6"; font.pixelSize: 12 }
                TextField {
                    id: urlField
                    Layout.fillWidth: true
                    text: uploadConfigDialog._urlBuf
                    onTextChanged: uploadConfigDialog._urlBuf = text
                    placeholderText: "http://<host>:<port>/upload"
                    color: "#e8e8ec"
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        border.color: urlField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: 1
                        radius: 4
                    }
                }

                Text { text: qsTr("Token"); color: "#9aa0a6"; font.pixelSize: 12 }
                TextField {
                    id: tokField
                    Layout.fillWidth: true
                    text: uploadConfigDialog._tokBuf
                    onTextChanged: uploadConfigDialog._tokBuf = text
                    placeholderText: qsTr("可选；服务未启 PLAYERX_TOKEN 时留空即可")
                    color: "#e8e8ec"
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        border.color: tokField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: 1
                        radius: 4
                    }
                }
            }

            Item { Layout.preferredHeight: 4 }
        }

        footer: Rectangle {
            color: "transparent"
            implicitHeight: 56
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a30"
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 8
                PillBtn {
                    text: qsTr("仅保存")
                    onClicked: {
                        if (typeof Rating !== "undefined") {
                            Rating.uploadServerUrl = uploadConfigDialog._urlBuf.trim()
                            Rating.uploadToken     = uploadConfigDialog._tokBuf
                        }
                        uploadConfigDialog.close()
                    }
                }
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("取消")
                    onClicked: uploadConfigDialog.close()
                }
                PillBtn {
                    text: qsTr("保存并上传")
                    emphasized: true
                    enabled: uploadConfigDialog._urlBuf.trim().length > 0
                    onClicked: {
                        if (typeof Rating !== "undefined") {
                            Rating.uploadServerUrl = uploadConfigDialog._urlBuf.trim()
                            Rating.uploadToken     = uploadConfigDialog._tokBuf
                            // 复用主入口已记录的勾选；如果设置框是"未配置 URL → 直接打开"路径
                            // 进来的，_lastUploadFolders 已被填好
                            Rating.uploadToCloud(false, root._lastUploadFolders || [])
                        }
                        uploadConfigDialog.close()
                    }
                }
            }
        }

        // 打开时预填当前配置
        onOpened: {
            if (typeof Rating !== "undefined") {
                _urlBuf = Rating.uploadServerUrl || ""
                _tokBuf = Rating.uploadToken     || ""
            }
        }
    }

    // ── 通用操作反馈 Toast（导出成功 / 上传成功都走这里）───────────────
    // 锡在对话框右下角，加轻微上滑动画，~3.5s 后深出。
    Item {
        id: actionToast
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 18
        width: toastBg.width
        height: toastBg.height
        opacity: 0
        visible: opacity > 0.01
        transform: Translate { id: toastSlide; y: 12 }
        z: 1000

        property bool _ok: true
        property string _msg: ""

        function show(ok, msg) {
            _ok = ok
            _msg = msg
            // 重点击时重启动画与计时
            fadeOut.stop()
            slideIn.restart()
            fadeIn.restart()
            hideTimer.restart()
        }

        Rectangle {
            id: toastBg
            radius: 8
            color: "#1e1e22"
            border.color: actionToast._ok ? "#52c41a" : "#f5222d"
            border.width: 1
            implicitWidth: Math.min(420, Math.max(220, toastLabel.implicitWidth + 32))
            width: implicitWidth
            height: toastLabel.implicitHeight + 22
            // 轻微阴影，提高在深色背景上的漂浮感
            Rectangle {
                anchors.fill: parent
                anchors.margins: -4
                z: -1
                radius: parent.radius + 3
                color: "#80000000"
                opacity: 0.45
            }
            Text {
                id: toastLabel
                anchors.fill: parent
                anchors.margins: 12
                text: (actionToast._ok ? "✅ " : "❌ ") + actionToast._msg
                color: "#e8e8ec"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
            }
        }

        NumberAnimation on opacity {
            id: fadeIn
            from: 0; to: 1; duration: 180
            easing.type: Easing.OutCubic
            running: false
        }
        NumberAnimation on opacity {
            id: fadeOut
            from: 1; to: 0; duration: 280
            easing.type: Easing.InCubic
            running: false
        }
        NumberAnimation {
            id: slideIn
            target: toastSlide
            property: "y"
            from: 12; to: 0; duration: 220
            easing.type: Easing.OutCubic
        }
        Timer {
            id: hideTimer
            interval: 3500
            onTriggered: fadeOut.restart()
        }
    }

    // 接上传结果信号跳 toast（导出的反馈在 exportDialog.onAccepted 里直接调发）
    Connections {
        target: (typeof Rating !== "undefined") ? Rating : null
        ignoreUnknownSignals: true
        function onUploadFinished(ok, message) {
            // 鉴权类硬错（HTTP 401/403 由 C++ 端在文案前置 "[AUTH]"）单独弹模态提醒，
            // 防止"一闪而过的 toast"被用户漏看，进而以为上传成功。
            if (!ok && message && message.indexOf("[AUTH]") >= 0) {
                // 去掉前缀 token 标记，只保留人话部分给用户
                var clean = message.replace("[AUTH]", "").trim()
                uploadAuthErrorDialog._msg = clean
                uploadAuthErrorDialog.open()
                return
            }
            if (ok) {
                // 成功：右下角小 toast 容易被用户漏看（"我点了上传按钮怎么没反应？"），
                // 改用居中模态成功对话框 + 4s 自动关闭：既醒目，又不打断后续操作太久。
                // 同时按钮闪一下做次要反馈。
                uploadSuccessDialog._msg = message || qsTr("上传成功")
                uploadSuccessDialog.open()
                uploadSuccessAutoClose.restart()
                uploadBtn.flash = true
                uploadFlashTimer.restart()
            } else {
                // 失败仍走 toast：失败信息通常较长（地址不对/网络超时），用 toast 容许用户一边看一边改。
                actionToast.show(false, message)
            }
        }
        // 服务端返回 409：(rater, tag) 重复上传 → 弹覆盖确认
        function onUploadConflict(message) {
            uploadConflictDialog._msg = message
            uploadConflictDialog.open()
        }
    }

    // 未评完拦截对话框：勾选的文件夹中存在"未把所有视频都评完"的，弹此窗阻止上传。
    // 设计原则：列出具体哪些文件夹缺多少视频，让用户能精准回去补；不提供"忽略并继续上传"
    // 入口（避免把"半成品"打分集合污染云端统计）。
    Dialog {
        id: incompleteUploadDialog
        modal: true
        anchors.centerIn: parent
        width: 540
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        // 由 openWith() 写入，类型：[{ name, path, ratedCount, totalVideos }]
        property var _items: []
        function openWith(items) {
            _items = items || []
            open()
        }

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#ffb05c"      // 警示色：与汇总列"未评完"同款
            border.width: 1
            radius: 10
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: Text.AlignVCenter
                text: qsTr("⚠ 评分尚未完成，无法上传")
                color: "#ffd9a8"
                font.pixelSize: 14
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#3a2a1a"
            }
        }

        contentItem: ColumnLayout {
            spacing: 10
            // 顶部说明
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.topMargin: 16
                text: qsTr("以下文件夹中还有视频未评分，请先评完所有视频再上传：")
                color: "#e8e3d8"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
            // 列表（最多 8 行；超出滚动）
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.preferredHeight: Math.min(
                    Math.max(1, incompleteUploadDialog._items.length) * 28 + 12,
                    8 * 28 + 12)
                color: "#15151a"
                border.color: "#2a2a30"
                border.width: 1
                radius: 6
                ListView {
                    id: _incompleteList
                    anchors.fill: parent
                    anchors.margins: 6
                    clip: true
                    model: incompleteUploadDialog._items
                    spacing: 2
                    delegate: Item {
                        width: ListView.view.width
                        height: 26
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            spacing: 10
                            Text {
                                Layout.fillWidth: true
                                text: "📁 " + (modelData.name || "")
                                color: "#e8e8ea"
                                font.pixelSize: 12
                                elide: Text.ElideMiddle
                                ToolTip.visible: _ma.containsMouse
                                ToolTip.delay: 500
                                ToolTip.timeout: 8000
                                ToolTip.text: modelData.path || ""
                                MouseArea {
                                    id: _ma
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.NoButton
                                }
                            }
                            Text {
                                text: qsTr("已评 %1 / %2（缺 %3）")
                                        .arg(modelData.ratedCount)
                                        .arg(modelData.totalVideos)
                                        .arg(modelData.totalVideos - modelData.ratedCount)
                                color: "#ffb05c"
                                font.pixelSize: 12
                                font.bold: true
                            }
                        }
                    }
                }
            }
            // 底部按钮
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.topMargin: 4
                Layout.bottomMargin: 16
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("我知道了")
                    onClicked: incompleteUploadDialog.close()
                }
            }
        }
    }

    // 上传成功对话框：居中弹出，4s 后自动关闭。
    // 设计动机：右下角 actionToast 易被忽视；上传是用户的关键操作，需要明确"成功"反馈。
    Dialog {
        id: uploadSuccessDialog
        modal: true
        anchors.centerIn: parent
        width: 420
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        property string _msg: ""

        Overlay.modal: Rectangle { color: "#80000000" }

        background: Rectangle {
            color: "#1a2a1f"
            border.color: "#3aa55a"
            border.width: 1
            radius: 10
            // 阴影
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        contentItem: ColumnLayout {
            spacing: 12
            anchors.margins: 20
            // 用 Item 撑边距而不是给 ColumnLayout 设 margins（QML 不支持）
            Item { Layout.preferredHeight: 4 }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                spacing: 12
                Text {
                    text: "✅"
                    font.pixelSize: 28
                    color: "#5fd17a"
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("上传成功")
                    color: "#e8f5ec"
                    font.pixelSize: 16
                    font.bold: true
                    elide: Text.ElideRight
                }
            }
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                text: uploadSuccessDialog._msg
                color: "#cfeede"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }
            // 进度条样式倒计时（视觉提示"几秒后自动关闭"）。
            // 实现细节：内层 Rectangle 的 width 不能预先用 binding 表达式（会被 onOpened 里的
            // 命令式赋值打断 → "left-hand side of assignment operator is not an lvalue"）。
            // 改为：父开门时把 NumberAnimation 启动，由动画把 width 从满变到 0；动画自带 lvalue 写入路径。
            Rectangle {
                id: _autoCloseTrack
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.preferredHeight: 3
                radius: 2
                color: "#22381f"
                Rectangle {
                    id: _autoCloseBar
                    height: parent.height
                    radius: parent.radius
                    color: "#3aa55a"
                    width: 0   // 初始 0，开门时由动画把它推到满再线性收缩
                }
                NumberAnimation {
                    id: _autoCloseAnim
                    target: _autoCloseBar
                    property: "width"
                    duration: uploadSuccessAutoClose.interval
                    easing.type: Easing.Linear
                    // from/to 在动画启动时即时取值，保证宽度跟随父容器实际像素
                    from: _autoCloseTrack.width
                    to: 0
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.bottomMargin: 16
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("确定")
                    onClicked: { uploadSuccessAutoClose.stop(); uploadSuccessDialog.close() }
                }
            }
        }

        // 打开时启动倒计时动画（NumberAnimation 自身负责 lvalue 写入）
        onOpened: {
            _autoCloseAnim.stop()
            _autoCloseAnim.start()
        }
        onClosed: _autoCloseAnim.stop()
    }

    Timer {
        id: uploadSuccessAutoClose
        interval: 4000
        repeat: false
        onTriggered: uploadSuccessDialog.close()
    }

    // 鉴权失败对话框：服务器开启了 token 校验、但客户端未配置/配错时，弹强提醒并提供"打开设置"快捷入口。
    Dialog {
        id: uploadAuthErrorDialog
        modal: true
        anchors.centerIn: parent
        width: 460
        padding: 0

        property string _msg: ""

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#5a2a2a"
            border.width: 1
            radius: 8
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: Text.AlignVCenter
                text: qsTr("🔒 上传被拒：鉴权失败")
                color: "#f0f0f3"
                font.pixelSize: 14
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a30"
            }
        }

        contentItem: Item {
            implicitHeight: _authCol.implicitHeight + 32
            ColumnLayout {
                id: _authCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 10
                Text {
                    Layout.fillWidth: true
                    text: uploadAuthErrorDialog._msg
                    color: "#e6e6ea"
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("请向管理员获取正确的 token，并在「⚙ 上传设置」中填写后重试。")
                    color: "#8a8a90"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
            }
        }

        footer: Rectangle {
            color: "transparent"
            implicitHeight: 56
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a30"
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 8
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("知道了")
                    onClicked: uploadAuthErrorDialog.close()
                }
                PillBtn {
                    text: qsTr("打开设置")
                    danger: true
                    onClicked: {
                        uploadAuthErrorDialog.close()
                        uploadConfigDialog.open()
                    }
                }
            }
        }
    }

    // 覆盖确认对话框：同 (评分人, tag) 已存在时询问是否覆盖。
    // 确认后调 Rating.uploadToCloud(true) 带 force=1 重走。
    Dialog {
        id: uploadConflictDialog
        modal: true
        anchors.centerIn: parent
        width: 460
        padding: 0

        property string _msg: ""

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#2e2e34"
            border.width: 1
            radius: 8
            Rectangle {
                anchors.fill: parent
                anchors.margins: -6
                z: -1
                radius: parent.radius + 4
                color: "#80000000"
                opacity: 0.45
            }
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: Text.AlignVCenter
                text: qsTr("上传冲突：是否覆盖？")
                color: "#f0f0f3"
                font.pixelSize: 14
                font.bold: true
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: "#2a2a30"
            }
        }

        contentItem: Item {
            implicitHeight: _conflictCol.implicitHeight + 32
            ColumnLayout {
                id: _conflictCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: uploadConflictDialog._msg
                    color: "#e6e6ea"
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("覆盖将自动归档旧版本（每个槽位最多保留 20 份）")
                    color: "#8a8a90"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
            }
        }

        footer: Rectangle {
            color: "transparent"
            implicitHeight: 56
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2a30"
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 8
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("取消")
                    onClicked: uploadConflictDialog.close()
                }
                PillBtn {
                    text: qsTr("覆盖上传")
                    danger: true
                    onClicked: {
                        uploadConflictDialog.close()
                        if (typeof Rating !== "undefined")
                            Rating.uploadToCloud(true, root._lastUploadFolders || [])
                    }
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // 内部组件
    // ════════════════════════════════════════════════════════════════════

    // 单元格
    component CellText: Rectangle {
        property int w: 100
        property string text: ""
        property bool dim: false
        property bool rtl: false   // 路径/文件名过长时左侧省略，确保后缀可见
        property string tooltipText: ""   // 非空时鼠标悬停 ~600ms 弹出（典型用法：文件名→绝对路径）
        width: w
        height: 26
        color: "transparent"
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            text: parent.text
            color: parent.dim ? "#9aa0a6" : "#dcdcde"
            font.pixelSize: 12
            elide: parent.rtl ? Text.ElideLeft : Text.ElideRight
            horizontalAlignment: Text.AlignLeft
        }
        // 悬停 ToolTip：仅在显式提供了 tooltipText 时启用，避免空 tooltip 干扰其他单元格
        MouseArea {
            id: _cellMA
            anchors.fill: parent
            hoverEnabled: parent.tooltipText.length > 0
            acceptedButtons: Qt.NoButton          // 不抢点击事件，纯 hover
            ToolTip.visible: containsMouse && parent.tooltipText.length > 0
            ToolTip.delay: 500
            ToolTip.timeout: 8000
            ToolTip.text: parent.tooltipText
        }
    }

    // 圆角胶囊按钮（与项目深色风格一致）
    component PillBtn: Rectangle {
        property string text: ""
        property bool enabled: true
        property bool emphasized: false
        property bool danger: false
        // 瞬态成功闪烁：设为 true 后按钮变绿、文案前加 ✅，外部负责起定时器退出
        property bool flash: false
        signal clicked()

        implicitWidth:  Math.max(72, _t.implicitWidth + 22)
        implicitHeight: 28
        radius: 5
        color: !enabled ? "#1a1a1d"
              : flash       ? (_ma.containsMouse ? "#37a169" : "#2f855a")
              : danger      ? (_ma.containsMouse ? "#a23a3a" : "#3a2326")
              : emphasized  ? (_ma.containsMouse ? "#3a7afe" : "#2a5994")
              :               (_ma.containsMouse ? "#3a3a44" : "#2a2a30")
        border.color: flash ? "#52c41a"
                            : (danger ? "#5a2a2e" : "#3a3a42")
        border.width: flash ? 1 : 1
        Behavior on color {
            ColorAnimation { duration: 180 }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180 }
        }
        Text {
            id: _t
            anchors.centerIn: parent
            text: (parent.flash ? "✅ " : "") + parent.text
            color: parent.enabled ? "#ffffff" : "#555"
            font.pixelSize: 12
        }
        MouseArea {
            id: _ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: parent.enabled
            onClicked: parent.clicked()
        }
    }
}
