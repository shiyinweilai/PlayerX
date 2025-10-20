#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include <iostream>
#include <string>
#include <vector>
#include <algorithm>
#include <filesystem>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <mutex>
#include <condition_variable>

#ifdef _WIN32
#include <windows.h>
#include <shlobj.h>
#else
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>
// 添加POSIX相关头文件以支持open/posix_spawn/waitpid等
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <limits.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
// 声明environ用于posix_spawn传递环境变量
extern char **environ;
#endif

// 颜色定义
const SDL_Color BACKGROUND_COLOR = {54, 69, 79, 255};
const SDL_Color TEXT_COLOR = {255, 255, 255, 255};
const SDL_Color SUBTEXT_COLOR = {200, 200, 200, 255};
const SDL_Color BUTTON_COLOR = {70, 130, 180, 255};
const SDL_Color BUTTON_HOVER_COLOR = {100, 149, 237, 255};
const SDL_Color DISABLED_COLOR = {100, 100, 100, 255};
const SDL_Color PANEL_BG = {40, 48, 56, 255};
const SDL_Color PANEL_BORDER = {90, 100, 110, 255};

// 全局变量
SDL_Window* window = nullptr;
SDL_Renderer* renderer = nullptr;
TTF_Font* font = nullptr;
TTF_Font* title_font = nullptr;

// 文件选择状态
std::string selected_file1 = "";
std::string selected_file2 = "";

// 线程安全变量
std::mutex file_mutex;
std::condition_variable file_cv;
bool file_selection_in_progress = false;
int pending_file_selection = 0; // 0: 无, 1: 文件1, 2: 文件2
std::string pending_file_path = "";

// 新增：鼠标位置（用于悬停高亮）
static int g_mouse_x = -1;
static int g_mouse_y = -1;

// 获取文件名（不含路径）
std::string get_filename(const std::string& path) {
    size_t last_slash = path.find_last_of("/\\");
    if (last_slash != std::string::npos) {
        return path.substr(last_slash + 1);
    }
    return path;
}

// 文本测量
void measure_text(const std::string& text, TTF_Font* use_font, int& w, int& h) {
    if (!use_font || text.empty()) { w = h = 0; return; }
    if (TTF_SizeUTF8(use_font, text.c_str(), &w, &h) != 0) { w = h = 0; }
}

// 绘制文本
void draw_text(const std::string& text, int x, int y, SDL_Color color, TTF_Font* font) {
    SDL_Surface* surface = TTF_RenderUTF8_Blended(font, text.c_str(), color);
    if (!surface) return;
    
    SDL_Texture* texture = SDL_CreateTextureFromSurface(renderer, surface);
    if (!texture) {
        SDL_FreeSurface(surface);
        return;
    }
    
    SDL_Rect dest = {x, y, surface->w, surface->h};
    SDL_RenderCopy(renderer, texture, nullptr, &dest);
    
    SDL_DestroyTexture(texture);
    SDL_FreeSurface(surface);
}

// 居中绘制文本（按给定矩形居中）
void draw_text_centered(const std::string& text, const SDL_Rect& area, SDL_Color color, TTF_Font* use_font) {
    int w = 0, h = 0;
    measure_text(text, use_font, w, h);
    int x = area.x + (area.w - w) / 2;
    int y = area.y + (area.h - h) / 2;
    draw_text(text, x, y, color, use_font);
}

// 检查点是否在矩形内
bool point_in_rect(int x, int y, const SDL_Rect& rect) {
    return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h;
}

// 新增：获取当前可执行文件所在目录（POSIX/macOS）
static std::string get_executable_dir() {
#ifndef _WIN32
#ifdef __APPLE__
    char pathbuf[PATH_MAX];
    uint32_t size = sizeof(pathbuf);
    if (_NSGetExecutablePath(pathbuf, &size) == 0) {
        char realbuf[PATH_MAX];
        if (realpath(pathbuf, realbuf)) {
            std::string full(realbuf);
            size_t pos = full.find_last_of("/\\");
            if (pos != std::string::npos) return full.substr(0, pos);
        }
    }
#else
    char pathbuf[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", pathbuf, sizeof(pathbuf)-1);
    if (len > 0) {
        pathbuf[len] = '\0';
        std::string full(pathbuf);
        size_t pos = full.find_last_of("/\\");
        if (pos != std::string::npos) return full.substr(0, pos);
    }
#endif
    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd))) return std::string(cwd);
    return std::string(".");
