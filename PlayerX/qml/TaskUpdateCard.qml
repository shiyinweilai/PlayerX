import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0
import "MainLogic.js" as Logic

Popup {
    id: taskUpdateCard
    property var root: null
    property var testSourceDownloadDialog: null
    property var testSourceGroupDialog: null
    property var testSourceRedownloadDialog: null
    property var dimReloadTimer: null
    property var updateToast: null
    property var ratingsDialog: null
    property var ratingToast: null
    visible: root._taskUpdateVisible

    // 【本次"接受后卡住"的根因】本文件此前根本没有 `import "MainLogic.js" as Logic`，
    // 点击"接受"按钮时 onClicked 里的 `Logic._applyRemoteConfigItem(...)` 直接抛
    // ReferenceError: Logic is not defined（日志可见），异常发生在 `rowItem._applying = true`
    // 之后、`= false` 之前，于是按钮永远停在"…"态，自动化下载流程根本没被触发——
    // 表现上就是"点了接受，卡住不动"。这里补上 import，并同 TopBar.qml 一样做一次
    // 独立模块副本的初始化（MainLogic.js 没有 `.pragma library`，每个 import 它的
    // QML 文件都有自己独立的一份模块状态，必须各自 _init 一次）。
    Component.onCompleted: {
        Logic._init({
            root: root,
            updateToast: updateToast,
            testSourceDownloadDialog: testSourceDownloadDialog,
            testSourceGroupDialog: testSourceGroupDialog,
            testSourceRedownloadDialog: testSourceRedownloadDialog,
            multiGroupDialog: null,
            dimReloadTimer: dimReloadTimer,
            ratingsDialog: ratingsDialog,
            ratingToast: ratingToast
        })
        console.log("[TaskUpdate] TaskUpdateCard 自身的 MainLogic.js 模块副本已初始化，接受按钮应可正常工作")
    }
    modal: false
    focus: false
    closePolicy: Popup.NoAutoClose
    x: 16
    y: root.height - height - 56
    padding: 0
    // 固定宽度 320：容纳"类型+模式"一行 + tag 一行 + 忽略/应用按钮。
    // 【历史教训】不要用 Column/Positioner 的 implicitWidth 反推 Popup
    // 尺寸（会跟 anchors.left+right 冲突 → Popup 变 0×0 弹不出来）。
    implicitWidth: 320

    background: Rectangle {
        color: "#cc1a1a1f"
        border.color: "#33ffffff"
        border.width: 1
        radius: 6
    }

    contentItem: Column {
        spacing: 0

        // 标题行
        RowLayout {
            width: 320
            height: 36
            spacing: 6

            Item { width: 12 }  // 左边距

            Text {
                text: "🔔"
                font.pixelSize: 14
                Layout.alignment: Qt.AlignVCenter
            }
            Text {
                text: root._remoteHasUpdate ? "远程有新任务" : "远程任务"
                color: "#e8e8ec"
                font.pixelSize: 13
                font.bold: true
                Layout.alignment: Qt.AlignVCenter
                Layout.fillWidth: true
            }
            // 无更新时的小说明：表明这些是远程当前绑定、可手动应用
            Text {
                visible: !root._remoteHasUpdate
                text: "可手动应用为启动项"
                color: "#6a6a7c"
                font.pixelSize: 10
                Layout.alignment: Qt.AlignVCenter
            }
            // 关闭按钮（只隐藏，不清空数据，可通过常驻按钮再次打开）
            Text {
                text: "✕"
                color: "#888"
                font.pixelSize: 12
                Layout.alignment: Qt.AlignVCenter
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root._taskUpdateVisible = false
                }
            }
            Item { width: 8 }  // 右边距
        }

        // 分隔线
        Rectangle { width: 320; height: 1; color: "#33ffffff" }

        // 每一条待更新配置：三列水平布局
        //   列 1（左侧信息区）：上行=类型+模式，下行=tag（超长自动 elide）
        //   列 2：忽略按钮 —— 高度 ≈ 两行信息总高
        //   列 3：应用按钮 —— 高度同上
        //
        // 【稳定要点】所有子项 width/height 都基于 rowItem 固定值 320，
        // anchors 只用单向引用链（applyBtn→parent.right、ignoreBtn→applyBtn.left、
        // infoWrap.right→ignoreBtn.left），绝无回环 → Popup 一定能算出尺寸。
        Repeater {
            model: root._remoteConfigCardList
            delegate: Item {
                id: rowItem
                width: 320
                // 高度 = 两行 11px 文字 + 1×spacing(4) + 上下各 8px 边距 ≈ 38
                height: 38
                // 点「接受」后的即时反馈状态：按钮变 … 并禁用，
                // 用于区分"点击没注册"与"网络拉取中"，应用完成后复位
                property bool _applying: false
                // 该项是否"有更新"（在 _pendingRemoteConfig 中）：有→显示忽略+应用；无→仅应用
                readonly property bool _isPending: {
                    var k = (modelData.mode || "") + ":" + (modelData.configName || "")
                    var pend = Array.isArray(root._pendingRemoteConfig) ? root._pendingRemoteConfig : []
                    for (var i = 0; i < pend.length; i++) {
                        if ((pend[i].mode || "") + ":" + (pend[i].configName || "") === k) return true
                    }
                    return false
                }

                readonly property string _tagText: {
                    var obj = modelData.obj || {}
                    return obj.tag || "—"
                }
                // 评测类型：按绑定模式显示（不再依赖配置 JSON 里的 type 字段）
                // 这样可避免显示成配置文件名/历史 type 残留。
                readonly property string _modeLabel: {
                    var m = (modelData.mode || "")
                    var map = {
                        "multi_dim": "多维评分",
                        "subjective": "主观评分",
                        "quality": "质量比较",
                        "quality_slide": "质量比较2",
                        "test": "测试模式"
                    }
                    return map[m] || m || "—"
                }
                readonly property string _nameText: _modeLabel

                // 按模式取一个简约低饱和区分色（无更新时用）
                readonly property string _modeColor: {
                    var key = (modelData.mode || "")
                    var pal = {
                        "multi_dim": "#6f9c8a",
                        "subjective": "#7d8aa8",
                        "quality": "#a8927d",
                        "quality_slide": "#9a7da8",
                        "test": "#8aa07d"
                    }
                    if (pal[key]) return pal[key]
                    var pool = ["#6f9c8a", "#7d8aa8", "#a8927d", "#9a7da8", "#8aa07d", "#a88a7d", "#7da8a0", "#a87d8a"]
                    var h = 0
                    for (var i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0
                    return pool[h % pool.length]
                }

                // 左侧色条：有更新→明显红色加粗；无更新→按 mode 的简约区分色
                Rectangle {
                    id: modeBar
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: rowItem._isPending ? 4 : 3
                    height: rowItem._isPending ? parent.height - 12 : parent.height - 20
                    radius: 2
                    color: rowItem._isPending ? "#f5c518" : rowItem._modeColor
                }

                // 悬停背景 / 有更新红底高亮
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 1
                    anchors.rightMargin: 1
                    color: rowItem._isPending
                          ? (rowHover.containsMouse ? "#3a3216" : "#2e2810")
                          : (rowHover.containsMouse ? "#14ffffff" : "transparent")
                    radius: 3
                }
                HoverHandler { id: rowHover }

                // 列 3：应用按钮（最右）
                //   先声明按钮再声明信息区，让 infoWrap.anchors.right 引用
                //   ignoreBtn.left（当忽略显示时）或 applyBtn.left（忽略隐藏时）不会出现"未定义 id"警告。
                Rectangle {
                    id: applyBtn
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 44
                    // 高度 = 两行文字（11+11）+ spacing 4 ≈ 28，稍加余量到 28
                    height: 28
                    radius: 4
                    color: rowItem._applying ? "#1d6b5c"
                          : (applyMouse.containsMouse ? "#0db092" : "#0fa085")

                    Text {
                        anchors.centerIn: parent
                        text: rowItem._applying ? "…" : "接受"
                        color: "#ffffff"
                        font.pixelSize: 11
                        font.bold: true
                    }

                    MouseArea {
                        id: applyMouse
                        anchors.fill: parent
                        enabled: !rowItem._applying
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: console.log("[ApplyDebug] 接受按钮 onPressed（输入事件已到达按钮）")
                        onClicked: {
                            rowItem._applying = true
                            Logic._applyRemoteConfigItem(modelData, function() {
                                rowItem._applying = false
                            })
                        }
                    }
                }

                // 列 2：忽略按钮（仅"有更新"的项显示；无更新的手动应用项不显示）
                Rectangle {
                    id: ignoreBtn
                    visible: rowItem._isPending
                    anchors.right: applyBtn.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 44
                    height: 28
                    radius: 4
                    color: ignoreMouse.containsMouse ? "#3a3a44" : "#2a2a34"
                    border.color: "#44ffffff"
                    border.width: 1

                    Text {
                        anchors.centerIn: parent
                        text: "忽略"
                        color: "#aaaabc"
                        font.pixelSize: 11
                    }

                    MouseArea {
                        id: ignoreMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var _ignKey = modelData.mode + ":" + modelData.configName
                            // 【关键】把"当前这一版的内容指纹"写入忽略表，
                            // 下次轮询发现远端 == 忽略版 时就不再入队；
                            // 一旦服务端后续又改了这个配置（rawText 变），忽略自动失效、会重新弹。
                            var _rawIgn = modelData.rawText || ""
                            if (_rawIgn) {
                                var fpIgn = JSON.parse(JSON.stringify(root._localConfigFingerprint || {}))
                                fpIgn["__ignored__:" + _ignKey] = _rawIgn
                                root._localConfigFingerprint = fpIgn
                                Logic._saveFingerprintToFile()
                                console.log("[ConfigCheck] 已忽略配置的当前版本：", _ignKey,
                                    "（服务端后续修改后会重新弹出）")
                            }
                            var rem = (root._pendingRemoteConfig || []).filter(function(x) {
                                return (x.mode + ":" + x.configName) !== _ignKey
                            })
                            root._pendingRemoteConfig = rem.length > 0 ? rem : null
                            if (!root._pendingRemoteConfig) root._taskUpdateVisible = false
                        }
                    }
                }

                // 列 1：信息区（左侧）—— Item 外壳 + 内层 Column
                //   Item 用 anchors.left/right 定位（合法），Column 用
                //   width: parent.width 撑满（Positioner 铁律：不能 anchors.left+right）。
                Item {
                    id: infoWrap
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.right: rowItem._isPending ? ignoreBtn.left : applyBtn.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    height: infoCol.implicitHeight

                    Column {
                        id: infoCol
                        width: parent.width
                        spacing: 4

                        // 行 1：评测类型（配置名，如"配置1"）
                        Row {
                            spacing: 4
                            width: parent.width
                            Text {
                                text: "评测类型 "
                                color: "#6a6a7c"
                                font.pixelSize: 11
                            }
                            Text {
                                text: rowItem._nameText
                                color: "#e8e8ec"
                                font.pixelSize: 11
                                elide: Text.ElideRight
                                width: parent.width - 56
                                wrapMode: Text.NoWrap
                            }
                        }

                        // 行 2：备注 tag
                        Row {
                            spacing: 4
                            width: parent.width
                            Text {
                                text: "备注 tag "
                                color: "#6a6a7c"
                                font.pixelSize: 11
                            }
                            Text {
                                text: rowItem._tagText
                                color: "#e8e8ec"
                                font.pixelSize: 11
                                elide: Text.ElideRight
                                width: parent.width - 56
                                wrapMode: Text.NoWrap
                            }
                        }
                    }
                }

                // 行分隔线（最后一行不显示）
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    height: 1
                    color: "#22ffffff"
                    visible: index < (root._remoteConfigCardList.length - 1)
                }
            }
        }

        // 底部间距
        Item { width: 320; height: 6 }
    }
}
