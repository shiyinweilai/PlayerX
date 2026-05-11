#include "rb_player_ui.h"
#include "rb_video_cell.h"
#include "rb_slider_view.h"
#include "../player/rb_video_player.h"
#include "../utils/rb_utils.h"
#include <iostream>
#include <algorithm>
#include <cmath>

namespace rb {

// ─── 颜色 ─────────────────────────────────────────────────────────────────────
static constexpr SDL_Color kUIBg        = {22,  26,  32,  255};
static constexpr SDL_Color kUIToolbarBg = {30,  35,  44,  255};
static constexpr SDL_Color kUIText      = {220, 222, 228, 255};
static constexpr SDL_Color kUIBtn       = {50,  110, 190, 255};
static constexpr SDL_Color kUIBtnHover  = {75,  145, 235, 255};
static constexpr SDL_Color kUIBtnActive = {40,  90,  160, 255};

// ─── 工具栏按钮布局（逻辑常量，运行时会乘以 DPI 缩放子存于 m_tb*）───────────────────────────────
static constexpr int kTBBtnWLogical    = 60;
static constexpr int kTBBtnHLogical    = 28;
static constexpr int kTBPadLogical     = 8;
static constexpr int kTBNumBtnWLogical = 36;
static constexpr int kToolbarHLogical  = 44;
// ═══════════════════════════════════════════════════════════════════════════
// RBPlayerUI
// ═══════════════════════════════════════════════════════════════════════════

RBPlayerUI::RBPlayerUI() = default;

RBPlayerUI::~RBPlayerUI() {
    rbShutdown();
}

bool RBPlayerUI::rbInit(const std::string& title, int w, int h) {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        std::cerr << "[RBPlayerUI] SDL_Init 失败: " << SDL_GetError() << std::endl;
        return false;
    }
    // 注册文件对话框自定义事件（必须在 SDL_Init 之后）
    rbInitFileDialogEvent();

    if (TTF_Init() != 0) {
        std::cerr << "[RBPlayerUI] TTF_Init 失败: " << TTF_GetError() << std::endl;
        return false;
    }

