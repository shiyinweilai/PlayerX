/**
 * ReferenceStore.cpp — 见 ReferenceStore.h
 */
#include "ReferenceStore.h"

#include <QByteArray>
#include <QCollator>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>
#include <QStringConverter>
#include <QTextStream>
#include <QUrl>
#include <algorithm>

namespace rbqt {

namespace {
const QStringList kImageExts = {
    "png", "jpg", "jpeg", "webp", "bmp", "gif"
};
const QStringList kVideoExts = {
    "mp4", "mov", "mkv", "avi", "webm", "flv", "ts", "m4v", "wmv",
    "mpg", "mpeg", "m2ts", "mts", "vob", "ogv", "3gp", "asf",
    "h264", "h265", "hevc", "264", "265", "y4m"
};

constexpr const char* kGroup = "references";

QString encodeKey(const QString& folder) {
    return QString::fromLatin1(folder.toUtf8().toBase64(QByteArray::OmitTrailingEquals));
}
QString decodeKey(const QString& key) {
    return QString::fromUtf8(QByteArray::fromBase64(key.toLatin1()));
}
bool inExtList(const QString& path, const QStringList& exts) {
    if (path.isEmpty()) return false;
    const QString suf = QFileInfo(path).suffix().toLower();
    if (suf.isEmpty()) return false;
    for (const auto& e : exts) {
        if (suf == e) return true;
    }
    return false;
}
} // namespace

// ════════════════════════════════════════════════════════════════════════
// 构造 / 析构
// ════════════════════════════════════════════════════════════════════════

ReferenceStore::ReferenceStore(QObject* parent) : QObject(parent) {
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (base.isEmpty()) {
        base = QDir::homePath() + "/.PlayerX";
    }
    QDir().mkpath(base);
    m_settingsFile = QDir(base).filePath("references.ini");

    loadFromDisk();
}

ReferenceStore::~ReferenceStore() = default;

// ════════════════════════════════════════════════════════════════════════
// 持久化
// ════════════════════════════════════════════════════════════════════════
//
// ini 结构（v3）：
//   [references]
//   <base64(folder)>\kind=image|folder
//   <base64(folder)>\path=...
//   <base64(folder)>\textKind=csv
//   <base64(folder)>\textPath=...
//
// 旧版本（v1 平铺、v2 仅 image/folder）会在 loadFromDisk 中静默兼容。

void ReferenceStore::loadFromDisk() {
    QSettings s(m_settingsFile, QSettings::IniFormat);
    s.beginGroup(kGroup);
    m_map.clear();

    const QStringList groups = s.childGroups();
    for (const QString& g : groups) {
        s.beginGroup(g);
        Entry e;
        e.kind     = s.value("kind", "").toString();
        e.path     = s.value("path", "").toString();
        e.kind2    = s.value("kind2", "").toString();
        e.path2    = s.value("path2", "").toString();
        e.textKind = s.value("textKind", "").toString();
        e.textPath = s.value("textPath", "").toString();
        s.endGroup();

        // 图片字段校验
        if (!e.path.isEmpty() && (e.kind != "image" && e.kind != "folder")) {
            e.kind.clear(); e.path.clear();
        }
        if (!e.path2.isEmpty() && (e.kind2 != "image" && e.kind2 != "folder")) {
            e.kind2.clear(); e.path2.clear();
        }
        // 文本字段校验
        if (!e.textPath.isEmpty() && e.textKind != "csv") {
            e.textKind.clear(); e.textPath.clear();
        }
        // 全部为空 → 跳过
        if (e.path.isEmpty() && e.path2.isEmpty() && e.textPath.isEmpty()) continue;

        const QString folder = decodeKey(g);
        if (folder.isEmpty()) continue;
        m_map.insert(folder, e);
    }

    // v1 兼容：旧版本平铺写法（[references] <base64>=path）
    const QStringList flatKeys = s.allKeys();
    for (const QString& k : flatKeys) {
        if (k.contains('/')) continue;
        const QString folder = decodeKey(k);
        if (folder.isEmpty()) continue;
        if (m_map.contains(folder)) continue;
        const QString v = s.value(k).toString();
        if (v.isEmpty()) continue;
        Entry e;
        e.kind = "image";
        e.path = v;
        m_map.insert(folder, e);
    }

    s.endGroup();
}

void ReferenceStore::saveToDisk() const {
    QSettings s(m_settingsFile, QSettings::IniFormat);
    s.beginGroup(kGroup);
    s.remove("");
    for (auto it = m_map.constBegin(); it != m_map.constEnd(); ++it) {
        const QString enc = encodeKey(it.key());
        const Entry& e = it.value();
        s.beginGroup(enc);
        if (!e.kind.isEmpty() && !e.path.isEmpty()) {
            s.setValue("kind", e.kind);
            s.setValue("path", e.path);
        }
        if (!e.kind2.isEmpty() && !e.path2.isEmpty()) {
            s.setValue("kind2", e.kind2);
            s.setValue("path2", e.path2);
        }
        if (!e.textKind.isEmpty() && !e.textPath.isEmpty()) {
            s.setValue("textKind", e.textKind);
            s.setValue("textPath", e.textPath);
        }
        s.endGroup();
    }
    s.endGroup();
    s.sync();
}

// ════════════════════════════════════════════════════════════════════════
// 内部工具
// ════════════════════════════════════════════════════════════════════════

QString ReferenceStore::normalizeFolder(const QString& folderPath) {
    if (folderPath.isEmpty()) return {};
    QString p = QDir::fromNativeSeparators(folderPath);
    while (p.endsWith('/') && p.size() > 1) p.chop(1);
    return p;
}

QString ReferenceStore::urlOrPathToLocal(const QString& s) {
    if (s.isEmpty()) return {};
    if (s.startsWith("file://")) {
        QUrl u(s);
        if (u.isLocalFile()) return u.toLocalFile();
    }
    return s;
}

bool ReferenceStore::isSupportedImage(const QString& path) const {
    return inExtList(path, kImageExts);
}

QStringList ReferenceStore::listImages(const QString& dir) {
    QStringList out;
    QFileInfo fi(dir);
    if (!fi.exists() || !fi.isDir()) return out;
    QDirIterator it(dir,
                    QDir::Files | QDir::NoDotAndDotDot | QDir::Readable,
                    QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        const QFileInfo f = it.fileInfo();
        if (!f.isFile()) continue;
        if (!inExtList(f.absoluteFilePath(), kImageExts)) continue;
        out << f.absoluteFilePath();
    }
    // 自然序（1 < 2 < 10），与预览/帧号顺序一致
    {
        QCollator coll;
        coll.setNumericMode(true);
        coll.setCaseSensitivity(Qt::CaseInsensitive);
        std::sort(out.begin(), out.end(),
                  [&coll](const QString& a, const QString& b) {
                      return coll.compare(a, b) < 0;
                  });
    }
    return out;
}

QStringList ReferenceStore::listVideos(const QString& dir) {
    QStringList out;
    QFileInfo fi(dir);
    if (!fi.exists() || !fi.isDir()) return out;
    QDirIterator it(dir,
                    QDir::Files | QDir::NoDotAndDotDot | QDir::Readable,
                    QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        const QFileInfo f = it.fileInfo();
        if (!f.isFile()) continue;
        if (!inExtList(f.absoluteFilePath(), kVideoExts)) continue;
        out << f.absoluteFilePath();
    }
    // 自然序（1 < 2 < 10），与 Finder/Explorer 一致
    {
        QCollator coll;
        coll.setNumericMode(true);
        coll.setCaseSensitivity(Qt::CaseInsensitive);
        std::sort(out.begin(), out.end(),
                  [&coll](const QString& a, const QString& b) {
                      return coll.compare(a, b) < 0;
                  });
    }
    return out;
}

int ReferenceStore::videoCountInFolder(const QString& folderPath) const {
    // 直接复用 listVideos：实现一份扩展名/递归口径，避免上层各自重写出现不一致。
    // 注意：listVideos 是 static，所以 const 限定符不影响它的调用。
    if (folderPath.isEmpty()) return 0;
    return listVideos(folderPath).size();
}

QPair<int, int> ReferenceStore::videoIndexInDir(const QString& videoPath) {
    if (videoPath.isEmpty()) return {-1, 0};
    QFileInfo fi(videoPath);
    if (!fi.exists() || !fi.isFile()) return {-1, 0};
    const QString dir = fi.absolutePath();
    const QStringList vids = listVideos(dir);
    const int total = vids.size();
    if (total == 0) return {-1, 0};
    const QString abs = fi.absoluteFilePath();
    for (int i = 0; i < total; ++i) {
        if (vids[i].compare(abs, Qt::CaseInsensitive) == 0) {
            return {i, total};
        }
    }
    return {-1, total};
}

// ── CSV 解析（RFC4180 兼容）──────────────────────────────────────────────
//   - 支持 \r\n / \n / \r 三种行尾
//   - 支持双引号包裹的字段，字段内 "" 表示一个 "
//   - 支持字段内换行（含义同 RFC4180）
//   - 第一非空行作为表头；表头列名做 trim 与小写比较
QList<QVariantMap> ReferenceStore::parseCsv(const QString& csvPath) {
    QList<QVariantMap> rows;
    QFile f(csvPath);
    if (!f.open(QIODevice::ReadOnly)) return rows;
    QByteArray bytes = f.readAll();
    f.close();
    if (bytes.isEmpty()) return rows;

    // BOM / 编码识别（默认 UTF-8）
    QStringDecoder dec = QStringDecoder(QStringDecoder::Utf8);
    QString text = dec.decode(bytes);
    if (text.isEmpty()) return rows;

    // ── 状态机解析 ─────────────────────────────────────────────────
    QList<QStringList> records;          // 全部行
    QStringList curRow;                  // 当前行
    QString curField;                    // 当前字段
    bool inQuotes = false;
    const int n = text.size();
    for (int i = 0; i < n; ++i) {
        QChar c = text.at(i);
        if (inQuotes) {
            if (c == '"') {
                // 转义 "" → "
                if (i + 1 < n && text.at(i + 1) == '"') {
                    curField.append('"');
                    ++i;
                } else {
                    inQuotes = false;
                }
            } else {
                curField.append(c);
            }
        } else {
            if (c == '"') {
                inQuotes = true;
            } else if (c == ',') {
                curRow.append(curField);
                curField.clear();
            } else if (c == '\r') {
                // \r 或 \r\n 都算行尾
                curRow.append(curField);
                curField.clear();
                records.append(curRow);
                curRow.clear();
                if (i + 1 < n && text.at(i + 1) == '\n') ++i;
            } else if (c == '\n') {
                curRow.append(curField);
                curField.clear();
                records.append(curRow);
                curRow.clear();
            } else {
                curField.append(c);
            }
        }
    }
    // 文件末尾未换行的最后一字段 / 一行
    if (!curField.isEmpty() || !curRow.isEmpty()) {
        curRow.append(curField);
        records.append(curRow);
    }

    if (records.isEmpty()) return rows;

    // 找到第一非空行作为表头
    int headerIdx = -1;
    for (int i = 0; i < records.size(); ++i) {
        // 仅由空字段组成视为空
        bool empty = true;
        for (const auto& s : records[i]) {
            if (!s.trimmed().isEmpty()) { empty = false; break; }
        }
        if (!empty) { headerIdx = i; break; }
    }
    if (headerIdx < 0) return rows;

    QStringList headers;
    for (const auto& h : records[headerIdx]) headers << h.trimmed();

    for (int i = headerIdx + 1; i < records.size(); ++i) {
        const QStringList& r = records[i];
        // 全空行跳过
        bool empty = true;
        for (const auto& s : r) {
            if (!s.trimmed().isEmpty()) { empty = false; break; }
        }
        if (empty) continue;

        QVariantMap m;
        for (int j = 0; j < headers.size(); ++j) {
            const QString key = headers[j];
            const QString val = j < r.size() ? r[j] : QString();
            m.insert(key, val);
        }
        rows << m;
    }
    return rows;
}

// ════════════════════════════════════════════════════════════════════════
// (A) 参考图：通用查询
// ════════════════════════════════════════════════════════════════════════

QString ReferenceStore::kindOf(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = m_map.constFind(k);
    if (it == m_map.constEnd()) return {};
    if (it->kind == "image") {
        if (!QFileInfo::exists(it->path)) return {};
    } else if (it->kind == "folder") {
        QFileInfo fi(it->path);
        if (!fi.exists() || !fi.isDir()) return {};
    } else {
        return {};
    }
    return it->kind;
}

bool ReferenceStore::hasReference(const QString& folderPath) const {
    return !kindOf(folderPath).isEmpty();
}

QString ReferenceStore::referenceOf(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = m_map.constFind(k);
    if (it == m_map.constEnd()) return {};
    if (it->kind == "image" && !QFileInfo::exists(it->path)) return {};
    if (it->kind == "folder") {
        QFileInfo fi(it->path);
        if (!fi.exists() || !fi.isDir()) return {};
    }
    return it->path;
}

QUrl ReferenceStore::referenceUrlOf(const QString& folderPath) const {
    const QString p = referenceOf(folderPath);
    if (p.isEmpty()) return {};
    return QUrl::fromLocalFile(p);
}

QUrl ReferenceStore::referenceUrlForVideo(const QString& videoPath) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};

    const QString folder = normalizeFolder(fi.absolutePath());
    if (folder.isEmpty()) return {};

    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return {};

    if (it->kind == "image") {
        if (!QFileInfo::exists(it->path)) return {};
        return QUrl::fromLocalFile(it->path);
    }
    if (it->kind == "folder") {
        const QStringList imgs = listImages(it->path);
        if (imgs.isEmpty()) return {};
        auto idx = videoIndexInDir(videoPath);
        int useIdx = idx.first;
        if (useIdx < 0) useIdx = 0;
        if (useIdx >= imgs.size()) useIdx = imgs.size() - 1;
        return QUrl::fromLocalFile(imgs.at(useIdx));
    }
    return {};
}

