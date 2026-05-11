#include "rb_slider_view.h"
#include "../player/rb_video_player.h"
#include "../utils/rb_utils.h"

#include <algorithm>
#include <cmath>

extern "C" {
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
}

namespace rb {

namespace {
// 用 libswscale BICUBIC 把 player 当前帧 YUV420P 缩放到 (dstW,dstH) 的目标尺寸 IYUV nearest 纹理。
// - swsCtxIn / 缓存尺寸：调用者持有，本函数按需重建；
// - texOut / 缓存尺寸：调用者持有，按需重建为 (dstW,dstH) IYUV streaming 纹理（nearest）；
// 返回是否成功（成功后 texOut 已填充并可 1:1 渲染）。
static bool rbBicubicDownscaleToTexture(
    SDL_Renderer* renderer, RBVideoPlayer* player,
    int dstW, int dstH,
    void*& swsCtxIn,
    int& swsSrcW, int& swsSrcH, int& swsDstW, int& swsDstH,
    SDL_Texture*& texOut, int& texOutW, int& texOutH)
{
    if (!player || dstW <= 0 || dstH <= 0) return false;
    AVFrame* frame = player->rbGetCurrentFrame();
    if (!frame) return false;

    int fw = frame->width;
    int fh = frame->height;
    if (fw <= 0 || fh <= 0) return false;

    AVPixelFormat fmt = static_cast<AVPixelFormat>(frame->format);
    bool needConvert = !(fmt == AV_PIX_FMT_YUV420P || fmt == AV_PIX_FMT_YUVJ420P);

    // 重建 sws 上下文
    SwsContext* ctx = static_cast<SwsContext*>(swsCtxIn);
    if (!ctx ||
        swsSrcW != fw || swsSrcH != fh ||
        swsDstW != dstW || swsDstH != dstH) {
        if (ctx) sws_freeContext(ctx);
        ctx = sws_getContext(
            fw, fh, AV_PIX_FMT_YUV420P,
            dstW, dstH, AV_PIX_FMT_YUV420P,
            SWS_BICUBIC | SWS_FULL_CHR_H_INT | SWS_ACCURATE_RND,
            nullptr, nullptr, nullptr);
        swsCtxIn = ctx;
        swsSrcW = fw; swsSrcH = fh;
        swsDstW = dstW; swsDstH = dstH;
    }
    if (!ctx) return false;

    // 重建目标尺寸 IYUV nearest 纹理
    if (!texOut || texOutW != dstW || texOutH != dstH) {
        if (texOut) SDL_DestroyTexture(texOut);
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "nearest");
        texOut = SDL_CreateTexture(renderer,
            SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, dstW, dstH);
        texOutW = dstW; texOutH = dstH;
        if (!texOut) return false;
    }

    AVFrame* dstFrame = av_frame_alloc();
    dstFrame->format = AV_PIX_FMT_YUV420P;
    dstFrame->width  = dstW;
    dstFrame->height = dstH;
    if (av_frame_get_buffer(dstFrame, 0) != 0) {
        av_frame_free(&dstFrame);
        return false;
    }

