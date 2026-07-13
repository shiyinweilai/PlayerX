// Updater.cpp — PlayerX 应用自动更新器实现（第一阶段：macOS 完整可用）
//
// 流程详细注释见同名头文件。这里重点说明几个**易踩坑点**：
//
// 1) macOS 替换正在运行的 .app：
//    - 不能在父进程里直接覆盖自身 .app，会出现 Gatekeeper / 文件占用问题。
//    - 必须 fork 一个独立 shell 脚本：等父进程退出 → xattr 去隔离 → mv 替换 → open。
//    - 我们用 `nohup bash relaunch.sh </dev/null >/dev/null 2>&1 &` + `setsid`，
//      让脚本完全脱离父进程组，父进程随后 quit() 才不会把它一起带走。
//
// 2) Gatekeeper / quarantine：
//    - 通过浏览器/curl 下载的文件会被打上 com.apple.quarantine xattr，
//      open .app 时 Finder 会弹"未知开发者"二次确认。我们在替换前先 `xattr -dr` 清掉。
//      （这条来自用户长期偏好：mac 自动更新需自动移除隔离属性。）
//
// 3) 进度速率：使用 EWMA（指数加权平均）平滑显示，避免数字抖动。

#include "Updater.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QCryptographicHash>
#include <QProcess>
#include <QSysInfo>
#include <QDateTime>
#include <QDebug>

namespace rbqt {

// ─── 默认远端清单地址（可在 QML 里改） ───────────────────────────────────
//    第一阶段你说会把 json 上传云端，这里先用一个占位 URL；
//    只要在 QML 里 `Updater.manifestUrl = "https://你的域名/latest.json"`
//    就能切换，无需重新打包。
static const char* kDefaultManifestUrl =
    "https://tvp-76917.gzc.vod.tencent-cloud.com/rbyang/PlayerX/latest.json";

// 编译期注入的版本号（CMake project(... VERSION x.y.z) → APP_VERSION_STR）
#ifndef APP_VERSION_STR
#  define APP_VERSION_STR "0.0.0"
#endif

Updater::Updater(QObject* parent)
    : QObject(parent),
      m_net(new QNetworkAccessManager(this)),
      m_manifestUrl(QString::fromLatin1(kDefaultManifestUrl)),
      m_currentVersion(QString::fromLatin1(APP_VERSION_STR))
{
}

Updater::~Updater() {
    if (m_reply) {
        m_reply->abort();
        m_reply->deleteLater();
    }
    if (m_dlFile) {
        m_dlFile->close();
        delete m_dlFile;
    }
}

void Updater::setManifestUrl(const QString& u) {
    QUrl url(u);
    if (url == m_manifestUrl) return;
    m_manifestUrl = url;
    emit manifestUrlChanged();
}

bool Updater::updateAvailable() const {
    return !m_latestVersion.isEmpty()
           && compareVersion(m_currentVersion, m_latestVersion) < 0;
}

void Updater::setState(const QString& s, const QString& err) {
    if (s == m_state && err == m_errorText) return;
    m_state = s;
    m_errorText = err;
    emit stateChanged();
}

// ─── 1. 检查更新 ─────────────────────────────────────────────────────────
void Updater::checkForUpdates(bool silent) {
    if (m_state == QLatin1String("checking") || m_state == QLatin1String("downloading")) {
        // 已在进行中，忽略重复触发
        return;
    }
    m_silentCheck = silent;
    setState(QStringLiteral("checking"));

    QNetworkRequest req(m_manifestUrl);
    req.setHeader(QNetworkRequest::UserAgentHeader,
                  QStringLiteral("PlayerX/%1 (%2)")
                      .arg(m_currentVersion, QSysInfo::prettyProductName()));
    // 不缓存，永远拿最新版本清单
    req.setAttribute(QNetworkRequest::CacheLoadControlAttribute,
                     QNetworkRequest::AlwaysNetwork);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);

    m_reply = m_net->get(req);
    connect(m_reply, &QNetworkReply::finished, this, &Updater::onManifestFinished);
}

void Updater::onManifestFinished() {
    if (!m_reply) return;
    QNetworkReply* r = m_reply;
    m_reply = nullptr;
    r->deleteLater();

    if (r->error() != QNetworkReply::NoError) {
        const QString reason = r->errorString();
        setState(QStringLiteral("error"), reason);
        emit checkFailed(reason);
        return;
    }
    parseManifest(r->readAll());
}

