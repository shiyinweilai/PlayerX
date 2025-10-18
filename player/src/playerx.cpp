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
    std::string command;
    
    // 构建video-compare命令
#ifdef _WIN32
    command = "video-compare.exe \"" + file1 + "\" \"" + file2 + "\"";
#else
    command = "./video-compare \"" + file1 + "\" \"" + file2 + "\"";
#endif
    
    std::cout << "Running: " << command << std::endl;
    
    int result = system(command.c_str());
    if (result != 0) {
        std::cerr << "Failed to run video-compare" << std::endl;
    }
}

// 使用AppleScript打开文件选择对话框（在后台线程中执行）
std::string open_file_dialog_thread() {
#ifdef __APPLE__
    std::string script = R"(
        tell application "System Events"
            set theFile to choose file with prompt "请选择视频文件" of type {"public.movie"}
            set thePath to POSIX path of theFile
            return thePath
        end tell
    )";
    
    std::string command = "osascript -e '" + script + "'";
    
    FILE* pipe = popen(command.c_str(), "r");
    if (!pipe) {
        return "";
    }
    
    char buffer[1024];
    std::string result = "";
    
    while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
        result += buffer;
    }
    
    pclose(pipe);
    
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
    std::string file_path = open_file_dialog_thread();
    
    std::lock_guard<std::mutex> lock(file_mutex);
    pending_file_path = file_path;
    pending_file_selection = file_number;
    file_selection_in_progress = false;
    file_cv.notify_one();
}

// 开始文件选择（非阻塞）
void start_file_selection(int file_number) {
    std::lock_guard<std::mutex> lock(file_mutex);
    if (file_selection_in_progress) {
        return; // 已经有文件选择在进行中
    }
    
    file_selection_in_progress = true;
    pending_file_selection = 0;
    pending_file_path = "";
    
    // 在新线程中执行文件选择
    std::thread(file_selection_thread, file_number).detach();
}

