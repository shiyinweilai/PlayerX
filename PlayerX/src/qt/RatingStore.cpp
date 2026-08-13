/**
 * RatingStore.cpp — 见 RatingStore.h
 */
#include "RatingStore.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
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
#include <QRegularExpression>
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <QTextStream>
#include <QUrl>

namespace rbqt {

namespace {
constexpr const char* kCsvHeader =
    "updated_at,rater,file_name,file_path,file_size,quick_hash,stars,slide_type,checklist";
constexpr const char* kSettingsUserKey      = "rating/user";
constexpr const char* kSettingsModeKey      = "rating/mode";
constexpr const char* kSettingsUploadUrlKey = "rating/uploadUrl";
constexpr const char* kSettingsUploadTokKey = "rating/uploadToken";
constexpr const char* kSettingsUploadTagKey = "rating/uploadTag";

// 评分模式表：未来加新模式只要在这里追加一项，
// QML 会通过 modeList 自动拿到所有字段生成 UI。
struct ModeDef { const char* id; const char* label; int maxStars; };
static const ModeDef kModeTable[] = {
    {"subjective",    "主观评分（五分制）",          5},
    {"quality",       "质量比较（差/相当/好）",       2},
    // 质量比较 2：行为与 quality 完全一致（CSV 格式/写入逻辑均不变），
    // 仅在 QML 层额外要求"必须进入滑动对比并对 L/R 各打分"才能切下一组。
    // CSV 文件名 ratings_quality_slide.csv，与 quality 隔离不冲突。
    {"quality_slide", "质量比较 2（含滑动对比）",     2},
    // 多维评分：从 dimensions.json 加载维度列表，每个维度独立打分（五分制）。
    {"multi_dim",     "多维评分",                   5},
    // 测试模式：开发者调试用途，行为与 subjective 完全一致（五分制、单视频打星）。
    // 单独一个 mode id 便于把测试数据从主观评分的 CSV / 归档批次里隔离出来，
    // 不会污染真正的主观评分统计。
    {"test",          "测试模式",                    5},
};
static constexpr int kModeCount = sizeof(kModeTable) / sizeof(kModeTable[0]);

static const ModeDef* findMode(const QString& id) {
    if (id.isEmpty()) return nullptr;
    for (int i = 0; i < kModeCount; ++i) {
        if (id == QLatin1String(kModeTable[i].id)) return &kModeTable[i];
    }
    return nullptr;
}

// 把 "文件夹路径" 规整成与 QFileInfo(file_path).absolutePath() 同形态的键，
// 用于 buildExportCsvBytes / removeByFolders / archiveByFolders 三处的 set 命中。
//
// 规整内容：
//   1) trim；
//   2) 去掉末尾的 '/' 或 '\\'（FolderDialog 选出的路径常带末尾斜杠，会让
//      QFileInfo("/x/y/").absoluteFilePath() 返回 "/x/y/" 与目录侧的
//      "/x/y" 不匹配，是这次重置进度未生效的真正原因）；
//   3) 走 QFileInfo::absoluteFilePath() 统一到绝对形态；
//   4) 再用 QDir::cleanPath 折叠 "//"、"."、".."。
// 仅针对 "目录路径"，不要对文件路径用。
static QString normalizeFolderForMatch(const QString& raw) {
    QString t = raw.trimmed();
    while (t.size() > 1
           && (t.endsWith(QLatin1Char('/')) || t.endsWith(QLatin1Char('\\')))) {
        t.chop(1);
    }
    if (t.isEmpty()) return QString();
    return QDir::cleanPath(QFileInfo(t).absoluteFilePath());
}

// folder 列显示名：file_path 所在目录的末 N 级路径（默认 3 级，如 "包名/g3/A"）。
// 早期只取最后一段（"A"），后台列表无法区分同名文件夹，故多带两级父目录；
// 分隔符统一为 '/'，兼容 Windows '\' 与 macOS/Linux '/'。
// 用于 buildExportCsvBytes / buildArchiveExportCsvBytes 两处的 folder 列。
static QString folderDisplayName(const QString& filePath, int levels = 3) {
    if (filePath.isEmpty()) return QString();
    QString dir = QFileInfo(filePath).dir().absolutePath();
    dir.replace(QLatin1Char('\\'), QLatin1Char('/'));
    const QStringList segs = dir.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    const int n = qMin(levels, segs.size());
    return segs.mid(segs.size() - n).join(QLatin1Char('/'));
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

    // 预热默认模式的文件（首启动即生成 ratings_subjective.csv，
    // 避免 UI 首次读取 dataFilePath 时拿到一个不存在的路径）。
    ensureFileForMode(currentMode());

    // ── 【开发者本地 override】───────────────────────────────────────
    // 优先级（从高到低）：
    //   1) 环境变量 PLAYERX_UPLOAD_URL_DEV（临时覆盖：export 一次即可，重启失效）
    //   2) bundle 内 dev-upload.conf（每次 `python3 build.py` 编译时由 build.py 写入，
    //      内容格式：
    //          url=http://<本机内网IP>:2026/
    //          token=10086
    //      这样"每次本地编译产物"天然带上当前机器的 dev URL，换电脑重编译自动跟新 IP；
    //      正式分发包（--package）不会写入此文件，普通用户看不到）
    // 命中后：
    //   · 不写入 QSettings，关掉环境变量 / 换成正式包重启行为完全等同旧版；
    //   · setUploadServerUrl/setUploadToken 命中时被短路，防止远端 latest.json
    //     的 clientConfig 或用户在 UI 里改的 URL 又覆盖调试环境；
    //   · 未命中的普通用户完全无感知，与之前一模一样。
    QString envUrl   = qEnvironmentVariable("PLAYERX_UPLOAD_URL_DEV").trimmed();
    QString envToken = qEnvironmentVariable("PLAYERX_UPLOAD_TOKEN_DEV");
    QString source   = QStringLiteral("env");
    if (envUrl.isEmpty()) {
        // 兜底：读 <app>/Contents/Resources/dev-upload.conf（macOS）或 exe 同目录（Windows）
        // 位置计算与 dimensions.json 的读取一致，都走 applicationDirPath() 定位。
        const QString appDir = QCoreApplication::applicationDirPath();
        QStringList candidates;
    #ifdef Q_OS_MACOS
        // .app/Contents/MacOS/ → 上一层 Resources/
        candidates << QDir(appDir).filePath(QStringLiteral("../Resources/dev-upload.conf"));
    #endif
        // Windows / 兜底：exe 同目录
        candidates << QDir(appDir).filePath(QStringLiteral("dev-upload.conf"));

        for (const QString& p : candidates) {
            QFile f(p);
            if (!f.exists() || !f.open(QIODevice::ReadOnly | QIODevice::Text)) continue;
            // 极简 KV 解析：忽略空行 / '#' 开头注释；识别 url= / token= 两个键
            QString fUrl, fTok;
            while (!f.atEnd()) {
                const QString line = QString::fromUtf8(f.readLine()).trimmed();
                if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;
                const int eq = line.indexOf(QLatin1Char('='));
                if (eq <= 0) continue;
                const QString k = line.left(eq).trimmed();
                const QString v = line.mid(eq + 1).trimmed();
                if (k == QLatin1String("url"))   fUrl = v;
                else if (k == QLatin1String("token")) fTok = v;
            }
            if (!fUrl.isEmpty()) {
                envUrl   = fUrl;
                envToken = fTok;
                source   = QStringLiteral("conf:%1").arg(QFileInfo(p).absoluteFilePath());
            }
            break;
        }
    }

    if (!envUrl.isEmpty()) {
        m_uploadUrlOverridden = true;
        m_uploadUrlOverride   = envUrl;
        m_uploadTokenOverride = envToken;
        qInfo().noquote() << "[RatingStore] 开发者 override 生效 [" << source << "]："
                          << "uploadServerUrl =" << envUrl
                          << (m_uploadTokenOverride.isEmpty()
                              ? QStringLiteral("(token 未设置)")
                              : QStringLiteral("(token 已设置)"));
    }
}

// 按 mode 路由 CSV 文件：
//   - mode == "off" 或不在表里 → 返回空串（调用方需自行兼容）
//   - 其他 → ratings_<mode>.csv，不存在则创建空文件 + 表头
QString RatingStore::ensureFileForMode(const QString& mode) const {
    if (mode.isEmpty() || mode == QStringLiteral("off")) return {};
    // quality_slide_slide 是滑动评分的内部标识，实际写入主 CSV（ratings_quality_slide.csv），
    // 通过 slide_type 列区分普通打分与滑动打分，不再使用独立文件。
    if (mode == QStringLiteral("quality_slide_slide")) {
        return ensureFileForMode(QStringLiteral("quality_slide"));
    }
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
// 评分模式：QSettings 持久化，默认 "subjective"
// ════════════════════════════════════════════════════════════════════════

QString RatingStore::currentMode() const {
    QSettings s;
    QString m = s.value(kSettingsModeKey, QStringLiteral("off")).toString().trimmed();
    // 兼容性兜底：值不在表里且不是 "off" 时回退到 off，避免脏数据卡死 UI。
    if (m == QStringLiteral("off")) return m;
    if (!findMode(m)) return QStringLiteral("off");
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

// ── 导出/上传 CSV 时的 checklist 白名单过滤 ──────────────────────
// 见 RatingStore.h 中的详细说明。这里的实现仅"打上标记 + 存 QStringList"，
// 真正过滤发生在 filterChecklistKeysForExport（buildExportCsvBytes /
// buildArchiveExportCsvBytes 里的 lambda 会调它）。
//
// 注意：为方便 QML 侧数据集合去重，keys 会做 trim + 去空 + 去重。
void RatingStore::setExportChecklistWhitelist(const QStringList& keys, bool active) {
    m_hasExportChecklistWhitelist = active;
    if (!active) {
        m_exportChecklistWhitelist.clear();
        return;
    }
    QStringList uniq;
    uniq.reserve(keys.size());
    for (const QString& raw : keys) {
        const QString k = raw.trimmed();
        if (k.isEmpty()) continue;
        if (!uniq.contains(k)) uniq.push_back(k);
    }
    m_exportChecklistWhitelist = uniq;
}

void RatingStore::clearExportChecklistWhitelist() {
    m_hasExportChecklistWhitelist = false;
    m_exportChecklistWhitelist.clear();
}

QString RatingStore::filterChecklistKeysForExport(const QStringList& rawKeys) const {
    // 情况 1：未设置白名单 → 保留旧行为（不过滤），仅去空 join
    if (!m_hasExportChecklistWhitelist) {
        QStringList out;
        out.reserve(rawKeys.size());
        for (const QString& k : rawKeys) {
            if (!k.isEmpty()) out.push_back(k);
        }
        return out.join(QLatin1Char(','));
    }
    // 情况 2：白名单激活且为空 → "当前模式无 checklist"，全部输出空
    if (m_exportChecklistWhitelist.isEmpty()) {
        return QString();
    }
    // 情况 3：白名单激活且非空 → 仅保留白名单里的 keys
    QStringList out;
    out.reserve(rawKeys.size());
    for (const QString& k : rawKeys) {
        if (!k.isEmpty() && m_exportChecklistWhitelist.contains(k)) {
            out.push_back(k);
        }
    }
    return out.join(QLatin1Char(','));
}

// 从 QSettings 读回某文件的 checklist（JSON 数组），经白名单过滤后返回逗号连接的字符串。
// 存储由 QML 端 Rating.saveString("checklist:<filePath>", JSON.stringify(keys)) 写入。
// 空 / 格式错误 / 非数组 → 交给 filterChecklistKeysForExport(空列表) 处理（返回空或按白名单）。
QString RatingStore::readChecklistCell(const QString& filePath) const {
    if (filePath.isEmpty()) return filterChecklistKeysForExport(QStringList{});
    QSettings s;
    const QString raw = s.value(QStringLiteral("checklist:") + filePath).toString();
    if (raw.isEmpty()) return filterChecklistKeysForExport(QStringList{});
    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(raw.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isArray()) {
        return filterChecklistKeysForExport(QStringList{});
    }
    QStringList keys;
    const QJsonArray arr = doc.array();
    keys.reserve(arr.size());
    for (const auto& v : arr) {
        const QString k = v.toString();
        if (!k.isEmpty()) keys.push_back(k);
    }
    return filterChecklistKeysForExport(keys);
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
    // quality_slide 模式的滑动数据不再在 C++ 层过滤。
    // 由 QML（RatingsDialog）根据当前第二维度 key 做区分：
    //   · slide_type == "multi_<slideDimKey>" 或 == "slide" → 归到"滑动对比打分"分组
    //   · 其他 → 归到"普通打分"分组
    // 这样 C++ 不用感知"第二维度是哪个 key"，避免硬编码，同时兼容旧数据。
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
// 按指定 mode 只读接口（不依赖 currentMode，也不发信号）
// 用途：QML"评分数据"弹窗切换查看 mode 时读取对应 CSV，绝不修改全局状态，
//       避免背景视频宫格的星条/cellRatings 跟着跳变。
// 契约与 ensureFileForMode 一致：off / 未知 mode 一律返回空/兜底值。
// ════════════════════════════════════════════════════════════════════════

QVariantList RatingStore::getAllRatingsForMode(const QString& mode) const {
    QVariantList out;
    // 路径规则完全复用 ensureFileForMode：off / 未知 mode 返回空串 → 视为无数据。
    const QString fp = ensureFileForMode(mode);
    if (fp.isEmpty()) return out;
    QFile f(fp);
    if (!f.exists()) return out;
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return out;

    QList<QVariantMap> rows;
    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);
    bool firstLine = true;
    while (!ts.atEnd()) {
        QString line = ts.readLine();
        if (firstLine) { firstLine = false; continue; }
        if (line.trimmed().isEmpty()) continue;
        QStringList cols = parseCsvLine(line);
        if (cols.size() < 7) continue;
        QVariantMap row;
        row["updated_at"] = cols.value(0);
        row["rater"]      = cols.value(1);
        row["file_name"]  = cols.value(2);
        row["file_path"]  = cols.value(3);
        row["file_size"]  = cols.value(4).toLongLong();
        row["quick_hash"] = cols.value(5);
        row["stars"]      = cols.value(6).toInt();
        row["slide_type"] = cols.size() >= 8 ? cols.value(7) : QString();
        row["checklist"]  = cols.size() >= 9 ? cols.value(8) : QString();
        rows.push_back(row);
    }

    // updated_at 倒序，与 getAllRatings 保持一致
    std::sort(rows.begin(), rows.end(),
              [](const QVariantMap& a, const QVariantMap& b) {
                  return a.value("updated_at").toString() > b.value("updated_at").toString();
              });
    out.reserve(rows.size());
    for (const auto& r : rows) out << r;
    return out;
}

QString RatingStore::dataFilePathForMode(const QString& mode) const {
    // ensureFileForMode 已经处理 off / 未知 mode → 返回空串；
    // 同时保证目录/表头文件存在，QML 端拿到的路径可以直接展示 / 拼 archive 目录。
    return ensureFileForMode(mode);
}

int RatingStore::maxStarsForMode(const QString& mode) const {
    if (mode.isEmpty() || mode == QStringLiteral("off")) return 0;
    if (auto* d = findMode(mode)) return d->maxStars;
    // 未知 mode 返回 0，让 QML 端走自己的兜底（当前 RatingsDialog 会兜到 5）。
    return 0;
}

// ════════════════════════════════════════════════════════════════════════
// 读取滑动对比评分（quality_slide 模式专用）
// 从 slide/ratings_quality_slide.csv 读取，与普通打分完全隔离。
// 非 quality_slide 模式下返回空列表。
// ════════════════════════════════════════════════════════════════════════

QVariantList RatingStore::getSlideRatings() const {
    if (currentMode() != QStringLiteral("quality_slide")) return {};
    // 从主 CSV 过滤 slide_type=="slide" 的行，与普通打分共用同一文件
    QList<QVariantMap> all = readAll();
    QList<QVariantMap> rows;
    rows.reserve(all.size());
    for (const auto& r : all) {
        if (r.value("slide_type").toString() == QStringLiteral("slide"))
            rows.push_back(r);
    }
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
                               int channelIndex,
                               const QString& slideType) {
    if (filePath.trimmed().isEmpty()) return false;
    // off 模式不写盘（避免用户切到 "关闭" 后误触快捷键还在记录）
    const QString modeNow = currentMode();
    if (modeNow == QStringLiteral("off")) return false;
    const int cap = maxStars();
    if (stars < 0) stars = 0;
    // 多维评分（slideType 以 "multi_" 开头）时，每个维度的上限由 levels.length 决定，
    // 不受当前模式 maxStars 限制，跳过截断。
    const bool isMultiDim = slideType.startsWith(QStringLiteral("multi_"));
    if (!isMultiDim && cap > 0 && stars > cap) stars = cap;  // 自动截断到当前模式上限

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
    row["updated_at"]  = QDateTime::currentDateTime().toString(Qt::ISODateWithMs);
    row["rater"]       = rater;
    row["file_name"]   = name;
    row["file_path"]   = filePath;
    row["file_size"]   = fileSizeOf(filePath);
    row["quick_hash"]  = quickHashOf(filePath);
    row["stars"]       = stars;
    // slide_type 优先级：调用方显式传入 > quality_slide 模式自动标记 > 空
    if (!slideType.isEmpty()) {
        row["slide_type"] = slideType;
    } else {
        row["slide_type"] = (modeNow == QStringLiteral("quality_slide"))
                             ? QStringLiteral("normal") : QString();
    }

    // checklist：从 QSettings（key = "checklist:<filePath>"）读回当前勾选，
    // 经当前模式白名单过滤后写入 CSV 的 checklist 列，与上传 CSV 保持一致。
    row["checklist"] = readChecklistCell(filePath);

    QList<QVariantMap> rows = readAll();
    bool replaced = false;
    for (auto& r : rows) {
        // 同 file_path + 同 rater + 同 slide_type 视为同一条 → 覆盖
        if (r.value("file_path").toString() == filePath &&
            r.value("rater").toString() == rater &&
            r.value("slide_type").toString() == row["slide_type"].toString()) {
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
// 向指定 CSV 文件写入一条评分（不依赖 currentMode）
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::recordRatingToFile(const QString& csvPath,
                                     const QString& filePath,
                                     const QString& fileName,
                                     int stars,
                                     int channelIndex) {
    if (csvPath.isEmpty() || filePath.trimmed().isEmpty()) return false;
    if (stars < 0) stars = 0;
    if (stars > 2) stars = 2;   // 滑动评分固定 2 星制

    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();

    QString name = fileName;
    if (name.isEmpty()) name = QFileInfo(filePath).fileName();
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

    // 读取目标 CSV 文件的现有行
    QList<QVariantMap> rows;
    QFile rf(csvPath);
    if (rf.exists() && rf.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QTextStream ts(&rf);
        ts.setEncoding(QStringConverter::Utf8);
        bool firstLine = true;
        while (!ts.atEnd()) {
            QString line = ts.readLine();
            if (firstLine) { firstLine = false; continue; }
            if (line.trimmed().isEmpty()) continue;
            QStringList cols = parseCsvLine(line);
            if (cols.size() < 7) continue;
            QVariantMap r;
            r["updated_at"] = cols.value(0);
            r["rater"]      = cols.value(1);
            r["file_name"]  = cols.value(2);
            r["file_path"]  = cols.value(3);
            r["file_size"]  = cols.value(4).toLongLong();
            r["quick_hash"] = cols.value(5);
            r["stars"]      = cols.value(6).toInt();
            r["slide_type"] = cols.size() >= 8 ? cols.value(7) : QString();
            r["checklist"]  = cols.size() >= 9 ? cols.value(8) : QString();
            rows.push_back(r);
        }
    }

    bool replaced = false;
    for (auto& r : rows) {
        if (r.value("file_path").toString() == filePath &&
            r.value("rater").toString() == rater) {
            r = row;
            replaced = true;
            break;
        }
    }
    if (!replaced) rows.push_back(row);

    // 写回目标 CSV
    QFile wf(csvPath);
    if (!wf.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return false;
    QTextStream ts(&wf);
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
           << r.value("stars").toInt()                    << ","
           << csvEscape(r.value("slide_type").toString()) << ","
           << csvEscape(r.value("checklist").toString())  << "\n";
    }
    emit changed();
    return true;
}

// ════════════════════════════════════════════════════════════════════════
// 滑动对比评分持久化（quality_slide 模式专用）
// 写入主 CSV（ratings_quality_slide.csv），slide_type=slide 区分普通打分。
// 每次打分立即调用，同 (file_path, rater, slide_type) 覆盖最新一条。
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::recordSlideRating(const QString& filePathL,
                                    const QString& fileNameL,
                                    int starsL,
                                    const QString& filePathR,
                                    const QString& fileNameR,
                                    int starsR,
                                    const QString& slideType) {
    // 仅在 quality_slide 模式下生效
    if (currentMode() != QStringLiteral("quality_slide")) return false;

    // 滑动评分的星数由第二个维度配置决定，不受模式级 maxStars 截断
    // （与多维评分的处理方式一致）
    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();

    // slide_type 列的值：优先用调用方传入（推荐 "multi_<第二维度key>"），
    // 为空时兜底 "slide"（向后兼容旧调用方）。
    const QString stValue = slideType.isEmpty()
        ? QStringLiteral("slide")
        : slideType;

    auto makeRow = [&](const QString& fp, const QString& fn, int stars, int ch) -> QVariantMap {
        QString name = fn.isEmpty() ? QFileInfo(fp).fileName() : fn;
        if (ch >= 0) name = QString::number(ch + 1) + QStringLiteral("_") + name;
        if (stars < 0) stars = 0;
        // 不截断：滑动评分星数由 QML 层的 slideMaxStars 控制
        QVariantMap r;
        r["updated_at"] = QDateTime::currentDateTime().toString(Qt::ISODateWithMs);
        r["rater"]      = rater;
        r["file_name"]  = name;
        r["file_path"]  = fp;
        r["file_size"]  = fileSizeOf(fp);
        r["quick_hash"] = quickHashOf(fp);
        r["stars"]      = stars;
        r["slide_type"] = stValue;
        return r;
    };

    // 读取主 CSV，替换同 (file_path, rater, slide_type, file_name) 的行
    // 注意：file_name 含 ch+1_ 前缀（如 "1_foo.mp4" vs "2_foo.mp4"），
    // 用于区分 L/R 两侧，避免同路径文件互相覆盖。
    //
    // 兼容旧数据：若历史上该 (file_path, rater) 的滑动评分行写入的 slide_type 是
    // 老的硬编码 "slide"，而本次写入的是新的 "multi_<key>"，理应视为同一条覆盖，
    // 避免用户已有的滑动评分变成孤立残留 + 新格式重复行。
    QList<QVariantMap> rows = readAll();
    auto upsert = [&](const QString& fp, const QString& fn, int stars, int ch) {
        if (fp.trimmed().isEmpty()) return;
        QVariantMap row = makeRow(fp, fn, stars, ch);
        const QString newName = row.value("file_name").toString();
        bool replaced = false;
        for (auto& r : rows) {
            if (r.value("file_path").toString() != fp) continue;
            if (r.value("rater").toString() != rater) continue;
            if (r.value("file_name").toString() != newName) continue;
            const QString oldSt = r.value("slide_type").toString();
            // 匹配条件：slide_type 完全一致 或 属于"旧硬编码 slide"（升级情形）
            if (oldSt == stValue || oldSt == QStringLiteral("slide")) {
                r = row;
                replaced = true;
                break;
            }
        }
        if (!replaced) rows.push_back(row);
    };

    upsert(filePathL, fileNameL, starsL, 0);
    upsert(filePathR, fileNameR, starsR, 1);

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
            // 多维评分记录不受 maxStars 截断（维度星数由 levels.length 决定）
            const bool isMultiDim = r.value("slide_type").toString().startsWith(QStringLiteral("multi_"));
            if (!isMultiDim && cap > 0 && v > cap) v = cap;
            return v;
        }
    }
    return -1;
}

int RatingStore::ratingFor(const QString& filePath, const QString& slideType) const {
    if (filePath.trimmed().isEmpty()) return -1;
    if (currentMode() == QStringLiteral("off")) return -1;
    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();
    const int cap = maxStars();
    const QList<QVariantMap> rows = readAll();
    for (const auto& r : rows) {
        if (r.value("file_path").toString() == filePath &&
            r.value("rater").toString() == rater &&
            r.value("slide_type").toString() == slideType) {
            int v = r.value("stars").toInt();
            if (v < 0) v = 0;
            // 多维评分记录不受 maxStars 截断（维度星数由 levels.length 决定）
            const bool isMultiDim = slideType.startsWith(QStringLiteral("multi_"));
            if (!isMultiDim && cap > 0 && v > cap) v = cap;
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
            const QString k = normalizeFolderForMatch(p);
            if (k.isEmpty()) continue;
            allow.insert(k);
        }
    }

    QByteArray buf;
    QTextStream ts(&buf, QIODevice::WriteOnly);
    ts.setEncoding(QStringConverter::Utf8);
    ts.setGenerateByteOrderMark(true);
    ts << "updated_at,rater,folder,file_name,stars,slide_type,checklist\n";

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

    // ── Checklist 读取器 ────────────────────────────────────────────
    // 存储由 QML 端 Rating.saveString("checklist:<filePath>", JSON.stringify(keys))
    // 写入 QSettings；这里读回来解析成 keys 列表，再按当前模式的 checklist 白名单
    // 过滤，逗号连接后作为 CSV 的 checklist 列。空、格式错误、或非数组 → 输出空字符串。
    //
    // 【重要】QSettings 里的 "checklist:<filePath>" 不带 mode 前缀，
    // 因此同一文件在多个模式下勾选后会共享存储，导出时必须按当前模式的合法 keys
    // 白名单过滤，否则 CSV 会串到别的模式（如"测试模式"却带着"多维评分"旧勾选）。
    auto readChecklistCsvCell = [this](const QString& filePath) -> QString {
        if (filePath.isEmpty()) return QString();
        QSettings s;
        const QString raw = s.value(QStringLiteral("checklist:") + filePath).toString();
        if (raw.isEmpty()) return this->filterChecklistKeysForExport(QStringList{});
        QJsonParseError err{};
        const QJsonDocument doc = QJsonDocument::fromJson(raw.toUtf8(), &err);
        if (err.error != QJsonParseError::NoError || !doc.isArray()) {
            return this->filterChecklistKeysForExport(QStringList{});
        }
        const QJsonArray arr = doc.array();
        QStringList keys;
        keys.reserve(arr.size());
        for (const auto& v : arr) {
            const QString k = v.toString();
            if (!k.isEmpty()) keys.push_back(k);
        }
        return this->filterChecklistKeysForExport(keys);
    };

    const QList<QVariantMap> rows = readAll();
    for (const auto& r : rows) {
        const QString fp = r.value("file_path").toString();
        if (filter) {
            // 只看文件所在目录（与 QML 端 _rebuildGroups 的"按目录分组"一致）。
            if (fp.isEmpty()) continue;
            const QString dir = QDir::cleanPath(QFileInfo(fp).absolutePath());
            if (!allow.contains(dir)) continue;
        }
        const QString rawTs = r.value("updated_at").toString();
        QDateTime dt = QDateTime::fromString(rawTs, Qt::ISODateWithMs);
        if (!dt.isValid()) dt = QDateTime::fromString(rawTs, Qt::ISODate);
        const QString prettyTs = dt.isValid()
                                     ? dt.toString("yyyy-MM-dd HH:mm:ss")
                                     : rawTs;

        // folder = file_path 所在目录的末三级路径（如 "包名/g3/A"），
        // 后台列表可区分同名文件夹（见 folderDisplayName）
        const QString folder = folderDisplayName(fp);

        const QString fileName =
            stripChannelPrefix(r.value("file_name").toString());

        ts << csvEscape(prettyTs)                          << ","
           << csvEscape(rater)                             << ","
           << csvEscape(folder)                            << ","
           << csvEscape(fileName)                          << ","
           << r.value("stars").toInt()                     << ","
           << csvEscape(r.value("slide_type").toString())  << ","
           << csvEscape(readChecklistCsvCell(fp))          << "\n";
    }
    ts.flush();
    return buf;
}

// ════════════════════════════════════════════════════════════════════════
// 把某归档批次的 CSV 转成与 buildExportCsvBytes 完全一致的// 用于上传归档批次时复用 postCsvBytesToServer 的 multipart / 表单链路。
//
// 与 buildExportCsvBytes 的差异仅在于：
//   · 数据源：archive/<mode>/<batchName>/ratings.csv（而非主 CSV readAll）。
//   · rater 列：归档落盘时的 rater 是“写入瞬间”的值——这里仍按照
//     “导出/上传时统一身份”的语义改用 currentUser（与当前 Tab 一致），
//     避免用户改名后云端列出错乱身份。
// 列顺序、BOM、表头、folder/file_name 处理规则都与 buildExportCsvBytes 完全相同，
// 后端无需任何改动即可识别。
// ════════════════════════════════════════════════════════════════════════

QByteArray RatingStore::buildArchiveExportCsvBytes(const QString& mode,
                                                   const QString& batchName,
                                                   const QStringList& folderPaths) const {
    QByteArray buf;
    if (mode.isEmpty() || mode == QStringLiteral("off")) return buf;
    if (!findMode(mode)) return buf;
    if (batchName.isEmpty()) return buf;

    // 归档批次的物理 CSV 路径（与 archiveBatchCsvIn 完全等价，但避免依赖
    // 后文匿名命名空间里的 helper —— 那些 helper 定义在本函数下方，
    // 这里就近内联拼路径，让前后函数体内的小工具相互独立、维护更简单）。
    const QString csvPath = QDir(QDir(QDir(m_baseDir).filePath(QStringLiteral("archive")))
                                     .filePath(mode))
                                .filePath(batchName)
                            + QStringLiteral("/ratings.csv");

    // 读批次 CSV：表头格式与主 CSV 一致（updated_at,rater,file_name,
    // file_path,file_size,quick_hash,stars），逐行解析。
    QList<QVariantMap> rows;
    {
        QFile f(csvPath);
        if (!f.exists()) return buf;
        if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return buf;
        QTextStream ts(&f);
        ts.setEncoding(QStringConverter::Utf8);
        bool firstLine = true;
        while (!ts.atEnd()) {
            QString line = ts.readLine();
            if (firstLine) { firstLine = false; continue; }
            if (line.trimmed().isEmpty()) continue;
            const QStringList cols = parseCsvLine(line);
            if (cols.size() < 7) continue;
            QVariantMap row;
            row["updated_at"] = cols.value(0);
            row["rater"]      = cols.value(1);
            row["file_name"]  = cols.value(2);
            row["file_path"]  = cols.value(3);
            row["stars"]      = cols.value(6).toInt();
            // 第8列 slide_type（向后兼容：旧归档无此列时为空）
            row["slide_type"] = cols.size() >= 8 ? cols.value(7) : QString();
            rows.push_back(row);
        }
    }

    QString rater = currentUser();
    if (rater.isEmpty()) rater = systemUserName();

    QSet<QString> allow;
    const bool filter = !folderPaths.isEmpty();
    if (filter) {
        for (const QString& p : folderPaths) {
            const QString k = normalizeFolderForMatch(p);
            if (k.isEmpty()) continue;
            allow.insert(k);
        }
    }

    QTextStream ts(&buf, QIODevice::WriteOnly);
    ts.setEncoding(QStringConverter::Utf8);
    ts.setGenerateByteOrderMark(true);
    ts << "updated_at,rater,folder,file_name,stars,slide_type,checklist\n";

    auto stripChannelPrefix = [](const QString& name) -> QString {
        int i = 0;
        while (i < name.size() && i < 3 && name.at(i).isDigit()) ++i;
        if (i > 0 && i < name.size() && name.at(i) == QLatin1Char('_')) {
            return name.mid(i + 1);
        }
        return name;
    };

    // ── Checklist 数据源（归档场景）──────────────────────────────────
    // 优先从批次目录下的 checklist.json（QML 归档时写入的 snapshot）读，
    // 结构：{"<file_path>": ["key1","key2", ...], ...}
    // 若该 file_path 在 snapshot 里没有条目 → 回退到 QSettings 现值
    // （用户可能归档后又勾选/取消了本地的同名文件，snapshot 优先能保证与归档瞬间一致）。
    QHash<QString, QString> checklistSnapshot;
    {
        const QString ckJsonPath = QDir(QDir(QDir(m_baseDir).filePath(QStringLiteral("archive")))
                                            .filePath(mode))
                                       .filePath(batchName)
                                   + QStringLiteral("/checklist.json");
        QFile jf(ckJsonPath);
        if (jf.exists() && jf.open(QIODevice::ReadOnly | QIODevice::Text)) {
            QJsonParseError je{};
            const QJsonDocument doc = QJsonDocument::fromJson(jf.readAll(), &je);
            if (je.error == QJsonParseError::NoError && doc.isObject()) {
                const QJsonObject obj = doc.object();
                for (auto it = obj.begin(); it != obj.end(); ++it) {
                    if (!it.value().isArray()) continue;
                    QStringList keys;
                    const QJsonArray arr = it.value().toArray();
                    keys.reserve(arr.size());
                    for (const auto& v : arr) {
                        const QString k = v.toString();
                        if (!k.isEmpty()) keys.push_back(k);
                    }
                    checklistSnapshot.insert(it.key(), keys.join(QLatin1Char(',')));
                }
            }
        }
    }
    auto readChecklistCsvCell = [this, &checklistSnapshot](const QString& filePath) -> QString {
        if (filePath.isEmpty()) return QString();
        // 快照命中：将逗号连接后的字符串再拆回 keys 走过滤
        auto it = checklistSnapshot.constFind(filePath);
        if (it != checklistSnapshot.constEnd()) {
            const QStringList snapKeys = it.value().split(QLatin1Char(','),
                                                          Qt::SkipEmptyParts);
            return this->filterChecklistKeysForExport(snapKeys);
        }
        // 回退：QSettings 现值
        QSettings s;
        const QString raw = s.value(QStringLiteral("checklist:") + filePath).toString();
        if (raw.isEmpty()) return this->filterChecklistKeysForExport(QStringList{});
        QJsonParseError err{};
        const QJsonDocument doc = QJsonDocument::fromJson(raw.toUtf8(), &err);
        if (err.error != QJsonParseError::NoError || !doc.isArray()) {
            return this->filterChecklistKeysForExport(QStringList{});
        }
        const QJsonArray arr = doc.array();
        QStringList keys;
        keys.reserve(arr.size());
        for (const auto& v : arr) {
            const QString k = v.toString();
            if (!k.isEmpty()) keys.push_back(k);
        }
        return this->filterChecklistKeysForExport(keys);
    };

    for (const auto& r : rows) {
        const QString fp = r.value("file_path").toString();
        if (filter) {
            if (fp.isEmpty()) continue;
            const QString dir = QDir::cleanPath(QFileInfo(fp).absolutePath());
            if (!allow.contains(dir)) continue;
        }
        const QString rawTs = r.value("updated_at").toString();
        QDateTime dt = QDateTime::fromString(rawTs, Qt::ISODateWithMs);
        if (!dt.isValid()) dt = QDateTime::fromString(rawTs, Qt::ISODate);
        const QString prettyTs = dt.isValid()
                                     ? dt.toString("yyyy-MM-dd HH:mm:ss")
                                     : rawTs;

        // folder = file_path 所在目录的末三级路径（与 buildExportCsvBytes 一致）
        const QString folder = folderDisplayName(fp);

        const QString fileName =
            stripChannelPrefix(r.value("file_name").toString());

        ts << csvEscape(prettyTs)                          << ","
           << csvEscape(rater)                             << ","
           << csvEscape(folder)                            << ","
           << csvEscape(fileName)                          << ","
           << r.value("stars").toInt()                     << ","
           << csvEscape(r.value("slide_type").toString())  << ","
           << csvEscape(readChecklistCsvCell(fp))          << "\n";
    }
    ts.flush();
    return buf;
}

// ═════════════════════════════════════════════════════════════════════
// 上传：读取配置 → 拼 multipart → POST → 信号带出结果
// ═════════════════════════════════════════════════════════════════════

QString RatingStore::uploadServerUrl() const {
    // 【开发者 override 优先】：环境变量 PLAYERX_UPLOAD_URL_DEV 命中时，
    // 直接返回内存态 URL，不读 QSettings；这样即使 QSettings 里存着正式 URL，
    // 开发/联调期间 UI/上传/维度 API 全部走 dev URL。
    if (m_uploadUrlOverridden) return m_uploadUrlOverride.trimmed();
    QSettings s;
    return s.value(kSettingsUploadUrlKey).toString().trimmed();
}

void RatingStore::setUploadServerUrl(const QString& url) {
    // 【开发者 override 保护】：命中 override 时忽略任何来源的写入（远端 latest.json、
    // 用户 UI 里改的、旧版持久化恢复），保证进程期内 uploadServerUrl 稳定不被抢走。
    // 仍然发一次 uploadConfigChanged 通知，让 UI 刷新，但底层值不变。
    if (m_uploadUrlOverridden) {
        emit uploadConfigChanged();
        return;
    }
    QSettings s;
    QString trimmed = url.trimmed();
    if (s.value(kSettingsUploadUrlKey).toString() == trimmed) return;
    s.setValue(kSettingsUploadUrlKey, trimmed);
    s.sync();
    emit uploadConfigChanged();
}

QString RatingStore::uploadToken() const {
    // 【开发者 override 优先】：URL override 生效时，token 也走内存态，
    // 允许 dev token 为空（例如后端未启用 PLAYERX_TOKEN），此时返回空串即可。
    if (m_uploadUrlOverridden) return m_uploadTokenOverride;
    QSettings s;
    return s.value(kSettingsUploadTokKey).toString();
}

void RatingStore::setUploadToken(const QString& token) {
    // 【开发者 override 保护】：与 URL 相同的短路策略。
    if (m_uploadUrlOverridden) {
        emit uploadConfigChanged();
        return;
    }
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
    // 用户经常只填基址（如 http://host:2026 或 http://host:2026/），并不带 /upload 路径。
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

    // 把 multipart 装配 + 网络发送 + reply 解析全部走共享路径，
    // 当前 Tab 上传与归档批次上传仅在 csvBytes / fileNameTag 上有区别。
    // 但在真正发 multipart 之前，先用一次 HEAD 探活判断后端是否存活——
    // 这样用户不需要等到 30s 上传超时才知道"服务根本没启"。
    probeServerThenPost(modeNow, csvBytes, /*fileNameTag*/ modeNow, force);
}

// ════════════════════════════════════════════════════════════════════════
// 上传归档批次（与 uploadToCloud 共用网络栈与状态机；CSV 数据源换成归档）
// ════════════════════════════════════════════════════════════════════════

void RatingStore::uploadArchiveBatchToCloud(const QString& mode,
                                            const QString& batchName,
                                            bool force,
                                            const QStringList& folderPaths) {
    if (m_uploading) {
        emit uploadFinished(false, tr("已有上传任务进行中，请稍后重试"));
        return;
    }
    const QString modeNow = mode.isEmpty() ? currentMode() : mode;
    if (modeNow.isEmpty() || modeNow == QStringLiteral("off")) {
        emit uploadFinished(false, tr("当前为「不评分」模式，无可上传的评分数据"));
        return;
    }
    if (!findMode(modeNow)) {
        emit uploadFinished(false, tr("未知的评分模式：%1").arg(modeNow));
        return;
    }
    if (batchName.trimmed().isEmpty()) {
        emit uploadFinished(false, tr("未指定归档批次，无法上传"));
        return;
    }
    // 必填校验：评分人 / tag —— 与当前 Tab 上传保持一致语义，
    // 避免“归档上传绕过身份校验”导致云端数据无法溯源。
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
    // URL 校验：尽早拦截配置缺失，避免拼好 multipart 后才发现没地方发。
    const QString url = uploadServerUrl();
    if (url.isEmpty()) {
        emit uploadFinished(false, tr("未配置上传地址，请先填写服务器 URL"));
        return;
    }
    {
        QUrl u(url);
        if (!u.isValid() || (u.scheme() != "http" && u.scheme() != "https")) {
            emit uploadFinished(false, tr("服务器地址不合法（需以 http:// 或 https:// 开头）"));
            return;
        }
    }

    const QByteArray csvBytes = buildArchiveExportCsvBytes(modeNow, batchName, folderPaths);
    bool csvEmpty = csvBytes.isEmpty();
    if (!csvEmpty) {
        int dataLines = csvBytes.count('\n') - 1;
        if (dataLines <= 0) csvEmpty = true;
    }
    if (csvEmpty) {
        if (!folderPaths.isEmpty()) {
            emit uploadFinished(false, tr("勾选的文件夹下没有可上传的归档记录"));
        } else {
            emit uploadFinished(false, tr("该归档批次为空，无需上传"));
        }
        return;
    }

    // 文件名加批次后缀，方便后端落盘后人工区分是哪个归档；
    // mode 表单字段仍只填 modeNow，与 (user, tag, mode) 唯一性键一致——也就是说：
    // “同一评分人 + 同一 tag + 同一模式” 上传当前 / 归档都会触发覆盖确认，
    // 让用户主动选择是覆盖云端旧数据还是先改 tag 再传，行为可预测。
    const QString fileNameTag = QStringLiteral("%1__%2").arg(modeNow, batchName);
    // 与当前 Tab 上传一致：先做 HEAD 探活，避免后端没启时用户等 30s 才知道。
    probeServerThenPost(modeNow, csvBytes, fileNameTag, force);
}

// ════════════════════════════════════════════════════════════════════════
// 上传前探活：HEAD <url>，5s 超时；通过则继续 postCsvBytesToServer
// ════════════════════════════════════════════════════════════════════════
//
// 设计要点：
//   1) 把 m_uploading 在探活阶段就置 true，让 QML 的"上传按钮置灰 + 文案变上传中"
//      立刻生效，给用户即时反馈；探活失败时再复位。
//   2) 任何"端口可达"的响应（含 404/405/任何 HTTP 状态码）都视作探活通过——
//      因为我们只想确认"服务进程在监听"，HEAD 是不是路由匹配并不重要。
//   3) 真·失败（连接拒绝 / DNS 失败 / 超时 / TLS 失败）才走 [NET] 失败信号；
//      QML 端识别 [NET] 前缀弹模态错误对话框。
//   4) 5 秒超时是体感临界值：太短可能误判内网慢链路，太长违背"探活"目的。
void RatingStore::probeServerThenPost(const QString& modeNow,
                                      const QByteArray& csvBytes,
                                      const QString& fileNameTag,
                                      bool force) {
    // URL 归一化：与 postCsvBytesToServer 中保持一致，避免探活地址与上传地址不一致。
    QUrl u(uploadServerUrl());
    {
        QString path = u.path();
        if (path.isEmpty() || path == "/") {
            u.setPath("/upload");
        } else if (path.size() > 1 && path.endsWith('/')) {
            u.setPath(path.left(path.size() - 1));
        }
    }

    if (!m_nam) m_nam = new QNetworkAccessManager(this);

    QNetworkRequest req(u);
    req.setRawHeader("User-Agent", "PlayerX-Uploader/1.0 (probe)");
    const QString tok = uploadToken();
    if (!tok.isEmpty()) req.setRawHeader("X-Token", tok.toUtf8());
    // 5s 短超时：保证用户在"后端没启"时最多等 5 秒就能拿到反馈。
    req.setTransferTimeout(5 * 1000);

    // 进入"上传中"状态：UI 立刻置灰防连点；探活失败再复位。
    m_uploading = true;
    emit uploadingChanged();
    emit uploadStarted();

    // 用 sendCustomRequest("HEAD", ...) 而非 head()——某些后端对 head() 默认实现不友好；
    // 但 head() 与 sendCustomRequest 行为本质相同，这里使用 head() 简单稳定。
    QNetworkReply* probe = m_nam->head(req);

    // 把上下文捕获进 lambda：成功时再发起实际 multipart 上传。
    QObject::connect(probe, &QNetworkReply::finished, this,
                     [this, probe, modeNow, csvBytes, fileNameTag, force, urlStr = u.toString()]() {
        const int httpCode = probe->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QNetworkReply::NetworkError err = probe->error();
        probe->deleteLater();

        // 端口通：拿到任何 HTTP 状态码就算通过（哪怕 404/405），继续走真实上传。
        // 但需要避开"端口通但 TLS 握手失败 / 协议不对"这类硬错——
        //   · 这种情况下 httpCode 不会有值，err 会是 SslHandshakeFailedError 等；
        //   · 用 httpCode > 0 作为"拿到 HTTP 响应"的判定标准最稳。
        if (httpCode > 0) {
            // 探活只是前哨，把 m_uploading 交还给真正的上传链路接管——
            // 先复位再调 postCsvBytesToServer，由后者重新置 true，避免状态被双重 emit。
            m_uploading = false;
            emit uploadingChanged();
            postCsvBytesToServer(modeNow, csvBytes, fileNameTag, force);
            return;
        }

        // 失败：把 Qt 的网络错误码翻译成给人看的文案，覆盖最常见的几种场景。
        QString reason;
        switch (err) {
            case QNetworkReply::ConnectionRefusedError:
                reason = tr("连接被拒绝（后端服务可能未启动，或端口不对）");
                break;
            case QNetworkReply::HostNotFoundError:
                reason = tr("找不到主机（请检查 URL 中的域名 / IP）");
                break;
            case QNetworkReply::RemoteHostClosedError:
                reason = tr("远端主动断开连接");
                break;
            case QNetworkReply::TimeoutError:
            case QNetworkReply::OperationCanceledError:
                reason = tr("连接超时（5s 内未收到响应，请检查服务器是否启动 / 网络是否通畅）");
                break;
            case QNetworkReply::SslHandshakeFailedError:
                reason = tr("TLS/SSL 握手失败（证书是否正确？或 URL 是否应改为 http://）");
                break;
            case QNetworkReply::UnknownNetworkError:
            case QNetworkReply::UnknownServerError:
                reason = tr("未知网络错误");
                break;
            default:
                reason = probe->errorString();
                if (reason.isEmpty()) reason = tr("网络不可达");
                break;
        }

        // [NET] 前缀给 QML 端用来识别"是否走模态错误对话框"。
        const QString message = QStringLiteral("[NET] ")
                + tr("无法连接到上传服务器：%1\n地址：%2\n\n"
                     "请检查：\n"
                     "  1) 后端服务是否已启动？\n"
                     "  2) 服务器 URL 是否正确？\n"
                     "  3) 本机网络 / 防火墙是否允许该端口？")
                  .arg(reason).arg(urlStr);

        m_uploading = false;
        emit uploadingChanged();
        emit uploadFinished(false, message);
    });
}

// ════════════════════════════════════════════════════════════════════════
// 共享上传发送：拼 multipart、设置头、发起 POST、绑定 finished 回调
// ════════════════════════════════════════════════════════════════════════

void RatingStore::postCsvBytesToServer(const QString& modeNow,
                                       const QByteArray& csvBytes,
                                       const QString& fileNameTag,
                                       bool force) {
    // URL 归一化（与历史行为完全一致）：
    //   - path 为空 / "/"  → 补 "/upload"
    //   - path 末尾误带 "/" → 去掉
    QUrl u(uploadServerUrl());
    {
        QString path = u.path();
        if (path.isEmpty() || path == "/") {
            u.setPath("/upload");
        } else if (path.size() > 1 && path.endsWith('/')) {
            u.setPath(path.left(path.size() - 1));
        }
    }

    // rater / tag 已经在调用方校验通过，这里直接读用即可。
    const QString rater  = currentUser().trimmed();
    const QString tagVal = uploadTag().trimmed();

    if (!m_nam) m_nam = new QNetworkAccessManager(this);

    auto* multi = new QHttpMultiPart(QHttpMultiPart::FormDataType);

    // file 字段：文件名携带 fileNameTag（mode 或 "<mode>__<batch>"），
    // 让后端 / 运维一眼识别是主观评分 / 质量比较 / 哪一个归档批次。
    QHttpPart filePart;
    QString fileName = QStringLiteral("playerx_%1_%2_%3.csv")
                           .arg(rater.isEmpty() ? QStringLiteral("anon") : rater)
                           .arg(fileNameTag)
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

    // client 字段：应用名+版本，服务端可记录以供审计
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

    // tag 字段
    {
        QHttpPart p;
        p.setHeader(QNetworkRequest::ContentDispositionHeader,
                    QVariant("form-data; name=\"tag\""));
        p.setBody(tagVal.toUtf8());
        multi->append(p);
    }
    // mode 字段：让后端可按模式分桶
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
    req.setTransferTimeout(30 * 1000);

    QNetworkReply* reply = m_nam->post(req, multi);
    multi->setParent(reply);   // reply 析构时一起释放 multipart

    m_uploading = true;
    emit uploadingChanged();
    emit uploadStarted();

    QObject::connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        const int httpCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();

        // 409 = (rater, tag, mode) 已存在 → 走 uploadConflict 信号，QML 弹覆盖确认
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
            QString trimmed = QString::fromUtf8(body).trimmed();
            if (trimmed.size() > 200) trimmed = trimmed.left(200) + QStringLiteral("…");
            message = tr("上传成功：%1").arg(trimmed.isEmpty() ? tr("已收到") : trimmed);
        } else {
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
        const QString k = normalizeFolderForMatch(p);
        if (k.isEmpty()) continue;
        allow.insert(k);
    }
    if (allow.isEmpty()) return false;

    const QList<QVariantMap> rows = readAll();
    QList<QVariantMap> kept;
    kept.reserve(rows.size());
    int removed = 0;
    for (const auto& r : rows) {
        const QString fp = r.value("file_path").toString();
        if (!fp.isEmpty()) {
            const QString dir = QDir::cleanPath(QFileInfo(fp).absolutePath());
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
// 归档目录布局（v2 — 按批次文件夹组织）
//
// 物理目录结构：
//   <AppData>/PlayerX/archive/
//   ├── subjective/
//   │   ├── 20260518_201906/
//   │   │   └── ratings.csv
//   │   └── v2.1_第一轮/
//   │       └── ratings.csv
//   └── quality/
//       └── ...
//
// 设计动机：
//   - 同一文件夹下的视频可被归档多次（例如先归档"v1 评分"，再重新打分后归档"v2 评分"），
//     按"文件夹"而非"单 CSV"组织，给同一视频多次评分留出共存空间；
//   - 一个批次一个独立目录，未来若要附带截图/元信息（report.json、screenshot/）也好扩展；
//   - 按 mode 隔离批次，避免主观评分和质量比较的批次混在同一下拉里。
// ════════════════════════════════════════════════════════════════════════

namespace {
// 归档根目录：<AppData>/PlayerX/archive
inline QString archiveRootIn(const QString& baseDir) {
    return QDir(baseDir).filePath(QStringLiteral("archive"));
}
// 归档某模式根目录：<AppData>/PlayerX/archive/<mode>
inline QString archiveModeDirIn(const QString& baseDir, const QString& mode) {
    return QDir(archiveRootIn(baseDir)).filePath(mode);
}
// 归档某批次目录：<AppData>/PlayerX/archive/<mode>/<batchName>
inline QString archiveBatchDirIn(const QString& baseDir,
                                 const QString& mode,
                                 const QString& batchName) {
    return QDir(archiveModeDirIn(baseDir, mode)).filePath(batchName);
}
// 归档某批次的 CSV 路径
inline QString archiveBatchCsvIn(const QString& baseDir,
                                 const QString& mode,
                                 const QString& batchName) {
    return QDir(archiveBatchDirIn(baseDir, mode, batchName))
                .filePath(QStringLiteral("ratings.csv"));
}
// 把用户输入的批次名清洗成跨平台合法的目录名
//   - 去掉首尾空白
//   - 把 / \\ : * ? " < > |  替换成 "_"
//   - 长度限制 80 字（防止文件路径超长）
//   - 全空白 → 退化为 "_unnamed"
QString sanitizeBatchName(const QString& raw) {
    QString s = raw.trimmed();
    if (s.isEmpty()) return QStringLiteral("_unnamed");
    static const QRegularExpression badChars(QStringLiteral("[\\/:*?\"<>|]"));
    s.replace(badChars, QStringLiteral("_"));
    if (s.size() > 80) s = s.left(80);
    if (s.trimmed().isEmpty()) s = QStringLiteral("_unnamed");
    return s;
}
// 从批次 CSV 中读所有行（与 RatingStore::readAll 同样的格式）
QList<QVariantMap> readBatchCsv(const QString& csvPath) {
    QList<QVariantMap> out;
    if (csvPath.isEmpty()) return out;
    QFile f(csvPath);
    if (!f.exists()) return out;
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return out;
    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);
    bool firstLine = true;
    while (!ts.atEnd()) {
        QString line = ts.readLine();
        if (firstLine) { firstLine = false; continue; }
        if (line.trimmed().isEmpty()) continue;
        QStringList cols = RatingStore::parseCsvLine(line);
        if (cols.size() < 7) continue;
        QVariantMap row;
        row["updated_at"] = cols.value(0);
        row["rater"]      = cols.value(1);
        row["file_name"]  = cols.value(2);
        row["file_path"]  = cols.value(3);
        row["file_size"]  = cols.value(4).toLongLong();
        row["quick_hash"] = cols.value(5);
        row["stars"]      = cols.value(6).toInt();
        // 第8/9列 slide_type/checklist（向后兼容：旧归档无这些列时留空）
        row["slide_type"] = cols.size() >= 8 ? cols.value(7) : QString();
        row["checklist"]  = cols.size() >= 9 ? cols.value(8) : QString();
        out.push_back(row);
    }
    return out;
}
// 把行集写入批次 CSV（覆盖式，含 BOM 与表头）
bool writeBatchCsv(const QString& csvPath, const QList<QVariantMap>& rows) {
    QFile f(csvPath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return false;
    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);
    ts.setGenerateByteOrderMark(true);
    ts << kCsvHeader << "\n";
    for (const auto& r : rows) {
        ts << RatingStore::csvEscape(r.value("updated_at").toString()) << ","
           << RatingStore::csvEscape(r.value("rater").toString())      << ","
           << RatingStore::csvEscape(r.value("file_name").toString())  << ","
           << RatingStore::csvEscape(r.value("file_path").toString())  << ","
           << r.value("file_size").toLongLong()                        << ","
           << RatingStore::csvEscape(r.value("quick_hash").toString()) << ","
           << r.value("stars").toInt()                                 << ","
           << RatingStore::csvEscape(r.value("slide_type").toString()) << ","
           << RatingStore::csvEscape(r.value("checklist").toString())  << "\n";
    }
    return true;
}
// 递归删除批次目录（连同 ratings.csv 与可能的附属文件）
bool removeBatchDir(const QString& baseDir, const QString& mode, const QString& batchName) {
    const QString dir = archiveBatchDirIn(baseDir, mode, batchName);
    QDir d(dir);
    if (!d.exists()) return true;       // 已经没有，视为成功
    return d.removeRecursively();
}
}  // namespace

// ════════════════════════════════════════════════════════════════════════
// 按文件夹批量归档（v2 — 写到 archive/<mode>/<batchName>/ratings.csv）
//
// 时序保证：先写好归档文件，再回写主 CSV。任一步失败都不会破坏主 CSV。
// ════════════════════════════════════════════════════════════════════════

bool RatingStore::archiveByFolders(const QStringList& folderPaths,
                                   const QString& batchName) {
    // 与 removeByFolders 同样的入参校验
    QSet<QString> allow;
    for (const QString& p : folderPaths) {
        const QString k = normalizeFolderForMatch(p);
        if (k.isEmpty()) continue;
        allow.insert(k);
    }
    if (allow.isEmpty()) return false;

    const QString modeNow = currentMode();
    if (modeNow.isEmpty() || modeNow == QStringLiteral("off")) return false;

    // 命中筛选
    const QList<QVariantMap> rows = readAll();
    QList<QVariantMap> kept;
    QList<QVariantMap> picked;
    kept.reserve(rows.size());
    picked.reserve(rows.size());
    for (const auto& r : rows) {
        const QString fp = r.value("file_path").toString();
        if (!fp.isEmpty()) {
            const QString dir = QDir::cleanPath(QFileInfo(fp).absolutePath());
            if (allow.contains(dir)) { picked.push_back(r); continue; }
        }
        kept.push_back(r);
    }
    if (picked.isEmpty()) return false;

    // 计算批次目录名（用户给空 → 用默认时间戳；同名追加 _N 序号防覆盖）
    QString batch = sanitizeBatchName(
        batchName.isEmpty() ? defaultArchiveBatchName(modeNow) : batchName);
    {
        const QString modeDir = archiveModeDirIn(m_baseDir, modeNow);
        if (!QDir().mkpath(modeDir)) return false;
        QString candidate = batch;
        int suffix = 2;
        while (QFileInfo::exists(QDir(modeDir).filePath(candidate))) {
            candidate = QStringLiteral("%1_%2").arg(batch).arg(suffix++);
        }
        batch = candidate;
    }

    const QString batchDir = archiveBatchDirIn(m_baseDir, modeNow, batch);
    if (!QDir().mkpath(batchDir)) return false;
    const QString archivePath = archiveBatchCsvIn(m_baseDir, modeNow, batch);

    // 先写归档（先成功，后再删主 CSV，保证失败不破坏数据）
    if (!writeBatchCsv(archivePath, picked)) return false;

    // 回写主 CSV：失败时尝试删除已生成的归档文件，避免出现“数据双份在两个文件”的歧义
    if (!writeAll(kept)) {
        QFile::remove(archivePath);
        QDir(batchDir).removeRecursively();
        return false;
    }
    emit changed();
    return true;
}

// 推荐的默认批次名：<mode>_yyyyMMdd_HHmmss
QString RatingStore::defaultArchiveBatchName(const QString& mode) const {
    const QString m = mode.isEmpty() ? currentMode() : mode;
    const QString tag = (m.isEmpty() || m == QStringLiteral("off")) ? QStringLiteral("rating") : m;
    return QStringLiteral("%1_%2").arg(
        tag, QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss"));
}

// 列出指定模式下所有归档批次（按 modifiedAt 倒序）
QVariantList RatingStore::listArchiveBatches(const QString& mode) const {
    QVariantList out;
    const QString m = mode.isEmpty() ? currentMode() : mode;
    if (m.isEmpty() || m == QStringLiteral("off")) return out;
    if (!findMode(m)) return out;

    const QString modeDir = archiveModeDirIn(m_baseDir, m);
    QDir d(modeDir);
    if (!d.exists()) return out;

    const QFileInfoList subs = d.entryInfoList(
        QDir::Dirs | QDir::NoDotAndDotDot, QDir::Time);   // QDir::Time = 修改时间倒序

    for (const QFileInfo& sub : subs) {
        const QString name = sub.fileName();
        const QString csv  = archiveBatchCsvIn(m_baseDir, m, name);
        if (!QFileInfo::exists(csv)) continue;       // 没有 ratings.csv 的目录跳过

        const QList<QVariantMap> rows = readBatchCsv(csv);
        QString latest;
        QSet<QString> raterSet;
        for (const auto& r : rows) {
            const QString u = r.value("updated_at").toString();
            if (u > latest) latest = u;
            const QString rt = r.value("rater").toString();
            if (!rt.isEmpty()) raterSet.insert(rt);
        }
        QStringList raters = raterSet.values();
        std::sort(raters.begin(), raters.end());

        QVariantMap entry;
        entry["name"]       = name;
        entry["path"]       = csv;
        entry["count"]      = rows.size();
        entry["latest"]     = latest;
        entry["raters"]     = raters;
        entry["modifiedAt"] = sub.lastModified().toString(Qt::ISODate);
        out.push_back(entry);
    }
    return out;
}

// 读取某批次 CSV 的所有行（updated_at 倒序）
QVariantList RatingStore::loadArchiveBatch(const QString& mode,
                                           const QString& batchName) const {
    QVariantList out;
    const QString m = mode.isEmpty() ? currentMode() : mode;
    if (m.isEmpty() || m == QStringLiteral("off") || batchName.isEmpty()) return out;
    if (!findMode(m)) return out;

    const QString csv = archiveBatchCsvIn(m_baseDir, m, batchName);
    QList<QVariantMap> rows = readBatchCsv(csv);
    std::sort(rows.begin(), rows.end(), [](const QVariantMap& a, const QVariantMap& b) {
        return a.value("updated_at").toString() > b.value("updated_at").toString();
    });
    for (const auto& r : rows) out.push_back(r);
    return out;
}

// 删除某批次（连目录一起删）
bool RatingStore::deleteArchiveBatch(const QString& mode, const QString& batchName) {
    const QString m = mode.isEmpty() ? currentMode() : mode;
    if (m.isEmpty() || m == QStringLiteral("off") || batchName.isEmpty()) return false;
    if (!findMode(m)) return false;

    const bool ok = removeBatchDir(m_baseDir, m, batchName);
    if (ok) emit changed();
    return ok;
}

// 行级删除：从某批次 CSV 中按 file_path 白名单删行
bool RatingStore::removeArchiveRows(const QString& mode,
                                    const QString& batchName,
                                    const QStringList& filePathsToRemove) {
    const QString m = mode.isEmpty() ? currentMode() : mode;
    if (m.isEmpty() || m == QStringLiteral("off") || batchName.isEmpty()) return false;
    if (!findMode(m)) return false;
    if (filePathsToRemove.isEmpty()) return true;   // 没要删任何行 → 视为成功 no-op

    QSet<QString> drop;
    for (const QString& fp : filePathsToRemove) {
        const QString t = fp.trimmed();
        if (!t.isEmpty()) drop.insert(t);
    }
    if (drop.isEmpty()) return true;

    const QString csv = archiveBatchCsvIn(m_baseDir, m, batchName);
    if (!QFileInfo::exists(csv)) return false;

    const QList<QVariantMap> rows = readBatchCsv(csv);
    QList<QVariantMap> kept;
    kept.reserve(rows.size());
    int removed = 0;
    for (const auto& r : rows) {
        if (drop.contains(r.value("file_path").toString())) {
            ++removed;
            continue;
        }
        kept.push_back(r);
    }
    if (removed == 0) return true;   // 没命中也算成功

    if (kept.isEmpty()) {
        // 删空了 → 整个批次目录一并清掉，避免下拉里残留
        if (!removeBatchDir(m_baseDir, m, batchName)) return false;
    } else {
        if (!writeBatchCsv(csv, kept)) return false;
    }
    emit changed();
    return true;
}

// 把某归档批次另存为单 CSV（精简列：updated_at,rater,file_name,stars）
bool RatingStore::exportArchiveBatch(const QString& mode,
                                     const QString& batchName,
                                     const QString& targetPath) const {
    const QString m = mode.isEmpty() ? currentMode() : mode;
    if (m.isEmpty() || m == QStringLiteral("off") || batchName.isEmpty()) return false;
    if (!findMode(m)) return false;
    if (targetPath.isEmpty()) return false;

    const QString csv = archiveBatchCsvIn(m_baseDir, m, batchName);
    const QList<QVariantMap> rows = readBatchCsv(csv);

    QFile f(targetPath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return false;
    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);
    ts.setGenerateByteOrderMark(true);
    ts << "updated_at,rater,file_name,stars\n";
    for (const auto& r : rows) {
        QString upd = r.value("updated_at").toString();
        QDateTime dt = QDateTime::fromString(upd, Qt::ISODate);
        if (dt.isValid()) upd = dt.toString("yyyy-MM-dd HH:mm:ss");
        ts << csvEscape(upd) << ","
           << csvEscape(r.value("rater").toString())     << ","
           << csvEscape(r.value("file_name").toString()) << ","
           << r.value("stars").toInt()                   << "\n";
    }
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
// 在系统文件管理器中打开归档目录（archive/）。目录不存在时自动建立，
// 让用户即使一次都没归档过也能"先看一眼归档目录在哪"。
// ════════════════════════════════════════════════════════════════════════

void RatingStore::revealArchiveFolder(const QString& mode) const {
    const QString root = archiveRootIn(m_baseDir);
    QDir().mkpath(root);
    QString target = root;
    const QString m = mode.trimmed();
    if (!m.isEmpty() && m != QStringLiteral("off") && findMode(m)) {
        const QString sub = archiveModeDirIn(m_baseDir, m);
        QDir().mkpath(sub);
        target = sub;
    }
    QDesktopServices::openUrl(QUrl::fromLocalFile(target));
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
        ts << csvEscape(r.value("updated_at").toString())  << ","
           << csvEscape(r.value("rater").toString())       << ","
           << csvEscape(r.value("file_name").toString())   << ","
           << csvEscape(r.value("file_path").toString())   << ","
           << r.value("file_size").toLongLong()            << ","
           << csvEscape(r.value("quick_hash").toString())  << ","
           << r.value("stars").toInt()                     << ","
           << csvEscape(r.value("slide_type").toString())  << ","
           << csvEscape(r.value("checklist").toString())   << "\n";
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
        // 第8列 slide_type（向后兼容：旧行无此列时视为 normal）
        row["slide_type"] = cols.size() >= 8 ? cols.value(7) : QString();
        // 第9列 checklist（向后兼容：旧行无此列时留空）
        row["checklist"]  = cols.size() >= 9 ? cols.value(8) : QString();
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
