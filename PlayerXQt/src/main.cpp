/**
 * main.cpp — PlayerXQt Qt+QML 应用入口
 *
 * 第 2 阶段：注册 EngineBridge 单例给 QML，使所有视频窗共享同一引擎。
 */

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QIcon>

#include "qt/EngineBridge.h"

extern "C" {
#include <libavformat/avformat.h>
}

int main(int argc, char* argv[]) {
    QGuiApplication app(argc, argv);
    app.setApplicationName("PlayerXQt");
    app.setOrganizationName("PlayerX");

    QQuickStyle::setStyle("Fusion");

    avformat_network_init();

    // EngineBridge 必须先于 engine.load 创建，且生命周期 >= QML 引擎
    rbqt::EngineBridge engineBridge;

    QQmlApplicationEngine engine;

    // 把 engineBridge 作为 context property 暴露给 QML，名称 = "Engine"
    engine.rootContext()->setContextProperty("Engine", &engineBridge);

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.loadFromModule("PlayerXQt", "Main");

    int rc = app.exec();
    avformat_network_deinit();
    return rc;
}
