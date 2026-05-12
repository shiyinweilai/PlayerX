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
};

} // namespace rbqt
