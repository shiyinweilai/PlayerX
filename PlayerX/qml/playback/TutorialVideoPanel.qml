// ─── 教程视频面板（播放对比页空态 · 公告/教学区） ─────────────────────
// 设计参考专业视频软件（Premiere / DaVinci Resolve 的"学习"面板）：
//   · 未打开视频时，主空态区显示一个自动播放的教程视频渲染窗口；
//   · 视频静音、循环播放，不抢焦点、不接收快捷键；
//   · 面板比例固定为教程视频的 16:10（2128×1330 无边框版 = 1.6）：
//     在可用空间内等比缩放并居中，不拉伸不留黑边，窗口缩放时持续跟随；
//   · 秒开策略：首次联网把教程 mp4 缓存到 appCacheDir/tutorial/，
//     之后每次启动直接播本地文件（毫秒级出画，不再先显示占位符）；
//     启动时后台 HEAD 比对远端 Last-Modified，远端更新才重新下载；
//   · 本地缓存损坏 → 自动清缓存转在线流重试；视频完全不可用时
//     优雅回退为标题 + 提示文案（不报错）。
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia

// 外层透明占位：由布局决定可用空间（fillHeight + 列宽），
// 自身不画任何东西，只负责把内容等比放进这块空间。
Item {
    id: root

    // 教程视频路径：默认在线 URL；可在外部覆盖（如未来本地资源）
    property string tutorialSource: ""

    // 视频宽高比（宽/高）：教程源为 2128×1330 = 16:10 = 1.6（ffprobe 实测）
    property real videoAspect: 16 / 10

    // ── 秒开缓存 ──────────────────────────────────────────────
    property string cacheDir:  Fs.appCacheDir() + "/tutorial"
    property string cachePath: cacheDir + "/tutorial.mp4"
    property string partPath:  cachePath + ".part"
    property string metaPath:  cachePath + ".meta"   // 记录下载时的远端 Last-Modified
    // 当前实际播放源：有本地缓存用本地（毫秒级），否则用在线 URL
    property string activeSource: ""
    // HEAD 探测到的远端戳（Last-Modified，缺失时退回 Content-Length）
    property string remoteStamp: ""

    function toFileUrl(p) {
        // Windows 盘符路径 → file:///C:/...；macOS/Linux 绝对路径 → file:///...
        return "file://" + (p.startsWith("/") ? "" : "/") + p.replace(/\\/g, "/")
    }
    function cacheUrl() { return toFileUrl(cachePath) }

    // 启动时决定播放源：本地缓存优先
    function resolveStartupSource() {
        activeSource = Fs.fileExists(cachePath) ? cacheUrl() : tutorialSource
    }

    // 后台同步缓存：无缓存 → 下载；有缓存 → HEAD 比对远端是否更新
    // 注意：禁止在 onreadystatechange 中调用 xhr.abort()——Qt 的
    // QQmlXMLHttpRequest 在 abort 后的 finished 回调里会访问已释放的
    // QIODevice（readAll 崩溃，SIGSEGV），必须让请求自然走到 DONE。
    function syncTutorial() {
        if (!tutorialSource || !tutorialSource.toString().startsWith("http")) return
        var localStamp = Fs.fileExists(metaPath)
                         ? Fs.readTextFile(metaPath).trim() : ""
        var xhr = new XMLHttpRequest()
        xhr.open("HEAD", tutorialSource)
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status >= 200 && xhr.status < 300) {
                    var stamp = xhr.getResponseHeader("Last-Modified") || ""
                    if (!stamp) stamp = "len:" + (xhr.getResponseHeader("Content-Length") || "")
                    remoteStamp = stamp
                    var haveCache = Fs.fileExists(cachePath)
                    if (!haveCache || (stamp && stamp !== localStamp))
                        startCacheDownload()
                } else {
                    // HEAD 失败（如离线）：有缓存就继续用本地；没缓存试一次直连下载
                    if (!Fs.fileExists(cachePath)) startCacheDownload()
                }
            }
        }
        xhr.send()
    }

    function startCacheDownload() {
        // Downloader 是全局单例（与"下载测试源"共用），
        // 用户正在下载时不抢，本次跳过、下次启动再补
        if (Downloader.downloading) return
        Downloader.download(tutorialSource, partPath)
    }

    Component.onCompleted: {
        resolveStartupSource()
        syncTutorial()
    }

    // 下载完成：.part → 正式缓存（下次启动秒开）
    Connections {
        target: Downloader
        function onFinished(ok, savePath, errorMsg) {
            if (savePath !== root.partPath) return
            if (ok && Fs.renamePath(root.partPath, root.cachePath)) {
                // 记录远端戳，供下次 HEAD 比对
                if (root.remoteStamp)
                    Fs.writeTextFile(root.metaPath, root.remoteStamp)
                // 首次下载完成：当前还在放在线流且未成功出画 → 切到本地
                var st = tutorialPlayer.mediaStatus
                if (root.activeSource !== root.cacheUrl()
                        && st !== MediaPlayer.LoadedMedia
                        && st !== MediaPlayer.BufferedMedia)
                    root.activeSource = root.cacheUrl()
            } else {
                console.warn("[TutorialVideo] 缓存下载失败:", errorMsg)
            }
        }
    }

    MediaPlayer {
        id: tutorialPlayer
        source: root.activeSource
        playbackRate: 1.0
        loops: MediaPlayer.Infinite
        audioOutput: AudioOutput { muted: true }
        videoOutput: tutorialOutput
        // 资源就绪后自动播放；出错静默降级（显示占位文案）
        onMediaStatusChanged: {
            if (tutorialPlayer.mediaStatus === MediaPlayer.LoadedMedia
                    || tutorialPlayer.mediaStatus === MediaPlayer.BufferedMedia)
                tutorialPlayer.play()
        }
        onErrorOccurred: function(error, errorString) {
            console.warn("[TutorialVideo] 播放失败:", error, errorString)
            // 本地缓存损坏：清缓存 → 转在线流重试一次
            if (root.activeSource === root.cacheUrl() && root.tutorialSource) {
                Fs.removeDirRecursively(root.cacheDir)
                root.activeSource = root.tutorialSource
                root.syncTutorial()
            }
        }
    }

    // 可视面板：等比适配可用空间并居中 —— 宽受限于 高×比例，高受限于 宽/比例
    Rectangle {
        id: frame
        color: "#101014"
        radius: 10
        border.color: "#2a2a32"
        border.width: 1

        // 等比 fit：宽度先受可用宽与(可用高×比例)二者较小约束，
        // 高度由宽度反推，严格保持视频比例且不超出可用空间
        width: Math.min(root.width, root.height * root.videoAspect)
        height: width / root.videoAspect
        anchors.centerIn: parent

        VideoOutput {
            id: tutorialOutput
            anchors.fill: parent
            anchors.margins: 1   // 贴边框内侧，避免遮住 1px 描边
            visible: tutorialPlayer.mediaStatus === MediaPlayer.LoadedMedia
                     || tutorialPlayer.mediaStatus === MediaPlayer.BufferedMedia
        }

        // 回退占位：视频缺失 / 加载失败
        ColumnLayout {
            id: fallbackItem
            anchors.centerIn: parent
            spacing: 8
            visible: !tutorialOutput.visible
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "🎬"
                font.pixelSize: 40
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "软件操作教程"
                color: "#e8e8ec"
                font.pixelSize: 16
                font.bold: true
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "教程视频加载中，请稍候或检查网络"
                color: "#7a7f86"
                font.pixelSize: 12
            }
        }

        // 左上角标题角标已按用户要求移除（不保留，勿再添加）
    }
}
