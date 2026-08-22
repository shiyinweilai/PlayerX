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

Item {
    id: streamView
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

    Component.onCompleted: {
        // 从 QSettings 恢复上次的码流文件列表（与 YuvBridge 一致）
        const saved = StreamBridge.streamFileList()
        if (saved && saved.length > 0) {
            streamView.pendingFiles = saved
            streamView.pendingSelectedIndex = 0
            // 自动探测第一个文件
            streamView._onFileSelected(0)
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

    // ── 拖拽导入：从 DropArea 接收文件 URL 列表 ──
    function _handleDroppedFiles(urls) {
        if (!urls || urls.length === 0) return
        const videoExts = ["mp4", "mov", "mkv", "avi", "webm", "flv", "ts", "m4v",
                           "wmv", "mpg", "mpeg", "m2ts", "mts", "vob", "ogv",
                           "3gp", "asf", "h264", "h265", "hevc", "264", "265",
                           "y4m", "yuv"]
        const newPaths = []
        for (let i = 0; i < urls.length; ++i) {
            const localPath = streamView._normalizeFilePath(urls[i])
            if (!localPath || localPath.length === 0) continue
            // 扩展名过滤
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
    readonly property var    slotFrameList: {
        const _ = streamView.globalVer
        return slotActive ? StreamBridge.frameList(effectiveSlot) : []
    }
    readonly property var    slotGopList: {
        const _ = streamView.globalVer
        return slotActive ? StreamBridge.gopList(effectiveSlot) : []
    }
    readonly property var    slotBlocks: {
        const _ = streamView.globalVer
        return slotActive ? StreamBridge.blockInfoAt(effectiveSlot, slotCurrent) : []
    }
    readonly property bool   blockSupported: slotBlocks && slotBlocks.length > 0
    property bool qpOverlayEnabled: false

    // 全局版本号：任意 slot 的帧变化/打开/关闭都 ++，驱动底部总控栏的"▶/⏸"图标等
    property int globalVer: 0
    Connections {
        target: StreamBridge
        function onCurrentFrameChanged(changedSlot) { streamView.globalVer++ }
        function onFileOpened(openedSlot)            { streamView.globalVer++ }
        function onFileClosed(closedSlot)            { streamView.globalVer++ }
        function onSlotCountChanged()                { streamView.globalVer++ }
    }
    // 当前 slot 是否"正在播放"（P1 真接播放时才有意义；P0 永远 false，▶ 一直显示）
    function globalAnyPlaying() {
        const _ = streamView.globalVer
        return false
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

        // ── 标题栏 ──
        Row {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: 24
            anchors.topMargin: 20
            spacing: 12
            Text {
                text: "码流分析"
                color: "#e8e8ec"; font.pixelSize: 18; font.bold: true
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "· " + streamView.pendingFiles.length + " 个"
                color: "#9aa0a6"; font.pixelSize: 13
            }
        }

        // ── 顶部操作按钮（仿 YuvSetupView 的"添加/清空"组） ──
        Row {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 18
            anchors.rightMargin: 24
            spacing: 8

            // 排序按钮 + 下拉菜单
            StreamFlatButton {
                text: streamView._sortLabel() + " ▾"
                enabled: streamView.pendingFiles.length > 0
                onClicked: sortMenu.open()

                Menu {
                    id: sortMenu
                    width: 160
                    y: parent.height + 4

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
                    // 清空 = 删除全部文件记录（持久化也会同步更新）
                    streamView.pendingFiles = []
                    streamView.pendingSelectedIndex = -1
                    streamView.pendingStatus = ""
                }
            }
        }

        // ── 主区：左侧文件列表（宽） + 右侧文件信息面板 ──
        RowLayout {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 70
            anchors.bottomMargin: 90
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            spacing: 16

            // 左：文件列表卡片（占大部分宽度）
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: 400
                radius: 4
                color: streamView._dragHovering ? "#1a1a22" : "#16161b"
                border.color: streamView._dragHovering ? "#3a78c8" : "#2a2e33"
                border.width: streamView._dragHovering ? 2 : 1
                Behavior on border.color { ColorAnimation { duration: 120 } }
                Behavior on color { ColorAnimation { duration: 120 } }

                ListView {
                    id: fileListView
                    anchors.fill: parent
                    anchors.margins: 8
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
                        color: streamView.pendingSelectedIndex === index
                               ? "#2a3a55" : (rowMa.containsMouse ? "#1e1e24" : "transparent")
                        border.color: streamView.pendingSelectedIndex === index ? "#3a78c8" : "transparent"
                        border.width: 1
                        RowLayout {
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
                                Layout.maximumWidth: 260
                                elide: Text.ElideLeft
                            }
                            // 删除按钮（hover 时显示）
                            Rectangle {
                                visible: rowMa.containsMouse
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
                            onClicked: streamView._onFileSelected(index)
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: streamView.pendingFiles.length === 0
                        text: "拖拽视频文件到此处，或点右上「+ 添加」选择 H.264 / H.265 视频"
                        color: "#6a6f76"; font.pixelSize: 12
                    }
                }

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
                radius: 4
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

                    // 开始分析按钮
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        radius: 6
                        color: startMa.containsMouse ? "#3d7adf" : "#2a5fc0"
                        Text {
                            anchors.centerIn: parent
                            text: streamView.pendingFiles.length > 1
                                  ? "▶  开始分析（" + streamView.pendingFiles.length + " 个文件）"
                                  : "▶  开始分析"
                            color: "#fff"; font.pixelSize: 14; font.bold: true
                        }
                        MouseArea {
                            id: startMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: streamView._startAnalysis()
                        }
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

        // ── 顶部：流信息条（与 YuvWindow 总控栏同款 #8018181c） ──
        Rectangle {
            id: topInfoBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 36
            color: "#8018181c"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 14

                Text {
                    text: "码流分析"
                    color: "#e8e8ec"
                    font.pixelSize: 12
                    font.bold: true
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 14

                    // 槽位选择器（多 slot 时显示）
                    Row {
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

                    Text { visible: streamView.slotActive
                        text: (streamView.slotInfo.width > 0 && streamView.slotInfo.height > 0)
                              ? (streamView.slotInfo.width + " × " + streamView.slotInfo.height)
                              : "分辨率未知"
                        color: "#cccccc"; font.pixelSize: 11
                        font.family: "Monospace" }
                    Text { visible: streamView.slotActive
                        text: Number(streamView.slotInfo.fps).toFixed(2) + " fps"
                        color: "#cccccc"; font.pixelSize: 11
                        font.family: "Monospace" }
                    Text { visible: streamView.slotActive
                        text: streamView.slotInfo.codecLong
                        color: "#cccccc"; font.pixelSize: 11 }
                    Text { visible: streamView.slotActive
                        text: streamView.slotInfo.profile + " | Level " + streamView.slotInfo.level
                        color: "#cccccc"; font.pixelSize: 11 }
                    Text { visible: streamView.slotActive
                        text: (Number(streamView.slotInfo.bitrate) / 1e6).toFixed(2) + " Mbps"
                        color: "#cccccc"; font.pixelSize: 11 }
                    Text { visible: streamView.slotActive
                        text: "File: " + streamView.slotInfo.fileName
                        color: "#9aa0a6"; font.pixelSize: 11 }
                    Text { visible: !streamView.slotActive
                        text: "未加载文件"
                        color: "#6a6f76"; font.pixelSize: 11 }
                }

                // 显示 QP 开关（占位）
                Row {
                    spacing: 6
                    visible: streamView.slotActive
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "显示QP"
                        color: "#9aa0a6"; font.pixelSize: 11
                    }
                    Rectangle {
                        width: 28; height: 16; radius: 8
                        color: streamView.qpOverlayEnabled ? "#2a5fc0" : "#252528"
                        border.color: streamView.qpOverlayEnabled ? "#3d7adf" : "#3a3a44"
                        border.width: 1
                        Rectangle {
                            width: 12; height: 12; radius: 6
                            color: "#e8e8ec"
                            anchors.verticalCenter: parent.verticalCenter
                            x: streamView.qpOverlayEnabled ? parent.width - 14 : 2
                            Behavior on x { NumberAnimation { duration: 90 } }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                streamView.qpOverlayEnabled = !streamView.qpOverlayEnabled
                                console.log("[StreamView] 显示QP =", streamView.qpOverlayEnabled,
                                            "（占位，未实现 CU 网格 / QP 着色）")
                            }
                        }
                    }
                }
            }
        }

        // ── 中部：主显示区（CU 网格 + QP 占位） ──
        Item {
            id: mainDisplay
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: topInfoBar.bottom
            anchors.bottom: bottomBar.top

            Rectangle { anchors.fill: parent; color: "#0a0a0e" }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 8
                Text { Layout.alignment: Qt.AlignHCenter; text: "🎞"; font.pixelSize: 56 }
                Text { Layout.alignment: Qt.AlignHCenter
                    visible: !streamView.slotActive
                    text: "未加载码流文件"
                    color: "#e8e8ec"; font.pixelSize: 16; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter
                    visible: streamView.slotActive
                    text: "帧级信息已加载"
                    color: "#e8e8ec"; font.pixelSize: 16; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter
                    visible: streamView.slotActive
                    text: "块级 CU 划分 / QP 着色需要 P1 阶段接入 FFmpeg 解码器补丁"
                    color: "#9aa0a6"; font.pixelSize: 12 }
                Text { Layout.alignment: Qt.AlignHCenter
                    visible: streamView.slotActive
                            && streamView.slotInfo.width > 0 && streamView.slotInfo.height > 0
                    text: "（已加载：" + streamView.slotInfo.width + "×" + streamView.slotInfo.height
                          + " @ " + Number(streamView.slotInfo.fps).toFixed(2) + " fps，"
                          + streamView.slotInfo.codecLong + "）"
                    color: "#6a6f76"; font.pixelSize: 11 }
                Text { Layout.alignment: Qt.AlignHCenter
                    visible: streamView.slotActive
                            && (streamView.slotInfo.width <= 0 || streamView.slotInfo.height <= 0)
                    text: "（裸流 fallback：帧级统计 / GOP 切分可用，宽高 / fps / profile 等"
                          + " 需要 P1 接入 FFmpeg 解码器补丁）"
                    color: "#6a6f76"; font.pixelSize: 11 }
            }
        }

        // ── 底部：全局总控栏（仿 YuvWindow.qml 第 1556-1750 行，36px 半透明深色） ──
        Rectangle {
            id: bottomBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 36
            color: "#8018181c"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 4

                // 左：弹性空白把按钮推到右
                Item { Layout.fillWidth: true }

                // 帧号文本（YuvWindow 总控栏同款，"N / Total"，纯数字等宽字体）
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: {
                        const _ = streamView.globalVer
                        return streamView.slotActive
                               ? (streamView.slotCurrent + 1) + " / " + streamView.slotFrames
                               : "— / —"
                    }
                    color: "#a0a4ac"; font.pixelSize: 11
                    font.family: "Monospace"
                }

                // 播放控制组（YuvWindow 总控栏同款配色：#80252528 / #802a5fc0 / #80b85a5a）
                Row {
                    spacing: 2
                    Layout.alignment: Qt.AlignVCenter

                    // ⏮（快退 15 帧）
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gSkipBackMa.containsMouse ? "#803a3a3d" : "#80252528"
                        Text { anchors.centerIn: parent; text: "⏮"; color: "#ccc"; font.pixelSize: 11 }
                        MouseArea {
                            id: gSkipBackMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: StreamBridge.gotoFrame(streamView.effectiveSlot,
                                                              streamView.slotCurrent - 15)
                        }
                    }
                    // ◀（上一帧）
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gPrevMa.containsMouse ? "#803a3a3d" : "#80252528"
                        Text { anchors.centerIn: parent; text: "◀"; color: "#ccc"; font.pixelSize: 11 }
                        MouseArea {
                            id: gPrevMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: StreamBridge.prevFrame(streamView.effectiveSlot)
                        }
                    }
                    // ▶/⏸（主播放按钮，蓝色）
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gPlayMa.containsMouse ? "#803d7adf" : "#802a5fc0"
                        Text {
                            anchors.centerIn: parent
                            text: {
                                const _ = streamView.globalVer
                                return streamView.globalAnyPlaying() ? "⏸" : "▶"
                            }
                            color: "#fff"; font.pixelSize: 11
                        }
                        MouseArea {
                            id: gPlayMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // 一期未实现真播放：仅 console.log
                                console.log("[StreamView] 播放/暂停（一期未实现，仅切换当前帧）")
                            }
                        }
                    }
                    // ▶（下一帧）
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gNextMa.containsMouse ? "#803a3a3d" : "#80252528"
                        Text { anchors.centerIn: parent; text: "▶"; color: "#ccc"; font.pixelSize: 11 }
                        MouseArea {
                            id: gNextMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: StreamBridge.nextFrame(streamView.effectiveSlot)
                        }
                    }
                    // ⏭（快进 15 帧）
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gSkipFwdMa.containsMouse ? "#803a3a3d" : "#80252528"
                        Text { anchors.centerIn: parent; text: "⏭"; color: "#ccc"; font.pixelSize: 11 }
                        MouseArea {
                            id: gSkipFwdMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: StreamBridge.gotoFrame(streamView.effectiveSlot,
                                                              streamView.slotCurrent + 15)
                        }
                    }
                    // ↺（复位到 0 帧，红色）
                    Rectangle {
                        width: 28; height: 22; radius: 3
                        color: gResetMa.containsMouse ? "#80c87070" : "#80b85a5a"
                        Text { anchors.centerIn: parent; text: "↺"; color: "#fff"; font.pixelSize: 14 }
                        MouseArea {
                            id: gResetMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: StreamBridge.firstFrame(streamView.effectiveSlot)
                        }
                    }
                }

                // 右侧：清空（仅关闭所有 slot 回到 setup 阶段，不删除 pendingFiles 记录）
                // pendingFiles 始终保留在 QSettings 中，用户回到 setup 阶段仍可看到历史文件。
                Row {
                    spacing: 6
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: 12

                    Rectangle {
                        width: 64; height: 22; radius: 3
                        color: clearMa.containsMouse ? "#80c87070" : "#80b85a5a"
                        Text {
                            anchors.centerIn: parent
                            text: "清空"; color: "#fff"; font.pixelSize: 11
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
            "码流文件 (*.mp4 *.mov *.m4v *.mkv *.ts *.flv *.h264 *.hevc *.h265 *.265)",
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
        }
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

    // 点「开始分析」：把所有 pendingFiles 通过 openFile 打开（最多 3 个 slot）
    function _startAnalysis() {
        streamView.pendingStatus = ""
        const files = streamView.pendingFiles
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
