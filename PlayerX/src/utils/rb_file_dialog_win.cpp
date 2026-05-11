/**
 * rb_file_dialog_win.cpp — Windows 原生文件选择（GetOpenFileNameW）
 *
 * 使用 comdlg32 的经典对话框 API。模态对话框与主进程同生命周期，
 * 不存在残留问题；主线程被 SDL 占用，所以本函数会在后台线程被调用，
 * Windows 允许在非 UI 线程调用 GetOpenFileNameW（前提是该线程已初始化 COM 为 STA）。
 */

#include "rb_file_dialog.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commdlg.h>
#include <objbase.h>
#include <vector>

namespace rb {

static std::string Utf16ToUtf8(const wchar_t* wide) {
    if (wide == nullptr || *wide == L'\0') return {};
    int needed = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 1) return {};
    std::string out(static_cast<size_t>(needed - 1), '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), needed, nullptr, nullptr);
    return out;
}

std::string rbShowOpenFileDialogNative() {
    // 单线程套间初始化（多次调用安全：S_FALSE 表示已初始化）
    HRESULT hrCo = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);

    // 双 \0 结尾的过滤器字符串
    static const wchar_t kFilter[] =
        L"Video Files\0*.mp4;*.mov;*.mkv;*.avi;*.webm;*.hevc;*.h265;*.h264;*.ts;*.flv;*.m4v;*.mpg;*.mpeg;*.wmv;*.3gp\0"
        L"All Files\0*.*\0";

    wchar_t fileBuf[MAX_PATH * 4] = {0};

    OPENFILENAMEW ofn = {};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner   = nullptr;
    ofn.lpstrFilter = kFilter;
    ofn.nFilterIndex = 1;
    ofn.lpstrFile   = fileBuf;
    ofn.nMaxFile    = static_cast<DWORD>(sizeof(fileBuf) / sizeof(wchar_t));
    ofn.lpstrTitle  = L"Select Video File";
    ofn.Flags       = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST
                    | OFN_NOCHANGEDIR  | OFN_EXPLORER;

    std::string result;
    if (::GetOpenFileNameW(&ofn)) {
        result = Utf16ToUtf8(fileBuf);
    }

    if (SUCCEEDED(hrCo)) {
        ::CoUninitialize();
    }
    return result;
}

void rbCancelOpenFileDialogNative() {
    // Windows 模态对话框随主进程退出而自动关闭，无需主动取消。
}

} // namespace rb