    bool ok = false;
    if (!needConvert) {
        sws_scale(ctx, frame->data, frame->linesize, 0, fh,
                  dstFrame->data, dstFrame->linesize);
        ok = true;
    } else {
        SwsContext* tmp = sws_getContext(fw, fh, fmt,
                                         fw, fh, AV_PIX_FMT_YUV420P,
                                         SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (tmp) {
            AVFrame* mid = av_frame_alloc();
            mid->format = AV_PIX_FMT_YUV420P;
            mid->width  = fw; mid->height = fh;
            if (av_frame_get_buffer(mid, 0) == 0) {
                sws_scale(tmp, frame->data, frame->linesize, 0, fh,
                          mid->data, mid->linesize);
                sws_scale(ctx, mid->data, mid->linesize, 0, fh,
                          dstFrame->data, dstFrame->linesize);
                ok = true;
            }
            av_frame_free(&mid);
            sws_freeContext(tmp);
        }
    }

    if (ok) {
        SDL_UpdateYUVTexture(texOut, nullptr,
            dstFrame->data[0], dstFrame->linesize[0],
            dstFrame->data[1], dstFrame->linesize[1],
            dstFrame->data[2], dstFrame->linesize[2]);
    }
    av_frame_free(&dstFrame);
    return ok;
}
} // anonymous namespace

// ─── 颜色常量（与 Cell 风格对齐）──────────────────────────────────────────────
static constexpr SDL_Color kColBg         = {18,  20,  24,  255};
static constexpr SDL_Color kColCtrlBg     = {20,  24,  30,  235};
static constexpr SDL_Color kColText       = {230, 230, 230, 255};
static constexpr SDL_Color kColSubText    = {150, 155, 165, 255};
static constexpr SDL_Color kColBtn        = {55,  120, 200, 255};
static constexpr SDL_Color kColBtnHover   = {80,  150, 240, 255};
static constexpr SDL_Color kColProgBg     = {50,  55,  65,  255};
static constexpr SDL_Color kColProgFill   = {70,  140, 220, 255};
static constexpr SDL_Color kColProgKnob   = {200, 220, 255, 255};
static constexpr SDL_Color kColSlider     = {255, 255, 255, 255};
static constexpr SDL_Color kColLabelBg    = {0,   0,   0,   140};

// ─── 布局常量 ─────────────────────────────────────────────────────────────────
static constexpr int kCtrlHLogical = 56;
static constexpr int kBtnWLogical  = 64;
static constexpr int kBtnHLogical  = 28;
static constexpr int kPadLogical   = 10;

// dpi 缩放辅助（到 drawable 像素）
static inline int rbScaleI(float s, int v) {
    int r = static_cast<int>(s * static_cast<float>(v) + 0.5f);
    return (v > 0 && r < 1) ? 1 : r;
}

// ═══════════════════════════════════════════════════════════════════════════
RBSliderView::RBSliderView() = default;

RBSliderView::~RBSliderView() {
    if (m_texLeftLinear)   SDL_DestroyTexture(m_texLeftLinear);
    if (m_texLeftNearest)  SDL_DestroyTexture(m_texLeftNearest);
    if (m_texRightLinear)  SDL_DestroyTexture(m_texRightLinear);
    if (m_texRightNearest) SDL_DestroyTexture(m_texRightNearest);
    if (m_texLeftDown)     SDL_DestroyTexture(m_texLeftDown);
    if (m_texRightDown)    SDL_DestroyTexture(m_texRightDown);
    if (m_swsLeftDown)  { sws_freeContext(static_cast<SwsContext*>(m_swsLeftDown));  m_swsLeftDown  = nullptr; }
    if (m_swsRightDown) { sws_freeContext(static_cast<SwsContext*>(m_swsRightDown)); m_swsRightDown = nullptr; }
}

void RBSliderView::rbInit(SDL_Renderer* renderer, TTF_Font* font, TTF_Font* smallFont) {
    m_renderer  = renderer;
    m_font      = font;
    m_smallFont = smallFont;
}

void RBSliderView::rbSetPlayers(RBVideoPlayer* left, RBVideoPlayer* right) {
    auto resetPair = [](SDL_Texture*& a, SDL_Texture*& b, int& w, int& h) {
        if (a) { SDL_DestroyTexture(a); a = nullptr; }
        if (b) { SDL_DestroyTexture(b); b = nullptr; }
        w = h = 0;
    };
    auto resetDown = [](SDL_Texture*& tex, int& tw, int& th,
                        void*& sws, int& sw, int& sh, int& dw, int& dh) {
        if (tex) { SDL_DestroyTexture(tex); tex = nullptr; }
        tw = th = 0;
        if (sws) { sws_freeContext(static_cast<SwsContext*>(sws)); sws = nullptr; }
        sw = sh = dw = dh = 0;
    };
    if (m_left  != left) {
        resetPair(m_texLeftLinear,  m_texLeftNearest,  m_texLeftW,  m_texLeftH);
        resetDown(m_texLeftDown, m_texLeftDownW, m_texLeftDownH,
                  m_swsLeftDown, m_swsLeftSrcW, m_swsLeftSrcH, m_swsLeftDstW, m_swsLeftDstH);
    }
    if (m_right != right) {
        resetPair(m_texRightLinear, m_texRightNearest, m_texRightW, m_texRightH);
        resetDown(m_texRightDown, m_texRightDownW, m_texRightDownH,
                  m_swsRightDown, m_swsRightSrcW, m_swsRightSrcH, m_swsRightDstW, m_swsRightDstH);
    }
    m_left  = left;
    m_right = right;
}

void RBSliderView::rbSetRect(const SDL_Rect& rect) {
    m_rect = rect;
}

// ─── 子区域 ───────────────────────────────────────────────────────────────────
SDL_Rect RBSliderView::rbVideoArea() const {
    int ctrlH = rbScaleI(m_dpiScale, kCtrlHLogical);
    return { m_rect.x, m_rect.y, m_rect.w, std::max(0, m_rect.h - ctrlH) };
}

SDL_Rect RBSliderView::rbControlArea() const {
    int ctrlH = rbScaleI(m_dpiScale, kCtrlHLogical);
    return { m_rect.x, m_rect.y + std::max(0, m_rect.h - ctrlH), m_rect.w, ctrlH };
}

SDL_Rect RBSliderView::rbPlayBtnRect() const {
    auto ctrl = rbControlArea();
    int btnW = rbScaleI(m_dpiScale, kBtnWLogical);
    int btnH = rbScaleI(m_dpiScale, kBtnHLogical);
    int pad  = rbScaleI(m_dpiScale, kPadLogical);
    int y = ctrl.y + (ctrl.h - btnH) / 2;
    return { ctrl.x + pad, y, btnW, btnH };
}

SDL_Rect RBSliderView::rbProgressRect() const {
    auto ctrl = rbControlArea();
    auto play = rbPlayBtnRect();
    int pad   = rbScaleI(m_dpiScale, kPadLogical);
    int timeW = rbScaleI(m_dpiScale, 120);
    int x = play.x + play.w + pad;
    int w = ctrl.x + ctrl.w - x - timeW - pad;
    int h = rbScaleI(m_dpiScale, 8);
    int y = ctrl.y + (ctrl.h - h) / 2;
    return { x, y, std::max(w, 0), h };
}

// ─── 视频布局：等比缩放居中 ───────────────────────────────────────────────────
void RBSliderView::rbComputeVideoLayout(SDL_Rect& outDst, int& outVideoW, int& outVideoH) const {
    auto area = rbVideoArea();
    // 取左右两路的"统一画布"尺寸：用 max 以避免任何一路被裁切，
    // 真实纹理由各自帧填充自身的子矩形。
    int wL = m_left  ? m_left->rbWidth()  : 0;
    int hL = m_left  ? m_left->rbHeight() : 0;
    int wR = m_right ? m_right->rbWidth() : 0;
    int hR = m_right ? m_right->rbHeight() : 0;
    int videoW = std::max(wL, wR);
    int videoH = std::max(hL, hR);
    if (videoW <= 0 || videoH <= 0) {
        outDst = { area.x, area.y, area.w, area.h };
        outVideoW = std::max(1, area.w);
        outVideoH = std::max(1, area.h);
        return;
    }
    float sx = static_cast<float>(area.w) / videoW;
    float sy = static_cast<float>(area.h) / videoH;
    float s  = std::min(sx, sy);
    int dw = static_cast<int>(videoW * s);
    int dh = static_cast<int>(videoH * s);
    outDst = { area.x + (area.w - dw) / 2,
               area.y + (area.h - dh) / 2,
               dw, dh };
    outVideoW = videoW;
    outVideoH = videoH;
}

// ─── 帧上传（linear + nearest 两份同步上传）───────────────────────────
bool RBSliderView::rbUploadFrame(SDL_Texture*& texLinear, SDL_Texture*& texNearest,
                                  int& texW, int& texH, RBVideoPlayer* player) {
    if (!player) return false;
    AVFrame* frame = player->rbGetCurrentFrame();
    // 没新帧但旧纹理仍可用
    if (!frame) return (texLinear != nullptr && texNearest != nullptr);

    int fw = frame->width;
    int fh = frame->height;
    if (fw <= 0 || fh <= 0) return (texLinear != nullptr && texNearest != nullptr);

    if (!texLinear || !texNearest || texW != fw || texH != fh) {
        if (texLinear)  { SDL_DestroyTexture(texLinear);  texLinear  = nullptr; }
        if (texNearest) { SDL_DestroyTexture(texNearest); texNearest = nullptr; }

        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");
        texLinear = SDL_CreateTexture(m_renderer,
            SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, fw, fh);

        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "nearest");
        texNearest = SDL_CreateTexture(m_renderer,
            SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, fw, fh);

        texW = fw;
        texH = fh;
    }
    if (!texLinear || !texNearest) return false;