QString ReferenceStore::referenceProgressForVideo(const QString& videoPath) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return {};
    if (it->kind != "folder") return {};

    const QStringList imgs = listImages(it->path);
    if (imgs.isEmpty()) return {};
    auto idx = videoIndexInDir(videoPath);
    int useIdx = idx.first < 0 ? 0 : idx.first;
    if (useIdx >= imgs.size()) useIdx = imgs.size() - 1;
    return QString::number(useIdx + 1) + " / " + QString::number(imgs.size());
}

// ── 偏移版 ───────────────────────────────────────────────────────────────
// 在"自动索引"基础上 +offset 取图；仅 folder 模式生效。
// image / 未绑定时退化为对应非偏移版（image 始终返回固定图，无所谓偏移）。
QUrl ReferenceStore::referenceUrlForVideoOffset(const QString& videoPath, int offset) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    const QString folder = normalizeFolder(fi.absolutePath());
    if (folder.isEmpty()) return {};
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return {};

    if (it->kind == "image") {
        if (!QFileInfo::exists(it->path)) return {};
        return QUrl::fromLocalFile(it->path);
    }
    if (it->kind == "folder") {
        const QStringList imgs = listImages(it->path);
        if (imgs.isEmpty()) return {};
        auto idx = videoIndexInDir(videoPath);
        int useIdx = idx.first < 0 ? 0 : idx.first;
        useIdx += offset;
        if (useIdx < 0) useIdx = 0;
        if (useIdx >= imgs.size()) useIdx = imgs.size() - 1;
        return QUrl::fromLocalFile(imgs.at(useIdx));
    }
    return {};
}

