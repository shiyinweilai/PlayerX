// MOC 桩文件：强制 CMake AUTOMOC 为 ImageDisplayItem 生成 meta object 代码。
// ImageDisplayItem 实现全部在 .h 中（QQuickPaintedItem 子类，仅 paint + property），
// 但 qmlRegisterType<> 需要 vtable / staticMetaObject / qt_metacall 等符号，
// AUTOMOC 扫描 .cpp 文件才会生成 moc_ImageDisplayItem.cpp。
#include "ImageDisplayItem.h"
