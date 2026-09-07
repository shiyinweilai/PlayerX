#include "NoticeBarBridge.h"

#if defined(Q_OS_MACOS)
// 由 MacAppearance.mm 提供：显示/隐藏标题栏公告 overlay。
// 声明放在这里，避免把 Obj-C 头文件暴露给纯 C++ 编译单元。
void setTitleBarNoticeVisible(bool visible);
#endif

void NoticeBarBridge::setVisible(bool v) {
#if defined(Q_OS_MACOS)
    setTitleBarNoticeVisible(v);
#else
    // Windows / Linux：公告尚未实现，空操作（QML 侧无需区分平台）。
    (void)v;
#endif
}
