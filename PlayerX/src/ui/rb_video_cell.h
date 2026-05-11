#pragma once
/**
 * rb_video_cell.h — 单路视频渲染单元
 * 负责将 RBVideoPlayer 的帧渲染到指定的 SDL_Rect 区域内，
 * 并绘制该路的控制条（进度条、播放/暂停、时间标签）。
 *
 * 设计为可复用：RBPlayerUI 持有 N 个 RBVideoCell 实例，
 * 每个 Cell 独立管理一路视频的显示和控制。
 */

#include <string>
#include <memory>
#include <functional>

#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

namespace rb {

class RBVideoPlayer;

// 控制条高度（像素）
constexpr int kRBControlBarH = 56;

class RBVideoCell {
public:
    RBVideoCell();
    ~RBVideoCell();

    // 初始化（renderer 和字体由 RBPlayerUI 统一管理并传入）
    void rbInit(SDL_Renderer* renderer, TTF_Font* font, TTF_Font* smallFont);

    // HighDPI 缩放因子：drawable / window，由 RBPlayerUI 在初始化与 dpi 变化时同步过来。
    // Cell 内部所有像素尺寸常量（控制条、按钮、进度条、内边距等）都会按此因子放大，
    // 保证以 drawable（物理像素）坐标系工作时视觉尺寸正确，并让字体/控件 1:1 锐利渲染。
    void rbSetDpiScale(float s) { m_dpiScale = (s > 0.0f) ? s : 1.0f; }
    float rbDpiScale() const { return m_dpiScale; }

    // 设置播放器（可为 nullptr 表示空 Cell）
    void rbSetPlayer(RBVideoPlayer* player);
    RBVideoPlayer* rbPlayer() const { return m_player; }

    // 设置布局区域（每帧渲染前由 RBPlayerUI 调用）
    void rbSetRect(const SDL_Rect& rect);
    const SDL_Rect& rbRect() const { return m_rect; }

    // 渲染（每帧调用）
    void rbRender(int mouseX, int mouseY);

    // 鼠标事件（由 RBPlayerUI 分发）
    // clicks: SDL 提供的连击计数，1=单击，2=双击（双击视频画面切换播放/暂停）
    void rbOnMouseDown(int x, int y, int clicks = 1);
    void rbOnMouseUp(int x, int y);
    void rbOnMouseMove(int x, int y);

    // 标题（显示在 Cell 左上角）
    void rbSetTitle(const std::string& title) { m_title = title; }

    // 是否被选中（高亮边框）
    void rbSetSelected(bool sel) { m_selected = sel; }
    bool rbIsSelected() const { return m_selected; }

    // 打开文件对话框回调（由外部设置，Cell 内部触发）
    using OpenFileCallback = std::function<void(RBVideoCell*)>;
    void rbSetOpenFileCallback(OpenFileCallback cb) { m_openFileCb = std::move(cb); }

    // 关闭（删除该 Cell）回调：右上角 × 按钮触发，由 RBPlayerUI 设置
    using CloseCallback = std::function<void(RBVideoCell*)>;
    void rbSetCloseCallback(CloseCallback cb) { m_closeCb = std::move(cb); }

    // 是否显示右上角的 × 关闭按钮（最后一路也允许关闭，由 UI 层控制）
    void rbSetClosable(bool b) { m_closable = b; }
    bool rbIsClosable() const { return m_closable; }

private:
    // 子区域计算
    SDL_Rect rbVideoArea()   const; // 视频显示区（去掉控制条）
    SDL_Rect rbControlArea() const; // 控制条区域
    SDL_Rect rbCloseBtnRect() const; // 右上角 × 关闭按钮

    // 渲染子函数
    void rbRenderVideo();
    void rbRenderPlaceholder();
    void rbRenderControlBar(int mouseX, int mouseY);
    void rbRenderProgressBar(const SDL_Rect& barRect, int mouseX, int mouseY);

    // 控制条按钮区域
    SDL_Rect rbPlayBtnRect()   const;
    SDL_Rect rbOpenBtnRect()   const;
    // 4 个跳转按钮：<<（5s 后退）、<（前一帧）、>（下一帧）、>>（5s 前进）
    // 仅作用于本 cell 的 player，不影响其他路。位于 Open 按钮右侧。
    SDL_Rect rbSeekBtnRect(int idx) const;  // idx: 0=<<, 1=<, 2=>, 3=>>
    SDL_Rect rbProgressRect()  const;

    // 工具
    void rbDrawText(const std::string& text, int x, int y, SDL_Color color, TTF_Font* f);
    void rbDrawTextCentered(const std::string& text, const SDL_Rect& area, SDL_Color color, TTF_Font* f);
    void rbFillRect(const SDL_Rect& r, SDL_Color color);
    void rbDrawRect(const SDL_Rect& r, SDL_Color color);

    SDL_Renderer*       m_renderer{nullptr};
    TTF_Font*           m_font{nullptr};
    TTF_Font*           m_smallFont{nullptr};
    // 两套视频纹理：linear 用于缩小（消除 nearest 网格条纹伪影），
    // nearest 用于放大/1:1 渲染（保持像素锐利）。两者尺寸/格式同步。
    SDL_Texture*        m_videoTexLinear{nullptr};
    SDL_Texture*        m_videoTexNearest{nullptr};
    int                 m_texW{0}, m_texH{0};

    // ── 缩小路径（高质量）：libswscale BICUBIC 离屏缩放 → 1:1 上屏 ──
    // 缩小场景 SDL linear 仍会产生轻微"网格/摩尔纹"伪影；改用 BICUBIC（4×4 采样、无负瓣，
    // mpv/VLC 默认下采样算法）将 YUV420P 帧先在 CPU 上缩到 dst 尺寸，
    // 再上传到目标尺寸 IYUV 纹理 1:1 渲染，从根源上消除条纹。
    // 与 video-compare 中 LanczosScaler / render_lanczos 思路一致。
    void*               m_swsDown{nullptr};   // SwsContext*（前向声明避免暴露 ffmpeg 头）
    int                 m_swsSrcW{0}, m_swsSrcH{0};
    int                 m_swsDstW{0}, m_swsDstH{0};
    int                 m_swsSrcFmt{-1};
    SDL_Texture*        m_videoTexDown{nullptr};   // 目标尺寸 IYUV 纹理（nearest 1:1 渲染）
    int                 m_texDownW{0}, m_texDownH{0};

    RBVideoPlayer*      m_player{nullptr};
    SDL_Rect            m_rect{0, 0, 0, 0};
    std::string         m_title;
    bool                m_selected{false};

    // HighDPI 缩放因子（drawable / window）。详见 rbSetDpiScale。
    float               m_dpiScale{1.0f};

    // 进度条拖拽状态
    bool                m_draggingProgress{false};

    // 是否显示并响应右上角 × 关闭按钮
    bool                m_closable{true};

    OpenFileCallback    m_openFileCb;
    CloseCallback       m_closeCb;
};

} // namespace rb
