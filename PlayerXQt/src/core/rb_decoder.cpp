#include "rb_decoder.h"
#include "rb_demuxer.h"
#include "rb_frame_queue.h"
#include <iostream>
#include <chrono>
#include <thread>

extern "C" {
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
}

namespace rb {

// ─── 硬件加速像素格式回调 ─────────────────────────────────────────────────────
// 通过 codecCtx->opaque 传递期望的 hw pix_fmt，避免全局变量在多实例/重复 open 时被污染
static AVPixelFormat rbGetHwFormat(AVCodecContext* ctx, const AVPixelFormat* fmts) {
    AVPixelFormat desired = ctx->opaque
        ? *static_cast<AVPixelFormat*>(ctx->opaque)
        : AV_PIX_FMT_NONE;
    for (const AVPixelFormat* p = fmts; *p != AV_PIX_FMT_NONE; ++p) {
        if (*p == desired) return *p;
    }
    return fmts[0];
}

// ═══════════════════════════════════════════════════════════════════════════
// RBDecoder
// ═══════════════════════════════════════════════════════════════════════════

RBDecoder::RBDecoder() = default;

RBDecoder::~RBDecoder() {
    rbClose();
}

bool RBDecoder::rbInit(AVCodecParameters* codecpar, bool hwAccel) {
    rbClose();

    m_codecparCopy = avcodec_parameters_alloc();
    avcodec_parameters_copy(m_codecparCopy, codecpar);
    m_hwAccelEnabled = hwAccel;

    const AVCodec* codec = avcodec_find_decoder(codecpar->codec_id);
    if (!codec) {
        std::cerr << "[RBDecoder] 未找到解码器: " << avcodec_get_name(codecpar->codec_id) << std::endl;
        return false;
    }

    m_codecCtx = avcodec_alloc_context3(codec);
    if (!m_codecCtx) return false;

    if (avcodec_parameters_to_context(m_codecCtx, codecpar) < 0) {
        avcodec_free_context(&m_codecCtx);
        return false;
    }

    // ─── 尝试硬件加速（macOS VideoToolbox）────────────────────────────────
    if (hwAccel) {
        AVHWDeviceType hwType = av_hwdevice_find_type_by_name("videotoolbox");
        if (hwType != AV_HWDEVICE_TYPE_NONE) {
            for (int i = 0; ; ++i) {
                const AVCodecHWConfig* cfg = avcodec_get_hw_config(codec, i);
                if (!cfg) break;
                if (cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX
                    && cfg->device_type == hwType) {
                    m_hwPixFmt = cfg->pix_fmt;
                    break;
                }
            }
            if (m_hwPixFmt != AV_PIX_FMT_NONE) {
                if (av_hwdevice_ctx_create(&m_hwDeviceCtx, hwType, nullptr, nullptr, 0) >= 0) {
                    // 通过 opaque 把期望的 hw pix_fmt 传给回调，不使用全局变量
                    m_codecCtx->opaque        = &m_hwPixFmt;
                    m_codecCtx->hw_device_ctx = av_buffer_ref(m_hwDeviceCtx);
                    m_codecCtx->get_format    = rbGetHwFormat;
                    std::cout << "[RBDecoder] 硬件加速已启用 (VideoToolbox)" << std::endl;
                } else {
                    std::cerr << "[RBDecoder] VideoToolbox 初始化失败，回退软解" << std::endl;
                    m_hwPixFmt = AV_PIX_FMT_NONE;
                }
            }
        }
    }

    if (m_hwPixFmt == AV_PIX_FMT_NONE) {
        m_codecCtx->thread_count = 0;
        m_codecCtx->thread_type  = FF_THREAD_FRAME | FF_THREAD_SLICE;
    }

    if (avcodec_open2(m_codecCtx, codec, nullptr) < 0) {
        std::cerr << "[RBDecoder] 解码器打开失败" << std::endl;
        avcodec_free_context(&m_codecCtx);
        return false;
    }

    return true;
}

void RBDecoder::rbClose() {
    rbStopDecoding();
    if (m_hwDeviceCtx) {
        av_buffer_unref(&m_hwDeviceCtx);
        m_hwDeviceCtx = nullptr;
    }
    if (m_codecCtx) {
        avcodec_free_context(&m_codecCtx);
        m_codecCtx = nullptr;
    }
    if (m_codecparCopy) {
        avcodec_parameters_free(&m_codecparCopy);
        m_codecparCopy = nullptr;
    }
    m_hwPixFmt = AV_PIX_FMT_NONE;
    m_hwAccelEnabled = false;
}

void RBDecoder::rbStartDecoding(RBPacketQueue* pktQueue, RBFrameQueue* frameQueue) {
    if (m_running.load() || !m_codecCtx) return;
    m_running.store(true);
    m_idle.store(false);
    m_decodeThread = std::thread(&RBDecoder::decodeLoop, this, pktQueue, frameQueue);
}

void RBDecoder::rbStopDecoding() {
    m_running.store(false);
    if (m_decodeThread.joinable()) m_decodeThread.join();
}

int RBDecoder::rbWidth()  const { return m_codecCtx ? m_codecCtx->width  : 0; }
int RBDecoder::rbHeight() const { return m_codecCtx ? m_codecCtx->height : 0; }
AVPixelFormat RBDecoder::rbPixFmt() const {
    return m_codecCtx ? m_codecCtx->pix_fmt : AV_PIX_FMT_NONE;
}

void RBDecoder::decodeLoop(RBPacketQueue* pktQueue, RBFrameQueue* frameQueue) {
    AVFrame* frame   = av_frame_alloc();
    AVFrame* swFrame = av_frame_alloc();

    while (m_running.load()) {
        // ── seeking 期间：自己 flush 解码器，然后进入 idle ─────────────────
        // 严格参照 video-compare 的 decode_video()：
        //   检测到 seeking_ 时，flush decoder，设 ready_to_seek，然后 sleep
        if (m_seeking.load()) {
            // 自己 flush 解码器缓冲（此时 pktQueue 已 stopped，无并发访问）
            if (m_codecCtx) {
                avcodec_flush_buffers(m_codecCtx);
            }
            m_idle.store(true);
            while (m_seeking.load() && m_running.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            m_idle.store(false);
            continue;
        }

        // ── 队列 stopped：等待 restart ────────────────────────────────────
        if (pktQueue->isStopped()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        AVPacket* pkt = pktQueue->rbPop();
        if (!pkt) {
            if (m_seeking.load()) continue; // seeking 唤醒，重新循环

            // 真正的 EOF：冲刷解码器
            if (m_codecCtx) avcodec_send_packet(m_codecCtx, nullptr);
            while (m_codecCtx) {
                int ret = avcodec_receive_frame(m_codecCtx, frame);
                if (ret < 0) break;
                AVFrame* out = av_frame_alloc();
                if (frame->format == m_hwPixFmt && m_hwPixFmt != AV_PIX_FMT_NONE) {
                if (av_hwframe_transfer_data(swFrame, frame, 0) >= 0) {
                        // 补全硬件解码后丢失的元数据
                        swFrame->pts                  = frame->pts;
                        swFrame->best_effort_timestamp = frame->best_effort_timestamp;
                        swFrame->pkt_dts              = frame->pkt_dts;
                        swFrame->duration             = frame->duration;
                        swFrame->pict_type            = frame->pict_type;
                        swFrame->flags                = frame->flags; // 含 AV_FRAME_FLAG_KEY
                        av_frame_move_ref(out, swFrame);
                    } else {
                        av_frame_free(&out);
                        continue;
                    }
                } else {
                    av_frame_move_ref(out, frame);
                }
                frameQueue->rbPush(out);
            }
            frameQueue->rbSetEof();
            // 等待 seek 或 stop
            while (m_running.load() && !m_seeking.load() && !pktQueue->isStopped()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            continue;
        }

        if (!m_codecCtx || avcodec_send_packet(m_codecCtx, pkt) < 0) {
            av_packet_free(&pkt);
            continue;
        }
        av_packet_free(&pkt);

        while (m_codecCtx) {
            int ret = avcodec_receive_frame(m_codecCtx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            AVFrame* out = av_frame_alloc();
            if (frame->format == m_hwPixFmt && m_hwPixFmt != AV_PIX_FMT_NONE) {
            if (av_hwframe_transfer_data(swFrame, frame, 0) >= 0) {
                    // 补全硬件解码后丢失的元数据
                    swFrame->pts                  = frame->pts;
                    swFrame->best_effort_timestamp = frame->best_effort_timestamp;
                    swFrame->pkt_dts              = frame->pkt_dts;
                    swFrame->duration             = frame->duration;
                    swFrame->pict_type            = frame->pict_type;
                    swFrame->flags                = frame->flags; // 含 AV_FRAME_FLAG_KEY
                    av_frame_move_ref(out, swFrame);
                } else {
                    av_frame_free(&out);
                    continue;
                }
            } else {
                av_frame_move_ref(out, frame);
            }
            frameQueue->rbPush(out);
        }
    }

    av_frame_free(&frame);
    av_frame_free(&swFrame);
}

} // namespace rb
