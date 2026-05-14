/**
 * PlayerX 评分 CSV 收集服务（最简实现）
 *
 * 设计要点：
 *   1. 单文件、零状态；upload 一次 = 在 ./uploads 落一份新 CSV，
 *      命名规则 `<user>__<tag>__<ts>.csv`，便于人眼区分多轮评测。
 *   2. 同一 (user, tag) 重复上传：默认 **拒绝并返回 409**，由客户端
 *      弹"是否覆盖"确认；客户端再次带 force=1 上来时，把原来的
 *      文件移到 archive/<user>__<tag>/ 下保留（最多 10 份），再写新的。
 *   3. 鉴权：默认开启（默认 token = 123456）。可通过环境变量
 *      PLAYERX_TOKEN 覆盖；设置 PLAYERX_TOKEN=- 表示显式关闭鉴权。
 *      客户端在 HTTP 头 `X-Token` 或 query `?token=` 中传入即可。
 *   4. /list /merge 两个只读接口；/list 的每条记录额外带 user / tag 字段，
 *      /merge 默认仅合并各 (user, tag) 的最新文件，避免重复行膨胀。
 *
 * 启动：
 *   npm install                       # 仅首次
 *   node server.js                    # 默认 0.0.0.0:8765，鉴权开启 (token=123456)
 *   PLAYERX_TOKEN=mySecret node server.js   # 自定义 token
 *   PLAYERX_TOKEN=- node server.js          # 显式关闭鉴权
 *   PORT=9000 node server.js          # 自定义端口
 *
 * 接口：
 *   POST /upload   multipart/form-data
 *                  字段：file=<csv>, user=<评分人>, tag=<可选标签>,
 *                       client=<可选客户端版本>, force=<"1" 表示强制覆盖>
 *                  正常：200 { ok, saved, archived: [...], size, receivedAt }
 *                  冲突：409 { ok:false, needConfirm:true, existing:[{name,mtime,size}], message }
 *
 *   GET  /list     列出所有 csv（[{name,user,tag,size,mtime}]）
 *   GET  /merge    合并 csv 一键下载（默认仅每个 (user, tag) 的最新一份）
 *   GET  /         健康检查（HTML）
 */
const express = require('express');
const multer  = require('multer');
const fs      = require('fs');
const path    = require('path');

// ── 配置 ──────────────────────────────────────────────────────────────
const PORT       = parseInt(process.env.PORT || '8765', 10);
// 鉴权 token：
//   - 默认 '123456'（默认即开启鉴权，客户端必须配同样的 token 才能上传）
//   - 通过环境变量 PLAYERX_TOKEN 可覆盖（例如生产用更强的随机串）
//   - 显式设为 '-' 表示关闭鉴权（局域网纯内部场景）
const RAW_TOKEN  = process.env.PLAYERX_TOKEN;
const TOKEN      = (RAW_TOKEN === undefined ? '123456' : RAW_TOKEN).trim() === '-'
                   ? ''
                   : (RAW_TOKEN === undefined ? '123456' : RAW_TOKEN).trim();
const UPLOAD_DIR = path.join(__dirname, 'uploads');
const ARCHIVE_DIR = path.join(__dirname, 'archive');
const MAX_BYTES  = 10 * 1024 * 1024;
const ARCHIVE_KEEP = 20;   // 每个 (user,tag) 槽位最多保留 20 份历史归档，更早的物理删除

// 在每个会读/写这两个目录的入口都先调一下，保证运行期手工删了目录也能自愈。
// 否则 readdirSync 会抛 ENOENT，整个接口就 500/400 给客户端。
function ensureDirs() {
    fs.mkdirSync(UPLOAD_DIR, { recursive: true });
    fs.mkdirSync(ARCHIVE_DIR, { recursive: true });
}
ensureDirs();

// ── 工具：清洗 user/tag 形成可作为文件名的安全片段 ─────────────────
//   只允许字母数字、下划线、横线、点、汉字；其他一律换成下划线。
//   兜底：空串 → user='anon' / tag='default'；长度截到 64。
function safeSlug(raw, fallback) {
    const s = (raw || '').toString()
        .replace(/[^A-Za-z0-9._\-\u4e00-\u9fa5]/g, '_')
        .slice(0, 64);
    return s || fallback;
}
function tsNow() {
    return new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19);
}

