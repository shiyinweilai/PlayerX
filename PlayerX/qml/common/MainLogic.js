// MainLogic.js — 由 Main.qml 拆出的纯逻辑函数（_init 注入 root 与桥接对象）。
// 注意：QML 信号可能在 Component.onCompleted 之前触发，此时 _root 未注入。
// 用空对象兜底，防止 "Cannot read property 'xxx' of null" 崩溃。
var _root = {}
var _updateToast = null
var _testSourceDownloadDialog = null
var _testSourceGroupDialog = null
var _testSourceRedownloadDialog = null
var _multiGroupDialog = null
var _dimReloadTimer = null
var _ratingsDialog = null
var _ratingToast = null
var _initialized = false

function isInitialized() { return _initialized }

// 兜底：从全局对象自动获取 root 对象（Main.qml 在属性绑定中注册）
function _tryAutoInit() {
    if (_initialized) return
    try {
        if (typeof Qt !== "undefined" && Qt._playerXRoot) {
            _root = Qt._playerXRoot
            _initialized = true
            console.log("[Init] _tryAutoInit 成功（Qt._playerXRoot）")
            return
        }
    } catch(e) { console.warn("[Init] _tryAutoInit 失败:", e) }
    console.warn("[Init] _tryAutoInit 失败，_root 仍为未初始化")
}

function _init(ctx) {
    _root = ctx.root
    _initialized = true
    _updateToast = ctx.updateToast
    _testSourceDownloadDialog = ctx.testSourceDownloadDialog
    _testSourceGroupDialog = ctx.testSourceGroupDialog
    _testSourceRedownloadDialog = ctx.testSourceRedownloadDialog
    _multiGroupDialog = ctx.multiGroupDialog
    _dimReloadTimer = ctx.dimReloadTimer
    _ratingsDialog = ctx.ratingsDialog
    _ratingToast = ctx.ratingToast
}

function _parseChecklistExclusiveKey(obj) {
    if (!obj) return ""
    if (obj.checklist_config && obj.checklist_config.exclusive_key)
        return String(obj.checklist_config.exclusive_key)
    var items = obj.checklists
    if (items && typeof items.length === "number") {
        for (var i = 0; i < items.length; ++i) {
            if (items[i] && items[i].exclusive === true && items[i].key)
                return String(items[i].key)
        }
    }
    return ""
}

function _syncChecklistWhitelist() {
    if (typeof Rating === "undefined") return
    var arr = _root.reviewChecklist || []
    var keys = []
    for (var i = 0; i < arr.length; i++) {
        var it = arr[i]
        if (!it) continue
        // 兼容两种形态：{key,label,definition,...} 对象 / 或纯字符串
        var k = (typeof it === "string") ? it : (it.key || "")
        if (k && keys.indexOf(k) === -1) keys.push(k)
    }
    Rating.setExportChecklistWhitelist(keys, true)
}

function _loadBuiltinDefaultConfigs() {
    var modes = ["subjective", "quality", "quality_slide", "multi_dim", "test"]
    var bd = {}, bc = {}, bt = {}
    if (typeof Fs === "undefined" || typeof Fs.readTextFile !== "function") return
    for (var i = 0; i < modes.length; ++i) {
        var mode = modes[i]
        try {
            var text = Fs.readTextFile(_resourcesDir() + "/default_configs/" + mode + ".json") || ""
            if (text.length === 0) continue
            var obj = JSON.parse(text)
            if (!obj) continue
            if (obj.dimensions && typeof obj.dimensions.length === "number" && obj.dimensions.length > 0)
                bd[mode] = obj.dimensions
            if (obj.checklists && typeof obj.checklists.length === "number" && obj.checklists.length > 0)
                bc[mode] = { items: obj.checklists, exclusiveKey: _parseChecklistExclusiveKey(obj) }
            if (typeof obj.tag === "string" && obj.tag.length > 0)
                bt[mode] = obj.tag
        } catch (e) {
            console.warn("[DefaultCfg] 内置默认读取失败 mode=", mode, e)
        }
    }
    _root._builtinDimsByMode = bd
    _root._builtinChecklistByMode = bc
    _root._builtinTagByMode = bt
    console.log("[DefaultCfg] 内置默认配置加载完成：dims=", Object.keys(bd).join(","),
        " checklist=", Object.keys(bc).join(","), " tag=", Object.keys(bt).join(","))
}

function _dimsForMode(mode) {
    var ov = (_root._dimsByMode && mode) ? _root._dimsByMode[mode] : null
    if (ov && typeof ov.length === "number" && ov.length > 0) return ov
    return _root._builtinDimsByMode[mode] || null
}

function _checklistForMode(mode) {
    var ov = (_root._checklistByMode && mode) ? _root._checklistByMode[mode] : null
    if (ov && ov.items && typeof ov.items.length === "number" && ov.items.length > 0) return ov
    return _root._builtinChecklistByMode[mode] || null
}

function _tagForMode(mode) {
    if (_root._tagByMode && typeof _root._tagByMode[mode] === "string" && _root._tagByMode[mode].length > 0)
        return _root._tagByMode[mode]
    return _root._builtinTagByMode[mode] || ""
}

function _applyModeConfigToUI(mode) {
    if (!mode || mode === "off") return
    var dimsRaw = _dimsForMode(mode)
    if (dimsRaw && typeof dimsRaw.length === "number" && dimsRaw.length > 0) {
        var dims = []
        for (var _i = 0; _i < dimsRaw.length; _i++) {
            var d = dimsRaw[_i]
            var sc = (d && d.levels && typeof d.levels.length === "number" && d.levels.length > 0) ? d.levels.length : 5
            dims.push(Object.assign({}, d, { starCount: sc }))
        }
        _forceApplyDimensions(dims, _tagForMode(mode), mode, "applyModeConfig")
    }
    var ck = _checklistForMode(mode)
    if (ck && ck.items && typeof ck.items.length === "number" && ck.items.length > 0) {
        var items = []
        for (var _j = 0; _j < ck.items.length; _j++) items.push(ck.items[_j])
        _root.reviewChecklist = items
        _root.reviewChecklistExclusiveKey = ck.exclusiveKey || ""
    } else {
        _root.reviewChecklist = []
        _root.reviewChecklistExclusiveKey = ""
    }
    var tag = _tagForMode(mode)
    if (tag.length > 0) {
        _root._remoteTag = tag
        if (typeof Rating !== "undefined" && Rating.uploadTag !== tag) Rating.uploadTag = tag
    }
}

function _restoreDefaultConfig(mode) {
    if (!mode || mode === "off") return false
    var label = mode
    try {
        var ml = Rating.modeList
        for (var i = 0; i < ml.length; ++i) if (ml[i].id === mode) { label = ml[i].label; break }
    } catch (e) {}
    if (!_root._builtinDimsByMode[mode] && !_root._builtinChecklistByMode[mode] && !_root._builtinTagByMode[mode]) {
        _root._configCheckSummary = "「" + label + "」没有内置默认配置"
        return false
    }
    var changed = false
    if (_root._dimsByMode && _root._dimsByMode[mode] !== undefined) {
        var dm = {}
        for (var k1 in _root._dimsByMode) if (k1 !== mode) dm[k1] = _root._dimsByMode[k1]
        _root._dimsByMode = dm
        _saveDimsByMode()
        changed = true
    }
    if (_root._checklistByMode && _root._checklistByMode[mode] !== undefined) {
        var cm = {}
        for (var k2 in _root._checklistByMode) if (k2 !== mode) cm[k2] = _root._checklistByMode[k2]
        _root._checklistByMode = cm
        _saveChecklistByMode()
        changed = true
    }
    if (_root._tagByMode && _root._tagByMode[mode] !== undefined) {
        var tm = {}
        for (var k3 in _root._tagByMode) if (k3 !== mode) tm[k3] = _root._tagByMode[k3]
        _root._tagByMode = tm
        _saveTagByMode()
        changed = true
    }
    // 当前模式立即生效（覆盖层已清，查询会命中内置默认）
    var curMode = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
    if (curMode === mode) _applyModeConfigToUI(mode)
    _root._configCheckSummary = changed
            ? ("已恢复「" + label + "」的内置默认配置（远程覆盖已清除）")
            : ("「" + label + "」当前就是内置默认配置")
    console.log("[DefaultCfg] 恢复默认 mode=", mode, "清掉覆盖:", changed)
    return true
}

function _canonicalDimsJson(dims) {
    if (!dims || typeof dims.length !== "number") return ""
    var out = []
    for (var i = 0; i < dims.length; ++i) {
        var d = dims[i] || {}
        var lv = []
        var levels = d.levels || []
        for (var j = 0; j < levels.length; ++j) {
            var l = levels[j] || {}
            lv.push({ score: l.score, label: l.label, description: l.description })
        }
        out.push({ key: d.key, definition: d.definition, levels: lv })
    }
    return JSON.stringify(out)
}

function _canonicalChecklistJson(entry) {
    if (!entry) return ""
    var items = []
    var arr = entry.items || []
    for (var i = 0; i < arr.length; ++i) {
        var it = arr[i] || {}
        items.push({ key: it.key, label: it.label, definition: it.definition, exclusive: !!it.exclusive })
    }
    return JSON.stringify({ items: items, exclusiveKey: entry.exclusiveKey || "" })
}

function _pruneOverridesEqualToBuiltin() {
    var dm = {}, dimsChanged = false
    for (var k1 in (_root._dimsByMode || {})) {
        var ov = _root._dimsByMode[k1], bd = _root._builtinDimsByMode[k1]
        if (bd && _canonicalDimsJson(ov) === _canonicalDimsJson(bd)) { dimsChanged = true; continue }
        dm[k1] = ov
    }
    if (dimsChanged) { _root._dimsByMode = dm; _saveDimsByMode(); console.log("[DefaultCfg] 清理与内置一致的 dims 覆盖") }
    var cm = {}, ckChanged = false
    for (var k2 in (_root._checklistByMode || {})) {
        var oc = _root._checklistByMode[k2], bc = _root._builtinChecklistByMode[k2]
        if (bc && _canonicalChecklistJson(oc) === _canonicalChecklistJson(bc)) { ckChanged = true; continue }
        cm[k2] = oc
    }
    if (ckChanged) { _root._checklistByMode = cm; _saveChecklistByMode(); console.log("[DefaultCfg] 清理与内置一致的 checklist 覆盖") }
    var tm = {}, tagChanged = false
    for (var k3 in (_root._tagByMode || {})) {
        var ot = _root._tagByMode[k3], bt = _root._builtinTagByMode[k3]
        if (bt && ot === bt) { tagChanged = true; continue }
        tm[k3] = ot
    }
    if (tagChanged) { _root._tagByMode = tm; _saveTagByMode(); console.log("[DefaultCfg] 清理与内置一致的 tag 覆盖") }
}

function _saveDimsByMode() {
    try {
        var path = _resourcesDir() + "/dimsByMode.json"
        if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
            EngineBridge.writeTextFile(path, JSON.stringify(_root._dimsByMode || {}))
        }
    } catch (e) {
        console.warn("[DimSave] 保存 dimsByMode.json 失败：", e)
    }
    // 同步持久化 checklistByMode.json
    _saveChecklistByMode()
}

function _saveChecklistByMode() {
    try {
        var path = _resourcesDir() + "/checklistByMode.json"
        if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
            EngineBridge.writeTextFile(path, JSON.stringify(_root._checklistByMode || {}))
        }
    } catch (e) {
        console.warn("[ChecklistSave] 保存 checklistByMode.json 失败：", e)
    }
}

function _saveTagByMode() {
    try {
        var path = _resourcesDir() + "/tagByMode.json"
        if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
            EngineBridge.writeTextFile(path, JSON.stringify(_root._tagByMode || {}))
        }
    } catch (e) {
        console.warn("[TagSave] 保存 tagByMode.json 失败：", e)
    }
}

function _setTagForMode(mode, tag) {
    if (!mode || mode === "off") return
    var m = JSON.parse(JSON.stringify(_root._tagByMode || {}))
    m[mode] = tag || ""
    _root._tagByMode = m
    _saveTagByMode()
}

