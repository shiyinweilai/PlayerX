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
std::vector<std::string> video_files;
int selected_file1 = -1;
int selected_file2 = -1;
std::string current_directory;

// 获取用户主目录
std::string get_home_directory() {
#ifdef _WIN32
    char path[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathA(NULL, CSIDL_PROFILE, NULL, 0, path))) {
        return std::string(path);
    }
    return "C:\\";
#else
    const char* home = getenv("HOME");
    if (home) return home;
    
    struct passwd* pw = getpwuid(getuid());
    if (pw) return pw->pw_dir;
    
    return "/";
#endif
}

// 获取视频文件扩展名列表
std::vector<std::string> get_video_extensions() {
    return {
        ".mp4", ".avi", ".mkv", ".mov", ".wmv", ".flv", ".webm",
        ".m4v", ".3gp", ".3g2", ".mpeg", ".mpg", ".ts", ".mts",
        ".m2ts", ".ogv", ".divx", ".rm", ".rmvb", ".asf", ".amv"
    };
}

// 检查文件是否为视频文件
bool is_video_file(const std::string& filename) {
    size_t dot_pos = filename.find_last_of(".");
    if (dot_pos == std::string::npos) return false;
    
    std::string ext = filename.substr(dot_pos);
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    
    auto extensions = get_video_extensions();
    return std::find(extensions.begin(), extensions.end(), ext) != extensions.end();
}

// 扫描目录中的视频文件
void scan_directory(const std::string& path) {
    video_files.clear();
    
    try {
        for (const auto& entry : std::filesystem::directory_iterator(path)) {
            if (entry.is_regular_file() && is_video_file(entry.path().filename().string())) {
                video_files.push_back(entry.path().string());
            }
        }
        
        // 按文件名排序
        std::sort(video_files.begin(), video_files.end());
        
    } catch (const std::filesystem::filesystem_error& e) {
        std::cerr << "Error scanning directory: " << e.what() << std::endl;
    }
}

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
    
    // 检查文件列表点击
    int list_y = 120;
    int list_height = window_height - 250;
    int items_per_page = list_height / 25;
    
    if (x >= 40 && x <= window_width - 40 && y >= list_y && y < list_y + items_per_page * 25) {
        int item_index = (y - list_y) / 25;
        if (item_index < (int)video_files.size()) {
            if (selected_file1 == item_index) {
                selected_file1 = -1;
            } else if (selected_file2 == item_index) {
                selected_file2 = -1;
            } else if (selected_file1 == -1) {
                selected_file1 = item_index;
            } else if (selected_file2 == -1) {
                selected_file2 = item_index;
            } else {
                // 替换第一个选择
                selected_file1 = selected_file2;
                selected_file2 = item_index;
            }
        }
    }
    
    // 检查按钮点击
    int button_y = window_height - 60;
    int button_width = 120;
    int button_height = 40;
    
    // 比较按钮
    SDL_Rect compare_rect = {20, button_y, button_width, button_height};
    if (point_in_rect(x, y, compare_rect) && selected_file1 != -1 && selected_file2 != -1) {
        run_video_compare(video_files[selected_file1], video_files[selected_file2]);
    }
    
    // 退出按钮
    SDL_Rect exit_rect = {150, button_y, button_width, button_height};
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
    
    // 绘制当前目录
    draw_text("Current Directory: " + current_directory, 20, 70, TEXT_COLOR, font);
    
    // 绘制文件列表
    int list_y = 120;
    int list_height = window_height - 250;
    int items_per_page = list_height / 25;
    
    draw_text("Select two video files to compare:", 20, list_y - 30, TEXT_COLOR, font);
    
    for (int i = 0; i < std::min(items_per_page, (int)video_files.size()); i++) {
        int file_index = i;
        if (file_index >= (int)video_files.size()) break;
        
        std::string filename = get_filename(video_files[file_index]);
        SDL_Color color = TEXT_COLOR;
        
        if (file_index == selected_file1 || file_index == selected_file2) {
            color = SELECTED_COLOR;
        }
        
        draw_text(filename, 40, list_y + i * 25, color, font);
    }
    
    // 绘制选中的文件
    std::string selected_text = "Selected: ";
    if (selected_file1 != -1) {
        selected_text += get_filename(video_files[selected_file1]);
    }
    if (selected_file2 != -1) {
        selected_text += " vs " + get_filename(video_files[selected_file2]);
    }
    
    draw_text(selected_text, 20, window_height - 100, TEXT_COLOR, font);
    
    // 绘制按钮
    bool can_compare = (selected_file1 != -1 && selected_file2 != -1);
    
    int button_y = window_height - 60;
    int button_width = 120;
    int button_height = 40;
    
    // 比较按钮
    SDL_Color compare_color = can_compare ? BUTTON_COLOR : SDL_Color{100, 100, 100, 255};
    SDL_Rect compare_rect = {20, button_y, button_width, button_height};
    
    SDL_SetRenderDrawColor(renderer, compare_color.r, compare_color.g, compare_color.b, compare_color.a);
    SDL_RenderFillRect(renderer, &compare_rect);
    
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &compare_rect);
    
    draw_text("Compare", 20 + (button_width - 50) / 2, button_y + 12, 
              can_compare ? TEXT_COLOR : SDL_Color{150, 150, 150, 255}, font);
    
    // 退出按钮
    SDL_Rect exit_rect = {150, button_y, button_width, button_height};
    SDL_SetRenderDrawColor(renderer, BUTTON_COLOR.r, BUTTON_COLOR.g, BUTTON_COLOR.b, BUTTON_COLOR.a);
    SDL_RenderFillRect(renderer, &exit_rect);
    
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    SDL_RenderDrawRect(renderer, &exit_rect);
    
    draw_text("Exit", 150 + (button_width - 30) / 2, button_y + 12, TEXT_COLOR, font);
    
    SDL_RenderPresent(renderer);
}

int main(int argc, char* argv[]) {
    if (!init_sdl()) {
        return 1;
    }
    
    // 初始化当前目录
    current_directory = get_home_directory();
    scan_directory(current_directory);
    
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
        
        render();
        SDL_Delay(16); // 约60FPS
    }
    
    cleanup();
    return 0;
}