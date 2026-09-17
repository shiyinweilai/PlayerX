// StreamHierarchyChart.qml — 底部向上展开的参考层级（Hierarchy）面板
//
// 由 StreamView.qml GOP 栏左侧「层级」按钮触发展开（2026-09-16）：
//   · floating=false（挤占）→ host 高度 200，视频上移让位，实底填充
//   · floating=true（悬浮）→ 以 host 底边为基线向上悬浮 200px 半透明浮层
//
// 内容：横轴=显示序（POC 升序，POC 相同按解码序——兼容 265 IDR 重置/回绕）；
//   I/P 锚点沉底，B 帧按参考深度向上分层。节点上方标注显示序帧号（与右侧栏
//   「帧号」同口径，从 1 起）；参考箭头从参考帧指向当前帧：后向（过去）蓝、
//   前向（未来）绿。P 帧链式参考按编码序（解码顺序）取最近前驱 I/P。
//   单击节点=选中并弹出该帧参考关系详情（高亮其参考/被参考箭头）；
//   双击节点=跳转到该帧；拖动=横向滚动；◎ 自动跟随播放。
//
// 性能（2026-09-16 三次修复，265 万帧不卡）：
//   · 参考关系（refs/backRefs）在文件级预计算，O(n) 一次
//   · 画布固定为可视区大小（不随帧数增长，无巨型纹理），按 contentX
//     视口裁剪绘制，每帧重绘成本与文件帧数无关
//   · 帧结构仅文件变化时重算，播放中每帧只做小画布重绘（游标）
//
// 完全独立模块：只依赖 StreamBridge 公开接口。

import QtQuick
import QtQuick.Controls

