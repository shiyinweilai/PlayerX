#pragma once
/**
 * rb_player_ui.h — 主 UI 管理器
 * 管理 SDL 窗口/渲染器、字体，以及 N 路 RBVideoCell 的布局和事件分发。
 * 支持 1/2/3/4 路宫格布局，可运行时切换。
 */

#include <vector>
#include <memory>
#include <string>
#include <functional>

#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

namespace rb {

class RBVideoCell;
class RBVideoPlayer;
class RBSliderView;

// 布局模式（路数即枚举值，最多 9 路）
enum class RBLayoutMode {
    Single  = 1,  // 1 路
    Dual    = 2,  // 1行2列
    Triple  = 3,  // 1行3列
    Quad    = 4,  // 2×2 四宫格
    Five    = 5,  // 2行3列
    Six     = 6,  // 2行3列
    Seven   = 7,  // 3行3列
    Eight   = 8,  // 3行3列
    Nine    = 9,  // 3行3列
};

class RBPlayerUI {
public:
    RBPlayerUI();
    ~RBPlayerUI();

    // 初始化 SDL 窗口和渲染器，返回 false 表示失败
    bool rbInit(const std::string& title = "PlayerX", int w = 1280, int h = 720);
    void rbShutdown();

    // 主循环（阻塞直到退出）
    void rbRunLoop();

    // 布局切换（可在运行时调用）
    void rbSetLayout(RBLayoutMode mode);
    RBLayoutMode rbLayout() const { return m_layout; }

    // 动态增加一路视频（最多 9 路）
    void rbAddCell();

    // 删除指定 Cell（索引起始 0），后续路数会整体前移。
    // 允许删空（剩余 0 路）。
    void rbRemoveCell(int idx);

    // Solo 模式：只显示第 idx 路（-1 = 显示全部）
    void rbSetSoloCell(int idx);

    // 为指定 Cell 加载视频（0-based index）
    void rbOpenFileForCell(int cellIndex, const std::string& filePath);

    // 全局同步播放（所有 Cell 同时 play/pause）
    void rbSyncPlay();
    void rbSyncPause();
    void rbSyncToggle();
    void rbSyncSeek(double seconds);
    // 全局同步：将所有 Cell seek 到 0 并暂停，便于从头开始统一播放
    void rbSyncReset();

private:
    // 布局计算：根据窗口大小和 layout 模式，更新每个 Cell 的 rect
    void rbRelayout();

    // 渲染一帧
    void rbRenderFrame();

    // 渲染顶部工具栏
    void rbRenderToolbar();

    // 事件处理
    void rbHandleEvent(const SDL_Event& e);
    void rbHandleKeyDown(const SDL_Keysym& key);
    void rbHandleToolbarClick(int x, int y);

    // 将当前 m_dpiScale 同步到所有 Cell 与 Slider，使其内部布局以 drawable 像素工作
    void rbSyncDpiToChildren();

    // 工具
    void rbDrawText(const std::string& text, int x, int y, SDL_Color color, TTF_Font* f);
    void rbDrawTextCentered(const std::string& text, const SDL_Rect& area, SDL_Color color, TTF_Font* f);
    void rbFillRect(const SDL_Rect& r, SDL_Color color);
    void rbDrawRect(const SDL_Rect& r, SDL_Color color);
    bool rbPointInRect(int x, int y, const SDL_Rect& r) const;

    SDL_Window*     m_window{nullptr};
    SDL_Renderer*   m_renderer{nullptr};
    TTF_Font*       m_font{nullptr};       // 正常字体 16pt
    TTF_Font*       m_titleFont{nullptr};  // 标题字体 22pt
    TTF_Font*       m_smallFont{nullptr};  // 小字体 13pt

    RBLayoutMode    m_layout{RBLayoutMode::Single};

    // Cell 和 Player 的生命周期均由 UI 管理
    std::vector<std::unique_ptr<RBVideoCell>>   m_cells;
    std::vector<std::unique_ptr<RBVideoPlayer>> m_players;

    int             m_activeCellCount{1};  // 当前激活的路数（1~9）
    int             m_soloCell{-1};        // -1=显示全部, >=0=只显示该路

    // ─── Slider 模式（双视频滑动比较，仅在激活路数==2时可进入）──────────
    bool                            m_sliderMode{false};
    std::unique_ptr<RBSliderView>   m_sliderView;
    // 记录上次进入 Slider 模式时两路视频的文件路径，用来判断"是否需要重新
    // reset 到 0"。若再次进入时两路文件未变，则不触发 reset，实现无缝切换。
    std::string                     m_sliderLastPath0;
    std::string                     m_sliderLastPath1;

    bool            m_running{false};
    int             m_mouseX{-1}, m_mouseY{-1};   // 已转换为 drawable 像素坐标

    // ─── HighDPI / drawable 像素 ──────────────────────────────────────────
    // 与 video-compare 的"config 缩放保持清晰"思路一致：所有 UI 几何与字体
    // 全部以 drawable（物理像素）为坐标系工作，避免 SDL_RenderSetLogicalSize
    // 把渲染锁回 window 像素后被合成层二次拉伸导致的模糊。
    float           m_dpiScale{1.0f};        // drawable / window
    int             m_drawableW{0}, m_drawableH{0};

    // 工具栏几何（运行时按 m_dpiScale 计算，以 drawable 像素为单位）
    int             m_tbH{44};
    int             m_tbBtnW{60};
    int             m_tbBtnH{28};
    int             m_tbPad{8};
    int             m_tbNumBtnW{36};

    // 兼容历史代码：仍提供与原同名的常量入口
    int rbToolbarH() const { return m_tbH; }
};

} // namespace rb
