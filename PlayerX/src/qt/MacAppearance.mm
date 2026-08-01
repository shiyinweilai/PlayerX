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

// ─── 登录菜单展开拦截 ────────────────────────────────────────────────
// 需求：菜单栏「登录 / 评分人名字」点击直接弹登录对话框，永不出现下拉。
// AppKit 的菜单栏条目没有"点击即动作"能力（任何菜单点击必展开下拉），
// 唯一可行的拦截点：给登录菜单的 NSMenu 挂 NSMenuDelegate，在
// menuWillOpen:（即将展开、尚未渲染）阶段 cancelTrackingWithoutAnimation
// 中止本次展开，同时回调 QML 打开登录对话框。
// 兜底：若个别系统版本拦截失效，下拉里仍有唯一菜单项（登录…/个人信息…）
// 可点开同一个对话框，功能不受影响。

static void (*g_loginMenuFn)(void*) = nullptr;
static void *g_loginMenuCtx = nullptr;

@interface PXLoginMenuSuppressor : NSObject <NSMenuDelegate>
@end

@implementation PXLoginMenuSuppressor
- (void)menuWillOpen:(NSMenu *)menu {
    [menu cancelTrackingWithoutAnimation];
    if (g_loginMenuFn) g_loginMenuFn(g_loginMenuCtx);
}
@end

// ctx/fn：回调上下文与函数（main.cpp 注入，内部 invokeMethod 到 QML 根对象）
void installLoginMenuSuppressor(void* ctx, void(*fn)(void*)) {
    g_loginMenuCtx = ctx;
    g_loginMenuFn = fn;
    dispatch_async(dispatch_get_main_queue(), ^{
        static PXLoginMenuSuppressor *del = nil;
        if (!del) del = [PXLoginMenuSuppressor new];
        NSMenu *mainMenu = [NSApp mainMenu];
        if (!mainMenu) return;
        // 定位登录菜单：标题为「登录」或当前评分人名（登录后标题变为名字）。
        // 布局固定为 App(0) 文件(1) 设置(2) 帮助(3) 登录(4)，位置做兜底。
        QSettings s(QStringLiteral("PlayerX"), QStringLiteral("PlayerX"));
        NSString *rater = s.value(QStringLiteral("rating/user")).toString().toNSString();
        NSMenu *target = nil;
        for (NSMenuItem *item in mainMenu.itemArray) {
            NSString *t = item.title ?: @"";
            if ([t isEqualToString:@"登录"] ||
                (rater.length > 0 && [t isEqualToString:rater])) {
                target = item.submenu;
                break;
            }
        }
        if (!target && mainMenu.itemArray.count > 4)
            target = [mainMenu.itemArray objectAtIndex:4].submenu;
        if (target) target.delegate = del;
    });
}
