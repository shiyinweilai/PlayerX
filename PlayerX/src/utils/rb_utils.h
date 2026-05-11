#pragma once
/**
 * rb_utils.h — 工具函数
 * 字体加载、文件对话框、路径处理等跨平台工具。
 */

#include <string>
#include <vector>
#include <functional>
#include <SDL2/SDL.h>

struct TTF_Font;

namespace rb {

// ─── 路径工具 ─────────────────────────────────────────────────────────────────
std::string rbGetExecutableDir();
std::string rbGetFilename(const std::string& path);   // 取文件名（不含目录）
std::string rbGetExtension(const std::string& path);  // 取扩展名（小写，含点）

// ─── 字体加载 ─────────────────────────────────────────────────────────────────
// 按优先级搜索系统字体，返回加载成功的字体；失败返回 nullptr
TTF_Font* rbLoadFont(int ptSize);

// ─── 文件选择对话框 ───────────────────────────────────────────────────────────
// 异步弹出文件选择对话框，结果通过 SDL 自定义事件推回主线程。
// 使用方式：
//   1. SDL_Init 之后调用一次 rbInitFileDialogEvent()
//   2. 主事件循环中判断 e.type == rbFileDialogEventType()，
//      取 e.user.data1（heap-allocated RBFileCallback*）和
//      e.user.data2（heap-allocated std::string* 路径）处理后 delete
//   3. 调用 rbOpenFileDialog(callback) 触发弹窗
using RBFileCallback = std::function<void(const std::string& filePath)>;

// 注册自定义事件类型（SDL_Init 后调用一次）
void    rbInitFileDialogEvent();
// 返回已注册的事件类型值（用于主循环匹配）
Uint32  rbFileDialogEventType();
// 异步弹出对话框，结果通过 SDL 事件推回主线程
void    rbOpenFileDialog(const RBFileCallback& callback);

// ─── 时间格式化 ───────────────────────────────────────────────────────────────
std::string rbFormatTime(double seconds); // "mm:ss" 或 "hh:mm:ss"

} // namespace rb
