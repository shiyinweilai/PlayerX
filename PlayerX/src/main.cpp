/**
 * main.cpp — PlayerX Qt+QML 应用入口
 *
 * 第 2 阶段：注册 EngineBridge 单例给 QML，使所有视频窗共享同一引擎。
 */

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QIcon>

#include "qt/EngineBridge.h"
#include "qt/FsUtils.h"
#include "qt/RatingStore.h"
#include "qt/Updater.h"

extern "C" {
#include <libavformat/avformat.h>
}

int main(int argc, char* argv[]) {
    QGuiApplication app(argc, argv);
    app.setApplicationName("PlayerX");
    app.setOrganizationName("PlayerX");

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

    // Updater：远端 latest.json 比对 + 静默下载 + 替换 .app + relaunch。
    // 完全独立于播放内核；macOS 已完整实现，Windows 后续接 NSIS Setup。
    rbqt::Updater updater;

    QQmlApplicationEngine engine;

    // 把 engineBridge 作为 context property 暴露给 QML，名称 = "Engine"
    engine.rootContext()->setContextProperty("Engine",  &engineBridge);
    engine.rootContext()->setContextProperty("Fs",      &fsUtils);
    engine.rootContext()->setContextProperty("Rating",  &ratingStore);
    engine.rootContext()->setContextProperty("Updater", &updater);

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.loadFromModule("PlayerX", "Main");

    int rc = app.exec();
    avformat_network_deinit();
    return rc;
}
