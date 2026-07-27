/**
 * WinTitleBar.cpp — Windows 标题栏深色化（仅 Windows 编译）
 *
 * 通过 DWM API 把系统标题栏渲染为深色，与应用 #101012 深色主题协调：
 *   1) DWMWA_USE_IMMERSIVE_DARK_MODE：沉浸式深色标题栏
 *      （Win10 1809+ / Win11 通用；属性 20 失败时回退旧值 19，兼容 Win10 1909 及更早）
 *   2) DWMWA_CAPTION_COLOR / DWMWA_TEXT_COLOR：Win11 精确配色，
 *      标题栏底色 = 应用背景 #101012，文字浅色 #e8e8ec，与内容区无缝
 *      （Win10 上返回 E_INVALIDARG，静默忽略，沿用 1) 的深色效果）
 *   3) 无边框窗口（FramelessWindowHint，主窗口在 Windows 全自绘标题栏）：
 *      补回 DWM 阴影（1px 框架延入客户区）与 Win11 圆角（DWMWA_WINDOW_CORNER_PREFERENCE）
 *
 * 需在窗口创建之后调用（QML visible:true 时 engine.load 返回即已创建）。
 */
#include <QQuickWindow>

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

    // 3) 无边框窗口（主窗口在 Windows 用 FramelessWindowHint 全自绘标题栏）补回系统观感：
    if (win->flags() & Qt::FramelessWindowHint) {
        // DWM 阴影：把 1px 框架延入客户区（无边框窗口默认没有阴影）
        MARGINS shadow = {0, 0, 0, 1};
        DwmExtendFrameIntoClientArea(hwnd, &shadow);
        // Win11 圆角（无边框默认方角；Win10 上该属性不存在，静默失败）
        DWORD corner = 2;  // DWMWCP_ROUND
        DwmSetWindowAttribute(hwnd, 33 /*DWMWA_WINDOW_CORNER_PREFERENCE*/,
                              &corner, sizeof(corner));
    }
}
