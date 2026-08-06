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
// 判定原理（跟踪会话状态机，不依赖鼠标事件）：
//   实测菜单栏点击不经过本地/全局事件监听器（WindowServer 直发），
//   唯一可靠 hook 点是 NSMenuDelegate 的 menuWillOpen:（渲染前）。
//   点击 vs 悬停滑入的区分：二者都会先 didClose 旧菜单再 willOpen 新菜单
//   （所以"某菜单是否打开着"区分不了），但悬停滑入发生在【同一次连续的
//   菜单栏跟踪会话】内，而每次显式点击都会先结束旧会话、再开启新会话。
//   主菜单栏（NSApp.mainMenu）的 NSMenuDidBegin/EndTrackingNotification
//   正好标记会话边界（同步派发，保证时序）：
//   · Begin/End → 复位"本会话已有菜单展开"标记；
//   · willOpen 时标记为真 → 同会话内的再次展开 = 悬停滑入 → 取消；
//   · 标记为假 → 新会话首次展开 = 显式点击 → 放行（登录菜单：取消+弹面板）。
//   兜底：若系统版本不发主菜单栏跟踪通知（g_seenTrackingNotif 恒假），
//   守卫退化为不拦截任何展开，保证点击功能不受新问题影响。
//
// 注意：守卫包装 Qt 原有的 NSMenuDelegate（QCocoaNSMenuDelegate），
// menuWillOpen/menuDidClose 之外的调用（menuNeedsUpdate: 等动态项同步）
// 全部转发，不影响菜单内容刷新。
// Qt 重同步/重建菜单会重置 delegate，故用 1s 定时器 + 激活通知自愈重挂。
// 子菜单（如 设置 ▸ 布局）不挂守卫，照常悬停展开。
// 已知边角：键盘菜单导航的左右方向键切换在同一会话内，会被拦一次。

static void (*g_loginMenuFn)(void*) = nullptr;
static void *g_loginMenuCtx = nullptr;
static NSTimeInterval g_lastLoginFire = 0;   // 上次信息面板触发时刻（去重用）
static BOOL g_trackingMenuOpened = NO;       // 本次跟踪会话内是否已展开过菜单
static BOOL g_seenTrackingNotif = NO;        // 是否收到过主菜单栏跟踪通知（兜底用）

// 触发登录信息面板（0.5s 内去重）
static void px_fireLoginDialog() {
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now - g_lastLoginFire < 0.5) return;
    g_lastLoginFire = now;
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
    // 同会话内的再次展开 = 悬停滑入（未收到主菜单栏跟踪通知时该判定停用，
    // 守卫退化为全放行，确保点击功能不受影响）
    const BOOL hoverSwitch = g_seenTrackingNotif && g_trackingMenuOpened;
    if (self.isLogin) {
        // 登录：任何情况都不展开下拉；仅"新会话首次展开（点击）"才弹面板
        [menu cancelTrackingWithoutAnimation];
        if (!hoverSwitch) px_fireLoginDialog();
        return;
    }
    if (hoverSwitch) {
        [menu cancelTrackingWithoutAnimation];
        return;
    }
    g_trackingMenuOpened = YES;
    if ([self.orig respondsToSelector:@selector(menuWillOpen:)])
        [self.orig menuWillOpen:menu];
}
- (void)menuDidClose:(NSMenu *)menu {
    // 注意：此处【不】复位 g_trackingMenuOpened —— 悬停滑入与点击切换
    // 都会先 didClose 旧菜单，复位由主菜单栏 End/Begin 跟踪通知负责。
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

        // 主菜单栏跟踪会话边界：Begin/End 都复位"本会话已有菜单展开"标记。
        // queue:nil = 同步派发，保证通知与 willOpen/didClose 的相对时序不变。
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSMenuDidBeginTrackingNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            if (note.object == [NSApp mainMenu]) {
                g_seenTrackingNotif = YES;
                g_trackingMenuOpened = NO;
            }
        }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSMenuDidEndTrackingNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            if (note.object == [NSApp mainMenu]) {
                g_seenTrackingNotif = YES;
                g_trackingMenuOpened = NO;
            }
        }];
    });
}