// 解析文件名 → { user, tag, ts }；返回 null 表示不符合命名规则。
//   兼容旧文件 `<user>_<ts>.csv`（无 tag），tag 视作 ''。
function parseName(name) {
    if (!name.toLowerCase().endsWith('.csv')) return null;
    const stem = name.slice(0, -4);
    // 新格式：双下划线分隔
    const m = stem.match(/^(.+?)__(.+?)__([0-9T:_\-\.]+)$/);
    if (m) return { user: m[1], tag: m[2], ts: m[3] };
    // 旧格式：单下划线 + 时间戳
    const m2 = stem.match(/^(.+)_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})$/);
    if (m2) return { user: m2[1], tag: '', ts: m2[2] };
    return { user: stem, tag: '', ts: '' };
}

// 同 (user, tag) 已存在的 csv 文件列表（按 mtime 倒序）
function findExisting(user, tag) {
    ensureDirs();
    return fs.readdirSync(UPLOAD_DIR)
        .filter(n => n.toLowerCase().endsWith('.csv'))
        .map(n => {
            const meta = parseName(n) || {};
            const st = fs.statSync(path.join(UPLOAD_DIR, n));
            return { name: n, user: meta.user || '', tag: meta.tag || '', size: st.size, mtime: st.mtime };
        })
        .filter(it => it.user === user && it.tag === tag)
        .sort((a, b) => b.mtime - a.mtime);
}

// 把 (user, tag) 现有文件全部归档到 archive/<user>__<tag>/，并裁剪到 ARCHIVE_KEEP 份
function archiveExisting(user, tag) {
    const slot = path.join(ARCHIVE_DIR, `${user}__${tag || 'default'}`);
    fs.mkdirSync(slot, { recursive: true });
    const moved = [];
    for (const it of findExisting(user, tag)) {
        const dst = path.join(slot, it.name);
        try {
            fs.renameSync(path.join(UPLOAD_DIR, it.name), dst);
            moved.push(it.name);
        } catch (e) {
            console.warn('[archive] rename failed:', e.message);
        }
    }
    // 裁剪：按 mtime 倒序保留最新 N 份，其余删除
    const all = fs.readdirSync(slot)
        .filter(n => n.toLowerCase().endsWith('.csv'))
        .map(n => ({ name: n, mtime: fs.statSync(path.join(slot, n)).mtime }))
        .sort((a, b) => b.mtime - a.mtime);
    for (const old of all.slice(ARCHIVE_KEEP)) {
        try { fs.unlinkSync(path.join(slot, old.name)); }
        catch (e) { console.warn('[archive] prune failed:', e.message); }
    }
    return moved;
}

// ── multer：先把上传内容缓存到内存，业务侧根据冲突情况再决定怎么落盘 ──
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_BYTES } });