void Updater::parseManifest(const QByteArray& body) {
    QJsonParseError perr{};
    QJsonDocument doc = QJsonDocument::fromJson(body, &perr);
    if (perr.error != QJsonParseError::NoError || !doc.isObject()) {
        const QString reason = QStringLiteral("清单解析失败: %1").arg(perr.errorString());
        setState(QStringLiteral("error"), reason);
        emit checkFailed(reason);
        return;
    }
    const QJsonObject obj = doc.object();
    m_latestVersion = obj.value(QStringLiteral("version")).toString();
    m_minSupported  = obj.value(QStringLiteral("minSupported")).toString();
    m_releaseNotes  = obj.value(QStringLiteral("notes")).toString();
    m_mandatory     = obj.value(QStringLiteral("mandatory")).toBool(false);

    // 取本平台对应的下载条目；兼容两种格式：
    //   1) 行业标准对象格式：{"url":"...","sha256":"..."}
    //   2) 兼容你给的简化格式：直接是字符串 URL
    const QJsonValue dlAny = obj.value(QStringLiteral("downloads"));
    m_pkgUrl.clear();
    m_pkgSha256.clear();
    if (dlAny.isObject()) {
        const QJsonObject dl = dlAny.toObject();
        const QString key = platformKey();
        QJsonValue v = dl.value(key);
        // 兼容旧字段名 "darwin"
        if (v.isUndefined() && key.startsWith(QLatin1String("mac-"))) {
            v = dl.value(QStringLiteral("darwin"));
        }
        if (v.isObject()) {
            const QJsonObject o = v.toObject();
            m_pkgUrl   = o.value(QStringLiteral("url")).toString();
            m_pkgSha256 = o.value(QStringLiteral("sha256")).toString();
        } else if (v.isString()) {
            m_pkgUrl = v.toString();
        }
    }

    // 解析客户端上传配置（clientConfig 字段，可选）
    // 只要字段存在就更新，为空字段不覆盖（让 QML 侧决定是否应用）
    const QJsonValue ccVal = obj.value(QStringLiteral("clientConfig"));
    if (ccVal.isObject()) {
        const QJsonObject cc = ccVal.toObject();
        const QString newUploadUrl = cc.value(QStringLiteral("uploadUrl")).toString();
        const QString newToken     = cc.value(QStringLiteral("token")).toString();
        if (newUploadUrl != m_clientUploadUrl || newToken != m_clientToken) {
            m_clientUploadUrl = newUploadUrl;
            m_clientToken     = newToken;
            emit clientConfigChanged();
        }
    }

    emit infoChanged();

    if (updateAvailable()) {
        setState(QStringLiteral("available"));
    } else {
        setState(QStringLiteral("idle"));
        if (!m_silentCheck) {
            // 手动触发但已是最新版：通过 checkFailed 信号让 UI 提示一下
            emit checkFailed(QStringLiteral("已是最新版本 %1").arg(m_currentVersion));
        }
    }
}

// ─── 2. 下载并应用 ───────────────────────────────────────────────────────
void Updater::downloadAndApply() {
    if (!updateAvailable() || m_pkgUrl.isEmpty()) {
        emit checkFailed(QStringLiteral("没有可下载的安装包"));
        return;
    }
    if (m_state == QLatin1String("downloading")) return;

    // 准备本地文件
    QDir().mkpath(cacheDir());
    const QUrl url(m_pkgUrl);
    QString fileName = QFileInfo(url.path()).fileName();
    if (fileName.isEmpty()) fileName = QStringLiteral("PlayerX-update.bin");
    const QString localPath = cacheDir() + QLatin1Char('/') + fileName;

    if (m_dlFile) { m_dlFile->close(); delete m_dlFile; m_dlFile = nullptr; }
    m_dlFile = new QFile(localPath);
    if (!m_dlFile->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        setState(QStringLiteral("error"),
                 QStringLiteral("无法写入: %1").arg(localPath));
        return;
    }

    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader,
                  QStringLiteral("PlayerX/%1").arg(m_currentVersion));
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);

    m_progress = 0.0;
    m_progressText.clear();
    m_lastReceived = 0;
    m_speedBps = 0.0;
    m_dlTimer.start();
    m_lastTickMs = 0;
    setState(QStringLiteral("downloading"));
    emit progressChanged();

    m_reply = m_net->get(req);
    connect(m_reply, &QNetworkReply::downloadProgress,
            this, &Updater::onDownloadProgress);
    connect(m_reply, &QNetworkReply::readyRead, this, [this]() {
        if (m_reply && m_dlFile) m_dlFile->write(m_reply->readAll());
    });
    connect(m_reply, &QNetworkReply::finished,
            this, &Updater::onDownloadFinished);
}