function _rebuildCellRatingsFromCsv(reason) {
    if (typeof Engine === "undefined") return
    var n = Engine.fileCount
    if (n <= 0) return
    var arr = []
    var dims = _root.reviewDimensions
    // quality_slide 模式下只取第一个维度用于普通打分，第二个维度留给滑动对比
    if (_root.isQualitySlideMode && dims && dims.length >= 2)
        dims = [dims[0]]
    var hasDims = dims && dims.length > 0
    for (var i = 0; i < n; ++i) {
        var fp = Engine.filePathAt(i)
        if (hasDims) {
            // 有维度配置时（不限于 multi_dim 模式）：每项初始化为对象，从 CSV 按 slide_type 回填各维度
            var obj = {}
            for (var d = 0; d < dims.length; ++d) {
                var dimKey = dims[d].key
                var saved = -1
                if (typeof Rating !== "undefined" && fp && fp.length > 0) {
                    saved = Rating.ratingFor(fp, "multi_" + dimKey)
                }
                obj[dimKey] = (typeof saved === "number" && saved >= 1 && saved <= 5) ? saved : 0
            }
            arr.push(obj)
        } else {
            var v = -1
            if (typeof Rating !== "undefined" && fp && fp.length > 0) {
                v = Rating.ratingFor(fp)
            }
            arr.push((typeof v === "number" && v >= 1 && v <= 5) ? v : 0)
        }
    }
    _root.cellRatings = arr
    // quality_slide：先清零再从 CSV 恢复本组已有的滑动评分，
    // 避免循环切组时评分被清零，同时防止上一组评分残留。
    _resetSlideRatings()
    _restoreSlideRatings()
    console.log("[RebuildRatings] reason=", reason || "-", " 回填完成，n=", n,
                "，hasDims=", hasDims, "，dims=",
                hasDims ? dims.map(function(x){return x.key}).join(",") : "(none)")
}

function _forceApplyDimensions(dims, tag, forMode, reason) {
    // 【关键】QML property var 里存的数组读回来常常不是纯 JS Array（会被包装成 QJSValue/QVariantList），
    // Array.isArray 会返回 false，导致这里静默 return。
    // 因此先判断 length（duck-typing），再转成纯 JS 数组，避免误早退。
    if (!dims) {
        console.warn("[ForceApply] ⚠️ dims 为空，跳过。reason=", reason || "-", "forMode=", forMode || "-")
        return
    }
    if (typeof dims.length !== "number" || dims.length <= 0) {
        console.warn("[ForceApply] ⚠️ dims 无有效 length，跳过。reason=", reason || "-", "forMode=", forMode || "-", "typeof:", typeof dims)
        return
    }
    // 统一转成纯 JS 数组，后续操作（map、赋值给 property var）都用它
    var pureDims = []
    for (var _i = 0; _i < dims.length; _i++) pureDims.push(dims[_i])
    dims = pureDims
    var curMode = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
    // 【二重防线】只要传入了 forMode 且与当前 mode 不一致，直接拦截，避免污染当前 UI
    if (forMode && curMode && forMode !== curMode) {
        console.warn("[ForceApply] ⚠️ 拒绝跨模式刷新 UI！forMode=", forMode, "currentMode=", curMode,
            "reason=", reason || "-",
            "，dims=", dims.map(function(d){return d.key+"("+(d.starCount||(d.levels&&d.levels.length)||5)+"星)"}).join(","))
        return
    }
    console.log("[ForceApply] 开始强制刷新 → reason=", reason || "-",
        "forMode=", forMode || "-", "currentMode=", curMode,
        "，dims=", dims.map(function(d){return d.key+"("+(d.starCount||(d.levels&&d.levels.length)||5)+"星)"}).join(","))
    _root._applyingConfig = true
    _root._pendingDimsToApply = dims
    _root._pendingTagToApply = tag || ""
    // 阶段1：清空数组，外层 Repeater 立即销毁所有 delegate
    _root.reviewDimensions = []
    _root.reviewDimensionsVersion = _root.reviewDimensionsVersion + 1
    // 阶段2：稍后重建（Timer 触发时赋新值）
    _dimReloadTimer.restart()
}

function _configFingerprint(obj) {
    if (!obj) return ""
    try {
        return JSON.stringify(obj)
    } catch (e) { return "" }
}

function _hintRemoteTaskEmpty(hiddenCount, hiddenForRater) {
    // 【静默策略】用户要求点🔔后无可见项时不再弹任何 toast 提示
    // （避免右侧"开启开发者模式后可见"这种打扰性横幅）。
    // 静默并不影响功能：开发者模式未开启时被隐藏的任务依然可在开启后查看。
    return
}

// 判断一项远程配置对当前用户是否"可见"：
//   · 开发者模式开启 → 全部可见（拥有绝对访问权限）；
//   · 否则先按 mode === "test" 隐藏；再按 testSource.groups / testSource.groupMap
//     是否命中当前评分人来隐藏「测试源自动化」任务（避免无差打扰）。
// 跨模块共用，避免 _checkRemoteConfigUpdate 与 Main._remoteConfigCardList 规则撕裂。
function _isRemoteItemVisibleForUser(it) {
    if (_root.developerMode) return true
    if (!it) return true
    if ((it.mode || "") === "test") return false
    var obj = (it && it.obj) || {}
    var ts = obj.testSource
    if (!ts || typeof ts !== "object") return true   // 非测试源任务，不过滤
    var rater = ""
    try {
        if (typeof Rating !== "undefined") {
            rater = String(Rating.currentUser || "").trim()
            if (rater.length === 0 && typeof Rating.systemUserName === "function")
                rater = String(Rating.systemUserName() || "").trim()
        }
    } catch (e) {}
    if (rater.length === 0) return false             // 未登录 / 无系统用户名 → 全部隐藏
    var gs = ts.groups
    if (gs && typeof gs === "object" && !Array.isArray(gs)) {
        for (var name in gs) {
            var arr = gs[name]
            if (Array.isArray(arr) && arr.indexOf(rater) >= 0) return true
        }
    }
    var raw = String(ts.groupMap || "").trim()
    if (raw.length > 0) {
        var entries = raw.split(/[,，;；\n]+/)
        for (var i = 0; i < entries.length; ++i) {
            var kv = entries[i].split(/[:：]/)
            if (kv.length >= 2 && kv[0].trim() === rater) return true
        }
    }
    return false
}