    AVPixelFormat fmt = static_cast<AVPixelFormat>(frame->format);
    if (fmt == AV_PIX_FMT_YUV420P || fmt == AV_PIX_FMT_YUVJ420P) {
        SDL_UpdateYUVTexture(texLinear,  nullptr,
            frame->data[0], frame->linesize[0],
            frame->data[1], frame->linesize[1],
            frame->data[2], frame->linesize[2]);
        SDL_UpdateYUVTexture(texNearest, nullptr,
            frame->data[0], frame->linesize[0],
            frame->data[1], frame->linesize[1],
            frame->data[2], frame->linesize[2]);
    } else {
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
            SDL_UpdateYUVTexture(texLinear,  nullptr,
                dst->data[0], dst->linesize[0],
                dst->data[1], dst->linesize[1],
                dst->data[2], dst->linesize[2]);
            SDL_UpdateYUVTexture(texNearest, nullptr,
                dst->data[0], dst->linesize[0],
                dst->data[1], dst->linesize[1],
                dst->data[2], dst->linesize[2]);
            av_frame_free(&dst);
            sws_freeContext(sws);
        }
    }
    return true;
}
// ─── 渲染半边 ─────────────────────────────────────────────────────────────────
// 语义：把 dstFull 按"统一画布坐标 [0, videoW]"线性划分，本次只负责绘制
// 横向区段 [srcX, srcX+srcW) 对应的部分。该路纹理（可能与 videoW 不同尺寸）
// 整体被等比映射到 dstFull，再用同样比例切出对应横向区段。
void RBSliderView::rbRenderHalf(SDL_Texture* tex, int videoW, int videoH,
                                 int srcX, int srcW,
                                 const SDL_Rect& dstFull, int dstSplitX) {
    (void)videoH;
    (void)dstSplitX;
    if (!tex || srcW <= 0 || dstFull.w <= 0 || dstFull.h <= 0 || videoW <= 0) return;

    int realW = 0, realH = 0;
    SDL_QueryTexture(tex, nullptr, nullptr, &realW, &realH);
    if (realW <= 0 || realH <= 0) return;

    // 1) 在统一画布上的横向比例区间 [r0, r1]
    float r0 = static_cast<float>(srcX) / videoW;
    float r1 = static_cast<float>(srcX + srcW) / videoW;
    r0 = std::max(0.0f, std::min(1.0f, r0));
    r1 = std::max(0.0f, std::min(1.0f, r1));
    if (r1 <= r0) return;

    // 2) 该路真实纹理对应的 src 矩形：按相同比例切自己的全宽
    int texSrcX = static_cast<int>(std::round(r0 * realW));
    int texSrcW = static_cast<int>(std::round((r1 - r0) * realW));
    if (texSrcW <= 0) return;
    SDL_Rect texSrc = { texSrcX, 0, texSrcW, realH };

    // 3) 在 dstFull 上的目标矩形：同比例切 dstFull 全宽
    int dstX0 = dstFull.x + static_cast<int>(std::round(r0 * dstFull.w));
    int dstX1 = dstFull.x + static_cast<int>(std::round(r1 * dstFull.w));
    SDL_Rect dst = { dstX0, dstFull.y, std::max(1, dstX1 - dstX0), dstFull.h };

    SDL_RenderCopy(m_renderer, tex, &texSrc, &dst);
}