QString ReferenceStore::referenceProgressForVideoOffset(const QString& videoPath, int offset) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return {};
    if (it->kind != "folder") return {};

    const QStringList imgs = listImages(it->path);
    if (imgs.isEmpty()) return {};
    auto idx = videoIndexInDir(videoPath);
    int useIdx = idx.first < 0 ? 0 : idx.first;
    useIdx += offset;
    if (useIdx < 0) useIdx = 0;
    if (useIdx >= imgs.size()) useIdx = imgs.size() - 1;
    return QString::number(useIdx + 1) + " / " + QString::number(imgs.size());
}

int ReferenceStore::referenceImageCountForVideo(const QString& videoPath) const {
    if (videoPath.isEmpty()) return 0;
    QFileInfo fi(videoPath);
    if (!fi.exists()) return 0;
    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return 0;
    if (it->kind != "folder") return 0;
    return listImages(it->path).size();
}

// ════════════════════════════════════════════════════════════════════════
// (A) 参考图：写入
// ════════════════════════════════════════════════════════════════════════

bool ReferenceStore::setReference(const QString& folderPath, const QString& imagePath) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return false;
    const QString p = urlOrPathToLocal(imagePath);
    if (p.isEmpty()) return false;
    if (!isSupportedImage(p)) return false;
    if (!QFileInfo::exists(p)) return false;

    Entry e = m_map.value(k);  // 保留文本字段
    e.kind = "image"; e.path = p;
    m_map.insert(k, e);
    saveToDisk();
    emit referenceChanged(k);
    return true;
}

