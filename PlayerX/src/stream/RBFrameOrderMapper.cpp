/**
 * RBFrameOrderMapper.cpp — 编码顺序 ↔ 显示顺序 映射器实现
 *
 * 实现要点（与 .h 顶部"原理"一致，已用真实 B 金字塔流实测验证）：
 *   1. 打开独立的 AVFormatContext + AVCodecContext（软解、单线程、
 *      不开 export_side_data，纯解码最快路径）；
 *   2. 顺序读包，人为覆盖 pkt->pts = 视频包序号（编码序）；
 *   3. 收集输出帧：输出序号即显示序 d，帧 pts 即编码序 c，
 *      由此填 dispToCode / codeToDisp / 双序帧类型；
 *   4. EAGAIN 按 FFmpeg 契约处理：先排空再重发同一包（与本仓库
 *      RBBlockAnalyzer 的修复一致，B 帧流无此处理会丢帧）；
 *   5. 尾部 flush 排空重排缓冲。
 *
 * 输出帧 pts == 自身源包序号的依据：libavcodec decode.c 在返回帧时
 * frame->pts 取自该帧对应的 packet（触发输出的是另一个包），实测
 * B 金字塔流（IBBB... 重排 I B B B P...）输出 pts 序列 0,3,2,4,1,...
 * 与包序完全对应。
 */

#include "RBFrameOrderMapper.h"

namespace rb {

RBFrameOrderMapper::Result RBFrameOrderMapper::build(const std::string& filePath,
                                                     const std::atomic_bool* cancel) {
    Result r;

    AVFormatContext* fmt = nullptr;
    if (avformat_open_input(&fmt, filePath.c_str(), nullptr, nullptr) < 0)
        return r;
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        avformat_close_input(&fmt);
        return r;
    }
    const int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (vidx < 0) {
        avformat_close_input(&fmt);
        return r;
    }
    AVStream* vs = fmt->streams[vidx];
    const AVCodecParameters* par = vs->codecpar;
    if (par->codec_id != AV_CODEC_ID_H264 &&
        par->codec_id != AV_CODEC_ID_HEVC &&
        par->codec_id != AV_CODEC_ID_VVC) {
        avformat_close_input(&fmt);
        return r;   // 其它编码无重排意义，UI 保持现状（显示顺序）
    }

    const AVCodec* dec = avcodec_find_decoder(par->codec_id);
    if (!dec) {
        avformat_close_input(&fmt);
        return r;
    }
    AVCodecContext* ctx = avcodec_alloc_context3(dec);
    if (!ctx) {
        avformat_close_input(&fmt);
        return r;
    }
    if (avcodec_parameters_to_context(ctx, par) < 0) {
        avcodec_free_context(&ctx);
        avformat_close_input(&fmt);
        return r;
    }
    ctx->thread_count = 1;   // 单线程：帧 pts 继承才可靠（threading 会改 pkt_dts 语义）
    ctx->export_side_data = 0;   // 不需要 side data，纯解码最快
    if (avcodec_open2(ctx, dec, nullptr) < 0) {
        avcodec_free_context(&ctx);
        avformat_close_input(&fmt);
        return r;
    }

    AVPacket* pkt = av_packet_alloc();
    AVFrame*  frm = av_frame_alloc();

    int pktIdx = 0;   // 视频包序号（编码序）
    int disp   = 0;   // 输出帧序号（显示序）

