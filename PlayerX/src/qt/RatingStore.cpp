/**
 * RatingStore.cpp — 见 RatingStore.h
 */
#include "RatingStore.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QSettings>
#include <QStandardPaths>
#include <QTextStream>
#include <QUrl>

namespace rbqt {

namespace {
constexpr const char* kCsvHeader =
    "updated_at,rater,file_name,file_path,file_size,quick_hash,stars";
constexpr const char* kSettingsUserKey = "rating/user";
}  // namespace

// ════════════════════════════════════════════════════════════════════════
// 构造：解析数据文件路径，必要时建目录与表头
// ════════════════════════════════════════════════════════════════════════

RatingStore::RatingStore(QObject* parent) : QObject(parent) {
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (base.isEmpty()) {
        base = QDir::homePath() + "/.PlayerX";
    }
    QDir().mkpath(base);
    m_dataFile = QDir(base).filePath("ratings.csv");

    // 不存在则建空文件 + 表头；存在但首行非表头不强行覆盖（用户可能手动改过）
    if (!QFileInfo::exists(m_dataFile)) {
        QFile f(m_dataFile);
        if (f.open(QIODevice::WriteOnly | QIODevice::Text)) {
            QTextStream ts(&f);
            ts.setEncoding(QStringConverter::Utf8);
            ts.setGenerateByteOrderMark(true);
            ts << kCsvHeader << "\n";
        }
    }
}

// ════════════════════════════════════════════════════════════════════════
// 评分人（QSettings 持久化）
// ════════════════════════════════════════════════════════════════════════

QString RatingStore::currentUser() const {
    QSettings s;
    QString u = s.value(kSettingsUserKey).toString().trimmed();
    return u;  // 允许返回空，QML 端可显示"未设置"提示
}

void RatingStore::setCurrentUser(const QString& name) {
    QSettings s;
    QString trimmed = name.trimmed();
    if (s.value(kSettingsUserKey).toString() == trimmed) return;
    s.setValue(kSettingsUserKey, trimmed);
    s.sync();
    emit currentUserChanged();
}

QString RatingStore::systemUserName() const {
    QString u = qEnvironmentVariable("USER");
    if (u.isEmpty()) u = qEnvironmentVariable("USERNAME");  // Windows
    if (u.isEmpty()) u = "unknown";
    return u;
}

// ════════════════════════════════════════════════════════════════════════
// 总数 / 列表
// ════════════════════════════════════════════════════════════════════════

int RatingStore::totalCount() const {
    return readAll().size();
}

QVariantList RatingStore::getAllRatings() const {
    QList<QVariantMap> rows = readAll();
    // updated_at 倒序（字符串 ISO8601 直接字典序倒序即可近似时间倒序）
    std::sort(rows.begin(), rows.end(),
              [](const QVariantMap& a, const QVariantMap& b) {
                  return a.value("updated_at").toString() > b.value("updated_at").toString();
              });
    QVariantList out;
    out.reserve(rows.size());
    for (const auto& r : rows) out << r;
    return out;
}

// ════════════════════════════════════════════════════════════════════════
// 写入一条评分（同 filePath 覆盖）
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::recordRating(const QString& filePath,
                               const QString& fileName,
                               int stars) {
    if (filePath.trimmed().isEmpty()) return false;
    if (stars < 0) stars = 0;
    if (stars > 5) stars = 5;

    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();

    QString name = fileName;
    if (name.isEmpty()) name = QFileInfo(filePath).fileName();

    QVariantMap row;
    row["updated_at"] = QDateTime::currentDateTime().toString(Qt::ISODateWithMs);
    row["rater"]      = rater;
    row["file_name"]  = name;
    row["file_path"]  = filePath;
    row["file_size"]  = fileSizeOf(filePath);
    row["quick_hash"] = quickHashOf(filePath);
    row["stars"]      = stars;

    QList<QVariantMap> rows = readAll();
    bool replaced = false;
    for (auto& r : rows) {
        // 同 file_path + 同 rater 视为同一条 → 覆盖
        // （不同评分人是不同记录，多人共用一台机也能各自留痕）
        if (r.value("file_path").toString() == filePath &&
            r.value("rater").toString() == rater) {
            r = row;
            replaced = true;
            break;
        }
    }
    if (!replaced) rows.push_back(row);

    if (!writeAll(rows)) return false;
    emit changed();
    return true;
}

// ════════════════════════════════════════════════════════════════════════
// 导出到任意路径
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::exportToFile(const QString& targetPath) const {
    if (targetPath.trimmed().isEmpty()) return false;
    QFile src(m_dataFile);
    if (!src.exists()) return false;
    QFile dst(targetPath);
    QFileInfo(targetPath).absoluteDir().mkpath(".");
    if (!dst.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    if (!src.open(QIODevice::ReadOnly)) return false;
    dst.write(src.readAll());
    return true;
}

// ════════════════════════════════════════════════════════════════════════
// 清空（仅保留表头）
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::clearAll() {
    QFile f(m_dataFile);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return false;
    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);
    ts.setGenerateByteOrderMark(true);
    ts << kCsvHeader << "\n";
    f.close();
    emit changed();
    return true;
}

// ════════════════════════════════════════════════════════════════════════
// 在系统文件管理器中定位
// ════════════════════════════════════════════════════════════════════════

void RatingStore::revealInFolder() const {
    QFileInfo fi(m_dataFile);
#ifdef Q_OS_MAC
    QStringList args;
    args << "-e" << QString("tell application \"Finder\" to reveal POSIX file \"%1\"")
                        .arg(fi.absoluteFilePath());
    QProcess::execute("/usr/bin/osascript", args);
    QProcess::execute("/usr/bin/osascript",
                      {"-e", "tell application \"Finder\" to activate"});
#elif defined(Q_OS_WIN)
    QStringList args;
    args << "/select," << QDir::toNativeSeparators(fi.absoluteFilePath());
    QProcess::startDetached("explorer.exe", args);
#else
    QDesktopServices::openUrl(QUrl::fromLocalFile(fi.absolutePath()));
#endif
}

// ════════════════════════════════════════════════════════════════════════
// 内部：CSV I/O
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::writeAll(const QList<QVariantMap>& rows) const {
    QFile f(m_dataFile);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return false;
    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);
    ts.setGenerateByteOrderMark(true);
    ts << kCsvHeader << "\n";
    for (const auto& r : rows) {
        ts << csvEscape(r.value("updated_at").toString()) << ","
           << csvEscape(r.value("rater").toString())      << ","
           << csvEscape(r.value("file_name").toString())  << ","
           << csvEscape(r.value("file_path").toString())  << ","
           << r.value("file_size").toLongLong()           << ","
           << csvEscape(r.value("quick_hash").toString()) << ","
           << r.value("stars").toInt()                    << "\n";
    }
    return true;
}

