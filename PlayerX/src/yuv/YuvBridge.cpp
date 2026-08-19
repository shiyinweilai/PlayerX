#include "YuvBridge.h"
#include "YuvAnalyzer.h"

#include <QDir>
#include <QSettings>
#include <QTimer>
#include <QUrl>
#include <algorithm>
#include <climits>
#include <cstdio>

// 将路径标准化：统一分隔符为 '/'，处理 file:// URL 前缀
static QString normalizePath(const QString& input) {
    QString p = input.trimmed();
    // 如果是 file:// URL，转为本地路径
    if (p.startsWith(QLatin1String("file://"))) {
        QUrl url(p);
        p = url.toLocalFile();
    }
    // 统一路径分隔符为 /
    p = QDir::fromNativeSeparators(p);
    return p;
}

YuvBridge::YuvBridge(QObject* parent)
    : QObject(parent) {
    for (int i = 0; i < MaxSlots; ++i) {
        m_analyzers[i] = std::make_unique<rb::YuvAnalyzer>();
        m_displayModes[i] = 0;
    }
}

YuvBridge::~YuvBridge() = default;

// ── 批量打开 ──────────────────────────────────────────────────────────

int YuvBridge::openFiles(const QVariantList& files) {
    QStringList paths;
    paths.reserve(files.size());
    for (const QVariant& v : files) {
        const QString p = normalizePath(v.toString());
        if (!p.isEmpty()) paths << p;
    }

    // 先清空旧的，保证 slot 从 0 开始连续编号。
    closeAll();

    int opened = 0;
    for (int i = 0; i < paths.size() && opened < MaxSlots; ++i) {
        // 各自读自己的持久化参数（"WxH|fmt|fps"），做到每个文件独立参数。
        // 无记录则用默认（1920×1080 / yuv420p / 30）。
        int w = 1920, h = 1080;
        QString fmt = "yuv420p";
        double fps = 30.0;
        const QString paramsStr = yuvFileParams(paths[i]);
        if (!paramsStr.isEmpty()) {
            const QStringList parts = paramsStr.split('|');
            if (parts.size() >= 1) {
                const QStringList wh = parts[0].split('x');
                if (wh.size() == 2) {
                    w = wh[0].toInt();
                    h = wh[1].toInt();
                    if (w <= 0) w = 1920;
                    if (h <= 0) h = 1080;
                }
            }
            if (parts.size() >= 2 && !parts[1].isEmpty()) fmt = parts[1];
            if (parts.size() >= 3) {
                fps = parts[2].toDouble();
                if (fps <= 0.0) fps = 30.0;
            }
        }

        if (!m_analyzers[opened]->open(paths[i], w, h, fmt, fps)) {
            continue;  // 打开失败则跳过，尝试下一个
        }
        m_displayModes[opened] = 0;
        refreshFrameImage(opened);
        ++opened;
    }

    emit slotCountChanged();
    if (opened > 0) {
        // 通知 QML 重建渲染窗口（slot 0 作为代表）
        emit fileOpened(0);
    }
    return opened;
}

void YuvBridge::closeAll() {
    for (int i = 0; i < MaxSlots; ++i) {
        stopTimer(i);
        m_analyzers[i]->close();
        m_frameImages[i] = QImage();
        m_displayModes[i] = 0;
    }
    emit slotCountChanged();
}

int YuvBridge::slotCount() const {
    int n = 0;
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_analyzers[i]->isOpen()) ++n;
    }
    return n;
}

// ── 单 slot 文件操作 ──────────────────────────────────────────────────

void YuvBridge::closeFile(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;
    stopTimer(slot);
    m_analyzers[slot]->close();
    m_frameImages[slot] = QImage();

    // 压缩：把后续 slot 前移，保持打开的 slot 从 0 开始连续无空洞，
    // 这样 QML 端 Repeater model = slotCount 即可正确遍历。
    for (int i = slot; i < MaxSlots - 1; ++i) {
        m_analyzers[i]      = std::move(m_analyzers[i + 1]);
        m_frameImages[i]    = std::move(m_frameImages[i + 1]);
        m_displayModes[i]   = m_displayModes[i + 1];
    }
    m_analyzers[MaxSlots - 1]    = std::make_unique<rb::YuvAnalyzer>();
    m_frameImages[MaxSlots - 1]  = QImage();
    m_displayModes[MaxSlots - 1] = 0;

    emit frameChanged(slot);
    emit fileOpened(slot);
    emit slotCountChanged();
}

