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

    Component.onCompleted: {
        // 从 QSettings 恢复上次的码流文件列表（与 YuvBridge 一致）
        const saved = StreamBridge.streamFileList()
        if (saved && saved.length > 0) {
            streamView.pendingFiles = saved
            streamView.pendingSelectedIndex = 0
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
    readonly property bool   slotActive:    StreamBridge.hasFile(effectiveSlot)
    readonly property string slotName:      slotActive ? StreamBridge.fileName(effectiveSlot) : ""
    readonly property var    slotInfo:      slotActive ? StreamBridge.streamInfo(effectiveSlot)
                                                       : ({ width: 0, height: 0, fps: 0,
                                                            codecLong: "", profile: "", level: 0,
                                                            bitrate: 0, fileName: "" })
    readonly property int    slotFrames:    slotActive ? StreamBridge.frameCount(effectiveSlot) : 0
    readonly property int    slotCurrent:   slotActive ? StreamBridge.currentFrame(effectiveSlot) : 0
    readonly property var    slotFrameList: slotActive ? StreamBridge.frameList(effectiveSlot) : []
    readonly property var    slotGopList:   slotActive ? StreamBridge.gopList(effectiveSlot) : []
    readonly property var    slotBlocks:    slotActive ? StreamBridge.blockInfoAt(effectiveSlot, slotCurrent) : []
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

            // 默认排序
            StreamFlatButton {
                text: "默认 ▾"
                enabled: streamView.pendingFiles.length > 0
                onClicked: console.log("[StreamView] 排序待实现（一期仅按添加顺序）")
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

        // ── 主区：左侧文件列表 + 右侧参数预览 ──
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

            // 左：文件列表卡片
            Rectangle {
                Layout.preferredWidth: 520
                Layout.fillHeight: true
                radius: 4
                color: "#16161b"
                border.color: "#2a2e33"; border.width: 1

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
                        height: 32
                        radius: 3
                        color: streamView.pendingSelectedIndex === index
                               ? "#2a3a55" : (rowMa.containsMouse ? "#1e1e24" : "transparent")
                        border.color: streamView.pendingSelectedIndex === index ? "#3a78c8" : "transparent"
                        border.width: 1
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 8
                            Text {
                                text: String.fromCharCode(0x2460 + index)  // ① ② ③ ...
                                color: "#9aa0a6"; font.pixelSize: 11
                                Layout.preferredWidth: 18
                            }
                            Text {
                                text: streamView._fileBasename(modelData)
                                color: "#e8e8ec"; font.pixelSize: 12
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                            }
                            Text {
                                text: streamView._fileDir(modelData)
                                color: "#6a6f76"; font.pixelSize: 10
                                Layout.maximumWidth: 200
                                elide: Text.ElideLeft
                            }
                            // 删除按钮（hover 时显示）
                            Rectangle {
                                visible: rowMa.containsMouse
                                Layout.preferredWidth: 20; Layout.preferredHeight: 20
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
                                        arr.splice(index, 1)
                                        streamView.pendingFiles = arr
                                        if (streamView.pendingSelectedIndex >= arr.length)
                                            streamView.pendingSelectedIndex = arr.length - 1
                                    }
                                }
                            }
                        }
                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: streamView.pendingSelectedIndex = index
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: streamView.pendingFiles.length === 0
                        text: "暂无文件 — 点右上「+ 添加」选择 H.264 / H.265 视频"
                        color: "#6a6f76"; font.pixelSize: 12
                    }
                }
            }

            // 右：参数预览 + 开始按钮
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // 文件未选中时：占位提示
                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 10
                    visible: streamView.pendingFiles.length === 0
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "🎞"
                        font.pixelSize: 56
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "选择 1～3 个码流文件开始分析"
                        color: "#9aa0a6"; font.pixelSize: 13
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "支持 H.264 / H.265 / mp4 / mkv / ts / flv / 裸流"
                        color: "#6a6f76"; font.pixelSize: 11
                    }
                }

                // 文件已选中：显示参数预览
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 12
                    visible: streamView.pendingFiles.length > 0
                              && streamView.pendingSelectedIndex >= 0
                              && streamView.pendingSelectedIndex < streamView.pendingFiles.length

                    Text {
                        text: "参数预览（来自文件）"
                        color: "#bbbbbb"; font.pixelSize: 13; font.bold: true
                    }
                    Text {
                        text: "码流分析无需手动设置参数：宽高 / 帧率 / 编码 / profile / level / 码率"
                              + " 全部从文件头自动解析，点「开始分析」即可。"
                        color: "#6a6f76"; font.pixelSize: 11
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    Text {
                        text: "当前文件：" + (streamView.pendingSelectedIndex >= 0
                              ? streamView._fileBasename(streamView.pendingFiles[streamView.pendingSelectedIndex])
                              : "—")
                        color: "#cccccc"; font.pixelSize: 12
                        font.family: "Monospace"
                    }

                    // 状态文本（错误提示等）
                    Text {
                        text: streamView.pendingStatus
                        color: "#e05050"; font.pixelSize: 11
                        visible: streamView.pendingStatus.length > 0
                    }

                    Item { Layout.fillHeight: true }   // 弹性空白：把开始按钮顶到底

                    // 开始分析按钮
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 220
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