    auto recordFrame = [&](AVFrame* f) {
        // 帧 pts 即编码序（我们覆盖过 pkt->pts = pktIdx）
        const int code = static_cast<int>(f->pts);
        const int pt   = (f->pict_type == AV_PICTURE_TYPE_I) ? 0
                       : (f->pict_type == AV_PICTURE_TYPE_B) ? 2 : 1;
        // 容量自适应：解码器一般不会输出多于包数的帧，但防御性扩容
        if (static_cast<int>(r.dispToCode.size()) <= disp) {
            r.dispToCode.resize(static_cast<size_t>(disp) * 2 + 16, -1);
            r.dispPictType.resize(static_cast<size_t>(disp) * 2 + 16, -1);
        }
        if (static_cast<int>(r.codeToDisp.size()) <= code) {
            const size_t ns = static_cast<size_t>(code) * 2 + 16;
            r.codeToDisp.resize(ns, -1);
            r.codePictType.resize(ns, -1);
        }
        r.dispToCode[disp]   = code;
        r.dispPictType[disp] = pt;
        if (code >= 0) {
            r.codeToDisp[code]   = disp;
            r.codePictType[code] = pt;
        }
        ++disp;
    };

    while (av_read_frame(fmt, pkt) >= 0) {
        // 协作式取消：slot 释放（freeSlot/closeAll）时提前退出，
        // 避免主线程 waitForFinished 卡住整个流时长。
        if (cancel && cancel->load(std::memory_order_relaxed)) {
            av_packet_unref(pkt);
            avcodec_free_context(&ctx);
            avformat_close_input(&fmt);
            r.ok = false;
            return r;
        }
        if (pkt->stream_index != vidx) {
            av_packet_unref(pkt);
            continue;
        }
        // ★ 核心：pts 覆盖为视频包序号 → 输出帧 pts = 该帧源包的编码序
        pkt->pts = pktIdx;
        pkt->dts = pktIdx;

        int sendRet = avcodec_send_packet(ctx, pkt);
        if (sendRet == AVERROR(EAGAIN)) {
            // FFmpeg 契约：先排空输出再重发同一包（pkt 未被消费）
            while (avcodec_receive_frame(ctx, frm) >= 0) {
                recordFrame(frm);
                av_frame_unref(frm);
            }
            sendRet = avcodec_send_packet(ctx, pkt);
        }
        av_packet_unref(pkt);
        if (sendRet < 0) { ++pktIdx; continue; }
        while (avcodec_receive_frame(ctx, frm) >= 0) {
            recordFrame(frm);
            av_frame_unref(frm);
        }
        ++pktIdx;
    }
    // 尾部 flush：排空重排缓冲（B 帧流尾部还有若干帧未输出）
    avcodec_send_packet(ctx, NULL);
    while (avcodec_receive_frame(ctx, frm) >= 0) {
        recordFrame(frm);
        av_frame_unref(frm);
    }

    // 收尾：截断到实际数量
    r.dispToCode.resize(disp);
    r.dispPictType.resize(disp);
    r.frameCount  = disp;
    r.packetCount = pktIdx;

    // ★ 反查表 codeToDisp 必须由 dispToCode 求逆重建，不能直接用 frame->pts 当
    //   编码序下标。原因：重排延迟下 frame->pts 并不稳定等于该帧源包序号，实测
    //   直接写 codeToDisp[pts]=disp 会与 dispToCode 不自洽——本流表现为
    //   codeToDisp=[0,2,1,3,8,...]（缺 POC 4、多帧塌到同一显示位置），
    //   于是「编码顺序」下 POC 序列变成 0,2,1,3 而非真实的 0,4,2,1,3，
    //   且 decodeIndexOf 非单射 → 画面出现两个 1080-0、层级图跳转错位。
    //   dispToCode 已与 ffmpeg trace_headers 交叉验证为正确，故以其求逆为准。
    r.codeToDisp.assign(size_t(pktIdx), -1);
    r.codePictType.assign(size_t(pktIdx), -1);
    for (int d = 0; d < disp; ++d) {
        const int c = r.dispToCode[d];
        if (c >= 0 && c < pktIdx) {
            r.codeToDisp[size_t(c)]   = d;
            r.codePictType[size_t(c)] = r.dispPictType[size_t(d)];
        }
    }
    r.ok = (disp > 0 && pktIdx > 0 && disp == pktIdx);

    av_packet_free(&pkt);
    av_frame_free(&frm);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    return r;
}

} // namespace rb