// ─── 主渲染 ───────────────────────────────────────────────────────────────────
void RBSliderView::rbRender(int mouseX, int mouseY) {
    if (!m_renderer) return;
    m_mouseX = mouseX;
    m_mouseY = mouseY;

    // 整体背景
    rbFillRect(m_rect, kColBg);

    // 上传两路当前帧到各自纹理（linear + nearest 同步上传）
    rbUploadFrame(m_texLeftLinear,  m_texLeftNearest,  m_texLeftW,  m_texLeftH,  m_left);
    rbUploadFrame(m_texRightLinear, m_texRightNearest, m_texRightW, m_texRightH, m_right);

    // 计算视频布局
    SDL_Rect dst;
    int videoW = 0, videoH = 0;
    rbComputeVideoLayout(dst, videoW, videoH);

    // 鼠标 x → split_x（视频坐标）。若鼠标不在 video area 内，固定为中线。
    auto vidArea = rbVideoArea();
    int split_x = videoW / 2;
    if (mouseX >= vidArea.x && mouseX < vidArea.x + vidArea.w &&
        mouseY >= vidArea.y && mouseY < vidArea.y + vidArea.h &&
        dst.w > 0) {
        // 用 dst 区域将屏幕 x 反变换为视频坐标
        float r = static_cast<float>(mouseX - dst.x) / std::max(1, dst.w);
        r = std::max(0.0f, std::min(1.0f, r));
        split_x = static_cast<int>(std::round(r * videoW));
        split_x = std::max(0, std::min(videoW, split_x));
    }

    // 按缩放选路径：
    //   - 缩小 (dstHalfW < realW): 走 BICUBIC 离屏 YUV→YUV 缩放到 dst 尺寸，
    //     再用 nearest 1:1 切片渲染（与 video-compare LanczosScaler 一致，从根源
    //     消除 SDL 缩小时的网格/摩尔纹伪影）；
    //   - 放大或 1:1：使用 nearest 纹理（保持像素锐利）。

    // 左半 dst 宽度：split_x / videoW * dst.w；右半同理
    int dstLeftW  = static_cast<int>(std::round(static_cast<float>(split_x) / std::max(1, videoW) * dst.w));
    int dstRightW = std::max(0, dst.w - dstLeftW);

    // 该路全宽对应到 dstFull 后的目标整体宽：本路真实宽 / videoW * dst.w
    auto fullDstSizeFor = [&](int realW, int realH, int& outW, int& outH) {
        if (realW <= 0 || realH <= 0 || videoW <= 0) { outW = outH = 0; return; }
        outW = std::max(1, static_cast<int>(std::round(static_cast<float>(realW) / videoW * dst.w)));
        outH = std::max(1, dst.h);
    };

    auto renderHalfDownscaled = [&](SDL_Texture* texDown, int texDownW, int texDownH,
                                     int srcStartX, int srcSpanX) {
        // 在统一画布上的横向比例区间 [r0, r1]
        if (videoW <= 0 || srcSpanX <= 0) return;
        float r0 = static_cast<float>(srcStartX) / videoW;
        float r1 = static_cast<float>(srcStartX + srcSpanX) / videoW;
        r0 = std::max(0.0f, std::min(1.0f, r0));
        r1 = std::max(0.0f, std::min(1.0f, r1));
        if (r1 <= r0) return;
        // 该路 down 纹理代表"该路全宽映射到 dstFull 后"的图像，所以按 [r0,r1] 切片
        int sx0 = static_cast<int>(std::round(r0 * texDownW));
        int sx1 = static_cast<int>(std::round(r1 * texDownW));
        SDL_Rect texSrc = { sx0, 0, std::max(1, sx1 - sx0), texDownH };
        int dx0 = dst.x + static_cast<int>(std::round(r0 * dst.w));
        int dx1 = dst.x + static_cast<int>(std::round(r1 * dst.w));
        SDL_Rect dstR  = { dx0, dst.y, std::max(1, dx1 - dx0), dst.h };
        SDL_RenderCopy(m_renderer, texDown, &texSrc, &dstR);
    };

    // ── 左半 ──
    if (split_x > 0) {
        bool useDownLeft = false;
        // 仅当该路真实尺寸 > 该路完整映射到 dstFull 后的尺寸时才走 BICUBIC 缩小
        int leftFullDstW = 0, leftFullDstH = 0;
        fullDstSizeFor(m_texLeftW, m_texLeftH, leftFullDstW, leftFullDstH);
        if (m_left && m_texLeftW > 0 && leftFullDstW > 0 &&
            (leftFullDstW < m_texLeftW || leftFullDstH < m_texLeftH)) {
            useDownLeft = rbBicubicDownscaleToTexture(
                m_renderer, m_left, leftFullDstW, leftFullDstH,
                m_swsLeftDown, m_swsLeftSrcW, m_swsLeftSrcH, m_swsLeftDstW, m_swsLeftDstH,
                m_texLeftDown, m_texLeftDownW, m_texLeftDownH);
        }
        if (useDownLeft) {
            renderHalfDownscaled(m_texLeftDown, m_texLeftDownW, m_texLeftDownH, 0, split_x);
        } else if (m_texLeftNearest) {
            rbRenderHalf(m_texLeftNearest, videoW, videoH, 0, split_x, dst, split_x);
        }
    }

    // ── 右半 ──
    if (split_x < videoW) {
        bool useDownRight = false;
        int rightFullDstW = 0, rightFullDstH = 0;
        fullDstSizeFor(m_texRightW, m_texRightH, rightFullDstW, rightFullDstH);
        if (m_right && m_texRightW > 0 && rightFullDstW > 0 &&
            (rightFullDstW < m_texRightW || rightFullDstH < m_texRightH)) {
            useDownRight = rbBicubicDownscaleToTexture(
                m_renderer, m_right, rightFullDstW, rightFullDstH,
                m_swsRightDown, m_swsRightSrcW, m_swsRightSrcH, m_swsRightDstW, m_swsRightDstH,
                m_texRightDown, m_texRightDownW, m_texRightDownH);
        }
        if (useDownRight) {
            renderHalfDownscaled(m_texRightDown, m_texRightDownW, m_texRightDownH,
                                 split_x, videoW - split_x);
        } else if (m_texRightNearest) {
            rbRenderHalf(m_texRightNearest, videoW, videoH, split_x, videoW - split_x, dst, split_x);
        }
    }
    (void)dstLeftW; (void)dstRightW;

    // 分割线：dst 内对应 split_x 的屏幕位置（仅画在 video area 内）
    if (videoW > 0) {
        float r = static_cast<float>(split_x) / videoW;
        int lineX = dst.x + static_cast<int>(std::round(r * dst.w));
        SDL_SetRenderDrawColor(m_renderer, kColSlider.r, kColSlider.g, kColSlider.b, kColSlider.a);
        SDL_RenderDrawLine(m_renderer, lineX,     dst.y, lineX,     dst.y + dst.h - 1);
        // 加粗一根（旁边再画一像素）
        SDL_RenderDrawLine(m_renderer, lineX + 1, dst.y, lineX + 1, dst.y + dst.h - 1);
    }

    // 左右标签
    if (m_smallFont) {
        const char* lhs = "L";
        const char* rhs = "R";
        int tw = 0, th = 0;
        TTF_SizeUTF8(m_smallFont, lhs, &tw, &th);
        SDL_Rect lbgL = { dst.x + 8, dst.y + 8, tw + 10, th + 6 };
        rbFillRect(lbgL, kColLabelBg);
        rbDrawText(lhs, lbgL.x + 5, lbgL.y + 3, kColText, m_smallFont);

        TTF_SizeUTF8(m_smallFont, rhs, &tw, &th);
        SDL_Rect lbgR = { dst.x + dst.w - tw - 18, dst.y + 8, tw + 10, th + 6 };
        rbFillRect(lbgR, kColLabelBg);
        rbDrawText(rhs, lbgR.x + 5, lbgR.y + 3, kColText, m_smallFont);
    }

    // 控制条
    rbRenderControlBar(mouseX, mouseY);
}

