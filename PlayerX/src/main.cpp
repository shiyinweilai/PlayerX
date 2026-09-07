/**
 * main.cpp — PlayerX Qt+QML 应用入口
 *
 * 第 2 阶段：注册 EngineBridge 单例给 QML，使所有视频窗共享同一引擎。
 *
 * 启动早期会把 stderr 与 Qt 日志（qDebug/qInfo/qWarning/...）一同写入
 *   <appCacheDir>/logs/playerx_YYYYMMDD_HHmmss.log
 * 用于事后排查问题（用户可在「设置」菜单里点「打开日志目录」直达）。
 */

// QtGlobal 必须先包含，才能让 Q_OS_MACOS / Q_OS_WIN 等平台宏被定义；
// 否则下面的 #if defined(Q_OS_MACOS) 判断恒为假，会错走到 #else 分支
// 去 include <QApplication>（mac/win 已不链接 QtWidgets，会报头文件找不到）。
#include <QtGlobal>

// macOS 走平台原生多选目录对话框（NSOpenPanel），不依赖 QtWidgets，
// 因此用 QGuiApplication 即可，包体更小。
// Windows / Linux 等其他平台走 Qt 自绘 QFileDialog 兜底，需要 QApplication（Widgets）。
#if defined(Q_OS_MACOS)
#  include <QGuiApplication>
#else
#  include <QApplication>
#endif
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QIcon>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>
#include <QtGlobal>
#include <QMessageLogContext>
#include <QString>
#include <QByteArray>
#include <QList>
#include <algorithm>

#include <cstdio>

#include "qt/EngineBridge.h"
#include "qt/FileDownloader.h"
#include "qt/FsUtils.h"
#include "qt/RatingStore.h"
#include "qt/ReferenceStore.h"
#include "qt/ScreenProbe.h"
#include "qt/NoticeBarBridge.h"
#include "qt/Updater.h"
#include "yuv/YuvBridge.h"
#include "yuv/YuvDisplayItem.h"
#include "yuv/YuvSliderCompareItem.h"
#include "stream/RBStreamBridge.h"
#include "image/ImageBridge.h"
#include "image/ImageDisplayItem.h"
#include "image/ImageSliderCompareItem.h"

extern "C" {
#include <libavformat/avformat.h>
}

#if defined(Q_OS_MACOS)
// 实现在 src/qt/MacAppearance.mm（Objective-C++）：
// 强制 NSApp 深色外观，让系统标题栏 / 原生菜单 / 原生对话框渲染为深色。
void applyMacDarkAppearance();
// 标题栏「右侧栏」切换按钮（macOS 原生标题栏 AppKit，挂在标题栏右侧）
void installTitleBarSidebarButton(QQuickWindow* win, void* ctx, void(*fn)(void*));
// 标题栏「个人中心」按钮（macOS 原生标题栏 AppKit，点击打开登录/个人信息）
void installTitleBarProfileButton(QQuickWindow* win, void* ctx, void(*fn)(void*));
// 登录菜单展开拦截：菜单栏「登录/评分人名」点击时在 menuWillOpen 阶段
// 取消展开（永不出下拉）并回调此处，转而打开 QML 登录对话框。
void installLoginMenuSuppressor(void* ctx, void(*fn)(void*));
// 标题栏公告文字（macOS 原生标题栏内嵌，红绿灯右侧标题位置，
// 不占内容区；文字放不下时左右往复滚动）。
void installTitleBarNotice(QQuickWindow* win, const char* text);
static void openLoginDialogFromNative(void* ctx) {
    // ctx = QML 根对象；QueuedConnection 保证回到 Qt 主事件循环再开对话框
    QMetaObject::invokeMethod(static_cast<QObject*>(ctx),
                              "_openLoginDialogFromNative", Qt::QueuedConnection);
}
// 标题栏右侧栏按钮点击回调：转发到 QML 根对象的 _onTitleBarSidebarToggle()
static void onTitleBarSidebarToggleFromNative(void* ctx) {
    QMetaObject::invokeMethod(static_cast<QObject*>(ctx),
                              "_onTitleBarSidebarToggle", Qt::QueuedConnection);
}
#endif

#if defined(Q_OS_WIN)
// 实现在 src/qt/WinTitleBar.cpp：
// DWM 沉浸式深色标题栏 + Win11 精确配色（#101012 底色 / 浅色文字）。
void applyWindowsDarkTitleBar(QQuickWindow* win);
#endif

