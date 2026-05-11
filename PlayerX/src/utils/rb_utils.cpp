#include "rb_utils.h"
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
// 文件选择对话框（SDL 自定义事件方案）
// ═══════════════════════════════════════════════════════════════════════════

static Uint32 s_fileDialogEventType = static_cast<Uint32>(-1);

void rbInitFileDialogEvent() {
    s_fileDialogEventType = SDL_RegisterEvents(1);
}

Uint32 rbFileDialogEventType() {
    return s_fileDialogEventType;
}

void rbOpenFileDialog(const RBFileCallback& callback) {
    // 子线程：只负责弹窗取路径，结果通过 SDL 事件推回主线程
    std::thread([callback]() {
        std::string result;

#ifdef __APPLE__
        // 使用 osascript 弹出系统文件选择框，无需编译，直接可用
        FILE* pipe = popen(
            "osascript -e 'POSIX path of (choose file with prompt \"Select Video File\")'",
            "r");
        if (pipe) {
            char buf[4096];
            while (fgets(buf, sizeof(buf), pipe)) result += buf;
            pclose(pipe);
        }
        // 去掉末尾换行
        while (!result.empty() && (result.back() == '\n' || result.back() == '\r'))
            result.pop_back();

#else
        // 非 macOS：简单命令行输入（后续可替换为 zenity/kdialog）
        std::cout << "[rbOpenFileDialog] Enter video file path: " << std::flush;
        std::getline(std::cin, result);
#endif

        // 将结果通过 SDL 自定义事件推回主线程
        // data1 = heap-allocated RBFileCallback*
        // data2 = heap-allocated std::string* (路径)
        if (s_fileDialogEventType != static_cast<Uint32>(-1)) {
            auto* cb   = new RBFileCallback(callback);
            auto* path = new std::string(result);
            SDL_Event ev{};
            ev.type       = s_fileDialogEventType;
            ev.user.data1 = cb;
            ev.user.data2 = path;
            SDL_PushEvent(&ev);
        }
    }).detach();
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