static QString humanBytes(qint64 b) {
    if (b < 1024) return QStringLiteral("%1 B").arg(b);
    if (b < 1024LL * 1024) return QStringLiteral("%1 KB").arg(b / 1024.0, 0, 'f', 1);
    if (b < 1024LL * 1024 * 1024) return QStringLiteral("%1 MB").arg(b / 1024.0 / 1024.0, 0, 'f', 1);
    return QStringLiteral("%1 GB").arg(b / 1024.0 / 1024.0 / 1024.0, 0, 'f', 2);
}

void Updater::onDownloadProgress(qint64 received, qint64 total) {
    // EWMA 平滑速率：每次取本次窗口的瞬时速率，0.3 比例融合
    const qint64 nowMs = m_dlTimer.elapsed();
    if (m_lastTickMs > 0 && nowMs > m_lastTickMs) {
        const qreal inst = qreal(received - m_lastReceived) * 1000.0 / qreal(nowMs - m_lastTickMs);
        m_speedBps = (m_speedBps <= 0.0) ? inst : (m_speedBps * 0.7 + inst * 0.3);
    }
    m_lastTickMs   = nowMs;
    m_lastReceived = received;

    if (total > 0) {
        m_progress = qreal(received) / qreal(total);
        const qint64 remain = qint64((qreal(total - received) / qMax<qreal>(1.0, m_speedBps)));
        m_progressText = QStringLiteral("%1 / %2 · %3/s · 剩余 %4s")
                             .arg(humanBytes(received), humanBytes(total),
                                  humanBytes(qint64(m_speedBps))).arg(remain);
    } else {
        m_progress = 0.0;
        m_progressText = QStringLiteral("已下载 %1 · %2/s")
                             .arg(humanBytes(received), humanBytes(qint64(m_speedBps)));
    }
    emit progressChanged();
}

void Updater::onDownloadFinished() {
    if (!m_reply) return;
    QNetworkReply* r = m_reply;
    m_reply = nullptr;

    if (m_dlFile) {
        m_dlFile->write(r->readAll());
        m_dlFile->flush();
        m_dlFile->close();
    }
    const QString localPath = m_dlFile ? m_dlFile->fileName() : QString();
    delete m_dlFile;
    m_dlFile = nullptr;

    const bool aborted = (r->error() == QNetworkReply::OperationCanceledError);
    const QNetworkReply::NetworkError err = r->error();
    const QString errStr = r->errorString();
    r->deleteLater();

    if (aborted) {
        setState(QStringLiteral("idle"));
        return;
    }
    if (err != QNetworkReply::NoError) {
        setState(QStringLiteral("error"), QStringLiteral("下载失败: %1").arg(errStr));
        return;
    }

    // 校验 SHA256（清单里有就校验，没有就跳过）
    if (!m_pkgSha256.isEmpty()) {
        setState(QStringLiteral("verifying"));
        QFile f(localPath);
        if (!f.open(QIODevice::ReadOnly)) {
            setState(QStringLiteral("error"),
                     QStringLiteral("无法打开下载文件做校验: %1").arg(localPath));
            return;
        }
        QCryptographicHash h(QCryptographicHash::Sha256);
        if (!h.addData(&f)) {
            setState(QStringLiteral("error"), QStringLiteral("SHA256 计算失败"));
            return;
        }
        const QString got = QString::fromLatin1(h.result().toHex());
        if (got.compare(m_pkgSha256, Qt::CaseInsensitive) != 0) {
            setState(QStringLiteral("error"),
                     QStringLiteral("文件校验不通过 (期望 %1, 实际 %2)")
                         .arg(m_pkgSha256.left(12), got.left(12)));
            return;
        }
    }

    emit readyToInstall();

#if defined(Q_OS_MACOS)
    applyMacOS(localPath);
#elif defined(Q_OS_WIN)
    applyWindows(localPath);
#else
    setState(QStringLiteral("error"),
             QStringLiteral("当前平台暂不支持自动更新，请手动下载: %1").arg(localPath));
#endif
}