void YuvBridge::gotoFrame(int slot, int frameNum) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;
    if (m_analyzers[slot]->seekToFrame(frameNum)) {
        refreshFrameImage(slot);
    }
}

void YuvBridge::nextFrame(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;
    m_analyzers[slot]->nextFrame();
    refreshFrameImage(slot);
}

void YuvBridge::prevFrame(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;
    m_analyzers[slot]->prevFrame();
    refreshFrameImage(slot);
}

void YuvBridge::firstFrame(int slot) {
    gotoFrame(slot, 0);
}

void YuvBridge::lastFrame(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    const int total = m_analyzers[slot]->totalFrames();
    if (total > 0) gotoFrame(slot, total - 1);
}

// ── 单 slot 查询 ──────────────────────────────────────────────────────

QImage  YuvBridge::frameImage(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_frameImages[slot] : QImage();
}
int     YuvBridge::currentFrame(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_analyzers[slot]->currentFrame() : 0;
}
int     YuvBridge::totalFrames(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_analyzers[slot]->totalFrames() : 0;
}
int     YuvBridge::width(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_analyzers[slot]->width() : 0;
}
int     YuvBridge::height(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_analyzers[slot]->height() : 0;
}
QString YuvBridge::filePath(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_analyzers[slot]->filePath() : QString();
}
QString YuvBridge::fileName(int slot) const {
    const QString p = filePath(slot);
    const int idx = std::max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    return (idx >= 0) ? p.mid(idx + 1) : p;
}
QString YuvBridge::fmtName(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_analyzers[slot]->pixelFormatName() : QString();
}
double  YuvBridge::fps(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_analyzers[slot]->fps() : 0.0;
}
bool    YuvBridge::hasFile(int slot) const {
    return (slot >= 0 && slot < MaxSlots) && m_analyzers[slot]->isOpen();
}
int     YuvBridge::displayMode(int slot) const {
    return (slot >= 0 && slot < MaxSlots) ? m_displayModes[slot] : 0;
}
void    YuvBridge::setDisplayMode(int slot, int mode) {
    if (slot < 0 || slot >= MaxSlots) return;
    mode = std::clamp(mode, 0, 3);
    if (mode == m_displayModes[slot]) return;
    m_displayModes[slot] = mode;
    refreshFrameImage(slot);
    emit displayModeChanged(slot);
}

QVariantList YuvBridge::pixelBlock8x8(int slot, int px, int py) const {
    QVariantList result;
    if (slot < 0 || slot >= MaxSlots) return result;
    if (!m_analyzers[slot]->isOpen()) return result;

    // 对齐到 8 的倍数
    const int bx = (px / 8) * 8;
    const int by = (py / 8) * 8;

    for (int row = 0; row < 8; ++row) {
        for (int col = 0; col < 8; ++col) {
            const int x = bx + col;
            const int y = by + row;
            auto pix = m_analyzers[slot]->getPixelYUV(x, y);
            QVariantMap m;
            m["y"] = pix.y;
            m["u"] = pix.u;
            m["v"] = pix.v;
            result.append(m);
        }
    }
    return result;
}

QVariantMap YuvBridge::pixelBlockStats8x8(int slot, int px, int py) const {
    QVariantMap result;
    if (slot < 0 || slot >= MaxSlots) return result;
    if (!m_analyzers[slot]->isOpen()) return result;

    // 对齐到 8 的倍数（与 pixelBlock8x8 保持一致）
    const int bx = (px / 8) * 8;
    const int by = (py / 8) * 8;

    long long ySum = 0, uSum = 0, vSum = 0;
    int yMin = INT_MAX, yMax = INT_MIN;
    int uMin = INT_MAX, uMax = INT_MIN;
    int vMin = INT_MAX, vMax = INT_MIN;
    int valid = 0;

    for (int row = 0; row < 8; ++row) {
        for (int col = 0; col < 8; ++col) {
            const int x = bx + col;
            const int y = by + row;
            auto pix = m_analyzers[slot]->getPixelYUV(x, y);
            if (pix.y < 0) continue;   // 越界/无效像素
            ++valid;
            ySum += pix.y; uSum += pix.u; vSum += pix.v;
            yMin = std::min(yMin, pix.y); yMax = std::max(yMax, pix.y);
            uMin = std::min(uMin, pix.u); uMax = std::max(uMax, pix.u);
            vMin = std::min(vMin, pix.v); vMax = std::max(vMax, pix.v);
        }
    }

    if (valid == 0) return result;
    const long long n = valid;
    result["yAvg"] = int(ySum / n); result["yMin"] = yMin; result["yMax"] = yMax;
    result["uAvg"] = int(uSum / n); result["uMin"] = uMin; result["uMax"] = uMax;
    result["vAvg"] = int(vSum / n); result["vMin"] = vMin; result["vMax"] = vMax;
    return result;
}