    m_window = SDL_CreateWindow(title.c_str(),
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        w, h, SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    if (!m_window) {
        std::cerr << "[RBPlayerUI] 创建窗口失败: " << SDL_GetError() << std::endl;
        return false;
    }

    m_renderer = SDL_CreateRenderer(m_window, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!m_renderer) {
        std::cerr << "[RBPlayerUI] 创建渲染器失败: " << SDL_GetError() << std::endl;
        return false;
    }

    // ── HighDPI 适配（与 video-compare 缩放清晰策略一致）──
    // 1) 取得 drawable（物理像素）尺寸；2) 计算 dpi factor；3) 不调用 SDL_RenderSetLogicalSize，
    // 让所有渲染直接落在物理像素上；4) 按 factor 放大 UI 几何 + 字体光栅化分辨率。
    int wW = w, wH = h;
    SDL_GetWindowSize(m_window, &wW, &wH);
    SDL_GL_GetDrawableSize(m_window, &m_drawableW, &m_drawableH);
    if (m_drawableW <= 0) m_drawableW = wW;
    if (m_drawableH <= 0) m_drawableH = wH;
    m_dpiScale = (wW > 0) ? static_cast<float>(m_drawableW) / static_cast<float>(wW) : 1.0f;

    // 工具栏与按钮几何按物理像素重新计算
    m_tbH       = static_cast<int>(std::round(kToolbarHLogical  * m_dpiScale));
    m_tbBtnW    = static_cast<int>(std::round(kTBBtnWLogical    * m_dpiScale));
    m_tbBtnH    = static_cast<int>(std::round(kTBBtnHLogical    * m_dpiScale));
    m_tbPad     = static_cast<int>(std::round(kTBPadLogical     * m_dpiScale));
    m_tbNumBtnW = static_cast<int>(std::round(kTBNumBtnWLogical * m_dpiScale));

    // 字体 size 直接按物理像素加载，保证文字以原生 DPI 锐利渲染
    int fontPt      = std::max(8, static_cast<int>(std::round(16 * m_dpiScale)));
    int titleFontPt = std::max(10, static_cast<int>(std::round(22 * m_dpiScale)));
    int smallFontPt = std::max(7, static_cast<int>(std::round(13 * m_dpiScale)));
    m_font      = rbLoadFont(fontPt);
    m_titleFont = rbLoadFont(titleFontPt);
    m_smallFont = rbLoadFont(smallFontPt);
    if (!m_font) {
        std::cerr << "[RBPlayerUI] font load failed" << std::endl;
        return false;
    }

    // 默认单路布局，创建 1 个 Cell
    rbSetLayout(RBLayoutMode::Single);

    // 初始化 Slider 视图（共享 renderer/字体），player 在进入模式时再绑定
    m_sliderView = std::make_unique<RBSliderView>();
    m_sliderView->rbInit(m_renderer, m_font, m_smallFont);
    return true;
}

void RBPlayerUI::rbShutdown() {
    m_cells.clear();
    m_players.clear();
    if (m_font)      { TTF_CloseFont(m_font);      m_font      = nullptr; }
    if (m_titleFont) { TTF_CloseFont(m_titleFont); m_titleFont = nullptr; }
    if (m_smallFont) { TTF_CloseFont(m_smallFont); m_smallFont = nullptr; }
    if (m_renderer)  { SDL_DestroyRenderer(m_renderer); m_renderer = nullptr; }
    if (m_window)    { SDL_DestroyWindow(m_window);     m_window   = nullptr; }
    TTF_Quit();
    SDL_Quit();
}

// ─── 内部：创建一个新 Cell+Player 并追加 ─────────────────────────────────────
static void rbMakeCellPlayer(RBPlayerUI* ui, SDL_Renderer* renderer,
                              TTF_Font* font, TTF_Font* smallFont,
                              std::vector<std::unique_ptr<RBVideoCell>>& cells,
                              std::vector<std::unique_ptr<RBVideoPlayer>>& players) {
    auto player = std::make_unique<RBVideoPlayer>();
    auto cell   = std::make_unique<RBVideoCell>();
    cell->rbInit(renderer, font, smallFont);
    cell->rbSetPlayer(player.get());

    int idx = static_cast<int>(cells.size());
    cell->rbSetTitle("Ch." + std::to_string(idx + 1));

    cell->rbSetOpenFileCallback([ui, idx](RBVideoCell*) {
        rbOpenFileDialog([ui, idx](const std::string& path) {
            if (!path.empty()) ui->rbOpenFileForCell(idx, path);
        });
    });

    players.push_back(std::move(player));
    cells.push_back(std::move(cell));
}

// ─── 布局 ─────────────────────────────────────────────────────────────────────
void RBPlayerUI::rbSetLayout(RBLayoutMode mode) {
    int n = static_cast<int>(mode);
    m_layout = mode;
    m_activeCellCount = n;
    m_soloCell = -1;  // 切换布局时退出 solo 模式

    // 扩展 Cell 和 Player 数量（只增不减，保留已有播放器）
    while (static_cast<int>(m_players.size()) < n) {
        rbMakeCellPlayer(this, m_renderer, m_font, m_smallFont, m_cells, m_players);
    }

    rbRelayout();
}

void RBPlayerUI::rbAddCell() {
    if (m_activeCellCount >= 9) return;
    m_activeCellCount++;
    m_soloCell = -1;  // 退出 solo 模式

    // 按需创建新 Cell
    while (static_cast<int>(m_players.size()) < m_activeCellCount) {
        rbMakeCellPlayer(this, m_renderer, m_font, m_smallFont, m_cells, m_players);
    }

    // 同步 layout 枚举
    m_layout = static_cast<RBLayoutMode>(m_activeCellCount);
    rbRelayout();
}

void RBPlayerUI::rbSetSoloCell(int idx) {
    if (idx < 0 || idx >= m_activeCellCount) return;
    if (m_soloCell == idx) {
        // 再次点击同一路 → 退出 solo，恢复多路显示
        m_soloCell = -1;
    } else {
        m_soloCell = idx;
    }
    rbRelayout();
}

void RBPlayerUI::rbSyncDpiToChildren() {
    for (auto& c : m_cells) {
        if (c) c->rbSetDpiScale(m_dpiScale);
    }
    if (m_sliderView) m_sliderView->rbSetDpiScale(m_dpiScale);
}

void RBPlayerUI::rbRelayout() {
    int ww = m_drawableW, wh = m_drawableH;
    if (m_window) {
        SDL_GL_GetDrawableSize(m_window, &ww, &wh);
        m_drawableW = ww; m_drawableH = wh;
    }

    // 每次重布局都把 dpi 同步给子组件（新创建的 cell 也能拿到正确缩放）
    rbSyncDpiToChildren();

    int contentY = m_tbH;
    int contentH = wh - m_tbH;
    int contentW = ww;
    const int kGap = std::max(2, static_cast<int>(std::round(4 * m_dpiScale)));

    auto setCell = [&](int i, int x, int y, int w, int h) {
        if (i < static_cast<int>(m_cells.size())) {
            m_cells[i]->rbSetRect({ x, y, w, h });
        }
    };

    // Solo 模式：只显示一路，全屏
    if (m_soloCell >= 0 && m_soloCell < m_activeCellCount) {
        setCell(m_soloCell, 0, contentY, contentW, contentH);
        return;
    }

    int n = m_activeCellCount;

    // 确定行列数
    //  1       → 1×1
    //  2       → 1×2
    //  3       → 1×3
    //  4       → 2×2
    //  5~6     → 2×3
    //  7~9     → 3×3
    int cols, rows;
    if      (n == 1)            { cols = 1; rows = 1; }
    else if (n == 2)            { cols = 2; rows = 1; }
    else if (n == 3)            { cols = 3; rows = 1; }
    else if (n == 4)            { cols = 2; rows = 2; }
    else if (n <= 6)            { cols = 3; rows = 2; }
    else                        { cols = 3; rows = 3; }

    // 计算每格宽高（均分，最后一列/行吸收余数）
    // 列宽：(contentW - (cols-1)*kGap) / cols
    // 行高：(contentH - (rows-1)*kGap) / rows
    auto colX = [&](int c) -> int {
        int totalGap = (cols - 1) * kGap;
        int baseW    = (contentW - totalGap) / cols;
        int extra    = (contentW - totalGap) - baseW * cols;  // 余数像素
        // 前 extra 列各宽 1px
        int x = 0;
        for (int i = 0; i < c; ++i) x += baseW + (i < extra ? 1 : 0) + kGap;
        return x;
    };
    auto colW = [&](int c) -> int {
        int totalGap = (cols - 1) * kGap;
        int baseW    = (contentW - totalGap) / cols;
        int extra    = (contentW - totalGap) - baseW * cols;
        return baseW + (c < extra ? 1 : 0);
    };
    auto rowY = [&](int r) -> int {
        int totalGap = (rows - 1) * kGap;
        int baseH    = (contentH - totalGap) / rows;
        int extra    = (contentH - totalGap) - baseH * rows;
        int y = contentY;
        for (int i = 0; i < r; ++i) y += baseH + (i < extra ? 1 : 0) + kGap;
        return y;
    };
    auto rowH = [&](int r) -> int {
        int totalGap = (rows - 1) * kGap;
        int baseH    = (contentH - totalGap) / rows;
        int extra    = (contentH - totalGap) - baseH * rows;
        return baseH + (r < extra ? 1 : 0);
    };

    for (int i = 0; i < n; ++i) {
        int r = i / cols;
        int c = i % cols;
        setCell(i, colX(c), rowY(r), colW(c), rowH(r));
    }
}

// ─── 文件加载 ─────────────────────────────────────────────────────────────────
void RBPlayerUI::rbOpenFileForCell(int cellIndex, const std::string& filePath) {
    if (cellIndex < 0 || cellIndex >= static_cast<int>(m_players.size())) return;
    auto* player = m_players[cellIndex].get();
    player->rbClose();
    if (player->rbOpen(filePath)) {
        player->rbPlay();
        std::cout << "[RBPlayerUI] Cell " << cellIndex << " opened: " << filePath << std::endl;
    } else {
        std::cerr << "[RBPlayerUI] Cell " << cellIndex << " open failed: " << filePath << std::endl;
    }
}

// ─── 同步控制 ─────────────────────────────────────────────────────────────────
void RBPlayerUI::rbSyncPlay() {
    for (auto& p : m_players) p->rbPlay();
}

void RBPlayerUI::rbSyncPause() {
    for (auto& p : m_players) p->rbPause();
}

void RBPlayerUI::rbSyncToggle() {
    // 以第一个有效播放器的状态为准
    bool anyPlaying = false;
    for (auto& p : m_players) {
        if (p->rbIsPlaying()) { anyPlaying = true; break; }
    }
    if (anyPlaying) {
        rbSyncPause();
    } else {
        // 只对 Ready/Paused 状态的 player 调用 rbPlay，跳过 Ended/Idle
        for (auto& p : m_players) {
            auto s = p->rbState();
            if (s == RBPlayerState::Ready || s == RBPlayerState::Paused) {
                p->rbPlay();
            }
        }
    }
}

void RBPlayerUI::rbSyncSeek(double seconds) {
    for (auto& p : m_players) {
        if (p->rbState() != RBPlayerState::Idle) p->rbSeekTo(seconds);
    }
}

void RBPlayerUI::rbSyncReset() {
    // 将所有有效播放器回到 0 并暂停，便于用户随后统一从头开始播放
    for (auto& p : m_players) {
        if (p->rbState() == RBPlayerState::Idle) continue;
        p->rbPause();
        p->rbSeekTo(0.0);
    }
    // seek 后画面仍是旧帧，主动等待解码并刷新到首帧，
    // 让用户视觉上立即看到"对齐到 0:00 的画面"，而不是等到点 Play 才更新。
    for (auto& p : m_players) {
        if (p->rbState() == RBPlayerState::Idle) continue;
        p->rbRefreshPausedFrame();
    }
}

// ─── 主循环 ───────────────────────────────────────────────────────────────────
void RBPlayerUI::rbRunLoop() {
    m_running = true;
    while (m_running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            rbHandleEvent(e);
        }
        rbRenderFrame();
        // VSync 已开启，不需要额外 delay
    }
}

