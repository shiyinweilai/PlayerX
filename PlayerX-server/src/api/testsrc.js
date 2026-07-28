/**
 * src/api/testsrc.js — 测试源安装包（zip）托管
 *
 * 背景：
 *   配置的 testSource.url 原先只能指向 COS 等公网地址。
 *   内网部署时把 zip 直接放到评分服务器上，客户端下载走内网带宽，
 *   通常比 COS 公网更快，也不依赖外网连通性。
 *
 * 提供：
 *   GET    /testsrc/<name>        静态下载（在 server.js 挂载，express.static 自带 Range/etag）
 *   GET    /api/testsrc/list      包列表（匿名可读，与 list/files 等读接口一致）
 *   POST   /api/testsrc/upload    上传 zip（需管理员，multer 磁盘存储，支持大文件）
 *   DELETE /api/testsrc/:name     删除（需管理员）
 *
 * 安全：
 *   - 文件名一律 path.basename 去路径，并再拒绝一次分隔符，防路径逃逸
 *   - 写操作走 requireAdmin（X-Admin-Token），与配置/归档写操作一致
 *   - 服务定位受信任内网，下载不设鉴权
 */
const fs     = require('fs');
const path   = require('path');
const multer = require('multer');

const { TESTSRC_DIR } = require('../lib/paths');
const { requireAdmin } = require('./auth');

// 上传大小上限：测试源 zip 通常几百 MB，放宽到 4GB
//（上传 CSV 的 MAX_BYTES=10MB 是针对评分 CSV 的，不适用于此）
const MAX_ZIP_BYTES = 4 * 1024 * 1024 * 1024;

function sanitizeName(raw) {
    const base = path.basename(String(raw || '')).trim();
    if (!base || base === '.' || base === '..') return null;
    if (/[\\/]/.test(base)) return null;
    return base;
}

function fileInfo(name) {
    let size = 0, mtime = '';
    try {
        const st = fs.statSync(path.join(TESTSRC_DIR, name));
        size = st.size;
        mtime = st.mtime.toISOString();
    } catch (_) { /* 忽略 */ }
    return { name, size, mtime, url: '/testsrc/' + encodeURIComponent(name) };
}

// multer 磁盘存储：直接写入托管目录，保留原始文件名（同名覆盖，便于同名包更新）
const storage = multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, TESTSRC_DIR),
    filename: (_req, file, cb) => {
        // multer 按 latin1 解析文件名，中文名需转回 utf8
        let name = Buffer.from(file.originalname || 'package.zip', 'latin1').toString('utf8');
        name = sanitizeName(name) || 'package.zip';
        cb(null, name);
    },
});
const upload = multer({
    storage,
    limits: { fileSize: MAX_ZIP_BYTES },
});

function register(app) {
    // 包列表：新上传的排前
    app.get('/api/testsrc/list', (_req, res) => {
        let ents = [];
        try { ents = fs.readdirSync(TESTSRC_DIR, { withFileTypes: true }); } catch (_) {}
        const files = ents
            .filter(e => e.isFile() && !e.name.startsWith('.'))
            .map(e => fileInfo(e.name))
            .sort((a, b) => b.mtime.localeCompare(a.mtime));
        res.json({ ok: true, files });
    });

    // 上传（multipart 字段名 file）
    app.post('/api/testsrc/upload', requireAdmin, upload.single('file'), (req, res) => {
        if (!req.file) {
            return res.status(400).json({ ok: false, error: '缺少文件（multipart 字段名 file）' });
        }
        const name = req.file.filename;
        console.log(`[testsrc] 上传完成: ${name} (${req.file.size} B)`);
        res.json(Object.assign({ ok: true }, fileInfo(name)));
    });

    // 删除
    app.delete('/api/testsrc/:name', requireAdmin, (req, res) => {
        const name = sanitizeName(req.params.name);
        if (!name) return res.status(400).json({ ok: false, error: '非法文件名' });
        const full = path.join(TESTSRC_DIR, name);
        if (path.dirname(full) !== TESTSRC_DIR) {
            return res.status(400).json({ ok: false, error: '非法文件名' });
        }
        fs.unlink(full, err => {
            if (err) {
                if (err.code === 'ENOENT') return res.status(404).json({ ok: false, error: '文件不存在' });
                return res.status(500).json({ ok: false, error: err.message });
            }
            console.log(`[testsrc] 已删除: ${name}`);
            res.json({ ok: true, deleted: name });
        });
    });
}

module.exports = register;