namespace {

// ── 日志路径（启动后保持不变，菜单项「打开日志目录」从这里取目录） ──
static QString g_logFilePath;

// 计算并准备好日志目录与本次运行的日志文件路径。
// 路径与 FsUtils::appLogDir 保持一致：<CacheLocation>/logs。
//
// 文件名格式：playerx_<unix_timestamp>_<NN>.log
//   - <unix_timestamp>：秒级时间戳，天然单调递增，一眼可看出"哪个最新"
//   - <NN>：两位十进制序号（00~99），同一秒内多次启动时递增，确保不撞名
//   示例：playerx_1755900000_03.log（第 3 次启动且时间戳为 1755900000）
//
// 日志轮转策略（最多保留 kKeepCount 份）：
//   ① 扫描目录下所有 playerx_*.log，按文件名中的时间戳+序号降序排列（最新在前）
//   ② 保留前 kKeepCount 个，其余全部删除
//   ③ 总大小上限兜底：即使文件数 ≤ kKeepCount，若总和超过 kMaxTotalBytes，
//      从最旧的开始删，直到总和 ≤ 上限
// 这样既满足"最多 10 份日志"的硬上限，又能防止单份日志过大撑爆磁盘。
static QString prepareLogFilePath() {
    QString cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    if (cache.isEmpty()) cache = QDir::homePath() + "/.playerx_cache";
    QString logDir = cache + "/logs";
    QDir().mkpath(logDir);

    // ── 计算本次序号：取已有日志中的最大序号 +1，每次启动序号都递增 ──
    //   旧逻辑只在"同一秒内多次启动"时才递增，正常使用间隔超过 1 秒 → 永远是 00。
    //   新逻辑扫描所有 playerx_*.log 的序号，取最大值 +1，使每次启动序号都不同。
    //   序号范围 00~99，溢出后回绕到 00（约 100 次启动才回绕一次，此时时间戳已不同，不会撞名）。
    qint64 nowSecs = QDateTime::currentSecsSinceEpoch();
    int seq = 0;
    {
        QDir d(logDir);
        int maxSeq = -1;
        for (const QFileInfo& fi : d.entryInfoList({"playerx_*.log"}, QDir::Files | QDir::NoSymLinks)) {
            QString base = fi.completeBaseName();   // e.g. "playerx_1755900000_03"
            int lastUnderscore = base.lastIndexOf('_');
            if (lastUnderscore >= 0) {
                QString seqStr = base.mid(lastUnderscore + 1);
                bool ok = false;
                int s = seqStr.toInt(&ok);
                if (ok && s > maxSeq) maxSeq = s;
            }
        }
        seq = (maxSeq + 1) % 100;  // 00~99 循环递增
    }

    // ── 旧日志清理 ──
    {
        constexpr int    kKeepCount     = 10;                  // 最多保留 10 份日志
        constexpr qint64 kMaxTotalBytes = 20LL * 1024 * 1024;  // 总大小不超过 20 MB

        QDir d(logDir);
        QFileInfoList all = d.entryInfoList({"playerx_*.log"},
                                            QDir::Files | QDir::NoSymLinks,
                                            QDir::Name);  // 按文件名升序

        // 按文件名降序排列（时间戳+序号大的在前 = 最新在前）
        std::sort(all.begin(), all.end(), [](const QFileInfo& a, const QFileInfo& b) {
            return a.fileName() > b.fileName();
        });

        // ① 数量裁剪：保留前 kKeepCount 个，其余删除
        if (all.size() > kKeepCount) {
            for (int i = kKeepCount; i < all.size(); ++i) {
                QFile::remove(all.at(i).absoluteFilePath());
            }
            all = all.mid(0, kKeepCount);
        }

        // ② 总大小裁剪：从最新往最旧累计；累计值首次超过上限的那一刻起，
        //    后续（更旧的）全部删掉。这样保证留下来的都是"最新一批"。
        qint64 acc = 0;
        for (int i = 0; i < all.size(); ++i) {
            acc += all.at(i).size();
            if (acc > kMaxTotalBytes && i + 1 < all.size()) {
                for (int j = i + 1; j < all.size(); ++j) {
                    QFile::remove(all.at(j).absoluteFilePath());
                }
                break;
            }
        }
    }

    QString seqStr = QString("%1").arg(seq, 2, 10, QChar('0'));   // 两位补零
    return logDir + "/playerx_" + QString::number(nowSecs) + "_" + seqStr + ".log";
}

// Qt 日志 handler：把 qDebug/qInfo/qWarning/... 同时输出到 stderr（已被重定向到文件）。
// 由于我们在 install 之前用 freopen 把 stderr 指向日志文件，这里写 stderr 等价于写日志文件。
static void rbMessageHandler(QtMsgType type,
                             const QMessageLogContext& ctx,
                             const QString& msg) {
    Q_UNUSED(ctx);
    const char* lvl = "DBG";
    switch (type) {
        case QtDebugMsg:    lvl = "DBG"; break;
        case QtInfoMsg:     lvl = "INF"; break;
        case QtWarningMsg:  lvl = "WRN"; break;
        case QtCriticalMsg: lvl = "ERR"; break;
        case QtFatalMsg:    lvl = "FTL"; break;
    }
    QByteArray ts = QDateTime::currentDateTime()
                        .toString("HH:mm:ss.zzz").toUtf8();
    QByteArray line = msg.toUtf8();
    std::fprintf(stderr, "[%s][%s] %s\n", ts.constData(), lvl, line.constData());
    std::fflush(stderr);
}

// 把 stderr 重定向到日志文件；安装 Qt 日志 handler，确保 qDebug 等也落盘。
// 失败时不阻断启动，仅放弃日志记录。
static void installLogging() {
    g_logFilePath = prepareLogFilePath();
    // freopen 后所有 fprintf(stderr,...) 与 Qt 默认 stderr 输出都进文件。
    if (std::freopen(g_logFilePath.toLocal8Bit().constData(),
                     "a", stderr) == nullptr) {
        // 重定向失败：保持原 stderr，仍能用 qInstallMessageHandler 控制 Qt 日志，
        // 但 fprintf(stderr,...) 输出去向取决于宿主终端。
    } else {
        // 行缓冲：每行刷新，崩溃前的最后日志不会丢。
        std::setvbuf(stderr, nullptr, _IOLBF, 0);
    }
    qInstallMessageHandler(rbMessageHandler);
    std::fprintf(stderr,
                 "==== PlayerX log start: %s ====\n",
                 QDateTime::currentDateTime()
                     .toString(Qt::ISODate).toUtf8().constData());
    std::fflush(stderr);
}

} // namespace

