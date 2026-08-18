## 【坑】非 pragma library 的 .js 模块，每个 import 它的 QML 文件都有独立状态副本

### 现象（同一根因的三个连坏 case，2026-08-18）
- 铃铛（远程任务）点击无效
- 远程任务卡片点"接受"卡在 "…"，日志报 `ReferenceError: Logic is not defined`
- 星星打分无效、checklist 不弹出，日志报 `TypeError: Cannot call method 'slice' of undefined`

### 根因
`MainLogic.js` / `RatingLogic.js` 都**没有加 `.pragma library`**。
按 QML 规范：普通（非 library）js 被**每个** `import` 它的 QML 文件/组件实例各拿一份**完全独立**的模块状态副本
（各自独立的 `_root`、`_initialized` 等模块级变量）。
- 只有 `Main.qml` 的 `Component.onCompleted` 调过 `Logic._init(...)` / `RatingLogic._initRating(...)`，
  初始化的只是 Main.qml 自己那份。
- 其它单独 `import "MainLogic.js"` / `import "RatingLogic.js"` 的文件（`TopBar.qml`、
  `GlobalShortcuts.qml`、`TaskUpdateCard.qml`、`VideoCellDelegate.qml`）各自都是从未初始化过的
  独立副本，`_root` 一直是模块顶部兜底的空对象 `{}`，一用就抛 `ReferenceError`/`TypeError`，或者
  被提前 `return`。
- `VideoCellDelegate.qml` 更特殊：一个 Grid 里最多 9 个实例，就是 9 份互相独立的状态，必须每个实例
  自己的 `Component.onCompleted` 里都初始化一次。

### 检索方式（下次遇到"点了没反应/卡住/报错 xxx is not defined"，按此排查）
1. 先看日志，抓 `ReferenceError: Logic is not defined` / `TypeError: Cannot call method 'xxx' of undefined`
   / `_root` 相关字样，能直接定位到出问题的 qml 文件+行号。
2. 确认 js 文件是否加了 `.pragma library`：
   ```
   grep -n "pragma library" PlayerX/PlayerX/qml/MainLogic.js PlayerX/PlayerX/qml/RatingLogic.js
   ```
   没加 → 就是这个坑。
3. 找出所有 import 该 js 的 QML 文件，逐个确认是否都调用了对应的 `_init`/`_initRating`：
   ```
   grep -rn 'import "MainLogic.js"' PlayerX/PlayerX/qml
   grep -rn 'import "RatingLogic.js"' PlayerX/PlayerX/qml
   grep -rn '_init(\|_initRating(' PlayerX/PlayerX/qml
   ```
   两边数量对不上，缺初始化调用的文件就是待修复点。
4. 修复模板（照抄 `TopBar.qml` / `VideoCellDelegate.qml` 已有写法）：
   - 该 QML 文件补齐 `_init`/`_initRating` 需要的所有 `property var xxx: null`；
   - `Component.onCompleted: { Logic._init({ root: root, ... }) }`；
   - 上层实例化处（一般在 `Main.qml`/`VideoArea.qml`）把这些属性逐一透传下去。

### 已修复文件清单（2026-08-18）
- `TopBar.qml`（铃铛）
- `GlobalShortcuts.qml`（数字键打分等全局快捷键）
- `TaskUpdateCard.qml`（远程任务"接受/忽略"按钮，此前甚至漏了 `import` 本身）
- `VideoCellDelegate.qml` + `VideoArea.qml`（星星打分 / checklist 联动）

### 根本性建议（尚未做，供以后彻底解决）
给 `MainLogic.js`、`RatingLogic.js` 顶部加 `.pragma library`，让全局只有一份真正共享的模块状态，
一次 `_init` 即可全局生效，不用每个新增的 QML 文件都记得手动初始化一遍
（但要注意 library script 里不能再用裸的 QML id，如 `root`，需要全部通过传入的 ctx 访问）。
