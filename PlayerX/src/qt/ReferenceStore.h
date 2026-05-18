/**
 * ReferenceStore.h — 文件夹「参考资料」本地持久化（仅供 QML 侧边栏 / MultiGroupRow 使用）
 *
 * 设计要点：
 *   - 与 EngineBridge / 播放内核完全解耦：只做「视频所在文件夹 → 参考资料来源」的映射；
 *   - 「参考资料」分为两个独立维度，互不干扰：
 *       (A) 参考图：
 *           · "image"  ：一张固定图片
 *           · "folder" ：一个图片文件夹，按"当前视频在其所在文件夹中的索引"取同序号图片
 *       (B) 参考文本（新增）：
 *           · "csv"    ：一个 CSV 文件，按"当前视频索引"取同序号行；
 *                        优先识别列名 prompt / en_prompt / Image，
 *                        对应展示中文 prompt、英文 prompt 与图片名。
 *   - 持久化：QSettings (ini)，folder 路径用 base64 作 key，避免 "/" 与 QSettings 子组冲突；
 *   - 通过 contextProperty 暴露给 QML，命名空间 "Reference"。
 */
#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QHash>
#include <QVariantMap>

namespace rbqt {

class ReferenceStore : public QObject {
    Q_OBJECT
public:
    explicit ReferenceStore(QObject* parent = nullptr);
    ~ReferenceStore() override;

    // ════════════════════════════════════════════════════════════════
    // (A) 参考图 维度
    // ════════════════════════════════════════════════════════════════

    // 取某文件夹绑定的参考图来源类型："image" / "folder" / ""（未绑定）
    Q_INVOKABLE QString kindOf(const QString& folderPath) const;
    Q_INVOKABLE bool hasReference(const QString& folderPath) const;
    Q_INVOKABLE QString referenceOf(const QString& folderPath) const;
    Q_INVOKABLE QUrl referenceUrlOf(const QString& folderPath) const;

    // 跟随视频的图片查询：
    //   · image  → 固定图；
    //   · folder → 按视频在其所在文件夹（递归排序）中的索引取同序号图片。
    Q_INVOKABLE QUrl referenceUrlForVideo(const QString& videoPath) const;
    Q_INVOKABLE QString referenceProgressForVideo(const QString& videoPath) const;

    // 在 referenceUrlForVideo / referenceProgressForVideo 计算出的"自动索引"基础上偏移 offset 张
    // 取参考图（仅 folder 模式生效；越界自动夹紧到 [0, N-1]）。
    // 用途：侧边栏临时浏览参考图文件夹的相邻图片。
    Q_INVOKABLE QUrl referenceUrlForVideoOffset(const QString& videoPath, int offset) const;
    Q_INVOKABLE QString referenceProgressForVideoOffset(const QString& videoPath, int offset) const;
    // folder 模式下参考图总数；image / 未绑定时为 0；用于 QML 端边界判断
    Q_INVOKABLE int referenceImageCountForVideo(const QString& videoPath) const;

    Q_INVOKABLE bool setReference(const QString& folderPath, const QString& imagePath);
    Q_INVOKABLE bool setReferenceUrl(const QString& folderPath, const QUrl& imageUrl);
    Q_INVOKABLE bool setReferenceFolder(const QString& folderPath, const QString& imageDir);
    Q_INVOKABLE bool setReferenceFolderUrl(const QString& folderPath, const QUrl& imageDirUrl);
    Q_INVOKABLE void clearReference(const QString& folderPath);

    // ════════════════════════════════════════════════════════════════
    // (B) 参考文本（CSV）维度 — 与参考图相互独立
    // ════════════════════════════════════════════════════════════════

    // 文本来源类型："csv" / ""（未绑定）；预留 "txt" / "json" 等扩展位
    Q_INVOKABLE QString textKindOf(const QString& folderPath) const;
    Q_INVOKABLE bool hasText(const QString& folderPath) const;
    // 已绑定的 csv 绝对路径
    Q_INVOKABLE QString textPathOf(const QString& folderPath) const;

