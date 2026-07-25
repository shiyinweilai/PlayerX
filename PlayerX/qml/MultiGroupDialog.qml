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
import QtQuick.Dialogs
import QtQuick.LocalStorage 2.15
import PlayerX 1.0

ApplicationWindow {
    id: dlg
    title: "打开文件夹 / 多组对比"

    // ─── 每次 Dialog 显示时，把独立的「文件夹历史」合并到 lanes 列表 ──
    // 即使中途 _rowsModel 被 loadFlatFiles 等覆盖式重置，下次打开 Dialog 时
    // 历史中固化的文件夹路径仍会作为新 lane 出现（默认未勾选），符合"路径固化、
    // 每次打开加载历史路径，新增就增加一路"的预期行为。
    onVisibleChanged: {
        if (visible && !_folderHistMerged) {
            _folderHistMerged = true
            try { _mergeFolderHistoryIntoLanes() } catch (e) { /* ignore */ }
        } else if (!visible) {
            // 隐藏时复位，下次打开重新合并（确保期间被拖入的新文件夹也能浮现）
            _folderHistMerged = false
        }
    }

    // ─── 评分模式切换时按新槽位重载 lanes ─────────────────────────
    // 时序：用户在 Main.qml / 顶部菜单切到「主观评分 / 质量比较 / off」 →
    //   Rating.currentMode 变化 → 这里被触发。
    // _persistKey / _persistFileName 是 readonly property，绑定到 Rating.currentMode，
    // 此时已经指向新模式槽位；旧模式的快照在切换前每次 lane 改动都已 _persistLanes
    // 落库，无需再补写。
    // 行为：从新模式槽位读快照覆盖到当前 lanes；若新模式之前没用过（槽位为空），
    //   保持当前 lanes 不变 —— 这给"刚切到新模式直接复用当前选路"留了空间，但
    //   一旦发生任何改动，就会以新模式槽位独立记录，互不干扰。
    Connections {
        target: (typeof Rating !== "undefined") ? Rating : null
        ignoreUnknownSignals: true
        function onCurrentModeChanged() {
            // 防御：还原期间不要再触发 _restoreLanes（_restoring 在内部已判，
            // 但模式切换通常发生在用户已交互后，此处一般 _restoring=false）
            if (_restoring) return
            try {
                // 读新槽位；为空则不动当前 lanes
                var s = _fileLoad() || ""
                if (!s || s.length === 0) s = _lsLoad(_persistKey) || ""
                if (!s || s.length === 0) {
                    try {
                        if (Rating && typeof Rating.loadString === "function") {
                            s = Rating.loadString(_persistKey, "") || ""
                        }
                    } catch (e) { s = "" }
                }
                if (s && s.length > 0) {
                    _restoreLanes()  // 走完整还原流程（含视图刷新）
                }
            } catch (e) { /* ignore */ }
        }
    }

    // ─── 持久化：记住上次配置的 lanes（文件夹 / 过滤关键字 / 勾选 / 当前索引）───
    // 设计要点：
    //   · 仅存"轻量状态"（文件夹路径、关键字、勾选、当前索引）——不存 allFiles/visibleFiles
    //     避免一些路径过多时存储臃胀；打开时重新扫描。
    //   · 采用 JSON 字符串作为单一存储 key，原子性写回，避免多字段不一致。
    //   · 首次启动（持久化为空）才走默认 2 路创建逻辑。
    //   · 调用 _persistLanes() 在：addLane / removeLane / _syncLaneFromRow / loadFlatFiles
    //     等所有会改变 lanes 的入口。
    //
    // ── 三轨存储（按可靠性排序，主路先写先读）──────────────────────
    //   ① cache 文件：<AppCache>/multi_group_lanes.json  ← 用户可直接打开查看 / 手动备份
    //      路径：
    //        macOS:   ~/Library/Caches/PlayerX/multi_group_lanes.json
    //        Windows: %LOCALAPPDATA%/PlayerX/cache/multi_group_lanes.json
    //   ② QtQuick.LocalStorage（SQLite，Qt6 自带，无任何部署依赖）
    //   ③ Rating.saveString → QSettings ini（与评分人/上传配置共用一份）
    //   写入：①②③ 同时写。读取：① → ② → ③ 顺序兜底。
    //   任何一路出问题都不影响主流程。
    //
    // ── 按「评分模式」分桶 ────────────────────────────────────────
    //   背景：同一个文件夹在主观评分 / 质量比较 / off 三种模式下可能播放进度不同
    //   （比如主观评分评到第 4 个，质量比较还没开始评）。如果共用一份 lanes 快照，
    //   切模式后会把上一种模式的 currentIndex 串过来，造成"接错"。
    //   做法：把当前模式作为命名空间拼进 key/文件名里：
    //      key      → "multiGroup/lanesJson/<mode>"
    //      filename → "multi_group_lanes_<mode>.json"
    //   其中 <mode> ∈ { off, subjective, quality }（未知值兜底为 off）。
    //   兼容旧数据：首次进入时若发现"旧的 multi_group_lanes.json / multiGroup/lanesJson"
    //   存在但当前模式槽位为空，则把它整体迁到当前模式槽位（一次性）。
    function _modeSlug() {
        try {
            if (typeof Rating === "undefined" || !Rating) return "off"
            var m = Rating.currentMode || "off"
            // 白名单：所有能承载多组评分的模式，均可作为持久化槽位 slug；
            // 未知/未启用值兜底为 "off"。
            // 注意：test（测试模式）行为与 subjective 完全一致，但独立成槽位，
            // 保证测试期间的多组进度不污染真正主观评分的持久化数据。
            if (m === "subjective" || m === "quality" || m === "quality_slide"
                || m === "test" || m === "off") return m
            return "off"
        } catch (e) { return "off" }
    }
    // 当前模式的人类可读标签，用于弹窗"作用域提示"
    function _modeLabel() {
        var m = _modeSlug()
        if (m === "subjective")    return "主观评分"
        if (m === "quality")       return "质量比较"
        if (m === "quality_slide") return "质量比较2（含滑动对比）"
        if (m === "test")          return "测试模式"
        return "未启用评分"
    }
    // 旧版本用的固定 key / 文件名：仅用于一次性迁移，迁完即删
    readonly property string _legacyPersistKey:      "multiGroup/lanesJson"
    readonly property string _legacyPersistFileName: "multi_group_lanes.json"
    // 当前模式对应的 key / 文件名（绑定到 Rating.currentMode，模式切换时自动失效）
    readonly property string _persistKey: {
        var m = (typeof Rating !== "undefined" && Rating) ? (Rating.currentMode || "off") : "off"
        // 允许被承载多组进度持久化的模式白名单，其余（quality_slide / multi_dim 等）
        // 归到 "off" 槽位以避免与其他模式相互覆盖。
        // test（测试模式）单列一个槽位，等价 subjective 但相互独立。
        if (m !== "subjective" && m !== "quality" && m !== "test") m = "off"
        return "multiGroup/lanesJson/" + m
    }
    readonly property string _persistFileName: {
        var m = (typeof Rating !== "undefined" && Rating) ? (Rating.currentMode || "off") : "off"
        if (m !== "subjective" && m !== "quality" && m !== "test") m = "off"
        return "multi_group_lanes_" + m + ".json"
    }

    // ─── 独立的「文件夹历史」持久化 ──────────────────────────────────
    // 设计动机：lanes 持久化会被 loadFlatFiles（添加文件场景）等覆盖式重置，
    //   一旦用户走过"添加文件"流程，原先拖入过的文件夹路径就会丢失。
    //   为此用一份**完全独立**的存储仅保存「文件夹路径数组」，作为"路径固化"的真相。
    // 行为：
    //   · 拖入文件夹时，addFoldersToHistory 写入此处（去重）；
    //   · 每次 Dialog 打开（onVisibleChanged → visible=true）时，从此处合并到 _rowsModel —
    //     已存在同 folderPath 的 lane 跳过；不在的追加为新 lane（默认未勾选，
    //     不打扰当前已勾选的 lanes）。
    //   · 容量上限：kMaxLanes（9 条），FIFO 截断（保留最近一次拖入的）。
    readonly property string _folderHistKey: "multiGroup/folderHistoryJson"
    readonly property string _folderHistFileName: "multi_group_folder_history.json"

    // ─── 「全局上次导入目录」持久化 ─────────────────────────────────
    // 用户体感：一旦导入过一次（任意一路成功选了文件夹），后续：
    //   · 已导入路再次点 📁 → 还从该路自身路径起步（与 Qt 默认一致）；
    //   · 新增路第一次点 📁 → 从"全局上次目录"起步，而不是回到 Macintosh HD 根。
    // 实现：每次 MultiGroupRow.folderImported(url) 被触发时刷新此值并写盘。
    // 仅依赖 Rating.saveString/loadString（QSettings），单值轻量，无需文件 + LocalStorage 三轨。
    readonly property string _lastImportFolderKey: "multiGroup/lastImportFolderUrl"
    property url lastImportFolderUrl: ""

    // effectiveDefaultFolderUrl —— 真正派发给 MultiGroupRow.defaultFolderUrl 的值。
    // 优先级（从高到低）：
    //   1) lastImportFolderUrl —— 当前会话/历史会话最后一次「📁 选文件夹」成功的路径。
    //      这是最贴近"上一次操作"的语义，且跨进程持久化（Rating QSettings）。
    //   2) 已有 lanes 中"最大 laneIndex 的非空 folderPath"——
    //      用于覆盖"老用户从未触发过 save"或"刚清掉持久化值"的场景：
    //      此时仍然能从已存在的某一路推断出"最近的目录"，
    //      天然实现"新增第 N 路时用第 N-1 路的目录起步"的体感。
    //   3) 都没有 → 空 URL，Qt FolderDialog 自行回退到 HOME。
    readonly property url effectiveDefaultFolderUrl: {
        // 1) 持久化值
        if (lastImportFolderUrl && ("" + lastImportFolderUrl).length > 0) {
            return lastImportFolderUrl
        }
        // 2) 从 _rowsModel 里挑最近一条非空 folderPath
        try {
            for (var i = _rowsModel.count - 1; i >= 0; --i) {
                var l = _rowsModel.get(i)
                if (!l) continue
                var p = l.folderPath || ""
                if (p.length > 0) {
                    var u = (p.charAt(0) === "/") ? ("file://" + p)
                                                  : ("file:///" + p)
                    return u
                }
            }
        } catch (e) { /* ignore */ }
        return ""
    }
    function _loadLastImportFolder() {
        try {
            if (typeof Rating !== "undefined" && Rating
                && typeof Rating.loadString === "function") {
                var s = Rating.loadString(_lastImportFolderKey, "") || ""
                if (s && s.length > 0) lastImportFolderUrl = s
            }
        } catch (e) { /* ignore */ }
    }
    function _saveLastImportFolder(url) {
        // url 可能是 QUrl，也可能是 string —— 统一转字符串落库
        var s = ""
        try { s = url ? ("" + url) : "" } catch (e) { s = "" }
        if (!s || s.length === 0) return
        if (("" + lastImportFolderUrl) === s) return  // 无变化，免写
        lastImportFolderUrl = s
        try {
            if (typeof Rating !== "undefined" && Rating
                && typeof Rating.saveString === "function") {
                Rating.saveString(_lastImportFolderKey, s)
            }
        } catch (e) { /* ignore */ }
    }

    // 避免还原过程中 _syncLaneFromRow 反复触发写盘
    property bool _restoring: false
    // 避免 onVisibleChanged 在同一次打开中重复合并
    property bool _folderHistMerged: false

    // ── 主路：cache 文件路径 ──────────────────────────────────────
    // 注意：_persistFileName 跟随 Rating.currentMode 变化，因此**不能缓存**结果，
    // 否则模式切换后还在写入旧模式的文件。每次调用都现拼。
    function _cacheFile() {
        try {
            if (typeof Fs !== "undefined" && Fs
                && typeof Fs.appCacheDir === "function") {
                var dir = Fs.appCacheDir() || ""
                if (dir.length > 0) {
                    return dir + "/" + _persistFileName
                }
            }
        } catch (e) { /* ignore */ }
        return ""
    }
    // 旧版本固定文件名的路径——仅用于一次性迁移读取
    function _legacyCacheFile() {
        try {
            if (typeof Fs !== "undefined" && Fs
                && typeof Fs.appCacheDir === "function") {
                var dir = Fs.appCacheDir() || ""
                if (dir.length > 0) return dir + "/" + _legacyPersistFileName
            }
        } catch (e) { /* ignore */ }
        return ""
    }

    // 「文件夹历史」cache 文件路径（与 lanes cache 同目录，文件名不同）
    property string _folderHistCachePath: ""
    function _folderHistCacheFile() {
        if (_folderHistCachePath && _folderHistCachePath.length > 0) return _folderHistCachePath
        try {
            if (typeof Fs !== "undefined" && Fs
                && typeof Fs.appCacheDir === "function") {
                var dir = Fs.appCacheDir() || ""
                if (dir.length > 0) {
                    _folderHistCachePath = dir + "/" + _folderHistFileName
                    return _folderHistCachePath
                }
            }
        } catch (e) { /* ignore */ }
        return ""
    }
    function _fileSave(json) {
        var p = _cacheFile()
        if (!p || p.length === 0) return false
        try {
            if (typeof Fs.writeTextFile === "function") {
                return Fs.writeTextFile(p, json || "")
            }
        } catch (e) { return false }
        return false
    }
    function _fileLoad() {
        var p = _cacheFile()
        if (!p || p.length === 0) return ""
        try {
            if (typeof Fs.readTextFile === "function") {
                return Fs.readTextFile(p) || ""
            }
        } catch (e) { return "" }
        return ""
    }

    // ── 副路：LocalStorage 帮手 ───────────────────────────────────
    function _ldb() {
        // 1MB 上限对单个 JSON 配置项足够（实际 < 10KB）。
        return LocalStorage.openDatabaseSync(
            "PlayerX", "1.0", "PlayerX local KV", 1000000)
    }
    function _lsSave(key, val) {
        try {
            var db = _ldb()
            db.transaction(function(tx) {
                tx.executeSql(
                    "CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)")
                if (!val || val.length === 0) {
                    tx.executeSql("DELETE FROM kv WHERE k = ?", [key])
                } else {
                    tx.executeSql("INSERT OR REPLACE INTO kv(k, v) VALUES (?, ?)",
                                  [key, val])
                }
            })
            return true
        } catch (e) {
            return false
        }
    }
    function _lsLoad(key) {
        try {
            var db = _ldb()
            var got = ""
            db.readTransaction(function(tx) {
                tx.executeSql(
                    "CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)")
                var rs = tx.executeSql("SELECT v FROM kv WHERE k = ?", [key])
                if (rs && rs.rows && rs.rows.length > 0) {
                    got = rs.rows.item(0).v || ""
                }
            })
            return got
        } catch (e) {
            return ""
        }
    }

    // ─── 「文件夹历史」三轨读写 ─────────────────────────────────────
    // 与 lanes 的三轨完全独立，键名/文件名不同，避免误覆盖。
    function _saveFolderHistory(json) {
        // ① cache 文件
        try {
            var p = _folderHistCacheFile()
            if (p && p.length > 0 && typeof Fs.writeTextFile === "function") {
                Fs.writeTextFile(p, json || "")
            }
        } catch (e) { /* ignore */ }
        // ② LocalStorage
        _lsSave(_folderHistKey, json || "")
        // ③ Rating QSettings
        try {
            if (typeof Rating !== "undefined" && Rating
                && typeof Rating.saveString === "function") {
                Rating.saveString(_folderHistKey, json || "")
            }
        } catch (e) { /* ignore */ }
    }
    function _loadFolderHistory() {
        var s = ""
        // ① cache 文件
        try {
            var p = _folderHistCacheFile()
            if (p && p.length > 0 && typeof Fs.readTextFile === "function") {
                s = Fs.readTextFile(p) || ""
            }
        } catch (e) { s = "" }
        // ② LocalStorage
        if (!s || s.length === 0) s = _lsLoad(_folderHistKey) || ""
        // ③ Rating QSettings
        if (!s || s.length === 0) {
            try {
                if (typeof Rating !== "undefined" && Rating
                    && typeof Rating.loadString === "function") {
                    s = Rating.loadString(_folderHistKey, "") || ""
                }
            } catch (e) { s = "" }
        }
        if (!s || s.length === 0) return []
        var arr = []
        try { arr = JSON.parse(s) } catch (e) { return [] }
        if (!arr || !Array.isArray(arr)) return []
        // 仅保留字符串元素，去空
        var out = []
        for (var i = 0; i < arr.length; ++i) {
            var v = arr[i]
            if (typeof v === "string" && v.length > 0) out.push(v)
        }
        return out
    }
    // 把若干路径追加进「文件夹历史」（去重，FIFO 截断到 kMaxLanes）
    // 返回最终的历史数组
    function _appendToFolderHistory(paths) {
        if (!paths || paths.length === 0) return _loadFolderHistory()
        var hist = _loadFolderHistory()
        var seen = {}
        for (var i = 0; i < hist.length; ++i) seen[hist[i]] = true
        for (var k = 0; k < paths.length; ++k) {
            var p = paths[k]
            if (!p || typeof p !== "string" || p.length === 0) continue
            if (seen[p]) continue
            hist.push(p)
            seen[p] = true
        }
        // 超出上限：FIFO 丢弃最早的，保留最近 kMaxLanes 条
        if (hist.length > kMaxLanes) {
            hist = hist.slice(hist.length - kMaxLanes)
        }
        var json = ""
        try { json = JSON.stringify(hist) } catch (e) { json = "" }
        _saveFolderHistory(json)
        return hist
    }
    // 从「文件夹历史」中删除一条路径，并写回持久化
    function _removeFromFolderHistory(folderPath) {
        if (!folderPath) return
        var hist = _loadFolderHistory()
        var out = []
        for (var i = 0; i < hist.length; ++i) {
            if (hist[i] !== folderPath) out.push(hist[i])
        }
        if (out.length === hist.length) return  // 无变化
        var json = ""
        try { json = JSON.stringify(out) } catch (e) { json = "" }
        _saveFolderHistory(json)
    }

    function _persistLanes() {
        if (_restoring) return
        var arr = []
        for (var i = 0; i < _rowsModel.count; ++i) {
            var l = _rowsModel.get(i)
            if (!l) continue
            arr.push({
                selected:    !!l.selected,
                folderPath:  l.folderPath || "",
                keyword:     l.keyword || "",
                currentIndex: (typeof l.currentIndex === "number") ? l.currentIndex : -1
            })
        }
        var json = ""
        try { json = JSON.stringify(arr) } catch (e) { json = "" }
        try { console.log("[MGD] _persistLanes mode=", (Rating ? Rating.currentMode : "?"),
                          " file=", _cacheFile(),
                          " json=", json) } catch (e) { /* ignore */ }

        // ① cache 文件（主路：用户可见永久固化）
        var okFile = _fileSave(json)

        // ② LocalStorage（兜底）
        _lsSave(_persistKey, json)

        // ③ Rating QSettings（兜底，仅在 C++ 重编译后才有 saveString 方法）
        try {
            if (typeof Rating !== "undefined" && Rating
                && typeof Rating.saveString === "function") {
                Rating.saveString(_persistKey, json)
            }
        } catch (e) { /* ignore */ }

        if (!okFile) {
            // 仅做调试日志：cache 写失败时仍有 ②③ 兜底，但用户应该看到提示
            console.warn("[MultiGroupDialog] cache 文件写入失败：", _cacheFile())
        }
    }

    // 尝试恢复上次保存的 lanes；返回是否成功还原了至少 1 行。
    function _restoreLanes() {
        var s = ""
        try { console.log("[MGD] _restoreLanes BEGIN mode=", (Rating ? Rating.currentMode : "?"),
                          " cacheFile=", _cacheFile()) } catch (e) {}

        // ① 优先从 cache 文件读
        s = _fileLoad() || ""

        // ② 回退到 LocalStorage
        if (!s || s.length === 0) {
            s = _lsLoad(_persistKey) || ""
        }
        // ③ 再回退到 Rating QSettings
        if (!s || s.length === 0) {
            try {
                if (typeof Rating !== "undefined" && Rating
                    && typeof Rating.loadString === "function") {
                    s = Rating.loadString(_persistKey, "") || ""
                }
            } catch (e) { s = "" }
        }
        // ④ 兼容旧版本：当前模式无快照 → 读旧固定 key/文件名作为初始值，
        //    并迁移到当前模式槽位 + 立即清旧位，避免下次切到其它模式时
        //    被同一份旧数据污染（关键：旧数据只能落到"首次切到的模式"，
        //    其它模式仍以"空快照 → 默认 2 路"作为起点）。
        if (!s || s.length === 0) {
            var legacy = ""
            // legacy ① 旧 cache 文件
            try {
                var lp = _legacyCacheFile()
                if (lp && lp.length > 0 && typeof Fs.readTextFile === "function") {
                    legacy = Fs.readTextFile(lp) || ""
                }
            } catch (e) { legacy = "" }
            // legacy ② 旧 LocalStorage key
            if (!legacy || legacy.length === 0) {
                legacy = _lsLoad(_legacyPersistKey) || ""
            }
            // legacy ③ 旧 QSettings key
            if (!legacy || legacy.length === 0) {
                try {
                    if (typeof Rating !== "undefined" && Rating
                        && typeof Rating.loadString === "function") {
                        legacy = Rating.loadString(_legacyPersistKey, "") || ""
                    }
                } catch (e) { legacy = "" }
            }
            if (legacy && legacy.length > 0) {
                s = legacy
                // 把旧数据"复制"到当前模式槽位
                _fileSave(s)
                _lsSave(_persistKey, s)
                try {
                    if (typeof Rating !== "undefined" && Rating
                        && typeof Rating.saveString === "function") {
                        Rating.saveString(_persistKey, s)
                    }
                } catch (e) { /* ignore */ }
                // 清旧位：避免下次进入"其它模式"时重复迁移
                try {
                    var lp2 = _legacyCacheFile()
                    if (lp2 && lp2.length > 0 && typeof Fs.writeTextFile === "function") {
                        Fs.writeTextFile(lp2, "")
                    }
                } catch (e) { /* ignore */ }
                _lsSave(_legacyPersistKey, "")
                try {
                    if (typeof Rating !== "undefined" && Rating
                        && typeof Rating.saveString === "function") {
                        Rating.saveString(_legacyPersistKey, "")
                    }
                } catch (e) { /* ignore */ }
            }
        }
        if (!s || s.length === 0) {
            try { console.log("[MGD] _restoreLanes EMPTY (no snapshot)") } catch (e) {}
            return false
        }

        var arr = []
        try { arr = JSON.parse(s) } catch (e) { return false }
        if (!arr || !Array.isArray(arr) || arr.length === 0) return false
        try { console.log("[MGD] _restoreLanes DATA=", s) } catch (e) {}

        _restoring = true
        // 清空现有行（正常首次启动下这里 count == 0）
        while (_rowsModel.count > 0) {
            _rowsModel.remove(_rowsModel.count - 1)
        }
        _laneRuntime = []

        for (var i = 0; i < arr.length && i < kMaxLanes; ++i) {
            var rec = arr[i] || {}
            var folder = rec.folderPath || ""
            var kw     = rec.keyword || ""
            // 恢复历史一律不勾选：重启后不应出现任何"自动勾上"的路，
            // 是否参与启动完全由用户每次手动勾选决定（持久化的 selected 字段忽略）
            var sel    = false
            var savedIdx = (typeof rec.currentIndex === "number") ? rec.currentIndex : -1

            // 重新扫描文件夹（仅当为非空路径时）
            var allFiles = []
            if (folder && folder.length > 0) {
                try { allFiles = Fs.scanVideoFolderPath(folder, true) || [] } catch (e) { allFiles = [] }
            }
            // 应用关键字过滤 + 名称升序（与 MultiGroupRow._recomputeVisible 保持一致的默认顺序）
            var visible = _filterAndSort(allFiles, kw)

            var curIdx = -1
            if (visible.length > 0) {
                if (savedIdx >= 0 && savedIdx < visible.length) curIdx = savedIdx
                else curIdx = 0
            }
            var curPath = (curIdx >= 0 && curIdx < visible.length) ? visible[curIdx] : ""

            _laneRuntime.push({ allFiles: allFiles, visibleFiles: visible })
            _rowsModel.append({
                selected:    sel,
                folderPath:  folder,
                keyword:     kw,
                currentPath: curPath,
                currentIndex: curIdx,
                allCount:    allFiles.length,
                visibleCount: visible.length
            })
        }
        _restoring = false
        _bumpState()
        return _rowsModel.count > 0
    }

    // 自然序字符串比较（与 MultiGroupRow._natCompare 保持同一份实现）：
    // 把串切成"文本/数字"片段，文本按字典序，数字按数值比，从而保证
    // "1 < 2 < 10 < 11"。注意 Qt V4 不支持 localeCompare 的 {numeric:true} 选项，
    // 必须自己实现，否则会退化为字典序。
    function _natCompare(a, b) {
        var re = /(\d+)|(\D+)/g
        var pa = a.toLowerCase().match(re) || []
        var pb = b.toLowerCase().match(re) || []
        var n = Math.min(pa.length, pb.length)
        for (var i = 0; i < n; ++i) {
            var sa = pa[i], sb = pb[i]
            var na = /^\d+$/.test(sa)
            var nb = /^\d+$/.test(sb)
            if (na && nb) {
                var va = parseInt(sa, 10)
                var vb = parseInt(sb, 10)
                if (va !== vb) return va < vb ? -1 : 1
                if (sa.length !== sb.length) return sa.length < sb.length ? -1 : 1
            } else if (na !== nb) {
                return na ? -1 : 1
            } else {
                if (sa !== sb) return sa < sb ? -1 : 1
            }
        }
        return pa.length - pb.length
    }

    // 与 MultiGroupRow._recomputeVisible 逻辑同步：默认名称升序、过滤关键字不区分大小写。
    function _filterAndSort(files, kw) {
        var arr = (files || []).slice()
        var k = (kw || "").trim().toLowerCase()
        if (k.length > 0) {
            arr = arr.filter(function(p) { return p.toLowerCase().indexOf(k) >= 0 })
        }
        arr.sort(function(a, b) {
            return _natCompare(Fs.fileName(a), Fs.fileName(b))
        })
        return arr
    }

    // 最多 9 路（与 Engine 上限一致）
    readonly property int kMaxLanes: 9
    // 旧语义：多组对比至少 2 路；新语义下作为「是否进入多组对比态」的阈值使用，
    //        当勾选数 < 2 时仅走单文件夹打开，不会把 active 置 true。
    readonly property int kMinLanes: 2

    // ─── 对外属性 ───────────────────────────────────────────────────
    // 多组模式是否处于"已启动"状态：用户至少成功 start() 过一次，
    // 且 lanes 仍是当前打开的那一批（lanes 内容若被用户改动会自动失效）。
    property bool active: false
    onActiveChanged: console.log("[MGD][debug] active ->", active, "fileCount=", Engine.fileCount)

    // 当 Engine 中的视频被全部关闭（用户点"✕ 全部" / ⌘W / 菜单"关闭所有视频"等回到欢迎页）时，
    // 多组对比的"已启动"状态自然就失效了——继续保留 active=true 会让主界面残留
    // ⏮ / ⏭ / "1 / N" 等只在对比态下才有意义的控件。
    // 这里统一在 fileCount 归零时把 active 复位，保证 UI 与 Engine 的实际状态对齐。
    Connections {
        target: Engine
        function onFileCountChanged() {
            console.log("[MGD][debug] fileCountChanged -> fileCount=", Engine.fileCount, "active=", dlg.active)
            if (Engine.fileCount <= 0 && dlg.active) {
                console.log("[MGD][debug] reset active to false because fileCount=0")
                dlg.active = false
            }
        }
    }


    // 当前每路在自己 visibleFiles 中的索引（仅用于"上一组/下一组"导航；start() 时刷新）
    property var laneSnapshotPaths: []   // 上次启动时各路的 currentPath，用于检测是否需要重新 start
    property var laneSnapshotIndexes: [] // 上次启动时各路的 currentIndex

    // ─── 评分模式（review mode）────────────────────────────────────
    // 由 Main.qml 注入回调；reviewMode = true 时，翻上一组/下一组前要求当前组所有通道都已评分。
    //   - unratedChecker  : function() -> [idx, idx, ...] 返回未评分通道的索引列表（空数组=全部已评分）
    //   - getCellLabel    : function(idx) -> "通道 1 · xxx.mp4" 文案，仅用于提醒展示
    //   - onGoToRate      : function() 用户点"去评分"时的回调（通常关掉 dlg、聚焦主窗）
    //   - setRatingAt     : function(idx, score) 提醒弹窗内联评分时调用（复用主窗 _writeRating）
    // 三者任一为 null 时 reviewMode 直接跳过提醒、按原逻辑翻组，安全降级。
    //
    // 真值由 Rating.currentMode 派生：!= "off" → 评分态。
    // 这样"配置 → 选某种评分模式"的下拉菜单天然成为唯一来源，减少同步成本。
    readonly property bool reviewMode: (typeof Rating !== "undefined") && Rating.currentMode !== "off"
    property var  unratedChecker: null
    property var  getCellLabel: null
    property var  onGoToRate: null
    property var  setRatingAt: null
    // 开发者模式（由 Main.qml 注入）：勾选时模式选择菜单显示「测试模式」
    property bool developerMode: false
    // 模式选择菜单实际展示的列表：开发者模式未勾选时过滤掉「测试模式」
    readonly property var _visibleModeList: {
        var ml = (typeof Rating !== "undefined") ? Rating.modeList : []
        if (dlg.developerMode) return ml
        var out = []
        for (var i = 0; i < ml.length; ++i) {
            if (ml[i].id !== "test") out.push(ml[i])
        }
        return out
    }
    // 获取指定通道当前评分（由 Main.qml 注入）：function(idx) -> number | object
    // 多维模式返回 {key: stars, ...}，单维模式返回 number；未注入时返回 null
    property var  getCellRating: null
    // 多维评分模式支持（由 Main.qml 注入）
    property bool isMultiDimMode: false
    property var  reviewDimensions: []
    // quality_slide 模式下第二维度（滑动对比专用）的 key，由 Main.qml 注入。
    // 用于 allGroupsRated 检查每组两文件是否都有滑动评分。非该模式时为 ""。
    property string slideDimKey: ""
    // Checklist 配置（由 Main.qml 注入）：非空时 allGroupsRated 额外校验
    // 每个文件是否至少勾选一项（数据来源：Rating.loadString("checklist:"+filePath)）。
    property var  reviewChecklist: []
    // 每次维度更新时递增，供内层 Repeater 强制重新求值
    property int reviewDimensionsVersion: 0
    // 按 mode 缓存的维度列表（由 Main.qml 注入），切换 mode 时自动加载对应维度
    property var  dimsByMode: ({})
    // 有维度配置时（不限于 multi_dim 模式）走多维布局
    readonly property bool hasDims: reviewDimensions && reviewDimensions.length > 0
    // 启动对比时，如果是多维模式，Main.qml 注入此回调以静默加载最新维度配置
    property var  onDimLoadNeeded: null
    // 后端服务器地址（用于构造「查看规则」跳转 URL）
    property string uploadServerUrl: ""
    // 本地配置指纹（格式：{ "mode:configName": fp, "__bindings__": fp }）
    // 用于从当前模式反查绑定的 configName，构造规则页 URL
    property var localConfigFingerprint: null

    // 从 localConfigFingerprint 中查找当前模式绑定的 configName
    // 优先从 __bindings__ 读取（最新绑定关系），避免指纹里残留旧 key 导致返回错误配置名
    function _boundConfigName() {
        var mode = (typeof Rating !== "undefined") ? Rating.currentMode : ""
        if (!mode || mode === "off") return ""
        var fp = localConfigFingerprint
        if (!fp) return ""
        // 优先从 __bindings__ 读取：格式 JSON.stringify({ mode -> configName })
        var bindingsStr = fp["__bindings__"] || ""
        if (bindingsStr.length > 0) {
            try {
                var bindings = JSON.parse(bindingsStr)
                if (bindings && bindings[mode]) {
                    // 兼容新格式（数组）和旧格式（字符串）
                    var val = bindings[mode]
                    return Array.isArray(val) ? (val[0] || "") : val
                }
            } catch(e) {}
        }
        // 兜底：遍历 key（格式 "mode:configName"），取最后一个匹配（最新写入）
        var result = ""
        var keys = Object.keys(fp)
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i]
            if (k === "__bindings__") continue
            var sep = k.indexOf(":")
            if (sep < 0) continue
            if (k.substring(0, sep) === mode) result = k.substring(sep + 1)
        }
        return result
    }

    // 构造后端规则页面 URL：origin + /#rules/ + encodeURIComponent(configName)
    function _rulesPageUrl() {
        var base = uploadServerUrl.trim()
        if (base.length === 0) return ""
        var configName = _boundConfigName()
        if (configName.length === 0) return ""
        var m = base.match(/^(https?:\/\/[^/]+)/)
        var origin = m ? m[1] : base.replace(/\/$/, "")
        return origin + "/#rules/" + encodeURIComponent(configName)
    }

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
    function _bumpState() {
        stateBumper = stateBumper + 1
        // 联动：让 unratedDialog 里 checklist 相关的响应式属性重新计算
        // （unratedDialog 是本 dialog 的子组件，勾选变化 → 弹窗内提示与按钮态同步）
        try {
            if (typeof unratedDialog !== "undefined" && unratedDialog !== null)
                unratedDialog._ckBump = (unratedDialog._ckBump || 0) + 1
        } catch (e) {}
    }

    // 所有组的所有通道是否都已评分（供主窗控制栏显示"评分数据"快捷按钮）
    readonly property bool allGroupsRated: {
        var _ = stateBumper  // 触发响应式更新
        if (!active || !reviewMode) return false
        if (typeof Rating === "undefined") return false
        var n = Math.min(_rowsModel.count, _laneRuntime.length)
        if (n === 0) return false
        var totalGroups = groupCount()
        if (totalGroups <= 0) return false
        // 【quality_slide 特殊处理】除了第一维度按每文件检查，还要检查第二维度（滑动）
        // slide_type = "multi_<slideDimKey>" 是滑动打分，对每个 file_path 打一次分。
        var isQS = (typeof Rating !== "undefined") && Rating.currentMode === "quality_slide"
        var slideTag = (isQS && slideDimKey && slideDimKey.length > 0)
            ? ("multi_" + slideDimKey) : ""
        // 【Checklist 校验】有 checklist 配置时，每个文件必须至少勾选一项 checklist。
        // 数据存储在 Rating.loadString("checklist:" + filePath) 里，JSON 数组字符串。
        var hasChecklist = reviewChecklist
                && typeof reviewChecklist.length === "number"
                && reviewChecklist.length > 0
        // 遍历所有通道，检查每个通道的每个文件（每组）是否都有评分
        for (var li = 0; li < n; ++li) {
            var lane = _rowsModel.get(li)
            if (!lane || !lane.selected) continue
            var rt = _laneRuntime[li]
            if (!rt || !rt.visibleFiles) return false
            for (var fi = 0; fi < rt.visibleFiles.length; ++fi) {
                var fp = rt.visibleFiles[fi]
                if (!fp) return false
                if (hasDims) {
                    // 有维度：每个维度都需要有评分（这里 reviewDimensions 已由 Main.qml
                    // 通过 cellReviewDimensions 裁剪过——quality_slide 下不含第二维度）
                    for (var di = 0; di < reviewDimensions.length; ++di) {
                        var dimKey = reviewDimensions[di].key
                        var score = Rating.ratingFor(fp, "multi_" + dimKey)
                        if (!(score > 0)) return false
                    }
                } else {
                    var s = Rating.ratingFor(fp)
                    if (!(s > 0)) return false
                }
                // quality_slide：额外校验第二维度（滑动打分）每个文件都要有分
                if (slideTag.length > 0) {
                    var slideScore = Rating.ratingFor(fp, slideTag)
                    if (!(slideScore > 0)) return false
                }
                // Checklist：至少勾选一项才算完成
                if (hasChecklist) {
                    var rawCk = Rating.loadString("checklist:" + fp, "")
                    var ckCount = 0
                    if (rawCk && rawCk.length > 0) {
                        try {
                            var arrCk = JSON.parse(rawCk)
                            if (arrCk && typeof arrCk.length === "number") ckCount = arrCk.length
                        } catch (eCk) { ckCount = 0 }
                    }
                    if (ckCount === 0) return false
                }
            }
        }
        return true
    }

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

    // 空态占位卡点击后弹出的「首路文件夹选择」对话框。
    // 选中后复用 addFoldersToHistory，同一路径的扫描 / 去重 / 持久化逻辑。
    FolderDialog {
        id: firstFolderDlg
        title: "选择要导入的文件夹"
        currentFolder: dlg.effectiveDefaultFolderUrl
        onAccepted: {
            // selectedFolder 是 QUrl，addFoldersWithConfirm 内部已兼容 url / 本地路径，
            // 并会在检测到与已有路重复时弹出确认（让用户选择「再开一路」或「仅勾选已有」）。
            addFoldersWithConfirm([ selectedFolder ])
            // 同时固化「全局上次导入目录」，后续新增/打开都从这里起始
            try { _saveLastImportFolder(selectedFolder) } catch (e) { /* ignore */ }
        }
    }

    // ─── 「重复目录」确认对话框 ─────────────────────────────────
    // 触发时机：
    //   1) 拖拽 / 空态点 ➕ / 选文件夹 → 检测到目标路径已经存在于 lanes；
    //   2) 已有路 → 在 Row 内点 📁 选了和「其它路」相同的目录。
    // 行为：
    //   · 「再开一路」：调用强制版 addFoldersToHistory(...,{allowDuplicate:true})，
    //     给用户多一条与已有路同目录的新路（刻意制造同源对比）；
    //   · 「取消」：保持当前 lanes 不变（行内场景下连本路也不修改）。
    // 状态由 _pendingDup 暂存，避免使用 Promise/异步链。
    Dialog {
        id: dupConfirmDialog
        modal: true
        // 居中到主窗口
        anchors.centerIn: parent
        title: "重复导入提示"
        standardButtons: Dialog.NoButton
        // 暗色主题适配
        background: Rectangle {
            color: "#1f1f24"
            border.color: "#3a3a45"
            border.width: 1
            radius: 6
        }
        // 关闭时若仍未决议（窗口外点击/Esc），按"取消"语义处理
        onClosed: {
            if (_pendingDup && !_pendingDup._resolved) {
                _resolveDupCancel()
            }
        }

        contentItem: ColumnLayout {
            spacing: 12
            Label {
                Layout.fillWidth: true
                Layout.maximumWidth: 460
                wrapMode: Text.WordWrap
                color: "#e8e8ec"
                font.pixelSize: 13
                text: {
                    if (!_pendingDup) return ""
                    var paths = _pendingDup.dupPaths || []
                    if (paths.length === 0) return ""
                    var head = paths.length === 1
                        ? ("以下文件夹已经在列表中：\n" + paths[0])
                        : ("以下 " + paths.length + " 个文件夹已经在列表中：\n" + paths.join("\n"))
                    var tail = _pendingDup.mode === "row"
                        ? "\n\n是否仍然把当前路设为该目录？"
                        : "\n\n是否仍然再开一路（同目录可用于重复对比）？"
                    return head + tail
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: "取消"
                    onClicked: { _resolveDupCancel(); dupConfirmDialog.close() }
                    background: Rectangle {
                        color: parent.down ? "#3a3a45"
                              : parent.hovered ? "#2a2a32"
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
                    implicitHeight: 28
                    implicitWidth: 70
                }
                Button {
                    text: _pendingDup && _pendingDup.mode === "row" ? "确认覆盖本路" : "再开一路"
                    onClicked: { _resolveDupConfirm(); dupConfirmDialog.close() }
                    background: Rectangle {
                        color: parent.down ? "#0d8b73"
                              : parent.hovered ? "#119c80"
                                              : "#0fa085"
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "#ffffff"
                        font.pixelSize: 12
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    implicitHeight: 28
                    implicitWidth: 110
                }
            }
        }
    }

    // ─── 「接着评分 / 重置进度」选择弹窗 ──────────────────────────
    // 触发：启动按钮（_startWithResumeCheck）检测到当前模式有进度时弹出。
    // 作用域提示：标题/副标题强调"仅作用于当前模式（如 主观评分）"，避免误以为
    //   重置会清掉其它模式的进度。
    // 行为：
    //   · 接着评分：直接调 start() 然后关 dlg。
    //   · 重置进度：把"勾选+有效"路的 currentIndex 全部归零，再 start() + 关 dlg。
    //                 重置只写到当前模式槽位（_persistKey 已绑定 Rating.currentMode）。
    Dialog {
        id: resumeChoiceDialog
        modal: true
        anchors.centerIn: parent
        title: "继续评分？"
        standardButtons: Dialog.NoButton
        property var _info: null   // _collectResumeInfo 的返回值
        background: Rectangle {
            color: "#1f1f24"
            border.color: "#3a3a45"
            border.width: 1
            radius: 6
        }
        // 默认 header 是系统样式的白底标题栏，这里接管为深色，与整体主题一致。
        header: Rectangle {
            color: "#1f1f24"
            implicitHeight: 36
            radius: 6
            // 只让顶部两个角圆，避免与下方内容出现双重圆角
            Rectangle {
                anchors {
                    left: parent.left; right: parent.right; bottom: parent.bottom
                }
                height: parent.radius
                color: parent.color
            }
            Label {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                text: resumeChoiceDialog.title
                color: "#e8e8ec"
                font.pixelSize: 14
                font.bold: true
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
            // 底部分隔线
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: "#2c2c33"
            }
        }
        contentItem: ColumnLayout {
            spacing: 10
            // 作用域提示
            Label {
                Layout.fillWidth: true
                Layout.maximumWidth: 520
                text: "当前模式：" + _modeLabel()
                color: "#0fa085"
                font.pixelSize: 13
                font.bold: true
            }
            Label {
                Layout.fillWidth: true
                Layout.maximumWidth: 520
                wrapMode: Text.WordWrap
                color: "#bdbdc4"
                font.pixelSize: 12
                text: "检测到此模式上次的播放进度。是否接着上次的位置继续？\n注：「重置进度」会清空 " + _modeLabel() + " 模式下\"参与启动的这些文件夹\"的评分记录，进度自然回到第 1 个；不会影响其它评分模式、其它文件夹，也不会影响\"归档\"中的数据。"
            }
            // 进度明细：每路一行
            Frame {
                Layout.fillWidth: true
                Layout.maximumWidth: 520
                background: Rectangle {
                    color: "#15151a"
                    border.color: "#2c2c33"
                    border.width: 1
                    radius: 4
                }
                ColumnLayout {
                    spacing: 4
                    width: parent.width
                    Repeater {
                        model: resumeChoiceDialog._info ? (resumeChoiceDialog._info.items || []) : []
                        delegate: RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                color: "#e8e8ec"
                                font.pixelSize: 12
                                text: {
                                    var folder = (modelData.folderLabel && modelData.folderLabel.length > 0)
                                                    ? modelData.folderLabel : "（无文件夹）"
                                    return folder + " · " + (modelData.fileName || "—")
                                }
                            }
                            Label {
                                color: modelData.idx > 0 ? "#0fa085" : "#888"
                                font.pixelSize: 12
                                font.bold: modelData.idx > 0
                                text: (modelData.idx + 1) + " / " + (modelData.total || 0)
                            }
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: "取消"
                    onClicked: resumeChoiceDialog.close()
                    background: Rectangle {
                        color: parent.down ? "#3a3a45"
                              : parent.hovered ? "#2a2a32"
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
                    implicitHeight: 28
                    implicitWidth: 70
                }
                Button {
                    text: "重置进度"
                    onClicked: {
                        _resetSelectedLanesProgress()
                        resumeChoiceDialog.close()
                        if (start()) dlg.close()
                    }
                    background: Rectangle {
                        color: parent.down ? "#a04040"
                              : parent.hovered ? "#bf4848"
                                              : "#8a3030"
                        border.color: "#bf4848"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "#ffffff"
                        font.pixelSize: 12
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    implicitHeight: 28
                    implicitWidth: 90
                }
                Button {
                    text: "接着评分"
                    onClicked: {
                        // 把 _collectResumeInfo 推荐的 idx 写回 row，
                        // 让 start() 从"上次最后一次评分的下一个"开始播放。
                        // 仅当推荐 idx 比当前 row.currentIndex 大时才覆盖（不回退）。
                        try {
                            var info = resumeChoiceDialog._info || {}
                            var its = info.items || []
                            for (var ii = 0; ii < its.length; ++ii) {
                                var it = its[ii] || {}
                                var li = (typeof it._laneIndex === "number") ? it._laneIndex : -1
                                var ri = (typeof it._recommendIdx === "number") ? it._recommendIdx : -1
                                if (li < 0 || li >= _rowsModel.count) continue
                                if (ri < 0) continue
                                var lane = _rowsModel.get(li)
                                if (!lane) continue
                                var rt = _laneRuntime[li]
                                if (!rt || !rt.visibleFiles) continue
                                if (ri >= rt.visibleFiles.length) continue
                                if (typeof lane.currentIndex === "number" && lane.currentIndex >= ri) continue
                                _rowsModel.set(li, {
                                    selected:    lane.selected,
                                    folderPath:  lane.folderPath || "",
                                    keyword:     lane.keyword || "",
                                    currentPath: rt.visibleFiles[ri],
                                    currentIndex: ri,
                                    allCount:    lane.allCount || (rt.allFiles ? rt.allFiles.length : 0),
                                    visibleCount: lane.visibleCount || rt.visibleFiles.length
                                })
                                var rowItem = (typeof rowsRepeater !== "undefined" && rowsRepeater)
                                              ? rowsRepeater.itemAt(li) : null
                                if (rowItem && rowItem.currentIndex !== ri) rowItem.currentIndex = ri
                            }
                            _persistLanes()
                        } catch (e) { /* 安全降级：进入 start() */ }
                        resumeChoiceDialog.close()
                        if (start()) dlg.close()
                    }
                    background: Rectangle {
                        color: parent.down ? "#0d8b73"
                              : parent.hovered ? "#119c80"
                                              : "#0fa085"
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "#ffffff"
                        font.pixelSize: 12
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    implicitHeight: 28
                    implicitWidth: 90
                }
            }
        }
    }

    // 待决议的重复确认上下文（同一时刻仅一份）。
    // 字段：
    //   · mode: "batch" | "row"
    //   · dupPaths: 重复路径集合（用于文案展示）
    //   · dupUrls:  与 dupPaths 对应的原始 url 列表（用于走"再开一路"时强制新增）
    //   · onConfirm / onCancel: 决议回调
    //   · _resolved: 防止 onClosed 二次触发
    property var _pendingDup: null

    function _resolveDupConfirm() {
        if (!_pendingDup || _pendingDup._resolved) return
        _pendingDup._resolved = true
        var ctx = _pendingDup
        _pendingDup = null
        try { if (ctx.onConfirm) ctx.onConfirm() } catch (e) { /* ignore */ }
    }
    function _resolveDupCancel() {
        if (!_pendingDup || _pendingDup._resolved) return
        _pendingDup._resolved = true
        var ctx = _pendingDup
        _pendingDup = null
        try { if (ctx.onCancel) ctx.onCancel() } catch (e) { /* ignore */ }
    }

    // ─── 带「重复目录确认」的批量加路入口 ───────────────────────────
    // 把 urls 拆为 freshUrls / dupUrls：
    //   · freshUrls 立刻走 addFoldersToHistory 正常追加（新增路默认不勾选）；
    //   · dupUrls 非空 → 弹 dupConfirmDialog：
    //       - 用户「再开一路」  → 走强制版 addFoldersToHistory(dupUrls,{allowDuplicate:true})；
    //       - 用户「取消」      → 纯 no-op（不勾选已有路 —— 任何时候不替用户勾选）。
    function addFoldersWithConfirm(urls) {
        if (!urls || urls.length === 0) return []
        // 当前 lanes 中已存在的 folderPath 集
        var existing = {}
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            if (lane && lane.folderPath && lane.folderPath.length > 0) {
                existing[lane.folderPath] = true
            }
        }

        var freshUrls = []
        var dupUrls = []
        var dupPaths = []
        for (var k = 0; k < urls.length; ++k) {
            var u = urls[k]
            var p = ""
            try {
                if (typeof u === "string") {
                    p = (u.indexOf("file://") === 0) ? Fs.urlToLocalFile(u) : u
                } else {
                    p = Fs.urlToLocalFile(u)
                }
            } catch (e) { p = "" }
            if (existing[p]) {
                dupUrls.push(u)
                if (dupPaths.indexOf(p) < 0) dupPaths.push(p)
            } else {
                freshUrls.push(u)
            }
        }

        // 1) 先处理新路径（不需要确认）
        var hits = []
        if (freshUrls.length > 0) {
            try { hits = addFoldersToHistory(freshUrls) || [] } catch (e) { hits = [] }
        }

        // 2) 没有重复 → 直接结束
        if (dupUrls.length === 0) return hits

        // 3) 有重复 → 弹确认（异步；返回值仅包含已经同步处理的 fresh 部分）
        _pendingDup = {
            mode: "batch",
            dupPaths: dupPaths,
            dupUrls: dupUrls,
            _resolved: false,
            onConfirm: function() {
                try {
                    addFoldersToHistory(dupUrls, { allowDuplicate: true })
                } catch (e) { /* ignore */ }
            },
            onCancel: function() {
                // 兜底：保留旧的"重复时仅勾选已有"行为，避免拖拽完全没反馈
                try { addFoldersToHistory(dupUrls) } catch (e) { /* ignore */ }
            }
        }
        dupConfirmDialog.open()
        // 把重复路径也并入 hits 返回，便于 addFoldersAndShow 等需要"涉及到的路径"语义的调用方
        for (var di = 0; di < dupPaths.length; ++di) {
            if (hits.indexOf(dupPaths[di]) < 0) hits.push(dupPaths[di])
        }
        return hits
    }

    // ─── 行内「📁 选到与别路相同目录」的确认入口 ──────────────────
    // 由 MultiGroupRow.folderRequested(folderUrl, apply) 触发：
    //   · 不重复 → 立即 apply()。
    //   · 与「其它路」重复 → 弹确认；用户确认后 apply()，取消则保持 row 原状。
    // 注意：这里"重复"指的是与「其它路」相同；若与本路自身的 folderPath 相同，
    //       视为同样目录的重新扫描请求 → 也直接 apply（视为刷新）。
    function _confirmRowFolderPick(laneIdx, folderUrl, apply) {
        if (typeof apply !== "function") return
        if (laneIdx < 0 || laneIdx >= _rowsModel.count) { apply(); return }
        var newPath = ""
        try { newPath = Fs.urlToLocalFile(folderUrl) } catch (e) { newPath = "" }
        if (!newPath || newPath.length === 0) { apply(); return }

        var dupOther = false
        for (var i = 0; i < _rowsModel.count; ++i) {
            if (i === laneIdx) continue
            var l = _rowsModel.get(i)
            if (l && l.folderPath === newPath) { dupOther = true; break }
        }

        if (!dupOther) { apply(); return }

        // 弹确认：用户确认 → 让 row 自己 apply（写 folderPath/allFiles + 触发 folderImported）
        _pendingDup = {
            mode: "row",
            dupPaths: [ newPath ],
            dupUrls: [ folderUrl ],
            _resolved: false,
            onConfirm: function() { try { apply() } catch (e) { /* ignore */ } },
            onCancel:  function() { /* 保持 row 原状 */ }
        }
        dupConfirmDialog.open()
    }

    // ─── 多选文件夹一步入口（C++ FsUtils.pickMultipleFolders 桥接） ─────
    // 通过 Qt 自绘 QFileDialog（DontUseNativeDialog + ExtendedSelection）
    // 在【单一对话框】里让用户 Ctrl/Cmd/Shift 多选目录，一次添加多路。
    //
    // 设计要点：
    //   · 选中 N (≥1) 个目录 → 转成 file:// URL 列表喂给 addFoldersWithConfirm，
    //     完整复用「重复确认 / 历史合并 / 持久化」逻辑；
    //   · 用户取消 → 走 onCancel 回调（默认行为：emptyOrAdd，根据当前 lanes
    //     是否为空决定退化策略——空态时打开旧的 firstFolderDlg 单选兜底；
    //     已有 lanes 时退化为 addLane() 增加一个空行，让用户可以再点行内 📁）；
    //   · 起始目录用 effectiveDefaultFolderUrl 解析出的本地路径，没设过则空串
    //     由 C++ 侧回退到 HOME。
    //
    // fallbackOnCancel: "openSingle" / "addEmpty" / "none"
    //   · "openSingle"  → 取消时弹出旧 firstFolderDlg 单选兜底（空态卡用）
    //   · "addEmpty"    → 取消时调 addLane() 加空行（"➕ 新增一路"按钮用）
    //   · "none"        → 取消时什么都不做
    function _pickFoldersAndAddLanes(fallbackOnCancel) {
        if (typeof Fs === "undefined" || !Fs
            || typeof Fs.pickMultipleFolders !== "function") {
            // C++ 侧没暴露多选接口（理论上不会发生，留作防御性兜底）
            if (fallbackOnCancel === "openSingle") firstFolderDlg.open()
            else if (fallbackOnCancel === "addEmpty") addLane()
            return
        }

        // 起始目录：从 effectiveDefaultFolderUrl（QUrl）转成本地路径
        var startPath = ""
        try {
            var u = effectiveDefaultFolderUrl
            if (u && ("" + u).length > 0) {
                startPath = Fs.urlToLocalFile(u)
            }
        } catch (e) { startPath = "" }

        var paths = []
        try {
            paths = Fs.pickMultipleFolders("选择要导入的文件夹（可多选）", startPath) || []
        } catch (e) { paths = [] }

        if (!paths || paths.length === 0) {
            // 用户取消或选空 → 按调用方指定的退化策略处理
            if (fallbackOnCancel === "openSingle") firstFolderDlg.open()
            else if (fallbackOnCancel === "addEmpty") addLane()
            return
        }

        // 多路一次性追加；urlToFileUrls 在 C++ 侧统一处理 file:// 前缀。
        var urls = []
        try { urls = Fs.toFileUrls(paths) || [] } catch (e) { urls = [] }
        if (!urls || urls.length === 0) {
            if (fallbackOnCancel === "openSingle") firstFolderDlg.open()
            else if (fallbackOnCancel === "addEmpty") addLane()
            return
        }
        addFoldersWithConfirm(urls)

        // 固化"全局上次导入目录" —— 关键：用【第一个选中目录的父目录】，
        // 也就是用户当时所在的浏览目录。如果直接用选中目录本身（例如
        // …/app_test/ours_hyzm0509_6w），下次打开会进到子层级里，与
        // 用户预期不符（用户期望停留在 …/app_test 那一层继续浏览同级别目录）。
        try {
            var first = paths[0]
            if (first && first.length > 0) {
                // 取父目录：去掉末尾可能的 "/"，再砍到最后一个 "/"
                var p = first
                if (p.charAt(p.length - 1) === "/") p = p.substring(0, p.length - 1)
                var slash = p.lastIndexOf("/")
                var parent = (slash > 0) ? p.substring(0, slash) : p
                if (parent && parent.length > 0) {
                    var parentUrl = (parent.charAt(0) === "/") ? ("file://" + parent)
                                                               : ("file:///" + parent)
                    _saveLastImportFolder(parentUrl)
                }
            }
        } catch (e) { /* ignore */ }
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
            // 默认不勾选：任何场景都不替用户做勾选决定
            selected: false,
            folderPath: "",
            keyword: defaultKw,
            currentPath: "",
            currentIndex: -1,
            allCount: 0,
            visibleCount: 0
        })
        _laneRuntime.push({ allFiles: [], visibleFiles: [] })
        _bumpState()
        _persistLanes()
    }

    function removeLane(i) {
        if (i < 0 || i >= _rowsModel.count) return
        // 允许删到 0 路：删完后会显示一个大占位卡（点击新增 / 拖入文件夹），
        // 不再强制保留 1 行；旧版本里的 "if (count <= 1) return" 限制已移除。
        // 删除前记录 folderPath，便于同步从「文件夹历史」中也清除（否则下次打开会又合并回来）
        var lane = _rowsModel.get(i)
        var fp = (lane && lane.folderPath) ? lane.folderPath : ""
        _rowsModel.remove(i)
        _laneRuntime.splice(i, 1)
        _bumpState()
        _persistLanes()
        if (fp && fp.length > 0) {
            try { _removeFromFolderHistory(fp) } catch (e) { /* ignore */ }
        }
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
        _persistLanes()
    }

    // ─── 对外动作：启动 / 切组 ──────────────────────────────────────
    // 新语义：
    //   · 勾选 1 路  → 单视频浏览模式（只打开 currentPath 这一个），active=true，
    //                  「上一组/下一组」在该路 visibleFiles 内循环切换
    //   · 勾选 >=2 路 → 多组对比（每路 currentPath 组 url 列表），active=true

    // ─── 进度续看：「接着评分 / 重置」交互辅助 ───────────────────
    // 设计动机：
    //   每个评分模式（subjective / quality / off）独立记录每路 currentIndex。
    //   切到某模式 + 选好文件夹后，点「启动」时如果检测到当前模式的
    //   选中路里有任何 currentIndex > 0 的进度，弹出选择：
    //     · 接着评分 → 保留当前 currentIndex 直接 start()
    //     · 重置进度 → 把所有"勾选+有效"路的 currentIndex 重置为 0，再 start()
    //   重置仅作用于当前模式槽位（_persistKey/_persistFileName 已按模式派生），
    //   不会影响其他模式的进度。
    //
    // _collectResumeInfo() 返回 { hasProgress, items: [{label, idx, total}, ...] }
    //   · hasProgress：当前模式下是否存在"上次的进度"。判定方式有两条路（任一即可）：
    //       (a) row.currentIndex > 0 —— 沿用旧逻辑：用户翻过组、navigate 写过盘
    //       (b) 当前模式 CSV (Rating.ratingFor) 中存在该 lane 任意 visible 文件的评分
    //           —— 兼容"评了第一个就退出 app"的场景：此时 currentIndex 仍是 0，
    //              但用户实质已有进度；用 ratingFor 查一下就能识别。
    //              并把 idx 提升为"最后一个已评分项的下一个"，做最贴近用户预期的"继续评分"。
    //   · items：每路一条，仅含"勾选+有效"的路；用于弹窗罗列展示
    function _collectResumeInfo() {
        var items = []
        var hasProgress = false
        // 是否能向 RatingStore 查评分
        var canQueryRating = (typeof Rating !== "undefined" && Rating
                              && typeof Rating.ratingFor === "function"
                              && Rating.currentMode !== "off")
        for (var i = 0; i < _rowsModel.count; ++i) {
            var l = _rowsModel.get(i)
            if (!l || !l.selected) continue
            if (!l.currentPath || l.currentPath.length === 0) continue
            var total = l.visibleCount || 0
            var idx   = (typeof l.currentIndex === "number" && l.currentIndex >= 0)
                            ? l.currentIndex : 0

            // 通过 RatingStore 探测该 lane 已评分的最大 visible 索引（含 0 = 已取消评分行）
            // 注意：ratingFor 命中时返回 0..maxStars；未命中返回 -1。
            // 任一命中即视为"有进度"，并把推荐 idx 提到 lastRated + 1（不超过 total-1）。
            var lastRated = -1
            if (canQueryRating) {
                var rt = _laneRuntime[i]
                var vis = (rt && rt.visibleFiles) ? rt.visibleFiles : []
                for (var v = 0; v < vis.length; ++v) {
                    var got = -1
                    try { got = Rating.ratingFor(vis[v]) } catch (e) { got = -1 }
                    if (got >= 0) lastRated = v
                }
            }
            if (lastRated >= 0) {
                hasProgress = true
                // 推荐到下一个未评分项；若已评到最后一个，停在最后
                var nextIdx = Math.min(lastRated + 1, Math.max(0, total - 1))
                if (nextIdx > idx) idx = nextIdx
            }
            // 文件名（不带路径）
            var name = ""
            try {
                var p = l.currentPath
                var k = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
                name = (k >= 0) ? p.substring(k + 1) : p
            } catch (e) { name = "" }
            // 路径标签：直接用"完整文件夹路径"，与打开话框选中的展示对齐；
            // 只做“去掉末尾 '/' 与 '\\' ”的轻量规整（FolderDialog 返回的
            // 路径为 `/x/y/` 形式，去尾杠后含义一致）。
            // 超长路径依靠 Label.elide=ElideMiddle 自然省略。
            var folderLabel = ""
            try {
                var fp = l.folderPath || ""
                while (fp.length > 1
                       && (fp.charAt(fp.length - 1) === "/"
                           || fp.charAt(fp.length - 1) === "\\")) {
                    fp = fp.substring(0, fp.length - 1)
                }
                folderLabel = fp
            } catch (e) { folderLabel = "" }
            if (l.keyword && l.keyword.length > 0) {
                folderLabel = folderLabel + "（" + l.keyword + "）"
            }
            items.push({
                folderLabel: folderLabel,
                fileName: name,
                idx: idx,
                total: total,
                // 给"接着评分"分支用：把推荐 idx 同步回 row 时需要它
                _laneIndex: i,
                _recommendIdx: idx
            })
            if (idx > 0) hasProgress = true
        }
        // 调试日志：定位"为什么没弹窗"问题。看 Qt 控制台输出即可。
        try {
            console.log("[MGD] _collectResumeInfo mode=", (Rating ? Rating.currentMode : "?"),
                        " items=", JSON.stringify(items),
                        " hasProgress=", hasProgress)
        } catch (e) { /* ignore */ }
        return { hasProgress: hasProgress, items: items }
    }

    // 重置当前模式下「参与启动」的这些文件夹的评分进度。
    //
    // 行为（新语义）：
    //   1) 调 Rating.removeByFolders(folderPaths) —— 在当前模式的 CSV 中
    //      物理删除这些文件夹下所有视频的评分记录（不影响其它模式 CSV，
    //      也不影响"归档"目录里的数据，归档存放路径与主 CSV 隔离）；
    //   2) 把这些路的 row.currentIndex / model.currentIndex 归零，
    //      currentPath 置为 visibleFiles[0]，并写持久化（让 _restoreLanes
    //      下次也能从 0 开始）；
    //   3) 进度信息不再依赖"上次播放索引"——评分记录都没了，
    //      自然就从第 1 个开始。
    //
    // 仅作用于"勾选 + 有效（folderPath 非空 / visibleFiles 非空）"的路；
    // 未勾选/未参与启动的历史路保持不变。
    function _resetSelectedLanesProgress() {
        // ① 先收集要清空的文件夹列表（仅勾选 + 有 folderPath 的路）
        var folders = []
        for (var j = 0; j < _rowsModel.count; ++j) {
            var lj = _rowsModel.get(j)
            if (!lj || !lj.selected) continue
            if (!lj.folderPath || lj.folderPath.length === 0) continue
            folders.push(lj.folderPath)
        }
        // ② 调 RatingStore 物理删除当前模式下这些文件夹的评分记录
        //    Rating 单例 + removeByFolders 在 RatingsDialog 中已是稳定接口；
        //    返回值仅用于日志，不影响后续进度归零（即使没有任何记录命中也继续走）。
        if (folders.length > 0 && typeof Rating !== "undefined"
                && typeof Rating.removeByFolders === "function") {
            try { Rating.removeByFolders(folders) } catch (e) { /* 安全降级 */ }
        }
        // ③ 同步清空每个文件对应的 checklist 勾选记录（saveString 写空串即为清除）
        //    checklist key 格式：「checklist:<filePath>」，由 VideoCellDelegate 写入。
        if (typeof Rating !== "undefined" && typeof Rating.saveString === "function") {
            try {
                for (var ci = 0; ci < _rowsModel.count; ++ci) {
                    var cl = _rowsModel.get(ci)
                    if (!cl || !cl.selected) continue
                    var crt = _laneRuntime[ci]
                    if (!crt) continue
                    var cFiles = crt.allFiles || crt.visibleFiles || []
                    for (var cfi = 0; cfi < cFiles.length; ++cfi) {
                        var cfp = cFiles[cfi] || ""
                        if (cfp.length > 0) {
                            Rating.saveString("checklist:" + cfp, "")
                        }
                    }
                }
            } catch (e) { /* 安全降级 */ }
        }
        // ③ 把每条勾选路的进度归零（row + model 双写，保证 row 内部 property 也立即生效）
        for (var i = 0; i < _rowsModel.count; ++i) {
            var l = _rowsModel.get(i)
            if (!l || !l.selected) continue
            var rt = _laneRuntime[i]
            if (!rt || !rt.visibleFiles || rt.visibleFiles.length === 0) continue
            var ri = (typeof rowsRepeater !== "undefined" && rowsRepeater)
                        ? rowsRepeater.itemAt(i) : null
            // 直接写 model（保底，避免 row.currentIndex 已是 0 时 onCurrentIndexChanged 不触发）
            var firstPath = rt.visibleFiles[0] || ""
            _rowsModel.set(i, {
                selected:    l.selected,
                folderPath:  l.folderPath || "",
                keyword:     l.keyword || "",
                currentPath: firstPath,
                currentIndex: 0,
                allCount:    l.allCount || (rt.allFiles ? rt.allFiles.length : 0),
                visibleCount: l.visibleCount || rt.visibleFiles.length
            })
            // 强制把 row 内部 currentIndex 也归零（绕开 binding 失效的极端场景）
            if (ri && ri.currentIndex !== 0) ri.currentIndex = 0
        }
        _bumpState()
        _persistLanes()
    }
    // 启动按钮入口：先检查进度，再决定是否弹"接着 / 重置"
    // 返回 true → 已直接启动；false → 已弹窗（启动延后到用户选择）
    // 调用方：启动按钮 onClicked。dlg.close() 由弹窗回调里负责。
    property bool _startedFromResumeDialog: false
    function _startWithResumeCheck() {
        if (!canStart) return false
        var info = _collectResumeInfo()
        try { console.log("[MGD] _startWithResumeCheck hasProgress=", info.hasProgress) } catch (e) {}
        if (!info.hasProgress) {
            // 无进度，直接启动
            if (start()) dlg.close()
            return true
        }
        // 有进度 → 弹窗
        resumeChoiceDialog._info = info
        resumeChoiceDialog.open()
        return false
    }

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

    // ─── 拖拽专用入口：把多个文件夹注入为多路并启动多组对比 ───────
    // 触发时机：用户从 Finder/Explorer 一次拖入 ≥2 个文件夹到欢迎页。
    // 语义：
    //   · 这些文件夹会被「追加合并」进 lanes 列表（去重，最多 kMaxLanes 路），
    //     即「拖入即写入历史」—— 下次打开 Dialog 时这些路径仍能看到；
    //   · 启动时：把"本次拖入的这一批"作为参与启动的有效路（其它历史保留但不勾选）。
    // 入参 urls 元素可以是 file:// QUrl，也可以是本地路径字符串；
    // 仅扫描出至少 1 个视频的文件夹会被纳入。
    // 返回：true=已成功启动；false=没有有效文件夹。
    // 清理占位/失效 lane，为新导入腾出位置：
    //   1) 空槽位：「未导入」占位行（folderPath 为空，从未选过文件夹）——
    //      多为「➕ 新增一路」后未使用的残留，没有任何有效内容；
    //   2) 死路：folderPath 指向的目录已不存在于磁盘（如测试源被删除/移动）。
    // 它们会占满 kMaxLanes 名额，导致新导入失败。
    function _pruneStaleLanes() {
        var removed = 0
        for (var i = _rowsModel.count - 1; i >= 0; --i) {
            var l = _rowsModel.get(i)
            if (!l) continue
            var fp = l.folderPath || ""
            var isEmptySlot = (fp.length === 0)
            var isDead = (fp.length > 0 && !Fs.isDirectoryPath(fp))
            if (isEmptySlot || isDead) {
                removeLane(i)   // removeLane 会同步从文件夹历史里清除
                ++removed
            }
        }
        if (removed > 0) console.log("[MGD] _pruneStaleLanes 清理空槽/死路:", removed, "条")
        return removed
    }

    // 为"路数上限"腾位置：按优先级清理占位 lane，返回被移除的路名列表。
    //   ① 空槽位 / 死路（复用 _pruneStaleLanes）；
    //   ② 最旧的【未勾选】有效路（从下标 0 即最早添加的开始）。
    // 绝不自动删除【勾选中的有效路】——那是用户明确在用的工作区；
    // 清理结果通过 _evictNotice 在状态栏明确提示（非静默删除）。
    property string _evictNotice: ""
    function _evictForCapacity(needCount) {
        var evicted = []
        // ① 空槽 + 死路
        var before = _rowsModel.count
        _pruneStaleLanes()
        var pruned = before - _rowsModel.count
        for (var j = 0; j < pruned; ++j) evicted.push("（空槽/死路）")
        // ② 最旧未勾选有效路，直到腾出 needCount 个名额
        var target = Math.max(0, kMaxLanes - Math.min(needCount, kMaxLanes))
        while (_rowsModel.count > target) {
            var idx = -1
            for (var i = 0; i < _rowsModel.count; ++i) {
                var l = _rowsModel.get(i)
                if (l && !l.selected) { idx = i; break }
            }
            if (idx < 0) break   // 全是勾选中的路，绝不动
            var lane = _rowsModel.get(idx)
            evicted.push(lane.folderPath || "（空）")
            removeLane(idx)
        }
        if (evicted.length > 0) {
            console.log("[MGD] 为腾出上限名额自动移除:", evicted.join(" | "))
            _evictNotice = "⚠ 路数已满，已自动移除 " + evicted.length + " 条占位路"
            _evictNoticeTimer.restart()
        }
        return evicted
    }
    Timer {
        id: _evictNoticeTimer
        interval: 6000
        onTriggered: dlg._evictNotice = ""
    }

    function loadFolders(urls) {
        if (!urls || urls.length === 0) return false

        // 1) 先把这一批文件夹追加到历史 lanes（去重 + 持久化）
        var addedPaths = addFoldersToHistory(urls)
        // 路数撞上限（kMaxLanes）时：按优先级腾位置（空槽 → 死路 → 最旧未勾选），
        // 再重试一次。勾选中的路绝不动——若 9 路全在勾选，返回 false 让用户手动删。
        if ((!addedPaths || addedPaths.length === 0) && _rowsModel.count >= kMaxLanes) {
            console.log("[MGD] loadFolders: 路数已满，按优先级腾位置后重试")
            _evictForCapacity(urls.length)
            addedPaths = addFoldersToHistory(urls)
        }
        if (!addedPaths || addedPaths.length === 0) return false

        // 2) 启动：仅勾选「本次拖入」的那几路；其它历史路设为未勾选（保留但不参与启动）
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            if (!lane) continue
            var hit = (addedPaths.indexOf(lane.folderPath) >= 0)
            if (lane.selected !== hit) {
                _rowsModel.setProperty(i, "selected", hit)
            }
        }
        _bumpState()
        _persistLanes()
        return start()
    }

    // ─── 把若干文件夹路径「追加合并」进 lanes 历史（仅写入，不启动）──
    //   · 已存在同路径的 lane → 跳过（不重复添加）
    //   · 不在历史中且能扫出视频 → 追加为新 lane（默认 selected=false：
    //     打开/导入不再自动勾选，由用户手动勾选要参与启动的路）
    //   · 总数受 kMaxLanes 限制（满则停止追加）
    //   · 调用 _persistLanes() 持久化
    //   · 同时把所有有效文件夹路径写入独立的「文件夹历史」持久化（_appendToFolderHistory），
    //     即便后续 _rowsModel 被 loadFlatFiles 等覆盖，下次打开 Dialog 也能从文件夹历史
    //     恢复这些路径（onVisibleChanged → _mergeFolderHistoryIntoLanes()）。
    //   · 返回「本次实际新增/已存在的目标路径列表」（用于后续勾选锁定）
    //   · opts.allowDuplicate=true 时：对已存在 folderPath 也走「新增一路」分支
    //     （而不是跳过/仅勾选）。供「确认重复导入」流程使用。
    function addFoldersToHistory(urls, opts) {
        if (!urls || urls.length === 0) return []
        var allowDup = !!(opts && opts.allowDuplicate)

        // 收集已有 folderPath 集合（去重用）
        var existing = {}
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            if (lane && lane.folderPath && lane.folderPath.length > 0) {
                existing[lane.folderPath] = true
            }
        }

        var hitPaths = []  // 本次涉及到的目标路径（无论是新增还是已存在）

        for (var k = 0; k < urls.length; ++k) {
            if (_rowsModel.count >= kMaxLanes) {
                break
            }
            var u = urls[k]
            if (u === undefined || u === null) continue

            // 规范化：QUrl/字符串都转成本地目录路径，并扫描视频
            // 双路兜底：先按"原类型"扫一次；不行就转成另一种再扫一次。
            var files = []
            var folderPath = ""
            try {
                if (typeof u === "string") {
                    var s0 = u
                    if (s0.indexOf("file://") === 0) folderPath = Fs.urlToLocalFile(s0)
                    else                              folderPath = s0
                    files = Fs.scanVideoFolderPath(folderPath, true) || []
                    if (!files || files.length === 0) {
                        // 兜底：用 url 形式再扫一次
                        try { files = Fs.scanVideoFolder(s0, true) || [] } catch (e2) { /* ignore */ }
                    }
                } else {
                    // QUrl 对象
                    folderPath = Fs.urlToLocalFile(u)
                    files = Fs.scanVideoFolder(u, true) || []
                    if ((!files || files.length === 0) && folderPath) {
                        // 兜底：用本地路径再扫一次
                        try { files = Fs.scanVideoFolderPath(folderPath, true) || [] } catch (e3) { /* ignore */ }
                    }
                }
            } catch (e) {
                files = []
            }

            if (!folderPath || folderPath.length === 0) {
                continue
            }
            if (!files || files.length === 0) {
                continue
            }

            // 已在 lanes 中：
            //   · 默认行为：直接跳过，不再强制 selected=true ——
            //     "任何时候不替用户勾选"原则：重复拖入/选择也不自动勾上已有路，
            //     其余字段（keyword / currentIndex / currentPath）保留不动。
            //   · allowDuplicate=true：跳过该分支，继续走下方的「新增一路」逻辑，
            //     让用户得到一条与已有路同目录的新路（典型场景：刻意做同源对比）。
            if (existing[folderPath] && !allowDup) {
                if (hitPaths.indexOf(folderPath) < 0) hitPaths.push(folderPath)
                continue
            }

            // 新增 lane（与 addLane / loadFlatFiles 注入格式一致）
            // 默认不勾选：打开/导入文件夹只把路加进列表，是否参与启动由用户手动勾选决定
            var visible = _filterAndSort(files, "")
            _laneRuntime.push({ allFiles: files, visibleFiles: visible })
            _rowsModel.append({
                selected:     false,
                folderPath:   folderPath,
                keyword:      "",
                currentPath:  visible.length > 0 ? visible[0] : "",
                currentIndex: visible.length > 0 ? 0 : -1,
                allCount:     files.length,
                visibleCount: visible.length
            })
            existing[folderPath] = true
            hitPaths.push(folderPath)
        }

        if (hitPaths.length > 0) {
            _bumpState()
            _persistLanes()
            // 关键：写入独立的「文件夹历史」（路径固化，不受 lanes 覆盖式重置影响）
            _appendToFolderHistory(hitPaths)
        }
        return hitPaths
    }

    // ─── 把「文件夹历史」合并到 _rowsModel（视图层）─────────────────
    // 触发时机：Dialog 每次从隐藏 → 可见时调用一次（onVisibleChanged）。
    // 行为：
    //   · 读取独立的「文件夹历史」持久化；
    //   · 已存在同 folderPath 的 lane → 跳过（保持原 selected/keyword/currentIndex）；
    //   · 不存在的 → 追加为新 lane，**默认 selected=false**：避免影响当前正在播放的 lanes
    //     状态；用户在 Dialog 里手动勾选即可启用。
    //   · 受 kMaxLanes(=9) 上限保护：满则停止追加（历史中靠前的优先）。
    //   · 合并后会触发一次 _persistLanes() 同步 lanes 持久化。
    // 返回：本次实际新追加的路径数。
    function _mergeFolderHistoryIntoLanes() {
        var hist = _loadFolderHistory()
        if (!hist || hist.length === 0) return 0

        // 已有 folderPath 集合
        var existing = {}
        for (var i = 0; i < _rowsModel.count; ++i) {
            var lane = _rowsModel.get(i)
            if (lane && lane.folderPath && lane.folderPath.length > 0) {
                existing[lane.folderPath] = true
            }
        }

        var added = 0
        for (var k = 0; k < hist.length; ++k) {
            if (_rowsModel.count >= kMaxLanes) break
            var folderPath = hist[k]
            if (!folderPath || existing[folderPath]) continue

            // 重新扫描；扫不到任何视频就跳过（文件夹被删/移走的情况）
            var files = []
            try { files = Fs.scanVideoFolderPath(folderPath, true) || [] } catch (e) { files = [] }
            if (!files || files.length === 0) continue

            var visible = _filterAndSort(files, "")
            _laneRuntime.push({ allFiles: files, visibleFiles: visible })
            _rowsModel.append({
                selected:     false,                // 历史合并默认不勾选，避免误启动
                folderPath:   folderPath,
                keyword:      "",
                currentPath:  visible.length > 0 ? visible[0] : "",
                currentIndex: visible.length > 0 ? 0 : -1,
                allCount:     files.length,
                visibleCount: visible.length
            })
            existing[folderPath] = true
            added++
        }

        if (added > 0) {
            _bumpState()
            _persistLanes()
        }
        return added
    }

    // ─── 对外推荐的"打开"入口：合并最新文件夹历史 + 显示窗口 ────────
    // 仅靠 onVisibleChanged 在某些场景下可能不触发（例如 Window 已 visible=true
    // 仅被 raise/requestActivate 时），所以外部调用方一律走 showAndRefresh()，
    // 以保证每次"打开/激活" Dialog 都能把最新的文件夹历史同步进来；
    // 再叠加 onVisibleChanged 作为兜底。
    function showAndRefresh() {
        try { _mergeFolderHistoryIntoLanes() } catch (e) { /* ignore */ }
        _folderHistMerged = true
        // 每次打开自动清理空槽位（未导入的占位行）与死路（目录已失效），
        // 避免它们长期占用 kMaxLanes 名额堵死新导入
        _pruneStaleLanes()
        show()
        raise()
        requestActivate()
    }

    // ─── 拖入文件夹的统一入口 ─────────────────────────────────────
    // 行为（与"点击打开文件夹"统一）：
    //   1) 先把全部「文件夹历史」合并进 lanes —— 历史路径默认 **不勾选**；
    //   2) 再把本次拖入的文件夹追加为新 lane / 命中已有 lane —— 新增路默认 **不勾选**
    //      （是否参与启动完全由用户手动勾选决定）；
    //   3) 显示并置顶 Dialog，等同用户点击工具栏「打开文件夹」入口。
    // 调用方：dropZone / liveDropZone 在拖入时调用此方法，**不**再静默改播放队列。
    // 参数：urls —— QUrl 数组或字符串数组（file:// URL 或本地路径均可）。
    // 返回：本次涉及到的文件夹路径列表（命中 + 新增）。
    function addFoldersAndShow(urls) {
        // 1) 历史合并（默认不勾选）
        try { _mergeFolderHistoryIntoLanes() } catch (e) { /* ignore */ }
        _folderHistMerged = true

        // 2) 本次拖入：新增的默认不勾选；已存在的会触发"重复目录"确认
        //    （让用户决定再开一路还是仅勾选已有）。
        var hits = []
        try { hits = addFoldersWithConfirm(urls) || [] } catch (e) { hits = [] }

        // 3) 弹出 Dialog
        show()
        raise()
        requestActivate()
        return hits
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
        // 切宫格数会改变 currentIndex（按页对齐），同步落盘，避免重启后丢失。
        _persistLanes()
        return true
    }

    // 上一组 / 下一组：
    //   · 单路浏览模式（singleLaneMode=true）：以 viewCount 为步长翻页（循环），一次性打开 N 个
    //   · 多组对比模式：每路 ±1 循环切换
    // dir = -1 / +1
    function navigate(dir) {
        if (!active) return false
        if (dir !== -1 && dir !== 1) return false
        console.log("[MGD-NAV] navigate dir=" + dir + " reviewMode=" + reviewMode + " singleLaneMode=" + singleLaneMode)

        // ── 评分模式拦截：当前组若有未评分通道，先弹提醒 ─────────
        // 仅由 reviewMode 主动触发；未注入 unratedChecker 时直接跳过，安全降级。
        if (reviewMode && typeof unratedChecker === "function") {
            var missing = []
            try { missing = unratedChecker() || [] } catch (e) { missing = [] }
            if (missing.length > 0) {
                _pendingNavDir = dir
                _pendingMissing = missing
                unratedDialog.show()
                return false
            }
        }
        return _doNavigate(dir)
    }

    // 提醒弹窗"跳过"时调用：绕过 reviewMode 拦截，直接执行翻组。
    property int _pendingNavDir: 0
    property var _pendingMissing: []
    function _doNavigate(dir) {

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
            // 进度落盘：写入 cache／存储层，避免 app 重启后丢进度。
            // （不加这一句时，navigate 仅在内存里改 row.currentIndex，
            //   重启后 _restoreLanes 拿到的还是旧值，_collectResumeInfo
            //   会误判 hasProgress=false、不弹续评分对话框。）
            _persistLanes()
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
        var okOpen = Engine.openFiles(urls)
        if (okOpen) {
            // 进度落盘：写入 cache／存储层，避免 app 重启后丢进度。
            // 同 singleLaneMode 分支一样，不加这一句时多组对比下
            // navigate 后的进度也不会进入持久化，重启后“继续评分？”
            // 对话框将不会被触发。
            _persistLanes()
        }
        return okOpen
    }
    function nextGroup() { return navigate(1) }
    function prevGroup() { return navigate(-1) }

    // 当前组号 / 总组数（仅显示用）
    //   · 单路浏览模式：按页计算，groupCount = ceil(total / viewCount), groupIndex = floor(cur / viewCount)
    //   · 多组对比模式：仅统计「已勾选 selected=true」的路，取它们 visibleFiles.length 的最大值。
    //
    // 兼容历史记忆：_restoreLanes 会把"上次会话"的所有路（含未勾选的）一并还原到
    // _rowsModel/_laneRuntime，这些未勾选/未参与启动的路不应影响计数显示。
    // 旧实现遍历整个 _laneRuntime 取 max，会被历史残留路（如曾经一路 20 个视频）污染，
    // 出现"行内 1/2 共 2，但底部 2/20"的不一致；这里改为只看 selected=true 的路。
    // 注意：保留历史记忆功能本身不变，只是计数过滤掉未勾选的路。
    function groupCount() {
        var _ = stateBumper
        if (singleLaneMode) {
            var i = activeLaneIndex
            if (i < 0 || i >= _laneRuntime.length) return 0
            var rt = _laneRuntime[i]
            if (!rt || !rt.visibleFiles) return 0
            var step = Math.max(1, viewCount)
            return Math.ceil(rt.visibleFiles.length / step)
        }
        var maxN = 0
        var n = Math.min(_rowsModel.count, _laneRuntime.length)
        for (var k = 0; k < n; ++k) {
            var lane = _rowsModel.get(k)
            if (!lane || !lane.selected) continue
            var rtM = _laneRuntime[k]
            if (rtM && rtM.visibleFiles && rtM.visibleFiles.length > maxN)
                maxN = rtM.visibleFiles.length
        }
        return maxN
    }
    function groupIndex() {
        var _ = stateBumper
        if (singleLaneMode) {
            var i = activeLaneIndex
            if (i < 0 || i >= _rowsModel.count) return -1
            var lane = _rowsModel.get(i)
            if (!lane) return -1
            var step = Math.max(1, viewCount)
            return Math.floor(Math.max(0, lane.currentIndex) / step)
        }
        // 多组模式：取第一个「已勾选且 currentIndex>=0」的路当前位置
        for (var j = 0; j < _rowsModel.count; ++j) {
            var ln = _rowsModel.get(j)
            if (ln && ln.selected && ln.currentIndex >= 0) return ln.currentIndex
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
        // 启动即加载"全局上次导入目录"（轻量、可空，不影响主流程）
        _loadLastImportFolder()
        // 优先从本地记忆还原上次配置；首次启动或还原失败时才创建默认 2 路。
        if (_rowsModel.count === 0) {
            if (!_restoreLanes()) {
                addLane()
                addLane()
            }
        }
    }

    // ─── 全局拖拽承接区（有通路时启用） ───────────────────────────
    // 设计目标：用户进入 Dialog 后即使已经有若干路，也可以**直接把系统文件夹拖到对话框任意位置**
    //         （而不必先删空所有路、或先点 ➕ 再点 📁）。
    // 与 emptyDropArea 关系：
    //   · 空态时此区禁用（enabled=false），避免和 emptyDropArea 抢事件；
    //   · 有通路时此区生效，覆盖整个对话框；行内若有自己的 DropArea 会优先（嵌套子 DropArea 优先），
    //     当前 MultiGroupRow 没有 DropArea，所以拖到任意位置都会落到这里。
    DropArea {
        id: globalDropArea
        anchors.fill: parent
        z: -1  // 放到内容下层：视觉上完全不影响布局/点击；DropArea 处理拖拽事件不依赖 z
        enabled: _rowsModel.count > 0
        onEntered: function(drag) {
            if (!drag.hasUrls) { drag.accepted = false; return }
            drag.accept(Qt.CopyAction)
        }
        onDropped: function(drop) {
            if (!drop.hasUrls || drop.urls.length === 0) {
                drop.accepted = false
                return
            }
            // 复用「批量加路 + 重复目录确认」入口：
            //   · 文件夹扫描 / file:// → 本地路径；
            //   · 已存在 lane → 弹「重复目录」确认（再开一路 / 取消）；
            //   · 写入文件夹历史 + 持久化；
            //   · 自动跳过到达 kMaxLanes 上限的多余路径。
            addFoldersWithConfirm(drop.urls)
            drop.accept(Qt.CopyAction)
        }
    }

    // 拖入时的高亮蒙层（仅可视反馈，不接收事件）。
    // 用 anchors.fill 覆盖整个窗口，containsDrag 触发时画一圈高亮内描边 + 中央提示，
    // 让用户清晰知道"松手即可新增一路"。
    Rectangle {
        id: globalDropHint
        anchors.fill: parent
        z: 9999
        visible: globalDropArea.enabled && globalDropArea.containsDrag
        color: "#330fa085"  // 半透明高亮叠色
        border.color: "#0fa085"
        border.width: 2
        radius: 0
        // 不接收任何事件，保证不干扰底下控件
        // （DropArea / MouseArea / keyboard 全部继续工作）
        Rectangle {
            anchors.centerIn: parent
            width: hintLabel.implicitWidth + 28
            height: 40
            radius: 6
            color: "#1f1f24"
            border.color: "#0fa085"
            border.width: 1
            Label {
                id: hintLabel
                anchors.centerIn: parent
                text: "松开以新增一路（最多 " + kMaxLanes + " 路）"
                color: "#7fe5cc"
                font.pixelSize: 13
                font.bold: true
            }
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
                // 仅在「空态」时把 ColumnLayout 撑满 ScrollView 可见区，
                // 以便占位卡通过 Layout.fillHeight 铺满剩余空间；
                // 有通道时使用 implicitHeight，保持原本从顶部依次排列的布局，
                // 避免行被垂直居中/拉伸。
                height: _rowsModel.count === 0
                        ? rowsScroll.availableHeight
                        : implicitHeight
                spacing: 8

                Repeater {
                    id: rowsRepeater
                    model: _rowsModel
                    delegate: MultiGroupRow {
                        id: rowItem
                        Layout.fillWidth: true
                        laneIndex: index
                        selected: model.selected
                        folderPath: model.folderPath
                        keyword: model.keyword
                        currentIndex: model.currentIndex
                        // 任何一路都允许删除（含最后一路）；删到 0 路后会显示空态占位卡。
                        removable: true
                        // 关键：让"📁 选择文件夹"对话框的起始目录跟随全局上一次导入目录。
                        // 已选过 folderPath 的行内部会优先用自身 folderPath，所以这里的值
                        // 只对"未导入过的新行 / 全新打开"两种情况生效。
                        // 用 effectiveDefaultFolderUrl 而非 lastImportFolderUrl —— 老用户从未触发
                        // 过 _saveLastImportFolder 时也能从已有 lanes 的 folderPath 推断出回退值。
                        defaultFolderUrl: dlg.effectiveDefaultFolderUrl
                        // 任意一路成功选完文件夹 → 固化为新的全局上次目录
                        onFolderImported: function(folderUrl) {
                            dlg._saveLastImportFolder(folderUrl)
                        }
                        // 用户在该路上「选了」文件夹但还没应用 → 路由到父级做重复确认
                        onFolderRequested: function(folderUrl, apply) {
                            dlg._confirmRowFolderPick(index, folderUrl, apply)
                        }

                        // 初始化期内（属性绑定→ onCurrentIndexChanged / onSelectedChanged
                        // 等会先一步触发 laneChanged）若任由 _syncLaneFromRow 执行，
                        // 会把"还没注入 allFiles"的空状态写回 _laneRuntime，
                        // 导致历史导入被误清空（tooltip 还在 / 列表却未导入）。
                        // 这里用一个本地门闩：onCompleted 注入完 allFiles 之后再放行。
                        property bool _bootDone: false

                        Component.onCompleted: {
                            // 注入历史扫描结果（_laneRuntime 在 _restoreLanes 中预填）
                            var rt = _laneRuntime[index]
                            if (rt && rt.allFiles && rt.allFiles.length > 0) {
                                allFiles = rt.allFiles
                                // onAllFilesChanged → _recomputeVisible 会同步刷新 visibleFiles，
                                // 并保留有效的 currentIndex（_recomputeVisible 已支持保留逻辑）。
                                // 同步一次给模型，确保 allCount/visibleCount/currentPath 立刻正确：
                                _syncLaneFromRow(index, selected, folderPath, keyword,
                                                 allFiles, visibleFiles, currentIndex)
                            }
                            _bootDone = true
                        }
                        onLaneChanged: {
                            // 初始化阶段（_bootDone 为 false）忽略，避免空数组覆盖历史
                            if (!_bootDone) return
                            _syncLaneFromRow(index, selected, folderPath, keyword,
                                             allFiles, visibleFiles, currentIndex)
                        }
                        onRemoveRequested: removeLane(index)
                    }
                }

                // ─── 空状态占位卡（仅当一路都没有时显示）─────────────────
                // 设计目标：用户删除完所有路后，给一个清晰、显眼的入口，
                //   · 整卡可点 → 等价于「➕ 新增一路」（弹出该路自己的文件夹选择对话框）；
                //   · 支持把系统文件夹直接拖到这里：复用 addFoldersToHistory(urls)，
                //     一次拖多个文件夹会按 kMaxLanes 上限批量新增。
                Rectangle {
                    id: emptyDropCard
                    visible: _rowsModel.count === 0
                    Layout.fillWidth: true
                    // 未选任何路时让占位卡铺满列表区域，视觉上更明显、点击热区更大
                    Layout.fillHeight: true
                    Layout.minimumHeight: 140
                    radius: 8
                    color: emptyDropArea.containsDrag ? "#1f3a33"
                          : (emptyMouseArea.containsMouse ? "#23232a" : "#1a1a1f")
                    border.color: emptyDropArea.containsDrag ? "#0fa085" : "#3a3a45"
                    border.width: 1

                    // 虚线感：用一层略浅的内描边模拟（QML 没有原生 dashed border）
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        color: "transparent"
                        radius: 6
                        border.color: emptyDropArea.containsDrag ? "#0fa085" : "#4a4a55"
                        border.width: 1
                    }

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 4
                        Label {
                            text: "➕"
                            color: emptyDropArea.containsDrag ? "#7fe5cc" : "#9ec1ee"
                            font.pixelSize: 22
                            Layout.alignment: Qt.AlignHCenter
                        }
                        Label {
                            text: emptyDropArea.containsDrag
                                  ? "松开以添加文件夹"
                                  : "点击新增一路 / 拖拽文件夹到这里"
                            color: "#cfcfd6"
                            font.pixelSize: 13
                            Layout.alignment: Qt.AlignHCenter
                        }
                        Label {
                            text: "（支持一次拖入多个文件夹，最多 " + kMaxLanes + " 路）"
                            color: "#777"
                            font.pixelSize: 11
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }

                    MouseArea {
                        id: emptyMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // 未选任何路时，点「新增一路」不需要「先增空行再点 📁」两步，
                        // 直接弹出【多选】文件夹对话框，选完后一次性追加多路，
                        // 复用 addFoldersToHistory 的扫描 / 去重 / 持久化。
                        // 用户取消时退化到旧的单选 firstFolderDlg，避免“点了但什么也没发生”。
                        onClicked: _pickFoldersAndAddLanes("openSingle")
                    }

                    DropArea {
                        id: emptyDropArea
                        anchors.fill: parent
                        // 仅接受包含 url 的拖拽（系统文件/文件夹），过滤掉文本之类。
                        onEntered: function(drag) {
                            if (!drag.hasUrls) { drag.accepted = false; return }
                            drag.accept(Qt.CopyAction)
                        }
                        onDropped: function(drop) {
                            if (!drop.hasUrls || drop.urls.length === 0) {
                                drop.accepted = false
                                return
                            }
                            // 复用现成的「批量加路」入口：内部会做
                            //   · 文件夹扫描 / file:// → 本地路径；
                            //   · 已存在 lane → 弹「重复目录」确认（再开一路 / 取消）；
                            //   · 写入文件夹历史 + 持久化。
                            addFoldersWithConfirm(drop.urls)
                            drop.accept(Qt.CopyAction)
                        }
                    }
                }

                // ➕ 新增一行（已经有路时显示；空态下让位给上面的占位卡）
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    spacing: 12
                    visible: _rowsModel.count > 0
                    Button {
                        id: addLaneBtn
                        text: "➕ 新增一路"
                        enabled: _rowsModel.count < kMaxLanes
                        // 点击【多选】：弹出多选文件夹对话框，选中 N 个后一次性追加 N 路。
                        // 取消时退化为原来的「加一条空行」语义，用户仍可在空行内点 📁 逐个选。
                        onClicked: _pickFoldersAndAddLanes("addEmpty")
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

            // ⚙️ 配置：当前仅一个评分模式切换器，未来可扩展
            // reviewMode = (当前模式 != "off")，点中进入评分态；btn 文案 / 边框全从 Rating.currentMode 补。
            Button {
                id: configBtn
                text: {
                    if (typeof Rating === "undefined") return "⚙️ 配置"
                    if (Rating.currentMode === "off") return "⚙️ 配置"
                    // 从 modeList 里查当前模式的 label
                    var ml = Rating.modeList || []
                    for (var i = 0; i < ml.length; ++i) {
                        if (ml[i].id === Rating.currentMode) return "⚙️ " + ml[i].label
                    }
                    return "⚙️ 配置"
                }
                onClicked: {
                    // 已打开则收回（toggle），否则弹出
                    if (settingsPopup.visible) {
                        settingsPopup.close()
                        return
                    }
                    var p = configBtn.mapToItem(null, 0, 0)
                    settingsPopup.x = dlg.x + p.x
                    settingsPopup.y = dlg.y + p.y - settingsPopup.height - 4
                    settingsPopup.show()
                }
                background: Rectangle {
                    color: configBtn.down ? "#4a4a55"
                          : configBtn.hovered ? "#33333a"
                                              : "#202024"
                    border.color: reviewMode ? "#0fa085" : "#3a3a42"
                    border.width: 1
                    radius: 4
                }
                contentItem: Text {
                    id: configBtnText
                    text: configBtn.text
                    color: reviewMode ? "#0fa085" : "#e8e8ec"
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }
                implicitHeight: 30
                implicitWidth: Math.min(Math.max(configBtnText.implicitWidth + 20, 90), 220)
            }

            // 查看规则按钮：仅在已选中评分模式且后端有绑定配置时显示
            Button {
                id: viewRulesBtn
                visible: reviewMode && _rulesPageUrl().length > 0
                text: "查看规则 ↗"
                onClicked: Qt.openUrlExternally(_rulesPageUrl())
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: _rulesPageUrl()
                background: Rectangle {
                    color: viewRulesBtn.down    ? "#0a4a8a"
                          : viewRulesBtn.hovered ? "#1a5faa"
                                                 : "#152a4a"
                    border.color: "#2a6abf"
                    border.width: 1
                    radius: 4
                }
                contentItem: Text {
                    text: viewRulesBtn.text
                    color: "#7ab8f5"
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                implicitHeight: 30
                implicitWidth: 90
            }

            Label {
                color: "#9a9aa8"
                font.pixelSize: 11
                text: {
                    // 腾位置提示优先显示（几秒后由 _evictNoticeTimer 自动清空恢复）
                    if (dlg._evictNotice.length > 0) return dlg._evictNotice
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
                onClicked: {
                    // 先关掉评分模式弹出菜单（若还开着），再关主弹窗
                    if (settingsPopup.visible) settingsPopup.close()
                    dlg.close()
                }
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
                    // 直接用本地缓存配置启动（远程配置更新通过后台差异检测 + 通知卡片处理）
                    _startWithResumeCheck()
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

    // ─── 配置上拉菜单：选择评分模式（关闭 / 主观评分 / 质量比较）─────
    // 风格参考系统右键菜单 / 文件菜单：无标题、按项高、点击后选中，
    // 失焦自动隐藏（Qt.Popup flag 已自带）。
    Window {
        id: settingsPopup
        // 文案项数 = modeList.length + 1（"关闭" 项）；每项 32px + 上下 padding 8
        // 加入"（差/相当/好）"等括号说明后文案变长，宽度从 150 扩到 210，
        // 保证最长项"质量比较（差/相当/好）"能完整显示而不被截断。
        width: 210
        height: {
            // 用过滤后的可见列表（开发者模式关闭时不含「测试模式」）
            var n = dlg._visibleModeList.length
            return (n + 1) * 32 + 8
        }
        flags: Qt.Popup | Qt.FramelessWindowHint | Qt.NoDropShadowWindowHint
        color: "transparent"
        modality: Qt.NonModal

        Rectangle {
            anchors.fill: parent
            color: "#1f1f24"
            border.color: "#3a3a42"
            border.width: 1
            radius: 6

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 4
                spacing: 0

                // "关闭" 项：off 模式
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    radius: 4
                    color: offMA.containsMouse ? "#2c2c34" : "transparent"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8
                        Text {
                            Layout.preferredWidth: 16
                            text: (typeof Rating !== "undefined" && Rating.currentMode === "off") ? "✓" : ""
                            color: "#0fa085"
                            font.pixelSize: 14
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "关闭评分"
                            color: "#e8e8ec"
                            font.pixelSize: 13
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    MouseArea {
                        id: offMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof Rating !== "undefined") Rating.currentMode = "off"
                            settingsPopup.close()
                        }
                    }
                }

                // 从可见模式列表生成各评分模式项（开发者模式关闭时已过滤「测试模式」）
                Repeater {
                    model: dlg._visibleModeList
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 28
                        radius: 4
                        property var modeData: modelData
                        property bool _hover: itemMA.containsMouse
                        color: _hover ? "#2c2c34" : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 8
                            Text {
                                Layout.preferredWidth: 16
                                text: (typeof Rating !== "undefined" && Rating.currentMode === modeData.id) ? "✓" : ""
                                color: "#0fa085"
                                font.pixelSize: 14
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modeData.label
                                color: "#e8e8ec"
                                font.pixelSize: 13
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                        MouseArea {
                            id: itemMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (typeof Rating !== "undefined") Rating.currentMode = modeData.id
                                // 切换 mode 后，从缓存加载对应维度（避免多 mode 应用后维度互相覆盖）
                                var cached = (dlg.dimsByMode || {})[modeData.id]
                                if (cached && cached.length > 0) dlg.reviewDimensions = cached
                                settingsPopup.close()
                            }
                        }
                    }
                }

            }
        }
    }
    // ─── 未评分提醒弹窗：评分模式下翻组前的拦截 UI ─────────────
    // 列出当前组未评分的通道，每行右侧内联 5 颗星可直接评分；
    // 评完后该项从列表移除，全部评完时「去评分」变「继续翻组」。
    Window {
        id: unratedDialog
        width: 560
        height: dlg.hasDims ? Math.min(600, 200 + (dlg._pendingMissing || []).length * (dlg.reviewDimensions.length * 26 + 16)) : 320
        flags: Qt.Dialog | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
        color: "#161619"
        modality: Qt.ApplicationModal
        title: "评分模式 · 当前组尚未评分"
        // 居中到主对话框上方
        x: dlg.x + (dlg.width  - width)  / 2
        y: dlg.y + (dlg.height - height) / 2

        // 评分动作反馈 toast（右上角一闪而过，避免点击后无反馈）
        property string _toastText: ""
        Timer {
            id: _toastTimer
            interval: 900
            onTriggered: unratedDialog._toastText = ""
        }

        // 弹窗内对各通道的本地评分缓存：chIdx -> 1..5；评分后用于驻留显示星位。
        // 真实评分写入由 dlg.setRatingAt 完成，本字段仅用于 UI 展示，避免点快了不知道打了几分。
        property var _localRatings: ({})
        // 【Checklist 未勾选状态】响应式 bumper：外部主界面 checklist 勾选变化后会
        // 通过 dlg 触发 _ckBump++，让 _allRated / 文案 / 每行未勾提示重新求值。
        property int _ckBump: 0
        // 判断某通道是否 checklist 未勾（有 checklist 配置且该文件的持久化勾选为空）。
        // 供 _allRated 与详情行响应式使用；_ckBump 参数只用于建立依赖。
        function _isCkMissing(chIdx) {
            var _ = _ckBump  // 触达依赖
            if (chIdx < 0) return false  // sentinel（滑动 L/R）不参与 checklist
            var ck = dlg.reviewChecklist
            if (!(ck && typeof ck.length === "number" && ck.length > 0)) return false
            if (typeof Rating === "undefined") return false
            var fp = ""
            try { fp = Engine.filePathAt(chIdx) || "" } catch (e) { fp = "" }
            if (fp.length === 0) return true
            var raw = Rating.loadString("checklist:" + fp, "")
            if (!raw || raw.length === 0) return true
            try {
                var arr = JSON.parse(raw)
                return !(arr && typeof arr.length === "number" && arr.length > 0)
            } catch (e) { return true }
        }
        // 全部通道是否都已评分（基于 _pendingMissing 与 _localRatings 派生）
        readonly property bool _allRated: {
            var _b = _ckBump  // 建立对 checklist 变化的响应式依赖
            var arr = dlg._pendingMissing || []
            if (!arr.length) return true
            for (var i = 0; i < arr.length; ++i) {
                var chIdx = arr[i]
                var v = _localRatings[chIdx]
                if (dlg.hasDims) {
                    // 有维度：需要每个维度都 > 0
                    if (chIdx >= 0) {
                        if (typeof v !== "object" || v === null) return false
                        var dims = dlg.reviewDimensions
                        for (var d = 0; d < dims.length; ++d) {
                            if (!(v[dims[d].key] > 0)) return false
                        }
                    }
                } else {
                    if (chIdx >= 0 && (!v || v <= 0)) return false
                }
                // Checklist 校验：任一通道 checklist 未勾选也算未完成
                if (chIdx >= 0 && _isCkMissing(chIdx)) return false
            }
            return true
        }
        // 打开时从主界面 cellRatings 预填已有评分；关闭时清空缓存
        onVisibleChanged: {
            if (visible) {
                // 预填：把主界面已有评分同步进弹窗，避免已评分的通道显示空星
                var init = {}
                var missing = dlg._pendingMissing || []
                for (var i = 0; i < missing.length; ++i) {
                    var chIdx = missing[i]
                    if (chIdx < 0) continue
                    if (typeof dlg.getCellRating === "function") {
                        var existing = dlg.getCellRating(chIdx)
                        if (existing !== null && existing !== undefined) {
                        if (dlg.hasDims) {
                                // 有维度：复制对象，过滤掉 0 值（0 视为未评分）
                                if (typeof existing === "object") {
                                    var obj = {}
                                    var dims = dlg.reviewDimensions
                                    for (var d = 0; d < dims.length; ++d) {
                                        var k = dims[d].key
                                        obj[k] = (existing[k] > 0) ? existing[k] : 0
                                    }
                                    init[chIdx] = obj
                                }
                            } else {
                                if (existing > 0) init[chIdx] = existing
                            }
                        }
                    }
                }
                _localRatings = init
                _toastText = ""
                // 打开弹窗时触发一次 checklist 响应式，确保 _allRated 与文案基于最新持久化数据计算
                _ckBump = _ckBump + 1
            } else {
                _localRatings = ({})
                _toastText = ""
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Label {
                    text: {
                        var _b = unratedDialog._ckBump  // 建立 checklist 响应式依赖
                        var total = (dlg._pendingMissing || []).length
                        if (total === 0) return "✅ 当前组全部评分完成"
                        // 已在弹窗内完成的数量（星星维度）
                        var done = 0
                        // 未勾选 checklist 的通道数（不含 sentinel）
                        var ckMiss = 0
                        for (var i = 0; i < total; ++i) {
                            var chIdx = dlg._pendingMissing[i]
                            var v = unratedDialog._localRatings[chIdx]
                            var starOk = false
                            if (dlg.hasDims) {
                                if (typeof v === "object" && v !== null) {
                                    var dims = dlg.reviewDimensions
                                    var allOk = true
                                    for (var d = 0; d < dims.length; ++d) {
                                        if (!(v[dims[d].key] > 0)) { allOk = false; break }
                                    }
                                    if (allOk) starOk = true
                                } else if (chIdx < 0) {
                                    // sentinel：不参与星星统计
                                    starOk = true
                                }
                            } else {
                                if (chIdx < 0) starOk = true
                                else if (v && v > 0) starOk = true
                            }
                            if (starOk) done++
                            // Checklist 校验
                            if (chIdx >= 0 && unratedDialog._isCkMissing(chIdx)) ckMiss++
                        }
                        var starLeft = total - done
                        if (starLeft <= 0 && ckMiss <= 0) return "✅ 当前组全部评分完成"
                        var parts = []
                        if (starLeft > 0) parts.push(starLeft + " 个通道未评分")
                        if (ckMiss > 0) parts.push(ckMiss + " 个通道未勾选检查项")
                        return "🔔 当前组还有 " + parts.join("、")
                    }
                    color: "#e8e8ec"
                    font.pixelSize: 15
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
                Label {
                    visible: unratedDialog._toastText.length > 0
                    text: unratedDialog._toastText
                    color: "#0fa085"
                    font.pixelSize: 12
                    font.bold: true
                }
            }
            Label {
                text: {
                    if (unratedDialog._allRated) return "可点击「继续翻组」进入下一组。"
                    // 判断是否有 checklist 未勾选，给用户更明确的引导
                    var _b = unratedDialog._ckBump
                    var hasCkMiss = false
                    var arr = dlg._pendingMissing || []
                    for (var i = 0; i < arr.length; ++i) {
                        if (arr[i] >= 0 && unratedDialog._isCkMissing(arr[i])) { hasCkMiss = true; break }
                    }
                    if (hasCkMiss)
                        return "在下方直接点星号完成评分；⚠️ 检查项未勾选的通道请回到主界面点星星右侧展开 checklist 勾选。"
                    return "在下方直接点星号完成评分（也可在主界面使用 Shift+1~5 快捷键）。"
                }
                color: "#9a9aa8"
                font.pixelSize: 11
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }

            // 未评分通道列表：每行 = 文件名 + 5 颗星 + 清除
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#101013"
                border.color: "#2a2a32"
                border.width: 1
                radius: 4

                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 6
                    clip: true
                    ColumnLayout {
                        width: parent.width
                        spacing: 4
                        Repeater {
                            model: dlg._pendingMissing
                            delegate: Rectangle {
                                // 把外层 modelData（=通道 idx）提升为稳定属性，
                                // 防止被内层 Repeater 的 modelData/index 遮蔽。
                                property int chIdx: modelData
                                Layout.fillWidth: true
                                // 多维模式：文件名行(24) + checklist提示行(16可选) + 每维度行(22) + 间距；单维：固定32
                                implicitHeight: dlg.hasDims && chIdx >= 0
                                    ? 24 + (unratedDialog._isCkMissing(chIdx) ? 16 : 0) + dlg.reviewDimensions.length * 22 + 8
                                    : 32
                                color: "transparent"
                                radius: 3

                                // 有维度时：文件名在上，各维度星星在下（ColumnLayout）
                                ColumnLayout {
                                    visible: dlg.hasDims
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    anchors.topMargin: 4
                                    anchors.bottomMargin: 4
                                    spacing: 2

                                    Label {
                                        Layout.fillWidth: true
                                        color: "#cfcfd4"
                                        font.pixelSize: 12
                                        elide: Text.ElideMiddle
                                        text: {
                                            var idx = chIdx
                                            var label = ""
                                            if (typeof dlg.getCellLabel === "function") {
                                                try { label = dlg.getCellLabel(idx) || "" } catch (e) {}
                                            }
                                            if (!label) label = "通道 " + (idx + 1)
                                            return label
                                        }
                                    }

                                    // sentinel 提示（chIdx < 0）
                                    Label {
                                        visible: chIdx < 0
                                        text: chIdx === -2 ? "需在滑动模式打 L 分"
                                            : chIdx === -3 ? "需在滑动模式打 R 分"
                                            : ""
                                        color: "#ffb86c"
                                        font.pixelSize: 11
                                        font.italic: true
                                    }

                                    // Checklist 未勾选提示（响应式依赖 _ckBump）
                                    Label {
                                        visible: chIdx >= 0 && unratedDialog._isCkMissing(chIdx)
                                        text: "⚠️ 未勾选检查项：请在主界面点星星右侧 ☑ 展开勾选"
                                        color: "#ffb86c"
                                        font.pixelSize: 11
                                        font.italic: true
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }

                                    // 多维星星：每个维度一行
                                    Repeater {
                                        id: dimRepeaterDlg
                                        // 【关键】直接把整个数组作为 model：
                                        // 当 dlg.reviewDimensions 引用变化时，Repeater 会完全销毁重建所有 delegate，
                                        // 内层 Repeater 也随之全部重建，从新的 modelData 直接读 starCount。
                                        // chIdx < 0 时用空数组关闭 Repeater。
                                        model: chIdx >= 0 ? dlg.reviewDimensions : []
                                        delegate: Row {
                                            spacing: 4
                                            // 直接从 modelData 拿维度对象（delegate 重建时会带上最新数据）
                                            readonly property var dimData: modelData || null
                                            property string dimKey: dimData ? (dimData.key || "") : ""
                                            property int dimHover: -1
                                            Text {
                                                text: dimKey
                                                color: "#9a9aa8"
                                                font.pixelSize: 10
                                                width: 28
                                                horizontalAlignment: Text.AlignRight
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Repeater {
                                                // 直接从外层 delegate 的 dimData 取 starCount：
                                                // delegate 由外层 Repeater 重建时创建，dimData 就是最新维度对象
                                                model: {
                                                    var d = dimData
                                                    if (!d) return 5
                                                    if (d.starCount > 0) return d.starCount
                                                    return (d.levels && d.levels.length > 0) ? d.levels.length : 5
                                                }
                                                delegate: Item {
                                                    id: dimStarCell2
                                                    width: 20; height: 20
                                                    property int starOrder: index
                                                    property int curScore: {
                                                        var obj = unratedDialog._localRatings[chIdx]
                                                        if (typeof obj === "object" && obj !== null)
                                                            return obj[dimKey] || 0
                                                        return 0
                                                    }
                                                    property bool lit: parent.parent.dimHover >= 0
                                                        ? starOrder <= parent.parent.dimHover
                                                        : starOrder < curScore
                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: dimStarCell2.lit ? "★" : "☆"
                                                        color: dimStarCell2.lit ? "#ffd34d" : "#7a7a82"
                                                        font.pixelSize: 14
                                                    }
                                                    MouseArea {
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onEntered: parent.parent.parent.dimHover = starOrder
                                                        onExited:  parent.parent.parent.dimHover = -1
                                                        onClicked: {
                                                            var ch = chIdx
                                                            var sc = starOrder + 1
                                                            var dk = dimKey
                                                            if (typeof dlg.setRatingAt === "function") {
                                                                try { dlg.setRatingAt(ch, sc, dk) } catch (e) {}
                                                            }
                                                            var lr = unratedDialog._localRatings
                                                            var nr = {}
                                                            for (var k in lr) nr[k] = lr[k]
                                                            var oldObj = (typeof nr[ch] === "object" && nr[ch] !== null) ? nr[ch] : {}
                                                            var newObj = {}
                                                            for (var ok in oldObj) newObj[ok] = oldObj[ok]
                                                            newObj[dk] = sc
                                                            nr[ch] = newObj
                                                            unratedDialog._localRatings = nr
                                                            var stars = ""
                                                            for (var s = 0; s < sc; ++s) stars += "★"
                                                            unratedDialog._toastText = "通道" + (ch+1) + " " + dk + "：" + stars
                                                            _toastTimer.restart()
                                                            parent.parent.parent.dimHover = -1
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // 无维度时：文件名 + 星星横排（RowLayout）
                                RowLayout {
                                    visible: !dlg.hasDims
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 8

                                    Label {
                                        Layout.fillWidth: true
                                        color: "#cfcfd4"
                                        font.pixelSize: 12
                                        elide: Text.ElideMiddle
                                        verticalAlignment: Text.AlignVCenter
                                        text: {
                                            var idx = chIdx
                                            var label = ""
                                            if (typeof dlg.getCellLabel === "function") {
                                                try { label = dlg.getCellLabel(idx) || "" } catch (e) {}
                                            }
                                            if (!label) label = "通道 " + (idx + 1)
                                            return label
                                        }
                                    }

                                    // sentinel 提示（chIdx < 0）
                                    Label {
                                        visible: chIdx < 0
                                        text: chIdx === -1 ? "需进入滑动对比 (按 B)"
                                            : chIdx === -2 ? "需在滑动模式打 L 分"
                                            : chIdx === -3 ? "需在滑动模式打 R 分"
                                            : ""
                                        color: "#ffb86c"
                                        font.pixelSize: 11
                                        font.italic: true
                                    }
                                    // 单维星星
                                    Row {
                                        visible: chIdx >= 0
                                        spacing: 2
                                        Repeater {
                                            model: (chIdx >= 0 && typeof Rating !== "undefined" && Rating.maxStars > 0) ? Rating.maxStars : 0
                                            delegate: Rectangle {
                                                property int starOrder: index
                                                property int curScore: {
                                                    var v = unratedDialog._localRatings[chIdx]
                                                    return v ? v : 0
                                                }
                                                property bool litFilled: starMA.containsMouse
                                                                          ? false
                                                                          : (starOrder < curScore)
                                                width: 22; height: 22
                                                color: starMA.containsMouse ? "#2c2c34" : "transparent"
                                                radius: 3
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: (starMA.containsMouse || litFilled) ? "★" : "☆"
                                                    color: {
                                                        if (starMA.containsMouse) return "#ffd34d"
                                                        if (litFilled) return "#ffd34d"
                                                        return "#7a7a82"
                                                    }
                                                    font.pixelSize: 16
                                                    font.bold: true
                                                }
                                                MouseArea {
                                                    id: starMA
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        var ch = chIdx
                                                        var sc = starOrder + 1
                                                        if (typeof dlg.setRatingAt === "function") {
                                                            try { dlg.setRatingAt(ch, sc) } catch (e) {}
                                                        }
                                                        var lr = unratedDialog._localRatings
                                                        var nr = {}
                                                        for (var k in lr) nr[k] = lr[k]
                                                        nr[ch] = sc
                                                        unratedDialog._localRatings = nr
                                                        var stars = ""
                                                        for (var s = 0; s < sc; ++s) stars += "★"
                                                        unratedDialog._toastText = "通道 " + (ch + 1) + " 评分：" + stars
                                                        _toastTimer.restart()
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

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    text: "取消"
                    onClicked: unratedDialog.close()
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

                Item { Layout.fillWidth: true }

                Button {
                    text: "跳过本次"
                    visible: !unratedDialog._allRated
                    onClicked: {
                        var d = dlg._pendingNavDir
                        unratedDialog.close()
                        // 绕过 reviewMode 拦截直接翻组
                        if (d === -1 || d === 1) dlg._doNavigate(d)
                    }
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
                    implicitWidth: 90
                }

                // 评分未完 → 「去评分」；全部评完 → 「继续翻组」
                Button {
                    id: actionBtn
                    text: unratedDialog._allRated ? "继续翻组" : "去评分"
                    onClicked: {
                        if (unratedDialog._allRated) {
                            // 全部评完：直接翻组
                            var d = dlg._pendingNavDir
                            unratedDialog.close()
                            if (d === -1 || d === 1) dlg._doNavigate(d)
                        } else {
                            // 还有未评分：关闭多组对话框，让用户回主窗操作
                            unratedDialog.close()
                            if (typeof dlg.onGoToRate === "function") {
                                try { dlg.onGoToRate() } catch (e) {}
                            }
                            dlg.close()
                        }
                    }
                    background: Rectangle {
                        color: actionBtn.down ? "#0a8f76"
                              : actionBtn.hovered ? "#0db092"
                                                  : "#0fa085"
                        border.color: "#0fa085"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: actionBtn.text
                        color: "#ffffff"
                        font.pixelSize: 12
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    implicitHeight: 30
                    implicitWidth: 100
                }
            }
        }
    }
}