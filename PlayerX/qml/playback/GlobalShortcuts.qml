import QtQuick
import QtQuick.Controls
import QtQuick.Window
import PlayerX 1.0
import "../common/MainLogic.js" as Logic
import "RatingLogic.js" as RatingLogic

Item {
    id: globalShortcuts
    property var root: null
    property var multiGroupDialog: null
    property var ratingToast: null

    // 【与铃铛同一根因】RatingLogic.js 同样没有 `.pragma library`，本文件
    // `import "RatingLogic.js" as RatingLogic` 拿到的是独立于 Main.qml 的
    // 一份模块状态副本，从未被 _initRating() 初始化过。数字键 1-9 打分 /
    // [ ] 清除评分 / 对比滑块切换等全局快捷键因此在 Windows 上很可能同样
    // 处于"写入一个空对象，UI 无变化"的失效状态。这里补一次初始化修复。
    Component.onCompleted: {
        RatingLogic._initRating({
            root: root,
            multiGroupDialog: multiGroupDialog,
            ratingsDialog: null,
            ratingToast: ratingToast
        })
        console.log("[TaskUpdate] GlobalShortcuts 自身的 RatingLogic.js 模块副本已初始化")
    }
// ─── 全局快捷键（ApplicationShortcut，与焦点无关）────────────────────
// 用 Shortcut 而非 Keys.onPressed，避免焦点跑到 ToolBar/Slider/ComboBox
// 后空格、左右键等"全局控制"快捷键失效。
Shortcut {
    sequence: "Space"; context: Qt.ApplicationShortcut
    onActivated: {
        // YUV 分析 tab：空格 = 播放/暂停所有已打开的 YUV slot（用 YuvBridge，不是 Engine）
        if (root.currentTab === "yuv") {
            const n = YuvBridge.slotCount
            for (let i = 0; i < n; ++i) YuvBridge.togglePlayPause(i)
            return
        }
        Engine.togglePause()
    }
}
// V：切换全局显示视频信息。全屏抑制状下会先清抑制再强制显示。
Shortcut {
    sequence: "V"; context: Qt.ApplicationShortcut
    onActivated: {
        if (root.fullscreenSuppressInfo) {
            root.fullscreenSuppressInfo = false
            root.globalInfoVisible = true
        } else {
            root.globalInfoVisible = !root.globalInfoVisible
        }
    }
}
// C：切换全局通道信息（序号+文件名）。全屏抑制状下会先清抑制再强制显示。
Shortcut {
    sequence: "C"; context: Qt.ApplicationShortcut
    onActivated: {
        if (root.fullscreenSuppressChannel) {
            root.fullscreenSuppressChannel = false
            root.globalChannelVisible = true
        } else {
            root.globalChannelVisible = !root.globalChannelVisible
        }
    }
}
Shortcut {
    sequence: "Left"; context: Qt.ApplicationShortcut
    // 首帧守卫（即时判定）：与工具栏 `<<` 按钮语义一致。
    onActivated: {
        // YUV 分析 tab：左键 = 单帧快退所有 slot
        if (root.currentTab === "yuv") {
            const n = YuvBridge.slotCount
            for (let i = 0; i < n; ++i) YuvBridge.prevFrame(i)
            return
        }
        if (Logic._isAtFirstFrameNow()) return
        Engine.seek(Math.max(0, Engine.position - 5))
    }
}
Shortcut {
    sequence: "Right"; context: Qt.ApplicationShortcut
    // 末帧守卫（即时判定）：与工具栏 `>>` 按钮语义一致。
    onActivated: {
        // YUV 分析 tab：右键 = 单帧快进所有 slot
        if (root.currentTab === "yuv") {
            const n = YuvBridge.slotCount
            for (let i = 0; i < n; ++i) YuvBridge.nextFrame(i)
            return
        }
        if (Logic._isAtLastFrameNow()) return
        Engine.seek(Math.min(Engine.duration, Engine.position + 5))
    }
}
// YUV 分析专用：上/下键 = 15 帧快进/快退（仅 yuv tab 生效，避免与播放 tab 冲突）
Shortcut {
    sequence: "Up"; context: Qt.ApplicationShortcut
    enabled: root.currentTab === "yuv"
    onActivated: {
        const n = YuvBridge.slotCount
        for (let i = 0; i < n; ++i) YuvBridge.skipForward(i, 15)
    }
}
Shortcut {
    sequence: "Down"; context: Qt.ApplicationShortcut
    enabled: root.currentTab === "yuv"
    onActivated: {
        const n = YuvBridge.slotCount
        for (let i = 0; i < n; ++i) YuvBridge.skipBackward(i, 15)
    }
}
Shortcut {
    sequence: ","; context: Qt.ApplicationShortcut
    // 上一帧：首帧守卫，避免解码器空跑
    onActivated: {
        if (Logic._isAtFirstFrameNow()) return
        Engine.stepFrame(-1)
    }
}
Shortcut {
    sequence: "."; context: Qt.ApplicationShortcut
    // 下一帧：末帧守卫，避免解码器空跑
    onActivated: {
        if (Logic._isAtLastFrameNow()) return
        Engine.stepFrame(1)
    }
}
Shortcut {
    sequence: "F"; context: Qt.ApplicationShortcut
    onActivated: {
        var goingFullscreen = (root.visibility !== Window.FullScreen)
        root.visibility = goingFullscreen
            ? Window.FullScreen : Window.AutomaticVisibility
        // 进入全屏：默认抑制 V/C 的叠加显示，但保留开关本身的值，
        // 用户可以再按 V/C 售起。退出全屏：清除抑制，恢复平常表现。
        if (goingFullscreen) {
            root.fullscreenSuppressInfo    = true
            root.fullscreenSuppressChannel = true
        } else {
            root.fullscreenSuppressInfo    = false
            root.fullscreenSuppressChannel = false
        }
    }
}
Shortcut {
    sequence: "S"; context: Qt.ApplicationShortcut
    // 在多路布局之间循环切换（不包含 Single）
    onActivated: {
        var arr = root.multiLayoutValues
        var i = arr.indexOf(Engine.layoutMode)
        if (i < 0) i = 0
        var v = arr[(i + 1) % arr.length]
        Engine.layoutMode = v
        root.lastMultiLayout = v
    }
}
Shortcut {
    sequence: "R"; context: Qt.ApplicationShortcut
    onActivated: {
        // YUV 分析 tab：R = 重置到开头（所有 slot 跳到首帧，多路对齐）
        if (root.currentTab === "yuv") {
            const n = YuvBridge.slotCount
            for (let i = 0; i < n; ++i) YuvBridge.firstFrame(i)
            return
        }
        // 播放 tab：R = 回到开头
        Engine.seek(0)
    }
}
// Ctrl+R（macOS 上 ⌘+R）= 还原视图（缩放回 1X + 平移归零），仅 yuv tab 生效
//   - 与裸 R "重置到开头"分离，避免混淆语义
//   - Qt 跨平台：macOS 上 CtrlModifier 自动对应 Command 键，无需特殊处理
Shortcut {
    sequence: StandardKey.Refresh  // 在不同平台映射为 Ctrl+R / ⌘+R
    context: Qt.ApplicationShortcut
    enabled: root.currentTab === "yuv" && YuvBridge.slotCount > 0
    onActivated: YuvBridge.resetView()
}
// B：切换"滑动对比"模式（仅 2 路视频可用）
Shortcut {
    sequence: "B"; context: Qt.ApplicationShortcut
    onActivated: RatingLogic._toggleCompareSlider()
}
// 倍速快捷键（参考 video-compare）：- 慢、= 快、0 复位
// 同时支持小键盘 + / - 与主键盘 + 的常见组合
Shortcut { sequence: "-";          context: Qt.ApplicationShortcut; onActivated: Engine.adjustSpeed(-1) }
Shortcut { sequence: "=";          context: Qt.ApplicationShortcut; onActivated: Engine.adjustSpeed(+1) }
Shortcut { sequence: "+";          context: Qt.ApplicationShortcut; onActivated: Engine.adjustSpeed(+1) }
Shortcut { sequence: "0";          context: Qt.ApplicationShortcut; onActivated: Engine.resetSpeed() }
// 数字键 1..9：toggle 单路/多路。
//   - 当前不是 Single，或 activeIndex != n-1：进入 Single 并显示对应窗口
//   - 当前已经是 Single 且 activeIndex == n-1（再次按下相同数字）：
//     切回上一次使用的多路布局（lastMultiLayout，默认 1×N）
//
// 注意：原先用 Repeater { Shortcut {...} } 并不会工作 —— Repeater 的
// delegate 必须是 Item/可视类型，非可视的 Shortcut 不会被实例化，所以
// 数字键根本不会触发。改成展开 9 个独立的 Shortcut。
Shortcut { sequence: "1"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(0) }
Shortcut { sequence: "2"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(1) }
Shortcut { sequence: "3"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(2) }
Shortcut { sequence: "4"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(3) }
Shortcut { sequence: "5"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(4) }
Shortcut { sequence: "6"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(5) }
Shortcut { sequence: "7"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(6) }
Shortcut { sequence: "8"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(7) }
Shortcut { sequence: "9"; context: Qt.ApplicationShortcut; onActivated: RatingLogic._toggleOne(8) }

// ── 快捷评分 / 选中通道切换 ─────────────────────────────────────
// 设计要点：
//   1. 数字键 1-9 已被占用为「toggle 单路/多路」，因此评分用 Shift+0..5
//      避开冲突（Shift+0 = 清空，Shift+1..5 = 1..5 星）。
//   2. [ / ] 用于在通道间切换 activeIndex（即"选中下一路 / 上一路"），
//      不改变布局（layoutMode），只换"选中"——这点很重要，避免和数字键
//      的 toggle 行为语义重叠。
//   3. 全部走 RatingLogic.setRatingAt() 已有逻辑：写入 cellRatings + 持久化到 CSV、
//      "再按相同分数 = 取消"等行为完全复用，零重复实现。
//   4. enabled 守卫：只有 fileCount > 0 才允许评分，防止空状态误触发。
//   5. context 选 ApplicationShortcut：和现有数字键一致，确保仅当应用前台
//      聚焦时生效；TextField/SpinBox 等控件聚焦时 Qt 会自动让控件优先吃键，
//      所以"输入框场景下不打扰"的诉求天然满足。
// 评分时确定目标通道：
//   - 用户已显式选中（selectedIdx ≥ 0）→ 直接用
//   - 仅有一路视频 → 自动落到 0（无歧义场景，省去先点击的麻烦）
//   - 多路且未选中 → 返回 -1，调用方应给出提示，不要悄悄打到第 0 路造成误评
// 【Checklist 勾选变更通知】由 VideoCellDelegate 的 checklistPopup 在
// 每次勾/取消勾选后调用，触发 multiGroupDialog._bumpState() 让 allGroupsRated
// 响应式重算，避免"下一组"按钮亮灭状态延迟。

// 快捷键评分专用：不走 setRatingAt（那里含 toggle 语义，给鼠标点星条用），
// 这里一律"强制覆盖写入"：不管以前是几星，按下 Shift+N 就是 N 星，
// 避免"首次评分出现已清除评分"、"连按两下变 0 分"这些迷惑场景。
// 超过当前模式 maxStars 的会被自动钉到上限（如主观模式 Shift+5 → 实际写 3）。
Shortcut { sequence: "Shift+0"; context: Qt.ApplicationShortcut; enabled: Engine.fileCount > 0
           onActivated: RatingLogic._clearRatingForActive() }
Shortcut { sequence: "Shift+1"; context: Qt.ApplicationShortcut
           enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 1
           onActivated: RatingLogic._setRatingForActive(1) }
Shortcut { sequence: "Shift+2"; context: Qt.ApplicationShortcut
           enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 2
           onActivated: RatingLogic._setRatingForActive(2) }
Shortcut { sequence: "Shift+3"; context: Qt.ApplicationShortcut
           enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 3
           onActivated: RatingLogic._setRatingForActive(3) }
// 主观模式 maxStars=3，4/5 这两个快捷键会被 disable，避免误操作写出超限评分。
Shortcut { sequence: "Shift+4"; context: Qt.ApplicationShortcut
           enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 4
           onActivated: RatingLogic._setRatingForActive(4) }
Shortcut { sequence: "Shift+5"; context: Qt.ApplicationShortcut
           enabled: Engine.fileCount > 0 && root.reviewMaxStars >= 5
           onActivated: RatingLogic._setRatingForActive(5) }
// 选中切换（不改布局，仅改 selectedIdx + Engine.activeIndex）：[ 上一路 / ] 下一路，循环。
// 即使 fileCount == 1，也允许按 ] 让 selectedIdx 从 -1 进入 0（"用键盘进入选中状态"）。
Shortcut { sequence: "[";       context: Qt.ApplicationShortcut; enabled: Engine.fileCount >= 1
           onActivated: RatingLogic._shiftActive(-1) }
Shortcut { sequence: "]";       context: Qt.ApplicationShortcut; enabled: Engine.fileCount >= 1
           onActivated: RatingLogic._shiftActive(+1) }

// ── 多组对比专用快捷键：上组 / 下组。仅在 multiGroupDialog.active 且当前确实有视频时生效。
// 选用 Ctrl+↑/↓，避免与现有 ←→（快进快退） / "."","（帧步进）冲突。
Shortcut {
    sequence: "Ctrl+Up";   context: Qt.ApplicationShortcut
    enabled: multiGroupDialog.active && Engine.fileCount > 0
    onActivated: { if (root.compareSliderActive) root.compareSliderActive = false; multiGroupDialog.prevGroup() }
}
Shortcut {
    sequence: "Ctrl+Down"; context: Qt.ApplicationShortcut
    enabled: multiGroupDialog.active && Engine.fileCount > 0
    onActivated: { if (root.compareSliderActive) root.compareSliderActive = false; multiGroupDialog.nextGroup() }
}

}