function _checkRemoteConfigUpdate(onNoUpdate, openCardOnNoUpdate) {
    // 兜底：如果 _root 未注入，尝试从 QML 引擎获取
    if (!_initialized) {
        _tryAutoInit()
    }
    if (!_initialized) { console.warn("[TaskUpdate] _root 未初始化，跳过"); return }
    var base = _dimApiUrl()
    if (base.length === 0) return  // 未配置服务器，跳过

    // 第一步：拉取所有模式绑定
    var activeUrl = base.replace(/\/api\/dimensions.*$/, '') + "/api/active-config"
    var xhr0 = new XMLHttpRequest()
    var _done0 = false
    var _t0 = Qt.createQmlObject('import QtQuick 2.0; Timer { interval: 8000; repeat: false }', root)
    _t0.triggered.connect(function() { if (!_done0) { _done0 = true; xhr0.abort() } _t0.destroy() })
    _t0.start()
    xhr0.onreadystatechange = function() {
        if (xhr0.readyState !== XMLHttpRequest.DONE) return
        if (_done0) return
        _done0 = true
        _t0.stop()
        if (xhr0.status !== 200 && xhr0.status !== 0) return
        try {
            var activeObj = JSON.parse(xhr0.responseText)
            if (!activeObj || !activeObj.bindings) return
            var bindings = activeObj.bindings  // { mode -> configName[] }
            var modes = Object.keys(bindings)
            if (modes.length === 0) return

            // 对比绑定关系是否发生变化（用 JSON.stringify 排序后对比）
            var sortedBindings = {}
            modes.slice().sort().forEach(function(m) { sortedBindings[m] = bindings[m] })
            var bindingsFp = JSON.stringify(sortedBindings)
            var localBindingsFp = (_root._localConfigFingerprint || {})["__bindings__"] || ""

            // 第二步：展开为 (mode, configName) 对，并发请求每个绑定配置的内容
            var configBase = base.replace(/\/api\/dimensions.*$/, '') + "/api/configs/"
            var pending = []   // 收集有差异的 { mode, obj, configName }
            // 【手动应用】收集"远程当前绑定的全部配置"（含已是最新的），
            // 供"无更新时"也让用户能主动应用任意远程配置作为启动项。
            var allFetched = []
            // 展开所有 (mode, configName) 对
            var allPairs = []
            modes.forEach(function(m) {
                var names = bindings[m]
                if (!Array.isArray(names)) names = [names]  // 兼容旧字符串格式
                names.forEach(function(n) { allPairs.push({ mode: m, configName: n }) })
            })
            var total = allPairs.length
            var finished = 0

            function onAllDone() {
                if (!_initialized) { _tryAutoInit() }
                if (!_initialized) { console.warn("[TaskUpdate] onAllDone: _root 未初始化，跳过"); return }
                // 【手动应用】无论有无差异，都把"远程当前绑定的全部配置"存下来，
                // 供卡片在无更新时也展示完整列表、每条带"应用"按钮。
                _root._remoteAllConfigs = allFetched.slice()
                if (pending.length === 0) {
                    // 无更新（含首次启动静默应用完毕）：把当前 mode 的维度同步到 reviewDimensions
                    // 这样首次启动时用户无需手动应用，打开评分规则面板就能看到配置
                    var curMode = (typeof Rating !== "undefined") ? Rating.currentMode : ""
                    if (curMode && curMode !== "off") {
                        var curDims = _dimsForMode(curMode)
                        if (curDims && curDims.length > 0 && _root && _root.reviewDimensions && _root.reviewDimensions.length === 0) {
                            _root.reviewDimensions = curDims
                            _root.reviewDimensionsVersion++
                            console.log("[ConfigCheck] 首次启动静默加载 mode=", curMode, "维度数:", curDims.length)
                        }
                        // 【修复】同步 reviewChecklist：_checklistByMode 在首次启动时已按 mode 填充，
                        // 但 reviewChecklist 属性没有在 onAllDone 里更新，导致点星星时为空
                        // 【QML 陷阱】property var 里存的数组读出来是 QJSValue/QVariantList，
                        // Array.isArray() 返回 false，必须用 length duck-typing 判断，并转纯 JS 数组
                        var ckForCurMode = _checklistForMode(curMode)
                        console.log("[ChecklistDebug] onAllDone curMode=", curMode,
                            " _checklistByMode keys=", Object.keys(_root._checklistByMode || {}).join(","),
                            " ckForCurMode=", JSON.stringify(ckForCurMode),
                            " isArray(items)=", (ckForCurMode ? Array.isArray(ckForCurMode.items) : "N/A"),
                            " items.length=", (ckForCurMode && ckForCurMode.items ? ckForCurMode.items.length : "N/A"))
                        var _hasCkItems = ckForCurMode && ckForCurMode.items
                                && typeof ckForCurMode.items.length === "number"
                                && ckForCurMode.items.length > 0
                        if (_hasCkItems) {
                            // 转成纯 JS 数组，避免 QJSValue 类型问题
                            var _plainItems = []
                            for (var _ci = 0; _ci < ckForCurMode.items.length; _ci++) {
                                _plainItems.push(ckForCurMode.items[_ci])
                            }
                            _root.reviewChecklist = _plainItems
                            _root.reviewChecklistExclusiveKey = ckForCurMode.exclusiveKey || ""
                            console.log("[ConfigCheck] 首次启动同步 checklist mode=", curMode, "条数:", _plainItems.length)
                        } else {
                            _root.reviewChecklist = []
                            _root.reviewChecklistExclusiveKey = ""
                            console.log("[ConfigCheck] 首次启动 checklist 为空 mode=", curMode)
                        }
                    }
                    // 回调通知调用方（用于🔔按钮的 tooltip "没有更新"提示）
                    // 【手动应用】无差异时把卡片打开（仅当用户主动检测时，
                    // openCardOnNoUpdate=true；后台静默轮询保持不打扰）。
                    // 卡片展示远程当前绑定的全部配置 + 每条"应用"按钮，
                    // 让用户能主动选择远程配置作为启动项。
                    _root._remoteHasUpdate = false
                    if (openCardOnNoUpdate) {
                        // 可见列表非空才开卡片；为空（仅剩测试模式任务或评分人未命中）
                        // → 不开空卡片，改轻提示告知原因
                        if (_root._remoteConfigCardList.length > 0) {
                            _root._taskUpdateVisible = true
                        } else {
                            _root._taskUpdateVisible = false
                            // 区分两类隐藏原因：测试模式 / 未绑定当前评分人
                            var hiddenTest = 0, hiddenForRater = 0
                            for (var _hi2 = 0; _hi2 < allFetched.length; ++_hi2) {
                                var _vIt = allFetched[_hi2]
                                if (_isRemoteItemVisibleForUser(_vIt)) continue
                                if ((_vIt.mode || "") === "test") hiddenTest++
                                else hiddenForRater++
                            }
                            _hintRemoteTaskEmpty(hiddenTest, hiddenForRater)
                        }
                    }
                    if (typeof onNoUpdate === "function") onNoUpdate()
                    return
                }
                // 有差异：合并到已有列表（避免覆盖用户已部分应用的条目）
                // key = mode + ":" + configName，同一 mode 可有多个配置
                var existing = Array.isArray(_root._pendingRemoteConfig) ? _root._pendingRemoteConfig : []
                var merged = existing.slice()
                pending.forEach(function(newItem) {
                    var found = false
                    var newKey = newItem.mode + ":" + newItem.configName
                    for (var k = 0; k < merged.length; k++) {
                        var existKey = merged[k].mode + ":" + merged[k].configName
                        if (existKey === newKey) { merged[k] = newItem; found = true; break }
                    }
                    if (!found) merged.push(newItem)
                })
                _root._pendingRemoteConfig = merged
                // 开发者模式未开启时，遵循"免打扰"规则：
                //   · 隐藏 mode === "test" 的测试模式任务；
                //   · 隐藏"测试源自动化任务"中组别映射不含当前评分人的项。
                // pending 数据保留，开启开发者模式后可见（开发者拥有绝对访问权限）。
                // 但手动点 🔔 时，_remoteAllConfigs 中可能还有非测试模式/已命中的
                // "当前最新"项值得展示给用户主动选择应用，因此只要卡片列表非空就打开。
                var _visiblePending = merged.filter(_isRemoteItemVisibleForUser)
                if (_visiblePending.length > 0) {
                    _root._taskUpdateVisible = true
                } else if (openCardOnNoUpdate && _root._remoteConfigCardList.length > 0) {
                    // 无可见 pending，但仍有可应用的远程项 → 弹卡片
                    _root._taskUpdateVisible = true
                } else {
                    _root._taskUpdateVisible = false
                }
                _root._remoteHasUpdate = _visiblePending.length > 0
                // 手动点🔔但卡片确实为空（全是隐藏项）→ 轻提示
                // 区分两类隐藏原因：测试模式 / 未绑定当前评分人
                if (openCardOnNoUpdate && !_root._taskUpdateVisible) {
                    var hiddenTest = merged.length - _visiblePending.length
                    // 当前评分人不命中的项数（与 _visiblePending 相对）
                    var hiddenForRater = 0
                    for (var _hi = 0; _hi < merged.length; ++_hi) {
                        if (!_isRemoteItemVisibleForUser(merged[_hi])) {
                            // 进一步细分：测试模式单独计
                            if ((merged[_hi].mode || "") !== "test") hiddenForRater++
                        }
                    }
                    _hintRemoteTaskEmpty(merged.length - hiddenForRater, hiddenForRater)
                }
                console.log("[ConfigCheck] 检测到", pending.length, "个模式配置有更新，当前待应用", merged.length, "个（可见", _visiblePending.length, "个）")
            }

            allPairs.forEach(function(pair) {
                // 用 IIFE 封装每次迭代，确保 xhr1/mode/configName/_done1/_t1 各自独立，避免闭包共享最后一个值
                (function(mode, configName) {
                var cfgUrl = configBase + encodeURIComponent(configName)
                // 指纹 key = "mode:configName"
                var fpKey = mode + ":" + configName
                var xhr1 = new XMLHttpRequest()
                var _done1 = false
                var _t1 = Qt.createQmlObject('import QtQuick 2.0; Timer { interval: 8000; repeat: false }', root)
                _t1.triggered.connect(function() { if (!_done1) { _done1 = true; xhr1.abort() } _t1.destroy() })
                _t1.start()
                xhr1.onreadystatechange = function() {
                    if (xhr1.readyState !== XMLHttpRequest.DONE) return
                    if (_done1) return
                    _done1 = true
                    _t1.stop()
                    finished++
                    if (xhr1.status === 200 || xhr1.status === 0) {
                        try {
                            var rawText = xhr1.responseText
                            var obj = JSON.parse(rawText)
                            if (obj && Array.isArray(obj.dimensions) && obj.dimensions.length > 0) {
                                var remoteFp = rawText
                                var localFp  = (_root._localConfigFingerprint || {})[fpKey] || ""
                                // 【忽略机制】用户曾主动忽略过"这个配置的某一版"（rawText 快照），
                                // 如果远端当前 rawText == 忽略快照 → 本次直接跳过，不入队、不弹窗；
                                // 如果远端 rawText 变了 → 忽略不再匹配，往下走正常流程（重新弹）。
                                var ignoredFp = (_root._localConfigFingerprint || {})["__ignored__:" + fpKey] || ""
                                if (ignoredFp && ignoredFp === remoteFp) {
                                    console.log("[ConfigCheck] 命中忽略快照，静默跳过：", fpKey)
                                    return  // 直接从本个 xhr1.onreadystatechange 中返回，不影响 finished / onAllDone
                                }
                                // 远端 rawText 已不再与忽略快照相同，清掋忽略记录，避免长期残留
                                if (ignoredFp && ignoredFp !== remoteFp) {
                                    var fpClr = JSON.parse(JSON.stringify(_root._localConfigFingerprint || {}))
                                    delete fpClr["__ignored__:" + fpKey]
                                    _root._localConfigFingerprint = fpClr
                                    _saveFingerprintToFile()
                                    console.log("[ConfigCheck] 远端已变化，忽略快照自动失效：", fpKey)
                                }

                                // 【手动应用】把"远程当前绑定的这份配置"收集到 allFetched。
                                // 注意：被忽略快照命中的项已经在上面 return 跳过，不会进这里，
                                // 因此 allFetched 不含用户明确忽略过的版本，符合预期。
                                allFetched.push({
                                    mode: mode,
                                    obj: obj,
                                    configName: configName,
                                    rawText: rawText,
                                    fpKey: fpKey,
                                    bindingsFp: bindingsFp
                                })

                                // 判断是否为绑定切换：绑定关系指纹变了，且该 mode 的 configName 发生了变化
                                var bindingChanged = (localBindingsFp.length > 0) && (bindingsFp !== localBindingsFp) &&
                                    (function() {
                                        try {
                                            var oldBindings = JSON.parse(localBindingsFp)
                                            var oldVal = oldBindings[mode]
                                            // 兼容旧格式（字符串）和新格式（数组）
                                            var oldNames = Array.isArray(oldVal) ? oldVal : (oldVal ? [oldVal] : [])
                                            return oldNames.indexOf(configName) === -1
                                        } catch(e) { return false }
                                    })()

                                if (localFp.length === 0 && localBindingsFp.length === 0) {
                                    // 真正首次启动（无任何历史）：静默自动应用配置，不弹通知
                                    // 各 mode 各自存入 _dimsByMode，不切换当前 mode
                                    var _dimsInit = obj.dimensions.map(function(d) {
                                        var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                                        return Object.assign({}, d, { starCount: sc })
                                    })
                                    var dimsCacheInit = _root._dimsByMode || {}
                                    dimsCacheInit[mode] = _dimsInit
                                    _root._dimsByMode = dimsCacheInit
                                    // 同步缓存该 mode 的 checklist
                                    // 【多配置合并策略】同一 mode 可能绑定多个配置，有 checklists 的优先，
                                    // 后续无 checklists 的配置不覆盖已有值。
                                    // 【竞态修复】每次都从 _root._checklistByMode 读最新值，避免并发 xhr 使用陈旧快照
                                    if (Array.isArray(obj.checklists) && obj.checklists.length > 0) {
                                        var _ckCacheInit = _root._checklistByMode || {}
                                        _ckCacheInit[mode] = { items: obj.checklists, exclusiveKey: _parseChecklistExclusiveKey(obj) }
                                        _root._checklistByMode = _ckCacheInit
                                        console.log("[ChecklistInit] mode=", mode, "写入 checklist 条数:", obj.checklists.length,
                                            " 当前 keys:", Object.keys(_ckCacheInit).join(","))
                                    } else {
                                        // 本次无 checklists：只在该 mode 完全没有 items 时才写 null（往已存在的有值 items 不覆盖）
                                        var _ckCacheInitEmpty = _root._checklistByMode || {}
                                        var _existingCk = _ckCacheInitEmpty[mode]
                                        var _hasItems = _existingCk && _existingCk.items && _existingCk.items.length > 0
                                        console.log("[ChecklistInit] mode=", mode, "无 checklists。已有数据=", _hasItems, " existing=", JSON.stringify(_existingCk))
                                        if (!_hasItems) {
                                            _ckCacheInitEmpty[mode] = null
                                            _root._checklistByMode = _ckCacheInitEmpty
                                        }
                                    }
                                    // 【关键】按 mode 独立持久化
                                    _saveDimsByMode()
                                    // 【tag 按 mode 独立缓存】无论当前 mode 是不是这个 mode，
                                    // 都记录该 mode 的 tag，防止后续任何一次远程返回覆盖掉别人。
                                    _setTagForMode(mode, obj.tag || "")
                                    // 只有该 mode 恰好是当前 mode 时，才写共享 dimensions.json（避免其他 mode 污染当前 UI 缓存）
                                    var _curMode1 = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
                                    if (mode === _curMode1) {
                                        var localPathInit = _resourcesDir() + "/dimensions.json"
                                        if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
                                            EngineBridge.writeTextFile(localPathInit, JSON.stringify(obj))
                                        }
                                        // 更新 tag（只在当前 mode 匹配时才同步 uploadTag，避免不同 mode 的 tag 相互覆盖）
                                        if (obj.tag && typeof Rating !== "undefined") Rating.uploadTag = obj.tag
                                        _root._remoteTag = obj.tag || ""
                                    }
                                    // 建指纹基线
                                    var fp2 = JSON.parse(JSON.stringify(_root._localConfigFingerprint || {}))
                                    fp2[fpKey] = remoteFp
                                    fp2["__bindings__"] = bindingsFp
                                    _root._localConfigFingerprint = fp2
                                    _saveFingerprintToFile()
                                    console.log("[ConfigCheck] 首次启动，静默应用 mode=", mode, "维度数:", _dimsInit.length)
                                } else if (bindingChanged) {
                                    // 绑定切换了（运行中或重启后），视为变化，弹通知
                                    console.log("[ConfigCheck] 绑定切换检测到：mode=", mode, "旧配置→新配置=", configName)
                                    pending.push({ mode: mode, obj: obj, configName: configName, rawText: rawText, fpKey: fpKey, bindingsFp: bindingsFp })
                                } else if (localFp.length === 0) {
                                    // 新增绑定（之前该 mode 没有绑定）：静默自动应用，不弹通知
                                    var _dimsNew = obj.dimensions.map(function(d) {
                                        var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                                        return Object.assign({}, d, { starCount: sc })
                                    })
                                    var dimsCacheNew = _root._dimsByMode || {}
                                    dimsCacheNew[mode] = _dimsNew
                                    _root._dimsByMode = dimsCacheNew
                                    // 同步缓存该 mode 的 checklist（多配置合并策略：有 checklists 的优先）
                                    // 【竞态修复】每次都从 _root._checklistByMode 读最新值
                                    if (Array.isArray(obj.checklists) && obj.checklists.length > 0) {
                                        var _ckCacheNew = _root._checklistByMode || {}
                                        _ckCacheNew[mode] = { items: obj.checklists, exclusiveKey: _parseChecklistExclusiveKey(obj) }
                                        _root._checklistByMode = _ckCacheNew
                                        console.log("[ChecklistInit] mode=", mode, "写入 checklist 条数:", obj.checklists.length,
                                            " 当前 keys:", Object.keys(_ckCacheNew).join(","))
                                    } else {
                                        var _ckCacheNewEmpty = _root._checklistByMode || {}
                                        var _existingCkN = _ckCacheNewEmpty[mode]
                                        var _hasItemsN = _existingCkN && _existingCkN.items && _existingCkN.items.length > 0
                                        console.log("[ChecklistInit] mode=", mode, "无 checklists。已有数据=", _hasItemsN)
                                        if (!_hasItemsN) {
                                            _ckCacheNewEmpty[mode] = null
                                            _root._checklistByMode = _ckCacheNewEmpty
                                        }
                                    }
                                    // 【关键】按 mode 独立持久化
                                    _saveDimsByMode()
                                    // 【tag 按 mode 独立缓存】
                                    _setTagForMode(mode, obj.tag || "")
                                    // 只有当前 mode 匹配时才写共享 dimensions.json + 覆盖 uploadTag/_remoteTag
                                    var _curMode2 = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
                                    if (mode === _curMode2) {
                                        var localPathNew = _resourcesDir() + "/dimensions.json"
                                        if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
                                            EngineBridge.writeTextFile(localPathNew, JSON.stringify(obj))
                                        }
                                        if (obj.tag && typeof Rating !== "undefined") Rating.uploadTag = obj.tag
                                        _root._remoteTag = obj.tag || ""
                                    }
                                    // 建指纹基线
                                    var fp3 = JSON.parse(JSON.stringify(_root._localConfigFingerprint || {}))
                                    fp3[fpKey] = remoteFp
                                    fp3["__bindings__"] = bindingsFp
                                    _root._localConfigFingerprint = fp3
                                    _saveFingerprintToFile()
                                    console.log("[ConfigCheck] 新增绑定，静默应用 mode=", mode, "维度数:", _dimsNew.length)
                                } else if (remoteFp !== localFp) {
                                    // 同一绑定，内容发生了变化
                                    pending.push({ mode: mode, obj: obj, configName: configName, rawText: rawText, fpKey: fpKey, bindingsFp: bindingsFp })
                                } else {
                                    // 指纹相同（无需弹通知），但仍需同步 checklist 到内存缓存
                                    // 因为 _checklistByMode 是纯内存属性，重启后为空，必须在每次拉取时补齐
                                    // 【多配置合并策略】有 checklists 的优先，无 checklists 的不覆盖已有值
                                    if (Array.isArray(obj.checklists) && obj.checklists.length > 0) {
                                        var _ckSame = _root._checklistByMode || {}
                                        _ckSame[mode] = { items: obj.checklists, exclusiveKey: _parseChecklistExclusiveKey(obj) }
                                        _root._checklistByMode = _ckSame
                                        console.log("[ChecklistSame] mode=", mode, "写入 checklist 条数:", obj.checklists.length)
                                    } else {
                                        var _ckSameEmpty = _root._checklistByMode || {}
                                        var _existingSame = _ckSameEmpty[mode]
                                        var _hasItemsSame = _existingSame && _existingSame.items
                                                && typeof _existingSame.items.length === "number"
                                                && _existingSame.items.length > 0
                                        if (!_hasItemsSame) {
                                            _ckSameEmpty[mode] = null
                                            _root._checklistByMode = _ckSameEmpty
                                        } else {
                                            console.log("[ChecklistSame] mode=", mode, "无 checklists 但已有值，不覆盖")
                                        }
                                    }
                                    // 如果当前就是这个 mode，立即更新 reviewChecklist（duck-typing 避免 QJSValue 陷阱）
                                    var _curModeSame = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
                                    if (mode === _curModeSame) {
                                        var _ckCur = _checklistForMode(_curModeSame)
                                        var _hasCkCur = _ckCur && _ckCur.items
                                                && typeof _ckCur.items.length === "number"
                                                && _ckCur.items.length > 0
                                        if (_hasCkCur) {
                                            var _plainCkCur = []
                                            for (var _pi = 0; _pi < _ckCur.items.length; _pi++) _plainCkCur.push(_ckCur.items[_pi])
                                            _root.reviewChecklist = _plainCkCur
                                            _root.reviewChecklistExclusiveKey = _ckCur.exclusiveKey || ""
                                        } else {
                                            _root.reviewChecklist = []
                                            _root.reviewChecklistExclusiveKey = ""
                                        }
                                    }
                                }
                            }
                        } catch (e) {
                            console.warn("[ConfigCheck] 解析配置失败 mode=", mode, e)
                        }
                    }
                    if (finished >= total) {
                        // 所有模式检测完毕后，更新绑定关系指纹基线
                        if (pending.length === 0 && bindingsFp !== localBindingsFp) {
                            // 绑定有变化但没有内容差异（不太可能，保险起见更新基线）
                            var fpUpd = JSON.parse(JSON.stringify(_root._localConfigFingerprint || {}))
                            fpUpd["__bindings__"] = bindingsFp
                            _root._localConfigFingerprint = fpUpd
                            _saveFingerprintToFile()
                        }
                        onAllDone()
                    }
                }
                xhr1.open("GET", cfgUrl)
                xhr1.send()
                })(pair.mode, pair.configName)  // IIFE 结束：每次迭代变量独立
            })
        } catch (e) {
            console.warn("[ConfigCheck] 解析 active-config 失败：", e)
        }
    }
    xhr0.open("GET", activeUrl)
    xhr0.send()
}