    // 跟随视频的文本查询：
    //   按"视频在其所在文件夹中的索引"取 csv 第 N 行（不含表头），
    //   返回 { "image": "...", "zh": "...", "en": "...", "row": N+1, "total": M, "raw": "原始拼接" }。
    //   未绑定 / 越界时返回空 map（QML 可用 .row 是否 > 0 判断）。
    Q_INVOKABLE QVariantMap referenceTextForVideo(const QString& videoPath) const;
    // 简易进度文本："N / M"
    Q_INVOKABLE QString textProgressForVideo(const QString& videoPath) const;

    // 在 referenceTextForVideo / textProgressForVideo 计算出的"自动索引"基础上偏移 offset 行
    // 取参考文本（仅 csv 模式生效；越界自动夹紧到 [0, M-1]）。
    // 用途：侧边栏临时浏览参考文本相邻行（与参考图 ◀ ▶ 行为对齐）。
    Q_INVOKABLE QVariantMap referenceTextForVideoOffset(const QString& videoPath, int offset) const;
    Q_INVOKABLE QString textProgressForVideoOffset(const QString& videoPath, int offset) const;
    // csv 模式下文本总行数（不含表头）；未绑定 / 解析失败时为 0；用于 QML 端边界判断
    Q_INVOKABLE int textRowCountForVideo(const QString& videoPath) const;

    // 绑定一个 csv 文件
    Q_INVOKABLE bool setReferenceCsv(const QString& folderPath, const QString& csvPath);
    Q_INVOKABLE bool setReferenceCsvUrl(const QString& folderPath, const QUrl& csvUrl);
    Q_INVOKABLE void clearText(const QString& folderPath);

    // ════════════════════════════════════════════════════════════════
    // 通用
    // ════════════════════════════════════════════════════════════════
    Q_INVOKABLE QStringList allFolders() const;
    Q_INVOKABLE bool isSupportedImage(const QString& path) const;

    // 给"评分汇总"等业务用：枚举给定文件夹下的"视频文件"总数（递归子目录），
    // 复用与播放器一致的视频扩展名集合，结果与 referenceUrlForVideo 计算出的索引口径一致。
    // 不存在/不是目录 → 返回 0。
    Q_INVOKABLE int videoCountInFolder(const QString& folderPath) const;

signals:
    // 参考图发生变化（绑定 / 解绑 / 切换模式）
    void referenceChanged(const QString& folderPath);
    // 参考文本（CSV）发生变化
    void referenceTextChanged(const QString& folderPath);

private:
    // ── 内部数据结构 ────────────────────────────────────────────────
    // 一个文件夹同时拥有图片绑定 + 文本绑定，二者独立。
    struct Entry {
        // 图片维度
        QString kind;       // "image" / "folder" / ""（未绑定）
        QString path;       // 图片或图片文件夹绝对路径
        // 文本维度
        QString textKind;   // "csv" / ""（未绑定）
        QString textPath;   // csv 绝对路径
    };
    QHash<QString, Entry> m_map;
    QString m_settingsFile;

    // ── 内部工具 ─────────────────────────────────────────────────────
    void loadFromDisk();
    void saveToDisk() const;
    static QString normalizeFolder(const QString& folderPath);
    static QString urlOrPathToLocal(const QString& s);

    static QStringList listImages(const QString& dir);
    static QStringList listVideos(const QString& dir);
    static QPair<int, int> videoIndexInDir(const QString& videoPath);

    // CSV 解析：
    //   读取整个文件，识别表头（取第一非空行），返回所有"数据行"，
    //   每行为列名 → 列值的 map。失败时返回空。
    //   兼容 RFC4180：双引号包裹的字段、字段内 "" 转义、\r\n / \n 换行、字段内换行。
    static QList<QVariantMap> parseCsv(const QString& csvPath);
};

} // namespace rbqt
