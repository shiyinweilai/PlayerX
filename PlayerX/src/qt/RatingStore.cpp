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
constexpr const char* kSettingsModeKey      = "rating/mode";
constexpr const char* kSettingsUploadUrlKey = "rating/uploadUrl";
constexpr const char* kSettingsUploadTokKey = "rating/uploadToken";
constexpr const char* kSettingsUploadTagKey = "rating/uploadTag";

// 评分模式表：未来加新模式只要在这里追加一项，
// QML 会通过 modeList 自动拿到所有字段生成 UI。
struct ModeDef { const char* id; const char* label; int maxStars; };
static const ModeDef kModeTable[] = {
    {"aigc",       "AIGC 评分",     5},
    {"subjective", "传统主观评分", 3},
};
static constexpr int kModeCount = sizeof(kModeTable) / sizeof(kModeTable[0]);

static const ModeDef* findMode(const QString& id) {
    if (id.isEmpty()) return nullptr;
    for (int i = 0; i < kModeCount; ++i) {
        if (id == QLatin1String(kModeTable[i].id)) return &kModeTable[i];
    }
    return nullptr;
}
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
    m_baseDir = base;

    // 预热默认模式的文件（首启动即生成 ratings_aigc.csv，
    // 避免 UI 首次读取 dataFilePath 时拿到一个不存在的路径）。
    ensureFileForMode(currentMode());
}

// 按 mode 路由 CSV 文件：
//   - mode == "off" 或不在表里 → 返回空串（调用方需自行兼容）
//   - 其他 → ratings_<mode>.csv，不存在则创建空文件 + 表头
QString RatingStore::ensureFileForMode(const QString& mode) const {
    if (mode.isEmpty() || mode == QStringLiteral("off")) return {};
    if (!findMode(mode)) return {};

    const QString fp = QDir(m_baseDir).filePath(
        QStringLiteral("ratings_%1.csv").arg(mode));
    if (!QFileInfo::exists(fp)) {
        QFile f(fp);
        if (f.open(QIODevice::WriteOnly | QIODevice::Text)) {
            QTextStream ts(&f);
            ts.setEncoding(QStringConverter::Utf8);
            ts.setGenerateByteOrderMark(true);
            ts << kCsvHeader << "\n";
        }
    }
    return fp;
}

