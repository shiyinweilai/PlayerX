#include "YuvAnalyzer.h"

#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <algorithm>

extern "C" {
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
}

namespace rb {

static AVPixelFormat parsePixelFormat(const QString& name) {
    const QString n = name.trimmed().toLower();
    // ── 灰度（单平面，只有 Y） ──
    if (n == "yuv400" || n == "gray" || n == "grey" || n == "y8")
        return AV_PIX_FMT_GRAY8;
    // ── Planar YUV ──
    if (n == "yuv420p")  return AV_PIX_FMT_YUV420P;
    if (n == "yuv422p")  return AV_PIX_FMT_YUV422P;
    if (n == "yuv440p")  return AV_PIX_FMT_YUV440P;
    if (n == "yuv444p")  return AV_PIX_FMT_YUV444P;
    // ── 全范围 JPEG-style（BT.601）──
    if (n == "yuvj420p") return AV_PIX_FMT_YUVJ420P;
    if (n == "yuvj422p") return AV_PIX_FMT_YUVJ422P;
    if (n == "yuvj444p") return AV_PIX_FMT_YUVJ444P;
    // ── Semi-planar（UV 交错）──
    if (n == "nv12")     return AV_PIX_FMT_NV12;
    if (n == "nv21")     return AV_PIX_FMT_NV21;
    if (n == "nv16")     return AV_PIX_FMT_NV16;
    if (n == "nv24")     return AV_PIX_FMT_NV24;
    // ── Packed（YUV 交错在单一平面）──
    if (n == "yuyv422" || n == "yuy2")  return AV_PIX_FMT_YUYV422;
    if (n == "uyvy422")                 return AV_PIX_FMT_UYVY422;
    // default
    return AV_PIX_FMT_YUV420P;
}

YuvAnalyzer::YuvAnalyzer()
    : m_pixFmt(AV_PIX_FMT_YUV420P), m_fmtName("yuv420p") {}

YuvAnalyzer::~YuvAnalyzer() {
    close();
}

bool YuvAnalyzer::open(const QString& path, int width, int height,
                        const QString& fmt, double fps) {
    close();

    m_file.setFileName(path);
    if (!m_file.open(QIODevice::ReadOnly)) {
        std::fprintf(stderr, "[YuvAnalyzer] 无法打开文件: %s\n",
                     path.toUtf8().constData());
        return false;
    }

    m_width  = width;
    m_height = height;
    m_pixFmt = parsePixelFormat(fmt);
    m_fmtName = fmt.trimmed().toLower();
    if (m_fmtName.isEmpty()) m_fmtName = "yuv420p";
    m_fps    = (fps > 0.0) ? fps : 30.0;
    m_currentFrame = 0;
    m_filePath = path;

    m_fileSize  = m_file.size();
    m_frameSize = av_image_get_buffer_size(m_pixFmt, m_width, m_height, 1);

    if (m_frameSize <= 0) {
        std::fprintf(stderr, "[YuvAnalyzer] 无法计算帧大小: %dx%d %s\n",
                     m_width, m_height, m_fmtName.toUtf8().constData());
        close();
        return false;
    }

    const int total = totalFrames();
    if (total <= 0 || m_fileSize < static_cast<int64_t>(m_frameSize)) {
        std::fprintf(stderr,
                     "[YuvAnalyzer] 文件太小: fileSize=%lld frameSize=%d totalFrames=%d\n",
                     static_cast<long long>(m_fileSize), m_frameSize, total);
        close();
        return false;
    }

    std::fprintf(stderr,
                 "[YuvAnalyzer] 打开: %s  %dx%d %s  %.1ffps  totalFrames=%d\n",
                 path.toUtf8().constData(), m_width, m_height,
                 m_fmtName.toUtf8().constData(), m_fps, total);

    m_frameBuf.resize(m_frameSize);

    initSwsContext();
    readCurrentFrame();
    fillSrcFrame();

    return true;
}

void YuvAnalyzer::close() {
    freeSwsContext();
    m_file.close();
    m_filePath.clear();
    m_frameBuf.clear();
    m_width  = 0;
    m_height = 0;
    m_currentFrame = 0;
    m_frameSize = 0;
    m_fileSize = 0;
}

bool YuvAnalyzer::seekToFrame(int frameNum) {
    const int total = totalFrames();
    if (total <= 0 || frameNum < 0 || frameNum >= total) return false;

    m_currentFrame = frameNum;
    return readCurrentFrame();
}

void YuvAnalyzer::nextFrame() {
    const int total = totalFrames();
    if (total <= 0) return;
    const int next = m_currentFrame + 1;
    if (next < total) {
        m_currentFrame = next;
        readCurrentFrame();
    }
}

void YuvAnalyzer::prevFrame() {
    const int prev = m_currentFrame - 1;
    if (prev >= 0) {
        m_currentFrame = prev;
        readCurrentFrame();
    }
}

int YuvAnalyzer::totalFrames() const {
    if (m_frameSize <= 0) return 0;
    return static_cast<int>(m_fileSize / m_frameSize);
}

bool YuvAnalyzer::readCurrentFrame() {
    if (!m_file.isOpen() || m_frameSize <= 0) return false;

    const qint64 offset = static_cast<qint64>(m_currentFrame) * m_frameSize;
    if (offset + m_frameSize > m_fileSize) return false;

    if (!m_file.seek(offset)) return false;
    const qint64 read = m_file.read(
        reinterpret_cast<char*>(m_frameBuf.data()), m_frameSize);
    if (read != m_frameSize) return false;

    fillSrcFrame();
    return true;
}

QImage YuvAnalyzer::getFrameImage() {
    if (m_frameBuf.empty() || !m_swsCtx || !m_srcFrame || !m_dstFrame)
        return QImage();

    sws_scale(m_swsCtx,
              m_srcFrame->data, m_srcFrame->linesize,
              0, m_height,
              m_dstFrame->data, m_dstFrame->linesize);

    QImage img(m_width, m_height, QImage::Format_RGBA8888);
    for (int y = 0; y < m_height; ++y) {
        std::memcpy(img.scanLine(y),
                    m_dstFrame->data[0] + y * m_dstFrame->linesize[0],
                    static_cast<size_t>(m_width) * 4);
    }
    return img;
}

QImage YuvAnalyzer::getPlaneImage(int plane) {
    if (m_frameBuf.empty() || !m_srcFrame || plane < 0 || plane >= planeCount())
        return QImage();

    if (m_srcFrame->data[plane] == nullptr) return QImage();

    int pw = 0, ph = 0;
    planeSize(plane, pw, ph);

    const int ls = m_srcFrame->linesize[plane];

    // Y 平面：纯灰度（亮度直观，无需染色）
    if (plane == 0) {
        QImage img(pw, ph, QImage::Format_Grayscale8);
        for (int y = 0; y < ph; ++y) {
            std::memcpy(img.scanLine(y),
                        m_srcFrame->data[0] + y * ls,
                        static_cast<size_t>(pw));
        }
        return img;
    }

    // U / V 平面：染色（仿 YUView / Elecard 风格）
    //   U 平面（Cb）：128=灰, >128→蓝, <128→黄（蓝-黄轴）
    //   V 平面（Cr）：128=灰, >128→红, <128→绿（红-绿轴）
    //   对比度 2× 增强，使细微色差更易观察。
    QImage img(pw, ph, QImage::Format_RGBA8888);
    for (int y = 0; y < ph; ++y) {
        const uint8_t* src = m_srcFrame->data[plane] + y * ls;
        uint8_t*       dst = img.scanLine(y);
        for (int x = 0; x < pw; ++x) {
            const int val  = static_cast<int>(src[x]);
            const int delta = std::clamp((val - 128) * 2, -255, 255);
            int r, g, b;
            if (plane == 1) {
                // U (Cb): blue–yellow axis
                r = std::clamp(128 - delta,     0, 255);
                g = std::clamp(128 - std::abs(delta) / 2, 0, 255);
                b = std::clamp(128 + delta,     0, 255);
            } else {
                // V (Cr): red–green axis
                r = std::clamp(128 + delta,     0, 255);
                g = std::clamp(128 - delta,     0, 255);
                b = std::clamp(128 - std::abs(delta) / 2, 0, 255);
            }
            dst[4*x + 0] = static_cast<uint8_t>(r);
            dst[4*x + 1] = static_cast<uint8_t>(g);
            dst[4*x + 2] = static_cast<uint8_t>(b);
            dst[4*x + 3] = 255;
        }
    }
    return img;
}

// ── 内部 ──────────────────────────────────────────────────────────────

void YuvAnalyzer::initSwsContext() {
    freeSwsContext();

    if (m_width <= 0 || m_height <= 0) return;

    m_srcFrame = av_frame_alloc();
    m_dstFrame = av_frame_alloc();
    if (!m_srcFrame || !m_dstFrame) {
        freeSwsContext();
        return;
    }

    m_dstFrame->width  = m_width;
    m_dstFrame->height = m_height;
    m_dstFrame->format = AV_PIX_FMT_RGBA;
    av_frame_get_buffer(m_dstFrame, 0);

    m_swsCtx = sws_getContext(m_width, m_height, m_pixFmt,
                              m_width, m_height, AV_PIX_FMT_RGBA,
                              SWS_BILINEAR, nullptr, nullptr, nullptr);
    m_swsW   = m_width;
    m_swsH   = m_height;
    m_swsFmt = m_pixFmt;
}

void YuvAnalyzer::freeSwsContext() {
    if (m_swsCtx) { sws_freeContext(m_swsCtx); m_swsCtx = nullptr; }
    if (m_srcFrame) { av_frame_free(&m_srcFrame); }
    if (m_dstFrame) { av_frame_free(&m_dstFrame); }
    m_swsW = m_swsH = 0;
}

void YuvAnalyzer::fillSrcFrame() {
    if (!m_srcFrame || m_frameBuf.empty()) return;

    m_srcFrame->width  = m_width;
    m_srcFrame->height = m_height;
    m_srcFrame->format = m_pixFmt;

    av_image_fill_arrays(m_srcFrame->data, m_srcFrame->linesize,
                         m_frameBuf.data(), m_pixFmt,
                         m_width, m_height, 1);
}

int YuvAnalyzer::planeCount() const {
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(m_pixFmt);
    return desc ? desc->nb_components : 3;
}

void YuvAnalyzer::planeSize(int plane, int& pw, int& ph) const {
    if (!m_srcFrame) { pw = ph = 0; return; }

    // 利用 av_pix_fmt_desc_get 计算各平面尺寸
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(m_pixFmt);
    pw = m_width;
    ph = m_height;
    if (desc) {
        if (plane > 0) {
            pw = (m_width + desc->log2_chroma_w) >> desc->log2_chroma_w;
            // 注意：对于非 subsampled 平面 log2_chroma_w=0，pw 不变
            pw = -((-pw) >> desc->log2_chroma_w);  // 本质还是 pw >> log2
            // 简化：直接使用右移
            pw = m_width >> desc->log2_chroma_w;
            ph = m_height >> desc->log2_chroma_h;
        }
    }
    // 对于 nv12/nv21 的 UV 交错平面（plane=1），宽高各减半
    if (m_pixFmt == AV_PIX_FMT_NV12 || m_pixFmt == AV_PIX_FMT_NV21) {
        if (plane >= 1) {
            pw = m_width;
            ph = m_height / 2;
        }
    }
}

YuvAnalyzer::YuvPixel YuvAnalyzer::getPixelYUV(int x, int y) const {
    if (m_frameBuf.empty() || !m_srcFrame) return {-1, -1, -1};
    if (x < 0 || x >= m_width || y < 0 || y >= m_height) return {-1, -1, -1};

    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(m_pixFmt);
    if (!desc) return {-1, -1, -1};

    // Y 值：直接从 plane 0 读取
    int yVal = 0;
    if (m_srcFrame->data[0]) {
        yVal = m_srcFrame->data[0][y * m_srcFrame->linesize[0] + x];
    }

    // U/V 值：考虑色度下采样
    int uVal = 128, vVal = 128;
    const int chromaW = desc->log2_chroma_w;
    const int chromaH = desc->log2_chroma_h;
    const int cx = x >> chromaW;
    const int cy = y >> chromaH;

    if (m_pixFmt == AV_PIX_FMT_NV12 || m_pixFmt == AV_PIX_FMT_NV21) {
        // Semi-planar: UV 交错在 plane 1
        if (m_srcFrame->data[1]) {
            const int uvOffset = cy * m_srcFrame->linesize[1] + cx * 2;
            if (m_pixFmt == AV_PIX_FMT_NV12) {
                uVal = m_srcFrame->data[1][uvOffset];
                vVal = m_srcFrame->data[1][uvOffset + 1];
            } else { // NV21
                vVal = m_srcFrame->data[1][uvOffset];
                uVal = m_srcFrame->data[1][uvOffset + 1];
            }
        }
    } else if (m_pixFmt == AV_PIX_FMT_YUYV422 || m_pixFmt == AV_PIX_FMT_UYVY422) {
        // Packed: YUYV 或 UYVY
        if (m_srcFrame->data[0]) {
            const int pairX = (x / 2) * 4;
            const uint8_t* row = m_srcFrame->data[0] + y * m_srcFrame->linesize[0];
            if (m_pixFmt == AV_PIX_FMT_YUYV422) {
                uVal = row[pairX + 1];
                vVal = row[pairX + 3];
            } else {
                uVal = row[pairX];
                vVal = row[pairX + 2];
            }
        }
    } else if (m_pixFmt == AV_PIX_FMT_GRAY8) {
        // 灰度：无 U/V
        uVal = 128;
        vVal = 128;
    } else {
        // Planar: U 在 plane 1, V 在 plane 2
        if (m_srcFrame->data[1]) {
            uVal = m_srcFrame->data[1][cy * m_srcFrame->linesize[1] + cx];
        }
        if (m_srcFrame->data[2]) {
            vVal = m_srcFrame->data[2][cy * m_srcFrame->linesize[2] + cx];
        }
    }

    return {yVal, uVal, vVal};
}

} // namespace rb
