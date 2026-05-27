/**
 * ScreenProbe.h — 主动探测当前活动窗口所在屏幕的真实状态
 *
 * 背景：
 *   QML 里 `Screen` 附加属性（QQuickScreenAttached）以及 QScreen 在 macOS 上
 *   切换"外接显示器缩放档位"（如 PHL 278B1）时，存在长期的"changed 信号
 *   不发 / 缓存值不刷新"问题，导致 QML 端的自适应逻辑感知不到档位变化。
 *
 *   ScreenProbe 在 macOS 上**绕开整个 Qt screen 子系统**，直接走 Cocoa 原生
 *   `NSScreen` API 取实时值；并订阅系统级
 *     NSApplicationDidChangeScreenParametersNotification
 *   通知 → 转发为 Qt 信号 `screenParamsChanged()`，让 QML 能事件驱动地立即
 *   重算（不再需要轮询）。
 *
 *   非 macOS 平台保留 Qt QScreen 路径作为回退，行为等价于直接 QML 访问。
 *
 * 使用：
 *   QML 端通过 contextProperty "ScreenProbe" 调用：
 *     Connections {
 *         target: ScreenProbe
 *         function onScreenParamsChanged() { ... }
 *     }
 *     var st = ScreenProbe.currentForWindow(rootWindow)
 *     var w  = st.width, pd = st.pixelDensity, nm = st.name
 *
 *   纯只读 / 无副作用 / 不持有任何窗口指针；与播放内核完全解耦。
 */
#pragma once

#include <QObject>
#include <QVariantMap>

class QWindow;

namespace rbqt {

class ScreenProbeImpl;  // 平台私有实现（macOS 用，桥到 NSNotificationCenter）

class ScreenProbe : public QObject {
    Q_OBJECT
public:
    explicit ScreenProbe(QObject* parent = nullptr);
    ~ScreenProbe() override;

    // 返回给定窗口当前实际所在屏幕的关键参数。
    // 字段：width / height（逻辑像素）、pixelDensity（物理像素/mm，与 QML
    // Screen.pixelDensity 同口径）、devicePixelRatio、name。
    // 任何参数无效时（窗口为 null 或未关联屏幕），返回空 map。
    Q_INVOKABLE QVariantMap currentForWindow(QObject* windowObj) const;

signals:
    // 系统级"显示参数已变化"事件转发：
    //   · macOS：NSApplicationDidChangeScreenParametersNotification
    //   · 其他平台：保留接口（暂不发射，由 QML 端 1.5s 轮询兜底）
    // QML 端连上即可在用户切换缩放档位 / 接拔显示器 / 改分辨率时立刻重算。
    void screenParamsChanged();

private:
    // 仅 macOS 平台下持有；其他平台为 nullptr。
    ScreenProbeImpl* m_impl = nullptr;
};

} // namespace rbqt
