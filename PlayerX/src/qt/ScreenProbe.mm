/**
 * ScreenProbe.mm — 见同名 .h
 *
 * 关键设计（macOS）：
 *   ┌──────────────────────────────────────────────────────────────────────┐
 *   │ 数据源走 CoreGraphics（CGDisplay*），不走 NSScreen                    │
 *   └──────────────────────────────────────────────────────────────────────┘
 *
 *   原因：NSScreen 的内部缓存依赖 AppKit drain 主 RunLoop 通知队列才会
 *   刷新；当 PlayerX 不是前台 App、或 Qt 事件循环在切档位时刚好被某些操作
 *   阻塞时，AppKit 通知会积压，[NSScreen screens] 返回的就是旧值。
 *   表现就是用户报告的：「第一次切有效，再切就停了；切到别的软件再切回来
 *   就刷新了」——这正是"通知积压在 mainQueue，App 重新激活时一次性 drain"
 *   的特征。
 *
 *   CoreGraphics 的 CGDisplay* API 是 framework 直接调用 WindowServer 的
 *   IPC 拿当前值，与 AppKit 通知队列、Qt 事件循环都无关，**任何时候调用
 *   返回的都是 WindowServer 此刻的真实状态**。这是 macOS 显示参数最权威、
 *   最早可见的源头（NSScreen 是它的 Cocoa 包装，理论上同源但有缓存层）。
 *
 *   通知监听仍然保留作为"事件驱动"的最佳入口（应用前台时切档位会立刻发），
 *   但不再是正确性的依赖——即使通知被吞，QML 端 2s 轮询调用 currentForWindow()
 *   也能立刻拿到 WindowServer 的最新值并重算系数。
 */
#include "ScreenProbe.h"

#include <QGuiApplication>
#include <QPoint>
#include <QRect>
#include <QScreen>
#include <QWindow>

#ifdef __APPLE__
#  import <AppKit/AppKit.h>
#  include <CoreGraphics/CoreGraphics.h>
#endif

namespace rbqt {

#ifdef __APPLE__

// ─── macOS：用 ObjC observer 桥接系统通知 ────────────────────────────────────
class ScreenProbeImpl {
public:
    explicit ScreenProbeImpl(ScreenProbe* owner);
    ~ScreenProbeImpl();
private:
    id m_observer = nil;  // NSNotificationCenter 返回的 observer token
};

} // namespace rbqt

// 通知抵达后，把信号 emit 派发到 Qt 主线程。即便此时 NSScreen 缓存还没刷新，
// 只要 QML 端拿到信号后调 currentForWindow() 就会走 CoreGraphics 实时拿值，
// 仍然能拿到最新数据。
static void rb_emit_screen_params_changed(rbqt::ScreenProbe* owner) {
    if (!owner) return;
    QMetaObject::invokeMethod(owner, "screenParamsChanged", Qt::QueuedConnection);
}

namespace rbqt {

ScreenProbeImpl::ScreenProbeImpl(ScreenProbe* owner) {
    // queue:nil → block 在通知 post 的线程**同步**回调（通常是主线程）。
    // 不用 [NSOperationQueue mainQueue]，避免再次进入 mainQueue → 依赖 Qt drain
    // 的链路。这里 ObjC block 内只做一次 invokeMethod(QueuedConnection)，开销
    // 极小且线程安全（QObject 跨线程信号 emit 由 Qt 自己 marshall）。
    m_observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* /*note*/) {
                    rb_emit_screen_params_changed(owner);
                }];
}

ScreenProbeImpl::~ScreenProbeImpl() {
    if (m_observer) {
        [[NSNotificationCenter defaultCenter] removeObserver:m_observer];
        m_observer = nil;
    }
}

#else  // 非 APPLE 平台：占位实现

class ScreenProbeImpl {
public:
    explicit ScreenProbeImpl(ScreenProbe* /*owner*/) {}
    ~ScreenProbeImpl() = default;
};

#endif

ScreenProbe::ScreenProbe(QObject* parent) : QObject(parent) {
    m_impl = new ScreenProbeImpl(this);
}

ScreenProbe::~ScreenProbe() {
    delete m_impl;
    m_impl = nullptr;
}

