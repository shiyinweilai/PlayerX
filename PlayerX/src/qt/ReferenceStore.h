/**
 * ReferenceStore.h — 文件夹「参考资料」本地持久化（仅供 QML 侧边栏 / MultiGroupRow 使用）
 *
 * 设计要点：
 *   - 与 EngineBridge / 播放内核完全解耦：只做「视频所在文件夹 → 参考资料来源」的映射；
 *   - 「参考资料」分为两个独立维度，互不干扰：
 *       (A) 参考图（N 个槽位，1..kMaxSlots，默认 9）：
 *           · "image"   ：一张固定图片
 *           · "folder"  ：一个图片文件夹，按"当前视频在其所在文件夹中的索引"取同序号图片
 *           · "grouped" ：「分组多图」模式 —— 根目录下两级结构
 *                          根/组A/{图1,图2,...}
 *                          根/组B/{图1,图2,...}
 *                         所有图被拉直成一条「长队列」（按子组自然序、组内自然序拼接）。
 *                         · 跟随对比组切换时：跳到该视频组对应子组的「组首张」
 *                           （先按子组名 == 视频文件夹名匹配，匹配不到按索引顺序回退）；
 *                         · ◀ ▶ 在长队列上 ±1，可跨组无缝翻图，到队首/队尾停住；
 *                         · 与 "folder" 共享同一组对外接口（offset / count），
 *                           上层 QML 几乎不用区分。
 *       (B) 参考文本（CSV）：
 *           · "csv"    ：一个 CSV 文件，按"当前视频索引"取同序号行；
 *                        优先识别列名 prompt / en_prompt / Image，
 *                        对应展示中文 prompt、英文 prompt 与图片名。
 *   - 持久化：QSettings (ini)，folder 路径用 base64 作 key，避免 "/" 与 QSettings 子组冲突；
 *   - 通过 contextProperty 暴露给 QML，命名空间 "Reference"。
 *
 * 槽位说明（v4）：
 *   - 参考图从「固定 2 个槽位」泛化为 N 个（1..9），每个槽位独立绑定、独立翻图；
 *   - ini 字段：槽位 1 用旧名 kind/path（兼容 v3），槽位 n≥2 用 kindN/pathN
 *     （槽位 2 的 kind2/path2 与 v3 完全同名，天然兼容）；
 *   - 旧的槽位 1 / 槽位 2 专属 API（kindOf / kindOf2 等）保留为泛化 API 的薄包装，
 *     现存调用方零改动即可继续工作。
 */
#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QHash>
#include <QVariantMap>
#include <QVector>
#include <QPair>

namespace rbqt {

class ReferenceStore : public QObject {
    Q_OBJECT
public:
    explicit ReferenceStore(QObject* parent = nullptr);
    ~ReferenceStore() override;

    // ════════════════════════════════════════════════════════════════
    // (A) 参考图：N 槽位通用 API（slot 为 1 起始的槽位号）
    // ════════════════════════════════════════════════════════════════

    // 槽位上限（与客户端最大路数一致）
    Q_INVOKABLE int maxSlots() const;

    // 某文件夹已绑定的槽位数量（= 最后一个非空槽位的序号；中间允许空洞）
    Q_INVOKABLE int slotCountOf(const QString& folderPath) const;

    // 取某文件夹某槽位的来源类型："image" / "folder" / "grouped" / ""（未绑定）
    Q_INVOKABLE QString kindOfAt(const QString& folderPath, int slot) const;
    Q_INVOKABLE bool hasReferenceAt(const QString& folderPath, int slot) const;

    // 跟随视频的图片查询（同槽位 1 语义，按 slot 区分）：
    //   · image  → 固定图；
    //   · folder → 按视频索引 + offset 取图（越界循环回绕）；
    //   · grouped→ 按组首 + offset 在长队列上取图。
    Q_INVOKABLE QUrl referenceUrlForVideoOffsetAt(const QString& videoPath, int offset, int slot) const;
    Q_INVOKABLE QString referenceProgressForVideoOffsetAt(const QString& videoPath, int offset, int slot) const;
    Q_INVOKABLE int referenceImageCountForVideoAt(const QString& videoPath, int slot) const;

