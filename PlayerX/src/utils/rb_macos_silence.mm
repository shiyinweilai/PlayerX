/**
 * rb_macos_silence.mm — macOS 平台抑制系统按键提示音（NSBeep）
 *
 * 背景：
 *   SDL 应用在 macOS 上接收到键盘事件时，AppKit 会沿 responder chain 派发，
 *   若最终没有 menu/responder 接收，系统会调用 NSBeep 作为反馈，
 *   表现为用户每次按键都听到"砰"的提示音。
 *
 * 解法：
 *   注册一个 NSEvent 的 local monitor（仅本进程内生效），监听 NSEventMaskKeyDown。
 *   在 block 中显式把事件转发给 keyWindow 的 contentView（SDL 创建的 view），
 *   让 SDL 正常生成 SDL_KEYDOWN 事件；随后 return nil，吞掉默认派发，
 *   防止事件再走到 menu/responder 兜底（也就是不会再触发 NSBeep）。
 *
 *   注意：对带 Cmd 修饰的快捷键不做拦截，让系统菜单（Cmd+Q 等）正常工作。
 */

#import <AppKit/AppKit.h>
#include "rb_utils.h"

namespace rb {

static id s_keyDownMonitor = nil;

void rbSilenceSystemBeep() {
    if (s_keyDownMonitor) return; // 仅注册一次

    NSEventMask mask = NSEventMaskKeyDown;

    s_keyDownMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
        handler:^NSEvent *(NSEvent *event) {
            // 带 Command 修饰的事件留给系统（菜单快捷键、应用切换等），不拦截。
            if (event.modifierFlags & NSEventModifierFlagCommand) {
                return event;
            }

            // 把事件直接送给当前 key window 的 contentView。
            // SDL 的 SDLView 实现了 -keyDown:，会把按键转换成 SDL_KEYDOWN 事件，
            // 我们手工转发后吞掉系统派发，避免 NSBeep 兜底。
            NSWindow *keyWin = [NSApp keyWindow];
            if (keyWin) {
                NSResponder *target = keyWin.firstResponder ?: keyWin.contentView;
                if ([target respondsToSelector:@selector(keyDown:)]) {
                    [target keyDown:event];
                }
            }
            return nil; // 吞掉，阻止系统默认 fallback（NSBeep）
        }];
}

} // namespace rb
