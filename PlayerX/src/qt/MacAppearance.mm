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
#include <QQuickWindow>

void applyMacDarkAppearance() {
    if (@available(macOS 10.14, *)) {
        NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }
}

// ─── 标题栏「右侧栏」切换按钮（原生 AppKit，VSCode 风格）──────────────────
// 图标 = 圆角正方形 + 中间一条竖线；未展开时空心，展开后右侧填色。
// 按钮自维护展开状态（g_sidebarOpen）用于重绘，点击时同步 toggle 并回调 QML。
// LEFT_INSET：让两个按钮整体左移，避开 macOS 窗口右上角的圆弧区域。
#define LEFT_INSET 16.0
static void* g_sbCtx = nullptr;
static void (*g_sbFn)(void*) = nullptr;
static BOOL g_sidebarOpen = NO;

// 标题栏小按钮基类：继承 NSControl，同时【吞掉 mouseUp】。
// macOS 的标题栏双击 zoom 是在 mouseUp 阶段检测 clickCount==2 触发的；
// 只要把 mouseUp 重写为空、不向上冒泡，NSWindow 就收不到双击事件，不会 zoom。
// mouseDown 不判断 clickCount：双击当两次单击处理（快速两次 onClick=两次 toggle）。
@interface PXTitleBarButton : NSControl
@property (nonatomic, copy) void (^onClick)(void);
@end
@implementation PXTitleBarButton
- (void)mouseDown:(NSEvent*)e {
    if (self.onClick) self.onClick();
}
- (void)mouseUp:(NSEvent*)e {
    // 关键：吞掉 mouseUp，阻止事件冒泡到 NSWindow 触发双击 zoom。
    // （不要调用 [super mouseUp:]，否则会沿 responder 链传到 NSWindow。）
}
- (BOOL)acceptsFirstMouse:(NSEvent*)e { return YES; }
- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
@end

@interface PXSidebarBtnView : PXTitleBarButton @end
@implementation PXSidebarBtnView
- (void)drawRect:(NSRect)dirtyRect {
    NSColor* fg = [NSColor labelColor];   // 深色模式下系统自动取白

    // 圆角正方形（居中，16×16）
    CGFloat side = 16.0;
    NSRect frame = NSMakeRect((self.bounds.size.width  - side) / 2.0,
                              (self.bounds.size.height - side) / 2.0,
                              side, side);
    NSBezierPath* box = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:3.0 yRadius:3.0];
    box.lineWidth = 1.2;
    [fg setStroke];
    [box stroke];

    // 中间一条竖线
    CGFloat midX = NSMidX(frame);
    NSBezierPath* div = [NSBezierPath bezierPath];
    [div moveToPoint:NSMakePoint(midX, frame.origin.y + 2.0)];
    [div lineToPoint:NSMakePoint(midX, frame.origin.y + frame.size.height - 2.0)];
    div.lineWidth = 1.2;
    [div stroke];

    // 展开态：右侧填色（用圆角框裁剪，保证填色不超出圆角）
    if (g_sidebarOpen) {
        [box addClip];
        NSRect rightHalf = NSMakeRect(midX, frame.origin.y,
                                      frame.size.width / 2.0, frame.size.height);
        [fg setFill];
        NSRectFill(rightHalf);
    }
}
@end

void installTitleBarSidebarButton(QQuickWindow* win, void* ctx, void(*fn)(void*)) {
    g_sbCtx = ctx;
    g_sbFn = fn;
    if (!win) return;
    NSView* view = reinterpret_cast<NSView*>(win->winId());
    NSWindow* nswin = [view window];
    if (!nswin) return;

    PXSidebarBtnView* btn = [[PXSidebarBtnView alloc] initWithFrame:NSMakeRect(0, 0, 26, 22)];
    btn.onClick = ^{
        g_sidebarOpen = !g_sidebarOpen;
        [btn setNeedsDisplay:YES];
        if (g_sbFn) g_sbFn(g_sbCtx);
    };

    // 容器宽度 = 按钮宽 + LEFT_INSET，按钮靠容器左边（x=0），
    // 右边多出的 LEFT_INSET 空隙让按钮整体左移，避开窗口右上角圆弧。
    // 容器高度 = 28（macOS 标准标题栏高度），按钮 22 高居中于容器，
    // 这样 accessory 居中对齐标题栏中心时按钮也正好和 traffic lights 同基线。
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 26 + LEFT_INSET, 28)];
    [container addSubview:btn];
    btn.frame = NSMakeRect(0, 3, 26, 22);   // 22 高的按钮在 28 高的容器里居中

    NSTitlebarAccessoryViewController* acc = [[NSTitlebarAccessoryViewController alloc] init];
    acc.layoutAttribute = NSLayoutAttributeRight;
    acc.view = container;
    [nswin addTitlebarAccessoryViewController:acc];
}