function _tsExpandHome(p) {
    if (!p) return p
    if (p === "~" || p.indexOf("~/") === 0)
        return (typeof Fs !== "undefined" ? Fs.homeDir() : "") + p.substring(1)
    return p
}

function _tsCanonical(ts) {
    var refDirs = []
    if (ts.referenceDirs && typeof ts.referenceDirs.length === "number") {
        for (var i = 0; i < ts.referenceDirs.length; ++i) {
            var s = String(ts.referenceDirs[i] || "").trim()
            if (s.length > 0) refDirs.push(s)
        }
    } else {
        var lr = String(ts.referenceDir || "").trim()
        if (lr.length > 0) refDirs.push(lr)
    }
    var lanes = []
    if (ts.laneDirs && typeof ts.laneDirs.length === "number") {
        for (var j = 0; j < ts.laneDirs.length; ++j) {
            var l = String(ts.laneDirs[j] || "").trim()
            if (l.length > 0) lanes.push(l)
        }
    }
    var workDir = _tsExpandHome(String(ts.workDir || "").trim())
    if (!workDir) workDir = (typeof Fs !== "undefined" ? Fs.downloadsDir() : "")
    return JSON.stringify({
        url: String(ts.url || "").trim(),
        workDir: workDir,
        rootDir: String(ts.rootDir || "").trim(),
        laneDirs: lanes,
        referenceDirs: refDirs,
        promptCsv: String(ts.promptCsv || "").trim()
    })
}

function _tsSaveLastAuto(st) {
    try {
        Rating.saveString("testSource/lastAuto", JSON.stringify({
            canon: _tsCanonical(st.ts),
            zipPath: st.zipPath,
            extractTarget: st.extractTarget
        }))
    } catch (e) {}
}

function _tsLoadLastAuto() {
    try {
        var raw = Rating.loadString("testSource/lastAuto", "")
        return raw ? JSON.parse(raw) : null
    } catch (e) { return null }
}

function _tsRootDirFor(ts, extractTarget) {
    var rootRel = String(ts.rootDir || "").trim()
    return rootRel.length > 0
        ? (rootRel.charAt(0) === "/" ? rootRel : extractTarget + "/" + rootRel)
        : extractTarget
}

