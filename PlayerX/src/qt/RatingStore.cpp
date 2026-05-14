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

// 返回导出 CSV 时 FileDialog 默认落脚的目录：系统下载文件夹（~/Downloads）。
// 如果 QStandardPaths 拿不到（极端定制环境）则退到家目录，避免 Qt 默认落到文件系统根。
QUrl RatingStore::defaultExportDir() const {
    QString dir = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    if (dir.isEmpty())
        dir = QStandardPaths::writableLocation(QStandardPaths::HomeLocation);
    if (dir.isEmpty())
        dir = QDir::homePath();
    return QUrl::fromLocalFile(dir);
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
                               int stars,
                               int channelIndex) {
    if (filePath.trimmed().isEmpty()) return false;
    if (stars < 0) stars = 0;
    if (stars > 5) stars = 5;

    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();

    QString name = fileName;
    if (name.isEmpty()) name = QFileInfo(filePath).fileName();
    // 多路场景下提供了宏格索引：在 file_name 前面拼接通道号（1-based）。
    // 仅仅作用于当前评分仅要写入 CSV 的这一行记录，不会反向传出去影响其他 UI。
    if (channelIndex >= 0) {
        name = QString::number(channelIndex + 1) + QStringLiteral("_") + name;
    }

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
// 查询某文件在「当前评分人」下的评分（用于 UI 显示回填）
// ════════════════════════════════════════════════════════════════════════

int RatingStore::ratingFor(const QString& filePath) const {
    if (filePath.trimmed().isEmpty()) return -1;
    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();
    const QList<QVariantMap> rows = readAll();
    for (const auto& r : rows) {
        if (r.value("file_path").toString() == filePath &&
            r.value("rater").toString() == rater) {
            int v = r.value("stars").toInt();
            if (v < 0) v = 0;
            if (v > 5) v = 5;
            return v;
        }
    }
    return -1;
}

// ════════════════════════════════════════════════════════════════════════
// 导出到任意路径
//
// 注意：这里**不直接拷贝** m_dataFile，而是在内存里重新组装一份
// "汇总友好的精简 CSV"。因为：
//   1. 多人评分同一份视频时，大家会把各自的 CSV 汇总到一起做横向对比，
//      file_path（每个人本地路径千差万别）、file_size、quick_hash
//      属于环境噪音，混进去反而干扰对齐——只留 file_name 即可，
//      file_name 已经被写成 "<通道号>_<原文件名>" 形式（如 "1_xxx.mp4"），
//      天然带"通道维度"，多人多组 vlookup 都能对齐。
//   2. 内部存储的 ISO8601（含毫秒/T 分隔）人眼读起来割裂，导出时统一
//      格式化为 "yyyy-MM-dd HH:mm:ss"，与弹窗表格里看到的一致。
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::exportToFile(const QString& targetPath) const {
    if (targetPath.trimmed().isEmpty()) return false;

    QFileInfo(targetPath).absoluteDir().mkpath(".");
    QFile dst(targetPath);
    if (!dst.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        return false;

    QTextStream ts(&dst);
    ts.setEncoding(QStringConverter::Utf8);
    ts.setGenerateByteOrderMark(true);   // 让 Excel 直接打开中文不乱码

    // 精简表头：仅四列，按汇总场景下的可读优先排序
    ts << "updated_at,rater,file_name,stars\n";

    const QList<QVariantMap> rows = readAll();
    for (const auto& r : rows) {
        // 把 ISO8601（"2026-05-14T18:48:21.281" 或带时区）转成 "yyyy-MM-dd HH:mm:ss"。
        // 兼容三种实际可能出现的格式：ISODateWithMs、ISODate、退化为本地时间字符串。
        const QString rawTs = r.value("updated_at").toString();
        QDateTime dt = QDateTime::fromString(rawTs, Qt::ISODateWithMs);
        if (!dt.isValid()) dt = QDateTime::fromString(rawTs, Qt::ISODate);
        const QString prettyTs = dt.isValid()
                                     ? dt.toString("yyyy-MM-dd HH:mm:ss")
                                     : rawTs;  // 拿不动就原样吐出，至少不丢数据

        ts << csvEscape(prettyTs)                          << ","
           << csvEscape(r.value("rater").toString())       << ","
           << csvEscape(r.value("file_name").toString())   << ","
           << r.value("stars").toInt()                     << "\n";
    }
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
