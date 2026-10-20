import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import PlayerX 1.0

// 窗口边缘缩放占位组件。
//
// ── 缩放由谁负责（重要）──
// Windows 无边框窗口的边缘缩放，最终方案是 C++ 原生路线：
// WinTitleBar.cpp 补回 WS_THICKFRAME 并拦截 WM_NCHITTEST，把窗口最外圈
// 像素映射为 HTLEFT/HTBOTTOM/HTBOTTOMRIGHT… 系统收到命中码后自行进入
// 原生缩放循环。水平/垂直完全对称、永不丢事件。
//
// 因此本组件在 Windows 上【不再做任何缩放逻辑】，也【不能拦截鼠标】——
// 否则 QML 的 MouseArea 会先吃掉边框像素的鼠标事件，WM_NCHITTEST 根本
// 收不到，系统缩放被挡死（这正是之前"光标会变但拖不动"的其中一环）。
// 这里保留组件只为：① 兼容 Main.qml / AppMenuBar.qml 已有的声明；
// ② 在非 Windows（理论上不会用到）留一个空壳。
//
// 关键：enabled:false + acceptedButtons:Qt.NoButton，彻底让出鼠标，
// 让边框像素的 hit-test 直达 Win32 非客户区逻辑。光标形状也交给系统
// （WM_NCHITTEST 返回 HTxxx 后系统自动显示对应的缩放光标）。
MouseArea {
    id: edge
    property var root: null
    property int edges: 0

    // 不接收任何鼠标按钮、不启用 hover：边框像素事件全部放行给系统 NC 区
    enabled: false
    hoverEnabled: false
    acceptedButtons: Qt.NoButton
    visible: false
}