// ── 简单 token 中间件（空 token 时放行） ─────────────────────────────
function checkToken(req, res, next) {
    if (!TOKEN) return next();
    const got = req.header('X-Token') || req.query.token;
    if (got !== TOKEN) {
        // 文案里前缀 "[AUTH] " 让客户端可以识别为"鉴权类硬错"，弹强提醒并引导去配 token。
        const reason = !got
            ? '[AUTH] 服务器已开启鉴权，但客户端未携带 token，请在「⚙ 上传设置」中填写。'
            : '[AUTH] token 不匹配，请在「⚙ 上传设置」中确认 token 是否填写正确。';
        return res.status(401).json({ ok: false, error: reason });
    }
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
  <li><code>POST /upload</code> — 客户端上传入口（字段：file, user, tag, client, force）</li>
  <li><a href="/list">GET /list</a> — 已收 CSV 列表</li>
  <li><a href="/merge">GET /merge</a> — 合并 CSV 一键下载（仅各 (user,tag) 最新一份）</li>
</ul>
<p style="color:#888">uploads 目录：<code>${UPLOAD_DIR}</code></p>
<p style="color:#888">archive 目录：<code>${ARCHIVE_DIR}</code> &nbsp;（每个 (user,tag) 最多保留 ${ARCHIVE_KEEP} 份历史）</p>
</body>`);
});

app.post('/upload', checkToken, upload.single('file'), (req, res) => {
    if (!req.file) return res.status(400).json({ ok: false, error: 'missing file field' });

    const user  = safeSlug(req.body.user, 'anon');
    const tag   = safeSlug(req.body.tag,  'default');
    const force = String(req.body.force || '').trim() === '1';

    // 冲突检测
    const existing = findExisting(user, tag);
    if (existing.length > 0 && !force) {
        return res.status(409).json({
            ok: false,
            needConfirm: true,
            user, tag,
            message: `已存在 ${existing.length} 份同 (user=${user}, tag=${tag}) 的记录，确认覆盖？`,
            existing: existing.map(it => ({
                name: it.name, size: it.size, mtime: it.mtime.toISOString()
            })),
        });
    }

    // 强制覆盖：先把旧的归档
    let archived = [];
    if (existing.length > 0 && force) {
        archived = archiveExisting(user, tag);
    }

    // 落盘
    ensureDirs();
    const filename = `${user}__${tag}__${tsNow()}.csv`;
    const dst = path.join(UPLOAD_DIR, filename);
    fs.writeFileSync(dst, req.file.buffer);
    const size = req.file.buffer.length;

    res.json({
        ok: true,
        saved: filename,
        archived,
        size,
        receivedAt: new Date().toISOString(),
        client: (req.body.client || '').toString().slice(0, 64),
        user, tag,
    });
    console.log(`[upload] ${filename} (${size} bytes, archived=${archived.length}) from ${req.ip}`);
});

app.get('/list', checkToken, (_req, res) => {
    ensureDirs();
    const items = fs.readdirSync(UPLOAD_DIR)
        .filter(n => n.toLowerCase().endsWith('.csv'))
        .map(n => {
            const st = fs.statSync(path.join(UPLOAD_DIR, n));
            const meta = parseName(n) || {};
            return {
                name: n,
                user: meta.user || '',
                tag:  meta.tag  || '',
                size: st.size,
                mtime: st.mtime.toISOString(),
            };
        })
        .sort((a, b) => a.mtime < b.mtime ? 1 : -1);
    res.json({ ok: true, count: items.length, items });
});

// 默认仅合并各 (user, tag) 的最新一份；?all=1 时并入全部 csv（含历史）。
app.get('/merge', checkToken, (req, res) => {
    ensureDirs();
    const all = req.query.all === '1';
    let files = fs.readdirSync(UPLOAD_DIR)
        .filter(n => n.toLowerCase().endsWith('.csv'));

    if (!all) {
        // 按 (user, tag) 取 mtime 最新的那个
        const bucket = new Map();   // key=`${user}__${tag}` → {name, mtime}
        for (const n of files) {
            const meta = parseName(n) || {};
            const key = `${meta.user || ''}__${meta.tag || ''}`;
            const st = fs.statSync(path.join(UPLOAD_DIR, n));
            const cur = bucket.get(key);
            if (!cur || cur.mtime < st.mtime) bucket.set(key, { name: n, mtime: st.mtime });
        }
        files = [...bucket.values()].sort((a, b) => a.name < b.name ? -1 : 1).map(x => x.name);
    } else {
        files.sort();
    }

    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.set('Content-Disposition', 'attachment; filename="playerx_all.csv"');
    let first = true;
    for (const n of files) {
        let txt = fs.readFileSync(path.join(UPLOAD_DIR, n), 'utf8');
        if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);
        const lines = txt.split(/\r?\n/);
        if (lines.length === 0) continue;
        if (first) {
            res.write('\uFEFF');
            res.write(lines.join('\n'));
            first = false;
        } else {
            res.write('\n' + lines.slice(1).join('\n'));
        }
    }
    if (first) res.write('\uFEFFupdated_at,rater,file_name,stars\n');
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
    console.log(`  archive dir : ${ARCHIVE_DIR}  (keep latest ${ARCHIVE_KEEP} per slot)`);
    console.log(`  auth token  : ${TOKEN ? '(set, X-Token required)' : '(disabled)'}`);
});