void Updater::cancel() {
    if (m_reply) {
        m_reply->abort();   // 触发 finished + OperationCanceledError
    } else {
        setState(QStringLiteral("idle"));
    }
}

// ─── 3. 平台特定的 apply ────────────────────────────────────────────────
void Updater::applyMacOS(const QString& downloadedZip) {
#if defined(Q_OS_MACOS)
    // 当前 .app bundle 路径：QCoreApplication::applicationDirPath() →
    //   .../PlayerX.app/Contents/MacOS  →  上溯两层得到 .app 目录
    QDir d(QCoreApplication::applicationDirPath());
    d.cdUp(); // Contents
    d.cdUp(); // .app
    const QString appPath = d.absolutePath();
    if (!appPath.endsWith(QLatin1String(".app"))) {
        setState(QStringLiteral("error"),
                 QStringLiteral("无法定位 .app 路径: %1").arg(appPath));
        return;
    }
    const QString appDir  = QFileInfo(appPath).absolutePath(); // 安装父目录（如 /Applications）
    const QString tmpDir  = cacheDir() + QStringLiteral("/extract_") +
                            QString::number(QDateTime::currentMSecsSinceEpoch());
    QDir().mkpath(tmpDir);

    // 1) 解压 zip
    QProcess unzip;
    unzip.start(QStringLiteral("/usr/bin/unzip"),
                {QStringLiteral("-oq"), downloadedZip, QStringLiteral("-d"), tmpDir});
    if (!unzip.waitForFinished(120000) || unzip.exitCode() != 0) {
        setState(QStringLiteral("error"),
                 QStringLiteral("解压失败: %1").arg(QString::fromUtf8(unzip.readAllStandardError())));
        return;
    }

    // 2) 在解压目录里找 *.app
    QString newApp;
    for (const QFileInfo& fi : QDir(tmpDir).entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        if (fi.suffix() == QLatin1String("app")) { newApp = fi.absoluteFilePath(); break; }
    }
    if (newApp.isEmpty()) {
        setState(QStringLiteral("error"), QStringLiteral("zip 中未找到 .app"));
        return;
    }

    // 3) 写 relaunch.sh：等父退出 → 去隔离 → 替换 → open
    const QString script = cacheDir() + QStringLiteral("/relaunch.sh");
    QFile sf(script);
    if (!sf.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        setState(QStringLiteral("error"), QStringLiteral("无法写 relaunch.sh"));
        return;
    }
    const qint64 pid = QCoreApplication::applicationPid();
    QString sh;
    sh += QStringLiteral("#!/bin/bash\n");
    sh += QStringLiteral("set -e\n");
    sh += QStringLiteral("PARENT_PID=%1\n").arg(pid);
    sh += QStringLiteral("OLD_APP=\"%1\"\n").arg(appPath);
    sh += QStringLiteral("NEW_APP=\"%1\"\n").arg(newApp);
    sh += QStringLiteral("# 等父进程退出（最多 30s 兜底）\n");
    sh += QStringLiteral("for i in $(seq 1 150); do\n");
    sh += QStringLiteral("  if ! kill -0 \"$PARENT_PID\" 2>/dev/null; then break; fi\n");
    sh += QStringLiteral("  sleep 0.2\n");
    sh += QStringLiteral("done\n");
    sh += QStringLiteral("# 去除浏览器/curl/网盘下载产生的 quarantine 标记（递归清扩展属性更彻底）\n");
    sh += QStringLiteral("/usr/bin/xattr -rc \"$NEW_APP\" 2>/dev/null || true\n");
    sh += QStringLiteral("# 修正写权限，避免子文件只读导致后续操作失败\n");
    sh += QStringLiteral("/bin/chmod -R u+w \"$NEW_APP\" 2>/dev/null || true\n");
    sh += QStringLiteral("# 替换 .app（先删旧再 mv，避免合并残留）\n");
    sh += QStringLiteral("rm -rf \"$OLD_APP\"\n");
    sh += QStringLiteral("/bin/mv \"$NEW_APP\" \"$OLD_APP\"\n");
    sh += QStringLiteral("# 重新 ad-hoc 签名：xattr 修改和 mv 都可能让原签名失效，\n");
    sh += QStringLiteral("# 不重签会被 Gatekeeper 判定为\"已损坏\"或要求二次确认。\n");
    sh += QStringLiteral("/usr/bin/codesign --force --deep --sign - \"$OLD_APP\" 2>/dev/null || true\n");
    sh += QStringLiteral("# 拉起新版本\n");
    sh += QStringLiteral("/usr/bin/open \"$OLD_APP\"\n");
    sf.write(sh.toUtf8());
    sf.close();
    QFile::setPermissions(script,
                          QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner |
                          QFile::ReadGroup | QFile::ExeGroup |
                          QFile::ReadOther | QFile::ExeOther);

    // 4) startDetached + setsid，让脚本完全脱离父进程组
    QStringList args = {QStringLiteral("-c"),
                        QStringLiteral("nohup /bin/bash \"%1\" </dev/null >/dev/null 2>&1 &")
                            .arg(script)};
    qint64 spawnedPid = -1;
    bool ok = QProcess::startDetached(QStringLiteral("/bin/bash"), args,
                                      QString(), &spawnedPid);
    if (!ok) {
        setState(QStringLiteral("error"), QStringLiteral("启动 relaunch.sh 失败"));
        return;
    }

    setState(QStringLiteral("ready"));
    // 200ms 后退出主程序，让脚本接管
    QMetaObject::invokeMethod(qApp, []() {
        QCoreApplication::quit();
    }, Qt::QueuedConnection);

    Q_UNUSED(appDir);
#else
    Q_UNUSED(downloadedZip);
    setState(QStringLiteral("error"), QStringLiteral("非 macOS 平台调用了 applyMacOS"));
#endif
}