QVariantMap YuvBridge::histogram(int slot, int plane) const {
    QVariantMap result;
    if (slot < 0 || slot >= MaxSlots) return result;
    if (!m_analyzers[slot]->isOpen()) return result;

    const rb::YuvAnalyzer::PlaneHistogram h =
        m_analyzers[slot]->computeHistogram(plane);
    if (h.bins.empty()) return result;

    QVariantList bins;
    bins.reserve(static_cast<int>(h.bins.size()));
    for (int v : h.bins) bins.append(v);

    result["bins"]     = bins;
    result["mean"]     = h.mean;
    result["stddev"]   = h.stddev;
    result["min"]      = h.minVal;
    result["max"]      = h.maxVal;
    result["binCount"] = h.binCount;
    return result;
}

// ── 预设持久化 ──────────────────────────────────────────────────────
// 用 QSettings 把用户的"尺寸 / 格式 / 帧率"历史存到磁盘，
// 跨会话保留，下次直接下拉复用。可单独删除任一项。
//
// 内部约定：每个集合内部"最近用在前"，并按 QSettings 数组语义去重。

namespace {

// QSettings 在 Qt 6 禁用了拷贝，所以 helper 返回单例引用。
// 关键：用 INI 格式 + 显式 scope/organization/application，把存储位置固定下来，
// 避免依赖 QCoreApplication::setOrganizationName 等上层设置（不同平台默认
// 行为差异大），同时 INI 文件可直接查看便于调试持久化问题。
//
// 存储位置（macOS）：~/Library/Preferences/PlayerX/YuvBridge.ini
// 存储位置（Linux）：~/.config/PlayerX/YuvBridge.ini
QSettings& yuvSettings() {
    static QSettings s(QSettings::IniFormat, QSettings::UserScope,
                       QStringLiteral("PlayerX"), QStringLiteral("YuvBridge"));
    return s;
}

constexpr const char* kSizesKey   = "yuv_presets/sizes";
constexpr const char* kFormatsKey = "yuv_presets/formats";
constexpr const char* kFpsKey     = "yuv_presets/fps";
constexpr const char* kFileListKey = "yuv_presets/filelist";
constexpr const char* kFileParamsPrefix = "yuv_presets/fileparams/";

// 取文件 basename 作为持久化 key，避免完整路径中的 '/' 被 QSettings 解析为 group。
QString basenameOf(const QString& p) {
    const int idx = std::max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    return (idx >= 0) ? p.mid(idx + 1) : p;
}

// 强制同步写盘，确保 setYuv* 调用立即落到磁盘文件（而不是仅停留在内存），
// 避免应用异常退出或 onFileListChanged 触发的最后一次写丢失。
void yuvSettingsSync() {
    yuvSettings().sync();
}

// 把字符串 list 按"去重 + 大小写敏感"保存到 key。
void appendUniqueString(QAnyStringView key, const QString& value) {
    QStringList list = yuvSettings().value(key).toStringList();
    list.removeAll(value);
    list.prepend(value);
    yuvSettings().setValue(key, list);
}

// 把字符串 list 从 key 移除一项。
void removeString(QAnyStringView key, const QString& value) {
    QStringList list = yuvSettings().value(key).toStringList();
    if (list.removeAll(value) > 0) {
        yuvSettings().setValue(key, list);
    }
}

// 把 fps 列表（QList<double>）按"去重 + 容差 1e-6"保存。
void appendUniqueFps(QAnyStringView key, double fps) {
    QVariantList raw = yuvSettings().value(key).toList();
    QList<double> list;
    for (const QVariant& v : raw) list.push_back(v.toDouble());
    // remove existing equal
    for (int i = list.size() - 1; i >= 0; --i) {
        if (qFuzzyCompare(list[i] + 1.0, fps + 1.0)) {
            list.removeAt(i);
        }
    }
    list.prepend(fps);
    QVariantList out;
    for (double d : list) out.append(d);
    yuvSettings().setValue(key, out);
}

void removeFps(QAnyStringView key, double fps) {
    QVariantList raw = yuvSettings().value(key).toList();
    QList<double> list;
    for (const QVariant& v : raw) list.push_back(v.toDouble());
    bool changed = false;
    for (int i = list.size() - 1; i >= 0; --i) {
        if (qFuzzyCompare(list[i] + 1.0, fps + 1.0)) {
            list.removeAt(i);
            changed = true;
        }
    }
    if (changed) {
        QVariantList out;
        for (double d : list) out.append(d);
        yuvSettings().setValue(key, out);
    }
}

} // namespace