// ─── 渲染 ─────────────────────────────────────────────────────────────────────────────────────────────
void RBPlayerUI::rbRenderFrame() {
    // 同步 drawable 尺寸（窗口可能被 resize）
    SDL_GL_GetDrawableSize(m_window, &m_drawableW, &m_drawableH);

    // 重新布局（以 drawable 像素为单位）
    rbRelayout();

    // 不使用 SDL_RenderSetLogicalSize：避免将逻辑尺寸锁在 window 像素后被合成层二次拉伸。
    // 所有 UI 几何已转换为 drawable 像素，renderer 直接画在物理像素上。
    SDL_SetRenderDrawColor(m_renderer, kUIBg.r, kUIBg.g, kUIBg.b, 255);
    SDL_RenderClear(m_renderer);

    if (m_sliderMode && m_sliderView) {
        // Slider 模式：用整个内容区显示双视频比较
        SDL_Rect sliderRect = { 0, m_tbH, m_drawableW, m_drawableH - m_tbH };
        m_sliderView->rbSetRect(sliderRect);
        m_sliderView->rbRender(m_mouseX, m_mouseY);
    } else if (m_soloCell >= 0 && m_soloCell < static_cast<int>(m_cells.size())) {
        // Solo 模式只渲染焦点路
        m_cells[m_soloCell]->rbRender(m_mouseX, m_mouseY);
    } else {
        for (int i = 0; i < m_activeCellCount && i < static_cast<int>(m_cells.size()); ++i) {
            m_cells[i]->rbRender(m_mouseX, m_mouseY);
        }
    }

    // 渲染工具栏
    rbRenderToolbar();

    SDL_RenderPresent(m_renderer);
}