function _tsResolveUrl(rawUrl) {
    var u = String(rawUrl || "").trim()
    if (u.length === 0) return ""
    if (/^https?:\/\//i.test(u)) return u
    if (u.charAt(0) === "/") {
        var base = _dimApiUrl()   // http://host:port/api/dimensions
        var origin = base ? base.replace(/\/api\/dimensions$/, "") : ""
        if (origin.length > 0) return origin + u
        console.warn("[TestSource] url 为相对路径但未配置服务器，无法解析:", u)
        return ""
    }
    return u
}

// 按 {group} 模板解析实际下载 URL 和 rootDir：
//   url 含 {group} → 按组拆分模式，先确定评分人所属组别再替换
//   url 不含 {group} → 旧模式，返回原值
// 返回 { url, rootDir, group } ；group 为空表示未命中映射（旧模式或无 groups 配置）
function _tsResolveGroup(ts) {
    var rawUrl = String(ts.url || "").trim()
    var rootRel = String(ts.rootDir || "").trim()
    if (rawUrl.indexOf("{group}") < 0 && rootRel.indexOf("{group}") < 0) {
        return { url: _tsResolveUrl(rawUrl), rootDir: rootRel, group: "" }
    }

    // 按组拆分模式：先确定评分人所属组别
    var rater = ""
    try {
        if (typeof Rating !== "undefined") {
            rater = String(Rating.currentUser || "").trim()
            if (rater.length === 0 && typeof Rating.systemUserName === "function")
                rater = String(Rating.systemUserName() || "").trim()
        }
    } catch (e) {}

    var group = _tsGroupForRater(ts, rater)
    if (group.length === 0) {
        console.warn("[TestSource] url 含 {group} 模板但评分人「" + rater + "」未命中组别映射")
        // 未命中映射：{group} 无法替换，返回空 url 让调用方报错
        return { url: "", rootDir: rootRel, group: "" }
    }

    console.log("[TestSource] 评分人「" + rater + "」命中组别「" + group + "」→ 按组下载")
    var resolvedUrl = _tsResolveUrl(rawUrl.replace(/\{group\}/g, group))
    var resolvedRoot = rootRel.replace(/\{group\}/g, group)
    return { url: resolvedUrl, rootDir: resolvedRoot, group: group }
}

function _startTestSourceAutomation(ts, configName) {
    if (_root._tsAuto) {
        console.warn("[TestSource] 已有自动化任务进行中，忽略本次触发")
        return
    }

    // 按组拆分模式：先确定评分人所属组别，替换 {group} 模板
    var resolved = _tsResolveGroup(ts)
    var url = resolved.url
    if (url.length === 0) {
        _testSourceDownloadDialog._status = "error"
        _testSourceDownloadDialog._statusText = "无法确定下载地址：url 含 {group} 模板但评分人未命中组别映射"
        _testSourceDownloadDialog.open()
        return
    }

    // 按组拆分模式下，组别已确定，直接写入 st 避免后续 _tsGateGroup 再弹窗
    if (resolved.group.length > 0) {
        ts = Object.assign({}, ts, { rootDir: resolved.rootDir })
    }

    var fileName = url.split("/").pop().split("?")[0] || "test-source.zip"
    var workDir = _tsExpandHome(String(ts.workDir || "").trim())
    if (!workDir) workDir = (typeof Fs !== "undefined" ? Fs.downloadsDir() : "")
    var zipPath = workDir + "/" + fileName
    // 解压目标 = workDir 本身（与 Finder 双击解压行为一致：
    // zip 内顶层目录 test_auto/ 解压后落在 workDir/test_auto，
    // 不再额外多套一层与 zip 同名的目录）
    var extractTarget = workDir

    // 构造 st 对象，预置 chosenGroup（按组拆分模式下组别已在下载前确定）
    var _stObj = { ts: ts, configName: configName,
                   zipPath: zipPath, extractTarget: extractTarget }
    if (resolved.group.length > 0) {
        _stObj._chosenGroup = resolved.group
        _root._tsLastGroup = resolved.group
    }

    // ── 重复下载检测：同配置 + zip 在 + 解压根在 → 弹「直接开始/重新下载」──
    var canon = _tsCanonical(ts)
    var last = _tsLoadLastAuto()
    if (last && last.canon === canon
            && Fs.fileExists(last.zipPath)
            && Fs.isDirectoryPath(_tsRootDirFor(ts, last.extractTarget))) {
        console.log("[TestSource] 命中重复下载检测，询问用户:", fileName)
        _testSourceRedownloadDialog.openWith({
            ts: ts, configName: configName,
            fileName: fileName, zipPath: last.zipPath,
            extractTarget: last.extractTarget
        })
        return
    }

    _tsBeginDownload(ts, configName, fileName, zipPath, extractTarget, resolved.group)
}

function _tsBeginDownload(ts, configName, fileName, zipPath, extractTarget, group) {
    var url = _tsResolveUrl(ts.url)   // 相对路径在此兜底解析（幂等）
    // 按组拆分模式：url 含 {group}，需替换后再下载
    if (ts.url && String(ts.url).indexOf("{group}") >= 0) {
        var resolved = _tsResolveGroup(ts)
        url = resolved.url
    }
    _root._tsAuto = {
        ts: ts, configName: configName,
        zipPath: zipPath, extractTarget: extractTarget
    }
    // 按组拆分模式：组别已在下载前确定，预置到 st 避免后续 _tsGateGroup 再弹窗
    if (group && group.length > 0) {
        _root._tsAuto._chosenGroup = group
    }
    console.log("[TestSource] 自动化启动:", url, "→ 解压到", extractTarget)
    // 直接驱动下载（不走 startDownload：它内部写死 ~/Downloads，会无视 workDir 配置）
    var d = _testSourceDownloadDialog
    d._url        = url
    d._fileName   = fileName
    d._configName = configName
    d._savePath   = ""
    d._progress   = 0
    d._status     = "downloading"
    d._statusText = "正在下载…"
    d.open()
    Downloader.download(url, zipPath)
}

function _tsImportAndStart(st, extractTarget) {
    var ts = st.ts
    var laneDirs = []
    if (ts.laneDirs && typeof ts.laneDirs.length === "number") {
        for (var i = 0; i < ts.laneDirs.length; ++i) {
            var s = String(ts.laneDirs[i] || "").trim()
            if (s.length > 0) laneDirs.push(s)
        }
    }
    if (laneDirs.length === 0) return "testSource 配置缺少 laneDirs（参与对比的子目录）"

    // 定位内容根：完全由配置决定，不做任何目录探测。
    // rootDir 相对解压目标目录 workDir（"/" 开头视为绝对路径）；缺省 = workDir 本身。
    var rootRel = String(ts.rootDir || "").trim()
    var rootDir = rootRel.length > 0
        ? (rootRel.charAt(0) === "/" ? rootRel : extractTarget + "/" + rootRel)
        : extractTarget
    if (!Fs.isDirectoryPath(rootDir))
        return "内容根目录不存在：" + rootDir + "\n（请检查 testSource.rootDir 配置）"

    // 组别处理：
    //   · 按组拆分模式（rootDir 含 {group} 已被替换为实际值如 cfg_g1）：
    //     zip 内顶层目录就是 cfg_g1，直接作为 effRoot，不再拼接 chosenGroup
    //   · 旧模式（一个 zip 含 g1/g2/...）：effRoot = rootDir + chosenGroup
    var effRoot = rootDir
    if (st._chosenGroup) {
        // 按组拆分模式：rootDir 已是 cfg_g1 这种实际路径，不再拼接组目录
        // 判定方式：rootDir 末段已包含组名（如 _g1）→ 不拼接
        var rootBase = rootDir.split("/").pop()
        if (rootBase.indexOf(st._chosenGroup) < 0) {
            // 旧模式：rootDir 是 cfg，需拼接 /g1
            effRoot = rootDir + "/" + st._chosenGroup
            if (!Fs.isDirectoryPath(effRoot)) return "所选组别目录不存在：" + effRoot
        }
    }

    // 收集 lane 绝对路径并校验存在性
    var lanes = []
    for (var j = 0; j < laneDirs.length; ++j) {
        var p = effRoot + "/" + laneDirs[j]
        if (!Fs.isDirectoryPath(p)) return "缺少对比目录：" + p
        lanes.push(p)
    }

    // 参考图目录列表：新写法 referenceDirs（数组，最多 2 个，对应侧栏两个参考图窗口）；
    // 兼容旧写法 referenceDir（单字符串，视为第 1 个）。
    var refDirs = []
    if (ts.referenceDirs && typeof ts.referenceDirs.length === "number") {
        for (var ri = 0; ri < ts.referenceDirs.length; ++ri) {
            var rs = String(ts.referenceDirs[ri] || "").trim()
            if (rs.length > 0) refDirs.push(rs)
        }
    } else {
        var legacyRef = String(ts.referenceDir || "").trim()
        if (legacyRef.length > 0) refDirs.push(legacyRef)
    }
    var csvRel = String(ts.promptCsv || "").trim()
    var refAbs1 = refDirs.length > 0 ? effRoot + "/" + refDirs[0] : ""
    var refAbs2 = refDirs.length > 1 ? effRoot + "/" + refDirs[1] : ""
    var csvAbs = csvRel.length > 0 ? effRoot + "/" + csvRel : ""
    var bindRef1 = refAbs1.length > 0 && Fs.isDirectoryPath(refAbs1)
    var bindRef2 = refAbs2.length > 0 && Fs.isDirectoryPath(refAbs2)
    var bindCsv = csvAbs.length > 0 && Fs.fileExists(csvAbs)
    // 绑定参考图（槽位 1/2）与提示词 CSV —— 绑定键是每路自己的文件夹
    for (var k = 0; k < lanes.length; ++k) {
        if (bindRef1) Reference.setReferenceFolder(lanes[k], refAbs1)
        if (bindRef2) Reference.setReferenceFolder2(lanes[k], refAbs2)
        if (bindCsv) Reference.setReferenceCsv(lanes[k], csvAbs)
    }
    console.log("[TestSource] 根目录:", rootDir, " 组别:", st._chosenGroup || "(无)",
        " 路:", lanes.join(" | "),
        " 参考图1:", bindRef1 ? refAbs1 : "(无)",
        " 参考图2:", bindRef2 ? refAbs2 : "(无)",
        " CSV:", bindCsv ? csvAbs : "(无)")

    // 导入并直接启动（loadFolders：仅勾选本次导入的路 → start → 进入打分界面；
    // 路满时会先自动清理"文件夹已不存在"的死路再重试）
    // 传递"重新下载"标记：loadFolders 据此决定是否跳过"继续评分？"弹窗
    _multiGroupDialog.forceResetProgress = !!_root._tsForceResetProgress
    _root._tsForceResetProgress = false   // 消费根标记
    if (!_multiGroupDialog.loadFolders(lanes))
        return "导入失败：目录里没有可播放的视频，或路数已达 9 路上限"
    // 绑定到了参考图或提示词 → 自动展开左侧参考图侧栏 + 底部提示词栏
    // （等价于用户手动点左下角「图片」按钮）
    if (bindRef1 || bindRef2 || bindCsv) _root.refSidebarVisible = true
    return ""
}

function _tsDetectGroups(rootDir, laneDirs) {
    var subs = []
    try { subs = Fs.listSubDirs(rootDir) || [] } catch (e) {}
    var out = []
    for (var i = 0; i < subs.length; ++i) {
        var name = String(subs[i]).split("/").pop()
        if (name === "__MACOSX") continue
        var all = true
        for (var j = 0; j < laneDirs.length; ++j) {
            if (!Fs.isDirectoryPath(subs[i] + "/" + laneDirs[j])) { all = false; break }
        }
        if (all) out.push(name)
    }
    return out
}

function _tsGroupForRater(ts, rater) {
    var r = String(rater || "").trim()
    if (r.length === 0 || !ts) return ""
    var gs = ts.groups
    if (gs && typeof gs === "object" && !Array.isArray(gs)) {
        for (var name in gs) {
            var arr = gs[name]
            if (Array.isArray(arr) && arr.indexOf(r) >= 0) return name
        }
        return ""
    }
    var raw = String(ts.groupMap || "").trim()
    if (raw.length === 0) return ""
    var entries = raw.split(/[,，;；\n]+/)
    for (var i = 0; i < entries.length; ++i) {
        var kv = entries[i].split(/[:：]/)
        if (kv.length < 2) continue
        var name = kv[0].trim()
        var grp = kv.slice(1).join(":").trim()
        if (name.length > 0 && name === r) return grp
    }
    return ""
}

function _tsGateGroup(st, extractTarget) {
    if (st._chosenGroup) return false
    var ts = st.ts
    var laneDirs = []
    if (ts.laneDirs && typeof ts.laneDirs.length === "number") {
        for (var i = 0; i < ts.laneDirs.length; ++i) {
            var s = String(ts.laneDirs[i] || "").trim()
            if (s.length > 0) laneDirs.push(s)
        }
    }
    if (laneDirs.length === 0) return false
    var rootDir = _tsRootDirFor(ts, extractTarget)
    if (!Fs.isDirectoryPath(rootDir)) return false   // 交给原逻辑报"根目录不存在"

    // 按组拆分模式：rootDir 含 {group}（已被替换为实际值如 cfg_g1），
    // zip 内只有一个组的顶层目录，无需也无法检测多个组别
    var rootBase = String(ts.rootDir || "").trim()
    if (rootBase.indexOf("{group}") >= 0 || /_g\d+$/.test(rootBase.split("/").pop())) {
        console.log("[TestSource] 按组拆分模式，rootDir 已含组别，跳过组别检测")
        return false
    }

    var groups = _tsDetectGroups(rootDir, laneDirs)
    if (groups.length === 0) return false

    // 自动选组：配置声明了「评分人→组别」映射（groupMap），且当前评分人命中 →
    // 跳过选组弹窗直接继续。评分人取值与上传署名一致（Rating.currentUser，
    // 为空时回退系统用户名，与导出 CSV 的 rater 列兜底规则相同）。
    var _rater = ""
    try {
        if (typeof Rating !== "undefined") {
            _rater = String(Rating.currentUser || "").trim()
            if (_rater.length === 0 && typeof Rating.systemUserName === "function")
                _rater = String(Rating.systemUserName() || "").trim()
        }
    } catch (e) {}
    var _mapped = _tsGroupForRater(ts, _rater)
    if (_mapped.length > 0 && groups.indexOf(_mapped) >= 0) {
        console.log("[TestSource] 评分人「" + _rater + "」命中组别映射 → 自动选择:", _mapped)
        st._chosenGroup = _mapped
        _root._tsLastGroup = _mapped
        _updateToast.text = "已按评分人「" + _rater + "」自动选择组别「" + _mapped + "」"
        _updateToast.open()
        return false
    }
    if (_mapped.length > 0)
        console.warn("[TestSource] 映射组别「" + _mapped + "」不在包内组别",
                     groups.join(" | "), "中，转手动选组")

    console.log("[TestSource] 检测到组别:", groups.join(" | "), " 等待用户选择")
    _root._tsGroupCtx = { st: st, extractTarget: extractTarget }
    _testSourceGroupDialog.openWith(groups,
        _root._tsLastGroup || String(ts.group || "").trim(), st.configName || "")
    _testSourceDownloadDialog.close()   // 避免与选组弹窗两层叠压
    return true
}

function _tsOnGroupChosen(g) {
    var ctx = _root._tsGroupCtx
    _root._tsGroupCtx = null
    if (!ctx) return
    _root._tsLastGroup = g
    ctx.st._chosenGroup = g
    console.log("[TestSource] 用户选择组别:", g)
    var err = _tsImportAndStart(ctx.st, ctx.extractTarget)
    if (err.length > 0) {
        _testSourceDownloadDialog._status = "error"
        _testSourceDownloadDialog._statusText = err
        _testSourceDownloadDialog.open()
        return
    }
    // 记录本次产物（与 onZipExtracted 成功路径一致，供下次「跳过下载」判重）
    _tsSaveLastAuto(ctx.st)
    _testSourceDownloadDialog.close()
}

function _tsOnGroupCancel() {
    console.log("[TestSource] 用户取消选组，本次自动化中止")
    _root._tsGroupCtx = null
    _testSourceDownloadDialog.close()
}

function _tsPlaceStagedContent(st, stagingDir) {
    var rootRel = String(st.ts.rootDir || "").trim()
    var finalRoot = st.extractTarget + "/" + rootRel
    var stagedRoot = stagingDir + "/" + rootRel
    if (!Fs.isDirectoryPath(stagedRoot)) {
        var subs = []
        try { subs = Fs.listSubDirs(stagingDir) || [] } catch (e) {}
        // 过滤打包杂质目录：macOS 打的 zip 会带 __MACOSX 资源叉目录，
        // macOS ditto 解压时自动忽略，但 Windows Expand-Archive 会原样解出，
        // 不过滤会把顶层目录数判成 2 个，导致自动适配失效
        subs = subs.filter(function(p) {
            return String(p).split("/").pop() !== "__MACOSX"
        })
        if (subs.length === 1) {
            console.warn("[TestSource] rootDir 配置「" + rootRel + "」与 zip 内顶层目录「"
                + subs[0] + "」不一致，已自动适配（建议在后台修正 rootDir）")
            stagedRoot = subs[0]
        } else {
            var names = []
            for (var i = 0; i < subs.length; ++i) names.push(subs[i].split("/").pop())
            return "内容根目录不存在：" + finalRoot
                + "\n解压结果顶层目录：" + (names.length > 0 ? names.join("、") : "（无，zip 内可能只有散文件）")
                + "\n请检查 testSource.rootDir 配置"
        }
    }
    // 清理旧内容根（护栏：finalRoot 必须严格位于 extractTarget 内部）
    var prefix = st.extractTarget + "/"
    if (finalRoot.length > prefix.length && finalRoot.indexOf(prefix) === 0
            && Fs.isDirectoryPath(finalRoot)) {
        // Windows 特有：旧内容根里的视频可能正在被播放（文件被系统锁定），
        // 此时删除会静默失败、后续换名也失败。先关闭全部播放释放句柄 ——
        // 自动化本来就会用新内容替换当前会话；macOS 无文件锁，调用无害。
        try { Engine.closeAll() } catch (e) {}
        console.log("[TestSource] 清理旧内容根目录:", finalRoot)
        if (!Fs.removeDirRecursively(finalRoot) && Fs.isDirectoryPath(finalRoot)) {
            return "旧内容根目录删除失败（文件可能被占用）：" + finalRoot
                + "\n请关闭正在播放的相关视频后重试"
        }
    }
    if (!Fs.renamePath(stagedRoot, finalRoot)) {
        return "内容根目录就位失败：无法移动 " + stagedRoot + " → " + finalRoot
    }
    try { Fs.removeDirRecursively(stagingDir) } catch (e) {}
    return ""
}

function _applyRemoteConfigItem(item, onDone) {
    if (!item) { if (onDone) onDone(); return }
    var configName = item.configName || ""
    var mode = item.mode || ""
    console.log("[ApplyDebug] 点击应用 → mode:", mode, "configName:", configName,
        "item.obj.type:", item.obj && item.obj.type, "item.obj.tag:", item.obj && item.obj.tag)
    var base = _dimApiUrl()  // 例如 http://host:port/api/dimensions
    var apiRoot = base ? base.replace(/\/api\/dimensions$/, "") : ""
    var fetchUrl = (apiRoot && configName)
        ? (apiRoot + "/api/configs/" + encodeURIComponent(configName))
        : ""

    // 定义应用逻辑（拿到最新 obj 后走这一段）
    function _doApply(obj, rawText) {
        try {
            if (!obj || !Array.isArray(obj.dimensions)) {
                console.warn("[ConfigCheck] 应用失败：配置内容无效")
                _root._showRatingWarn("应用失败：配置内容无效", 2200)
                if (onDone) onDone()
                return
            }
            console.log("[ApplyDebug] _doApply → mode:", mode, "configName:", configName,
                "obj.type:", obj.type, "obj.tag:", obj.tag,
                "dims:", obj.dimensions.map(function(d){return d.key+"("+(d.levels?d.levels.length:0)+")"}).join(","))
            // 更新指纹基线
            var fp2 = JSON.parse(JSON.stringify(_root._localConfigFingerprint || {}))
            var _fpKey = item.fpKey || (mode + ":" + configName)
            fp2[_fpKey] = rawText || _configFingerprint(obj)
            if (item.bindingsFp) fp2["__bindings__"] = item.bindingsFp
            // 用户点了应用 = 明确接受该配置，清掉可能残留的忽略快照
            delete fp2["__ignored__:" + _fpKey]
            // 记录"用户实际应用的配置"：服务器 active 绑定（__bindings__）可能与用户
            // 手动选择的配置不同（如同一模式多张卡片），tooltip 的规则配置名应以
            // 实际应用为准，__bindings__ 仅作变更检测基线，不能当显示源
            var _appliedMap = {}
            try { _appliedMap = JSON.parse(fp2["__applied__"] || "{}") } catch(e) {}
            _appliedMap[mode] = configName
            fp2["__applied__"] = JSON.stringify(_appliedMap)
            _root._localConfigFingerprint = fp2
            _saveFingerprintToFile()

            // 计算该 mode 的维度列表（starCount 严格来自 levels.length）
            var _dims = obj.dimensions.map(function(d) {
                var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                return Object.assign({}, d, { starCount: sc })
            })

            // 存入按 mode 的维度缓存（无论当前是不是这个 mode，都保存进去）
            var dimsCacheUpd = _root._dimsByMode || {}
            dimsCacheUpd[mode] = _dims
            _root._dimsByMode = dimsCacheUpd
            // 同步缓存该 mode 的 checklist
            var _ckCacheUpd = _root._checklistByMode || {}
            _ckCacheUpd[mode] = Array.isArray(obj.checklists) && obj.checklists.length > 0
                ? { items: obj.checklists, exclusiveKey: _parseChecklistExclusiveKey(obj) }
                : null
            _root._checklistByMode = _ckCacheUpd
            // 【关键】立即按 mode 独立持久化，避免多 mode 通过共享 dimensions.json 相互覆盖
            _saveDimsByMode()
            // 【tag 按 mode 独立缓存】同步记录该 mode 的 tag（不管是不是当前 mode），
            // 这样后续切到该 mode 时能显示正确的备注 tag，也不会被其他 mode 覆盖。
            _setTagForMode(mode, obj.tag || "")
            console.log("[ApplyDebug] _dimsByMode 更新完成 → keys:", Object.keys(_root._dimsByMode).join(","),
                "，本次写入 mode=", mode,
                "，维度：", _dims.map(function(d){return d.key+"("+d.starCount+"星)"}).join(","))

            // 【模式切换策略（用户约定）】
            // - 空闲态（Engine.fileCount === 0，还没打开对比）：应用配置时【自动切换】到通知里那个 mode，
            //   下次开对比就直接使用该配置。
            // - 已打开对比（fileCount > 0）：仅更新对应 mode 的缓存，绝不动 UI/切模式，
            //   避免打断用户正在做的评分。
            var currentMode = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
            var _isIdle = (typeof Engine !== "undefined") ? (Engine.fileCount === 0) : true

            if (mode === currentMode) {
                // 只有被应用的 mode 恰好就是用户当前所在 mode 时，才热更新 UI
                _forceApplyDimensions(_dims, obj.tag || "", mode, "applyItem")
                // 同步 checklist（仅当前 mode 热更新）
                if (Array.isArray(obj.checklists) && obj.checklists.length > 0) {
                    _root.reviewChecklist = obj.checklists
                    _root.reviewChecklistExclusiveKey = _parseChecklistExclusiveKey(obj)
                    // 【修复】同步写入 _checklistByMode 并持久化，否则重启后丢失
                    var _ckApplyCache = _root._checklistByMode || {}
                    _ckApplyCache[mode] = { items: obj.checklists, exclusiveKey: _root.reviewChecklistExclusiveKey }
                    _root._checklistByMode = _ckApplyCache
                    _saveChecklistByMode()
                    console.log("[ChecklistApply] ✅ 单条应用写入 _checklistByMode mode=", mode, "条数:", obj.checklists.length)
                } else {
                    var _ckApplyCacheClear = _root._checklistByMode || {}
                    _ckApplyCacheClear[mode] = null
                    _root._checklistByMode = _ckApplyCacheClear
                    _saveChecklistByMode()
                    _root.reviewChecklist = []
                    _root.reviewChecklistExclusiveKey = ""
                    console.log("[ChecklistApply] mode=", mode, "无 checklists，已清空")
                }

                // 持久化到本地缓存文件（只在与当前 mode 匹配时写，保持"当前 mode 的最新配置"语义）
                var localPath = _resourcesDir() + "/dimensions.json"
                if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
                    EngineBridge.writeTextFile(localPath, JSON.stringify(obj))
                }
                console.log("[ConfigCheck] 已热更新当前模式维度，mode:", mode,
                    "维度：", _dims.map(function(d){return d.key + "(" + d.starCount + "星)"}).join(", "),
                    "tag:", obj.tag)
            } else if (_isIdle) {
                // 空闲态：主动帮用户把当前模式切到通知里那个 mode。
                // 切换后 onCurrentModeChanged 会自动从 _dimsByMode[mode] 加载最新维度到 UI。
                console.log("[ConfigCheck] 空闲态应用→自动切换当前模式：", currentMode, "→", mode,
                    "（fileCount=0）")
                if (typeof Rating !== "undefined") {
                    Rating.currentMode = mode
                }
                // 同步 tag（应用到当前模式，因为已经切过去了）
                if (obj.tag && typeof Rating !== "undefined") {
                    Rating.uploadTag = obj.tag
                }
                _root._remoteTag = obj.tag || ""
            } else {
                // 已打开对比：不切换、不动 UI，只更新缓存（避免打断评分）
                console.log("[ConfigCheck] 已更新维度缓存（非当前模式且已在对比中，不切换、不重建UI）",
                    "被应用 mode:", mode, "当前 mode:", currentMode,
                    "fileCount:", (typeof Engine !== "undefined") ? Engine.fileCount : "?",
                    "维度：", _dims.map(function(d){return d.key + "(" + d.starCount + "星)"}).join(", "))
            }

            // 从待更新列表中移除该条
            var _appliedKey = mode + ":" + configName
            var remaining = (_root._pendingRemoteConfig || []).filter(function(x) {
                return (x.mode + ":" + x.configName) !== _appliedKey
            })
            _root._pendingRemoteConfig = remaining.length > 0 ? remaining : null
            if (!_root._pendingRemoteConfig) _root._taskUpdateVisible = false

            // 【测试源自动化】配置携带 testSource 对象时，应用后启动全自动流水线：
            // 下载 → 解压 → 绑定参考图/提示词 → 导入多路 → 直接启动进入打分界面。
            // （旧版 testSourceUrl 字符串字段已废弃，统一从 testSource.url 读取。）
            var _tsObj = obj.testSource
            if (_tsObj && typeof _tsObj === "object" && typeof _tsObj.url === "string" && _tsObj.url.trim().length > 0) {
                console.log("[TestSource] 命中 testSource 自动化配置, configName =", configName)
                _startTestSourceAutomation(_tsObj, configName)
            } else {
                // 无测试源配置：不会自动下载/导入/跳转 —— 中央大浮层明确告知，
                // 引导手动导入（否则用户会以为"接受没反应"，Windows 实测反馈）。
                _root._showRatingWarn("已应用配置「" + (configName || mode) + "」", 0, 18,
                                     "未配置测试源，请手动导入视频/文件夹开始评分", true)
            }
            if (onDone) onDone()
        } catch (e) {
            console.warn("[ConfigCheck] 应用单条配置失败：", e)
            if (onDone) onDone()
        }
    }

    // 优先现拉最新；拉不到就 fallback 用 item.obj
    if (fetchUrl) {
        console.log("[ConfigCheck] 应用时现拉最新配置：", fetchUrl)
        var xhr = new XMLHttpRequest()
        var _finished = false
        var _to = Qt.createQmlObject('import QtQuick 2.0; Timer { interval: 4000; repeat: false }', root)
        _to.triggered.connect(function() {
            if (_finished) { _to.destroy(); return }
            _finished = true
            console.warn("[ConfigCheck] 现拉超时，使用缓存 item.obj")
            xhr.abort()
            _doApply(item.obj, item.rawText)
            _to.destroy()
        })
        _to.start()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || _finished) return
            _finished = true
            _to.stop(); _to.destroy()
            if (xhr.status === 200 || xhr.status === 0) {
                try {
                    var latest = JSON.parse(xhr.responseText)
                    console.log("[ApplyDebug] 现拉成功 → mode:", mode, "configName:", configName,
                        "拉到 obj.type:", latest.type, "obj.tag:", latest.tag,
                        "dims:", latest.dimensions.map(function(d){return d.key+"("+(d.levels?d.levels.length:0)+")"}).join(","))
                    _doApply(latest, xhr.responseText)
                } catch (e) {
                    console.warn("[ConfigCheck] 解析现拉数据失败，回退缓存：", e)
                    _doApply(item.obj, item.rawText)
                }
            } else {
                console.warn("[ConfigCheck] 现拉失败 status=", xhr.status, "，回退缓存")
                _doApply(item.obj, item.rawText)
            }
        }
        xhr.open("GET", fetchUrl)
        xhr.send()
    } else {
        // 没法现拉，直接用缓存的 obj
        _doApply(item.obj, item.rawText)
    }
}