#else
    // Windows 下此函数不使用
    return std::string(".");
#endif
}

// 运行video-compare
void run_video_compare(const std::string& file1, const std::string& file2) {
#ifndef _WIN32
    // 可能的二进制路径候选：优先同目录，其次常见安装产物，最后当前目录
    std::string exeDir = get_executable_dir();
    std::vector<std::string> candidates = {
        exeDir + "/video-compare",
        exeDir + "/../bin/video-compare",
    };
    std::string exe;
    for (const auto& c : candidates) {
        if (std::filesystem::exists(c) && access(c.c_str(), X_OK) == 0) { exe = c; break; }
    }

    // 打开日志文件，捕获stdout/stderr
    const char* log_path = "/tmp/video-compare.run.log";
    int log_fd = ::open(log_path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (log_fd == -1) {
        std::perror("open log file");
    }

    // 使用posix_spawn/posix_spawnp执行
    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (log_fd != -1) {
        posix_spawn_file_actions_adddup2(&actions, log_fd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, log_fd, STDERR_FILENO);
    }

    // 构造argv
    std::vector<char*> argv;
    if (!exe.empty()) {
        argv.push_back(const_cast<char*>(exe.c_str()));
    } else {
        argv.push_back(const_cast<char*>("video-compare"));
    }
    argv.push_back(const_cast<char*>("-w"));
    argv.push_back(const_cast<char*>("960x540"));
    argv.push_back(const_cast<char*>(file1.c_str()));
    argv.push_back(const_cast<char*>(file2.c_str()));
    argv.push_back(nullptr);

    int spawn_rc = 0;
    if (!exe.empty()) {
        std::cout << "Running: " << exe << " -w 960x540 " << file1 << " " << file2 << std::endl;
        spawn_rc = posix_spawn(&pid, exe.c_str(), &actions, nullptr, argv.data(), environ);
    } else {
        std::cout << "Running via PATH: video-compare -w 960x540 " << file1 << " " << file2 << std::endl;
        spawn_rc = posix_spawnp(&pid, "video-compare", &actions, nullptr, argv.data(), environ);
    }

    posix_spawn_file_actions_destroy(&actions);
    if (log_fd != -1) ::close(log_fd);

    if (spawn_rc != 0) {
        std::cerr << "posix_spawn failed: errno=" << spawn_rc << std::endl;
        if (exe.empty()) {
            std::cerr << "Cannot find video-compare executable. Tried:" << std::endl;
            for (const auto& c : candidates) std::cerr << "  " << c << std::endl;
            std::cerr << "Also tried PATH lookup for 'video-compare'." << std::endl;
        }
        return;
    }

    // 等待进程结束
    int status = 0;
    if (waitpid(pid, &status, 0) == -1) {
        std::perror("waitpid");
        return;
    }
    if (WIFEXITED(status)) {
        int code = WEXITSTATUS(status);
        if (code != 0) {
            std::cerr << "video-compare exited with code: " << code << ". See /tmp/video-compare.run.log for details." << std::endl;
        }
    } else if (WIFSIGNALED(status)) {
        std::cerr << "video-compare terminated by signal: " << WTERMSIG(status) << std::endl;
    }
#else
    // Windows：优先使用同目录的video-compare.exe
    char exeFullPath[MAX_PATH];
    DWORD length = GetModuleFileNameA(NULL, exeFullPath, MAX_PATH);
    std::string exeDir;
    if (length > 0 && length < MAX_PATH) {
        int pos = (int)length - 1;
        while (pos >= 0 && exeFullPath[pos] != '\\' && exeFullPath[pos] != '/') pos--;
        if (pos >= 0) {
            exeFullPath[pos] = '\0';
            exeDir = exeFullPath;
        }
    }
    std::string candidate = exeDir.empty() ? std::string("video-compare.exe") : (exeDir + "\\video-compare.exe");

    std::string command;
    if (_access(candidate.c_str(), 0) == 0) {
        command = std::string("\"") + candidate + "\" -w 960x540 \"" + file1 + "\" \"" + file2 + "\"";
    } else {
        // 回退到 PATH 查找
        command = std::string("video-compare.exe -w 960x540 \"") + file1 + "\" \"" + file2 + "\"";
    }

    std::cout << "Running: " << command << std::endl;
    int result = system(command.c_str());
    if (result != 0) {
        std::cerr << "video-compare exited with code: " << result << std::endl;
    }
#endif
}

// 使用macOS原生API打开文件选择对话框（在后台线程中执行）
void file_selection_thread(int file_number);
std::string open_file_dialog_thread() {
#ifdef __APPLE__
    // 使用Objective-C++调用macOS原生文件选择API
    std::string command = R"OBJC(
#import <Cocoa/Cocoa.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
        [[NSRunningApplication currentApplication] activateWithOptions:NSApplicationActivateIgnoringOtherApps];

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"请选择视频文件";
        panel.allowsMultipleSelection = NO;
        panel.canChooseDirectories = NO;
        panel.canChooseFiles = YES;
        // 使用常见扩展名，兼容性更好
        panel.allowedFileTypes = @[@"mov", @"mp4", @"m4v", @"avi", @"mkv", @"webm"]; 

        [panel center];
        [panel makeKeyAndOrderFront:nil];
        [panel orderFrontRegardless];
        [panel setLevel:NSModalPanelWindowLevel];

        NSInteger result = [panel runModal];
        if (result == NSModalResponseOK) {
            NSURL *url = panel.URLs.firstObject;
            const char *path = url.fileSystemRepresentation;
            printf("%s", path);
            return 0;
        }
        return 1;
    }
}
)OBJC";
    
    // 将Objective-C代码写入临时文件
    std::string temp_file = "/tmp/video_select.m";
    FILE* code_file = fopen(temp_file.c_str(), "w");
    if (!code_file) {
        std::cerr << "Failed to create temporary Objective-C file" << std::endl;
        return "";
    }
    fprintf(code_file, "%s", command.c_str());
    fclose(code_file);
    
    // 编译并执行Objective-C程序（开启ARC）
    std::string compile_cmd = "clang -fobjc-arc -framework Cocoa -o /tmp/video_select /tmp/video_select.m";
    std::string exec_cmd = "/tmp/video_select";
    
    std::cout << "Compiling Objective-C code..." << std::endl;
    int compile_status = system(compile_cmd.c_str());
    
    if (compile_status != 0) {
        std::cerr << "Failed to compile Objective-C code" << std::endl;
        remove(temp_file.c_str());
        return "";
    }
    
    std::cout << "Executing file selection dialog..." << std::endl;
    FILE* pipe = popen(exec_cmd.c_str(), "r");
    if (!pipe) {
        std::cerr << "Failed to open pipe for file selection" << std::endl;
        remove(temp_file.c_str());
        remove("/tmp/video_select");
        return "";
    }
    
    char buffer[1024];
    std::string result = "";
    
    while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
        result += buffer;
    }
    
    int status = pclose(pipe);
    std::cout << "File selection execution status: " << status << std::endl;
    std::cout << "File selection result: " << result << std::endl;
    
    // 清理临时文件
    remove(temp_file.c_str());
    remove("/tmp/video_select");
    
    // 移除末尾的换行符
    if (!result.empty() && result[result.length()-1] == '\n') {
        result.erase(result.length()-1);
    }
    
    return result;