void RBPlayerUI::rbRenderToolbar() {
    int ww = m_drawableW, wh = m_drawableH;
    (void)wh;

    SDL_Rect toolbar = { 0, 0, ww, m_tbH };
    rbFillRect(toolbar, kUIToolbarBg);

    // 标题
    int titleH = static_cast<int>(std::round(20 * m_dpiScale));
    rbDrawText("PlayerX", m_tbPad, (m_tbH - titleH) / 2, kUIText, m_titleFont ? m_titleFont : m_font);

    // ── 右侧按钮区，从右向左排列 ──────────────────────────────
    int bx = ww - m_tbPad;

    // ＋ 按钮（最右）
    bx -= m_tbBtnW;
    SDL_Rect addBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    bool addDisabled = (m_activeCellCount >= 9) || m_sliderMode;
    bool addHover    = !addDisabled && rbPointInRect(m_mouseX, m_mouseY, addBtn);
    SDL_Color addCol = addDisabled ? SDL_Color{40,50,65,180} : (addHover ? kUIBtnHover : kUIBtn);
    rbFillRect(addBtn, addCol);
    rbDrawRect(addBtn, {80, 100, 130, 255});
    rbDrawTextCentered("+", addBtn, addDisabled ? SDL_Color{100,110,130,180} : kUIText, m_font);
    bx -= m_tbPad;

    // 序号按钮（从右向左：N, N-1, ..., 1），使用紧凑宽度
    for (int i = m_activeCellCount - 1; i >= 0; --i) {
        bx -= m_tbNumBtnW;
        SDL_Rect r = { bx, (m_tbH - m_tbBtnH) / 2, m_tbNumBtnW, m_tbBtnH };
        bool isSolo  = (m_soloCell == i);
        bool hover   = !m_sliderMode && rbPointInRect(m_mouseX, m_mouseY, r);
        SDL_Color c  = m_sliderMode ? SDL_Color{40,50,65,180}
                                    : (isSolo ? kUIBtnActive : (hover ? kUIBtnHover : kUIBtn));
        rbFillRect(r, c);
        rbDrawRect(r, {80, 100, 130, 255});
        rbDrawTextCentered(std::to_string(i + 1), r,
                           m_sliderMode ? SDL_Color{100,110,130,180} : kUIText, m_font);
        bx -= m_tbPad;
    }

    // Multi 按钮（序号左侧）：退出 Solo 回到多路视图
    bx -= m_tbBtnW;
    SDL_Rect multiBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    {
        bool inSolo = (m_soloCell >= 0);
        bool hover  = !m_sliderMode && rbPointInRect(m_mouseX, m_mouseY, multiBtn);
        SDL_Color c = m_sliderMode ? SDL_Color{40,50,65,180}
                                   : (inSolo ? kUIBtnActive : (hover ? kUIBtnHover : kUIBtn));
        rbFillRect(multiBtn, c);
        rbDrawRect(multiBtn, {80, 100, 130, 255});
        rbDrawTextCentered("Multi", multiBtn,
                           m_sliderMode ? SDL_Color{100,110,130,180} : kUIText, m_font);
    }
    bx -= m_tbPad;

    // Sync 按钮（Multi 左侧）：播放中显示 "Pause"，暂停时显示 "Play"
    bx -= m_tbBtnW;
    SDL_Rect syncBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    {
        bool anyPlaying = false;
        for (auto& p : m_players) { if (p->rbIsPlaying()) { anyPlaying = true; break; } }
        bool hover = rbPointInRect(m_mouseX, m_mouseY, syncBtn);
        rbFillRect(syncBtn, hover ? kUIBtnHover : kUIBtn);
        rbDrawRect(syncBtn, {80, 100, 130, 255});
        rbDrawTextCentered(anyPlaying ? "Pause" : "Play", syncBtn, kUIText, m_font);
    }
    bx -= m_tbPad;

    // Reset 按钮（Sync 左侧）：所有通路同步回到 0，便于从头播放
    bx -= m_tbBtnW;
    SDL_Rect resetBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    {
        bool hover = rbPointInRect(m_mouseX, m_mouseY, resetBtn);
        rbFillRect(resetBtn, hover ? kUIBtnHover : kUIBtn);
        rbDrawRect(resetBtn, {80, 100, 130, 255});
        rbDrawTextCentered("Reset", resetBtn, kUIText, m_font);
    }
    bx -= m_tbPad;

    // Slider 按钮（Reset 左侧）：仅当激活路数==2 时可点
    bx -= m_tbBtnW;
    SDL_Rect sliderBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    {
        bool enabled  = (m_activeCellCount == 2);
        bool hover    = enabled && rbPointInRect(m_mouseX, m_mouseY, sliderBtn);
        SDL_Color col = !enabled ? SDL_Color{40,50,65,180}
                                 : (m_sliderMode ? kUIBtnActive : (hover ? kUIBtnHover : kUIBtn));
        rbFillRect(sliderBtn, col);
        rbDrawRect(sliderBtn, {80, 100, 130, 255});
        rbDrawTextCentered("Slider", sliderBtn,
                           enabled ? kUIText : SDL_Color{100,110,130,180}, m_font);
    }
}