int main(int argc, char* argv[]) {
    // 应用对象：macOS 走 QGuiApplication（不依赖 QtWidgets，包体更小），
    // Windows / 其他平台走 QApplication（FsUtils 多选目录的 Qt 自绘兜底需要它）。
#if defined(Q_OS_MACOS)
    QGuiApplication app(argc, argv);
#else
    QApplication app(argc, argv);
#endif
    app.setApplicationName("PlayerX");
    app.setOrganizationName("PlayerX");

#if defined(Q_OS_MACOS)
    // 强制深色外观（Dark Aqua）：标题栏 / 原生菜单 / 原生对话框全部深色，
    // 与 #101012 主题协调；需在窗口创建前调用。
    applyMacDarkAppearance();
#endif

    // QStandardPaths 依赖 applicationName/organizationName，先设好再装日志。
    installLogging();

    // 运行时窗口图标：Windows 任务栏 / Alt-Tab / Linux WM / macOS Dock fallback
    // 都从这里取（exe 内 .rsrc 嵌的 .ico 只管"静态文件图标"，不管运行中 HICON）。
    // 资源由 CMake AUTORCC 处理 resources/app_icon.qrc 自动打进 exe。
    app.setWindowIcon(QIcon(":/icon/app.png"));

    // 使用 Basic 风格，自绘 background/contentItem 委托才能生效。
    // macOS 默认会套用原生 NSButton 风格 → 自绘失效、无 hover/press 反馈。
    QQuickStyle::setStyle("Basic");

    avformat_network_init();

    // EngineBridge 必须先于 engine.load 创建，且生命周期 >= QML 引擎
    rbqt::EngineBridge engineBridge;

    // FsUtils：仅供 QML 多组对比模式配置面板使用的纯工具类（文件夹扫描等）。
    // 不与播放内核交互，单组模式下 QML 不会调用任何方法 → 行为零变化。
    rbqt::FsUtils fsUtils;

    // FileDownloader：异步文件下载器，供 QML 测试源下载使用。
    // 用 QNetworkAccessManager 异步下载，不阻塞 UI 线程，通过信号回传进度和结果。
    rbqt::FileDownloader fileDownloader;

    // RatingStore：视频评分的本地 CSV 持久化（覆盖式，按 file_path+rater 唯一）。
    // 完全独立于播放内核，仅暴露给 QML 用于评分写入/导出/查看。
    rbqt::RatingStore ratingStore;

    // ReferenceStore：文件夹「参考图」绑定的本地 ini 持久化，仅供 QML 侧边栏使用。
    // 与播放内核完全解耦。
    rbqt::ReferenceStore referenceStore;

    // Updater：远端 latest.json 比对 + 静默下载 + 替换 .app + relaunch。
    // 完全独立于播放内核；macOS 已完整实现，Windows 后续接 NSIS Setup。
    rbqt::Updater updater;

    // ScreenProbe：主动探测当前窗口所在屏幕的真实状态（绕开 QML Screen 附加属性
    // 在 macOS 外接屏切档位时的缓存丢信号问题）。无状态、轻量。
    rbqt::ScreenProbe screenProbe;

    // YuvBridge：YUV 裸数据分析工具桥接（独立窗口，不与主播放器联动）
    YuvBridge yuvBridge;

    // StreamBridge：码流分析工具桥接（独立窗口，不与主播放器联动）。
    // 多 slot 设计，结构与 YuvBridge 一致；一期仅提供顶层流参数 / 帧类型 / GOP
    // 统计，块级深度信息返回空数组（见 码流分析架构.md §4 的 FFmpeg 补丁路径）。
    RBStreamBridge streamBridge;

    // ImageBridge：图片分析工具桥接（独立模块，用 QImageReader 加载图片）
    ImageBridge imageBridge;

    // NoticeBarBridge：标题栏公告条显隐（macOS 生效，其它平台空操作）
    NoticeBarBridge noticeBarBridge;

    QQmlApplicationEngine engine;

    // 把 engineBridge 作为 context property 暴露给 QML，名称 = "Engine"
    engine.rootContext()->setContextProperty("Engine",      &engineBridge);
    engine.rootContext()->setContextProperty("Fs",          &fsUtils);
    engine.rootContext()->setContextProperty("Downloader",  &fileDownloader);
    engine.rootContext()->setContextProperty("Rating",      &ratingStore);
    engine.rootContext()->setContextProperty("Reference",   &referenceStore);
    engine.rootContext()->setContextProperty("Updater",     &updater);
    engine.rootContext()->setContextProperty("ScreenProbe", &screenProbe);
    engine.rootContext()->setContextProperty("YuvBridge",   &yuvBridge);
    engine.rootContext()->setContextProperty("StreamBridge", &streamBridge);
    engine.rootContext()->setContextProperty("ImageBridge",  &imageBridge);
    // 标题栏公告条显隐控制（QML 按当前 tab 调用；非 mac 平台为空操作）。
    engine.rootContext()->setContextProperty("NoticeBar",    &noticeBarBridge);

    // 注册 YuvDisplayItem 为 QML 类型（供 YuvWindow.qml 使用）。
    // URI 用独立前缀，避免和 qt_add_qml_module(URI PlayerX) 冲突。
    qmlRegisterType<YuvDisplayItem>("PlayerX.YuvTools", 1, 0, "YuvDisplayItem");

    // 注册 YuvSliderCompareItem（YUV 双路滑动对比渲染组件）。
    qmlRegisterType<YuvSliderCompareItem>("PlayerX.YuvTools", 1, 0, "YuvSliderCompareItem");

    // 注册 ImageDisplayItem（图片分析渲染组件，物理像素级渲染）。
    qmlRegisterType<ImageDisplayItem>("PlayerX.ImageTools", 1, 0, "ImageDisplayItem");

    // 注册 ImageSliderCompareItem（图片双路滑动对比渲染组件）。
    qmlRegisterType<ImageSliderCompareItem>("PlayerX.ImageTools", 1, 0, "ImageSliderCompareItem");

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.loadFromModule("PlayerX", "Main");

    const QObjectList rootObjs = engine.rootObjects();

#if defined(Q_OS_MACOS)
    // 标题栏「个人中心」按钮（最左）+「右侧栏」切换按钮（最右）+ 登录菜单展开拦截。
    if (!rootObjs.isEmpty()) {
        installTitleBarProfileButton(qobject_cast<QQuickWindow*>(rootObjs.first()),
                                     rootObjs.first(), &openLoginDialogFromNative);
        installTitleBarSidebarButton(qobject_cast<QQuickWindow*>(rootObjs.first()),
                                     rootObjs.first(), &onTitleBarSidebarToggleFromNative);
        installLoginMenuSuppressor(rootObjs.first(), &openLoginDialogFromNative);
        // 标题栏公告文字（放在红绿灯右侧、标题位置，不占内容区；
        // 放不下时左右往复滚动）。内容即打分原则提示。
        installTitleBarNotice(qobject_cast<QQuickWindow*>(rootObjs.first()),
                              "打分原则: 相对分更重要，完全符合提示词无物理问题五分，三个视频中更差的要多扣更多分，体现出好坏。");
        // 【补一次登录态同步】QML 的 Component.onCompleted 早于此处安装原生按钮，
        // 那次调用因 g_profileBtn 为 nil 被丢弃；而 currentUser 是持久化值、
        // 启动后不再变化，不会触发 currentUserChanged → 按钮会停在图标态。
        QMetaObject::invokeMethod(rootObjs.first(), "syncNoticeBar", Qt::QueuedConnection);
    }
#endif

#if defined(Q_OS_WIN)
    // QML 窗口 visible:true，load 返回时原生句柄已存在，立即深色化标题栏。
    if (!rootObjs.isEmpty()) {
        applyWindowsDarkTitleBar(qobject_cast<QQuickWindow*>(rootObjs.first()));
    }
#endif

    int rc = app.exec();
    avformat_network_deinit();
    return rc;
}
