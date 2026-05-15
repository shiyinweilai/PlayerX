/**
 * RatingStore.cpp — 见 RatingStore.h
 */
#include "RatingStore.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHttpMultiPart>
#include <QHttpPart>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <QTextStream>
#include <QUrl>

namespace rbqt {

namespace {
constexpr const char* kCsvHeader =
    "updated_at,rater,file_name,file_path,file_size,quick_hash,stars";
constexpr const char* kSettingsUserKey      = "rating/user";
constexpr const char* kSettingsUploadUrlKey = "rating/uploadUrl";
constexpr const char* kSettingsUploadTokKey = "rating/uploadToken";
constexpr const char* kSettingsUploadTagKey = "rating/uploadTag";
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

// ──通用 KV 持久化 ─────────────────────────────────────────────
// 直接落到 QSettings 默认 scope（与 currentUser / uploadServerUrl 等共用同一份 ini）。
// 这里没有 Q_PROPERTY 通知，调用方自己负责 set 后再 get 读取。

QString RatingStore::loadString(const QString& key, const QString& defaultValue) const {
    if (key.isEmpty()) return defaultValue;
    QSettings s;
    return s.value(key, defaultValue).toString();
}

void RatingStore::saveString(const QString& key, const QString& value) {
    if (key.isEmpty()) return;
    QSettings s;
    if (value.isEmpty()) {
        s.remove(key);
    } else {
        s.setValue(key, value);
    }
    s.sync();
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

    const QByteArray bytes = buildExportCsvBytes();
    return dst.write(bytes) == bytes.size();
}

// 在内存里拼出与 exportToFile 完全一致的精简 CSV（UTF-8 with BOM）。
// 上传代码复用这份字节，避免绕一圈磁盘。
//
// 重要变更：**rater 列使用 currentUser 强制覆盖**。
//   场景：用户在评分人输入框里从 "rbyang" 改为 "test"后，期望导出/上传的 CSV
//   全归到 "test" 名下；但本地 ratings.csv 仍保留“写入当时的 rater”以供追溯。
//   这里仅在“导出瞬间”统一身份。
QByteArray RatingStore::buildExportCsvBytes(const QStringList& folderPaths) const {
    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();

    // 把白名单一次规整化成绝对路径，避免大小写/末尾斜杠/相对路径的逐行比对开销。
    // 空白名单 = 不过滤。
    QSet<QString> allow;
    const bool filter = !folderPaths.isEmpty();
    if (filter) {
        for (const QString& p : folderPaths) {
            const QString t = p.trimmed();
            if (t.isEmpty()) continue;
            allow.insert(QFileInfo(t).absoluteFilePath());
        }
    }

    QByteArray buf;
    QTextStream ts(&buf, QIODevice::WriteOnly);
    ts.setEncoding(QStringConverter::Utf8);
    ts.setGenerateByteOrderMark(true);
    ts << "updated_at,rater,file_name,stars\n";

    const QList<QVariantMap> rows = readAll();
    for (const auto& r : rows) {
        if (filter) {
            // 只看文件所在目录（与 QML 端 _rebuildGroups 的“按目录分组”一致）。
            const QString fp = r.value("file_path").toString();
            if (fp.isEmpty()) continue;
            const QString dir = QFileInfo(fp).absolutePath();
            if (!allow.contains(dir)) continue;
        }
        const QString rawTs = r.value("updated_at").toString();
        QDateTime dt = QDateTime::fromString(rawTs, Qt::ISODateWithMs);
        if (!dt.isValid()) dt = QDateTime::fromString(rawTs, Qt::ISODate);
        const QString prettyTs = dt.isValid()
                                     ? dt.toString("yyyy-MM-dd HH:mm:ss")
                                     : rawTs;

        ts << csvEscape(prettyTs)                          << ","
           << csvEscape(rater)                             << ","
           << csvEscape(r.value("file_name").toString())   << ","
           << r.value("stars").toInt()                     << "\n";
    }
    ts.flush();
    return buf;
}

// ═════════════════════════════════════════════════════════════════════
// 上传：读取配置 → 拼 multipart → POST → 信号带出结果
// ═════════════════════════════════════════════════════════════════════

QString RatingStore::uploadServerUrl() const {
    QSettings s;
    return s.value(kSettingsUploadUrlKey).toString().trimmed();
}

void RatingStore::setUploadServerUrl(const QString& url) {
    QSettings s;
    QString trimmed = url.trimmed();
    if (s.value(kSettingsUploadUrlKey).toString() == trimmed) return;
    s.setValue(kSettingsUploadUrlKey, trimmed);
    s.sync();
    emit uploadConfigChanged();
}

QString RatingStore::uploadToken() const {
    QSettings s;
    return s.value(kSettingsUploadTokKey).toString();
}

void RatingStore::setUploadToken(const QString& token) {
    QSettings s;
    if (s.value(kSettingsUploadTokKey).toString() == token) return;
    s.setValue(kSettingsUploadTokKey, token);
    s.sync();
    emit uploadConfigChanged();
}

QString RatingStore::uploadTag() const {
    QSettings s;
    return s.value(kSettingsUploadTagKey).toString().trimmed();
}

void RatingStore::setUploadTag(const QString& tag) {
    QSettings s;
    QString trimmed = tag.trimmed();
    if (s.value(kSettingsUploadTagKey).toString() == trimmed) return;
    s.setValue(kSettingsUploadTagKey, trimmed);
    s.sync();
    emit uploadConfigChanged();
}

void RatingStore::uploadToCloud(bool force, const QStringList& folderPaths) {
    if (m_uploading) {
        // 并发护栏：连点不会发出多起请求。
        emit uploadFinished(false, tr("已有上传任务进行中，请稍后重试"));
        return;
    }
    const QString url = uploadServerUrl();
    if (url.isEmpty()) {
        emit uploadFinished(false, tr("未配置上传地址，请先填写服务器 URL"));
        return;
    }
    QUrl u(url);
    if (!u.isValid() || (u.scheme() != "http" && u.scheme() != "https")) {
        emit uploadFinished(false, tr("服务器地址不合法（需以 http:// 或 https:// 开头）"));
        return;
    }

    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();

    const QByteArray csvBytes = buildExportCsvBytes(folderPaths);
    // 仅有表头一行 → 视为空结果。
    // 区分两种空：完全没有评分 vs 过滤后没命中（白名单挑了空文件夹）。
    bool csvEmpty = csvBytes.isEmpty();
    if (!csvEmpty) {
        // 表头行 = "updated_at,rater,file_name,stars\n"，加 BOM 共 35 字节。
        // 用换行计数判定数据行更稳：数据行数 = 总行数 - 1（表头）。
        int dataLines = csvBytes.count('\n') - 1;
        if (dataLines <= 0) csvEmpty = true;
    }
    if (csvEmpty) {
        if (!folderPaths.isEmpty()) {
            emit uploadFinished(false, tr("勾选的文件夹下没有可上传的评分记录"));
        } else {
            emit uploadFinished(false, tr("评分数据为空，无需上传"));
        }
        return;
    }

    if (!m_nam) m_nam = new QNetworkAccessManager(this);

    auto* multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);

