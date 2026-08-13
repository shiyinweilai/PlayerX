// MOC 桩文件：强制 CMake AUTOMOC 为 YuvDisplayItem 生成 meta object 代码。
// YuvDisplayItem 实现全部在 .h 中（QQuickPaintedItem 子类，仅 paint + property），
// 但 qmlRegisterType<> 需要 vtable / staticMetaObject / qt_metacall 等符号，
// 这些由 MOC 从此 .cpp 生成并链接。
#include "YuvDisplayItem.h"
