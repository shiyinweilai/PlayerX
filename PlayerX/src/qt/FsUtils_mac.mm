/**
 * FsUtils_mac.mm — macOS 原生 NSOpenPanel 多选目录实现
 *
 * 问题背景：
 *   Qt 的 QFileDialog 在 macOS 上虽然底层会桥接到 NSOpenPanel，但
 *   "目录选择 + 多选" 这个组合 Qt 没有暴露开关（QFileDialog::Directory
 *   模式下 SelectionMode 始终是 Single）。我们之前走 Qt 自绘 QFileDialog
 *   能多选，但 UI 不是原生 Finder 风格，且要拉入 Qt6::Widgets。
 *
 * 本实现：直接走 Cocoa NSOpenPanel —— 设 canChooseDirectories=YES、
 *   canChooseFiles=NO、allowsMultipleSelection=YES，UI 完全是用户熟悉的
 *   Finder 文件浏览面板（侧边栏 / Tags / 搜索 / 最近 全有），且支持
 *   Cmd/Shift 多选目录。零额外依赖（AppKit 框架在项目里已经因为
 *   ScreenProbe.mm 链上了）。
 *
 * 接口语义与跨平台 FsUtils::pickMultipleFolders 完全一致：
 *   · 用户取消 / 没选任何项 → 返回空列表；
 *   · 仅返回存在的目录绝对路径；
 *   · title 为空时走默认；startPath 为空 / 不存在 → HOME。
 */
#import <AppKit/AppKit.h>

#include <QFileInfo>
#include <QDir>
#include <QStringList>

namespace rbqt {

QStringList pickMultipleFoldersNative(const QString& title,
                                       const QString& startPath) {
    QStringList result;

    @autoreleasepool {
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        // 关键开关组合：选目录、不选文件、允许多选
        [panel setCanChooseDirectories:YES];
        [panel setCanChooseFiles:NO];
        [panel setAllowsMultipleSelection:YES];
        [panel setResolvesAliases:YES];
        // "新建文件夹"按钮可见，与 Finder 一致
        [panel setCanCreateDirectories:YES];

        // 标题（macOS 13+ message 用作主标题，老版本用 title）
        NSString* titleStr = title.isEmpty()
            ? @"选择文件夹（可多选）"
            : title.toNSString();
        [panel setMessage:titleStr];
        // 兼容旧 API（10.13 以前）：title 字段
        if ([panel respondsToSelector:@selector(setTitle:)]) {
            [panel setTitle:titleStr];
        }
        // "打开"按钮文案，让中文用户看着更顺
        [panel setPrompt:@"选择"];

        // 起始目录：传入路径优先 → HOME 兜底
        QString start = startPath;
        if (start.isEmpty() || !QFileInfo(start).isDir()) {
            start = QDir::homePath();
        }
        NSURL* startURL = [NSURL fileURLWithPath:start.toNSString()
                                      isDirectory:YES];
        [panel setDirectoryURL:startURL];

        // 模态运行（阻塞）。NSOpenPanel 在主线程跑没有问题；
        // QML 端调用方本来就在主线程触发 Q_INVOKABLE。
        NSModalResponse rsp = [panel runModal];
        if (rsp != NSModalResponseOK) {
            return result;
        }

        NSArray<NSURL*>* urls = [panel URLs];
        for (NSURL* u in urls) {
            if (!u) continue;
            NSString* p = [u path];
            if (!p || [p length] == 0) continue;
            QString qp = QString::fromNSString(p);
            QFileInfo fi(qp);
            if (!fi.exists() || !fi.isDir()) continue;
            result << fi.absoluteFilePath();
        }
    }

    return result;
}

} // namespace rbqt
