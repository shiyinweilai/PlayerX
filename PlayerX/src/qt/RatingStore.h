#pragma once
/**
 * RatingStore.h — 视频评分本地持久化（CSV，覆盖式）
 *
 * 设计目标：
 *   - 完全独立于播放内核（EngineBridge 一概不知道它的存在）；
 *   - 同一"文件路径"只保留**最新**一条评分（覆盖式），符合用户偏好：
 *     「不会是同一个终端，需要和评分人绑定，可以采取同一文件覆盖式存储最新评分」。
 *   - 评分人由用户在 UI 里设置一次，QSettings 持久化，重启不丢；
 *   - 数据文件落在 QStandardPaths::AppDataLocation 下：
 *       macOS:   ~/Library/Application Support/PlayerX/ratings.csv
 *       Windows: %APPDATA%/PlayerX/ratings.csv
 *   - 提供"导出到任意路径"接口，用于交给后端汇总；
 *   - 通过 contextProperty 暴露给 QML，命名空间 "Rating"。
 *
 * CSV 字段（首行表头固定）：
 *   updated_at,rater,file_name,file_path,file_size,quick_hash,stars
 *
 *   - updated_at: ISO8601 本地时间（含时区偏移）
 *   - rater:      评分人名（用户在 UI 设置；为空则取系统用户名）
 *   - stars:      0-5；0 = 取消评分（仍记录，便于撤销审计）
 */

#include <QObject>
#include <QString>
#include <QUrl>
#include <QVariantList>

namespace rbqt {

class RatingStore : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString currentUser READ currentUser WRITE setCurrentUser NOTIFY currentUserChanged)
    Q_PROPERTY(QString dataFilePath READ dataFilePath CONSTANT)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY changed)
    // 导出 CSV 时 FileDialog 默认弹出的目录（QUrl 字符串，形如 "file:///Users/.../Downloads"）。
    // 跨平台一律落到系统下载目录；若不可用则回退到家目录。
    Q_PROPERTY(QUrl defaultExportDir READ defaultExportDir CONSTANT)

public:
    explicit RatingStore(QObject* parent = nullptr);

    // 评分人（持久化在 QSettings 的 "rating/user" 下）
    QString currentUser() const;
    void    setCurrentUser(const QString& name);

    // 数据文件绝对路径（保证父目录已建立）
    QString dataFilePath() const { return m_dataFile; }

    // 导出 CSV 默认目录（QUrl 形式，供 QML FileDialog.currentFolder 绑定）
    QUrl    defaultExportDir() const;

    // 当前条目总数（同 file_path 的覆盖后只算一条）
    int totalCount() const;

public slots:
    // 记录一次评分；若同 filePath 已存在则覆盖；stars=0 也会保留为"已取消"行。
    // filePath 为空时不写入，安静返回 false。
    bool recordRating(const QString& filePath,
                      const QString& fileName,
                      int stars);

    // 查询某文件路径在 *当前评分人* 下的评分。
    //   · 命中：返回 0-5（含 0 = 已取消评分）
    //   · 未命中：返回 -1
    // 用途：QML 翻组 / 切宫格 / 重新打开文件后，根据新文件路径回填星级显示，
    //       避免上一组的 cellRatings[idx] 残留串到下一组。
    int ratingFor(const QString& filePath) const;

    // 返回所有评分行（每行一个 QVariantMap，键名同 CSV 列）。
    // 排序：updated_at 倒序（新→旧）。
    QVariantList getAllRatings() const;

    // 导出到任意路径（CSV，UTF-8 with BOM，便于 Excel 直接打开中文不乱码）。
    // 成功返回 true。
    bool exportToFile(const QString& targetPath) const;

    // 清空全部评分（保留表头）
    bool clearAll();

    // 在系统文件管理器中定位 dataFilePath（macOS Finder / Windows 资源管理器）
    void revealInFolder() const;

    // 平台用户名兜底（当 currentUser 为空时使用）
    QString systemUserName() const;

signals:
    void currentUserChanged();
    void changed();   // 任何写入/清空都会触发，QML 表格可绑定刷新

private:
    // 把 vector<map> 整体重写到 CSV（覆盖式）
    bool writeAll(const QList<QVariantMap>& rows) const;
    // 读全部行，文件不存在返回空列表
    QList<QVariantMap> readAll() const;

    // CSV 字段安全转义
    static QString csvEscape(const QString& s);
    // CSV 单行解析（支持 "..." 内含逗号/双引号转义）
    static QStringList parseCsvLine(const QString& line);

    // 计算 file_size 与 quickHash（前后各 1MB + size 的简短指纹）
    static qint64 fileSizeOf(const QString& path);
    static QString quickHashOf(const QString& path);

    QString m_dataFile;   // 绝对路径（构造时计算并 mkpath）
};

} // namespace rbqt
