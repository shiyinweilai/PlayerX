#pragma once
/**
 * SliderCompareItem.h — 双路视频滑动比较渲染 Item（QML 元素）
 *
 * 设计原则（重点）：
 *   ① 完全独立：与 VideoFrameProvider / RBVideoPlayer / RBPlayerEngine 等核心
 *      模块解耦，不修改任何已有播放控制逻辑。本 Item 仅作为"显示组件"。
 *   ② 纯只读消费：从 EngineBridge::playerAt(leftIndex / rightIndex) 拿到的
 *      RBVideoPlayer，仅调用 rbGetCurrentFrame() / rbWidth() / rbHeight()，
 *      不调用任何 rbPlay / rbPause / rbSeekTo / rbStepFrame —— 播放/快进/快退
 *      /帧步进继续走 Main.qml 现有的 Engine.* 接口，行为与 Grid 模式 100% 一致。
 *   ③ 渲染链路与 VideoFrameProvider 完全一致：
 *        SwsContext(SWS_LANCZOS | SWS_FULL_CHR_H_INT | SWS_ACCURATE_RND)
 *        + rbSwsApplyColorspace（BT.709 / full-range 矩阵）
 *        + 屏幕物理像素 1:1 上屏（关闭 SmoothPixmapTransform）
 *      — 所以不会出现网格伪影，也不会因二次插值导致视频内文字模糊。
 *
 * 使用方式（QML）：
 *   SliderCompareItem {
 *       anchors.fill: parent
 *       engine:      Engine             // EngineBridge 单例
 *       leftIndex:   0                  // 左路 player 索引
 *       rightIndex:  1                  // 右路 player 索引
 *       splitRatio:  0.5                // 分割比例 [0,1]，由外部 MouseArea 跟随鼠标 x 设置
 *   }
 *
 * 实现说明：
 *   - 维护两套 SwsContext（左/右各一份），输入分辨率/格式或目标尺寸变化时重建。
 *   - paint() 流程：
 *       1) 取两路 AVFrame，分别按 视频纵横比 计算各自在 widget 物理像素中的
 *          目标矩形 dstRectL / dstRectR（分别等比缩放居中）。
 *       2) 调用 sws 把每路缩到目标物理像素 RGBA QImage。
 *       3) 按 splitX = round(width * splitRatio * dpr) 把 widget 切两半：
 *          - [0, splitX]            画左路图（仅画与 widget 重叠的子矩形）
 *          - (splitX, areaW]        画右路图
 *       4) 在 splitX 处画一根 1 物理像素白色竖线作为分隔条。
 *   - 接 EngineBridge::requestRepaint 信号触发 update()，与 VideoFrameProvider
 *     使用同样的刷新节拍（Engine 60Hz QTimer）。
 */

#include <QQuickPaintedItem>
#include <QImage>
#include <QPointer>

extern "C" {
#include <libswscale/swscale.h>
#include <libavutil/pixfmt.h>
}

namespace rb {
class RBVideoPlayer;
}

namespace rbqt {

class EngineBridge;

class SliderCompareItem : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QObject* engine     READ engineObject WRITE setEngineObject NOTIFY engineChanged)
    Q_PROPERTY(int      leftIndex  READ leftIndex    WRITE setLeftIndex    NOTIFY leftIndexChanged)
    Q_PROPERTY(int      rightIndex READ rightIndex   WRITE setRightIndex   NOTIFY rightIndexChanged)
    Q_PROPERTY(double   splitRatio READ splitRatio   WRITE setSplitRatio   NOTIFY splitRatioChanged)
    QML_ELEMENT
public:
    explicit SliderCompareItem(QQuickItem* parent = nullptr);
    ~SliderCompareItem() override;

    void paint(QPainter* painter) override;

    QObject* engineObject() const;
    void     setEngineObject(QObject* obj);

    int  leftIndex()  const { return m_leftIndex; }
    void setLeftIndex(int v);
    int  rightIndex() const { return m_rightIndex; }
    void setRightIndex(int v);

    double splitRatio() const { return m_splitRatio; }
    void   setSplitRatio(double r);

signals:
    void engineChanged();
    void leftIndexChanged();
    void rightIndexChanged();
    void splitRatioChanged();

private slots:
    void onEngineRepaint();

private:
    // 单路渲染状态：每路独立的 SwsContext + 已转好的 RGBA 图
    struct Side {
        QImage      image;          // 已 sws 缩到目标物理像素的 RGBA8888
        SwsContext* sws{nullptr};
        int         srcW{0};
        int         srcH{0};
        int         srcFmt{-1};
        int         dstW{0};
        int         dstH{0};
        int         offX{0};        // 在 widget 物理像素坐标系内的左上 X
        int         offY{0};        // 在 widget 物理像素坐标系内的左上 Y
    };

    void rbConvertSide(Side& s, rb::RBVideoPlayer* p, int areaW, int areaH);
    void rbReleaseSws(Side& s);

    QPointer<EngineBridge> m_engine;
    int     m_leftIndex{0};
    int     m_rightIndex{1};
    double  m_splitRatio{0.5};

    Side m_left;
    Side m_right;
};

} // namespace rbqt
