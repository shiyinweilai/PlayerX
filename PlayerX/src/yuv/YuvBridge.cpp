#include "YuvBridge.h"
#include "YuvAnalyzer.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSettings>
#include <QStandardPaths>
#include <QStringConverter>
#include <QTextStream>
#include <QTimer>
#include <QUrl>
#include <QtConcurrent>
#include <QFutureWatcher>
#include <QMetaObject>
#include <QHash>
#include <QVector>
#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>

extern "C" {
#include <libavutil/pixdesc.h>
}

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

    // 多通道同步播放帧率：从 QSettings 恢复，默认 30fps
    m_syncFps = yuvSettings().value("yuv_presets/syncFps", 30).toInt();
    if (m_syncFps < 1 || m_syncFps > 240) m_syncFps = 30;
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
    stopSyncPlay();
    for (int i = 0; i < MaxSlots; ++i) {
        stopTimer(i);
        // 等待异步解码完成（如果正在运行），避免 Worker 线程访问已关闭的 analyzer
        if (m_watchers[i] && m_watchers[i]->isRunning()) {
            m_watchers[i]->waitForFinished();
        }
        // 等待同步播放解码完成
        if (m_decodeWatchers[i] && m_decodeWatchers[i]->isRunning()) {
            m_decodeWatchers[i]->waitForFinished();
        }
        // 等待统计计算完成
        if (m_statsWatchers[i] && m_statsWatchers[i]->isRunning()) {
            m_statsWatchers[i]->waitForFinished();
        }
        m_asyncBusy[i] = false;
        m_pendingFrame[i] = -1;
        m_asyncTarget[i] = -1;
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
    stopSyncPlay();
    stopTimer(slot);
    // 等待异步解码完成
    if (m_watchers[slot] && m_watchers[slot]->isRunning()) {
        m_watchers[slot]->waitForFinished();
    }
    // 等待同步播放解码完成
    if (m_decodeWatchers[slot] && m_decodeWatchers[slot]->isRunning()) {
        m_decodeWatchers[slot]->waitForFinished();
    }
    // 等待统计计算完成
    if (m_statsWatchers[slot] && m_statsWatchers[slot]->isRunning()) {
        m_statsWatchers[slot]->waitForFinished();
    }
    m_asyncBusy[slot] = false;
    m_pendingFrame[slot] = -1;
    m_asyncTarget[slot] = -1;
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
    refreshFrameImageAsyncToFrame(slot, currentFrame(slot) + 1);
}

void YuvBridge::prevFrame(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot]->isOpen()) return;
    refreshFrameImageAsyncToFrame(slot, currentFrame(slot) - 1);
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
    if (slot < 0 || slot >= MaxSlots) return 0;
    // 显示帧号以 m_visibleFrame 为准：重置/seek 立刻改这里，避免分析器被
    // 对照快照 seek 走之后底栏仍停在旧帧、或画面已回第一帧而数字不动。
    if (m_analyzers[slot]->isOpen() && m_visibleFrame[slot] >= 0)
        return m_visibleFrame[slot];
    return m_analyzers[slot]->currentFrame();
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

static QVariantMap frameFeaturesToMap(const rb::YuvAnalyzer::FrameFeatures& f) {
    QVariantMap m;
    if (!f.valid) return m;
    m["ok"] = true;
    m["bitDepth"] = f.bitDepth;
    m["peak"] = f.peak;
    m["yEntropy"] = f.yEntropy;
    m["yUsedBins"] = f.yUsedBins;
    m["yLongestHole"] = f.yLongestHole;
    m["yHoleRatio"] = f.yHoleRatio;
    m["yP01"] = f.yP01;
    m["yP05"] = f.yP05;
    m["yP50"] = f.yP50;
    m["yP95"] = f.yP95;
    m["yP99"] = f.yP99;
    m["yFootroomPct"] = f.yFootroomPct;
    m["yHeadroomPct"] = f.yHeadroomPct;
    m["ySat0Pct"] = f.ySat0Pct;
    m["ySatPeakPct"] = f.ySatPeakPct;
    m["uOutRangePct"] = f.uOutRangePct;
    m["vOutRangePct"] = f.vOutRangePct;
    m["yNoiseSigma"] = f.yNoiseSigma;
    m["yBandingScore"] = f.yBandingScore;
    m["yAcEnergy"] = f.yAcEnergy;
    m["chromaMeanAbs"] = f.chromaMeanAbs;
    m["chromaRatio"] = f.chromaRatio;
    m["uvCorr"] = f.uvCorr;
    QVariantList blk;
    for (int i = 0; i < 4; ++i) {
        QVariantMap b;
        b["size"] = f.blk[i].size;
        b["count"] = f.blk[i].count;
        b["meanVar"] = f.blk[i].meanVar;
        b["p90Var"] = f.blk[i].p90Var;
        b["highEnergyPct"] = f.blk[i].highEnergyPct;
        blk.append(b);
    }
    m["blockVar"] = blk;
    m["temporalValid"] = f.temporalValid;
    m["ti"] = f.ti;
    m["sadY"] = f.sadY;
    m["mseY"] = f.mseY;
    m["madY"] = f.madY;
    m["maxAbsY"] = f.maxAbsY;
    m["staticBlk16Pct"] = f.staticBlk16Pct;
    m["meanAbsDiffY"] = f.meanAbsDiffY;
    return m;
}

QVariantMap YuvBridge::frameFeatures(int slot) const {
    if (slot < 0 || slot >= MaxSlots) return QVariantMap();
    if (m_cachedStats[slot].frameNum >= 0)
        return m_cachedStats[slot].features;
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

    // 必须对同一显示帧各拍一份快照再比：同步播放时后台预解码会把
    // analyzer 各自 seek 到不同的未来帧，直接 getPixelYUV 会把错位当成差异。
    int target = m_visibleFrame[slotA];
    if (target < 0) target = m_analyzers[slotA]->currentFrame();
    auto snapAt = [](rb::YuvAnalyzer* a, int frame) {
        a->lockData();
        a->seekToFrameNoLock(frame);
        auto s = a->snapshotCurrentFrameLocked();
        a->unlockData();
        return s;
    };
    const auto snapA = snapAt(m_analyzers[slotA].get(), target);
    const auto snapB = snapAt(m_analyzers[slotB].get(), target);
    if (!snapA.valid || !snapB.valid) return result;

    // 取两路的公共分辨率（交集），避免分辨率不一致时越界。
    const int w = std::min(snapA.width, snapB.width);
    const int h = std::min(snapA.height, snapB.height);
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

    auto sample = [plane](const rb::YuvAnalyzer::FrameSnapshot& s, int x, int y) -> int {
        if (!s.valid || x < 0 || y < 0 || x >= s.width || y >= s.height) return -1;
        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(s.pixFmt);
        const bool hi = desc && desc->comp[0].depth > 8;
        const int p = (plane <= 0) ? 0 : ((plane == 1) ? 1 : 2);
        if (p >= s.planeCount || s.planes[p].data.empty()) return -1;
        int sx = x, sy = y;
        if (p > 0 && desc) {
            sx = x >> desc->log2_chroma_w;
            sy = y >> desc->log2_chroma_h;
        }
        const auto& pl = s.planes[p];
        if (sx < 0 || sy < 0 || sx >= pl.pw || sy >= pl.ph) return -1;
        if (hi) {
            const auto* row = reinterpret_cast<const uint16_t*>(pl.data.data() + sy * pl.stride);
            return int(row[sx]);
        }
        return int(pl.data[sy * pl.stride + sx]);
    };

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
                    const int va = sample(snapA, x, y);
                    const int vb = sample(snapB, x, y);
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
    result["frame"] = target;
    return result;
}

