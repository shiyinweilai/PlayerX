/**
 * WinTitleBar.cpp — Windows 标题栏深色化 + 无边框原生缩放（仅 Windows 编译）
 *
 * 通过 DWM API 把系统标题栏渲染为深色，与应用 #101012 深色主题协调：
 *   1) DWMWA_USE_IMMERSIVE_DARK_MODE：沉浸式深色标题栏
 *      （Win10 1809+ / Win11 通用；属性 20 失败时回退旧值 19，兼容 Win10 1909 及更早）
 *   2) DWMWA_CAPTION_COLOR / DWMWA_TEXT_COLOR：Win11 精确配色
 *   3) 无边框窗口（FramelessWindowHint，主窗口在 Windows 全自绘标题栏）：
 *      补回 WS_THICKFRAME（原生边缘缩放能力）+ 拦截 WM_NCCALCSIZE（去掉
 *      原生边框对布局的侵占）+ 拦截 WM_NCHITTEST（四边/四角命中由系统缩放）。
 *
 * ── 为什么回到原生路线（关键历史教训）──
 * 纯 QML 的边缘缩放（startSystemResize / MouseArea 坐标轮询 / CursorProbe
 * 全局坐标）在 Windows 无边框窗口上，垂直方向反复失效：鼠标一旦垂直拖出
 * 底部几 px 热区，Qt 的鼠标抓取/事件流在该平台不稳定，拖动量恒为 0。
 * 水平方向因热区贯穿全高、鼠标可停留区内故正常。多轮尝试证明 QML 层
 * 无法稳定拿到连续的垂直拖动量。
 *
 * 唯一稳定的做法是把缩放完全交给 Windows：补回 WS_THICKFRAME 让系统获得
 * 原生缩放能力，再用 WM_NCHITTEST 把窗口四边/四角映射为 HTLEFT/HTBOTTOM…
 * 系统收到命中码后自行进入模态缩放循环（SetCapture + WM_MOUSEMOVE），
 * 完全不经过 QML 事件流，水平垂直彻底对称、永不丢事件。
 *
 * ── 为什么这次布局不会再坏（修正 3.1.17 的 bug）──
 * 3.1.17 曾用 WS_THICKFRAME + 简单 WM_NCCALCSIZE(return 0)，缩放能用但布局坏：
 * 最大化时 `return 0` 让客户区等于整个窗口矩形，而最大化窗口矩形比工作区
 * 大一圈（系统本应扣掉的边距），内容溢出屏幕边缘 → 底部按钮/右上三键被推出。
 * 本版 WM_NCCALCSIZE 区分状态：普通窗口清零边框（无边框 + 可缩放），
 * 最大化时保留系统计算的自动边距（内容不溢出），布局恒定正确。
 *
 * 需在窗口创建之后调用（QML visible:true 时 engine.load 返回即已创建）。
 */
#include <QQuickWindow>
#include <QObject>
#include <QAbstractNativeEventFilter>
#include <QGuiApplication>

#include <windows.h>
#include <dwmapi.h>
#include <uxtheme.h>   // MARGINS（DwmExtendFrameIntoClientArea）

// 老 SDK / MinGW 头文件可能未定义这些较新的 DWM 属性，手动补齐
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20        // Win10 20H1+ / Win11
#endif
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE_OLD
#define DWMWA_USE_IMMERSIVE_DARK_MODE_OLD 19    // Win10 1809 ~ 1909
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35                  // Win11
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36                     // Win11
#endif

namespace {

// 自绘标题栏高度（逻辑像素）：menuBar 条高度，命中测试里把这一条顶部
// 判成 HTTOP 以外的标题拖拽区交给 QML（QML 已有 DragHandler 处理拖拽），
// 这里只接管最外圈用于缩放的边框像素。
constexpr int kResizeBorderPx = 6;   // 缩放命中边框宽度（逻辑像素，未乘 DPI）

// 当前窗口是否处于最大化状态
inline bool isMaximized(HWND hwnd) {
    WINDOWPLACEMENT wp{};
    wp.length = sizeof(wp);
    if (!GetWindowPlacement(hwnd, &wp)) return false;
    return wp.showCmd == SW_SHOWMAXIMIZED;
}

}  // namespace

// ─── 原生事件过滤器：WM_NCCALCSIZE + WM_NCHITTEST ─────────────────────
// 只处理目标窗口（m_hwnd）的这两条消息，其余一律放行。
class WinResizeFilter : public QObject, public QAbstractNativeEventFilter {
public:
    explicit WinResizeFilter(HWND hwnd)
        : QObject(QGuiApplication::instance()), m_hwnd(hwnd) {}

