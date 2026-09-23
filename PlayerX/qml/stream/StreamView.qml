// StreamView.qml — 码流分析视图（仿 YuvSetupView 的两阶段结构）
//
// 阶段切换（与 YuvSetupView 同款）：
//   - setup 阶段：StreamBridge.slotCount === 0
//       · 让出左侧导航栏（main.qml 用 anchors.left 切到 leftNavBar.right）
//       · 显示「文件列表 + 添加/清空 + 当前选中文件参数预览」+「▶ 开始分析」按钮
//   - render 阶段：StreamBridge.slotCount > 0
//       · main.qml 把 anchors.left 切到 parent.left → 沉浸满屏
//       · 顶部流信息条 / 中部主显示区 / 底部全局总控栏（仿 YuvWindow 总控栏）
//       · 右侧统计卡片
//
// 与 YuvSetupView 的差异：
//   1. 不需要"手动填分辨率/fps/格式"等参数（这些从码流自动解析）
//   2. setup 阶段用户选完文件后直接"开始分析"，把已选路径 openFile（最多 3 个 slot）
//   3. render 阶段的"控制按钮"集中在最下面的全局总控栏（与 YuvWindow 总控栏同款 36px 半透明深色）

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import PlayerX 1.0

import "."

Item {
    id: streamView

    // ═════════════════════════════════════════════════════════════════════
    // 底部码率曲线面板（2026-09-16 新增）：
    //   · 由 GOP 栏左侧「码率」按钮向上展开，宽同 GOP 栏，高 180。
    //   · floating=false（挤占）：videoHost 高度减 180，视频区整体上移让位。
    //   · floating=true（悬浮）：videoHost 高度不变，面板圆角浮于视频上层。
    //   · 独立模块（StreamBitrateChart.qml），不引用右侧栏与主显示区内部状态。
// ═════════════════════════════════════ anchored lift for bitrate chart ═══
property bool bitrateChartOpen: false      // 默认关
property bool bitrateChartFloating: false // true=悬浮；false=挤占（视频上移）
property int  bitrateChartH: 200  // 面板高度（与层级一致；顶部把手拖拽可调）
// ═════════════════════════════════ anchored lift for hierarchy chart ════
property bool hierarchyChartOpen: true       // 默认开
property bool hierarchyChartFloating: false // true=悬浮；false=挤占（视频上移）
property int  hierarchyChartH: 200  // 面板高度（顶部把手拖拽可调，不持久化）
// 码率 + 层级 同时打开时的左右分栏比例（左侧占比，0.2~0.8，双击分隔条复位 0.5）
// 高度与比例均不持久化：每次启动回到默认（200 / 0.5）
property real panelSplitRatio: 0.5
    property int currentSlot: 0
    signal switchTab(string tab)

    // ── 文件列表（setup 阶段用，render 阶段也保留以便"切换"查看） ─────
    // 与 YuvSetupView.yuvSetupView.fileList 同款："待打开"文件路径数组
    property var pendingFiles: []
    property int pendingSelectedIndex: -1
    property string pendingStatus: ""
    property bool _pendingLoaded: false

    // ── 文件探测（setup 阶段点击文件时调用 probeFile） ──────────────
    property var _probeCache: ({})       // { path: { ...probeData } }（以路径为键，排序后仍命中）
    property var _probeData: ({})        // 当前选中文件的探测信息
    property bool _probing: false

    // ── 排序 ──
    property string _sortMode: "default"   // default | name_asc | name_desc | size_desc | size_asc | resolution_desc | resolution_asc | duration_desc | duration_asc
    property bool _dragHovering: false     // 拖拽悬停高亮

    // Ctrl+A 全选 / 取消全选（仅 setup 阶段生效）
    Shortcut {
        sequence: StandardKey.SelectAll
        enabled: StreamBridge.slotCount === 0 && streamView.pendingFiles.length > 0
        onActivated: streamView._toggleSelectAll()
    }

    // ── 多选（Ctrl+Click / Shift+Click / 全选） ──
    property var _selectedFiles: ({})      // { path: true } 选中集合
    property bool _selectAllChecked: false  // 全选按钮状态
    property int _anchorIndex: -1           // Shift 范围选的锚点

    // 行点击：根据修饰键决定单选 / Ctrl多选 / Shift范围选
    function _onFileClicked(idx, modifiers) {
        if (idx < 0 || idx >= streamView.pendingFiles.length) return
        const path = streamView.pendingFiles[idx]
        const ctrl = (modifiers & Qt.ControlModifier) !== 0
        const shift = (modifiers & Qt.ShiftModifier) !== 0

        if (shift && streamView._anchorIndex >= 0) {
            // 范围选：从 anchor 到 idx
            var s = Object.assign({}, streamView._selectedFiles)
            var lo = Math.min(streamView._anchorIndex, idx)
            var hi = Math.max(streamView._anchorIndex, idx)
            for (var i = lo; i <= hi; ++i)
                s[streamView.pendingFiles[i]] = true
            streamView._selectedFiles = s
        } else if (ctrl) {
            // 切换选中
            var s2 = Object.assign({}, streamView._selectedFiles)
            if (s2[path]) delete s2[path]
            else s2[path] = true
            streamView._selectedFiles = s2
            streamView._anchorIndex = idx
        } else {
            // 单选：清空其他，只选这个（一次性赋值确保绑定立即更新）
            var s3 = {}
            s3[path] = true
            streamView._selectedFiles = s3
            streamView._anchorIndex = idx
        }
        streamView._selectAllChecked = streamView._isAllSelected()

        // 更新信息面板
        streamView._onFileSelected(idx)
    }

    // 全选 / 全不选
    function _toggleSelectAll() {
        if (streamView._isAllSelected()) {
            streamView._selectedFiles = ({})
            streamView._selectAllChecked = false
        } else {
            var s = {}
            for (var i = 0; i < streamView.pendingFiles.length; ++i)
                s[streamView.pendingFiles[i]] = true
            streamView._selectedFiles = s
            streamView._selectAllChecked = true
        }
    }
    // 是否全部选中
    function _isAllSelected() {
        if (streamView.pendingFiles.length === 0) return false
        for (var i = 0; i < streamView.pendingFiles.length; ++i) {
            if (!streamView._selectedFiles[streamView.pendingFiles[i]]) return false
        }
        return true
    }
    // 选中数量
    function _selectedCount() {
        return Object.keys(streamView._selectedFiles).length
    }
    // 获取选中的文件路径列表（保持 pendingFiles 顺序）
    function _selectedPaths() {
        var paths = []
        for (var i = 0; i < streamView.pendingFiles.length; ++i) {
            var p = streamView.pendingFiles[i]
            if (streamView._selectedFiles[p]) paths.push(p)
        }
        return paths
    }
    // ── 裸码流导出 ──
    property string _exportStatus: ""
    property bool _exporting: false
    property var _pendingExportPaths: []

    // 导出裸码流（支持单个或批量）
    // paths: 选中的文件路径数组；不传则用 _selectedPaths()
    function _exportRawBitstream(paths) {
        if (streamView._exporting) return
        var filePaths = paths || streamView._selectedPaths()
        if (!filePaths || filePaths.length === 0) {
            streamView._exportStatus = "请先选择文件"
            return
        }
        // 选择输出目录
        exportFolderDialog.open()
        // 存储待导出列表供 dialog.onAccepted 使用
        streamView._pendingExportPaths = filePaths
    }

    // 实际执行导出
    function _doExportRawBitstream(outputDir) {
        var paths = streamView._pendingExportPaths || []
        if (paths.length === 0) {
            streamView._exportStatus = "⚠ 没有待导出的文件"
            exportStatusClearTimer.restart()
            return
        }
        streamView._exporting = true
        streamView._exportStatus = "正在导出 0/" + paths.length + "…"

        var done = 0
        var failed = 0
        var errorMsgs = []
        for (var i = 0; i < paths.length; ++i) {
            var srcPath = paths[i]
            var baseName = streamView._fileBasename(srcPath)
            // 输出文件名：原名 + .h264 / .265（根据编码）
            var info = streamView._probeCache[srcPath] || {}
            var codec = info.codec || "h264"
            var ext = (codec === "hevc") ? ".265" : ".h264"
            // 去掉原扩展名再加裸码流扩展名
            var dotIdx = baseName.lastIndexOf(".")
            if (dotIdx > 0) baseName = baseName.substring(0, dotIdx)
            var outPath = outputDir + "/" + baseName + ext

            streamView._exportStatus = "正在导出 (" + (i + 1) + "/" + paths.length + ") " + baseName + "…"

            var result = StreamBridge.demuxToAnnexB(srcPath, outPath)
            if (result.ok) {
                ++done
            } else {
                ++failed
                var err = result.error || "未知错误"
                errorMsgs.push(baseName + ": " + err)
                console.log("[Export] failed:", srcPath, err)
            }
        }

        streamView._exporting = false
        if (failed === 0) {
            streamView._exportStatus = "✅ 已导出 " + done + " 个裸码流文件到 " + outputDir
        } else {
            streamView._exportStatus = "⚠ 导出完成：成功 " + done + " / 失败 " + failed
                + (errorMsgs.length > 0 ? "（" + errorMsgs.join("; ") + "）" : "")
        }
        // 5 秒后清空状态（有错误时留更久）
        exportStatusClearTimer.interval = (failed > 0) ? 8000 : 3000
        exportStatusClearTimer.restart()
    }

    Component.onCompleted: {
        // 从 QSettings 恢复上次的码流文件列表（与 YuvBridge 一致）
        const saved = StreamBridge.streamFileList()
        if (saved && saved.length > 0) {
            streamView.pendingFiles = saved
            streamView.pendingSelectedIndex = 0
            // 批量预 probe 所有文件（列表显示大小+修改时间）
            streamView._batchProbe()
            // 选中第一个文件并展示详情
            streamView._onFileSelected(0)
            // 默认选中第一个文件（用于开始分析/导出）
            streamView._selectedFiles = ({})
            streamView._selectedFiles[saved[0]] = true
            streamView._anchorIndex = 0
            streamView._selectAllChecked = false
        }
        streamView._pendingLoaded = true
    }

    // pendingFiles 变化时自动持久化（跳过初始加载阶段避免覆盖未读数据）
    onPendingFilesChanged: {
        if (!streamView._pendingLoaded) return
        // 去重 + 去空
        const seen = new Set()
        const clean = []
        for (let i = 0; i < streamView.pendingFiles.length; ++i) {
            const p = streamView.pendingFiles[i]
            if (!p || p.length === 0) continue
            if (seen.has(p)) continue
            seen.add(p)
            clean.push(p)
        }
        StreamBridge.setStreamFileList(clean)
        // 同步清理选中集：删除已不在列表中的路径
        var newSel = {}
        var changed = false
        for (var key in streamView._selectedFiles) {
            if (seen.has(key)) {
                newSel[key] = true
            } else {
                changed = true
            }
        }
        if (changed) {
            streamView._selectedFiles = newSel
            streamView._selectAllChecked = streamView._isAllSelected()
        }
    }

    // 点击文件项：切换选中 + 调 probeFile 获取基本信息
    function _onFileSelected(idx) {
        streamView.pendingSelectedIndex = idx
        if (idx < 0 || idx >= streamView.pendingFiles.length) {
            streamView._probeData = ({})
            return
        }
        const path = streamView.pendingFiles[idx]
        // 有缓存直接用
        if (streamView._probeCache[path]) {
            streamView._probeData = streamView._probeCache[path]
            return
        }
        // 无缓存：调 probeFile
        streamView._probeData = ({})
        streamView._probing = true
        const data = StreamBridge.probeFile(path)
        streamView._probing = false
        if (data && Object.keys(data).length > 0) {
            streamView._probeCache[path] = data
            // 强制刷新 _probeCache 绑定（与 _batchProbe 同理），使列表中该行大小/时间立即显示
            streamView._probeCache = Object.assign({}, streamView._probeCache)
            streamView._probeData = data
        }
    }

    // ── 排序 ──
    // 对 pendingFiles 做排序。排序完成后清空 probeCache 键映射并重选第一个文件。
    function _sortFiles(mode) {
        const files = streamView.pendingFiles.slice()
        if (files.length <= 1) { streamView._sortMode = mode; return }

        // 预取每个文件的 probe 数据（利用缓存，避免重复 probe）
        const items = []
        for (let i = 0; i < files.length; ++i) {
            const p = files[i]
            let info = streamView._probeCache[p]
            if (!info) {
                info = StreamBridge.probeFile(p)
                if (info && Object.keys(info).length > 0)
                    streamView._probeCache[p] = info
            }
            items.push({ path: p, info: info || {} })
        }

        switch (mode) {
            case "name_asc":
                items.sort((a, b) => streamView._fileBasename(a.path).toLowerCase()
                                     .localeCompare(streamView._fileBasename(b.path).toLowerCase()))
                break
            case "name_desc":
                items.sort((a, b) => streamView._fileBasename(b.path).toLowerCase()
                                     .localeCompare(streamView._fileBasename(a.path).toLowerCase()))
                break
            case "size_asc":
                items.sort((a, b) => (a.info.fileSize || 0) - (b.info.fileSize || 0))
                break
            case "size_desc":
                items.sort((a, b) => (b.info.fileSize || 0) - (a.info.fileSize || 0))
                break
            case "resolution_asc":
                items.sort((a, b) => {
                    const pa = (a.info.width || 0) * (a.info.height || 0)
                    const pb = (b.info.width || 0) * (b.info.height || 0)
                    return pa - pb
                })
                break
            case "resolution_desc":
                items.sort((a, b) => {
                    const pa = (a.info.width || 0) * (a.info.height || 0)
                    const pb = (b.info.width || 0) * (b.info.height || 0)
                    return pb - pa
                })
                break
            case "duration_asc":
                items.sort((a, b) => (a.info.duration || 0) - (b.info.duration || 0))
                break
            case "duration_desc":
                items.sort((a, b) => (b.info.duration || 0) - (a.info.duration || 0))
                break
            default:
                // default：恢复添加顺序（无操作，items 已按原顺序）
                break
        }

        const sortedPaths = items.map(it => it.path)
        streamView._sortMode = mode
        streamView.pendingFiles = sortedPaths
        streamView.pendingSelectedIndex = 0
        streamView._onFileSelected(0)
        // 排序后默认选中第一个
        streamView._selectedFiles = ({})
        streamView._selectedFiles[sortedPaths[0]] = true
        streamView._anchorIndex = 0
        streamView._selectAllChecked = false
    }

    // ── 排序按钮文字 ──
    function _sortLabel() {
        const m = {
            "default": "默认",
            "name_asc": "名称 ↑",
            "name_desc": "名称 ↓",
            "size_asc": "大小 ↑",
            "size_desc": "大小 ↓",
            "resolution_asc": "分辨率 ↑",
            "resolution_desc": "分辨率 ↓",
            "duration_asc": "时长 ↑",
            "duration_desc": "时长 ↓"
        }
        return m[streamView._sortMode] || "默认"
    }

    // ── 批量预 probe：添加文件后遍历所有未缓存的路径，逐个探测并填充 _probeCache ──
    // 使文件列表中每行都能显示文件大小和修改时间，而不仅仅是被点击的那一个。
    function _batchProbe() {
        for (let i = 0; i < streamView.pendingFiles.length; ++i) {
            const p = streamView.pendingFiles[i]
            if (streamView._probeCache[p]) continue
            const info = StreamBridge.probeFile(p)
            if (info && Object.keys(info).length > 0)
                streamView._probeCache[p] = info
        }
        // 强制刷新 _probeCache 绑定：QML 对 property var 的原地修改（obj[key]=val）
        // 不会触发绑定刷新，ListView 中已存在的 delegate 不会重新求值。
        // 重新赋值一个浅拷贝对象，使依赖 _probeCache[modelData] 的 delegate 全部刷新。
        streamView._probeCache = Object.assign({}, streamView._probeCache)
        // 刷新当前选中文件的详情（可能刚被 probe 过）
        if (streamView.pendingSelectedIndex >= 0
            && streamView.pendingSelectedIndex < streamView.pendingFiles.length) {
            const curPath = streamView.pendingFiles[streamView.pendingSelectedIndex]
            if (streamView._probeCache[curPath])
                streamView._probeData = streamView._probeCache[curPath]
        }
    }

    // ── 拖拽导入：从 DropArea 接收文件 URL 列表 ──
    function _handleDroppedFiles(urls) {
        if (!urls || urls.length === 0) return
        const videoExts = ["mp4", "mov", "mkv", "avi", "webm", "flv", "ts", "m4v",
                           "wmv", "mpg", "mpeg", "m2ts", "mts", "vob", "ogv",
                           "3gp", "asf", "h264", "h265", "hevc", "264", "265",
                           "266", "h266", "vvc", "av1", "ivf", "obu", "avc",
                           "m2v", "mpv", "m1v", "y4m", "stream","bin"]
        const newPaths = []
        for (let i = 0; i < urls.length; ++i) {
            const localPath = streamView._normalizeFilePath(urls[i])
            if (!localPath || localPath.length === 0) continue

            // 文件夹：递归扫描视频文件
            if (Fs.isDirectoryPath(localPath)) {
                let found = []
                try { found = Fs.scanVideoFolderPath(localPath, true) || [] } catch (e) { found = [] }
                for (let j = 0; j < found.length; ++j) {
                    const p = found[j]
                    if (newPaths.indexOf(p) < 0 && streamView.pendingFiles.indexOf(p) < 0)
                        newPaths.push(p)
                }
                continue
            }

            // 文件：扩展名过滤
            const dotIdx = localPath.lastIndexOf(".")
            if (dotIdx < 0) continue
            const ext = localPath.substring(dotIdx + 1).toLowerCase()
            if (videoExts.indexOf(ext) < 0) continue
            // 去重
            if (newPaths.indexOf(localPath) < 0
                && streamView.pendingFiles.indexOf(localPath) < 0)
                newPaths.push(localPath)
        }
        if (newPaths.length === 0) {
            streamView.pendingStatus = "拖入的文件中未找到支持的视频格式"
            return
        }
        const merged = streamView.pendingFiles.slice()
        for (let i = 0; i < newPaths.length; ++i) merged.push(newPaths[i])
        streamView.pendingFiles = merged
        streamView.pendingSelectedIndex = merged.length - newPaths.length
        streamView.pendingStatus = ""
        // 批量预 probe，使列表中每行都能显示大小和修改时间
        streamView._batchProbe()
        // 选中第一个新加入的文件
        streamView._onFileSelected(streamView.pendingSelectedIndex)
        // 默认选中第一个新文件（用于开始分析/导出）
        streamView._selectedFiles = ({})
        streamView._selectedFiles[merged[streamView.pendingSelectedIndex]] = true
        streamView._anchorIndex = streamView.pendingSelectedIndex
        streamView._selectAllChecked = false
    }

    // 格式化码率
    function _formatBitrate(bps) {
        if (bps >= 1000000)
            return (bps / 1000000).toFixed(2) + " Mbps"
        if (bps >= 1000)
            return (bps / 1000).toFixed(0) + " kbps"
        return bps + " bps"
    }

    // 格式化时长
    function _formatDuration(secs) {
        if (secs <= 0) return "—"
        const h = Math.floor(secs / 3600)
        const m = Math.floor((secs % 3600) / 60)
        const s = Math.floor(secs % 60)
        if (h > 0)
            return h + ":" + String(m).padStart(2, '0') + ":" + String(s).padStart(2, '0')
        return m + ":" + String(s).padStart(2, '0')
    }

    // 格式化文件大小
    function _formatFileSize(bytes) {
        if (bytes <= 0) return "—"
        if (bytes >= 1048576)
            return (bytes / 1048576).toFixed(2) + " MB"
        if (bytes >= 1024)
            return (bytes / 1024).toFixed(1) + " KB"
        return bytes + " B"
    }

    // ── 当前 slot 的派生状态（render 阶段用） ───────────────────────
    // 兜底：slotCount > 0 但 currentSlot 指向空 slot 时，自动回落到第一个有效 slot，
    // 避免"已打开文件但顶部显示未加载文件 + 主区显示未加载码流"的歧义状态。
    readonly property int    effectiveSlot: {
        if (StreamBridge.slotCount === 0) return 0
        if (currentSlot >= 0 && currentSlot < StreamBridge.slotCount
            && StreamBridge.hasFile(currentSlot)) return currentSlot
        // currentSlot 失效：找第一个 hasFile 的 slot
        for (let i = 0; i < StreamBridge.slotCount; ++i) {
            if (StreamBridge.hasFile(i)) return i
        }
        return 0
    }
    // 注意：hasFile() 是 Q_INVOKABLE 函数而非属性，QML 绑定只在依赖的属性变化时才重求值。
    // effectiveSlot 在 slotCount 0→1 时值可能不变（0→0），导致 slotActive 不刷新。
    // 解决：显式依赖 StreamBridge.slotCount，确保 slotCount 变化时 slotActive 强制重求值。
    readonly property bool   slotActive:    StreamBridge.slotCount > 0 && StreamBridge.hasFile(effectiveSlot)
    // globalVer 在 fileOpened/fileClosed/currentFrameChanged/slotCountChanged 时 ++，
    // 确保同一 slot 打开不同文件、帧切换等场景下 slotInfo/slotFrames/... 也能刷新。
    readonly property string slotName:      slotActive ? StreamBridge.fileName(effectiveSlot) : ""
    readonly property var    slotInfo: {
        const _ = streamView.globalVer  // 强制依赖
        return slotActive ? StreamBridge.streamInfo(effectiveSlot)
                          : ({ width: 0, height: 0, fps: 0,
                               codecLong: "", profile: "", level: 0,
                               bitrate: 0, fileName: "" })
    }
    readonly property int    slotFrames: {
        const _ = streamView.globalVer
        return slotActive ? StreamBridge.frameCount(effectiveSlot) : 0
    }
    readonly property int    slotCurrent: {
        const _ = streamView.globalVer
        return slotActive ? StreamBridge.currentFrame(effectiveSlot) : 0
    }
    // 帧序模式（仅影响 POC 展示口径）：0=显示顺序 1=编码顺序（POC 按 GOP 重排）
    property int orderMode: 1   // 默认编码顺序
    // 模式变化计数：驱动模式感知绑定刷新
    property int orderVer: 0
    // 编码序映射是否就绪（后台解码建立）；未就绪时开关禁用、保持显示顺序
    readonly property bool orderMapReady: {
        const _ = streamView.globalVer
        const __ = streamView.orderVer
        return slotActive ? StreamBridge.frameOrderMapReady(effectiveSlot) : false
    }
    // ── 帧结构缓存（2026-09-16 性能修复，文件级）──
    // 265 播放卡顿主因：globalVer 每帧 ++ → slotFrameList 绑定重求值 →
    // StreamBridge.frameList() 全量重拷（QVariantList，万帧级列表）→ GOP 条/
    // 层级面板等 5 处消费点同步堆积。改为：帧列表只在文件打开/关闭/槽位变化
    // 时重取一次并缓存（fileVer 驱动），播放每帧零重拷。
    property int fileVer: 0
    property var slotFrameCache: []
    property var slotGopCache: []
    onFileVerChanged: {
        slotFrameCache = slotActive ? StreamBridge.frameList(effectiveSlot) : []
        slotGopCache   = slotActive ? StreamBridge.gopList(effectiveSlot) : []
    }
    onEffectiveSlotChanged: {
        fileVer++
        streamView.resetViewZoom()
    }
    Connections {
        target: StreamBridge
        function onFileOpened(openedSlot)  { streamView.fileVer++ }
        function onFileClosed(closedSlot)  { streamView.fileVer++; streamView.resetViewZoom() }
        function onSlotCountChanged()      { streamView.fileVer++; streamView.resetViewZoom() }
    }

    readonly property var    slotFrameList: {
        const _ = streamView.orderVer
        return slotFrameCache
    }
    readonly property var    slotGopList: slotGopCache
    readonly property var    slotBlocks: {
        const _ = streamView.globalVer
        const __ = streamView.orderVer
        // 解码器按输出序（显示序）解码，编码顺序模式下必须换算，
        // 否则画面按播放序渲染，与层级图的编码序不一致。
        return slotActive ? StreamBridge.blockInfoAt(effectiveSlot, decodeIndex) : []
    }
    // 当前帧对应的「解码器输出序索引」（编码顺序模式下由 C++ 侧映射换算）
    readonly property int    decodeIndex: {
        const _ = streamView.globalVer
        const __ = streamView.orderVer
        return slotActive ? StreamBridge.decodeIndexOf(effectiveSlot, slotCurrent) : 0
    }
    readonly property bool   blockSupported: slotBlocks && slotBlocks.length > 0
    // 画面是否已成功解码可显示：与块信息完全解耦。
    // 由 frameUnderlay.onStatusChanged 维护，Ready 时置 true。
    // 画面数据（YUV/RGB）始终随帧解码产出，即使该帧块信息为空（如 B 帧首帧
    // side data 缺失）画面也应正常显示，不受 blockSupported 连坐。
    property bool frameHasImage: false
    property bool qpOverlayEnabled: true   // 默认开块信息

    // ── 播放窗口缩放（画面 + CU 网格同一层，保证对齐）──────────────
    // viewZoom=1 / pan=0 为适应窗口；滚轮对着指针缩放，双击或「复位」恢复。
    property real viewZoom: 1.0
    property real viewPanX: 0
    property real viewPanY: 0
    readonly property real viewZoomMin: 0.25
    readonly property real viewZoomMax: 16.0
    readonly property bool viewZoomed: Math.abs(viewZoom - 1.0) > 0.001
    property real _zoomWheelAccum: 0

    function resetViewZoom() {
        viewZoom = 1.0
        viewPanX = 0
        viewPanY = 0
        _zoomWheelAccum = 0
    }
    function clampViewPan() {
        if (!viewZoomed) {
            viewPanX = 0
            viewPanY = 0
            return
        }
        const vw = viewport.width
        const vh = viewport.height
        if (vw <= 0 || vh <= 0) return
        const zw = vw * viewZoom
        const zh = vh * viewZoom
        // 小于窗口：居中，避免缩到角落。大于窗口：夹紧使画面仍有重叠。
        if (zw <= vw) viewPanX = (vw - zw) / 2
        else viewPanX = Math.min(0, Math.max(vw - zw, viewPanX))
        if (zh <= vh) viewPanY = (vh - zh) / 2
        else viewPanY = Math.min(0, Math.max(vh - zh, viewPanY))
    }
    // cx/cy：viewport 本地坐标。缩放后让该点仍停在指针下。
    function zoomViewAt(factor, cx, cy) {
        const oldZ = viewZoom
        const newZ = Math.max(viewZoomMin, Math.min(viewZoomMax, oldZ * factor))
        if (Math.abs(newZ - oldZ) < 1e-6) return
        const r = newZ / oldZ
        viewPanX = cx - r * (cx - viewPanX)
        viewPanY = cy - r * (cy - viewPanY)
        viewZoom = newZ
        if (!viewZoomed)
            resetViewZoom()
        else
            clampViewPan()
    }
    // P1：块级精度描述（如"宏块级 (16×16)"），由 C++ 侧 blockGranularity 提供
    readonly property string blockGranularityText: {
        const _ = streamView.globalVer
        return slotActive ? StreamBridge.blockGranularity(effectiveSlot) : ""
    }
    // P1：当前帧的块级统计（{ valid, avgQp, minQp, maxQp, blockCount, width, height }）
    // 底层原始画面版本号：C++ 端解码出新画面后递增，用于刷新 Image source。
    // 注意：必须依赖 globalVer（帧切换），否则翻帧时不会重新取图。
    readonly property int    frameImageVersion: {
        const _ = streamView.globalVer
        const __ = streamView.imgVer
        return slotActive ? StreamBridge.frameImageVersion(effectiveSlot) : 0
    }
    // frameImageChanged 信号计数：仅用于打断 QML 绑定缓存
    property int imgVer: 0
    Connections {
        target: StreamBridge
        function onFrameImageChanged(slot) {
            if (slot === streamView.effectiveSlot) {
                streamView.imgVer++
                frameUnderlay.refreshKey++
            }
        }
    }
    readonly property var    slotBlockStats: {
        const _ = streamView.globalVer
        return slotActive ? StreamBridge.blockStats(effectiveSlot, slotCurrent)
                          : ({ valid: false, avgQp: 0, minQp: 0, maxQp: 0, blockCount: 0 })
    }
    // 当前 hover 块（驱动跟随卡片）；钉住块只在点击时写，给右侧「块」页用
    property int selectedBlockIndex: -1
    property var pinnedBlock: null
    function pinBlock(idx) {
        const blocks = streamView.slotBlocks
        if (idx < 0 || !blocks || idx >= blocks.length) {
            streamView.pinnedBlock = null
            return
        }
        if (streamView.pinnedBlock
                && streamView.pinnedBlock.x === blocks[idx].x
                && streamView.pinnedBlock.y === blocks[idx].y
                && streamView.pinnedBlock.w === blocks[idx].w
                && streamView.pinnedBlock.h === blocks[idx].h) {
            streamView.pinnedBlock = null
            return
        }
        streamView.pinnedBlock = blocks[idx]
    }


    // 全局版本号：任意 slot 的帧变化/打开/关闭都 ++，驱动底部总控栏的"▶/⏸"图标等
    property int globalVer: 0
    Connections {
        target: StreamBridge
        function onCurrentFrameChanged(changedSlot) { streamView.globalVer++ }
        function onFileOpened(openedSlot)            { streamView.stopPlay(); streamView.globalVer++ }
        function onFileClosed(closedSlot)            { streamView.stopPlay(); streamView.globalVer++ }
        function onSlotCountChanged()                { streamView.stopPlay(); streamView.globalVer++ }
        // 编码顺序切换：刷新模式感知绑定（POC 展示口径）。
        // 不比较 changedSlot === effectiveSlot：fileOpened 的处理链里
        // effectiveSlot 可能尚未切换到新 slot（绑定重算滞后一拍），
        // 若做过滤，openFile 恢复的勾选状态会被丢弃 → 开关显示 ON
        // 但 orderMode 仍是 0（「要重新勾一次才生效」的根因之一）。
        // frameOrderMode(slot) 每槽独立存储，多 slot 下其它槽的信号
        // 只会把 orderMode 重设为当前槽的真实值，无副作用。
        function onFrameOrderModeChanged(changedSlot) {
            streamView.orderMode = StreamBridge.frameOrderMode(streamView.effectiveSlot)
            streamView.orderVer++
        }
        // 映射就绪：刷新帧列表（POC 换成真实值）并放开切换。
        // 同上不做 changedSlot 过滤：openFile 后映射就绪时 effectiveSlot
        // 绑定可能尚未指向新 slot，过滤会丢弃这次刷新 → 恢复的勾选
        // 状态下帧列表 POC 未按编码序重排。
        function onFrameOrderMapReadyChanged(changedSlot) {
            streamView.orderVer++
            if (streamView.orderMode === 1 && streamView.orderMapReady)
                streamView.setOrderMode(1)
        }
    }
    // 切换 POC 展示口径（显示顺序 / 编码顺序），仅改展示，不动播放与解码
    function setOrderMode(m) {
        if (!slotActive) return
        if (m === 1 && !orderMapReady) return     // 映射未就绪：不切到编码序
        StreamBridge.setFrameOrderMode(effectiveSlot, m)
        orderMode = m
        orderVer++
    }
    // 当前是否有 slot 正在播放（P1：由 QML 侧逐帧定时器驱动的真实播放）
    property bool playing: false

    // 逐帧播放定时器：按码流帧率请求下一帧；解码在 Worker 线程，
    // 上一帧未完成时 StreamBridge 会自动丢弃本拍 → 播放可变慢但绝不卡死。
    Timer {
        id: playTimer
        interval: streamView.playInterval()
        repeat: true
        running: streamView.playing
        onTriggered: streamView.playStep()
    }
    // 帧率 → 定时器间隔（ms）；帧率无效时兜底 40ms（25fps）
    function playInterval() {
        if (!streamView.slotActive) return 40
        const f = Number(streamView.slotInfo.fps)
        return (f > 0 && f < 240) ? Math.max(1, Math.round(1000 / f)) : 40
    }
    function togglePlay() {
        if (!streamView.slotActive) return
        // 已停在末尾：本意是"从头重播"，先 seek 到第 0 帧再开始播放
        if (streamView.atEnd && !streamView.playing) {
            streamView.atEnd = false
            StreamBridge.gotoFrame(streamView.effectiveSlot, 0)
        }
        streamView.playing = !streamView.playing
    }
    function stopPlay() {
        if (streamView.playing) {
            streamView.playing = false
            streamView.globalVer++
        }
    }
    function resetToStart() {
        if (!streamView.slotActive) return
        streamView.atEnd = false
        streamView.stopPlay()
        StreamBridge.firstFrame(streamView.effectiveSlot)
    }
    // 是否已停在末尾（播完最后一帧后置 true；按空格时据此决定从头播）
    property bool atEnd: false

    function playStep() {
        if (!streamView.slotActive) { streamView.playing = false; return }
        const cur = streamView.slotCurrent
        if (cur >= streamView.slotFrames - 1) {
            // 已到最后一帧：暂停并标记末尾（等待用户按空格才从头重播）
            streamView.playing = false
            streamView.atEnd = true
            return
        }
        // 异步：忙时由 StreamBridge 丢弃本拍，主线程不阻塞。
        //
        // 传【UI 帧号】cur+1，由 C++ 侧 requestPlayStep 内部换算成输出序。
        // 不能传 decodeIndex+1（那是输出序+1 = 按显示序推进），
        // 也不能在这里换算后回填 —— currentFrame 必须是 UI 帧号，
        // 否则帧号与画面各按一套序走：GOP=4 本该 0,4,2,1,3 实际成 0,1,2,3。
        StreamBridge.requestPlayStep(streamView.effectiveSlot, cur + 1)
    }
    // 单帧步进（供 ←/→ 快捷键与按钮共用）：先停播放，再 seek 到相邻帧。
    // 节流：4K VVC 单帧解码+取块是同步的（blockInfoAt 随 slotCurrent 变化即触发），
    // 连按方向键会高频堆积同步解码把主线程堵死（表现为"卡"）。
    // 这里只累加目标帧号并延迟合并执行，连按时只解最终那一帧。
    property int  _stepTarget: -1
    property bool _stepScheduled: false
    Timer {
        id: stepThrottle
        interval: 120          // 合并窗口：连按只解最后一次目标
        repeat: false
        onTriggered: {
            streamView._stepScheduled = false
            if (streamView._stepTarget < 0) return
            const t = streamView._stepTarget
            streamView._stepTarget = -1
            // 异步跳帧：解码在 Worker 线程，忙时自动合并最新目标，
            // 主线程零同步解码（4K VVC 大跳不再冻结 UI）。
            StreamBridge.requestGotoAsync(streamView.effectiveSlot, t)
        }
    }
    function stepFrame(delta) {
        if (!streamView.slotActive) return
        streamView.atEnd = false          // 手动翻帧后不再是"停在末尾"态
        streamView.stopPlay()
        const cur = streamView.slotCurrent
        const n = streamView.slotFrames
        streamView._stepTarget = Math.max(0, Math.min(n - 1, cur + delta))
        if (!streamView._stepScheduled) {
            streamView._stepScheduled = true
            stepThrottle.restart()
        }
    }
    function globalAnyPlaying() {
        const _ = streamView.globalVer
        return streamView.playing
    }

    Rectangle { anchors.fill: parent; color: "#101012" }

    // ═════════════════════════════════════════════════════════════════════
    // SETUP 阶段（slotCount === 0）
    //   仿 YuvSetupView 的 setup 视图：让出左侧导航栏后，左边是文件列表区，
    //   右边是当前选中文件的参数预览。
    // ═════════════════════════════════════════════════════════════════════
    Item {
        id: streamSetupView
        anchors.fill: parent
        visible: StreamBridge.slotCount === 0

        // sortMenu 定义（id 供卡片头部排序按钮引用，Menu 本身是 popup 不需要可见父级）
        Menu {
            id: sortMenu
            width: 160

            background: Rectangle {
                implicitWidth: 160
                implicitHeight: 32
                color: "#cc1a1a1f"
                border.color: "#33ffffff"
                border.width: 1
                radius: 6
            }
            topPadding: 6; bottomPadding: 6
            leftPadding: 4; rightPadding: 4
            spacing: 0

            MenuItem {
                text: "默认（添加顺序）"
                height: 28
                onTriggered: streamView._sortFiles("default")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "default" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
            MenuSeparator { height: 1; topPadding: 4; bottomPadding: 4
                contentItem: Rectangle { color: "#33ffffff"; implicitHeight: 1 }
                background: Rectangle { color: "transparent" }
            }
            MenuItem {
                text: "名称 ↑ (A→Z)"
                height: 28
                onTriggered: streamView._sortFiles("name_asc")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "name_asc" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
            MenuItem {
                text: "名称 ↓ (Z→A)"
                height: 28
                onTriggered: streamView._sortFiles("name_desc")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "name_desc" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
            MenuSeparator { height: 1; topPadding: 4; bottomPadding: 4
                contentItem: Rectangle { color: "#33ffffff"; implicitHeight: 1 }
                background: Rectangle { color: "transparent" }
            }
            MenuItem {
                text: "大小 ↓ (大→小)"
                height: 28
                onTriggered: streamView._sortFiles("size_desc")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "size_desc" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
            MenuItem {
                text: "大小 ↑ (小→大)"
                height: 28
                onTriggered: streamView._sortFiles("size_asc")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "size_asc" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
            MenuSeparator { height: 1; topPadding: 4; bottomPadding: 4
                contentItem: Rectangle { color: "#33ffffff"; implicitHeight: 1 }
                background: Rectangle { color: "transparent" }
            }
            MenuItem {
                text: "分辨率 ↓ (高→低)"
                height: 28
                onTriggered: streamView._sortFiles("resolution_desc")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "resolution_desc" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
            MenuItem {
                text: "分辨率 ↑ (低→高)"
                height: 28
                onTriggered: streamView._sortFiles("resolution_asc")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "resolution_asc" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
            MenuSeparator { height: 1; topPadding: 4; bottomPadding: 4
                contentItem: Rectangle { color: "#33ffffff"; implicitHeight: 1 }
                background: Rectangle { color: "transparent" }
            }
            MenuItem {
                text: "时长 ↓ (长→短)"
                height: 28
                onTriggered: streamView._sortFiles("duration_desc")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "duration_desc" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
            MenuItem {
                text: "时长 ↑ (短→长)"
                height: 28
                onTriggered: streamView._sortFiles("duration_asc")
                contentItem: Text {
                    text: parent.text
                    color: streamView._sortMode === "duration_asc" ? "#3d7adf" : "#e8e8ec"
                    font.pixelSize: 12
                    leftPadding: 12
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#803a3a3d" : "transparent"
                    radius: 4
                }
            }
        }

        // ── 主区：左侧文件列表（含操作按钮头） + 右侧文件信息面板 ──
        RowLayout {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 24
            anchors.bottomMargin: 24
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            spacing: 16

            // 左：文件列表卡片（占大部分宽度）
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: 400
                radius: 10
                color: streamView._dragHovering ? "#1a1a22" : "#16161b"
                border.color: streamView._dragHovering ? "#3a78c8" : "#2a2e33"
                border.width: streamView._dragHovering ? 2 : 1
                Behavior on border.color { ColorAnimation { duration: 120 } }
                Behavior on color { ColorAnimation { duration: 120 } }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 0
                    spacing: 0

                    // ── 卡片头部操作栏：左侧（开始分析 + 导出码流）| 右侧（排序+添加+文件夹+清空） ──
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 44
                        Layout.leftMargin: 12
                        Layout.rightMargin: 8
                        spacing: 8

                        // 左侧：开始分析 + 导出码流
                        Rectangle {
                            width: 100; height: 28; radius: 6
                            color: startHeadMa.containsMouse ? "#3d7adf" : "#2a5fc0"
                            Text {
                                anchors.centerIn: parent
                                text: "开始分析"
                                color: "#fff"; font.pixelSize: 12; font.bold: true
                            }
                            MouseArea {
                                id: startHeadMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: streamView._startAnalysis()
                            }
                        }
                        Rectangle {
                            width: 100; height: 28; radius: 6
                            color: exportRawHeadMa.containsMouse ? "#2a2a34" : "#1e1e24"
                            border.color: exportRawHeadMa.containsMouse ? "#4a4a56" : "#3a3a44"
                            border.width: 1
                            enabled: streamView._selectedCount() > 0
                            opacity: streamView._selectedCount() > 0 ? 1.0 : 0.5
                            Text {
                                anchors.centerIn: parent
                                text: "导出码流"
                                color: "#cccccc"; font.pixelSize: 12
                            }
                            MouseArea {
                                id: exportRawHeadMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: streamView._exportRawBitstream()
                            }
                            ToolTip.visible: exportRawHeadMa.containsMouse
                            ToolTip.text: streamView._selectedCount() > 0
                                          ? ("导出裸码流（已选 " + streamView._selectedCount() + " 个）")
                                          : "请先选择文件"
                            ToolTip.delay: 200
                        }
                        // 已选计数
                        Text {
                            visible: streamView._selectedCount() > 0
                            text: "已选 " + streamView._selectedCount() + " 个"
                            color: "#6a6f76"; font.pixelSize: 11
                        }

                        Item { Layout.fillWidth: true }

                        // 右侧：排序 + 添加 + 文件夹 + 清空
                        StreamFlatButton {
                            text: streamView._sortLabel() + " ▾"
                            enabled: streamView.pendingFiles.length > 0
                            onClicked: sortMenu.open()
                        }
                        StreamFlatButton {
                            text: "+ 添加"
                            onClicked: streamView._openFile()
                        }
                        StreamFlatButton {
                            text: "+ 文件夹"
                            onClicked: streamView._openFolder()
                        }
                        StreamFlatButton {
                            text: "清空"
                            bgNormal: "#807a2e2e"
                            bgHover:  "#809c3c3c"
                            bgDown:   "#80b84848"
                            textColor: "#f5c6c6"
                            enabled: streamView.pendingFiles.length > 0
                            onClicked: {
                                streamView.pendingFiles = []
                                streamView.pendingSelectedIndex = -1
                                streamView.pendingStatus = ""
                                streamView._selectedFiles = ({})
                                streamView._selectAllChecked = false
                                streamView._anchorIndex = -1
                            }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#2a2e33" }

                ListView {
                    id: fileListView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 8
                    clip: true
                    model: streamView.pendingFiles
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        required property int index
                        required property string modelData
                        width: ListView.view.width
                        height: 36
                        radius: 3
                        color: streamView._selectedFiles[modelData]
                               ? "#2a3a55" : (rowMa.containsMouse ? "#1e1e24" : "transparent")
                        border.color: streamView._selectedFiles[modelData] ? "#3a78c8" : "transparent"
                        border.width: 1
                        RowLayout {
                            z: 1  // 置于 rowMa 之上，使删除按钮可点击
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 10
                            spacing: 10
                            Text {
                                text: String.fromCharCode(0x2460 + index)  // ① ② ③ ...
                                color: "#9aa0a6"; font.pixelSize: 12
                                Layout.preferredWidth: 20
                            }
                            Text {
                                text: streamView._fileBasename(modelData)
                                color: "#e8e8ec"; font.pixelSize: 13
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                            }
                            Text {
                                text: streamView._fileDir(modelData)
                                color: "#6a6f76"; font.pixelSize: 10
                                Layout.maximumWidth: 200
                                elide: Text.ElideLeft
                            }
                            Text {
                                // 文件大小（从 probeCache 取，无缓存时显示 —）
                                text: {
                                    var info = streamView._probeCache[modelData]
                                    if (info && info.fileSize > 0)
                                        return streamView._formatFileSize(info.fileSize)
                                    return "—"
                                }
                                color: "#6a6f76"; font.pixelSize: 10
                                Layout.preferredWidth: 64
                                horizontalAlignment: Text.AlignRight
                            }
                            Text {
                                // 修改时间（从 probeCache 取，无缓存时显示 —）
                                text: {
                                    var info = streamView._probeCache[modelData]
                                    if (info && info.fileModified)
                                        return info.fileModified
                                    return "—"
                                }
                                color: "#6a6f76"; font.pixelSize: 10
                                Layout.preferredWidth: 140
                            }
                            // 跳转到所在文件夹按钮
                            Rectangle {
                                Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                radius: 3
                                color: revealFileMa.containsMouse ? "#803a3a44" : "transparent"
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 14; height: 14
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.reset()
                                        ctx.strokeStyle = revealFileMa.containsMouse ? "#e8e8ec" : "#9aa0a6"
                                        ctx.lineWidth = 1.3
                                        ctx.fillStyle = "transparent"
                                        // 文件夹主体
                                        ctx.beginPath()
                                        ctx.moveTo(1, 4)
                                        ctx.lineTo(5, 4)
                                        ctx.lineTo(6.5, 5.5)
                                        ctx.lineTo(13, 5.5)
                                        ctx.lineTo(13, 12)
                                        ctx.lineTo(1, 12)
                                        ctx.closePath()
                                        ctx.stroke()
                                    }
                                }
                                MouseArea {
                                    id: revealFileMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Fs.revealInFileManager(modelData)
                                }
                            }
                            // 删除按钮
                            Rectangle {
                                Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                radius: 3
                                color: delFileMa.containsMouse ? "#80b84848" : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: "×"; color: delFileMa.containsMouse ? "#fff" : "#9aa0a6"
                                    font.pixelSize: 14
                                }
                                MouseArea {
                                    id: delFileMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var arr = streamView.pendingFiles.slice()
                                        const removedPath = arr[index]
                                        arr.splice(index, 1)
                                        streamView.pendingFiles = arr
                                        if (streamView.pendingSelectedIndex >= arr.length)
                                            streamView.pendingSelectedIndex = arr.length - 1
                                        // 清除该文件的缓存探测信息（以路径为键）
                                        if (removedPath && streamView._probeCache[removedPath])
                                            delete streamView._probeCache[removedPath]
                                        // 同步清理选中集合
                                        if (removedPath && streamView._selectedFiles[removedPath]) {
                                            var s = Object.assign({}, streamView._selectedFiles)
                                            delete s[removedPath]
                                            streamView._selectedFiles = s
                                            streamView._selectAllChecked = streamView._isAllSelected()
                                        }
                                        // 删除后自动选中相邻文件
                                        if (streamView.pendingSelectedIndex >= 0)
                                            streamView._onFileSelected(streamView.pendingSelectedIndex)
                                    }
                                }
                            }
                        }
                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: (mouse) => streamView._onFileClicked(index, mouse.modifiers)
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        visible: streamView.pendingFiles.length === 0
                        text: "拖拽视频文件到此处，或点右上「+ 添加」选择视频文件"
                        color: "#6a6f76"; font.pixelSize: 12
                    }
                }
                }  // ColumnLayout 闭合

                // ── 拖拽导入（在 ListView 之后声明，z 序最高，覆盖其上接收事件） ──
                DropArea {
                    id: fileDropArea
                    anchors.fill: parent
                    // 不设 keys：接受所有拖拽类型（Finder 拖文件用 text/uri-list，非 text/plain）

                    onEntered: (drag) => {
                        streamView._dragHovering = true
                        drag.accepted = true
                    }
                    onExited: streamView._dragHovering = false
                    onDropped: (drop) => {
                        streamView._dragHovering = false
                        drop.accepted = true
                        // 优先用 urls（Finder 拖文件的标准通道）
                        var urls = drop.urls || []
                        if (urls.length > 0) {
                            streamView._handleDroppedFiles(urls)
                            return
                        }
                        // 退化：某些场景 drop.text 包含 file:// 路径列表
                        var txt = drop.text || ""
                        if (txt.length > 0) {
                            var lines = txt.split("\n")
                            var paths = []
                            for (var i = 0; i < lines.length; ++i) {
                                var line = lines[i].trim()
                                if (line.length > 0) paths.push(line)
                            }
                            if (paths.length > 0)
                                streamView._handleDroppedFiles(paths)
                        }
                    }
                }
            }

            // 右：文件信息面板（固定宽度 320px）
            Rectangle {
                Layout.preferredWidth: 320
                Layout.fillHeight: true
                radius: 10
                color: "#16161b"
                border.color: "#2a2e33"; border.width: 1

                // 未选中文件时：占位
                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 10
                    visible: streamView.pendingFiles.length === 0
                              || streamView.pendingSelectedIndex < 0
                              || streamView.pendingSelectedIndex >= streamView.pendingFiles.length
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "📋"
                        font.pixelSize: 40
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "点击左侧文件查看信息"
                        color: "#9aa0a6"; font.pixelSize: 12
                    }
                }

                // 已选中文件：显示 probeFile 解析的基本信息
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 0
                    visible: streamView.pendingFiles.length > 0
                              && streamView.pendingSelectedIndex >= 0
                              && streamView.pendingSelectedIndex < streamView.pendingFiles.length

                    // 标题
                    Text {
                        text: "文件信息"
                        color: "#e8e8ec"; font.pixelSize: 14; font.bold: true
                        Layout.bottomMargin: 12
                    }

                    // 文件名
                    Text {
                        text: streamView._probeData.fileName || "—"
                        color: "#cccccc"; font.pixelSize: 12
                        font.family: "Monospace"
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                        Layout.bottomMargin: 4
                    }
                    Text {
                        text: streamView._probeData.filePath || ""
                        color: "#6a6f76"; font.pixelSize: 10
                        elide: Text.ElideLeft
                        Layout.fillWidth: true
                        Layout.bottomMargin: 16
                    }

                    // 分隔线
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 1
                        color: "#2a2e33"
                        Layout.bottomMargin: 12
                    }

                    // 信息行
                    Repeater {
                        model: [
                            // ── 基本编码信息 ──
                            { label: "编码格式", value: streamView._probeData.codecLong || "—" },
                            { label: "封装格式", value: streamView._probeData.formatLong || streamView._probeData.format || "—" },
                            { label: "Profile",  value: streamView._probeData.profile || "—" },
                            { label: "Level",    value: streamView._probeData.level && streamView._probeData.level !== "0"
                                                ? streamView._probeData.level : "—" },
                            { label: "分辨率",   value: (streamView._probeData.width > 0 && streamView._probeData.height > 0)
                                                ? (streamView._probeData.width + " × " + streamView._probeData.height)
                                                : "—" },
                            { label: "帧率",     value: streamView._probeData.fps > 0
                                                ? (streamView._probeData.fps.toFixed(2) + " fps")
                                                : "—" },
                            { label: "总帧数",   value: streamView._probeData.frameCount > 0
                                                ? streamView._probeData.frameCount : "—" },
                            { label: "时长",     value: streamView._probeData.duration > 0
                                                ? (streamView._formatDuration(streamView._probeData.duration))
                                                : "—" },
                            { label: "码率",     value: streamView._probeData.bitrate > 0
                                                ? (streamView._formatBitrate(streamView._probeData.bitrate))
                                                : "—" },
                            // ── 像素与色彩 ──
                            { label: "像素格式", value: streamView._probeData.pixFmt || "—" },
                            { label: "位深",     value: streamView._probeData.bitsPerRawSample || "—" },
                            { label: "色彩空间", value: streamView._probeData.colorSpace || "—" },
                            { label: "色彩范围", value: streamView._probeData.colorRange || "—" },
                            { label: "色彩原色", value: streamView._probeData.colorPrimaries || "—" },
                            { label: "传输特性", value: streamView._probeData.colorTransfer || "—" },
                            { label: "色度位置", value: streamView._probeData.chromaLocation || "—" },
                            // ── 编码特征 ──
                            { label: "场序",     value: streamView._probeData.fieldOrder || "—" },
                            { label: "B帧延迟",  value: streamView._probeData.hasBFrames !== undefined
                                                ? streamView._probeData.hasBFrames : "—" },
                            { label: "参考帧数", value: streamView._probeData.refs || "—" },
                            // ── 文件信息 ──
                            { label: "文件大小", value: streamView._probeData.fileSize > 0
                                                ? (streamView._formatFileSize(streamView._probeData.fileSize))
                                                : "—" },
                            { label: "修改时间", value: streamView._probeData.fileModified || "—" },
                            { label: "封装类型", value: streamView._probeData.isAvc !== undefined
                                                ? (streamView._probeData.isAvc ? "AVCC" : "Annex-B")
                                                : "—" }
                        ]
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 24
                            spacing: 8
                            Text {
                                text: modelData.label
                                color: "#9aa0a6"; font.pixelSize: 11
                                Layout.preferredWidth: 70
                            }
                            Text {
                                text: modelData.value
                                color: "#e8e8ec"; font.pixelSize: 12
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                    }

                    // 探测中提示
                    Text {
                        visible: streamView._probing
                        text: "正在解析…"
                        color: "#6a6f76"; font.pixelSize: 11
                        Layout.topMargin: 12
                    }

                    Item { Layout.fillHeight: true }

                    // 状态文本（错误提示等）
                    Text {
                        text: streamView.pendingStatus
                        color: "#e05050"; font.pixelSize: 11
                        visible: streamView.pendingStatus.length > 0
                        Layout.bottomMargin: 8
                    }

                    // 导出状态文本
                    Text {
                        text: streamView._exportStatus
                        color: "#6a6f76"; font.pixelSize: 11
                        visible: streamView._exportStatus.length > 0
                        Layout.topMargin: 4
                        Layout.bottomMargin: 4
                    }
                }
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // RENDER 阶段（slotCount > 0）—— 沉浸满屏
    //   顶部流信息条 / 中部主显示区 / 底部全局总控栏
    // ═════════════════════════════════════════════════════════════════════
    Item {
        id: streamRenderView
        anchors.fill: parent
        visible: StreamBridge.slotCount > 0

        // ── 中部：主显示区（CU 网格 + QP 着色，P1 真实渲染） ──
        // 挤占模式时底部上移让位给码率/层级面板；悬浮模式或未展开时贴底栏。
        Item {
            id: mainDisplay
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: bottomBar.top
            anchors.bottomMargin: {
                let h = 0
                if (streamView.hierarchyChartOpen && !streamView.hierarchyChartFloating)
                    h = Math.max(h, streamView.hierarchyChartH)
                if (streamView.bitrateChartOpen && !streamView.bitrateChartFloating)
                    h = Math.max(h, streamView.bitrateChartH)
                return h
            }

            Rectangle { anchors.fill: parent; color: "#0a0a0e" }

            // 未加载码流时的占位
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 8
                visible: !streamView.slotActive
                Text { Layout.alignment: Qt.AlignHCenter; text: "🎞"; font.pixelSize: 56 }
                Text { Layout.alignment: Qt.AlignHCenter
                    text: "未加载码流文件"
                    color: "#e8e8ec"; font.pixelSize: 16; font.bold: true }
            }

            // 已加载：块级 CU 网格 + QP 着色叠加层
            // ★ 仅当"既无画面又无块信息"时才显示占位提示，避免有画面的帧
            //   （块信息为空，如 B 帧首帧）被提示文字盖住而看不到画面。
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 10
                visible: streamView.slotActive && !streamView.blockSupported
                         && !streamView.frameHasImage
                Text { Layout.alignment: Qt.AlignHCenter; text: "🎞"; font.pixelSize: 56 }
                Text { Layout.alignment: Qt.AlignHCenter
                    text: "帧级信息已加载"
                    color: "#e8e8ec"; font.pixelSize: 16; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter
                    text: streamView.blockGranularityText.length > 0
                          ? "当前帧块级数据暂不可用（" + streamView.blockGranularityText + "）"
                          : "当前编码格式暂不支持块级分析（P1 支持 H.264 / HEVC）"
                    color: "#9aa0a6"; font.pixelSize: 12 }
            }

            // ── 视口：画面 + CU 网格同一层缩放（滚轮 / 拖拽平移 / 双击复位）──
            // clip 避免放大后盖住 GOP 栏；zoomLayer 用 TopLeft + pan，网格与画面同步。
            Item {
                id: viewport
                anchors.fill: parent
                anchors.margins: 12
                clip: true
                visible: streamView.slotActive
                onWidthChanged: streamView.clampViewPan()
                onHeightChanged: streamView.clampViewPan()

                Item {
                    id: zoomLayer
                    width: parent.width
                    height: parent.height
                    x: streamView.viewPanX
                    y: streamView.viewPanY
                    scale: streamView.viewZoom
                    transformOrigin: Item.TopLeft

                    // ── 前一帧保持层（消除播放闪屏）──
                    // frameUnderlay 用 cache:false + asynchronous:true 且 URL 每帧变化，
                    // 重载期间 status != Ready 会露出空白底 → 4K 下肉眼可见闪屏。
                    // 本层始终保留"上一张已加载完成的图"，新图 Ready 前遮住空白。
                    Image {
                        id: prevUnderlay
                        anchors.fill: parent
                        visible: streamView.slotActive
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        cache: true
                        source: ""
                        z: frameUnderlay.z + 1
                    }

                    // ── 底层：当前帧真实解码画面（CU 网格叠加在它上面）──
                    Image {
                        id: frameUnderlay
                        anchors.fill: parent
                        visible: streamView.slotActive
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        cache: false
                        source: "image://streamframe/" + streamView.effectiveSlot
                                + "_" + streamView.slotCurrent
                                + "_" + streamView.frameImageVersion
                                + "_" + frameUnderlay.refreshKey
                        property int refreshKey: 0
                        onStatusChanged: {
                            streamView.frameHasImage = (status === Image.Ready)
                            prevUnderlay.visible = (status !== Image.Ready)
                                                   && streamView.slotActive
                            if (status === Image.Ready) {
                                prevUnderlay.source = frameUnderlay.source
                                blockCanvas.requestPaint()
                            }
                        }
                    }

            // ── CU 网格 + QP 着色画布 ──
            // 透明底：只画网格线 / QP 半透明色块 / 选中高亮，
            // 真实画面由下方 frameUnderlay 提供。
            Canvas {
                id: blockCanvas
                anchors.fill: parent
                visible: streamView.slotActive && streamView.blockSupported

                // 悬停高亮的块索引（-1 表示无）
                property int hoverIndex: -1
                // 点击选中的块索引（-1 表示无）
                property int selectedIndex: -1

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    const blocks = streamView.slotBlocks
                    if (!blocks || blocks.length === 0) return

                    // 计算等比缩放：适应画布，保持宽高比
                    let vw = 0, vh = 0
                    for (let i = 0; i < blocks.length; ++i) {
                        vw = Math.max(vw, blocks[i].x + blocks[i].w)
                        vh = Math.max(vh, blocks[i].y + blocks[i].h)
                    }
                    const info = streamView.slotInfo
                    if (info.width > 0)  vw = info.width
                    if (info.height > 0) vh = info.height
                    if (vw <= 0 || vh <= 0) return

                    // 等比缩放：必须与底层 frameUnderlay 的 PreserveAspectFit
                    // 完全一致，否则 CU 网格会和真实画面错位。
                    // 优先直接采用 Image 计算出的实际绘制矩形。
                    let offX = 0, offY = 0, drawW = width, drawH = height
                    const pw = frameUnderlay.paintedWidth
                    const ph = frameUnderlay.paintedHeight
                    if (frameUnderlay.visible && pw > 0 && ph > 0) {
                        // Image 在 PreserveAspectFit 下把画面居中绘制
                        drawW = pw
                        drawH = ph
                        offX = (width  - pw) / 2
                        offY = (height - ph) / 2
                    } else {
                        // 无底层画面时退化为自适应缩放（保持原有行为）
                        const sw = Math.min(width / vw, height / vh)
                        drawW = vw * sw
                        drawH = vh * sw
                        offX = (width  - drawW) / 2
                        offY = (height - drawH) / 2
                    }
                    // ★ 修复：X / Y 独立缩放。
                    // 画布宽高比与视频不一致时 pw/vw ≠ ph/vh，若只取 X 方向的
                    // 单一 scale 去缩放 Y，垂直方向就会整体错位（网格与画面对不齐、
                    // 甚至缺垂直边界）。改为分别按 X / Y 计算。
                    const scale  = drawW / vw
                    const scaleY = drawH / vh

                    // ── CU 网格线（只画白色线条，不填充色块）──
                    // 用户需求：不要蓝色底，划分仅用白色线条，且白线更亮。
                    if (streamView.qpOverlayEnabled) {
                        ctx.lineWidth = 1
                        ctx.strokeStyle = "rgba(255,255,255,0.95)"
                        for (let i = 0; i < blocks.length; ++i) {
                            const b = blocks[i]
                            ctx.strokeRect(offX + b.x * scale, offY + b.y * scaleY,
                                           b.w * scale, b.h * scaleY)
                        }
                    }

                    // ── 悬停 / 选中高亮（黄色描边）──
                    const hi = blockCanvas.hoverIndex
                    const si = blockCanvas.selectedIndex
                    const drawHi = (idx, lw) => {
                        if (idx < 0 || idx >= blocks.length) return
                        const b = blocks[idx]
                        ctx.strokeStyle = "#f0c040"
                        ctx.lineWidth = lw
                        ctx.strokeRect(offX + b.x * scale, offY + b.y * scaleY,
                                       b.w * scale, b.h * scaleY)
                    }
                    if (streamView.qpOverlayEnabled) {
                        drawHi(hi, 1.5)
                        drawHi(si, 2)
                    }

                    // 记录映射参数供命中测试复用
                    blockCanvas._scale = scale
                    blockCanvas._scaleY = scaleY
                    blockCanvas._offX  = offX
                    blockCanvas._offY  = offY
                    blockCanvas._vw    = vw
                    blockCanvas._vh    = vh
                }

                property real _scale: 1
                property real _scaleY: 1
                property real _offX: 0
                property real _offY: 0
                property int  _vw: 0
                property int  _vh: 0

                // 帧切换 / QP 开关切换 / 块数据变化时重绘，并复位选中态
                onVisibleChanged: requestPaint()
                Connections {
                    target: streamView
                    function onSlotBlocksChanged()       { blockCanvas.requestPaint() }
                    function onQpOverlayEnabledChanged() { blockCanvas.requestPaint() }
                    function onSlotCurrentChanged() {
                        blockCanvas.selectedIndex = -1
                        streamView.selectedBlockIndex = -1
                        streamView.pinnedBlock = null
                        blockCanvas.requestPaint()
                    }
                    function onPinnedBlockChanged() { blockCanvas.requestPaint() }
                }

                // 命中测试：屏幕坐标 → 块索引
                function hitTest(mx, my) {
                    const blocks = streamView.slotBlocks
                    if (!blocks || blocks.length === 0) return -1
                    const vx = (mx - blockCanvas._offX) / blockCanvas._scale
                    const vy = (my - blockCanvas._offY) / blockCanvas._scaleY
                    for (let i = 0; i < blocks.length; ++i) {
                        const b = blocks[i]
                        if (vx >= b.x && vx < b.x + b.w &&
                            vy >= b.y && vy < b.y + b.h)
                            return i
                    }
                    return -1
                }

                }
                } // zoomLayer

                // 交互层：坐标在 viewport，命中时换算到 zoomLayer 本地（与 Canvas 一致）
                MouseArea {
                    id: viewInput
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    preventStealing: true
                    cursorShape: streamView.viewZoom > 1
                                 ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                                 : Qt.ArrowCursor

                    property real _lastX: 0
                    property real _lastY: 0
                    property bool _panning: false
                    property bool _dragged: false

                    function mapToLayer(mx, my) {
                        const z = Math.max(streamView.viewZoom, 1e-6)
                        return Qt.point((mx - streamView.viewPanX) / z,
                                        (my - streamView.viewPanY) / z)
                    }
                    function hoverAt(mx, my) {
                        const p = mapToLayer(mx, my)
                        const idx = blockCanvas.hitTest(p.x, p.y)
                        if (idx !== blockCanvas.hoverIndex) {
                            blockCanvas.hoverIndex = idx
                            blockCanvas.requestPaint()
                        }
                        if (streamView.qpOverlayEnabled)
                            streamView.selectedBlockIndex = idx
                    }

                    onPressed: function(mouse) {
                        streamView.forceActiveFocus()
                        _dragged = false
                        _lastX = mouse.x
                        _lastY = mouse.y
                        if (streamView.viewZoom > 1)
                            _panning = true
                    }
                    onPositionChanged: function(mouse) {
                        if (pressed && (Math.abs(mouse.x - _lastX) > 3
                                        || Math.abs(mouse.y - _lastY) > 3))
                            _dragged = true
                        if (_panning && pressed) {
                            streamView.viewPanX += mouse.x - _lastX
                            streamView.viewPanY += mouse.y - _lastY
                            _lastX = mouse.x
                            _lastY = mouse.y
                            streamView.clampViewPan()
                        } else {
                            hoverAt(mouse.x, mouse.y)
                        }
                    }
                    onReleased: function(mouse) {
                        _panning = false
                        if (!_dragged && mouse.button === Qt.LeftButton) {
                            const p = mapToLayer(mouse.x, mouse.y)
                            const idx = blockCanvas.hitTest(p.x, p.y)
                            streamView.pinBlock(idx)
                            blockCanvas.selectedIndex = (streamView.pinnedBlock && idx >= 0) ? idx : -1
                            blockCanvas.requestPaint()
                        }
                    }
                    onExited: {
                        _panning = false
                        if (blockCanvas.hoverIndex !== -1) {
                            blockCanvas.hoverIndex = -1
                            blockCanvas.requestPaint()
                        }
                        streamView.selectedBlockIndex = -1
                    }
                    onDoubleClicked: streamView.resetViewZoom()
                    onWheel: function(wheel) {
                        streamView._zoomWheelAccum += wheel.angleDelta.y
                        let dir = 0
                        if (streamView._zoomWheelAccum >= 120) {
                            dir = 1
                            streamView._zoomWheelAccum -= 120
                        } else if (streamView._zoomWheelAccum <= -120) {
                            dir = -1
                            streamView._zoomWheelAccum += 120
                        }
                        if (dir !== 0)
                            streamView.zoomViewAt(dir > 0 ? 1.15 : (1 / 1.15),
                                                  wheel.x, wheel.y)
                        wheel.accepted = true
                    }
                }

                // 放大后显示倍率，点击复位
                Rectangle {
                    visible: streamView.viewZoomed
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 8
                    width: zoomBadgeRow.implicitWidth + 16
                    height: 22
                    radius: 4
                    color: "#cc1a1a1f"
                    border.color: "#2a2e33"
                    border.width: 1
                    z: 5
                    Row {
                        id: zoomBadgeRow
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            text: Math.round(streamView.viewZoom * 100) + "%"
                            color: "#e8e8ec"; font.pixelSize: 10; font.family: "Monospace"
                        }
                        Text {
                            text: "复位"
                            color: zoomBadgeMa.containsMouse ? "#42A5FF" : "#9aa0a6"
                            font.pixelSize: 10
                        }
                    }
                    MouseArea {
                        id: zoomBadgeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: streamView.resetViewZoom()
                    }
                }
            } // viewport

            // ── CU 详情卡片（hover 块时跟随显示，需勾选「块信息」开关）──
            Rectangle {
                id: blockDetailCard
                visible: streamView.qpOverlayEnabled
                         && streamView.selectedBlockIndex >= 0
                         && streamView.selectedBlockIndex < streamView.slotBlocks.length

                // 被选中块在视图中的屏幕矩形（与 hitTest 同一坐标系）
                readonly property var blk: (streamView.selectedBlockIndex >= 0
                                            && streamView.selectedBlockIndex < streamView.slotBlocks.length)
                                           ? streamView.slotBlocks[streamView.selectedBlockIndex] : null
                // 块矩形：zoomLayer 本地 → 乘缩放加平移 → 再加 viewport 在 mainDisplay 的偏移
                readonly property real bx: blk
                    ? (viewport.x + streamView.viewPanX
                       + (blockCanvas._offX + blk.x * blockCanvas._scale) * streamView.viewZoom)
                    : 0
                readonly property real by: blk
                    ? (viewport.y + streamView.viewPanY
                       + (blockCanvas._offY + blk.y * blockCanvas._scaleY) * streamView.viewZoom)
                    : 0
                readonly property real bw: blk ? (blk.w * blockCanvas._scale * streamView.viewZoom) : 0
                readonly property real bh: blk ? (blk.h * blockCanvas._scaleY * streamView.viewZoom) : 0

                width: cardCol.implicitWidth + 16
                height: cardCol.implicitHeight + 16
                radius: 5
                color: "#cc1a1a1f"
                border.color: "#2a2e33"; border.width: 1

                // 容器可用范围（卡片父容器即该矩形区域）
                readonly property real cw: parent.width
                readonly property real ch: parent.height
                readonly property real gap: 8

                // 优先放块右侧，放不下依次尝试左侧、下方、上方，最后夹回容器内
                x: {
                    if (!blk) return 16
                    // 右侧
                    if (bx + bw + gap + width <= cw) return bx + bw + gap
                    // 左侧
                    if (bx - gap - width >= 0) return bx - gap - width
                    // 水平夹紧：尽量水平居中对齐块中心
                    const cx = bx + bw / 2 - width / 2
                    return Math.max(gap, Math.min(cx, cw - width - gap))
                }
                y: {
                    if (!blk) return 16
                    const verticalCenter = by + bh / 2 - height / 2
                    // 左右放置时：垂直与块居中
                    const placedHoriz = (x === bx + bw + gap) || (x === bx - gap - width)
                    if (placedHoriz)
                        return Math.max(gap, Math.min(verticalCenter, ch - height - gap))
                    // 上下放置：优先下方
                    if (by + bh + gap + height <= ch) return by + bh + gap
                    // 上方
                    if (by - gap - height >= 0) return by - gap - height
                    return Math.max(gap, Math.min(verticalCenter, ch - height - gap))
                }

                Column {
                    id: cardCol
                    x: 8; y: 8
                    spacing: 3
                    // 不左右锚满父级：implicitWidth 跟内容走，卡片右侧不再留空。
                    readonly property int labelW: 32
                    readonly property var b: streamView.slotBlocks[streamView.selectedBlockIndex] || ({})

                    // 类型：Skip / Intra / Inter / IBC / Palette。先看 flag，再看 VVC predMode。
                    function predLabel(b) {
                        if (!b) return "—"
                        if (b.isSkip) return "Skip"
                        if (b.isIntra) return "Intra"
                        const pm = Number(b.predMode)
                        if (pm === 3) return "Palette"
                        if (pm === 4) return "IBC"
                        return "Inter"
                    }
                    function refLabel(b) {
                        if (!b || b.isIntra || b.isSkip) return ""
                        const pf = Number(b.predFlag !== undefined ? b.predFlag : 0)
                        if (pf === 3) return "Bi"
                        if (pf === 2) return "L1"
                        if (pf === 1) return "L0"
                        if (b.refIdx === 1) return "L1"
                        if (b.refIdx === 0) return "L0"
                        return ""
                    }
                    function mvLabel(b) {
                        if (!b || b.isIntra || b.isSkip) return ""
                        const x = Number(b.mvx), y = Number(b.mvy)
                        if (!(x === x) || !(y === y)) return ""
                        return "(" + x.toFixed(1) + ", " + y.toFixed(1) + ")"
                    }

                    Text {
                        id: titleLine
                        text: {
                            const b = cardCol.b
                            const x = b.x !== undefined ? b.x : 0
                            const y = b.y !== undefined ? b.y : 0
                            const w = b.w !== undefined ? b.w : 0
                            const h = b.h !== undefined ? b.h : 0
                            return "CU (" + x + ", " + y + ") " + w + "×" + h
                        }
                        color: "#e8e8ec"; font.pixelSize: 11; font.bold: true
                        font.family: "Monospace"
                    }
                    Rectangle {
                        width: Math.max(titleLine.implicitWidth,
                                        depthRow.implicitWidth,
                                        qpRow.implicitWidth,
                                        typeRow.implicitWidth,
                                        mvRow.implicitWidth,
                                        refRow.implicitWidth)
                        height: 1
                        color: "#2a2e33"
                    }

                    // 划分深度（QT）：CTU 128 → 64×64 = depth 1，按 CtbSizeY 语法计算
                    Row {
                        id: depthRow
                        spacing: 6
                        Text { text: "深度"; color: "#9aa0a6"; font.pixelSize: 10; width: cardCol.labelW }
                        Text {
                            text: {
                                const b = cardCol.b
                                if (b.depth === undefined) return "—"
                                const ctu = Number(b.ctuSize)
                                return String(b.depth) + (ctu > 0 ? (" · CTU " + ctu) : "")
                            }
                            color: "#cccccc"; font.pixelSize: 11; font.family: "Monospace"
                        }
                    }
                    Row {
                        id: qpRow
                        spacing: 6
                        Text { text: "QP"; color: "#9aa0a6"; font.pixelSize: 10; width: cardCol.labelW }
                        Text {
                            text: cardCol.b.qp !== undefined ? String(cardCol.b.qp) : "—"
                            color: "#cccccc"; font.pixelSize: 11; font.family: "Monospace"
                        }
                    }
                    Row {
                        id: typeRow
                        spacing: 6
                        Text { text: "类型"; color: "#9aa0a6"; font.pixelSize: 10; width: cardCol.labelW }
                        Text {
                            text: cardCol.predLabel(cardCol.b)
                            color: "#cccccc"; font.pixelSize: 11; font.family: "Monospace"
                        }
                    }
                    // 帧间块才显示 MV / 参考（帧内 / Skip 无意义）
                    Row {
                        id: mvRow
                        visible: cardCol.mvLabel(cardCol.b).length > 0
                        spacing: 6
                        Text { text: "MV"; color: "#9aa0a6"; font.pixelSize: 10; width: cardCol.labelW }
                        Text {
                            text: cardCol.mvLabel(cardCol.b)
                            color: "#cccccc"; font.pixelSize: 11; font.family: "Monospace"
                        }
                    }
                    Row {
                        id: refRow
                        visible: cardCol.refLabel(cardCol.b).length > 0
                        spacing: 6
                        Text { text: "参考"; color: "#9aa0a6"; font.pixelSize: 10; width: cardCol.labelW }
                        Text {
                            text: cardCol.refLabel(cardCol.b)
                            color: "#cccccc"; font.pixelSize: 11; font.family: "Monospace"
                        }
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        streamView.selectedBlockIndex = -1
                        blockCanvas.selectedIndex = -1
                        blockCanvas.requestPaint()
                    }
                }
            }

        }

        // ══════════════ 码率 / 层级 面板宿主（联合分栏）══════════════
        // 两者都开（且都非悬浮）时：一分为二左右排列，中间竖直分隔条可左右
        // 拖拽调整宽度比例（panelSplitRatio，不持久化，每次启动默认 0.5）；
        // 只开一个时该面板占满整宽。高度取两者较大值，视频区按此上移让位。
        Item {
            id: panelHost
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: bottomBar.top
            z: 60   // 高于 mainDisplay 内部层（渲染层 z 通常 < 50）

            // 背景事件拦截：防止面板区域内的点击穿透到下方 gopBar 触发帧跳转
            MouseArea {
                anchors.fill: parent
                onClicked: mouse.accepted = true
                onPressed: mouse.accepted = true
                onReleased: mouse.accepted = true
                onWheel: wheel.accepted = false   // 滚轮允许穿透（面板内部 Flickable 自行消费）
            }

            readonly property bool bOpen: streamView.bitrateChartOpen
                                          && !streamView.bitrateChartFloating
            readonly property bool hOpen: streamView.hierarchyChartOpen
                                          && !streamView.hierarchyChartFloating
            readonly property bool both: bOpen && hOpen
            readonly property int boxH: Math.max(bOpen ? streamView.bitrateChartH : 0,
                                                 hOpen ? streamView.hierarchyChartH : 0)
            height: (bOpen || hOpen) ? boxH : 0

            // 双开瞬间对齐两栏高度：面板内部拖拽会断开外部绑定，
            // 故除写 streamView 两个值外，还要通过 id 直接设 panelHeight 覆盖。
            onBothChanged: {
                if (!both) return
                const h = Math.max(streamView.bitrateChartH, streamView.hierarchyChartH)
                streamView.bitrateChartH = h
                streamView.hierarchyChartH = h
                bitrateChart.panelHeight = h
                hierarchyChart.panelHeight = h
            }

            // ── 码率面板（左侧）──
            Item {
                id: bitrateBox
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                // 未打开时宽度为 0（否则 hierarchyBox 的 left 锚点会把它挤到半宽）
                width: panelHost.bOpen
                       ? (panelHost.both ? Math.round(panelHost.width * streamView.panelSplitRatio)
                                         : panelHost.width)
                       : 0
                visible: panelHost.bOpen
                clip: true
                StreamBitrateChart {
                    id: bitrateChart
                    anchors.fill: parent
                    slot: streamView.effectiveSlot
                    open: streamView.bitrateChartOpen
                    floating: streamView.bitrateChartFloating
                    // 高度双向同步：面板把手拖拽 → 宿主高度 → 视频区让位
                    // 双开时的联动由下方 connBitrateH/connHierarchyH 负责：
                    // 面板内部拖拽会断开这里的外部绑定，故必须直接监听属性强制同步。
                    panelHeight: streamView.bitrateChartH
                    onPanelHeightChanged: streamView.bitrateChartH = panelHeight
                    onRequestClose: streamView.bitrateChartOpen = false
                    onRequestToggleMode: streamView.bitrateChartFloating = !streamView.bitrateChartFloating
                }
            }

            // ── 竖直分隔条：左右拖拽调整两栏宽度比例（双击复位 50/50）──
            // 同样用屏幕全局坐标，避免面板位移反作用于 mouse.x 造成抖动。
            Rectangle {
                id: vSplitter
                x: bitrateBox.width - 3
                y: 0
                width: 6
                height: panelHost.height
                visible: panelHost.both
                color: vMa.pressed ? "#42A5FF" : (vMa.containsMouse ? "#2a3f5a" : "transparent")
                z: 40
                MouseArea {
                    id: vMa
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: pressed ? Qt.SplitHCursor
                                         : (containsMouse ? Qt.SplitHCursor : Qt.ArrowCursor)
                    property real startGlobalX: 0
                    property real startRatio: 0.5
                    onPressed: {
                        startGlobalX = mapToGlobal(mouse.x, mouse.y).x
                        startRatio = streamView.panelSplitRatio
                        mouse.accepted = true
                    }
                    onPositionChanged: {
                        if (!pressed || panelHost.width <= 0) return
                        const dx = mapToGlobal(mouse.x, mouse.y).x - startGlobalX
                        let r = startRatio + dx / panelHost.width
                        r = Math.max(0.2, Math.min(0.8, r))
                        streamView.panelSplitRatio = r
                    }
                    onDoubleClicked: streamView.panelSplitRatio = 0.5
                }
            }

            // ── 层级面板（右侧）──
            Item {
                id: hierarchyBox
                // 码率未开时左锚到父级左边缘（撑满整宽）；双开时锚在码率框右侧
                anchors.left: panelHost.bOpen ? bitrateBox.right : panelHost.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                visible: panelHost.hOpen
                clip: true
                StreamHierarchyChart {
                    id: hierarchyChart
                    anchors.fill: parent
                    slot: streamView.effectiveSlot
                    open: streamView.hierarchyChartOpen
                    floating: streamView.hierarchyChartFloating
                    // 高度双向同步：面板把手拖拽 → 宿主高度 → 视频区让位
                    // 双开联动同样由下方 Connections 负责（内部拖拽会断开外部绑定）
                    panelHeight: streamView.hierarchyChartH
                    onPanelHeightChanged: streamView.hierarchyChartH = panelHeight
                    onRequestClose: streamView.hierarchyChartOpen = false
                    onRequestToggleMode: streamView.hierarchyChartFloating = !streamView.hierarchyChartFloating
                }
            }
        }

        // ── 悬浮模式挂载容器：host 高度 0，面板以本容器底边为基线向上悬浮 ──
        // 悬浮本质是不挤占画面，故不参与左右分栏，两面板各自浮于视频上层。
        Item {
            id: floatingHost
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: bottomBar.top
            // 高度必须覆盖实际面板区域，否则溢出父容器边界的子元素不接收点击事件（穿透）
            height: {
                let h = 0
                if (streamView.bitrateChartOpen && streamView.bitrateChartFloating)
                    h = Math.max(h, streamView.bitrateChartH)
                if (streamView.hierarchyChartOpen && streamView.hierarchyChartFloating)
                    h = Math.max(h, streamView.hierarchyChartH)
                return h
            }
            z: 61

            StreamBitrateChart {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                slot: streamView.effectiveSlot
                open: streamView.bitrateChartOpen && streamView.bitrateChartFloating
                floating: true
                panelHeight: streamView.bitrateChartH
                onPanelHeightChanged: streamView.bitrateChartH = panelHeight
                onRequestClose: streamView.bitrateChartOpen = false
                onRequestToggleMode: streamView.bitrateChartFloating = !streamView.bitrateChartFloating
            }
            StreamHierarchyChart {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                slot: streamView.effectiveSlot
                open: streamView.hierarchyChartOpen && streamView.hierarchyChartFloating
                floating: true
                panelHeight: streamView.hierarchyChartH
                onPanelHeightChanged: streamView.hierarchyChartH = panelHeight
                onRequestClose: streamView.hierarchyChartOpen = false
                onRequestToggleMode: streamView.hierarchyChartFloating = !streamView.hierarchyChartFloating
            }
        }

        // ── 双开高度联动 ──
        // 面板内部的把手拖拽会直接给自己的 panelHeight 赋值，从而断开外部的
        // `panelHeight: streamView.xxxChartH` 绑定；此时再写 streamView 的值已无法
        // 回传到另一个面板。因此这里用 Connections 直接监听属性变化并强制同步对方。
        Connections {
            target: bitrateChart
            enabled: panelHost.both
            onPanelHeightChanged: {
                streamView.bitrateChartH = bitrateChart.panelHeight
                if (hierarchyChart.panelHeight !== bitrateChart.panelHeight)
                    hierarchyChart.panelHeight = bitrateChart.panelHeight
            }
        }
        Connections {
            target: hierarchyChart
            enabled: panelHost.both
            onPanelHeightChanged: {
                streamView.hierarchyChartH = hierarchyChart.panelHeight
                if (bitrateChart.panelHeight !== hierarchyChart.panelHeight)
                    bitrateChart.panelHeight = hierarchyChart.panelHeight
            }
        }

        // ── 底部：全局总控栏（控件填满行高，左右避开窗口圆角） ──
        Rectangle {
            id: bottomBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 22
            color: "#8018181c"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 0
                anchors.bottomMargin: 0
                spacing: 6

                // ── 视图上拉：状态栏式图标，无描边圆角盒 ──
                Item {
                    id: viewMenuBtn
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 28
                    implicitHeight: 20
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 20

                    Rectangle {
                        anchors.fill: parent
                        radius: 3
                        color: viewMenuPopup.visible ? "#403a3a3d"
                             : (viewMenuMa.containsMouse ? "#283a3a3d" : "transparent")
                    }
                    // 层叠面板图标（视图选项）+ 上箭头
                    Canvas {
                        id: viewMenuIcon
                        anchors.centerIn: parent
                        width: 18; height: 14
                        property color ink: viewMenuPopup.visible || viewMenuMa.containsMouse
                                           ? "#e8e8ec" : "#9aa0a6"
                        onInkChanged: requestPaint()
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            ctx.strokeStyle = ink
                            ctx.fillStyle = ink
                            ctx.lineWidth = 1.2
                            ctx.lineJoin = "round"
                            ctx.strokeRect(1.2, 5.2, 8.6, 6.2)
                            ctx.strokeRect(3.6, 2.4, 8.6, 6.2)
                            ctx.beginPath()
                            ctx.moveTo(14.2, 9.2)
                            ctx.lineTo(16.2, 6.4)
                            ctx.lineTo(18.2, 9.2)
                            ctx.closePath()
                            ctx.fill()
                        }
                    }
                    MouseArea {
                        id: viewMenuMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: viewMenuPopup.visible ? viewMenuPopup.close() : viewMenuPopup.open()
                    }
                    ToolTip.visible: viewMenuMa.containsMouse && !viewMenuPopup.visible
                    ToolTip.text: qsTr("显示选项：编码顺序 / 码率 / 层级 / 块信息")

                    Popup {
                        id: viewMenuPopup
                        x: 0
                        y: -implicitHeight - 4
                        padding: 4
                        modal: false
                        dim: false
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                        background: Rectangle {
                            color: "#1a1d22"
                            border.color: "#2a2e33"
                            radius: 4
                        }
                        contentItem: Column {
                            spacing: 1
                            Repeater {
                                model: [
                                    { key: "order",  label: "编码顺序" },
                                    { key: "rate",   label: "码率" },
                                    { key: "hier",   label: "层级" },
                                    { key: "blocks", label: "块信息" }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: menuRow.implicitWidth + 10
                                    height: 22
                                    radius: 3
                                    readonly property bool checked: {
                                        const k = modelData.key
                                        if (k === "order") return streamView.orderMode === 1
                                        if (k === "rate") return streamView.bitrateChartOpen
                                        if (k === "hier") return streamView.hierarchyChartOpen
                                        return streamView.qpOverlayEnabled
                                    }
                                    color: rowMa.containsMouse ? "#2a3f5a" : "transparent"
                                    Row {
                                        id: menuRow
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.left: parent.left
                                        anchors.leftMargin: 5
                                        spacing: 6
                                        Rectangle {
                                            width: 12; height: 12; radius: 2
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: checked ? "#2a5fc0" : "#252528"
                                            border.color: checked ? "#3d7adf" : "#3a3a44"
                                            border.width: 1
                                            Text {
                                                anchors.centerIn: parent
                                                visible: checked
                                                text: "✓"
                                                color: "#fff"; font.pixelSize: 9
                                            }
                                        }
                                        Text {
                                            id: menuLabel
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.label
                                            color: "#e8e8ec"; font.pixelSize: 12
                                        }
                                    }
                                    MouseArea {
                                        id: rowMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const k = modelData.key
                                            if (k === "order") {
                                                const m = streamView.orderMode === 1 ? 0 : 1
                                                streamView.setOrderMode(m)
                                            } else if (k === "rate") {
                                                streamView.bitrateChartOpen = !streamView.bitrateChartOpen
                                            } else if (k === "hier") {
                                                streamView.hierarchyChartOpen = !streamView.hierarchyChartOpen
                                            } else {
                                                streamView.qpOverlayEnabled = !streamView.qpOverlayEnabled
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── 槽位选择器（多 slot 时显示）──
                Row {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 4
                    visible: StreamBridge.slotCount > 1
                    Repeater {
                        model: StreamBridge.slotCount
                        delegate: Rectangle {
                            required property int index
                            width: 22; height: 18; radius: 3
                            color: streamView.currentSlot === index
                                   ? "#2a5fc0" : "#80252528"
                            border.color: streamView.currentSlot === index
                                          ? "#3d7adf" : "#3a3a44"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: String.fromCharCode(0x2460 + index)
                                color: "#fff"; font.pixelSize: 10
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: streamView.currentSlot = index
                            }
                        }
                    }
                }

                // GOP 进度条（原独立一行，现与播放控件共用底栏）
                Canvas {
                    id: gopCanvas
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredHeight: 22
                    Layout.alignment: Qt.AlignVCenter
                    Layout.minimumWidth: 80
                    visible: streamView.slotActive && streamView.slotFrames > 0

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        const list = streamView.slotFrameCache
                        const n = list ? list.length : 0
                        if (n === 0) return

                        const bw = width / n
                        const bwAct = Math.max(bw, 1)

                        const gops = streamView.slotGopCache
                        ctx.fillStyle = "rgba(240,192,64,0.45)"
                        for (let g = 0; g < (gops ? gops.length : 0); ++g) {
                            const sf = Number(gops[g].startFrameIndex)
                            if (isNaN(sf)) continue
                            ctx.fillRect(sf * bw, 0, Math.max(bwAct * 0.6, 1), height)
                        }

                        for (let i = 0; i < n; ++i) {
                            const t = String(list[i].type)
                            let c = "#6a6f76"
                            if (t === "IDR" || t === "I") c = "#f0c040"
                            else if (t === "P")          c = "#3a7adf"
                            ctx.fillStyle = c
                            ctx.fillRect(i * bw, 2, bwAct, height - 4)
                        }

                        const cur = streamView.slotCurrent
                        ctx.fillStyle = "#ffffff"
                        ctx.fillRect(cur * bw, 0, Math.max(bwAct, 2), height)
                    }

                    Connections {
                        target: streamView
                        function onSlotCurrentChanged() { gopCanvas.requestPaint() }
                        function onSlotFrameCacheChanged() { gopCanvas.requestPaint() }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const n = streamView.slotFrames
                            if (n > 0) {
                                const idx = Math.floor(mouseX / width * n)
                                StreamBridge.requestGotoAsync(streamView.effectiveSlot,
                                                              Math.max(0, Math.min(n - 1, idx)))
                            }
                        }
                    }
                }

                // 帧号：按总帧位数预留固定宽，避免 9→10、99→100 时进度条被挤动
                Text {
                    id: framePosLabel
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: 6
                    Layout.preferredWidth: framePosMetrics.width
                    Layout.minimumWidth: framePosMetrics.width
                    Layout.maximumWidth: framePosMetrics.width
                    horizontalAlignment: Text.AlignRight
                    text: {
                        const _ = streamView.globalVer
                        return streamView.slotActive
                               ? (streamView.slotCurrent + 1) + " / " + streamView.slotFrames
                               : "— / —"
                    }
                    color: "#a0a4ac"; font.pixelSize: 11
                    font.family: "Monospace"
                    elide: Text.ElideNone
                }
                TextMetrics {
                    id: framePosMetrics
                    font: framePosLabel.font
                    text: {
                        const _ = streamView.globalVer
                        const total = Math.max(1, streamView.slotFrames)
                        const cur = Math.max(1, streamView.slotCurrent + 1)
                        const d = Math.max(String(total).length, String(cur).length)
                        return "8".repeat(d) + " / " + "8".repeat(d)
                    }
                }

                // 播放控制组（与底栏同高，避免上松下贴）
                Row {
                    spacing: 2
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: 20

                    // ◀◀（上一帧，帧级步进）
                    Rectangle {
                        width: 28; height: 20; radius: 3
                        color: gPrevMa.containsMouse ? "#803a3a3d" : "#80252528"
                        Text { anchors.centerIn: parent; text: "◀◀"; color: "#ccc"; font.pixelSize: 10 }
                        ToolTip.visible: gPrevMa.containsMouse
                        ToolTip.text: qsTr("上一帧（帧级步进）")
                        MouseArea {
                            id: gPrevMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { streamView.atEnd = false; streamView.stopPlay(); StreamBridge.prevFrame(streamView.effectiveSlot) }
                        }
                    }
                    // ⏮（快退 15 帧）
                    Rectangle {
                        width: 26; height: 20; radius: 3
                        color: gSkipBackMa.containsMouse ? "#803a3a3d" : "#80252528"
                        Text { anchors.centerIn: parent; text: "⏮"; color: "#ccc"; font.pixelSize: 11 }
                        ToolTip.visible: gSkipBackMa.containsMouse
                        ToolTip.text: qsTr("快退 15 帧")
                        MouseArea {
                            id: gSkipBackMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: StreamBridge.requestGotoAsync(streamView.effectiveSlot,
                                                                    streamView.slotCurrent - 15)
                        }
                    }
                    // ▶/⏸（主播放按钮，蓝色，真实逐帧播放）
                    Rectangle {
                        width: 26; height: 20; radius: 3
                        color: gPlayMa.containsMouse ? "#803d7adf" : (streamView.playing ? "#805a8ae0" : "#802a5fc0")
                        Text {
                            anchors.centerIn: parent
                            text: streamView.playing ? "⏸" : "▶"
                            color: "#fff"; font.pixelSize: 11
                        }
                        ToolTip.visible: gPlayMa.containsMouse
                        ToolTip.text: streamView.playing ? qsTr("暂停播放") : qsTr("播放（按帧率连续解码）")
                        MouseArea {
                            id: gPlayMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: streamView.togglePlay()
                        }
                    }
                    // ⏭（快进 15 帧）
                    Rectangle {
                        width: 26; height: 20; radius: 3
                        color: gSkipFwdMa.containsMouse ? "#803a3a3d" : "#80252528"
                        Text { anchors.centerIn: parent; text: "⏭"; color: "#ccc"; font.pixelSize: 11 }
                        ToolTip.visible: gSkipFwdMa.containsMouse
                        ToolTip.text: qsTr("快进 15 帧")
                        MouseArea {
                            id: gSkipFwdMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: StreamBridge.requestGotoAsync(streamView.effectiveSlot,
                                                                    streamView.slotCurrent + 15)
                        }
                    }
                    // ▶▶（下一帧，帧级步进）
                    Rectangle {
                        width: 28; height: 20; radius: 3
                        color: gNextMa.containsMouse ? "#803a3a3d" : "#80252528"
                        Text { anchors.centerIn: parent; text: "▶▶"; color: "#ccc"; font.pixelSize: 10 }
                        ToolTip.visible: gNextMa.containsMouse
                        ToolTip.text: qsTr("下一帧（帧级步进）")
                        MouseArea {
                            id: gNextMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { streamView.atEnd = false; streamView.stopPlay(); StreamBridge.nextFrame(streamView.effectiveSlot) }
                        }
                    }
                    // ↺（复位到 0 帧，R）
                    Rectangle {
                        width: 26; height: 20; radius: 3
                        color: gResetMa.containsMouse ? "#80c87070" : "#80b85a5a"
                        Text { anchors.centerIn: parent; text: "↺"; color: "#fff"; font.pixelSize: 14 }
                        ToolTip.visible: gResetMa.containsMouse
                        ToolTip.text: qsTr("重置到首帧（R）")
                        MouseArea {
                            id: gResetMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: streamView.resetToStart()
                        }
                    }
                }

                // 右侧：返回（仅关闭所有 slot 回到 setup 阶段，不删除 pendingFiles 记录）
                // pendingFiles 始终保留在 QSettings 中，用户回到 setup 阶段仍可看到历史文件。
                Row {
                    spacing: 6
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: 8

                    Rectangle {
                        width: 52; height: 20; radius: 3
                        color: clearMa.containsMouse ? "#80c87070" : "#80b85a5a"
                        Text {
                            anchors.centerIn: parent
                            text: "返回"; color: "#fff"; font.pixelSize: 11
                        }
                        MouseArea {
                            id: clearMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // 只关闭所有已打开的码流文件，不动 setup 阶段的待选列表
                                StreamBridge.closeAll()
                                streamView.currentSlot = 0
                            }
                        }
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 文件 / 文件夹对话框（setup 阶段使用，render 阶段隐藏）
    // ─────────────────────────────────────────────────────────────────────
    FileDialog {
        id: addFileDialog
        title: "添加码流文件"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.m4v *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv *.mpg *.mpeg *.m2ts *.mts *.vob *.ogv *.3gp *.asf *.h264 *.hevc *.h265 *.265 *.264 *.266 *.h266 *.vvc *.av1 *.ivf *.obu *.avc *.m2v *.mpv *.m1v *.y4m *.yuv)",
            "所有文件 (*)"
        ]
        onAccepted: {
            const newPaths = []
            for (let i = 0; i < selectedFiles.length; ++i) {
                newPaths.push(streamView._normalizeFilePath(selectedFiles[i]))
            }
            if (newPaths.length === 0) return
            const merged = streamView.pendingFiles.slice()
            for (let i = 0; i < newPaths.length; ++i) {
                if (merged.indexOf(newPaths[i]) < 0) merged.push(newPaths[i])
            }
            streamView.pendingFiles = merged
            streamView.pendingSelectedIndex = merged.length - newPaths.length
            streamView.pendingStatus = ""
            // 批量预 probe，使列表中每行都能显示大小和修改时间
            streamView._batchProbe()
            streamView._onFileSelected(streamView.pendingSelectedIndex)
            // 默认选中第一个新文件
            streamView._selectedFiles = ({})
            streamView._selectedFiles[merged[streamView.pendingSelectedIndex]] = true
            streamView._anchorIndex = streamView.pendingSelectedIndex
            streamView._selectAllChecked = false
        }
    }
    FolderDialog {
        id: addFolderDialog
        title: "添加码流文件夹"
        onAccepted: {
            const folder = streamView._normalizeFilePath(selectedFolder)
            let found = []
            try { found = Fs.scanVideoFolderPath(folder, true) || [] } catch (e) { found = [] }
            if (found.length === 0) {
                streamView.pendingStatus = "未在该文件夹中找到码流文件"
                return
            }
            const merged = streamView.pendingFiles.slice()
            for (let i = 0; i < found.length; ++i) {
                if (merged.indexOf(found[i]) < 0) merged.push(found[i])
            }
            streamView.pendingFiles = merged
            streamView.pendingSelectedIndex = merged.length - found.length
            streamView.pendingStatus = ""
            // 批量预 probe
            streamView._batchProbe()
            streamView._onFileSelected(streamView.pendingSelectedIndex)
            // 默认选中第一个新文件
            streamView._selectedFiles = ({})
            streamView._selectedFiles[merged[streamView.pendingSelectedIndex]] = true
            streamView._anchorIndex = streamView.pendingSelectedIndex
            streamView._selectAllChecked = false
        }
    }

    // ── 裸码流导出：选择输出目录 ──
    FolderDialog {
        id: exportFolderDialog
        title: "选择裸码流导出目录"
        currentFolder: {
            try { return "file://" + Fs.downloadsDir() } catch (e) { return "" }
        }
        onAccepted: {
            const outDir = streamView._normalizeFilePath(selectedFolder)
            streamView._doExportRawBitstream(outDir)
        }
    }

    // 导出状态自动清除
    Timer {
        id: exportStatusClearTimer
        interval: 3000
        repeat: false
        onTriggered: streamView._exportStatus = ""
    }

    // ── 工具函数 ──
    function _normalizeFilePath(urlOrStr) {
        const s = String(urlOrStr)
        if (s.indexOf("file://") === 0) return Fs.urlToLocalFile(urlOrStr)
        return s.replace(/\\/g, "/")
    }
    function _fileBasename(path) {
        const p = String(path).replace(/\\/g, "/")
        const idx = p.lastIndexOf("/")
        return idx >= 0 ? p.substring(idx + 1) : p
    }
    function _fileDir(path) {
        const p = String(path).replace(/\\/g, "/")
        const idx = p.lastIndexOf("/")
        return idx >= 0 ? p.substring(0, idx) : ""
    }
    function _openFile() { addFileDialog.open() }
    function _openFolder() { addFolderDialog.open() }

    // 点「开始分析」：把选中的文件（或全部）通过 openFile 打开（最多 3 个 slot）
    function _startAnalysis() {
        streamView.pendingStatus = ""
        // 优先使用选中的文件，如果没选则用全部
        var sel = streamView._selectedPaths()
        const files = (sel.length > 0) ? sel : streamView.pendingFiles
        if (!files || files.length === 0) {
            streamView.pendingStatus = "请先添加码流文件"
            return
        }
        let openedCount = 0
        let firstSlot = -1
        const max = Math.min(files.length, StreamBridge.maxSlots)
        for (let i = 0; i < max; ++i) {
            const slot = StreamBridge.openFile(files[i])
            if (slot >= 0) {
                if (firstSlot < 0) firstSlot = slot
                ++openedCount
            } else {
                streamView.pendingStatus = "打开失败：" + streamView._fileBasename(files[i])
            }
        }
        if (openedCount === 0) {
            streamView.pendingStatus = "全部文件打开失败，请检查路径"
            return
        }
        // 不清空 pendingFiles：保留文件列表以便"清空返回"后仍能看到历史
        // 只重置选中索引和状态文本，切到 render 阶段
        streamView.pendingStatus = ""
        if (firstSlot >= 0) streamView.currentSlot = firstSlot
    }
}