QString RatingStore::dataFilePath() const {
    return ensureFileForMode(currentMode());
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
// 评分模式：QSettings 持久化，默认 "aigc"
// ════════════════════════════════════════════════════════════════════════

QString RatingStore::currentMode() const {
    QSettings s;
    QString m = s.value(kSettingsModeKey, QStringLiteral("aigc")).toString().trimmed();
    // 兼容性兜底：值不在表里且不是 "off" 时回退到 aigc，避免脏数据卡死 UI。
    if (m == QStringLiteral("off")) return m;
    if (!findMode(m)) return QStringLiteral("aigc");
    return m;
}

void RatingStore::setCurrentMode(const QString& mode) {
    QString m = mode.trimmed();
    // 仅允许：在 modeList 中的合法 id，或 "off"。
    if (m != QStringLiteral("off") && !findMode(m)) return;
    QSettings s;
    if (s.value(kSettingsModeKey).toString() == m) return;
    s.setValue(kSettingsModeKey, m);
    s.sync();
    // 切换 mode 后保证目标文件存在（off 模式 ensureFileForMode 直接返回空串）。
    ensureFileForMode(m);
    emit currentModeChanged();
    // dataFilePath 与 totalCount 视图也要刷新；后者依赖 changed 信号。
    emit changed();
}

int RatingStore::maxStars() const {
    const QString m = currentMode();
    if (m == QStringLiteral("off")) return 0;
    if (auto* d = findMode(m)) return d->maxStars;
    return 5;
}

QVariantList RatingStore::modeList() const {
    QVariantList out;
    out.reserve(kModeCount);
    for (int i = 0; i < kModeCount; ++i) {
        QVariantMap m;
        m[QStringLiteral("id")]       = QString::fromLatin1(kModeTable[i].id);
        m[QStringLiteral("label")]    = QString::fromUtf8(kModeTable[i].label);
        m[QStringLiteral("maxStars")] = kModeTable[i].maxStars;
        out << m;
    }
    return out;
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
    // off 模式不写盘（避免用户切到 "关闭" 后误触快捷键还在记录）
    const QString modeNow = currentMode();
    if (modeNow == QStringLiteral("off")) return false;
    const int cap = maxStars();
    if (stars < 0) stars = 0;
    if (cap > 0 && stars > cap) stars = cap;  // 自动截断到当前模式上限

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
    if (currentMode() == QStringLiteral("off")) return -1;
    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();
    const int cap = maxStars();
    const QList<QVariantMap> rows = readAll();
    for (const auto& r : rows) {
        if (r.value("file_path").toString() == filePath &&
            r.value("rater").toString() == rater) {
            int v = r.value("stars").toInt();
            if (v < 0) v = 0;
            if (cap > 0 && v > cap) v = cap;
            return v;
        }
    }
    return -1;
}

// ════════════════════════════════════════════════════════════════════════
// 导出到任意路径
//
// 注意：这里**不直接拷贝**当前模式 CSV 文件，而是在内存里重新组装一份
// "汇总友好的精简 CSV"。因为：
//   1. 多人评分同一份视频时，大家会把各自的 CSV 汇总到一起做横向对比，
//      file_path（每个人本地路径千差万别）、file_size、quick_hash
//      属于环境噪音，混进去反而干扰对齐——所以只导出
//      (updated_at, rater, folder, file_name, stars) 5 列。
//   2. **新结构（与前端 UI 一致）**：用单独一列 `folder` 表示分组，
//      `file_name` 不再拼接 "<通道号>_" 前缀，回归原始文件名。
//      这样后端拿到的 CSV 就能直接按 folder 分组，
//      与桌面端"评分弹窗按文件夹归并"的视图天然对齐。
//   3. 内部存储的 ISO8601（含毫秒/T 分隔）人眼读起来割裂，导出时统一
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
    ts << "updated_at,rater,folder,file_name,stars\n";

    // 历史本地 CSV 里 file_name 形如 "1_xxx.mp4"（带通道前缀）。
    // 上传/导出阶段把通道前缀剥掉，只保留原始文件名；通道维度由
    // file_path 所属目录补齐到 folder 列里。这样新老数据导出格式一致。
    auto stripChannelPrefix = [](const QString& name) -> QString {
        // 形如 "<digits>_<rest>"：digits 长度 1~3 即视为通道号前缀，剥掉。
        // 普通文件名以数字开头但跟着别的字符（比如 "0001_b.mp4"）不会被误剥，
        // 因为这种命名方式用数字+下划线+其他字符开头，但前缀长度上限 3 位
        // 加上下划线即可基本避开（业务上通道号最多到几十路）。
        int i = 0;
        while (i < name.size() && i < 3 && name.at(i).isDigit()) ++i;
        if (i > 0 && i < name.size() && name.at(i) == QLatin1Char('_')) {
            return name.mid(i + 1);
        }
        return name;
    };

    const QList<QVariantMap> rows = readAll();
    for (const auto& r : rows) {
        const QString fp = r.value("file_path").toString();
        if (filter) {
            // 只看文件所在目录（与 QML 端 _rebuildGroups 的"按目录分组"一致）。
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

        // folder = file_path 所在目录的最后一段名字（与 UI 中折叠分组的标题一致）
        QString folder;
        if (!fp.isEmpty()) folder = QFileInfo(fp).dir().dirName();

        const QString fileName =
            stripChannelPrefix(r.value("file_name").toString());

        ts << csvEscape(prettyTs)  << ","
           << csvEscape(rater)     << ","
           << csvEscape(folder)    << ","
           << csvEscape(fileName)  << ","
           << r.value("stars").toInt() << "\n";
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
    // off 模式不产生数据，也禁止上传，避免上传最近一次“遗留在内存里”的空集。
    const QString modeNow = currentMode();
    if (modeNow == QStringLiteral("off")) {
        emit uploadFinished(false, tr("当前为「不评分」模式，无可上传的评分数据"));
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
    // ── URL 归一化 ────────────────────────────────────────────────────
    // 用户经常只填基址（如 http://host:8765 或 http://host:8765/），并不带 /upload 路径。
    // 这种情况下后端的静态文件中间件会"吞掉"请求，看起来好像 200 实则没存文件，
    // 是历史上经常踩的坑。这里统一在客户端兜底：
    //   - path 为空或只有 "/"  → 补成 "/upload"
    //   - path 末尾误带 "/"     → 去掉
    //   - 其他路径（如 "/api/upload"）保持原样，不替用户做主
    {
        QString path = u.path();
        if (path.isEmpty() || path == "/") {
            u.setPath("/upload");
        } else if (path.size() > 1 && path.endsWith('/')) {
            u.setPath(path.left(path.size() - 1));
        }
    }

    // ── 必填校验（不再做"用系统用户名 / default tag 兜底"，避免误传）─────────
    // 设计动机：之前后端会在 user 为空时回退到系统用户名，tag 为空时由服务端兜成
    // "default"，结果"没填评分人也能上传"。这违反了对话框 UI 上的红色 * 标记，
    // 且会污染云端数据（多个未填写者匿名汇总到同一份 default tag）。
    // 现在所有上传入口（按钮/覆盖重传/保存并上传）都在这里统一拒绝。
    QString rater = currentUser().trimmed();
    if (rater.isEmpty()) {
        emit uploadFinished(false,
            tr("「评分人」为必填项，未填写无法上传。\n请在顶部「评分人 *」输入框填写后再试。"));
        return;
    }
    QString tagVal = uploadTag().trimmed();
    if (tagVal.isEmpty()) {
        emit uploadFinished(false,
            tr("「备注 tag」为必填项，未填写无法上传。\n请在顶部「备注 tag *」输入框填写后再试。"));
        return;
    }

    const QByteArray csvBytes = buildExportCsvBytes(folderPaths);
    // 仅有表头一行 → 视为空结果。
    // 区分两种空：完全没有评分 vs 过滤后没命中（白名单挑了空文件夹）。
    bool csvEmpty = csvBytes.isEmpty();
    if (!csvEmpty) {
        // 用换行计数判定数据行更稳：数据行数 = 总行数 - 1（表头）。
        // （新表头：updated_at,rater,folder,file_name,stars）
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

    // file 字段（主要负载）。
    // 文件名携带当前模式，让后端 / 运维在付启同名时一眼识别是 AIGC 还是主观评分。
    QHttpPart filePart;
    QString fileName = QStringLiteral("playerx_%1_%2_%3.csv")
                           .arg(rater.isEmpty() ? "anon" : rater)
                           .arg(modeNow)
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

    // tag 字段：后端靠 (user, tag, mode) 识别是否重复上传
    {
        QHttpPart p;
        p.setHeader(QNetworkRequest::ContentDispositionHeader,
                    QVariant("form-data; name=\"tag\""));
        p.setBody(tagVal.toUtf8());   // 已在入口处校验非空
        multi->append(p);
    }
    // mode 字段：让后端可按模式分桶，不同模式的 (user, tag) 互不冲突。
    // 后端服务考虑兼容旧客户端：不传 mode 默认当作 "aigc"。
    {
        QHttpPart p;
        p.setHeader(QNetworkRequest::ContentDispositionHeader,
                    QVariant("form-data; name=\"mode\""));
        p.setBody(modeNow.toUtf8());
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
    const QString fp = currentDataFile();
    if (fp.isEmpty()) return false;   // off 模式无从谈起清空
    QFile f(fp);
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
// 按文件夹批量删除（与 buildExportCsvBytes 的目录命中规则保持一致：
// 用 file_path 的"绝对父目录"匹配 folderPaths 经 QFileInfo 规整化后的集合）
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::removeByFolders(const QStringList& folderPaths) {
    // 空白名单视为非法（避免被误用为"全删"——那种语义请走 clearAll）
    QSet<QString> allow;
    for (const QString& p : folderPaths) {
        const QString t = p.trimmed();
        if (t.isEmpty()) continue;
        allow.insert(QFileInfo(t).absoluteFilePath());
    }
    if (allow.isEmpty()) return false;

    const QList<QVariantMap> rows = readAll();
    QList<QVariantMap> kept;
    kept.reserve(rows.size());
    int removed = 0;
    for (const auto& r : rows) {
        const QString fp = r.value("file_path").toString();
        if (!fp.isEmpty()) {
            const QString dir = QFileInfo(fp).absolutePath();
            if (allow.contains(dir)) { ++removed; continue; }   // 命中 → 删
        }
        kept.push_back(r);
    }

    if (removed == 0) return false;            // 没有命中任何行：不写盘、也不发信号

    if (!writeAll(kept)) return false;
    emit changed();
    return true;
}

// ════════════════════════════════════════════════════════════════════════
// 在系统文件管理器中定位
// ════════════════════════════════════════════════════════════════════════

void RatingStore::revealInFolder() const {
    const QString fp = currentDataFile();
    QFileInfo fi(fp.isEmpty() ? m_baseDir : fp);
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
    const QString fp = currentDataFile();
    if (fp.isEmpty()) return false;
    QFile f(fp);
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
    const QString fp = currentDataFile();
    if (fp.isEmpty()) return out;   // off 模式：表格表现为空
    QFile f(fp);
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
