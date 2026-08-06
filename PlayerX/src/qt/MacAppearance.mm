/**
 * MacAppearance.mm — macOS 外观定制（Objective-C++）
 *
 * 把 NSApp.appearance 强制设为 Dark Aqua：
 *   - 系统标题栏（含红绿灯区域）渲染为深色，与应用 #101012 深色主题协调
 *   - 原生 NSMenu（macOS 菜单栏）、NSOpenPanel 等原生对话框同步变深
 *   - 不受系统"浅色模式"影响，应用观感始终一致
 *
 * 必须在 QGuiApplication 创建之后、任何窗口创建之前调用。
 */
#import <AppKit/AppKit.h>
#include <QSettings>
#include <QString>

void applyMacDarkAppearance() {
    if (@available(macOS 10.14, *)) {
        NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }
}

// ─── 菜单栏"点击守卫"（含登录菜单展开拦截）─────────────────────────────
// 两条需求合一：
//  1) 禁止悬停滑入切换：点开一个下拉后，鼠标未点击直接滑到相邻菜单，
//     macOS 默认会跟踪切换展开 —— 拦截掉，必须显式点击才展开。
//  2) 「登录 / 评分人名字」点击直接弹信息面板，永不出现下拉。
//
// 判定原理（会话状态机，不依赖鼠标事件）：
//   实测菜单栏点击不经过本地/全局事件监听器（WindowServer 直发），
//   NSMenuDidBeginTrackingNotification 也不为 Qt 原生菜单触发，
//   唯一可靠 hook 点是 NSMenuDelegate 的 menuWillOpen:（渲染前）。
//   · 没有任何菜单展开时的 willOpen → 必是显式点击 → 放行；
//     （登录菜单：取消展开 + 弹信息面板，直达无下拉）
//   · 已有菜单展开中的 willOpen → 必是悬停滑入 → cancelTracking 取消，
//     整个跟踪会话结束，用户接下来点击目标菜单正常展开。
//   菜单关闭（选项/Esc/点外）经 menuDidClose: 复位会话状态。
//
// 注意：守卫包装 Qt 原有的 NSMenuDelegate（若有），menuWillOpen/menDidClose
// 之外的调用（menuNeedsUpdate: 等动态项同步）全部转发，不影响菜单内容刷新。
// Qt 重同步/重建菜单会重置 delegate，故用 1s 定时器 + 激活通知自愈重挂。
//
// 子菜单（如 设置 ▸ 布局）不挂守卫，照常悬停展开。
// 已知边角：一个菜单展开时点击另一个菜单，若系统先 willOpen 新菜单再
// didClose 旧菜单，这次点击会被当成滑入取消（再点一次即可）；
// 键盘菜单导航的左右方向键切换同理会被拦一次。

static void (*g_loginMenuFn)(void*) = nullptr;
static void *g_loginMenuCtx = nullptr;
static NSTimeInterval g_lastLoginFire = 0;   // 上次信息面板触发时刻（去重用）
static BOOL g_menuSessionOpen = NO;          // 是否有一级菜单正在展开/跟踪

// ── 临时诊断日志（排查菜单栏拦截链路，定位后删除）──
#define PXMLOG(fmt, ...) fprintf(stderr, "[PXMenu] " fmt "\n", ##__VA_ARGS__)

// 触发登录信息面板（0.5s 内去重）
static void px_fireLoginDialog() {
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now - g_lastLoginFire < 0.5) return;
    g_lastLoginFire = now;
    PXMLOG("fireLoginDialog → 调 QML 打开面板");
    if (g_loginMenuFn) g_loginMenuFn(g_loginMenuCtx);
}

// 判定某一级菜单是否为登录菜单：标题 =「登录」或当前评分人名（QSettings），
// 位置兜底 index 4（布局：Apple/文件/设置/帮助/登录/QtWindowMenu）。
// 注意不能用"最后一项"：Qt 会在末尾自动追加 QtWindowMenu（实测日志证实）。
static BOOL px_isLoginMenu(NSMenu *menu, NSInteger index) {
    NSString *t = menu.title ?: @"";
    if ([t isEqualToString:@"登录"]) return YES;
    QSettings s(QStringLiteral("PlayerX"), QStringLiteral("PlayerX"));
    NSString *rater = s.value(QStringLiteral("rating/user")).toString().toNSString();
    if (rater.length > 0 && [t isEqualToString:rater]) return YES;
    return index == 4;
}

