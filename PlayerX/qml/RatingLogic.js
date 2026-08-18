.import "MainLogic.js" as ML

// 用空对象兜底，防止 QML 信号在 _initRating 之前触发时崩溃
var _root = {}
var _multiGroupDialog = null
var _ratingsDialog = null
var _ratingToast = null

function _initRating(ctx) {
    _root = ctx.root
    _multiGroupDialog = ctx.multiGroupDialog
    _ratingsDialog = ctx.ratingsDialog
    _ratingToast = ctx.ratingToast
}

function _boot() {
    _root._bootT0 = Date.now()
    // 初始化手机模式校准系数（按当前 Screen.width 查表，跟随系统显示档位变化）
    ML._applyAutoPhoneScale()

    // 启动时立即同步一次 checklist 白名单到 C++（保证在任何配置加载完成前，
    // 导出/上传就已经处于"过滤为空"状态，避免残留旧勾选被写入 CSV）。
    ML._syncChecklistWhitelist()

    // 开发者模式：不记忆，每次启动一律不勾选（隐藏测试模式），只能当次手动开启。
    // 同时清掉历史版本可能残留的持久化值，避免旧机器上一直"被勾选"。
    _root.developerMode = false
    try { Rating.saveString("ui/developerMode", "0") } catch (e) {}
    // 恢复自动更新开关（持久化）：首次安装默认不勾选，之后以用户选择为准
    try { _root.autoUpdate = (Rating.loadString("ui/autoUpdate", "0") === "1") } catch (e) {}
    // 开发者模式未开启时，若历史记忆（rating.mode）停留在「测试模式」，强制回退为
    // 「关闭评分」——避免普通用户在不知情下处于测试模式（评分会写入测试 CSV）。
    if (!_root.developerMode && typeof Rating !== "undefined" && Rating.currentMode === "test") {
        console.log("[DevMode] 开发者模式未开启，当前模式为 test → 强制回退为 off")
        Rating.currentMode = "off"
    }

    // 加载多维度评分配置
    // 新策略：内置默认配置（Resources/default_configs/<mode>.json，跟随软件发布）为底，
    //       远程"接受"来的配置只是临时覆盖层（dimsByMode.json 等）；
    //       启动不再主动拉取远程，覆盖层优先、内置兜底，任何模式启动即有配置。
    // 【按 mode 独立缓存】读取 dimsByMode.json → 填充 _root._dimsByMode，
    // 并按当前 Rating.currentMode 装载对应维度到 UI。
    // 这是解决"多 mode 配置串扰"的关键：每个 mode 的维度独立保存，不再共用 dimensions.json。
    function _loadDimsByModeCache(url, onDone) {
        var xhr3 = new XMLHttpRequest()
        xhr3.onreadystatechange = function() {
            if (xhr3.readyState !== XMLHttpRequest.DONE) return
            var loaded = false
            if (xhr3.status === 200 || xhr3.status === 0) {
                try {
                    var cache = JSON.parse(xhr3.responseText)
                    if (cache && typeof cache === "object") {
                        _root._dimsByMode = cache
                        // 按当前 mode 装载到 UI（若有）
                        var curMode = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
                        if (curMode && curMode !== "off" && cache[curMode] && Array.isArray(cache[curMode]) && cache[curMode].length > 0) {
                            _root.reviewDimensions = cache[curMode]
                            _root.reviewDimensionsVersion++
                            console.log("[DimLoad-B] _loadDimsByModeCache 启动装载 mode=", curMode, "维度数:", cache[curMode].length,
                                "（理论上只在启动时调用）")
                        }
                        loaded = true
                    }
                } catch (e) {
                    console.warn("[DimLoad] 解析 dimsByMode.json 失败：", e)
                }
            }
            if (typeof onDone === "function") onDone(loaded)
        }
        xhr3.open("GET", url)
        xhr3.send()
    }
    // 构建 bundle Resources 路径
    var exePath = Qt.application.arguments[0]  // 如 .../PlayerX.app/Contents/MacOS/PlayerX
    var dimsByModeUrl = ""
    var dimsByModeLocalPath = ""   // 无 file:// 前缀，用于 Fs.readTextFile 同步读
    if (Qt.platform.os === "osx") {
        var macosDir = exePath.substring(0, exePath.lastIndexOf("/"))  // .../Contents/MacOS
        var contentsDir = macosDir.substring(0, macosDir.lastIndexOf("/"))  // .../Contents
        dimsByModeUrl = "file://" + contentsDir + "/Resources/dimsByMode.json"
        dimsByModeLocalPath = contentsDir + "/Resources/dimsByMode.json"
    } else {
        var binDir = exePath.substring(0, exePath.lastIndexOf("/"))
        dimsByModeUrl = "file://" + binDir + "/dimsByMode.json"
        dimsByModeLocalPath = binDir + "/dimsByMode.json"
    }

    // 【内置默认配置】最先加载出厂配置（跟随软件，永远在），
    // 之后读的 dimsByMode.json 等只是远程"接受"留下的临时覆盖层。
    ML._loadBuiltinDefaultConfigs()

    // 【无感启动优化】优先用 Fs.readTextFile 同步读取本地 dimsByMode.json，
    //   这样 Component.onCompleted 一返回，reviewDimensions 就已就绪。
    //   避免"打开文件夹后星星隔一下才出现"的问题：
    //     - 之前走异步 XMLHttpRequest：从 Component.onCompleted 到 xhr.DONE
    //       之间存在几十~几百 ms 的窗口，用户手速快时会先看到空白再看到星星。
    //     - 现在走 Q_INVOKABLE 同步读：本地几十 KB 文件读完就是毫秒级，
    //       打开文件夹时 onFilesChanged 直接读到 reviewDimensions 立即回填评分。
    //   同步失败（文件不存在/JSON 错误）时回退到异步 XHR 保底路径，
    //   不影响原有的 dimensions.json fallback 逻辑；也完全不动远程配置更新流程。
    var syncLoaded = false
    if (typeof Fs !== "undefined" && typeof Fs.readTextFile === "function") {
        try {
            var text = Fs.readTextFile(dimsByModeLocalPath) || ""
            if (text.length > 0) {
                var cache = JSON.parse(text)
                if (cache && typeof cache === "object") {
                    _root._dimsByMode = cache
                    var curMode0 = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
                    if (curMode0 && curMode0 !== "off"
                            && cache[curMode0] && Array.isArray(cache[curMode0])
                            && cache[curMode0].length > 0) {
                        // 预注入 starCount，避免 Repeater delegate 依赖深层
                        // levels.length 动态计算（与 _applyModeConfigToUI 保持一致）
                        var _dimsSync = cache[curMode0].map(function(d) {
                            var sc = (d && d.levels && Array.isArray(d.levels) && d.levels.length > 0)
                                        ? d.levels.length : 5
                            return Object.assign({}, d, { starCount: sc })
                        })
                        _root.reviewDimensions = _dimsSync
                        _root.reviewDimensionsVersion++
                        console.log("[DimLoad-Sync] 同步读取 dimsByMode.json 完成，mode=",
                            curMode0, "维度数:", _dimsSync.length)
                    }
                    syncLoaded = true
                }
            }
        } catch (e) {
            console.warn("[DimLoad-Sync] 同步解析 dimsByMode.json 失败，回退异步路径：", e)
        }
    }

    // 【tag 按 mode 独立缓存 - 同步读取】
    //   与 dimsByMode.json 平行的一份 tag 落盘，Resources/tagByMode.json。
    //   启动瞬间就把当前 Rating.currentMode 对应的 tag 灌进 _remoteTag / Rating.uploadTag，
    //   RatingsDialog 一打开就能显示正确的备注 tag，不会所有模式都是同一个。
    //   同步失败/文件缺失 → 静默跳过，走后续远程配置流程再补齐。
    if (typeof Fs !== "undefined" && typeof Fs.readTextFile === "function") {
        try {
            var tagPath = (Qt.platform.os === "osx")
                    ? (contentsDir + "/Resources/tagByMode.json")
                    : (binDir + "/tagByMode.json")
            var tagText = Fs.readTextFile(tagPath) || ""
            if (tagText.length > 0) {
                var tagCache = JSON.parse(tagText)
                if (tagCache && typeof tagCache === "object") {
                    _root._tagByMode = tagCache
                    var curModeT = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
                    if (curModeT && curModeT !== "off" && typeof tagCache[curModeT] === "string") {
                        var tagInit = tagCache[curModeT]
                        _root._remoteTag = tagInit
                        if (typeof Rating !== "undefined" && Rating.uploadTag !== tagInit) {
                            Rating.uploadTag = tagInit
                        }
                        console.log("[TagLoad-Sync] 同步读取 tagByMode.json 完成，mode=", curModeT, "tag=", tagInit)
                    }
                }
            }
        } catch (e) {
            console.warn("[TagLoad-Sync] 同步解析 tagByMode.json 失败：", e)
        }
    }

    // 【checklist 按 mode 独立缓存 - 同步读取】与 tagByMode.json 完全平行
    if (typeof Fs !== "undefined" && typeof Fs.readTextFile === "function") {
        try {
            var ckPath = (Qt.platform.os === "osx")
                    ? (contentsDir + "/Resources/checklistByMode.json")
                    : (binDir + "/checklistByMode.json")
            console.log("[ChecklistLoad-Sync] 尝试读取路径:", ckPath)
            var ckText = Fs.readTextFile(ckPath) || ""
            console.log("[ChecklistLoad-Sync] 文件内容长度:", ckText.length, "内容前100字符:", ckText.substring(0, 100))
            if (ckText.length > 0) {
                var ckCache = JSON.parse(ckText)
                console.log("[ChecklistLoad-Sync] 解析成功，keys:", Object.keys(ckCache).join(","))
                if (ckCache && typeof ckCache === "object") {
                    _root._checklistByMode = ckCache
                    var curModeCk = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
                    console.log("[ChecklistLoad-Sync] 当前 mode:", curModeCk)
                    if (curModeCk && curModeCk !== "off") {
                        var ckForCur = ckCache[curModeCk]
                        console.log("[ChecklistLoad-Sync] mode对应checklist:", JSON.stringify(ckForCur))
                        if (ckForCur && Array.isArray(ckForCur.items) && ckForCur.items.length > 0) {
                            _root.reviewChecklist = ckForCur.items
                            _root.reviewChecklistExclusiveKey = ckForCur.exclusiveKey || ""
                            console.log("[ChecklistLoad-Sync] ✅ 同步读取完成，mode=", curModeCk, "条数:", ckForCur.items.length)
                        } else {
                            _root.reviewChecklist = []
                            _root.reviewChecklistExclusiveKey = ""
                            console.log("[ChecklistLoad-Sync] ⚠️ mode存在但items为空或格式不对:", JSON.stringify(ckForCur))
                        }
                    }
                }
            } else {
                console.log("[ChecklistLoad-Sync] ⚠️ 文件不存在或为空，checklistByMode.json 尚未生成")
            }
        } catch (e) {
            console.warn("[ChecklistLoad-Sync] 同步解析 checklistByMode.json 失败：", e)
        }
    }

    if (syncLoaded) {
        // 同步装载完成：覆盖层优先、内置兜底，当前模式立即生效（不再走任何远程/legacy 拉取）。
        var _bootMode = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
        if (_bootMode && _bootMode !== "off") ML._applyModeConfigToUI(_bootMode)
        ML._pruneOverridesEqualToBuiltin()
    } else {
        // 同步读失败（极端：平台无 Fs）：保底走异步 XHR 读覆盖层缓存，内置默认已在上面同步就绪。
        _loadDimsByModeCache(dimsByModeUrl, function(loaded) {
            var _m2 = (typeof Rating !== "undefined" && Rating.currentMode) ? Rating.currentMode : ""
            if (_m2 && _m2 !== "off") ML._applyModeConfigToUI(_m2)
            ML._pruneOverridesEqualToBuiltin()
        })
    }
}

