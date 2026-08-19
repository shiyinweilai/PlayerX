import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

Item {
    id: fileDialogs
    property var root: null
    property var multiGroupDialog: null

    // 【对外 property alias】
    // 子组件的 id 只能在本组件 scope 内访问（`fileDialogs.addDialog` 拿不到
    // 内部 id），必须用 property alias 显式导出。Main.qml / AppMenuBar 等外部
    // 通过 fileDialogs.addDialog / fileDialogs.replaceDialog / fileDialogs.refSidebar*
    // 等访问的就是下面这些别名。
    property alias addDialog: addDialog
    property alias replaceDialog: replaceDialog
    property alias refSidebarCsvDlg: refSidebarCsvDlg
    property alias refSidebarFileDlg: refSidebarFileDlg
    property alias refSidebarDirDlg: refSidebarDirDlg
    property alias refSidebarGroupedDlg: refSidebarGroupedDlg
    property alias refSidebarFileDlg2: refSidebarFileDlg2
    property alias refSidebarDirDlg2: refSidebarDirDlg2
    property alias refSidebarGroupedDlg2: refSidebarGroupedDlg2

    FileDialog {
        id: addDialog
        title: "添加视频文件（可多选）"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv *.y4m *.yuv *.h264 *.h265 *.hevc)",
            "所有文件 (*)"
        ]
        onAccepted: {
            // 从空状态打开 → 走 MultiGroupDialog.loadFlatFiles 接管，获得 N 宫格切换 / 翻页能力；
            // 已有视频时 → 维持原"逐个 addFile"的追加语义（不打断当前对比）。
            if (Engine.fileCount === 0) {
                if (selectedFiles.length === 1) {
                    // 单个文件：直接打开即可，不进 active 态（用户没想进队列模式）
                    Engine.openFiles(selectedFiles)
                } else if (selectedFiles.length > 1) {
                    // 多个文件：纳入 MultiGroupDialog 接管，默认以 1 宫格启动，
                    // 之后用底栏 ▦ 按钮切宫格、⏮⏭ 翻页。
                    if (!multiGroupDialog.loadFlatFiles(selectedFiles)) {
                        // 兜底：接管失败仍按老逻辑直开（截前 9 个）
                        var arr = selectedFiles
                        if (arr.length > 9) arr = arr.slice(0, 9)
                        Engine.openFiles(arr)
                    }
                }
            } else {
                for (var i = 0; i < selectedFiles.length; ++i) {
                    if (Engine.fileCount >= 9) break
                    Engine.addFile(selectedFiles[i])
                }
            }
        }
    }

    // 「替换本路」对话框：单选文件，原地调用 Engine.replaceAt(idx, url)。
    // 使用 root.pendingReplaceIdx 传递"哪一路要被替换"——FileDialog 不能绑定变量，
    // 在 cell 点 🔁 时先写入该 idx，然后 open() 。
    FileDialog {
        id: replaceDialog
        title: "替换本路视频文件"
        fileMode: FileDialog.OpenFile
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv *.y4m *.yuv *.h264 *.h265 *.hevc)",
            "所有文件 (*)"
        ]
        onAccepted: {
            var idx = root.pendingReplaceIdx
            if (idx < 0 || idx >= Engine.fileCount) return
            Engine.replaceAt(idx, selectedFile)
        }
    }

    // 侧边栏：选择 CSV
    FileDialog {
        id: refSidebarCsvDlg
        title: "选择参考文本 CSV"
        nameFilters: [ "CSV (*.csv)" ]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            Reference.setReferenceCsvUrl(root.refCurrentFolder, selectedFile)
        }
    }

    // 侧边栏：选择单张参考图（image 模式）
    FileDialog {
        id: refSidebarFileDlg
        title: "选择参考图（固定图）"
        nameFilters: [ "图片 (*.png *.jpg *.jpeg *.webp *.bmp *.gif)" ]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            Reference.setReferenceUrl(root.refCurrentFolder, selectedFile)
        }
    }

    // 侧边栏：选择参考图文件夹（folder 模式 → 跟随对比组同步切换）
    FolderDialog {
        id: refSidebarDirDlg
        title: "选择参考图文件夹（跟随对比组）"
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            // 不传 selectedFolder（QUrl）字符串截取，统一用 C++ 端的 URL → path 转换
            if (!Reference.setReferenceFolderUrl(root.refCurrentFolder, selectedFolder)) {
                // 选错了空文件夹时静默失败；提示文字过多反而干扰。
                // 用户能从「占位提示」直接看到"未绑定"再次操作。
            }
        }
    }

    // 侧边栏：选择「分组多图」根目录（grouped 模式）
    //   预期结构：root/组A/图1.jpg · root/组A/图2.jpg · root/组B/图1.jpg ...
    //   跟随对比组切换时：按名称/索引对齐到同名子组的「组首」；◀▶在长队列上递归跨组。
    FolderDialog {
        id: refSidebarGroupedDlg
        title: "选择参考图根目录（分组多图、两级文件夹）"
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            if (!Reference.setGroupedFolderUrl(root.refCurrentFolder, selectedFolder)) {
                // 路径结构不符合（无子目录 / 子目录里无图片）时静默失败。
            }
        }
    }

    // 侧边栏（槽位 2）：选择单张参考图
    FileDialog {
        id: refSidebarFileDlg2
        title: "选择参考图（固定图）"
        nameFilters: [ "图片 (*.png *.jpg *.jpeg *.webp *.bmp *.gif)" ]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            Reference.setReferenceUrl2(root.refCurrentFolder, selectedFile)
        }
    }

    // 侧边栏（槽位 2）：选择参考图文件夹
    FolderDialog {
        id: refSidebarDirDlg2
        title: "选择第 2 张参考图文件夹（跟随对比组）"
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            if (!Reference.setReferenceFolderUrl2(root.refCurrentFolder, selectedFolder)) {
                // 静默失败
            }
        }
    }

    // 侧边栏（槽位 2）：选择「分组多图」根目录
    FolderDialog {
        id: refSidebarGroupedDlg2
        title: "选择第 2 张参考图根目录（分组多图、两级文件夹）"
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            if (!Reference.setGroupedFolderUrl2(root.refCurrentFolder, selectedFolder)) {
                // 静默失败
            }
        }
    }
}
