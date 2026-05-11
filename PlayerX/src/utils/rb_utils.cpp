#include "rb_utils.h"
#include "rb_file_dialog.h"
#include <SDL2/SDL_ttf.h>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <thread>
#include <functional>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifdef _WIN32
#  include <windows.h>
#else
#  include <unistd.h>
#  include <limits.h>
#  ifdef __APPLE__
#    include <mach-o/dyld.h>
#  endif
#endif
#include <atomic>
#include <mutex>

namespace rb {

// ═══════════════════════════════════════════════════════════════════════════
// 路径工具
// ═══════════════════════════════════════════════════════════════════════════

std::string rbGetExecutableDir() {
#ifdef _WIN32
    char buf[MAX_PATH];
    DWORD len = GetModuleFileNameA(nullptr, buf, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
        std::string full(buf, len);
        auto pos = full.find_last_of("/\\");
        if (pos != std::string::npos) return full.substr(0, pos);
    }
    return ".";
#elif defined(__APPLE__)
    char buf[PATH_MAX];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0) {
        char real[PATH_MAX];
        if (realpath(buf, real)) {
            std::string full(real);
            auto pos = full.find_last_of('/');
            if (pos != std::string::npos) return full.substr(0, pos);
        }
    }
    return ".";
#else
    char buf[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (len > 0) {
        buf[len] = '\0';
        std::string full(buf);
        auto pos = full.find_last_of('/');
        if (pos != std::string::npos) return full.substr(0, pos);
    }
    return ".";
#endif
}

std::string rbGetFilename(const std::string& path) {
    auto pos = path.find_last_of("/\\");
    return (pos != std::string::npos) ? path.substr(pos + 1) : path;
}

std::string rbGetExtension(const std::string& path) {
    auto name = rbGetFilename(path);
    auto pos  = name.find_last_of('.');
    if (pos == std::string::npos) return "";
    std::string ext = name.substr(pos);
    for (auto& c : ext) c = static_cast<char>(tolower(c));
    return ext;
}

// ═══════════════════════════════════════════════════════════════════════════
// 字体加载
// ═══════════════════════════════════════════════════════════════════════════

TTF_Font* rbLoadFont(int ptSize) {
    static const std::vector<std::string> kFontPaths = {
        // macOS — 优先使用支持 Unicode 符号的字体
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.dfont",
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
        // Linux
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
        // Windows
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
    };

    for (const auto& p : kFontPaths) {
        TTF_Font* f = TTF_OpenFont(p.c_str(), ptSize);
        if (f) {
            std::cout << "[rbLoadFont] loaded: " << p << " size=" << ptSize << std::endl;
            return f;
        }
    }
    std::cerr << "[rbLoadFont] all font paths failed, ptSize=" << ptSize << std::endl;
    return nullptr;
}

// ═══════════════════════════════════════════════════════════════════════════
// 文件选择对话框（跨平台分发：macOS=NSOpenPanel / Windows=GetOpenFileNameW）
// ═══════════════════════════════════════════════════════════════════════════

static Uint32             s_fileDialogEventType = static_cast<Uint32>(-1);
static std::atomic<bool>  s_dialogOpen{false};       // 防重复打开
static std::atomic<bool>  s_dialogShutdown{false};
static std::mutex         s_dialogThreadMtx;
static std::thread        s_dialogThread;

void rbInitFileDialogEvent() {
    s_fileDialogEventType = SDL_RegisterEvents(1);
}

Uint32 rbFileDialogEventType() {
    return s_fileDialogEventType;
}

void rbOpenFileDialog(const RBFileCallback& callback) {
    // 已有对话框打开，忽略后续点击，避免叠加多个窗口
    bool expected = false;
    if (!s_dialogOpen.compare_exchange_strong(expected, true)) {
        return;
    }
    if (s_dialogShutdown.load()) {
        s_dialogOpen.store(false);
        return;
    }

    // 上次的线程若还未 join（极少数情况），先 join
    {
        std::lock_guard<std::mutex> lk(s_dialogThreadMtx);
        if (s_dialogThread.joinable()) s_dialogThread.join();
        s_dialogThread = std::thread([callback]() {
            // 调用平台原生对话框（同步阻塞）
            //   macOS  : NSOpenPanel（内部自动 dispatch 到主线程）
            //   Windows: GetOpenFileNameW（在本工作线程中运行）
            std::string result = rbShowOpenFileDialogNative();

            // 主进程已在退出流程，则不再 push 事件
            if (s_dialogShutdown.load()) {
                s_dialogOpen.store(false);
                return;
            }

            // 将结果通过 SDL 自定义事件推回主线程
            if (s_fileDialogEventType != static_cast<Uint32>(-1)) {
                auto* cb   = new RBFileCallback(callback);
                auto* path = new std::string(result);
                SDL_Event ev{};
                ev.type       = s_fileDialogEventType;
                ev.user.data1 = cb;
                ev.user.data2 = path;
                SDL_PushEvent(&ev);
            }
            s_dialogOpen.store(false);
        });
    }
}

// 主程序退出时调用：通知原生层关闭对话框（macOS）并 join 后台线程。
void rbShutdownFileDialog() {
    s_dialogShutdown.store(true);
    // 通知原生层关闭可能仍在显示的 Panel（macOS 关闭 NSOpenPanel；Windows 空实现）
    rbCancelOpenFileDialogNative();
    std::lock_guard<std::mutex> lk(s_dialogThreadMtx);
    if (s_dialogThread.joinable()) s_dialogThread.join();
}

// ═══════════════════════════════════════════════════════════════════════════
// 时间格式化
// ═══════════════════════════════════════════════════════════════════════════

std::string rbFormatTime(double seconds) {
    if (seconds < 0) seconds = 0;
    int total = static_cast<int>(seconds);
    int h = total / 3600;
    int m = (total % 3600) / 60;
    int s = total % 60;
    std::ostringstream oss;
    if (h > 0) {
        oss << h << ":" << std::setw(2) << std::setfill('0') << m
            << ":" << std::setw(2) << std::setfill('0') << s;
    } else {
        oss << m << ":" << std::setw(2) << std::setfill('0') << s;
    }
    return oss.str();
}

} // namespace rb
