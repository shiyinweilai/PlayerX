#pragma once
/**
 * rb_file_dialog.h — 跨平台原生文件选择对话框（内部接口）
 *
 * 仅供 rb_utils.cpp 内部使用，外部统一通过 rbOpenFileDialog 调用。
 * 各平台实现：
 *   - macOS  : rb_file_dialog_mac.mm   （NSOpenPanel）
 *   - Windows: rb_file_dialog_win.cpp  （GetOpenFileNameW）
 */

#include <string>

namespace rb {

// 同步阻塞地弹出原生文件选择对话框，返回选中的本地路径（UTF-8）。
// 用户取消或失败时返回空串。
// 注意：调用方应在【后台线程】中调用；macOS 实现内部会自动 dispatch 到主线程。
std::string rbShowOpenFileDialogNative();

// 通知原生层取消当前打开中的对话框（应用退出时调用）。
// macOS：关闭 NSOpenPanel；Windows：模态自动关闭，空实现。
void rbCancelOpenFileDialogNative();

} // namespace rb
