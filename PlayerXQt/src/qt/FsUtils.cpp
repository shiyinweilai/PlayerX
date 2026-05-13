/**
 * FsUtils.cpp — 见 FsUtils.h
 */
#include "FsUtils.h"

#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QSet>
#include <QStringList>

namespace rbqt {

// 视频扩展名白名单（与项目其他位置 FileDialog.nameFilters 大致对齐，并补齐常见容器）。
// 全部小写；匹配时统一转小写。
static const QStringList kVideoExts = {
    "mp4", "mov", "mkv", "avi", "webm", "flv", "ts", "m4v", "wmv",
    "mpg", "mpeg", "m2ts", "mts", "vob", "ogv", "3gp", "asf",
    // 原始码流与 YUV 序列也允许（rb_demuxer 支持）
    "h264", "h265", "hevc", "264", "265", "y4m"
};

static bool isVideoFile(const QFileInfo& fi) {
    if (!fi.isFile()) return false;
    const QString suf = fi.suffix().toLower();
    if (suf.isEmpty()) return false;
    for (const auto& e : kVideoExts) {
        if (suf == e) return true;
    }
    return false;
}

static QString urlToLocal(const QUrl& url) {
    if (url.isLocalFile()) return url.toLocalFile();
    // 兼容 QML DropArea 传入的 file:// URL 字符串
    QString s = url.toString();
    if (s.startsWith("file://")) {
        QUrl u(s);
        if (u.isLocalFile()) return u.toLocalFile();
    }
    return s;
}

QStringList FsUtils::scanVideoFolderPath(const QString& dirPath, bool recursive) const {
    QStringList out;
    if (dirPath.isEmpty()) return out;
    QFileInfo dirFi(dirPath);
    if (!dirFi.exists() || !dirFi.isDir()) return out;

    QDirIterator::IteratorFlags flags = recursive
        ? QDirIterator::Subdirectories
        : QDirIterator::NoIteratorFlags;
    QDirIterator it(dirPath,
                    QDir::Files | QDir::NoDotAndDotDot | QDir::Readable,
                    flags);

    QSet<QString> seen;  // 去重保护（极少数情况下 iterator 可能重复返回）
    while (it.hasNext()) {
        it.next();
        const QFileInfo fi = it.fileInfo();
        if (!isVideoFile(fi)) continue;
        const QString abs = fi.absoluteFilePath();
        if (seen.contains(abs)) continue;
        seen.insert(abs);
        out << abs;
    }
    out.sort(Qt::CaseInsensitive);
    return out;
}

QStringList FsUtils::scanVideoFolder(const QUrl& dir, bool recursive) const {
    return scanVideoFolderPath(urlToLocal(dir), recursive);
}

bool FsUtils::isDirectoryPath(const QString& path) const {
    if (path.isEmpty()) return false;
    QFileInfo fi(path);
    return fi.exists() && fi.isDir();
}

bool FsUtils::isDirectory(const QUrl& url) const {
    return isDirectoryPath(urlToLocal(url));
}

QList<QUrl> FsUtils::toFileUrls(const QStringList& paths) const {
    QList<QUrl> out;
    out.reserve(paths.size());
    for (const auto& p : paths) {
        if (p.isEmpty()) continue;
        out << QUrl::fromLocalFile(p);
    }
    return out;
}

QStringList FsUtils::filterByKeyword(const QStringList& paths, const QString& keyword) const {
    const QString kw = keyword.trimmed().toLower();
    if (kw.isEmpty()) return paths;
    QStringList out;
    out.reserve(paths.size());
    for (const auto& p : paths) {
        if (p.toLower().contains(kw)) out << p;
    }
    return out;
}

QString FsUtils::fileName(const QString& path) const {
    if (path.isEmpty()) return {};
    return QFileInfo(path).fileName();
}

QString FsUtils::urlToLocalFile(const QUrl& url) const {
    return urlToLocal(url);
}

} // namespace rbqt
