#pragma once
/**
 * RBFrameOrderMapper.h — 编码顺序 ↔ 显示顺序 映射器（独立模块）
 *
 * 背景：
 *   码流分析中"渲染帧"（RBBlockAnalyzer 解码输出）天然是显示顺序
 *   （解码器对 B 帧做了重排），而"帧统计/GOP 结构"来自包扫描，天然是
 *   编码顺序。B 帧流两者错位，且无法只从包序推断重排结果。
 *
 * 原理（已实测验证）：
 *   FFmpeg 解码输出的 AVFrame::pts 继承自"该帧自身的源 AVPacket"的 pts
 *   （而非触发它输出的包）。因此顺序送包时若人为覆盖
 *   pkt->pts = 包序号，则每个输出帧的 pts 即为它的编码序号。
 *   一次顺序解码即可同时得到：
 *     dispToCode[显示序] = 源包序（编码序）
 *     codeToDisp[编码序] = 显示序
 *     以及每包的真实帧类型（I/P/B，含 parseSlot 无法区分的 B 帧）
 *
 * 隔离性：
 *   - 自带独立的 AVFormatContext / AVCodecContext，不触碰
 *     RBBlockAnalyzer / RBDecoder / 播放管线的任何状态；
 *   - 不修改 FFmpeg 源码；
 *   - 不引入 Qt 类型，可独立编译（与 RBBlockAnalyzer 约束一致）。
 *
 * 耗时：与流长度成正比（纯解码一遍，无 side_data 导出），
 *       必须在后台线程调用。
 */

#include <cstdint>
#include <string>
#include <vector>
#include <atomic>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
}

namespace rb {

class RBFrameOrderMapper {
public:
    struct Result {
        bool ok = false;                 // 映射是否有效（失败时 UI 退化现状）
        int  frameCount = 0;             // 解码输出帧总数（= 显示序总数）
        int  packetCount = 0;            // 视频包总数（= 编码序总数）
        // dispToCode[d] = 显示序 d 的帧来自哪个包（编码序）；-1 表示未知
        std::vector<int> dispToCode;
        // codeToDisp[c] = 编码序 c 的包对应哪个显示序；-1 表示该包无输出帧
        std::vector<int> codeToDisp;
        // 帧类型：0=I（含 IDR，是否 IDR 需结合包 KEY 标志） 1=P 2=B
        std::vector<int> codePictType;   // 按编码序
        std::vector<int> dispPictType;   // 按显示序
    };

    // 顺序解码整个流建立映射。耗时与流长度成正比，应在后台线程调用。
    // 仅对 h264 / hevc / vvc 有效（其它编码无重排意义，返回 ok=false）。
    // cancel：协作式取消检查点（非空且 *cancel==true 时提前返回 ok=false），
    //         用于 slot 释放时快速终止大流整流解码（VVC 可达秒级）。
    static Result build(const std::string& filePath,
                        const std::atomic_bool* cancel = nullptr);
};

} // namespace rb