namespace {

rb::YuvAnalyzer::FrameSnapshot snapshotSlotAt(rb::YuvAnalyzer* a, int frame) {
    a->lockData();
    a->seekToFrameNoLock(frame);
    auto s = a->snapshotCurrentFrameLocked();
    a->unlockData();
    return s;
}

int sampleSnap(const rb::YuvAnalyzer::FrameSnapshot& s, int plane, int x, int y) {
    if (!s.valid || x < 0 || y < 0 || x >= s.width || y >= s.height) return -1;
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(s.pixFmt);
    const bool hi = desc && desc->comp[0].depth > 8;
    const int p = (plane <= 0) ? 0 : ((plane == 1) ? 1 : 2);
    if (p >= s.planeCount || s.planes[p].data.empty()) return -1;
    int sx = x, sy = y;
    if (p > 0 && desc) {
        sx = x >> desc->log2_chroma_w;
        sy = y >> desc->log2_chroma_h;
    }
    const auto& pl = s.planes[p];
    if (sx < 0 || sy < 0 || sx >= pl.pw || sy >= pl.ph) return -1;
    if (hi) {
        const auto* row = reinterpret_cast<const uint16_t*>(pl.data.data() + sy * pl.stride);
        return int(row[sx]);
    }
    return int(pl.data[sy * pl.stride + sx]);
}

void planeMetrics(const rb::YuvAnalyzer::FrameSnapshot& a,
                  const rb::YuvAnalyzer::FrameSnapshot& b,
                  int plane, int w, int h, const AVPixFmtDescriptor* desc,
                  double* mse, int* maxAbs, qint64* sad, qint64* count) {
    int stepX = 1, stepY = 1;
    if (plane > 0 && desc) {
        stepX = 1 << desc->log2_chroma_w;
        stepY = 1 << desc->log2_chroma_h;
    }
    double se = 0;
    int mx = 0;
    qint64 s = 0, n = 0;
    for (int y = 0; y < h; y += stepY) {
        for (int x = 0; x < w; x += stepX) {
            const int va = sampleSnap(a, plane, x, y);
            const int vb = sampleSnap(b, plane, x, y);
            if (va < 0 || vb < 0) continue;
            const int d = std::abs(va - vb);
            se += double(d) * double(d);
            s += d;
            if (d > mx) mx = d;
            ++n;
        }
    }
    *mse = (n > 0) ? (se / double(n)) : 0;
    *maxAbs = mx;
    *sad = s;
    *count = n;
}

double psnrFromMse(double mse, int peak) {
    if (mse <= 0) return 99.0;
    return 10.0 * std::log10((double(peak) * double(peak)) / mse);
}

} // namespace

QVariantMap YuvBridge::compareFrameMetrics(int slotA, int slotB) const {
    QVariantMap r;
    r["ok"] = false;
    if (slotA < 0 || slotA >= MaxSlots || slotB < 0 || slotB >= MaxSlots) return r;
    if (!m_analyzers[slotA]->isOpen() || !m_analyzers[slotB]->isOpen()) return r;
    int target = m_visibleFrame[slotA];
    if (target < 0) target = m_analyzers[slotA]->currentFrame();
    const auto sa = snapshotSlotAt(m_analyzers[slotA].get(), target);
    const auto sb = snapshotSlotAt(m_analyzers[slotB].get(), target);
    if (!sa.valid || !sb.valid) return r;
    const int w = std::min(sa.width, sb.width);
    const int h = std::min(sa.height, sb.height);
    if (w <= 0 || h <= 0) return r;
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(sa.pixFmt);
    const int peak = (desc && desc->comp[0].depth > 8) ? ((1 << desc->comp[0].depth) - 1) : 255;
    double mse[3] = {0, 0, 0};
    int mx[3] = {0, 0, 0};
    qint64 sad[3] = {0, 0, 0}, cnt[3] = {0, 0, 0};
    for (int p = 0; p < 3; ++p)
        planeMetrics(sa, sb, p, w, h, desc, &mse[p], &mx[p], &sad[p], &cnt[p]);
    const bool identical = (mx[0] == 0 && mx[1] == 0 && mx[2] == 0);
    r["ok"] = true;
    r["frame"] = target;
    r["identical"] = identical;
    r["peak"] = peak;
    r["maxAbsY"] = mx[0]; r["maxAbsU"] = mx[1]; r["maxAbsV"] = mx[2];
    r["madY"] = (cnt[0] > 0) ? (double(sad[0]) / double(cnt[0])) : 0;
    r["psnrY"] = psnrFromMse(mse[0], peak);
    r["psnrU"] = psnrFromMse(mse[1], peak);
    r["psnrV"] = psnrFromMse(mse[2], peak);
    return r;
}

void YuvBridge::gotoBothFrames(int frameNum) {
    globalPause();
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_analyzers[i] && m_analyzers[i]->isOpen())
            gotoFrame(i, frameNum);
    }
}

void YuvBridge::stopExportFrameStats() {
    if (!m_statsExportBusy)
        return;
    m_statsExportCancel.store(true);
}