@interface PXTopMenuGuard : NSObject <NSMenuDelegate>
@property(nonatomic, assign) BOOL isLogin;
@property(nonatomic, assign) id<NSMenuDelegate> orig;   // Qt 原 delegate（可 nil）
@end

@implementation PXTopMenuGuard
- (void)menuWillOpen:(NSMenu *)menu {
    if (self.isLogin) {
        // 登录：任何情况都不展开下拉；仅"无菜单展开中的点击"才弹面板
        PXMLOG("willOpen LOGIN title=%s session=%d → cancel%s",
               [menu.title UTF8String], g_menuSessionOpen,
               g_menuSessionOpen ? "（悬停滑入，不弹面板）" : "（点击，弹面板）");
        [menu cancelTrackingWithoutAnimation];
        if (!g_menuSessionOpen) px_fireLoginDialog();
        g_menuSessionOpen = NO;   // 拦截即结束本次跟踪会话
        return;
    }
    if (g_menuSessionOpen) {
        // 已有菜单展开时的再次展开 = 悬停滑入 → 禁止（必须点击）
        PXMLOG("willOpen title=%s session=1 → cancel（悬停滑入）", [menu.title UTF8String]);
        [menu cancelTrackingWithoutAnimation];
        g_menuSessionOpen = NO;
        return;
    }
    PXMLOG("willOpen title=%s session=0 → 放行（点击）", [menu.title UTF8String]);
    g_menuSessionOpen = YES;
    if ([self.orig respondsToSelector:@selector(menuWillOpen:)])
        [self.orig menuWillOpen:menu];
}
- (void)menuDidClose:(NSMenu *)menu {
    PXMLOG("didClose title=%s → session=0", [menu.title UTF8String]);
    g_menuSessionOpen = NO;
    if ([self.orig respondsToSelector:@selector(menuDidClose:)])
        [self.orig menuDidClose:menu];
}
// 其余 NSMenuDelegate 方法（menuNeedsUpdate: / willHighlightItem: 等）
// 全部转发给 Qt 原 delegate，保证菜单项动态状态正常同步
- (id)forwardingTargetForSelector:(SEL)sel { return self.orig; }
- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.orig respondsToSelector:sel];
}
@end

// 给全部一级菜单挂/补挂守卫（Apple 菜单除外；QtWindowMenu 跳过）。
// Qt 重建菜单后 delegate 丢失，本函数幂等，可反复调用。
static void px_installGuards() {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) return;
    NSArray<NSMenuItem*> *items = mainMenu.itemArray;
    for (NSUInteger i = 0; i < items.count; ++i) {
        NSMenu *sub = items[i].submenu;
        if (!sub) continue;
        if ([sub.title isEqualToString:@"QtWindowMenu"]) continue;
        if ([sub.delegate isKindOfClass:[PXTopMenuGuard class]]) continue;   // 已挂
        PXTopMenuGuard *gd = [PXTopMenuGuard new];
        gd.isLogin = px_isLoginMenu(sub, (NSInteger)i);
        gd.orig = sub.delegate;   // 保留 Qt 原 delegate 以便转发
        sub.delegate = gd;
        PXMLOG("guard 挂载: [%lu] title=%s isLogin=%d orig=%s",
               (unsigned long)i, [sub.title UTF8String], gd.isLogin,
               gd.orig ? [NSStringFromClass([gd.orig class]) UTF8String] : "nil");
    }
}

// ctx/fn：回调上下文与函数（main.cpp 注入，内部 invokeMethod 到 QML 根对象）
void installLoginMenuSuppressor(void* ctx, void(*fn)(void*)) {
    g_loginMenuCtx = ctx;
    g_loginMenuFn = fn;
    dispatch_async(dispatch_get_main_queue(), ^{
        px_installGuards();
        // 自愈重挂：应用激活时 + 1s 周期（Qt 重同步/重建菜单后 1s 内恢复）
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) { px_installGuards(); }];
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                       repeats:YES
                                         block:^(NSTimer *t) { px_installGuards(); }];
    });
}
