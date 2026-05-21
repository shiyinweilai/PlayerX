/**
 * ReferenceStore.h — 文件夹「参考资料」本地持久化（仅供 QML 侧边栏 / MultiGroupRow 使用）
 *
 * 设计要点：
 *   - 与 EngineBridge / 播放内核完全解耦：只做「视频所在文件夹 → 参考资料来源」的映射；
 *   - 「参考资料」分为两个独立维度，互不干扰：
 *       (A) 参考图：
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
    // 「分组多图」模式：rootDir 下两级结构（rootDir/组X/图Y）
    Q_INVOKABLE bool setGroupedFolder(const QString& folderPath, const QString& rootDir);
    Q_INVOKABLE bool setGroupedFolderUrl(const QString& folderPath, const QUrl& rootDirUrl);
    Q_INVOKABLE bool isGrouped(const QString& folderPath) const;
    Q_INVOKABLE QString groupedRootOf(const QString& folderPath) const;
    Q_INVOKABLE void clearReference(const QString& folderPath);

    // ════════════════════════════════════════════════════════════════
    // (A2) 参考图 槽位 2（独立于槽位 1，行为完全对等）
    //
    // 设计动机：
    //   左侧栏需要同时展示「两份」参考图（如原型图 + 草图），二者各自独立绑定，
    //   都跟随对比组同步切换。这里的接口是「槽位 1」的完全镜像，
    //   持久化字段为 kind2 / path2，与 kind/path 不冲突。
    // ════════════════════════════════════════════════════════════════
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
    // 「分组多图」模式（槽位 2）
    Q_INVOKABLE bool setGroupedFolder2(const QString& folderPath, const QString& rootDir);
    Q_INVOKABLE bool setGroupedFolderUrl2(const QString& folderPath, const QUrl& rootDirUrl);
    Q_INVOKABLE bool isGrouped2(const QString& folderPath) const;
    Q_INVOKABLE QString groupedRootOf2(const QString& folderPath) const;
    Q_INVOKABLE void clearReference2(const QString& folderPath);

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
    // 参考图（槽位 2）发生变化
    void reference2Changed(const QString& folderPath);

private:
    // ── 内部数据结构 ────────────────────────────────────────────────
    // 一个文件夹同时拥有图片绑定 + 文本绑定，二者独立。
    struct Entry {
        // 图片维度（槽位 1）
        QString kind;       // "image" / "folder" / "grouped" / ""（未绑定）
        QString path;       // image: 图片绝对路径；folder: 图片文件夹；grouped: 分组根目录
        // 图片维度（槽位 2，与槽位 1 完全独立）
        QString kind2;      // "image" / "folder" / "grouped" / ""（未绑定）
        QString path2;      // 同上（槽位 2）
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

    // ── 分组多图工具 ─────────────────────────────────────────────
    // 列出 rootDir 下的所有子目录（自然序，仅一级）
    static QStringList listSubGroups(const QString& rootDir);
    // 把 rootDir/组A/{图...}, rootDir/组B/{图...} 拼成一条长队列（图绝对路径）
    static QStringList listGroupedImages(const QString& rootDir);
    // 给定视频，决定其在 grouped 长队列中的「组首」下标 base：
    //   1) 先按子组名 == 视频所在文件夹名（不区分大小写）匹配；
    //   2) 匹配不到，按视频组在「视频根目录的子目录列表」中的索引回退到分组列表的同序号；
    //   3) 仍失败 → 返回 0（落在第一张）。
    // 同时返回总长度，便于上层做边界 / 进度计算。
    static QPair<int, int> groupedBaseIndexForVideo(const QString& videoPath,
                                                    const QString& rootDir);

    // CSV 解析：
    //   读取整个文件，识别表头（取第一非空行），返回所有"数据行"，
    //   每行为列名 → 列值的 map。失败时返回空。
    //   兼容 RFC4180：双引号包裹的字段、字段内 "" 转义、\r\n / \n 换行、字段内换行。
    static QList<QVariantMap> parseCsv(const QString& csvPath);
};

} // namespace rbqt
