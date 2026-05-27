/**
 * ScreenProbe.cpp — 非 APPLE 平台（Windows/Linux）的回退实现
 *
 * macOS 走同目录下的 ScreenProbe.mm（Cocoa NSScreen + CoreGraphics 原生 API），
 * 由 CMakeLists.txt 按平台二选一加入编译列表。
 *
 * 本文件文件名 stem 与 ScreenProbe.h 一致，AUTOMOC 会自动把 moc_ScreenProbe.cpp
 * 挂接到本 TU，无需手动 include moc 输出。
 */
#include "ScreenProbe.h"

#include <QGuiApplication>
#include <QRect>
#include <QScreen>
#include <QWindow>

namespace rbqt {

// 非 APPLE 平台不需要平台私有状态，留个空 Impl 让 .h 里 PIMPL 形状保持一致。
class ScreenProbeImpl {
public:
    explicit ScreenProbeImpl(ScreenProbe* /*owner*/) {}
    ~ScreenProbeImpl() = default;
};

ScreenProbe::ScreenProbe(QObject* parent) : QObject(parent) {
    m_impl = new ScreenProbeImpl(this);
}

ScreenProbe::~ScreenProbe() {
    delete m_impl;
    m_impl = nullptr;
}

QVariantMap ScreenProbe::currentForWindow(QObject* windowObj) const {
    QVariantMap m;
    if (!windowObj) return m;
    auto* qw = qobject_cast<QWindow*>(windowObj);
    if (!qw) return m;
    QScreen* s = qw->screen();
    if (!s) s = QGuiApplication::primaryScreen();
    if (!s) return m;
    const QRect g = s->geometry();
    const qreal pd = s->physicalDotsPerInch() / 25.4;
    const qreal dpr = s->devicePixelRatio();
    m.insert("width",            g.width());
    m.insert("height",           g.height());
    m.insert("pixelDensity",     pd);
    m.insert("devicePixelRatio", dpr);
    m.insert("name",             s->name());
    return m;
}

} // namespace rbqt
