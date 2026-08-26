#pragma once
/**
 * RatingStore.h — 视频评分本地持久化（CSV，覆盖式）
 *
 * 设计目标：
 *   - 完全独立于播放内核（EngineBridge 一概不知道它的存在）；
 *   - 同一"文件路径"只保留**最新**一条评分（覆盖式），符合用户偏好：
 *     「不会是同一个终端，需要和评分人绑定，可以采取同一文件覆盖式存储最新评分」。
 *   - 评分人由用户在 UI 里设置一次，QSettings 持久化，重启不丢；
 *   - 数据文件按「评分模式」分文件存储，落在 QStandardPaths::AppDataLocation 下：
 *       macOS:   ~/Library/Application Support/PlayerX/ratings_<mode>.csv
 *       Windows: %APPDATA%/PlayerX/ratings_<mode>.csv
 *     当前内置两种模式：
 *       - subjective : 主观评分，5 星制（单视频打星）
 *       - quality    : 质量比较，2 星制（双视频优劣对比）
 *     未来新增模式只要在 modeList 里追加一行即可，不影响已有数据。
 *   - 提供"导出到任意路径"接口，用于交给后端汇总；
 *   - 通过 contextProperty 暴露给 QML，命名空间 "Rating"。
 *
 * CSV 字段（首行表头固定，与历史一致；mode 体现在文件名而非列里，避免每行冗余）：
 *   updated_at,rater,file_name,file_path,file_size,quick_hash,stars
 *
 *   - updated_at: ISO8601 本地时间（含时区偏移）
 *   - rater:      评分人名（用户在 UI 设置；为空则取系统用户名）
 *   - stars:      0..maxStars(mode)；0 = 取消评分（仍记录，便于撤销审计）
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
    // 当前评分模式（"subjective" / "quality" / "off"）。
    //   - "off"：不评分模式；UI 隐藏星条、不写盘；调用 recordRating 安静返回 false。
    //   - 其他：按 mode 路由到独立 CSV 文件；切换 mode 后 dataFilePath / maxStars / totalCount
    //     等都会跟着重算，QML 表格会自动刷新。
    Q_PROPERTY(QString currentMode READ currentMode WRITE setCurrentMode NOTIFY currentModeChanged)
// 当前模式的星级上限（subjective=5 / quality=2 / off=0）。QML 渲染星条的 Repeater model 直接用它。
    Q_PROPERTY(int     maxStars    READ maxStars    NOTIFY currentModeChanged)
    // 可用模式列表（QVariantList of QVariantMap），每项含 id/label/maxStars。
    // QML 端用它生成模式切换菜单 / 下拉，未来加新模式不必改 QML 硬编码。
    Q_PROPERTY(QVariantList modeList READ modeList CONSTANT)
    // 当前模式对应的 CSV 路径（切 mode 后变化）
    Q_PROPERTY(QString dataFilePath READ dataFilePath NOTIFY currentModeChanged)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY changed)
    // 导出 CSV 时 FileDialog 默认弹出的目录（QUrl 字符串，形如 "file:///Users/.../Downloads"）。
    // 跨平台一律落到系统下载目录；若不可用则回退到家目录。
    Q_PROPERTY(QUrl defaultExportDir READ defaultExportDir CONSTANT)

    // 上传到后端的配置项，都持久化在 QSettings 下。
    //   uploadServerUrl: 如 "http://192.168.1.10:2026/upload"；为空表示未配置，用户点上传时
    //                    会被引导填写。
    //   uploadToken    : 可选；后端开了 PLAYERX_TOKEN 时填一致的值，未开可以为空。
    Q_PROPERTY(QString uploadServerUrl READ uploadServerUrl WRITE setUploadServerUrl NOTIFY uploadConfigChanged)
    Q_PROPERTY(QString uploadToken     READ uploadToken     WRITE setUploadToken     NOTIFY uploadConfigChanged)
    // 【开发者本地覆盖】uploadUrlOverridden == true 表示当前 uploadServerUrl/uploadToken
    // 由进程内 override（来源：环境变量 PLAYERX_UPLOAD_URL_DEV / PLAYERX_UPLOAD_TOKEN_DEV）
    // 优先返回，不落 QSettings，也不接受远端 latest.json 的 clientConfig 覆盖。
    // 关掉环境变量重启，行为完全等同旧版；因此开发/联调期间使用完全无副作用。
    // QML 侧用它决定"是否忽略 Updater.clientConfigChanged"，也可用于 UI 上标注"开发者模式"。
    Q_PROPERTY(bool    uploadUrlOverridden READ uploadUrlOverridden CONSTANT)
    // 备注 tag：用于区分同一评分人多轮提交（如 test1 / 公司终评）。
    // 同 (rater, tag) 重复上传时后端返回 409，由 UI 弹窗确认后再带 force=true 重传。
    Q_PROPERTY(QString uploadTag       READ uploadTag       WRITE setUploadTag       NOTIFY uploadConfigChanged)
    // 上传时的组别信息（如 g1/g2），客户端接受任务时自动识别并传递给后端。
    // 后端文件名用此值取代旧的时间戳段。未识别到组别时为空，后端兜底为 gx。
    Q_PROPERTY(QString uploadGroup     READ uploadGroup     WRITE setUploadGroup     NOTIFY uploadConfigChanged)
    // 上传过程状态：QML 按钮可以用它进行 disable / loading 反馈。
    Q_PROPERTY(bool uploading READ uploading NOTIFY uploadingChanged)

public:
    explicit RatingStore(QObject* parent = nullptr);

    // 评分人（持久化在 QSettings 的 "rating/user" 下）
    QString currentUser() const;
    void    setCurrentUser(const QString& name);

    // 当前评分模式（QSettings 持久化在 "rating/mode" 下，默认 "subjective"）
    QString currentMode() const;
    void    setCurrentMode(const QString& mode);
    // 当前模式的星级上限（不在表里则返回 5 兜底）
    int     maxStars() const;
    // 内置模式表（id / label / maxStars）。CONSTANT，进程内不变。
    QVariantList modeList() const;

    // 数据文件绝对路径（保证父目录已建立，对应当前模式）
    QString dataFilePath() const;

    // 导出 CSV 默认目录（QUrl 形式，供 QML FileDialog.currentFolder 绑定）
    QUrl    defaultExportDir() const;

    // 当前条目总数（同 file_path 的覆盖后只算一条）
    int totalCount() const;

public slots:
    // 记录一次评分；若同 filePath 已存在则覆盖；stars=0 也会保留为"已取消"行。
    // filePath 为空 / currentMode == "off" 时不写入，安静返回 false。
    //
    // channelIndex：多路场景下的宏格索引（0-based，-1 = 不提供）。
    // 为了让导出的 CSV 能一眼分辨"哪一路"，
    // 写入时会把 file_name 统一成 "<channel+1>_<原文件名>"的样子（如 "1_xxx.mp4"）。
    // 未传（默认 -1）时保持原为写入原始文件名，保证后向兼容。
    // 该名称仅影响 CSV/评分表这一层，不影响标题栏、文件列表弹窗等其他处的文件名显示。
    //
// stars 会按当前模式的 maxStars 自动截断（quality 模式传 5 → 自动钉为 2）。
    // slideType：可选，多维评分时传 "multi_动作" / "multi_物理" 等，
    //            用于在 CSV 的 slide_type 列区分同一文件的不同维度评分。
    Q_INVOKABLE bool recordRating(const QString& filePath,
                      const QString& fileName,
                      int stars,
                      int channelIndex = -1,
                      const QString& slideType = QString());

    // 记录一次滑动对比评分（quality_slide 模式专用）。
    // 滑动评分独立存储到 ratings_quality_slide.csv（主 CSV），
    // 通过 slide_type 列区分普通打分。每次打分立即持久化。
    // starsL/starsR ∈ {0,1,2}；0 = 取消/未打，也会写入便于审计。
    // 非 quality_slide 模式下调用安静返回 false。
    // slideType：CSV 里 slide_type 列的写入值。
    //   · 推荐传入 "multi_<第二维度key>"（与其他多维打分语义一致，便于服务端展示统一）；
    //   · 兜底：为空时写 "slide"（保持向后兼容）。
    Q_INVOKABLE bool recordSlideRating(const QString& filePathL,
                                       const QString& fileNameL,
                                       int starsL,
                                       const QString& filePathR,
                                       const QString& fileNameR,
                                       int starsR,
                                       const QString& slideType = QString());

    // 查询某文件路径在 *当前评分人 + 当前模式* 下的评分。
    //   · 命中：返回 0..maxStars（含 0 = 已取消评分）
    //   · 未命中 / off 模式：返回 -1
    // 用途：QML 翻组 / 切宫格 / 重新打开文件后，根据新文件路径回填星级显示，
    //       避免上一组的 cellRatings[idx] 残留串到下一组。
    Q_INVOKABLE int ratingFor(const QString& filePath) const;

    // 多维评分专用重载：按 file_path + slide_type 精确查找。
    // slideType 传 "multi_动作" / "multi_物理" 等；未命中返回 -1。
    Q_INVOKABLE int ratingFor(const QString& filePath, const QString& slideType) const;

    // 返回所有评分行（每行一个 QVariantMap，键名同 CSV 列）。
    // 排序：updated_at 倒序（新→旧）。仅返回当前模式的数据。
    QVariantList getAllRatings() const;

    // ── 按指定 mode 只读地读取该模式的数据 ────────────────────
    // 设计动机：QML 端"评分数据"弹窗需要在切换查看 mode 时展示对应 CSV，
    //   但绝对不能修改全局 currentMode（否则背后视频宫格的星条会跟着跳变）。
    //   这三个接口是"完全解耦"的只读入口：不依赖 currentMode，也不发信号。
    //   传入的 mode 与 modeList().id 一致；"off"/未知 mode 一律返回空/兜底值。
    //   路径规则与 ensureFileForMode 完全一致（ratings_<mode>.csv）。
    Q_INVOKABLE QVariantList getAllRatingsForMode(const QString& mode) const;
    Q_INVOKABLE QString      dataFilePathForMode(const QString& mode) const;
    Q_INVOKABLE int          maxStarsForMode(const QString& mode) const;

    // 返回滑动对比评分行（quality_slide 模式专用）。
    // 数据来自 slide/ratings_quality_slide.csv，与普通打分完全隔离。
    // 非 quality_slide 模式下返回空列表。
    Q_INVOKABLE QVariantList getSlideRatings() const;

    // 导出到任意路径（CSV，UTF-8 with BOM，便于 Excel 直接打开中文不乱码）。
    // 成功返回 true。导出的是「当前模式」的数据。
    bool exportToFile(const QString& targetPath) const;

    // 清空当前模式的全部评分（保留表头）
    bool clearAll();

    // 按文件夹批量删除：删除当前模式下所有 file_path 所在目录命中 folderPaths 白名单的行。
    // folderPaths 为空时不做任何修改并返回 false（避免被误用为"全删"，那种语义请直接走 clearAll）。
    // 删除成功后会发 changed() 信号；UI 据此刷新表格。
    Q_INVOKABLE bool removeByFolders(const QStringList& folderPaths);

    // 按文件夹批量归档：与 removeByFolders 命中规则完全一致，但行会先被**搬出**到
    //   <AppData>/PlayerX/archive/<mode>/<batchName>/ratings.csv
    // 然后才从主 CSV 删除；表头与主 CSV 一致，方便日后人工合并/审计。
    // 失败时主 CSV 不会被破坏（先写归档文件，归档文件落盘成功后再回写主 CSV）。
    //
    // batchName：批次文件夹名（用户在 UI 输入，例如 "v2.1_第一轮"）。
    //   - 为空时使用 defaultArchiveBatchName(currentMode()) 兜底；
    //   - 自动剔除非法字符（/ \\ : * ? " < > |）；
    //   - 同名已存在时在末尾追加 _2 / _3 序号防止覆盖。
    //
    // 成功返回 true，并发 changed() 信号；同时通过返回值之外的副作用（CSV 文件）保留数据。
    // 与 removeByFolders 一样：folderPaths 为空 / off 模式 / 没命中任何行 → 返回 false。
    Q_INVOKABLE bool archiveByFolders(const QStringList& folderPaths,
                                      const QString& batchName = {});

    // 推荐的默认批次名：<mode>_yyyyMMdd_HHmmss。
    // 用法：QML 弹"确认归档"对话框前，先用它填充输入框默认值。
    Q_INVOKABLE QString defaultArchiveBatchName(const QString& mode = {}) const;

    // 列出指定模式下所有归档批次（按时间倒序，新→旧）。
    // 返回 [{ name, path, count, latest, raters[], modifiedAt }, ...]：
    //   · name        : 批次文件夹名（QML 端显示用）
    //   · path        : 该批次 ratings.csv 的绝对路径
    //   · count       : CSV 行数（不含表头）
    //   · latest      : 该批次中 updated_at 的最大值（ISO8601 字符串）
    //   · raters      : 评分人去重列表
    //   · modifiedAt  : 该 CSV 文件的最后修改时间（ISO8601 字符串）
    // mode 为空 → 使用 currentMode()；off / 不存在的 mode → 返回空列表。
    Q_INVOKABLE QVariantList listArchiveBatches(const QString& mode = {}) const;

    // 读取某批次 CSV 全部行；返回结构与 getAllRatings 一致（列名相同），
    // updated_at 倒序。批次不存在 / 读不到 → 返回空列表。
    Q_INVOKABLE QVariantList loadArchiveBatch(const QString& mode,
                                              const QString& batchName) const;

    // 删除某批次（连同 ratings.csv 与所在文件夹一起删除，不可逆）。
    // 成功返回 true。
    Q_INVOKABLE bool deleteArchiveBatch(const QString& mode,
                                        const QString& batchName);

    // 行级删除：从某批次 CSV 中删除 file_path ∈ filePathsToRemove 的所有行。
    // 删完若该批次为空，会一并把空文件夹清理掉，避免下拉里残留无意义批次。
    // 成功返回 true（即使没命中任何行也返回 true，调用方根据 deleted 数判断）。
    Q_INVOKABLE bool removeArchiveRows(const QString& mode,
                                       const QString& batchName,
                                       const QStringList& filePathsToRemove);

    // 把某归档批次另存为单 CSV（用户选定路径），与 exportToFile 风格一致：
    // 精简列 updated_at,rater,file_name,stars，UTF-8 with BOM。
    Q_INVOKABLE bool exportArchiveBatch(const QString& mode,
                                        const QString& batchName,
                                        const QString& targetPath) const;

    // 在系统文件管理器中定位 dataFilePath（macOS Finder / Windows 资源管理器）
    void revealInFolder() const;

    // 在系统文件管理器中打开归档目录。
    //   - mode 为空 → 打开归档根目录 <AppData>/PlayerX/archive/
    //   - mode 非空 → 打开 <AppData>/PlayerX/archive/<mode>/
    // 目录不存在时会自动建立，便于用户即使一次都没归档过也能"看一眼归档目录在哪"。
    Q_INVOKABLE void revealArchiveFolder(const QString& mode = {}) const;

    // 平台用户名兑底（当 currentUser 为空时使用）
    // Q_INVOKABLE：QML 端测试源组别自动分配（groupMap）也用同一份兜底身份。
    Q_INVOKABLE QString systemUserName() const;

    // ── 通用 KV 持久化（QSettings 透传）──────────────────────────
    // 复用 RatingStore 已有的 QSettings 实例（与 currentUser 等共用同一份 ini 文件），
    // 给 QML 端任意子模块（如 MultiGroupDialog 的 lanes 配置）提供轻量级
    // "记一下/读一下"能力，避免每个 QML 子组件都引入 Qt.labs.settings 模块或
    // 独立 ini 文件。key 推荐用 "module/field" 形式（如 "multiGroup/lanesJson"）。
    // 写入空字符串等价于"删除该键"，读取不存在的 key 返回 defaultValue。
    Q_INVOKABLE QString loadString(const QString& key, const QString& defaultValue = {}) const;
    Q_INVOKABLE void    saveString(const QString& key, const QString& value);

    // ── 导出/上传 CSV 时的 checklist 白名单过滤 ──────────────────
    // 【背景】checklist 勾选数据在 QSettings 里以 "checklist:<filePath>" 为 key
    //   保存，**不带 mode 前缀**，因此同一个文件在不同模式（如从"多维评分"切到
    //   "测试模式"）下会看到之前模式勾选过的旧数据。导出/上传 CSV 时如果不加过滤，
    //   会把旧模式的 keys 一并写入 checklist 列——尽管当前模式的配置里根本没这些项，
    //   造成"测试模式配置里 checklist 是空的，但上传的 CSV 里 checklist 有值"的问题。
    //
    // 【契约】QML 端在切换 mode / 应用远程配置时调用一次：
    //     · active=false（默认调用 clearExportChecklistWhitelist()）：不过滤，
    //       readChecklistCsvCell 直接返回 QSettings 现值，保留旧行为兼容；
    //     · active=true 且 keys 非空：仅保留 keys 中出现过的 checklist 项，
    //       其他项被丢弃；
    //     · active=true 且 keys 为空：表示"当前模式没有 checklist 配置"，
    //       所有行的 checklist 列全部输出为空字符串。
    // 白名单只影响 CSV 导出结果，不改动 QSettings 存储本身，因此不会误删用户旧数据；
    // 切模式回去仍能看到之前勾选状态。
    Q_INVOKABLE void setExportChecklistWhitelist(const QStringList& keys, bool active);
    Q_INVOKABLE void clearExportChecklistWhitelist();

    // ──上传配置 ──────────────────────────────────────
    QString uploadServerUrl() const;
    void    setUploadServerUrl(const QString& url);
    QString uploadToken() const;
    void    setUploadToken(const QString& token);
    // 是否命中开发者本地 override（环境变量 PLAYERX_UPLOAD_URL_DEV 非空）。
    // 命中时 uploadServerUrl()/uploadToken() 会优先返回内存态 override，
    // 且远端下发的 clientConfig 会被 QML 侧忽略（避免开发时被覆盖）。
    bool    uploadUrlOverridden() const { return m_uploadUrlOverridden; }
    QString uploadTag() const;
    void    setUploadTag(const QString& tag);
    QString uploadGroup() const;
    void    setUploadGroup(const QString& group);
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

    // 把某个归档批次上传到云端：与 uploadToCloud 完全等价的网络/状态/信号链路，
    // 区别仅在于 CSV 数据源——读自 archive/<mode>/<batchName>/ratings.csv，
    // 而不是当前模式的主 CSV。
    //
    // 设计动机：归档批次承载“打分快照”，业务上同样需要交给后端汇总；之前因为
    //   后端目录结构未对齐而暂未开放，本轮按"与 uploadToCloud 同样的精简列+多部分表单"
    //   提交，后端无需改动即可识别。文件名携带 batch 信息便于运维区分。
    //
    // 参数：
    //   · mode       : 归档批次所在的评分模式（"subjective"/"quality"）。空 → 用当前模式。
    //   · batchName  : 批次目录名（与 listArchiveBatches 返回 .name 字段一致）。空 → 拒绝。
    //   · force      : 与 uploadToCloud 一样，true 时携带 force=1 强制覆盖。
    //   · folderPaths: 可选的“文件夹白名单”，与 uploadToCloud 同义；
    //                  归档默认是“完整快照”，UI 可不勾选 = 全量上传，也可按 folder 过滤。
    //
    // 上传中重复调用会被忽略；结果通过 uploadFinished/uploadConflict 信号回调，
    // 与当前 Tab 上传共用同一套 QML 处理链路。
    Q_INVOKABLE void uploadArchiveBatchToCloud(const QString& mode,
                                               const QString& batchName,
                                               bool force = false,
                                               const QStringList& folderPaths = {});

signals:
    void currentUserChanged();
    void currentModeChanged(); // mode 切换：dataFilePath / maxStars / totalCount 都会跟着变
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

public:
    // CSV 字段安全转义（公开仅供归档子模块复用，UI 不应直接调用）
    static QString csvEscape(const QString& s);
    // CSV 单行解析（支持 "..." 内含逗号/双引号转义）
    static QStringList parseCsvLine(const QString& line);

private:

    // 计算 file_size 与 quickHash（前后各 1MB + size 的简短指纹）
    static qint64 fileSizeOf(const QString& path);
    static QString quickHashOf(const QString& path);

    // 在内存里拼出“精简 CSV”（与 exportToFile 完全一致）。上传时复用。
    // folderPaths 非空时仅保留 file_path 所在目录命中白名单的行；空 = 不过滤。
    QByteArray buildExportCsvBytes(const QStringList& folderPaths = {}) const;

    // 在内存里拼出某归档批次的“精简 CSV”，列与 buildExportCsvBytes 完全一致：
    //   updated_at,rater,folder,file_name,stars
    // 数据源换成 archive/<mode>/<batchName>/ratings.csv，因此与归档落盘格式解耦：
    // 即便用户重命名了主 mode 或换了评分人，归档批次也能保留写入瞬间的 rater 身份语义。
    // folderPaths 非空时仅保留 file_path 所在目录命中白名单的行。
    QByteArray buildArchiveExportCsvBytes(const QString& mode,
                                          const QString& batchName,
                                          const QStringList& folderPaths = {}) const;

    // 共享上传发送：拼 multipart、设置头、发起 POST、绑定 finished 回调。
    // 当前 Tab 与归档 Tab 上传都走这里，差异仅在 csvBytes 与 fileNameTag。
    //   · modeNow      : 表单中要带的 mode 字段（与服务端 (user, tag, mode) 唯一性键一致）；
    //                    归档上传也复用所属模式，避免和当前 CSV 混淆。
    //   · csvBytes     : 已经拼好的精简 CSV 字节（含 BOM + 表头 + 数据行）。
    //   · fileNameTag  : 拼到下载文件名里的标签（mode 或 "<mode>__<batch>"），
    //                    后端只是落盘时透传，方便人工区分批次来源。
    //   · force        : 与 uploadToCloud 同义，true 时携带 force=1。
    void postCsvBytesToServer(const QString& modeNow,
                              const QByteArray& csvBytes,
                              const QString& fileNameTag,
                              bool force);

    // 上传前的"服务器探活"：发一次 HEAD（5 秒短超时），用来判断 URL 指向的端口
    // 是否真有进程在监听。设计动机：
    //   · 后端服务没启动时，正式 multipart POST 会等到 30s 超时才反馈，
    //     用户体感"点了上传没任何反应"，而且可能已经放弃等待；
    //   · HEAD 失败 / 5s 超时 → 直接 emit uploadFinished(false, "[NET] ...")，
    //     QML 端识别 [NET] 前缀走模态错误对话框，给出可操作的诊断指引；
    //   · HEAD 成功（即便 404/405 也算"端口通"）→ 走原 postCsvBytesToServer，
    //     上传链路完全不变。
    // 注意：本函数会接管 m_uploading 状态机；探活期间也算"上传中"，
    // 防止用户连点。
    void probeServerThenPost(const QString& modeNow,
                             const QByteArray& csvBytes,
                             const QString& fileNameTag,
                             bool force);

    // 按 mode 计算/确保 CSV 路径存在（建目录、写表头）。返回该模式的绝对路径；
    // 若 mode 是 "off" 或不在 modeList 里，返回空串（调用方需自行兼容）。
    QString ensureFileForMode(const QString& mode) const;
    // 当前模式对应的 CSV 路径（off 模式返回空串）
    QString currentDataFile() const { return ensureFileForMode(currentMode()); }

    // 向指定 CSV 文件写入一条评分（不依赖 currentMode）。
    // csvPath 为空时安静返回 false。
    bool recordRatingToFile(const QString& csvPath,
                            const QString& filePath,
                            const QString& fileName,
                            int stars,
                            int channelIndex = -1);

    QString m_baseDir;    // 数据根目录（AppDataLocation/PlayerX）

    // 【开发者本地 override】进程启动时从环境变量读入，之后不落 QSettings；
    //   · m_uploadUrlOverridden : 是否命中（PLAYERX_UPLOAD_URL_DEV 非空）
    //   · m_uploadUrlOverride   : 覆盖的 URL（例如 http://localhost:2026/）
    //   · m_uploadTokenOverride : 覆盖的 token（可空；仅当 URL 也 override 时才生效）
    // 命中时 uploadServerUrl() / uploadToken() 直接返回内存态值，setUploadServerUrl
    // 拒绝写入以防远端 clientConfig 或 QSettings 里的旧值把它顶掉。
    bool    m_uploadUrlOverridden = false;
    QString m_uploadUrlOverride;
    QString m_uploadTokenOverride;

    // QNetworkAccessManager 懒初始化：不走上传的运行不产生任何网络资源。
    mutable QNetworkAccessManager* m_nam = nullptr;
    bool m_uploading = false;

    // ── 导出/上传时的 checklist 白名单过滤状态 ──
    // 见 setExportChecklistWhitelist 注释。默认关闭（保持旧行为）。
    bool        m_hasExportChecklistWhitelist = false;
    QStringList m_exportChecklistWhitelist;
    // 私有 helper：给定文件在 QSettings 里存的 keys（已解析为 QStringList），
    // 按当前 whitelist 状态过滤后返回逗号连接的字符串（供 CSV 单元格用）。
    QString filterChecklistKeysForExport(const QStringList& rawKeys) const;
    // 私有 helper：从 QSettings 读回某文件的 checklist（JSON 数组），
    // 经白名单过滤后返回逗号连接的字符串。主 CSV 的 checklist 列用它。
    QString readChecklistCell(const QString& filePath) const;
};

} // namespace rbqt
