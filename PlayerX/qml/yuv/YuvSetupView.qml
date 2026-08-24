// YuvSetupView.qml — YUV 分析视图（从 Main.qml 拆分）
// 两阶段架构：setup 参数输入 + render 沉浸渲染
// 用法：在 Main.qml 中实例化，由外部设置 anchors 和 visible 即可。

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import PlayerX 1.0

Item {
    id: yuvView
    z: 100

    // ── 供顶部菜单「YUV 分析 ▸ 打开 YUV 文件/文件夹」调用的入口 ──
    // 仅触发本模块自带的 FileDialog / FolderDialog（见下方 yuvSetupView 内），
    // 与「播放对比」的视频打开入口（addDialog / multiGroupDialog）完全隔离。
    // 打开前先回填上次选中的目录（持久化在 YuvBridge），避免首次按下就跳到根目录。
    function openFileDialog() {
        const last = YuvBridge.lastOpenedFolder()
        if (last && last.length > 0) yuvSetupFileDialog.currentFolder = "file://" + last
        yuvSetupFileDialog.open()
    }
    function openFolderDialog() {
        const last = YuvBridge.lastOpenedFolder()
        if (last && last.length > 0) yuvSetupFolderDialog.currentFolder = "file://" + last
        yuvSetupFolderDialog.open()
    }

    // ── 路径工具函数（兼容 Windows / macOS / Linux）──
    // 使用 Fs.urlToLocalFile() 转换 file:// URL 为本地路径（与播放对比一致）
    // 跨平台正确：macOS → "/Users/..."，Windows → "C:/Users/..."
    function normalizeFilePath(urlOrStr) {
        // 如果是 file:// URL，走 C++ 的 QUrl::toLocalFile()
        const s = String(urlOrStr)
        if (s.indexOf("file://") === 0) {
            return Fs.urlToLocalFile(urlOrStr)
        }
        // 非 URL 的普通路径字符串，统一分隔符
        return s.replace(/\\/g, "/")
    }

    // 从绝对路径中提取文件名
    function fileBasename(path) {
        const p = String(path).replace(/\\/g, "/")
        const idx = p.lastIndexOf('/')
        return idx >= 0 ? p.substring(idx + 1) : p
    }

    // ── 参数输入主界面（setup） ────────────────────────────────
    Item {
        id: yuvSetupView
        // 文件列表（多选文件或文件夹扫描结果）
        property var fileList: []
        property int selectedIndex: -1
        // 勾选要渲染的文件路径（最多 3 个）
        property var checkedList: []
        // 排序方式：0=添加顺序（默认）/ 1=名称 A→Z / 2=名称 Z→A
        property int sortMode: 0
        readonly property var sortOptions: [
            { mode: 0, label: "默认",   short: "默认" },
            { mode: 1, label: "名称升序", short: "升序" },
            { mode: 2, label: "名称降序", short: "降序" }
        ]
        readonly property string sortLabel: sortOptions[sortMode].short

        // 按当前 sortMode 返回有序的展示列表（用于驱动 ListView.model）。
        //   - 添加顺序：保持原始顺序
        //   - 名称 A→Z / Z→A：按 basename 不区分大小写排序
        readonly property var sortedFileList: {
            const arr = fileList.slice()
            if (sortMode === 1) {
                arr.sort(function(a, b) {
                    const A = String(a).toLowerCase(), B = String(b).toLowerCase()
                    const ai = A.lastIndexOf("/"), bi = B.lastIndexOf("/")
                    const an = (ai >= 0 ? A.substring(ai + 1) : A)
                    const bn = (bi >= 0 ? B.substring(bi + 1) : B)
                    if (an < bn) return -1
                    if (an > bn) return 1
                    return 0
                })
            } else if (sortMode === 2) {
                arr.sort(function(a, b) {
                    const A = String(a).toLowerCase(), B = String(b).toLowerCase()
                    const ai = A.lastIndexOf("/"), bi = B.lastIndexOf("/")
                    const an = (ai >= 0 ? A.substring(ai + 1) : A)
                    const bn = (bi >= 0 ? B.substring(bi + 1) : B)
                    if (an < bn) return 1
                    if (an > bn) return -1
                    return 0
                })
            }
            return arr
        }

        function _indexInFileList(path) {
            return fileList.indexOf(path)
        }
        // 当前正在编辑参数的文件（用于切换时保存旧参数、加载新参数）
        property string currentPath: ""
        // 防止初始化时空列表覆盖持久化数据
        property bool _loaded: false
        anchors.fill: parent
        visible: YuvBridge.slotCount === 0

        // ── 文件列表持久化：加载/保存 ──
        Component.onCompleted: {
            const saved = YuvBridge.yuvFileList()
            console.log("[yuvSetupView] Component.onCompleted loaded:", saved.length, "files")
            if (saved && saved.length > 0) {
                const arr = []
                for (let i = 0; i < saved.length; ++i) {
                    arr.push(saved[i])
                }
                if (arr.length > 0) fileList = arr
            }
            _loaded = true
        }

        onFileListChanged: {
            if (!_loaded) return  // 初始化阶段不写入，防止清空持久化
            console.log("[yuvSetupView] fileList changed:", fileList.length, "items")
            YuvBridge.setYuvFileList(fileList)
        }

        // ── 参数联动：切换文件时保存旧参数、加载新参数 ──
        onSelectedIndexChanged: {
            // 1) 保存旧文件参数（如果正在编辑某个文件）
            if (currentPath !== "" && yuvSetupW && yuvSetupH) {
                saveCurrentParams()
            }
            // 2) 更新当前文件
            if (selectedIndex >= 0 && selectedIndex < fileList.length) {
                currentPath = fileList[selectedIndex]
            } else {
                currentPath = ""
            }
            // 3) 加载新文件参数（无记录则回默认）
            loadParamsForCurrent()
        }

        function currentFmt() {
            let baseFmt = "yuv420p"
            if (yuvFmtCombo && yuvFmtCombo.model && yuvFmtCombo.currentIndex >= 0
                    && yuvFmtCombo.currentIndex < yuvFmtCombo.model.length) {
                baseFmt = yuvFmtCombo.model[yuvFmtCombo.currentIndex].fmt
            }
            // 根据 bit depth 组合最终格式名
            // 例如 yuv420p + 10bit → yuv420p10le
            const bd = currentBitDepth()
            if (bd === 10) {
                // 如果 baseFmt 已经含 "10"，不重复加
                if (baseFmt.indexOf("10") < 0) {
                    return baseFmt + "10le"
                }
            }
            return baseFmt
        }

        function currentBitDepth() {
            if (yuvBitDepthCombo && yuvBitDepthCombo.model && yuvBitDepthCombo.currentIndex >= 0
                    && yuvBitDepthCombo.currentIndex < yuvBitDepthCombo.model.length) {
                return yuvBitDepthCombo.model[yuvBitDepthCombo.currentIndex].value
            }
            return 8
        }

        function saveCurrentParams() {
            if (currentPath === "") return
            const w   = parseInt(yuvSetupW.text) || 1920
            const h   = parseInt(yuvSetupH.text) || 1080
            const fmt = currentFmt()
            const fps = parseFloat(yuvFpsCombo.displayText) || 30.0
            const bd  = currentBitDepth()
            YuvBridge.setYuvFileParams(currentPath, w + "x" + h + "|" + fmt + "|" + fps + "|" + bd)
        }

        // ── 从文件名自动解析参数（宽高、帧率、bit 深度）──
        // 算法：按下划线 split，逐段查找 "数字x数字" 确定宽高，
        //       宽高段紧后的段作为帧率，含 "10bit" 段则标记 10bit。
        // 典型文件名模式：
        //   BQSquare_416x240_60.yuv        → 416×240, 60fps, 8bit
        //   10bit_3_4096x2160_24_f300.yuv  → 4096×2160, 24fps, 10bit
        //   10bit_animation_3400x1912_25.yuv → 3400×1912, 25fps, 10bit
        function parseFilenameParams(filePath) {
            const name = fileBasename(filePath)
            let result = { width: 0, height: 0, fps: 0, is10bit: false }

            // 去掉扩展名后按下划线 split
            const baseName = name.replace(/\.[^.]+$/, "")
            const parts = baseName.split('_')

            let whIdx = -1
            for (let i = 0; i < parts.length; ++i) {
                // 检测 10bit
                if (/^10bit$/i.test(parts[i])) {
                    result.is10bit = true
                    continue
                }
                // 检测宽高：数字x数字（不区分大小写，支持 4096x2160 / 4096X2160）
                const m = parts[i].match(/^(\d+)[xX](\d+)$/)
                if (m && whIdx < 0) {
                    const w = parseInt(m[1])
                    const h = parseInt(m[2])
                    if (w >= 16 && w <= 16384 && h >= 16 && h <= 16384) {
                        result.width = w
                        result.height = h
                        whIdx = i
                    }
                }
            }

            // 帧率：宽高段之后紧跟的段（纯数字或浮点数）
            if (whIdx >= 0 && whIdx + 1 < parts.length) {
                const fpsStr = parts[whIdx + 1]
                const f = parseFloat(fpsStr)
                if (!isNaN(f) && f >= 1 && f <= 240) {
                    result.fps = f
                }
            }

            return result
        }

        function loadParamsForCurrent() {
            if (currentPath === "") return
            const params = YuvBridge.yuvFileParams(currentPath)
            if (params && params.length > 0) {
                // 解析 "1920x1080|yuv420p|30|8" 或旧格式 "1920x1080|yuv420p|30"
                const parts = params.split('|')
                const wh = parts[0].split('x')
                if (wh.length === 2) {
                    yuvSetupW.text = wh[0]
                    yuvSetupH.text = wh[1]
                }
                if (parts.length >= 2) {
                    // 格式可能存储的是 yuv420p10le 这种合成格式，
                    // 需拆回 baseFmt + bitDepth
                    let fmtStr = parts[1]
                    let loadedBd = 8
                    if (fmtStr.indexOf("10le") >= 0) {
                        loadedBd = 10
                        fmtStr = fmtStr.replace("10le", "")
                    }
                    // 在格式列表中匹配 baseFmt
                    for (let i = 0; i < yuvFmtCombo.model.length; ++i) {
                        if (yuvFmtCombo.model[i].fmt === fmtStr) {
                            yuvFmtCombo.currentIndex = i
                            break
                        }
                    }
                    // 设置 bitDepth 下拉
                    yuvBitDepthCombo.currentIndex = (loadedBd === 10) ? 1 : 0
                }
                if (parts.length >= 3) {
                    const f = parseFloat(parts[2]) || 30.0
                    for (let i = 0; i < yuvFpsCombo.model.length; ++i) {
                        if (Math.abs(yuvFpsCombo.model[i].value - f) < 0.01) {
                            yuvFpsCombo.currentIndex = i
                            break
                        }
                    }
                }
                if (parts.length >= 4) {
                    const bd = parseInt(parts[3]) || 8
                    yuvBitDepthCombo.currentIndex = (bd === 10) ? 1 : 0
                }
                // 同步尺寸预设下拉选中
                yuvSizeCombo.rebuild()
            } else {
                // 新文件：尝试从文件名解析参数
                const parsed = parseFilenameParams(currentPath)

                // 宽高：解析到则填入，否则保留空（不乱填）
                if (parsed.width > 0 && parsed.height > 0) {
                    yuvSetupW.text = String(parsed.width)
                    yuvSetupH.text = String(parsed.height)
                } else {
                    yuvSetupW.text = ""
                    yuvSetupH.text = ""
                }

                // 像素格式：默认 yuv420p（bitDepth 单独控制 8/10bit）
                for (let i = 0; i < yuvFmtCombo.model.length; ++i) {
                    if (yuvFmtCombo.model[i].fmt === "yuv420p") { yuvFmtCombo.currentIndex = i; break }
                }

                // bit 位宽
                yuvBitDepthCombo.currentIndex = parsed.is10bit ? 1 : 0

                // 帧率：解析到则选中最接近的，否则选默认 30fps
                if (parsed.fps > 0) {
                    let bestIdx = -1, bestDiff = 9999
                    for (let i = 0; i < yuvFpsCombo.model.length; ++i) {
                        const diff = Math.abs(yuvFpsCombo.model[i].value - parsed.fps)
                        if (diff < bestDiff) { bestDiff = diff; bestIdx = i }
                    }
                    if (bestIdx >= 0 && bestDiff < 1) {
                        yuvFpsCombo.currentIndex = bestIdx
                    } else {
                        for (let i = 0; i < yuvFpsCombo.model.length; ++i) {
                            if (yuvFpsCombo.model[i].value === 30) { yuvFpsCombo.currentIndex = i; break }
                        }
                    }
                } else {
                    for (let i = 0; i < yuvFpsCombo.model.length; ++i) {
                        if (yuvFpsCombo.model[i].value === 30) { yuvFpsCombo.currentIndex = i; break }
                    }
                }

                yuvSizeCombo.rebuild()
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "#101012"
        }

        // ════ 左侧列表 + 右侧参数栏（始终显示；空列表时显示添加提示）══════
        RowLayout {
            anchors.fill: parent
            anchors.margins: 22
            spacing: 18

            // ── 左侧文件列表 ──
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 10
                color: "#18181e"
                border.color: "#2c2c34"; border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    // 顶部栏
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Text {
                            text: "文件列表"
                            color: "#e8e8ec"; font.pixelSize: 15; font.bold: true
                        }
                        Text {
                            text: "· " + yuvSetupView.fileList.length + " 个"
                            color: "#9aa0a6"; font.pixelSize: 12
                        }
                        Item { Layout.fillWidth: true }

                        // ── 排序下拉按钮：默认 / 升序 / 降序 三选一 ──
                        // 按钮宽高固定（implicitWidth:76），不跟随 label 内容浮动，
                        // 切换排序模式时按钮位置/尺寸绝对稳定。
                        // 浮层 sortMenu 放在卡片顶层（见下方 sortMenuLayer），与 ListView 同父，
                        // z 直接可比，避免被列表的 hover 高亮遮挡。
                        Item {
                            id: sortBtn
                            implicitWidth: 76
                            implicitHeight: 28
                            Layout.preferredWidth: implicitWidth
                            Layout.preferredHeight: implicitHeight

                            Rectangle {
                                id: sortTrigger
                                anchors.fill: parent
                                radius: 6
                                color: (sortMa.containsMouse || sortMenu.visible)
                                       ? "#2a2a34" : "#1e1e24"
                                border.color: (sortMa.containsMouse || sortMenu.visible)
                                              ? "#4a4a56" : "#3a3a44"
                                border.width: 1
                                Row {
                                    anchors.centerIn: parent
                                    spacing: 4
                                    Text {
                                        id: sortLbl
                                        text: yuvSetupView.sortLabel
                                        color: "#e8e8ec"; font.pixelSize: 12
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "▾"; color: "#9aa0a6"; font.pixelSize: 10
                                    }
                                }
                                MouseArea {
                                    id: sortMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        // mapToItem() 内部读取的祖先 x/y 不会被 QML 绑定依赖
                                        // 追踪到，声明式绑定在布局未稳定前算出的坐标不会再更新。
                                        // 因此改为每次“打开”时命令式重新计算一次（此时布局已稳定）。
                                        if (!sortMenu.visible) {
                                            const pt = sortTrigger.mapToItem(sortMenuLayer,
                                                sortTrigger.width / 2, sortTrigger.height)
                                            sortMenu.x = pt.x - sortMenu.width / 2
                                            sortMenu.y = pt.y + 4
                                        }
                                        sortMenu.visible = !sortMenu.visible
                                    }
                                }
                            }
                        }

                        Rectangle {
                            width: 76; height: 28; radius: 6
                            color: yuvAddMoreMa.containsMouse ? "#2a2a34" : "#1e1e24"
                            border.color: yuvAddMoreMa.containsMouse ? "#4a4a56" : "#3a3a44"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: "+ 添加"; color: "#e8e8ec"; font.pixelSize: 12
                            }
                            MouseArea {
                                id: yuvAddMoreMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: yuvView.openFileDialog()
                            }
                        }
                        Rectangle {
                            width: 84; height: 28; radius: 6
                            color: yuvAddFolderMa.containsMouse ? "#2a2a34" : "#1e1e24"
                            border.color: yuvAddFolderMa.containsMouse ? "#4a4a56" : "#3a3a44"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: "+ 文件夹"; color: "#e8e8ec"; font.pixelSize: 12
                            }
                            MouseArea {
                                id: yuvAddFolderMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: yuvView.openFolderDialog()
                            }
                        }
                        Rectangle {
                            width: 64; height: 28; radius: 6
                            color: yuvClearMa.containsMouse ? "#5a3a3a" : "#3a2a2a"
                            Text {
                                anchors.centerIn: parent
                                text: "清空"; color: "#f5a3a3"; font.pixelSize: 12
                            }
                            MouseArea {
                                id: yuvClearMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    yuvSetupView.fileList = []
                                    yuvSetupView.selectedIndex = -1
                                }
                            }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: "#2c2c34" }

                    // ── 列表区：空时显示提示 + 添加按钮；有文件时显示 ListView ──
                    Item {
                        Layout.fillWidth: true; Layout.fillHeight: true

                        // 空状态：居中提示 + 添加按钮
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 14
                            visible: yuvSetupView.fileList.length === 0
                            Canvas {
                                Layout.alignment: Qt.AlignHCenter
                                width: 40; height: 40
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.reset()
                                    ctx.lineWidth = 1.8
                                    ctx.strokeStyle = "#5a5a68"
                                    ctx.fillStyle = "#2a2a34"
                                    ctx.lineJoin = "round"
                                    // 文件夹主体
                                    ctx.beginPath()
                                    ctx.moveTo(4, 12)
                                    ctx.lineTo(4, 34)
                                    ctx.lineTo(36, 34)
                                    ctx.lineTo(36, 12)
                                    ctx.lineTo(22, 12)
                                    ctx.lineTo(19, 8)
                                    ctx.lineTo(4, 8)
                                    ctx.closePath()
                                    ctx.fill()
                                    ctx.stroke()
                                    // 文件夹翻盖
                                    ctx.beginPath()
                                    ctx.moveTo(4, 16)
                                    ctx.lineTo(36, 16)
                                    ctx.stroke()
                                }
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "列表为空"
                                color: "#9aa0a6"; font.pixelSize: 13
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: "点击下方按钮添加文件或文件夹"
                                color: "#6a6a78"; font.pixelSize: 11
                            }
                            RowLayout {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.topMargin: 4
                                spacing: 10
                                Rectangle {
                                    Layout.preferredWidth: 120; Layout.preferredHeight: 32
                                    radius: 6
                                    color: yuvEmptyFileMa.containsMouse ? "#2a2a34" : "#1e1e24"
                                    border.color: yuvEmptyFileMa.containsMouse ? "#4a4a56" : "#3a3a44"
                                    border.width: 1
                                    Text {
                                        anchors.centerIn: parent
                                        text: "+ 添加文件"; color: "#e8e8ec"; font.pixelSize: 12
                                    }
                                    MouseArea {
                                        id: yuvEmptyFileMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: yuvView.openFileDialog()
                                    }
                                }
                                Rectangle {
                                    Layout.preferredWidth: 120; Layout.preferredHeight: 32
                                    radius: 6
                                    color: yuvEmptyFolderMa.containsMouse ? "#2a2a34" : "#1e1e24"
                                    border.color: yuvEmptyFolderMa.containsMouse ? "#4a4a56" : "#3a3a44"
                                    border.width: 1
                                    Text {
                                        anchors.centerIn: parent
                                        text: "+ 文件夹"; color: "#e8e8ec"; font.pixelSize: 12
                                    }
                                    MouseArea {
                                        id: yuvEmptyFolderMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: yuvView.openFolderDialog()
                                    }
                                }
                            }
                        }

                        // 有文件时：ListView，每项支持单独删除
                        // model 走 sortedFileList，按 sortMode（添加顺序 / A→Z / Z→A）实时排序；
                        // delegate 内通过 modelData 反查 fileList 中的真实索引，
                        // 保证 selectedIndex / 删除等操作始终指向源数组的正确位置。
                        ListView {
                            anchors.fill: parent
                            anchors.margins: 4
                            visible: yuvSetupView.fileList.length > 0
                            clip: true; spacing: 4
                            model: yuvSetupView.sortedFileList
                            delegate: Rectangle {
                                required property string modelData
                                required property int index
                                readonly property int srcIndex: yuvSetupView._indexInFileList(modelData)
                                width: ListView.view.width; height: 48
                                radius: 6
                                color: yuvSetupView.selectedIndex === srcIndex
                                       ? "#2a2a32"
                                       : (fileItemMa.containsMouse ? "#22222a" : "transparent")
                                border.color: yuvSetupView.selectedIndex === srcIndex
                                              ? "#4a4a56"
                                              : (fileItemMa.containsMouse ? "#2c2c34" : "transparent")
                                border.width: 1

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12; anchors.rightMargin: 4
                                    spacing: 10
                                    // 勾选 checkbox（独立于选中，最多勾选 3 个）
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 18; height: 18; radius: 4
                                        color: (yuvSetupView.checkedList.indexOf(modelData) >= 0)
                                               ? "#3a6fd8" : "#1e1e24"
                                        border.color: (yuvSetupView.checkedList.indexOf(modelData) >= 0)
                                                      ? "#4a7cf0" : "#3a3a44"
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: (yuvSetupView.checkedList.indexOf(modelData) >= 0)
                                                  ? "✓" : ""
                                            color: "#fff"; font.pixelSize: 12; font.bold: true
                                        }
                                    }
                                    Canvas {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 20; height: 20
                                        onPaint: {
                                            var ctx = getContext("2d")
                                            ctx.reset()
                                            ctx.lineWidth = 1.4
                                            ctx.strokeStyle = "#6a7a90"
                                            ctx.fillStyle = "#6a7a90"
                                            ctx.lineJoin = "round"
                                            // 胶片帧
                                            ctx.strokeRect(3, 3, 14, 14)
                                            // 齿孔
                                            ctx.fillRect(4.5, 3, 1.5, 2)
                                            ctx.fillRect(8, 3, 1.5, 2)
                                            ctx.fillRect(11.5, 3, 1.5, 2)
                                            ctx.fillRect(4.5, 15, 1.5, 2)
                                            ctx.fillRect(8, 15, 1.5, 2)
                                            ctx.fillRect(11.5, 15, 1.5, 2)
                                            // 内画面
                                            ctx.strokeRect(5.5, 6.5, 9, 7)
                                        }
                                    }
                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        Text {
                                            text: yuvView.fileBasename(modelData)
                                            color: "#e8e8ec"; font.pixelSize: 13
                                            font.bold: yuvSetupView.selectedIndex === srcIndex
                                        }
                                        Text {
                                            text: modelData
                                            color: "#6a6a78"; font.pixelSize: 10
                                            elide: Text.ElideMiddle
                                            width: ListView.view.width - 110
                                        }
                                    }
                                    // 每项右侧 × 删除按钮
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 22; height: 22; radius: 11
                                        visible: fileItemMa.containsMouse || yuvSetupView.selectedIndex === srcIndex
                                        color: fileItemDelMa.containsMouse ? "#b85a5a" : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "×"; color: "#f5a3a3"; font.pixelSize: 14; font.bold: true
                                        }
                                    }
                                }
                                MouseArea {
                                    id: fileItemMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: yuvSetupView.selectedIndex = srcIndex
                                }
                                // checkbox 勾选的 hit zone：声明在 fileItemMa 之后（z 更高），
                                // 定位到 checkbox 位置，避免被 fileItemMa 拦截点击。
                                MouseArea {
                                    id: fileCheckMa
                                    anchors.left: parent.left
                                    anchors.leftMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 18; height: 18
                                    z: 1
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const arr = yuvSetupView.checkedList.slice()
                                        const pos = arr.indexOf(modelData)
                                        if (pos >= 0) {
                                            arr.splice(pos, 1)
                                        } else {
                                            if (arr.length >= 9) {
                                                yuvSetupView.selectedIndex = srcIndex
                                                yuvSetupStatus.text = "最多同时渲染 9 个 YUV"
                                                return
                                            }
                                            arr.push(modelData)
                                            // 勾选时同步点选，让右侧参数栏显示
                                            yuvSetupView.selectedIndex = srcIndex
                                        }
                                        yuvSetupView.checkedList = arr
                                    }
                                }
                                // × 删除按钮的 hit zone（不冒泡到 fileItemMa）
                                MouseArea {
                                    id: fileItemDelMa
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 30; height: 30
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    visible: fileItemMa.containsMouse || yuvSetupView.selectedIndex === srcIndex
                                    propagateComposedEvents: false
                                    onClicked: {
                                        const arr = yuvSetupView.fileList.slice()
                                        // 用 srcIndex 删除 fileList 中的真实条目，
                                        // 避免排序后 ListView.index 与 fileList 索引错位。
                                        if (srcIndex >= 0 && srcIndex < arr.length) arr.splice(srcIndex, 1)
                                        yuvSetupView.fileList = arr
                                        // 选中索引修正：指向与被删项相同路径（若仍存在）的位置，
                                        // 否则回退到末尾。
                                        let newSel = -1
                                        if (srcIndex >= 0 && srcIndex < arr.length) newSel = srcIndex
                                        else if (arr.length > 0) newSel = arr.length - 1
                                        yuvSetupView.selectedIndex = newSel
                                    }
                                }
                            }
                        }
                    }
                }

                // ── 排序下拉浮层 + 点击外部关闭：放在 ColumnLayout 之后、DropArea 之前，
                //    作为卡片顶层节点（与 ListView 同祖父），绘制顺序由 z:30 保证在最上层，
                //    不会被列表 hover 高亮（任何 z:0 的兄弟）遮挡。─────────────
                // 位置：sortTrigger 在 RowLayout 内 sortBtn 内，用 sortTrigger.mapToItem
                //      算其在卡片坐标系的位置；sortMenuLayer 始终 enabled 让绑定稳定。
                Item {
                    id: sortMenuLayer
                    // 显式 width/height 而非 anchors.fill：保证子项 mapToItem 坐标系建立，
                    // 即使父是 Layout-managed Item 也能正确返回坐标。
                    anchors.left: parent.left
                    anchors.top: parent.top
                    width: parent.width
                    height: parent.height

                    // 下拉浮层：相对 sortTrigger 底边居中定位（卡片坐标系）。
                    // x/y 不用声明式绑定（mapToItem 内部读取的祖先几何不会被
                    // QML 绑定依赖追踪到，会导致布局变化后位置卡死不更新），
                    // 而是在 sortMa.onClicked 打开时命令式赋值一次。
                    Rectangle {
                        id: sortMenu
                        visible: false
                        width: 110
                        // 显式高度 = Column 内容高度 + 上下 margin；不用 anchors.fill 让
                        // Column 撑满 parent（那样会与下面这行反向循环绑定，退化成 0 高度，
                        // 只是没裁剪所以文字仍能画出来，背板却消失/错位）。
                        height: sortMenuCol.height + 8
                        x: 0
                        y: 0
                        radius: 6
                        color: "#1a1a22"
                        border.color: "#3a3a44"; border.width: 1
                        z: 30

                        Column {
                            id: sortMenuCol
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 4
                            spacing: 2
                            Repeater {
                                model: yuvSetupView.sortOptions
                                delegate: Rectangle {
                                    required property var modelData
                                    required property int index
                                    width: parent.width; height: 26; radius: 4
                                    color: (sortItemMa.containsMouse || yuvSetupView.sortMode === index)
                                           ? "#2a3a55" : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        color: (yuvSetupView.sortMode === index)
                                               ? "#ffffff" : "#c8c8d0"
                                        font.pixelSize: 12
                                        font.bold: yuvSetupView.sortMode === index
                                    }
                                    MouseArea {
                                        id: sortItemMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            yuvSetupView.sortMode = index
                                            sortMenu.visible = false
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 点击浮层外关闭：覆盖整张卡片的透明 MouseArea。
                    // sortMenu 自身（z:30）之上的点击由它自己处理；其他区域的点击
                    // 冒泡到这里 → 关闭浮层。propagateComposedEvents 让下方按钮
                    //（添加/清空/列表行等）在浮层打开时仍可点击。
                    // hoverEnabled 在菜单打开时同步开启：拦住下方列表行的 hover
                    // 悬浮事件（不接管就会穿透到 ListView delegate，导致鼠标划过
                    // 下拉菜单时，被遮住的列表行 hover 高亮/删除按钮一闪一闪）。
                    MouseArea {
                        anchors.fill: parent
                        z: 29
                        enabled: sortMenu.visible
                        hoverEnabled: sortMenu.visible
                        propagateComposedEvents: true
                        preventStealing: false
                        onPressed: function(mouse) {
                            // 点在 sortTrigger 范围内 → 不关闭，让 sortBtn 自己切换
                            const local = sortTrigger.mapFromItem(sortMenuLayer, mouse.x, mouse.y)
                            const inBtn = local.x >= 0 && local.x <= sortTrigger.width
                                          && local.y >= 0 && local.y <= sortTrigger.height
                            if (!inBtn) sortMenu.visible = false
                        }
                    }
                }

                // ── 拖拽接收：整个列表区域支持拖入文件 / 文件夹 ──
                // 覆盖整个文件列表 Rectangle；散文件按 .yuv/.y4m 过滤，
                // 文件夹用 Fs.scanVideoFolder 递归展开（白名单含 yuv/y4m）。
                DropArea {
                    anchors.fill: parent
                    onEntered: function(drag) {
                        if (!drag.hasUrls) { drag.accepted = false; return }
                        drag.accept(Qt.CopyAction)
                    }
                    onDropped: function(drop) {
                        if (!drop.hasUrls) return
                        const newFiles = []
                        for (let i = 0; i < drop.urls.length; ++i) {
                            const u = drop.urls[i]
                            const s = String(u).toLowerCase()
                            // 文件夹优先：能扫出 .yuv/.y4m 即按文件夹展开
                            let scanned = []
                            try { scanned = Fs.scanVideoFolder(u, true) || [] } catch (e) { scanned = [] }
                            if (scanned.length > 0) {
                                for (let j = 0; j < scanned.length; ++j) newFiles.push(scanned[j])
                            } else if (s.endsWith(".yuv") || s.endsWith(".y4m")) {
                                newFiles.push(yuvView.normalizeFilePath(u))
                            }
                        }
                        if (newFiles.length === 0) return
                        const merged = yuvSetupView.fileList.slice()
                        for (let i = 0; i < newFiles.length; ++i) {
                            if (merged.indexOf(newFiles[i]) < 0) merged.push(newFiles[i])
                        }
                        yuvSetupView.fileList = merged
                        yuvSetupView.selectedIndex = merged.length - newFiles.length
                        yuvSetupStatus.text = ""
                    }
                }
            }

            // ── 右侧参数栏（始终显示，无选中文件时显示占位）──
            Rectangle {
                Layout.preferredWidth: 320
                Layout.fillHeight: true
                radius: 10
                color: "#18181e"
                border.color: "#2c2c34"; border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 14

                    Text {
                        visible: yuvSetupView.selectedIndex >= 0
                        text: "参数设置"
                        color: "#e8e8ec"; font.pixelSize: 15; font.bold: true
                    }

                    // 无选中文件时的占位
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: yuvSetupView.selectedIndex < 0
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 12
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: yuvSetupView.fileList.length === 0
                                      ? "请先添加文件"
                                      : "在左侧选择文件后可调整参数"
                                color: "#6a6a78"; font.pixelSize: 13
                            }
                        }
                    }

                    // 选中文件名（仅选中时显示）
                    Rectangle {
                        visible: yuvSetupView.selectedIndex >= 0
                        Layout.fillWidth: true; height: 32; radius: 6
                        color: "#14141a"; border.color: "#3a3a44"; border.width: 1
                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 10; anchors.rightMargin: 10
                            verticalAlignment: Text.AlignVCenter
                            text: yuvSetupView.selectedIndex >= 0
                                  ? yuvSetupView.fileList[yuvSetupView.selectedIndex]
                                  : ""
                            color: "#e8e8ec"; font.pixelSize: 12
                            elide: Text.ElideMiddle
                        }
                    }

                    // ══════ 尺寸预设下拉（内置 + 用户，可保存/删除）══════
                    ColumnLayout {
                        visible: yuvSetupView.selectedIndex >= 0
                        Layout.fillWidth: true; spacing: 4
                        Text { text: "尺寸预设"; color: "#9aa0a6"; font.pixelSize: 11 }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            ComboBox {
                                id: yuvSizeCombo
                                Layout.fillWidth: true; Layout.preferredHeight: 34
                                textRole: "label"
                                function rebuild() {
                                    // 内置项已不再含"自定义"占位。找不到匹配时 currentIndex = -1，
                                    // contentItem 会回退显示当前手输的 "宽×高" 字符串。
                                    const builtin = [
                                        {label: "480p (720×480 NTSC)", w: 720,  h: 480,  builtin: true},
                                        {label: "576p (720×576 PAL)",  w: 720,  h: 576,  builtin: true},
                                        {label: "720p (1280×720)",     w: 1280, h: 720,  builtin: true},
                                        {label: "1080p (1920×1080)",   w: 1920, h: 1080, builtin: true},
                                        {label: "4K (3840×2160)",      w: 3840, h: 2160, builtin: true}
                                    ]
                                    const user = []
                                    const ss = YuvBridge.yuvSizePresets()
                                    for (let i = 0; i < ss.length; ++i) {
                                        const p = ss[i].split('x')
                                        user.push({
                                            label: ss[i],
                                            w: parseInt(p[0]) || 0,
                                            h: parseInt(p[1]) || 0,
                                            builtin: false,
                                            key: ss[i]
                                        })
                                    }
                                    model = builtin.concat(user)
                                    // 同步选中：如果手输宽高匹配某项，自动指向它；否则 -1（无匹配）
                                    const cw = parseInt(yuvSetupW.text) || 0
                                    const ch = parseInt(yuvSetupH.text) || 0
                                    let found = -1
                                    for (let i = 0; i < model.length; ++i) {
                                        if (model[i].w === cw && model[i].h === ch) { found = i; break }
                                    }
                                    currentIndex = found
                                }
                                Component.onCompleted: rebuild()
                                Connections {
                                    target: YuvBridge
                                    function onYuvPresetsChanged() { yuvSizeCombo.rebuild() }
                                }
                                onActivated: {
                                    const it = model[currentIndex]
                                    if (it && it.w > 0 && it.h > 0) {
                                        yuvSetupW.text = it.w.toString()
                                        yuvSetupH.text = it.h.toString()
                                    }
                                }
                                background: Rectangle { color: "#14141a"; radius: 6; border.color: "#3a3a44"; border.width: 1 }
                                contentItem: Text {
                                    // 选中时显示下拉项的 label；无匹配（currentIndex = -1）时回退显示
                                    // 当前手输宽高（例如 "1920×1080"），让用户清楚看到当前值。
                                    text: (yuvSizeCombo.currentIndex >= 0 && yuvSizeCombo.model[yuvSizeCombo.currentIndex]
                                          ? yuvSizeCombo.model[yuvSizeCombo.currentIndex].label
                                          : ((parseInt(yuvSetupW.text) || 0) + "×" + (parseInt(yuvSetupH.text) || 0)))
                                    color: "#e8e8ec"; font.pixelSize: 13
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: 10
                                }
                                popup: Popup {
                                    id: yuvSizePopup
                                    y: yuvSizeCombo.height; width: yuvSizeCombo.width; padding: 2
                                    background: Rectangle { color: "#14141a"; radius: 6; border.color: "#3a3a44"; border.width: 1 }
                                    contentItem: ListView {
                                        clip: true
                                        implicitHeight: Math.min(contentHeight, 280)
                                        model: yuvSizeCombo.model
                                        delegate: Item {
                                            width: yuvSizeCombo.width; height: 30
                                            required property var modelData
                                            required property int index
                                            Rectangle {
                                                anchors.fill: parent
                                                color: yuvSizeRowMa.containsMouse ? "#2a2a32" : "transparent"
                                            }
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 8; anchors.rightMargin: 4
                                                spacing: 4
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.label
                                                    color: "#e8e8ec"; font.pixelSize: 13
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                                Rectangle {
                                                    Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                                    radius: 11
                                                    color: yuvSizeDelMa.containsMouse ? "#b85a5a" : "transparent"
                                                    visible: !modelData.builtin
                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: "×"; color: "#f5a3a3"; font.pixelSize: 14; font.bold: true
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                id: yuvSizeRowMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    yuvSizeCombo.currentIndex = index
                                                    yuvSizeCombo.activated(index)
                                                    yuvSizePopup.close()
                                                }
                                            }
                                            MouseArea {
                                                id: yuvSizeDelMa
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 28; height: 28
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                visible: !modelData.builtin
                                                propagateComposedEvents: false
                                                onClicked: YuvBridge.removeYuvSizePreset(modelData.key)
                                            }
                                        }
                                    }
                                }
                            }
                            Rectangle {
                                width: 64; height: 34; radius: 6
                                color: yuvSizeSaveMa.containsMouse ? "#2a2a34" : "#1e1e24"
                                border.color: yuvSizeSaveMa.containsMouse ? "#4a4a56" : "#3a3a44"
                                border.width: 1
                                Text {
                                    anchors.centerIn: parent
                                    text: "+ 保存"; color: "#cfd2d6"; font.pixelSize: 12
                                }
                                MouseArea {
                                    id: yuvSizeSaveMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const w = parseInt(yuvSetupW.text) || 0
                                        const h = parseInt(yuvSetupH.text) || 0
                                        if (w > 0 && h > 0) {
                                            const key = w + "x" + h
                                            YuvBridge.addYuvSizePreset(key)
                                            yuvSizeCombo.rebuild()
                                            // 保存后下拉指向新建的用户项（user 在 builtin 之后），
                                            // 而不是回到 "自定义"。
                                            for (let i = 0; i < yuvSizeCombo.model.length; ++i) {
                                                if (yuvSizeCombo.model[i].key === key) {
                                                    yuvSizeCombo.currentIndex = i
                                                    break
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 宽 / 高（手输，与预设下拉双向）
                    RowLayout {
                        visible: yuvSetupView.selectedIndex >= 0
                        Layout.fillWidth: true; spacing: 10
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            Text { text: "宽"; color: "#9aa0a6"; font.pixelSize: 11 }
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 34; radius: 6
                                color: "#14141a"; border.color: "#3a3a44"; border.width: 1
                                TextInput {
                                    id: yuvSetupW
                                    anchors.fill: parent; anchors.margins: 6
                                    color: "#e8e8ec"; font.pixelSize: 13
                                    text: "1920"
                                    horizontalAlignment: TextInput.AlignHCenter
                                    validator: IntValidator { bottom: 1; top: 16384 }
                                    onTextChanged: yuvSetupView.saveCurrentParams()
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            Text { text: "高"; color: "#9aa0a6"; font.pixelSize: 11 }
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 34; radius: 6
                                color: "#14141a"; border.color: "#3a3a44"; border.width: 1
                                TextInput {
                                    id: yuvSetupH
                                    anchors.fill: parent; anchors.margins: 6
                                    color: "#e8e8ec"; font.pixelSize: 13
                                    text: "1080"
                                    horizontalAlignment: TextInput.AlignHCenter
                                    validator: IntValidator { bottom: 1; top: 16384 }
                                    onTextChanged: yuvSetupView.saveCurrentParams()
                                }
                            }
                        }
                    }

                    // ══════ 像素格式下拉（内置 + 用户，可保存/删除）══════
                    ColumnLayout {
                        visible: yuvSetupView.selectedIndex >= 0
                        Layout.fillWidth: true; spacing: 4
                        Text { text: "像素格式"; color: "#9aa0a6"; font.pixelSize: 11 }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            ComboBox {
                                id: yuvFmtCombo
                                Layout.fillWidth: true; Layout.preferredHeight: 34
                                textRole: "label"
                                function rebuild() {
                                    const builtin = [
                                        {label: "yuv400 (灰度)",       fmt: "yuv400", builtin: true},
                                        {label: "yuv420p (I420)",        fmt: "yuv420p", builtin: true},
                                        {label: "yuv422p (I422)",        fmt: "yuv422p", builtin: true},
                                        {label: "yuv440p",               fmt: "yuv440p", builtin: true},
                                        {label: "yuv444p (I444)",        fmt: "yuv444p", builtin: true},
                                        {label: "yuvj420p (JPEG)",       fmt: "yuvj420p", builtin: true},
                                        {label: "yuvj422p (JPEG)",       fmt: "yuvj422p", builtin: true},
                                        {label: "yuvj444p (JPEG)",       fmt: "yuvj444p", builtin: true},
                                        {label: "nv12 (semi-planar 420)", fmt: "nv12", builtin: true},
                                        {label: "nv21 (semi-planar 420)", fmt: "nv21", builtin: true},
                                        {label: "nv16 (semi-planar 422)", fmt: "nv16", builtin: true},
                                        {label: "nv24 (semi-planar 444)", fmt: "nv24", builtin: true},
                                        {label: "yuyv422 (packed)",      fmt: "yuyv422", builtin: true},
                                        {label: "uyvy422 (packed)",      fmt: "uyvy422", builtin: true}
                                    ]
                                    const user = []
                                    const fs = YuvBridge.yuvFormatPresets()
                                    for (let i = 0; i < fs.length; ++i) {
                                        user.push({label: fs[i], fmt: fs[i], builtin: false, key: fs[i]})
                                    }
                                    model = builtin.concat(user)
                                }
                                Component.onCompleted: {
                                    rebuild()
                                    // 默认选中 yuv420p（I420，最常用）
                                    for (let i = 0; i < model.length; ++i) {
                                        if (model[i].fmt === "yuv420p") { currentIndex = i; break }
                                    }
                                }
                                Connections {
                                    target: YuvBridge
                                    function onYuvPresetsChanged() { yuvFmtCombo.rebuild() }
                                }
                                onActivated: yuvSetupView.saveCurrentParams()
                                background: Rectangle { color: "#14141a"; radius: 6; border.color: "#3a3a44"; border.width: 1 }
                                contentItem: Text {
                                    text: yuvFmtCombo.displayText
                                    color: "#e8e8ec"; font.pixelSize: 13
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: 10
                                }
                                popup: Popup {
                                    id: yuvFmtPopup
                                    y: yuvFmtCombo.height; width: yuvFmtCombo.width; padding: 2
                                    background: Rectangle { color: "#14141a"; radius: 6; border.color: "#3a3a44"; border.width: 1 }
                                    contentItem: ListView {
                                        clip: true
                                        implicitHeight: Math.min(contentHeight, 300)
                                        model: yuvFmtCombo.model
                                        delegate: Item {
                                            width: yuvFmtCombo.width; height: 30
                                            required property var modelData
                                            required property int index
                                            Rectangle {
                                                anchors.fill: parent
                                                color: yuvFmtRowMa.containsMouse ? "#2a2a32" : "transparent"
                                            }
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 8; anchors.rightMargin: 4
                                                spacing: 4
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.label
                                                    color: "#e8e8ec"; font.pixelSize: 13
                                                }
                                                Rectangle {
                                                    Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                                    radius: 11
                                                    color: yuvFmtDelMa.containsMouse ? "#b85a5a" : "transparent"
                                                    visible: !modelData.builtin
                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: "×"; color: "#f5a3a3"; font.pixelSize: 14; font.bold: true
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                id: yuvFmtRowMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    yuvFmtCombo.currentIndex = index
                                                    yuvFmtCombo.activated(index)
                                                    yuvFmtPopup.close()
                                                }
                                            }
                                            MouseArea {
                                                id: yuvFmtDelMa
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 28; height: 28
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                visible: !modelData.builtin
                                                propagateComposedEvents: false
                                                onClicked: YuvBridge.removeYuvFormatPreset(modelData.key)
                                            }
                                        }
                                    }
                                }
                            }
                            Rectangle {
                                width: 64; height: 34; radius: 6
                                color: yuvFmtSaveMa.containsMouse ? "#2a2a34" : "#1e1e24"
                                border.color: yuvFmtSaveMa.containsMouse ? "#4a4a56" : "#3a3a44"
                                border.width: 1
                                Text {
                                    anchors.centerIn: parent
                                    text: "+ 保存"; color: "#cfd2d6"; font.pixelSize: 12
                                }
                                MouseArea {
                                    id: yuvFmtSaveMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (yuvFmtCombo.displayText) {
                                            const key = yuvFmtCombo.displayText.trim().toLowerCase()
                                            if (!key) return
                                            YuvBridge.addYuvFormatPreset(key)
                                            yuvFmtCombo.rebuild()
                                            // 保存后下拉指向新建的用户项
                                            for (let i = 0; i < yuvFmtCombo.model.length; ++i) {
                                                if (yuvFmtCombo.model[i].key === key) {
                                                    yuvFmtCombo.currentIndex = i
                                                    break
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ══════ 帧率下拉（内置 + 用户，可保存/删除）══════
                    ColumnLayout {
                        visible: yuvSetupView.selectedIndex >= 0
                        Layout.fillWidth: true; spacing: 4
                        Text { text: "帧率 (fps)"; color: "#9aa0a6"; font.pixelSize: 11 }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            ComboBox {
                                id: yuvFpsCombo
                                Layout.fillWidth: true; Layout.preferredHeight: 34
                                textRole: "label"
                                function rebuild() {
                                    const builtin = [
                                        {label: "23.976", value: 23.976, builtin: true},
                                        {label: "24",     value: 24,    builtin: true},
                                        {label: "25",     value: 25,    builtin: true},
                                        {label: "29.97",  value: 29.97, builtin: true},
                                        {label: "30",     value: 30,    builtin: true},
                                        {label: "50",     value: 50,    builtin: true},
                                        {label: "59.94",  value: 59.94, builtin: true},
                                        {label: "60",     value: 60,    builtin: true},
                                        {label: "120",    value: 120,   builtin: true}
                                    ]
                                    const user = []
                                    const fs = YuvBridge.yuvFpsPresets()
                                    for (let i = 0; i < fs.length; ++i) {
                                        user.push({
                                            label: fs[i].toString(),
                                            value: fs[i],
                                            builtin: false,
                                            key: fs[i]
                                        })
                                    }
                                    model = builtin.concat(user)
                                }
                                Component.onCompleted: {
                                    rebuild()
                                    // 默认选中 30 fps（最常用）
                                    for (let i = 0; i < model.length; ++i) {
                                        if (model[i].value === 30) { currentIndex = i; break }
                                    }
                                }
                                Connections {
                                    target: YuvBridge
                                    function onYuvPresetsChanged() { yuvFpsCombo.rebuild() }
                                }
                                onActivated: yuvSetupView.saveCurrentParams()
                                background: Rectangle { color: "#14141a"; radius: 6; border.color: "#3a3a44"; border.width: 1 }
                                contentItem: Text {
                                    text: yuvFpsCombo.displayText
                                    color: "#e8e8ec"; font.pixelSize: 13
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: 10
                                }
                                popup: Popup {
                                    id: yuvFpsPopup
                                    y: yuvFpsCombo.height; width: yuvFpsCombo.width; padding: 2
                                    background: Rectangle { color: "#14141a"; radius: 6; border.color: "#3a3a44"; border.width: 1 }
                                    contentItem: ListView {
                                        clip: true
                                        implicitHeight: Math.min(contentHeight, 280)
                                        model: yuvFpsCombo.model
                                        delegate: Item {
                                            width: yuvFpsCombo.width; height: 30
                                            required property var modelData
                                            required property int index
                                            Rectangle {
                                                anchors.fill: parent
                                                color: yuvFpsRowMa.containsMouse ? "#2a2a32" : "transparent"
                                            }
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 8; anchors.rightMargin: 4
                                                spacing: 4
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.label
                                                    color: "#e8e8ec"; font.pixelSize: 13
                                                }
                                                Rectangle {
                                                    Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                                    radius: 11
                                                    color: yuvFpsDelMa.containsMouse ? "#b85a5a" : "transparent"
                                                    visible: !modelData.builtin
                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: "×"; color: "#f5a3a3"; font.pixelSize: 14; font.bold: true
                                                    }
                                                }
                                            }
                                            MouseArea {
                                                id: yuvFpsRowMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    yuvFpsCombo.currentIndex = index
                                                    yuvFpsCombo.activated(index)
                                                    yuvFpsPopup.close()
                                                }
                                            }
                                            MouseArea {
                                                id: yuvFpsDelMa
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 28; height: 28
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                visible: !modelData.builtin
                                                propagateComposedEvents: false
                                                onClicked: YuvBridge.removeYuvFpsPreset(modelData.key)
                                            }
                                        }
                                    }
                                }
                            }
                            Rectangle {
                                width: 64; height: 34; radius: 6
                                color: yuvFpsSaveMa.containsMouse ? "#2a2a34" : "#1e1e24"
                                border.color: yuvFpsSaveMa.containsMouse ? "#4a4a56" : "#3a3a44"
                                border.width: 1
                                Text {
                                    anchors.centerIn: parent
                                    text: "+ 保存"; color: "#cfd2d6"; font.pixelSize: 12
                                }
                                MouseArea {
                                    id: yuvFpsSaveMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const f = parseFloat(yuvFpsCombo.displayText) || 0
                                        if (f > 0) {
                                            YuvBridge.addYuvFpsPreset(f)
                                            yuvFpsCombo.rebuild()
                                            // 保存后下拉指向新建的用户项（user 在 builtin 之后）
                                            for (let i = 0; i < yuvFpsCombo.model.length; ++i) {
                                                if (yuvFpsCombo.model[i].value === f) {
                                                    yuvFpsCombo.currentIndex = i
                                                    break
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ══════ bit 位宽选择 ══════
                    ColumnLayout {
                        visible: yuvSetupView.selectedIndex >= 0
                        Layout.fillWidth: true; spacing: 4
                        Text { text: "位宽 (bit depth)"; color: "#9aa0a6"; font.pixelSize: 11 }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            ComboBox {
                                id: yuvBitDepthCombo
                                Layout.fillWidth: true; Layout.preferredHeight: 34
                                textRole: "label"
                                model: [
                                    {label: "8 bit", value: 8},
                                    {label: "10 bit", value: 10}
                                ]
                                Component.onCompleted: currentIndex = 0
                                onActivated: yuvSetupView.saveCurrentParams()
                                background: Rectangle { color: "#14141a"; radius: 6; border.color: "#3a3a44"; border.width: 1 }
                                contentItem: Text {
                                    text: yuvBitDepthCombo.displayText
                                    color: "#e8e8ec"; font.pixelSize: 13
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: 10
                                }
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }

                    // 状态 + 渲染按钮
                    ColumnLayout {
                        visible: yuvSetupView.selectedIndex >= 0
                        Layout.fillWidth: true; spacing: 8
                        Text {
                            id: yuvSetupStatus
                            color: "#f5a3a3"; font.pixelSize: 11
                            text: ""; Layout.fillWidth: true
                            elide: Text.ElideRight; wrapMode: Text.WordWrap
                        }
                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: 42; radius: 8
                            color: yuvRenderMa.containsMouse ? "#2a2a34" : "#1e1e24"
                            border.color: yuvRenderMa.containsMouse ? "#5a5a66" : "#3a3a44"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: "开始渲染"
                                color: "#e8e8ec"; font.pixelSize: 14; font.bold: true
                            }
                            MouseArea {
                                id: yuvRenderMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (yuvSetupView.checkedList.length === 0) {
                                        yuvSetupStatus.text = "请先勾选要渲染的文件（最多 3 个）"
                                        return
                                    }
                                    // 关键：只把当前 UI 参数写入当前选中文件（currentPath），
                                    // 绝不能覆盖其他勾选文件的持久化参数，否则切换查看时
                                    // 当前 UI 值会把别人冲掉，导致所有文件都用同一个分辨率。
                                    // 其他文件的参数保持各自独立的持久化值，渲染时由
                                    // openFiles 内部按文件读取，互不干扰。
                                    yuvSetupView.saveCurrentParams()

                                    const opened = YuvBridge.openFiles(yuvSetupView.checkedList)
                                    if (opened > 0) {
                                        yuvSetupStatus.text = ""
                                    } else {
                                        yuvSetupStatus.text = "打开失败，请检查路径和参数"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 文件对话框（多选 .yuv / .y4m，按追加方式合并到现有列表）
        // currentFolder 在 open() 时由外部调用者（_openFileDialog）回填上次值，确保
        // "添加文件"按钮首次按下就能跳回上次选的目录，而不是默认根目录。
        FileDialog {
            id: yuvSetupFileDialog
            title: "选择 YUV 文件"
            fileMode: FileDialog.OpenFiles
            nameFilters: [
                "YUV / Y4M 文件 (*.yuv *.y4m)",
                "所有文件 (*)"
            ]
            onAccepted: {
                const newPaths = []
                for (let i = 0; i < selectedFiles.length; ++i) {
                    newPaths.push(yuvView.normalizeFilePath(selectedFiles[i]))
                }
                if (newPaths.length === 0) return
                // 记住首个文件所在目录，下次打开时自动跳回去
                if (newPaths.length > 0) {
                    const firstPath = String(newPaths[0])
                    const sep = Math.max(firstPath.lastIndexOf("/"), firstPath.lastIndexOf("\\"))
                    if (sep > 0) YuvBridge.setLastOpenedFolder(firstPath.substring(0, sep))
                }
                // 追加到现有列表末尾并去重，保留用户原有顺序。
                const merged = yuvSetupView.fileList.slice()
                for (let i = 0; i < newPaths.length; ++i) {
                    if (merged.indexOf(newPaths[i]) < 0) merged.push(newPaths[i])
                }
                yuvSetupView.fileList = merged
                // 选中新追加的第一个，让用户能看到它。
                yuvSetupView.selectedIndex = merged.length - newPaths.length
            }
        }

        // 文件夹对话框（扫描 .yuv / .y4m，按追加方式合并到现有列表）
        // 利用 Fs.scanVideoFolderPath 的白名单（含 yuv / y4m）递归扫描。
        // currentFolder 同样在 open() 时回填上次值。
        FolderDialog {
            id: yuvSetupFolderDialog
            title: "选择 YUV 文件夹"
            onAccepted: {
                const folder = yuvView.normalizeFilePath(selectedFolder)
                YuvBridge.setLastOpenedFolder(folder)
                let found = []
                try { found = Fs.scanVideoFolderPath(folder, true) || [] } catch (e) { found = [] }
                if (found.length === 0) {
                    yuvSetupStatus.text = "未在该文件夹中找到 .yuv / .y4m 文件"
                    return
                }
                const merged = yuvSetupView.fileList.slice()
                for (let i = 0; i < found.length; ++i) {
                    if (merged.indexOf(found[i]) < 0) merged.push(found[i])
                }
                yuvSetupView.fileList = merged
                // 选中新追加的第一个。
                yuvSetupView.selectedIndex = merged.length - found.length
                yuvSetupStatus.text = ""
            }
        }
    }

    // ── 渲染子界面（render） ────────────────────────────────
    Loader {
        id: yuvViewLoader
        anchors.fill: parent
        active: YuvBridge.slotCount > 0
        source: "qrc:/yuv/YuvWindow.qml"
        onLoaded: {
            if (item && item.closeRequested) {
                // 渲染子界面的"← 返回"：关闭全部文件，回到 setup（仍处于 YUV tab）
                item.closeRequested.connect(function() {
                    YuvBridge.closeAll()
                })
            }
        }
    }
}
