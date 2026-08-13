#include "YuvBridge.h"
#include "YuvAnalyzer.h"

#include <cstdio>

YuvBridge::YuvBridge(QObject* parent)
    : QObject(parent)
    , m_analyzer(std::make_unique<rb::YuvAnalyzer>()) {}

YuvBridge::~YuvBridge() = default;

// ── 文件操作 ──────────────────────────────────────────────────────────

bool YuvBridge::openFile(const QString& path, int width, int height,
                          const QString& pixFmt, double fps) {
    if (!m_analyzer->open(path, width, height, pixFmt, fps))
        return false;

    m_displayMode = 0;  // 默认全彩
    refreshFrameImage();
    emit fileOpened();
    emit displayModeChanged();
    return true;
}

void YuvBridge::closeFile() {
    m_analyzer->close();
    m_frameImage = QImage();
    emit frameChanged();
    emit fileOpened();
}

// ── 帧导航 ────────────────────────────────────────────────────────────

void YuvBridge::gotoFrame(int frameNum) {
    if (!m_analyzer->isOpen()) return;
    if (m_analyzer->seekToFrame(frameNum)) {
        refreshFrameImage();
    }
}

void YuvBridge::nextFrame() {
    if (!m_analyzer->isOpen()) return;
    m_analyzer->nextFrame();
    refreshFrameImage();
}

void YuvBridge::prevFrame() {
    if (!m_analyzer->isOpen()) return;
    m_analyzer->prevFrame();
    refreshFrameImage();
}

void YuvBridge::firstFrame() {
    gotoFrame(0);
}

void YuvBridge::lastFrame() {
    const int total = m_analyzer->totalFrames();
    if (total > 0) gotoFrame(total - 1);
}

// ── 显示模式 ──────────────────────────────────────────────────────────

void YuvBridge::setDisplayMode(int mode) {
    mode = std::clamp(mode, 0, 3);
    if (mode == m_displayMode) return;
    m_displayMode = mode;
    refreshFrameImage();
    emit displayModeChanged();
}

// ── getter ────────────────────────────────────────────────────────────

QImage  YuvBridge::frameImage()    { return m_frameImage; }
int     YuvBridge::currentFrame() const { return m_analyzer->currentFrame(); }
int     YuvBridge::totalFrames()  const { return m_analyzer->totalFrames(); }
int     YuvBridge::width()        const { return m_analyzer->width(); }
int     YuvBridge::height()       const { return m_analyzer->height(); }
QString YuvBridge::filePath()     const { return m_analyzer->filePath(); }
QString YuvBridge::fmtName()      const { return m_analyzer->pixelFormatName(); }
double  YuvBridge::fps()          const { return m_analyzer->fps(); }
bool    YuvBridge::hasFile()      const { return m_analyzer->isOpen(); }

// ── 内部 ──────────────────────────────────────────────────────────────

void YuvBridge::refreshFrameImage() {
    if (!m_analyzer->isOpen()) {
        m_frameImage = QImage();
        emit frameChanged();
        return;
    }

    switch (m_displayMode) {
        case 0: m_frameImage = m_analyzer->getFrameImage();   break; // YUV全彩
        case 1: m_frameImage = m_analyzer->getPlaneImage(0);  break; // Y 平面
        case 2: m_frameImage = m_analyzer->getPlaneImage(1);  break; // U 平面
        case 3: m_frameImage = m_analyzer->getPlaneImage(2);  break; // V 平面
        default: m_frameImage = m_analyzer->getFrameImage();  break;
    }

    emit frameChanged();
}
