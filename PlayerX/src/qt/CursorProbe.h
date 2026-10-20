/**
 * CursorProbe.h — 全局光标位置探针（跨平台）
 *
 * 背景：QML MouseArea 在窗口边缘拖拽缩放时，鼠标可能拖出 5px 热区
 * 甚至窗口外，mouseX/mouseY 停止更新，导致垂直缩放"拖不动"。
 * CursorProbe 用 QCursor::pos() 返回屏幕全局坐标（逻辑像素），QML 端
 * 轮询调用即可获得连续的鼠标轨迹，事件永不丢失。
 *
 * 使用：QML 端通过 contextProperty "CursorProbe" 调用：
 *     var p = CursorProbe.globalPos()   // { x: ..., y: ... }
 *
 * 纯只读 / 无副作用，与窗口系统解耦。
 */
#pragma once

#include <QObject>
#include <QVariantMap>

namespace rbqt {

class CursorProbe : public QObject {
    Q_OBJECT
public:
    explicit CursorProbe(QObject* parent = nullptr);

    // 返回全局光标坐标（逻辑像素，与 QML mapToGlobal 同一坐标系）
    Q_INVOKABLE QVariantMap globalPos() const;
};

}  // namespace rbqt