#else
    // 对于非macOS系统，使用简单的命令行输入
    std::cout << "请输入视频文件路径: ";
    std::string path;
    std::getline(std::cin, path);
    return path;
#endif
}

// 文件选择线程函数
void file_selection_thread(int file_number) {
    std::cout << "文件选择线程启动，选择文件: " << file_number << std::endl;
    std::string file_path = open_file_dialog_thread();
    
    std::cout << "文件选择结果: " << (file_path.empty() ? "空" : file_path) << std::endl;
    
    std::lock_guard<std::mutex> lock(file_mutex);
    pending_file_path = file_path;
    pending_file_selection = file_number;
    file_selection_in_progress = false;
    std::cout << "文件选择线程结束，file_selection_in_progress设置为false" << std::endl;
    file_cv.notify_one();
}

// 开始文件选择（非阻塞）
void start_file_selection(int file_number) {
    std::lock_guard<std::mutex> lock(file_mutex);
    if (file_selection_in_progress) {
        std::cout << "文件选择正在进行中，跳过新的选择请求" << std::endl;
        return; // 已经有文件选择在进行中
    }
    
    file_selection_in_progress = true;
    pending_file_selection = 0;
    pending_file_path = "";
    std::cout << "开始文件选择: " << file_number << ", file_selection_in_progress设置为true" << std::endl;

    // 不再最小化窗口，依赖系统对话框置顶
    
    // 在新线程中执行文件选择
    std::thread(file_selection_thread, file_number).detach();
}