// 检查是否有文件选择结果
void check_file_selection_results() {
    std::unique_lock<std::mutex> lock(file_mutex);
    if (!file_selection_in_progress && pending_file_selection != 0) {
        if (!pending_file_path.empty()) {
            if (pending_file_selection == 1) {
                selected_file1 = pending_file_path;
                std::cout << "Selected file 1: " << pending_file_path << std::endl;
            } else if (pending_file_selection == 2) {
                selected_file2 = pending_file_path;
                std::cout << "Selected file 2: " << pending_file_path << std::endl;
            }
        }
        pending_file_selection = 0;
        pending_file_path = "";
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
    SDL_GetWindowSize(window, &window_width, &window_height);
    
    // 检查按钮点击
    int button_y = 200;
    int button_width = 200;
    int button_height = 50;
    int button_spacing = 30;
    
    // 选择第一个文件按钮
    SDL_Rect file1_rect = {(window_width - button_width) / 2, button_y, button_width, button_height};
    if (point_in_rect(x, y, file1_rect)) {
        start_file_selection(1);
    }
    
    // 选择第二个文件按钮
    SDL_Rect file2_rect = {(window_width - button_width) / 2, button_y + button_height + button_spacing, button_width, button_height};
    if (point_in_rect(x, y, file2_rect)) {
        start_file_selection(2);
    }
    
    // 比较按钮
    SDL_Rect compare_rect = {(window_width - button_width) / 2, button_y + (button_height + button_spacing) * 2, button_width, button_height};
    if (point_in_rect(x, y, compare_rect) && !selected_file1.empty() && !selected_file2.empty()) {
        run_video_compare(selected_file1, selected_file2);
    }
    
    // 退出按钮
    SDL_Rect exit_rect = {(window_width - button_width) / 2, button_y + (button_height + button_spacing) * 3, button_width, button_height};
    if (point_in_rect(x, y, exit_rect)) {
        SDL_Event quit_event;
        quit_event.type = SDL_QUIT;
        SDL_PushEvent(&quit_event);
    }
}

// 主渲染函数
void render() {
    // 清屏
    SDL_SetRenderDrawColor(renderer, BACKGROUND_COLOR.r, BACKGROUND_COLOR.g, BACKGROUND_COLOR.b, BACKGROUND_COLOR.a);
    SDL_RenderClear(renderer);
    
    int window_width, window_height;
    SDL_GetWindowSize(window, &window_width, &window_height);
    
    // 绘制标题
    draw_text("Video Compare Player", 20, 20, TEXT_COLOR, title_font);
    
    // 绘制说明文本
    draw_text("请选择两个视频文件进行比较", 20, 80, TEXT_COLOR, font);
    
    // 检查文件选择状态
    std::lock_guard<std::mutex> lock(file_mutex);
    bool is_selecting = file_selection_in_progress;
    
    // 绘制按钮
    int button_y = 200;
    int button_width = 200;
    int button_height = 50;
    int button_spacing = 30;
    
    // 选择第一个文件按钮
    SDL_Rect file1_rect = {(window_width - button_width) / 2, button_y, button_width, button_height};
    SDL_Color file1_color = is_selecting ? SDL_Color{100, 100, 100, 255} : BUTTON_COLOR;
    SDL_SetRenderDrawColor(renderer, file1_color.r, file1_color.g, file1_color.b, file1_color.a);
    SDL_RenderFillRect(renderer, &file1_rect);
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &file1_rect);
    
    std::string file1_text = is_selecting ? "选择中..." : (selected_file1.empty() ? "选择第一个文件" : get_filename(selected_file1));
    draw_text(file1_text, (window_width - file1_text.length() * 8) / 2, button_y + 15, 
              is_selecting ? SDL_Color{150, 150, 150, 255} : TEXT_COLOR, font);
    
    // 选择第二个文件按钮
    SDL_Rect file2_rect = {(window_width - button_width) / 2, button_y + button_height + button_spacing, button_width, button_height};
    SDL_Color file2_color = is_selecting ? SDL_Color{100, 100, 100, 255} : BUTTON_COLOR;
    SDL_SetRenderDrawColor(renderer, file2_color.r, file2_color.g, file2_color.b, file2_color.a);
    SDL_RenderFillRect(renderer, &file2_rect);
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &file2_rect);
    
    std::string file2_text = is_selecting ? "选择中..." : (selected_file2.empty() ? "选择第二个文件" : get_filename(selected_file2));
    draw_text(file2_text, (window_width - file2_text.length() * 8) / 2, button_y + button_height + button_spacing + 15, 
              is_selecting ? SDL_Color{150, 150, 150, 255} : TEXT_COLOR, font);
    
    // 比较按钮
    bool can_compare = (!selected_file1.empty() && !selected_file2.empty() && !is_selecting);
    SDL_Color compare_color = can_compare ? BUTTON_COLOR : SDL_Color{100, 100, 100, 255};
    SDL_Rect compare_rect = {(window_width - button_width) / 2, button_y + (button_height + button_spacing) * 2, button_width, button_height};
    
    SDL_SetRenderDrawColor(renderer, compare_color.r, compare_color.g, compare_color.b, compare_color.a);
    SDL_RenderFillRect(renderer, &compare_rect);
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &compare_rect);
    
    draw_text("开始比较", (window_width - 60) / 2, button_y + (button_height + button_spacing) * 2 + 15, 
              can_compare ? TEXT_COLOR : SDL_Color{150, 150, 150, 255}, font);
    
    // 退出按钮
    SDL_Rect exit_rect = {(window_width - button_width) / 2, button_y + (button_height + button_spacing) * 3, button_width, button_height};
    SDL_Color exit_color = is_selecting ? SDL_Color{100, 100, 100, 255} : BUTTON_COLOR;
    SDL_SetRenderDrawColor(renderer, exit_color.r, exit_color.g, exit_color.b, exit_color.a);
    SDL_RenderFillRect(renderer, &exit_rect);
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &exit_rect);
    
    draw_text("退出", (window_width - 30) / 2, button_y + (button_height + button_spacing) * 3 + 15, 
              is_selecting ? SDL_Color{150, 150, 150, 255} : TEXT_COLOR, font);
    
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