/**
 * FsUtils.cpp — 见 FsUtils.h
 */
#include "FsUtils.h"

#include <QCollator>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QSet>
#include <QStandardPaths>
#include <QStringList>
#include <QTextStream>
#include <QUrl>

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
    // 自然序排序：让 "1.mp4 < 2.mp4 < 10.mp4"，而不是字典序的 "1 < 10 < 2"。
    // 与 macOS Finder / Windows Explorer 行为一致，避免用户预览到的顺序
    // 与图集/帧号顺序错位。注意：路径里只有最后一级文件名才是用户感知的，
    // 但 QCollator 直接比整条路径也是稳定的（同目录下前缀相同，比较只发生
    // 在文件名段；跨目录下父目录段优先决定顺序，仍然合理）。
    QCollator coll;
    coll.setNumericMode(true);
    coll.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(out.begin(), out.end(),
              [&coll](const QString& a, const QString& b) {
                  return coll.compare(a, b) < 0;
              });
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

// ── 应用级 cache 目录 + 通用文本读写 ─────────────────────────────

QString FsUtils::appCacheDir() const {
    // QStandardPaths::CacheLocation 已自带应用名后缀（依赖
    // QCoreApplication::applicationName/organizationName，在 main.cpp 已设置）。
    //   macOS:   ~/Library/Caches/PlayerX
    //   Windows: %LOCALAPPDATA%/PlayerX/cache
    //   Linux:   ~/.cache/PlayerX
    QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    if (dir.isEmpty()) {
        // 极端兜底：落到家目录下 .playerx_cache
        dir = QDir::homePath() + "/.playerx_cache";
    }
    QDir d(dir);
    if (!d.exists()) d.mkpath(".");
    // 规范化：去尾部斜杠
    while (dir.endsWith('/') || dir.endsWith('\\')) dir.chop(1);
    return dir;
}

bool FsUtils::writeTextFile(const QString& filePath, const QString& text) const {
    if (filePath.isEmpty()) return false;
    QFileInfo fi(filePath);
    QDir parent = fi.absoluteDir();
    if (!parent.exists()) {
        if (!parent.mkpath(".")) return false;
    }
    QFile f(filePath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    const QByteArray bytes = text.toUtf8();
    qint64 n = f.write(bytes);
    f.close();
    return n == bytes.size();
}

QString FsUtils::readTextFile(const QString& filePath) const {
    if (filePath.isEmpty()) return {};
    QFile f(filePath);
    if (!f.exists()) return {};
    if (!f.open(QIODevice::ReadOnly)) return {};
    const QByteArray bytes = f.readAll();
    f.close();
    return QString::fromUtf8(bytes);
}

bool FsUtils::fileExists(const QString& filePath) const {
    if (filePath.isEmpty()) return false;
    return QFileInfo::exists(filePath);
}

// ── 日志目录 + 文件管理器揭示 ────────────────────────────────

QString FsUtils::appLogDir() const {
    // 落在 cache 目录下的 logs 子目录：用户感知一致、清理方便、跨平台规范。
    QString dir = appCacheDir() + "/logs";
    QDir d(dir);
    if (!d.exists()) d.mkpath(".");
    return dir;
}

bool FsUtils::revealInFileManager(const QString& path) const {
    if (path.isEmpty()) return false;
    QFileInfo fi(path);
    // 不存在则尝试打开父目录（兜底，避免点完按钮无反应）
    if (!fi.exists()) {
        QFileInfo parent(fi.absolutePath());
        if (!parent.exists()) return false;
#if defined(Q_OS_MACOS)
        QProcess::startDetached("open", { parent.absoluteFilePath() });
#elif defined(Q_OS_WIN)
        QProcess::startDetached("explorer", { QDir::toNativeSeparators(parent.absoluteFilePath()) });
#else
        QDesktopServices::openUrl(QUrl::fromLocalFile(parent.absoluteFilePath()));
#endif
        return true;
    }

#if defined(Q_OS_MACOS)
    // Finder reveal：选中目标项
    if (fi.isDir()) {
        QProcess::startDetached("open", { fi.absoluteFilePath() });
    } else {
        QProcess::startDetached("open", { "-R", fi.absoluteFilePath() });
    }
    return true;
#elif defined(Q_OS_WIN)
    // explorer /select, "C:\path\to\file"  必须用反斜杠
    if (fi.isDir()) {
        QProcess::startDetached("explorer", { QDir::toNativeSeparators(fi.absoluteFilePath()) });
    } else {
        QStringList args;
        args << QString("/select,") + QDir::toNativeSeparators(fi.absoluteFilePath());
        QProcess::startDetached("explorer", args);
    }
    return true;
#else
    // Linux：尝试 xdg-open 父目录（多数 DE 不支持 select）
    if (fi.isDir()) {
        QDesktopServices::openUrl(QUrl::fromLocalFile(fi.absoluteFilePath()));
    } else {
        QDesktopServices::openUrl(QUrl::fromLocalFile(fi.absolutePath()));
    }
    return true;
#endif
}

} // namespace rbqt
