/**
 * ScreenProbe_generic.cpp — 非 APPLE 平台的回退实现
 *
 * macOS 走 ScreenProbe.mm（Cocoa NSScreen 原生 API）；
 * 其他平台（Windows/Linux）回退到 Qt QScreen。
 * 注意：本文件仅在非 APPLE 时被 CMake 加入编译列表。
 */
#include "ScreenProbe.h"

#include <QGuiApplication>
#include <QRect>
#include <QScreen>
#include <QWindow>

namespace rbqt {

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