    // 写入（按槽位）
    Q_INVOKABLE bool setReferenceAt(const QString& folderPath, const QString& imagePath, int slot);
    Q_INVOKABLE bool setReferenceUrlAt(const QString& folderPath, const QUrl& imageUrl, int slot);
    Q_INVOKABLE bool setReferenceFolderAt(const QString& folderPath, const QString& imageDir, int slot);
    Q_INVOKABLE bool setReferenceFolderUrlAt(const QString& folderPath, const QUrl& imageDirUrl, int slot);
    // 「分组多图」模式（按槽位）
    Q_INVOKABLE bool setGroupedFolderAt(const QString& folderPath, const QString& rootDir, int slot);
    Q_INVOKABLE bool setGroupedFolderUrlAt(const QString& folderPath, const QUrl& rootDirUrl, int slot);
    Q_INVOKABLE bool isGroupedAt(const QString& folderPath, int slot) const;
    Q_INVOKABLE QString groupedRootOfAt(const QString& folderPath, int slot) const;
    Q_INVOKABLE void clearReferenceAt(const QString& folderPath, int slot);

    // ════════════════════════════════════════════════════════════════
    // (A-legacy) 参考图 槽位 1 / 槽位 2 旧 API —— 泛化 API 的薄包装，行为不变
    // ════════════════════════════════════════════════════════════════
    Q_INVOKABLE QString kindOf(const QString& folderPath) const;
    Q_INVOKABLE bool hasReference(const QString& folderPath) const;
    Q_INVOKABLE QString referenceOf(const QString& folderPath) const;
    Q_INVOKABLE QUrl referenceUrlOf(const QString& folderPath) const;

    Q_INVOKABLE QUrl referenceUrlForVideo(const QString& videoPath) const;
    Q_INVOKABLE QString referenceProgressForVideo(const QString& videoPath) const;
    Q_INVOKABLE QUrl referenceUrlForVideoOffset(const QString& videoPath, int offset) const;
    Q_INVOKABLE QString referenceProgressForVideoOffset(const QString& videoPath, int offset) const;
    Q_INVOKABLE int referenceImageCountForVideo(const QString& videoPath) const;

    Q_INVOKABLE bool setReference(const QString& folderPath, const QString& imagePath);
    Q_INVOKABLE bool setReferenceUrl(const QString& folderPath, const QUrl& imageUrl);
    Q_INVOKABLE bool setReferenceFolder(const QString& folderPath, const QString& imageDir);
    Q_INVOKABLE bool setReferenceFolderUrl(const QString& folderPath, const QUrl& imageDirUrl);
    Q_INVOKABLE bool setGroupedFolder(const QString& folderPath, const QString& rootDir);
    Q_INVOKABLE bool setGroupedFolderUrl(const QString& folderPath, const QUrl& rootDirUrl);
    Q_INVOKABLE bool isGrouped(const QString& folderPath) const;
    Q_INVOKABLE QString groupedRootOf(const QString& folderPath) const;
    Q_INVOKABLE void clearReference(const QString& folderPath);

    // 槽位 2 旧 API（v3 时代硬编码的下半区窗口）
    Q_INVOKABLE QString kindOf2(const QString& folderPath) const;
    Q_INVOKABLE bool hasReference2(const QString& folderPath) const;
    Q_INVOKABLE QUrl referenceUrlForVideo2(const QString& videoPath) const;
    Q_INVOKABLE QString referenceProgressForVideo2(const QString& videoPath) const;
    Q_INVOKABLE QUrl referenceUrlForVideoOffset2(const QString& videoPath, int offset) const;
    Q_INVOKABLE QString referenceProgressForVideoOffset2(const QString& videoPath, int offset) const;
    Q_INVOKABLE int referenceImageCountForVideo2(const QString& videoPath) const;
    Q_INVOKABLE bool setReference2(const QString& folderPath, const QString& imagePath);
    Q_INVOKABLE bool setReferenceUrl2(const QString& folderPath, const QUrl& imageUrl);
    Q_INVOKABLE bool setReferenceFolder2(const QString& folderPath, const QString& imageDir);
    Q_INVOKABLE bool setReferenceFolderUrl2(const QString& folderPath, const QUrl& imageDirUrl);
    Q_INVOKABLE bool setGroupedFolder2(const QString& folderPath, const QString& rootDir);
    Q_INVOKABLE bool setGroupedFolderUrl2(const QString& folderPath, const QUrl& rootDirUrl);
    Q_INVOKABLE bool isGrouped2(const QString& folderPath) const;
    Q_INVOKABLE QString groupedRootOf2(const QString& folderPath) const;
    Q_INVOKABLE void clearReference2(const QString& folderPath);

