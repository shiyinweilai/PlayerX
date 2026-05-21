/**
 * EngineBridge.cpp — RBPlayerEngine 的 Qt/QML 包装实现
 */

#include "EngineBridge.h"
#include "../player/rb_player_engine.h"
#include "../player/rb_video_player.h"

#include <QFileInfo>
#include <QUrl>
#include <QVariantMap>
#include <algorithm>

namespace rbqt {

EngineBridge::EngineBridge(QObject* parent)
    : QObject(parent)
    , m_engine(std::make_unique<rb::RBPlayerEngine>())
{
    // ~60Hz tick：推进主时钟 + 通知所有 provider 重绘
    m_timer.setInterval(16);
    connect(&m_timer, &QTimer::timeout, this, &EngineBridge::onTick);
    m_timer.start();
}

EngineBridge::~EngineBridge() {
    m_timer.stop();
}

rb::RBVideoPlayer* EngineBridge::playerAt(int idx) const {
    if (!m_engine) return nullptr;
    return m_engine->rbAt(idx);
}

std::shared_ptr<rb::RBVideoPlayer> EngineBridge::playerAtShared(int idx) const {
    if (!m_engine) return nullptr;
    return m_engine->rbAtShared(idx);
}

int EngineBridge::fileCount() const {
    return m_engine ? m_engine->rbCount() : 0;
}

QStringList EngineBridge::titles() const {
    QStringList out;
    if (!m_engine) return out;
    int n = m_engine->rbCount();
    for (int i = 0; i < n; ++i) {
        out << QFileInfo(QString::fromStdString(m_engine->rbPathAt(i))).fileName();
    }
    return out;
}

void EngineBridge::setActiveIndex(int v) {
    int maxIdx = std::max(0, fileCount() - 1);
    v = std::clamp(v, 0, maxIdx);
    if (v != m_activeIndex) {
        m_activeIndex = v;
        emit activeIndexChanged();
    }
}

void EngineBridge::setLayoutMode(int v) {
    if (v != m_layoutMode) {
        m_layoutMode = v;
        emit layoutModeChanged();
    }
}

// ════════════════════════════════════════════════════════════════════════
// 文件管理
// ════════════════════════════════════════════════════════════════════════

bool EngineBridge::openFiles(const QList<QUrl>& urls) {
    fprintf(stderr, "[EB-OPEN] entry: urls.size=%d\n", (int)urls.size());
    std::vector<std::string> files;
    files.reserve(urls.size());
    for (const auto& u : urls) {
        QString p = u.isLocalFile() ? u.toLocalFile() : u.toString();
        if (!p.isEmpty()) files.push_back(p.toStdString());
    }
    bool ok = m_engine->rbOpenFiles(files);
    setActiveIndex(0);

    // 立即触发一次状态广播
    emit fileCountChanged();
    emit filesChanged();
    emit positionChanged();
    emit durationChanged();
    emit playingChanged();
    emit requestRepaint();

    // 暂停态下让首帧立刻可见
    int n = m_engine->rbCount();
    for (int i = 0; i < n; ++i) {
        // ₠️ 用 shared_ptr 保活：汤中 openFiles 本身不会被其它线程调用 closeAll，
        // 但为了统一防御风格，这里同样走 shared_ptr 路径。
        if (auto sp = m_engine->rbAtShared(i)) sp->rbRefreshPausedFrame(200);
    }
    return ok;
}

bool EngineBridge::addFile(const QUrl& url) {
    QString p = url.isLocalFile() ? url.toLocalFile() : url.toString();
    if (p.isEmpty()) return false;
    int idx = m_engine->rbAddFile(p.toStdString());
    if (idx < 0) return false;

    emit fileCountChanged();
    emit filesChanged();
    emit requestRepaint();
    if (auto sp = m_engine->rbAtShared(idx)) sp->rbRefreshPausedFrame(200);
    return true;
}

bool EngineBridge::replaceAt(int idx, const QUrl& url) {
    fprintf(stderr, "[EB-REPLACEAT] entry: idx=%d\n", idx);
    QString p = url.isLocalFile() ? url.toLocalFile() : url.toString();
    if (p.isEmpty()) return false;
    if (!m_engine->rbReplaceAt(idx, p.toStdString())) return false;

    // 索引数量不变，但文件名/时长/位置都变了 → 通知 QML 刷新文件名条与悬浮控制条。
    emit filesChanged();
    emit positionChanged();
    emit durationChanged();
    emit playingChanged();
    emit requestRepaint();
    // 暂停态下让首帧立刻可见，避免画面残留为旧帧
    if (auto sp = m_engine->rbAtShared(idx)) sp->rbRefreshPausedFrame(200);
    return true;
}

void EngineBridge::closeAt(int idx) {
    int n = fileCount();
    if (idx < 0 || idx >= n) return;
    m_engine->rbCloseAt(idx);
    if (m_activeIndex >= fileCount()) {
        setActiveIndex(std::max(0, fileCount() - 1));
    }
    emit fileCountChanged();
    emit filesChanged();
    emit positionChanged();
    emit durationChanged();
    emit playingChanged();
    emit requestRepaint();
}

void EngineBridge::closeAll() {
    fprintf(stderr, "[EB-CLOSEALL] entry\n");
    m_engine->rbCloseAll();
    setActiveIndex(0);
    emit fileCountChanged();
    emit filesChanged();
    emit positionChanged();
    emit durationChanged();
    emit playingChanged();
    emit requestRepaint();
}

// ════════════════════════════════════════════════════════════════════════
// 全局控制
// ════════════════════════════════════════════════════════════════════════

void EngineBridge::play()        {
    if (!m_engine) return;
    m_engine->rbPlay();
    // rbPlay 内部检测到全部 Ended 时会自动把主时钟锚点复位到 0；这里立刻
    // 同步 m_lastPosition 并广播 position/playing，让 QML 顶部进度条 + 单路
    // cellSlider 立刻从末尾回退到 0，否则要等 onTick 才能感知到。
    double pos = m_engine->rbPosition();
    if (std::abs(pos - m_lastPosition) > 1e-6) m_lastPosition = pos;
    emit positionChanged();
    emit playingChanged();
    emit requestRepaint();
}
void EngineBridge::pause()       {
    if (!m_engine) return;
    m_engine->rbPause();
    emit playingChanged();
    emit requestRepaint();
}
void EngineBridge::togglePause() {
    if (!m_engine) return;
    m_engine->rbTogglePause();
    // 末尾态点击 ▶ 时引擎走 replay 分支，主时钟锚点被复位到 0，立刻广播
    // position/playing 让 QML 进度条从末尾回退到 0；非末尾态广播也无副作用。
    double pos = m_engine->rbPosition();
    if (std::abs(pos - m_lastPosition) > 1e-6) m_lastPosition = pos;
    emit positionChanged();
    emit playingChanged();
    emit requestRepaint();
}

// seek/stepFrame 之后必须立刻同步 m_lastPosition 并 emit positionChanged，
// 否则：① 暂停态下 onTick 里主时钟不推进，rbPosition() 与 m_lastPosition 差值
// 检测不到变化，顶部进度条/时间标签完全不动；② 即便能检测到，也要等到下一次
// 16ms tick 才更新，存在视觉滞后。这里同步刷新即可与单路滑块一致地立刻贴到新位置。
void EngineBridge::seek(double s){
    if (!m_engine) return;
    m_engine->rbSeek(s);
    double pos = m_engine->rbPosition();
    if (std::abs(pos - m_lastPosition) > 1e-6) {
        m_lastPosition = pos;
        emit positionChanged();
    } else {
        // 即便引擎层报告位置未变（个别极端边界），也强制让 QML 端重新求值，
        // 单路 cellSlider 绑定 positionAt(idx)，依赖 positionChanged 触发重算。
        emit positionChanged();
    }
    emit requestRepaint();
}
void EngineBridge::seekRelative(double delta) {
    if (!m_engine) return;
    m_engine->rbSeekRelative(delta);
    // 与 seek() 一致：立刻同步 m_lastPosition 并广播 positionChanged，
    // 让顶部进度条 + 单路 cellSlider（绑定 positionAt(idx)）立刻贴到新位置。
    double pos = m_engine->rbPosition();
    if (std::abs(pos - m_lastPosition) > 1e-6) m_lastPosition = pos;
    emit positionChanged();
    emit requestRepaint();
}
void EngineBridge::stepFrame(int n) {
    if (!m_engine) return;
    m_engine->rbStepFrame(n);
    double pos = m_engine->rbPosition();
    m_lastPosition = pos;
    // 帧步进后全局一定是暂停态，需要同步状态让 QML 播放按钮
    // 图标切回 ▶（togglePause 之外的路径不会自动 emit playingChanged）。
    bool pl = m_engine->rbIsPlaying();
    if (pl != m_lastPlaying) {
        m_lastPlaying = pl;
        emit playingChanged();
    }
    emit positionChanged();
    emit requestRepaint();
}

// 倍速控制
void EngineBridge::adjustSpeed(int delta) {
    if (!m_engine) return;
    m_engine->rbAdjustSpeedLevel(delta);
    double s = m_engine->rbSpeed();
    if (std::abs(s - m_lastSpeed) > 1e-9) {
        m_lastSpeed = s;
        emit speedChanged();
    }
}
void EngineBridge::resetSpeed() {
    if (!m_engine) return;
    m_engine->rbResetSpeed();
    double s = m_engine->rbSpeed();
    if (std::abs(s - m_lastSpeed) > 1e-9) {
        m_lastSpeed = s;
        emit speedChanged();
    }
}

void EngineBridge::setSpeed(double speed) {
    if (!m_engine) return;
    // 保护性裁剪：与引擎内部级别范围 ±42 级近似对齐（1/128 ~ 128）。
    if (!(speed > 0.0)) return;
    if (speed < 1.0/128.0) speed = 1.0/128.0;
    if (speed > 128.0)    speed = 128.0;
    m_engine->rbSetSpeed(speed);
    double s = m_engine->rbSpeed();
    if (std::abs(s - m_lastSpeed) > 1e-9) {
        m_lastSpeed = s;
        emit speedChanged();
    }
}

// ═════════════════════════════════════════════════════════════════════
// 全局视图变换（缩放 / 平移）
// 存在 EngineBridge 中一份，所有 cell / 滑动对比视图同步读同一组状态。
// 画质策略：zoom == 1 且 pan == 0 时走原有快路径，按位不动；
// 只要任一项偏移，才走 srcRect→dstRect 采样路径（详 VideoFrameProvider::paint）。
// ═════════════════════════════════════════════════════════════════════
void EngineBridge::rbClampViewPan() {
    // pan 可活动范围：zoom 越大，允许越大的 |pan|，以保证画面不被拖出身体完全可见范围。
    // 具体使用"src 边界必须覆盖显示矩形"作为约束：
    //   srcW = areaW / zoom，src 中心偏移 pan*areaW 后，需保证 src 区间仍在 [0,areaW] 内。
    //   → |pan| <= (1 - 1/zoom) / 2。zoom<=1 时则强制 pan=0（全画面可见，无需平移）。
    if (m_viewZoom <= 1.0 + 1e-9) {
        m_viewPanX = 0.0;
        m_viewPanY = 0.0;
        return;
    }
    const double maxPan = (1.0 - 1.0 / m_viewZoom) * 0.5;
    if (m_viewPanX >  maxPan) m_viewPanX =  maxPan;
    if (m_viewPanX < -maxPan) m_viewPanX = -maxPan;
    if (m_viewPanY >  maxPan) m_viewPanY =  maxPan;
    if (m_viewPanY < -maxPan) m_viewPanY = -maxPan;
}

void EngineBridge::zoomBy(double factor, double anchorNX, double anchorNY) {
    if (!(factor > 0.0)) return;
    const double oldZoom = m_viewZoom;
    double newZoom = oldZoom * factor;
    if (newZoom < kZoomMin) newZoom = kZoomMin;
    if (newZoom > kZoomMax) newZoom = kZoomMax;
    if (std::abs(newZoom - oldZoom) < 1e-9 &&
        std::abs(m_viewPanX) < 1e-9 && std::abs(m_viewPanY) < 1e-9) {
        return;
    }
    // 以 anchor 为中心缩放：保持 anchor 在屏幕上对应的"视频内容点"不动。
    // 在归一化坐标下：
    //   src_old(anchor) = (anchor - 0.5)/oldZoom + 0.5 + panOld
    //   src_new(anchor) = (anchor - 0.5)/newZoom + 0.5 + panNew
    //   令 src_new == src_old → panNew = panOld + (anchor - 0.5)*(1/oldZoom - 1/newZoom)
    const double ax = (anchorNX - 0.5);
    const double ay = (anchorNY - 0.5);
    m_viewPanX += ax * (1.0/oldZoom - 1.0/newZoom);
    m_viewPanY += ay * (1.0/oldZoom - 1.0/newZoom);
    m_viewZoom  = newZoom;
    rbClampViewPan();
    emit viewTransformChanged();
    emit requestRepaint();
}

void EngineBridge::zoomTo(double absZoom, double anchorNX, double anchorNY) {
    if (!(absZoom > 0.0)) return;
    if (m_viewZoom <= 0.0) return;
    zoomBy(absZoom / m_viewZoom, anchorNX, anchorNY);
}

void EngineBridge::panBy(double dxN, double dyN) {
    if (m_viewZoom <= 1.0 + 1e-9) return; // 1× 下不可平移
    // 画面跟随鼠标方向：鼠标向右拖，dxN > 0 → 看到的内容向左移动一个鼠标偏移量，
    // 即 src 区间在归一化坐标上向左偏移 → pan -= d (考虑 zoom 的实际肆例)。
    m_viewPanX -= dxN / m_viewZoom;
    m_viewPanY -= dyN / m_viewZoom;
    rbClampViewPan();
    emit viewTransformChanged();
    emit requestRepaint();
}

void EngineBridge::resetViewTransform() {
    if (std::abs(m_viewZoom - 1.0) < 1e-9 &&
        std::abs(m_viewPanX) < 1e-9 &&
        std::abs(m_viewPanY) < 1e-9) {
        return;
    }
    m_viewZoom = 1.0;
    m_viewPanX = 0.0;
    m_viewPanY = 0.0;
    emit viewTransformChanged();
    emit requestRepaint();
}

// 单路
void EngineBridge::togglePauseAt(int idx) {
    if (!m_engine) return;
    m_engine->rbTogglePauseAt(idx);
    // 单路播放状态变化后必须立刻广播：
    // QML 端单路按钮文本 `cell._playing() ? "⏸" : "▶"` 依赖
    // `function _playing(){ Engine.playing; return Engine.playingAt(idx) }`，
    // 它只在 playingChanged 触发时重算。若不 emit，图标不会随单路状态切换。
    // （全局 m_playing 在多路场景下未必变化，所以 onTick 的差异检测不一定触发。）
    emit playingChanged();
    // 末尾点击 ▶ 时单路会自动 replay（rbVideoPlayer 内部 seek 回 0），该路时间
    // 从 duration 突变到 0，cellSlider 绑定 Engine.positionAt(idx) 需要
    // positionChanged 触发重算，否则该路单路进度条仍卡在末尾。
    emit positionChanged();
    emit requestRepaint();
}
void EngineBridge::seekAt(int idx, double s) {
    if (!m_engine) return;
    m_engine->rbSeekAt(idx, s);
    // 单路 seek 也可能让全局 rbPosition()（多路下通常是 active/主路）变化；
    // 即便不变，也要 emit positionChanged 触发 QML 端 positionAt(idx) 重算，
    // 这样该路的 cellSlider/time 标签能立即贴到新位置（暂停态尤其重要）。
    double pos = m_engine->rbPosition();
    if (std::abs(pos - m_lastPosition) > 1e-6) m_lastPosition = pos;
    emit positionChanged();
    emit requestRepaint();
}
void EngineBridge::stepFrameAt(int idx, int n) {
    if (!m_engine) return;
    m_engine->rbStepFrameAt(idx, n);
    double pos = m_engine->rbPosition();
    if (std::abs(pos - m_lastPosition) > 1e-6) m_lastPosition = pos;
    emit positionChanged();
    // 单路帧步进会让该路进入暂停态，但 togglePause 之外的路径不会自动
    // emit playingChanged——QML 里 cellPlayBtn.text = cell._playing() ? "⏸" : "▶"
    // 依赖 playingChanged 重算，不 emit 会导致按一下 > / < 后图标仍是 ⏸。
    emit playingChanged();
    emit requestRepaint();
}

// 工具
QString EngineBridge::fileNameAt(int idx) const {
    if (!m_engine) return {};
    if (idx < 0 || idx >= m_engine->rbCount()) return {};
    return QFileInfo(QString::fromStdString(m_engine->rbPathAt(idx))).fileName();
}
QString EngineBridge::filePathAt(int idx) const {
    if (!m_engine) return {};
    if (idx < 0 || idx >= m_engine->rbCount()) return {};
    return QString::fromStdString(m_engine->rbPathAt(idx));
}
double EngineBridge::positionAt(int idx) const {
    if (auto sp = playerAtShared(idx)) return sp->rbCurrentTime();
    return 0.0;
}
double EngineBridge::durationAt(int idx) const {
    if (auto sp = playerAtShared(idx)) return sp->rbDuration();
    return 0.0;
}
bool EngineBridge::playingAt(int idx) const {
    if (auto sp = playerAtShared(idx)) return sp->rbIsPlaying();
    return false;
}

QVariantMap EngineBridge::videoInfoAt(int idx) const {
    QVariantMap info;
    auto sp = playerAtShared(idx);
    rb::RBVideoPlayer* p = sp.get();
    if (!p) return info;
    info["codec"]      = QString::fromStdString(p->rbCodecName());
    info["decoder"]    = QString::fromStdString(p->rbDecoderName());
    info["width"]      = p->rbWidth();
    info["height"]     = p->rbHeight();
    info["fps"]        = p->rbFps();
    info["frameNum"]   = static_cast<qlonglong>(p->rbCurrentFrameNum());
    info["frameType"]  = QString(QChar(p->rbCurrentFrameType()));
    info["pts"]        = p->rbCurrentTime();
    info["pixFmt"]     = QString::fromStdString(p->rbPixelFormatName());
    info["colorSpace"] = QString::fromStdString(p->rbColorSpaceName());
    info["colorRange"] = QString::fromStdString(p->rbColorRangeName());
    info["hwAccel"]    = p->rbHwAccelActive();
    return info;
}

// ════════════════════════════════════════════════════════════════════════
// Tick
// ════════════════════════════════════════════════════════════════════════

void EngineBridge::onTick() {
    if (!m_engine) return;
    m_engine->rbTick();

    // 状态变更广播
    int    cnt = m_engine->rbCount();
    bool   pl  = m_engine->rbIsPlaying();
    double pos = m_engine->rbPosition();
    double dur = m_engine->rbDuration();

    if (cnt != m_lastFileCount) {
        m_lastFileCount = cnt;
        emit fileCountChanged();
        emit filesChanged();
    }
    if (pl != m_lastPlaying) {
        m_lastPlaying = pl;
        emit playingChanged();
    }

    // ── 任一路在独立播放（不走主时钟）也算播放中 ────────────────────────
    // 单路 ▶（rbTogglePauseAt）会让该路 enableMasterClock(false) 并独立播放，
    // 此时全局 m_playing 仍为 false，rbPosition() 返回固定 m_pausedPts，
    // 下面 |pos - m_lastPosition| 检测永远不过阈值 → positionChanged 永不
    // 触发 → 顶部进度条 + 单路 cellSlider（依赖 positionAt(idx) 重算）全部
    // 僵死。这里改为：只要有任一路实际在播放，就每帧强制 emit 让 QML 重算
    // 各 cell._pos() / Engine.position。
    bool anyPlaying = pl;
    if (!anyPlaying) {
        for (int i = 0; i < cnt; ++i) {
            // ₠️ use-after-free 防御：onTick 与 closeAll 主线程同源，本不会并发，
            // 但为了统一风格且跳过任何未来可能引入的异步销毁，走 shared_ptr。
            if (auto sp = m_engine->rbAtShared(i)) {
                if (sp->rbIsPlaying()) { anyPlaying = true; break; }
            }
        }
    }

    // 检测"任一路播放"状态的下降沿：单路独立播放走到末尾时，全局 m_playing
    // 始终为 false（pl != m_lastPlaying 不成立，不会 emit），但单路按钮的
    // cell._playing() 求值依赖 playingChanged 信号触发重算。这里在 anyPlaying
    // 由 true → false 时主动 emit 一次，让单路 ▶/⏸ 图标立刻刷新到末尾态。
    if (m_lastAnyPlaying && !anyPlaying) {
        emit playingChanged();
    }
    m_lastAnyPlaying = anyPlaying;

    // position 每帧广播给 QML（让进度条丝滑）
    bool needPosEmit = std::abs(pos - m_lastPosition) > 1e-3;
    if (needPosEmit) m_lastPosition = pos;
    // 单路独立播放场景：rbPosition() 不变，但 positionAt(idx) 在变。
    // 强制 emit 触发 QML 端 positionAt(idx) 重新求值。
    if (needPosEmit || anyPlaying) {
        emit positionChanged();
    }

    if (std::abs(dur - m_lastDuration) > 1e-3) {
        m_lastDuration = dur;
        emit durationChanged();
    }

    // 倍速同步（外部可能因 rbOpenFiles 复位为 1.0）
    double sp = m_engine->rbSpeed();
    if (std::abs(sp - m_lastSpeed) > 1e-9) {
        m_lastSpeed = sp;
        emit speedChanged();
    }

    // 通知 VideoFrameProvider 重绘
    emit requestRepaint();
}

} // namespace rbqt

