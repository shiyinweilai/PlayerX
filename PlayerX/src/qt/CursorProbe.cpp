#include "CursorProbe.h"

#include <QCursor>

namespace rbqt {

CursorProbe::CursorProbe(QObject* parent) : QObject(parent) {}

QVariantMap CursorProbe::globalPos() const {
    const QPoint p = QCursor::pos();
    return {{"x", p.x()}, {"y", p.y()}};
}

}  // namespace rbqt