// ─── 控制条 ───────────────────────────────────────────────────────────────────
void RBSliderView::rbRenderControlBar(int mouseX, int mouseY) {
    auto ctrl = rbControlArea();
    rbFillRect(ctrl, kColCtrlBg);

    // 播放按钮（控制左右两路同步：以 left 状态为准）
    auto btn = rbPlayBtnRect();
    bool hover = (mouseX >= btn.x && mouseX < btn.x + btn.w &&
                  mouseY >= btn.y && mouseY < btn.y + btn.h);
    rbFillRect(btn, hover ? kColBtnHover : kColBtn);
    rbDrawRect(btn, {100, 120, 150, 255});

    bool anyPlaying = (m_left && m_left->rbIsPlaying()) || (m_right && m_right->rbIsPlaying());
    bool anyEnded   = (m_left && m_left->rbIsEnded())   && (m_right && m_right->rbIsEnded());
    std::string label = anyPlaying ? "Pause" : (anyEnded ? "Replay" : "Play");
    rbDrawTextCentered(label, btn, kColText, m_smallFont ? m_smallFont : m_font);

    // 进度条
    rbRenderProgressBar(rbProgressRect(), mouseX, mouseY);

    // 时间标签：以 left 为主（同步状态下两路时间相近）
    auto prog = rbProgressRect();
    double cur = m_left ? m_left->rbCurrentTime() : (m_right ? m_right->rbCurrentTime() : 0.0);
    double dur = 0.0;
    if (m_left)  dur = std::max(dur, m_left->rbDuration());
    if (m_right) dur = std::max(dur, m_right->rbDuration());
    std::string ts = rbFormatTime(cur) + " / " + rbFormatTime(dur);
    int pad = rbScaleI(m_dpiScale, kPadLogical);
    int tx = prog.x + prog.w + pad;
    int textH = rbScaleI(m_dpiScale, 14);
    int ty = ctrl.y + (ctrl.h - textH) / 2;
    rbDrawText(ts, tx, ty, kColSubText, m_smallFont ? m_smallFont : m_font);
}