#ifdef __APPLE__
namespace {

// 从全部活动 display 里挑出"包含锚点 (x,y)"的那一块。坐标系按 macOS 全局
// 坐标（主屏左上为原点，y 向下）。失败回退到主显示器。
//
// 注意：CGDisplayBounds 与 NSScreen.frame 的 y 轴方向不同——前者是"主屏顶
// 左为原点 y 向下"（与 Qt 一致），后者是 Cocoa 翻转坐标。我们这里用
// CGDisplay 全程，与 Qt 窗口几何的坐标系一致，无需翻转。
CGDirectDisplayID rb_pick_display_for_point(CGPoint p) {
    const uint32_t kMax = 16;
    CGDirectDisplayID ids[kMax] = {0};
    uint32_t count = 0;
    if (CGGetActiveDisplayList(kMax, ids, &count) != kCGErrorSuccess || count == 0) {
        return CGMainDisplayID();
    }
    for (uint32_t i = 0; i < count; ++i) {
        CGRect b = CGDisplayBounds(ids[i]);
        if (CGRectContainsPoint(b, p)) return ids[i];
    }
    return CGMainDisplayID();
}

// 取 display 的 backingScaleFactor（DPR）。CoreGraphics 没有直接 API，
// 用「pixelsWide / boundsWidth」算出来——两者都是 CG 实时值，
// 不会受 AppKit 缓存影响。
qreal rb_dpr_for_display(CGDirectDisplayID dispId) {
    CGRect b = CGDisplayBounds(dispId);          // 逻辑分辨率（pt）
    size_t pxW = CGDisplayPixelsWide(dispId);    // 当前 mode 的像素宽度
    if (b.size.width <= 0 || pxW == 0) return 1.0;
    return (qreal)pxW / (qreal)b.size.width;
}

} // namespace
#endif

QVariantMap ScreenProbe::currentForWindow(QObject* windowObj) const {
    QVariantMap m;
    if (!windowObj) return m;

    auto* qw = qobject_cast<QWindow*>(windowObj);
    if (!qw) return m;

#ifdef __APPLE__
    // 用窗口几何中心做"屏幕归属"判定。Qt 的全局窗口坐标与 CGDisplayBounds
    // 同坐标系（y 向下，主屏左上为原点），无需转换。
    const QPoint anchor = qw->geometry().center();
    const CGPoint p = CGPointMake((CGFloat)anchor.x(), (CGFloat)anchor.y());

    const CGDirectDisplayID dispId = rb_pick_display_for_point(p);
    const CGRect bounds = CGDisplayBounds(dispId);            // 逻辑像素
    const qreal  dpr    = rb_dpr_for_display(dispId);
    const CGSize physMm = CGDisplayScreenSize(dispId);        // 物理 mm

    // pixelDensity = 物理像素数 / 物理毫米，与 QML Screen.pixelDensity 口径
    // 一致（dots/mm）。
    qreal pd = 0.0;
    if (physMm.width > 0 && bounds.size.width > 0) {
        const qreal physicalPixelsWide = (qreal)bounds.size.width * dpr;
        pd = physicalPixelsWide / (qreal)physMm.width;
    }

    // 显示器名字：CG 没有直接 API；用 NSScreen 顺带读一下（用于预设表 key
    // 匹配）。即便 NSScreen 名字暂时落后，预设表也以 width 兜底。
    QString name;
    for (NSScreen* s in [NSScreen screens]) {
        NSNumber* num = [[s deviceDescription]
                            objectForKey:@"NSScreenNumber"];
        if (num && (CGDirectDisplayID)[num unsignedIntValue] == dispId) {
            if ([s respondsToSelector:@selector(localizedName)]) {
                NSString* n = [s localizedName];
                if (n) name = QString::fromNSString(n);
            }
            break;
        }
    }
    if (name.isEmpty()) {
        QScreen* qs = qw->screen();
        if (qs) name = qs->name();
    }

    m.insert("width",            (int)bounds.size.width);
    m.insert("height",           (int)bounds.size.height);
    m.insert("pixelDensity",     pd);
    m.insert("devicePixelRatio", (qreal)dpr);
    m.insert("name",             name);
    return m;
#else
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
#endif
}

} // namespace rbqt