// ── 尺寸预设 ──
QStringList YuvBridge::yuvSizePresets() const {
    return yuvSettings().value(kSizesKey).toStringList();
}
void YuvBridge::addYuvSizePreset(const QString& size) {
    const QString v = size.trimmed().toLower();
    if (v.isEmpty()) return;
    appendUniqueString(kSizesKey, v);
    emit yuvPresetsChanged();
}
void YuvBridge::removeYuvSizePreset(const QString& size) {
    const QString v = size.trimmed().toLower();
    removeString(kSizesKey, v);
    emit yuvPresetsChanged();
}

// ── 像素格式预设 ──
QStringList YuvBridge::yuvFormatPresets() const {
    return yuvSettings().value(kFormatsKey).toStringList();
}
void YuvBridge::addYuvFormatPreset(const QString& fmt) {
    const QString v = fmt.trimmed().toLower();
    if (v.isEmpty()) return;
    appendUniqueString(kFormatsKey, v);
    emit yuvPresetsChanged();
}
void YuvBridge::removeYuvFormatPreset(const QString& fmt) {
    const QString v = fmt.trimmed().toLower();
    removeString(kFormatsKey, v);
    emit yuvPresetsChanged();
}

// ── 帧率预设 ──
QList<double> YuvBridge::yuvFpsPresets() const {
    QVariantList raw = yuvSettings().value(kFpsKey).toList();
    QList<double> list;
    for (const QVariant& v : raw) list.push_back(v.toDouble());
    return list;
}
void YuvBridge::addYuvFpsPreset(double fps) {
    if (fps <= 0.0 || fps > 1000.0) return;
    appendUniqueFps(kFpsKey, fps);
    emit yuvPresetsChanged();
}
void YuvBridge::removeYuvFpsPreset(double fps) {
    removeFps(kFpsKey, fps);
    emit yuvPresetsChanged();
}

// ── 文件列表 + 每文件参数持久化 ──────────────────────────────────────

QStringList YuvBridge::yuvFileList() const {
    const QStringList list = yuvSettings().value(kFileListKey).toStringList();
    qDebug("[YuvBridge] yuvFileList: %d files <- %s",
           list.size(), yuvSettings().fileName().toUtf8().constData());
    return list;
}

void YuvBridge::setYuvFileList(const QVariantList& files) {
    QStringList list;
    list.reserve(files.size());
    for (const QVariant& v : files) {
        const QString p = normalizePath(v.toString());
        if (!p.isEmpty()) list << p;
    }
    yuvSettings().setValue(kFileListKey, list);
    yuvSettingsSync();
    qDebug("[YuvBridge] setYuvFileList: %d files -> %s",
           list.size(), yuvSettings().fileName().toUtf8().constData());
}

QString YuvBridge::yuvFileParams(const QString& path) const {
    const QString key = QString::fromLatin1(kFileParamsPrefix) + basenameOf(path);
    return yuvSettings().value(key).toString();
}

void YuvBridge::setYuvFileParams(const QString& path, const QString& params) {
    const QString key = QString::fromLatin1(kFileParamsPrefix) + basenameOf(path);
    yuvSettings().setValue(key, params);
    yuvSettingsSync();
}

// ── 内部 ──────────────────────────────────────────────────────────────

