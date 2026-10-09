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
    // 参考图三对话框（动态槽位版）：openForSlot(n) 指定目标槽位
    property alias refSidebarFileDlg: refSidebarFileDlg
    property alias refSidebarDirDlg: refSidebarDirDlg
    property alias refSidebarGroupedDlg: refSidebarGroupedDlg

    FileDialog {
        id: addDialog
        title: "添加视频文件（可多选）"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "视频文件 (*.mp4 *.mov *.mkv *.avi *.webm *.flv *.ts *.m4v *.wmv *.y4m *.yuv *.h264 *.h265 *.hevc)",
            "所有文件 (*)"
        ]
        onAccepted: {
            // 从空状态打开 → 与"拖拽多文件"保持一致：直接横向铺开（1×N 横排）。
            // 已有视频时 → 维持原"逐个 addFile"的追加语义（不打断当前对比）。
            if (Engine.fileCount === 0) {
                if (selectedFiles.length === 1) {
                    // 单个文件：直接打开即可，不进 active 态（用户没想进队列模式）
                    Engine.openFiles(selectedFiles)
                } else if (selectedFiles.length > 1) {
                    // 多个文件：直接横向铺开（等价于拖拽多个文件到窗口）。
                    var arr = selectedFiles
                    if (arr.length > 9) arr = arr.slice(0, 9)
                    // 确保横向铺开：layoutMode=1（SideBySide）。若用户此前手动
                    // 切到了 Single/宫格，这里强制回到横排，避免多选后只看到一路。
                    if (Engine.layoutMode !== 1) Engine.layoutMode = 1
                    Engine.openFiles(arr)
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

    // ── 参考图三对话框（动态槽位版）────────────────────────────────
    // openForSlot(slot)：先记住目标槽位再打开；onAccepted 按 slot 写入。
    // slot=1 时走旧 API 名（kind/path），≥2 走 kindN/pathN —— 但持久化层已统一，
    // 直接调 setReference*At 即可。

    // 选择单张参考图（image 模式）
    FileDialog {
        id: refSidebarFileDlg
        title: "选择参考图（固定图）"
        nameFilters: [ "图片 (*.png *.jpg *.jpeg *.webp *.bmp *.gif)" ]
        fileMode: FileDialog.OpenFile
        property int targetSlot: 1
        function openForSlot(slot) {
            targetSlot = slot
            open()
        }
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            Reference.setReferenceUrlAt(root.refCurrentFolder, selectedFile, targetSlot)
        }
    }

    // 选择参考图文件夹（folder 模式 → 跟随对比组同步切换）
    FolderDialog {
        id: refSidebarDirDlg
        title: "选择参考图文件夹（跟随对比组）"
        property int targetSlot: 1
        function openForSlot(slot) {
            targetSlot = slot
            open()
        }
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            if (!Reference.setReferenceFolderUrlAt(root.refCurrentFolder, selectedFolder, targetSlot)) {
                // 选错了空文件夹时静默失败；用户能从「占位提示」看到"未绑定"再次操作。
            }
        }
    }

    // 选择「分组多图」根目录（grouped 模式）
    //   预期结构：root/组A/图1.jpg · root/组A/图2.jpg · root/组B/图1.jpg ...
    FolderDialog {
        id: refSidebarGroupedDlg
        title: "选择参考图根目录（分组多图、两级文件夹）"
        property int targetSlot: 1
        function openForSlot(slot) {
            targetSlot = slot
            open()
        }
        onAccepted: {
            if (root.refCurrentFolder.length === 0) return
            if (!Reference.setGroupedFolderUrlAt(root.refCurrentFolder, selectedFolder, targetSlot)) {
                // 路径结构不符合（无子目录 / 子目录里无图片）时静默失败。
            }
        }
    }
}
