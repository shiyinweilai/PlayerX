#include "rb_video_cell.h"
#include "../player/rb_video_player.h"
#include "../utils/rb_utils.h"
#include <cstring>
#include <algorithm>
#include <iostream>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
}

namespace rb {

// 把 frame 的色彩空间/范围信息应用到 SwsContext。
// 不调用此函数时 sws 默认用 BT.601 + limited range，对 BT.709 / full-range
// (AVCOL_RANGE_JPEG，常见于手机/相机视频) 视频会产生轻微色偏与对比度压缩，
// 高对比边缘（白字幕/黑背景）灰阶过渡曲线偏移 → 笔画粗细不均 → 视觉上的"毛边"。
// 与 video-compare/format_converter.cpp 的 sws_setColorspaceDetails 行为对齐。
static void rbSwsApplyColorspace(SwsContext* ctx, const AVFrame* frame) {
    if (!ctx || !frame) return;
    int sws_cs = SWS_CS_ITU601;
    switch (frame->colorspace) {
        case AVCOL_SPC_BT709:        sws_cs = SWS_CS_ITU709;    break;
        case AVCOL_SPC_FCC:          sws_cs = SWS_CS_FCC;       break;
        case AVCOL_SPC_SMPTE170M:    sws_cs = SWS_CS_SMPTE170M; break;
        case AVCOL_SPC_SMPTE240M:    sws_cs = SWS_CS_SMPTE240M; break;
        case AVCOL_SPC_BT2020_CL:
        case AVCOL_SPC_BT2020_NCL:   sws_cs = SWS_CS_BT2020;    break;
        default: break;
    }
    const int* coeffs = sws_getCoefficients(sws_cs);
    const int src_range = (frame->color_range == AVCOL_RANGE_JPEG) ? 1 : 0;
    constexpr int FIXED_1_0 = (1 << 16);
    sws_setColorspaceDetails(ctx,
        coeffs, src_range,        // src
        coeffs, 1,                // dst：RGB 输出永远 full-range（PC range）
        0, FIXED_1_0, FIXED_1_0);
}

// ─── 颜色常量 ─────────────────────────────────────────────────────────────────
static constexpr SDL_Color kColBg         = {28,  32,  38,  255};
static constexpr SDL_Color kColBorder     = {70,  80,  95,  255};
static constexpr SDL_Color kColBorderSel  = {80,  160, 255, 255};
static constexpr SDL_Color kColCtrlBg     = {20,  24,  30,  220};
static constexpr SDL_Color kColText       = {230, 230, 230, 255};
static constexpr SDL_Color kColSubText    = {150, 155, 165, 255};
static constexpr SDL_Color kColBtn        = {55,  120, 200, 255};
static constexpr SDL_Color kColBtnHover   = {80,  150, 240, 255};
static constexpr SDL_Color kColProgBg     = {50,  55,  65,  255};
static constexpr SDL_Color kColProgFill   = {70,  140, 220, 255};
static constexpr SDL_Color kColProgKnob   = {200, 220, 255, 255};

// ─── 布局常量（逻辑像素）─────────────────────────────────────────────────────
// 运行时会乘以 m_dpiScale 转换为 drawable（物理）像素，详见 rbScaleI()。
static constexpr int kBtnWLogical    = 64;
static constexpr int kBtnHLogical    = 28;
static constexpr int kPaddingLogical = 10;

// dpi 缩放辅助（到 drawable 像素）
static inline int rbScaleI(float s, int v) {
    int r = static_cast<int>(s * static_cast<float>(v) + 0.5f);
    return (v > 0 && r < 1) ? 1 : r;
}

// ═══════════════════════════════════════════════════════════════════════════
// RBVideoCell
// ═══════════════════════════════════════════════════════════════════════════

RBVideoCell::RBVideoCell() = default;

RBVideoCell::~RBVideoCell() {
    if (m_videoTexLinear)  SDL_DestroyTexture(m_videoTexLinear);
    if (m_videoTexNearest) SDL_DestroyTexture(m_videoTexNearest);
    if (m_videoTexDown)    SDL_DestroyTexture(m_videoTexDown);
    if (m_swsDown) {
        sws_freeContext(static_cast<SwsContext*>(m_swsDown));
        m_swsDown = nullptr;
    }
}

void RBVideoCell::rbInit(SDL_Renderer* renderer, TTF_Font* font, TTF_Font* smallFont) {
    m_renderer  = renderer;
    m_font      = font;
    m_smallFont = smallFont;
}

void RBVideoCell::rbSetPlayer(RBVideoPlayer* player) {
    m_player = player;
    if (m_videoTexLinear)  { SDL_DestroyTexture(m_videoTexLinear);  m_videoTexLinear  = nullptr; }
    if (m_videoTexNearest) { SDL_DestroyTexture(m_videoTexNearest); m_videoTexNearest = nullptr; }
    if (m_videoTexDown)    { SDL_DestroyTexture(m_videoTexDown);    m_videoTexDown    = nullptr; }
    if (m_swsDown) {
        sws_freeContext(static_cast<SwsContext*>(m_swsDown));
        m_swsDown = nullptr;
    }
    m_texW = m_texH = 0;
    m_texDownW = m_texDownH = 0;
    m_swsSrcW = m_swsSrcH = m_swsDstW = m_swsDstH = 0;
    m_swsSrcFmt = -1;
}

void RBVideoCell::rbSetRect(const SDL_Rect& rect) {
    m_rect = rect;
}

// ─── 子区域 ───────────────────────────────────────────────────────────────────
SDL_Rect RBVideoCell::rbVideoArea() const {
    int barH = rbScaleI(m_dpiScale, kRBControlBarH);
    return { m_rect.x, m_rect.y, m_rect.w, m_rect.h - barH };
}

SDL_Rect RBVideoCell::rbControlArea() const {
    int barH = rbScaleI(m_dpiScale, kRBControlBarH);
    return { m_rect.x, m_rect.y + m_rect.h - barH, m_rect.w, barH };
}

SDL_Rect RBVideoCell::rbPlayBtnRect() const {
    auto ctrl = rbControlArea();
    int btnW = rbScaleI(m_dpiScale, kBtnWLogical);
    int btnH = rbScaleI(m_dpiScale, kBtnHLogical);
    int pad  = rbScaleI(m_dpiScale, kPaddingLogical);
    int y = ctrl.y + (ctrl.h - btnH) / 2;
    return { ctrl.x + pad, y, btnW, btnH };
}

SDL_Rect RBVideoCell::rbOpenBtnRect() const {
    auto ctrl = rbControlArea();
    int btnW = rbScaleI(m_dpiScale, kBtnWLogical);
    int btnH = rbScaleI(m_dpiScale, kBtnHLogical);
    int pad  = rbScaleI(m_dpiScale, kPaddingLogical);
    int gap  = rbScaleI(m_dpiScale, 6);
    int y = ctrl.y + (ctrl.h - btnH) / 2;
    return { ctrl.x + pad + btnW + gap, y, btnW, btnH };
}

// 4 个跳转按钮：<<  <  >  >>
// idx: 0=<<(5s back), 1=<(prev frame), 2=>(next frame), 3=>>(5s fwd)
// 单按钮窄一点（kSeekBtnWLogical），4 个连排，整体放在 Open 右侧。
SDL_Rect RBVideoCell::rbSeekBtnRect(int idx) const {
    auto ctrl  = rbControlArea();
    auto open  = rbOpenBtnRect();
    int btnH   = rbScaleI(m_dpiScale, kBtnHLogical);
    int pad    = rbScaleI(m_dpiScale, kPaddingLogical);
    int gap    = rbScaleI(m_dpiScale, 4);
    // 单箭头按钮宽度比常规按钮窄，给进度条让出空间
    int sw     = rbScaleI(m_dpiScale, 32);
    int y      = ctrl.y + (ctrl.h - btnH) / 2;
    int xStart = open.x + open.w + pad;
    return { xStart + idx * (sw + gap), y, sw, btnH };
}

SDL_Rect RBVideoCell::rbProgressRect() const {
    auto ctrl  = rbControlArea();
    auto last  = rbSeekBtnRect(3);  // 最右一个跳转按钮
    int pad    = rbScaleI(m_dpiScale, kPaddingLogical);
    // 时间标签宽度约 100 逻辑像素，按 dpi 同步放大
    int timeW  = rbScaleI(m_dpiScale, 100);
    int x      = last.x + last.w + pad;
    int w      = ctrl.x + ctrl.w - x - timeW - pad;
    int h      = rbScaleI(m_dpiScale, 8);
    int y      = ctrl.y + (ctrl.h - h) / 2;
    return { x, y, std::max(w, 0), h };
}

SDL_Rect RBVideoCell::rbCloseBtnRect() const {
    // 右上角 × 关闭按钮：正方形，边长与控制条按钮高保持一致、并距边一个 pad
    int sz  = rbScaleI(m_dpiScale, kBtnHLogical);
    int pad = rbScaleI(m_dpiScale, 6);
    int x   = m_rect.x + m_rect.w - pad - sz;
    int y   = m_rect.y + pad;
    return { x, y, sz, sz };
}

// ─── 工具绘制 ─────────────────────────────────────────────────────────────────
void RBVideoCell::rbFillRect(const SDL_Rect& r, SDL_Color c) {
    SDL_SetRenderDrawColor(m_renderer, c.r, c.g, c.b, c.a);
    SDL_SetRenderDrawBlendMode(m_renderer, SDL_BLENDMODE_BLEND);
    SDL_RenderFillRect(m_renderer, &r);
}

void RBVideoCell::rbDrawRect(const SDL_Rect& r, SDL_Color c) {
    SDL_SetRenderDrawColor(m_renderer, c.r, c.g, c.b, c.a);
    SDL_RenderDrawRect(m_renderer, &r);
}

void RBVideoCell::rbDrawText(const std::string& text, int x, int y, SDL_Color color, TTF_Font* f) {
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

void RBVideoCell::rbDrawTextCentered(const std::string& text, const SDL_Rect& area, SDL_Color color, TTF_Font* f) {
    if (!f || text.empty()) return;
    int w = 0, h = 0;
    TTF_SizeUTF8(f, text.c_str(), &w, &h);
    rbDrawText(text, area.x + (area.w - w) / 2, area.y + (area.h - h) / 2, color, f);
}

// ─── 渲染入口 ─────────────────────────────────────────────────────────────────
void RBVideoCell::rbRender(int mouseX, int mouseY) {
    if (!m_renderer) return;

    // 背景
    rbFillRect(m_rect, kColBg);

    // 视频或占位
    if (m_player && m_player->rbState() != RBPlayerState::Idle) {
        rbRenderVideo();
    } else {
        rbRenderPlaceholder();
    }

    // 控制条
    rbRenderControlBar(mouseX, mouseY);

    // 边框
    rbDrawRect(m_rect, m_selected ? kColBorderSel : kColBorder);

    // 标题（左上角）
    if (!m_title.empty()) {
        int pad = rbScaleI(m_dpiScale, kPaddingLogical);
        rbDrawText(m_title, m_rect.x + pad, m_rect.y + pad, kColSubText, m_smallFont);
    }

    // 右上角 × 关闭按钮（低调背景 + hover 高亮）
    if (m_closable) {
        auto cb = rbCloseBtnRect();
        bool hover = (mouseX >= cb.x && mouseX < cb.x + cb.w &&
                      mouseY >= cb.y && mouseY < cb.y + cb.h);
        SDL_Color bg = hover ? SDL_Color{200, 70, 80, 220}
                             : SDL_Color{0, 0, 0, 120};
        rbFillRect(cb, bg);
        rbDrawRect(cb, hover ? SDL_Color{240, 200, 200, 255}
                             : SDL_Color{120, 130, 145, 200});
        rbDrawTextCentered("\xc3\x97", cb, kColText, m_font);  // U+00D7 乘号
    }
}

void RBVideoCell::rbRenderPlaceholder() {
    auto area = rbVideoArea();
    std::string hint = m_player ? "Loading..." : "Click [Open] to load a video";
    rbDrawTextCentered(hint, area, kColSubText, m_font);
}

void RBVideoCell::rbRenderVideo() {
    if (!m_player) return;
    AVFrame* frame = m_player->rbGetCurrentFrame();
    if (!frame) {
        rbRenderPlaceholder();
        return;
    }

    int fw = frame->width;
    int fh = frame->height;
    if (fw <= 0 || fh <= 0) { rbRenderPlaceholder(); return; }

    // 创建或重建纹理（同时建立 linear / nearest 两份，尺寸格式相同）
    // SDL2 的过滤模式由 SDL_HINT_RENDER_SCALE_QUALITY 在 SDL_CreateTexture 时决定，
    // 创建后无法更改，因此必须维护两份纹理。
    if (!m_videoTexLinear || !m_videoTexNearest || m_texW != fw || m_texH != fh) {
        if (m_videoTexLinear)  { SDL_DestroyTexture(m_videoTexLinear);  m_videoTexLinear  = nullptr; }
        if (m_videoTexNearest) { SDL_DestroyTexture(m_videoTexNearest); m_videoTexNearest = nullptr; }

        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");
        m_videoTexLinear = SDL_CreateTexture(m_renderer,
            SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, fw, fh);

        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "nearest");
        m_videoTexNearest = SDL_CreateTexture(m_renderer,
            SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, fw, fh);

        m_texW = fw; m_texH = fh;
    }

    if (!m_videoTexLinear || !m_videoTexNearest) { rbRenderPlaceholder(); return; }

    // 上传帧数据到两份纹理（YUV420P 直接上传，其他格式先转换）
    AVPixelFormat fmt = static_cast<AVPixelFormat>(frame->format);
    if (fmt == AV_PIX_FMT_YUV420P || fmt == AV_PIX_FMT_YUVJ420P) {
        SDL_UpdateYUVTexture(m_videoTexLinear,  nullptr,
            frame->data[0], frame->linesize[0],
            frame->data[1], frame->linesize[1],
            frame->data[2], frame->linesize[2]);
        SDL_UpdateYUVTexture(m_videoTexNearest, nullptr,
            frame->data[0], frame->linesize[0],
            frame->data[1], frame->linesize[1],
            frame->data[2], frame->linesize[2]);
    } else {
        // 转换为 YUV420P
        SwsContext* sws = sws_getContext(fw, fh, fmt,
            fw, fh, AV_PIX_FMT_YUV420P,
            SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (sws) {
            AVFrame* dst = av_frame_alloc();
            dst->format = AV_PIX_FMT_YUV420P;
            dst->width  = fw;
            dst->height = fh;
            av_frame_get_buffer(dst, 0);
            sws_scale(sws, frame->data, frame->linesize, 0, fh,
                      dst->data, dst->linesize);
            SDL_UpdateYUVTexture(m_videoTexLinear,  nullptr,
                dst->data[0], dst->linesize[0],
                dst->data[1], dst->linesize[1],
                dst->data[2], dst->linesize[2]);
            SDL_UpdateYUVTexture(m_videoTexNearest, nullptr,
                dst->data[0], dst->linesize[0],
                dst->data[1], dst->linesize[1],
                dst->data[2], dst->linesize[2]);
            av_frame_free(&dst);
            sws_freeContext(sws);
        }
    }

    // 等比缩放居中显示。
    // 关键：dst 尺寸/位置必须四舍五入到整数像素，否则截断会导致：
    //  1) sws_scale 的目标尺寸与屏幕实际渲染纹理像素错位（亚像素偏差）
    //  2) nearest 上屏时边缘像素采样发生 0~0.999 像素偏移 → 字幕等高对比边缘出现毛边/锯齿
    // 与 video-compare 行为完全一致（display.cpp 的 std::round 路径）。
    auto area = rbVideoArea();
    float scaleX = static_cast<float>(area.w) / fw;
    float scaleY = static_cast<float>(area.h) / fh;
    float scale  = std::min(scaleX, scaleY);
    int dw = static_cast<int>(std::round(fw * scale));
    int dh = static_cast<int>(std::round(fh * scale));
    SDL_Rect dst = {
        area.x + static_cast<int>(std::round((area.w - dw) / 2.0f)),
        area.y + static_cast<int>(std::round((area.h - dh) / 2.0f)),
        dw, dh
    };

    bool needHQResample = (dw != fw) || (dh != fh);

    if (needHQResample && dw > 0 && dh > 0) {
        // ── 高质量缩放（缩小或放大）：libswscale LANCZOS 离屏缩放到 dst 尺寸的
        //     RGB24，再上传到目标尺寸 RGB24 nearest 纹理 1:1 渲染。
        //
        // 为什么不走 SDL 自带缩放（IYUV + linear）：
        //   1) Windows D3D11 后端的 IYUV 纹理走专用 YUV→RGB shader，其内部
        //      采样器可能不响应 SDL_HINT_RENDER_SCALE_QUALITY，导致 nearest
        //      hint 在 Windows 上不一定生效（macOS Metal 后端则 100% 生效）——
        //      这就是图中"macOS 锐利、Windows 有毛边"的根因。
        //   2) D3D11 硬件 bilinear 在非整数比例放大时（如窗口 1.3× / 1.7×）
        //      会让中文字幕这类高频边缘出现轻微"油腻感"。
        //
        // 改为：CPU 端 LANCZOS（Lanczos3，6×6 采样、带负瓣 → 锐边保持最好，
        // mpv 默认 sws_flags）一次性把 YUV 帧重采样到 dst 物理像素的 RGB24，
        // 然后 SDL 仅做 1:1 nearest 上屏 → 跨平台行为一致，物理像素级别清晰。
        //
        // 同时使用 RGB24 全分辨率链路，避免 YUV→YUV 缩放时色度被二次子采样
        // 在白字幕/黑背景这类高对比边缘出现的彩色毛边（chroma fringing）。
        //
        // 重建 SwsContext（源尺寸/目标尺寸/格式有任一变化时）
        SwsContext* ctx = static_cast<SwsContext*>(m_swsDown);
        if (!ctx ||
            m_swsSrcW != fw || m_swsSrcH != fh ||
            m_swsDstW != dw || m_swsDstH != dh ||
            m_swsSrcFmt != static_cast<int>(fmt)) {
            if (ctx) sws_freeContext(ctx);
            ctx = sws_getContext(
                fw, fh, fmt,
                dw, dh, AV_PIX_FMT_RGB24,
                SWS_LANCZOS | SWS_FULL_CHR_H_INT | SWS_ACCURATE_RND,
                nullptr, nullptr, nullptr);
            m_swsDown    = ctx;
            m_swsSrcW    = fw;  m_swsSrcH = fh;
            m_swsDstW    = dw;  m_swsDstH = dh;
            m_swsSrcFmt  = static_cast<int>(fmt);
        }
        // 每帧应用色彩空间/范围（开销极小，且 frame 的 colorspace/range
        // 可能动态变化，保持与当前帧严格匹配）
        rbSwsApplyColorspace(ctx, frame);

        // 重建目标尺寸 RGB24 纹理（nearest 1:1 渲染，避免任何 SDL 端缩放）
        if (!m_videoTexDown || m_texDownW != dw || m_texDownH != dh) {
            if (m_videoTexDown) SDL_DestroyTexture(m_videoTexDown);
            SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "nearest");
            m_videoTexDown = SDL_CreateTexture(m_renderer,
                SDL_PIXELFORMAT_RGB24, SDL_TEXTUREACCESS_STREAMING, dw, dh);
            m_texDownW = dw;  m_texDownH = dh;
        }

        if (ctx && m_videoTexDown) {
            // BICUBIC 缩放到 RGB24 缓冲（按 32B 对齐，避免 sws 内部慢路径）
            AVFrame* dstFrame = av_frame_alloc();
            dstFrame->format = AV_PIX_FMT_RGB24;
            dstFrame->width  = dw;
            dstFrame->height = dh;
            if (av_frame_get_buffer(dstFrame, 32) == 0) {
                sws_scale(ctx, frame->data, frame->linesize, 0, fh,
                          dstFrame->data, dstFrame->linesize);
                SDL_UpdateTexture(m_videoTexDown, nullptr,
                                  dstFrame->data[0], dstFrame->linesize[0]);
                // 整数 dst rect 上屏，nearest 1:1 渲染
                SDL_RenderCopy(m_renderer, m_videoTexDown, nullptr, &dst);
                av_frame_free(&dstFrame);
                return;
            }
            av_frame_free(&dstFrame);
        }

        // 兜底：使用 linear 纹理直接缩放渲染
        SDL_RenderCopy(m_renderer, m_videoTexLinear, nullptr, &dst);
        return;
    }

    // 放大或 1:1 → nearest（保持像素锐利，避免 bilinear blur）
    SDL_RenderCopy(m_renderer, m_videoTexNearest, nullptr, &dst);
}

void RBVideoCell::rbRenderControlBar(int mouseX, int mouseY) {
    auto ctrl = rbControlArea();
    rbFillRect(ctrl, kColCtrlBg);

    // ─── 播放/暂停按钮 ────────────────────────────────────────────────────
    auto playBtn = rbPlayBtnRect();
    bool playHover = (mouseX >= playBtn.x && mouseX < playBtn.x + playBtn.w &&
                      mouseY >= playBtn.y && mouseY < playBtn.y + playBtn.h);
    rbFillRect(playBtn, playHover ? kColBtnHover : kColBtn);
    rbDrawRect(playBtn, {100, 120, 150, 255});

    std::string playLabel = "Play";
    if (m_player) {
        if (m_player->rbIsPlaying()) playLabel = "Pause";
        else if (m_player->rbIsEnded()) playLabel = "Replay";
    }
    rbDrawTextCentered(playLabel, playBtn, kColText, m_smallFont ? m_smallFont : m_font);

    // ─── Open 按钮 ────────────────────────────────────────────────────────
    auto openBtn = rbOpenBtnRect();
    bool openHover = (mouseX >= openBtn.x && mouseX < openBtn.x + openBtn.w &&
                      mouseY >= openBtn.y && mouseY < openBtn.y + openBtn.h);
    rbFillRect(openBtn, openHover ? kColBtnHover : kColBtn);
    rbDrawRect(openBtn, {100, 120, 150, 255});
    rbDrawTextCentered("Open", openBtn, kColText, m_smallFont ? m_smallFont : m_font);

    // ─── 跳转按钮 << < > >> ────────────────────────────────────────────
    // 行为：只作用于该 cell（与全局 ←/→ 同步 5s 区分）。
    //  <<  / >>  ：5 秒粗粒度跳转（与左右键单 cell 化等价）
    //  <   / >   ：单帧步进（暂停下解码到目标帧，画面立即更新）
    static const char* kSeekLabel[4] = {
        "\xe2\x80\xb9\xe2\x80\xb9",  // ‹‹
        "\xe2\x80\xb9",              // ‹
        "\xe2\x80\xba",              // ›
        "\xe2\x80\xba\xe2\x80\xba",  // ››
    };
    bool hasPlayer = (m_player && m_player->rbState() != RBPlayerState::Idle);
    for (int i = 0; i < 4; ++i) {
        SDL_Rect r = rbSeekBtnRect(i);
        // 进度条会被压缩到 0 时不再绘制按钮，避免溢出到时间标签上
        if (r.x + r.w >= m_rect.x + m_rect.w) break;
        bool hover = hasPlayer && (mouseX >= r.x && mouseX < r.x + r.w &&
                                   mouseY >= r.y && mouseY < r.y + r.h);
        SDL_Color col = !hasPlayer ? SDL_Color{40,55,75,180}
                                   : (hover ? kColBtnHover : kColBtn);
        rbFillRect(r, col);
        rbDrawRect(r, {100, 120, 150, 255});
        rbDrawTextCentered(kSeekLabel[i], r,
                           hasPlayer ? kColText : SDL_Color{120,130,150,200},
                           m_smallFont ? m_smallFont : m_font);
    }

    // ─── 进度条 ───────────────────────────────────────────────────────────
    rbRenderProgressBar(rbProgressRect(), mouseX, mouseY);

    // ─── 时间标签 ─────────────────────────────────────────────────────────
    auto progRect = rbProgressRect();
    double cur = m_player ? m_player->rbCurrentTime() : 0.0;
    double dur = m_player ? m_player->rbDuration()    : 0.0;
    std::string timeStr = rbFormatTime(cur) + " / " + rbFormatTime(dur);
    int pad = rbScaleI(m_dpiScale, kPaddingLogical);
    int tx = progRect.x + progRect.w + pad;
    int textH = rbScaleI(m_dpiScale, 14);
    int ty = ctrl.y + (ctrl.h - textH) / 2;
    rbDrawText(timeStr, tx, ty, kColSubText, m_smallFont ? m_smallFont : m_font);
}

void RBVideoCell::rbRenderProgressBar(const SDL_Rect& barRect, int mouseX, int mouseY) {
    if (barRect.w <= 0) return;

    // 背景轨道（加高方便点击）
    int trackPadV = rbScaleI(m_dpiScale, 6);
    int trackExtH = rbScaleI(m_dpiScale, 12);
    SDL_Rect track = { barRect.x, barRect.y - trackPadV, barRect.w, barRect.h + trackExtH };
    rbFillRect(barRect, kColProgBg);

    double cur = m_player ? m_player->rbCurrentTime() : 0.0;
    double dur = m_player ? m_player->rbDuration()    : 0.0;
    float ratio = (dur > 0) ? static_cast<float>(cur / dur) : 0.0f;
    ratio = std::max(0.0f, std::min(1.0f, ratio));

    // 已播放部分（圆角感用稍高的矩形）
    SDL_Rect filled = { barRect.x, barRect.y, static_cast<int>(barRect.w * ratio), barRect.h };
    rbFillRect(filled, kColProgFill);

    // 拖拽旋钮
    int knobX = barRect.x + static_cast<int>(barRect.w * ratio);
    bool hover = (mouseX >= track.x && mouseX < track.x + track.w &&
                  mouseY >= track.y && mouseY < track.y + track.h);
    if (hover || m_draggingProgress) {
        int kw  = rbScaleI(m_dpiScale, 12);
        int kpv = rbScaleI(m_dpiScale, 4);
        int kph = rbScaleI(m_dpiScale, 8);
        SDL_Rect knob = { knobX - kw / 2, barRect.y - kpv, kw, barRect.h + kph };
        rbFillRect(knob, kColProgKnob);
    }
}

// ─── 鼠标事件 ─────────────────────────────────────────────────────
void RBVideoCell::rbOnMouseDown(int x, int y, int clicks) {
    // 右上角 × 关闭按钮（优先级最高，避免与选中/双击冲突）
    if (m_closable) {
        auto cb = rbCloseBtnRect();
        if (x >= cb.x && x < cb.x + cb.w &&
            y >= cb.y && y < cb.y + cb.h) {
            if (m_closeCb) m_closeCb(this);
            return;
        }
    }

    // 播放/暂停按钮
    auto playBtn = rbPlayBtnRect();    if (x >= playBtn.x && x < playBtn.x + playBtn.w &&
        y >= playBtn.y && y < playBtn.y + playBtn.h) {
        if (m_player) {
            if (m_player->rbIsEnded()) {
                m_player->rbSeekTo(0.0);
                m_player->rbPlay();
            } else {
                m_player->rbTogglePause();
            }
        }
        return;
    }

    // Open 按钮
    auto openBtn = rbOpenBtnRect();
    if (x >= openBtn.x && x < openBtn.x + openBtn.w &&
        y >= openBtn.y && y < openBtn.y + openBtn.h) {
        if (m_openFileCb) m_openFileCb(this);
        return;
    }

    // 跳转按钮 << < > >>（只作用于本 cell）
    // 0:<< -5s, 1:< 上一帧, 2:> 下一帧, 3:>> +5s
    if (m_player && m_player->rbState() != RBPlayerState::Idle) {
        for (int i = 0; i < 4; ++i) {
            SDL_Rect r = rbSeekBtnRect(i);
            if (x >= r.x && x < r.x + r.w &&
                y >= r.y && y < r.y + r.h) {
                if (i == 0) {
                    m_player->rbSeekTo(std::max(0.0, m_player->rbCurrentTime() - 5.0));
                } else if (i == 3) {
                    m_player->rbSeekTo(std::min(m_player->rbDuration(),
                                                 m_player->rbCurrentTime() + 5.0));
                } else if (i == 1) {
                    m_player->rbStepFrame(-1);
                } else {
                    m_player->rbStepFrame(+1);
                }
                return;
            }
        }
    }

    // 进度条点击
    auto prog = rbProgressRect();
    int trackPad = rbScaleI(m_dpiScale, 4);
    int trackExt = rbScaleI(m_dpiScale, 8);
    SDL_Rect track = { prog.x, prog.y - trackPad, prog.w, prog.h + trackExt };
    if (x >= track.x && x < track.x + track.w &&
        y >= track.y && y < track.y + track.h && prog.w > 0) {
        m_draggingProgress = true;
        double ratio = static_cast<double>(x - prog.x) / prog.w;
        ratio = std::max(0.0, std::min(1.0, ratio));
        if (m_player) {
            double target = ratio * m_player->rbDuration();
            m_player->rbSeekTo(target);
        }
        return;
    }

    // 视频画面区域：双击切换播放/暂停（常规视频播放器交互）
    auto vid = rbVideoArea();
    if (clicks >= 2 &&
        x >= vid.x && x < vid.x + vid.w &&
        y >= vid.y && y < vid.y + vid.h) {
        if (m_player && m_player->rbState() != RBPlayerState::Idle) {
            if (m_player->rbIsEnded()) {
                m_player->rbSeekTo(0.0);
                m_player->rbPlay();
            } else {
                m_player->rbTogglePause();
            }
        }
        return;
    }
}

void RBVideoCell::rbOnMouseUp(int x, int y) {
    (void)x; (void)y;
    m_draggingProgress = false;
}

void RBVideoCell::rbOnMouseMove(int x, int y) {
    if (!m_draggingProgress || !m_player) return;
    auto prog = rbProgressRect();
    if (prog.w <= 0) return;
    double ratio = static_cast<double>(x - prog.x) / prog.w;
    ratio = std::max(0.0, std::min(1.0, ratio));
    m_player->rbSeekTo(ratio * m_player->rbDuration());
}

} // namespace rb
