#pragma once
#include <QObject>
#include <QString>

// 标题栏公告条的显隐控制桥（供 QML 按当前 tab 切换）。
// 同时也承担「标题栏原生控件状态同步」（如个人中心按钮登录态）。
// macOS：公告是叠加在 NSThemeFrame 上的原生 NSView，由 MacAppearance.mm 持有，
//        这里转发 setHidden: 给它。
// 其它平台（含 Windows）：公告尚未实现，本桥为空操作，保证 QML 侧代码统一、
//        将来 Windows 实现后无需改 QML。
class NoticeBarBridge : public QObject {
    Q_OBJECT
public:
    explicit NoticeBarBridge(QObject* parent = nullptr) : QObject(parent) {}

    // QML 调用：true = 显示公告，false = 隐藏。
    Q_INVOKABLE void setVisible(bool v);

    // QML 调用：同步标题栏「个人中心」按钮的登录态。
    // 传当前评分人名字；空串 = 未登录（恢复人像图标）。
    // macOS：转发给原生按钮，在其内部直接绘制名字（不叠子视图，保证可点击）。
    // 其它平台：Windows 标题栏为 QML 自绘，用户名在 AppMenuBar.qml 直接绑定。
    Q_INVOKABLE void setProfileUser(const QString& user);
};