Item {
    id: chartRoot

    property int slot: 0
    property bool open: false
    property bool floating: false
    // 面板高度（唯一数据源）：顶部把手上下拖拽调整，宿主高度绑定它。
    property int panelHeight: 200
    readonly property int panelMinH: 120
    readonly property int panelMaxH: 640

    signal requestClose()
    signal requestToggleMode()

    // ── 挤占模式容器 ──
    Rectangle {
        id: dockedBox
        visible: chartRoot.open && !chartRoot.floating
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: chartRoot.panelHeight
        color: "#141418"
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: "#2a2e33"
        }
        Loader {
            anchors.fill: parent
            active: chartRoot.open && !chartRoot.floating
            sourceComponent: chartContentComp
        }
    }

    // ── 悬浮模式容器 ──
    Rectangle {
        id: floatBox
        visible: chartRoot.open && chartRoot.floating
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 4
        height: chartRoot.panelHeight
        radius: 8
        color: "#f0121417"
        border.color: "#2a2e33"
        border.width: 1
        Loader {
            anchors.fill: parent
            active: chartRoot.open && chartRoot.floating
            sourceComponent: chartContentComp
        }
    }

    // ── 顶部拖拽把手：上下拖动调整面板高度（120~640），双击复位 200 ──
    // 两种模式共用：把手贴在当前可见容器的顶边（悬浮容器有 12px 侧边距，需内缩）。
    //
    // 关键：拖拽必须用「屏幕全局坐标」计算位移。把手自身会随面板高度移动，
    // 若用 mouse.y（相对把手）算位移，高度变化会反过来改变 mouse.y，形成
    // 正反馈回路 → 面板抖动、指针脱离分界线。改用 mapToGlobal 后，把手移动
    // 被抵消，只有鼠标真实移动才产生位移。
    Rectangle {
        id: resizeHandle
        readonly property bool forFloat: chartRoot.floating
        x: forFloat ? 12 : 0
        width: forFloat ? (chartRoot.width - 24) : chartRoot.width
        height: 10
        y: {
            const box = forFloat ? floatBox : dockedBox
            return box.y - 4
        }
        visible: chartRoot.open
        color: resizeMa.pressed ? "#42A5FF"
                                : (resizeMa.containsMouse ? "#2a3f5a" : "transparent")
        z: 30
        // 拖拽中显示的尺寸提示
        Text {
            anchors.centerIn: parent
            visible: resizeMa.pressed
            text: chartRoot.panelHeight + " px"
            color: "#42A5FF"; font.pixelSize: 8
        }
        MouseArea {
            id: resizeMa
            anchors.fill: parent
            hoverEnabled: true
            // 拖动中即使指针移出把手也保持抓取，避免中途脱手
            preventStealing: true
            cursorShape: pressed ? Qt.SizeVerCursor
                                 : (containsMouse ? Qt.SizeVerCursor : Qt.ArrowCursor)
            property real startGlobalY: 0
            property int startH: 0
            onPressed: {
                startGlobalY = mapToGlobal(mouse.x, mouse.y).y
                startH = chartRoot.panelHeight
                mouse.accepted = true
            }
            onPositionChanged: {
                if (!pressed) return
                // 向上拖动（dy<0）= 变高：面板底边固定，顶边随之上移
                const dy = mapToGlobal(mouse.x, mouse.y).y - startGlobalY
                // 量化到 2px，减少挤占模式下的重排次数（视频区缩放更稳）
                let nh = startH - dy
                nh = Math.round(nh / 2) * 2
                chartRoot.panelHeight = Math.max(chartRoot.panelMinH,
                                                 Math.min(chartRoot.panelMaxH, nh))
            }
            onDoubleClicked: chartRoot.panelHeight = 200
        }
    }

    // 内容组件：两种模式共用
    Component {
        id: chartContentComp
        Item {
            id: chartPanel
            required property int slot
            property int ver: 0          // 帧级：游标刷新
            property int structVer: 0    // 文件级：结构重算
            property bool autoFollow: true
            property int selRank: -1     // 选中节点（显示序 rank）
            property bool detailOn: false // 详情面板是否展开（点帧展开，× 收起）
            property bool detailDocked: true  // 详情面板：true=挤占右侧(等高)，false=悬浮覆盖(等高)
            slot: chartRoot.slot

            // 真实参考结构（C++ 解析 slice 头）是否就绪：就绪则用真实层级/参考，
            // 否则回退位置启发式，保证非 hevc / 解析中也有可用视图。
            readonly property bool refReady: {
                const _ = ver
                return slotActive ? StreamBridge.refStructReady(slot) : false
            }

            Connections {
                target: StreamBridge
                function onCurrentFrameChanged(changedSlot) { chartPanel.ver++ }
                function onFileOpened(openedSlot) {
                    if (openedSlot === chartPanel.slot) { chartPanel.ver++; chartPanel.structVer++ }
                }
                function onFileClosed(closedSlot) {
                    if (closedSlot === chartPanel.slot) { chartPanel.ver++; chartPanel.structVer++ }
                }
                function onSlotCountChanged() { chartPanel.ver++; chartPanel.structVer++ }
                // 参考结构后台解析完成 → 结构重算（切到真实层级）
                function onRefStructReadyChanged(rsSlot) {
                    if (rsSlot === chartPanel.slot) { chartPanel.ver++; chartPanel.structVer++ }
                }
                // 编码序映射就绪：参考结构按解码序存放，需它换算到显示序
                function onFrameOrderMapReadyChanged(omSlot) {
                    if (omSlot === chartPanel.slot) { chartPanel.ver++; chartPanel.structVer++ }
                }
            }

            readonly property bool slotActive: { const _ = ver; return StreamBridge.hasFile(slot) }
            readonly property int curFrame: { const _ = ver; return slotActive ? StreamBridge.currentFrame(slot) : 0 }

            // ── 帧结构缓存（文件级，播放中不重算）──
            property var frameCache: []
            property var rowsData: []     // 显示序数组：{idx,poc,type,sizeBytes,rank,dispNo,decNo,row,depth,refs[]}
            property var rankOfIdx: []    // 解码序 idx → 显示序 rank
            property var backRefs: []     // rank → 参考它的 rank 列表
            property int maxRow: 1
            onSlotActiveChanged: recomputeStructure()
            onStructVerChanged: recomputeStructure()
            Component.onCompleted: {
                if (StreamBridge.hasFile(chartPanel.slot)) recomputeStructure()
            }

            function typeColor(t) {
                if (t === "B") return "#8a9096"
                if (t === "P") return "#3a7adf"
                return "#f0c040"
            }
            // GPB（低延迟 B）：在 B 的灰基础上偏紫，与真 B 区分
            function frameColor(f) {
                if (f && f.isGpb) return "#9b7fd4"
                return typeColor(f ? f.type : "")
            }

            // 结构预计算：O(n log n) 排序 + O(n) 参考关系（含 P 帧编码序前驱）
            function recomputeStructure() {
                const fl = chartPanel.slotActive ? StreamBridge.frameList(chartPanel.slot) : []
                chartPanel.frameCache = fl
                if (!fl || fl.length === 0) {
                    chartPanel.rowsData = []; chartPanel.rankOfIdx = []
                    chartPanel.backRefs = []; chartPanel.maxRow = 1
                    chartPanel.selRank = -1
                    return
                }
                const n = fl.length
                // 1) 编码序预计算：P 在编码序上最近的先前 I/P（I/IDR 无参考）
                const prevIP = new Array(n).fill(-1)
                let lastIP = -1
                for (let i = 0; i < n; ++i) {
                    const t = String(fl[i].type)
                    prevIP[i] = (t === "P") ? lastIP : -1
                    if (t !== "B") lastIP = i
                }
                // 2) 显示序排列：POC 升序，POC 相同按解码序（265 IDR 重置/POC 回绕安全）
                const arr = []
                for (let i = 0; i < n; ++i)
                    arr.push({ idx: i, poc: Number(fl[i].poc), type: String(fl[i].type),
                               sizeBytes: Number(fl[i].sizeBytes) })
                arr.sort(function(a, b) { return (a.poc - b.poc) || (a.idx - b.idx) })
                const rankOfIdx = new Array(n).fill(-1)
                for (let k = 0; k < n; ++k) rankOfIdx[arr[k].idx] = k
                // 3) 显示序下一个锚点 rank（B 的前向锚点，反扫 O(n)）
                const nextAnchor = new Array(n).fill(-1)
                for (let k = n - 1; k >= 0; --k) {
                    nextAnchor[k] = (arr[k].type !== "B") ? k
                                    : ((k + 1 < n) ? nextAnchor[k + 1] : -1)
                }
                // 4) 主遍历：帧号口径 + 参考列表（真实解析优先，否则启发式）
                //    真实数据来自 RBRefStructureParser（slice 头 stRPS），按显示序索引；
                //    未就绪（非 hevc / 解析中 / 映射未就绪）时回退位置启发式。
                const useReal = chartPanel.refReady
                const out = []
                let lastAnchorRank = -1
                let maxDepth = 0
                for (let k = 0; k < n; ++k) {
                    const f = arr[k]
                    f.rank = k
                    f.dispNo = k + 1     // 显示序帧号（右侧栏「帧号」同口径）
                    f.decNo = f.idx + 1  // 解码序（编码顺序）
                    f.refs = []
                    f.keptRefs = []

                    let realLayer = -1
                    if (useReal) realLayer = StreamBridge.frameLayer(chartPanel.slot, k)
                    // GPB：slice_type=B 但参考全在过去（低延迟 B），可即时解码
                    f.isGpb = useReal && f.type === "B"
                               && StreamBridge.frameIsGpb(chartPanel.slot, k)
                    if (f.isGpb) ++chartPanel.gpbSeen

                    if (useReal && realLayer >= 0) {
                        // 真实参考关系（显示序 rank）
                        const rr = StreamBridge.frameRefs(chartPanel.slot, k)
                        for (let q = 0; q < rr.length; ++q) {
                            const rv = Number(rr[q])
                            if (rv >= 0 && rv < n && f.refs.indexOf(rv) < 0) f.refs.push(rv)
                        }
                        // DPB 保留条目（used=0）：本帧不预测，但护送给后续帧
                        f.keptRefs = []
                        const kk = StreamBridge.frameKeptRefs(chartPanel.slot, k)
                        for (let q = 0; q < kk.length; ++q) {
                            const kv = Number(kk[q])
                            if (kv >= 0 && kv < n && kv !== k
                                && f.refs.indexOf(kv) < 0 && f.keptRefs.indexOf(kv) < 0)
                                f.keptRefs.push(kv)
                        }
                        f.depth = realLayer
                        if (f.type !== "B") lastAnchorRank = k
                        if (realLayer > maxDepth) maxDepth = realLayer
                    } else if (f.type !== "B") {
                        lastAnchorRank = k
                        f.depth = 0
                        if (f.type === "P") {
                            const p = prevIP[f.idx]
                            if (p >= 0) f.refs.push(rankOfIdx[p])
                        }
                    } else {
                        const li = lastAnchorRank, ri = nextAnchor[k]
                        if (li >= 0) f.refs.push(li)
                        if (ri >= 0) f.refs.push(ri)
                        let depth = 1
                        if (li >= 0 && ri >= 0) {
                            const span = ri - li
                            const rel = (k - li) / span
                            depth = Math.max(1, Math.min(4, Math.round(Math.abs(rel - 0.5) * 6)))
                        }
                        f.depth = depth
                        if (depth > maxDepth) maxDepth = depth
                    }
                    out.push(f)
                }
                // 5) 行映射：row 越大越靠下（rowY(r)=18+r*rowGap）。
                //    真实模式：layer 0（I/IDR，最重要）沉底 → row = maxLayer - layer。
                //    启发式：锚点沉底，B 越居中越靠顶（保持兼容）。
                const base = Math.max(1, maxDepth)
                for (let k = 0; k < n; ++k) {
                    const f = out[k]
                    if (useReal) {
                        f.row = base - (f.depth >= 0 ? f.depth : 0)
                        if (f.row < 0) f.row = 0
                    } else {
                        f.row = (f.type === "B") ? (base - f.depth) : base
                    }
                }
                // 6) 反向索引：谁参考了我
                const backRefs = []
                for (let k = 0; k < n; ++k) backRefs.push([])
                for (let k = 0; k < n; ++k) {
                    const refs = out[k].refs
                    for (let q = 0; q < refs.length; ++q)
                        if (refs[q] >= 0 && refs[q] < n) backRefs[refs[q]].push(k)
                }
                chartPanel.rowsData = out
                chartPanel.rankOfIdx = rankOfIdx
                chartPanel.backRefs = backRefs
                chartPanel.maxRow = base + 1
                if (chartPanel.selRank >= n) chartPanel.selRank = -1
                hierCanvas.requestPaint()
            }

            // 当前播放帧变化时，若详情面板已展开，则同步选中到该帧（左右键逐帧同样生效）
            onCurFrameChanged: {
                if (!chartPanel.detailOn) return
                const cur = chartPanel.curFrame
                if (!chartPanel.slotActive || cur < 0) return
                if (cur >= chartPanel.rankOfIdx.length) return
                const cr = chartPanel.rankOfIdx[cur]
                if (cr >= 0 && cr !== chartPanel.selRank) chartPanel.selRank = cr
            }

            readonly property var selFrame:
                (selRank >= 0 && selRank < rowsData.length) ? rowsData[selRank] : null
            readonly property var selBackRefs:
                (selFrame !== null && selRank < backRefs.length) ? backRefs[selRank] : []

            // GOP 信息：优先用真实解析（IRAP 边界切分），未就绪时回退预扫描 gopList
            readonly property int  gopSize: {
                const _ = chartPanel.ver
                if (!chartPanel.slotActive) return 0
                const r = StreamBridge.refGopSize(chartPanel.slot)
                if (r > 0) return r
                const gl = StreamBridge.gopList(chartPanel.slot)
                if (!gl || gl.length === 0) return 0
                let best = 0, bestCnt = 0
                const cnt = {}
                for (let i = 0; i < gl.length; ++i) {
                    const n = Number(gl[i].frameCount) || 0
                    cnt[n] = (cnt[n] || 0) + 1
                    if (cnt[n] > bestCnt) { bestCnt = cnt[n]; best = n }
                }
                return best
            }
            readonly property int openGop: {
                const _ = chartPanel.ver
                if (!chartPanel.slotActive) return -1
                if (StreamBridge.refStructReady(chartPanel.slot))
                    return StreamBridge.refOpenGop(chartPanel.slot) ? 1 : 0
                const gl = StreamBridge.gopList(chartPanel.slot)
                if (!gl || gl.length === 0) return -1
                for (let i = 0; i < gl.length; ++i)
                    if (gl[i].isOpenGop) return 1
                return 0
            }
            property int gpbSeen: 0

            // 当前帧所在层级深度（实时随播放/选中变化）
            readonly property int curDepth: {
                const _ = chartPanel.ver
                const r = chartPanel.selRank >= 0 ? chartPanel.selRank
                        : (chartPanel.slotActive ? chartPanel.rankOfIdx[chartPanel.curFrame] : -1)
                if (r === undefined || r === null || r < 0) return -1
                if (r >= chartPanel.rowsData.length) return -1
                const d = chartPanel.rowsData[r].depth
                return (d === undefined || d === null) ? -1 : d
            }
            readonly property bool hasCra: {
                const _ = chartPanel.ver
                return chartPanel.slotActive ? StreamBridge.refHasCra(chartPanel.slot) : false
            }
            // 术语：纯 IDR 时边界是 IDR 间隔，只有出现 CRA 才是严格意义的 GOP
            readonly property string gopLabel: chartPanel.hasCra ? "GOP" : "IDR间隔"
            readonly property int miniGop: {
                const _ = chartPanel.ver
                return chartPanel.slotActive ? StreamBridge.refMiniGop(chartPanel.slot) : 0
            }
            readonly property int gpbCount: {
                const _ = chartPanel.ver
                return chartPanel.slotActive ? StreamBridge.refGpbCount(chartPanel.slot) : 0
            }
            // 帧类型显示：GPB（低延迟 B）单独标注，便于识别可即时解码的帧
            function typeLabel(f) {
                if (!f) return ""
                return (f.isGpb ? "GPB" : f.type)
            }
            readonly property string headerInfo: {
                const _ = chartPanel.ver
                if (!chartPanel.slotActive) return "当前 —"
                let t = "当前 " + (chartPanel.curFrame + 1) + " / " + chartPanel.frameCache.length
                const d = chartPanel.curDepth
                if (d >= 0) t += " · 深度 " + d
                if (chartPanel.gopSize > 0) t += " · " + chartPanel.gopLabel + " " + chartPanel.gopSize
                if (chartPanel.miniGop > 0) t += " / mini " + chartPanel.miniGop
                if (chartPanel.gpbCount > 0) t += " · GPB " + chartPanel.gpbCount
                if (chartPanel.hasCra) {
                    if (chartPanel.openGop === 0) t += " · Closed GOP"
                    else if (chartPanel.openGop === 1) t += " · Open GOP"
                }
                return t
            }

            Column {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6

                // ── 头部 ──
                Item {
                    width: parent.width
                    height: 20
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "参考层级 (Hierarchy)"
                        color: "#bbbbbb"; font.pixelSize: 12; font.bold: true
                    }
                    // 滚动提示：置于标题栏右侧（层级图之上），不再压在画布里
                    Text {
                        id: dragHint
                        anchors.right: headerInfoTxt.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: flick.contentWidth > flick.width ? "拖动查看更多" : ""
                        visible: text !== ""
                        color: "#6a6f76"; font.pixelSize: 9
                    }
                    Text {
                        id: headerInfoTxt
                        anchors.right: followBtn.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: chartPanel.headerInfo
                        color: "#FFC857"; font.pixelSize: 10; font.family: "Monospace"
                    }
                    Rectangle {
                        id: followBtn
                        anchors.right: modeBtn.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 4
                        color: followMa.pressed ? "#2a3f5a" : "#1a1d22"
                        border.color: chartPanel.autoFollow ? "#42A5FF" : "#2a2e33"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent; text: "◎"
                            color: chartPanel.autoFollow ? "#42A5FF" : "#9aa0a6"; font.pixelSize: 12
                        }
                        MouseArea {
                            id: followMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: chartPanel.autoFollow = !chartPanel.autoFollow
                            ToolTip.visible: containsMouse
                            ToolTip.text: chartPanel.autoFollow
                                           ? "跟随开启：播放时自动滚动到当前帧（点击关闭）"
                                           : "跟随已关：手动拖动查看（点击开启）"
                        }
                    }
                    Rectangle {
                        id: modeBtn
                        anchors.right: closeBtn.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 4
                        color: modeMa.pressed ? "#2a3f5a" : "#1a1d22"
                        border.color: "#2a2e33"; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: chartRoot.floating ? "◫" : "▣"
                            color: "#9aa0a6"; font.pixelSize: 12
                        }
                        MouseArea {
                            id: modeMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: chartRoot.requestToggleMode()
                            ToolTip.visible: containsMouse
                            ToolTip.text: chartRoot.floating
                                           ? "切换为挤占模式（视频上移让位）"
                                           : "切换为悬浮模式（浮于画面上层）"
                        }
                    }
                    Rectangle {
                        id: closeBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 4
                        color: closeMa.pressed ? "#2a3f5a" : "#1a1d22"
                        border.color: "#2a2e33"; border.width: 1
                        Text {
                            anchors.centerIn: parent; text: "×"
                            color: "#9aa0a6"; font.pixelSize: 13
                        }
                        MouseArea {
                            id: closeMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: chartRoot.requestClose()
                            ToolTip.visible: containsMouse
                            ToolTip.text: "收起参考层级"
                        }
                    }
                }

                // ── 主体：层级图 + 参考关系面板（两者等高）──
                Item {
                    id: bodyRow
                    width: parent.width
                    height: parent.height - 26
                    // 详情面板宽度：与层级图等高，宽度自适应但不小于 150
                    readonly property real detailW:
                        Math.min(300, Math.max(150, bodyRow.width * 0.34))

                    // 层级图：挤占模式右侧让位（画布随之变窄并重绘），
                    //         悬浮模式占满整宽，详情面板覆盖其上。
                    Item {
                        id: chartBody
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.rightMargin:
                            (chartPanel.detailOn && chartPanel.selFrame !== null && chartPanel.detailDocked)
                            ? (bodyRow.detailW + 6) : 0

                    // 背景垫底（画布保持透明，滚动条在 Flickable 内可见）
                    Rectangle {
                        anchors.fill: parent
                        color: "#0a0a0e"
                        z: 0
                    }

                    Flickable {
                        id: flick
                        anchors.fill: parent
                        z: 2
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.HorizontalFlick
                        readonly property real bodyItemW: {
                            const n = chartPanel.rowsData.length
                            // 最小帧宽 18px：保证 POC 数字（≤2 位）有足够横向空间
                            return n > 0 ? Math.max(18, Math.min(40, flick.width / Math.max(1, n))) : 18
                        }
                        contentWidth: Math.max(width, chartPanel.rowsData.length * bodyItemW)
                        contentHeight: height

                        ScrollBar.horizontal: ScrollBar {
                            parent: flick
                            anchors.left: flick.left
                            anchors.right: flick.right
                            anchors.bottom: flick.bottom
                            policy: ScrollBar.AsNeeded
                        }

                        // 命中层（contentItem 坐标，宽=contentWidth；拖动由 Flickable 抓取）
                        Item {
                            width: flick.contentWidth
                            height: flick.height
                            MouseArea {
                                id: hitMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                function rankAt(mx) {
                                    const n = chartPanel.rowsData.length
                                    if (n === 0) return -1
                                    const r = Math.floor(mx / flick.bodyItemW)
                                    return (r >= 0 && r < n) ? r : -1
                                }
                                // 单击 = 选中 + 展开详情 + 直接跳转（不再需要双击）
                                onClicked: {
                                    const r = rankAt(mouse.x)
                                    if (r < 0) return
                                    if (chartPanel.selRank === r && chartPanel.detailOn) {
                                        chartPanel.detailOn = false
                                        return
                                    }
                                    chartPanel.selRank = r
                                    chartPanel.detailOn = true
                                    StreamBridge.gotoFrame(chartPanel.slot, chartPanel.rowsData[r].idx)
                                }

                            }
                        }
                    }

                    // 画布：固定可视区大小，按 contentX 视口裁剪绘制（265 万帧不卡）
                    Canvas {
                        id: hierCanvas
                        anchors.fill: parent
                        z: 1   // 画布在 Flickable 之下：无输入处理，事件穿透；滚动条可见
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        Connections {
                            target: flick
                            function onContentXChanged() { hierCanvas.requestPaint() }
                        }
                        Connections {
                            target: chartPanel
                            function onHoverRankChanged() { hierCanvas.requestPaint() }
                            function onSelRankChanged() { hierCanvas.requestPaint() }
                        }

                        // 箭头（从参考帧指向当前帧）
                        function drawArrow(ctx, x1, y1, x2, y2, color, lw) {
                            const dx = x2 - x1, dy = y2 - y1
                            const len = Math.sqrt(dx * dx + dy * dy)
                            if (len < 8) return
                            const ux = dx / len, uy = dy / len
                            const hl = Math.min(6, len * 0.4), hw = 3
                            const bx = x2 - ux * hl, by = y2 - uy * hl
                            ctx.strokeStyle = color
                            ctx.lineWidth = lw
                            ctx.beginPath()
                            ctx.moveTo(x1, y1)
                            ctx.lineTo(bx, by)
                            ctx.stroke()
                            ctx.fillStyle = color
                            ctx.beginPath()
                            ctx.moveTo(x2, y2)
                            ctx.lineTo(bx - uy * hw, by + ux * hw)
                            ctx.lineTo(bx + uy * hw, by - ux * hw)
                            ctx.closePath()
                            ctx.fill()
                        }

                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.reset()
                            const w = width, h = height
                            const n = chartPanel.rowsData.length
                            ctx.clearRect(0, 0, w, h)
                            if (n === 0) {
                                ctx.fillStyle = "#6a6f76"
                                ctx.font = "11px sans-serif"
                                ctx.textAlign = "center"
                                ctx.fillText("未加载文件", w / 2, h / 2)
                                return
                            }
                            const rows = chartPanel.rowsData
                            const iw = flick.bodyItemW
                            const cx = flick.contentX
                            const maxR = chartPanel.maxRow
                            // 纵向布局：整体下对齐，层间距自动撑满可用高度。
                            //   顶部 16px 留给 POC 标签，底部 6px 留边距/滚动条；
                            //   每层一个等高 band，方块在 band 内「下对齐」，
                            //   于是最底层（I/IDR）紧贴画布底部，不再留大片空白。
                            const topPad = 16, botPad = 6
                            const usable = Math.max(24, h - topPad - botPad)
                            const rowGap = usable / maxR
                            const bh = Math.max(8, Math.min(18,
                                           rowGap - Math.min(6, rowGap * 0.3)))
                            const rowTop = function(r) {
                                return topPad + r * rowGap + (rowGap - bh)
                            }
                            // 箭头连接点取方块垂直中心（原来是方块顶边，视觉上偏高）
                            const rowY = function(r) { return rowTop(r) + bh / 2 }
                            const xc = function(rank) { return rank * iw - cx + iw / 2 }
                            // 可视范围（前后各 3 帧余量；锚点在窗外时线画向窗外被裁剪）
                            const first = Math.max(0, Math.floor(cx / iw) - 3)
                            const last = Math.min(n - 1, Math.ceil((cx + w) / iw) + 3)
                            const sel = chartPanel.selRank
                            const hasSel = sel >= 0 && sel < n

                            // 1) 参考箭头：严格区分「入边 = 我参考谁」与「出边 = 谁参考我」。
                            //    选中帧自身往往只参考 1~2 帧（入边），但会被多层 B 参考（出边）；
                            //    此前两类线同色叠加，易被误读成「这一帧引用了 6 帧」。
                            //    现在：出边先画（橙色虚线，压底层），入边后画（亮实线，浮上层）。
                            if (hasSel) {
                                for (let r = first; r <= last; ++r) {
                                    const f = rows[r]
                                    if (r === sel) continue
                                    for (let q = 0; q < f.refs.length; ++q) {
                                        const tr = f.refs[q]
                                        if (tr !== sel || tr < 0 || tr >= n) continue
                                        ctx.setLineDash([3, 4])
                                        drawArrow(ctx, xc(tr), rowY(rows[tr].row), xc(r), rowY(f.row),
                                                  "#e0a33e", 1.3)
                                        ctx.setLineDash([])
                                    }
                                }
                            }
                            for (let r = first; r <= last; ++r) {
                                const f = rows[r]
                                for (let q = 0; q < f.refs.length; ++q) {
                                    const tr = f.refs[q]
                                    if (tr < 0 || tr >= n) continue
                                    const isPast = tr < r
                                    const inEdge = hasSel && (r === sel)
                                    if (hasSel && tr === sel && !inEdge) continue   // 出边已画
                                    let col, lw = 1
                                    if (inEdge) {
                                        // 入边配色与右侧「参考」列表逐字一致：
                                        //   后向(←) #7ec8ff 浅蓝 / 前向(→) #8fe6a8 浅绿
                                        lw = 2
                                        col = isPast ? "#7ec8ff" : "#8fe6a8"
                                    } else if (hasSel) {
                                        col = isPast ? "rgba(74,144,217,0.10)" : "rgba(91,191,127,0.10)"
                                    } else {
                                        col = isPast ? "rgba(74,144,217,0.45)" : "rgba(91,191,127,0.45)"
                                    }
                                    drawArrow(ctx, xc(tr), rowY(rows[tr].row), xc(r), rowY(f.row), col, lw)
                                }
                            }

                            // 帧号标签：全部显示（不再依赖 hover）。
                            // 每帧都标 POC（与 VQ 对照口径）；帧宽不足时按步长抽样，
                            // 保证标签间距 ≥ 单个标签宽度，避免数字叠在一起看不清。
                            const fs = iw >= 34 ? 10 : (iw >= 26 ? 9 : 8)
                            // 标签所需最小间距：按最大位数（POC 位数）估算，留 2px 间隙
                            let maxDigits = 1
                            for (let r = first; r <= last; ++r) {
                                const d = String(rows[r].poc).length
                                if (d > maxDigits) maxDigits = d
                            }
                            const needW = maxDigits * fs * 0.62 + 2
                            const step = Math.max(1, Math.ceil(needW / iw))
                            ctx.textAlign = "center"
                            for (let r = first; r <= last; ++r) {
                                const f = rows[r]
                                const c = chartPanel.frameColor(f)
                                const x = r * iw - cx
                                const y = rowTop(f.row)
                                const bw = Math.max(2, iw - 2)
                                ctx.fillStyle = c
                                ctx.fillRect(x, y, bw, bh)
                                // 选中帧/其参考帧：白描边；悬停：灰描边
                                const isSelRef = hasSel && sel < n && rows[sel].refs.indexOf(r) >= 0
                                if (r === sel) {
                                    ctx.strokeStyle = "#ffffff"; ctx.lineWidth = 2
                                    ctx.strokeRect(x - 2, y - 2, bw + 4, bh + 4)
                                } else if (isSelRef) {
                                    ctx.strokeStyle = "#7ec8ff"; ctx.lineWidth = 1.5
                                    ctx.strokeRect(x - 1.5, y - 1.5, bw + 3, bh + 3)
                                }
                                // 帧号：全部帧都标 POC（口径与 VQ 一致），选中帧用高亮色。
                                // step>1 表示帧太密，按步长抽样标注，避免数字重叠。
                                if ((r % step === 0) || r === sel) {
                                    ctx.fillStyle = (r === sel) ? "#ffd76a" : c
                                    ctx.font = fs + "px sans-serif"
                                    ctx.fillText(String(f.poc), x + bw / 2, y - 4)
                                }
                            }

                            // 3) 当前帧游标（rank 口径）
                            const cur = chartPanel.curFrame
                            if (chartPanel.slotActive && cur >= 0 && cur < chartPanel.rankOfIdx.length) {
                                const cr = chartPanel.rankOfIdx[cur]
                                if (cr >= 0) {
                                    const px = xc(cr)
                                    // 虚线竖线：细且淡（仅作位置提示，不抢帧块/箭头视觉），
                                    // 顶部三角游标保持实心亮色，便于一眼定位。
                                    ctx.save()
                                    ctx.setLineDash([3, 4])
                                    ctx.strokeStyle = "rgba(255,255,255,0.34)"
                                    ctx.lineWidth = 1
                                    ctx.beginPath()
                                    ctx.moveTo(px, 0); ctx.lineTo(px, h)
                                    ctx.stroke()
                                    ctx.restore()
                                    ctx.fillStyle = "#ffffff"
                                    ctx.beginPath()
                                    ctx.moveTo(px - 4, 0); ctx.lineTo(px + 4, 0); ctx.lineTo(px, 5)
                                    ctx.closePath(); ctx.fill()
                                }
                            }
                        }
                    }

                    // 自动跟随：帧变化时滚动（用户手动拖动不抢）
                    Connections {
                        target: chartPanel
                        function onVerChanged() {
                            hierCanvas.requestPaint()
                            if (!chartPanel.autoFollow) return
                            const n = chartPanel.rowsData.length
                            const cur = chartPanel.curFrame
                            if (n === 0 || cur < 0 || cur >= chartPanel.rankOfIdx.length) return
                            const cr = chartPanel.rankOfIdx[cur]
                            if (cr < 0) return
                            const iw = flick.bodyItemW
                            const px = cr * iw + iw / 2
                            const viewL = flick.contentX + 40
                            const viewR = flick.contentX + flick.width - 40
                            if (px < viewL || px > viewR)
                                flick.contentX = Math.max(0, Math.min(px - flick.width / 2,
                                                                flick.contentWidth - flick.width))
                        }
                        function onStructVerChanged() { hierCanvas.requestPaint() }
                    }
                }

                // ── 参考关系面板：与层级图等高，贴于右侧 ──
                // detailDocked=true → 挤占（层级图收窄让位）
                // detailDocked=false → 悬浮覆盖在层级图上层
                Rectangle {
                    id: detailPop
                    visible: chartPanel.detailOn && chartPanel.selFrame !== null
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    width: bodyRow.detailW
                    radius: chartPanel.detailDocked ? 0 : 6
                    color: chartPanel.detailDocked ? "#101318" : "#f01a1d24"
                    border.color: "#2a2e33"
                    border.width: 1
                    z: chartPanel.detailDocked ? 5 : 20

                    // 悬浮模式下的投影感（分隔线）
                    Rectangle {
                        visible: chartPanel.detailDocked
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 1
                        color: "#2a2e33"
                    }

                    Flickable {
                        id: detailCol
                        anchors.top: parent.top
                        anchors.topMargin: 8
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 4
                        contentWidth: width
                        contentHeight: detailInner.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick

                        Column {
                            id: detailInner
                            width: detailCol.width
                            spacing: 3

                            // 标题：帧号 + 类型
                    Item {
                        width: parent.width
                        height: 16
                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: chartPanel.selFrame
                                  ? "帧 " + chartPanel.selFrame.dispNo + " · " + chartPanel.typeLabel(chartPanel.selFrame)
                                  : ""
                            color: chartPanel.selFrame ? chartPanel.typeColor(chartPanel.selFrame.type) : "#ffffff"
                            font.pixelSize: 12; font.bold: true
                        }
                        // 停靠/悬浮切换
                        Rectangle {
                            id: dockBtn
                            anchors.right: popClose.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18; radius: 3
                            color: dockMa.pressed ? "#2a3f5a" : "#1a1d22"
                            border.color: "#2a2e33"; border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: chartPanel.detailDocked ? "⇥" : "⇤"
                                color: "#9aa0a6"; font.pixelSize: 11
                            }
                            MouseArea {
                                id: dockMa; anchors.fill: parent
                                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: chartPanel.detailDocked = !chartPanel.detailDocked
                                ToolTip.visible: containsMouse
                                ToolTip.text: chartPanel.detailDocked
                                    ? "当前挤占：层级图收窄让位（点击切悬浮）"
                                    : "当前悬浮：覆盖层级图上层（点击切挤占）"
                            }
                        }
                        Text {
                            id: popClose
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "×"
                            color: "#9aa0a6"; font.pixelSize: 13
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: chartPanel.detailOn = false
                            }
                        }
                    }
                    // 信息：POC / 解码序 / 大小
                    Text {
                        width: parent.width
                        text: chartPanel.selFrame
                              ? "POC " + chartPanel.selFrame.poc
                                + " · 解码序 " + chartPanel.selFrame.decNo
                                + " · " + (chartPanel.selFrame.sizeBytes / 1024).toFixed(1) + " KB"
                              : ""
                        color: "#9aa0a6"; font.pixelSize: 10
                        font.family: "Monospace"
                    }
                    // 层级：真实解析模式下显示码流真实层级（0 最重要，与 VQ 金字塔一致）
                    Text {
                        width: parent.width
                        visible: chartPanel.refReady && chartPanel.selFrame
                        text: chartPanel.selFrame
                              ? "Layer " + chartPanel.selFrame.depth
                                + " · VQ: " + chartPanel.selFrame.decNo + "/" + chartPanel.selFrame.poc
                              : ""
                        color: "#e0c46a"; font.pixelSize: 10
                        font.family: "Monospace"
                    }
                    // 参考列表（该帧参考了谁）
                    Text {
                        text: chartPanel.selFrame
                              ? "参考 (" + chartPanel.selFrame.refs.length + ")"
                              : ""
                        color: "#bbbbbb"; font.pixelSize: 10; font.bold: true
                    }
                    Repeater {
                        model: chartPanel.selFrame ? chartPanel.selFrame.refs : []
                        Text {
                            required property int modelData
                            readonly property var rf: (modelData >= 0 && modelData < chartPanel.rowsData.length)
                                                       ? chartPanel.rowsData[modelData] : null
                            width: detailCol.width
                            text: rf ? (modelData < chartPanel.selRank ? "← " : "→ ")
                                        + "POC " + rf.poc + " · " + chartPanel.typeLabel(rf)
                                    : ""
                            color: (rf && modelData < chartPanel.selRank) ? "#7ec8ff" : "#8fe6a8"
                            font.pixelSize: 10
                            font.family: "Monospace"
                        }
                    }
                    // DPB 保留（RPS 中 used=0）：本帧不用于预测，但要求解码器继续保留，
                    // 供解码序后续的帧使用。不画箭头，仅以暗灰列出以示区分。
                    Text {
                        text: chartPanel.selFrame
                              ? "DPB 保留 (" + chartPanel.selFrame.keptRefs.length + ")"
                              : ""
                        color: "#8a8a8a"; font.pixelSize: 10; font.bold: true
                        visible: chartPanel.selFrame
                                 && chartPanel.selFrame.keptRefs
                                 && chartPanel.selFrame.keptRefs.length > 0
                    }
                    Repeater {
                        model: (chartPanel.selFrame && chartPanel.selFrame.keptRefs)
                               ? chartPanel.selFrame.keptRefs : []
                        Text {
                            required property int modelData
                            readonly property var rf: (modelData >= 0 && modelData < chartPanel.rowsData.length)
                                                       ? chartPanel.rowsData[modelData] : null
                            width: detailCol.width
                            text: rf ? (modelData < chartPanel.selRank ? "· " : "· ")
                                        + "POC " + rf.poc + " · " + chartPanel.typeLabel(rf)
                                    : ""
                            color: "#8a8a8a"; font.pixelSize: 10
                            font.family: "Monospace"
                        }
                    }
                    // 被参考列表（谁参考了该帧，全量，区域可滚动）
                    // 口径：仅统计本 IDR(GOP) 内引用它的帧，不跨 IDR 累积
                    Text {
                        text: "被参考(" + chartPanel.selBackRefs.length + ")·本GOP内"
                        color: "#e0a33e"; font.pixelSize: 10; font.bold: true
                        visible: chartPanel.selBackRefs.length > 0
                    }
                    Repeater {
                        model: chartPanel.selBackRefs
                        Text {
                            required property int modelData
                            readonly property var rf: (modelData >= 0 && modelData < chartPanel.rowsData.length)
                                                       ? chartPanel.rowsData[modelData] : null
                            width: detailInner.width
                            text: rf ? "POC " + rf.poc + " · " + chartPanel.typeLabel(rf) : ""
                            color: "#e0a33e"; font.pixelSize: 10
                            font.family: "Monospace"
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
