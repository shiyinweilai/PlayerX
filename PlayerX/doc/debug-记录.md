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

---

## 【坑】macOS 菜单栏登录菜单判定用了 index 兜底，点「通用/码流分析」误弹个人信息面板

### 现象（2026-08-19）
- 点击顶部菜单栏「通用」「码流分析」会弹出"个人信息"对话框（本该展开各自下拉菜单）。
- 登录后菜单栏标题是用户名（如 `rbyang`），与「通用」相邻，容易误以为是位置重叠导致。

### 根因
`MacAppearance.mm` 的 `px_isLoginMenu()` 里有一句 **`return index == 4;` 的位置兜底**判定。
旧菜单布局是 `Apple/文件/设置/帮助/登录`，index 4 恰是登录菜单。
后来把「设置」重构为按模块平铺（`文件/播放对比/YUV分析/通用/帮助/登录`），
index 4 变成了「通用」，于是每次轮询挂菜单守卫（guard）时，「通用」被错误标记为 `isLogin=YES`，
点击即触发 `px_fireLoginDialog()` 弹出个人信息面板；「码流分析」等位置也会命中同类误判。

### 修复
删除 index 兜底，只保留**标题匹配**（`"登录"` 或当前评分人名 `rating/user`）：

```objc
static BOOL px_isLoginMenu(NSMenu *menu, NSInteger index) {
    (void)index;   // 保留参数仅为兼容，刻意不用
    NSString *t = menu.title ?: @"";
    if ([t isEqualToString:@"登录"]) return YES;
    QSettings s(QStringLiteral("PlayerX"), QStringLiteral("PlayerX"));
    NSString *rater = s.value(QStringLiteral("rating/user")).toString().toNSString();
    if (rater.length > 0 && [t isEqualToString:rater]) return YES;
    return NO;
}
```

### 教训
菜单布局会随迭代变化，**不要用位置/索引兜底**去定位某个特定菜单；用标题/标识等稳定特征判定。
改菜单结构后，顺手 `grep` 一遍 C++ 侧是否还有 `index == N` 这类硬编码位置假设。

---

## 【坑】FileDialogs 内部 id 外部访问 → undefined，所有"打开文件"按钮失效

### 现象（2026-08-19）
重构顶部菜单（按模块平铺）后，顶部菜单「播放对比 ▸ 打开文件…」和主界面「打开文件」大按钮都**无任何反应**——点了菜单项高亮关闭，FileDialog 不弹。

### 日志
```
[12:44:56] TypeError: Cannot call method 'open' of undefined
   qrc:/qt/qml/PlayerX/qml/AppMenuBar.qml:326
[12:45:09] TypeError: Cannot call method 'open' of undefined
   qrc:/qt/qml/PlayerX/qml/VideoArea.qml:268
```

### 根因
`FileDialogs.qml` 内部 `FileDialog { id: addDialog }` 的 `addDialog` 是**内部 id**，
QML 中 id 只在当前 component scope 内解析——外部通过 `fileDialogs.addDialog` 访问
内部 id 返回 **undefined**（QML 早期/AOT 关闭时宽松返回内部对象，AOT 严格后直接 undefined）。

Main.qml 里大量 `addDialog: fileDialogs.addDialog` / `fileDialogs.refSidebar*` 都被这一 bug 影响。

### 修复
在 `FileDialogs.qml` 用 `property alias` 显式导出所有内部 id：

```qml
property alias addDialog: addDialog
property alias replaceDialog: replaceDialog
property alias refSidebarCsvDlg: refSidebarCsvDlg
property alias refSidebarFileDlg: refSidebarFileDlg
property alias refSidebarDirDlg: refSidebarDirDlg
property alias refSidebarGroupedDlg: refSidebarGroupedDlg
property alias refSidebarFileDlg2: refSidebarFileDlg2
property alias refSidebarDirDlg2: refSidebarDirDlg2
property alias refSidebarGroupedDlg2: refSidebarGroupedDlg2
```

### 教训
**子组件的 id 不要假设外部能直接访问**——必须用 `property alias` 显式导出。
新增需要被外部访问的子组件时，第一件事就是写 `property alias`。
重构完 QML，**第一件事**是打开 app 日志搜 `TypeError` / `Cannot read property 'X' of undefined`，
这类静默失败不会有 UI 反馈，只会在日志里留警告。
