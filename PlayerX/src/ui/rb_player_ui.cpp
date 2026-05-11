#include "rb_player_ui.h"
#include "rb_video_cell.h"
#include "../player/rb_video_player.h"
#include "../utils/rb_utils.h"
#include <iostream>
#include <algorithm>

namespace rb {

// ─── 颜色 ─────────────────────────────────────────────────────────────────────
static constexpr SDL_Color kUIBg        = {22,  26,  32,  255};
static constexpr SDL_Color kUIToolbarBg = {30,  35,  44,  255};
static constexpr SDL_Color kUIText      = {220, 222, 228, 255};
static constexpr SDL_Color kUIBtn       = {50,  110, 190, 255};
static constexpr SDL_Color kUIBtnHover  = {75,  145, 235, 255};
static constexpr SDL_Color kUIBtnActive = {40,  90,  160, 255};

// ─── 工具栏按钮布局 ───────────────────────────────────────────────────────────
static constexpr int kTBBtnW = 60;
static constexpr int kTBBtnH = 28;
static constexpr int kTBPad  = 8;

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

    m_font      = rbLoadFont(16);
    m_titleFont = rbLoadFont(22);
    m_smallFont = rbLoadFont(13);
    if (!m_font) {
        std::cerr << "[RBPlayerUI] font load failed" << std::endl;
        return false;
    }

