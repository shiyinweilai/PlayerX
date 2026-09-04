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

    // ESC 关闭本面板
    Shortcut {
        sequence: "Escape"
        onActivated: root.close()
    }

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

    // ── 视图模式（"current" / "archive"）─────────────────────────────────
    // current：浏览当前模式 CSV（可编辑、可归档、可上传），与原行为一致
    // archive：浏览某个归档批次（只读账本，仅支持导出 / 行级删除 / 删整批）
    // 切换 Tab 时会重置 _checkedFolders、清空选择，避免跨 Tab 误操作。
    property string _viewMode: "current"
    // 弹窗内的「当前查看模式」，与全局 Rating.currentMode 完全解耦：
    // 切胶囊只改本属性，数据读取均走 Rating.*ForMode(_selectedMode) 只读接口，
    // 绝不写入全局状态，避免背景视频宏格星条、cellRatings 跟着跳变。
    // 打开弹窗时从 Rating.currentMode 初始化（默认就看当前模式）。
    property string _selectedMode: (typeof Rating !== "undefined") ? Rating.currentMode : "subjective"
    // 归档 Tab 当前选中的批次名（首次打开自动取最新一批）
    property string _archiveBatch: ""
    // 选中批次所属的「评分模式」（如 test / multi_dim）。
    // 归档列表现在是跨 mode 聚合的（不再按当前模式过滤），因此
    // loadArchiveBatch / 上传 / 删除 / 打开文件夹 都必须用这个 mode，
    // 而不是 root._selectedMode，否则会操作到错误的模式目录。
    property string _archiveBatchMode: ""
    // 最近一次归档成功的「模式 + 批次名」缓存：供归档成功 toast 上的"打开所在文件夹"
    // 按钮安全取值（QML 的 JS 闭包对 var 局部变量捕获不可靠，故用属性承载）
    property string _lastArchivedMode: ""
    property string _lastArchivedBatch: ""
    // 归档 Tab 缓存的批次列表（[{name, count, latest, raters, modifiedAt, path}]）
    property var _archiveBatches: []
    // 便捷判断
    readonly property bool _isArchiveView: _viewMode === "archive"
    // 当前「查看模式」的星级上限（决定“有效评分”区间与子项星条渲染长度）。
    // 严格按 _selectedMode 读（而非全局 Rating.maxStars），与方案 C 的“弹窗与全局解耦”一致。
    // off / 未知 mode 下 maxStarsForMode 会返回 0，本处兜底 5。
    readonly property int _maxStars: {
        if (typeof Rating === "undefined") return 5
        var m = (typeof Rating.maxStarsForMode === "function") ? Rating.maxStarsForMode(_selectedMode) : Rating.maxStars
        return (m > 0) ? m : 5
    }

    // ── 分组（VSCode 风格三层树：文件夹 → 文件 → 评分记录）─────────
    // _folders: [{ key:'dir:<dir>', name, path, files:[file...], latest, avg, totalItems }]
    //   file:    { key:'file:<file_path>', name, path, items:[row...], latest, avg }
    // _expanded: { key -> bool }，文件夹与文件用不同前缀互不冲突；刷新不丢失
    // _visibleRows: 当前 ListView 实际渲染的行数组，元素形态为：
    //   { kind:'section', label, icon }  ← quality_slide 模式下的分组标题行
    //   { kind:'folder', d:<folder> }
    //   { kind:'file',   d:<folder>, g:<file> }
    //   { kind:'item',   d:<folder>, g:<file>, r:<row> }
    property var _folders: []
    // quality_slide 模式下的滑动打分文件夹组（与 _folders 普通打分分开存储）
    property var _slideFolders: []
    // 归档 Tab 的 tag 树结构：[{ key:"tag:<batchName>", name, mode, count, latest, folders:[...] }]
    // 每个 tag 节点下是正常的文件夹→文件→记录三层树
    property var _archiveTagFolders: []
    // 当前 Tab 的虚拟 tag 树（与归档结构相同，供 _rebuildVisibleRows 统一渲染 tag → folder 两级树）
    property var _curTagFolders: []
    property var _expanded: ({})
    property var _visibleRows: []

    // 上传勾选：key = folder.key（如 "dir:/Users/x/a"），value = bool。
    // 默认不勾选；刷新时保留已勾选状态、自动清理已消失的文件夹，避免脏 key 残留。
    // 外部一键上传（previewCurrentUpload）只自动勾选「当前打开的视频通路」所在文件夹，
    // 历史文件夹需用户在面板里手动勾选（全选 / 反选 / 单个勾选均可）。
    // 仅用于"按文件夹勾选上传"功能，不影响导出 / 渲染。
    property var _checkedFolders: ({})

    // ── 归档 Tab：tag 勾选 → 备注 tag 自动同步 ──────────────────
    // true = tagField 受勾选状态驱动（用户未手动改写）；
    // false = 用户手动改写过，自动同步暂停，下次勾选变化时恢复接管。
    property bool _tagAutoSync: true

    // ── 外部"一键上传"路由标志 ───────────────────────────────────
    // Main.qml 通过 triggerQuickUploadForCurrentTab() 触发时，会将本标志
    // 置 true。上传流程在 uploadFinished / uploadConflict / uploadNetError
    // 信号里判断该标志：为 true 时【跳过】面板内的 uploadSuccessDialog /
    // uploadConflictDialog 等，改为 emit quickUploadXxx 信号让 Main.qml
    // 用主窗口顶层的对话框展示结果，从而实现"上传成功不弹面板"的体验。
    // 校验失败（评分人/tag/未评完）时，主动切回可视化面板供用户修改，
    // 并把本标志置 false，避免下一次弹窗被错误路由。
    property bool _quickUploadInProgress: false

    // 外部一键上传的结果信号：Main.qml 会连上这些信号，用自己的对话框展示。
    // archivedBatch：上传成功后自动归档产生的批次名；为空表示未自动归档。
    // 一键上传（📤 上传数据）也走这个信号，主窗结果对话框据此显示"已自动归档"。
    signal quickUploadFinished(bool ok, string message, string archivedBatch)
    signal quickUploadConflict(string message)
    signal quickUploadNetError(string message)

    // 上次发起上传时所携带的文件夹白名单。
    // 设置框"保存并上传"、覆盖确认"覆盖上传"都会复用它，
    // 避免“点上传 → 弹设置 → 保存”过程中把白名单丢了变成全量上传。
    property var _lastUploadFolders: []
    // 上次上传的“来源标记”："current"（当前 Tab 主 CSV）/ "archive"（归档批次）。
    // 服务端返回 409 后用户选择“覆盖上传”时，需要按同一来源 + 同一批次重发，
    // 否则点了归档批次的上传，覆盖时却走当前 Tab 数据，会和用户预期完全错位。
    property string _lastUploadKind: "current"
    // 归档来源专属：上次上传所选的批次名；current 来源时无意义。
    property string _lastUploadArchiveBatch: ""
    // 归档来源上传时，该批次所属的 mode（跨 mode 聚合后必须记录，
    // 否则 uploadArchiveBatchToCloud 会按当前模式去找、找错目录）
    property string _lastUploadArchiveMode: ""
    // 多 tag 上传时的 tag→{mode, paths} 映射，供覆盖上传重发使用
    property var _lastUploadTagPickedMap: ({})
    // 串行上传队列：多 tag 上传时，逐个发送，避免 m_uploading 互斥
    property var _serialUploadQueue: []
    property int _serialUploadIndex: 0
    property bool _serialUploadForce: false
    // 发起串行上传队列中的下一个
    function _sendNextSerialUpload() {
        if (_serialUploadIndex >= _serialUploadQueue.length) {
            // 队列全部完成
            _serialUploadQueue = []
            _serialUploadIndex = 0
            _serialUploadForce = false
            return
        }
        var item = _serialUploadQueue[_serialUploadIndex]
        console.log("[SerialUpload] #" + _serialUploadIndex + " → uploadArchiveBatchToCloud, mode=",
                    item.mode, "batch=", item.name, "force=", _serialUploadForce)
        Rating.uploadArchiveBatchToCloud(item.mode, item.name, _serialUploadForce, item.paths)
    }
    // 远程激活配置的 tag（由 Main.qml 注入），用于上传前校验
    property string remoteTag: ""
    // 开发者模式（由 Main.qml 注入）：勾选时模式切换 Tab 显示「测试模式」
    property bool developerMode: false
    // 模式切换 Tab 实际展示的列表：始终包含「测试模式」
    readonly property var _visibleModeList: {
        var ml = (typeof Rating !== "undefined") ? Rating.modeList : []
        return ml
    }
    // quality_slide 模式下第二维度的 key（由 Main.qml 注入，例如 "滑动"）。
    // 用来区分同 CSV 里的滑动打分（slide_type == "multi_<slideDimKey>" 或旧值 "slide"）
    // 和第一维度普通打分（slide_type == "multi_<其他key>"），便于分组显示。
    property string slideDimKey: ""
    // 当前模式的 checklist 配置（items 数组：[{key, label, definition, ...}]）。
    // 由 Main.qml 注入。空数组 = 该模式没有 checklist，本 Dialog 完全不做 checklist 校验。
    property var reviewChecklist: []

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
    // 归档 Tab：把扁平 _rows（已带 _archiveBatch / _archiveBatchMode 标记）
    // 聚成 tag 树：tag → 文件夹 → 文件 → 评分记录。
    // 返回 [{ key:"tag:<name>", name, mode, count, latest, folders:[...] }]
    function _buildArchiveTagTree(rows) {
        // 第一轮：按 (batchName, batchMode) 分组
        var tagMap = {}
        var tagOrder = []
        for (var i = 0; i < rows.length; ++i) {
            var r = rows[i]
            var bn = r._archiveBatch || ""
            var bm = r._archiveBatchMode || ""
            if (bn.length === 0) continue
            var tkey = bm + "::" + bn
            if (!tagMap[tkey]) {
                tagMap[tkey] = { name: bn, mode: bm, rows: [] }
                tagOrder.push(tkey)
            }
            tagMap[tkey].rows.push(r)
        }
        // 第二轮：每个 tag 下的 rows 调用 _buildFoldersFromRows 构建文件夹树
        var tags = []
        for (var j = 0; j < tagOrder.length; ++j) {
            var tg = tagMap[tagOrder[j]]
            var folders = _buildFoldersFromRows(tg.rows)
            var totalItems = 0
            var latest = ""
            for (var k = 0; k < folders.length; ++k) {
                totalItems += folders[k].totalItems || 0
                if ((folders[k].latest || "") > latest) latest = folders[k].latest || ""
            }
            tags.push({
                key: "tag:" + tg.name,
                name: tg.name,
                mode: tg.mode,
                count: tg.rows.length,
                latest: latest,
                totalItems: totalItems,
                folders: folders
            })
        }
        // 按 latest 倒序
        tags.sort(function(a, b) {
            if (a.latest === b.latest) return 0
            return a.latest < b.latest ? 1 : -1
        })
        return tags
    }

    // 把扁平 _rows 聚成三层树：文件夹 → 文件 → 评分记录。
    // _sortDesc 影响：
    //   · 同一文件下记录始终倒序（最新在前，便于一眼看到最近评分）
    //   · 文件之间、文件夹之间则按 _sortDesc 排（按各自组内最新时间）
    // quality_slide 模式下，_rows 中含 _source 字段（"normal"/"slide"），
    // 会分别建 _folders（普通打分）和 _slideFolders（滑动打分）两组。
    function _buildFoldersFromRows(rows) {
        var fileMap = {}
        var fileOrder = []
        for (var i = 0; i < rows.length; ++i) {
            var r = rows[i]
            var fkey = r.file_path && r.file_path.length > 0
                       ? r.file_path
                       : ("name:" + (r.file_name || "(unknown)"))
            if (!fileMap[fkey]) {
                var rawName = r.file_name || _baseName(fkey)
                fileMap[fkey] = {
                    key: "file:" + fkey,
                    name: _stripChannelPrefix(rawName),
                    rawName: rawName,
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
                if (s >= 1) {
                    if (s > root._maxStars) s = root._maxStars
                    sum += s
                    ++cnt
                }
            }
            g.avg = cnt > 0 ? Math.round(sum / cnt * 10) / 10 : 0
        }
        // 按目录聚成文件夹
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
        var folders = []
        for (var n = 0; n < dirOrder.length; ++n) {
            var d = dirMap[dirOrder[n]]
            d.files.sort(function(a, b) {
                var ta = a.latest || "", tb = b.latest || ""
                if (ta === tb) return 0
                if (root._sortDesc) return ta < tb ? 1 : -1
                return ta < tb ? -1 : 1
            })
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
            d.latest = dLatest
            d.avg = dCnt > 0 ? Math.round(dSum / dCnt * 10) / 10 : 0
            d.ratedCount = d.files.length
            // 汇总列/预览面板都依赖 d.totalItems 展示"N 条评分"，
            // 这里 total 是本文件夹下所有 file.items 累加，直接落到 d.totalItems。
            // （之前遗漏此赋值，导致预览面板与汇总列都显示为 0 条）
            d.totalItems = total
            var tot2 = d.ratedCount
            if (d.path && d.path.length > 0 && typeof Reference !== "undefined"
                    && typeof Reference.videoCountInFolder === "function") {
                var n2 = Reference.videoCountInFolder(d.path)
                if (n2 > tot2) tot2 = n2
            }
            d.totalVideos = tot2
            // ── Checklist 未勾选统计 ────────────────────────────────
            // 当模式配置了 checklist 时，逐文件读取 Rating.loadString("checklist:"+fp)
            // 若为空（未勾选任何检查项）则计数。ckMissing > 0 时该文件夹算未评完，
            // 会在 fullyRated 上体现、参与上传前拦截。
            // 无 checklist 配置或 Rating 未定义 → ckMissing 恒为 0，行为与旧版完全一致。
            var ckCfg = root.reviewChecklist
            var hasCkCfg = ckCfg && typeof ckCfg.length === "number" && ckCfg.length > 0
            var ckMiss = 0
            if (hasCkCfg && typeof Rating !== "undefined") {
                for (var cf = 0; cf < d.files.length; ++cf) {
                    var cfp = d.files[cf].path || ""
                    if (!cfp) continue
                    var craw = Rating.loadString("checklist:" + cfp, "")
                    var cok = false
                    if (craw && craw.length > 0) {
                        try {
                            var carr = JSON.parse(craw)
                            if (carr && typeof carr.length === "number" && carr.length > 0) cok = true
                        } catch (e) { cok = false }
                    }
                    if (!cok) ++ckMiss
                }
            }
            d.ckMissing = ckMiss
            d.fullyRated = (d.totalVideos > 0)
                && (d.ratedCount >= d.totalVideos)
                && (ckMiss === 0)
            folders.push(d)
        }
        folders.sort(function(a, b) {
            var ta = a.latest || "", tb = b.latest || ""
            if (ta === tb) return 0
            if (root._sortDesc) return ta < tb ? 1 : -1
            return ta < tb ? -1 : 1
        })
        return folders
    }

    function _rebuildGroups() {
        var isArchive = root._isArchiveView
        var isQS = root._selectedMode === "quality_slide"
        var normalRows, slideRows
        if (isQS) {
            normalRows = []
            slideRows = []
            for (var si = 0; si < _rows.length; ++si) {
                if (_rows[si]._source === "slide") slideRows.push(_rows[si])
                else normalRows.push(_rows[si])
            }
        } else {
            normalRows = _rows
            slideRows = []
        }

        if (isArchive) {
            // 归档 Tab：按 tag 分组构建 tag 树（tag → 文件夹 → 文件 → 记录）
            _archiveTagFolders = _buildArchiveTagTree(normalRows)
            _folders      = []
            _slideFolders = []
            _checkedFolders = ({})
            // 归档 Tab 刷新/切入时清空备注 tag，等待用户勾选后自动填入
            root._tagAutoSync = true
            if (typeof tagField !== "undefined") tagField.text = ""
            if (typeof Rating  !== "undefined") Rating.uploadTag = ""
        } else {
            var normalFolders = _buildFoldersFromRows(normalRows)
            var slideFolders  = _buildFoldersFromRows(slideRows)
            _folders      = normalFolders
            _slideFolders = slideFolders

            // ── 自动补充当前 Tab 的虚拟 tag（用于与归档界面对齐的两级树展示）──
            // 优先用 tagField 已填写的值；若为空则自动生成「用户名+时间戳」并回填 tagField。
            var curTagName = (typeof tagField !== "undefined") ? tagField.text.trim() : ""
            if (curTagName.length === 0) {
                var raterName = (typeof userField !== "undefined" && userField.text.trim().length > 0)
                    ? userField.text.trim()
                    : ((typeof Rating !== "undefined" && Rating.currentUser)
                        ? String(Rating.currentUser).trim() : "anon")
                var now = new Date()
                var yyyy = now.getFullYear()
                var mm   = ("0" + (now.getMonth() + 1)).slice(-2)
                var dd   = ("0" + now.getDate()).slice(-2)
                var hh   = ("0" + now.getHours()).slice(-2)
                var mi   = ("0" + now.getMinutes()).slice(-2)
                curTagName = raterName + yyyy + mm + dd + hh + mi
                if (typeof tagField !== "undefined") tagField.text = curTagName
                if (typeof Rating   !== "undefined") Rating.uploadTag = curTagName
            }
            // 把所有普通打分 folder 归到同一个虚拟 tag 节点
            var totalItems = 0
            var latestTs = ""
            for (var cti = 0; cti < normalFolders.length; ++cti) {
                totalItems += normalFolders[cti].totalItems || 0
                if ((normalFolders[cti].latest || "") > latestTs) latestTs = normalFolders[cti].latest || ""
            }
            _curTagFolders = (normalFolders.length > 0) ? [{
                key: "tag:" + curTagName,
                name: curTagName,
                mode: root._selectedMode,
                count: normalFolders.length,
                latest: latestTs,
                totalItems: totalItems,
                folders: normalFolders
            }] : []
            // tag 节点默认展开
            if (_curTagFolders.length > 0) {
                var exCopy = {}
                for (var ek in _expanded) exCopy[ek] = _expanded[ek]
                exCopy[_curTagFolders[0].key] = true
                _expanded = exCopy
            }

            // ── 同步 _checkedFolders（仅针对普通打分文件夹）
            var nextChecked = {}
            for (var ci = 0; ci < normalFolders.length; ++ci) {
                var ck = normalFolders[ci].key
                nextChecked[ck] = (root._checkedFolders[ck] === true) ? true : false
            }
            _checkedFolders = nextChecked
        }

        _rebuildVisibleRows()
    }

    // ── 以下是原 _rebuildGroups 里被提取到 _buildFoldersFromRows 之前的旧代码占位，
    //    保留空函数体以防万一有其他地方引用（实际已全部迁移到上面）──────────────
    function _rebuildGroups_unused() {
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
    }   // end _rebuildGroups_unused

    // 根据当前展开状态，把 _folders（+ quality_slide 模式下的 _slideFolders，
    // + 归档 Tab 下的 _archiveTagFolders）展平为 ListView 数据源
    function _rebuildVisibleRows() {
        var out = []
        var isArchive = root._isArchiveView
        var isQS = root._selectedMode === "quality_slide"

        if (isArchive) {
            // 归档 Tab：tag 树（tag → 文件夹 → 文件 → 记录）
            for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
                var tag = _archiveTagFolders[ti]
                out.push({ kind: "tag", d: tag })
                if (!_expanded[tag.key]) continue
                for (var fi = 0; fi < tag.folders.length; ++fi) {
                    var fd = tag.folders[fi]
                    out.push({ kind: "folder", d: fd, tag: tag })
                    if (!_expanded[fd.key]) continue
                    for (var fj = 0; fj < fd.files.length; ++fj) {
                        var fg = fd.files[fj]
                        out.push({ kind: "file", d: fd, g: fg, tag: tag })
                        if (!_expanded[fg.key]) continue
                        for (var fk = 0; fk < fg.items.length; ++fk) {
                            out.push({ kind: "item", d: fd, g: fg, r: fg.items[fk], tag: tag })
                        }
                    }
                }
            }
        } else {
            // 普通打分分组：以虚拟 tag 节点为一级，folder 为二级（与归档 Tab 结构对齐）
            if (isQS && (_curTagFolders.length > 0 || _slideFolders.length > 0)) {
                out.push({ kind: "section", label: "📋 普通打分", icon: "" })
            }
            for (var ti2 = 0; ti2 < _curTagFolders.length; ++ti2) {
                var ctag = _curTagFolders[ti2]
                out.push({ kind: "tag", d: ctag })
                if (!_expanded[ctag.key]) continue
                for (var cfi = 0; cfi < ctag.folders.length; ++cfi) {
                    var cfd = ctag.folders[cfi]
                    out.push({ kind: "folder", d: cfd, tag: ctag })
                    if (!_expanded[cfd.key]) continue
                    for (var cfj = 0; cfj < cfd.files.length; ++cfj) {
                        var cfg = cfd.files[cfj]
                        out.push({ kind: "file", d: cfd, g: cfg, tag: ctag })
                        if (!_expanded[cfg.key]) continue
                        for (var cfk = 0; cfk < cfg.items.length; ++cfk) {
                            out.push({ kind: "item", d: cfd, g: cfg, r: cfg.items[cfk], tag: ctag })
                        }
                    }
                }
            }

            // 滑动打分分组（仅 quality_slide 模式）
            if (isQS) {
                out.push({ kind: "section", label: "🎬 滑动对比打分", icon: "" })
                for (var si = 0; si < _slideFolders.length; ++si) {
                    var sd = _slideFolders[si]
                    out.push({ kind: "folder", d: sd })
                    if (!_expanded[sd.key]) continue
                    for (var sj = 0; sj < sd.files.length; ++sj) {
                        var sg = sd.files[sj]
                        out.push({ kind: "file", d: sd, g: sg })
                        if (!_expanded[sg.key]) continue
                        for (var sk = 0; sk < sg.items.length; ++sk) {
                            out.push({ kind: "item", d: sd, g: sg, r: sg.items[sk] })
                        }
                    }
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
        // 归档 Tab：展开/折叠所有 tag 及其子节点
        if (root._isArchiveView) {
            for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
                var tag = _archiveTagFolders[ti]
                ex[tag.key] = !!flag
                for (var fi = 0; fi < tag.folders.length; ++fi) {
                    var fd = tag.folders[fi]
                    ex[fd.key] = !!flag
                    for (var fj = 0; fj < fd.files.length; ++fj) {
                        ex[fd.files[fj].key] = !!flag
                    }
                }
            }
        } else {
            // 先展开/折叠 tag 节点
            for (var ei = 0; ei < _curTagFolders.length; ++ei) {
                var et = _curTagFolders[ei]
                ex[et.key] = !!flag
            }
            for (var i = 0; i < _folders.length; ++i) {
                var d = _folders[i]
                ex[d.key] = !!flag
                for (var j = 0; j < d.files.length; ++j) {
                    ex[d.files[j].key] = !!flag
                }
            }
        }
        _expanded = ex
        _rebuildVisibleRows()
    }
    // ── 勾选相关 ─────────────────────────────────────────────────────
    function _isFolderChecked(key) {
        // 缺省视为未勾（默认不选）
        return _checkedFolders[key] === true
    }
    function _toggleFolderChecked(key) {
        var c = {}
        for (var k in _checkedFolders) c[k] = _checkedFolders[k]
        c[key] = !_isFolderChecked(key)
        _checkedFolders = c
        _syncTagFieldFromChecked()
    }
    function _setFolderChecked(key, flag) {
        var c = {}
        for (var k in _checkedFolders) c[k] = _checkedFolders[k]
        c[key] = !!flag
        _checkedFolders = c
        _syncTagFieldFromChecked()
    }
    function _setAllFoldersChecked(flag) {
        var c = {}
        if (root._isArchiveView) {
            for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
                var tag = _archiveTagFolders[ti]
                for (var fi = 0; fi < tag.folders.length; ++fi) {
                    c[tag.folders[fi].key] = !!flag
                }
            }
        } else {
            for (var i = 0; i < _folders.length; ++i) c[_folders[i].key] = !!flag
        }
        _checkedFolders = c
        _syncTagFieldFromChecked()
    }
    // ── 归档 Tab：根据已勾选的 tag 自动填写备注 tag ─────────────────
    // 规则：
    //   · 归档 Tab 下：勾选了 1 个 tag → 填入该 tag 名；
    //                  勾选了 0 / 多个 tag → 清空（让用户自己填）。
    //   · 当前 Tab 下：不接管，保持用户输入原值。
    //   · 用户手动改写 tagField 后，_tagAutoSync = false，同步暂停；
    //     下次勾选变化时，自动接管前先把 _tagAutoSync 置回 true。
    function _syncTagFieldFromChecked() {
        if (!root._isArchiveView) return
        // 找出所有"整体被勾选（至少 1 个文件夹被勾）"的 tag
        var checkedTagNames = []
        for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
            var tg = _archiveTagFolders[ti]
            var anyChecked = false
            for (var fi = 0; fi < tg.folders.length; ++fi) {
                if (_isFolderChecked(tg.folders[fi].key)) { anyChecked = true; break }
            }
            if (anyChecked) checkedTagNames.push(tg.name)
        }
        // 每次勾选变化都接管 tagField（覆盖用户手动值）
        root._tagAutoSync = true
        var newTag = (checkedTagNames.length === 1) ? checkedTagNames[0] : ""
        if (typeof tagField !== "undefined" && tagField.text !== newTag) {
            tagField.text = newTag
        }
        if (typeof Rating !== "undefined" && Rating.uploadTag !== newTag) {
            Rating.uploadTag = newTag
        }
    }
    // 只勾选「当前打开的视频通路」所在的文件夹，其余一律置为不勾选。
    // 供外部一键上传（previewCurrentUpload）使用：用户诉求是"上传本次评的这几路视频"，
    // 历史评分过的其他文件夹不应被自动带上（需要时可在面板里手动补勾）。
    // 路径比对复用 _dirOf，与 _buildFoldersFromRows 生成文件夹 path 的规则完全一致，
    // 因此只要视频确实评分过，目录字符串必然能逐字节命中对应文件夹。
    function _setCheckedToCurrentVideoFolders() {
        var dirs = {}
        if (typeof Engine !== "undefined") {
            var n = 0
            try { n = Engine.fileCount || 0 } catch (e) { n = 0 }
            for (var i = 0; i < n; ++i) {
                var fp = ""
                try { fp = Engine.filePathAt(i) || "" } catch (e2) { fp = "" }
                var dir = _dirOf(fp)
                if (dir.length > 0) dirs[dir] = true
            }
        }
        var c = {}
        for (var j = 0; j < _folders.length; ++j) {
            var d = _folders[j]
            c[d.key] = (d.path && dirs[d.path] === true) ? true : false
        }
        _checkedFolders = c
        _syncTagFieldFromChecked()
    }
    function _invertFolderChecked() {
        var c = {}
        if (root._isArchiveView) {
            for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
                var tag = _archiveTagFolders[ti]
                for (var fi = 0; fi < tag.folders.length; ++fi) {
                    var k = tag.folders[fi].key
                    c[k] = !_isFolderChecked(k)
                }
            }
        } else {
            for (var i = 0; i < _folders.length; ++i) {
                var k = _folders[i].key
                c[k] = !_isFolderChecked(k)
            }
        }
        _checkedFolders = c
        _syncTagFieldFromChecked()
    }
    function _checkedFolderCount() {
        var n = 0
        if (root._isArchiveView) {
            for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
                var tag = _archiveTagFolders[ti]
                for (var fi = 0; fi < tag.folders.length; ++fi) {
                    if (_isFolderChecked(tag.folders[fi].key)) ++n
                }
            }
        } else {
            for (var i = 0; i < _folders.length; ++i) {
                if (_isFolderChecked(_folders[i].key)) ++n
            }
        }
        return n
    }
    // 收集已勾选文件夹的绝对路径，传给 Rating.uploadToCloud(folderPaths)
    function _collectCheckedFolderPaths() {
        var out = []
        if (root._isArchiveView) {
            for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
                var tag = _archiveTagFolders[ti]
                for (var fi = 0; fi < tag.folders.length; ++fi) {
                    var d = tag.folders[fi]
                    if (_isFolderChecked(d.key) && d.path && d.path.length > 0) {
                        out.push(d.path)
                    }
                }
            }
        } else {
            for (var i = 0; i < _folders.length; ++i) {
                var d = _folders[i]
                if (_isFolderChecked(d.key) && d.path && d.path.length > 0) {
                    out.push(d.path)
                }
            }
        }
        return out
    }
    // 删除已勾选文件夹的所有评分数据（当前 Tab，不可恢复）
    function _deleteCheckedFolders() {
        if (typeof Rating === "undefined") return
        var paths = []
        for (var i = 0; i < _folders.length; ++i) {
            var d = _folders[i]
            if (_isFolderChecked(d.key) && d.path && d.path.length > 0)
                paths.push(d.path)
        }
        // quality_slide 模式下也删滑动打分数据
        for (var si = 0; si < _slideFolders.length; ++si) {
            var sd = _slideFolders[si]
            if (_isFolderChecked(sd.key) && sd.path && sd.path.length > 0)
                paths.push(sd.path)
        }
        if (paths.length === 0) return
        Rating.removeByFolders(paths, root._selectedMode)
        _refresh()
    }

    // 收集已勾选、但还未评完的文件夹（用于上传前拦截）。
    // 返回元素：{ name, path, ratedCount, totalVideos }
    // 设计原则：不评完不让上传 → 避免云端出现"半成品"打分集合污染统计。
    // quality_slide 模式下同时检查普通打分（_folders）和滑动打分（_slideFolders）：
    // 只要勾选的文件夹在任意一组中未评完，都应拦截上传。
    function _collectCheckedIncomplete() {
        var out = []
        // 辅助：检查单个文件夹列表
        function _checkList(list) {
            for (var i = 0; i < list.length; ++i) {
                var d = list[i]
                if (!_isFolderChecked(d.key)) continue
                // path 为空（"(未知文件夹)" 兜底）的不参与校验：它本来也不会上传
                if (!d.path || d.path.length === 0) continue
                var rated = (d.ratedCount === undefined ? d.files.length : d.ratedCount)
                var total = (d.totalVideos === undefined ? rated : d.totalVideos)
                var ckMiss = (d.ckMissing === undefined ? 0 : d.ckMissing)
                var starIncomplete = (total > 0 && rated < total)
                var ckIncomplete = (ckMiss > 0)
                if (starIncomplete || ckIncomplete) {
                    out.push({
                        name: d.name,
                        path: d.path,
                        ratedCount: rated,
                        totalVideos: total,
                        ckMissing: ckMiss
                    })
                }
            }
        }
        _checkList(_folders)
        // quality_slide 模式：滑动打分文件夹也参与完整性校验
        if ((typeof Rating !== "undefined") && root._selectedMode === "quality_slide") {
            _checkList(_slideFolders)
        }
        return out
    }

    // ── 外部"一键上传"入口所需的预览接口 ─────────────────────────────
    // 场景：Main.qml 的"📤 评分数据"按钮不再打开评分数据面板，而是
    //   自动勾选"当前打开的视频通路"所在的文件夹（历史文件夹不自动勾选），
    //   弹一个二次确认框。
    // 本函数不依赖面板 UI 是否已打开：内部会强制刷新一次数据（_refresh），
    //   然后基于最新 _folders 计算返回预览信息。
    //
    // 返回结构：
    //   {
    //     mode          : "subjective" 等
    //     modeLabel     : 对应中文标签，用于展示
    //     rater         : Rating.currentUser
    //     tag           : Rating.uploadTag
    //     folders       : [ { name, path, ratedCount, totalVideos, ckMissing, totalItems }, ... ]
    //     recordCount   : 累计评分条数（用于文案 "N 条评分"）
    //     incomplete    : 未评完的文件夹列表（同 _collectCheckedIncomplete 结构）
    //     canUpload     : 是否所有校验通过，可直接上传
    //     blockReason   : 未通过时的原因文案（评分人未填 / tag 未填 / 无可上传文件夹 / 有未评完）
    //   }
    function previewCurrentUpload() {
        // 强制切到"当前"Tab 视图并刷新数据，避免残留归档 Tab 状态污染
        // （用户可能之前打开过面板并切到"归档"Tab，这里我们要的是"当前正在评分"）
        if (root._viewMode !== "current") root._viewMode = "current"
        _refresh()
        // 只自动勾选「当前打开的视频通路」所在的文件夹（而非历史全部），
        // 供后续 triggerQuickUploadForCurrentTab 直接使用；
        // 用户仍可在面板里通过「全选 / 反选 / 单个勾选」手动调整上传范围。
        _setCheckedToCurrentVideoFolders()

        var picked = _collectCheckedFolderPaths()
        var incomplete = _collectCheckedIncomplete()

        // ══════════════════════════════════════════════════════════════
        // 归档回退：当前 Tab 已无记录（数据已被自动归档走）时，
        // 自动改用「最近一次归档批次」的数据来上传。
        //
        // 场景：上次上传成功后自动归档 → 当前 Tab 被清空 → 用户再次点
        // 「📤 上传数据」时本来会显示"0 条评分，无法上传"，现在改为直接
        // 从归档批次取记录上传，等价于"在归档 Tab 里选中该批次再上传"。
        //
        // 关键：把 _lastUploadKind 置为 "archive" 并记下批次名，
        // _performUpload() 会据此走 uploadArchiveBatchToCloud 通路；
        // 且 _autoArchiveAfterUpload() 会跳过归档（数据本就在归档里），
        // 因此【不会重复归档】，持久化跟踪流程不受影响。
        // ══════════════════════════════════════════════════════════════
        var fromArchive = ""
        var archiveRowCount = 0
        if (picked.length === 0) {
            try {
                // 归档 csv 命名：playerx_<rater>_<mode>__<batch>_<group>.csv
                // group 即上传 tag，因此【给定 tag 时归档文件唯一】，
                // 直接按 "_<tag>.csv" 后缀定位，无需用户选择批次。
                var tagKey = (typeof Rating !== "undefined" && Rating.uploadGroup)
                             ? String(Rating.uploadGroup).trim() : ""
                var batches = (typeof Rating !== "undefined")
                              ? (Rating.listArchiveBatches(root._selectedMode) || []) : []
                var hit = null
                if (tagKey.length > 0) {
                    // ① 优先：批次目录名 == tag（统一命名后的正规形态，唯一且确定）
                    for (var ti = 0; ti < batches.length; ++ti) {
                        var bt = batches[ti] || {}
                        if (String(bt["name"] || "") === tagKey) { hit = bt; break }
                    }
                    // ② 回退：按 csv 文件名后缀 _<tag>.csv 匹配（旧时间戳命名残留时）
                    if (!hit) {
                        for (var tj = 0; tj < batches.length; ++tj) {
                            var bj = batches[tj] || {}
                            if (String(bj["path"] || "").endsWith("_" + tagKey + ".csv")) {
                                hit = bj; break
                            }
                        }
                    }
                }
                // ③ 最后退回最近批次
                if (!hit && batches.length > 0) hit = batches[0]

                if (hit) {
                    var bName = String(hit["name"] || "")
                    // 跨 mode 聚合后，命中批次自带 mode，必须用它读取/上传，
                    // 不能用当前 _selectedMode（归档可能属于别的模式）
                    var bMode = String(hit["mode"] || "") || root._selectedMode
                    if (bName.length > 0) {
                        var rows = Rating.loadArchiveBatch(bMode, bName) || []
                        archiveRowCount = rows.length
                        // 从归档记录的 file_path 反推所属文件夹，去重
                        var dirSet = {}, dirList = []
                        for (var ai = 0; ai < rows.length; ++ai) {
                            var r = rows[ai] || {}
                            var afp = r["file_path"] || ""
                            if (!afp) continue
                            var adir = afp.substring(0, afp.lastIndexOf("/"))
                            if (adir.length === 0 || dirSet[adir]) continue
                            dirSet[adir] = true
                            dirList.push(adir)
                        }
                        if (dirList.length > 0) {
                            picked = dirList
                            fromArchive = bName
                            // 归档数据视为"已评完"，无需 incomplete 拦截
                            incomplete = []
                            root._lastUploadKind = "archive"
                            root._lastUploadArchiveBatch = bName
                            root._lastUploadArchiveMode = bMode
                            root._lastUploadFolders = picked
                            console.log("[QuickUpload] 当前 Tab 无记录 → 按 tag「",
                                        tagKey, "」定位归档批次:", bName,
                                        "文件夹数:", picked.length)
                        }
                    }
                }
            } catch (e) {
                console.warn("[QuickUpload] 归档回退失败：", e)
                fromArchive = ""
            }
        } else {
            // 当前 Tab 有记录：恢复正常路径
            root._lastUploadKind = "current"
            root._lastUploadArchiveBatch = ""
            root._lastUploadArchiveMode = ""
        }

        // 累计评分条数：仅统计本次勾选文件夹里的评分记录数之和
        // 归档回退模式下 _folders 是"当前 Tab"的空表，改用归档 CSV 的实际行数
        var recordCount = 0
        if (fromArchive.length > 0) {
            recordCount = archiveRowCount
        } else {
            for (var i = 0; i < _folders.length; ++i) {
                var d = _folders[i]
                if (!d || !_isFolderChecked(d.key)) continue
                if (typeof d.totalItems === "number") recordCount += d.totalItems
            }
        }

        // 组装 folders 明细（仅本次勾选的文件夹，用 name / path / 完整度）
        // 归档回退模式下按归档目录逐项列（rated==total，视为已评完）
        var foldersOut = []
        if (fromArchive.length > 0) {
            for (var aj = 0; aj < picked.length; ++aj) {
                var ap = picked[aj] || ""
                if (ap.length === 0) continue
                foldersOut.push({
                    name: ap.substring(ap.lastIndexOf("/") + 1),
                    path: ap,
                    ratedCount: 1,
                    totalVideos: 1,
                    ckMissing: 0,
                    totalItems: 0
                })
            }
        } else {
            for (var j = 0; j < _folders.length; ++j) {
                var fd = _folders[j]
                if (!fd || !fd.path || fd.path.length === 0) continue
                if (!_isFolderChecked(fd.key)) continue
                var rated = (fd.ratedCount === undefined ? fd.files.length : fd.ratedCount)
                var total = (fd.totalVideos === undefined ? rated : fd.totalVideos)
                foldersOut.push({
                    name: fd.name,
                    path: fd.path,
                    ratedCount: rated,
                    totalVideos: total,
                    ckMissing: fd.ckMissing || 0,
                    totalItems: fd.totalItems || 0
                })
            }
        }

        // 从 modeList 找 label
        var modeLabel = root._selectedMode
        try {
            var _ml = (typeof Rating !== "undefined") ? Rating.modeList : []
            for (var mi = 0; mi < _ml.length; ++mi) {
                if (_ml[mi].id === root._selectedMode) { modeLabel = _ml[mi].label; break }
            }
        } catch (e) {}

        // 校验：任何一项不满足都视为"不能直接上传，需要用户到面板里修改"
        var raterText = (typeof Rating !== "undefined" && Rating.currentUser)
                        ? String(Rating.currentUser).trim() : ""
        var tagText   = (typeof Rating !== "undefined" && Rating.uploadTag)
                        ? String(Rating.uploadTag).trim() : ""
        var canUpload = true
        var blockReason = ""
        if (picked.length === 0) {
            canUpload = false
            blockReason = qsTr("当前打开的视频所在文件夹没有可上传的评分记录。\n可点「去修改」在评分数据面板里手动勾选要上传的文件夹。")
        } else if (raterText.length === 0) {
            canUpload = false
            blockReason = qsTr("评分人未填写，请先在评分数据面板顶部填写「评分人 *」。")
        } else if (tagText.length === 0) {
            canUpload = false
            blockReason = qsTr("备注 tag 未填写，请先在评分数据面板顶部填写「备注 tag *」。")
        } else if (incomplete.length > 0) {
            canUpload = false
            blockReason = qsTr("有 %1 个文件夹尚未评完，无法上传。").arg(incomplete.length)
        }

        // 数据源显示文案：用于确认弹窗的只读"数据源"行。
        // 归档回退时展示批次名 + 条数（蓝色），否则展示"当前评分数据 + 条数"。
        var sourceLabel = (fromArchive.length > 0)
            ? qsTr("归档批次 %1（%2 条）").arg(fromArchive).arg(recordCount)
            : qsTr("当前评分数据（%1 条）").arg(recordCount)

        return {
            mode: root._selectedMode,
            modeLabel: modeLabel,
            rater: raterText,
            tag: tagText,
            folders: foldersOut,
            recordCount: recordCount,
            incomplete: incomplete,
            canUpload: canUpload,
            blockReason: blockReason,
            // 非空 → 本次上传取自归档批次（当前 Tab 已无数据）
            fromArchiveBatch: fromArchive,
            // 只读文案，如"当前评分数据（12 条）"/"归档批次 test_xxx（85 条）"
            sourceLabel: sourceLabel
        }
    }

    // 外部"一键上传"入口的执行函数：
    // 已经由 previewCurrentUpload() 勾选当前视频文件夹并校验过；这里直接触发上传主流程
    // （复用所有既有拦截、tag 校验、成功回调、自动归档等）。
    //
    // 【路由说明】本 RatingsDialog 是独立 Window，其内部子对话框
    //   （uploadConflictDialog / uploadSuccessDialog 等）必须依赖 Window
    //   可见才能显示。为了让用户能"直接上传，不显示面板"的体验：
    //     · 设置 _quickUploadInProgress = true 标志；
    //     · onUploadFinished / onUploadConflict / onUploadNetError 里判断
    //       该标志为 true 时，跳过面板内对话框，改为 emit 信号让 Main.qml
    //       用主窗口的对话框展示结果；
    //     · 只有校验失败（评分人/tag/未评完）时才把 Window show 出来供修改。
    //
    // 注意：本函数假设 previewCurrentUpload().canUpload === true。若外部
    // 越过预览直接调用，遇到评分人/tag 缺失，_performUpload 内部的
    // _rejectUpload / rejectDialog 会兜底提示，不会真的把脏数据上传出去。
    function triggerQuickUploadForCurrentTab() {
        root._quickUploadInProgress = true
        _performUpload()
    }


    // 上传主流程：与 uploadBtn.onClicked 完全等价，抽出来是为了让
    // "外部一键上传入口（Main.qml 的📤按钮）"和"评分数据面板内的上传按钮"
    // 共用同一段校验/派发逻辑；任何一处扩展新校验都对两个入口自动生效。
    // ══════════════════════════════════════════════════════════════════
    // 归档核心逻辑（可复用）：把 picked 这些文件夹的评分记录归档到
    //   archive/<mode>/<batchName>/ 目录，并把 checklist 一并写入 checklist.json。
    //
    // 抽成函数是为了让两处共用：
    //   1) 手动点「归档」按钮（confirmArchiveDialog.onAccepted）
    //   2) 上传到云端成功后自动归档（onUploadFinished 的 ok 分支）
    // 返回归档后的批次名；失败返回 ""（不抛异常，由调用方决定提示方式）。
    //
    // 注意：archiveByFolders 会把主 CSV 里这些记录移走（主 CSV 瘦身），
    //       所以 checklist 必须在调用【之前】收集，否则数据已随记录迁走。
    // ══════════════════════════════════════════════════════════════════
    // overwrite=true 时覆盖写同名批次（用于重复上传同一 tag：刷新归档快照），
    // 不追加 _N 序号；false 时保持原"同名加序号"防覆盖行为（手动归档用）。
    function _archiveFolders(picked, batchName, overwrite) {
        if (typeof Rating === "undefined") return ""
        if (!picked || picked.length === 0) return ""

        // ── 归档前：先收集这些文件夹下所有文件的 checklist 数据 ──
        var checklistSnapshot = {}
        try {
            var allRows = ((typeof Rating.getAllRatingsForMode === "function")
                            ? Rating.getAllRatingsForMode(root._selectedMode)
                            : Rating.getAllRatings()) || []
            var pickedSet = {}
            for (var pi = 0; pi < picked.length; ++pi) {
                var pf = picked[pi].replace(/\/+$/, "")   // 规整路径（去末尾斜杠）
                pickedSet[pf] = true
            }
            for (var ri = 0; ri < allRows.length; ++ri) {
                var row = allRows[ri] || {}
                var fp = row["file_path"] || ""
                if (!fp) continue
                var dir = fp.substring(0, fp.lastIndexOf("/"))
                if (!pickedSet[dir]) continue
                var ckRaw = Rating.loadString("checklist:" + fp, "")
                if (ckRaw && ckRaw.length > 0) {
                    try { checklistSnapshot[fp] = JSON.parse(ckRaw) } catch(e) {}
                }
            }
        } catch(e) { checklistSnapshot = {} }

        // 显式传入弹窗当前查看的 mode（方案 C 下弹窗内切模式不回写全局
        // Rating.currentMode，不传就会按全局 off 被拒绝）
        var ok = Rating.archiveByFolders(picked, batchName, root._selectedMode,
                                        overwrite === true)
        if (!ok) return ""

        var batch = ""
        try {
            var batchList = Rating.listArchiveBatches(root._selectedMode) || []
            // listArchiveBatches 按修改时间倒序，第一个就是刚归档的
            if (batchList.length > 0) batch = batchList[0]["name"] || ""
        } catch(e) {}

        root._checkedFolders = ({})   // 归档后清勾选，避免误操作再删一次

        // ── 归档后：把 checklist 写入批次目录下的 checklist.json ──
        try {
            if (Object.keys(checklistSnapshot).length > 0
                    && typeof Fs !== "undefined"
                    && typeof Fs.writeTextFile === "function"
                    && batch.length > 0) {
                var dfp = ((typeof Rating.dataFilePathForMode === "function")
                            ? Rating.dataFilePathForMode(root._selectedMode)
                            : (Rating.dataFilePath || "")) || ""
                var baseDir = dfp.substring(0, dfp.lastIndexOf("/"))
                var mode = root._selectedMode || ""
                if (baseDir && mode) {
                    var ckPath = baseDir + "/archive/" + mode + "/" + batch + "/checklist.json"
                    Fs.writeTextFile(ckPath, JSON.stringify(checklistSnapshot, null, 2))
                    console.log("[Archive] checklist.json 已写入:", ckPath)
                }
            }
        } catch(e) {
            console.warn("[Archive] 写入 checklist.json 失败：", e)
        }
        return batch
    }

    // ══════════════════════════════════════════════════════════════════
    // 上传成功后自动归档（对所有上传入口统一生效）
    //
    // 抽成独立函数的原因：上传结果有【两条出口】，都要归档：
    //   1) 面板内上传  → onUploadFinished 里 ok 分支（走 uploadSuccessDialog）
    //   2) 外部一键上传 → onUploadFinished 里 _quickUploadInProgress 分支
    //      （Main.qml 的 📤「上传数据」/「评分数据」按钮），
    //      该分支会【提前 return】交由主窗对话框展示，若不单独调用就会被跳过。
    // 所以两个出口都调本函数，保证"只要上传成功就归档"这一语义不因入口而异。
    //
    // 返回归档批次名；未归档（无需归档/归档失败/无勾选）返回 ""。
    // ══════════════════════════════════════════════════════════════════
    // 取得当前上传 tag（归档 csv 的 group 段即 tag，用同一真数据源保证一致）
    function _currentUploadTag() {
        var t = ""
        try {
            if (typeof tagField !== "undefined" && tagField.text)
                t = String(tagField.text).trim()
            if (t.length === 0 && typeof Rating !== "undefined" && Rating.uploadGroup)
                t = String(Rating.uploadGroup).trim()
        } catch (e) {}
        return t
    }

    function _autoArchiveAfterUpload() {
        // 无论数据来源是"当前 Tab"还是"归档批次"，上传成功都触发归档。
        //
        // 归档来源也归档的原因：重复上传前用户可能改过内容（重新评过分），
        // 需要把最新内容刷新回归档快照，而不是让归档停留在旧版本。
        //
        // 批次名固定 = tag（不再用时间戳），配合 overwrite=true 覆盖写，
        // 因此同一 tag 永远只有一个归档目录，重复上传只刷新它、不堆新目录。
        var tagName = root._currentUploadTag()
        if (tagName.length === 0) {
            console.warn("[Upload] tag 为空 → 跳过自动归档（无法唯一定位归档文件）")
            return ""
        }

        var picked = root._lastUploadFolders
        if (!picked || picked.length === 0) {
            console.warn("[Upload] 上传成功，但无勾选文件夹 → 跳过自动归档")
            return ""
        }
        // 批次名 = tag，overwrite=true → 覆盖写该 tag 对应的唯一归档快照
        var batch = root._archiveFolders(picked, tagName, true)

        // 幂等兜底：纯重复上传（数据来自归档、主 CSV 里这批已被移走）时，
        // archiveByFolders 从主 CSV 捞不到记录会返回 ""。此时该 tag 的归档
        // 快照内容就是刚上传的内容，已是最新，无需重写，直接沿用即可。
        if ((!batch || batch.length === 0) && root._lastUploadKind === "archive") {
            try {
                var bl = Rating.listArchiveBatches(root._selectedMode) || []
                for (var i = 0; i < bl.length; ++i) {
                    if (String((bl[i] || {})["name"] || "") === tagName) {
                        console.log("[Upload] 归档已是最新快照，跳过重写:", tagName)
                        batch = tagName
                        break
                    }
                }
            } catch (e) {}
        }

        if (batch && batch.length > 0) {
            root._lastArchivedMode  = root._selectedMode
            root._lastArchivedBatch = batch
            root._refreshArchiveList(false)
            // 归档移走了主 CSV 记录，当前表格必须重刷，
            // 否则关掉弹窗后仍看到已被归档走的旧数据
            root._refresh()
            console.log("[Upload] 上传成功 → 已自动归档批次:", batch)
        } else {
            console.warn("[Upload] 上传成功，但自动归档失败（数据仍在当前列表）")
        }
        return batch || ""
    }

    function _performUpload() {
        console.log("[QuickUpload] _performUpload() start")
        if (typeof Rating === "undefined") { console.log("[QuickUpload] Rating undefined, abort"); root._quickUploadInProgress = false; return }
        // 防御性兜底：把焦点中的输入框（tag / 评分人）强制提交，
        // 避免"刚改完 tag 直接点上传"时旧值仍在使用。
        if (typeof userField !== "undefined" && userField.activeFocus) userField.focus = false
        if (typeof tagField  !== "undefined" && tagField.activeFocus)  tagField.focus  = false

        // ── 上传前必填校验：评分人 + 备注 tag ───────────────────
        // 外部一键上传入口（面板未打开）时，userField/tagField 仍存在
        // （Dialog 一加载就实例化），所以照旧读它们的 text。
        var raterText = (typeof userField !== "undefined") ? userField.text.trim() : ""
        var tagText   = (typeof tagField  !== "undefined") ? tagField.text.trim()  : ""
        // 兜底：如果 UI 输入框还没被填过（例如首次进入直接从外部一键上传），
        // 就退回 Rating.currentUser / Rating.uploadTag（真数据源）。
        if (raterText.length === 0 && Rating.currentUser)
            raterText = String(Rating.currentUser).trim()
        if (tagText.length === 0 && Rating.uploadTag)
            tagText = String(Rating.uploadTag).trim()
        console.log("[QuickUpload] rater=", raterText, "tag=", tagText)

        // 辅助：外部一键上传遇到校验失败时，展开面板让用户修改，
        // 并把外部标志清掉（免得后续弹窗被误路由）。
        function _fallbackToPanel() {
            if (root._quickUploadInProgress) {
                root._quickUploadInProgress = false
                if (!root.visible) {
                    root.show()
                    root.raise()
                    root.requestActivate()
                }
            }
        }

        if (raterText.length === 0) {
            console.log("[QuickUpload] rater empty → reject")
            _fallbackToPanel()
            root._rejectUpload(
                qsTr("「评分人」为必填项，未填写将无法识别上传来源。\n请在顶部「评分人 *」输入框填写后再点上传。"),
                (typeof userField !== "undefined" ? userField : null), "user")
            return
        }
        if (tagText.length === 0) {
            console.log("[QuickUpload] tag empty → reject")
            _fallbackToPanel()
            root._rejectUpload(
                qsTr("「备注 tag」为必填项，用于在云端区分同一评分人的多次上传。\n请在顶部「备注 tag *」输入框填写后再点上传。"),
                (typeof tagField !== "undefined" ? tagField : null), "tag")
            return
        }
        // 校验通过：把评分人值落库
        if (Rating.currentUser !== raterText) Rating.currentUser = raterText

        // ── 必须至少勾选一个文件夹再上传
        var picked = _collectCheckedFolderPaths()
        // 用户面板内的真实勾选状态（归档回退填充【前】采样）。
        // 非空 = 用户明确勾选了要上传的文件夹，属于明确的当前视图上传意图，
        // 绝不允许被上次归档上传残留的 _lastUploadKind/_lastUploadArchiveBatch
        // 误路由到归档上传通路（该通路按归档 CSV 过滤当前文件夹 → 捞不到数据
        // → 静默失败，表现为"点上传没反应、也没有 409 覆盖确认弹窗"）。
        var _hadChecked = picked.length > 0

        // 归档回退（外部一键上传 previewCurrentUpload() 设置的回退态）：
        // 仅当"用户无勾选 + 上次上传来自归档 + 批次名非空"时才成立。
        var _archiveMode = (!_hadChecked
                            && root._lastUploadKind === "archive"
                            && root._lastUploadArchiveBatch.length > 0)
        if (_archiveMode) {
            if (root._lastUploadFolders.length > 0) {
                picked = root._lastUploadFolders
                console.log("[QuickUpload] 归档回退：使用批次",
                            root._lastUploadArchiveBatch, "文件夹数:", picked.length)
            } else {
                console.log("[QuickUpload] 归档批次全量上传：",
                            root._lastUploadArchiveBatch, "（不限文件夹）")
            }
        }

        console.log("[QuickUpload] picked.length=", picked.length,
                    "_folders.length=", _folders.length,
                    "checkedCount=", _checkedFolderCount())
        if (picked.length === 0 && !_archiveMode) {
            console.log("[QuickUpload] picked empty → reject")
            _fallbackToPanel()
            rejectDialog.openWith(
                qsTr("无法上传到云端"),
                qsTr("还没有勾选任何文件夹，无法确定要上传哪些评分记录。\n请在列表里至少勾选一个文件夹后再点上传。"))
            return
        }

        // ── 未评完拦截：归档 Tab 与当前 Tab 一致都走
        // 归档回退模式下数据是归档快照（已评完），无需再查 incomplete
        var incomplete = (root._lastUploadKind === "archive" && !_hadChecked)
                         ? [] : _collectCheckedIncomplete()
        if (incomplete.length > 0) {
            console.log("[QuickUpload] incomplete → openWith incompleteUploadDialog")
            _fallbackToPanel()
            incompleteUploadDialog.openWith(incomplete)
            return
        }
        // 归档 Tab：不再依赖单个 _archiveBatch，改为检查多 tag 文件树中是否有勾选
        // 缓存本次勾选 + 上传来源
        // 归档回退态（_lastUploadKind=="archive" 且已有批次名）保持不变，
        // 不要被 _isArchiveView（面板是否停在归档 Tab）覆盖。
        // 注意：与上方 _archiveMode 一致，加上 !_hadChecked 约束——
        // 用户在面板里勾选了文件夹时永远按"当前视图"走，杜绝状态残留误路由。
        var _isArchiveFallback = (!_hadChecked
                                  && root._lastUploadKind === "archive"
                                  && root._lastUploadArchiveBatch.length > 0)
        root._lastUploadFolders = picked
        if (!_isArchiveFallback) {
            root._lastUploadKind = root._isArchiveView ? "archive" : "current"
            root._lastUploadArchiveBatch = root._isArchiveView ? root._archiveBatch : ""
            root._lastUploadArchiveMode = root._isArchiveView ? root._selectedMode : ""
        }

        // ── tag 与远程激活配置校验 ──
        if (root.remoteTag.length > 0 && tagText !== root.remoteTag) {
            console.log("[QuickUpload] tag mismatch remote=", root.remoteTag, "→ open tagMismatchDialog")
            _fallbackToPanel()
            tagMismatchDialog.open()
            return
        }

        if (!Rating.uploadServerUrl || Rating.uploadServerUrl.length === 0) {
            console.log("[QuickUpload] uploadServerUrl empty → open uploadConfigDialog")
            _fallbackToPanel()
            uploadConfigDialog.open()
        } else if (root._isArchiveView || _isArchiveFallback) {
            // 归档视图：按 tag 分组已勾选文件夹，对每个 tag 分别上传
            // 构建 tag → 已勾选文件夹路径的映射
            var tagPickedMap = {}
            for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
                var tag = _archiveTagFolders[ti]
                var tagPicked = []
                for (var fi = 0; fi < tag.folders.length; ++fi) {
                    var fd = tag.folders[fi]
                    if (_isFolderChecked(fd.key) && fd.path && fd.path.length > 0) {
                        tagPicked.push(fd.path)
                    }
                }
                if (tagPicked.length > 0) {
                    tagPickedMap[tag.name] = { mode: tag.mode, paths: tagPicked }
                }
            }
            // 归档回退态：使用缓存值
            if (_isArchiveFallback) {
                var _batchToUpload = root._lastUploadArchiveBatch
                var _modeToUpload = root._lastUploadArchiveMode || root._selectedMode
                console.log("[QuickUpload] → uploadArchiveBatchToCloud (fallback), mode=", _modeToUpload,
                            "batch=", _batchToUpload)
                Rating.uploadArchiveBatchToCloud(
                    _modeToUpload,
                    _batchToUpload,
                    false, picked)
            } else {
                // 对每个有勾选文件夹的 tag 分别调用上传
                var tagNames = Object.keys(tagPickedMap)
                if (tagNames.length === 0) {
                    console.log("[QuickUpload] archive view: no checked folders → reject")
                    _fallbackToPanel()
                    rejectDialog.openWith(
                        qsTr("无法上传到云端"),
                        qsTr("还没有勾选任何文件夹，无法确定要上传哪些评分记录。
请在列表里至少勾选一个文件夹后再点上传。"))
                    return
                }
                // 保存多 tag 映射，供覆盖上传重发使用
                root._lastUploadTagPickedMap = tagPickedMap
                // 构建串行上传队列，逐个发送避免 m_uploading 互斥
                root._serialUploadQueue = []
                for (var tn = 0; tn < tagNames.length; ++tn) {
                    var tname = tagNames[tn]
                    var tinfo = tagPickedMap[tname]
                    root._serialUploadQueue.push({ mode: tinfo.mode, name: tname, paths: tinfo.paths })
                }
                root._serialUploadIndex = 0
                root._serialUploadForce = false
                root._sendNextSerialUpload()
            }
        } else {
            console.log("[QuickUpload] → Rating.uploadToCloud(false, picked)")
            Rating.uploadToCloud(false, picked)
        }
    }

    function _refresh() {
        var raw
        if (root._viewMode === "archive") {
            // 先确保批次列表是最新的。
            //
            // 必须 keepSelection=true：本函数会在"切换批次 / 切 Tab / 删行"之后被
            // 立刻调用，若传 false 会把用户刚选中的 _archiveBatch 强行打回
            // list[0]（最新一批），表现为"归档批次下拉点了切不动、永远停在第一个"。
            // 选中项失效（被删掉）的兜底由 _refreshArchiveList 内部处理。
            _refreshArchiveList(true)
            // 归档 Tab 改为 tag 文件树：加载所有批次的数据，每条记录带上
            // _archiveBatch / _archiveBatchMode 标记，供 _buildFoldersFromRows
            // 在文件夹之上构建 tag 层级。
            raw = []
            if (typeof Rating !== "undefined" && root._archiveBatches.length > 0) {
                for (var bi = 0; bi < root._archiveBatches.length; ++bi) {
                    var b = root._archiveBatches[bi]
                    var bMode = b.mode || root._selectedMode
                    var bName = b.name || ""
                    if (bName.length === 0) continue
                    // 只加载当前 _selectedMode 的批次（_refreshArchiveList 已按模式过滤，
                    // 此处再兜底一次，防止 _archiveBatches 被外部直接赋值绕过过滤）
                    if (bMode !== root._selectedMode) continue
                    var bRows = Rating.loadArchiveBatch(bMode, bName) || []
                    for (var br = 0; br < bRows.length; ++br) {
                        var rr = {}
                        for (var rk in bRows[br]) rr[rk] = bRows[br][rk]
                        rr._archiveBatch     = bName
                        rr._archiveBatchMode = bMode
                        raw.push(rr)
                    }
                }
            }
        } else {
            raw = (typeof Rating !== "undefined")
                    ? ((typeof Rating.getAllRatingsForMode === "function")
                        ? Rating.getAllRatingsForMode(root._selectedMode)
                        : Rating.getAllRatings())
                    : []
            // quality_slide 模式：按 slide_type 分组打 _source 标记
            //   · slide_type == "multi_<slideDimKey>"（新格式）或 == "slide"（旧格式）→ 滑动打分
            //   · 其他                                                              → 普通打分
            if ((typeof Rating !== "undefined") && root._selectedMode === "quality_slide") {
                var slideMultiTag = (root.slideDimKey && root.slideDimKey.length > 0)
                    ? ("multi_" + root.slideDimKey) : ""
                for (var ni = 0; ni < raw.length; ++ni) {
                    var nr = {}
                    for (var nk in raw[ni]) nr[nk] = raw[ni][nk]
                    var stVal = String(nr.slide_type || "")
                    var isSlide = (stVal === "slide") ||
                                  (slideMultiTag.length > 0 && stVal === slideMultiTag)
                    nr._source = isSlide ? "slide" : "normal"
                    raw[ni] = nr
                }
            }
        }
        _rows = _applySort(raw || [])
        _rebuildGroups()
    }
    // 重新拉取归档批次列表；keepSelection=true 表示沿用 _archiveBatch（前提是它仍存在），
    // false 时若当前选中失效则自动落到第一项。
    function _refreshArchiveList(keepSelection) {
        if (typeof Rating === "undefined") {
            root._archiveBatches = []; root._archiveBatch = ""; root._archiveBatchMode = ""; return
        }
        // 按当前 _selectedMode 过滤，只展示对应模式的归档批次
        var list = (typeof Rating.listArchiveBatches === "function")
                   ? (Rating.listArchiveBatches(root._selectedMode) || [])
                   : []
        root._archiveBatches = list
        // 选中项是否仍在列表中
        var stillThere = false
        for (var i = 0; i < list.length; ++i) {
            if (list[i].name === root._archiveBatch) { stillThere = true; break }
        }
        if (!stillThere) {
            // 选中项已失效（批次被删 / 首次进入 / 手动指定了空值）→ 落到最新一批
            root._archiveBatch = (list.length > 0) ? list[0].name : ""
            root._archiveBatchMode = (list.length > 0) ? (list[0].mode || root._selectedMode) : ""
        } else if (!keepSelection && list.length > 0) {
            // 仅"显式要求重选"（如首次切到归档 Tab、刚归档完）才落到最新一批
            root._archiveBatch = list[0].name
            root._archiveBatchMode = list[0].mode || root._selectedMode
        }
        // 兜底：选中项有效但 mode 为空（老数据）时补上，避免后续操作传空 mode
        if (root._archiveBatch.length > 0 && root._archiveBatchMode.length === 0) {
            for (var k = 0; k < list.length; ++k) {
                if (list[k].name === root._archiveBatch) {
                    root._archiveBatchMode = list[k].mode || root._selectedMode
                    break
                }
            }
            if (root._archiveBatchMode.length === 0) root._archiveBatchMode = root._selectedMode
        }
        // keepSelection=true 且选中项仍有效 → 原样保留，不动用户的切换结果
    }
    // 切换视图模式（current ↔ archive）；切换时清掉勾选、上传白名单缓存，避免跨 Tab 残留
    function _switchView(mode) {
        if (mode === root._viewMode) return
        root._viewMode = mode
        root._checkedFolders = ({})
        root._lastUploadFolders = []
        if (mode === "archive") _refreshArchiveList(false)
        _refresh()
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
            // 打开时从全局同步一次查看模式；之后弹窗内切胶囊
            // 完全不会回写 Rating.currentMode（方案 C：严格只读）。
            if (typeof Rating !== "undefined") _selectedMode = Rating.currentMode
            // 归档列表跨 mode 且与当前视图无关，打开时【无条件预刷一次】：
            // 原先只有 _viewMode==="archive" 时 _refresh() 才会刷归档列表，
            // 而刚启动默认停在"当前"Tab，导致归档 Tab 计数/下拉显示为
            // "（无归档批次）"，必须切一次 Tab 或评一次分才刷出来。
            _refreshArchiveList(true)
            _refresh()
        }
    }

    Connections {
        target: (typeof Rating !== "undefined") ? Rating : null
        ignoreUnknownSignals: true
        function onChanged() { root._refresh() }
        // 外部模式切换：仅在弹窗不可见时同步 _selectedMode（避免弹窗打开
        // 期间外部或其他组件意外写入 currentMode 污染用户选中的胶囊）。
        // 弹窗打开后的胶囊切换不会触发此信号（方案 C 不写全局）。
        function onCurrentModeChanged() {
            if (!root.visible) {
                root._selectedMode = Rating.currentMode
                root._refresh()
            }
        }
    }

    // ── 总体布局：上(配置区) / 中(表格) / 下(操作栏) ────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        // ── 标题行（标题 + 关闭按钮）────
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
            // 右上角关闭按钮
            Rectangle {
                width: 26; height: 26
                radius: 13
                color: closeTitleMA.containsMouse ? "#3a3a44" : "transparent"
                border.color: closeTitleMA.containsMouse ? "#5a5a66" : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: closeTitleMA.containsMouse ? "#ffffff" : "#9aa0a6"
                    font.pixelSize: 13
                }
                MouseArea {
                    id: closeTitleMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.close()
                }
            }
        }

        // ── 次级 Tab：当前 / 归档 + 模式切换器 ─────────────────────────────────────────
        // 设计动机：归档批次承载"打分快照"，与当前评分账本逻辑分离。
        // 同一文件夹可被归档多次（重新打分前先归档），归档区按"批次文件夹"分桶展示。
        // 当前 Tab：可读写，可勾选/上传/归档/删除（保持原行为）
        // 归档 Tab：只读账本，可导出/行级删除/删整批
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // 「当前 / 归档」分段切换器
            Row {
                spacing: 0
                Repeater {
                    model: [
                        { id: "current", label: qsTr("当前") },
                        { id: "archive", label: qsTr("归档") }
                    ]
                    delegate: Rectangle {
                        property var tabData: modelData
                        property bool selected: root._viewMode === tabData.id
                        property int  archCount: tabData.id === "archive" ? root._archiveBatches.length : 0
                        radius: 0
                        // 第一个左圆角，最后一个右圆角，中间方角
                        Component.onCompleted: {
                            if (index === 0) { topLeftRadius = 6; bottomLeftRadius = 6 }
                            if (index === 1) { topRightRadius = 6; bottomRightRadius = 6 }
                        }
                        height: 28
                        implicitWidth: tabLabel.implicitWidth + 26
                        color: selected ? "#3a3a44"
                              : tabMA.containsMouse ? "#2c2c34"
                                                    : "#222226"
                        border.color: selected ? "#5a5a66" : "#3a3a42"
                        border.width: 1
                        Text {
                            id: tabLabel
                            anchors.centerIn: parent
                            text: tabData.id === "archive" && archCount > 0
                                  ? tabData.label + "（" + archCount + "）"
                                  : tabData.label
                            color: selected ? "#ffffff" : "#cfcfd4"
                            font.pixelSize: 12
                            font.bold: selected
                        }
                        MouseArea {
                            id: tabMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._switchView(tabData.id)
                        }
                    }
                }
            }

            // 模式切换器：紧接当前/归档按钮右侧
            Row {
                spacing: 6
                leftPadding: 4
                Repeater {
                    model: root._visibleModeList
                    delegate: Rectangle {
                        property var modeData: modelData
                        property bool selected: root._selectedMode === modeData.id
                        radius: 14
                        height: 26
                        implicitWidth: modeLbl.implicitWidth + 22
                        color: selected ? "#0fa085"
                              : modeSwitchMA.containsMouse ? "#2c2c34"
                                                           : "#222226"
                        border.color: selected ? "#0fa085" : "#3a3a42"
                        border.width: 1
                        Text {
                            id: modeLbl
                            anchors.centerIn: parent
                            text: {
                                var t = modeData.label || ""
                                var p = t.indexOf("（")
                                if (p >= 0) t = t.substring(0, p)
                                return t.trim()
                            }
                            color: selected ? "#ffffff" : "#cfcfd4"
                            font.pixelSize: 12
                            font.bold: selected
                        }
                        MouseArea {
                            id: modeSwitchMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root._selectedMode !== modeData.id) {
                                    root._selectedMode = modeData.id
                                    if (root._viewMode === "archive") root._refreshArchiveList(false)
                                    root._refresh()
                                }
                            }
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

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
                    // 避免"改完 tag 直接点上传按钮，但首次点击还在用旧值"的时序问题
                    // （旧逻辑只在 editingFinished 即失焦/回车时才同步）。
                    onTextChanged: {
                        if (typeof Rating !== "undefined"
                                && Rating.uploadTag !== text.trim()) {
                            Rating.uploadTag = text.trim()
                        }
                        // 用户开始输入即清掉无效态
                        if (root._invalidTag && text.trim().length > 0) root._invalidTag = false
                        // 归档 Tab 下：用户手动编辑（有焦点时）则关闭自动同步，
                        // 下次勾选变化时 _syncTagFieldFromChecked 会重新接管。
                        if (root._isArchiveView && tagField.activeFocus) {
                            root._tagAutoSync = false
                        }
                        // 当前 Tab：实时更新虚拟 tag 树的名称（使树标题跟随输入）
                        if (!root._isArchiveView && root._curTagFolders.length > 0) {
                            var newName = text.trim()
                            if (newName.length > 0 && root._curTagFolders[0].name !== newName) {
                                var updated = []
                                for (var xi = 0; xi < root._curTagFolders.length; ++xi) {
                                    var xt = root._curTagFolders[xi]
                                    updated.push({
                                        key: "tag:" + newName,
                                        name: newName,
                                        mode: xt.mode,
                                        count: xt.count,
                                        latest: xt.latest,
                                        totalItems: xt.totalItems,
                                        folders: xt.folders
                                    })
                                }
                                root._curTagFolders = updated
                                root._rebuildVisibleRows()
                            }
                        }
                    }
                    // 远程配置热更新后，Rating.uploadTag 会被外部改写，
                    // 但 TextField.text 的 QML 绑定在用户首次输入后已断开（binding break），
                    // 需要通过信号监听主动刷新，否则输入框永远显示旧 tag。
                    Connections {
                        target: (typeof Rating !== "undefined") ? Rating : null
                        function onUploadConfigChanged() {
                            if (typeof Rating !== "undefined"
                                    && tagField.text !== Rating.uploadTag) {
                                tagField.text = Rating.uploadTag
                            }
                        }
                    }
                }                Text {
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
                    text: (typeof Rating !== "undefined")
                            ? ((typeof Rating.dataFilePathForMode === "function")
                                ? Rating.dataFilePathForMode(root._selectedMode)
                                : Rating.dataFilePath)
                            : ""
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

        // ── 工具栏行 ──
        // 原「共 N 个文件夹 · N 个文件 · N 条记录 · 已勾选 N/N」统计文字已移除（不再需要），
        // 「刷新」按钮及其 onClicked 一并移除（数据仍由打开弹窗 / Rating.changed 等
        //  10 处 _refresh() 内部调用自动刷新，不依赖手动按钮）。
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Item { Layout.fillWidth: true }
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
                visible: root._isArchiveView
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
                anchors.top: header.visible ? header.bottom : parent.top
                anchors.bottom: parent.bottom
                anchors.margins: 1
                clip: true
                model: root._visibleRows
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Loader {
                    id: rowLoader
                    width: listView.width
                    sourceComponent: modelData.kind === "section" ? sectionRowComp
                                   : modelData.kind === "tag"     ? tagRowComp
                                   : modelData.kind === "folder"  ? folderRowComp
                                   : modelData.kind === "file"    ? fileRowComp
                                                                   : itemRowComp
                    // 把当前行数据与索引推送给 sourceComponent 实例；
                    // Component 内部通过 parent.rowData / parent.rowIndex 读取。
                    property var rowData: modelData
                    property int rowIndex: index
}

                // 空状态
                Text {
                    anchors.centerIn: parent
                    visible: (root._isArchiveView
                                ? root._archiveTagFolders.length === 0
                                : root._folders.length === 0 && root._slideFolders.length === 0)
                    text: root._isArchiveView
                          ? qsTr("暂无归档批次\n在「当前」Tab 勾选文件夹后点「📦 归档勾选」即可创建")
                          : qsTr("暂无评分数据\n在视频窗的 ⋯ 菜单中选择星级即可记录")
                    horizontalAlignment: Text.AlignHCenter
                    color: "#6a6a72"
                    font.pixelSize: 12
                }
            }

            // ── 归档 Tag 行（归档 Tab 下的顶层节点，可展开/折叠）─────
            Component {
                id: tagRowComp
                Rectangle {
                    id: tagRoot
                    height: 32
                    width: parent ? parent.width : 0
                    color: tagMA.containsMouse ? "#2c2c34" : "#1e1e26"
                    Behavior on color { ColorAnimation { duration: 120 } }

                    property var d: parent.rowData ? parent.rowData.d : null
                    property bool open: d ? !!root._expanded[d.key] : false

                    // 左侧强调条（蓝紫色，区别于文件夹的蓝色）
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 3
                        color: "#7c3aed"
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
                            Text {
                                width: 14
                                horizontalAlignment: Text.AlignHCenter
                                text: tagRoot.open ? "▾" : "▸"
                                color: "#cfcfd4"
                                font.pixelSize: 13
                            }
                            Text {
                                text: tagRoot.d ? (tagRoot.d.name + "  " + (tagRoot.d.totalItems || 0) + "条") : ""
                                color: "#ffffff"
                                font.pixelSize: 13
                                font.bold: true
                                elide: Text.ElideMiddle
                                width: Math.max(0, parent.width - 14 - 6)
                            }
                        }
                    }
                    // 最新时间
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: parent.width - 220 - 90 + 8
                        width: 220 - 16
                        text: tagRoot.d
                              ? (tagRoot.d.latest || "").replace("T", " ").substring(0, 19)
                              : ""
                        color: "#dcdcde"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    // 右侧区域：勾选框 + 模式·N条 + 打开文件夹图标
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        spacing: 8
                        // 勾选框
                        Item {
                            id: tagCheck
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18
                            property bool allChecked: {
                                if (!tagRoot.d) return false
                                var fds = tagRoot.d.folders
                                if (!fds || fds.length === 0) return false
                                for (var i = 0; i < fds.length; ++i) {
                                    if (!root._isFolderChecked(fds[i].key)) return false
                                }
                                return true
                            }
                            Rectangle {
                                anchors.fill: parent
                                radius: 4
                                color: tagCheck.allChecked ? "#3a7afe"
                                                           : (tagCheckMA.containsMouse ? "#3a3a44" : "#2a2a32")
                                border.width: 1
                                border.color: tagCheck.allChecked ? "#3a7afe"
                                                                  : (tagCheckMA.containsMouse ? "#5a5a66" : "#4a4a54")
                                Behavior on color       { ColorAnimation { duration: 100 } }
                                Behavior on border.color { ColorAnimation { duration: 100 } }
                                Text {
                                    anchors.centerIn: parent
                                    text: "✓"
                                    color: "#ffffff"
                                    font.pixelSize: 13
                                    font.bold: true
                                    visible: tagCheck.allChecked
                                }
                            }
                            MouseArea {
                                id: tagCheckMA
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton
                                propagateComposedEvents: false
                                onPressed: function(mouse) { mouse.accepted = true }
                                onClicked: function(mouse) {
                                    mouse.accepted = true
                                    if (!tagRoot.d) return
                                    var fds = tagRoot.d.folders
                                    var setTo = !tagCheck.allChecked
                                    for (var i = 0; i < fds.length; ++i) {
                                        root._setFolderChecked(fds[i].key, setTo)
                                    }
                                }
                                ToolTip.visible: containsMouse
                                ToolTip.delay: 600
                                ToolTip.text: tagCheck.allChecked ? qsTr("取消勾选该批次")
                                                                  : qsTr("勾选该批次")
                            }
                        }
                        // 打开所在文件夹（仅图标）
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "📂"
                            font.pixelSize: 14
                            color: openTagDirMA.containsMouse ? "#8ad4ff" : "#6a8a9a"
                            MouseArea {
                                id: openTagDirMA
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                propagateComposedEvents: false
                                onPressed: function(mouse) { mouse.accepted = true }
                                onClicked: function(mouse) {
                                    mouse.accepted = true
                                    if (tagRoot.d && typeof Rating !== "undefined"
                                            && typeof Rating.revealArchiveBatch === "function")
                                        Rating.revealArchiveBatch(tagRoot.d.mode, tagRoot.d.name)
                                }
                            }
                            ToolTip.visible: openTagDirMA.containsMouse
                            ToolTip.delay: 600
                            ToolTip.text: qsTr("在文件夹中显示")
                        }
                    }

                    // 底部分隔线
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: "#2a2a36"
                    }

                    MouseArea {
                        id: tagMA
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.rightMargin: 90  // 右侧 90px 留给勾选框+📂图标，不触发展开
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { if (tagRoot.d) root._toggleKey(tagRoot.d.key) }
                    }
                }
            }

            // ── 零级：分组标题行（quality_slide 模式下区分普通打分 / 滑动打分）─────
            Component {
                id: sectionRowComp
                Rectangle {
                    height: 26
                    width: parent ? parent.width : 0
                    color: "#1e1e26"
                    property var rowData: parent ? parent.rowData : null
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        spacing: 0
                        // 左侧强调色竖线
                        Rectangle {
                            width: 3; height: 14
                            radius: 2
                            color: "#3a7afe"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Item { width: 7; height: 1 }
                        Text {
                            text: rowData ? (rowData.label || "") : ""
                            color: "#a0a8c0"
                            font.pixelSize: 11
                            font.weight: Font.Medium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    // 底部分隔线
                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 1
                        color: "#2a2a36"
                    }
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
                    // 汇总（右侧操作区，仅文字）
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        spacing: 6

                        // 汇总文字
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 90
                            text: {
                                if (!folderRoot.d) return ""
                                var d = folderRoot.d
                                var rated = (d.ratedCount === undefined ? d.files.length : d.ratedCount)
                                var total = (d.totalVideos === undefined ? rated : d.totalVideos)
                                var ckMiss = d.ckMissing || 0
                                var head = (d.fullyRated ? "✓ " : "⚠ ") + rated + "/" + total
                                var tail = " · " + d.totalItems + "条"
                                    + (d.avg > 0 ? " · " + d.avg + "★" : "")
                                if (ckMiss > 0) tail += " · ☐" + ckMiss
                                return head + tail
                            }
                            color: folderRoot.d
                                    ? (folderRoot.d.fullyRated ? "#5fd17a" : "#ffb05c")
                                    : "#cfcfd4"
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            ToolTip.visible: _sumMA.containsMouse && folderRoot.d !== null
                            ToolTip.delay: 600
                            ToolTip.timeout: 8000
                            ToolTip.text: {
                                var d = folderRoot.d
                                if (!d) return ""
                                var rated = (d.ratedCount === undefined ? d.files.length : d.ratedCount)
                                var total = (d.totalVideos === undefined ? d.files.length : d.totalVideos)
                                var ckMiss = d.ckMissing || 0
                                var base = qsTr("已评分视频：%1 / %2\n评分记录：%3 条\n平均：%4")
                                    .arg(rated).arg(total).arg(d.totalItems)
                                    .arg(d.avg > 0 ? d.avg + " ★" : "—")
                                if (d.fullyRated) return base
                                var missing = []
                                var starLeft = total - rated
                                if (starLeft > 0)
                                    missing.push(qsTr("• 还有 %1 个视频未评分").arg(starLeft))
                                if (ckMiss > 0)
                                    missing.push(qsTr("• 还有 %1 个视频未勾选检查项").arg(ckMiss))
                                if (missing.length === 0) return base
                                return base + "\n\n" + qsTr("⚠ 未完成，无法上传：")
                                        + "\n" + missing.join("\n")
                            }
                            MouseArea {
                                id: _sumMA
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { if (folderRoot.d) root._toggleKey(folderRoot.d.key) }
                            }
                        }

                        // 单独勾选框
                        Item {
                            id: folderCheck
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
                                Behavior on color        { ColorAnimation { duration: 100 } }
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
                                ToolTip.text: folderCheck.checked ? qsTr("取消勾选") : qsTr("勾选此文件夹")
                            }
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
                        // 让出右侧操作区：汇总文字(90) + 间距(6) + 勾选框(18) + 右边距(8) ≈ 122
                        anchors.rightMargin: 122
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

            // 推右：所有按钮靠右对齐
            Item { Layout.fillWidth: true }

            // 全选按钮（仅当前Tab显示）
            Item {
                id: selectAllCheck
                visible: !root._isArchiveView
                anchors.verticalCenter: parent.verticalCenter
                width: 18; height: 18
                property bool allChecked: root._checkedFolderCount() > 0
                property bool hasFolders: root._folders.length > 0
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: selectAllCheck.allChecked ? "#3a7afe"
                                                      : (selectAllCheckMA.containsMouse ? "#3a3a44" : "#2a2a32")
                    border.width: 1
                    border.color: selectAllCheck.allChecked ? "#3a7afe"
                                                             : (selectAllCheckMA.containsMouse ? "#5a5a66" : "#4a4a54")
                    Behavior on color        { ColorAnimation { duration: 100 } }
                    Behavior on border.color { ColorAnimation { duration: 100 } }
                    Text {
                        anchors.centerIn: parent
                        text: "✓"
                        color: "#ffffff"
                        font.pixelSize: 13
                        font.bold: true
                        visible: selectAllCheck.allChecked
                    }
                }
                MouseArea {
                    id: selectAllCheckMA
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    propagateComposedEvents: false
                    enabled: selectAllCheck.hasFolders
                    onPressed: function(mouse) { mouse.accepted = true }
                    onClicked: function(mouse) {
                        mouse.accepted = true
                        root._setAllFoldersChecked(selectAllCheck.allChecked ? false : true)
                    }
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 600
                    ToolTip.text: selectAllCheck.allChecked ? qsTr("全不选") : qsTr("全选")
                }
            }
            PillBtn {
                id: exportBtn
                text: {
                    var _dep1 = root._checkedFolders
                    var _dep2 = root._archiveTagFolders
                    var n = root._checkedFolderCount()
                    return n > 0
                            ? qsTr("📤 导出勾选（%1）").arg(n)
                            : qsTr("📤 导出勾选")
                }
                emphasized: true
                enabled: {
                    var _dep1 = root._checkedFolders
                    var _dep2 = root._archiveTagFolders
                    return root._checkedFolderCount() > 0
                }
                onClicked: {
                    if (root._isArchiveView) {
                        exportArchiveDialog.open()
                    } else {
                        exportDialog.open()
                    }
                }
                Timer {
                    id: exportFlashTimer
                    interval: 1600
                    onTriggered: exportBtn.flash = false
                }
            }
            PillBtn {
                // 与"删除勾选"互补：把已勾选文件夹的评分搬到 archive/<mode>/<batchName>/ 子目录下，
                // 主表里不再显示，但归档 Tab 可查。
                // 改造点：归档前会先弹"批次名输入"对话框，让用户给本次归档命名。
                // 不是 danger 风格，避免和"删除"按钮视觉撞车。
                id: archiveSelectedBtn
                visible: !root._isArchiveView
                text: {
                    var _dep = root._checkedFolders
                    var _dep2 = root._folders
                    var n = root._checkedFolderCount()
                    return n > 0
                            ? qsTr("📦 归档勾选（%1）").arg(n)
                            : qsTr("📦 归档勾选")
                }
                enabled: (root._checkedFolders, root._folders, root._archiveTagFolders, root._checkedFolderCount() > 0)
                onClicked: {
                    // 给输入框填默认批次名（<mode>_yyyyMMdd_HHmmss）
                    if (typeof Rating !== "undefined") {
                        // 默认批次名统一 = 当前 tag（与"上传后自动归档"一致）。
                        // 这样同一 tag 只有一个归档目录，重复归档时覆盖刷新，
                        // 不再每次生成一个 <mode>_时间戳 的新目录。
                        // 用户仍可在输入框里改成自定义名（此时走防覆盖逻辑）。
                        var _t = root._currentUploadTag()
                        confirmArchiveDialog._batchName =
                            (_t.length > 0) ? _t
                                            : Rating.defaultArchiveBatchName(root._selectedMode)
                    } else {
                        confirmArchiveDialog._batchName = ""
                    }
                    confirmArchiveDialog.open()
                }
            }

            // ── 当前 Tab：删除勾选 ──
            PillBtn {
                visible: !root._isArchiveView
                danger: root._checkedFolderCount() > 0
                enabled: (root._checkedFolders, root._checkedFolderCount() > 0)
                text: {
                    var _dep = root._checkedFolders
                    var n = root._checkedFolderCount()
                    return n > 0 ? qsTr("🗑 删除勾选（%1）").arg(n) : qsTr("🗑 删除勾选")
                }
                onClicked: {
                    var n = root._checkedFolderCount()
                    if (n > 0) root._deleteCheckedFolders()
                }
            }

            // ── 归档 Tab：删除勾选（上传勾选左侧）──
            PillBtn {
                visible: root._isArchiveView
                danger: root._checkedFolderCount() > 0
                enabled: (root._checkedFolders, root._archiveTagFolders, root._checkedFolderCount() > 0)
                text: {
                    var _dep1 = root._checkedFolders
                    var _dep2 = root._archiveTagFolders
                    var n = root._checkedFolderCount()
                    return n > 0 ? qsTr("🗑 删除勾选（%1）").arg(n) : qsTr("🗑 删除勾选")
                }
                onClicked: confirmClearDialog.open()
            }

            PillBtn {
                // 当前 Tab 与归档 Tab 都支持云端上传：
                //   ・ 当前 Tab：上传当前主 CSV（与历史行为一致）
                //   ・ 归档 Tab：上传当前选中的批次（archive/<mode>/<batch>/ratings.csv）
                // 网络栈、覆盖确认、信号链路完全共用，差异仅在 onClicked 里的 API 选择。
                visible: true
                // 上传到后端服务器：
                //   ・ 未配置地址时 → 先弹设置对话框让用户填 URL/Token
                //   ・ 配置后点击 → 直接走上传。上传中 disable，避免连点重复提交
                // 鼠标右键 → 进设置对话框，取不到菜单 API 只能用双击代替：双击也走设置
                id: uploadBtn
                text: (typeof Rating !== "undefined" && Rating.uploading)
                      ? qsTr("☁ 上传中…")
                      : qsTr("☁ 上传勾选")
                // ── 启用条件分两层：
                // 1) 真·硬约束（绑定层就置灰，本地直接卡住）：
                //    - 至少勾选 1 个文件夹（picked > 0）
                //    - 勾选的文件夹全部已评完（incomplete == 0；归档批次跳过该约束，
                //      因为归档本身就是"某次评分快照"，业务上视作完整结果）
                //    - 归档 Tab 还要求当前选中了一个有效批次（_archiveBatch 非空）
                // 2) 软约束（点击层兜底拦截）：评分人/备注 tag 必填、网络上传中等
                //    保留 onClicked 中的 _collectCheckedIncomplete() 兜底，避免 binding
                //    没及时刷新时漏拦。
                // 依赖 _checkedFolders / _folders 两个 property 变化触发重算。
                enabled: {
                    var _dep1 = root._checkedFolders
                    var _dep2 = root._folders
                    var _dep3 = root._archiveBatch
                    if (typeof Rating === "undefined") return false
                    if (Rating.uploading) return false
                    if (root._rows.length === 0) return false
                    if (root._checkedFolderCount() === 0) return false
                    // 未评完拦截：归档 Tab 与当前 Tab 一视同仁——
                    // 归档批次也是基于"文件夹完整评分"做云端汇总，半成品上传同样不可信。
                    if (root._collectCheckedIncomplete().length > 0) return false
                    return true
                }
                // 鼠标悬浮看具体原因，避免用户对着灰按钮一脸懵。
                // 注意：PillBtn 内置 MouseArea 在 enabled=false 时会一并禁用 hover 检测，
                // 这里独立挂一个 hoverArea，acceptedButtons=NoButton 不抢点击，仅作 hover 驱动。
                MouseArea {
                    id: uploadHoverArea
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton  // 不吃点击，让 PillBtn 自己的 MouseArea 处理
                    cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                }
                ToolTip.visible: uploadHoverArea.containsMouse && !enabled
                                 && !(typeof Rating !== "undefined" && Rating.uploading)
                ToolTip.delay: 400
                ToolTip.timeout: 6000
                ToolTip.text: {
                    var _dep1 = root._checkedFolders
                    var _dep2 = root._folders
                    var _dep3 = root._archiveTagFolders
                    if (typeof Rating === "undefined") return ""
                    if (Rating.uploading) return ""
                    if (root._rows.length === 0)
                        return qsTr("当前还没有任何评分记录")
                    if (root._checkedFolderCount() === 0)
                        return qsTr("请先在列表里勾选要上传的文件夹")
                    var inc = root._collectCheckedIncomplete()
                    if (inc.length > 0) {
                        // 列出未评完的文件夹（最多 3 个，超出 …）
                        var lines = []
                        for (var i = 0; i < inc.length && i < 3; ++i) {
                            var it = inc[i]
                            var starLeft = (it.totalVideos - it.ratedCount)
                            var reasons = []
                            if (starLeft > 0)
                                reasons.push(it.ratedCount + "/" + it.totalVideos + " 已评分")
                            if (it.ckMissing > 0)
                                reasons.push(it.ckMissing + " 个文件未勾选检查项")
                            lines.push("• " + it.name + "（" + reasons.join("，") + "）")
                        }
                        if (inc.length > 3) lines.push("…还有 " + (inc.length - 3) + " 个")
                        var leadHint = root._isArchiveView
                                ? qsTr("以下勾选的文件夹在该归档批次中尚未评完，无法上传：\n")
                                : qsTr("以下勾选的文件夹尚未评完，无法上传：\n")
                        return leadHint + lines.join("\n")
                    }
                    return ""
                }
                onClicked: {
                    // 上传主流程已抽为 root 上的公共函数 _performUpload()，
                    // 与"外部一键上传入口（Main.qml 的📤按钮）"共用同一段逻辑。
                    root._performUpload()
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
                // "⚙ 设置"：独立入口，避免"双击上传按钮"这种隐藏交互被错过
                // 归档 Tab 同样可见——归档与当前 Tab 共用同一份服务器配置
                visible: true
                text: qsTr("⚙ 上传设置")
                onClicked: uploadConfigDialog.open()
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
            // 命名与服务端上传落盘规则完全一致：<user>__<tag>__<mode>__<yyyy-MM-dd_HH-mm-ss>.csv
            // （见 PlayerX-server src/api/upload.js + src/lib/slug.js 的 safeSlug/tsNow）。
            // 这样本地导出件与云端件同名同规则，人工对账 / 直接补传都不会对不上。
            function safeSlug(raw, fallback) {
                var s = String(raw || "").replace(/[^A-Za-z0-9._\-一-龥]/g, "_").slice(0, 64)
                return s.length > 0 ? s : fallback
            }
            var u = safeSlug(userField.text, "anon")
            var tag = safeSlug(tagField.text, "default")
            var mode = safeSlug(root._selectedMode, "subjective")
            // 时间戳 yyyy-MM-dd_HH-mm-ss（与 tsNow() 同形）
            var d = new Date()
            function pad(n) { return (n < 10 ? "0" : "") + n }
            var ts = d.getFullYear() + "-" + pad(d.getMonth()+1) + "-" + pad(d.getDate())
                   + "_" + pad(d.getHours()) + "-" + pad(d.getMinutes()) + "-" + pad(d.getSeconds())
            var name = u + "__" + tag + "__" + mode + "__" + ts
            // 拼接到下载目录 URL 后面，例如：file:///Users/xxx/Downloads/xxx__tag__mode__ts.csv
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
                    if (root._isArchiveView) {
                        return qsTr("将从归档批次 %1 中删除已勾选 %2 个文件夹下的全部评分（共 %3 条），\n操作不可恢复，是否继续？")
                                .arg(root._archiveBatch).arg(nFolders).arg(nRecs)
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
            if (root._isArchiveView) {
                // 归档 Tab：从 _archiveTagFolders 中收集已勾选文件夹，按 tag 分组删除
                var tagPickedMap = {}
                for (var ti = 0; ti < _archiveTagFolders.length; ++ti) {
                    var tag = _archiveTagFolders[ti]
                    var tagPicked = []
                    for (var fi = 0; fi < tag.folders.length; ++fi) {
                        var fd = tag.folders[fi]
                        if (_isFolderChecked(fd.key) && fd.path && fd.path.length > 0) {
                            tagPicked.push(fd.path)
                        }
                    }
                    if (tagPicked.length > 0) {
                        tagPickedMap[tag.name] = { mode: tag.mode, paths: tagPicked }
                    }
                }
                var tagNames = Object.keys(tagPickedMap)
                if (tagNames.length === 0) {
                    rejectDialog.openWith(qsTr("无法删除"), qsTr("请先勾选至少 1 个文件夹"))
                    return
                }
                var totalDeleted = 0
                for (var tn = 0; tn < tagNames.length; ++tn) {
                    var tname = tagNames[tn]
                    var tinfo = tagPickedMap[tname]
                    // 收集该 tag 下已勾选文件夹中的所有文件路径
                    var fpList = []
                    for (var ti2 = 0; ti2 < _archiveTagFolders.length; ++ti2) {
                        var tag2 = _archiveTagFolders[ti2]
                        if (tag2.name !== tname) continue
                        for (var fi2 = 0; fi2 < tag2.folders.length; ++fi2) {
                            var fd2 = tag2.folders[fi2]
                            if (!_isFolderChecked(fd2.key)) continue
                            for (var gi = 0; gi < fd2.files.length; ++gi) {
                                var g = fd2.files[gi]
                                if (g.path && g.path.length > 0) fpList.push(g.path)
                            }
                        }
                    }
                    var ok = Rating.removeArchiveRows(tinfo.mode, tname, fpList)
                    if (ok) totalDeleted += tinfo.paths.length
                }
                if (totalDeleted > 0) {
                    actionToast.show(true, qsTr("已从归档批次中删除 %1 个文件夹的记录").arg(totalDeleted))
                    root._checkedFolders = ({})
                    root._refreshArchiveList(true)
                } else {
                    actionToast.show(false, qsTr("删除失败"))
                }
                return
            }
            var picked = root._collectCheckedFolderPaths()
            if (picked.length === 0) {
                rejectDialog.openWith(qsTr("无法删除"), qsTr("请先勾选至少 1 个文件夹"))
                return
            }
            var ok = Rating.removeByFolders(picked, root._selectedMode)
            if (ok) {
                actionToast.show(true, qsTr("已删除 %1 个文件夹的评分").arg(picked.length))
            } else {
                actionToast.show(false, qsTr("删除失败：未命中任何记录"))
            }
        }
    }

    // ── 归档确认对话框（与"删除"对称：搬出而不是销毁，主表里看不到但磁盘还在）────
    Dialog {
        id: confirmArchiveDialog
        modal: true
        anchors.centerIn: parent
        width: 460
        padding: 0
        // 输入缓冲区（点击"📦 归档勾选"时由外部填默认时间戳名）
        property string _batchName: ""

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
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: qsTr("归档已勾选文件夹的评分？")
                color: "#f0f0f3"
                font.pixelSize: 14
                font.bold: true
                elide: Text.ElideRight
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
            spacing: 10
            Text {
                id: _archMsg
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 14
                text: {
                    var _dep = root._checkedFolders
                    var _dep2 = root._folders
                    var nFolders = root._checkedFolderCount()
                    var nRecs = 0
                    for (var i = 0; i < root._folders.length; ++i) {
                        var d = root._folders[i]
                        if (root._isFolderChecked(d.key)) nRecs += (d.totalItems || 0)
                    }
                    return qsTr("将把已勾选的 %1 个文件夹下的全部评分（共 %2 条）搬到一个新批次中。\n归档后这部分数据从「当前」表里清除，可在「归档」Tab 下随时查阅。")
                            .arg(nFolders).arg(nRecs)
                }
                color: "#cfcfd4"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }
            // ── 批次名输入框 ────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: 4
                Text {
                    text: qsTr("批次名（可改）")
                    color: "#9aa0a6"
                    font.pixelSize: 11
                }
                TextField {
                    id: archiveBatchField
                    Layout.fillWidth: true
                    text: confirmArchiveDialog._batchName
                    color: "#e8e8ec"
                    placeholderText: qsTr("默认：<模式>_yyyyMMdd_HHmmss")
                    placeholderTextColor: "#6a6a72"
                    selectByMouse: true
                    background: Rectangle {
                        color: "#26262a"
                        border.color: archiveBatchField.activeFocus ? "#3a7afe" : "#3a3a42"
                        border.width: 1
                        radius: 4
                    }
                    onTextChanged: confirmArchiveDialog._batchName = text
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Text {
                        id: archivePathText
                        // 路径中的 <批次名> 跟随输入框实时变化；未填写时回退为默认批次名
                        readonly property string _batchPart: {
                            var t = (archiveBatchField.text || "").trim()
                            return t.length > 0 ? t : (confirmArchiveDialog._batchName || "")
                        }
                        readonly property string _baseDir: (((typeof Rating !== "undefined") && (typeof Rating.dataFilePathForMode === "function"))
                                    ? Rating.dataFilePathForMode(root._selectedMode)
                                    : ((typeof Rating !== "undefined") ? Rating.dataFilePath : ""))
                                   .replace(/\/[^\/]*$/, "")
                        // 完整纯路径（供"复制"按钮用，不含"将存放在："前缀）
                        readonly property string _fullPath: _baseDir + "/archive/" + root._selectedMode + "/" + _batchPart + "/ratings.csv"
                        text: qsTr("将存放在：%1").arg(_fullPath)
                        color: "#6a6a72"
                        font.pixelSize: 10
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    PillBtn {
                        id: copyPathBtn
                        text: qsTr("复制")
                        implicitHeight: 24
                        Layout.preferredWidth: 56
                        onClicked: {
                            copyHelper.text = archivePathText._fullPath
                            copyHelper.selectAll()
                            copyHelper.copy()
                            copyPathBtn.flash = true
                            copyFlashTimer.restart()
                        }
                        Timer {
                            id: copyFlashTimer
                            interval: 1200
                            onTriggered: copyPathBtn.flash = false
                        }
                    }
                }
                // 隐藏的复制辅助元素
                TextEdit {
                    id: copyHelper
                    visible: false
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
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("取消")
                    onClicked: confirmArchiveDialog.reject()
                }
                PillBtn {
                    text: qsTr("确认归档")
                    onClicked: confirmArchiveDialog.accept()
                }
            }
        }

        onAccepted: {
            if (typeof Rating === "undefined") return
            var picked = root._collectCheckedFolderPaths()
            if (picked.length === 0) {
                rejectDialog.openWith(qsTr("无法归档"), qsTr("请先勾选至少 1 个文件夹"))
                return
            }
            var batchInput = (confirmArchiveDialog._batchName || "").trim()

            // 复用统一归档函数（与"上传成功后自动归档"同一套逻辑：
            // 收集 checklist → 调 archiveByFolders → 写 checklist.json）
            var batch = root._archiveFolders(picked, batchInput)
            if (batch.length > 0) {
                actionToast.show(true, qsTr("已归档 %1 个文件夹的评分").arg(picked.length))

                // 让用户能立刻在"归档"Tab 看到这一批：
                // 1) 刷新批次列表（listArchiveBatches 按时间倒序，[0] 就是刚归档的）
                // 2) 自动切到"归档"Tab，否则用户停留在"当前"Tab 会误以为归档没生效
                root._refreshArchiveList(false)
                var fresh = Rating.listArchiveBatches(root._selectedMode) || []
                if (fresh.length > 0) {
                    root._archiveBatch = fresh[0]["name"] || ""
                    root._switchView("archive")
                    // 缓存到属性，供下方 toast 动作按钮回调安全读取
                    root._lastArchivedMode  = root._selectedMode
                    root._lastArchivedBatch = root._archiveBatch
                    actionToast.showWithAction(
                        true,
                        qsTr("已归档 %1 个文件夹 → 批次「%2」").arg(picked.length).arg(root._archiveBatch),
                        qsTr("📂 打开所在文件夹"),
                        function() {
                            if (typeof Rating !== "undefined"
                                    && typeof Rating.revealArchiveBatch === "function"
                                    && root._lastArchivedBatch.length > 0)
                                Rating.revealArchiveBatch(root._lastArchivedMode, root._lastArchivedBatch)
                        })
                } else {
                    actionToast.show(true, qsTr("已归档 %1 个文件夹的评分").arg(picked.length))
                }
            } else {
                // 失败要显式弹窗（toast 一闪而过容易漏看），并给出可能原因提示
                var modeNow = (typeof Rating !== "undefined") ? (Rating.currentMode || "") : ""
                var reason = (modeNow === "" || modeNow === "off")
                        ? qsTr("当前评分模式为「关闭(off)」，无法归档。请先在菜单里启用对应的评分模式。")
                        : qsTr("未命中任何记录或写盘失败。请确认勾选的文件夹下确实有评分数据。")
                rejectDialog.openWith(qsTr("归档失败"), reason)
            }
        }
    }

    // ── 删除整批归档确认对话框（与"删除勾选"互补：删除整个批次目录，不可恢复）────
    Dialog {
        id: confirmDeleteBatchDialog
        modal: true
        anchors.centerIn: parent
        width: 420
        padding: 0

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#7a3a3a"
            border.width: 1
            radius: 8
        }

        header: Rectangle {
            color: "transparent"
            implicitHeight: 44
            Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: qsTr("删除整个归档批次？")
                color: "#ff8a8a"
                font.pixelSize: 14
                font.bold: true
                elide: Text.ElideRight
            }
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1; color: "#2a2a30"
            }
        }

        contentItem: Item {
            implicitHeight: _delBatchMsg.implicitHeight + 32
            Text {
                id: _delBatchMsg
                anchors.left: parent.left; anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16; anchors.rightMargin: 16
                text: qsTr("将永久删除归档批次「%1」及其所有评分记录，此操作不可恢复，是否继续？")
                        .arg(root._archiveBatch)
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
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: parent.top
                height: 1; color: "#2a2a30"
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16; anchors.rightMargin: 16
                anchors.topMargin: 12; anchors.bottomMargin: 12
                spacing: 8
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("取消")
                    onClicked: confirmDeleteBatchDialog.reject()
                }
                PillBtn {
                    text: qsTr("永久删除")
                    danger: true
                    onClicked: confirmDeleteBatchDialog.accept()
                }
            }
        }

        onAccepted: {
            if (typeof Rating === "undefined" || !root._archiveBatch) return
            var name = root._archiveBatch
            var ok = Rating.deleteArchiveBatch(root._archiveBatchMode, name)
            if (ok) {
                actionToast.show(true, qsTr("已删除归档批次「%1」").arg(name))
                root._archiveBatch = ""
                root._checkedFolders = ({})
                root._refreshArchiveList(false)
            } else {
                actionToast.show(false, qsTr("删除归档批次失败"))
            }
        }
    }

    // ── 导出此归档批次：用户指定保存路径（与主"导出"按钮逻辑同源，但走 exportArchiveBatch）────
    FileDialog {
        id: exportArchiveDialog
        title: qsTr("导出归档批次为 CSV")
        fileMode: FileDialog.SaveFile
        nameFilters: ["CSV (*.csv)"]
        defaultSuffix: "csv"
        currentFolder: (typeof Rating !== "undefined") ? Rating.defaultExportDir : ""
        currentFile: {
            var name = "PlayerX_archive"
            var u = (typeof Rating !== "undefined") ? Rating.currentUser : ""
            if (u && u.length > 0) name += "_" + u
            if (root._archiveBatch && root._archiveBatch.length > 0)
                name += "_" + root._archiveBatch
            var dir = (typeof Rating !== "undefined") ? Rating.defaultExportDir.toString() : ""
            if (dir.length > 0) {
                if (dir.charAt(dir.length - 1) !== "/") dir += "/"
                return dir + name + ".csv"
            }
            return name + ".csv"
        }
        onAccepted: {
            if (typeof Rating === "undefined") return
            var fp = selectedFile.toString().replace(/^file:\/\//, "")
            // Windows 下 selectedFile 可能形如 file:///C:/xxx，需要再剥一次开头的 /
            if (fp.length > 2 && fp.charAt(0) === "/" && fp.charAt(2) === ":") fp = fp.substring(1)
            var ok = Rating.exportArchiveBatch(root._selectedMode, root._archiveBatch, fp)
            if (ok) {
                actionToast.show(true, qsTr("已导出到 %1").arg(fp))
            } else {
                actionToast.show(false, qsTr("导出失败"))
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
                text: qsTr("填入后端服务地址，点“保存并上传”后会将当前评分 CSV 推送过去。\n局域网示例：http://192.168.x.x:2026/upload")
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
        // 可选动作按钮（例如归档后"打开所在文件夹"）：_actionLabel 为空则不显示
        property string _actionLabel: ""
        property var    _actionCb: null

        function show(ok, msg) {
            actionToast._actionLabel = ""
            actionToast._actionCb = null
            _ok = ok
            _msg = msg
            // 重点击时重启动画与计时
            fadeOut.stop()
            slideIn.restart()
            fadeIn.restart()
            hideTimer.restart()
        }

        // 带动作按钮的提示：actionLabel 为按钮文案，actionCb 为点击回调
        function showWithAction(ok, msg, actionLabel, actionCb) {
            _ok = ok
            _msg = msg
            _actionLabel = actionLabel || ""
            _actionCb = (typeof actionCb === "function") ? actionCb : null
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
            implicitWidth: Math.min(420, Math.max(220, toastColumn.implicitWidth + 32))
            width: implicitWidth
            height: toastColumn.implicitHeight + 22
            // 轻微阴影，提高在深色背景上的漂浮感
            Rectangle {
                anchors.fill: parent
                anchors.margins: -4
                z: -1
                radius: parent.radius + 3
                color: "#80000000"
                opacity: 0.45
            }
            Column {
                id: toastColumn
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8
                Text {
                    width: parent.width
                    text: (actionToast._ok ? "✅ " : "❌ ") + actionToast._msg
                    color: "#e8e8ec"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    verticalAlignment: Text.AlignVCenter
                }
                // 可选动作按钮（如归档后"📂 打开所在文件夹"）
                Rectangle {
                    visible: actionToast._actionLabel.length > 0 && actionToast._actionCb !== null
                    width: actionBtnLabel.implicitWidth + 20
                    height: 26
                    radius: 13
                    color: actionBtnMA.containsMouse ? "#1f2f3a" : "#26262a"
                    border.color: "#3a6a7a"
                    border.width: 1
                    Text {
                        id: actionBtnLabel
                        anchors.centerIn: parent
                        text: actionToast._actionLabel
                        color: "#8ad4ff"
                        font.pixelSize: 12
                    }
                    MouseArea {
                        id: actionBtnMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            hideTimer.stop()
                            fadeOut.restart()
                            if (actionToast._actionCb) actionToast._actionCb()
                        }
                    }
                }
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
            // ── 外部"一键上传"路由：跳过面板内弹窗，由 Main.qml 用主窗顶层
            //   对话框展示结果，让"上传成功不需要打开面板"成立。──
            if (root._quickUploadInProgress) {
                // 无论成功/失败，本次外部上传都消费掉这个标志
                root._quickUploadInProgress = false
                if (!ok && message && (message.indexOf("[AUTH]") >= 0
                                      || message.indexOf("[NET]") >= 0)) {
                    // 权限 / 网络类错误也走同一个"失败"信号；Main.qml 弹一个
                    // 简单错误对话框即可（此类错误较少见，无需精细分类）。
                    var cleanErr = message.replace(/^\[(AUTH|NET)\]\s*/, "").trim()
                    root.quickUploadNetError(cleanErr)
                    return
                }
                // 上传成功 → 自动归档（仅当数据来自"当前 Tab"时才归档；
                // 数据来自归档批次时跳过，数据已在归档里无需重复归档）
                // 外部一键上传（Main.qml 的 📤「上传数据」/「评分数据」）走这里。
                if (ok) {
                    var _qBatch = (root._lastUploadKind !== "archive")
                                  ? root._autoArchiveAfterUpload()
                                  : root._lastUploadArchiveBatch
                    // 批次名回传给主窗结果对话框，让它能显示"已自动归档"一行
                    root.quickUploadFinished(true, (message || ""), _qBatch)
                } else {
                    root.quickUploadFinished(false, message || "", "")
                }
                return
            }
            // 鉴权类硬错（HTTP 401/403 由 C++ 端在文案前置 "[AUTH]"）单独弹模态提醒，
            // 防止"一闪而过的 toast"被用户漏看，进而以为上传成功。
            if (!ok && message && message.indexOf("[AUTH]") >= 0) {
                // 去掉前缀 token 标记，只保留人话部分给用户
                var clean = message.replace("[AUTH]", "").trim()
                uploadAuthErrorDialog._msg = clean
                uploadAuthErrorDialog.open()
                return
            }
            // 网络不可达 / 后端未启动（C++ 端HEAD探活失败时加 "[NET]" 前缀）走独立模态提醒，
            // 原因同上：URL 填错 / 后端没起是高频用户错误，必须让他们一眼看见。
            if (!ok && message && message.indexOf("[NET]") >= 0) {
                var cleanNet = message.replace("[NET]", "").trim()
                uploadNetErrorDialog._msg = cleanNet
                uploadNetErrorDialog.open()
                return
            }
            if (ok) {
                // 成功：右下角小 toast 容易被用户漏看（"我点了上传按钮怎么没反应？"），
                // 改用居中模态成功对话框 + 4s 自动关闭：既醒目，又不打断后续操作太久。
                // 同时按钮闪一下做次要反馈。
                uploadSuccessDialog._msg = message || qsTr("上传成功")
                // 构造「查看结果」URL：取服务器 origin + /#results
                var _srvBase = (typeof Rating !== "undefined" && Rating.uploadServerUrl) ? Rating.uploadServerUrl.trim() : ""
                var _m = _srvBase.match(/^(https?:\/\/[^/]+)/)
                uploadSuccessDialog._viewUrl = _m ? _m[1] + "/#results" : ""
                // 填充本次上传的上下文信息，供弹窗展示
                uploadSuccessDialog._rater = (typeof Rating !== "undefined") ? Rating.currentUser : ""
                uploadSuccessDialog._tag   = (typeof Rating !== "undefined") ? Rating.uploadTag   : ""
                // 转换为相对路径：用 ~ 替换 home 目录
                var _rawPaths = root._lastUploadFolders
                var _relPaths = []
                for (var _pi = 0; _pi < _rawPaths.length; _pi++) {
                    var _p = String(_rawPaths[_pi])
                    // 尝试用 /Users/<name> 模式匹配 home，用 ~ 替换
                    var _homeMatch = _p.match(/^(\/Users\/[^\/]+)(\/.*)?$/)
                    if (_homeMatch) _p = "~" + (_homeMatch[2] || "")
                    _relPaths.push(_p)
                }
                uploadSuccessDialog._folderPaths = _relPaths
                // 从 modeList 中找到当前模式的 label
                var _ml = (typeof Rating !== "undefined") ? Rating.modeList : []
                var _mLabel = root._selectedMode
                for (var _mi = 0; _mi < _ml.length; _mi++) {
                    if (_ml[_mi].id === root._selectedMode) { _mLabel = _ml[_mi].label; break }
                }
                uploadSuccessDialog._modeName = _mLabel

                // ── 上传成功后自动归档（统一入口，与一键上传共用同一套逻辑）──
                // 归档 Tab 数据本就在归档中，跳过自动归档（避免重复归档操作）
                if (root._lastUploadKind !== "archive") {
                    uploadSuccessDialog._archivedBatch = root._autoArchiveAfterUpload()
                }
                uploadSuccessDialog.open()
                uploadBtn.flash = true
                uploadFlashTimer.restart()

                // ── 串行上传队列：继续发下一个 ──
                if (root._serialUploadQueue.length > 0) {
                    root._serialUploadIndex++
                    root._sendNextSerialUpload()
                }
            } else {
                // 失败仍走 toast：失败信息通常较长（地址不对/网络超时），用 toast 容许用户一边看一边改。
                actionToast.show(false, message)
                // 串行上传队列：失败也继续发下一个（不因一个 tag 失败阻塞整个队列）
                if (root._serialUploadQueue.length > 0) {
                    root._serialUploadIndex++
                    root._sendNextSerialUpload()
                }
            }
        }
        // 服务端返回 409：(rater, tag) 重复上传 → 弹覆盖确认
        function onUploadConflict(message) {
            // 外部"一键上传"路由：由 Main.qml 顶层对话框处理，避免面板弹出。
            // 注意：这里【不】重置 _quickUploadInProgress，因为覆盖上传后
            // 还会走一次 onUploadFinished，同一次外部上传流程结束才应重置。
            if (root._quickUploadInProgress) {
                root.quickUploadConflict(message || "")
                return
            }
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
                                text: {
                                    var starLeft = (modelData.totalVideos || 0) - (modelData.ratedCount || 0)
                                    var ckMiss = modelData.ckMissing || 0
                                    var parts = []
                                    if (starLeft > 0)
                                        parts.push(qsTr("已评 %1/%2（缺 %3）")
                                            .arg(modelData.ratedCount)
                                            .arg(modelData.totalVideos)
                                            .arg(starLeft))
                                    if (ckMiss > 0)
                                        parts.push(qsTr("%1 个文件未勾选检查项").arg(ckMiss))
                                    return parts.join("，")
                                }
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

    // tag 与远程激活配置不一致时的二次确认弹窗
    // 不阻止上传，用户可选择"仍然上传"或"取消修改 tag"
    Dialog {
        id: tagMismatchDialog
        modal: true
        anchors.centerIn: parent
        width: 480
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#ffb05c"
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
                text: qsTr("⚠ 备注 tag 与远程配置不一致")
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
            spacing: 12

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.topMargin: 16
                text: qsTr("你填写的备注 tag 与远程激活配置的 tag 不一致，可能导致数据归类错误。")
                color: "#e8e3d8"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }

            // 对比展示
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                color: "#15151a"
                border.color: "#2a2a30"
                border.width: 1
                radius: 6
                implicitHeight: tagCompareCol.implicitHeight + 16

                ColumnLayout {
                    id: tagCompareCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    RowLayout {
                        spacing: 8
                        Text {
                            text: qsTr("你填写的 tag：")
                            color: "#9aa0a6"
                            font.pixelSize: 12
                        }
                        Text {
                            text: tagField.text.trim() || qsTr("（空）")
                            color: "#f5a623"
                            font.pixelSize: 13
                            font.bold: true
                        }
                    }
                    RowLayout {
                        spacing: 8
                        Text {
                            text: qsTr("远程配置 tag：")
                            color: "#9aa0a6"
                            font.pixelSize: 12
                        }
                        Text {
                            text: root.remoteTag || qsTr("（空）")
                            color: "#5fd17a"
                            font.pixelSize: 13
                            font.bold: true
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                text: qsTr("确认要用当前 tag 继续上传吗？")
                color: "#c8c8cc"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            // 按钮行
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.topMargin: 4
                Layout.bottomMargin: 16
                spacing: 10
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("取消，去修改 tag")
                    onClicked: tagMismatchDialog.close()
                }
                PillBtn {
                    text: qsTr("仍然上传")
                    danger: true
                    onClicked: {
                        tagMismatchDialog.close()
                        // 直接走上传，跳过 tag 校验
                        if (!Rating.uploadServerUrl || Rating.uploadServerUrl.length === 0) {
                            uploadConfigDialog.open()
                        } else if (root._isArchiveView) {
                            Rating.uploadArchiveBatchToCloud(
                                root._selectedMode,
                                root._archiveBatch,
                                false, root._lastUploadFolders)
                        } else {
                            Rating.uploadToCloud(false, root._lastUploadFolders)
                        }
                    }
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
        property string _viewUrl: ""  // 上传成功后的「查看结果」跳转 URL
        property string _rater: ""
        property string _tag: ""
        property string _modeName: ""
        property var    _folderPaths: []   // 上传的文件夹绝对路径列表
        // 上传成功后自动归档产生的批次名；为空表示本次没有（或无需）自动归档
        property string _archivedBatch: ""

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
            spacing: 0

            // ── 标题行 ──────────────────────────────────────────────────
            Item { Layout.preferredHeight: 20 }
            RowLayout {
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                spacing: 10
                Text {
                    text: "✅"
                    font.pixelSize: 24
                }
                Text {
                    text: qsTr("上传成功")
                    color: "#e8f5ec"
                    font.pixelSize: 17
                    font.bold: true
                }
            }

            // ── 分隔线 ──────────────────────────────────────────────────
            Item { Layout.preferredHeight: 14 }
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                height: 1
                color: "#2a3d2a"
            }
            Item { Layout.preferredHeight: 12 }

            // ── 信息卡片：本次上传摘要 ──────────────────────────────────
            GridLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                columns: 2
                columnSpacing: 10
                rowSpacing: 10

                // 行 1：评分模式
                Text {
                    text: qsTr("评分模式")
                    color: "#7a9a7a"
                    font.pixelSize: 12
                    Layout.preferredWidth: 64
                }
                Text {
                    text: uploadSuccessDialog._modeName || "—"
                    color: "#d4f0d4"
                    font.pixelSize: 13
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // 行 2：备注 tag
                Text {
                    text: qsTr("备注 tag")
                    color: "#7a9a7a"
                    font.pixelSize: 12
                }
                Text {
                    text: uploadSuccessDialog._tag || "—"
                    color: "#5fd17a"
                    font.pixelSize: 13
                    font.family: "Menlo, Monaco, monospace"
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // 行 3：评分人
                Text {
                    text: qsTr("评分人")
                    color: "#7a9a7a"
                    font.pixelSize: 12
                }
                Text {
                    text: uploadSuccessDialog._rater || "—"
                    color: "#d4f0d4"
                    font.pixelSize: 13
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // 行 4：自动归档结果（仅上传成功后自动归档成功时显示）
                Text {
                    visible: uploadSuccessDialog._archivedBatch.length > 0
                    text: qsTr("已自动归档")
                    color: "#7a9a7a"
                    font.pixelSize: 12
                }
                Text {
                    visible: uploadSuccessDialog._archivedBatch.length > 0
                    text: (uploadSuccessDialog._archivedBatch.length > 0)
                          ? ("✅ " + uploadSuccessDialog._archivedBatch
                             + qsTr("（数据已从当前列表移入归档）"))
                          : "—"
                    color: "#8ad4ff"
                    font.pixelSize: 13
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // 行 5：上传文件夹（相对路径列表）
                Text {
                    text: qsTr("文件夹")
                    color: "#7a9a7a"
                    font.pixelSize: 12
                    Layout.alignment: Qt.AlignTop
                }
                Column {
                    Layout.fillWidth: true
                    spacing: 3
                    Repeater {
                        model: uploadSuccessDialog._folderPaths
                        Text {
                            width: parent.width
                            text: modelData
                            color: "#d4f0d4"
                            font.pixelSize: 12
                            elide: Text.ElideMiddle
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 16 }

            // ── 底部按钮行 ──────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: "#2a3d2a"
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.topMargin: 12
                Layout.bottomMargin: 16
                spacing: 8
                // 查看结果按钮：仅在有服务器地址时显示
                PillBtn {
                    visible: uploadSuccessDialog._viewUrl.length > 0
                    text: qsTr("查看结果 ↗")
                    emphasized: true
                    onClicked: Qt.openUrlExternally(uploadSuccessDialog._viewUrl)
                }
                Item { Layout.fillWidth: true }
                PillBtn {
                    text: qsTr("确定")
                    onClicked: { uploadSuccessAutoClose.stop(); uploadSuccessDialog.close() }
                }
            }
        }
    }

    Timer {
        id: uploadSuccessAutoClose
        interval: 4000
        repeat: false
        // 已禁用自动关闭：弹窗需用户手动点击确定（有「查看结果」跳转需求）
        // onTriggered: uploadSuccessDialog.close()
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

    // 网络不可达对话框：HEAD 探活失败（连接拒绝 / 超时 / DNS 错误 等）时弹。
    // 为什么独立于 [AUTH]：[AUTH] 是“服务起了但拒你”，[NET] 是“服务根本没起”，
    // 诊断路径和能给用户的建议完全不同，合并一起会混淆。
    Dialog {
        id: uploadNetErrorDialog
        modal: true
        anchors.centerIn: parent
        width: 520
        padding: 0

        property string _msg: ""

        Overlay.modal: Rectangle { color: "#aa000000" }

        background: Rectangle {
            color: "#1e1e22"
            border.color: "#5a3a2a"   // 橙色警示：不同于鉴权类的红色边框
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
                text: qsTr("⚠️ 无法连接到上传服务器")
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
            implicitHeight: _netCol.implicitHeight + 32
            ColumnLayout {
                id: _netCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 10
                Text {
                    Layout.fillWidth: true
                    text: uploadNetErrorDialog._msg
                    color: "#e6e6ea"
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    // C++ 端已拼好多行提示（包含原因 + 地址 + 检查清单），这里保留原始换行。
                    lineHeight: 1.35
                    textFormat: Text.PlainText
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
                    onClicked: uploadNetErrorDialog.close()
                }
                PillBtn {
                    text: qsTr("修改服务器地址")
                    danger: true
                    onClicked: {
                        uploadNetErrorDialog.close()
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
                    onClicked: {
                        uploadConflictDialog.close()
                        // 串行上传队列：取消覆盖 → 跳过当前 tag，继续下一个
                        if (root._serialUploadQueue.length > 0) {
                            root._serialUploadIndex++
                            root._sendNextSerialUpload()
                        }
                    }
                }
                PillBtn {
                    text: qsTr("覆盖上传")
                    danger: true
                    onClicked: {
                        uploadConflictDialog.close()
                        if (typeof Rating === "undefined") return
                        // 按上次的"上传来源"走：归档来源就重发归档批次，
                        // current 来源就重发主 CSV——避免用户在归档 Tab 触发的 409
                        // 被覆盖时却写到了当前 Tab 的数据上去。
                        // 多 tag 场景：按 _lastUploadTagPickedMap 逐个 tag 重发（串行队列）
                        var tagMap = root._lastUploadTagPickedMap
                        var tagNames = Object.keys(tagMap)
                        if (root._lastUploadKind === "archive" && tagNames.length > 0) {
                            root._serialUploadQueue = []
                            for (var tn = 0; tn < tagNames.length; ++tn) {
                                var tname = tagNames[tn]
                                var tinfo = tagMap[tname]
                                root._serialUploadQueue.push({ mode: tinfo.mode, name: tname, paths: tinfo.paths || [] })
                            }
                            root._serialUploadIndex = 0
                            root._serialUploadForce = true
                            root._sendNextSerialUpload()
                        } else if (root._lastUploadKind === "archive"
                                && root._lastUploadArchiveBatch
                                && root._lastUploadArchiveBatch.length > 0) {
                            Rating.uploadArchiveBatchToCloud(
                                root._lastUploadArchiveMode || root._selectedMode,
                                root._lastUploadArchiveBatch,
                                true,
                                root._lastUploadFolders || [])
                        } else {
                            Rating.uploadToCloud(true, root._lastUploadFolders || [])
                        }
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