void YuvBridge::refreshFrameImage(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) {
        m_frameImages[slot] = QImage();
        emit frameChanged(slot);
        return;
    }

    switch (m_displayModes[slot]) {
        case 0: m_frameImages[slot] = m_analyzers[slot]->getFrameImage();   break; // YUV全彩
        case 1: m_frameImages[slot] = m_analyzers[slot]->getPlaneImage(0);  break; // Y 平面
        case 2: m_frameImages[slot] = m_analyzers[slot]->getPlaneImage(1);  break; // U 平面
        case 3: m_frameImages[slot] = m_analyzers[slot]->getPlaneImage(2);  break; // V 平面
        default: m_frameImages[slot] = m_analyzers[slot]->getFrameImage();  break;
    }

    emit frameChanged(slot);
}

void YuvBridge::stopTimer(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (m_playTimers[slot]) {
        m_playTimers[slot]->stop();
        delete m_playTimers[slot];
        m_playTimers[slot] = nullptr;
    }
    m_playing[slot] = false;
    m_reversing[slot] = false;
}

void YuvBridge::play(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;

    stopTimer(slot);
    m_playing[slot] = true;
    m_reversing[slot] = false;

    const double fpsVal = m_analyzers[slot]->fps();
    const int intervalMs = (fpsVal > 0) ? qMax(1, (int)(1000.0 / fpsVal)) : 33;

    m_playTimers[slot] = new QTimer(this);
    m_playTimers[slot]->setInterval(intervalMs);
    connect(m_playTimers[slot], &QTimer::timeout, this, [this, slot]() {
        if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) {
            stopTimer(slot);
            emit playStateChanged(slot);
            return;
        }
        const int cur = m_analyzers[slot]->currentFrame();
        const int total = m_analyzers[slot]->totalFrames();
        if (cur >= total - 1) {
            // 到达末尾，停止播放
            stopTimer(slot);
            emit playStateChanged(slot);
            return;
        }
        m_analyzers[slot]->nextFrame();
        refreshFrameImage(slot);
    });
    m_playTimers[slot]->start();
    emit playStateChanged(slot);
}

void YuvBridge::playReverse(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;

    stopTimer(slot);
    m_playing[slot] = true;
    m_reversing[slot] = true;

    const double fpsVal = m_analyzers[slot]->fps();
    const int intervalMs = (fpsVal > 0) ? qMax(1, (int)(1000.0 / fpsVal)) : 33;

    m_playTimers[slot] = new QTimer(this);
    m_playTimers[slot]->setInterval(intervalMs);
    connect(m_playTimers[slot], &QTimer::timeout, this, [this, slot]() {
        if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) {
            stopTimer(slot);
            emit playStateChanged(slot);
            return;
        }
        const int cur = m_analyzers[slot]->currentFrame();
        if (cur <= 0) {
            stopTimer(slot);
            emit playStateChanged(slot);
            return;
        }
        m_analyzers[slot]->prevFrame();
        refreshFrameImage(slot);
    });
    m_playTimers[slot]->start();
    emit playStateChanged(slot);
}

void YuvBridge::pause(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    stopTimer(slot);
    emit playStateChanged(slot);
}

void YuvBridge::togglePlayPause(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (m_playing[slot]) {
        pause(slot);
    } else {
        play(slot);
    }
}

bool YuvBridge::isPlaying(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return false;
    return m_playing[slot];
}

bool YuvBridge::isReversing(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return false;
    return m_reversing[slot];
}

void YuvBridge::skipForward(int slot, int frames) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;
    const int cur = m_analyzers[slot]->currentFrame();
    const int total = m_analyzers[slot]->totalFrames();
    const int target = qMin(cur + frames, total - 1);
    m_analyzers[slot]->seekToFrame(target);
    refreshFrameImage(slot);
}

void YuvBridge::skipBackward(int slot, int frames) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;
    const int cur = m_analyzers[slot]->currentFrame();
    const int target = qMax(cur - frames, 0);
    m_analyzers[slot]->seekToFrame(target);
    refreshFrameImage(slot);
}

void YuvBridge::resetFrame(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;
    stopTimer(slot);
    m_analyzers[slot]->seekToFrame(0);
    refreshFrameImage(slot);
    emit playStateChanged(slot);
}