void YuvBridge::startExportFrameStats(int slot, int firstFrame, int lastFrame,
                                      const QVariantMap& opts) {
    if (m_statsExportBusy) {
        emit statsExportFinished(false, "已有导出任务在运行", QString());
        return;
    }
    if (slot < 0 || slot >= MaxSlots || !m_analyzers[slot] || !m_analyzers[slot]->isOpen()) {
        emit statsExportFinished(false, "当前槽未打开 YUV", QString());
        return;
    }
    const bool wantHist = opts.value(QStringLiteral("histSummary"), true).toBool();
    const bool wantBins = opts.value(QStringLiteral("histBins"), false).toBool();
    const bool wantGrad = opts.value(QStringLiteral("gradient"), true).toBool();
    const bool wantFeat = opts.value(QStringLiteral("features"), true).toBool();
    const bool wantGop = opts.value(QStringLiteral("gopSummary"), true).toBool();
    int gopSize = opts.value(QStringLiteral("gopSize"), 32).toInt();
    if (gopSize < 1) gopSize = 1;
    if (gopSize > 4096) gopSize = 4096;
    if (!wantHist && !wantBins && !wantGrad && !wantFeat && !wantGop) {
        emit statsExportFinished(false, "请至少勾选一项导出内容", QString());
        return;
    }

    const int total = m_analyzers[slot]->totalFrames();
    int first = std::max(0, firstFrame);
    int last = (lastFrame < 0) ? (total - 1) : lastFrame;
    if (last >= total) last = total - 1;
    if (first > last) {
        emit statsExportFinished(false, "帧范围无效", QString());
        return;
    }

    const QString srcPath = m_analyzers[slot]->filePath();
    const int w = m_analyzers[slot]->width();
    const int h = m_analyzers[slot]->height();
    const QString fmt = m_analyzers[slot]->pixelFormatName();
    const double fps = m_analyzers[slot]->fps();
    QString outPath = opts.value(QStringLiteral("outPath")).toString();
    if (outPath.isEmpty()) {
        QString dir = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
        if (dir.isEmpty()) dir = QDir::homePath() + QStringLiteral("/Downloads");
        QDir().mkpath(dir);
        const QString stem = QFileInfo(srcPath).completeBaseName();
        outPath = QDir(dir).filePath(
            QStringLiteral("%1_slot%2_f%3-%4_frame.csv")
                .arg(stem).arg(slot + 1).arg(first + 1).arg(last + 1));
    }
    {
        QFileInfo csvInfo(outPath);
        QString batch = csvInfo.completeBaseName();
        if (batch.endsWith(QStringLiteral("_frame")))
            batch.chop(6);
        if (batch.isEmpty())
            batch = QStringLiteral("yuv_stats");
        QDir parent = csvInfo.dir();
        if (parent.dirName() != batch) {
            const QString folder = parent.filePath(batch);
            QDir().mkpath(folder);
            const QString fileName = csvInfo.fileName().isEmpty()
                ? (batch + QStringLiteral("_frame.csv"))
                : csvInfo.fileName();
            outPath = QDir(folder).filePath(fileName);
        }
    }

    m_statsExportCancel.store(false);
    m_statsExportBusy = true;
    emit statsExportProgress(QStringLiteral("开始导出统计…"), 0);

    QtConcurrent::run([this, srcPath, w, h, fmt, fps, first, last, slot, outPath,
                       wantHist, wantBins, wantGrad, wantFeat, wantGop, gopSize]() {
        auto fail = [this](const QString& msg) {
            QMetaObject::invokeMethod(this, [this, msg]() {
                m_statsExportBusy = false;
                emit statsExportFinished(false, msg, QString());
            }, Qt::QueuedConnection);
        };

        rb::YuvAnalyzer ana;
        if (!ana.open(srcPath, w, h, fmt, fps)) {
            fail(QStringLiteral("无法打开文件进行导出"));
            return;
        }

        auto csvEsc = [](const QString& s) {
            if (!s.contains(QLatin1Char(',')) && !s.contains(QLatin1Char('"'))
                    && !s.contains(QLatin1Char('\n')))
                return s;
            QString t = s;
            t.replace(QLatin1Char('"'), QStringLiteral("\"\""));
            return QStringLiteral("\"") + t + QLatin1Char('"');
        };
        auto binsJson = [](const rb::YuvAnalyzer::PlaneHistogram& h) {
            QJsonArray arr;
            for (int v : h.bins) arr.append(v);
            return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
        };
        const char* planeTag[3] = { "Y", "U", "V" };
        QStringList headers;
        headers << QStringLiteral("poc") << QStringLiteral("gopPoc") << QStringLiteral("gopIdx")
                << QStringLiteral("gopSize") << QStringLiteral("codeIdx") << QStringLiteral("tid")
                << QStringLiteral("fileFrame") << QStringLiteral("slot") << QStringLiteral("file");
        if (wantHist) {
            for (int p = 0; p < 3; ++p) {
                const QString t = QString::fromLatin1(planeTag[p]);
                headers << (t + QStringLiteral("_mean")) << (t + QStringLiteral("_stddev"))
                        << (t + QStringLiteral("_variance")) << (t + QStringLiteral("_min"))
                        << (t + QStringLiteral("_max")) << (t + QStringLiteral("_range"));
            }
        }
        if (wantBins) {
            headers << QStringLiteral("Y_bins") << QStringLiteral("U_bins") << QStringLiteral("V_bins");
        }
        if (wantGrad) {
            for (int p = 0; p < 3; ++p) {
                const QString t = QString::fromLatin1(planeTag[p]);
                headers << (t + QStringLiteral("_gradH")) << (t + QStringLiteral("_gradV"))
                        << (t + QStringLiteral("_grad45")) << (t + QStringLiteral("_grad135"))
                        << (t + QStringLiteral("_gradMean")) << (t + QStringLiteral("_laplacian"))
                        << (t + QStringLiteral("_tenengrad"));
            }
        }
        if (wantFeat) {
            headers << QStringLiteral("Y_p01") << QStringLiteral("Y_p05") << QStringLiteral("Y_p50")
                    << QStringLiteral("Y_p95") << QStringLiteral("Y_p99")
                    << QStringLiteral("Y_entropy") << QStringLiteral("Y_usedBins")
                    << QStringLiteral("Y_holeRatio") << QStringLiteral("Y_longestHole")
                    << QStringLiteral("Y_banding") << QStringLiteral("Y_noiseSigma")
                    << QStringLiteral("Y_footroomPct") << QStringLiteral("Y_headroomPct")
                    << QStringLiteral("Y_sat0Pct") << QStringLiteral("Y_satPeakPct")
                    << QStringLiteral("U_outRangePct") << QStringLiteral("V_outRangePct")
                    << QStringLiteral("Y_acEnergy") << QStringLiteral("chromaMeanAbs")
                    << QStringLiteral("chromaRatio") << QStringLiteral("uvCorr")
                    << QStringLiteral("blk8_meanVar") << QStringLiteral("blk8_p90Var") << QStringLiteral("blk8_highPct")
                    << QStringLiteral("blk16_meanVar") << QStringLiteral("blk16_p90Var") << QStringLiteral("blk16_highPct")
                    << QStringLiteral("blk32_meanVar") << QStringLiteral("blk32_p90Var") << QStringLiteral("blk32_highPct")
                    << QStringLiteral("blk64_meanVar") << QStringLiteral("blk64_p90Var") << QStringLiteral("blk64_highPct")
                    << QStringLiteral("TI") << QStringLiteral("Y_sad") << QStringLiteral("Y_mse")
                    << QStringLiteral("Y_mad") << QStringLiteral("Y_maxAbsDiff")
                    << QStringLiteral("staticBlk16Pct");
        }

        QFile file(outPath);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            fail(QStringLiteral("无法写入 ") + outPath);
            return;
        }
        QTextStream ts(&file);
        ts.setEncoding(QStringConverter::Utf8);
        ts << QStringLiteral("\uFEFF") << headers.join(QLatin1Char(',')) << QLatin1Char('\n');

        auto encodeGopIdx = [&](int poc) {
            if (gopSize < 1 || poc <= 0) return 0;
            return (poc - 1) / gopSize;
        };
        auto temporalId = [&](int poc) {
            if (gopSize < 1 || poc % gopSize == 0) return 0;
            int step = gopSize;
            int tid = 0;
            while (step > 1) {
                step /= 2;
                ++tid;
                if (step < 1) break;
                if ((poc % (2 * step)) == step) return tid;
            }
            return tid;
        };
        auto hierarchicalCodingOrder = [&](int pocFirst, int pocLast) {
            QVector<int> order;
            if (gopSize < 1 || pocFirst > pocLast) return order;
            auto inRange = [&](int p) { return p >= pocFirst && p <= pocLast; };
            if (inRange(0)) order.push_back(0);
            const int kMax = pocLast / gopSize + 1;
            for (int k = 0; k <= kMax; ++k) {
                const int lo = k * gopSize;
                const int hi = (k + 1) * gopSize;
                if (lo > pocLast && k > 0) break;
                if (inRange(hi)) order.push_back(hi);
                int step = gopSize;
                while (step > 1) {
                    step /= 2;
                    if (step < 1) break;
                    for (int p = lo + step; p < hi; p += 2 * step) {
                        if (inRange(p)) order.push_back(p);
                    }
                }
            }
            QVector<char> seen(pocLast + 1, 0);
            for (int p : order) {
                if (p >= 0 && p <= pocLast) seen[p] = 1;
            }
            for (int p = pocFirst; p <= pocLast; ++p) {
                if (!seen[p]) order.push_back(p);
            }
            return order;
        };

        const bool needHist = wantHist || wantBins || wantGop;
        const bool needGrad = wantGrad || wantGop;
        const bool needFeat = wantFeat || wantGop;

        struct GopAcc {
            int gop = -1;
            int startF = 0;
            int endF = 0;
            int n = 0;
            bool hasHead = false;
            double yMeanSum = 0, yStdSum = 0, yGradSum = 0, yTenSum = 0;
            double yMeanMin = 1e300, yMeanMax = 0, yGradMax = 0, yTenMax = 0;
            int nTi = 0;
            double tiSum = 0, tiMax = 0, tiHead = 0;
            double madSum = 0, madMax = 0, mseSum = 0, sadSum = 0;
            int maxAbsMax = 0;
            double staticSum = 0, staticMin = 1e300;
            double footMax = 0, headroomMax = 0, sat0Max = 0, satPMax = 0;
            double uOutMax = 0, vOutMax = 0;
            double entSum = 0, bandMax = 0, noiseSum = 0;
            double blkHighSum[4] = {0, 0, 0, 0};
            double chromaRatioSum = 0, uvCorrSum = 0;
            double headYMean = 0, headYGrad = 0, headYTen = 0;
        };
        QVector<GopAcc> gops;
        GopAcc cur;

        auto flushGop = [&]() {
            if (cur.n > 0) gops.push_back(cur);
            cur = GopAcc();
        };
        auto addGop = [&](int f, const rb::YuvAnalyzer::PlaneHistogram& hy,
                          const rb::YuvAnalyzer::PlaneStats& sy,
                          const rb::YuvAnalyzer::FrameFeatures& feat) {
            const int gi = encodeGopIdx(f);
            if (cur.n > 0 && cur.gop != gi) flushGop();
            if (cur.n == 0) {
                cur.gop = gi;
                cur.startF = f;
            }
            cur.endF = f;
            ++cur.n;
            const int keyPoc = (gi == 0) ? 0 : (gi + 1) * gopSize;
            const bool isHead = (f == keyPoc);
            if (isHead) {
                cur.hasHead = true;
                cur.headYMean = hy.mean;
                cur.headYGrad = sy.gradMean;
                cur.headYTen = sy.tenengrad;
                if (feat.temporalValid) cur.tiHead = feat.ti;
            }
            cur.yMeanSum += hy.mean;
            cur.yStdSum += hy.stddev;
            cur.yGradSum += sy.gradMean;
            cur.yTenSum += sy.tenengrad;
            cur.yMeanMin = std::min(cur.yMeanMin, hy.mean);
            cur.yMeanMax = std::max(cur.yMeanMax, hy.mean);
            cur.yGradMax = std::max(cur.yGradMax, sy.gradMean);
            cur.yTenMax = std::max(cur.yTenMax, sy.tenengrad);
            if (feat.temporalValid) {
                ++cur.nTi;
                cur.tiSum += feat.ti;
                cur.tiMax = std::max(cur.tiMax, feat.ti);
                cur.madSum += feat.madY;
                cur.madMax = std::max(cur.madMax, feat.madY);
                cur.mseSum += feat.mseY;
                cur.sadSum += feat.sadY;
                cur.maxAbsMax = std::max(cur.maxAbsMax, feat.maxAbsY);
                cur.staticSum += feat.staticBlk16Pct;
                cur.staticMin = std::min(cur.staticMin, feat.staticBlk16Pct);
            }
            cur.footMax = std::max(cur.footMax, feat.yFootroomPct);
            cur.headroomMax = std::max(cur.headroomMax, feat.yHeadroomPct);
            cur.sat0Max = std::max(cur.sat0Max, feat.ySat0Pct);
            cur.satPMax = std::max(cur.satPMax, feat.ySatPeakPct);
            cur.uOutMax = std::max(cur.uOutMax, feat.uOutRangePct);
            cur.vOutMax = std::max(cur.vOutMax, feat.vOutRangePct);
            cur.entSum += feat.yEntropy;
            cur.bandMax = std::max(cur.bandMax, feat.yBandingScore);
            cur.noiseSum += feat.yNoiseSigma;
            for (int i = 0; i < 4; ++i) cur.blkHighSum[i] += feat.blk[i].highEnergyPct;
            cur.chromaRatioSum += feat.chromaRatio;
            cur.uvCorrSum += feat.uvCorr;
        };

        const int span = last - first + 1;
        rb::YuvAnalyzer::FrameSnapshot prevSnap;
        bool havePrev = false;
        if (needFeat && first > 0) {
            prevSnap = snapshotSlotAt(&ana, first - 1);
            havePrev = prevSnap.valid;
        }
        QHash<int, QStringList> frameRows;
        for (int f = first; f <= last; ++f) {
            const auto snap = snapshotSlotAt(&ana, f);
            rb::YuvAnalyzer::PlaneHistogram hist[3];
            rb::YuvAnalyzer::PlaneStats st[3];
            rb::YuvAnalyzer::FrameFeatures feat;
            for (int p = 0; p < 3; ++p) {
                if (needHist)
                    hist[p] = rb::YuvAnalyzer::computeHistogramFromSnapshot(snap, p);
                if (needGrad)
                    st[p] = rb::YuvAnalyzer::computeStatsFromSnapshot(snap, p);
            }
            if (needFeat)
                feat = rb::YuvAnalyzer::computeFrameFeaturesFromSnapshot(snap, havePrev ? &prevSnap : nullptr);
            if (wantGop)
                addGop(f, hist[0], st[0], feat);

            const int gi = encodeGopIdx(f);
            QStringList row;
            row << QString::number(f)
                << QString::number(f - gi * gopSize)
                << QString::number(gi)
                << QString::number(gopSize)
                << QString()
                << QString::number(temporalId(f))
                << QString::number(f + 1)
                << QString::number(slot + 1)
                << csvEsc(QFileInfo(srcPath).fileName());
            if (wantHist) {
                for (int p = 0; p < 3; ++p) {
                    row << QString::number(hist[p].mean, 'f', 4)
                        << QString::number(hist[p].stddev, 'f', 4)
                        << QString::number(hist[p].variance, 'f', 4)
                        << QString::number(hist[p].minVal)
                        << QString::number(hist[p].maxVal)
                        << QString::number(hist[p].range);
                }
            }
            if (wantBins) {
                row << csvEsc(binsJson(hist[0]))
                    << csvEsc(binsJson(hist[1]))
                    << csvEsc(binsJson(hist[2]));
            }
            if (wantGrad) {
                for (int p = 0; p < 3; ++p) {
                    row << QString::number(st[p].gradHorizMean, 'f', 4)
                        << QString::number(st[p].gradVertMean, 'f', 4)
                        << QString::number(st[p].gradDiag45Mean, 'f', 4)
                        << QString::number(st[p].gradDiag135Mean, 'f', 4)
                        << QString::number(st[p].gradMean, 'f', 4)
                        << QString::number(st[p].laplacianEnergy, 'f', 4)
                        << QString::number(st[p].tenengrad, 'f', 4);
                }
            }
            if (wantFeat) {
                auto num = [](double v, int prec = 4) { return QString::number(v, 'f', prec); };
                row << num(feat.yP01, 2) << num(feat.yP05, 2) << num(feat.yP50, 2)
                    << num(feat.yP95, 2) << num(feat.yP99, 2)
                    << num(feat.yEntropy) << QString::number(feat.yUsedBins)
                    << num(feat.yHoleRatio) << QString::number(feat.yLongestHole)
                    << num(feat.yBandingScore) << num(feat.yNoiseSigma)
                    << num(feat.yFootroomPct) << num(feat.yHeadroomPct)
                    << num(feat.ySat0Pct) << num(feat.ySatPeakPct)
                    << num(feat.uOutRangePct) << num(feat.vOutRangePct)
                    << num(feat.yAcEnergy) << num(feat.chromaMeanAbs)
                    << num(feat.chromaRatio) << num(feat.uvCorr)
                    << num(feat.blk[0].meanVar) << num(feat.blk[0].p90Var) << num(feat.blk[0].highEnergyPct)
                    << num(feat.blk[1].meanVar) << num(feat.blk[1].p90Var) << num(feat.blk[1].highEnergyPct)
                    << num(feat.blk[2].meanVar) << num(feat.blk[2].p90Var) << num(feat.blk[2].highEnergyPct)
                    << num(feat.blk[3].meanVar) << num(feat.blk[3].p90Var) << num(feat.blk[3].highEnergyPct)
                    << num(feat.ti) << num(feat.sadY, 1) << num(feat.mseY)
                    << num(feat.madY) << QString::number(feat.maxAbsY)
                    << num(feat.staticBlk16Pct);
            }
            frameRows.insert(f, row);
            prevSnap = snap;
            havePrev = snap.valid;

            if (m_statsExportCancel.load()) {
                file.close();
                QFile::remove(outPath);
                fail(QStringLiteral("已停止导出"));
                return;
            }

            if (((f - first) & 3) == 0 || f == last) {
                const QString msg = QStringLiteral("导出帧 %1 / %2…").arg(f - first + 1).arg(span);
                const double ratio = span > 0 ? double(f - first + 1) / double(span) : 1;
                QMetaObject::invokeMethod(this, [this, msg, ratio]() {
                    emit statsExportProgress(msg, ratio);
                }, Qt::QueuedConnection);
            }
        }
        const QVector<int> codeOrder = hierarchicalCodingOrder(first, last);
        int codeIdx = 0;
        for (int poc : codeOrder) {
            auto it = frameRows.find(poc);
            if (it == frameRows.end()) continue;
            QStringList row = it.value();
            if (row.size() > 4)
                row[4] = QString::number(codeIdx);
            ts << row.join(QLatin1Char(',')) << QLatin1Char('\n');
            ++codeIdx;
        }
        file.close();
        flushGop();

        const QFileInfo csvInfo(outPath);
        QString gopPath;
        if (wantGop) {
            QString gopName = csvInfo.completeBaseName();
            if (gopName.endsWith(QStringLiteral("_frame")))
                gopName.chop(6);
            gopPath = csvInfo.dir().filePath(gopName + QStringLiteral("_gop.csv"));
            QFile gf(gopPath);
            if (!gf.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
                fail(QStringLiteral("无法写入 ") + gopPath);
                return;
            }
            QTextStream gs(&gf);
            gs.setEncoding(QStringConverter::Utf8);
            const QStringList gh{
                QStringLiteral("gopIdx"), QStringLiteral("startPoc"), QStringLiteral("endPoc"),
                QStringLiteral("startGopPoc"), QStringLiteral("endGopPoc"),
                QStringLiteral("frames"), QStringLiteral("gopSize"), QStringLiteral("partial"),
                QStringLiteral("hasHead"),
                QStringLiteral("Y_mean_avg"), QStringLiteral("Y_mean_min"), QStringLiteral("Y_mean_max"),
                QStringLiteral("Y_stddev_avg"),
                QStringLiteral("Y_gradMean_avg"), QStringLiteral("Y_gradMean_max"),
                QStringLiteral("Y_tenengrad_avg"), QStringLiteral("Y_tenengrad_max"),
                QStringLiteral("head_Y_mean"), QStringLiteral("head_Y_gradMean"), QStringLiteral("head_Y_tenengrad"),
                QStringLiteral("TI_mean"), QStringLiteral("TI_max"), QStringLiteral("TI_head"),
                QStringLiteral("Y_mad_mean"), QStringLiteral("Y_mad_max"),
                QStringLiteral("Y_mse_mean"), QStringLiteral("Y_sad_sum"), QStringLiteral("Y_maxAbsDiff_max"),
                QStringLiteral("staticBlk16Pct_mean"), QStringLiteral("staticBlk16Pct_min"),
                QStringLiteral("Y_footroomPct_max"), QStringLiteral("Y_headroomPct_max"),
                QStringLiteral("Y_sat0Pct_max"), QStringLiteral("Y_satPeakPct_max"),
                QStringLiteral("U_outRangePct_max"), QStringLiteral("V_outRangePct_max"),
                QStringLiteral("Y_entropy_mean"), QStringLiteral("Y_banding_max"), QStringLiteral("Y_noiseSigma_mean"),
                QStringLiteral("blk8_highPct_mean"), QStringLiteral("blk16_highPct_mean"),
                QStringLiteral("blk32_highPct_mean"), QStringLiteral("blk64_highPct_mean"),
                QStringLiteral("chromaRatio_mean"), QStringLiteral("uvCorr_mean")
            };
            gs << QStringLiteral("\uFEFF") << gh.join(QLatin1Char(',')) << QLatin1Char('\n');
            auto avg = [](double s, int n) { return n > 0 ? s / n : 0.0; };
            auto num = [](double v, int prec = 4) { return QString::number(v, 'f', prec); };
            for (const auto& g : gops) {
                const int n = g.n;
                const int nTi = g.nTi;
                QStringList r;
                r << QString::number(g.gop)
                  << QString::number(g.startF) << QString::number(g.endF)
                  << QString::number(g.startF - g.gop * gopSize)
                  << QString::number(g.endF - g.gop * gopSize)
                  << QString::number(n) << QString::number(gopSize)
                  << QString::number(n != ((g.gop == 0) ? (gopSize + 1) : gopSize) ? 1 : 0)
                  << QString::number(g.hasHead ? 1 : 0)
                  << num(avg(g.yMeanSum, n)) << num(g.yMeanMin) << num(g.yMeanMax)
                  << num(avg(g.yStdSum, n))
                  << num(avg(g.yGradSum, n)) << num(g.yGradMax)
                  << num(avg(g.yTenSum, n)) << num(g.yTenMax)
                  << num(g.headYMean) << num(g.headYGrad) << num(g.headYTen)
                  << num(avg(g.tiSum, nTi)) << num(g.tiMax) << num(g.tiHead)
                  << num(avg(g.madSum, nTi)) << num(g.madMax)
                  << num(avg(g.mseSum, nTi)) << num(g.sadSum, 1) << QString::number(g.maxAbsMax)
                  << num(avg(g.staticSum, nTi)) << num(g.staticMin >= 1e300 ? 0 : g.staticMin)
                  << num(g.footMax) << num(g.headroomMax)
                  << num(g.sat0Max) << num(g.satPMax)
                  << num(g.uOutMax) << num(g.vOutMax)
                  << num(avg(g.entSum, n)) << num(g.bandMax) << num(avg(g.noiseSum, n))
                  << num(avg(g.blkHighSum[0], n)) << num(avg(g.blkHighSum[1], n))
                  << num(avg(g.blkHighSum[2], n)) << num(avg(g.blkHighSum[3], n))
                  << num(avg(g.chromaRatioSum, n)) << num(avg(g.uvCorrSum, n));
                gs << r.join(QLatin1Char(',')) << QLatin1Char('\n');
            }
            gf.close();
        }

        QString readmeStem = csvInfo.completeBaseName();
        if (readmeStem.endsWith(QStringLiteral("_frame")))
            readmeStem.chop(6);
        const QString readmePath = csvInfo.dir().filePath(readmeStem + QStringLiteral(".readme.txt"));
        QFile readme(readmePath);
        QString done = QStringLiteral("已导出 %1 帧").arg(span);
        if (wantGop)
            done += QStringLiteral(" / %1 个 GOP").arg(gops.size());
        if (readme.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            QTextStream rs(&readme);
            rs.setEncoding(QStringConverter::Utf8);
            rs << QStringLiteral("\uFEFF");
            rs << QStringLiteral("PlayerX YUV 统计导出说明\n");
            rs << QStringLiteral("========================\n\n");
            rs << QStringLiteral("逐帧表：") << csvInfo.fileName() << QLatin1Char('\n');
            if (wantGop)
                rs << QStringLiteral("GOP 表：") << QFileInfo(gopPath).fileName() << QLatin1Char('\n');
            rs << QStringLiteral("源文件：") << QFileInfo(srcPath).fileName() << QLatin1Char('\n');
            rs << QStringLiteral("分辨率：") << w << QLatin1Char('x') << h
               << QStringLiteral("  格式：") << fmt
               << QStringLiteral("  fps：") << QString::number(fps, 'f', 3) << QLatin1Char('\n');
            rs << QStringLiteral("槽：") << (slot + 1)
               << QStringLiteral("  导出范围 POC：") << first << QLatin1Char('-') << last
               << QStringLiteral("（播放器帧号 = poc+1）\n");
            rs << QStringLiteral("GOP 大小：") << gopSize
               << QStringLiteral("  行顺序按常见层级 B 编码序（GOP=32 时为 0,32,16,8,24…），不是 0,1,2 显示序。\n");
            rs << QStringLiteral("  假定文件开头为 IDR，其后按 dyadic：先段尾 P，再对半分 B。裸 YUV 无真实参考列表。\n");
            rs << QStringLiteral("  时间量（TI/SAD/MAD）仍相对显示相邻帧（poc 与 poc-1），不是相对编码上一帧。\n");
            rs << QStringLiteral("CSV 无注释行，可用 Excel / pandas 直接打开。本文件解释字段。\n\n");

            rs << QStringLiteral("逐帧表 · 公共列\n");
            rs << QStringLiteral("  poc       显示序 POC，从 0 起（文件第 1 帧 = 0）\n");
            rs << QStringLiteral("  gopPoc    编码 GOP 内偏移：第 0 段为 0..gopSize（含段尾 P），其后各段 1..gopSize\n");
            rs << QStringLiteral("  gopIdx    编码 GOP 段号：poc0 与 1..N 为 0；N+1..2N 为 1。不是 GOP 长度\n");
            rs << QStringLiteral("  gopSize   你输入的切段长度\n");
            rs << QStringLiteral("  codeIdx   本文件导出范围内的编码序号，0 起；行按此排序\n");
            rs << QStringLiteral("  tid       时间层：网格上的 I/P 为 0，然后 16→1、8/24→2，依此类推\n");
            rs << QStringLiteral("  fileFrame 播放器帧号 = poc+1\n");
            rs << QStringLiteral("  slot / file  导出槽（从 1）与源文件名\n\n");

            if (wantHist) {
                rs << QStringLiteral("直方图摘要（当前帧、本平面全部像素）\n");
                rs << QStringLiteral("  {Y,U,V}_mean / _stddev / _variance   均值 / 标准差 / 方差\n");
                rs << QStringLiteral("  {Y,U,V}_min / _max / _range          最小 / 最大 / 极差=max-min\n");
                rs << QStringLiteral("  8bit 值域约 0–255；10bit 约 0–1023。色度平面按该格式实际采样点数统计。\n\n");
            }
            if (wantBins) {
                rs << QStringLiteral("直方图桶\n");
                rs << QStringLiteral("  {Y,U,V}_bins   JSON 数组，下标=像素值，元素=该值的像素个数\n\n");
            }
            if (wantGrad) {
                rs << QStringLiteral("梯度 / 纹理（当前帧、本平面；与上一帧无关）\n");
                rs << QStringLiteral("  {Y,U,V}_gradH / _gradV / _grad45 / _grad135   水平 / 垂直 / 45° / 135° 一阶差分幅值均值\n");
                rs << QStringLiteral("  {Y,U,V}_gradMean     上述四向平均\n");
                rs << QStringLiteral("  {Y,U,V}_laplacian    4 邻域 Laplacian 能量均值（锐利度）\n");
                rs << QStringLiteral("  {Y,U,V}_tenengrad    Sobel 梯度平方和均值（纹理复杂度）\n\n");
            }
            if (wantFeat) {
                rs << QStringLiteral("帧级特征 · 时间量（相对上一帧的 Y 平面，不是相对另一路文件）\n");
                rs << QStringLiteral("  比较对象：POC=N 的 Y 与 POC=N-1 的 Y（显示相邻），不是编码参考帧。\n");
                rs << QStringLiteral("  POC=0 没有上一帧，对应时间量写 0。\n");
                rs << QStringLiteral("  若导出起点 poc>0，会先读 poc-1，因此起点行也有有效时间量。\n");
                rs << QStringLiteral("  TI              ITU-T P.910 风格时间信息：帧差（带符号）的标准差\n");
                rs << QStringLiteral("  Y_sad           帧差绝对值之和 Σ|Y_n − Y_{n-1}|\n");
                rs << QStringLiteral("  Y_mse           帧差均方  mean((Y_n − Y_{n-1})²)\n");
                rs << QStringLiteral("  Y_mad           帧差平均绝对差  mean(|Y_n − Y_{n-1}|)\n");
                rs << QStringLiteral("  Y_maxAbsDiff    帧差最大绝对差  max|Y_n − Y_{n-1}|\n");
                rs << QStringLiteral("  staticBlk16Pct  16×16 块中 SAD < 2×块像素数 的比例（%）；阈值随位深左移\n\n");
                rs << QStringLiteral("帧级特征 · Y 分布（当前帧）\n");
                rs << QStringLiteral("  Y_p01 / p05 / p50 / p95 / p99   直方图分位\n");
                rs << QStringLiteral("  Y_entropy      直方图熵（bit），越大分布越散\n");
                rs << QStringLiteral("  Y_usedBins     出现过的桶数\n");
                rs << QStringLiteral("  Y_holeRatio    [min,max] 内空桶占比\n");
                rs << QStringLiteral("  Y_longestHole  [min,max] 内最长连续空桶（bin 个数）\n");
                rs << QStringLiteral("  Y_banding      由空洞比与最长空洞合成的条带倾向分，越大越像条带/量化台阶\n");
                rs << QStringLiteral("  Y_noiseSigma   隔点 Laplacian 幅值的中位数 / 0.6745，高频噪声尺度估计\n\n");
                rs << QStringLiteral("帧级特征 · 限幅 / 合法范围（当前帧；按位深缩放 TV range）\n");
                rs << QStringLiteral("  8bit：Y 合法 16–235，C 合法 16–240；10bit 对应左移 2 位（64–940 / 64–960）。\n");
                rs << QStringLiteral("  Y_footroomPct / Y_headroomPct   Y 低于 / 高于 TV 亮度范围的像素占比（%）\n");
                rs << QStringLiteral("  Y_sat0Pct / Y_satPeakPct        Y=0 / Y=peak 的像素占比（%）\n");
                rs << QStringLiteral("  U_outRangePct / V_outRangePct   色度超出 TV 色度范围的像素占比（%）\n\n");
                rs << QStringLiteral("帧级特征 · 块方差（当前帧 Y，不重叠块）\n");
                rs << QStringLiteral("  blk{8,16,32,64}_meanVar   该块大小上方差的均值\n");
                rs << QStringLiteral("  blk{8,16,32,64}_p90Var    方差的 90 分位\n");
                rs << QStringLiteral("  blk{8,16,32,64}_highPct   方差 > (4<<bitDepth-8)² 的块占比（%），约 σ>4\n\n");
                rs << QStringLiteral("帧级特征 · 色度（当前帧）\n");
                rs << QStringLiteral("  Y_acEnergy      即 Y 标准差\n");
                rs << QStringLiteral("  chromaMeanAbs   mean((|U−mid|+|V−mid|)/2)，mid=128 或 512\n");
                rs << QStringLiteral("  chromaRatio     chromaMeanAbs / max(Y_acEnergy, 1)\n");
                rs << QStringLiteral("  uvCorr          U 与 V 的 Pearson 相关，范围约 [-1,1]\n\n");
            }
            if (wantGop) {
                rs << QStringLiteral("GOP 表（一段一行；按层级编码 GOP 聚合，不是码流里读出的 GOP）\n");
                rs << QStringLiteral("  第 0 段含 poc 0..N（I + B + 段尾 P）；其后每段含 (kN+1)..(k+1)N\n");
                rs << QStringLiteral("  gopIdx / startPoc / endPoc   段号与覆盖的起止 POC\n");
                rs << QStringLiteral("  startGopPoc / endGopPoc   段内偏移\n");
                rs << QStringLiteral("  frames / gopSize          本段帧数与指定 N；完整第 0 段应为 N+1 帧\n");
                rs << QStringLiteral("  partial         帧数不足完整段为 1\n");
                rs << QStringLiteral("  hasHead         段内关键帧是否在范围内（第 0 段看 poc0，其后看段尾 P）\n");
                rs << QStringLiteral("  Y_mean_* / Y_stddev_avg                段内 Y 均值的均/最小/最大，标准差均值\n");
                rs << QStringLiteral("  Y_gradMean_* / Y_tenengrad_*           段内纹理：均/最大\n");
                rs << QStringLiteral("  head_Y_*        仅 hasHead=1 时有意义：段首帧的空间量（对照 I 帧位置）\n");
                rs << QStringLiteral("  TI_mean / TI_max / TI_head             段内时间信息；TI_head 为段首相对上一显示帧\n");
                rs << QStringLiteral("  Y_mad_* / Y_mse_mean / Y_sad_sum / Y_maxAbsDiff_max\n");
                rs << QStringLiteral("                  段内帧差聚合；SAD 为段内各帧 SAD 之和\n");
                rs << QStringLiteral("  staticBlk16Pct_* 段内静止 16×16 块占比的均/最小\n");
                rs << QStringLiteral("  *_max（限幅/条带）段内峰值，用来抓该 GOP 最差一帧\n");
                rs << QStringLiteral("  blk*_highPct_mean  段内高能块占比均值\n");
                rs << QStringLiteral("  chromaRatio_mean / uvCorr_mean         段内色度均值\n");
                rs << QStringLiteral("  时间量仍是显示相邻帧，不是 B 帧实际参考帧。\n");
            }
            readme.close();
            done += QStringLiteral("，说明见 .readme.txt");
        }

        const QString revealPath = QFileInfo(outPath).absolutePath();
        QMetaObject::invokeMethod(this, [this, done, revealPath]() {
            m_statsExportBusy = false;
            emit statsExportFinished(true, done, revealPath);
        }, Qt::QueuedConnection);
    });
}