// ─── 标题栏「个人中心」按钮（原生 AppKit）────────────────────────────────
// 图标 = 圆头（空心圆环）+ 微笑弧 + 底部身体弧（参考用户提供的 user SVG）。
// 点击回调到 QML，复用登录/个人信息对话框入口。
static void* g_pfCtx = nullptr;
static void (*g_pfFn)(void*) = nullptr;
static BOOL g_profileOpen = NO;

@interface PXProfileBtnView : PXTitleBarButton @end
@implementation PXProfileBtnView
// 不翻折：使用 macOS 默认坐标系（y 从底部向上），与侧栏按钮一致，
// 保证两个按钮图标视觉垂直对齐。
- (void)drawRect:(NSRect)dirtyRect {
    NSColor* fg = [NSColor labelColor];   // 深色模式下系统自动取白
    CGFloat cx = self.bounds.size.width / 2.0;
    CGFloat cy = self.bounds.size.height / 2.0;   // 垂直中心（按钮 22 高 → cy=11）

    // 头部圆环（中心偏上）：圆心在 cy+3.5，圆 r=4.5
    CGFloat headR = 4.5;
    NSRect headRect = NSMakeRect(cx - headR, (cy + 3.5) - headR, headR * 2, headR * 2);
    NSBezierPath* head = [NSBezierPath bezierPathWithOvalInRect:headRect];

    // 微笑弧（头部圆内下方）
    NSBezierPath* smile = [NSBezierPath bezierPath];
    CGFloat sy = cy + 4.5;
    [smile moveToPoint:NSMakePoint(cx - 2.0, sy)];
    [smile curveToPoint:NSMakePoint(cx + 2.0, sy)
          controlPoint1:NSMakePoint(cx - 2.0, sy + 1.7)
          controlPoint2:NSMakePoint(cx + 2.0, sy + 1.7)];

    // 底部身体弧（U 形，比头宽 50%，模拟肩膀）
    NSBezierPath* body = [NSBezierPath bezierPath];
    [body moveToPoint:NSMakePoint(cx - 9.0, cy - 2.5)];
    [body curveToPoint:NSMakePoint(cx + 9.0, cy - 2.5)
         controlPoint1:NSMakePoint(cx - 9.0, cy - 8.5)
         controlPoint2:NSMakePoint(cx + 9.0, cy - 8.5)];

    if (g_profileOpen) {
        // 激活态：头部圆 + 身体弧整体填色（与侧栏按钮「右侧填色」视觉一致）
        [fg setFill];
        [head fill];
        [body fill];
        // 微笑处用窗口背景色反白，保留「嘴」轮廓
        [[NSColor windowBackgroundColor] setFill];
        NSRectFill(NSMakeRect(cx - 0.8, sy - 0.4, 1.6, 1.8));
    } else {
        [fg setStroke];
        head.lineWidth = 1.3;
        [head stroke];
        smile.lineWidth = 1.1;
        [smile stroke];
        body.lineWidth = 1.3;
        [body stroke];
    }
}
@end

void installTitleBarProfileButton(QQuickWindow* win, void* ctx, void(*fn)(void*)) {
    g_pfCtx = ctx;
    g_pfFn = fn;
    if (!win) return;
    NSView* view = reinterpret_cast<NSView*>(win->winId());
    NSWindow* nswin = [view window];
    if (!nswin) return;

    PXProfileBtnView* btn = [[PXProfileBtnView alloc] initWithFrame:NSMakeRect(0, 0, 26, 22)];
    btn.onClick = ^{
        g_profileOpen = !g_profileOpen;
        [btn setNeedsDisplay:YES];
        if (g_pfFn) g_pfFn(g_pfCtx);
    };

    // 与侧栏按钮一致：容器高 28、宽 = 26+LEFT_INSET，按钮 22 高在容器内居中。
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 26 + LEFT_INSET, 28)];
    [container addSubview:btn];
    btn.frame = NSMakeRect(0, 3, 26, 22);   // 22 高按钮在 28 高容器里居中

    NSTitlebarAccessoryViewController* acc = [[NSTitlebarAccessoryViewController alloc] init];
    acc.layoutAttribute = NSLayoutAttributeRight;
    acc.view = container;
    [nswin addTitlebarAccessoryViewController:acc];
}

