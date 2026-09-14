/**
 * RBBlockAnalyzer.cpp — 块级深度信息分析器实现（P1 阶段）
 *
 * 核心思路（与 码流分析架构.md §4 的"打补丁"路线对比）：
 *   原始方案要求修改 libavcodec 源码。实际 H.264 已原生支持：
 *   打开解码器时设置 export_side_data |= AV_CODEC_EXPORT_DATA_VIDEO_ENC_PARAMS，
 *   h264dec.c::h264_export_enc_params() 就会把逐宏块 QP 写进
 *   AV_FRAME_DATA_VIDEO_ENC_PARAMS side data，直接读取即可，零补丁。
 *
 * 解码策略：
 *   按需 seek + 顺序解码到目标帧。带"游标"优化：若目标帧恰好是
 *   上一帧的下一帧，直接继续解码，不必重新 seek（翻帧场景最常见）。
 */

#include "RBBlockAnalyzer.h"

#include <algorithm>
#include <cmath>

extern "C" {
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
}

namespace rb {

namespace {

// QP 有效范围（H.264: 0..51；HEVC: 0..51；VVC: 0..63）
constexpr int kQpMin = 0;
constexpr int kQpMax = 63;

} // namespace

RBBlockAnalyzer::RBBlockAnalyzer() = default;

RBBlockAnalyzer::~RBBlockAnalyzer() {
    rbClose();
}

bool RBBlockAnalyzer::openDecoder() {
    if (m_videoStream < 0) return false;

    AVStream* vs = m_fmt->streams[m_videoStream];
    const AVCodec* dec = avcodec_find_decoder(vs->codecpar->codec_id);
    if (!dec) return false;

    m_codecCtx = avcodec_alloc_context3(dec);
    if (!m_codecCtx) return false;

    if (avcodec_parameters_to_context(m_codecCtx, vs->codecpar) < 0) {
        avcodec_free_context(&m_codecCtx);
        return false;
    }

    // ★ P1 关键：启用块级编码参数导出。
    //   对 H.264，这会触发 h264dec.c 的 h264_export_enc_params()，
    //   在每帧 AVFrame 上挂 AVVideoEncParams（含逐宏块 QP）。
    m_codecCtx->export_side_data |= AV_CODEC_EXPORT_DATA_VIDEO_ENC_PARAMS;
    // ★ 图2 需要 MV / 参考索引：启用运动矢量导出（AV_FRAME_DATA_MOTION_VECTORS）。
    //   H.264 的 enc_params 不含 MV，MV 单独走 motion vectors 侧数据。
    m_codecCtx->export_side_data |= AV_CODEC_EXPORT_DATA_MVS;

    // 强制软解：硬件解码（VideoToolbox 等）不会产出 enc_params side data，
    // 且块级分析对性能不敏感，软解反而保证数据可用。
    m_codecCtx->thread_count = 1;

    if (avcodec_open2(m_codecCtx, dec, nullptr) < 0) {
        avcodec_free_context(&m_codecCtx);
        return false;
    }

    m_codecId = vs->codecpar->codec_id;
    m_width   = m_codecCtx->width;
    m_height  = m_codecCtx->height;

    // 帧数估算：优先用 stream 的 nb_frames，否则按时长×帧率推
    if (vs->nb_frames > 0) {
        m_frameCount = static_cast<int>(vs->nb_frames);
    } else {
        double fps = 0.0;
        if (vs->avg_frame_rate.den > 0)
            fps = av_q2d(vs->avg_frame_rate);
        double dur = (m_fmt->duration > 0)
                     ? static_cast<double>(m_fmt->duration) / AV_TIME_BASE
                     : 0.0;
        m_frameCount = (fps > 0 && dur > 0)
                       ? static_cast<int>(std::llround(fps * dur)) : 0;
    }

    // 块级支持判定
    switch (m_codecId) {
    case AV_CODEC_ID_H264:
        m_blockSupport = true;
        m_granularity  = "宏块级 (16×16)";
        break;
    case AV_CODEC_ID_HEVC:
        // HEVC 原生未导出 enc_params；一期走 CTU 降级（需 qp_y_tab 可访问）。
        // 若补丁未就绪，extractHevcCtu 会返回 false，UI 自动降级。
        m_blockSupport = true;
        m_granularity  = "CTU级 (64×64, 降级)";
        break;
    case AV_CODEC_ID_VVC:
        // VVC（H.266）：已给 libavcodec/vvc/refs.c 打补丁，
        // 导出真实 CU 划分（CTU 内四叉树+MTT 递归划分，含非方形），
        // 精度同 H.264 补丁，为块级（非降级）。
        m_blockSupport = true;
        m_granularity  = "块级 (CU 真实划分)";
        break;
    default:
        // VVC / AV1 等：FFmpeg 侧暂无对应导出，暂不支持
        m_blockSupport = false;
        m_granularity  = "不支持";
        break;
    }

    return true;
}

bool RBBlockAnalyzer::rbOpen(const std::string& filePath) {
    rbClose();

    if (avformat_open_input(&m_fmt, filePath.c_str(), nullptr, nullptr) < 0) {
        m_fmt = nullptr;
        return false;
    }
    if (avformat_find_stream_info(m_fmt, nullptr) < 0) {
        avformat_close_input(&m_fmt);
        m_fmt = nullptr;
        return false;
    }

    m_videoStream = av_find_best_stream(m_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (m_videoStream < 0) {
        avformat_close_input(&m_fmt);
        m_fmt = nullptr;
        return false;
    }

    if (!openDecoder()) {
        avformat_close_input(&m_fmt);
        m_fmt = nullptr;
        return false;
    }

    m_opened     = true;
    m_cursorFrame = -1;
    return true;
}

void RBBlockAnalyzer::rbClose() {
    if (m_codecCtx) {
        avcodec_free_context(&m_codecCtx);
        m_codecCtx = nullptr;
    }
    if (m_fmt) {
        avformat_close_input(&m_fmt);
        m_fmt = nullptr;
    }
    m_opened = false;
    m_blockSupport = false;
    m_videoStream = -1;
    m_cursorFrame = -1;
    if (m_sws) {
        sws_freeContext(m_sws);
        m_sws = nullptr;
    }
    rbClearCache();
}

void RBBlockAnalyzer::rbClearCache() {
    m_cacheMap.clear();
    m_cacheList.clear();
}

void RBBlockAnalyzer::releaseFrame(AVFrame*& frame) {
    if (frame) {
        av_frame_free(&frame);
        frame = nullptr;
    }
}

AVFrame* RBBlockAnalyzer::decodeFrameAt(int frameIndex) {
    if (!m_opened || !m_codecCtx) return nullptr;

    // 游标优化：目标帧 = 上一帧 +1，直接继续解码
    bool needSeek = true;
    if (m_cursorFrame >= 0 && frameIndex == m_cursorFrame + 1) {
        needSeek = false;
    }

    if (needSeek) {
        avcodec_flush_buffers(m_codecCtx);
        // 按帧号换算时间戳；对裸流（无时间戳）退化为按字节 seek 不准，
        // 故裸流场景统一从 0 顺序解码到目标帧（帧数一般可控）。
        AVStream* vs = m_fmt->streams[m_videoStream];
        if (vs->avg_frame_rate.den > 0 && m_fmt->duration > 0) {
            double fps = av_q2d(vs->avg_frame_rate);
            int64_t ts = static_cast<int64_t>(frameIndex / fps * AV_TIME_BASE);
            int64_t seekTs = av_rescale_q(ts, AV_TIME_BASE_Q, vs->time_base);
            // 往前多退一点，确保目标帧是完整可解码的（seek 到关键帧）
            if (av_seek_frame(m_fmt, m_videoStream, seekTs, AVSEEK_FLAG_BACKWARD) < 0) {
                // seek 失败：退回从头顺序解码
                av_seek_frame(m_fmt, m_videoStream, 0, AVSEEK_FLAG_BYTE);
            }
        } else {
            av_seek_frame(m_fmt, m_videoStream, 0, AVSEEK_FLAG_BYTE);
        }
        m_cursorFrame = -1;
    }

    AVPacket* pkt = av_packet_alloc();
    AVFrame*  frame = av_frame_alloc();
    AVFrame*  result = nullptr;
    int       decodedCount = 0;

    // 起始解码序号：seek 后按实际解码计数逼近目标帧
    int baseCount = (m_cursorFrame >= 0) ? (m_cursorFrame + 1) : 0;

    while (av_read_frame(m_fmt, pkt) >= 0) {
        if (pkt->stream_index != m_videoStream) {
            av_packet_unref(pkt);
            continue;
        }
        int ret = avcodec_send_packet(m_codecCtx, pkt);
        av_packet_unref(pkt);
        if (ret < 0) continue;

        while (true) {
            ret = avcodec_receive_frame(m_codecCtx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            const int cur = baseCount + decodedCount;
            if (cur == frameIndex) {
                result = av_frame_alloc();
                av_frame_ref(result, frame);
                m_cursorFrame = frameIndex;
                av_frame_unref(frame);
                goto done;
            }
            if (cur > frameIndex) {
                // 越过目标帧：放弃（理论上 seek 到前一关键帧不会出现）
                av_frame_unref(frame);
                goto done;
            }
            ++decodedCount;
            av_frame_unref(frame);
        }
    }

done:
    av_packet_free(&pkt);
    av_frame_free(&frame);
    return result;
}

bool RBBlockAnalyzer::extractH264(AVFrame* frame, RBFrameBlocks& out) {
    // H.264：读取 AV_FRAME_DATA_VIDEO_ENC_PARAMS side data
    //   par->qp         —— 帧级基准 QP（pps.init_qp）
    //   b->delta_qp     —— 该块相对基准的偏移
    //   b->src_x/y,w,h  —— 块位置与尺寸
    //
    // ★ PlayerX 定制：FFmpeg 的 h264_export_enc_params() 已改为按真实
    //   mb_type 展开宏块子划分（16x16 / 16x8 / 8x16 / 8x8），
    //   所以这里 b->w / b->h 不再是固定 16，而是真实 CU 划分尺寸。
    //   本函数原样透传 w/h，UI 即可画出非均匀的真实划分网格。
    const AVFrameSideData* sd =
        av_frame_get_side_data(frame, AV_FRAME_DATA_VIDEO_ENC_PARAMS);
    if (!sd || sd->size < static_cast<int>(sizeof(AVVideoEncParams))) return false;

    const AVVideoEncParams* par =
        reinterpret_cast<const AVVideoEncParams*>(sd->data);
    if (par->type != AV_VIDEO_ENC_PARAMS_H264) return false;
    if (par->nb_blocks <= 0) return false;

    out.blocks.clear();
    out.blocks.reserve(par->nb_blocks);

    double qpSum = 0.0;
    int    qpMin = kQpMax, qpMax = kQpMin;
    // 统计各尺寸出现次数，用于生成"真实划分"精度描述
    int cnt16x16 = 0, cnt16x8 = 0, cnt8x16 = 0, cnt8x8 = 0;
    int cnt8x4 = 0, cnt4x8 = 0, cnt4x4 = 0, cntOther = 0;

    for (unsigned int i = 0; i < par->nb_blocks; ++i) {
        const AVVideoBlockParams* b = av_video_enc_params_block(
            const_cast<AVVideoEncParams*>(par), i);
        if (!b) continue;

        // 实际 QP = 帧级基准 + 该块 delta（饱和到有效范围）
        int qp = par->qp + b->delta_qp;
        qp = std::clamp(qp, kQpMin, kQpMax);

        RBBlockInfo bi;
        bi.x  = b->src_x;
        bi.y  = b->src_y;
        // 尺寸无关透传：不再假设 H.264 的 16x16 上限。
        // w/h 为 0 仅作防御性回退（异常块），正常由解码器给出真实尺寸，
        // 未来 HEVC 的 32x32 / 64x64 CTU 也会原样透传到 UI。
        bi.w  = b->w;
        bi.h  = b->h;
        bi.qp = qp;
        // MV / 帧内帧间由后续 fillMotionVectors() 修正
        bi.isSkip  = false;
        bi.isIntra = true;
        bi.mvx = bi.mvy = 0.f;
        out.blocks.push_back(bi);

        // 尺寸分布统计（含帧内 4x4、帧间 8x4/4x8 子宏块划分）
        // H.264 宏块上限 16x16；此处按真实尺寸分类，更大尺寸（如 HEVC CTU）
        // 会落入"其它"，保证扩展时不会漏统计。
        if      (bi.w == 16 && bi.h == 16) ++cnt16x16;
        else if (bi.w == 16 && bi.h == 8)  ++cnt16x8;
        else if (bi.w == 8  && bi.h == 16) ++cnt8x16;
        else if (bi.w == 8  && bi.h == 8)  ++cnt8x8;
        else if (bi.w == 8  && bi.h == 4)  ++cnt8x4;
        else if (bi.w == 4  && bi.h == 8)  ++cnt4x8;
        else if (bi.w == 4  && bi.h == 4)  ++cnt4x4;
        else                               ++cntOther;

        qpSum += qp;
        qpMin = std::min(qpMin, qp);
        qpMax = std::max(qpMax, qp);
    }

    if (out.blocks.empty()) return false;

    // 生成真实划分描述：列出实际用到的块尺寸（如"真实划分 16×16 / 8×8"）
    {
        std::string parts;
        auto add = [&parts](const char* s) {
            if (!parts.empty()) parts += " / ";
            parts += s;
        };
        if (cnt16x16) add("16×16");
        if (cnt16x8)  add("16×8");
        if (cnt8x16)  add("8×16");
        if (cnt8x8)   add("8×8");
        if (cnt8x4)   add("8×4");
        if (cnt4x8)   add("4×8");
        if (cnt4x4)   add("4×4");
        if (cntOther) add("其它");
        m_granularity = parts.empty() ? "真实划分"
                                      : ("真实划分 " + parts);
    }

    out.width  = frame->width;
    out.height = frame->height;
    out.avgQp  = qpSum / static_cast<double>(out.blocks.size());
    out.minQp  = qpMin;
    out.maxQp  = qpMax;
    out.valid  = true;
    return true;
}

bool RBBlockAnalyzer::extractHevcCtu(AVFrame* frame, RBFrameBlocks& out) {
    // HEVC 降级方案：FFmpeg 原生未导出 HEVC 的 enc_params。
    // 完整实现需给 hevcdec.c 打补丁导出 qp_y_tab + tab_mvf（见 §4）。
    // 一期：若上游补丁已合入并产出了 H264 同款 side data（type=HEVC），
    // 这里复用同一解析逻辑；否则返回 false，由 UI 降级提示。
    const AVFrameSideData* sd =
        av_frame_get_side_data(frame, AV_FRAME_DATA_VIDEO_ENC_PARAMS);
    if (!sd || sd->size < static_cast<int>(sizeof(AVVideoEncParams))) return false;

    const AVVideoEncParams* par =
        reinterpret_cast<const AVVideoEncParams*>(sd->data);
    // HEVC 补丁若导出，会用 AV_VIDEO_ENC_PARAMS_HEVC（上游预留）
    if (par->nb_blocks <= 0) return false;

    out.blocks.clear();
    out.blocks.reserve(par->nb_blocks);

    double qpSum = 0.0;
    int    qpMin = kQpMax, qpMax = kQpMin;

    for (unsigned int i = 0; i < par->nb_blocks; ++i) {
        const AVVideoBlockParams* b = av_video_enc_params_block(
            const_cast<AVVideoEncParams*>(par), i);
        if (!b) continue;

        int qp = std::clamp(par->qp + b->delta_qp, kQpMin, kQpMax);
        RBBlockInfo bi;
        bi.x = b->src_x; bi.y = b->src_y;
        bi.w = b->w ? b->w : 64;
        bi.h = b->h ? b->h : 64;
        bi.qp = qp;
        bi.isSkip = false;
        bi.isIntra = true;
        bi.mvx = bi.mvy = 0.f;
        out.blocks.push_back(bi);

        qpSum += qp;
        qpMin = std::min(qpMin, qp);
        qpMax = std::max(qpMax, qp);
    }

    if (out.blocks.empty()) return false;

    out.width  = frame->width;
    out.height = frame->height;
    out.avgQp  = qpSum / static_cast<double>(out.blocks.size());
    out.minQp  = qpMin;
    out.maxQp  = qpMax;
    out.valid  = true;
    return true;
}

void RBBlockAnalyzer::fillMotionVectors(AVFrame* frame, RBFrameBlocks& out) {
    // 从 AV_FRAME_DATA_MOTION_VECTORS 提取 MV，按"块中心落在哪个 MV 区域内"匹配。
    // AVMotionVector 的粒度通常比宏块更细（4x4 或 8x8），这里取块中心命中，
    // 并用 dst 坐标判断是否被参考（motion_direction: 0=前向）。
    const AVFrameSideData* sd =
        av_frame_get_side_data(frame, AV_FRAME_DATA_MOTION_VECTORS);
    if (!sd || sd->size <= 0) return;

    const AVMotionVector* mvs =
        reinterpret_cast<const AVMotionVector*>(sd->data);
    const int nb = sd->size / static_cast<int>(sizeof(AVMotionVector));
    if (nb <= 0) return;

    for (auto& bi : out.blocks) {
        // 块中心（像素坐标）
        const int cx = bi.x + bi.w / 2;
        const int cy = bi.y + bi.h / 2;

        float sx = 0.f, sy = 0.f;
        int   hits = 0;
        int   refIdxFound = -1;

        for (int i = 0; i < nb; ++i) {
            const AVMotionVector& mv = mvs[i];
            // 只统计前向（dst 属于当前帧、src 为参考）
            if (mv.dst_x <= cx && cx < mv.dst_x + mv.w &&
                mv.dst_y <= cy && cy < mv.dst_y + mv.h) {
                // 优先用 motion_x/motion_y（已按 motion_scale 归一化的真实矢量）
                if (mv.motion_scale > 0) {
                    sx += static_cast<float>(mv.motion_x) / static_cast<float>(mv.motion_scale);
                    sy += static_cast<float>(mv.motion_y) / static_cast<float>(mv.motion_scale);
                } else {
                    sx += static_cast<float>(mv.src_x - mv.dst_x);
                    sy += static_cast<float>(mv.src_y - mv.dst_y);
                }
                // source：负数=来自过去（前向参考），正数=来自未来（后向）
                if (refIdxFound < 0) refIdxFound = (mv.source < 0) ? 0 : 1;
                ++hits;
            }
        }

        if (hits > 0) {
            bi.mvx = sx / static_cast<float>(hits);
            bi.mvy = sy / static_cast<float>(hits);
            // refIdxFound: 0=前向(L0), 1=后向(L1)
            bi.refIdx = (refIdxFound >= 0) ? refIdxFound : 0;
            // 有 MV → 帧间块
            bi.isIntra = false;
            bi.predMode = (bi.refIdx == 1) ? 2 : 1;   // 2=B_L0L1, 1=P_L0
            bi.hasResidual = true;                     // 帧间块通常有残差
        } else {
            // 无 MV → 帧内块（I 帧或帧内预测宏块）
            bi.isIntra = true;
            bi.mvx = bi.mvy = 0.f;
            bi.predMode = 0;                    // Intra
            bi.refIdx = 0;
            bi.hasResidual = true;
        }
    }
}

bool RBBlockAnalyzer::extractBlocks(AVFrame* frame, RBFrameBlocks& out) {
    if (!frame) return false;

    bool ok = false;
    if (m_codecId == AV_CODEC_ID_H264)
        ok = extractH264(frame, out);
    else if (m_codecId == AV_CODEC_ID_HEVC)
        ok = extractHevcCtu(frame, out);
    else if (m_codecId == AV_CODEC_ID_VVC)
        // VVC 补丁导出的 side data 与 H.264 完全同构
        // （AV_FRAME_DATA_VIDEO_ENC_PARAMS + AVVideoBlockParams），
        // 且块坐标/尺寸已是真实 CU，直接复用同一提取函数。
        ok = extractH264(frame, out);

    if (!ok) return false;

    // 块级 QP/CU 拿到后，再补充 MV / 参考索引 / 预测模式（图2 详情需要）
    fillMotionVectors(frame, out);
    return true;
}

const RBFrameBlocks& RBBlockAnalyzer::rbBlockInfoAt(int frameIndex) {
    // 缓存命中：移到 LRU 头部
    auto it = m_cacheMap.find(frameIndex);
    if (it != m_cacheMap.end()) {
        m_cacheList.splice(m_cacheList.begin(), m_cacheList, it->second);
        return it->second->second;
    }

    // 未命中：解码 + 提取
    RBFrameBlocks result;
    result.frameIndex = frameIndex;

    if (m_opened && m_blockSupport && frameIndex >= 0) {
        // 加锁：解码器非线程安全，异步播放线程可能与本线程并发解码
        std::lock_guard<std::mutex> lk(m_codecMutex);
        AVFrame* frame = decodeFrameAt(frameIndex);
        if (frame) {
            extractBlocks(frame, result);
            // 需要底层原始画面时，顺带转成 RGB24 缓存（CU 网格叠加在真实画面上）
            if (m_wantFrameImage)
                convertToRgb(frame, result);
            releaseFrame(frame);
        }
    }

    // 写入 LRU
    m_cacheList.push_front(std::make_pair(frameIndex, std::move(result)));
    m_cacheMap[frameIndex] = m_cacheList.begin();

    // 淘汰超出容量的最久未用项
    while (static_cast<int>(m_cacheList.size()) > m_cacheMax) {
        auto last = std::prev(m_cacheList.end());
        m_cacheMap.erase(last->first);
        m_cacheList.pop_back();
    }

    return m_cacheList.begin()->second;
}

bool RBBlockAnalyzer::convertToRgb(AVFrame* frame, RBFrameBlocks& out) {
    if (!frame || frame->width <= 0 || frame->height <= 0) return false;
    if (frame->format == AV_PIX_FMT_NONE) return false;

    const int w = frame->width;
    const int h = frame->height;

    // 复用 swscale 上下文（尺寸/格式变化时重建）
    m_sws = sws_getCachedContext(
        m_sws,
        w, h, static_cast<AVPixelFormat>(frame->format),
        w, h, AV_PIX_FMT_RGB24,
        SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!m_sws) return false;

    out.rgb.resize(static_cast<size_t>(w) * h * 3);

    uint8_t* dstData[4] = { out.rgb.data(), nullptr, nullptr, nullptr };
    int      dstStride[4] = { w * 3, 0, 0, 0 };

    const int ret = sws_scale(m_sws,
                              frame->data, frame->linesize,
                              0, h,
                              dstData, dstStride);
    if (ret <= 0) {
        out.rgb.clear();
        return false;
    }

    out.rgbWidth  = w;
    out.rgbHeight = h;
    out.hasRgb    = true;
    return true;
}

} // namespace rb