    // file 字段（主要负载）
    QHttpPart filePart;
    QString fileName = QStringLiteral("playerx_%1_%2.csv")
                           .arg(rater.isEmpty() ? "anon" : rater)
                           .arg(QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss"));
    filePart.setHeader(QNetworkRequest::ContentDispositionHeader,
                       QVariant(QString("form-data; name=\"file\"; filename=\"%1\"").arg(fileName)));
    filePart.setHeader(QNetworkRequest::ContentTypeHeader, QVariant("text/csv; charset=utf-8"));
    filePart.setBody(csvBytes);
    multi->append(filePart);

    // user 字段
    QHttpPart userPart;
    userPart.setHeader(QNetworkRequest::ContentDispositionHeader,
                       QVariant("form-data; name=\"user\""));
    userPart.setBody(rater.toUtf8());
    multi->append(userPart);

    // client 字段（带上应用名+版本，服务端可记录以供审计）
    QHttpPart cliPart;
    cliPart.setHeader(QNetworkRequest::ContentDispositionHeader,
                      QVariant("form-data; name=\"client\""));
    QString clientTag = QString("PlayerX/%1 (%2)")
                            .arg(qApp ? qApp->applicationVersion() : QString("dev"))
#if defined(Q_OS_MAC)
                            .arg("macOS");
#elif defined(Q_OS_WIN)
                            .arg("Windows");
#else
                            .arg("Linux");
#endif
    cliPart.setBody(clientTag.toUtf8());
    multi->append(cliPart);

    // tag 字段：后端靠 (user, tag) 识别是否重复上传
    {
        QHttpPart p;
        p.setHeader(QNetworkRequest::ContentDispositionHeader,
                    QVariant("form-data; name=\"tag\""));
        p.setBody(uploadTag().toUtf8());
        multi->append(p);
    }
    // force 字段：仅在用户“确认覆盖”后重走时为 true
    if (force) {
        QHttpPart p;
        p.setHeader(QNetworkRequest::ContentDispositionHeader,
                    QVariant("form-data; name=\"force\""));
        p.setBody(QByteArrayLiteral("1"));
        multi->append(p);
    }

    QNetworkRequest req(u);
    req.setRawHeader("User-Agent", "PlayerX-Uploader/1.0");
    const QString tok = uploadToken();
    if (!tok.isEmpty()) req.setRawHeader("X-Token", tok.toUtf8());
    // 超时 30s：局域网下 CSV 体积极小，不该超过 1s，这个是兑底。
    req.setTransferTimeout(30 * 1000);

    QNetworkReply* reply = m_nam->post(req, multi);
    multi->setParent(reply);   // reply 析构时一起释放 multipart

    m_uploading = true;
    emit uploadingChanged();
    emit uploadStarted();

    QObject::connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        const int httpCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();

        // 服务端返回 409 = (rater, tag) 已存在，需要二次确认。
        // 这里不作为错误报出，走专门的 uploadConflict 信号，QML 负责弹“是否覆盖”。
        // 后端 body 是个完整 JSON（带 existing 数组 + mtime 等），直接丢给 QML 显示太吵，
        // 这里只抽关键字段拼个人话。
        if (httpCode == 409) {
            QString msg;
            QJsonParseError perr{};
            const auto doc = QJsonDocument::fromJson(body, &perr);
            if (perr.error == QJsonParseError::NoError && doc.isObject()) {
                const auto obj = doc.object();
                const QString user = obj.value(QStringLiteral("user")).toString();
                const QString tag  = obj.value(QStringLiteral("tag")).toString();
                const auto exArr   = obj.value(QStringLiteral("existing")).toArray();
                const int n        = exArr.size();
                QString lastTime;
                if (n > 0) {
                    const auto it0 = exArr.first().toObject();
                    const QString iso = it0.value(QStringLiteral("mtime")).toString();
                    const QDateTime dt = QDateTime::fromString(iso, Qt::ISODate);
                    if (dt.isValid()) {
                        lastTime = dt.toLocalTime().toString(QStringLiteral("yyyy-MM-dd HH:mm"));
                    } else {
                        lastTime = iso;
                    }
                }
                msg = tr("评分人：%1    标签：%2\n已有 %3 份记录")
                          .arg(user.isEmpty() ? tr("(未填)") : user)
                          .arg(tag.isEmpty()  ? tr("(空)")    : tag)
                          .arg(n);
                if (!lastTime.isEmpty()) {
                    msg += tr("，最近一次：%1").arg(lastTime);
                }
            } else {
                // 后端没返 JSON（不太可能）才走这个兑底分支
                msg = tr("服务端提示该评分人/标签已有记录");
            }
            m_uploading = false;
            emit uploadingChanged();
            emit uploadConflict(msg);
            reply->deleteLater();
            return;
        }

        const bool ok = (reply->error() == QNetworkReply::NoError);
        QString message;
        if (ok) {
            // 服务端返回是个简单 JSON，里面有 saved 字段；这里不动用 QJsonDocument，
            // 反正只是展示用，拿原始字节足够这个场景。只护一下快照：
            QString trimmed = QString::fromUtf8(body).trimmed();
            if (trimmed.size() > 200) trimmed = trimmed.left(200) + QStringLiteral("…");
            message = tr("上传成功：%1").arg(trimmed.isEmpty() ? tr("已收到") : trimmed);
        } else {
            // 优先从 JSON body 里抠 error 字段（避免把一长串 JSON 原文吐给用户）
            QString errText;
            {
                QJsonParseError perr{};
                const auto doc = QJsonDocument::fromJson(body, &perr);
                if (perr.error == QJsonParseError::NoError && doc.isObject()) {
                    errText = doc.object().value(QStringLiteral("error")).toString().trimmed();
                }
            }
            if (errText.isEmpty()) errText = QString::fromUtf8(body).trimmed();
            if (errText.isEmpty()) errText = reply->errorString();

            // 401/403 视作鉴权类硬错：在文案前加 [AUTH] 标记，QML 端据此弹强提醒。
            // 兼容服务端自身已经带 [AUTH] 前缀的情况，避免重复加。
            const bool authErr = (httpCode == 401 || httpCode == 403);
            if (authErr && !errText.startsWith(QStringLiteral("[AUTH]"))) {
                errText = QStringLiteral("[AUTH] ") + errText;
            }

            if (httpCode > 0) {
                message = tr("上传失败 (HTTP %1)：%2").arg(httpCode).arg(errText);
            } else {
                message = tr("上传失败：%1").arg(errText);
            }
        }
        m_uploading = false;
        emit uploadingChanged();
        emit uploadFinished(ok, message);
        reply->deleteLater();
    });
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
