#include "rb_player_ui.h"
#include "rb_video_cell.h"
#include "rb_slider_view.h"
#include "../player/rb_video_player.h"
#include "../utils/rb_utils.h"
#include <iostream>
#include <algorithm>
#include <cmath>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#endif

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
    // ── HighDPI：在 SDL_Init 之前设置 hint，必须保证生效 ─────────────────────────
    // macOS 由系统自动给窗口提供 backing scale；Windows 必须显式声明 DPI awareness，
    // 否则 SDL_GetWindowSize == SDL_GL_GetDrawableSize（dpiScale=1），字体光栅化
    // 仍按 16/22/13pt，再被 DWM 的 DPI virtualization 二次拉伸 → 文字模糊。
    //
    // 主线声明：通过 PE manifest 在加载阶段固化 PerMonitorV2（见 res/win/PlayerX.rc），
    // 这是最可靠的方式，不存在运行期 API 时序问题。
    //
    // 这里仅做兜底 hint：
    //   SDL_HINT_WINDOWS_DPI_AWARENESS = "permonitorv2"
    //   告诉 SDL 在 Windows 上同步使用 PerMonitorV2（SDL2 ≥ 2.24 支持）。
    //
    // 注意：**不**设置 SDL_HINT_WINDOWS_DPI_SCALING：当 manifest 已声明 DPI aware
    // 时，开启 DPI_SCALING 会让 SDL 在 ALLOW_HIGHDPI 之上再叠一层逻辑→物理映射，
    // 引发"双重缩放"导致 RenderCopy 的目标 rect 被乘到 dpiScale²，最终被 GPU 缩
    // 回窗口区域 → 视频/字体出现 bilinear 二次重采样毛边。
    // 与 macOS 完全一致的路径：manifest + SDL_WINDOW_ALLOW_HIGHDPI，dpiScale
    // 由 SDL_GL_GetDrawableSize / SDL_GetWindowSize 自然计算得到。
#if defined(SDL_HINT_WINDOWS_DPI_AWARENESS)
    SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2");
#endif

#if defined(_WIN32)
    // 兜底：直接调 Win32 API 声明 Per-Monitor V2，覆盖老版本 SDL 与极个别
    // hint 不生效的环境。GetProcAddress 动态解析，避免对老 Windows SDK 的链接依赖。
    {
        HMODULE user32 = LoadLibraryA("user32.dll");
        if (user32) {
            typedef BOOL (WINAPI *PFN_SetProcessDpiAwarenessContext)(HANDLE);
            // 经 void* 中转，规避 -Wcast-function-type
            void* sym = reinterpret_cast<void*>(GetProcAddress(user32, "SetProcessDpiAwarenessContext"));
            auto pSetCtx = reinterpret_cast<PFN_SetProcessDpiAwarenessContext>(sym);
            if (pSetCtx) {
                // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
                pSetCtx(reinterpret_cast<HANDLE>(static_cast<intptr_t>(-4)));
            } else {
                typedef BOOL (WINAPI *PFN_SetProcessDPIAware)(void);
                void* sym2 = reinterpret_cast<void*>(GetProcAddress(user32, "SetProcessDPIAware"));
                auto pSetAware = reinterpret_cast<PFN_SetProcessDPIAware>(sym2);
                if (pSetAware) pSetAware();
            }
            FreeLibrary(user32);
        }
    }
