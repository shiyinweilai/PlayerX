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
#include <libavutil/codec_block_info.h>
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
        // HEVC：已给 libavcodec/hevc/ 打补丁，在 hls_coding_unit 采集叶子 CU
        // （四叉树，方形 cb_size×cb_size），经 refs.c 导出为 enc_params，
        // 与 VVC 同构，为真实块级划分（非降级）。
        m_blockSupport = true;
        m_granularity  = "块级 (CU 真实划分)";
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

    m_filePath = filePath;
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
    // 启动后台预解码线程：它是唯一持有解码权的线程，从头顺序解码整片，
    // 沿途把每帧块数据（及可选 RGB）入库。主线程/Worker 的 rbBlockInfoAt
    // 只查库 + 条件等待，永不触碰解码器，从根上消除并发崩溃。
    startPrefetch();
    return true;
}

void RBBlockAnalyzer::rbClose() {
    // ★ 必须先停后台线程，再释放它正在使用的解码器/格式上下文，
    //   否则线程仍在 avcodec_receive_frame 中而 ctx 被 free → 野指针崩溃。
    stopPrefetch();

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
    if (m_sws) {
        sws_freeContext(m_sws);
        m_sws = nullptr;
    }
    {
        std::lock_guard<std::mutex> lk(m_onDemandMutex);
        if (m_onDemandSws) {
            sws_freeContext(m_onDemandSws);
            m_onDemandSws = nullptr;
        }
    }
    rbClearCache();
}

void RBBlockAnalyzer::rbClearCache() {
    std::lock_guard<std::mutex> lk(m_storeMutex);
    m_store.clear();
    m_rgbLru.clear();
    m_decodedUpTo = -1;
    m_prefetchDone = false;
}

