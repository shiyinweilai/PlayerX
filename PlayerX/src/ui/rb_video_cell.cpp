#include "rb_video_cell.h"
#include "../player/rb_video_player.h"
#include "../utils/rb_utils.h"
#include <cstring>
#include <algorithm>
#include <iostream>

extern "C" {
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
}

namespace rb {

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

// ─── 布局常量 ─────────────────────────────────────────────────────────────────
static constexpr int kBtnW    = 64;
static constexpr int kBtnH    = 28;
static constexpr int kPadding = 10;

// ═══════════════════════════════════════════════════════════════════════════
// RBVideoCell
// ═══════════════════════════════════════════════════════════════════════════

RBVideoCell::RBVideoCell() = default;

RBVideoCell::~RBVideoCell() {
    if (m_videoTex) SDL_DestroyTexture(m_videoTex);
}

void RBVideoCell::rbInit(SDL_Renderer* renderer, TTF_Font* font, TTF_Font* smallFont) {
    m_renderer  = renderer;
    m_font      = font;
    m_smallFont = smallFont;
}

void RBVideoCell::rbSetPlayer(RBVideoPlayer* player) {
    m_player = player;
    if (m_videoTex) {
        SDL_DestroyTexture(m_videoTex);
        m_videoTex = nullptr;
        m_texW = m_texH = 0;
    }
}

void RBVideoCell::rbSetRect(const SDL_Rect& rect) {
    m_rect = rect;
}

// ─── 子区域 ───────────────────────────────────────────────────────────────────
SDL_Rect RBVideoCell::rbVideoArea() const {
    return { m_rect.x, m_rect.y, m_rect.w, m_rect.h - kRBControlBarH };
}

SDL_Rect RBVideoCell::rbControlArea() const {
    return { m_rect.x, m_rect.y + m_rect.h - kRBControlBarH, m_rect.w, kRBControlBarH };
}

SDL_Rect RBVideoCell::rbPlayBtnRect() const {
    auto ctrl = rbControlArea();
    int y = ctrl.y + (ctrl.h - kBtnH) / 2;
    return { ctrl.x + kPadding, y, kBtnW, kBtnH };
}

SDL_Rect RBVideoCell::rbOpenBtnRect() const {
    auto ctrl = rbControlArea();
    int y = ctrl.y + (ctrl.h - kBtnH) / 2;
    return { ctrl.x + kPadding + kBtnW + 6, y, kBtnW, kBtnH };
}

SDL_Rect RBVideoCell::rbProgressRect() const {
    auto ctrl  = rbControlArea();
    auto open  = rbOpenBtnRect();
    // 时间标签宽度约 100px，右侧留 kPadding
    int timeW  = 100;
    int x      = open.x + open.w + kPadding;
    int w      = ctrl.x + ctrl.w - x - timeW - kPadding;
    int h      = 8;
    int y      = ctrl.y + (ctrl.h - h) / 2;
    return { x, y, std::max(w, 0), h };
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
        rbDrawText(m_title, m_rect.x + kPadding, m_rect.y + kPadding, kColSubText, m_smallFont);
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

    // 创建或重建纹理
    if (!m_videoTex || m_texW != fw || m_texH != fh) {
        if (m_videoTex) SDL_DestroyTexture(m_videoTex);
        m_videoTex = SDL_CreateTexture(m_renderer,
            SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, fw, fh);
        m_texW = fw; m_texH = fh;
    }

    if (!m_videoTex) { rbRenderPlaceholder(); return; }

    // 上传帧数据（YUV420P 直接上传，其他格式先转换）
    AVPixelFormat fmt = static_cast<AVPixelFormat>(frame->format);
    if (fmt == AV_PIX_FMT_YUV420P || fmt == AV_PIX_FMT_YUVJ420P) {
        SDL_UpdateYUVTexture(m_videoTex, nullptr,
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
            SDL_UpdateYUVTexture(m_videoTex, nullptr,
                dst->data[0], dst->linesize[0],
                dst->data[1], dst->linesize[1],
                dst->data[2], dst->linesize[2]);
            av_frame_free(&dst);
            sws_freeContext(sws);
        }
    }

    // 等比缩放居中显示
    auto area = rbVideoArea();
    float scaleX = static_cast<float>(area.w) / fw;
    float scaleY = static_cast<float>(area.h) / fh;
    float scale  = std::min(scaleX, scaleY);
    int dw = static_cast<int>(fw * scale);
    int dh = static_cast<int>(fh * scale);
    SDL_Rect dst = {
        area.x + (area.w - dw) / 2,
        area.y + (area.h - dh) / 2,
        dw, dh
    };
    SDL_RenderCopy(m_renderer, m_videoTex, nullptr, &dst);
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

    // ─── 进度条 ───────────────────────────────────────────────────────────
    rbRenderProgressBar(rbProgressRect(), mouseX, mouseY);

    // ─── 时间标签 ─────────────────────────────────────────────────────────
    auto progRect = rbProgressRect();
    double cur = m_player ? m_player->rbCurrentTime() : 0.0;
    double dur = m_player ? m_player->rbDuration()    : 0.0;
    std::string timeStr = rbFormatTime(cur) + " / " + rbFormatTime(dur);
    int tx = progRect.x + progRect.w + kPadding;
    int ty = ctrl.y + (ctrl.h - 14) / 2;
    rbDrawText(timeStr, tx, ty, kColSubText, m_smallFont ? m_smallFont : m_font);
}

void RBVideoCell::rbRenderProgressBar(const SDL_Rect& barRect, int mouseX, int mouseY) {
    if (barRect.w <= 0) return;

    // 背景轨道（加高方便点击）
    SDL_Rect track = { barRect.x, barRect.y - 6, barRect.w, barRect.h + 12 };
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
        SDL_Rect knob = { knobX - 6, barRect.y - 4, 12, barRect.h + 8 };
        rbFillRect(knob, kColProgKnob);
    }
}

// ─── 鼠标事件 ─────────────────────────────────────────────────────────────────
void RBVideoCell::rbOnMouseDown(int x, int y, int clicks) {
    // 播放/暂停按钮
    auto playBtn = rbPlayBtnRect();
    if (x >= playBtn.x && x < playBtn.x + playBtn.w &&
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

    // 进度条点击
    auto prog = rbProgressRect();
    SDL_Rect track = { prog.x, prog.y - 4, prog.w, prog.h + 8 };
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