void YuvBridge::startScanFirstDiff(int slotA, int slotB, int fromFrame) {
    if (m_scanBusy) {
        emit scanJobFinished(false, -1, "已有扫描在运行");
        return;
    }
    if (slotA < 0 || slotB < 0 || !m_analyzers[slotA]->isOpen() || !m_analyzers[slotB]->isOpen()) {
        emit scanJobFinished(false, -1, "需要打开两路 YUV");
        return;
    }
    const QString pathA = m_analyzers[slotA]->filePath();
    const QString pathB = m_analyzers[slotB]->filePath();
    const int w = m_analyzers[slotA]->width();
    const int h = m_analyzers[slotA]->height();
    const QString fmt = m_analyzers[slotA]->pixelFormatName();
    const double fps = m_analyzers[slotA]->fps();
    const int total = std::min(m_analyzers[slotA]->totalFrames(), m_analyzers[slotB]->totalFrames());
    const int start = std::max(0, fromFrame);
    m_scanBusy = true;
    emit scanJobProgress("开始扫描差异帧…", 0);
    QtConcurrent::run([this, pathA, pathB, w, h, fmt, fps, start, total]() {
        rb::YuvAnalyzer scanA;
        rb::YuvAnalyzer scanB;
        int found = -1;
        int lastMax = 0;
        if (!scanA.open(pathA, w, h, fmt, fps) || !scanB.open(pathB, w, h, fmt, fps)) {
            QMetaObject::invokeMethod(this, [this]() {
                m_scanBusy = false;
                emit scanJobFinished(false, -1, "无法打开对照文件进行扫描");
            }, Qt::QueuedConnection);
            return;
        }
        for (int f = start; f < total; ++f) {
            const auto sa = snapshotSlotAt(&scanA, f);
            const auto sb = snapshotSlotAt(&scanB, f);
            int mx = 0;
            if (sa.valid && sb.valid) {
                const auto& pa = sa.planes[0];
                const auto& pb = sb.planes[0];
                if (!pa.data.empty() && pa.data.size() == pb.data.size()
                        && pa.data == pb.data) {
                    mx = 0;
                } else {
                    const int cw = std::min(sa.width, sb.width);
                    const int ch = std::min(sa.height, sb.height);
                    for (int y = 0; y < ch && mx < 1; ++y) {
                        for (int x = 0; x < cw; ++x) {
                            const int d = std::abs(sampleSnap(sa, 0, x, y) - sampleSnap(sb, 0, x, y));
                            if (d > mx) mx = d;
                            if (mx >= 1) break;
                        }
                    }
                }
            }
            lastMax = mx;
            if ((f & 7) == 0) {
                const QString msg = QString("扫描帧 %1 / %2…").arg(f + 1).arg(total);
                const double ratio = total > 0 ? double(f + 1) / double(total) : 0;
                QMetaObject::invokeMethod(this, [this, msg, ratio]() {
                    emit scanJobProgress(msg, ratio);
                }, Qt::QueuedConnection);
            }
            if (mx >= 1) { found = f; break; }
        }
        QMetaObject::invokeMethod(this, [this, found, lastMax, total, start]() {
            m_scanBusy = false;
            if (found >= 0) {
                gotoBothFrames(found);
                emit scanJobFinished(true, found,
                    QString("首个差异帧 #%1（Y max|Δ|≥1）").arg(found + 1));
            } else {
                emit scanJobFinished(false, -1,
                    QString("从 #%1 到 #%2 未发现 Y 差异").arg(start + 1).arg(total));
            }
            Q_UNUSED(lastMax);
        }, Qt::QueuedConnection);
    });
}

