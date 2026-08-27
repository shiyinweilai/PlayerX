#include "YuvBridge.h"
#include "YuvAnalyzer.h"

#include <QDir>
#include <QSettings>
#include <QTimer>
#include <QUrl>
#include <QtConcurrent>
#include <QFutureWatcher>
#include <algorithm>
#include <climits>
#include <cstdio>
#include <cstdlib>

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

// 前向声明：yuvSettings() 的完整定义在文件下方（预设持久化区块的匿名命名空间内）。
// 同一翻译单元内所有匿名命名空间引用同一命名空间，故此处声明与下方定义会正确合并，
// 使得构造函数可在其定义之前调用它。
namespace {
QSettings& yuvSettings();
}

YuvBridge::YuvBridge(QObject* parent)
    : QObject(parent) {
    for (int i = 0; i < MaxSlots; ++i) {
        m_analyzers[i] = std::make_unique<rb::YuvAnalyzer>();
        m_displayModes[i] = 0;
    }
    // "内嵌操作按钮隐藏" 偏好：固定每次启动为 true（隐藏内嵌控制条），
    // 不做持久化恢复，避免老用户在 QSettings 里残留的旧值导致菜单默认勾选状态错乱。
    // 同时主动清掉历史持久化值，确保干净状态。
    yuvSettings().remove("yuv_presets/inlineControlsHidden");
    m_inlineControlsHidden = true;

    // 色度插值模式：从 QSettings 恢复，默认 0 = NearestNeighbor
    m_chromaInterpolation = yuvSettings().value("yuv_presets/chromaInterpolation", 0).toInt();
    if (m_chromaInterpolation < 0 || m_chromaInterpolation > 2) m_chromaInterpolation = 0;
    // 同步到所有 analyzer（此时文件尚未打开，只是设好默认值）
    for (int i = 0; i < MaxSlots; ++i) {
        m_analyzers[i]->setChromaInterpolation(
            static_cast<rb::YuvAnalyzer::ChromaInterpolation>(m_chromaInterpolation));
    }

    // 颜色转换标准：从 QSettings 恢复，默认 0 = BT709 limited range（现代高清标准）
    m_colorConversion = yuvSettings().value("yuv_presets/colorConversion", 0).toInt();
    if (m_colorConversion < 0 || m_colorConversion > 5) m_colorConversion = 0;
    for (int i = 0; i < MaxSlots; ++i) {
        m_analyzers[i]->setColorConversion(
            static_cast<rb::YuvAnalyzer::ColorConversion>(m_colorConversion));
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
        // 等待异步解码完成（如果正在运行），避免 Worker 线程访问已关闭的 analyzer
        if (m_watchers[i] && m_watchers[i]->isRunning()) {
            m_watchers[i]->waitForFinished();
        }
        // 等待统计计算完成
        if (m_statsWatchers[i] && m_statsWatchers[i]->isRunning()) {
            m_statsWatchers[i]->waitForFinished();
        }
        m_asyncBusy[i] = false;
        m_pendingFrame[i] = -1;
        m_statsPendingFrame[i] = -1;
        invalidateStatsCache(i);
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
    // 等待异步解码完成
    if (m_watchers[slot] && m_watchers[slot]->isRunning()) {
        m_watchers[slot]->waitForFinished();
    }
    // 等待统计计算完成
    if (m_statsWatchers[slot] && m_statsWatchers[slot]->isRunning()) {
        m_statsWatchers[slot]->waitForFinished();
    }
    m_asyncBusy[slot] = false;
    m_pendingFrame[slot] = -1;
    m_statsPendingFrame[slot] = -1;
    invalidateStatsCache(slot);
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
    // 异步：seek+read+convert 全在 Worker 线程
    refreshFrameImageAsyncToFrame(slot, frameNum);
}

void YuvBridge::nextFrame(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;
    const int cur = m_analyzers[slot]->currentFrame();
    refreshFrameImageAsyncToFrame(slot, cur + 1);
}

void YuvBridge::prevFrame(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;
    const int cur = m_analyzers[slot]->currentFrame();
    refreshFrameImageAsyncToFrame(slot, cur - 1);
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

    // 对齐到 m_blockSize 的倍数
    const int bs = m_blockSize;
    const int bx = (px / bs) * bs;
    const int by = (py / bs) * bs;

    for (int row = 0; row < bs; ++row) {
        for (int col = 0; col < bs; ++col) {
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

    // 对齐到 m_blockSize 的倍数（与 pixelBlock8x8 保持一致）
    const int bs = m_blockSize;
    const int bx = (px / bs) * bs;
    const int by = (py / bs) * bs;

    long long ySum = 0, uSum = 0, vSum = 0;
    int yMin = INT_MAX, yMax = INT_MIN;
    int uMin = INT_MAX, uMax = INT_MIN;
    int vMin = INT_MAX, vMax = INT_MIN;
    int valid = 0;

    for (int row = 0; row < bs; ++row) {
        for (int col = 0; col < bs; ++col) {
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
    if (slot < 0 || slot >= MaxSlots) return QVariantMap();
    if (plane < 0 || plane > 2) return QVariantMap();
    // 返回缓存值（由 computeStatsAsync 异步填充）。
    // 缓存未就绪时返回空 map，QML 会收到 statsReady 后重新绑定。
    if (m_cachedStats[slot].frameNum >= 0 && !m_cachedStats[slot].hist[plane].isEmpty()) {
        return m_cachedStats[slot].hist[plane];
    }
    return QVariantMap();
}

QVariantMap YuvBridge::blockHistogram(int slot, int plane, int px, int py) const {
    QVariantMap result;
    if (slot < 0 || slot >= MaxSlots) return result;
    if (!m_analyzers[slot]->isOpen()) return result;

    const rb::YuvAnalyzer::PlaneHistogram h =
        m_analyzers[slot]->computeBlockHistogram(plane, px, py, m_blockSize);
    if (h.bins.empty()) return result;

    QVariantList bins;
    bins.reserve(static_cast<int>(h.bins.size()));
    for (int v : h.bins) bins.append(v);

    result["bins"]     = bins;
    result["mean"]     = h.mean;
    result["stddev"]   = h.stddev;
    result["variance"] = h.variance;
    result["min"]      = h.minVal;
    result["max"]      = h.maxVal;
    result["range"]    = h.range;
    result["binCount"] = h.binCount;
    return result;
}

// ── 帧级"梯度 / 纹理 / 锐利度"全方向统计 ─────────────────────────────
QVariantMap YuvBridge::planeStats(int slot, int plane) const {
    if (slot < 0 || slot >= MaxSlots) return QVariantMap();
    if (plane < 0 || plane > 2) return QVariantMap();
    // 返回缓存值（由 computeStatsAsync 异步填充）。
    if (m_cachedStats[slot].frameNum >= 0 && !m_cachedStats[slot].stats[plane].isEmpty()) {
        return m_cachedStats[slot].stats[plane];
    }
    return QVariantMap();
}

// ── 块级"梯度 / 纹理 / 锐利度"统计（与 blockHistogram 同一块）──────────
// 字段与 planeStats 完全一致，方便 UI 端共用同一组 QML 组件。差异：
//   - 计算范围限制在对齐到 blockSize 倍数后的 [bx..bx+blockSize-1]×[by..by+blockSize-1]
//   - sampleCount 反映该块实际参与计算的像素数（通常 = blockSize²）
QVariantMap YuvBridge::blockStats(int slot, int plane, int px, int py) const {
    QVariantMap result;
    if (slot < 0 || slot >= MaxSlots) return result;
    if (!m_analyzers[slot]->isOpen()) return result;

    const rb::YuvAnalyzer::PlaneStats s =
        m_analyzers[slot]->computeBlockStats(plane, px, py, m_blockSize);
    if (s.sampleCount == 0) return result;

    result["mean"]            = s.mean;
    result["stddev"]          = s.stddev;
    result["variance"]        = s.variance;
    result["min"]             = s.minVal;
    result["max"]             = s.maxVal;
    result["range"]           = s.range;
    result["gradHorizMean"]   = s.gradHorizMean;
    result["gradVertMean"]    = s.gradVertMean;
    result["gradDiag45Mean"]  = s.gradDiag45Mean;
    result["gradDiag135Mean"] = s.gradDiag135Mean;
    result["gradMean"]        = s.gradMean;
    result["laplacianEnergy"] = s.laplacianEnergy;
    result["tenengrad"]       = s.tenengrad;
    result["sampleCount"]     = static_cast<qlonglong>(s.sampleCount);
    return result;
}

QVariantMap YuvBridge::blockDiffOverview(int slotA, int slotB, int plane) const {
    QVariantMap result;
    if (slotA < 0 || slotA >= MaxSlots || slotB < 0 || slotB >= MaxSlots) return result;
    if (!m_analyzers[slotA]->isOpen() || !m_analyzers[slotB]->isOpen()) return result;

    // 取两路的公共分辨率（交集），避免分辨率不一致时越界。
    const int w = std::min(m_analyzers[slotA]->width(),  m_analyzers[slotB]->width());
    const int h = std::min(m_analyzers[slotA]->height(), m_analyzers[slotB]->height());
    if (w <= 0 || h <= 0) return result;

    const int bs = std::max(1, m_blockSize);
    const int cols = (w + bs - 1) / bs;
    const int rows = (h + bs - 1) / bs;
    if (cols <= 0 || rows <= 0) return result;

    QVariantList values;
    values.reserve(cols * rows);
    double maxDiff = 0.0;
    int firstCol = -1, firstRow = -1;
    // 判定为"有差异"的阈值（avg abs diff），过滤掉量化误差等噪声级别的抖动。
    const double diffThreshold = 1.0;

    for (int by = 0; by < rows; ++by) {
        for (int bx = 0; bx < cols; ++bx) {
            const int x0 = bx * bs;
            const int y0 = by * bs;
            const int x1 = std::min(x0 + bs, w);
            const int y1 = std::min(y0 + bs, h);

            long long sum = 0;
            int count = 0;
            for (int y = y0; y < y1; ++y) {
                for (int x = x0; x < x1; ++x) {
                    const auto pa = m_analyzers[slotA]->getPixelYUV(x, y);
                    const auto pb = m_analyzers[slotB]->getPixelYUV(x, y);
                    int va, vb;
                    switch (plane) {
                        case 1:  va = pa.u; vb = pb.u; break;
                        case 2:  va = pa.v; vb = pb.v; break;
                        default: va = pa.y; vb = pb.y; break;
                    }
                    if (va < 0 || vb < 0) continue;
                    sum += std::abs(va - vb);
                    ++count;
                }
            }
            const double avgDiff = (count > 0) ? (double(sum) / count) : 0.0;
            values.append(avgDiff);
            if (avgDiff > maxDiff) maxDiff = avgDiff;
            if (firstCol < 0 && avgDiff >= diffThreshold) {
                firstCol = bx;
                firstRow = by;
            }
        }
    }

    result["cols"] = cols;
    result["rows"] = rows;
    result["blockSize"] = bs;
    result["width"] = w;
    result["height"] = h;
    result["values"] = values;
    result["maxDiff"] = maxDiff;
    result["firstDiffCol"] = firstCol;
    result["firstDiffRow"] = firstRow;
    return result;
}

void YuvBridge::setHoverPixel(int slot, int px, int py, bool valid) {
    m_hoverSlot = slot;
    m_hoverPixelX = px;
    m_hoverPixelY = py;
    m_hoverValid = valid;
    emit hoverChanged();
}

void YuvBridge::setBlockSize(int size) {
    // 仅接受 8/16/32/64 四档，其余取最近的合法值。
    int v = 8;
    if (size >= 64) v = 64;
    else if (size >= 32) v = 32;
    else if (size >= 16) v = 16;
    else v = 8;

    if (v == m_blockSize) return;
    m_blockSize = v;
    emit blockSizeChanged();
    // 块大小变化会影响当前悬浮位置对应的块内容/高亮范围，一并通知刷新。
    emit hoverChanged();
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

// ── "上次打开"位置持久化 ──────────────────────────────────────────────
// QML 的 FileDialog/FolderDialog 在某些平台 / 首次打开时不会自动记忆目录，
// 显式把"上次成功选中的目录"写到 QSettings，下次打开时回填到 currentFolder。
namespace {
constexpr const char* kLastFolderKey = "yuv_presets/lastFolder";
}
QString YuvBridge::lastOpenedFolder() const {
    return yuvSettings().value(kLastFolderKey).toString();
}
void YuvBridge::setLastOpenedFolder(const QString& folder) {
    if (folder.isEmpty()) return;
    yuvSettings().setValue(kLastFolderKey, folder);
    yuvSettingsSync();
}

void YuvBridge::setInlineControlsHidden(bool hidden) {
    if (m_inlineControlsHidden == hidden) return;
    m_inlineControlsHidden = hidden;
    // 不再持久化该偏好：每次启动固定为"隐藏内嵌控制条"。
    // 如果用户曾勾选显示，下次重启也会自动回到隐藏状态。
    emit inlineControlsHiddenChanged();
}

void YuvBridge::setPixelInfoVisible(bool visible) {
    if (m_pixelInfoVisible == visible) return;
    m_pixelInfoVisible = visible;
    emit pixelInfoVisibleChanged();
}

void YuvBridge::setChromaInterpolation(int mode) {
    if (mode < 0 || mode > 2) mode = 0;
    if (m_chromaInterpolation == mode) return;
    m_chromaInterpolation = mode;
    // 持久化到 QSettings
    yuvSettings().setValue("yuv_presets/chromaInterpolation", mode);
    yuvSettingsSync();
    // 同步到所有 analyzer（已打开的会立即重建 sws 上下文，未打开的仅记录值）
    for (int i = 0; i < MaxSlots; ++i) {
        m_analyzers[i]->setChromaInterpolation(
            static_cast<rb::YuvAnalyzer::ChromaInterpolation>(mode));
    }
    // 刷新所有已打开 slot 的帧图像以应用新的插值
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_analyzers[i]->isOpen()) refreshFrameImage(i);
    }
    emit chromaInterpolationChanged();
}

void YuvBridge::setColorConversion(int mode) {
    if (mode < 0 || mode > 5) mode = 0;
    if (m_colorConversion == mode) return;
    m_colorConversion = mode;
    // 持久化到 QSettings
    yuvSettings().setValue("yuv_presets/colorConversion", mode);
    yuvSettingsSync();
    // 同步到所有 analyzer（已打开的会立即重建 sws 上下文，未打开的仅记录值）
    for (int i = 0; i < MaxSlots; ++i) {
        m_analyzers[i]->setColorConversion(
            static_cast<rb::YuvAnalyzer::ColorConversion>(mode));
    }
    // 刷新所有已打开 slot 的帧图像以应用新的颜色转换
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_analyzers[i]->isOpen()) refreshFrameImage(i);
    }
    emit colorConversionChanged();
}

// ── 全局缩放比例 ──────────────────────────────────────────────────────
// 档位常量：与 YuvDisplayItem 内部 m_scalePresets / m_scaleValues 严格保持一致。
//   0: 1/8, 1: 1/4, 2: 1/2, 3: 1X, 4: 2X, 5: 4X, 6: 8X
static const qreal kScaleValues[7] = {0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0};

void YuvBridge::setGlobalScale(qreal s) {
    if (s <= 0) s = 1.0;
    if (qFuzzyCompare(m_globalScale, s)) return;
    m_globalScale = s;
    // 不持久化：每次启动固定为 1X（用户要求"超大视频缩放到当前屏幕"，避免
    // 老用户上次关闭时是 1/8，下次启动首屏只看到 1/8 的小图）。
    emit globalScaleChanged();
}

void YuvBridge::setRightSidebarOpen(bool open) {
    if (m_rightSidebarOpen == open) return;
    m_rightSidebarOpen = open;
    emit rightSidebarOpenChanged();
    // 右侧栏展开时，如果当前在播放，立即触发当前帧的统计计算
    // （播放期间右侧栏展开 → 兼顾实时统计渲染）
    if (open) {
        for (int slot = 0; slot < MaxSlots; ++slot) {
            if (m_analyzers[slot] && m_analyzers[slot]->isOpen()) {
                const int curFrame = m_analyzers[slot]->currentFrame();
                if (m_cachedStats[slot].frameNum != curFrame) {
                    computeStatsAsync(slot, curFrame);
                } else {
                    emit statsReady(slot);
                }
            }
        }
    }
}

int YuvBridge::currentScaleIndex() const {
    for (int i = 0; i < 7; ++i) {
        if (qFuzzyCompare(m_globalScale, kScaleValues[i])) return i;
    }
    return 3;  // 兜底指向 1X
}

void YuvBridge::setCurrentScaleIndex(int idx) {
    if (idx < 0 || idx >= 7) idx = 3;
    setGlobalScale(kScaleValues[idx]);
}

QStringList YuvBridge::scalePresetLabels() const {
    return QStringList{"1/8", "1/4", "1/2", "1X", "2X", "4X", "8X"};
}

// 滚轮缩放：delta>0 放大一档，delta<0 缩小一档。QML 滚轮事件一般以 ±120 为一格。
void YuvBridge::bumpScale(int delta) {
    int idx = currentScaleIndex();
    if (delta > 0)      ++idx;
    else if (delta < 0) --idx;
    if (idx < 0) idx = 0;
    if (idx > 6) idx = 6;
    if (idx == currentScaleIndex()) return;  // 已到边界，不再触发 change
    setCurrentScaleIndex(idx);
}

// 线性连续缩放：globalScale × factor，clamp 到 [1/8, 8]。
// 与 bumpScale 的档位式跳变（1→2→4→8，每次翻倍）不同，这里做平滑连续缩放，
// 滚轮每次只乘一个小系数（如 1.1），视觉跳变感弱很多。
void YuvBridge::zoomBy(qreal factor) {
    if (factor <= 0) return;
    qreal target = m_globalScale * factor;
    constexpr qreal kMinScale = 0.125;  // 1/8
    constexpr qreal kMaxScale = 8.0;    // 8X
    if (target < kMinScale) target = kMinScale;
    if (target > kMaxScale) target = kMaxScale;
    setGlobalScale(target);
}

// 还原视图：缩放回 1X（发 globalScaleChanged → 预缩放图重算 + paint 重绘），
// 并发 resetViewChanged 让所有 YuvDisplayItem 把自己内部的 panX/panY 归零。
// 这样 QML 端只需一句 YuvBridge.resetView() 即可完整还原视图。
void YuvBridge::resetView() {
    setGlobalScale(1.0);   // 内部会判断是否变化，未变则不发 change，避免无谓重算
    emit resetViewChanged();
}

// ── 内部 ──────────────────────────────────────────────────────────────

void YuvBridge::refreshFrameImage(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) {
        m_frameImages[slot] = QImage();
        emit frameChanged(slot);
        return;
    }

    // 检查是否已有异步任务在进行中。如果当前请求的帧与 pending 帧不同，
    // 取消旧任务（不等完成），启动新的。如果相同，则等待已有任务完成即可。
    const int targetFrame = m_analyzers[slot]->currentFrame();

    if (m_asyncBusy[slot]) {
        // 已有异步任务在进行
        if (m_pendingFrame[slot] == targetFrame) {
            // 同一帧已在解码中，无需重复启动
            return;
        }
        // 不同帧：等待当前任务完成后自动启动新的（通过 watcher finished 信号链）
        // 不主动 cancel（QImage 计算不可中断），但标记需要重新刷新
        // pendingFrame 会在 finished 回调里检查并决定是否需要再发一次
        m_pendingFrame[slot] = -2;  // 标记"需要重试"
        return;
    }

    refreshFrameImageAsync(slot);
}

void YuvBridge::refreshFrameImageAsync(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;

    const int targetFrame = m_analyzers[slot]->currentFrame();
    refreshFrameImageAsyncToFrame(slot, targetFrame);
}

void YuvBridge::refreshFrameImageAsyncToFrame(int slot, int targetFrame) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;

    const int displayMode = m_displayModes[slot];

    // 如果已有异步任务在进行中，标记需要重试（finished 回调会检查）
    if (m_asyncBusy[slot]) {
        m_pendingFrame[slot] = -2;  // 标记"需要重试"
        return;
    }

    m_asyncBusy[slot] = true;
    m_pendingFrame[slot] = targetFrame;

    // 主线程先设置 m_currentFrame（锁内），这样 Worker 线程的幂等检查能跳过 seek
    {
        // YuvAnalyzer::seekToFrame 会锁+readCurrentFrameLocked，但我们不想在主线程做 I/O
        // 所以只设置 frame number，让 Worker 线程做 seek+read
        // 这里用 lockData 直接设 m_currentFrame（通过 seekToFrameNoLock 的幂等检查实现）
    }

    auto* analyzer = m_analyzers[slot].get();
    QFuture<QImage> future = QtConcurrent::run([analyzer, targetFrame, displayMode]() -> QImage {
        analyzer->lockData();
        // Worker 线程做 seek+read+convert（全在锁内）
        analyzer->seekToFrameNoLock(targetFrame);
        QImage img = analyzer->getFrameImageLocked(displayMode);
        analyzer->unlockData();
        return img;
    });

    if (!m_watchers[slot]) {
        m_watchers[slot] = new QFutureWatcher<QImage>(this);
        connect(m_watchers[slot], &QFutureWatcher<QImage>::finished, this, [this, slot]() {
            if (slot < 0 || slot >= MaxSlots || !m_watchers[slot]) return;

            const QImage result = m_watchers[slot]->result();
            m_frameImages[slot] = result;
            m_asyncBusy[slot] = false;

            // 检查是否在解码期间有新的帧请求
            const int pending = m_pendingFrame[slot];
            m_pendingFrame[slot] = -1;

            if (pending == -2) {
                // 解码期间有新的帧请求，重新触发当前帧
                refreshFrameImage(slot);
            } else {
                emit frameChanged(slot);
                // 非播放状态 → 总是计算帧级统计
                // 播放状态 + 右侧栏展开 → 兼顾实时统计渲染，也计算
                // 播放状态 + 右侧栏收起 → 跳过统计，保证最大帧率
                if (!m_playing[slot] || m_rightSidebarOpen) {
                    const int curFrame = m_analyzers[slot]->currentFrame();
                    computeStatsAsync(slot, curFrame);
                }
            }
        });
    }

    m_watchers[slot]->setFuture(future);
}