    // 默认单路布局，创建 1 个 Cell
    rbSetLayout(RBLayoutMode::Single);
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

// ─── 布局 ─────────────────────────────────────────────────────────────────────
void RBPlayerUI::rbSetLayout(RBLayoutMode mode) {
    int n = static_cast<int>(mode);
    m_layout = mode;

    // 扩展 Cell 和 Player 数量（只增不减，保留已有播放器）
    while (static_cast<int>(m_players.size()) < n) {
        auto player = std::make_unique<RBVideoPlayer>();
        auto cell   = std::make_unique<RBVideoCell>();
        cell->rbInit(m_renderer, m_font, m_smallFont);
        cell->rbSetPlayer(player.get());

        int idx = static_cast<int>(m_cells.size());
        cell->rbSetTitle("Ch." + std::to_string(idx + 1));

        // 文件选择回调：通过 SDL 事件推回主线程，记录 cellIndex
        cell->rbSetOpenFileCallback([this, idx](RBVideoCell*) {
            rbOpenFileDialog([this, idx](const std::string& path) {
                // 此回调已在主线程（SDL 事件处理中）执行
                if (!path.empty()) rbOpenFileForCell(idx, path);
            });
        });

        m_players.push_back(std::move(player));
        m_cells.push_back(std::move(cell));
    }

    rbRelayout();
}

void RBPlayerUI::rbRelayout() {
    int ww, wh;
    SDL_GetWindowSize(m_window, &ww, &wh);

    int contentY = kToolbarH;
    int contentH = wh - kToolbarH;
    int contentW = ww;
    static constexpr int kGap = 4;

    auto setCell = [&](int i, int x, int y, int w, int h) {
        if (i < static_cast<int>(m_cells.size())) {
            m_cells[i]->rbSetRect({ x, y, w, h });
        }
    };

    switch (m_layout) {
    case RBLayoutMode::Single:
        setCell(0, 0, contentY, contentW, contentH);
        break;

    case RBLayoutMode::Dual: {
        int cw = (contentW - kGap) / 2;
        setCell(0, 0,        contentY, cw, contentH);
        setCell(1, cw + kGap, contentY, contentW - cw - kGap, contentH);
        break;
    }

    case RBLayoutMode::Triple: {
        // 上方两个，下方一个居中
        int topH = (contentH - kGap) / 2;
        int botH = contentH - topH - kGap;
        int cw   = (contentW - kGap) / 2;
        setCell(0, 0,         contentY,           cw, topH);
        setCell(1, cw + kGap, contentY,           contentW - cw - kGap, topH);
        int botW = contentW / 2;
        setCell(2, (contentW - botW) / 2, contentY + topH + kGap, botW, botH);
        break;
    }

    case RBLayoutMode::Quad: {
        int cw = (contentW - kGap) / 2;
        int ch = (contentH - kGap) / 2;
        setCell(0, 0,         contentY,           cw, ch);
        setCell(1, cw + kGap, contentY,           contentW - cw - kGap, ch);
        setCell(2, 0,         contentY + ch + kGap, cw, contentH - ch - kGap);
        setCell(3, cw + kGap, contentY + ch + kGap, contentW - cw - kGap, contentH - ch - kGap);
        break;
    }
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

// ─── 渲染 ─────────────────────────────────────────────────────────────────────
void RBPlayerUI::rbRenderFrame() {
    // 重新布局（窗口可能被 resize）
    rbRelayout();

    // 设置逻辑渲染尺寸与窗口逻辑尺寸一致（修复 HiDPI 坐标偏移）
    int ww, wh;
    SDL_GetWindowSize(m_window, &ww, &wh);
    SDL_RenderSetLogicalSize(m_renderer, ww, wh);

    SDL_SetRenderDrawColor(m_renderer, kUIBg.r, kUIBg.g, kUIBg.b, 255);
    SDL_RenderClear(m_renderer);

    // 渲染所有 Cell（只渲染当前 layout 数量的 Cell）
    int cellCount = static_cast<int>(m_layout);
    for (int i = 0; i < cellCount && i < static_cast<int>(m_cells.size()); ++i) {
        m_cells[i]->rbRender(m_mouseX, m_mouseY);
    }

    // 渲染工具栏
    rbRenderToolbar();

    SDL_RenderPresent(m_renderer);
}

void RBPlayerUI::rbRenderToolbar() {
    int ww, wh;
    SDL_GetWindowSize(m_window, &ww, &wh);
    (void)wh;

    SDL_Rect toolbar = { 0, 0, ww, kToolbarH };
    rbFillRect(toolbar, kUIToolbarBg);

    // 标题
    rbDrawText("PlayerX", kTBPad, (kToolbarH - 20) / 2, kUIText, m_titleFont ? m_titleFont : m_font);

    // 布局切换按钮（右侧）
    struct LayoutBtn { const char* label; RBLayoutMode mode; };
    static const LayoutBtn kBtns[] = {
        {"1",  RBLayoutMode::Single},
        {"2",  RBLayoutMode::Dual},
        {"3",  RBLayoutMode::Triple},
        {"4",  RBLayoutMode::Quad},
    };

    int bx = ww - (kTBBtnW + kTBPad) * 4 - kTBPad;
    for (const auto& b : kBtns) {
        SDL_Rect r = { bx, (kToolbarH - kTBBtnH) / 2, kTBBtnW, kTBBtnH };
        bool active = (m_layout == b.mode);
        bool hover  = rbPointInRect(m_mouseX, m_mouseY, r);
        SDL_Color c = active ? kUIBtnActive : (hover ? kUIBtnHover : kUIBtn);
        rbFillRect(r, c);
        rbDrawRect(r, {80, 100, 130, 255});
        rbDrawTextCentered(b.label, r, kUIText, m_font);
        bx += kTBBtnW + kTBPad;
    }

    // 同步播放按钮
    int syncX = ww - (kTBBtnW + kTBPad) * 4 - kTBPad - kTBBtnW * 2 - kTBPad * 2;
    SDL_Rect syncBtn = { syncX, (kToolbarH - kTBBtnH) / 2, kTBBtnW * 2, kTBBtnH };
    bool syncHover = rbPointInRect(m_mouseX, m_mouseY, syncBtn);
    rbFillRect(syncBtn, syncHover ? kUIBtnHover : kUIBtn);
    rbDrawRect(syncBtn, {80, 100, 130, 255});
    rbDrawTextCentered("Sync All", syncBtn, kUIText, m_font);
}

// ─── 事件处理 ─────────────────────────────────────────────────────────────────
void RBPlayerUI::rbHandleEvent(const SDL_Event& e) {
    switch (e.type) {
    case SDL_QUIT:
        m_running = false;
        break;

    case SDL_WINDOWEVENT:
        if (e.window.event == SDL_WINDOWEVENT_RESIZED ||
            e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
            rbRelayout();
        }
        break;

    case SDL_MOUSEMOTION:
        m_mouseX = e.motion.x;
        m_mouseY = e.motion.y;
        // 分发给 Cell
        for (auto& c : m_cells) c->rbOnMouseMove(m_mouseX, m_mouseY);
        break;

    case SDL_MOUSEBUTTONDOWN:
        if (e.button.button == SDL_BUTTON_LEFT) {
            int x = e.button.x, y = e.button.y;

            // 工具栏点击
            if (y < kToolbarH) {
                rbHandleToolbarClick(x, y);
                break;
            }

            // 分发给 Cell
            int n = static_cast<int>(m_layout);
            for (int i = 0; i < n && i < static_cast<int>(m_cells.size()); ++i) {
                auto& r = m_cells[i]->rbRect();
                if (rbPointInRect(x, y, r)) {
                    // 选中该 Cell
                    for (auto& c : m_cells) c->rbSetSelected(false);
                    m_cells[i]->rbSetSelected(true);
                    m_cells[i]->rbOnMouseDown(x, y);
                    break;
                }
            }
        }
        break;

    case SDL_MOUSEBUTTONUP:
        for (auto& c : m_cells) c->rbOnMouseUp(e.button.x, e.button.y);
        break;

    default:
        // 文件对话框结果事件（子线程通过 SDL_PushEvent 推回主线程）
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
    int ww, wh;
    SDL_GetWindowSize(m_window, &ww, &wh);
    (void)wh;

    // 布局按钮
    struct LayoutBtn { RBLayoutMode mode; };
    static const LayoutBtn kBtns[] = {
        {RBLayoutMode::Single},
        {RBLayoutMode::Dual},
        {RBLayoutMode::Triple},
        {RBLayoutMode::Quad},
    };
    int bx = ww - (kTBBtnW + kTBPad) * 4 - kTBPad;
    for (const auto& b : kBtns) {
        SDL_Rect r = { bx, (kToolbarH - kTBBtnH) / 2, kTBBtnW, kTBBtnH };
        if (rbPointInRect(x, y, r)) {
            rbSetLayout(b.mode);
            return;
        }
        bx += kTBBtnW + kTBPad;
    }

    // Sync 按钮
    int syncX = ww - (kTBBtnW + kTBPad) * 4 - kTBPad - kTBBtnW * 2 - kTBPad * 2;
    SDL_Rect syncBtn = { syncX, (kToolbarH - kTBBtnH) / 2, kTBBtnW * 2, kTBBtnH };
    if (rbPointInRect(x, y, syncBtn)) {
        rbSyncToggle();
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
    case SDLK_1: rbSetLayout(RBLayoutMode::Single); break;
    case SDLK_2: rbSetLayout(RBLayoutMode::Dual);   break;
    case SDLK_3: rbSetLayout(RBLayoutMode::Triple); break;
    case SDLK_4: rbSetLayout(RBLayoutMode::Quad);   break;
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
