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

    // ── 参数输入主界面（setup） ────────────────────────────────
    Item {
        id: yuvSetupView
        // 文件列表（多选文件或文件夹扫描结果）
        property var fileList: []
        property int selectedIndex: -1
        // 勾选要渲染的文件路径（最多 3 个）
        property var checkedList: []
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
            if (yuvFmtCombo && yuvFmtCombo.model && yuvFmtCombo.currentIndex >= 0
                    && yuvFmtCombo.currentIndex < yuvFmtCombo.model.length) {
                return yuvFmtCombo.model[yuvFmtCombo.currentIndex].fmt
            }
            return "yuv420p"
        }

        function saveCurrentParams() {
            if (currentPath === "") return
            const w   = parseInt(yuvSetupW.text) || 1920
            const h   = parseInt(yuvSetupH.text) || 1080
            const fmt = currentFmt()
            const fps = parseFloat(yuvFpsCombo.displayText) || 30.0
            YuvBridge.setYuvFileParams(currentPath, w + "x" + h + "|" + fmt + "|" + fps)
        }

        function loadParamsForCurrent() {
            if (currentPath === "") return
            const params = YuvBridge.yuvFileParams(currentPath)
            if (params && params.length > 0) {
                // 解析 "1920x1080|yuv420p|30"
                const parts = params.split('|')
                const wh = parts[0].split('x')
                if (wh.length === 2) {
                    yuvSetupW.text = wh[0]
                    yuvSetupH.text = wh[1]
                }
                if (parts.length >= 2) {
                    for (let i = 0; i < yuvFmtCombo.model.length; ++i) {
                        if (yuvFmtCombo.model[i].fmt === parts[1]) {
                            yuvFmtCombo.currentIndex = i
                            break
                        }
                    }
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
                // 同步尺寸预设下拉选中
                yuvSizeCombo.rebuild()
            } else {
                // 新文件：默认参数（1920×1080 / yuv420p / 30）
                yuvSetupW.text = "1920"
                yuvSetupH.text = "1080"
                for (let i = 0; i < yuvFmtCombo.model.length; ++i) {
                    if (yuvFmtCombo.model[i].fmt === "yuv420p") { yuvFmtCombo.currentIndex = i; break }
                }
                for (let i = 0; i < yuvFpsCombo.model.length; ++i) {
                    if (yuvFpsCombo.model[i].value === 30) { yuvFpsCombo.currentIndex = i; break }
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
                                onClicked: yuvSetupFileDialog.open()
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
                                onClicked: yuvSetupFolderDialog.open()
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
                                        onClicked: yuvSetupFileDialog.open()
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
                                        onClicked: yuvSetupFolderDialog.open()
                                    }
                                }
                            }
                        }

                        // 有文件时：ListView，每项支持单独删除
                        ListView {
                            anchors.fill: parent
                            anchors.margins: 4
                            visible: yuvSetupView.fileList.length > 0
                            clip: true; spacing: 4
                            model: yuvSetupView.fileList
                            delegate: Rectangle {
                                required property string modelData
                                required property int index
                                width: ListView.view.width; height: 48
                                radius: 6
                                color: yuvSetupView.selectedIndex === index
                                       ? "#2a2a32"
                                       : (fileItemMa.containsMouse ? "#22222a" : "transparent")
                                border.color: yuvSetupView.selectedIndex === index
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
                                            text: modelData.split('/').pop()
                                            color: "#e8e8ec"; font.pixelSize: 13
                                            font.bold: yuvSetupView.selectedIndex === index
                                        }
                                        Text {
                                            text: modelData.substring(0, Math.max(0, modelData.lastIndexOf('/')))
                                            color: "#6a6a78"; font.pixelSize: 10
                                            elide: Text.ElideMiddle
                                            width: ListView.view.width - 110
                                        }
                                    }
                                    // 每项右侧 × 删除按钮
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 22; height: 22; radius: 11
                                        visible: fileItemMa.containsMouse || yuvSetupView.selectedIndex === index
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
                                    onClicked: yuvSetupView.selectedIndex = index
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
                                            if (arr.length >= 3) {
                                                yuvSetupView.selectedIndex = index
                                                yuvSetupStatus.text = "最多同时渲染 3 个 YUV"
                                                return
                                            }
                                            arr.push(modelData)
                                            // 勾选时同步点选，让右侧参数栏显示
                                            yuvSetupView.selectedIndex = index
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
                                    visible: fileItemMa.containsMouse || yuvSetupView.selectedIndex === index
                                    propagateComposedEvents: false
                                    onClicked: {
                                        const arr = yuvSetupView.fileList.slice()
                                        arr.splice(index, 1)
                                        yuvSetupView.fileList = arr
                                        // 选中索引修正：删掉后保持选中不变，或取消选中
                                        if (yuvSetupView.selectedIndex >= arr.length) {
                                            yuvSetupView.selectedIndex = arr.length - 1
                                        }
                                    }
                                }
                            }
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
                                newFiles.push(String(u).replace("file://", ""))
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
                                  ? yuvSetupView.fileList[yuvSetupView.selectedIndex].split('/').pop()
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
                    newPaths.push(selectedFiles[i].toString().replace("file://", ""))
                }
                if (newPaths.length === 0) return
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
        FolderDialog {
            id: yuvSetupFolderDialog
            title: "选择 YUV 文件夹"
            onAccepted: {
                const folder = selectedFolder.toString().replace("file://", "")
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
