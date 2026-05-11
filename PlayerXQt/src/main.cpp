/**
 * main.cpp — PlayerXQt Qt+QML 应用入口
 *
 * 第 1 阶段最小目标：
 *   - 启动 QGuiApplication，加载 qrc 中的 Main.qml
 *   - QML 中通过 VideoFrameProvider QML 类型显示视频
 */

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QIcon>

extern "C" {
#include <libavformat/avformat.h>
}

int main(int argc, char* argv[]) {
    // 高 DPI 在 Qt 6 默认开启，无需 setAttribute
    QGuiApplication app(argc, argv);
    app.setApplicationName("PlayerXQt");
    app.setOrganizationName("PlayerX");

    // 选用现代风格的 Quick Controls 样式（Mac/Win 都可用）
    QQuickStyle::setStyle("Fusion");

    // FFmpeg 全局初始化（4.0+ 不再需要 av_register_all，但 network init 仍需要）
    avformat_network_init();

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

    engine.loadFromModule("PlayerXQt", "Main");

    int rc = app.exec();
    avformat_network_deinit();
    return rc;
}
