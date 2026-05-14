// Updater.h — PlayerX 应用自动更新器（macOS 优先 / Windows 后续接入）
//
// 设计要点：
//   1. 远端清单：HTTPS GET `latest.json`，对比版本号 → 决定是否提示更新
//   2. 客户端：QNetworkAccessManager 异步拉取，UI 全程通过 QML 属性/信号驱动
//   3. macOS 流程：
//        下载 .zip → SHA256（可选）→ 解压到临时目录 →
//        写一个 relaunch.sh：等父进程退出 → 去 quarantine → 替换 .app → open
//   4. Windows 流程：第一阶段仅暴露接口，正式实现见后续 PR
//
// 版本比对规则：语义化版本（major.minor.patch），逐段数值比较
//   "2.0.10" > "2.0.9"，"2.1.0" > "2.0.99"
//
// 暴露给 QML 的对象名：`Updater`（main.cpp 中以 contextProperty 注入）

#pragma once

#include <QObject>
#include <QString>
#include <QUrl>
#include <QPointer>
#include <QElapsedTimer>

class QNetworkAccessManager;
class QNetworkReply;
class QFile;

namespace rbqt {

class Updater : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString currentVersion READ currentVersion CONSTANT)
    Q_PROPERTY(QString latestVersion  READ latestVersion  NOTIFY infoChanged)
    Q_PROPERTY(QString releaseNotes   READ releaseNotes   NOTIFY infoChanged)
    Q_PROPERTY(bool    updateAvailable READ updateAvailable NOTIFY infoChanged)
    Q_PROPERTY(bool    mandatory      READ mandatory      NOTIFY infoChanged)
    Q_PROPERTY(QString state          READ state          NOTIFY stateChanged)
    Q_PROPERTY(qreal   progress       READ progress       NOTIFY progressChanged)
    Q_PROPERTY(QString progressText   READ progressText   NOTIFY progressChanged)
    Q_PROPERTY(QString errorText      READ errorText      NOTIFY stateChanged)
    Q_PROPERTY(QString manifestUrl    READ manifestUrl    WRITE setManifestUrl NOTIFY manifestUrlChanged)

public:
    explicit Updater(QObject* parent = nullptr);
    ~Updater() override;

    // 远端 latest.json 的 URL（默认值在构造里给出，可被 QML 修改）
    QString manifestUrl() const { return m_manifestUrl.toString(); }
    void    setManifestUrl(const QString& u);

    QString currentVersion() const { return m_currentVersion; }
    QString latestVersion()  const { return m_latestVersion; }
    QString releaseNotes()   const { return m_releaseNotes; }
    bool    updateAvailable() const;
    bool    mandatory()      const { return m_mandatory; }
    QString state()          const { return m_state; }
    qreal   progress()       const { return m_progress; }
    QString progressText()   const { return m_progressText; }
    QString errorText()      const { return m_errorText; }

public slots:
    // 1) 启动后或菜单触发：检查更新（不下载，仅比对版本）
    void checkForUpdates(bool silent = false);

    // 2) 用户在弹窗里点"立即更新"：下载 + 校验 + 准备替换
    void downloadAndApply();

    // 3) 用户取消下载
    void cancel();

signals:
    void manifestUrlChanged();
    void infoChanged();          // 拉到清单后触发（latestVersion / notes 等更新）
    void stateChanged();         // state / errorText 变化
    void progressChanged();      // 下载进度
    void readyToInstall();       // 下载完成、即将切到外部脚本/进程
    void checkFailed(QString reason);   // 检查阶段失败（QML 可选弹 toast）

private slots:
    void onManifestFinished();
    void onDownloadProgress(qint64 received, qint64 total);
    void onDownloadFinished();

private:
    void   setState(const QString& s, const QString& err = QString());
    void   parseManifest(const QByteArray& body);
    static int compareVersion(const QString& a, const QString& b); // a<b: -1; a==b: 0; a>b: 1
    QString platformKey() const;   // "mac-arm64" / "mac-x64" / "win-install" / "win-portable"

    // macOS：解压 + 替换 + relaunch
    void applyMacOS(const QString& downloadedZip);

    // Windows：占位，后续实现（NSIS Setup /S 静默安装）
    void applyWindows(const QString& /*setupExe*/);

    QString cacheDir() const;       // 下载缓存目录

private:
    QNetworkAccessManager* m_net = nullptr;
    QPointer<QNetworkReply> m_reply;          // 当前 in-flight reply
    QFile*                  m_dlFile = nullptr;

    QUrl    m_manifestUrl;
    QString m_currentVersion;
    QString m_latestVersion;
    QString m_minSupported;
    QString m_releaseNotes;
    bool    m_mandatory = false;
    bool    m_silentCheck = false;

    // 平台对应的下载条目
    QString m_pkgUrl;
    QString m_pkgSha256;

    // 状态机：idle / checking / available / downloading / verifying / ready / error
    QString m_state = QStringLiteral("idle");
    QString m_errorText;

    // 下载进度
    qreal   m_progress = 0.0;
    QString m_progressText;
    QElapsedTimer m_dlTimer;
    qint64  m_lastReceived = 0;
    qint64  m_lastTickMs   = 0;
    qreal   m_speedBps     = 0.0;   // 平滑后速率
};

} // namespace rbqt
