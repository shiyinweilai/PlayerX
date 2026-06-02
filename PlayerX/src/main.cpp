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
#include <QIcon>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>
#include <QtGlobal>
#include <QMessageLogContext>
#include <QString>
#include <QByteArray>

#include <cstdio>

#include "qt/EngineBridge.h"
#include "qt/FsUtils.h"
#include "qt/RatingStore.h"
#include "qt/ReferenceStore.h"
#include "qt/ScreenProbe.h"
#include "qt/Updater.h"

extern "C" {
#include <libavformat/avformat.h>
}

namespace {

// ── 日志路径（启动后保持不变，菜单项「打开日志目录」从这里取目录） ──
static QString g_logFilePath;

// 计算并准备好日志目录与本次运行的日志文件路径。
// 路径与 FsUtils::appLogDir 保持一致：<CacheLocation>/logs。
//
// 同时清理过旧日志，避免无限增长：
//   ① 数量上限：仅保留最近 kKeepCount 个 playerx_*.log（按修改时间倒序）
//   ② 总大小上限：超过 kMaxTotalBytes 时，从最旧的开始删，直到总和 ≤ 上限
// 两条规则并行生效，谁先命中谁先删。这样既能避免文件数过多（用户终端
// 被无限文件污染），也能防止单次长跑写出超大日志撑爆磁盘。
static QString prepareLogFilePath() {
    QString cache = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    if (cache.isEmpty()) cache = QDir::homePath() + "/.playerx_cache";
    QString logDir = cache + "/logs";
    QDir().mkpath(logDir);

    // 旧日志清理
    {
        constexpr int      kKeepCount     = 100;                  // 保留最近 100 个文件
        constexpr qint64   kMaxTotalBytes = 100LL * 1024 * 1024;  // 总大小不超过 100 MB

        QDir d(logDir);
        QFileInfoList olds = d.entryInfoList({"playerx_*.log"},
                                              QDir::Files | QDir::NoSymLinks,
                                              QDir::Time);  // 最新在前

        // ① 数量裁剪
        for (int i = kKeepCount; i < olds.size(); ++i) {
            QFile::remove(olds.at(i).absoluteFilePath());
        }
        if (olds.size() > kKeepCount) olds = olds.mid(0, kKeepCount);

        // ② 总大小裁剪：从最新往最旧累计；累计值首次超过上限的那一刻起，
        //    后续（更旧的）全部删掉。这样保证留下来的都是"最新一批"。
        qint64 acc = 0;
        for (int i = 0; i < olds.size(); ++i) {
            acc += olds.at(i).size();
            if (acc > kMaxTotalBytes && i + 1 < olds.size()) {
                for (int j = i + 1; j < olds.size(); ++j) {
                    QFile::remove(olds.at(j).absoluteFilePath());
                }
                break;
            }
        }
    }

    QString stamp = QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss");
    return logDir + "/playerx_" + stamp + ".log";
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

    QQmlApplicationEngine engine;

    // 把 engineBridge 作为 context property 暴露给 QML，名称 = "Engine"
    engine.rootContext()->setContextProperty("Engine",      &engineBridge);
    engine.rootContext()->setContextProperty("Fs",          &fsUtils);
    engine.rootContext()->setContextProperty("Rating",      &ratingStore);
    engine.rootContext()->setContextProperty("Reference",   &referenceStore);
    engine.rootContext()->setContextProperty("Updater",     &updater);
    engine.rootContext()->setContextProperty("ScreenProbe", &screenProbe);

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.loadFromModule("PlayerX", "Main");

    int rc = app.exec();
    avformat_network_deinit();
    return rc;
}