#endif

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

    // ── 按主显示器工作区域计算"舒适"默认窗口尺寸（仅在调用方传入"经典默认 1280x720"
    //    时启用自适应；外部如果显式给了别的尺寸则尊重外部值，避免破坏脚本/测试调用）。
    //
    // 策略：取主屏 SDL_GetDisplayUsableBounds（已扣除任务栏 / Dock / 菜单栏）的 ~80%，
    // 并保持 16:9，限定在 [1280x720, 2560x1440] 之间。
    // 注意：SDL2 的 SDL_GetDisplayUsableBounds 在 Windows 上返回**逻辑像素**（DPI 缩放后），
    // 与 SDL_CreateWindow 入参一致，因此无需做 dpiScale 换算；
    // macOS 上同样返回 points，与 CreateWindow 入参一致。
    int initW = w, initH = h;
    if (w == 1280 && h == 720) {
        SDL_Rect usable;
        if (SDL_GetDisplayUsableBounds(0, &usable) == 0 && usable.w > 0 && usable.h > 0) {
            // 80% 工作区，保持 16:9（以宽为基准回算高，再裁回工作区）
            int targetW = static_cast<int>(usable.w * 0.80f);
            int targetH = static_cast<int>(usable.h * 0.80f);
            // 16:9 锁定：以较小一边的等比为准
            int by_w_h = targetW * 9 / 16;
            int by_h_w = targetH * 16 / 9;
            if (by_w_h <= targetH) {
                initW = targetW;
                initH = by_w_h;
            } else {
                initW = by_h_w;
                initH = targetH;
            }
            // 上下界
            if (initW < 1280) { initW = 1280; initH = 720; }
            if (initW > 2560) { initW = 2560; initH = 1440; }
            // 不超出工作区（窄屏兜底）
            if (initW > usable.w) initW = usable.w;
            if (initH > usable.h) initH = usable.h;
        }
    }

    m_window = SDL_CreateWindow(title.c_str(),
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        initW, initH, SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    if (!m_window) {
        std::cerr << "[RBPlayerUI] 创建窗口失败: " << SDL_GetError() << std::endl;
        return false;
    }

    // 抑制 macOS 上未被消费的按键触发的系统提示音（NSBeep）。
    // 在窗口创建之后调用，确保 keyWindow 存在；Windows 下为 no-op。
    rbSilenceSystemBeep();

    // ── Windows IME 拦截字母键修复 ───────────────────────────────────
    // SDL2 在 Windows 上创建窗口后会**默认启用文本输入**（SDL_StartTextInput），
    // 当系统输入法处于"中文/合成"状态时，字母键（如 R / Y / P 等）会被 IME
    // 当成合成首字符吞掉，根本不产生 SDL_KEYDOWN 事件，仅以 SDL_TEXTINPUT
    // 形式抵达。这就是 Windows 上 R 键无法触发 Reset、而方向键 / 空格 / Esc
    // 正常的根因（非字符键不走 IME）。
    // macOS 上不会自动开启文本输入，因此这里调用也无害。
    // 本应用没有任何文本输入需求，关闭后所有按键都会以 KEYDOWN 直送事件循环。
#if defined(SDL_HINT_IME_SHOW_UI)
    SDL_SetHint(SDL_HINT_IME_SHOW_UI, "0");
#endif
#if defined(SDL_HINT_IME_INTERNAL_EDITING)
    SDL_SetHint(SDL_HINT_IME_INTERNAL_EDITING, "1");
#endif
    SDL_StopTextInput();

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

// ─── 内部：创建一个新 Cell+Player 并追加 ────────────────────────────
static void rbMakeCellPlayer(RBPlayerUI* /*ui*/, SDL_Renderer* renderer,
                              TTF_Font* font, TTF_Font* smallFont,
                              std::vector<std::unique_ptr<RBVideoCell>>& cells,
                              std::vector<std::unique_ptr<RBVideoPlayer>>& players) {
    auto player = std::make_unique<RBVideoPlayer>();
    auto cell   = std::make_unique<RBVideoCell>();
    cell->rbInit(renderer, font, smallFont);
    cell->rbSetPlayer(player.get());
    // 标题与回调统一由 rbRebindCellCallbacks() 按当前索引设置，
    // 避免闭包捕获 idx 后、删除某路导致后续索引错位。
    players.push_back(std::move(player));
    cells.push_back(std::move(cell));
}

// 重新绑定所有 cell 的标题 / open 回调 / close 回调，及 closable 状态。
// 由于闭包按值捕获了 idx，在 rbAddCell / rbRemoveCell 后必须调用本函数重建，
// 以保证各 cell 的回调使用的是它在 m_cells 中的最新位置。
static void rbRebindCellCallbacks(RBPlayerUI* ui,
                                   std::vector<std::unique_ptr<RBVideoCell>>& cells,
                                   int activeCount) {
    int total = static_cast<int>(cells.size());
    for (int i = 0; i < total; ++i) {
        auto* cell = cells[i].get();
        if (!cell) continue;
        cell->rbSetTitle("Ch." + std::to_string(i + 1));
        cell->rbSetOpenFileCallback([ui, i](RBVideoCell*) {
            // 弹框前暂停所有正在播放的路，避免对话框期间墙钟流逝
            // 导致关闭时画面瞬间快进。
            ui->rbBeginFileDialogGuard();
            rbOpenFileDialog([ui, i](const std::string& path) {
                if (!path.empty()) ui->rbOpenFileForCell(i, path);
                // 无论是否选中文件，都要恢复其它路的播放状态。
                ui->rbEndFileDialogGuard();
            });
        });
        cell->rbSetCloseCallback([ui, i](RBVideoCell*) {
            ui->rbRemoveCell(i);
        });
        // 只有处于激活范围内的 cell 才会被渲染并需要 × 按钮
        cell->rbSetClosable(i < activeCount);
    }
    (void)activeCount;
}
// ─── 布局 ──────────────────────────────────────────────────────────────
void RBPlayerUI::rbSetLayout(RBLayoutMode mode) {
    int n = static_cast<int>(mode);
    m_layout = mode;
    m_activeCellCount = n;
    m_soloCell = -1;  // 切换布局时退出 solo 模式

    // 扩展 Cell 和 Player 数量（只增不减，保留已有播放器）
    while (static_cast<int>(m_players.size()) < n) {
        rbMakeCellPlayer(this, m_renderer, m_font, m_smallFont, m_cells, m_players);
    }

    rbRebindCellCallbacks(this, m_cells, m_activeCellCount);
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
    rbRebindCellCallbacks(this, m_cells, m_activeCellCount);
    rbRelayout();
}

void RBPlayerUI::rbRemoveCell(int idx) {
    if (idx < 0 || idx >= m_activeCellCount) return;
    if (idx >= static_cast<int>(m_cells.size())) return;

    // 1) 如果处于 Slider 模式，先退出（删除后路数变化，两路绑定不再成立）
    if (m_sliderMode) {
        if (m_sliderView) m_sliderView->rbSetPlayers(nullptr, nullptr);
        m_sliderMode = false;
        m_sliderLastPath0.clear();
        m_sliderLastPath1.clear();
    }

    // 2) 关闭并销毁该 cell/player
    if (m_cells[idx]) {
        m_cells[idx]->rbSetPlayer(nullptr);
    }
    if (m_players[idx]) {
        m_players[idx]->rbClose();
    }
    m_cells.erase(m_cells.begin() + idx);
    m_players.erase(m_players.begin() + idx);

    // 3) 同步路数/布局枚举
    m_activeCellCount = std::max(0, m_activeCellCount - 1);
    if (m_activeCellCount >= 1) {
        m_layout = static_cast<RBLayoutMode>(m_activeCellCount);
    } else {
        m_layout = RBLayoutMode::Single;  // 枚举仅作叠加创建时参考，路数以 m_activeCellCount 为准
    }

    // 4) 退出 Solo（如果删的正是 Solo 路或后面的路）
    m_soloCell = -1;

    // 5) 重建所有剩余 cell 的标题/回调（闭包里的 idx 需以新位置为准）
    rbRebindCellCallbacks(this, m_cells, m_activeCellCount);

    rbRelayout();
}

void RBPlayerUI::rbSetSoloCell(int idx) {    if (idx < 0 || idx >= m_activeCellCount) return;
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
        // 关键：把所有非 solo cell 的 rect 清零，避免它们因为残留旧网格 rect
        // 在鼠标事件分发或后续渲染中被错误命中（例如导致点击全屏 solo 视图时，
        // 真正接收事件的是隐藏在屏幕背后的另一路 cell）。
        for (int i = 0; i < m_activeCellCount && i < static_cast<int>(m_cells.size()); ++i) {
            if (i == m_soloCell) continue;
            m_cells[i]->rbSetRect({0, 0, 0, 0});
        }
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

void RBPlayerUI::rbSyncSeekDelta(double deltaSec) {
    for (auto& p : m_players) {
        if (p->rbState() == RBPlayerState::Idle) continue;
        double t = p->rbCurrentTime() + deltaSec;
        t = std::max(0.0, std::min(t, p->rbDuration()));
        p->rbSeekTo(t);
    }
}

void RBPlayerUI::rbSyncStepFrame(int n) {
    // 所有有效路同步走 n 帧。每路自身的 fps 可能不同，rbStepFrame 内部按各自
    // 帧率推进，因此严格意义上不是"所有路落到同一个时间戳"，而是"每路推进 n 帧"。
    // 这与帧步进的语义完全一致（用户希望逐帧观察），跨路时间偏差最多一帧。
    for (auto& p : m_players) {
        if (p->rbState() == RBPlayerState::Idle) continue;
        p->rbStepFrame(n);
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

// ─── 文件对话框守卫 ────────────────────────────────────────────────
void RBPlayerUI::rbBeginFileDialogGuard() {
    // 允许嵌套（理论上不会，但防抱一）：只有第一层守卫才生效。
    if (m_dialogGuardDepth++ > 0) return;

    m_dialogPausedCells.clear();
    for (size_t i = 0; i < m_players.size(); ++i) {
        auto* p = m_players[i].get();
        if (!p) continue;
        if (p->rbIsPlaying()) {
            p->rbPause();
            m_dialogPausedCells.push_back(static_cast<int>(i));
        }
    }
}

void RBPlayerUI::rbEndFileDialogGuard() {
    if (m_dialogGuardDepth <= 0) return;          // 未配对调用，忽略
    if (--m_dialogGuardDepth > 0) return;         // 仍有更外层守卫，不恢复

    for (int idx : m_dialogPausedCells) {
        if (idx < 0 || idx >= static_cast<int>(m_players.size())) continue;
        auto* p = m_players[idx].get();
        if (!p) continue;
        // 如果该路仍处于暂停（没有被用户手动改动过状态）才恢复。
        // rbPlay 在处于 Paused 的路上会重置墙钟起点 = now，PTS 起点 = currentTime，
        // 不会产生跳变，后续帧从原位置无缝继续。
        if (p->rbIsPaused()) {
            p->rbPlay();
        }
    }
    m_dialogPausedCells.clear();
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
    } else if (m_activeCellCount == 0) {
        // 空状态：所有路都被关闭。提示用户用 ＋ 添加新通路
        SDL_Rect area = { 0, m_tbH, m_drawableW, m_drawableH - m_tbH };
        rbDrawTextCentered("No channels. Click  +  in the toolbar to add one.",
                           area, {150, 155, 165, 255}, m_font);
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
    bx -= m_tbPad;

    // ─── 全局跳转按钮 << < > >>（Slider 左侧）────────────────────────
    // 与 cell 内同名按钮等价，但同时作用于所有有效路（同步 5s / 同步单帧步进）。
    // Slider 模式下也可用：内部最终调用 rbSyncSeekDelta / rbSyncStepFrame，
    // 它们对每路 player 操作，slider view 自动反映两路当前帧。
    {
        bool anyActive = false;
        for (auto& p : m_players) {
            if (p && p->rbState() != RBPlayerState::Idle) { anyActive = true; break; }
        }
        // 单按钮宽度比常规按钮窄，整体占 4 * sw + 3 * pad/2 ≈ 一个常规按钮 + 一些空间
        int sw  = static_cast<int>(std::round(36 * m_dpiScale));
        int sgp = static_cast<int>(std::round(2  * m_dpiScale));
        static const char* kSeekLabel[4] = {
            "\xe2\x80\xb9\xe2\x80\xb9", "\xe2\x80\xb9",
            "\xe2\x80\xba",             "\xe2\x80\xba\xe2\x80\xba",
        };
        // 从右向左排：>>, >, <, <<（绘制时按 i=3..0 顺序）
        for (int i = 3; i >= 0; --i) {
            bx -= sw;
            SDL_Rect r = { bx, (m_tbH - m_tbBtnH) / 2, sw, m_tbBtnH };
            bool hover = anyActive && rbPointInRect(m_mouseX, m_mouseY, r);
            SDL_Color col = !anyActive ? SDL_Color{40,50,65,180}
                                       : (hover ? kUIBtnHover : kUIBtn);
            rbFillRect(r, col);
            rbDrawRect(r, {80, 100, 130, 255});
            rbDrawTextCentered(kSeekLabel[i], r,
                               anyActive ? kUIText : SDL_Color{100,110,130,180},
                               m_font);
            if (i > 0) bx -= sgp;
        }
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
        } else if (m_soloCell >= 0 && m_soloCell < m_activeCellCount &&
                   m_soloCell < static_cast<int>(m_cells.size())) {
            // Solo 模式：仅当前 cell 在屏，其他 cell rect 已清零、不应再处理 move
            m_cells[m_soloCell]->rbOnMouseMove(m_mouseX, m_mouseY);
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

            // Solo 模式：屏幕上只有 m_soloCell 一路，其他 cell rect 已清零，
            // 直接把事件路由给它，避免遍历命中带来的潜在歧义。
            if (m_soloCell >= 0 && m_soloCell < m_activeCellCount &&
                m_soloCell < static_cast<int>(m_cells.size())) {
                for (auto& c : m_cells) c->rbSetSelected(false);
                m_cells[m_soloCell]->rbSetSelected(true);
                m_cells[m_soloCell]->rbOnMouseDown(x, y, e.button.clicks);
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
        } else if (m_soloCell >= 0 && m_soloCell < m_activeCellCount &&
                   m_soloCell < static_cast<int>(m_cells.size())) {
            m_cells[m_soloCell]->rbOnMouseUp(x, y);
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
        rbToggleSliderMode();
        return;
    }
    bx -= m_tbPad;

    // 全局跳转按钮 << < > >>（Slider 左侧）：保持与 rbRenderToolbar 一致的几何
    {
        bool anyActive = false;
        for (auto& p : m_players) {
            if (p && p->rbState() != RBPlayerState::Idle) { anyActive = true; break; }
        }
        int sw  = static_cast<int>(std::round(36 * m_dpiScale));
        int sgp = static_cast<int>(std::round(2  * m_dpiScale));
        for (int i = 3; i >= 0; --i) {
            bx -= sw;
            SDL_Rect r = { bx, (m_tbH - m_tbBtnH) / 2, sw, m_tbBtnH };
            if (rbPointInRect(x, y, r)) {
                if (!anyActive) return;
                if      (i == 0) rbSyncSeekDelta(-5.0);
                else if (i == 3) rbSyncSeekDelta(+5.0);
                else if (i == 1) rbSyncStepFrame(-1);
                else             rbSyncStepFrame(+1);
                return;
            }
            if (i > 0) bx -= sgp;
        }
    }
}

// 抽出 Slider 模式切换逻辑，使工具栏点击与键盘 S 快捷键共用同一实现，
// 避免两个入口的行为发散（reset 策略、player 绑定/解绑等）。
void RBPlayerUI::rbToggleSliderMode() {
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
}

// F 键：在窗口模式与无边框全屏之间切换。
// 使用 SDL_WINDOW_FULLSCREEN_DESKTOP（不改分辨率/不抢显示模式），
// 切换后 SDL 会发出 SIZE_CHANGED 事件，命中已有的 rbRelayout + dpi 重算路径，
// 所以工具栏几何、cell rect、字体光栅化保持锐利，不破坏其他功能。
void RBPlayerUI::rbToggleFullscreen() {
    if (!m_window) return;
    Uint32 flags = SDL_GetWindowFlags(m_window);
    bool isFs = (flags & SDL_WINDOW_FULLSCREEN_DESKTOP) != 0;
    SDL_SetWindowFullscreen(m_window, isFs ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
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
    // F 键：切换全屏（无边框桌面全屏，避免分辨率切换闪屏）
    case SDLK_f:
        rbToggleFullscreen();
        break;
    // S 键：切换 Slider 模式（与工具栏 Slider 按钮等价，受同样的
    // "激活路数==2"约束保护）
    case SDLK_s:
        rbToggleSliderMode();
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