bool ReferenceStore::setReferenceUrl(const QString& folderPath, const QUrl& imageUrl) {
    QString p;
    if (imageUrl.isLocalFile()) p = imageUrl.toLocalFile();
    else p = imageUrl.toString();
    return setReference(folderPath, p);
}

bool ReferenceStore::setReferenceFolder(const QString& folderPath, const QString& imageDir) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return false;
    const QString d = normalizeFolder(urlOrPathToLocal(imageDir));
    if (d.isEmpty()) return false;
    QFileInfo fi(d);
    if (!fi.exists() || !fi.isDir()) return false;
    if (listImages(d).isEmpty()) return false;

    Entry e = m_map.value(k);
    e.kind = "folder"; e.path = d;
    m_map.insert(k, e);
    saveToDisk();
    emit referenceChanged(k);
    return true;
}

bool ReferenceStore::setReferenceFolderUrl(const QString& folderPath, const QUrl& imageDirUrl) {
    QString p;
    if (imageDirUrl.isLocalFile()) p = imageDirUrl.toLocalFile();
    else p = imageDirUrl.toString();
    return setReferenceFolder(folderPath, p);
}

void ReferenceStore::clearReference(const QString& folderPath) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return;
    if (!m_map.contains(k)) return;
    Entry& e = m_map[k];
    e.kind.clear(); e.path.clear();
    if (e.kind2.isEmpty() && e.path2.isEmpty()
        && e.textKind.isEmpty() && e.textPath.isEmpty()) {
        m_map.remove(k);
    }
    saveToDisk();
    emit referenceChanged(k);
}