// 检查是否有文件选择结果
void check_file_selection_results() {
    std::unique_lock<std::mutex> lock(file_mutex);
    if (!file_selection_in_progress && pending_file_selection != 0) {
        std::cout << "检测到文件选择结果: " << pending_file_selection << std::endl;
        if (!pending_file_path.empty()) {
            if (pending_file_selection == 1) {
                selected_file1 = pending_file_path;
                std::cout << "Selected file 1: " << pending_file_path << std::endl;
            } else if (pending_file_selection == 2) {
                selected_file2 = pending_file_path;
                std::cout << "Selected file 2: " << pending_file_path << std::endl;
            }
        } else {
            std::cout << "文件路径为空，可能是用户取消了选择" << std::endl;
        }
        pending_file_selection = 0;
        pending_file_path = "";

        // 文件选择结束后，确保窗口处于前台
        lock.unlock();
        if (window) {
            SDL_RaiseWindow(window);
        }
        lock.lock();
    }
}

// 加载字体
bool load_fonts() {
    // 备选字体路径列表
    std::vector<std::string> font_paths = {
        "/Library/Fonts/Arial Unicode.ttf",        // macOS用户安装的Arial Unicode字体
        "/System/Library/Fonts/Arial.ttf",           // macOS系统字体
        "/Library/Fonts/Arial.ttf",                  // macOS用户安装字体
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",  // Linux字体
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",                 // Linux字体
        "C:\\Windows\\Fonts\\arial.ttf"               // Windows字体
    };
    
    // 尝试加载标题字体
    for (const auto& path : font_paths) {
        title_font = TTF_OpenFont(path.c_str(), 32);
        if (title_font) {
            std::cout << "Loaded title font from: " << path << std::endl;
            break;
        }
    }
    
    // 尝试加载普通字体
    for (const auto& path : font_paths) {
        font = TTF_OpenFont(path.c_str(), 16);
        if (font) {
            std::cout << "Loaded font from: " << path << std::endl;
            break;
        }
    }
    
    if (!title_font || !font) {
        std::cerr << "Failed to load fonts. Tried paths:" << std::endl;
        for (const auto& path : font_paths) {
            std::cerr << "  " << path << std::endl;
        }
        return false;
    }
    
    return true;
}

// 初始化SDL
bool init_sdl() {
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        std::cerr << "SDL_Init failed: " << SDL_GetError() << std::endl;
        return false;
    }
    
    if (TTF_Init() != 0) {
        std::cerr << "TTF_Init failed: " << SDL_GetError() << std::endl;
        return false;
    }
    
    // 创建窗口
    window = SDL_CreateWindow("VideoCompare Player", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1280, 720, SDL_WINDOW_RESIZABLE);
    if (!window) {
        std::cerr << "SDL_CreateWindow failed: " << SDL_GetError() << std::endl;
        return false;
    }
    
    // 创建渲染器
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (!renderer) {
        std::cerr << "SDL_CreateRenderer failed: " << SDL_GetError() << std::endl;
        return false;
    }
    
    // 加载字体
    if (!load_fonts()) {
        std::cerr << "Failed to load fonts" << std::endl;
        return false;
    }
    
    return true;
}

// 清理资源
void cleanup() {
    if (font) TTF_CloseFont(font);
    if (title_font) TTF_CloseFont(title_font);
    if (renderer) SDL_DestroyRenderer(renderer);
    if (window) SDL_DestroyWindow(window);
    TTF_Quit();
    SDL_Quit();
}

