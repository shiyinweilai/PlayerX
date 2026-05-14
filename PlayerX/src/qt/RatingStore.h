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

class QNetworkAccessManager;
class QNetworkReply;

namespace rbqt {

class RatingStore : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString currentUser READ currentUser WRITE setCurrentUser NOTIFY currentUserChanged)
    Q_PROPERTY(QString dataFilePath READ dataFilePath CONSTANT)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY changed)
    // 导出 CSV 时 FileDialog 默认弹出的目录（QUrl 字符串，形如 "file:///Users/.../Downloads"）。
    // 跨平台一律落到系统下载目录；若不可用则回退到家目录。
    Q_PROPERTY(QUrl defaultExportDir READ defaultExportDir CONSTANT)

    // 上传到后端的配置项，都持久化在 QSettings 下。
    //   uploadServerUrl: 如 "http://192.168.1.10:8765/upload"；为空表示未配置，用户点上传时
    //                    会被引导填写。
    //   uploadToken    : 可选；后端开了 PLAYERX_TOKEN 时填一致的值，未开可以为空。
    Q_PROPERTY(QString uploadServerUrl READ uploadServerUrl WRITE setUploadServerUrl NOTIFY uploadConfigChanged)
    Q_PROPERTY(QString uploadToken     READ uploadToken     WRITE setUploadToken     NOTIFY uploadConfigChanged)
    // 备注 tag：用于区分同一评分人多轮提交（如 test1 / 公司终评）。
    // 同 (rater, tag) 重复上传时后端返回 409，由 UI 弹窗确认后再带 force=true 重传。
    Q_PROPERTY(QString uploadTag       READ uploadTag       WRITE setUploadTag       NOTIFY uploadConfigChanged)
    // 上传过程状态：QML 按钮可以用它进行 disable / loading 反馈。
    Q_PROPERTY(bool uploading READ uploading NOTIFY uploadingChanged)

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
    //
    // channelIndex：多路场景下的宏格索引（0-based，-1 = 不提供）。
    // 为了让导出的 CSV 能一眼分辨"哪一路"，
    // 写入时会把 file_name 统一成 "<channel+1>_<原文件名>"的样子（如 "1_xxx.mp4"）。
    // 未传（默认 -1）时保持原为写入原始文件名，保证后向兼容。
    // 该名称仅影响 CSV/评分表这一层，不影响标题栏、文件列表弹窗等其他处的文件名显示。
    bool recordRating(const QString& filePath,
                      const QString& fileName,
                      int stars,
                      int channelIndex = -1);

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

    // 平台用户名兑底（当 currentUser 为空时使用）
    QString systemUserName() const;

    // ──上传配置 ──────────────────────────────────────
    QString uploadServerUrl() const;
    void    setUploadServerUrl(const QString& url);
    QString uploadToken() const;
    void    setUploadToken(const QString& token);
    QString uploadTag() const;
    void    setUploadTag(const QString& tag);
    bool    uploading() const { return m_uploading; }

    // 上传一份“精简 CSV”到 uploadServerUrl（与 exportToFile 写出的完全一致：
    //   updated_at,rater,file_name,stars，不含 file_path / quick_hash）。
    //   · 导出时 rater 列**强制使用** currentUser（若为空则取系统用户名），
    //     不再沿用 CSV 里历史写入的旧 rater——避免用户改名后“名义不一致”。
    //   · force=false（默认）：服务端检测 (rater, tag) 已存在会返回 409，
    //     SDK 解析后通过 uploadConflict(existing) 信号告知 QML 弹覆盖确认。
    //   · force=true：携带 force=1 强制覆盖，旧文件会被服务端归档。
    //   · folderPaths：可选的“文件夹白名单”。非空时只上传 file_path 所在目录
    //     在白名单中的记录；空 = 不过滤（默认全部上传），保持向后兼容。
    //     主要供 UI 端“按文件夹勾选上传”使用。
    // 调用后立即返回，用 uploadFinished(ok, message) 信号给出最终结果。
    // 在上传进行中重复调用会被忽略（避免连点手抽出多起请求）。
    Q_INVOKABLE void uploadToCloud(bool force = false,
                                   const QStringList& folderPaths = {});

signals:
    void currentUserChanged();
    void changed();   // 任何写入/清空都会触发，QML 表格可绑定刷新

    // 上传相关信号
    void uploadConfigChanged();
    void uploadingChanged();
    void uploadStarted();
    // ok=true 时 message 为后端返回的文件名或简要信息；ok=false 时 message 为错误描述。
    void uploadFinished(bool ok, const QString& message);
    // 服务端返回 409 (needConfirm) 时触发；message 是后端给的人话，QML 据此弹“是否覆盖”确认
    // 用户确认后再调用 uploadToCloud(true) 强制覆盖。
    void uploadConflict(const QString& message);
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

    // 在内存里拼出“精简 CSV”（与 exportToFile 完全一致）。上传时复用。
    // folderPaths 非空时仅保留 file_path 所在目录命中白名单的行；空 = 不过滤。
    QByteArray buildExportCsvBytes(const QStringList& folderPaths = {}) const;

    QString m_dataFile;   // 绝对路径（构造时计算并 mkpath）

    // QNetworkAccessManager 懒初始化：不走上传的运行不产生任何网络资源。
    mutable QNetworkAccessManager* m_nam = nullptr;
    bool m_uploading = false;
};

} // namespace rbqt