// ─── 标题栏「公告文字」（原生 AppKit，嵌进系统标题栏，不占内容区）──────────
// 用 NSTitlebarAccessoryViewController + layoutAttribute=Left 把一段可横向
// 滚动的黄色文字放进系统标题栏（红绿灯右侧、窗口标题位置），完全不占用
// 内容区空间。
//
// 滚动策略：文字宽度 ≤ 可用宽度 → 居中静止；超出 → 左右往复（pingpong）
// 滚动，两端各停顿 1.2s 让用户看清首尾，速度约 30ms/px。
// 用 NSTimer 驱动（20fps 重绘），轻量、不阻塞主线程。
// 公告文字垂直微调：正值 = 下移，负值 = 上移（单位 pt）。
// 实测按红绿灯 centerY 对齐后文字仍偏上，用这个常量补偿；要再调改这一个数即可。
#define NOTICE_DY 5.0

// 公告文字字体：统一抽出来，保证「测宽」与「绘制」两处用同一字号，
// 否则会出现宽度算错、滚动判定失真。13px semibold 比原来的 11px 更醒目。
static NSFont* PXNoticeFont(void) {
    return [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
}

@interface PXNoticeTextView : NSView
@property (nonatomic, copy) NSString* noticeText;
@property (nonatomic, strong) NSTimer* timer;
@property (nonatomic, assign) CGFloat offset;      // 当前横向偏移（≤0）
@property (nonatomic, assign) CGFloat dir;         // 1 = 右移（露出尾部），-1 = 回退
@property (nonatomic, assign) CGFloat pauseLeft;   // 剩余停顿（秒）
@property (nonatomic, assign) CGFloat textW;       // 文字自然宽度
@property (nonatomic, assign) CGFloat boxW;        // 可用宽度
@end

@implementation PXNoticeTextView

- (instancetype)initWithFrame:(NSRect)f text:(NSString*)t {
    if ((self = [super initWithFrame:f])) {
        _noticeText = [t copy];
        _offset = 0;
        _dir = 1;
        _pauseLeft = 1.2;
        [self recomputeMetrics];
        // 20fps 驱动滚动（标题栏条很窄，60fps 没必要，省 CPU）。
        // 用 target-action 形式（MRC 下不能用 __weak block），
        // timer 持有 self 并在 dealloc 中 invalidate，不会泄漏。
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0/20.0
                                                  target:self
                                                selector:@selector(tick)
                                                userInfo:nil
                                                 repeats:YES];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

// 重新计算文字宽度 / 可用宽度；放不下才标记为需要滚动。
- (void)recomputeMetrics {
    NSFont* font = PXNoticeFont();
    NSDictionary* attrs = @{ NSFontAttributeName: font };
    _textW = [_noticeText sizeWithAttributes:attrs].width;
    _boxW = self.bounds.size.width;
    if (_textW <= _boxW) {
        _offset = (_boxW - _textW) / 2.0;   // 居中静止
    }
}

- (void)setFrameSize:(NSSize)s {
    [super setFrameSize:s];
    [self recomputeMetrics];
}

- (BOOL)needsScroll { return _textW > _boxW; }

- (void)tick {
    if (![self needsScroll]) return;
    if (_pauseLeft > 0) {
        _pauseLeft -= 1.0/20.0;
        if (_pauseLeft <= 0) _pauseLeft = 0;
        return;
    }
    CGFloat maxOff = _boxW - _textW;        // 负值：能露到尾部的最左偏移
    CGFloat speed = 30.0;                   // px/s（约 30ms/px）
    CGFloat step = speed / 20.0;
    _offset += (_dir > 0 ? -step : step);   // dir>0：向左推进（露出尾部）
    if (_offset <= maxOff) {                // 到达尾部 → 停顿后回退
        _offset = maxOff;
        _dir = -1;
        _pauseLeft = 1.2;
    } else if (_offset >= 0) {              // 回到开头 → 停顿后再推进
        _offset = 0;
        _dir = 1;
        _pauseLeft = 1.2;
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSFont* font = PXNoticeFont();
    NSDictionary* attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.835 blue:0.29 alpha:1.0]  // #FFD54A 醒目黄
    };
    // 垂直精确居中：用字体度量（ascender 向上为正、descender 向下为负）
    // 算出真实墨迹高度，再按容器高（28，即标准标题栏高）居中，
    // 避免原来用固定 12 估算导致的偏上。
    CGFloat textH = font.ascender - font.descender;
    CGFloat y = (self.bounds.size.height - textH) / 2.0 - font.descender;
    [_noticeText drawAtPoint:NSMakePoint(_offset, y) withAttributes:attrs];
}
@end

// 当前安装的标题栏公告视图（全局仅一个主窗口），供显隐控制使用。
static PXNoticeTextView* g_noticeView = nil;

void installTitleBarNotice(QQuickWindow* win, const char* text) {
    if (!win || !text || !*text) return;
    NSView* view = reinterpret_cast<NSView*>(win->winId());
    NSWindow* nswin = [view window];
    if (!nswin) return;

    NSString* t = [NSString stringWithUTF8String:text];

    // 不用 NSTitlebarAccessoryViewController 的 Left/Right —— 那两种
    // layoutAttribute 会顶替/压缩系统标题「PlayerX」的位置。
    // 改为：把一段透明 overlay 直接叠在标题栏视图（NSThemeFrame）上，
    //   高 28（标准标题栏高）、贴顶、水平居中、宽度 = 标题栏宽 × 0.5。
    // 系统标题原样保留在左（红绿灯右侧），公告在中间，两者不重叠；
    // overlay 背景透明、只画中间这一条文字，不遮挡任何原生控件。
    NSView* themeFrame = nswin.contentView.superview;   // NSThemeFrame
    if (!themeFrame) return;

    PXNoticeTextView* notice = [[PXNoticeTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 28)
                                                                 text:t];
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    [themeFrame addSubview:notice];

    // 垂直定位不用「高 28 + 贴顶」—— NSThemeFrame 顶部还包含窗口边框/圆角区，
    // 那样算出的几何中心比标题栏视觉中心偏上（这就是之前没居中的原因）。
    // 改为：以红绿灯（关闭按钮）的垂直中心为基准，它就是标题栏的视觉中心线。
    NSMutableArray* cons = [NSMutableArray array];
    [cons addObject:[notice.centerXAnchor constraintEqualToAnchor:themeFrame.centerXAnchor]];
    // 宽度取标题栏 60%：给文字足够空间，又不会延伸到左侧标题区。
    [cons addObject:[notice.widthAnchor constraintEqualToAnchor:themeFrame.widthAnchor multiplier:0.6]];
    // 高度略大于字号（13px 字 + 上下余量），文字在容器内再精确居中。
    [cons addObject:[notice.heightAnchor constraintEqualToConstant:20.0]];

    NSButton* closeBtn = [nswin standardWindowButton:NSWindowCloseButton];
    if (closeBtn) {
        // NOTICE_DY：整体垂直微调（正值 = 下移，负值 = 上移）。
        // 红绿灯是系统按钮、走 autoresizing mask，约束到它的 centerY 未必
        // 完全生效，实测文字仍偏上，故用这个常量做人工补偿，按需再调。
        [cons addObject:[notice.centerYAnchor constraintEqualToAnchor:closeBtn.centerYAnchor
                                                            constant:NOTICE_DY]];
    } else {
        // 兜底：拿不到红绿灯时贴顶 + 偏移
        [cons addObject:[notice.topAnchor constraintEqualToAnchor:themeFrame.topAnchor
                                                        constant:4.0 + NOTICE_DY]];
    }
    [NSLayoutConstraint activateConstraints:cons];

    g_noticeView = notice;   // 供 setTitleBarNoticeVisible() 控制显隐
}

// 显示/隐藏标题栏公告（由 NoticeBarBridge 从 QML 按当前 tab 调用）。
void setTitleBarNoticeVisible(bool visible) {
    if (!g_noticeView) return;
    [g_noticeView setHidden:(visible ? NO : YES)];
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

// 判定某一级菜单是否为登录菜单：标题 =「登录」或当前评分人名（QSettings）。
// 【不要用位置/索引兜底】——菜单布局会变（旧布局是 Apple/文件/设置/帮助/登录，
// 现布局是 Apple/文件/播放对比/YUV分析/通用/帮助/登录），用 index 兜底会把
// 「通用」误判成登录菜单，导致点击"通用"弹出个人信息面板。
static BOOL px_isLoginMenu(NSMenu *menu, NSInteger index) {
    (void)index;   // 保留参数仅为兼容调用点，刻意不使用
    NSString *t = menu.title ?: @"";
    if ([t isEqualToString:@"登录"]) return YES;
    QSettings s(QStringLiteral("PlayerX"), QStringLiteral("PlayerX"));
    NSString *rater = s.value(QStringLiteral("rating/user")).toString().toNSString();
    if (rater.length > 0 && [t isEqualToString:rater]) return YES;
    return NO;
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