// 缓存按钮矩形，供点击检测
static SDL_Rect g_btn_choose_left = {0,0,0,0};
static SDL_Rect g_btn_choose_right = {0,0,0,0};
static SDL_Rect g_btn_compare = {0,0,0,0};
static SDL_Rect g_btn_quit = {0,0,0,0};
static SDL_Rect g_panel_left = {0,0,0,0};
static SDL_Rect g_panel_right = {0,0,0,0};

// 主渲染函数（全新布局：顶部标题 + 中部左右预览面板 + 底部工具栏）
void render() {
    // 清屏
    SDL_SetRenderDrawColor(renderer, BACKGROUND_COLOR.r, BACKGROUND_COLOR.g, BACKGROUND_COLOR.b, BACKGROUND_COLOR.a);
    SDL_RenderClear(renderer);
    
    int window_width, window_height;
    // 使用渲染器输出尺寸，确保与鼠标事件坐标一致
    SDL_GetRendererOutputSize(renderer, &window_width, &window_height);
    
    // 检查字体是否加载成功
    if (!font || !title_font) {
        std::cerr << "Fonts not loaded properly!" << std::endl;
        return;
    }
    
    // 布局参数
    const int padding = 20;
    const int header_h = 70;
    const int toolbar_h = 90;
    const int gap = padding;
    
    // 顶部标题与说明
    SDL_Rect header_rect = {padding, padding, window_width - 2*padding, header_h - padding};
    draw_text("VideoCompare Player", header_rect.x, header_rect.y, TEXT_COLOR, title_font);
    draw_text("请选择两个视频文件进行比较（预览面板为占位，未来用于分屏播放）", header_rect.x, header_rect.y + 40, SUBTEXT_COLOR, font);
    
    // 中部预览区
    int panels_y = header_rect.y + header_rect.h + padding;
    int panels_h = std::max(100, window_height - panels_y - toolbar_h - padding);
    int panels_w = window_width - 2*padding;
    int each_w = (panels_w - gap) / 2;
    g_panel_left = {padding, panels_y, each_w, panels_h};
    g_panel_right = {padding + each_w + gap, panels_y, each_w, panels_h};

    auto draw_panel = [&](const SDL_Rect& r, const std::string& title, const std::string& filename){
        // 背景
        SDL_SetRenderDrawColor(renderer, PANEL_BG.r, PANEL_BG.g, PANEL_BG.b, PANEL_BG.a);
        SDL_RenderFillRect(renderer, &r);
        // 边框
        SDL_SetRenderDrawColor(renderer, PANEL_BORDER.r, PANEL_BORDER.g, PANEL_BORDER.b, 255);
        SDL_RenderDrawRect(renderer, &r);
        // 标题
        SDL_Rect title_area = {r.x + 10, r.y + 10, r.w - 20, 24};
        draw_text(title, title_area.x, title_area.y, SUBTEXT_COLOR, font);
        // 中央占位提示
        SDL_Rect center_area = {r.x + 10, r.y + 10 + 24, r.w - 20, r.h - 20 - 24 - 30};
        draw_text_centered("预览占位", center_area, SDL_Color{180,180,180,255}, font);
        // 底部文件名
        std::string name = filename.empty() ? "未选择文件" : get_filename(filename);
        SDL_Rect bottom_area = {r.x + 10, r.y + r.h - 28, r.w - 20, 20};
        draw_text_centered(name, bottom_area, TEXT_COLOR, font);
    };

    // 绘制左右面板
    {
        std::lock_guard<std::mutex> lock(file_mutex);
        draw_panel(g_panel_left, "左侧预览", selected_file1);
        draw_panel(g_panel_right, "右侧预览", selected_file2);
    }

    // 底部工具栏按钮
    int btn_w = 180;
    int btn_h = 50;
    int btn_gap = 30;
    int total_btn_w = btn_w*4 + btn_gap*3;
    int btn_start_x = std::max(padding, (window_width - total_btn_w)/2);
    int btn_y = window_height - toolbar_h/2 - btn_h/2;

    g_btn_choose_left  = {btn_start_x + (btn_w+btn_gap)*0, btn_y, btn_w, btn_h};
    g_btn_choose_right = {btn_start_x + (btn_w+btn_gap)*1, btn_y, btn_w, btn_h};
    g_btn_compare      = {btn_start_x + (btn_w+btn_gap)*2, btn_y, btn_w, btn_h};
    g_btn_quit         = {btn_start_x + (btn_w+btn_gap)*3, btn_y, btn_w, btn_h};

    auto draw_button = [&](const SDL_Rect& r, const std::string& label, bool enabled){
        bool hover = enabled && point_in_rect(g_mouse_x, g_mouse_y, r);
        SDL_Color color = enabled ? (hover ? BUTTON_HOVER_COLOR : BUTTON_COLOR) : DISABLED_COLOR;
        SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
        SDL_RenderFillRect(renderer, &r);
        SDL_SetRenderDrawColor(renderer, 255,255,255,255);
        SDL_RenderDrawRect(renderer, &r);
        draw_text_centered(label, r, enabled ? TEXT_COLOR : SDL_Color{150,150,150,255}, font);
    };

    bool is_selecting = false;
    {
        std::lock_guard<std::mutex> lock(file_mutex);
        is_selecting = file_selection_in_progress;
    }

    draw_button(g_btn_choose_left,  is_selecting ? "选择中..." : "选择左侧文件", !is_selecting);
    draw_button(g_btn_choose_right, is_selecting ? "选择中..." : "选择右侧文件", !is_selecting);

    bool can_compare = false;
    {
        std::lock_guard<std::mutex> lock(file_mutex);
        can_compare = (!selected_file1.empty() && !selected_file2.empty() && !file_selection_in_progress);
    }
    draw_button(g_btn_compare, "开始比较", can_compare);
    draw_button(g_btn_quit, "退出", true);

    SDL_RenderPresent(renderer);
}