function _applyPendingRemoteConfig() {
    var list = _root._pendingRemoteConfig
    if (!list || !Array.isArray(list) || list.length === 0) return
    try {
        var currentMode = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
        // 【模式切换策略】空闲态一次应用多条时，最终切到"最后一条"对应的 mode。
        var _isIdle = (typeof Engine !== "undefined") ? (Engine.fileCount === 0) : true
        var _switchToMode = ""
        var _switchTag = ""
        // 深拷贝后修改再赋值，确保 QML property var binding 触发更新
        var fp2 = JSON.parse(JSON.stringify(_root._localConfigFingerprint || {}))
        // "用户实际应用的配置"映射（mode → configName），tooltip 显示源
        var appliedMap = {}
        try { appliedMap = JSON.parse(fp2["__applied__"] || "{}") } catch(e) {}
        var dimsCache = JSON.parse(JSON.stringify(_root._dimsByMode || {}))
        var ckCache = JSON.parse(JSON.stringify(_root._checklistByMode || {}))
        // 【tag 按 mode 独立缓存】批量应用时同步更新，避免多 mode 共享单一 tag 造成相互覆盖
        var tagCache = JSON.parse(JSON.stringify(_root._tagByMode || {}))

        list.forEach(function(item) {
            var obj = item.obj
            // 更新指纹基线（key = mode:configName，与检测时保持一致）
            var _fpKey = item.fpKey || (item.mode + ":" + item.configName)
            fp2[_fpKey] = item.rawText || _configFingerprint(obj)
            // 同步更新绑定关系指纹，防止下次轮询再次触发 bindingChanged
            if (item.bindingsFp) fp2["__bindings__"] = item.bindingsFp
            // 用户点了应用 = 明确接受该配置，清掉可能残留的忽略快照
            delete fp2["__ignored__:" + _fpKey]
            // 记录实际应用的配置（tooltip 显示源，见单条应用路径注释）
            if (item.mode && item.configName) appliedMap[item.mode] = item.configName

            // 所有 mode 都存入维度缓存
            var _dims = obj.dimensions.map(function(d) {
                var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                return Object.assign({}, d, { starCount: sc })
            })
            dimsCache[item.mode] = _dims
            // 同步存入该 mode 的 checklist
            ckCache[item.mode] = Array.isArray(obj.checklists) && obj.checklists.length > 0
                ? { items: obj.checklists, exclusiveKey: _parseChecklistExclusiveKey(obj) }
                : null
            // 同步存入该 mode 的 tag（无论当前 mode 是否匹配）
            tagCache[item.mode] = obj.tag || ""

            if (item.mode === currentMode) {
                // 【强制两阶段刷新】先清空 → Timer 触发 → 赋新数组
                _forceApplyDimensions(_dims, obj.tag || "", item.mode, "applyPending")
                // 同步热更新 checklist（仅当前 mode）
                if (Array.isArray(obj.checklists) && obj.checklists.length > 0) {
                    _root.reviewChecklist = obj.checklists
                    _root.reviewChecklistExclusiveKey = _parseChecklistExclusiveKey(obj)
                } else {
                    _root.reviewChecklist = []
                    _root.reviewChecklistExclusiveKey = ""
                }
                // 持久化到本地缓存文件
                var localPath = _resourcesDir() + "/dimensions.json"
                if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
                    EngineBridge.writeTextFile(localPath, JSON.stringify(obj))
                }
                console.log("[ConfigCheck] 已热更新当前模式维度，mode:", item.mode,
                    "维度：", _dims.map(function(d){return d.key + "(" + d.starCount + "星)"}).join(", "),
                    "tag:", obj.tag)
            } else if (_isIdle) {
                // 空闲态：记下要切到的 mode（覆盖式：最后一条生效）
                _switchToMode = item.mode
                _switchTag = obj.tag || ""
                console.log("[ConfigCheck] 空闲态应用→将在循环结束后切换到 mode：", item.mode)
            } else {
                console.log("[ConfigCheck] 已更新维度缓存（非当前模式且已在对比中，不切换、不重建UI）",
                    "被应用 mode:", item.mode, "当前 mode:", currentMode,
                    "fileCount:", (typeof Engine !== "undefined") ? Engine.fileCount : "?")
            }
        })

        _root._dimsByMode = dimsCache
        _root._checklistByMode = ckCache
        // 【关键】立即按 mode 独立持久化，保证多 mode 独立存储不互相覆盖
        _saveDimsByMode()
        _root._tagByMode = tagCache
        _saveTagByMode()
        // 落盘"实际应用的配置"映射（tooltip 显示源）
        fp2["__applied__"] = JSON.stringify(appliedMap)
        _root._localConfigFingerprint = fp2
        _saveFingerprintToFile()
        _root._pendingRemoteConfig = null
        _root._taskUpdateVisible = false

        // 空闲态：在所有缓存都落盘后再切模式，onCurrentModeChanged 就能从 _dimsByMode 拿到最新维度
        if (_isIdle && _switchToMode && _switchToMode !== currentMode) {
            console.log("[ConfigCheck] 空闲态应用完成→自动切换当前模式：", currentMode, "→", _switchToMode)
            if (typeof Rating !== "undefined") {
                Rating.currentMode = _switchToMode
                if (_switchTag) Rating.uploadTag = _switchTag
            }
            _root._remoteTag = _switchTag
        }
    } catch (e) {
        console.warn("[ConfigCheck] 应用配置失败：", e)
    }
}