void YuvBridge::setHoverPixel(int slot, int px, int py, bool valid) {
    m_hoverSlot = slot;
    m_hoverPixelX = px;
    m_hoverPixelY = py;
    m_hoverValid = valid;
    emit hoverChanged();
}

void YuvBridge::setBlockSize(int size) {
    int v = 16;
    if (size >= 64) v = 64;
    else if (size >= 32) v = 32;
    else v = 16;

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

void YuvBridge::setSlotInfoVisible(bool visible) {
    if (m_slotInfoVisible == visible) return;
    m_slotInfoVisible = visible;
    emit slotInfoVisibleChanged();
    emit toggleSlotInfoRequested();
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

void YuvBridge::setSyncFps(int fps) {
    if (fps < 1) fps = 1;
    if (fps > 240) fps = 240;
    if (m_syncFps == fps) return;
    m_syncFps = fps;
    yuvSettings().setValue("yuv_presets/syncFps", fps);
    yuvSettingsSync();
    // 若正在同步播放，实时更新主时钟间隔
    if (m_syncTimer) {
        m_syncTimer->setInterval(qMax(1, (int)(1000.0 / m_syncFps)));
    }
    emit syncFpsChanged();
}

void YuvBridge::setDiffDetectEnabled(bool enabled) {
    if (m_diffDetectEnabled == enabled) return;
    m_diffDetectEnabled = enabled;
    // 开启时重置忽略标志
    m_diffIgnoreOnce = false;
    emit diffDetectEnabledChanged();
    // 开启时立即检测一次（帧已加载的情况）
    if (enabled) {
        checkDiffDetect();
    }
}

void YuvBridge::resumeAfterDiff() {
    // 继续比较：仅作 QML 侧关闭 Toast 的 C++ 对应，不做任何操作
    // 播放已停止在当前帧，用户用底部控制推进，每帧继续检测差异
}

void YuvBridge::ignoreDiffContinue() {
    // 忽略后续差异：置忽略标志，恢复播放
    m_diffIgnoreOnce = true;
    if (activeSlotCount() >= 2) {
        startSyncPlay(false);
    }
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
    refreshFrameImageAsyncToFrame(slot, currentFrame(slot));
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

    const int total = m_analyzers[slot]->totalFrames();
    if (total <= 0) return;
    if (targetFrame < 0) targetFrame = 0;
    if (targetFrame >= total) targetFrame = total - 1;

    m_visibleFrame[slot] = targetFrame;
    emit frameChanged(slot);

    if (m_asyncBusy[slot]) {
        m_pendingFrame[slot] = targetFrame;
        return;
    }

    m_asyncBusy[slot] = true;
    m_asyncTarget[slot] = targetFrame;
    m_pendingFrame[slot] = -1;

    const int displayMode = m_displayModes[slot];
    auto* analyzer = m_analyzers[slot].get();
    QFuture<QImage> future = QtConcurrent::run([analyzer, targetFrame, displayMode]() -> QImage {
        analyzer->lockData();
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
            const int decoded = m_asyncTarget[slot];
            m_frameImages[slot] = result;
            m_asyncBusy[slot] = false;
            if (m_analyzers[slot] && m_analyzers[slot]->isOpen() && decoded >= 0)
                m_visibleFrame[slot] = decoded;

            const int pending = m_pendingFrame[slot];
            m_pendingFrame[slot] = -1;
            if (pending >= 0 && pending != decoded) {
                refreshFrameImageAsyncToFrame(slot, pending);
                return;
            }

            emit frameChanged(slot);
            if (!m_playing[slot] || m_rightSidebarOpen)
                computeStatsAsync(slot, decoded);
            if (!m_playing[slot])
                checkDiffDetect();
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
        rb::YuvAnalyzer::FrameSnapshot prevSnap;
        const bool wantPrev = targetFrame > 0;
        if (wantPrev) {
            analyzer->seekToFrameNoLock(targetFrame - 1);
            prevSnap = analyzer->snapshotCurrentFrameLocked();
        }
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

        cs.features = frameFeaturesToMap(
            rb::YuvAnalyzer::computeFrameFeaturesFromSnapshot(
                snapshot, (wantPrev && prevSnap.valid) ? &prevSnap : nullptr));

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

// ── 多通道同步播放 ──────────────────────────────────────────────────────

int YuvBridge::activeSlotCount() const {
    int n = 0;
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_analyzers[i] && m_analyzers[i]->isOpen()) ++n;
    }
    return n;
}

void YuvBridge::startSyncPlay(bool reverse) {
    // 停止所有 per-slot timer 和旧的 sync timer
    for (int i = 0; i < MaxSlots; ++i) stopTimer(i);
    stopSyncPlay();

    const int n = activeSlotCount();
    if (n == 0) return;

    m_syncStep = reverse ? -1 : 1;

    // 固定同步帧率（用户可在顶部菜单设置，默认 30fps）
    const int fps = qMax(1, m_syncFps);
    const int intervalMs = qMax(1, (int)(1000.0 / fps));

    // ── 统一起始帧：强制所有通道从同一帧号开始，消除固定偏移 ──
    // 各通道播放前可能因单独快进/快退处于不同帧，若各自为起点推进，
    // 帧号会始终错开一个固定量。这里取所有通道当前帧的最小值作为
    // 公共起始帧（保证不超过任一通道的 total-1），并把各通道 seek 到该帧。
    int startFrame = INT_MAX;
    int minTotal = INT_MAX;
    for (int i = 0; i < MaxSlots; ++i) {
        if (!m_analyzers[i] || !m_analyzers[i]->isOpen()) continue;
        startFrame = qMin(startFrame, m_analyzers[i]->currentFrame());
        minTotal = qMin(minTotal, m_analyzers[i]->totalFrames());
    }
    if (startFrame == INT_MAX) startFrame = 0;
    if (minTotal == INT_MAX) minTotal = 1;
    // 环绕处理：正向若已在（公共）末尾则从 0 重新开始；倒放若在开头则从末尾开始
    if (!reverse) {
        if (startFrame >= minTotal - 1) startFrame = -1;  // 下一解码帧 = 0
    } else {
        if (startFrame <= 0) startFrame = minTotal;       // 下一解码帧 = minTotal-1
    }

    // 初始化每通道的缓冲与解码起点（统一起点）
    for (int i = 0; i < MaxSlots; ++i) {
        if (!m_analyzers[i] || !m_analyzers[i]->isOpen()) continue;
        m_playing[i] = true;
        m_reversing[i] = reverse;
        m_frameBuffer[i].clear();
        m_decodeInFlight[i] = false;
        m_reachedEnd[i] = false;
        m_decodeTargetFrame[i] = -1;
        m_visibleFrame[i] = startFrame;

        // 所有通道从同一 startFrame 推进
        m_nextDecodeFrame[i] = reverse ? (startFrame - 1) : (startFrame + 1);
    }

    // 主时钟：固定帧率消费缓冲
    if (!m_syncTimer) {
        m_syncTimer = new QTimer(this);
        connect(m_syncTimer, &QTimer::timeout, this, &YuvBridge::onSyncTimerTick);
    }
    m_syncTimer->setInterval(intervalMs);
    m_syncTimer->start();

    // 立即启动各通道的后台解码，预填缓冲
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_analyzers[i] && m_analyzers[i]->isOpen()) scheduleDecode(i);
    }

    for (int i = 0; i < MaxSlots; ++i) {
        if (m_analyzers[i] && m_analyzers[i]->isOpen()) emit playStateChanged(i);
    }
}

void YuvBridge::stopSyncPlay() {
    const bool wasSync = (m_syncTimer != nullptr);
    if (m_syncTimer) {
        m_syncTimer->stop();
        delete m_syncTimer;
        m_syncTimer = nullptr;
    }
    // 仅多路同步播放才用 m_visibleFrame 回写：单路 play() 不维护这套缓冲，
    // 默认 vis=0，globalPause 里无条件对齐会把画面打回第 0 帧。
    if (wasSync) {
        for (int i = 0; i < MaxSlots; ++i) {
            if (!m_analyzers[i] || !m_analyzers[i]->isOpen()) continue;
            const int vis = m_visibleFrame[i];
            if (vis >= 0) {
                m_analyzers[i]->lockData();
                m_analyzers[i]->setCurrentFrameNoLock(vis);
                m_analyzers[i]->unlockData();
            }
        }
    }
    for (int i = 0; i < MaxSlots; ++i) {
        m_frameBuffer[i].clear();
        m_decodeInFlight[i] = false;
        m_reachedEnd[i] = false;
        m_decodeTargetFrame[i] = -1;
        m_nextDecodeFrame[i] = 0;
    }
}

// 触发某通道后台解码下一帧填缓冲（生产者）
void YuvBridge::scheduleDecode(int slot) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;
    if (!m_syncTimer) return;                    // 已停止同步播放
    if (m_decodeInFlight[slot]) return;          // 已有解码在途
    if (m_reachedEnd[slot]) return;              // 已到末尾
    if ((int)m_frameBuffer[slot].size() >= kBufferCapacity) return; // 缓冲已满

    const int target = m_nextDecodeFrame[slot];
    const int total = m_analyzers[slot]->totalFrames();
    if (target < 0 || target >= total) {
        m_reachedEnd[slot] = true;
        return;
    }

    m_decodeInFlight[slot] = true;
    m_decodeTargetFrame[slot] = target;
    const int displayMode = m_displayModes[slot];
    auto* analyzer = m_analyzers[slot].get();

    QFuture<QImage> future = QtConcurrent::run([analyzer, target, displayMode]() -> QImage {
        analyzer->lockData();
        analyzer->seekToFrameNoLock(target);
        QImage img = analyzer->getFrameImageLocked(displayMode);
        analyzer->unlockData();
        return img;
    });

    if (!m_decodeWatchers[slot]) {
        m_decodeWatchers[slot] = new QFutureWatcher<QImage>(this);
        connect(m_decodeWatchers[slot], &QFutureWatcher<QImage>::finished, this,
                [this, slot]() { onDecodeFinished(slot); });
    }
    m_decodeWatchers[slot]->setFuture(future);
}