void RBPlayerUI::rbHandleEvent(const SDL_Event& e) {
    // 辅助：将 SDL 事件中的 window 像素坐标转换为 drawable 像素（与 UI 几何一致）
    auto toDrawableX = [&](int x) { return static_cast<int>(std::round(x * m_dpiScale)); };
    auto toDrawableY = [&](int y) { return static_cast<int>(std::round(y * m_dpiScale)); };

    switch (e.type) {
    case SDL_QUIT:
        m_running = false;
        break;

    case SDL_WINDOWEVENT:
        if (e.window.event == SDL_WINDOWEVENT_RESIZED ||
            e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
            // 同步 drawable 尺寸；同时重算 dpi factor（跨屏拖拽可能变化）
            int wW = 0, wH = 0;
            SDL_GetWindowSize(m_window, &wW, &wH);
            SDL_GL_GetDrawableSize(m_window, &m_drawableW, &m_drawableH);
            if (wW > 0) {
                float newScale = static_cast<float>(m_drawableW) / static_cast<float>(wW);
                if (std::abs(newScale - m_dpiScale) > 0.01f) {
                    // 跨屏变化：重新按新 dpi 加载字体与重算工具栏几何。
                    // 为避免复杂化，此处只更新几何，字体保持初始化时的 size。
                    m_dpiScale  = newScale;
                    m_tbH       = static_cast<int>(std::round(kToolbarHLogical  * m_dpiScale));
                    m_tbBtnW    = static_cast<int>(std::round(kTBBtnWLogical    * m_dpiScale));
                    m_tbBtnH    = static_cast<int>(std::round(kTBBtnHLogical    * m_dpiScale));
                    m_tbPad     = static_cast<int>(std::round(kTBPadLogical     * m_dpiScale));
                    m_tbNumBtnW = static_cast<int>(std::round(kTBNumBtnWLogical * m_dpiScale));
                }
            }
            rbRelayout();
        }
        break;

    case SDL_MOUSEMOTION:
        m_mouseX = toDrawableX(e.motion.x);
        m_mouseY = toDrawableY(e.motion.y);
        if (m_sliderMode) {
            if (m_sliderView) m_sliderView->rbOnMouseMove(m_mouseX, m_mouseY);
        } else {
            // 分发给 Cell
            for (auto& c : m_cells) c->rbOnMouseMove(m_mouseX, m_mouseY);
        }
        break;

    case SDL_MOUSEBUTTONDOWN:
        if (e.button.button == SDL_BUTTON_LEFT) {
            int x = toDrawableX(e.button.x), y = toDrawableY(e.button.y);

            // 工具栏点击
            if (y < m_tbH) {
                rbHandleToolbarClick(x, y);
                break;
            }

            // Slider 模式：直接转发给 slider view
            if (m_sliderMode) {
                if (m_sliderView) m_sliderView->rbOnMouseDown(x, y, e.button.clicks);
                break;
            }

            // 分发给 Cell
            int n = m_activeCellCount;
            for (int i = 0; i < n && i < static_cast<int>(m_cells.size()); ++i) {
                auto& r = m_cells[i]->rbRect();
                if (rbPointInRect(x, y, r)) {
                    // 选中该 Cell
                    for (auto& c : m_cells) c->rbSetSelected(false);
                    m_cells[i]->rbSetSelected(true);
                    // 透传 SDL 双击计数（常规播放器：双击视频画面切换播放/暂停）
                    m_cells[i]->rbOnMouseDown(x, y, e.button.clicks);
                    break;
                }
            }
        }
        break;

    case SDL_MOUSEBUTTONUP: {
        int x = toDrawableX(e.button.x), y = toDrawableY(e.button.y);
        if (m_sliderMode) {
            if (m_sliderView) m_sliderView->rbOnMouseUp(x, y);
        } else {
            for (auto& c : m_cells) c->rbOnMouseUp(x, y);
        }
        break;
    }

    default:        // 文件对话框结果事件（子线程通过 SDL_PushEvent 推回主线程）
        if (e.type == rbFileDialogEventType()) {
            auto* cb   = static_cast<RBFileCallback*>(e.user.data1);
            auto* path = static_cast<std::string*>(e.user.data2);
            if (cb) { (*cb)(*path); delete cb; }
            if (path) delete path;
        }
        break;

    case SDL_KEYDOWN:
        rbHandleKeyDown(e.key.keysym);
        break;
    }
}