void RBSliderView::rbRenderProgressBar(const SDL_Rect& barRect, int mouseX, int mouseY) {
    if (barRect.w <= 0) return;
    int trackPadV = rbScaleI(m_dpiScale, 6);
    int trackExtH = rbScaleI(m_dpiScale, 12);
    SDL_Rect track = { barRect.x, barRect.y - trackPadV, barRect.w, barRect.h + trackExtH };
    rbFillRect(barRect, kColProgBg);

    double cur = m_left ? m_left->rbCurrentTime() : (m_right ? m_right->rbCurrentTime() : 0.0);
    double dur = 0.0;
    if (m_left)  dur = std::max(dur, m_left->rbDuration());
    if (m_right) dur = std::max(dur, m_right->rbDuration());
    float ratio = (dur > 0) ? static_cast<float>(cur / dur) : 0.0f;
    ratio = std::max(0.0f, std::min(1.0f, ratio));
    SDL_Rect filled = { barRect.x, barRect.y, static_cast<int>(barRect.w * ratio), barRect.h };
    rbFillRect(filled, kColProgFill);

    bool hover = (mouseX >= track.x && mouseX < track.x + track.w &&
                  mouseY >= track.y && mouseY < track.y + track.h);
    if (hover || m_draggingProgress) {
        int knobX = barRect.x + static_cast<int>(barRect.w * ratio);
        int kw  = rbScaleI(m_dpiScale, 12);
        int kpv = rbScaleI(m_dpiScale, 4);
        int kph = rbScaleI(m_dpiScale, 8);
        SDL_Rect knob = { knobX - kw / 2, barRect.y - kpv, kw, barRect.h + kph };
        rbFillRect(knob, kColProgKnob);
    }
}