// ════════════════════════════════════════════════════════════════════════
// (B) 参考文本：CSV
// ════════════════════════════════════════════════════════════════════════

QString ReferenceStore::textKindOf(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = m_map.constFind(k);
    if (it == m_map.constEnd()) return {};
    if (it->textKind != "csv") return {};
    if (!QFileInfo::exists(it->textPath)) return {};
    return it->textKind;
}

bool ReferenceStore::hasText(const QString& folderPath) const {
    return !textKindOf(folderPath).isEmpty();
}

QString ReferenceStore::textPathOf(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = m_map.constFind(k);
    if (it == m_map.constEnd()) return {};
    if (!QFileInfo::exists(it->textPath)) return {};
    return it->textPath;
}

QVariantMap ReferenceStore::referenceTextForVideo(const QString& videoPath) const {
    return referenceTextForVideoOffset(videoPath, 0);
}

// ── 偏移版 ───────────────────────────────────────────────────────────────
// 在"自动索引"基础上 +offset 取行；仅 csv 模式生效。
// 越界自动夹紧到 [0, M-1]；未绑定 / 无行 → 返回空 map。
QVariantMap ReferenceStore::referenceTextForVideoOffset(const QString& videoPath, int offset) const {
    QVariantMap out;
    if (videoPath.isEmpty()) return out;
    QFileInfo fi(videoPath);
    if (!fi.exists()) return out;

    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return out;
    if (it->textKind != "csv") return out;
    if (!QFileInfo::exists(it->textPath)) return out;

    const QList<QVariantMap> rows = parseCsv(it->textPath);
    if (rows.isEmpty()) return out;

    // 取视频在文件夹中的序号 + offset，并钳制到 [0, M-1]
    auto idx = videoIndexInDir(videoPath);
    int useIdx = idx.first < 0 ? 0 : idx.first;
    useIdx += offset;
    if (useIdx < 0) useIdx = 0;
    if (useIdx >= rows.size()) useIdx = rows.size() - 1;

    const QVariantMap& row = rows.at(useIdx);

    // 列名归一化匹配（大小写不敏感、容忍前后空格）
    QString zh, en, image, raw;
    for (auto rit = row.constBegin(); rit != row.constEnd(); ++rit) {
        const QString key = rit.key().trimmed().toLower();
        const QString val = rit.value().toString();
        if (key == "prompt" || key == "zh" || key == "zh_prompt" || key == "中文" || key == QString::fromUtf8("中文prompt")) {
            zh = val;
        } else if (key == "en_prompt" || key == "en" || key == "english" || key == "english_prompt") {
            en = val;
        } else if (key == "image" || key == "img" || key == "图片" || key == "filename") {
            image = val;
        }
        // raw 拼接：以 "列名: 值" 形式（仅当存在多列时使用）
        if (!val.trimmed().isEmpty()) {
            if (!raw.isEmpty()) raw += "\n\n";
            raw += rit.key() + ": " + val;
        }
    }
    // 兜底：若没有任何已识别列，但有数据 → 把第一个非空字段当 zh
    if (zh.isEmpty() && en.isEmpty()) {
        for (auto rit = row.constBegin(); rit != row.constEnd(); ++rit) {
            const QString val = rit.value().toString();
            if (!val.trimmed().isEmpty()) { zh = val; break; }
        }
    }

    out.insert("image", image);
    out.insert("zh", zh);
    out.insert("en", en);
    out.insert("raw", raw);
    out.insert("row", useIdx + 1);
    out.insert("total", rows.size());
    return out;
}

