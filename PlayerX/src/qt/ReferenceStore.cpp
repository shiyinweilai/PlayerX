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
constexpr int kMaxSlots = 9;

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
// ini 结构（v4）：
//   [references]
//   <base64(folder)>\kind=image|folder|grouped      ← 槽位 1（沿用旧名，兼容 v3）
//   <base64(folder)>\path=...
//   <base64(folder)>\kind2=image|folder|grouped     ← 槽位 2（与 v3 同名，天然兼容）
//   <base64(folder)>\path2=...
//   <base64(folder)>\kindN=...                      ← 槽位 N（3..9）
//   <base64(folder)>\pathN=...
//   <base64(folder)>\textKind=csv
//   <base64(folder)>\textPath=...
//
// 旧版本（v1 平铺、v2、v3 固定双槽位）会在 loadFromDisk 中静默兼容。

void ReferenceStore::loadFromDisk() {
    QSettings s(m_settingsFile, QSettings::IniFormat);
    s.beginGroup(kGroup);
    m_map.clear();

    const QStringList groups = s.childGroups();
    for (const QString& g : groups) {
        s.beginGroup(g);
        Entry e;
        // 参考图 N 槽位：kind/path（槽位1）、kindN/pathN（N≥2）
        for (int slot = 1; slot <= kMaxSlots; ++slot) {
            const QString kindKey = slot == 1 ? "kind" : ("kind" + QString::number(slot));
            const QString pathKey = slot == 1 ? "path" : ("path" + QString::number(slot));
            QString kind = s.value(kindKey, "").toString();
            QString path = s.value(pathKey, "").toString();
            if (!path.isEmpty() && !isValidKind(kind)) {
                kind.clear(); path.clear();
            }
            if (!kind.isEmpty() && !path.isEmpty()) {
                // imgSlots 按 1-based 槽位号补齐到该长度（中间空洞以空对占位）
                while (e.imgSlots.size() < slot)
                    e.imgSlots.append(qMakePair(QString(), QString()));
                e.imgSlots[slot - 1] = qMakePair(kind, path);
            }
        }
        e.textKind = s.value("textKind", "").toString();
        e.textPath = s.value("textPath", "").toString();
        s.endGroup();

        // 文本字段校验
        if (!e.textPath.isEmpty() && e.textKind != "csv") {
            e.textKind.clear(); e.textPath.clear();
        }
        // 全部为空 → 跳过
        if (entryIsEmpty(e)) continue;

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
        e.imgSlots.append(qMakePair(QStringLiteral("image"), v));
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
        for (int slot = 1; slot <= e.imgSlots.size(); ++slot) {
            const auto& kv = e.imgSlots.at(slot - 1);
            if (kv.first.isEmpty() || kv.second.isEmpty()) continue;
            const QString kindKey = slot == 1 ? "kind" : ("kind" + QString::number(slot));
            const QString pathKey = slot == 1 ? "path" : ("path" + QString::number(slot));
            s.setValue(kindKey, kv.first);
            s.setValue(pathKey, kv.second);
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

bool ReferenceStore::isValidKind(const QString& kind) {
    return kind == "image" || kind == "folder" || kind == "grouped";
}

bool ReferenceStore::isSupportedImage(const QString& path) const {
    return inExtList(path, kImageExts);
}

QPair<QString, QString> ReferenceStore::imgSlotOf(const Entry& e, int slot) {
    if (slot < 1 || slot > e.imgSlots.size()) return {"", ""};
    return e.imgSlots.at(slot - 1);
}

bool ReferenceStore::setImgSlot(Entry& e, int slot, const QString& kind, const QString& path) {
    if (slot < 1 || slot > kMaxSlots) return false;
    if (kind.isEmpty() || path.isEmpty()) return false;
    while (e.imgSlots.size() < slot)
        e.imgSlots.append(qMakePair(QString(), QString()));
    e.imgSlots[slot - 1] = qMakePair(kind, path);
    return true;
}

bool ReferenceStore::clearImgSlot(Entry& e, int slot) {
    if (slot < 1 || slot > e.imgSlots.size()) return false;
    e.imgSlots[slot - 1] = qMakePair(QString(), QString());
    // 尾部空槽位收缩（保持 slotCountOf 语义 = 最后一个非空槽位）
    while (!e.imgSlots.isEmpty()
           && e.imgSlots.last().first.isEmpty() && e.imgSlots.last().second.isEmpty()) {
        e.imgSlots.removeLast();
    }
    return true;
}

bool ReferenceStore::entryIsEmpty(const Entry& e) {
    if (!e.textKind.isEmpty() && !e.textPath.isEmpty()) return false;
    for (const auto& kv : e.imgSlots) {
        if (!kv.first.isEmpty() && !kv.second.isEmpty()) return false;
    }
    return true;
}

int ReferenceStore::maxSlots() const { return kMaxSlots; }

int ReferenceStore::slotCountOf(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return 0;
    auto it = findEntryForFolder(k);
    if (it == m_map.constEnd()) return 0;
    return it->imgSlots.size();
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

// ── 分组多图工具 ─────────────────────────────────────────────────────────
QStringList ReferenceStore::listSubGroups(const QString& rootDir) {
    QStringList out;
    QFileInfo fi(rootDir);
    if (!fi.exists() || !fi.isDir()) return out;
    QDir d(rootDir);
    const QFileInfoList subs = d.entryInfoList(
        QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable);
    for (const QFileInfo& s : subs) {
        out << s.absoluteFilePath();
    }
    QCollator coll;
    coll.setNumericMode(true);
    coll.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(out.begin(), out.end(),
              [&coll](const QString& a, const QString& b) {
                  return coll.compare(a, b) < 0;
              });
    return out;
}

QStringList ReferenceStore::listGroupedImages(const QString& rootDir) {
    QStringList out;
    const QStringList groups = listSubGroups(rootDir);
    QCollator coll;
    coll.setNumericMode(true);
    coll.setCaseSensitivity(Qt::CaseInsensitive);
    for (const QString& g : groups) {
        QDir d(g);
        const QFileInfoList files = d.entryInfoList(
            QDir::Files | QDir::NoDotAndDotDot | QDir::Readable);
        QStringList groupImgs;
        for (const QFileInfo& f : files) {
            const QString abs = f.absoluteFilePath();
            if (inExtList(abs, kImageExts)) groupImgs << abs;
        }
        std::sort(groupImgs.begin(), groupImgs.end(),
                  [&coll](const QString& a, const QString& b) {
                      return coll.compare(a, b) < 0;
                  });
        out += groupImgs;
    }
    return out;
}

QPair<int, int> ReferenceStore::groupedBaseIndexForVideo(const QString& videoPath,
                                                         const QString& rootDir) {
    const QStringList all = listGroupedImages(rootDir);
    const int total = all.size();
    if (total == 0) return {0, 0};

    QFileInfo fi(videoPath);
    if (!fi.exists()) return {0, total};

    const QString videoFolder = fi.absolutePath();
    const QString videoFolderName = QFileInfo(videoFolder).fileName();

    const QStringList subGroups = listSubGroups(rootDir);
    if (subGroups.isEmpty()) return {0, total};

    int matchedIdx = -1;

    // 策略 1：按子组名 == 视频文件夹名匹配
    for (int i = 0; i < subGroups.size(); ++i) {
        const QString name = QFileInfo(subGroups[i]).fileName();
        if (name.compare(videoFolderName, Qt::CaseInsensitive) == 0) {
            matchedIdx = i;
            break;
        }
    }

    // 策略 2：视频在「所在目录视频列表」中的索引（取模循环）
    if (matchedIdx < 0) {
        const QStringList videos = listVideos(videoFolder);
        const QString videoAbs = fi.absoluteFilePath();
        int videoIdx = -1;
        for (int i = 0; i < videos.size(); ++i) {
            if (videos[i].compare(videoAbs, Qt::CaseInsensitive) == 0) {
                videoIdx = i;
                break;
            }
        }
        if (videoIdx >= 0 && !subGroups.isEmpty()) {
            matchedIdx = videoIdx % subGroups.size();
        }
    }

    // 策略 3：视频文件夹在父目录子目录列表中的索引（取模循环）
    if (matchedIdx < 0) {
        const QString videoParent = QFileInfo(videoFolder).absolutePath();
        QDir vp(videoParent);
        const QFileInfoList vpSubs = vp.entryInfoList(
            QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable);
        QStringList vpNames;
        for (const QFileInfo& s : vpSubs) vpNames << s.absoluteFilePath();
        QCollator coll;
        coll.setNumericMode(true);
        coll.setCaseSensitivity(Qt::CaseInsensitive);
        std::sort(vpNames.begin(), vpNames.end(),
                  [&coll](const QString& a, const QString& b) {
                      return coll.compare(a, b) < 0;
                  });
        int videoGroupIdx = -1;
        for (int i = 0; i < vpNames.size(); ++i) {
            if (QFileInfo(vpNames[i]).fileName()
                    .compare(videoFolderName, Qt::CaseInsensitive) == 0) {
                videoGroupIdx = i;
                break;
            }
        }
        if (videoGroupIdx >= 0 && !subGroups.isEmpty()) {
            matchedIdx = videoGroupIdx % subGroups.size();
        }
    }

    if (matchedIdx < 0) return {0, total};

    int base = 0;
    for (int i = 0; i < matchedIdx; ++i) {
        QDir d(subGroups[i]);
        const QFileInfoList files = d.entryInfoList(
            QDir::Files | QDir::NoDotAndDotDot | QDir::Readable);
        for (const QFileInfo& f : files) {
            if (inExtList(f.absoluteFilePath(), kImageExts)) ++base;
        }
    }
    if (base >= total) base = total - 1;
    if (base < 0) base = 0;
    return {base, total};
}

// ── CSV 解析（RFC4180 兼容）──────────────────────────────────────────────
QList<QVariantMap> ReferenceStore::parseCsv(const QString& csvPath) {
    QList<QVariantMap> rows;
    QFile f(csvPath);
    if (!f.open(QIODevice::ReadOnly)) return rows;
    QByteArray bytes = f.readAll();
    f.close();
    if (bytes.isEmpty()) return rows;

    QStringDecoder dec = QStringDecoder(QStringDecoder::Utf8);
    QString text = dec.decode(bytes);
    if (text.isEmpty()) return rows;

    QList<QStringList> records;
    QStringList curRow;
    QString curField;
    bool inQuotes = false;
    const int n = text.size();
    for (int i = 0; i < n; ++i) {
        QChar c = text.at(i);
        if (inQuotes) {
            if (c == '"') {
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
    if (!curField.isEmpty() || !curRow.isEmpty()) {
        curRow.append(curField);
        records.append(curRow);
    }

    if (records.isEmpty()) return rows;

    int headerIdx = -1;
    for (int i = 0; i < records.size(); ++i) {
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
// (A) 参考图：查询核心实现
// ════════════════════════════════════════════════════════════════════════

// 校验 kind/path 指向的资源仍存在；有效则原样返回 kind，否则返回 ""
QString ReferenceStore::kindValidated(const QString& kind, const QString& path) const {
    if (kind == "image") {
        if (!QFileInfo::exists(path)) return {};
    } else if (kind == "folder" || kind == "grouped") {
        QFileInfo fi(path);
        if (!fi.exists() || !fi.isDir()) return {};
    } else {
        return {};
    }
    return kind;
}

QString ReferenceStore::groupedRootValidated(const QString& path) const {
    QFileInfo fi(path);
    if (!fi.exists() || !fi.isDir()) return {};
    return path;
}

QUrl ReferenceStore::urlForVideoOffsetImpl(const QString& videoPath, int offset,
                                           const QString& kind, const QString& path) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    if (kind.isEmpty() || path.isEmpty()) return {};

    if (kind == "image") {
        if (!QFileInfo::exists(path)) return {};
        return QUrl::fromLocalFile(path);
    }
    if (kind == "folder") {
        const QStringList imgs = listImages(path);
        if (imgs.isEmpty()) return {};
        auto idx = videoIndexInDir(videoPath);
        int useIdx = idx.first < 0 ? 0 : idx.first;
        const int n = imgs.size();
        useIdx = ((useIdx + offset) % n + n) % n;
        return QUrl::fromLocalFile(imgs.at(useIdx));
    }
    if (kind == "grouped") {
        const QStringList all = listGroupedImages(path);
        if (all.isEmpty()) return {};
        auto bp = groupedBaseIndexForVideo(videoPath, path);
        const int n = all.size();
        int useIdx = ((bp.first + offset) % n + n) % n;
        return QUrl::fromLocalFile(all.at(useIdx));
    }
    return {};
}

QString ReferenceStore::progressForVideoOffsetImpl(const QString& videoPath, int offset,
                                                    const QString& kind, const QString& path) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    if (kind.isEmpty() || path.isEmpty()) return {};

    if (kind == "folder") {
        const QStringList imgs = listImages(path);
        if (imgs.isEmpty()) return {};
        auto idx = videoIndexInDir(videoPath);
        int useIdx = idx.first < 0 ? 0 : idx.first;
        const int n = imgs.size();
        useIdx = ((useIdx + offset) % n + n) % n;
        return QString::number(useIdx + 1) + " / " + QString::number(n);
    }
    if (kind == "grouped") {
        const QStringList all = listGroupedImages(path);
        if (all.isEmpty()) return {};
        auto bp = groupedBaseIndexForVideo(videoPath, path);
        const int n = all.size();
        int useIdx = ((bp.first + offset) % n + n) % n;
        return QString::number(useIdx + 1) + " / " + QString::number(n);
    }
    return {};
}

int ReferenceStore::imageCountImpl(const QString& videoPath,
                                   const QString& kind, const QString& path) const {
    if (videoPath.isEmpty()) return 0;
    if (kind.isEmpty() || path.isEmpty()) return 0;
    if (kind == "folder") return listImages(path).size();
    if (kind == "grouped") return listGroupedImages(path).size();
    return 0;
}

// ════════════════════════════════════════════════════════════════════════
// (A) 参考图：N 槽位通用 API
// ════════════════════════════════════════════════════════════════════════

// 沿目录自身 → 逐级父目录查找已绑定条目；全部未命中返回 constEnd()。
// 这让「视频在扫描根的子目录里」的场景也能命中祖先目录上的绑定
// （详见头文件 findEntryForFolder 的说明）。
QHash<QString, ReferenceStore::Entry>::const_iterator
ReferenceStore::findEntryForFolder(const QString& folder) const {
    if (folder.isEmpty()) return m_map.constEnd();

    QString cur = normalizeFolder(folder);
    // 回溯深度上限，避免极端深路径下无意义循环
    for (int guard = 0; guard < 32 && !cur.isEmpty(); ++guard) {
        auto it = m_map.constFind(cur);
        if (it != m_map.constEnd()) return it;

        const int slash = cur.lastIndexOf('/');
        if (slash <= 0) break;          // 已到 "/" 或根目录，停止
        cur = cur.left(slash);
    }
    return m_map.constEnd();
}

QString ReferenceStore::kindOfAt(const QString& folderPath, int slot) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = findEntryForFolder(k);
    if (it == m_map.constEnd()) return {};
    const auto kv = imgSlotOf(*it, slot);
    return kindValidated(kv.first, kv.second);
}

bool ReferenceStore::hasReferenceAt(const QString& folderPath, int slot) const {
    return !kindOfAt(folderPath, slot).isEmpty();
}

QUrl ReferenceStore::referenceUrlForVideoOffsetAt(const QString& videoPath, int offset, int slot) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    const QString folder = normalizeFolder(fi.absolutePath());
    if (folder.isEmpty()) return {};
    auto it = findEntryForFolder(folder);
    if (it == m_map.constEnd()) return {};
    const auto kv = imgSlotOf(*it, slot);
    return urlForVideoOffsetImpl(videoPath, offset, kv.first, kv.second);
}

QString ReferenceStore::referenceProgressForVideoOffsetAt(const QString& videoPath, int offset, int slot) const {
    if (videoPath.isEmpty()) return {};
    QFileInfo fi(videoPath);
    if (!fi.exists()) return {};
    const QString folder = normalizeFolder(fi.absolutePath());
    if (folder.isEmpty()) return {};
    auto it = findEntryForFolder(folder);
    if (it == m_map.constEnd()) return {};
    const auto kv = imgSlotOf(*it, slot);
    return progressForVideoOffsetImpl(videoPath, offset, kv.first, kv.second);
}

int ReferenceStore::referenceImageCountForVideoAt(const QString& videoPath, int slot) const {
    if (videoPath.isEmpty()) return 0;
    QFileInfo fi(videoPath);
    if (!fi.exists()) return 0;
    const QString folder = normalizeFolder(fi.absolutePath());
    if (folder.isEmpty()) return 0;
    auto it = findEntryForFolder(folder);
    if (it == m_map.constEnd()) return 0;
    const auto kv = imgSlotOf(*it, slot);
    return imageCountImpl(videoPath, kv.first, kv.second);
}

// ════════════════════════════════════════════════════════════════════════
// (A) 参考图：写入核心
// ════════════════════════════════════════════════════════════════════════

bool ReferenceStore::setSlotEntry(const QString& folderPath, int slot,
                                  const QString& kind, const QString& localPath) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return false;
    if (slot < 1 || slot > kMaxSlots) return false;
    if (!isValidKind(kind) || localPath.isEmpty()) return false;

    Entry e = m_map.value(k);  // 保留其它槽位 + 文本字段
    if (!setImgSlot(e, slot, kind, localPath)) return false;
    m_map.insert(k, e);
    saveToDisk();
    emit referenceSlotChanged(k, slot);
    if (slot == 1) emit referenceChanged(k);
    if (slot == 2) emit reference2Changed(k);
    return true;
}

bool ReferenceStore::setReferenceAt(const QString& folderPath, const QString& imagePath, int slot) {
    const QString p = urlOrPathToLocal(imagePath);
    if (p.isEmpty()) return false;
    if (!isSupportedImage(p)) return false;
    if (!QFileInfo::exists(p)) return false;
    return setSlotEntry(folderPath, slot, "image", p);
}

bool ReferenceStore::setReferenceUrlAt(const QString& folderPath, const QUrl& imageUrl, int slot) {
    QString p;
    if (imageUrl.isLocalFile()) p = imageUrl.toLocalFile();
    else p = imageUrl.toString();
    return setReferenceAt(folderPath, p, slot);
}

bool ReferenceStore::setReferenceFolderAt(const QString& folderPath, const QString& imageDir, int slot) {
    const QString d = normalizeFolder(urlOrPathToLocal(imageDir));
    if (d.isEmpty()) return false;
    QFileInfo fi(d);
    if (!fi.exists() || !fi.isDir()) return false;
    if (listImages(d).isEmpty()) return false;
    return setSlotEntry(folderPath, slot, "folder", d);
}

bool ReferenceStore::setReferenceFolderUrlAt(const QString& folderPath, const QUrl& imageDirUrl, int slot) {
    QString p;
    if (imageDirUrl.isLocalFile()) p = imageDirUrl.toLocalFile();
    else p = imageDirUrl.toString();
    return setReferenceFolderAt(folderPath, p, slot);
}

bool ReferenceStore::setGroupedFolderAt(const QString& folderPath, const QString& rootDir, int slot) {
    const QString d = normalizeFolder(urlOrPathToLocal(rootDir));
    if (d.isEmpty()) return false;
    QFileInfo fi(d);
    if (!fi.exists() || !fi.isDir()) return false;
    if (listSubGroups(d).isEmpty()) return false;
    if (listGroupedImages(d).isEmpty()) return false;
    return setSlotEntry(folderPath, slot, "grouped", d);
}

bool ReferenceStore::setGroupedFolderUrlAt(const QString& folderPath, const QUrl& rootDirUrl, int slot) {
    QString p;
    if (rootDirUrl.isLocalFile()) p = rootDirUrl.toLocalFile();
    else p = rootDirUrl.toString();
    return setGroupedFolderAt(folderPath, p, slot);
}

bool ReferenceStore::isGroupedAt(const QString& folderPath, int slot) const {
    return kindOfAt(folderPath, slot) == QStringLiteral("grouped");
}

QString ReferenceStore::groupedRootOfAt(const QString& folderPath, int slot) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = findEntryForFolder(k);
    if (it == m_map.constEnd()) return {};
    const auto kv = imgSlotOf(*it, slot);
    if (kv.first != "grouped") return {};
    return groupedRootValidated(kv.second);
}

void ReferenceStore::clearReferenceAt(const QString& folderPath, int slot) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return;
    auto it = m_map.find(k);
    if (it == m_map.end()) return;
    if (!clearImgSlot(it.value(), slot)) return;
    if (entryIsEmpty(it.value())) {
        m_map.erase(it);
    }
    saveToDisk();
    emit referenceSlotChanged(k, slot);
    if (slot == 1) emit referenceChanged(k);
    if (slot == 2) emit reference2Changed(k);
}

// ════════════════════════════════════════════════════════════════════════
// (A-legacy) 槽位 1 / 槽位 2 旧 API — 泛化 API 的薄包装
// ════════════════════════════════════════════════════════════════════════

QString ReferenceStore::kindOf(const QString& folderPath) const {
    return kindOfAt(folderPath, 1);
}
bool ReferenceStore::hasReference(const QString& folderPath) const {
    return hasReferenceAt(folderPath, 1);
}

QString ReferenceStore::referenceOf(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = findEntryForFolder(k);
    if (it == m_map.constEnd()) return {};
    const auto kv = imgSlotOf(*it, 1);
    if (kindValidated(kv.first, kv.second).isEmpty()) return {};
    return kv.second;
}

QUrl ReferenceStore::referenceUrlOf(const QString& folderPath) const {
    const QString p = referenceOf(folderPath);
    if (p.isEmpty()) return {};
    return QUrl::fromLocalFile(p);
}

QUrl ReferenceStore::referenceUrlForVideo(const QString& videoPath) const {
    return referenceUrlForVideoOffsetAt(videoPath, 0, 1);
}
QString ReferenceStore::referenceProgressForVideo(const QString& videoPath) const {
    return referenceProgressForVideoOffsetAt(videoPath, 0, 1);
}
QUrl ReferenceStore::referenceUrlForVideoOffset(const QString& videoPath, int offset) const {
    return referenceUrlForVideoOffsetAt(videoPath, offset, 1);
}
QString ReferenceStore::referenceProgressForVideoOffset(const QString& videoPath, int offset) const {
    return referenceProgressForVideoOffsetAt(videoPath, offset, 1);
}
int ReferenceStore::referenceImageCountForVideo(const QString& videoPath) const {
    return referenceImageCountForVideoAt(videoPath, 1);
}

bool ReferenceStore::setReference(const QString& folderPath, const QString& imagePath) {
    return setReferenceAt(folderPath, imagePath, 1);
}
bool ReferenceStore::setReferenceUrl(const QString& folderPath, const QUrl& imageUrl) {
    return setReferenceUrlAt(folderPath, imageUrl, 1);
}
bool ReferenceStore::setReferenceFolder(const QString& folderPath, const QString& imageDir) {
    return setReferenceFolderAt(folderPath, imageDir, 1);
}
bool ReferenceStore::setReferenceFolderUrl(const QString& folderPath, const QUrl& imageDirUrl) {
    return setReferenceFolderUrlAt(folderPath, imageDirUrl, 1);
}
bool ReferenceStore::setGroupedFolder(const QString& folderPath, const QString& rootDir) {
    return setGroupedFolderAt(folderPath, rootDir, 1);
}
bool ReferenceStore::setGroupedFolderUrl(const QString& folderPath, const QUrl& rootDirUrl) {
    return setGroupedFolderUrlAt(folderPath, rootDirUrl, 1);
}
bool ReferenceStore::isGrouped(const QString& folderPath) const {
    return isGroupedAt(folderPath, 1);
}
QString ReferenceStore::groupedRootOf(const QString& folderPath) const {
    return groupedRootOfAt(folderPath, 1);
}
void ReferenceStore::clearReference(const QString& folderPath) {
    clearReferenceAt(folderPath, 1);
}

// 槽位 2 旧 API
QString ReferenceStore::kindOf2(const QString& folderPath) const {
    return kindOfAt(folderPath, 2);
}
bool ReferenceStore::hasReference2(const QString& folderPath) const {
    return hasReferenceAt(folderPath, 2);
}
QUrl ReferenceStore::referenceUrlForVideo2(const QString& videoPath) const {
    return referenceUrlForVideoOffsetAt(videoPath, 0, 2);
}
QString ReferenceStore::referenceProgressForVideo2(const QString& videoPath) const {
    return referenceProgressForVideoOffsetAt(videoPath, 0, 2);
}
QUrl ReferenceStore::referenceUrlForVideoOffset2(const QString& videoPath, int offset) const {
    return referenceUrlForVideoOffsetAt(videoPath, offset, 2);
}
QString ReferenceStore::referenceProgressForVideoOffset2(const QString& videoPath, int offset) const {
    return referenceProgressForVideoOffsetAt(videoPath, offset, 2);
}
int ReferenceStore::referenceImageCountForVideo2(const QString& videoPath) const {
    return referenceImageCountForVideoAt(videoPath, 2);
}
bool ReferenceStore::setReference2(const QString& folderPath, const QString& imagePath) {
    return setReferenceAt(folderPath, imagePath, 2);
}
bool ReferenceStore::setReferenceUrl2(const QString& folderPath, const QUrl& imageUrl) {
    return setReferenceUrlAt(folderPath, imageUrl, 2);
}
bool ReferenceStore::setReferenceFolder2(const QString& folderPath, const QString& imageDir) {
    return setReferenceFolderAt(folderPath, imageDir, 2);
}
bool ReferenceStore::setReferenceFolderUrl2(const QString& folderPath, const QUrl& imageDirUrl) {
    return setReferenceFolderUrlAt(folderPath, imageDirUrl, 2);
}
bool ReferenceStore::setGroupedFolder2(const QString& folderPath, const QString& rootDir) {
    return setGroupedFolderAt(folderPath, rootDir, 2);
}
bool ReferenceStore::setGroupedFolderUrl2(const QString& folderPath, const QUrl& rootDirUrl) {
    return setGroupedFolderUrlAt(folderPath, rootDirUrl, 2);
}
bool ReferenceStore::isGrouped2(const QString& folderPath) const {
    return isGroupedAt(folderPath, 2);
}
QString ReferenceStore::groupedRootOf2(const QString& folderPath) const {
    return groupedRootOfAt(folderPath, 2);
}
void ReferenceStore::clearReference2(const QString& folderPath) {
    clearReferenceAt(folderPath, 2);
}

// ════════════════════════════════════════════════════════════════════════
// (B) 参考文本：CSV
// ════════════════════════════════════════════════════════════════════════

QString ReferenceStore::textKindOf(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = findEntryForFolder(k);
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
    auto it = findEntryForFolder(k);
    if (it == m_map.constEnd()) return {};
    if (!QFileInfo::exists(it->textPath)) return {};
    return it->textPath;
}

QVariantMap ReferenceStore::referenceTextForVideo(const QString& videoPath) const {
    return referenceTextForVideoOffset(videoPath, 0);
}

QVariantMap ReferenceStore::referenceTextForVideoOffset(const QString& videoPath, int offset) const {
    QVariantMap out;
    if (videoPath.isEmpty()) return out;
    QFileInfo fi(videoPath);
    if (!fi.exists()) return out;

    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = findEntryForFolder(folder);
    if (it == m_map.constEnd()) return out;
    if (it->textKind != "csv") return out;
    if (!QFileInfo::exists(it->textPath)) return out;

    const QList<QVariantMap> rows = parseCsv(it->textPath);
    if (rows.isEmpty()) return out;

    auto idx = videoIndexInDir(videoPath);
    int useIdx = idx.first < 0 ? 0 : idx.first;
    useIdx += offset;
    if (useIdx < 0) useIdx = 0;
    if (useIdx >= rows.size()) useIdx = rows.size() - 1;

    const QVariantMap& row = rows.at(useIdx);

    QString zh, en, image, raw;
    for (auto rit = row.constBegin(); rit != row.constEnd(); ++rit) {
        const QString key = rit.key().trimmed().toLower();
        const QString val = rit.value().toString();
        if (zh.isEmpty() || en.isEmpty() || image.isEmpty()) {
            if (zh.isEmpty() && (key == "prompt" || key == "zh" || key == "zh_prompt" || key == "中文" || key == QString::fromUtf8("中文prompt"))) {
                zh = val;
            } else if (en.isEmpty() && (key == "en_prompt" || key == "en" || key == "english" || key == "english_prompt")) {
                en = val;
            } else if (image.isEmpty() && (key == "image" || key == "img" || key == "图片" || key == "filename")) {
                image = val;
            }
        }
        if (!val.trimmed().isEmpty()) {
            if (!raw.isEmpty()) raw += "\n\n";
            raw += rit.key() + ": " + val;
        }
    }
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
    auto it = findEntryForFolder(folder);
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
    auto it = m_map.find(k);
    if (it == m_map.end()) return;
    it->textKind.clear(); it->textPath.clear();
    if (entryIsEmpty(it.value())) {
        m_map.erase(it);
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

} // namespace rbqt