    bool nativeEventFilter(const QByteArray& eventType, void* message,
                           qintptr* result) override {
        if (eventType != "windows_generic_MSG") return false;
        MSG* msg = static_cast<MSG*>(message);
        if (msg->hwnd != m_hwnd) return false;

        switch (msg->message) {
        // ① 去掉 WS_THICKFRAME 引入的非客户区边框，让客户区占满窗口，
        //    否则 QML 内容被系统边框挤压（footer 按钮/右上三键被遮挡）。
        case WM_NCCALCSIZE: {
            if (!msg->wParam) return false;   // wParam=0 走默认

            if (isMaximized(m_hwnd)) {
                // 最大化：保留系统自动边距，否则内容溢出工作区被裁。
                // 返回 false 让 DefWindowProc 计算标准最大化客户区。
                return false;
            }
            // 普通窗口：客户区 = 整个窗口矩形（无边框观感），
            // 但保留 THICKFRAME 的原生缩放能力（由 WM_NCHITTEST 驱动）。
            if (result) *result = 0;
            return true;
        }

        // ② 把窗口最外圈像素映射为系统缩放命中码，系统自行进入缩放循环。
        //    这是垂直/水平完全对称、永不丢事件的关键。
        case WM_NCHITTEST: {
            if (isMaximized(m_hwnd)) return false;  // 最大化不缩放

            const LONG gx = GET_X_LPARAM_(msg->lParam);
            const LONG gy = GET_Y_LPARAM_(msg->lParam);

            RECT rc{};
            GetWindowRect(m_hwnd, &rc);

            // DPI 缩放：命中边框像素 = 逻辑 6px × 设备缩放
            const UINT dpi = dpiForWindow(m_hwnd);
            const int b = (int)(kResizeBorderPx * dpi / 96.0 + 0.5);

            const bool left   = gx >= rc.left   && gx <  rc.left + b;
            const bool right  = gx <  rc.right   && gx >= rc.right - b;
            const bool top    = gy >= rc.top    && gy <  rc.top + b;
            const bool bottom = gy <  rc.bottom  && gy >= rc.bottom - b;

            LRESULT hit = 0;
            if (top && left)         hit = HTTOPLEFT;
            else if (top && right)   hit = HTTOPRIGHT;
            else if (bottom && left) hit = HTBOTTOMLEFT;
            else if (bottom && right)hit = HTBOTTOMRIGHT;
            else if (left)           hit = HTLEFT;
            else if (right)          hit = HTRIGHT;
            else if (top)            hit = HTTOP;
            else if (bottom)         hit = HTBOTTOM;
            else return false;       // 非边框：交给 QML（拖拽/交互控件）

            if (result) *result = hit;
            return true;
        }

        default:
            return false;
        }
    }

private:
    HWND m_hwnd;

    // GET_X_LPARAM/GET_Y_LPARAM 在 windowsx.h，这里手动展开避免额外包含
    static LONG GET_X_LPARAM_(LPARAM lp) { return (LONG)(short)LOWORD(lp); }
    static LONG GET_Y_LPARAM_(LPARAM lp) { return (LONG)(short)HIWORD(lp); }

    // GetDpiForWindow 在 Win10 1607+；老系统回退 96（1.0 倍）
    static UINT dpiForWindow(HWND hwnd) {
        typedef UINT(WINAPI * Fn)(HWND);
        static Fn fn = reinterpret_cast<Fn>(
            GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
        if (fn) {
            UINT d = fn(hwnd);
            if (d) return d;
        }
        return 96;
    }
};

void applyWindowsDarkTitleBar(QQuickWindow* win) {
    if (!win) return;
    HWND hwnd = reinterpret_cast<HWND>(win->winId());

    // 1) 沉浸式深色标题栏（先新属性值，失败回退旧属性值）
    BOOL dark = TRUE;
    if (FAILED(DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
                                     &dark, sizeof(dark)))) {
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD,
                              &dark, sizeof(dark));
    }

    // 2) Win11 精确配色（Win10 静默失败，无副作用）
    COLORREF caption = RGB(0x10, 0x10, 0x12);
    DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &caption, sizeof(caption));
    COLORREF text = RGB(0xE8, 0xE8, 0xEC);
    DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, &text, sizeof(text));

    // 3) 无边框窗口补回系统观感 + 原生缩放：
    if (win->flags() & Qt::FramelessWindowHint) {
        // FramelessWindowHint 去掉了 WS_THICKFRAME，原生缩放随之失效。
        // 补回 THICKFRAME（+ 最大/最小化框，供任务栏右键菜单与系统动画），
        // 不加 WS_CAPTION 所以不会出现系统标题栏。
        LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        style |= WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MINIMIZEBOX;
        SetWindowLongPtrW(hwnd, GWL_STYLE, style);

        // 安装事件过滤器：WM_NCCALCSIZE 清边框 + WM_NCHITTEST 驱动缩放
        static WinResizeFilter* s_filter = nullptr;
        if (!s_filter) {
            s_filter = new WinResizeFilter(hwnd);
            QGuiApplication::instance()->installNativeEventFilter(s_filter);
        }

        // 通知系统样式已变更，立即重算非客户区（触发一次被过滤的 NCCALCSIZE）
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOACTIVATE | SWP_FRAMECHANGED);

        // DWM 阴影：把 1px 框架延入客户区（无边框窗口默认没有阴影）
        MARGINS shadow = {0, 0, 0, 1};
        DwmExtendFrameIntoClientArea(hwnd, &shadow);
        // Win11 圆角（无边框默认方角；Win10 上该属性不存在，静默失败）
        DWORD corner = 2;  // DWMWCP_ROUND
        DwmSetWindowAttribute(hwnd, 33 /*DWMWA_WINDOW_CORNER_PREFERENCE*/,
                              &corner, sizeof(corner));
    }
}