function _resourcesDir() {
    var exe = Qt.application.arguments[0]
    if (Qt.platform.os === "osx") {
        var macosDir   = exe.substring(0, exe.lastIndexOf("/"))
        var contentsDir = macosDir.substring(0, macosDir.lastIndexOf("/"))
        return contentsDir + "/Resources"
    } else {
        return exe.substring(0, exe.lastIndexOf("/"))
    }
}

function _saveFingerprintToFile() {
    var fpPath = _resourcesDir() + "/config_fingerprint.json"
    if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
        EngineBridge.writeTextFile(fpPath, JSON.stringify(_root._localConfigFingerprint || {}))
    }
}

function _loadFingerprintFromFile(callback) {
    var localFpPath = _resourcesDir() + "/config_fingerprint.json"

    // ── 优先同步读 ──────────────────────────────────────────────
    if (typeof Fs !== "undefined" && typeof Fs.readTextFile === "function") {
        try {
            var text = Fs.readTextFile(localFpPath) || ""
            if (text.length > 0) {
                var obj = JSON.parse(text)
                if (obj && typeof obj === "object") {
                    _root._localConfigFingerprint = obj
                    console.log("[ConfigCheck] [Sync] 已从文件加载指纹，共",
                        Object.keys(obj).length, "条")
                }
            }
            // 无论文件是否存在（首次启动就没有），都视为「已完成加载」
            // ——文件不存在时 text 为空，_localConfigFingerprint 保持默认空对象即可，
            // 与原异步版本 status===0/200 但内容为空的行为完全一致。
            if (typeof callback === "function") callback()
            return
        } catch (e) {
            console.warn("[ConfigCheck] [Sync] 同步读指纹失败，回退异步 XHR：", e)
            // 落到下面的异步兜底
        }
    }

    // ── 兜底：老路径异步 XHR（保留以防万一）────────────────────
    var fpUrl = "file://" + localFpPath
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE) return
        if (xhr.status === 200 || xhr.status === 0) {
            try {
                var obj2 = JSON.parse(xhr.responseText)
                if (obj2 && typeof obj2 === "object") {
                    _root._localConfigFingerprint = obj2
                    console.log("[ConfigCheck] 已从文件加载指纹，共", Object.keys(obj2).length, "条")
                }
            } catch (e) {}
        }
        if (typeof callback === "function") callback()
    }
    xhr.open("GET", fpUrl)
    xhr.send()
}

function loadDimensionsFromUrl(url, callback, forMode) {
    var _fm = forMode || ""
    // 【优先命中缓存】用户点过"应用"或启动装载过，_dimsByMode[forMode] 已有权威数据，
    // 不再走网络（否则服务端返回可能与用户预期不一致，并会反覆盖已确认的缓存）
    // 【关键】QML property var 里存的数组读回来常常不是纯 JS Array（会被包成 QJSValue/QVariantList），
    // Array.isArray 会返回 false 导致这里错过缓存分支。改用 length 做 duck-typing，并转成纯数组。
    var _rawCache = _fm ? _dimsForMode(_fm) : null
    if (_rawCache && typeof _rawCache.length === "number" && _rawCache.length > 0) {
        var cachedDims = []
        for (var _ci = 0; _ci < _rawCache.length; _ci++) cachedDims.push(_rawCache[_ci])
        console.log("[DimLoad] 命中缓存 → forMode:", _fm,
            "维度：", cachedDims.map(function(d){return d.key+"("+(d.starCount||5)+"星)"}).join(","),
            "，跳过网络请求")
        var _curMode0 = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
        if (_fm === _curMode0) {
            _forceApplyDimensions(cachedDims, _root._remoteTag, _fm, "loadFromUrl(cache)")
        } else {
            console.warn("[DimLoad] ⚠️ forMode(", _fm, ") ≠ currentMode(", _curMode0, ")，不更新 UI")
        }
        if (typeof callback === "function") callback(true)
        return
    }
    console.log("[DimLoad] 未命中缓存或未指定 mode，走网络请求 → url:", url, "forMode:", _fm || "-")
    var xhr = new XMLHttpRequest()
    var _done = false
    // 5秒超时兜底：防止网络不通时 callback 永远不触发导致评分面板空白
    var _timer = Qt.createQmlObject('import QtQuick 2.0; Timer { interval: 5000; repeat: false }', root)
    _timer.triggered.connect(function() {
        if (!_done) {
            _done = true
            console.warn("[DimLoad] 请求超时（5s），使用本地缓存维度")
            xhr.abort()
            if (typeof callback === "function") callback(false)
        }
        _timer.destroy()
    })
    _timer.start()
    xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE) return
        if (_done) return  // 已超时，忽略
        _done = true
        _timer.stop()
        if (xhr.status === 200 || xhr.status === 0) {
            try {
                var obj = JSON.parse(xhr.responseText)
                if (obj && Array.isArray(obj.dimensions) && obj.dimensions.length > 0) {
                    // 1. 热重载维度（预注入 starCount，避免 Repeater delegate 依赖深层 levels.length 动态计算）
                    var _dims1 = obj.dimensions.map(function(d) {
                        var sc = (d.levels && Array.isArray(d.levels) && d.levels.length > 0) ? d.levels.length : 5
                        return Object.assign({}, d, { starCount: sc })
                    })
                    var _curMode = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
                    // 【二重防线】若指定了 forMode 且不等于 currentMode，只写缓存，不动 UI
                    if (_fm && _fm !== _curMode) {
                        console.warn("[DimLoad] ⚠️ 网络返回但 forMode(", _fm, ") ≠ currentMode(", _curMode, ")，只写缓存不动 UI")
                        var _dimsUpd0 = JSON.parse(JSON.stringify(_root._dimsByMode || {}))
                        _dimsUpd0[_fm] = _dims1
                        _root._dimsByMode = _dimsUpd0
                        _saveDimsByMode()
                        // 同步缓存该 mode 的 checklist
                        var _ckUpd0 = _root._checklistByMode || {}
                        _ckUpd0[_fm] = Array.isArray(obj.checklists) && obj.checklists.length > 0
                            ? { items: obj.checklists, exclusiveKey: _parseChecklistExclusiveKey(obj) }
                            : null
                        _root._checklistByMode = _ckUpd0
                        // 【tag 按 mode 独立缓存】写缓存时同步写 _tagByMode[_fm]，不碰 Rating.uploadTag
                        _setTagForMode(_fm, obj.tag || "")
                        if (typeof callback === "function") callback(true)
                        return
                    }
                    console.log("[DimLoad] 网络返回并写入 UI → forMode:", _fm || "(unspecified)",
                        "currentMode:", _curMode,
                        "维度：", _dims1.map(function(d){return d.key+"("+d.starCount+"星)"}).join(","))
                    // 【强制两阶段刷新】确保外层 Repeater delegate 完全重建，starCount 生效
                    _forceApplyDimensions(_dims1, obj.tag || "", _curMode, "loadFromUrl(net)")
                    // 1a. 同步更新 _dimsByMode 缓存（按当前 mode 存储）
                    if (_curMode && _curMode !== "off") {
                        var _dimsUpd = JSON.parse(JSON.stringify(_root._dimsByMode || {}))
                        _dimsUpd[_curMode] = _dims1
                        _root._dimsByMode = _dimsUpd
                        // 同步缓存该 mode 的 checklist
                        var _ckUpd = _root._checklistByMode || {}
                        _ckUpd[_curMode] = Array.isArray(obj.checklists) && obj.checklists.length > 0
                            ? { items: obj.checklists, exclusiveKey: _parseChecklistExclusiveKey(obj) }
                            : null
                        _root._checklistByMode = _ckUpd
                        // 【关键】按 mode 独立持久化
                        _saveDimsByMode()
                        // 【tag 按 mode 独立缓存】与维度缓存保持同步，当前 mode 的 tag 也落盘
                        _setTagForMode(_curMode, obj.tag || "")
                    }
                    // 1b. 同步远程配置的 tag 到备注 tag 输入框（用户可手动覆盖）
                    if (obj.tag && typeof Rating !== "undefined") {
                        Rating.uploadTag = obj.tag
                    }
                    // 存储远程 tag，供上传时校验
                    _root._remoteTag = obj.tag || ""
                    // 2. 持久化到本地 Resources/dimensions.json（覆盖写）
                    var localPath = _resourcesDir() + "/dimensions.json"
                    if (typeof EngineBridge !== "undefined" && typeof EngineBridge.writeTextFile === "function") {
                        EngineBridge.writeTextFile(localPath, xhr.responseText)
                    }
                    if (typeof callback === "function") callback(true)
                    return
                }
            } catch (e) {
                console.warn("[DimLoad] JSON 解析失败：", e)
            }
        } else {
            console.warn("[DimLoad] 加载失败（HTTP", xhr.status, "）")
        }
        // 加载失败：仍调用 callback，让启动流程继续（用本地缓存维度）
        if (typeof callback === "function") callback(false)
    }
    xhr.open("GET", url)
    xhr.send()
}

function _dimApiUrl() {
    var base = (typeof Rating !== "undefined" && Rating.uploadServerUrl) ? Rating.uploadServerUrl.trim() : ""
    if (base.length === 0) return ""
    // 取 origin 部分：http://host:port
    var m = base.match(/^(https?:\/\/[^/]+)/)
    return m ? m[1] + "/api/dimensions" : ""
}

function _boundConfigName() {
    var mode = (typeof Rating !== "undefined") ? Rating.currentMode : ""
    if (!mode || mode === "off") return ""
    var fp = _root._localConfigFingerprint
    if (!fp) return ""
    // ① 优先「用户实际应用的配置」：手动接受多张卡片中的某张时，
    //    服务器 active 绑定（__bindings__）可能与实际应用的不一致
    var appliedStr = fp["__applied__"] || ""
    if (appliedStr.length > 0) {
        try {
            var applied = JSON.parse(appliedStr)
            if (applied && applied[mode]) return applied[mode]
        } catch(e) {}
    }
    // ② 服务器 active 绑定关系
    var bindingsStr = fp["__bindings__"] || ""
    if (bindingsStr.length > 0) {
        try {
            var bindings = JSON.parse(bindingsStr)
            if (bindings && bindings[mode]) {
                var val = bindings[mode]
                return Array.isArray(val) ? (val[0] || "") : val
            }
        } catch(e) {}
    }
    // 兜底：遍历 key "mode:configName"，取最后一个匹配
    var result = ""
    var keys = Object.keys(fp)
    for (var i = 0; i < keys.length; ++i) {
        var k = keys[i]
        if (k === "__bindings__") continue
        if (k.indexOf("__ignored__:") === 0) continue
        var sep = k.indexOf(":")
        if (sep < 0) continue
        if (k.substring(0, sep) === mode) result = k.substring(sep + 1)
    }
    return result
}