function _showRatingToast(idx, score) {
    var stars = ""
    for (var i = 0; i < 5; ++i) stars += (i < score ? "\u2605" : "\u2606")
    var cleared = (score === 0)
    _root.ratingToastText = (cleared ? "已清除评分" : stars)
                      + "  \u00b7  \u901a\u9053 " + (idx + 1)
    _root.ratingToastText2 = ""   // 单行打分快闪，清掉可能残留的第二行
    _root.ratingToastKind  = cleared ? "clear" : "score"
    _root.ratingToastScore = score
    _ratingToast.show()
}
function _showRatingWarn(text, durationMs, fontPx, text2, sticky) {
    _root.ratingToastText  = text
    _root.ratingToastText2 = (typeof text2 === "string") ? text2 : ""
    _root.ratingToastKind  = "warn"
    _root.ratingToastScore = 0
    _ratingToast.show(durationMs, fontPx, sticky)
}
function ratingAt(idx, dimKey) {
    if (idx < 0 || idx >= _root.cellRatings.length) return 0
    var v = _root.cellRatings[idx]
    if (typeof v === "object" && v !== null) {
        // 多维模式：返回指定维度的分数
        return (dimKey && v[dimKey]) ? v[dimKey] : 0
    }
    return (typeof v === "number" && v >= 1 && v <= 5) ? v : 0
}
function setRatingAt(idx, score) {
    if (idx < 0) return
    // 复制后整体赋值，确保 onCellRatingsChanged 能触发到 UI 绑定
    var arr = _root.cellRatings.slice()
    while (arr.length <= idx) arr.push(0)
    // 再次点击当前分数 = 取消评分
    arr[idx] = (arr[idx] === score) ? 0 : score
    _root.cellRatings = arr

    // 持久化到本地 CSV（Rating = RatingStore 单例）。
    // 取消评分（arr[idx]===0）也写入，便于审计；按 file_path+rater 覆盖，
    // 因此重复点同一分数→0→3 等只会留下最新一条。
    if (typeof Rating !== "undefined") {
        var fp = Engine.filePathAt(idx)
        if (fp && fp.length > 0) {
            var fn = Engine.fileNameAt(idx)
            // idx = 宫格索引（0-based），传给 RatingStore 用于在 CSV 的 file_name
            // 字段前加 "<idx+1>_" 前缀，方便多组对比时一眼定位通道；
            // 不影响标题栏 / 文件列表弹窗等其他位置的文件名显示。
            Rating.recordRating(fp, fn, arr[idx], idx)
        }
    }
    // 评分变更后 bump，让 allGroupsRated 响应式重算
    _multiGroupDialog._bumpState()
}
function _toggleCompareSlider() {
    if (_root.compareSliderActive) {
        _root.compareSliderActive = false
    } else if (_root.compareSliderAvailable) {
        _root.compareSliderActive = true
        // quality_slide：用户进入过滑动对比即记一次；切组时清空（见 onFilesChanged）。
        if (_root.isQualitySlideMode) _root.slideEnteredOnce = true
    }
}
function _toggleOne(idx) {
    if (idx < 0 || idx >= Engine.fileCount) return
    // 已经在该单路视图：再次按下 -> 回多路
    if (Engine.layoutMode === 0 && Engine.activeIndex === idx) {
        var v = _root.lastMultiLayout
        if (v === 0) v = 1   // 保险：永远不会回到 Single
        Engine.layoutMode = v
        return
    }
    // 否则进入 Single 并聚焦到该窗口；同时把 UI 选中态也设上，让快捷评分有目标
    Engine.activeIndex = idx
    Engine.layoutMode  = 0  // LayoutSingle
    _root.selectedIdx   = idx
}
function _resolveRatingTarget() {
    if (Engine.fileCount <= 0) return -1
    if (_root.selectedIdx >= 0 && _root.selectedIdx < Engine.fileCount)
        return _root.selectedIdx
    if (Engine.fileCount === 1) return 0
    return -1
}
function _onChecklistChanged() {
    if (typeof _multiGroupDialog !== "undefined" && _multiGroupDialog._bumpState)
        _multiGroupDialog._bumpState()
    // 若「视频评分数据」对话框已打开，让它同步重算文件夹完成度（含 checklist 未勾选统计），
    // 避免用户勾/取消后要重开 Dialog 才看到最新的 ✓ / ⚠ 状态。
    if (typeof _ratingsDialog !== "undefined"
            && _ratingsDialog.visible
            && typeof _ratingsDialog._refresh === "function") {
        _ratingsDialog._refresh()
    }
}
function _writeRating(idx, score, dimKey) {
    // 超出当前模式上限时仅 UI 层钉一下，避免 cellRatings 写出 "5" 但后端实际存为 3
    // 造成"UI 与实际不一致"。RatingStore::recordRating 内部也会再截一次、双保险。
    // 有维度配置时，上限从该维度的 levels.length 取（每个维度可独立配置星数）；
    // 无维度时才用 Rating.maxStars（C++ 层按模式设定的全局上限）。
    var cap = _root.reviewMaxStars
    if (dimKey && _root.reviewDimensions && _root.reviewDimensions.length > 0) {
        // 找到对应维度，取其 levels 数组长度作为上限
        for (var di = 0; di < _root.reviewDimensions.length; ++di) {
            var dim = _root.reviewDimensions[di]
            if (dim && dim.key === dimKey && dim.levels && dim.levels.length > 0) {
                cap = dim.levels.length
                break
            }
        }
    }
    if (cap > 0 && score > cap) score = cap
    if (score < 0) score = 0
    var arr = _root.cellRatings.slice()
    // 有维度配置时（不限于 multi_dim 模式），走多维写入路径
    var hasDims = _root.reviewDimensions && _root.reviewDimensions.length > 0
    if (hasDims && dimKey) {
        // 多维模式：写入对象的指定维度字段
        while (arr.length <= idx) {
            var emptyObj = {}
            var dims = _root.reviewDimensions
            for (var d = 0; d < dims.length; ++d) emptyObj[dims[d].key] = 0
            arr.push(emptyObj)
        }
        // 必须创建新对象才能触发QML属性变更通知
        var oldObj = arr[idx]
        var newObj = (typeof oldObj === "object" && oldObj !== null) ? Object.assign({}, oldObj) : {}
        newObj[dimKey] = score
        arr[idx] = newObj
        _root.cellRatings = arr
        // 持久化：file_name 用原始文件名，slide_type 传 "multi_<维度>" 区分各维度
        if (typeof Rating !== "undefined") {
            var fp = Engine.filePathAt(idx)
            if (fp && fp.length > 0) {
                Rating.recordRating(fp, Engine.fileNameAt(idx), score, idx, "multi_" + dimKey)
            }
        }
    } else {
        // 单维模式：原有逻辑
        while (arr.length <= idx) arr.push(0)
        arr[idx] = score
        _root.cellRatings = arr
        if (typeof Rating !== "undefined") {
            var fp2 = Engine.filePathAt(idx)
            if (fp2 && fp2.length > 0) {
        Rating.recordRating(fp2, Engine.fileNameAt(idx), score, idx)
            }
        }
    }
    // 评分变更后 bump，让 allGroupsRated 响应式重算
    _multiGroupDialog._bumpState()
}
function _setRatingForActive(score) {
    var idx = _resolveRatingTarget()
    if (idx < 0) {
        _showRatingWarn("\u8bf7\u5148\u9009\u4e2d\u4e00\u4e2a\u901a\u9053\uff08\u5355\u51fb\u753b\u9762\u6216\u6309 [ / ]\uff09")
        return
    }
    _writeRating(idx, score)
    _showRatingToast(idx, score)
}
function _clearRatingForActive() {
    var idx = _resolveRatingTarget()
    if (idx < 0) {
        _showRatingWarn("\u8bf7\u5148\u9009\u4e2d\u4e00\u4e2a\u901a\u9053\uff08\u5355\u51fb\u753b\u9762\u6216\u6309 [ / ]\uff09")
        return
    }
    _writeRating(idx, 0)
    _showRatingToast(idx, 0)
}
function _shiftActive(dir) {
    // dir: -1 上一路 / +1 下一路；循环。
    // 同时同步 Engine.activeIndex，让 Single 模式下的渲染也跟着切。
    var n = Engine.fileCount
    if (n <= 0) return
    var cur = _root.selectedIdx
    if (cur < 0) {
        // 未选中场景：进入选中态，从 0（往后切）或末尾（往前切）开始
        cur = (dir > 0) ? -1 : n   // 让下面 (cur+dir) 落到 0 / n-1
    }
    var nxt = ((cur + dir) % n + n) % n
    _root.selectedIdx = nxt
    Engine.activeIndex = nxt
}