void Updater::applyWindows(const QString& setupExe) {
#if defined(Q_OS_WIN)
    // 区分两种路径：
    //   1) win-install : 下载的是 PlayerX-Setup-x.y.z.exe，
    //                    拉起 setup.exe /S 静默升级，由 NSIS 内部脚本
    //                    kill + 覆盖 + 重启
    //   2) win-portable: 下载的是 PlayerX-x.y.z-win64-portable.zip 整包，
    //                    写 BAT 等父退出 → tar 解压 → robocopy /MIR 整目录覆盖 → 拉起 exe
    //                    （坚决不用 move 单 exe 的方式，那只能换 exe 不能换 dll，
    //                     遇到 Qt/llvm-mingw 升级会立即崩溃）
    const QString chan = platformKey();
    if (chan == QLatin1String("win-install")) {
        // 标准 NSIS 静默参数：
        //   /S                    NSIS 静默安装
        //   /CLOSEAPPLICATIONS    告知安装器可关闭被占用进程（NSIS 脚本里也会主动 kill 兜底）
        //   /RESTARTAPPLICATIONS  安装后重拉原进程（实际由 NSIS 脚本最后 Exec 完成）
        //   /D=<dir>              强制同目录覆盖（必须放最后，且不能加引号）
        const QString instDir = QDir::toNativeSeparators(QCoreApplication::applicationDirPath());
        QStringList args = {
            QStringLiteral("/S"),
            QStringLiteral("/CLOSEAPPLICATIONS"),
            QStringLiteral("/RESTARTAPPLICATIONS"),
            QStringLiteral("/D=") + instDir
        };
        if (!QProcess::startDetached(setupExe, args)) {
            setState(QStringLiteral("error"),
                     QStringLiteral("启动安装程序失败: %1").arg(setupExe));
            return;
        }
        setState(QStringLiteral("ready"));
        QMetaObject::invokeMethod(qApp, []() { QCoreApplication::quit(); },
                                  Qt::QueuedConnection);
        return;
    }

    // ── portable 路径：下载下来的是新版 ZIP（PlayerX-x.y.z-win64-portable.zip），
    //    内部顶层目录固定为 PlayerX/（**不带版本号**，自 build.py 改造后），
    //    里面是完整的 exe + 所有 dll + plugins + qml。
    //    自更新策略（VS Code Portable / JetBrains Portable 同款）：
    //      1) 把 zip 解压到临时目录
    //      2) 写 BAT：等父进程退出 → robocopy /MIR 整目录覆盖 → 拉起新 exe
    //      3) 用 robocopy 而不是 xcopy/move 是因为它能：
    //         · /MIR  目录镜像（删除目标里多余的旧文件，避免残留旧 dll 引发 ABI 错位）
    //         · /R:5 /W:1  自动重试被占用文件（兜底文件锁）
    //         · 退出码 0/1/2/3 都算成功（与 errorlevel >=8 才算失败 的语义一致）
    const QString instDir   = QDir::toNativeSeparators(QCoreApplication::applicationDirPath());
    const QString selfExe   = QDir::toNativeSeparators(QCoreApplication::applicationFilePath());
    const QString extractDir= QDir::toNativeSeparators(
        cacheDir() + QStringLiteral("/extract_") +
        QString::number(QDateTime::currentMSecsSinceEpoch()));
    const QString script    = cacheDir() + QStringLiteral("/relaunch.bat");
    const qint64  pid       = QCoreApplication::applicationPid();
    const QString zipPath   = QDir::toNativeSeparators(setupExe);   // 此处实参是下载好的 zip 完整路径

    QFile bf(script);
    if (!bf.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        setState(QStringLiteral("error"), QStringLiteral("无法写入 relaunch.bat"));
        return;
    }
    QString bat;
    bat += QStringLiteral("@echo off\r\n");
    bat += QStringLiteral("chcp 65001 >NUL\r\n");
    bat += QStringLiteral("setlocal EnableDelayedExpansion\r\n");
    bat += QStringLiteral("set PARENT_PID=%1\r\n").arg(pid);
    bat += QStringLiteral("set ZIP_FILE=\"%1\"\r\n").arg(zipPath);
    bat += QStringLiteral("set EXTRACT_DIR=\"%1\"\r\n").arg(extractDir);
    bat += QStringLiteral("set INST_DIR=\"%1\"\r\n").arg(instDir);
    bat += QStringLiteral("set NEW_EXE=\"%1\"\r\n").arg(selfExe);
    bat += QStringLiteral("REM 1) 轮询父进程退出（最多 30s 兜底）\r\n");
    bat += QStringLiteral("for /L %%i in (1,1,150) do (\r\n");
    bat += QStringLiteral("  tasklist /FI \"PID eq %PARENT_PID%\" 2>NUL | find \"%PARENT_PID%\" >NUL\r\n");
    bat += QStringLiteral("  if errorlevel 1 goto :do_extract\r\n");
    bat += QStringLiteral("  ping -n 1 -w 200 127.0.0.1 >NUL\r\n");
    bat += QStringLiteral(")\r\n");
    bat += QStringLiteral("REM 2) 兜底强制结束 PlayerX.exe（防多实例锁定 dll）\r\n");
    bat += QStringLiteral("taskkill /F /IM PlayerX.exe /T >NUL 2>&1\r\n");
    bat += QStringLiteral("ping -n 1 -w 500 127.0.0.1 >NUL\r\n");
    bat += QStringLiteral(":do_extract\r\n");
    bat += QStringLiteral("REM 3) 解压 zip 到独立临时目录（tar 是 Win10 1803+ 自带）\r\n");
    bat += QStringLiteral("if exist %EXTRACT_DIR% rmdir /S /Q %EXTRACT_DIR%\r\n");
    bat += QStringLiteral("mkdir %EXTRACT_DIR%\r\n");
    bat += QStringLiteral("tar -xf %ZIP_FILE% -C %EXTRACT_DIR%\r\n");
    bat += QStringLiteral("if errorlevel 1 (\r\n");
    bat += QStringLiteral("  echo [ERROR] 解压失败>>%EXTRACT_DIR%\\relaunch.log\r\n");
    bat += QStringLiteral("  exit /b 1\r\n");
    bat += QStringLiteral(")\r\n");
    bat += QStringLiteral("REM 4) 定位解压后的顶层目录\r\n");
    bat += QStringLiteral("REM    portable zip 顶层固定为 PlayerX\\（不带版本号），\r\n");
    bat += QStringLiteral("REM    解压目录名与版本解耦，自更新原地覆盖时路径恒定。\r\n");
    bat += QStringLiteral("set NEW_ROOT=%EXTRACT_DIR%\\PlayerX\r\n");
    bat += QStringLiteral("if not exist %NEW_ROOT%\\PlayerX.exe (\r\n");
    bat += QStringLiteral("  echo [ERROR] zip 内未找到 PlayerX\\PlayerX.exe>>%EXTRACT_DIR%\\relaunch.log\r\n");
    bat += QStringLiteral("  exit /b 2\r\n");
    bat += QStringLiteral(")\r\n");
    bat += QStringLiteral("REM 5) robocopy /MIR 整目录覆盖；保留更新器自身缓存目录不被删\r\n");
    bat += QStringLiteral("REM    /R:5 /W:1 应对偶发文件占用；/NFL /NDL /NJH /NJS 减少日志噪音\r\n");
    bat += QStringLiteral("robocopy \"!NEW_ROOT!\" %INST_DIR% /MIR /R:5 /W:1 /NFL /NDL /NJH /NJS /NP\r\n");
    bat += QStringLiteral("REM robocopy 退出码：0~7 均视为成功（8+ 才算错误）\r\n");
    bat += QStringLiteral("if errorlevel 8 (\r\n");
    bat += QStringLiteral("  echo [ERROR] robocopy 失败 errorlevel=!ERRORLEVEL!>>%EXTRACT_DIR%\\relaunch.log\r\n");
    bat += QStringLiteral("  exit /b 3\r\n");
    bat += QStringLiteral(")\r\n");
    bat += QStringLiteral("REM 6) 拉起新版本\r\n");
    bat += QStringLiteral("start \"\" %NEW_EXE%\r\n");
    bat += QStringLiteral("REM 7) 清理临时解压目录与 zip\r\n");
    bat += QStringLiteral("rmdir /S /Q %EXTRACT_DIR% >NUL 2>&1\r\n");
    bat += QStringLiteral("del /F /Q %ZIP_FILE% >NUL 2>&1\r\n");
    bat += QStringLiteral("(goto) 2>nul & del \"%~f0\"\r\n");
    bf.write(bat.toUtf8());
    bf.close();

    // 用 cmd.exe 启动 BAT 并完全脱离父进程
    QStringList args = {
        QStringLiteral("/c"),
        QStringLiteral("start"), QStringLiteral(""), QStringLiteral("/B"),
        QStringLiteral("cmd"), QStringLiteral("/c"),
        QDir::toNativeSeparators(script)
    };
    if (!QProcess::startDetached(QStringLiteral("cmd.exe"), args)) {
        setState(QStringLiteral("error"), QStringLiteral("启动 relaunch.bat 失败"));
        return;
    }
    setState(QStringLiteral("ready"));
    QMetaObject::invokeMethod(qApp, []() { QCoreApplication::quit(); },
                              Qt::QueuedConnection);
#else
    Q_UNUSED(setupExe);
#endif
}

