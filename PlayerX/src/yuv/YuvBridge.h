#pragma once
/**
 * YuvBridge.h — YuvAnalyzer 的 Qt/QML 桥接层
 *
 * 把纯 C++ 的 YuvAnalyzer 包装为 QObject，通过属性 + Q_INVOKABLE 暴露给 QML。
 * YuvWindow.qml 通过 "YuvBridge" context property 直接调用。
 */

#include <QObject>
#include <QImage>
#include <QString>
#include <memory>

namespace rb {
class YuvAnalyzer;
}

class YuvBridge : public QObject {
    Q_OBJECT

    // ── 读属性 ───────────────────────────────────────────────────────
    Q_PROPERTY(QImage  frameImage   READ frameImage   NOTIFY frameChanged)
    Q_PROPERTY(int     currentFrame READ currentFrame NOTIFY frameChanged)
    Q_PROPERTY(int     totalFrames  READ totalFrames  NOTIFY fileOpened)
    Q_PROPERTY(int     width        READ width        NOTIFY fileOpened)
    Q_PROPERTY(int     height       READ height       NOTIFY fileOpened)
    Q_PROPERTY(QString filePath     READ filePath     NOTIFY fileOpened)
    Q_PROPERTY(QString fmtName      READ fmtName      NOTIFY fileOpened)
    Q_PROPERTY(double  fps          READ fps          NOTIFY fileOpened)
    Q_PROPERTY(bool    hasFile      READ hasFile      NOTIFY fileOpened)

    // 显示模式: 0=YUV全彩, 1=Y仅, 2=U仅, 3=V仅
    Q_PROPERTY(int     displayMode  READ displayMode  WRITE setDisplayMode
                                    NOTIFY displayModeChanged)

public:
    explicit YuvBridge(QObject* parent = nullptr);
    ~YuvBridge() override;

    // ── Q_INVOKABLE ──────────────────────────────────────────────────
    Q_INVOKABLE bool openFile(const QString& path, int width, int height,
                              const QString& pixFmt, double fps);
    Q_INVOKABLE void closeFile();
    Q_INVOKABLE void gotoFrame(int frameNum);
    Q_INVOKABLE void nextFrame();
    Q_INVOKABLE void prevFrame();
    Q_INVOKABLE void firstFrame();
    Q_INVOKABLE void lastFrame();

    // ── getter / setter ──────────────────────────────────────────────
    QImage  frameImage();
    int     currentFrame() const;
    int     totalFrames()  const;
    int     width()        const;
    int     height()       const;
    QString filePath()     const;
    QString fmtName()      const;
    double  fps()          const;
    bool    hasFile()      const;

    int     displayMode()  const { return m_displayMode; }
    void    setDisplayMode(int mode);

signals:
    void frameChanged();
    void fileOpened();
    void displayModeChanged();

private:
    void refreshFrameImage();

    std::unique_ptr<rb::YuvAnalyzer> m_analyzer;
    int    m_displayMode{0};
    QImage m_frameImage;
};