void YuvBridge::invalidateStatsCache(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    m_cachedStats[slot].frameNum = -1;
    for (int i = 0; i < 3; ++i) {
        m_cachedStats[slot].hist[i].clear();
        m_cachedStats[slot].stats[i].clear();
    }
}

void YuvBridge::computeStatsAsync(int slot, int frameNum) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;

    // 如果该帧已缓存，直接发信号刷新
    if (m_cachedStats[slot].frameNum == frameNum) {
        emit statsReady(slot);
        return;
    }

    // 如果已有统计计算在进行中，标记需要重试
    if (m_statsWatchers[slot] && m_statsWatchers[slot]->isRunning()) {
        m_statsPendingFrame[slot] = frameNum;
        return;
    }

    m_statsPendingFrame[slot] = frameNum;

    // 如果 watcher 还没创建，创建之
    if (!m_statsWatchers[slot]) {
        m_statsWatchers[slot] = new QFutureWatcher<void>(this);
        connect(m_statsWatchers[slot], &QFutureWatcher<void>::finished, this, [this, slot]() {
            if (slot < 0 || slot >= MaxSlots || !m_statsWatchers[slot]) return;
            // 检查是否在计算期间有新的帧请求
            const int pending = m_statsPendingFrame[slot];
            if (pending >= 0 && pending != m_cachedStats[slot].frameNum) {
                computeStatsAsync(slot, pending);
            } else {
                m_statsPendingFrame[slot] = -1;
                emit statsReady(slot);
            }
        });
    }

    auto* analyzer = m_analyzers[slot].get();
    const int targetFrame = frameNum;

    // 在 Worker 线程计算所有 3 个平面的 histogram + planeStats
    // 关键优化：锁内只做帧数据快照拷贝（~2ms），释放锁后基于快照计算，
    // 不再阻塞解码 Worker 线程。
    QFuture<void> future = QtConcurrent::run([this, analyzer, slot, targetFrame]() {
        // ── 锁内：确保帧数据就位 + 快照拷贝（~2ms）──
        analyzer->lockData();
        analyzer->seekToFrameNoLock(targetFrame);
        auto snapshot = analyzer->snapshotCurrentFrameLocked();
        analyzer->unlockData();

        // ── 锁外：基于快照计算直方图 + 统计（不阻塞解码）──
        CachedStats cs;
        cs.frameNum = targetFrame;

        for (int plane = 0; plane < 3; ++plane) {
            // 直方图
            auto h = rb::YuvAnalyzer::computeHistogramFromSnapshot(snapshot, plane);
            if (!h.bins.empty()) {
                QVariantMap hm;
                QVariantList bins;
                bins.reserve(static_cast<int>(h.bins.size()));
                for (int v : h.bins) bins.append(v);
                hm["bins"]     = bins;
                hm["mean"]     = h.mean;
                hm["stddev"]   = h.stddev;
                hm["variance"] = h.variance;
                hm["min"]      = h.minVal;
                hm["max"]      = h.maxVal;
                hm["range"]    = h.range;
                hm["binCount"] = h.binCount;
                cs.hist[plane] = hm;
            }

            // 平面统计（梯度/纹理/锐利度）
            auto s = rb::YuvAnalyzer::computeStatsFromSnapshot(snapshot, plane);
            if (s.sampleCount > 0) {
                QVariantMap sm;
                sm["mean"]            = s.mean;
                sm["stddev"]          = s.stddev;
                sm["variance"]        = s.variance;
                sm["min"]             = s.minVal;
                sm["max"]             = s.maxVal;
                sm["range"]           = s.range;
                sm["gradHorizMean"]   = s.gradHorizMean;
                sm["gradVertMean"]    = s.gradVertMean;
                sm["gradDiag45Mean"]  = s.gradDiag45Mean;
                sm["gradDiag135Mean"] = s.gradDiag135Mean;
                sm["gradMean"]        = s.gradMean;
                sm["laplacianEnergy"] = s.laplacianEnergy;
                sm["tenengrad"]       = s.tenengrad;
                sm["sampleCount"]     = static_cast<qlonglong>(s.sampleCount);
                cs.stats[plane] = sm;
            }
        }

        // 写入缓存（Worker 线程写，主线程通过 finished 回调读取并发 statsReady。
        // histogram()/planeStats() 返回旧缓存或空 map 不会崩溃，statsReady 后刷新。）
        m_cachedStats[slot] = cs;
    });

    m_statsWatchers[slot]->setFuture(future);
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
    m_replayFromStart[slot] = false;
}