// 某通道一帧解码完成 → 入队，并继续预填
void YuvBridge::onDecodeFinished(int slot) {
    if (slot < 0 || slot >= MaxSlots || !m_decodeWatchers[slot]) return;
    if (!m_syncTimer) return;                    // 期间已停止

    const QImage img = m_decodeWatchers[slot]->result();
    const int decoded = m_decodeTargetFrame[slot];
    m_decodeInFlight[slot] = false;

    if (!img.isNull() && decoded >= 0) {
        m_frameBuffer[slot].push_back({img, decoded});
        // 推进下一个待解码帧号
        m_nextDecodeFrame[slot] = decoded + m_syncStep;
    }

    // 继续填缓冲（未满则再解一帧）
    scheduleDecode(slot);
}

// 主时钟消费者：所有通道都有可取帧时，同时取一帧显示
void YuvBridge::onSyncTimerTick() {
    bool anyActive = false;

    // 1) 检查是否所有活跃通道都有可显示帧（或已到末尾）
    bool allHaveFrame = true;
    bool anyRunning = false;   // 还有通道没到末尾
    for (int i = 0; i < MaxSlots; ++i) {
        if (!m_analyzers[i] || !m_analyzers[i]->isOpen() || !m_playing[i]) continue;
        anyActive = true;

        if (!m_frameBuffer[i].empty()) {
            anyRunning = true;
        } else if (m_reachedEnd[i]) {
            // 该通道缓冲空且已到末尾 → 视为就绪（本轮不显示新帧）
        } else {
            // 缓冲空但还没到末尾 → 解码没跟上，本 tick 等待
            allHaveFrame = false;
        }
    }

    if (!anyActive) { stopSyncPlay(); return; }

    // 所有仍在播放的通道都到末尾且缓冲空 → 播放结束
    if (!anyRunning) {
        for (int i = 0; i < MaxSlots; ++i) {
            if (m_analyzers[i] && m_analyzers[i]->isOpen() && m_playing[i]) {
                m_playing[i] = false;
                m_reversing[i] = false;
                emit playStateChanged(i);
            }
        }
        stopSyncPlay();
        return;
    }

    // 解码没跟上（有通道缓冲空但未到末尾）→ 本 tick 不推进，避免失步
    if (!allHaveFrame) return;

    // 只消费同一帧号：某路若因丢帧/预取错位领先或落后，先丢掉落后帧再对齐。
    int want = -1;
    for (int i = 0; i < MaxSlots; ++i) {
        if (!m_analyzers[i] || !m_analyzers[i]->isOpen() || !m_playing[i]) continue;
        if (m_frameBuffer[i].empty()) continue;
        want = std::max(want, m_frameBuffer[i].front().frameNum);
    }
    if (want < 0) return;
    bool aligned = true;
    for (int i = 0; i < MaxSlots; ++i) {
        if (!m_analyzers[i] || !m_analyzers[i]->isOpen() || !m_playing[i]) continue;
        while (!m_frameBuffer[i].empty() && m_frameBuffer[i].front().frameNum < want) {
            m_frameBuffer[i].pop_front();
            scheduleDecode(i);
        }
        if (m_frameBuffer[i].empty()) {
            if (!m_reachedEnd[i]) aligned = false;
        } else if (m_frameBuffer[i].front().frameNum != want) {
            aligned = false;
        }
    }
    if (!aligned) return;

    // 2) 同时从各通道队列取一帧显示（消费者），并触发继续解码
    for (int i = 0; i < MaxSlots; ++i) {
        if (!m_analyzers[i] || !m_analyzers[i]->isOpen() || !m_playing[i]) continue;
        if (m_frameBuffer[i].empty()) continue;  // 已到末尾的通道保持最后一帧

        const DecodedFrame df = m_frameBuffer[i].front();
        m_frameBuffer[i].pop_front();

        // 更新显示帧号：加锁同步 m_currentFrame（不读盘，图像已在 df.image）。
        // m_currentFrame 是唯一权威帧号源，与快进/快退共用，杜绝双帧号错位。
        m_analyzers[i]->lockData();
        m_analyzers[i]->setCurrentFrameNoLock(df.frameNum);
        m_analyzers[i]->unlockData();
        m_visibleFrame[i] = df.frameNum;
        m_frameImages[i] = df.image;
        emit frameChanged(i);

        // 右侧栏展开时才异步算统计（避免拖慢）
        if (m_rightSidebarOpen) {
            computeStatsAsync(i, df.frameNum);
        }

        // 消费一帧后缓冲有空位，继续后台解码
        scheduleDecode(i);
    }

    // ── 差异检测 ──
    checkDiffDetect();
}