void RBBlockAnalyzer::releaseFrame(AVFrame*& frame) {
    if (frame) {
        av_frame_free(&frame);
        frame = nullptr;
    }
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

bool RBBlockAnalyzer::extractVvc(AVFrame* frame, RBFrameBlocks& out) {
    // VVC：读取 PlayerX 定制 side data AV_FRAME_DATA_CODEC_BLOCK_INFO
    // 包含真实逐块 QP（Qp''Y）、预测模式、skip_flag
    const AVFrameSideData* sd =
        av_frame_get_side_data(frame, AV_FRAME_DATA_CODEC_BLOCK_INFO);
    if (!sd || sd->size < (int)sizeof(AVCodecBlockInfo)) {
        // 补丁未生效，降级用 enc_params（QP 精度差）
        return extractH264(frame, out);
    }

    const int nb = (int)(sd->size / sizeof(AVCodecBlockInfo));
    const AVCodecBlockInfo* cbi = reinterpret_cast<const AVCodecBlockInfo*>(sd->data);

    out.blocks.clear();
    out.blocks.reserve(nb);

    double qpSum = 0.0;
    int    qpMin = kQpMax, qpMax = kQpMin;

    for (int i = 0; i < nb; ++i) {
        const AVCodecBlockInfo& c = cbi[i];
        RBBlockInfo bi;
        bi.x = c.x; bi.y = c.y;
        bi.w = c.w ? c.w : 64;
        bi.h = c.h ? c.h : 64;
        bi.qp = std::clamp((int)(uint8_t)c.qp, kQpMin, kQpMax);

        // pred_mode: 0=Inter,1=Intra,2=Skip,3=PLT,4=IBC（与 VVC PredMode 对齐）
        bi.isIntra = (c.pred_mode == AV_CB_PRED_INTRA);
        bi.isSkip  = (c.skip_flag != 0) || (c.pred_mode == AV_CB_PRED_SKIP);
        bi.predMode = (int)c.pred_mode;
        bi.predFlag = (int)c.pred_flag;
        bi.refIdx   = (int)c.ref_idx[0];
        bi.refIdxL1 = (int)c.ref_idx[1];
        bi.hasResidual = !bi.isSkip;
        // MV：1/16 像素 → 像素。优先 L0，否则 L1（Bi 时详情卡展示 L0，参考行标 Bi）。
        if (c.pred_flag & AV_CB_PF_L0) {
            bi.mvx = float(c.mv[0][0]) / 16.f;
            bi.mvy = float(c.mv[0][1]) / 16.f;
        } else if (c.pred_flag & AV_CB_PF_L1) {
            bi.mvx = float(c.mv[1][0]) / 16.f;
            bi.mvy = float(c.mv[1][1]) / 16.f;
        } else {
            bi.mvx = bi.mvy = 0.f;
        }

        out.blocks.push_back(bi);

        qpSum += bi.qp;
        qpMin = std::min(qpMin, bi.qp);
        qpMax = std::max(qpMax, bi.qp);
    }

    if (out.blocks.empty()) return false;

    m_granularity = "CU 真实划分";
    out.width  = frame->width;
    out.height = frame->height;
    out.avgQp  = qpSum / (double)out.blocks.size();
    out.minQp  = qpMin;
    out.maxQp  = qpMax;
    out.valid  = true;
    return true;
}

bool RBBlockAnalyzer::extractBlocks(AVFrame* frame, RBFrameBlocks& out) {
    if (!frame) return false;

    bool ok = false;
    if (m_codecId == AV_CODEC_ID_H264)
        ok = extractH264(frame, out);
    else if (m_codecId == AV_CODEC_ID_HEVC)
        ok = extractHevcCtu(frame, out);
    else if (m_codecId == AV_CODEC_ID_VVC)
        ok = extractVvc(frame, out);

    if (!ok) return false;

    // VVC 已从 CODEC_BLOCK_INFO 拿到真实 pred/skip/MV，不再用运动矢量 side data 覆盖。
    // H.264 / HEVC 的 enc_params 不含 MV，再补 AV_FRAME_DATA_MOTION_VECTORS。
    if (m_codecId != AV_CODEC_ID_VVC)
        fillMotionVectors(frame, out);
    return true;
}

const RBFrameBlocks& RBBlockAnalyzer::rbBlockInfoAt(int frameIndex) {
    if (!m_opened || !m_blockSupport || frameIndex < 0) {
        m_emptyResult = RBFrameBlocks{};
        m_emptyResult.frameIndex = frameIndex;
        return m_emptyResult;
    }

    std::unique_lock<std::mutex> lk(m_storeMutex);

    // 命中直接返回；否则等后台解码进度追上该帧（或解码结束/停止）。
    // 后台是顺序解码，UI 无论正序还是编码序跳帧，等的都是"进度到达"，
    // 一次性开销；翻回已解过的帧全部即时命中。
    m_cv.wait(lk, [&]{
        return m_stop
            || m_prefetchDone
            || m_store.find(frameIndex) != m_store.end();
    });

    auto it = m_store.find(frameIndex);
    if (it == m_store.end() || !it->second) {
        // 解码已结束仍无此帧（越界 / 解不出）→ 返回空结果。
        m_emptyResult = RBFrameBlocks{};
        m_emptyResult.frameIndex = frameIndex;
        return m_emptyResult;
    }

    std::shared_ptr<RBFrameBlocks> fb = it->second;

    // 需要画面但该帧尚无 RGB：从缓存 YUV 按需转（只转当前帧，几毫秒）。
    // 后台不再批量转 RGB，播放到哪帧才转哪帧，避免整片 RGB 拖慢后台+爆内存。
    if (m_wantFrameImage && !fb->hasRgb && fb->hasYuv) {
        lk.unlock();                 // 转换耗时，不占 m_storeMutex
        ensureRgbFromYuv(*fb);       // 内部用 m_onDemandMutex 串行化
        lk.lock();
    }

    // 命中：把该帧 RGB 提到 LRU 头部，避免正在查看的帧 RGB 被水位淘汰。
    if (fb->hasRgb) {
        m_rgbLru.remove(frameIndex);
        m_rgbLru.push_front(frameIndex);
        // 淘汰超水位的旧 RGB（YUV 保留，随时可重转）。
        while (static_cast<int>(m_rgbLru.size()) > m_cacheMax) {
            int victim = m_rgbLru.back();
            m_rgbLru.pop_back();
            auto vit = m_store.find(victim);
            if (vit != m_store.end() && vit->second && vit->second->frameIndex != frameIndex) {
                vit->second->rgb.clear();
                vit->second->rgb.shrink_to_fit();
                vit->second->hasRgb = false;
            }
        }
    }

    // shared_ptr 常驻 m_store，解引用得到的引用在本对象生命周期内稳定。
    return *fb;
}

// 从 out 已保存的 YUV 平面按需转出 RGB24（任意线程，独立 sws + 独立锁）。
bool RBBlockAnalyzer::ensureRgbFromYuv(RBFrameBlocks& out) {
    if (!out.hasYuv || out.yuvW <= 0 || out.yuvH <= 0) return false;
    std::lock_guard<std::mutex> lk(m_onDemandMutex);
    if (out.hasRgb) return true;    // 期间被别的线程转好了

    const int w = out.yuvW, h = out.yuvH;
    m_onDemandSws = sws_getCachedContext(
        m_onDemandSws,
        w, h, static_cast<AVPixelFormat>(out.yuvFmt),
        w, h, AV_PIX_FMT_RGB24,
        SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!m_onDemandSws) return false;

    const uint8_t* srcData[4] = {nullptr,nullptr,nullptr,nullptr};
    int            srcStride[4] = {0,0,0,0};
    for (int p = 0; p < out.yuvNumPlanes && p < 4; ++p) {
        srcData[p]   = out.yuv.data() + out.yuvPlaneOff[p];
        srcStride[p] = out.yuvLinesize[p];
    }

    std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3);
    uint8_t* dstData[4]   = { rgb.data(), nullptr, nullptr, nullptr };
    int      dstStride[4] = { w * 3, 0, 0, 0 };

    const int ret = sws_scale(m_onDemandSws, srcData, srcStride, 0, h, dstData, dstStride);
    if (ret <= 0) return false;

    out.rgb       = std::move(rgb);
    out.rgbWidth  = w;
    out.rgbHeight = h;
    out.hasRgb    = true;
    return true;
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

// 把 AVFrame 的 YUV 平面紧凑保存到 out.yuv（后台线程用，仅 memcpy，无缩放/转换）。
// 保存后可由 ensureRgbFromYuv 在任意时刻按需转 RGB，不依赖原 AVFrame。
bool RBBlockAnalyzer::saveYuv(AVFrame* frame, RBFrameBlocks& out) {
    if (!frame || frame->width <= 0 || frame->height <= 0) return false;
    if (frame->format == AV_PIX_FMT_NONE) return false;

    const int w = frame->width;
    const int h = frame->height;
    const AVPixelFormat fmt = static_cast<AVPixelFormat>(frame->format);

    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(fmt);
    if (!desc) return false;

    // 平面数：取非零 linesize 的平面。
    int nb = 0;
    for (int p = 0; p < 4; ++p) if (frame->data[p] && frame->linesize[p]) ++nb;
    if (nb <= 0) return false;

    // 每个平面按其实际宽字节 * 高（考虑色度下采样）紧凑拷贝，行距=平面宽字节。
    int planeH[4]   = {0,0,0,0};
    int planeBpl[4] = {0,0,0,0};   // bytes per line（紧凑后）
    size_t total = 0;
    for (int p = 0; p < nb; ++p) {
        int compH = h;
        int compW = w;
        if (p == 1 || p == 2) {      // 色度平面按 log2 下采样
            compH = (h + (1 << desc->log2_chroma_h) - 1) >> desc->log2_chroma_h;
            compW = (w + (1 << desc->log2_chroma_w) - 1) >> desc->log2_chroma_w;
        }
        // 用 av_image_get_linesize 求该平面每行有效字节数（含高位深 *2）。
        int bpl = av_image_get_linesize(fmt, w, p);
        if (bpl <= 0) bpl = compW;
        planeH[p]   = compH;
        planeBpl[p] = bpl;
        out.yuvPlaneOff[p]  = static_cast<int>(total);
        out.yuvLinesize[p]  = bpl;
        total += static_cast<size_t>(bpl) * compH;
    }

    out.yuv.resize(total);
    for (int p = 0; p < nb; ++p) {
        const uint8_t* src = frame->data[p];
        uint8_t* dst = out.yuv.data() + out.yuvPlaneOff[p];
        const int srcStride = frame->linesize[p];
        const int bpl = planeBpl[p];
        for (int y = 0; y < planeH[p]; ++y)
            memcpy(dst + static_cast<size_t>(bpl) * y,
                   src + static_cast<size_t>(srcStride) * y, bpl);
    }

    out.yuvW = w;
    out.yuvH = h;
    out.yuvFmt = static_cast<int>(fmt);
    out.yuvNumPlanes = nb;
    out.hasYuv = true;
    return true;
}

void RBBlockAnalyzer::startPrefetch() {
    m_stop = false;
    {
        std::lock_guard<std::mutex> lk(m_storeMutex);
        m_decodedUpTo  = -1;
        m_prefetchDone = false;
    }
    if (m_blockSupport)
        m_prefetchThread = std::thread([this]{ prefetchLoop(); });
    else {
        // 不支持块级：直接标记完成，rbBlockInfoAt 会立即返回空结果。
        std::lock_guard<std::mutex> lk(m_storeMutex);
        m_prefetchDone = true;
        m_cv.notify_all();
    }
}

void RBBlockAnalyzer::stopPrefetch() {
    m_stop = true;
    m_cv.notify_all();
    if (m_prefetchThread.joinable())
        m_prefetchThread.join();
}

void RBBlockAnalyzer::prefetchLoop() {
    if (!m_fmt || !m_codecCtx) {
        std::lock_guard<std::mutex> lk(m_storeMutex);
        m_prefetchDone = true;
        m_cv.notify_all();
        return;
    }

    // 从数据起点开始顺序解码。
    // ★ 根因修复：裸流没有索引，rbOpen 的 avformat_find_stream_info 已消耗
    //   文件开头若干包，avio_seek(pb,0) 无法精确回到显示序 0（实测会从前
    //   8 帧之后开始解，m_store 帧号整体偏移，跨 GOP 时画面跳回新 GOP 起点）。
    //   改为重新打开文件，拿全新 demuxer 从显示序 0 开始解码。
    avcodec_flush_buffers(m_codecCtx);
    avformat_close_input(&m_fmt);
    m_fmt = nullptr;
    if (avformat_open_input(&m_fmt, m_filePath.c_str(), nullptr, nullptr) < 0) {
        std::lock_guard<std::mutex> lk(m_storeMutex);
        m_prefetchDone = true;
        m_cv.notify_all();
        return;
    }
    // 重新定位视频流（同一文件索引不变，但重新查更稳）；
    // 无需再 find_stream_info：codec ctx 已建好且参数不变，直接 read_frame 即可。
    m_videoStream = av_find_best_stream(m_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (m_videoStream < 0) {
        std::lock_guard<std::mutex> lk(m_storeMutex);
        m_prefetchDone = true;
        m_cv.notify_all();
        return;
    }

    AVPacket* pkt   = av_packet_alloc();
    AVFrame*  frame = av_frame_alloc();
    int       outIndex = 0;   // 已输出帧计数（= 下一帧的输出序号）

    // 把一帧解码结果提取块数据 + 保存 YUV，入库并唤醒等待者。
    // 不在此批量转 RGB：整片转 RGB 既拖慢后台又爆内存，且绝大多数帧不会被看。
    // RGB 由 rbBlockInfoAt 命中当前帧时从 YUV 按需转（只转要显示的那一帧）。
    auto commitFrame = [&](AVFrame* f) {
        auto fb = std::make_shared<RBFrameBlocks>();
        fb->frameIndex = outIndex;
        extractBlocks(f, *fb);
        if (m_wantFrameImage)
            saveYuv(f, *fb);        // 零转换开销，仅平面 memcpy
        {
            std::lock_guard<std::mutex> lk(m_storeMutex);
            m_store[outIndex] = fb;
            m_decodedUpTo = outIndex;
        }
        m_cv.notify_all();
        ++outIndex;
    };

    // 送一个包，排空其产出的所有帧。
    auto drainAfterSend = [&](AVPacket* p) -> bool {
        int ret = avcodec_send_packet(m_codecCtx, p);
        if (ret == AVERROR(EAGAIN)) {
            // 先排空再重发同一包（FFmpeg 契约，B 帧重排序常见）。
            while (!m_stop) {
                ret = avcodec_receive_frame(m_codecCtx, frame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
                if (ret < 0) break;
                commitFrame(frame);
                av_frame_unref(frame);
            }
            ret = avcodec_send_packet(m_codecCtx, p);
        }
        if (ret < 0 && ret != AVERROR(EAGAIN)) return false;
        while (!m_stop) {
            ret = avcodec_receive_frame(m_codecCtx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;
            commitFrame(frame);
            av_frame_unref(frame);
        }
        return true;
    };

    while (!m_stop && av_read_frame(m_fmt, pkt) >= 0) {
        if (pkt->stream_index != m_videoStream) {
            av_packet_unref(pkt);
            continue;
        }
        drainAfterSend(pkt);
        av_packet_unref(pkt);
    }

    // 排空解码器缓冲的延迟帧（B 帧重排序，末尾约 20 帧压在里面）。
    if (!m_stop) {
        avcodec_send_packet(m_codecCtx, nullptr);
        while (!m_stop) {
            int ret = avcodec_receive_frame(m_codecCtx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;
            commitFrame(frame);
            av_frame_unref(frame);
        }
    }

    av_packet_free(&pkt);
    av_frame_free(&frame);

    {
        std::lock_guard<std::mutex> lk(m_storeMutex);
        // 用真实解码出的帧数校正总帧数（估算值常有偏差）。
        if (outIndex > 0) m_frameCount = outIndex;
        m_prefetchDone = true;
    }
    m_cv.notify_all();
}

} // namespace rb