function _rulesPageUrl() {
    var base = (typeof Rating !== "undefined" && Rating.uploadServerUrl) ? Rating.uploadServerUrl.trim() : ""
    if (base.length === 0) return ""
    var configName = _boundConfigName()
    if (configName.length === 0) return ""
    var m = base.match(/^(https?:\/\/[^/]+)/)
    var origin = m ? m[1] : base.replace(/\/$/, "")
    return origin + "/?tab=dims#tasks/" + encodeURIComponent(configName)
}

function _rebuildCellRatingsForDims() {
    var n = Engine.fileCount
    if (n <= 0) return
    // quality_slide 模式下只取第一个维度用于普通打分
    var activeDims = _root.reviewDimensions
    if (_root.isQualitySlideMode && activeDims && activeDims.length >= 2)
        activeDims = [activeDims[0]]
    var hasDims = activeDims && activeDims.length > 0
    var arr = []
    for (var i = 0; i < n; ++i) {
        if (hasDims) {
            var obj = {}
            for (var d = 0; d < activeDims.length; ++d)
                obj[activeDims[d].key] = 0
            arr.push(obj)
        } else {
            arr.push(0)
        }
    }
    _root.cellRatings = arr
}

function _resetSlideRatings() {
    _root.slideEnteredOnce = false
    _root.slideRatingL = 0
    _root.slideRatingR = 0
}

function _restoreSlideRatings() {
    if (!_root.isQualitySlideMode) return
    if (typeof Rating === "undefined" || Engine.fileCount < 2) return
    var fpL = Engine.filePathAt(0)
    var fpR = Engine.filePathAt(1)
    if (!fpL || !fpR) return

    // 新格式：滑动打分的 slide_type = "multi_<第二维度key>"，与第一维度语义并列。
    // 优先按 file_path + slide_type 精确查找；找不到再走旧格式兼容分支。
    var rL = -1, rR = -1
    var slideKey = (_root.slideDimension && _root.slideDimension.key) ? _root.slideDimension.key : ""
    if (slideKey.length > 0) {
        rL = Rating.ratingFor(fpL, "multi_" + slideKey)
        rR = Rating.ratingFor(fpR, "multi_" + slideKey)
    }
    // 兼容旧数据：新格式没读到时，回退到旧的 slide_type=="slide" 硬编码格式
    if (rL < 0 || rR < 0) {
        var fnL = Engine.fileNameAt(0)
        var fnR = Engine.fileNameAt(1)
        var storedNameL = "1_" + fnL
        var storedNameR = "2_" + fnR
        var rows = Rating.getSlideRatings() || []
        for (var i = 0; i < rows.length; ++i) {
            var r = rows[i]
            if (rL < 0 && r.file_path === fpL && r.file_name === storedNameL) rL = r.stars || 0
            else if (rR < 0 && r.file_path === fpR && r.file_name === storedNameR) rR = r.stars || 0
        }
    }
    if (rL < 0) rL = 0
    if (rR < 0) rR = 0
    _root.slideRatingL = rL
    _root.slideRatingR = rR
    // 如果任意一侧已有评分，说明本组曾经进入过滑动对比
    if (rL > 0 || rR > 0) _root.slideEnteredOnce = true
}

function setSlideRating(side, score) {
    if (score < 0) score = 0
    if (score > _root.slideMaxStars) score = _root.slideMaxStars
    if (side === "L") _root.slideRatingL = (_root.slideRatingL === score ? 0 : score)
    else if (side === "R") _root.slideRatingR = (_root.slideRatingR === score ? 0 : score)

    // 立即持久化：slide_type 使用 "multi_<第二维度key>"，
    // 让服务端展示的字段直接是远程配置的维度名，与第一维度语义统一。
    if (typeof Rating !== "undefined" && Engine.fileCount >= 2) {
        var fpL = Engine.filePathAt(0)
        var fpR = Engine.filePathAt(1)
        var fnL = Engine.fileNameAt(0)
        var fnR = Engine.fileNameAt(1)
        var slideKey = (_root.slideDimension && _root.slideDimension.key) ? _root.slideDimension.key : ""
        var st = (slideKey.length > 0) ? ("multi_" + slideKey) : ""
        Rating.recordSlideRating(fpL, fnL, _root.slideRatingL, fpR, fnR, _root.slideRatingR, st)
    }
    // 触发 allGroupsRated 响应式重算，让"下一组"按钮及时更新亮/灰状态
    if (typeof _multiGroupDialog !== "undefined" && _multiGroupDialog._bumpState)
        _multiGroupDialog._bumpState()
}

function _refTargetIdx() {
    return Engine.fileCount > 0 ? 0 : -1
}

function _refDirOf(fp) {
    if (!fp || fp.length === 0) return ""
    var p = String(fp)
    var i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
    return i > 0 ? p.substring(0, i) : ""
}

function _phoneScalePresetsForScreen(name) {
    var map = _root._phoneScalePresetsByScreen
    if (name && map.hasOwnProperty(name)) return map[name]
    return null
}

function _autoPhoneScaleByFormula() {
    // 优先用 QML Screen 暴露的物理像素密度
    var pd = Screen.pixelDensity   // 物理像素 / mm
    var dpr = Screen.devicePixelRatio || 1
    // 主动从 ScreenProbe 拿一次实时值。该路径不走 QML Screen 缓存，
    // 在 macOS 外接屏切档位时能拿到刷新后的真值（关键修复点）。
    if (typeof ScreenProbe !== "undefined") {
        var st = ScreenProbe.currentForWindow(root)
        if (st && st.pixelDensity > 0) {
            pd  = st.pixelDensity
            dpr = st.devicePixelRatio > 0 ? st.devicePixelRatio : dpr
        }
    }
    if (pd && pd > 0) {
        var mmPerLogicalPx = dpr / pd
        var fw = _root.phoneFixedWidth > 0 ? _root.phoneFixedWidth : 440
        var s = _root._phoneTargetPhysicalMm / (fw * mmPerLogicalPx)
        if (s > 0) return s
    }
    return -1
}

function _autoPhoneScaleNearestPreset(w, presets) {
    if (!presets || presets.length === 0) return -1
    var best = presets[0]
    var bestDiff = Math.abs(w - best[0])
    for (var i = 1; i < presets.length; ++i) {
        var d = Math.abs(w - presets[i][0])
        if (d < bestDiff) { best = presets[i]; bestDiff = d }
    }
    return best[1]
}

function _autoPhoneScaleWindowsPreset(physWidth, dpr) {
    var t = _root._phoneScalePresetsWindows
    if (!t || t.length === 0) return -1
    if (!(physWidth > 0) || !(dpr > 0)) return -1
    for (var i = 0; i < t.length; ++i) {
        var pw        = t[i][0]
        var baseDpr   = t[i][1]
        var baseScale = t[i][2]
        if (Math.abs(physWidth - pw) <= 8) {
            // dpr 反比反推：scale ∝ 1 / dpr
            return baseScale * baseDpr / dpr
        }
    }
    return -1
}

function _applyAutoPhoneScale() {
    if (!_root.phoneScaleAutoTrack) return
    // 优先从 ScreenProbe 取实时屏幕状态（绕开 QML Screen 在 macOS 外接屏
    // 切档位时的缓存问题）；探测失败时回退到 QML Screen 附加属性。
    var w = Screen.width
    var nm = Screen.name
    var dpr = Screen.devicePixelRatio || 1
    if (typeof ScreenProbe !== "undefined") {
        var st = ScreenProbe.currentForWindow(root)
        if (st && st.width > 0) {
            w   = st.width
            nm  = st.name || nm
            dpr = st.devicePixelRatio > 0 ? st.devicePixelRatio : dpr
        }
    }
    if (!w || w <= 0) return
    // 1) 已知显示器：完全走预设表（保护已校准的内建/PHL 体验，不动）
    //   注意：by-name 分支只在 **非 Windows** 平台启用。
    //   原因：同一台外接显示器（如 PHL 278B1）在 macOS / Windows 下
    //   Screen.name 一致，但 Windows 还会叠加"分辨率档位 × 推荐缩放"，
    //   单凭显示器名无法区分；继续走 by-name 会拿到 macOS 校准的
    //   单一系数，与 Windows 实测值不符（用户报 3200×1800@150%
    //   命中 PHL 278B1 → 0.57，实际应=0.63）。
    //   Windows 一律落到 2-Win) 物理宽+dpr 实测表 → 公式 → 默认表。
    var presets = (Qt.platform.os === "windows")
                ? null
                : _phoneScalePresetsForScreen(nm)
    var s = -1
    if (presets) {
        s = _autoPhoneScaleNearestPreset(w, presets)
    } else if (Qt.platform.os === "windows") {
        // 2-Win) Windows 平台未知显示器：先按 (物理宽, dpr) 二元组查实测表。
        //
        //   背景：Windows 上 Qt 的 Screen.pixelDensity 取自 EDID 物理尺寸，
        //   切换分辨率档位时**不会变** → 公式
        //     scale = TARGET_MM / (fw × dpr / pd)
        //   的输出在不同档位下几乎一样，公式自适应在 Windows 失效。
        //
        //   实测表覆盖用户提供的若干 (分辨率, 推荐缩放) 组合（见
        //   _phoneScalePresetsWindows）。命中返回精确系数；未命中
        //   （用户用了非推荐分辨率/缩放档位）回退公式自适应；公式
        //   再失败才用默认表近邻兜底。
        //
        //   关键：(物理宽, dpr) 二元组天然区分了 Windows 上的"缩放档位"
        //   ——同一物理屏不同推荐缩放下 dpr 不同，会落到不同行；同一
        //   逻辑宽不同物理宽组合也不会互相误命中。
        //
        //   注意：Screen.width 在 Windows 上是"物理宽 / dpr"（已除过缩放），
        //   要还原回物理宽必须乘 dpr 后四舍五入。
        var physW = Math.round(w * dpr)
        s = _autoPhoneScaleWindowsPreset(physW, dpr)
        if (s <= 0) {
            s = _autoPhoneScaleByFormula()
            if (s <= 0)
                s = _autoPhoneScaleNearestPreset(w, _root._phoneScalePresetsDefault)
        }
    } else {
        // 2) 未知显示器（macOS / Linux）：物理 mm 公式自适应（保持原行为，
        //    macOS 已验证可靠）；公式失效兜底用默认表最近邻。
        s = _autoPhoneScaleByFormula()
        if (s <= 0)
            s = _autoPhoneScaleNearestPreset(w, _root._phoneScalePresetsDefault)
    }
    if (s <= 0) return
    // 与 SpinBox 校准框范围一致（0.1 ~ 5.0）
    if (s < 0.1) s = 0.1
    else if (s > 5.0) s = 5.0
    if (Math.abs(s - _root.phoneDisplayScale) > 0.001)
        _root.phoneDisplayScale = s
}

function _stepPhoneScale(delta) {
    var v = _root.phoneDisplayScale + delta
    v = Math.round(v * 100) / 100
    if (v < 0.1) v = 0.1
    if (v > 5.0) v = 5.0
    _root.phoneScaleAutoTrack = false
    _root.phoneDisplayScale = v
}

function fmtTime(sec) {
    if (!isFinite(sec) || sec < 0) sec = 0
    var h = Math.floor(sec / 3600)
    var m = Math.floor((sec % 3600) / 60)
    var s = Math.floor(sec % 60)
    function pad(n) { return n < 10 ? "0" + n : "" + n }
    return (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(s)
}

function _fdNow() {
    if (Engine.fileCount <= 0) return 1.0 / 30.0
    var fd = (typeof Engine.frameDuration === "function") ? Engine.frameDuration() : 0
    return (fd && fd > 0) ? fd : (1.0 / 30.0)
}

function _isAtFirstFrameNow() {
    if (Engine.fileCount <= 0) return false
    if (Engine.duration <= 0) return false
    return Engine.position <= _fdNow() * 0.5
}

function _isAtLastFrameNow() {
    if (Engine.fileCount <= 0) return false
    var d = Engine.duration
    if (d <= 0) return false
    return (d - Engine.position) <= _fdNow() * 0.5
}
