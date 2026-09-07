#pragma once
#include <QObject>

// 标题栏公告条的显隐控制桥（供 QML 按当前 tab 切换）。
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
};