    // ════════════════════════════════════════════════════════════════
    // (B) 参考文本（CSV）维度 — 与参考图相互独立
    // ════════════════════════════════════════════════════════════════

    Q_INVOKABLE QString textKindOf(const QString& folderPath) const;
    Q_INVOKABLE bool hasText(const QString& folderPath) const;
    Q_INVOKABLE QString textPathOf(const QString& folderPath) const;

    // 返回 { "image": "...", "zh": "...", "en": "...", "row": N+1, "total": M, "raw": "原始拼接" }。
    Q_INVOKABLE QVariantMap referenceTextForVideo(const QString& videoPath) const;
    Q_INVOKABLE QString textProgressForVideo(const QString& videoPath) const;
    Q_INVOKABLE QVariantMap referenceTextForVideoOffset(const QString& videoPath, int offset) const;
    Q_INVOKABLE QString textProgressForVideoOffset(const QString& videoPath, int offset) const;
    Q_INVOKABLE int textRowCountForVideo(const QString& videoPath) const;

    Q_INVOKABLE bool setReferenceCsv(const QString& folderPath, const QString& csvPath);
    Q_INVOKABLE bool setReferenceCsvUrl(const QString& folderPath, const QUrl& csvUrl);
    Q_INVOKABLE void clearText(const QString& folderPath);

    // ════════════════════════════════════════════════════════════════
    // 通用
    // ════════════════════════════════════════════════════════════════
    Q_INVOKABLE QStringList allFolders() const;
    Q_INVOKABLE bool isSupportedImage(const QString& path) const;
    Q_INVOKABLE int videoCountInFolder(const QString& folderPath) const;

signals:
    // 任一槽位参考图发生变化（绑定 / 解绑 / 切换模式）
    void referenceSlotChanged(const QString& folderPath, int slot);
    // 参考文本（CSV）发生变化
    void referenceTextChanged(const QString& folderPath);
    // 旧信号（槽位 1 / 槽位 2）继续发射，兼容外部既有监听
    void referenceChanged(const QString& folderPath);
    void reference2Changed(const QString& folderPath);

private:
    // ── 内部数据结构 ────────────────────────────────────────────────
    // 一个文件夹同时拥有 N 个图片槽位 + 文本绑定，二者独立。
    struct Entry {
        // 图片维度：imgSlots[i] = 第 i+1 槽位的 {kind, path}
        QVector<QPair<QString, QString>> imgSlots;   // kind: "image"/"folder"/"grouped"
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
    static bool isValidKind(const QString& kind);

    // 取 Entry 的第 slot 槽位（1 起始）；越界 / 未绑定返回 {"",""}
    static QPair<QString, QString> imgSlotOf(const Entry& e, int slot);
    // 写入第 slot 槽位（1 起始；越界静默失败），返回是否变化
    static bool setImgSlot(Entry& e, int slot, const QString& kind, const QString& path);
    // 清空第 slot 槽位；全部槽位与文本均空时返回 true（调用方据此移除 Entry）
    static bool clearImgSlot(Entry& e, int slot);
    // Entry 是否完全为空
    static bool entryIsEmpty(const Entry& e);

    // 槽位查询核心实现（kind/path 由 imgSlotOf 解出）
    QUrl urlForVideoOffsetImpl(const QString& videoPath, int offset,
                               const QString& kind, const QString& path) const;
    QString progressForVideoOffsetImpl(const QString& videoPath, int offset,
                                        const QString& kind, const QString& path) const;
    int imageCountImpl(const QString& videoPath,
                       const QString& kind, const QString& path) const;
    QString kindValidated(const QString& kind, const QString& path) const;
    QString groupedRootValidated(const QString& path) const;

    // 写入核心（校验 + 落盘 + 发信号）
    bool setSlotEntry(const QString& folderPath, int slot,
                      const QString& kind, const QString& localPath);

    static QStringList listImages(const QString& dir);
    static QStringList listVideos(const QString& dir);
    static QPair<int, int> videoIndexInDir(const QString& videoPath);

    // ── 分组多图工具 ─────────────────────────────────────────────
    static QStringList listSubGroups(const QString& rootDir);
    static QStringList listGroupedImages(const QString& rootDir);
    static QPair<int, int> groupedBaseIndexForVideo(const QString& videoPath,
                                                    const QString& rootDir);

    // CSV 解析（RFC4180 兼容）
    static QList<QVariantMap> parseCsv(const QString& csvPath);
};

} // namespace rbqt