void YuvBridge::checkDiffDetect() {
    // 仅两路 + 开关开启 + 非忽略。重置/seek 时两路异步完成时刻不同，
    // 未对齐的显示帧或还在解码的路，不能当成“有差异”。
    if (!m_diffDetectEnabled || m_diffIgnoreOnce || activeSlotCount() != 2)
        return;
    if (!m_analyzers[0]->isOpen() || !m_analyzers[1]->isOpen())
        return;
    if (m_asyncBusy[0] || m_asyncBusy[1])
        return;
    if (m_visibleFrame[0] != m_visibleFrame[1] || m_visibleFrame[0] < 0)
        return;

    const int target = m_visibleFrame[0];
    const auto sa = snapshotSlotAt(m_analyzers[0].get(), target);
    const auto sb = snapshotSlotAt(m_analyzers[1].get(), target);
    if (!sa.valid || !sb.valid) return;

    int maxAbsDiff = 0;
    const auto& pa = sa.planes[0];
    const auto& pb = sb.planes[0];
    if (!pa.data.empty() && pa.data.size() == pb.data.size() && pa.data == pb.data) {
        maxAbsDiff = 0;
    } else {
        const int w = std::min(sa.width, sb.width);
        const int h = std::min(sa.height, sb.height);
        for (int y = 0; y < h && maxAbsDiff < 1; ++y) {
            for (int x = 0; x < w; ++x) {
                const int d = std::abs(sampleSnap(sa, 0, x, y) - sampleSnap(sb, 0, x, y));
                if (d > maxAbsDiff) maxAbsDiff = d;
                if (maxAbsDiff >= 1) break;
            }
        }
    }
    if (maxAbsDiff < 1)
        return;

    if (m_syncTimer) m_syncTimer->stop();
    for (int i = 0; i < MaxSlots; ++i) m_playing[i] = false;
    emit diffDetected(target, maxAbsDiff);
}

