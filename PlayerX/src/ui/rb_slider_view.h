#pragma once
/**
 * rb_slider_view.h — 双视频"滑动比较"视图（参考 video-compare）
 *
 * 单窗口、固定 2 路视频：左视频显示鼠标 x 左侧，右视频显示鼠标 x 右侧，
 * 中间一根白色竖线作为分隔。左右两路 player 由 RBPlayerUI 提供（不接管所有权）。
 *
 * 视图自带底部一条统一的控制条（播放/暂停 + 进度条 + 时间）；
 * 鼠标拖拽进度、空格键、方向键的同步控制由 RBPlayerUI 统一负责（与多路一致）。
 */

#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include <string>

namespace rb {

class RBVideoPlayer;

class RBSliderView {
public:
    RBSliderView();
    ~RBSliderView();

    // 初始化（renderer 与字体由 UI 注入）
    void rbInit(SDL_Renderer* renderer, TTF_Font* font, TTF_Font* smallFont);

    // HighDPI 缩放因子（drawable / window），由 UI 同步
    void rbSetDpiScale(float s) { m_dpiScale = (s > 0.0f) ? s : 1.0f; }
    float rbDpiScale() const { return m_dpiScale; }

    // 绑定左右两路播放器（不接管所有权，UI 持有生命周期）
    void rbSetPlayers(RBVideoPlayer* left, RBVideoPlayer* right);

    // 设置占用区域（顶部工具栏下方的内容区域）
    void rbSetRect(const SDL_Rect& rect);

    // 渲染（每帧调用）
    void rbRender(int mouseX, int mouseY);

    // 鼠标事件（由 UI 分发）
    void rbOnMouseMove(int x, int y);
    void rbOnMouseDown(int x, int y, int clicks);
    void rbOnMouseUp(int x, int y);

private:
    // 视频显示区（去掉底部控制条）
    SDL_Rect rbVideoArea() const;
    SDL_Rect rbControlArea() const;
    SDL_Rect rbPlayBtnRect() const;
    SDL_Rect rbProgressRect() const;

    // 计算视频在 video area 中"等比缩放居中"后的目标矩形（左右两路统一以此为画布）
    // 同时返回视频的"逻辑像素尺寸" videoW/videoH（取左右两路的统一基准：max）
    void rbComputeVideoLayout(SDL_Rect& outDst, int& outVideoW, int& outVideoH) const;

    // 帧上传到指定纹理组（linear/nearest 同时同步上传）。
    // YUV420P 直接上传，其他格式 sws 转换。返回是否成功。
    bool rbUploadFrame(SDL_Texture*& texLinear, SDL_Texture*& texNearest,
                       int& texW, int& texH, RBVideoPlayer* player);
    // 渲染左右半边（src 是 [0,split_x] / [split_x,videoW]，dst 同步切分）
    void rbRenderHalf(SDL_Texture* tex, int videoW, int videoH,
                      int srcX, int srcW,
                      const SDL_Rect& dstFull, int dstSplitX);

    // 控制条
    void rbRenderControlBar(int mouseX, int mouseY);
    void rbRenderProgressBar(const SDL_Rect& barRect, int mouseX, int mouseY);

    void rbDrawText(const std::string& text, int x, int y, SDL_Color color, TTF_Font* f);
    void rbDrawTextCentered(const std::string& text, const SDL_Rect& area, SDL_Color color, TTF_Font* f);
    void rbFillRect(const SDL_Rect& r, SDL_Color color);
    void rbDrawRect(const SDL_Rect& r, SDL_Color color);

    SDL_Renderer*  m_renderer{nullptr};
    TTF_Font*      m_font{nullptr};
    TTF_Font*      m_smallFont{nullptr};

    RBVideoPlayer* m_left{nullptr};
    RBVideoPlayer* m_right{nullptr};

    // 每路两份纹理：linear 用于缩小（消除网格伪影），nearest 用于放大/1:1。
    SDL_Texture*   m_texLeftLinear{nullptr};
    SDL_Texture*   m_texLeftNearest{nullptr};
    int            m_texLeftW{0}, m_texLeftH{0};
    SDL_Texture*   m_texRightLinear{nullptr};
    SDL_Texture*   m_texRightNearest{nullptr};
    int            m_texRightW{0}, m_texRightH{0};

    // ── 缩小路径（高质量）：libswscale BICUBIC 离屏 YUV→YUV 缩放 → 1:1 上屏 ──
    // 为每路缓存 (sws ctx + 目标尺寸 IYUV nearest 纹理)，避免缩小时 SDL linear
    // 仍残留的轻微"网格/摩尔纹"伪影（与 video-compare LanczosScaler 思路一致）。
    void*          m_swsLeftDown{nullptr};   // SwsContext*
    int            m_swsLeftSrcW{0}, m_swsLeftSrcH{0};
    int            m_swsLeftDstW{0}, m_swsLeftDstH{0};
    SDL_Texture*   m_texLeftDown{nullptr};
    int            m_texLeftDownW{0}, m_texLeftDownH{0};

    void*          m_swsRightDown{nullptr};
    int            m_swsRightSrcW{0}, m_swsRightSrcH{0};
    int            m_swsRightDstW{0}, m_swsRightDstH{0};
    SDL_Texture*   m_texRightDown{nullptr};
    int            m_texRightDownW{0}, m_texRightDownH{0};

    SDL_Rect       m_rect{0,0,0,0};

    // 鼠标位置（窗口坐标），用于决定 split 位置
    int            m_mouseX{-1};
    int            m_mouseY{-1};

    // 进度条拖拽
    bool           m_draggingProgress{false};

    // HighDPI 缩放因子（drawable / window）
    float          m_dpiScale{1.0f};
};

} // namespace rb
