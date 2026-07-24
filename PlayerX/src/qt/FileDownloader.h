#pragma once

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QFile>

namespace rbqt {

/**
 * FileDownloader — 异步文件下载器，暴露给 QML 使用（contextProperty "Downloader"）
 *
 * 用法（QML）：
 *   Downloader.download(url, savePath)
 *   Downloader.onProgress → progress(qreal ratio, qint64 received, qint64 total)
 *   Downloader.onFinished → finished(bool ok, string savePath, string errorMsg)
 *   Downloader.cancel()
 */
class FileDownloader : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool downloading READ isDownloading NOTIFY downloadingChanged)

public:
    explicit FileDownloader(QObject* parent = nullptr);
    ~FileDownloader() override;

    bool isDownloading() const { return m_reply != nullptr; }

    // 开始下载 url 到 savePath（覆盖式）。若已有下载在进行，先取消旧的。
    Q_INVOKABLE void download(const QString& url, const QString& savePath);

    // 取消当前下载（若有）。
    Q_INVOKABLE void cancel();

signals:
    // ratio: 0.0~1.0；total=-1 表示服务端未返回 Content-Length
    void progress(qreal ratio, qint64 received, qint64 total);
    // ok=true 表示成功，savePath 为写入路径；ok=false 时 errorMsg 有描述
    void finished(bool ok, const QString& savePath, const QString& errorMsg);
    void downloadingChanged();

private slots:
    void onReadyRead();
    void onDownloadProgress(qint64 received, qint64 total);
    void onReplyFinished();

private:
    void cleanup();

    QNetworkAccessManager* m_nam  = nullptr;
    QNetworkReply*         m_reply = nullptr;
    QFile*                 m_file  = nullptr;
    QString                m_savePath;
};

} // namespace rbqt
