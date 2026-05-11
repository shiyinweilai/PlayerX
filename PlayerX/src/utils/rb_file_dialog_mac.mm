/**
 * rb_file_dialog_mac.mm — macOS 原生文件选择（NSOpenPanel）
 *
 * 通过 dispatch_sync 切到主线程运行 NSOpenPanel，避免 AppKit 线程安全问题。
 * 应用退出时通过 rbCancelOpenFileDialogNative 关闭可能仍在显示的 Panel，
 * 彻底解决"主进程退出后对话框残留"的问题（替代旧的 fork+osascript 方案）。
 */

#import <AppKit/AppKit.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#  import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#  define RB_HAS_UTTYPE 1
#else
#  define RB_HAS_UTTYPE 0
#endif
#include "rb_file_dialog.h"

// 当前打开的 Panel 引用（仅主线程访问）。用于退出时主动 cancel。
static NSOpenPanel* g_currentPanel = nil;

namespace rb {

std::string rbShowOpenFileDialogNative() {
    __block std::string out;

    dispatch_block_t block = ^{
        @autoreleasepool {
            NSOpenPanel* panel = [NSOpenPanel openPanel];
            panel.title                    = @"Select Video File";
            panel.canChooseFiles           = YES;
            panel.canChooseDirectories     = NO;
            panel.allowsMultipleSelection  = NO;
            panel.resolvesAliases          = YES;

            NSArray<NSString*>* exts = @[
                @"mp4", @"mov", @"mkv", @"avi", @"webm",
                @"hevc", @"h265", @"h264", @"ts", @"flv",
                @"m4v", @"mpg", @"mpeg", @"wmv", @"3gp"
            ];

#if RB_HAS_UTTYPE
            if (@available(macOS 11.0, *)) {
                NSMutableArray<UTType*>* types = [NSMutableArray arrayWithCapacity:exts.count];
                for (NSString* e in exts) {
                    UTType* t = [UTType typeWithFilenameExtension:e];
                    if (t) [types addObject:t];
                }
                panel.allowedContentTypes = types;
            } else {
                panel.allowedFileTypes = exts;
            }
#else
            panel.allowedFileTypes = exts;
#endif

            g_currentPanel = panel;
            NSModalResponse rsp = [panel runModal];
            g_currentPanel = nil;

            if (rsp == NSModalResponseOK && panel.URL != nil) {
                NSString* p = panel.URL.path;
                if (p != nil) {
                    const char* utf8 = [p UTF8String];
                    if (utf8 != nullptr) out.assign(utf8);
                }
            }
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return out;
}

void rbCancelOpenFileDialogNative() {
    // 必须切到主线程操作 NSOpenPanel
    dispatch_block_t block = ^{
        if (g_currentPanel != nil) {
            [g_currentPanel cancel:nil];
            g_currentPanel = nil;
        }
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        // 退出流程使用 async，避免万一主线程已不再处理事件造成死锁
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

} // namespace rb