// ─── 鼠标事件 ─────────────────────────────────────────────────────────────────
void RBSliderView::rbOnMouseMove(int x, int y) {
    m_mouseX = x;
    m_mouseY = y;
    if (m_draggingProgress) {
        auto prog = rbProgressRect();
        if (prog.w > 0) {
            double r = static_cast<double>(x - prog.x) / prog.w;
            r = std::max(0.0, std::min(1.0, r));
            double dur = 0.0;
            if (m_left)  dur = std::max(dur, m_left->rbDuration());
            if (m_right) dur = std::max(dur, m_right->rbDuration());
            double t = r * dur;
            if (m_left)  m_left->rbSeekTo(t);
            if (m_right) m_right->rbSeekTo(t);
        }
    }
}

void RBSliderView::rbOnMouseDown(int x, int y, int clicks) {
    // 播放按钮
    auto btn = rbPlayBtnRect();
    if (x >= btn.x && x < btn.x + btn.w && y >= btn.y && y < btn.y + btn.h) {
        bool anyPlaying = (m_left && m_left->rbIsPlaying()) || (m_right && m_right->rbIsPlaying());
        bool allEnded   = (!m_left || m_left->rbIsEnded()) && (!m_right || m_right->rbIsEnded());
        if (allEnded) {
            if (m_left)  { m_left->rbSeekTo(0.0);  m_left->rbPlay(); }
            if (m_right) { m_right->rbSeekTo(0.0); m_right->rbPlay(); }
        } else if (anyPlaying) {
            if (m_left)  m_left->rbPause();
            if (m_right) m_right->rbPause();
        } else {
            if (m_left)  m_left->rbPlay();
            if (m_right) m_right->rbPlay();
        }
        return;
    }

    // 进度条
    auto prog = rbProgressRect();
    SDL_Rect track = { prog.x, prog.y - 4, prog.w, prog.h + 8 };
    if (x >= track.x && x < track.x + track.w &&
        y >= track.y && y < track.y + track.h && prog.w > 0) {
        m_draggingProgress = true;
        double r = static_cast<double>(x - prog.x) / prog.w;
        r = std::max(0.0, std::min(1.0, r));
        double dur = 0.0;
        if (m_left)  dur = std::max(dur, m_left->rbDuration());
        if (m_right) dur = std::max(dur, m_right->rbDuration());
        double t = r * dur;
        if (m_left)  m_left->rbSeekTo(t);
        if (m_right) m_right->rbSeekTo(t);
        return;
    }

    // 双击视频区域：切换播放/暂停
    auto vid = rbVideoArea();
    if (clicks >= 2 &&
        x >= vid.x && x < vid.x + vid.w &&
        y >= vid.y && y < vid.y + vid.h) {
        bool anyPlaying = (m_left && m_left->rbIsPlaying()) || (m_right && m_right->rbIsPlaying());
        if (anyPlaying) {
            if (m_left)  m_left->rbPause();
            if (m_right) m_right->rbPause();
        } else {
            if (m_left)  m_left->rbPlay();
            if (m_right) m_right->rbPlay();
        }
    }
}