void RBPlayerUI::rbHandleToolbarClick(int x, int y) {
    int ww = m_drawableW;

    // 与 rbRenderToolbar 保持完全相同的布局计算（均以 drawable 像素为单位）
    int bx = ww - m_tbPad;

    // ＋ 按钮
    bx -= m_tbBtnW;
    SDL_Rect addBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    if (rbPointInRect(x, y, addBtn)) {
        if (m_sliderMode) return;  // slider 模式下禁止改路数
        rbAddCell();
        return;
    }
    bx -= m_tbPad;

    // 序号按钮（从右向左：N, N-1, ..., 1），使用紧凑宽度
    for (int i = m_activeCellCount - 1; i >= 0; --i) {
        bx -= m_tbNumBtnW;
        SDL_Rect r = { bx, (m_tbH - m_tbBtnH) / 2, m_tbNumBtnW, m_tbBtnH };
        if (rbPointInRect(x, y, r)) {
            if (m_sliderMode) return;  // slider 模式下禁止改 Solo
            rbSetSoloCell(i);
            return;
        }
        bx -= m_tbPad;
    }

    // Multi 按钮：退出 Solo，回到多路视图
    bx -= m_tbBtnW;
    SDL_Rect multiBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    if (rbPointInRect(x, y, multiBtn)) {
        if (m_sliderMode) return;
        m_soloCell = -1;
        rbRelayout();
        return;
    }
    bx -= m_tbPad;

    // Sync 按钮
    bx -= m_tbBtnW;
    SDL_Rect syncBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    if (rbPointInRect(x, y, syncBtn)) {
        rbSyncToggle();
        return;
    }
    bx -= m_tbPad;

    // Reset 按钮（Sync 左侧）
    bx -= m_tbBtnW;
    SDL_Rect resetBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    if (rbPointInRect(x, y, resetBtn)) {
        rbSyncReset();
        return;
    }
    bx -= m_tbPad;

    // Slider 按钮（Reset 左侧）：仅当激活路数==2 时可点
    bx -= m_tbBtnW;
    SDL_Rect sliderBtn = { bx, (m_tbH - m_tbBtnH) / 2, m_tbBtnW, m_tbBtnH };
    if (rbPointInRect(x, y, sliderBtn)) {
        bool enabled = (m_activeCellCount == 2);
        if (!enabled && !m_sliderMode) return;  // 不满足条件且当前不在 slider，禁用
        m_sliderMode = !m_sliderMode;
        if (m_sliderMode) {
            // 取前两路 player
            RBVideoPlayer* p0 = (m_players.size() > 0) ? m_players[0].get() : nullptr;
            RBVideoPlayer* p1 = (m_players.size() > 1) ? m_players[1].get() : nullptr;
            const std::string path0 = p0 ? p0->rbFilePath() : std::string();
            const std::string path1 = p1 ? p1->rbFilePath() : std::string();

            // 仅当两路视频与"上次进入 Slider 时"不一致时才 reset，
            // 这样首次进入会同步到 0:00，再次来回切换则保持当前播放位置无缝衔接。
            const bool needReset =
                (path0 != m_sliderLastPath0) || (path1 != m_sliderLastPath1);
            if (needReset) {
                rbSyncReset();
                m_sliderLastPath0 = path0;
                m_sliderLastPath1 = path1;
            }

            if (m_sliderView) m_sliderView->rbSetPlayers(p0, p1);
        } else {
            if (m_sliderView) m_sliderView->rbSetPlayers(nullptr, nullptr);
            rbRelayout();
        }
        return;
    }
}

