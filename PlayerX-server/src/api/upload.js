/**
 * src/api/upload.js — POST /upload
 *
 * 字段：
 *   file=<csv>, user=<评分人>, tag=<可选标签>, client=<可选客户端版本>,
 *   force=<"1" 表示强制覆盖>
 *
 * 行为：
 *   - 同 (user, tag) 已存在 → 默认 409 让客户端弹"覆盖确认"
 *   - force=1 → 把旧文件归档（最多保留 ARCHIVE_KEEP 份）后再写新的
 */
const fs     = require('fs');
const path   = require('path');
const multer = require('multer');

const { UPLOAD_DIR, MAX_BYTES, ensureDirs } = require('../lib/paths');
const { safeSlug, tsNow }                   = require('../lib/slug');
const { findExisting, archiveExisting }     = require('../lib/store');

// 先把上传内容缓存到内存，业务侧根据冲突情况再决定怎么落盘。
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_BYTES } });

function handle(req, res) {
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
}

module.exports = { multerMiddleware: upload.single('file'), handle };