void YuvBridge::globalPlay() {
    const int n = activeSlotCount();
    if (n <= 1) {
        // 单通道：走 per-slot timer
        for (int i = 0; i < MaxSlots; ++i) {
            if (m_analyzers[i] && m_analyzers[i]->isOpen()) play(i);
        }
    } else {
        startSyncPlay(false);
    }
}

void YuvBridge::globalPlayReverse() {
    const int n = activeSlotCount();
    if (n <= 1) {
        for (int i = 0; i < MaxSlots; ++i) {
            if (m_analyzers[i] && m_analyzers[i]->isOpen()) playReverse(i);
        }
    } else {
        startSyncPlay(true);
    }
}

void YuvBridge::globalPause() {
    stopSyncPlay();
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_playing[i])
            pause(i);
    }
}

void YuvBridge::globalTogglePlayPause() {
    // 检查是否任一通道正在播放
    bool anyPlaying = false;
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_playing[i]) { anyPlaying = true; break; }
    }
    if (anyPlaying) {
        globalPause();
    } else {
        globalPlay();
    }
}

void YuvBridge::globalToggleReverse() {
    // 检查是否任一通道正在倒放
    bool anyReversing = false;
    for (int i = 0; i < MaxSlots; ++i) {
        if (m_reversing[i]) { anyReversing = true; break; }
    }
    if (anyReversing) {
        globalPause();
        globalPlay();
    } else {
        globalPause();
        globalPlayReverse();
    }
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
    const int cur = currentFrame(slot);
    const int total = m_analyzers[slot]->totalFrames();
    const int target = qMin(cur + frames, total - 1);
    refreshFrameImageAsyncToFrame(slot, target);
}

void YuvBridge::skipBackward(int slot, int frames) {
    if (slot < 0 || slot >= MaxSlots) return;
    if (!m_analyzers[slot] || !m_analyzers[slot]->isOpen()) return;
    const int cur = currentFrame(slot);
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