void RBSliderView::rbOnMouseUp(int x, int y) {
    (void)x; (void)y;
    m_draggingProgress = false;
}

// ─── 工具 ─────────────────────────────────────────────────────────────────────
void RBSliderView::rbFillRect(const SDL_Rect& r, SDL_Color c) {
    SDL_SetRenderDrawColor(m_renderer, c.r, c.g, c.b, c.a);
    SDL_SetRenderDrawBlendMode(m_renderer, SDL_BLENDMODE_BLEND);
    SDL_RenderFillRect(m_renderer, &r);
}

void RBSliderView::rbDrawRect(const SDL_Rect& r, SDL_Color c) {
    SDL_SetRenderDrawColor(m_renderer, c.r, c.g, c.b, c.a);
    SDL_RenderDrawRect(m_renderer, &r);
}

void RBSliderView::rbDrawText(const std::string& text, int x, int y, SDL_Color color, TTF_Font* f) {
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

void RBSliderView::rbDrawTextCentered(const std::string& text, const SDL_Rect& area, SDL_Color color, TTF_Font* f) {
    if (!f || text.empty()) return;
    int w = 0, h = 0;
    TTF_SizeUTF8(f, text.c_str(), &w, &h);
    rbDrawText(text, area.x + (area.w - w) / 2, area.y + (area.h - h) / 2, color, f);
}

} // namespace rb