QList<QVariantMap> RatingStore::readAll() const {
    QList<QVariantMap> out;
    QFile f(m_dataFile);
    if (!f.exists()) return out;
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return out;
    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);
    bool firstLine = true;
    while (!ts.atEnd()) {
        QString line = ts.readLine();
        if (firstLine) { firstLine = false; continue; }   // 跳过表头
        if (line.trimmed().isEmpty()) continue;
        QStringList cols = parseCsvLine(line);
        if (cols.size() < 7) continue;  // 容错：列不足直接丢弃
        QVariantMap row;
        row["updated_at"] = cols.value(0);
        row["rater"]      = cols.value(1);
        row["file_name"]  = cols.value(2);
        row["file_path"]  = cols.value(3);
        row["file_size"]  = cols.value(4).toLongLong();
        row["quick_hash"] = cols.value(5);
        row["stars"]      = cols.value(6).toInt();
        out.push_back(row);
    }
    return out;
}

// ════════════════════════════════════════════════════════════════════════
// 内部：CSV 转义/解析（极简，但够用：处理 , " \n ）
// ════════════════════════════════════════════════════════════════════════

QString RatingStore::csvEscape(const QString& s) {
    bool needsQuote = s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r');
    if (!needsQuote) return s;
    QString t = s;
    t.replace("\"", "\"\"");
    return "\"" + t + "\"";
}

QStringList RatingStore::parseCsvLine(const QString& line) {
    QStringList out;
    QString cur;
    bool inQuote = false;
    for (int i = 0; i < line.size(); ++i) {
        QChar c = line.at(i);
        if (inQuote) {
            if (c == '"') {
                if (i + 1 < line.size() && line.at(i + 1) == '"') {
                    cur.append('"');
                    ++i;
                } else {
                    inQuote = false;
                }
            } else {
                cur.append(c);
            }
        } else {
            if (c == ',') {
                out << cur;
                cur.clear();
            } else if (c == '"') {
                inQuote = true;
            } else {
                cur.append(c);
            }
        }
    }
    out << cur;
    return out;
}

// ════════════════════════════════════════════════════════════════════════
// 内部：文件指纹（不阻塞 UI，几 MB 级别可接受）
// ════════════════════════════════════════════════════════════════════════

qint64 RatingStore::fileSizeOf(const QString& path) {
    QFileInfo fi(path);
    if (!fi.exists() || !fi.isFile()) return 0;
    return fi.size();
}

QString RatingStore::quickHashOf(const QString& path) {
    QFileInfo fi(path);
    if (!fi.exists() || !fi.isFile()) return {};
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};

    constexpr qint64 kChunk = 1 * 1024 * 1024;  // 头/尾各 1MB
    qint64 size = f.size();
    QCryptographicHash hash(QCryptographicHash::Sha1);

    QByteArray head = f.read(qMin(size, kChunk));
    hash.addData(head);

    if (size > kChunk * 2) {
        f.seek(size - kChunk);
        QByteArray tail = f.read(kChunk);
        hash.addData(tail);
    }

    QByteArray sizeBytes = QByteArray::number(size);
    hash.addData(sizeBytes);

    return QString::fromLatin1(hash.result().toHex().left(16));
}

}  // namespace rbqt
