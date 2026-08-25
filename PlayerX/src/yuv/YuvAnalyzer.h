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
    // ── 色度插值模式 ──────────────────────────────────────────────────
    // 控制 sws_scale 对 4:2:0/4:2:2 色度平面上采样到 4:4:4 的算法。
    //   NearestNeighbor = SWS_POINT，每个色度像素严格复制，适合像素级分析
    //   Bilinear        = SWS_BILINEAR，双线性插值，适合预览观看
    //   Bicubic         = SWS_BICUBIC，双三次插值，更平滑但计算更重
    enum ChromaInterpolation { NearestNeighbor = 0, Bilinear = 1, Bicubic = 2 };

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

    // ── 色度插值模式 ──────────────────────────────────────────────────
    // 设置 sws_scale 的色度上采样算法；改变后需要重建 sws 上下文。
    // 默认 NearestNeighbor（像素级分析标准）。
    void setChromaInterpolation(ChromaInterpolation mode);
    ChromaInterpolation chromaInterpolation() const { return m_chromaInterp; }

    // ── 像素级查询 ──────────────────────────────────────────────────────
    // 获取图像坐标 (x, y) 处的 YUV 值，返回 {y, u, v}；越界返回 {-1,-1,-1}
    struct YuvPixel { int y, u, v; };
    YuvPixel getPixelYUV(int x, int y) const;

    // ── 直方图统计（当前帧，plane: 0=Y, 1=U, 2=V）────────────────────────
    // 桶数按位深自适应：8bit=256 桶，10bit=1024 桶（高位深时 binCount>256）。
    // 顺带返回 mean / stddev / min / max / variance / range，一次遍历全部算好。
    struct PlaneHistogram {
        std::vector<int> bins;   // 每个值域的像素计数
        double mean     = 0.0;   // 均值
        double stddev   = 0.0;   // 标准差（无偏，整体标准差）
        double variance = 0.0;   // 方差（stddev 的平方）
        int    minVal   = 0;     // 最小值
        int    maxVal   = 0;     // 最大值
        int    range    = 0;     // 极差 = maxVal - minVal
        int    binCount = 0;     // 桶数（256 或 1024）
    };
    PlaneHistogram computeHistogram(int plane) const;

    // ── 梯度与边缘能量统计（当前帧，plane: 0=Y, 1=U, 2=V）───────────────
    // 与 computeHistogram 共用同一帧：直方图与梯度信息各扫一次以保证最佳性能
    // （getPixelYUV 是热点路径，重复访问会拖慢 UI）。建议调用方在帧变化时
    // 一次性拿到 PlaneStats，然后由 UI 自由拆解渲染。
    //
    // 指标含义（参考 H.264/HEVC/VVC 块划分、纹理复杂度、清晰度判定）：
    //   gradHorizMean      水平方向 |I(x)-I(x-1)| 平均值
    //                       —— 评估"水平边缘能量"，HEVC/VVC 决定是否启用水平
    //                          方向非对称划分 / 模式选择的重要依据
    //   gradVertMean       垂直方向 |I(y)-I(y-1)| 平均值
    //   gradDiag45Mean     45°  对角方向 |I(x+1,y+1) - I(x-1,y-1)| 平均值
    //   gradDiag135Mean    135° 对角方向 |I(x-1,y+1) - I(x+1,y-1)| 平均值
    //   gradMean           上述四方向梯度幅值的总平均 = 综合纹理能量
    //                       —— 决定 CU 划分深度/预处理强度的关键参数
    //   laplacianEnergy    4 邻域 Laplacian 能量（|4I-I_up-I_down-I_left-I_right|）
    //                       —— 衡量画面锐利度/对焦质量，类似清晰度评分
    //   tenengrad          Sobel 梯度平方和均值（SobelGx²+Gy² 后取均值）
    //                       —— 经典"纹理复杂度/聚焦评估"指标，编码器在
    //                          qp 决策 / 预处理开关上会引用类似量
    //   sampleCount        实际参与计算的像素数（内部有效像素数）
    struct PlaneStats {
        double mean            = 0.0;   // 均值（冗余：与 PlaneHistogram.mean 一致，方便独立使用）
        double stddev          = 0.0;   // 标准差
        double variance        = 0.0;   // 方差
        int    minVal          = 0;     // 最小值
        int    maxVal          = 0;     // 最大值
        int    range           = 0;     // 极差
        double gradHorizMean   = 0.0;   // 水平梯度幅值均值
        double gradVertMean    = 0.0;   // 垂直梯度幅值均值
        double gradDiag45Mean  = 0.0;   // 45° 对角梯度均值
        double gradDiag135Mean = 0.0;   // 135° 对角梯度均值
        double gradMean        = 0.0;   // 四方向总平均梯度幅值
        double laplacianEnergy = 0.0;   // Laplacian 锐利度能量
        double tenengrad       = 0.0;   // Tenengrad 纹理复杂度
        long long sampleCount  = 0;     // 有效像素数
    };
    PlaneStats computeStats(int plane) const;

    // ── 块级直方图统计（右侧栏"块级别"模式，随鼠标悬浮实时统计）──────────
    // 以 (px, py) 为基准，对齐到 blockSize 的倍数（默认 8×8，与
    // pixelBlock8x8 / pixelBlockStats8x8 的对齐规则保持一致）。
    PlaneHistogram computeBlockHistogram(int plane, int px, int py, int blockSize = 8) const;

    // ── 块级"梯度 / 纹理 / 锐利度"统计（与 computeBlockHistogram 同一块）──
    // 计算范围与 computeBlockHistogram 完全一致：先按 (px/blockSize)*blockSize
    // 对齐到块边界，再扫 [0..blockSize-1]² 像素；返回的 PlaneStats 各字段含义
    // 与 computeStats 相同，区别只在于"扫的是子区域而非整帧"。
    //   - 块太小（< 3×3，无法形成完整 8 邻域）则全部梯度置 0，避免被边界裁剪
    //     的伪梯度污染；sampleCount 反映有效像素数。
    PlaneStats computeBlockStats(int plane, int px, int py, int blockSize = 8) const;

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

    // 色度插值模式（默认 NearestNeighbor）；影响 sws_scale 的 flags
    ChromaInterpolation m_chromaInterp{NearestNeighbor};
};

} // namespace rb