void YuvBridge::play(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;

    stopTimer(slot);
    m_playing[slot] = true;
    m_reversing[slot] = false;

    // 如果已在最后一帧，从头播放：异步 seek 到第 0 帧，定时器回调中等待 seek
    // 完成后正常推进，避免 "play → 检测到末尾 → 立即停止" 的无效空转。
    const int curAtStart = m_analyzers[slot]->currentFrame();
    const int totalAtStart = m_analyzers[slot]->totalFrames();
    if (curAtStart >= totalAtStart - 1) {
        m_replayFromStart[slot] = true;
        refreshFrameImageAsyncToFrame(slot, 0);
    }

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

        // 从头播放等待中：seek 到 0 完成前跳过末尾检测
        if (m_replayFromStart[slot]) {
            if (m_asyncBusy[slot]) {
                // seek 仍在进行中，等下一拍
                return;
            }
            // seek 到 0 已完成，清除标记，正常推进到下一帧
            m_replayFromStart[slot] = false;
            const int curNow = m_analyzers[slot]->currentFrame();
            refreshFrameImageAsyncToFrame(slot, curNow + 1);
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
        // 异步解码下一帧：seek+read+sws_scale 全在 Worker 线程，主线程零阻塞
        refreshFrameImageAsyncToFrame(slot, cur + 1);
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
        // 异步解码上一帧
        refreshFrameImageAsyncToFrame(slot, cur - 1);
    });
    m_playTimers[slot]->start();
    emit playStateChanged(slot);
}

void YuvBridge::pause(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    stopTimer(slot);
    // 暂停后触发帧级统计计算（播放期间跳过的统计在暂停后补算）
    if (m_analyzers[slot] && m_analyzers[slot]->isOpen()) {
        const int curFrame = m_analyzers[slot]->currentFrame();
        // 如果当前帧已有缓存，直接发信号刷新；否则异步计算
        if (m_cachedStats[slot].frameNum != curFrame) {
            computeStatsAsync(slot, curFrame);
        } else {
            emit statsReady(slot);
        }
    }
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
    refreshFrameImageAsyncToFrame(slot, target);
}

void YuvBridge::skipBackward(int slot, int frames) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;
    const int cur = m_analyzers[slot]->currentFrame();
    const int target = qMax(cur - frames, 0);
    refreshFrameImageAsyncToFrame(slot, target);
}

void YuvBridge::resetFrame(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;
    stopTimer(slot);
    refreshFrameImageAsyncToFrame(slot, 0);
    emit playStateChanged(slot);
}
