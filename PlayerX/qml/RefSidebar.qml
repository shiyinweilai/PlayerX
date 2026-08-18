import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Rectangle {
    id: refSidebar
    property var root: null
    property var refSidebarFileDlg: null
    property var refSidebarDirDlg: null
    property var refSidebarGroupedDlg: null
    property var refSidebarFileDlg2: null
    property var refSidebarDirDlg2: null
    property var refSidebarGroupedDlg2: null
    property var refLightbox: null
    property Item leftNavBar: null
    anchors.left: leftNavBar.right
    anchors.top: parent.top
    anchors.topMargin: 2
    // 撑满到窗口底部：让左栏的图1/图2两个区域上下均分整个高度，
    // 不再为底部 CSV 提示词条让位（CSV 底栏只占视频区下方）。
    anchors.bottom: parent.bottom
    width: root.refSidebarWidth
    visible: root.refSidebarVisible && width > 0 && root.currentTab === "play"
    color: "#15151a"
    // 右侧 1px 分隔线，与视频区切开
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: "#2c2c32"
    }

    // 顶部标题栏（含关闭按钮）
    Rectangle {
        id: refHeader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 32
        color: "#1a1a1d"
        Label {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: "参考资料"
            color: "#cfcfd2"
            font.pixelSize: 12
            font.bold: true
        }
        Label {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "✕"
            color: closeMa.containsMouse ? "#ffffff" : "#9a9aa8"
            font.pixelSize: 14
            MouseArea {
                id: closeMa
                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refSidebarVisible = false
            }
        }
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: "#2c2c32"
        }
    }

    // 当前文件夹名：已隐藏（路径信息转移到侧栏右上角 ⋯ 按钮 ToolTip）
    // 保留 id，refTopPane.anchors.top 与 _refContentTop 计算均依赖它。height:0 不占位。
    Label {
        id: refFolderLabel
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: refHeader.bottom
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.topMargin: 0
        height: 0
        visible: false
        // 文件名过长时左侧省略，关键后缀（叶节点名）始终可见
        LayoutMirroring.enabled: false
        horizontalAlignment: Text.AlignLeft
        elide: Text.ElideLeft
        // 用 rtl 让"…/leaf"中省略号在前
        text: {
            var f = root.refCurrentFolder
            if (!f || f.length === 0) return "（未选中通道）"
            // 抽取最后一段作为标题，hover 完整 tooltip
            var i = Math.max(f.lastIndexOf("/"), f.lastIndexOf("\\"))
            return i >= 0 ? f.substring(i + 1) : f
        }
        color: "#9a9aa8"
        font.pixelSize: 11
        ToolTip.visible: refFolderHover.containsMouse && root.refCurrentFolder.length > 0
        ToolTip.delay: 400
        ToolTip.text: root.refCurrentFolder
        MouseArea { id: refFolderHover; anchors.fill: parent; hoverEnabled: true }
    }

    // 上半："参考图"区
    Item {
        id: refTopPane
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: refFolderLabel.bottom
        anchors.topMargin: 4
        // 高度由"上下分隔条"控制；refSplitter 顶部即上半底部
        anchors.bottom: refSplitter.top
    }

    // 中央图片区 + 拖拽接收 + 占位提示
    Rectangle {
        id: refImageBox
        anchors.left: refTopPane.left
        anchors.right: refTopPane.right
        anchors.top: refTopPane.top
        anchors.bottom: refButtonsBar.top
        anchors.margins: 8
        color: "#0e0e10"
        border.color: refDrop.containsDrag ? "#5a8fd8" : "#2c2c32"
        border.width: 1
        radius: 4

        // 实际图片（使用文件 URL；自动 Retina 缩放，PreserveAspectFit 保持比例）
        Image {
            id: refImage
            anchors.fill: parent
            anchors.margins: 4
            source: root.refCurrentUrl
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            cache: true
            // sourceSize 锁成稳定值（不再随容器尺寸变化）
            //   · 历史问题：之前写 width*2 / height*2，会随窗口尺寸变动
            //     按 F / 双击切全屏时，refImageBox 的 width/height 会经历瞬时中间值，
            //     导致 sourceSize 跳变 → Qt 重新解码 → status 回到 Loading → "加载中…"闪现
            //   · 解决：固定 1024×1024，对侧栏参考图（最大也就几百 px 宽）足够清晰；
            //     PreserveAspectFit 保留比例显示，sourceSize 只是解码上限不强制比例
            //   · 副作用：内存略升（从动态变为常驻 1024 上限），但侧栏只 1 张图，可忽略
            sourceSize.width:  1024
            sourceSize.height: 1024
            // 切换图片时不闪"加载中…"：
            //   · Image 在 source 变更但新图未 Ready 时，仍持有上一张已解码的纹理；
            //     只要保持 visible:true，这一张旧图就会原地停留到新图 Ready 才被替换。
            //   · 之前用 status === Ready 作为 visible 条件，会在 Loading 瞬间把图隐藏，
            //     让位给"加载中…"占位 → 视觉上一闪。
            //   · 现在改为"未出错就一直显示"：Ready 显新图、Loading 续旧图、Error/Null 让位占位。
            visible: root.refHasCurrent && status !== Image.Error
            asynchronous: true

            // 双击图片本体也能放大查看（与右上角 ⤢ 按钮等价）
            //   · 设计：常见图片查看器的"双击查看原图"惯用手势，无视觉打扰
            //   · 单击不做任何事（避免误触），仅 onDoubleClicked 触发 Lightbox
            //   · z 默认 0，低于 refImageZoomBtn(z:2)，按钮区域不会被这层吃掉
            //   · cursorShape 给个手型，暗示可点击；ToolTip 第一次 hover 时提示双击
            MouseArea {
                id: refImageDblMA
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onDoubleClicked: refLightbox.open()
                ToolTip.visible: containsMouse
                ToolTip.delay: 800
                ToolTip.text: "双击放大查看"
            }
        }

        // 右上角操作按钮组：⋯ 重选 / ⤢ 放大 / ✕ 清除
        //   · 仅在已绑定参考图时显示（与视频窗口右上角同风格、同语义）
        //   · 释放底部按钮条空间，让图片预览区获得更大显示面积
        //   · z:2 置顶，覆盖于 DropArea 之上；按钮自身只吃点击，不影响整体拖拽接收
        Row {
            id: refImageBtnRow
            z: 2
            anchors.top: refImage.top
            anchors.right: refImage.right
            anchors.topMargin: 8
            anchors.rightMargin: 8
            spacing: 4
            visible: refImage.visible

            // ⋯ 重选菜单（弹出小菜单：重选图片 / 重选文件夹）
            Rectangle {
                id: refImageMoreBtn
                width: 28; height: 28
                radius: 4
                color: refImageMoreBtnMA.pressed ? "#3a3a45"
                     : refImageMoreBtnMA.containsMouse ? "#2a2a32cc"
                     : "#1a1a1d99"
                border.color: refImageMoreBtnMA.containsMouse ? "#5a8fd8" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -2
                    text: "⋯"
                    color: refImageMoreBtnMA.containsMouse ? "#ffffff" : "#d0d0d8"
                    font.pixelSize: 18
                    font.bold: true
                }
                MouseArea {
                    id: refImageMoreBtnMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: refImageMoreMenu.open()
                    // ToolTip 直接显示当前参考图完整路径（去掉 file:// 前缀），
                    // 未绑定时回退为"更多操作"提示。
                    ToolTip.visible: containsMouse && !refImageMoreMenu.visible
                    ToolTip.delay: 400
                    ToolTip.text: {
                        var u = String(root.refCurrentUrl)
                        if (u.length === 0) return "更多操作（重新选择图片 / 文件夹 / 分组多图）"
                        // grouped 模式优先显示「根目录 + 当前图」，便于诊断
                        if (root.refCurrentMode === "grouped") {
                            var rootDir = Reference.groupedRootOf(root.refCurrentFolder) || ""
                            var cur = decodeURIComponent(u.replace(/^file:\/\//, ""))
                            if (rootDir.length > 0) return "[分组多图] 根目录: " + rootDir + "\n当前: " + cur
                            return cur
                        }
                        return decodeURIComponent(u.replace(/^file:\/\//, ""))
                    }
                }
                // 重选菜单：深色主题，与侧栏胶囊按钮同调。
                //   · Menu.background：不透明深色背景 + 薄边框，区别于底层画面
                //   · MenuItem.background / contentItem：hover 高亮、文字颜色与控件主题一致
                Menu {
                    id: refImageMoreMenu
                    y: refImageMoreBtn.height + 2
                    padding: 4
                    background: Rectangle {
                        // 文案由“重新选择图片”简化为“图片/文件夹/多文件夹”，
                        // 宽度同步收窄，避免右侧出现大片空白。
                        // 背景与头部“三个点”按钮保持一致的玻璃半透明风格：
                        //   · 颜色给 cc 约 80% alpha，边框与按钮同款 #3a3a45。
                        implicitWidth: 110
                        color: "#1a1a1dcc"
                        border.color: "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    delegate: MenuItem {
                        id: refImageMoreMenuItem
                        implicitHeight: 28
                        contentItem: Text {
                            leftPadding: 10
                            rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: refImageMoreMenuItem.text
                            color: refImageMoreMenuItem.highlighted ? "#ffffff" : "#d0d0d8"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: refImageMoreMenuItem.highlighted ? "#2a2a32" : "transparent"
                        }
                    }
                    // 注意：直接子 MenuItem 不会走上面的 delegate（delegate 只对
                    // 通过 model/Repeater 实例化的项生效），所以样式必须写在每个
                    // MenuItem 自身。需求：纯深色底 + 白字，去掉所有 highlight 变色，
                    // 鼠标悬停/选中均不变色，点击直接 onTriggered 起效。
                    // 样式说明：默认透明底；hover 时整行加一个深灰底，文字保持不变，
                    // 不再使用下划线，避免视觉过重。
                    MenuItem {
                        id: refImageMoreItem1
                        text: "图片"
                        implicitHeight: 28
                        onTriggered: refSidebarFileDlg.open()
                        contentItem: Text {
                            leftPadding: 10
                            rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: refImageMoreItem1.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: refImageMoreItem1.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                    MenuItem {
                        id: refImageMoreItem2
                        text: "文件夹"
                        implicitHeight: 28
                        onTriggered: refSidebarDirDlg.open()
                        contentItem: Text {
                            leftPadding: 10
                            rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: refImageMoreItem2.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: refImageMoreItem2.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                    // 分组多图根目录：root/组A/图... · root/组B/图...
                    // 跟随对比组跳到同名子组的「组首」；◀▶递归跨组翻图。
                    MenuItem {
                        id: refImageMoreItem3
                        text: "多文件夹"
                        implicitHeight: 28
                        onTriggered: refSidebarGroupedDlg.open()
                        contentItem: Text {
                            leftPadding: 10
                            rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: refImageMoreItem3.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: refImageMoreItem3.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                }
            }

            // ⤢ 放大查看（弹 Lightbox）
            Rectangle {
                id: refImageZoomBtn
                width: 28; height: 28
                radius: 4
                color: refImageZoomBtnMA.pressed ? "#3a3a45"
                     : refImageZoomBtnMA.containsMouse ? "#2a2a32cc"
                     : "#1a1a1d99"
                border.color: refImageZoomBtnMA.containsMouse ? "#5a8fd8" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    text: "⤢"
                    color: refImageZoomBtnMA.containsMouse ? "#ffffff" : "#d0d0d8"
                    font.pixelSize: 16
                    font.bold: true
                }
                MouseArea {
                    id: refImageZoomBtnMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: refLightbox.open()
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "放大查看（滚轮缩放，← → 翻页，Esc 关闭）"
                }
            }

            // ✕ 清除当前绑定
            Rectangle {
                id: refImageClearBtn
                width: 28; height: 28
                radius: 4
                color: refImageClearBtnMA.pressed ? "#5a2a2a"
                     : refImageClearBtnMA.containsMouse ? "#3a2228cc"
                     : "#1a1a1d99"
                border.color: refImageClearBtnMA.containsMouse ? "#e0454d" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: refImageClearBtnMA.containsMouse ? "#ffffff" : "#e8b0b0"
                    font.pixelSize: 14
                    font.bold: true
                }
                MouseArea {
                    id: refImageClearBtnMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: {
                        if (root.refCurrentFolder.length > 0)
                            Reference.clearReference(root.refCurrentFolder)
                    }
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "清除当前参考图绑定"
                }
            }
        }

        // 加载中 / 失败 / 未绑定占位
        //   · 未绑定时：占位文案 + 居中两按钮（📷 图片 / 📁 文件夹），
        //     替代原先底部按钮条的入口，让图片区铺满更多空间。
        Column {
            anchors.centerIn: parent
            width: parent.width - 24
            spacing: 12
            visible: !refImage.visible

            Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: "#6a6a78"
                font.pixelSize: 12
                text: {
                    if (root.refCurrentFolder.length === 0)
                        return "请选中任一通道，\n或在「打开文件夹」对话框中为该路绑定参考图"
                    if (!root.refHasCurrent)
                        return "该文件夹未绑定参考图\n\n选一张固定图，或让参考图随对比组切换\n（也可直接把图片或图片文件夹拖进来）"
                    // Loading 分支移除：Image 在 Loading 期间仍 visible 显示旧图，占位根本不会出现。
                    if (refImage.status === Image.Error)    return "图片无法加载（可能已被移动或删除）"
                    return ""
                }
            }

            // 中央两个选择按钮：仅在"未绑定但已选中通道"时出现
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                visible: root.refCurrentFolder.length > 0 && !root.refHasCurrent
                Button {
                    id: refPickImgBtnCenter
                    text: "📷 图片"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: refSidebarFileDlg.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择一张固定参考图（整组对比始终显示这张）"
                    background: Rectangle {
                        color: refPickImgBtnCenter.down ? "#4a4a55"
                             : refPickImgBtnCenter.hovered ? "#33333a"
                             : "#202024"
                        border.color: refPickImgBtnCenter.hovered ? "#5a8fd8" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: refPickImgBtnCenter.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    id: refPickDirBtnCenter
                    text: "📁 文件夹"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: refSidebarDirDlg.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择图片文件夹（参考图按对比组自动同步）"
                    background: Rectangle {
                        color: refPickDirBtnCenter.down ? "#4a4a55"
                             : refPickDirBtnCenter.hovered ? "#33333a"
                             : "#202024"
                        border.color: refPickDirBtnCenter.hovered ? "#0fa085" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: refPickDirBtnCenter.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                // 「分组多图」入口：root/组A/图... · root/组B/图...
                // 跟随对比组跳到同名子组首图；◀▶递归跨组翻图。
                Button {
                    id: refPickGroupedBtnCenter
                    text: "🗂 分组多图"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: refSidebarGroupedDlg.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择两级文件夹：root/组A/图... · root/组B/图...\n跟随对比组跳到同名子组首图；◀▶递归跨组翻图"
                    background: Rectangle {
                        color: refPickGroupedBtnCenter.down ? "#4a4a55"
                             : refPickGroupedBtnCenter.hovered ? "#33333a"
                             : "#202024"
                        border.color: refPickGroupedBtnCenter.hovered ? "#c89020" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: refPickGroupedBtnCenter.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // 拖拽接收：
        //   · 拖入文件夹 → folder 模式（参考图按对比组同步切换）
        //   · 拖入图片  → image 模式（固定图）
        //   · 多选时优先文件夹；都不命中再尝试每个 URL 当图片
        DropArea {
            id: refDrop
            anchors.fill: parent
            onDropped: function(drop) {
                if (root.refCurrentFolder.length === 0) {
                    drop.accepted = false
                    return
                }
                if (!drop.hasUrls) { drop.accepted = false; return }
                // 1) 优先识别文件夹
                for (var i = 0; i < drop.urls.length; ++i) {
                    var u = drop.urls[i]
                    if (Fs.isDirectory(u)) {
                        if (Reference.setReferenceFolderUrl(root.refCurrentFolder, u)) {
                            drop.accepted = true
                            return
                        }
                    }
                }
                // 2) 否则尝试图片文件
                for (var j = 0; j < drop.urls.length; ++j) {
                    var u2 = drop.urls[j]
                    if (Reference.setReferenceUrl(root.refCurrentFolder, u2)) {
                        drop.accepted = true
                        return
                    }
                }
                drop.accepted = false
            }
        }

        // ◀ ▶ 浮层切换按钮（仅 folder 模式 / 总数>1 时可见）
        //   ◀：在自动索引上 -1（夹紧到 0）
        //   ▶：在自动索引上 +1（夹紧到 N-1）
        //   悬浮在图片右下角，不占按钮条；点击时图片自动重新加载。
        Row {
            id: refImgNavBar
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 6
            spacing: 4
            visible: root.refCanNav && root.refImageCount > 1

            // ── 上一张 ───────────────────────────────────────
            Rectangle {
                id: refPrevBtn
                width: 28; height: 24
                radius: 3
                color: prevMA.pressed ? "#3a3a45"
                      : prevMA.containsMouse ? "#2a2a32"
                      : "#1a1a1da0"   // 半透明深底，避免遮挡图片
                border.color: refPrevBtn.enabled ? "#5a5a65" : "#2a2a32"
                border.width: 1
                // 循环切换：只要≥2 张图就可用（越过头/尾会装回）。
                property bool enabled: root.refImageCount > 1
                Text {
                    anchors.centerIn: parent
                    text: "◀"
                    font.pixelSize: 12
                    color: refPrevBtn.enabled ? "#e8e8ec" : "#555"
                }
                MouseArea {
                    id: prevMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: refPrevBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (!refPrevBtn.enabled) return
                        root._refImgOffset -= 1
                    }
                }
                ToolTip.visible: prevMA.containsMouse
                ToolTip.delay: 400
                ToolTip.text: "上一张参考图（手动浏览）"
            }

            // ── 下一张 ───────────────────────────────────────
            Rectangle {
                id: refNextBtn
                width: 28; height: 24
                radius: 3
                color: nextMA.pressed ? "#3a3a45"
                      : nextMA.containsMouse ? "#2a2a32"
                      : "#1a1a1da0"
                border.color: refNextBtn.enabled ? "#5a5a65" : "#2a2a32"
                border.width: 1
                // 循环切换：与 ◀ 保持一致。
                property bool enabled: root.refImageCount > 1
                Text {
                    anchors.centerIn: parent
                    text: "▶"
                    font.pixelSize: 12
                    color: refNextBtn.enabled ? "#e8e8ec" : "#555"
                }
                MouseArea {
                    id: nextMA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: refNextBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (!refNextBtn.enabled) return
                        root._refImgOffset += 1
                    }
                }
                ToolTip.visible: nextMA.containsMouse
                ToolTip.delay: 400
                ToolTip.text: "下一张参考图（手动浏览）"
            }
        }
    }

    // 模式 / 进度小标签：已隐藏（信息与 CSV 底栏重复，这里不再占用侧栏高度）
    Rectangle {
        id: refModeBar
        anchors.left: refTopPane.left
        anchors.right: refTopPane.right
        anchors.bottom: refButtonsBar.top
        height: 0
        visible: false
        color: "transparent"
    }

    // 底部按钮条：已移除（选择入口合并到右上角 ⋯ 菜单 + 未绑定时中央两按钮）
    // 保留空壳，让 anchors.bottom: refButtonsBar.top 这类既有引用继续生效；
    // height: 0 / visible: false 不占任何高度。
    Rectangle {
        id: refButtonsBar
        anchors.left: refTopPane.left
        anchors.right: refTopPane.right
        anchors.bottom: refTopPane.bottom
        height: 0
        visible: false
        color: "transparent"
    }

    // ─── 上下分隔条（可拖动调整上下两栏比例）─────────────────────
    // 用 fraction 表示上半占"内容区"剩余高度的比例（0.18 ~ 0.85），
    // 拖动时实时改变，但不持久化（保持轻量）。
    property real refTopFraction: 0.5
    // 内容区起点 = refFolderLabel 底部 + 4；终点 = refSidebar 底部
    readonly property real _refContentTop: refFolderLabel.y + refFolderLabel.height + 4
    readonly property real _refContentBottom: height
    readonly property real _refContentH: Math.max(120, _refContentBottom - _refContentTop)

    Rectangle {
        id: refSplitter
        anchors.left: parent.left
        anchors.right: parent.right
        // y = 内容起点 + 上半占比 * 总高
        y: refSidebar._refContentTop + Math.round(refSidebar._refContentH * refSidebar.refTopFraction)
        height: 6
        color: refSplitterMa.containsMouse || refSplitterMa.pressed ? "#2a2a32" : "transparent"
        // 中线：3 个浅色"・"作为视觉提示
        Row {
            anchors.centerIn: parent
            spacing: 4
            Repeater {
                model: 3
                Rectangle { width: 3; height: 3; radius: 1.5; color: "#5a5a66" }
            }
        }
        MouseArea {
            id: refSplitterMa
            anchors.fill: parent
            anchors.topMargin: -2
            anchors.bottomMargin: -2
            hoverEnabled: true
            cursorShape: Qt.SplitVCursor
            drag.target: null  // 自己用 onPositionChanged 计算，避免位移到上下边界外
            property real _grabOffset: 0
            onPressed: function(mouse) {
                _grabOffset = mouse.y
            }
            onPositionChanged: function(mouse) {
                if (!pressed) return
                var newY = refSplitter.y + (mouse.y - _grabOffset)
                var topMin = refSidebar._refContentTop + 80    // 上半至少 80
                var topMax = refSidebar.height - 120           // 下半至少 120
                newY = Math.max(topMin, Math.min(topMax, newY))
                refSidebar.refTopFraction = (newY - refSidebar._refContentTop) / refSidebar._refContentH
            }
            onDoubleClicked: refSidebar.refTopFraction = 0.5  // 双击复位（上下均分）
        }
    }

    // ─── 下半："参考图 2" 区（与上半完全镜像）───────────────────
    Item {
        id: refBottomPane
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: refSplitter.bottom
        anchors.bottom: parent.bottom
    }

    // 中央图片区 + 拖拽接收 + 占位提示（与 refImageBox 完全对齐，但操作的是 slot2）
    Rectangle {
        id: refImageBox2
        anchors.left: refBottomPane.left
        anchors.right: refBottomPane.right
        anchors.top: refBottomPane.top
        anchors.bottom: refButtonsBar2.top
        anchors.margins: 8
        color: "#0e0e10"
        border.color: refDrop2.containsDrag ? "#5a8fd8" : "#2c2c32"
        border.width: 1
        radius: 4

        Image {
            id: refImage2
            anchors.fill: parent
            anchors.margins: 4
            source: root.refCurrentUrl2
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            cache: true
            sourceSize.width:  1024
            sourceSize.height: 1024
            // 与 refImage 同策略：Loading 期间续显旧图，避免"加载中…"闪现。
            visible: root.refHasCurrent2 && status !== Image.Error
            asynchronous: true

            MouseArea {
                id: refImage2DblMA
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onDoubleClicked: refLightbox.openSlot(2)
                ToolTip.visible: containsMouse
                ToolTip.delay: 800
                ToolTip.text: "双击放大查看"
            }
        }

        // 右上角操作按钮组：⋯ 重选 / ⤢ 放大 / ✕ 清除（slot2 版）
        Row {
            id: refImageBtnRow2
            z: 2
            anchors.top: refImage2.top
            anchors.right: refImage2.right
            anchors.topMargin: 8
            anchors.rightMargin: 8
            spacing: 4
            visible: refImage2.visible

            // ⋯ 重选菜单
            Rectangle {
                id: refImageMoreBtn2
                width: 28; height: 28
                radius: 4
                color: refImageMoreBtn2MA.pressed ? "#3a3a45"
                     : refImageMoreBtn2MA.containsMouse ? "#2a2a32cc"
                     : "#1a1a1d99"
                border.color: refImageMoreBtn2MA.containsMouse ? "#5a8fd8" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -2
                    text: "⋯"
                    color: refImageMoreBtn2MA.containsMouse ? "#ffffff" : "#d0d0d8"
                    font.pixelSize: 18
                    font.bold: true
                }
                MouseArea {
                    id: refImageMoreBtn2MA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: refImageMoreMenu2.open()
                    ToolTip.visible: containsMouse && !refImageMoreMenu2.visible
                    ToolTip.delay: 400
                    ToolTip.text: {
                        var u = String(root.refCurrentUrl2)
                        if (u.length === 0) return "更多操作（重新选择图片 / 文件夹 / 分组多图）"
                        if (root.refCurrentMode2 === "grouped") {
                            var rootDir = Reference.groupedRootOf2(root.refCurrentFolder) || ""
                            var cur = decodeURIComponent(u.replace(/^file:\/\//, ""))
                            if (rootDir.length > 0) return "[分组多图] 根目录: " + rootDir + "\n当前: " + cur
                            return cur
                        }
                        return decodeURIComponent(u.replace(/^file:\/\//, ""))
                    }
                }
                // 重选菜单（slot2 版）：玻璃半透明主题，与三个点按钮一致。
                Menu {
                    id: refImageMoreMenu2
                    y: refImageMoreBtn2.height + 2
                    padding: 4
                    background: Rectangle {
                        implicitWidth: 110
                        color: "#1a1a1dcc"
                        border.color: "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    delegate: MenuItem {
                        id: refImageMoreMenu2Item
                        implicitHeight: 28
                        contentItem: Text {
                            leftPadding: 10
                            rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: refImageMoreMenu2Item.text
                            color: refImageMoreMenu2Item.highlighted ? "#ffffff" : "#d0d0d8"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: refImageMoreMenu2Item.highlighted ? "#2a2a32" : "transparent"
                        }
                    }
                    // 同图1：直接 MenuItem 不走 delegate，样式写在自身。
                    MenuItem {
                        id: refImageMoreItem2_1
                        text: "图片"
                        implicitHeight: 28
                        onTriggered: refSidebarFileDlg2.open()
                        contentItem: Text {
                            leftPadding: 10
                            rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: refImageMoreItem2_1.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: refImageMoreItem2_1.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                    MenuItem {
                        id: refImageMoreItem2_2
                        text: "文件夹"
                        implicitHeight: 28
                        onTriggered: refSidebarDirDlg2.open()
                        contentItem: Text {
                            leftPadding: 10
                            rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: refImageMoreItem2_2.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: refImageMoreItem2_2.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                    MenuItem {
                        id: refImageMoreItem2_3
                        text: "多文件夹"
                        implicitHeight: 28
                        onTriggered: refSidebarGroupedDlg2.open()
                        contentItem: Text {
                            leftPadding: 10
                            rightPadding: 10
                            verticalAlignment: Text.AlignVCenter
                            text: refImageMoreItem2_3.text
                            color: "#e8e8ec"
                            font.pixelSize: 12
                        }
                        background: Rectangle {
                            radius: 3
                            color: refImageMoreItem2_3.hovered ? "#2a2a32cc" : "transparent"
                        }
                        arrow: Item {}
                        indicator: Item {}
                    }
                }
            }

            // ⤢ 放大
            Rectangle {
                id: refImageZoomBtn2
                width: 28; height: 28
                radius: 4
                color: refImageZoomBtn2MA.pressed ? "#3a3a45"
                     : refImageZoomBtn2MA.containsMouse ? "#2a2a32cc"
                     : "#1a1a1d99"
                border.color: refImageZoomBtn2MA.containsMouse ? "#5a8fd8" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    text: "⤢"
                    color: refImageZoomBtn2MA.containsMouse ? "#ffffff" : "#d0d0d8"
                    font.pixelSize: 16
                    font.bold: true
                }
                MouseArea {
                    id: refImageZoomBtn2MA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: refLightbox.openSlot(2)
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "放大查看（滚轮缩放，← → 翻页，Esc 关闭）"
                }
            }

            // ✕ 清除当前绑定
            Rectangle {
                id: refImageClearBtn2
                width: 28; height: 28
                radius: 4
                color: refImageClearBtn2MA.pressed ? "#5a2a2a"
                     : refImageClearBtn2MA.containsMouse ? "#3a2228cc"
                     : "#1a1a1d99"
                border.color: refImageClearBtn2MA.containsMouse ? "#e0454d" : "#3a3a45"
                border.width: 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: refImageClearBtn2MA.containsMouse ? "#ffffff" : "#e8b0b0"
                    font.pixelSize: 14
                    font.bold: true
                }
                MouseArea {
                    id: refImageClearBtn2MA
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: {
                        if (root.refCurrentFolder.length > 0)
                            Reference.clearReference2(root.refCurrentFolder)
                    }
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "清除当前参考图绑定"
                }
            }
        }

        // 占位 + 未绑定时居中两按钮（slot2 版）
        Column {
            anchors.centerIn: parent
            width: parent.width - 24
            spacing: 12
            visible: !refImage2.visible

            Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: "#6a6a78"
                font.pixelSize: 12
                text: {
                    if (root.refCurrentFolder.length === 0)
                        return "请选中任一通道，\n或在「打开文件夹」对话框中为该路绑定参考图"
                    if (!root.refHasCurrent2)
                        return "该文件夹未绑定第 2 张参考图\n\n选一张固定图，或让参考图随对比组切换\n（也可直接把图片或图片文件夹拖进来）"
            // Loading 分支移除：理由同 refImage 占位文案。
                    if (refImage2.status === Image.Error)   return "图片无法加载（可能已被移动或删除）"
                    return ""
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                visible: root.refCurrentFolder.length > 0 && !root.refHasCurrent2
                Button {
                    id: refPickImgBtnCenter2
                    text: "📷 图片"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: refSidebarFileDlg2.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择一张固定参考图（整组对比始终显示这张）"
                    background: Rectangle {
                        color: refPickImgBtnCenter2.down ? "#4a4a55"
                             : refPickImgBtnCenter2.hovered ? "#33333a"
                             : "#202024"
                        border.color: refPickImgBtnCenter2.hovered ? "#5a8fd8" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: refPickImgBtnCenter2.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    id: refPickDirBtnCenter2
                    text: "📁 文件夹"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: refSidebarDirDlg2.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择图片文件夹（参考图按对比组自动同步）"
                    background: Rectangle {
                        color: refPickDirBtnCenter2.down ? "#4a4a55"
                             : refPickDirBtnCenter2.hovered ? "#33333a"
                             : "#202024"
                        border.color: refPickDirBtnCenter2.hovered ? "#0fa085" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: refPickDirBtnCenter2.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                // 「分组多图」入口（slot2 版）
                Button {
                    id: refPickGroupedBtnCenter2
                    text: "🗂 分组多图"
                    implicitWidth: 96
                    implicitHeight: 28
                    hoverEnabled: true
                    onClicked: refSidebarGroupedDlg2.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "选择两级文件夹：root/组A/图... · root/组B/图...\n跟随对比组跳到同名子组首图；◀▶ 递归跨组翻图"
                    background: Rectangle {
                        color: refPickGroupedBtnCenter2.down ? "#4a4a55"
                             : refPickGroupedBtnCenter2.hovered ? "#33333a"
                             : "#202024"
                        border.color: refPickGroupedBtnCenter2.hovered ? "#c89020" : "#3a3a45"
                        border.width: 1
                        radius: 4
                    }
                    contentItem: Text {
                        text: refPickGroupedBtnCenter2.text
                        color: "#e8e8ec"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // 拖拽接收（slot2 版）
        DropArea {
            id: refDrop2
            anchors.fill: parent
            onDropped: function(drop) {
                if (root.refCurrentFolder.length === 0) { drop.accepted = false; return }
                if (!drop.hasUrls) { drop.accepted = false; return }
                for (var i = 0; i < drop.urls.length; ++i) {
                    var u = drop.urls[i]
                    if (Fs.isDirectory(u)) {
                        if (Reference.setReferenceFolderUrl2(root.refCurrentFolder, u)) {
                            drop.accepted = true; return
                        }
                    }
                }
                for (var j = 0; j < drop.urls.length; ++j) {
                    var u2 = drop.urls[j]
                    if (Reference.setReferenceUrl2(root.refCurrentFolder, u2)) {
                        drop.accepted = true; return
                    }
                }
                drop.accepted = false
            }
        }

        // ◀ ▶ 浮层切换按钮（slot2 版，仅 folder 模式 / 总数>1 时可见）
        Row {
            id: refImgNavBar2
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 6
            spacing: 4
            visible: root.refCanNav2 && root.refImageCount2 > 1

            Rectangle {
                id: refPrevBtn2
                width: 28; height: 24
                radius: 3
                color: prevMA2.pressed ? "#3a3a45"
                      : prevMA2.containsMouse ? "#2a2a32"
                      : "#1a1a1da0"
                border.color: refPrevBtn2.enabled ? "#5a5a65" : "#2a2a32"
                border.width: 1
                // 循环切换：只要≥2 张图就可用。
                property bool enabled: root.refImageCount2 > 1
                Text {
                    anchors.centerIn: parent
                    text: "◀"
                    font.pixelSize: 12
                    color: refPrevBtn2.enabled ? "#e8e8ec" : "#555"
                }
                MouseArea {
                    id: prevMA2
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: refPrevBtn2.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: { if (refPrevBtn2.enabled) root._refImgOffset2 -= 1 }
                }
                ToolTip.visible: prevMA2.containsMouse
                ToolTip.delay: 400
                ToolTip.text: "上一张参考图（手动浏览）"
            }

            Rectangle {
                id: refNextBtn2
                width: 28; height: 24
                radius: 3
                color: nextMA2.pressed ? "#3a3a45"
                      : nextMA2.containsMouse ? "#2a2a32"
                      : "#1a1a1da0"
                border.color: refNextBtn2.enabled ? "#5a5a65" : "#2a2a32"
                border.width: 1
                // 循环切换。
                property bool enabled: root.refImageCount2 > 1
                Text {
                    anchors.centerIn: parent
                    text: "▶"
                    font.pixelSize: 12
                    color: refNextBtn2.enabled ? "#e8e8ec" : "#555"
                }
                MouseArea {
                    id: nextMA2
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: refNextBtn2.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: { if (refNextBtn2.enabled) root._refImgOffset2 += 1 }
                }
                ToolTip.visible: nextMA2.containsMouse
                ToolTip.delay: 400
                ToolTip.text: "下一张参考图（手动浏览）"
            }
        }
    }

    // 模式 / 进度小标签（slot2 版）：已隐藏（信息与 CSV 底栏冗余）
    Rectangle {
        id: refModeBar2
        anchors.left: refBottomPane.left
        anchors.right: refBottomPane.right
        anchors.bottom: refButtonsBar2.top
        height: 0
        visible: false
        color: "transparent"
    }

    // 底部按钮条（slot2 版）：已移除（选择入口合并到右上角 ⋯ 菜单 + 未绑定时中央两按钮）
    // 保留空壳，让 anchors.bottom: refButtonsBar2.top 这类既有引用继续生效。
    Rectangle {
        id: refButtonsBar2
        anchors.left: refBottomPane.left
        anchors.right: refBottomPane.right
        anchors.bottom: refBottomPane.bottom
        height: 0
        visible: false
        color: "transparent"
    }
}