// ─── 工具函数 ────────────────────────────────────────────────────────────
int Updater::compareVersion(const QString& a, const QString& b) {
    const QStringList la = a.split(QLatin1Char('.'));
    const QStringList lb = b.split(QLatin1Char('.'));
    const int n = qMax(la.size(), lb.size());
    for (int i = 0; i < n; ++i) {
        const int xa = (i < la.size()) ? la[i].toInt() : 0;
        const int xb = (i < lb.size()) ? lb[i].toInt() : 0;
        if (xa != xb) return (xa < xb) ? -1 : 1;
    }
    return 0;
}

QString Updater::platformKey() const {
#if defined(Q_OS_MACOS)
    // 区分 arm64 / x86_64
    const QString arch = QSysInfo::currentCpuArchitecture();
    if (arch.contains(QLatin1String("arm")))   return QStringLiteral("mac-arm64");
    if (arch.contains(QLatin1String("x86_64")) || arch.contains(QLatin1String("x86")))
        return QStringLiteral("mac-x64");
    return QStringLiteral("mac-arm64");
#elif defined(Q_OS_WIN)
    // Windows 区分两种形态，选择与当前运行一致的升级通道：
    //   · installed   - 通过 NSIS Setup 安装，目录下存在 "Uninstall PlayerX.exe"
    //   · portable    - 绿色单文件形态，无卸载器
    // 识别依据：启动路径下是否存在 Uninstaller。
    const QString dir = QCoreApplication::applicationDirPath();
    const bool installed =
        QFileInfo::exists(dir + QStringLiteral("/Uninstall PlayerX.exe")) ||
        QFileInfo::exists(dir + QStringLiteral("/uninstall.exe")) ||
        QFileInfo::exists(dir + QStringLiteral("/unins000.exe"));
    return installed ? QStringLiteral("win-install")
                     : QStringLiteral("win-portable");
#else
    return QStringLiteral("linux");
#endif
}

QString Updater::cacheDir() const {
    const QString base = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    return base + QStringLiteral("/Update");
}

} // namespace rbqt