QString ReferenceStore::textProgressForVideo(const QString& videoPath) const {
    return textProgressForVideoOffset(videoPath, 0);
}

QString ReferenceStore::textProgressForVideoOffset(const QString& videoPath, int offset) const {
    const QVariantMap m = referenceTextForVideoOffset(videoPath, offset);
    if (m.isEmpty()) return {};
    const int row = m.value("row").toInt();
    const int total = m.value("total").toInt();
    if (row <= 0 || total <= 0) return {};
    return QString::number(row) + " / " + QString::number(total);
}

int ReferenceStore::textRowCountForVideo(const QString& videoPath) const {
    if (videoPath.isEmpty()) return 0;
    QFileInfo fi(videoPath);
    if (!fi.exists()) return 0;
    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return 0;
    if (it->textKind != "csv") return 0;
    if (!QFileInfo::exists(it->textPath)) return 0;
    return parseCsv(it->textPath).size();
}

bool ReferenceStore::setReferenceCsv(const QString& folderPath, const QString& csvPath) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return false;
    const QString p = urlOrPathToLocal(csvPath);
    if (p.isEmpty()) return false;
    if (!QFileInfo::exists(p)) return false;
    // 至少能解析出一行
    if (parseCsv(p).isEmpty()) return false;

    Entry e = m_map.value(k);
    e.textKind = "csv"; e.textPath = p;
    m_map.insert(k, e);
    saveToDisk();
    emit referenceTextChanged(k);
    return true;
}

bool ReferenceStore::setReferenceCsvUrl(const QString& folderPath, const QUrl& csvUrl) {
    QString p;
    if (csvUrl.isLocalFile()) p = csvUrl.toLocalFile();
    else p = csvUrl.toString();
    return setReferenceCsv(folderPath, p);
}

void ReferenceStore::clearText(const QString& folderPath) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return;
    if (!m_map.contains(k)) return;
    Entry& e = m_map[k];
    e.textKind.clear(); e.textPath.clear();
    if (e.kind.isEmpty() && e.path.isEmpty()
        && e.kind2.isEmpty() && e.path2.isEmpty()) {
        m_map.remove(k);
    }
    saveToDisk();
    emit referenceTextChanged(k);
}

// ════════════════════════════════════════════════════════════════════════
// 通用
// ════════════════════════════════════════════════════════════════════════

QStringList ReferenceStore::allFolders() const {
    return m_map.keys();
}

// ════════════════════════════════════════════════════════════════════════
// (A2) 参考图 槽位 2 — 与槽位 1 完全对称的实现
// ════════════════════════════════════════════════════════════════════════
//
// 这一段是槽位 1 (kindOf / referenceUrlForVideo* / setReference* / clearReference)
// 的完全镜像，只是把字段名从 kind/path 改成 kind2/path2、信号改成 reference2Changed。
// 单独写一份是为了让槽位 1 的"老 API 行为零变化"——所有现存代码（包括 MultiGroupRow 等）
// 不需要改一行就能继续工作。
//
// 设计动机：左侧栏现在要展示「两份」参考图（如原型图 + 草图），二者各自独立绑定，
// 都跟随对比组同步切换。如果把两份合并到同一字段，clearReference 等行为会变得歧义。

QString ReferenceStore::kindOf2(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = m_map.constFind(k);
    if (it == m_map.constEnd()) return {};
    if (it->kind2 == "image") {
        if (!QFileInfo::exists(it->path2)) return {};
    } else if (it->kind2 == "folder") {
        QFileInfo fi(it->path2);
        if (!fi.exists() || !fi.isDir()) return {};
    } else {
        return {};
    }
    return it->kind2;
}

