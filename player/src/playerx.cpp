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
// 声明environ用于posix_spawn传递环境变量
extern char **environ;
#endif

// 颜色定义
const SDL_Color BACKGROUND_COLOR = {54, 69, 79, 255};
const SDL_Color TEXT_COLOR = {255, 255, 255, 255};
const SDL_Color BUTTON_COLOR = {70, 130, 180, 255};
const SDL_Color BUTTON_HOVER_COLOR = {100, 149, 237, 255};
const SDL_Color SELECTED_COLOR = {50, 205, 50, 255};

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

// 检查点是否在矩形内
bool point_in_rect(int x, int y, const SDL_Rect& rect) {
    return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h;
}

// 运行video-compare
void run_video_compare(const std::string& file1, const std::string& file2) {
#ifndef _WIN32
    // 可能的二进制路径候选（优先使用安装产物，与player.sh一致）
    std::vector<std::string> candidates = {
        "/Users/rbyang/Documents/UGit/private/PlayerX/build/player/install/bin/video-compare",
        "./video-compare"
    };
    std::string exe;
    for (const auto& c : candidates) {
        if (std::filesystem::exists(c) && access(c.c_str(), X_OK) == 0) { exe = c; break; }
    }
    if (exe.empty()) {
        std::cerr << "Cannot find video-compare executable. Tried:" << std::endl;
        for (const auto& c : candidates) std::cerr << "  " << c << std::endl;
        return;
    }

    // 构造argv
    std::vector<char*> argv;
    argv.push_back(const_cast<char*>(exe.c_str()));
    argv.push_back(const_cast<char*>("-w"));
    argv.push_back(const_cast<char*>("960x540"));
    argv.push_back(const_cast<char*>(file1.c_str()));
    argv.push_back(const_cast<char*>(file2.c_str()));
    argv.push_back(nullptr);

    // 打开日志文件，捕获stdout/stderr
    const char* log_path = "/tmp/video-compare.run.log";
    int log_fd = ::open(log_path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (log_fd == -1) {
        std::perror("open log file");
    }

    // 使用posix_spawn执行
    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (log_fd != -1) {
        posix_spawn_file_actions_adddup2(&actions, log_fd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, log_fd, STDERR_FILENO);
    }

    std::cout << "Running: " << exe << " -w 960x540 " << file1 << " " << file2 << std::endl;

    int spawn_rc = posix_spawn(&pid, exe.c_str(), &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    if (log_fd != -1) ::close(log_fd);

    if (spawn_rc != 0) {
        std::cerr << "posix_spawn failed: errno=" << spawn_rc << std::endl;
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
    // Windows 简单回退（后续可改为CreateProcess）
    std::string command = "video-compare.exe -w 960x540 \"" + file1 + "\" \"" + file2 + "\"";
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

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"请选择视频文件";
        panel.allowsMultipleSelection = NO;
        panel.canChooseDirectories = NO;
        panel.canChooseFiles = YES;
        // 使用常见扩展名，兼容性更好
        panel.allowedFileTypes = @[@"mov", @"mp4", @"m4v", @"avi", @"mkv", @"webm"]; 

        [panel center];
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

    // 在弹出系统文件选择前最小化当前窗口，避免遮挡（macOS下尤为重要）
    if (window) {
        SDL_MinimizeWindow(window);
    }
    
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

        // 文件选择结束后恢复并置顶SDL窗口
        lock.unlock();
        if (window) {
            SDL_RestoreWindow(window);
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
    window = SDL_CreateWindow("Video Compare Player", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1280, 720, SDL_WINDOW_RESIZABLE);
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

// 处理鼠标点击
void handle_click(int x, int y) {
    int window_width, window_height;
    // 使用渲染器输出尺寸，避免在HiDPI下坐标不一致
    SDL_GetRendererOutputSize(renderer, &window_width, &window_height);
    std::cout << "Mouse click at: (" << x << ", " << y << ") renderer size: " << window_width << "x" << window_height << std::endl;
    
    // 检查按钮点击
    int button_y = 200;
    int button_width = 200;
    int button_height = 50;
    int button_spacing = 30;
    
    // 选择第一个文件按钮
    SDL_Rect file1_rect = {(window_width - button_width) / 2, button_y, button_width, button_height};
    std::cout << "file1_rect: x=" << file1_rect.x << ", y=" << file1_rect.y << ", w=" << file1_rect.w << ", h=" << file1_rect.h << std::endl;
    if (point_in_rect(x, y, file1_rect)) {
        std::cout << "点击命中: 选择第一个文件按钮" << std::endl;
        start_file_selection(1);
        return;
    }
    
    // 选择第二个文件按钮
    SDL_Rect file2_rect = {(window_width - button_width) / 2, button_y + button_height + button_spacing, button_width, button_height};
    std::cout << "file2_rect: x=" << file2_rect.x << ", y=" << file2_rect.y << ", w=" << file2_rect.w << ", h=" << file2_rect.h << std::endl;
    if (point_in_rect(x, y, file2_rect)) {
        std::cout << "点击命中: 选择第二个文件按钮" << std::endl;
        start_file_selection(2);
        return;
    }
    
    // 比较按钮
    SDL_Rect compare_rect = {(window_width - button_width) / 2, button_y + (button_height + button_spacing) * 2, button_width, button_height};
    std::cout << "compare_rect: x=" << compare_rect.x << ", y=" << compare_rect.y << ", w=" << compare_rect.w << ", h=" << compare_rect.h << std::endl;
    if (point_in_rect(x, y, compare_rect) && !selected_file1.empty() && !selected_file2.empty()) {
        std::cout << "点击命中: 开始比较按钮" << std::endl;
        run_video_compare(selected_file1, selected_file2);
        return;
    }
    
    // 退出按钮
    SDL_Rect exit_rect = {(window_width - button_width) / 2, button_y + (button_height + button_spacing) * 3, button_width, button_height};
    std::cout << "exit_rect: x=" << exit_rect.x << ", y=" << exit_rect.y << ", w=" << exit_rect.w << ", h=" << exit_rect.h << std::endl;
    if (point_in_rect(x, y, exit_rect)) {
        std::cout << "点击命中: 退出按钮" << std::endl;
        SDL_Event quit_event;
        quit_event.type = SDL_QUIT;
        SDL_PushEvent(&quit_event);
        return;
    }
}

// 主渲染函数
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
    
    // 绘制标题
    draw_text("Video Compare Player", 20, 20, TEXT_COLOR, title_font);
    
    // 绘制说明文本
    draw_text("请选择两个视频文件进行比较", 20, 80, TEXT_COLOR, font);
    
    // 检查文件选择状态
    std::lock_guard<std::mutex> lock(file_mutex);
    bool is_selecting = file_selection_in_progress;
    
    // std::cout << "Rendering - is_selecting: " << is_selecting 
    //           << ", file1: " << (selected_file1.empty() ? "empty" : selected_file1)
    //           << ", file2: " << (selected_file2.empty() ? "empty" : selected_file2) << std::endl;
    
    // 绘制按钮
    int button_y = 200;
    int button_width = 200;
    int button_height = 50;
    int button_spacing = 30;
    
    // 选择第一个文件按钮 - 只有当没有选择进行中时才可点击
    SDL_Rect file1_rect = {(window_width - button_width) / 2, button_y, button_width, button_height};
    // 根据悬停与选择状态调整颜色
    bool hover_file1 = (!is_selecting && point_in_rect(g_mouse_x, g_mouse_y, file1_rect));
    SDL_Color file1_color = is_selecting ? SDL_Color{100, 100, 100, 255} : (hover_file1 ? BUTTON_HOVER_COLOR : BUTTON_COLOR);
    SDL_SetRenderDrawColor(renderer, file1_color.r, file1_color.g, file1_color.b, file1_color.a);
    SDL_RenderFillRect(renderer, &file1_rect);
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &file1_rect);
    
    std::string file1_text = is_selecting ? "选择中..." : (selected_file1.empty() ? "选择第一个文件" : get_filename(selected_file1));
    int text_width = file1_text.length() * 8; // 估算文本宽度
    draw_text(file1_text, (window_width - text_width) / 2, button_y + 15, 
              is_selecting ? SDL_Color{150, 150, 150, 255} : TEXT_COLOR, font);
    
    // 选择第二个文件按钮 - 只有当没有选择进行中时才可点击
    SDL_Rect file2_rect = {(window_width - button_width) / 2, button_y + button_height + button_spacing, button_width, button_height};
    bool hover_file2 = (!is_selecting && point_in_rect(g_mouse_x, g_mouse_y, file2_rect));
    SDL_Color file2_color = is_selecting ? SDL_Color{100, 100, 100, 255} : (hover_file2 ? BUTTON_HOVER_COLOR : BUTTON_COLOR);
    SDL_SetRenderDrawColor(renderer, file2_color.r, file2_color.g, file2_color.b, file2_color.a);
    SDL_RenderFillRect(renderer, &file2_rect);
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &file2_rect);
    
    std::string file2_text = is_selecting ? "选择中..." : (selected_file2.empty() ? "选择第二个文件" : get_filename(selected_file2));
    text_width = file2_text.length() * 8; // 估算文本宽度
    draw_text(file2_text, (window_width - text_width) / 2, button_y + button_height + button_spacing + 15, 
              is_selecting ? SDL_Color{150, 150, 150, 255} : TEXT_COLOR, font);
    
    // 比较按钮 - 只有当两个文件都已选择且没有选择进行中时才可点击
    bool can_compare = (!selected_file1.empty() && !selected_file2.empty() && !is_selecting);
    SDL_Rect compare_rect = {(window_width - button_width) / 2, button_y + (button_height + button_spacing) * 2, button_width, button_height};
    bool hover_compare = (can_compare && point_in_rect(g_mouse_x, g_mouse_y, compare_rect));
    SDL_Color compare_color = can_compare ? (hover_compare ? BUTTON_HOVER_COLOR : BUTTON_COLOR) : SDL_Color{100, 100, 100, 255};
    
    SDL_SetRenderDrawColor(renderer, compare_color.r, compare_color.g, compare_color.b, compare_color.a);
    SDL_RenderFillRect(renderer, &compare_rect);
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &compare_rect);
    
    draw_text("开始比较", (window_width - 60) / 2, button_y + (button_height + button_spacing) * 2 + 15, 
              can_compare ? TEXT_COLOR : SDL_Color{150, 150, 150, 255}, font);
    
    // 退出按钮 - 总是可点击
    SDL_Rect exit_rect = {(window_width - button_width) / 2, button_y + (button_height + button_spacing) * 3, button_width, button_height};
    bool hover_exit = point_in_rect(g_mouse_x, g_mouse_y, exit_rect);
    SDL_Color exit_color = hover_exit ? BUTTON_HOVER_COLOR : BUTTON_COLOR;
    SDL_SetRenderDrawColor(renderer, exit_color.r, exit_color.g, exit_color.b, exit_color.a);
    SDL_RenderFillRect(renderer, &exit_rect);
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &exit_rect);
    
    draw_text("退出", (window_width - 30) / 2, button_y + (button_height + button_spacing) * 3 + 15, TEXT_COLOR, font);
    
    // 绘制选中的文件信息
    if (!selected_file1.empty() || !selected_file2.empty()) {
        std::string selected_text = "已选择: ";
        if (!selected_file1.empty()) {
            selected_text += get_filename(selected_file1);
        }
        if (!selected_file2.empty()) {
            selected_text += " vs " + get_filename(selected_file2);
        }
        
        SDL_Rect selected_bg_rect = {15, window_height - 80, window_width - 30, 30};
        SDL_SetRenderDrawColor(renderer, 30, 144, 255, 50); // 半透明蓝色背景
        SDL_RenderFillRect(renderer, &selected_bg_rect);
        SDL_SetRenderDrawColor(renderer, 30, 144, 255, 255); // 蓝色边框
        SDL_RenderDrawRect(renderer, &selected_bg_rect);
        
        draw_text(selected_text, 20, window_height - 65, TEXT_COLOR, font);
    }
    
    SDL_RenderPresent(renderer);
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