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
//   <base64(folder)>\kind=image|folder|grouped
//   <base64(folder)>\path=...
//   <base64(folder)>\kind2=image|folder|grouped
//   <base64(folder)>\path2=...
//   <base64(folder)>\textKind=csv
//   <base64(folder)>\textPath=...
//
// 旧版本（v1 平铺、v2 仅 image/folder、v3 无 grouped）会在 loadFromDisk 中静默兼容。

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
        if (!e.path.isEmpty() && (e.kind != "image" && e.kind != "folder" && e.kind != "grouped")) {
            e.kind.clear(); e.path.clear();
        }
        if (!e.path2.isEmpty() && (e.kind2 != "image" && e.kind2 != "folder" && e.kind2 != "grouped")) {
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

// ── 分组多图工具 ─────────────────────────────────────────────────────────
// rootDir 下的「一级子目录」列表，按自然序排序（1 < 2 < 10），与图片排序一致。
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

// 把 rootDir/{组A,组B,...}/{图...} 拍平成一条长队列。
// 组按自然序、组内图按自然序（仅一级，避免组下还有子目录被误吞）。
QStringList ReferenceStore::listGroupedImages(const QString& rootDir) {
    QStringList out;
    const QStringList groups = listSubGroups(rootDir);
    QCollator coll;
    coll.setNumericMode(true);
    coll.setCaseSensitivity(Qt::CaseInsensitive);
    for (const QString& g : groups) {
        // 仅取该组目录下「一级」图片，不递归——避免再下一层目录误吞
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

// 给定视频，确定其在 grouped 长队列中的「组首」下标 base + 总长度 total。
//
// 对齐策略（优先级从高到低）：
//   1) 子组名 == 视频文件夹名（不区分大小写）→ 用这个子组；
//      适用：视频按子目录组织，且子目录命名与图片子组一致。
//   2) 视频本身在「所在目录视频列表」中的索引 → 同序号子组；
//      适用：所有对比组视频放在同一个目录里（最常见场景）。
//   3) 视频文件夹在「父目录子目录列表」中的索引 → 同序号子组；
//      适用：视频按子目录组织，但目录命名与图片子组不一致。
//   4) 仍失败 → 返回 0（落到长队列第 1 张）。
QPair<int, int> ReferenceStore::groupedBaseIndexForVideo(const QString& videoPath,
                                                         const QString& rootDir) {
    const QStringList all = listGroupedImages(rootDir);
    const int total = all.size();
    if (total == 0) return {0, 0};

    QFileInfo fi(videoPath);
    if (!fi.exists()) return {0, total};

    const QString videoFolder = fi.absolutePath();
    const QString videoFolderName = QFileInfo(videoFolder).fileName();

    const QStringList subGroups = listSubGroups(rootDir);  // 子组绝对路径
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

    // 策略 2：视频本身在「所在目录视频列表」中的索引（覆盖"同目录多视频"场景）
    // 当视频数 > 子组数时，对子组数取模，实现 r1,r2,...,rN,r1,r2,... 循环。
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

    // 策略 3：视频文件夹在父目录子目录列表中的索引（覆盖"按子目录组织但命名不一致"）
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
        // 同样取模，子组数不足时循环对应。
        if (videoGroupIdx >= 0 && !subGroups.isEmpty()) {
            matchedIdx = videoGroupIdx % subGroups.size();
        }
    }

    if (matchedIdx < 0) return {0, total};

    // 计算该子组在 all[] 中的「组首」下标：
    // 把 matchedIdx 之前所有子组的图片数累加。
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
    } else if (it->kind == "grouped") {
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
    return referenceUrlForVideoOffset(videoPath, 0);
}

QString ReferenceStore::referenceProgressForVideo(const QString& videoPath) const {
    return referenceProgressForVideoOffset(videoPath, 0);
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
        // 循环偏移：超出边界从另一头继续（C++ % 对负数可能为负，这里打个保险）。
        const int n = imgs.size();
        useIdx = ((useIdx + offset) % n + n) % n;
        return QUrl::fromLocalFile(imgs.at(useIdx));
    }
    if (it->kind == "grouped") {
        const QStringList all = listGroupedImages(it->path);
        if (all.isEmpty()) return {};
        auto bp = groupedBaseIndexForVideo(videoPath, it->path);
        const int n = all.size();
        int useIdx = ((bp.first + offset) % n + n) % n;
        return QUrl::fromLocalFile(all.at(useIdx));
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

    if (it->kind == "folder") {
        const QStringList imgs = listImages(it->path);
        if (imgs.isEmpty()) return {};
        auto idx = videoIndexInDir(videoPath);
        int useIdx = idx.first < 0 ? 0 : idx.first;
        const int n = imgs.size();
        useIdx = ((useIdx + offset) % n + n) % n;
        return QString::number(useIdx + 1) + " / " + QString::number(n);
    }
    if (it->kind == "grouped") {
        const QStringList all = listGroupedImages(it->path);
        if (all.isEmpty()) return {};
        auto bp = groupedBaseIndexForVideo(videoPath, it->path);
        const int n = all.size();
        int useIdx = ((bp.first + offset) % n + n) % n;
        return QString::number(useIdx + 1) + " / " + QString::number(n);
    }
    return {};
}

int ReferenceStore::referenceImageCountForVideo(const QString& videoPath) const {
    if (videoPath.isEmpty()) return 0;
    QFileInfo fi(videoPath);
    if (!fi.exists()) return 0;
    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return 0;
    if (it->kind == "folder") return listImages(it->path).size();
    if (it->kind == "grouped") return listGroupedImages(it->path).size();
    return 0;
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

// 「分组多图」模式（槽位 1）：rootDir 必须是「两级结构」的根目录
//   rootDir/组A/{图...}, rootDir/组B/{图...}
// 校验：rootDir 必须存在 + 至少有一个子组 + 长队列至少 1 张图。
bool ReferenceStore::setGroupedFolder(const QString& folderPath, const QString& rootDir) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return false;
    const QString d = normalizeFolder(urlOrPathToLocal(rootDir));
    if (d.isEmpty()) return false;
    QFileInfo fi(d);
    if (!fi.exists() || !fi.isDir()) return false;
    if (listSubGroups(d).isEmpty()) return false;
    if (listGroupedImages(d).isEmpty()) return false;

    Entry e = m_map.value(k);
    e.kind = "grouped"; e.path = d;
    m_map.insert(k, e);
    saveToDisk();
    emit referenceChanged(k);
    return true;
}

bool ReferenceStore::setGroupedFolderUrl(const QString& folderPath, const QUrl& rootDirUrl) {
    QString p;
    if (rootDirUrl.isLocalFile()) p = rootDirUrl.toLocalFile();
    else p = rootDirUrl.toString();
    return setGroupedFolder(folderPath, p);
}

bool ReferenceStore::isGrouped(const QString& folderPath) const {
    return kindOf(folderPath) == QStringLiteral("grouped");
}

QString ReferenceStore::groupedRootOf(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = m_map.constFind(k);
    if (it == m_map.constEnd()) return {};
    if (it->kind != "grouped") return {};
    QFileInfo fi(it->path);
    if (!fi.exists() || !fi.isDir()) return {};
    return it->path;
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
        // 已识别齐三个字段后跳过后续匹配（同义列名以先出现的列为准，不被覆盖）
        if (zh.isEmpty() || en.isEmpty() || image.isEmpty()) {
            if (zh.isEmpty() && (key == "prompt" || key == "zh" || key == "zh_prompt" || key == "中文" || key == QString::fromUtf8("中文prompt"))) {
                zh = val;
            } else if (en.isEmpty() && (key == "en_prompt" || key == "en" || key == "english" || key == "english_prompt")) {
                en = val;
            } else if (image.isEmpty() && (key == "image" || key == "img" || key == "图片" || key == "filename")) {
                image = val;
            }
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
    } else if (it->kind2 == "grouped") {
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
        const int n = imgs.size();
        useIdx = ((useIdx + offset) % n + n) % n;
        return QUrl::fromLocalFile(imgs.at(useIdx));
    }
    if (it->kind2 == "grouped") {
        const QStringList all = listGroupedImages(it->path2);
        if (all.isEmpty()) return {};
        auto bp = groupedBaseIndexForVideo(videoPath, it->path2);
        const int n = all.size();
        int useIdx = ((bp.first + offset) % n + n) % n;
        return QUrl::fromLocalFile(all.at(useIdx));
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

    if (it->kind2 == "folder") {
        const QStringList imgs = listImages(it->path2);
        if (imgs.isEmpty()) return {};
        auto idx = videoIndexInDir(videoPath);
        int useIdx = idx.first < 0 ? 0 : idx.first;
        const int n = imgs.size();
        useIdx = ((useIdx + offset) % n + n) % n;
        return QString::number(useIdx + 1) + " / " + QString::number(n);
    }
    if (it->kind2 == "grouped") {
        const QStringList all = listGroupedImages(it->path2);
        if (all.isEmpty()) return {};
        auto bp = groupedBaseIndexForVideo(videoPath, it->path2);
        const int n = all.size();
        int useIdx = ((bp.first + offset) % n + n) % n;
        return QString::number(useIdx + 1) + " / " + QString::number(n);
    }
    return {};
}

int ReferenceStore::referenceImageCountForVideo2(const QString& videoPath) const {
    if (videoPath.isEmpty()) return 0;
    QFileInfo fi(videoPath);
    if (!fi.exists()) return 0;
    const QString folder = normalizeFolder(fi.absolutePath());
    auto it = m_map.constFind(folder);
    if (it == m_map.constEnd()) return 0;
    if (it->kind2 == "folder") return listImages(it->path2).size();
    if (it->kind2 == "grouped") return listGroupedImages(it->path2).size();
    return 0;
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

// 「分组多图」模式（槽位 2）
bool ReferenceStore::setGroupedFolder2(const QString& folderPath, const QString& rootDir) {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return false;
    const QString d = normalizeFolder(urlOrPathToLocal(rootDir));
    if (d.isEmpty()) return false;
    QFileInfo fi(d);
    if (!fi.exists() || !fi.isDir()) return false;
    if (listSubGroups(d).isEmpty()) return false;
    if (listGroupedImages(d).isEmpty()) return false;

    Entry e = m_map.value(k);
    e.kind2 = "grouped"; e.path2 = d;
    m_map.insert(k, e);
    saveToDisk();
    emit reference2Changed(k);
    return true;
}

bool ReferenceStore::setGroupedFolderUrl2(const QString& folderPath, const QUrl& rootDirUrl) {
    QString p;
    if (rootDirUrl.isLocalFile()) p = rootDirUrl.toLocalFile();
    else p = rootDirUrl.toString();
    return setGroupedFolder2(folderPath, p);
}

bool ReferenceStore::isGrouped2(const QString& folderPath) const {
    return kindOf2(folderPath) == QStringLiteral("grouped");
}

QString ReferenceStore::groupedRootOf2(const QString& folderPath) const {
    const QString k = normalizeFolder(folderPath);
    if (k.isEmpty()) return {};
    auto it = m_map.constFind(k);
    if (it == m_map.constEnd()) return {};
    if (it->kind2 != "grouped") return {};
    QFileInfo fi(it->path2);
    if (!fi.exists() || !fi.isDir()) return {};
    return it->path2;
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
