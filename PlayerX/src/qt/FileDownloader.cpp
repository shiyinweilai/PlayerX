#include "FileDownloader.h"

#include <QDir>
#include <QFileInfo>
#include <QNetworkRequest>
#include <QSslConfiguration>

namespace rbqt {

FileDownloader::FileDownloader(QObject* parent)
    : QObject(parent)
    , m_nam(new QNetworkAccessManager(this))
{}

FileDownloader::~FileDownloader() {
    cleanup();
}

void FileDownloader::download(const QString& url, const QString& savePath) {
    // 若已有下载，先取消
    if (m_reply) cancel();

    m_savePath = savePath;

    // 确保父目录存在
    QFileInfo fi(savePath);
    QDir dir = fi.absoluteDir();
    if (!dir.exists()) dir.mkpath(".");

    // 打开目标文件
    m_file = new QFile(savePath, this);
    if (!m_file->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        QString err = QString("无法创建文件：%1").arg(savePath);
        delete m_file; m_file = nullptr;
        emit finished(false, savePath, err);
        return;
    }

    QUrl qurl(url);
    QNetworkRequest req(qurl);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    // 允许 HTTPS
    QSslConfiguration ssl = QSslConfiguration::defaultConfiguration();
    req.setSslConfiguration(ssl);

    m_reply = m_nam->get(req);
    connect(m_reply, &QNetworkReply::readyRead,        this, &FileDownloader::onReadyRead);
    connect(m_reply, &QNetworkReply::downloadProgress, this, &FileDownloader::onDownloadProgress);
    connect(m_reply, &QNetworkReply::finished,         this, &FileDownloader::onReplyFinished);

    emit downloadingChanged();
}

void FileDownloader::cancel() {
    if (m_reply) {
        m_reply->abort();
        // onReplyFinished 会被触发，cleanup 在那里做
    }
}

void FileDownloader::onReadyRead() {
    if (m_file && m_reply)
        m_file->write(m_reply->readAll());
}

void FileDownloader::onDownloadProgress(qint64 received, qint64 total) {
    qreal ratio = (total > 0) ? (qreal(received) / qreal(total)) : -1.0;
    emit progress(ratio, received, total);
}

void FileDownloader::onReplyFinished() {
    if (!m_reply) return;

    // 把剩余数据写完
    if (m_file && m_reply->bytesAvailable() > 0)
        m_file->write(m_reply->readAll());

    bool aborted = (m_reply->error() == QNetworkReply::OperationCanceledError);
    bool ok      = !aborted && (m_reply->error() == QNetworkReply::NoError);
    QString errMsg;
    if (!ok && !aborted)
        errMsg = m_reply->errorString();

    QString savePath = m_savePath;
    cleanup();

    if (aborted) {
        // 取消时删除不完整文件
        QFile::remove(savePath);
        emit finished(false, savePath, "已取消");
    } else {
        emit finished(ok, savePath, errMsg);
    }
}

void FileDownloader::cleanup() {
    if (m_reply) {
        m_reply->disconnect(this);
        m_reply->deleteLater();
        m_reply = nullptr;
    }
    if (m_file) {
        m_file->close();
        m_file->deleteLater();
        m_file = nullptr;
    }
    emit downloadingChanged();
}

} // namespace rbqt