void RBPlayerUI::rbHandleKeyDown(const SDL_Keysym& key) {
    switch (key.sym) {
    case SDLK_ESCAPE:
        m_running = false;
        break;
    case SDLK_SPACE:
        rbSyncToggle();
        break;
    case SDLK_LEFT:
        // 同步后退 5 秒
        for (auto& p : m_players) {
            if (p->rbState() != RBPlayerState::Idle)
                p->rbSeekTo(std::max(0.0, p->rbCurrentTime() - 5.0));
        }
        break;
    case SDLK_RIGHT:
        // 同步前进 5 秒
        for (auto& p : m_players) {
            if (p->rbState() != RBPlayerState::Idle)
                p->rbSeekTo(std::min(p->rbDuration(), p->rbCurrentTime() + 5.0));
        }
        break;
    // R 键：同步重置所有通路到头（便于从头播放）
    case SDLK_r:
        rbSyncReset();
        break;
    // 数字键：切换 solo 模式（1~9 对应各路）
    case SDLK_1: rbSetSoloCell(0); break;
    case SDLK_2: rbSetSoloCell(1); break;
    case SDLK_3: rbSetSoloCell(2); break;
    case SDLK_4: rbSetSoloCell(3); break;
    case SDLK_5: rbSetSoloCell(4); break;
    case SDLK_6: rbSetSoloCell(5); break;
    case SDLK_7: rbSetSoloCell(6); break;
    case SDLK_8: rbSetSoloCell(7); break;
    case SDLK_9: rbSetSoloCell(8); break;
    }
}