bool ReferenceStore::hasReference2(const QString& folderPath) const {
    return !kindOf2(folderPath).isEmpty();
}

QUrl ReferenceStore::referenceUrlForVideo2(const QString& videoPath) const {
    return referenceUrlForVideoOffset2(videoPath, 0);
}

QString ReferenceStore::referenceProgressForVideo2(const QString& videoPath) const {
    return referenceProgressForVideoOffset2(videoPath, 0);
}

QUrl ReferenceStore::referenceUrlForVideoOffset2(const QString& videoPath, int offset) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    const QString folder = normalizeFolder(fi.absolutePath());
    if (folder.isEmpty()) return {};
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return {};

    if (it->kind2 == "image") {
        if (!QFileInfo::exists(it->path2)) return {};
        return QUrl::fromLocalFile(it->path2);
    }
    if (it->kind2 == "folder") {
        const QStringList imgs = listImages(it->path2);
        if (imgs.isEmpty()) return {};
        auto idx = videoIndexInDir(videoPath);
        int useIdx = idx.first < 0 ? 0 : idx.first;
        useIdx += offset;
        if (useIdx < 0) useIdx = 0;
        if (useIdx >= imgs.size()) useIdx = imgs.size() - 1;
        return QUrl::fromLocalFile(imgs.at(useIdx));
    }
    return {};
}

QString ReferenceStore::referenceProgressForVideoOffset2(const QString& videoPath, int offset) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return {};
    if (it->kind2 != "folder") return {};

    const QStringList imgs = listImages(it->path2);
    if (imgs.isEmpty()) return {};
    auto idx = videoIndexInDir(videoPath);
    int useIdx = idx.first < 0 ? 0 : idx.first;
    useIdx += offset;
    if (useIdx < 0) useIdx = 0;
    if (useIdx >= imgs.size()) useIdx = imgs.size() - 1;
    return QString::number(useIdx + 1) + " / " + QString::number(imgs.size());
}

int ReferenceStore::referenceImageCountForVideo2(const QString& videoPath) const {
    if (videoPath.isEmpty()) return 0;
    QFileInfo fi(videoPath);
    if (!fi.exists()) return 0;
    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return 0;
    if (it->kind2 != "folder") return 0;
    return listImages(it->path2).size();
}

bool ReferenceStore::setReference2(const QString& folderPath, const QString& imagePath) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return false;
    const QString p = urlOrPathToLocal(imagePath);
    if (p.isEmpty()) return false;
    if (!isSupportedImage(p)) return false;
    if (!QFileInfo::exists(p)) return false;

    Entry e = m_map.value(k);
    e.kind2 = "image"; e.path2 = p;
    m_map.insert(k, e);
    saveToDisk();
    emit reference2Changed(k);
    return true;
}

bool ReferenceStore::setReferenceUrl2(const QString& folderPath, const QUrl& imageUrl) {
    QString p;
    if (imageUrl.isLocalFile()) p = imageUrl.toLocalFile();
    else p = imageUrl.toString();
    return setReference2(folderPath, p);
}

bool ReferenceStore::setReferenceFolder2(const QString& folderPath, const QString& imageDir) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return false;
    const QString d = normalizeFolder(urlOrPathToLocal(imageDir));
    if (d.isEmpty()) return false;
    QFileInfo fi(d);
    if (!fi.exists() || !fi.isDir()) return false;
    if (listImages(d).isEmpty()) return false;

    Entry e = m_map.value(k);
    e.kind2 = "folder"; e.path2 = d;
    m_map.insert(k, e);
    saveToDisk();
    emit reference2Changed(k);
    return true;
}

bool ReferenceStore::setReferenceFolderUrl2(const QString& folderPath, const QUrl& imageDirUrl) {
    QString p;
    if (imageDirUrl.isLocalFile()) p = imageDirUrl.toLocalFile();
    else p = imageDirUrl.toString();
    return setReferenceFolder2(folderPath, p);
}

void ReferenceStore::clearReference2(const QString& folderPath) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return;
    if (!m_map.contains(k)) return;
    Entry& e = m_map[k];
    e.kind2.clear(); e.path2.clear();
    if (e.kind.isEmpty() && e.path.isEmpty()
        && e.textKind.isEmpty() && e.textPath.isEmpty()) {
        m_map.remove(k);
    }
    saveToDisk();
    emit reference2Changed(k);
}

} // namespace rbqt
