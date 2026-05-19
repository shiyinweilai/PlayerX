/**
 * FsUtils.h — 仅供 QML "多组对比模式" 配置面板使用的文件系统工具
 *
 * 设计原则：
 *   - 与 EngineBridge / 播放内核完全解耦：本类只做"列出目录下所有视频文件"，
 *     不持有任何引擎状态、不调用 Engine 任何接口；
 *   - 通过 contextProperty 暴露给 QML，命名空间 "Fs"；
 *   - 平台无关：QDirIterator + 扩展名白名单。
 *
 * 仅在多组配置面板内被调用；非多组路径完全不会触达此类，单组模式行为零变化。
 */
#pragma once

#include <QObject>
#include <QStringList>
#include <QUrl>

namespace rbqt {

class FsUtils : public QObject {
    Q_OBJECT
public:
    explicit FsUtils(QObject* parent = nullptr) : QObject(parent) {}

    // 递归扫描 dir 下所有视频文件（白名单匹配扩展名，大小写不敏感）。
    // 返回排序后的绝对路径列表（升序）。dir 不存在或不是目录时返回空列表。
    Q_INVOKABLE QStringList scanVideoFolder(const QUrl& dir, bool recursive = true) const;

    // 与 scanVideoFolder 相同，但接受字符串路径（拖拽场景下 QML 端拿到的可能是裸路径）。
    Q_INVOKABLE QStringList scanVideoFolderPath(const QString& dirPath, bool recursive = true) const;

    // 判断给定 URL/路径是否是文件夹。
    Q_INVOKABLE bool isDirectory(const QUrl& url) const;
    Q_INVOKABLE bool isDirectoryPath(const QString& path) const;

    // 工具：把 QStringList<绝对路径> 转换成 QList<QUrl>，方便 QML 直接传给 Engine.openFiles。
    Q_INVOKABLE QList<QUrl> toFileUrls(const QStringList& paths) const;

    // 工具：用 includes 过滤（小写不敏感，关键字为空返回原列表）。
    Q_INVOKABLE QStringList filterByKeyword(const QStringList& paths, const QString& keyword) const;

    // 工具：取路径文件名部分。
    Q_INVOKABLE QString fileName(const QString& path) const;

    // 工具：把 QUrl（典型来自 QML FolderDialog/FileDialog）转成平台本地路径。
    // 跨平台正确：macOS 返回 "/Users/..."，Windows 返回 "C:/Users/..."。
    // QML 端禁止用 url.toString().substring(7) 之类的字符串截断方式，那在 Windows
    // 上会产生 "/C:/..."（多一个前导斜杠）导致扫描失败。
    Q_INVOKABLE QString urlToLocalFile(const QUrl& url) const;

    // ── 应用级 cache 目录 + 通用文本读写 ─────────────────────────
    // 用于持久化"轻量配置"（lanes JSON、面板状态等），用户可见、可手工清理，
    // 跨平台一致（macOS 在 ~/Library/Caches/PlayerX，Windows 在 %LOCALAPPDATA%/PlayerX/cache）。
    // 调用时若目录不存在会自动 mkpath；返回绝对路径，末尾不带斜杠。
    Q_INVOKABLE QString appCacheDir() const;

    // 写入文本文件（UTF-8，无 BOM，覆盖式）。父目录会自动创建。
    // 成功返回 true；filePath 为空或写入失败返回 false。
    Q_INVOKABLE bool writeTextFile(const QString& filePath, const QString& text) const;

    // 读取文本文件（按 UTF-8 解码）。文件不存在或读失败时返回空字符串。
    Q_INVOKABLE QString readTextFile(const QString& filePath) const;

    // 文件是否存在（filePath 为空返回 false）。
    Q_INVOKABLE bool fileExists(const QString& filePath) const;

    // ── 日志目录 + 文件管理器揭示 ────────────────────────────────
    // 应用日志目录（在 appCacheDir 下的 "logs" 子目录），用于排查问题。
    //   macOS:   ~/Library/Caches/PlayerX/logs
    //   Windows: %LOCALAPPDATA%/PlayerX/cache/logs
    //   Linux:   ~/.cache/PlayerX/logs
    // 不存在会自动创建。返回绝对路径，末尾不带斜杠。
    Q_INVOKABLE QString appLogDir() const;

    // 在系统文件管理器中"打开并选中"指定路径（Finder/Explorer/Files）。
    // 若选中失败（例如 Linux 下 xdg-open 不支持），退化为打开父目录。
    // path 为目录则直接打开该目录。返回 true 表示已发起 reveal 请求。
    Q_INVOKABLE bool revealInFileManager(const QString& path) const;
};

} // namespace rbqt
