# PlayerX 评分收集服务

最简后端：客户端 → POST CSV → 服务端落盘 → 任意成员合并取数；自带极简深色 Web 面板。

## 工程结构

```
PlayerX-server/
├── server.js              # 启动器（端口 / token / 挂载静态&API）
├── package.json
├── src/
│   ├── api/
│   │   ├── index.js       # 路由聚合
│   │   ├── auth.js        # token 鉴权中间件
│   │   ├── upload.js      # POST /upload
│   │   ├── list.js        # GET  /list
│   │   ├── merge.js       # GET  /merge
│   │   ├── files.js       # GET  /files/:name
│   │   ├── status.js      # GET  /api/status (不鉴权)
│   │   ├── dashboard.js   # GET  /api/dashboard 数据大盘
│   │   ├── analyze.js     # POST /api/analyze 盲评分析
│   │   ├── verify.js      # POST /api/verify 盲评校验
│   │   ├── build.js       # POST /api/build 构建任务
│   │   ├── models.js      # GET  /api/models  模型管理
│   │   └── config.js      # GET/POST /api/config 配置管理
│   ├── lib/
│   │   ├── paths.js       # 目录与配置常量
│   │   ├── slug.js        # safeSlug / tsNow / parseName
│   │   └── store.js       # uploads/archive 扫描与归档
│   └── web/               # Web 面板
│       ├── index.html
│       ├── admin-analyze.js   # 管理页：分析结果交互
│       ├── admin-tasks.js     # 管理页：任务管理
│       ├── app-core.js        # 基础设施（DOM、状态、工具、鉴权、模块路由）
│       ├── app-models.js      # 模型管理模块
│       ├── app-config-editor.js  # 配置编辑器（维度/构建/测试/评分）
│       ├── app-files.js       # 文件列表 + 大盘 + CSV预览 + 归档
│       ├── app-init.js        # 初始化（列宽/Hash/启动） + window.PX API
│       ├── app-analyze.js     # 分析结果模块（window.PXAnalyze）
│       ├── style-base.css          # CSS 变量 + 全局重置
│       ├── style-components.css    # 核心组件（顶栏/按钮/表格/弹窗/Toast）
│       ├── style-dim-editor.css    # 维度规则编辑器样式
│       ├── style-admin-layout.css  # 后台布局（侧栏/导航/归档页）
│       ├── style-enhance.css       # 设计令牌 + 毛玻璃质感层
│       ├── style-dashboard.css     # 数据大盘 + 小屏适配
│       └── style-analyze.css       # 分析结果 + 确认弹窗
├── uploads/               # 落盘目录（运行期自动建）
└── archive/               # 历史归档（每槽位最多保留 20 份）
```

## 启动

```bash
cd PlayerX-server
npm install        # 仅首次
restart.sh         # 使用的是nohup
```

启动成功后浏览器打开 `http://<本机 IP>:2026/` 即可看到 Web 面板。

## Web 面板

- 顶栏：连接状态、Token 设置、刷新
- KPI：已收文件数 / 评分人 / 标签组 / 总大小
- 列表：评分人 / 标签 / 文件名 / 大小 / 最近更新 + 单文件下载
- 操作：合并下载（每个 user/tag 仅最新一份） / 合并下载（全部）
- 搜索：评分人 / 标签 / 文件名 实时过滤
- 列头点击切换排序方向

> Token 仅保存在浏览器 localStorage，不会上送给三方。

## 局域网验证流程

1. 服务端：`npm start`
2. 查本机 IP：`ipconfig getifaddr en0`（macOS）
3. 客户端「评分数据 → ⚙ 上传设置」：
   - 上传地址 = `http://<本机 IP>:2026/upload`
   - Token = 启动时配置的（默认 `123456`）
4. 点「☁ 上传到云端」 → 服务端控制台会打印 `[upload] xxx.csv` 日志
5. 浏览器访问 `http://<本机 IP>:2026/` → Web 面板查看 / 下载 / 合并

## 接口

| Method | Path                | 鉴权 | 说明 |
| ------ | ------------------- | :--: | ---- |
| GET    | `/`                 | -    | Web 面板（index.html） |
| GET    | `/api/status`       | -    | 服务状态（用于面板首屏判断是否需要 token） |
| POST   | `/upload`           | ✓    | 上传 CSV：`file` / `user` / `tag` / `client` / `force` |
| POST   | `/api/upload`       | ✓    | 同上（前缀别名） |
| GET    | `/list`             | ✓    | 已收 CSV 列表（JSON） |
| GET    | `/api/list`         | ✓    | 同上 |
| GET    | `/merge[?all=1]`    | ✓    | 合并下载（默认仅各 (user,tag) 最新；`all=1` 含历史） |
| GET    | `/api/merge`        | ✓    | 同上 |
| GET    | `/files/:name`      | ✓    | 单个 CSV 下载 |
| GET    | `/api/files/:name`  | ✓    | 同上 |

## 文件落盘规则

`uploads/<user>__<tag>__<yyyy-MM-dd_HH-mm-ss>.csv`

- user / tag 做了字符净化（仅留字母数字、下划线、横线、点、汉字）
- 同 (user, tag) 重复上传：默认 409 让客户端弹"覆盖确认"；带 `force=1` 时把旧文件搬到 `archive/<user>__<tag>/`
- 每个槽位归档最多保留 20 份，更早的物理删除
- 单文件最大 10MB（CSV 远远到不了这个量级）