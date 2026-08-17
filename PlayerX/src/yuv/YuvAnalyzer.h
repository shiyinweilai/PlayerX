#pragma once
/**
 * YuvAnalyzer.h — 裸 YUV 文件逐帧分析器（纯 C++，无 Qt 依赖）
 *
 * 职责：
 *   - 直接读取裸 YUV 文件（无容器头），按帧偏移 seek
 *   - 支持多种像素格式：yuv420p / yuv422p / yuv444p / nv12 / nv21
 *   - 提供整帧 RGB 转换（复用 sws_scale）与单平面灰度提取
 *   - 纯数据层，不包含线程 / 队列 / 播放时钟
 *
 * 解码策略：
 *   裸 YUV 全部为 "I 帧"（无帧间依赖），每一帧的字节数由宽高与
 *   像素格式确定 → 任意帧的偏移量 = frameNum * frameSize。
 *   直接 QFile::seek 读取一帧即可，无需 FFmpeg demuxer / decoder。
 */

#include <QString>
#include <QImage>
#include <QFile>
#include <vector>
#include <cstdint>

extern "C" {
#include <libavutil/pixfmt.h>
#include <libavutil/frame.h>
}

struct SwsContext;

namespace rb {

class YuvAnalyzer {
public:
    YuvAnalyzer();
    ~YuvAnalyzer();

    // ── 生命周期 ──────────────────────────────────────────────────────
    // fmt: 像素格式名（"yuv420p", "yuv422p", "yuv444p", "nv12", "nv21"）
    bool open(const QString& path, int width, int height,
              const QString& fmt, double fps);
    void close();
    bool isOpen() const { return m_file.isOpen(); }

    // ── 帧导航 ────────────────────────────────────────────────────────
    bool seekToFrame(int frameNum);
    void nextFrame();
    void prevFrame();

    // ── 查询 ──────────────────────────────────────────────────────────
    int    totalFrames()  const;
    int    currentFrame() const { return m_currentFrame; }
    int    width()        const { return m_width; }
    int    height()       const { return m_height; }
    double fps()          const { return m_fps; }
    QString filePath()    const { return m_filePath; }
    QString pixelFormatName() const { return m_fmtName; }

    // ── 渲染输出 ──────────────────────────────────────────────────────
    // 整帧 YUV→RGB（全彩色，通过 sws_scale）
    QImage getFrameImage();
    // 单平面灰度图（plane: 0=Y, 1=U, 2=V）
    QImage getPlaneImage(int plane);

    // ── 像素级查询 ──────────────────────────────────────────────────────
    // 获取图像坐标 (x, y) 处的 YUV 值，返回 {y, u, v}；越界返回 {-1,-1,-1}
    struct YuvPixel { int y, u, v; };
    YuvPixel getPixelYUV(int x, int y) const;

private:
    void initSwsContext();
    void freeSwsContext();
    void fillSrcFrame();          // 把 m_frameBuf 填入 m_srcFrame 各平面
    bool readCurrentFrame();      // 从文件读当前帧到 m_frameBuf
    int  planeCount() const;      // 根据 m_pixFmt 返回平面数
    void planeSize(int plane, int& pw, int& ph) const;

    QFile          m_file;
    QString        m_filePath;
    int            m_width{0};
    int            m_height{0};
    AVPixelFormat  m_pixFmt;
    QString        m_fmtName;
    double         m_fps{30.0};
    int            m_currentFrame{0};
    int            m_frameSize{0};    // 每帧字节数
    int64_t        m_fileSize{0};

    std::vector<uint8_t> m_frameBuf;

    // sws_scale 上下文（YUV→RGB），仅当 m_width/m_height/m_pixFmt 变化时重建
    SwsContext*   m_swsCtx{nullptr};
    AVFrame*      m_srcFrame{nullptr};  // 指向 m_frameBuf 各平面
    AVFrame*      m_dstFrame{nullptr};  // RGB 输出缓冲区
    int           m_swsW{0};
    int           m_swsH{0};
    AVPixelFormat m_swsFmt;
};

} // namespace rb
