/**
 * rb_macos_silence_win.cpp — Windows 平台 rbSilenceSystemBeep 空实现
 *
 * Windows 上键盘事件未被处理不会触发系统提示音，因此无需任何操作。
 * 仅为满足跨平台符号链接而提供。
 */

#include "rb_utils.h"

namespace rb {

void rbSilenceSystemBeep() {
    // no-op on Windows
}

} // namespace rb
