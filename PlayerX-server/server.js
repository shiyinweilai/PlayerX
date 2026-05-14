/**
 * PlayerX 评分 CSV 收集服务（最简实现）
 *
 * 设计要点：
 *   1. 单文件、零状态；upload 一次 = 在 ./uploads 落一份新 CSV，按 user+ts 命名，不会互相覆盖。
 *   2. 可选的 PLAYERX_TOKEN：若设置环境变量则要求 header X-Token 匹配；不设则放行（局域网默认开放）。
 *   3. /list /merge 两个只读接口，方便人工核对 / 一键拿到合并表。
 *
 * 启动：
 *   npm install        # 仅首次
 *   node server.js     # 默认 0.0.0.0:8765
 *
 *   PORT=9000 PLAYERX_TOKEN=xxxxx node server.js   # 自定义端口 + 鉴权
 *
 * 接口：
 *   POST /upload   multipart/form-data
 *                  字段：file=<csv 二进制>, user=<评分人>, client=<可选客户端版本>
 *                  返回：{ ok, saved, size, receivedAt }
 *
 *   GET  /list     列出所有已收 csv（[{name,size,mtime}]）
 *   GET  /merge    把 uploads/ 下所有 csv 拼成一份返回（简单串联，仅保留一行表头）
 *   GET  /         健康检查（返回简单 HTML，便于浏览器打开自检）
 */
const express = require('express');
const multer  = require('multer');
const fs      = require('fs');
const path    = require('path');

// ── 配置 ──────────────────────────────────────────────────────────────
const PORT      = parseInt(process.env.PORT || '8765', 10);
const TOKEN     = (process.env.PLAYERX_TOKEN || '').trim();   // 空 = 不校验
const UPLOAD_DIR = path.join(__dirname, 'uploads');
const MAX_BYTES  = 10 * 1024 * 1024;                          // 单文件 10MB 兜底

fs.mkdirSync(UPLOAD_DIR, { recursive: true });

// ── multer：把上传文件直接落盘到 uploads/，按 <user>_<ts>.csv 命名 ─────
const storage = multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, UPLOAD_DIR),
    filename: (req, file, cb) => {
        const userRaw = (req.body.user || 'anon').toString();
        // 只允许字母数字、下划线、横线、点；其他一律下划线，防止路径穿越
        const user = userRaw.replace(/[^A-Za-z0-9._\-\u4e00-\u9fa5]/g, '_').slice(0, 64) || 'anon';
        const ts = new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19);
        cb(null, `${user}_${ts}.csv`);
    }
});
const upload = multer({ storage, limits: { fileSize: MAX_BYTES } });

// ── 简单 token 中间件（空 token 时放行） ─────────────────────────────
function checkToken(req, res, next) {
    if (!TOKEN) return next();
    const got = req.header('X-Token') || req.query.token;
    if (got !== TOKEN) return res.status(401).json({ ok: false, error: 'invalid token' });
    next();
}

// ── 路由 ─────────────────────────────────────────────────────────────
const app = express();

app.get('/', (_req, res) => {
    res.set('Content-Type', 'text/html; charset=utf-8');
    res.send(`<!doctype html><meta charset="utf-8">
<title>PlayerX Server</title>
<body style="font-family:sans-serif;padding:24px;color:#222;background:#fafafa">
<h2>📊 PlayerX 评分收集服务</h2>
<p>状态：<b style="color:#52c41a">Running</b> &nbsp; 端口：<code>${PORT}</code> &nbsp; 鉴权：<code>${TOKEN ? '开启' : '关闭'}</code></p>
<ul>
  <li><code>POST /upload</code> — 客户端上传入口</li>
  <li><a href="/list">GET /list</a> — 已收 CSV 列表</li>
  <li><a href="/merge">GET /merge</a> — 合并 CSV 一键下载</li>
</ul>
<p style="color:#888">uploads 目录：<code>${UPLOAD_DIR}</code></p>
</body>`);
});

app.post('/upload', checkToken, upload.single('file'), (req, res) => {
    if (!req.file) return res.status(400).json({ ok: false, error: 'missing file field' });
    const stat = fs.statSync(req.file.path);
    res.json({
        ok: true,
        saved: req.file.filename,
        size: stat.size,
        receivedAt: new Date().toISOString(),
        client: (req.body.client || '').toString().slice(0, 64),
        user:   (req.body.user   || '').toString().slice(0, 64),
    });
    console.log(`[upload] ${req.file.filename} (${stat.size} bytes) from ${req.ip}`);
});

app.get('/list', checkToken, (_req, res) => {
    const items = fs.readdirSync(UPLOAD_DIR)
        .filter(n => n.toLowerCase().endsWith('.csv'))
        .map(n => {
            const st = fs.statSync(path.join(UPLOAD_DIR, n));
            return { name: n, size: st.size, mtime: st.mtime.toISOString() };
        })
        .sort((a, b) => a.mtime < b.mtime ? 1 : -1);
    res.json({ ok: true, count: items.length, items });
});

// 简单合并：拼接所有 csv 内容；只保留第一份的表头（剥掉其余文件的首行 + BOM）
app.get('/merge', checkToken, (_req, res) => {
    const files = fs.readdirSync(UPLOAD_DIR)
        .filter(n => n.toLowerCase().endsWith('.csv'))
        .sort();
    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.set('Content-Disposition', 'attachment; filename="playerx_all.csv"');
    let first = true;
    for (const n of files) {
        let txt = fs.readFileSync(path.join(UPLOAD_DIR, n), 'utf8');
        if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);          // 去 BOM
        const lines = txt.split(/\r?\n/);
        if (lines.length === 0) continue;
        if (first) {
            res.write('\uFEFF');                                        // 输出一次 BOM
            res.write(lines.join('\n'));
            first = false;
        } else {
            // 跳过表头
            res.write('\n' + lines.slice(1).join('\n'));
        }
    }
    if (first) res.write('\uFEFFupdated_at,rater,file_name,stars\n');   // 没文件时给个空表
    res.end();
});

// multer 错误处理（超大文件等）
app.use((err, _req, res, _next) => {
    console.error('[error]', err);
    res.status(400).json({ ok: false, error: err.message || 'unknown error' });
});

app.listen(PORT, '0.0.0.0', () => {
    console.log(`PlayerX server listening on http://0.0.0.0:${PORT}`);
    console.log(`  uploads dir : ${UPLOAD_DIR}`);
    console.log(`  auth token  : ${TOKEN ? '(set, X-Token required)' : '(disabled)'}`);
});