// ─── 工具 ─────────────────────────────────────────────────────────────────────
void RBPlayerUI::rbFillRect(const SDL_Rect& r, SDL_Color c) {
    SDL_SetRenderDrawColor(m_renderer, c.r, c.g, c.b, c.a);
    SDL_SetRenderDrawBlendMode(m_renderer, SDL_BLENDMODE_BLEND);
    SDL_RenderFillRect(m_renderer, &r);
}

void RBPlayerUI::rbDrawRect(const SDL_Rect& r, SDL_Color c) {
    SDL_SetRenderDrawColor(m_renderer, c.r, c.g, c.b, c.a);
    SDL_RenderDrawRect(m_renderer, &r);
}

void RBPlayerUI::rbDrawText(const std::string& text, int x, int y, SDL_Color color, TTF_Font* f) {
    if (!f || text.empty()) return;
    SDL_Surface* surf = TTF_RenderUTF8_Blended(f, text.c_str(), color);
    if (!surf) return;
    SDL_Texture* tex = SDL_CreateTextureFromSurface(m_renderer, surf);
    if (tex) {
        SDL_Rect dst = { x, y, surf->w, surf->h };
        SDL_RenderCopy(m_renderer, tex, nullptr, &dst);
        SDL_DestroyTexture(tex);
    }
    SDL_FreeSurface(surf);
}

void RBPlayerUI::rbDrawTextCentered(const std::string& text, const SDL_Rect& area, SDL_Color color, TTF_Font* f) {
    if (!f || text.empty()) return;
    int w = 0, h = 0;
    TTF_SizeUTF8(f, text.c_str(), &w, &h);
    rbDrawText(text, area.x + (area.w - w) / 2, area.y + (area.h - h) / 2, color, f);
}

bool RBPlayerUI::rbPointInRect(int x, int y, const SDL_Rect& r) const {
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

} // namespace rb