// 处理鼠标点击（更新为新布局按钮）
void handle_click(int x, int y) {
    int window_width, window_height;
    SDL_GetRendererOutputSize(renderer, &window_width, &window_height);
    bool is_selecting = false;
    {
        std::lock_guard<std::mutex> lock(file_mutex);
        is_selecting = file_selection_in_progress;
    }

    if (!is_selecting && point_in_rect(x, y, g_btn_choose_left)) {
        std::cout << "点击命中: 选择左侧文件" << std::endl;
        start_file_selection(1);
        return;
    }
    if (!is_selecting && point_in_rect(x, y, g_btn_choose_right)) {
        std::cout << "点击命中: 选择右侧文件" << std::endl;
        start_file_selection(2);
        return;
    }

    if (point_in_rect(x, y, g_btn_compare)) {
        std::lock_guard<std::mutex> lock(file_mutex);
        if (!selected_file1.empty() && !selected_file2.empty() && !file_selection_in_progress) {
            std::cout << "点击命中: 开始比较按钮" << std::endl;
            run_video_compare(selected_file1, selected_file2);
            return;
        }
    }

    if (point_in_rect(x, y, g_btn_quit)) {
        std::cout << "点击命中: 退出按钮" << std::endl;
        SDL_Event quit_event;
        quit_event.type = SDL_QUIT;
        SDL_PushEvent(&quit_event);
        return;
    }
}

int main(int argc, char* argv[]) {
    if (!init_sdl()) {
        return 1;
    }
    
    bool running = true;
    while (running) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            switch (event.type) {
                case SDL_QUIT:
                    running = false;
                    break;
                case SDL_MOUSEBUTTONDOWN:
                    if (event.button.button == SDL_BUTTON_LEFT) {
                        handle_click(event.button.x, event.button.y);
                    }
                    break;
                case SDL_MOUSEMOTION:
                    // 新增：更新鼠标位置用于悬停高亮
                    g_mouse_x = event.motion.x;
                    g_mouse_y = event.motion.y;
                    break;
                case SDL_KEYDOWN:
                    if (event.key.keysym.sym == SDLK_ESCAPE) {
                        running = false;
                    }
                    break;
            }
        }
        
        // 检查文件选择结果
        check_file_selection_results();
        
        render();
        SDL_Delay(16); // 约60FPS
    }
    
    cleanup();
    return 0;
}