/**
 * src/api/upload.js — POST /upload
 *
 * 字段：
 *   file=<csv>, user=<评分人>, tag=<可选标签>, mode=<评分模式，默认 aigc>,
 *   client=<可选客户端版本>, force=<"1" 表示强制覆盖>
 *
 * 行为：
 *   - 同 (user, tag, mode) 已存在 → 默认 409 让客户端弹"覆盖确认"
 *   - force=1 → 把旧文件归档（最多保留 ARCHIVE_KEEP 份）后再写新的
 *   - 不同 mode 下同 (user, tag) 互不冲突（例如同一人可以同时上传 aigc 和 subjective）
 */
const fs     = require('fs');
const path   = require('path');
const multer = require('multer');

const { UPLOAD_DIR, MAX_BYTES, ensureDirs, getUploadToken } = require('../lib/paths');
const { safeSlug, tsNow }                                   = require('../lib/slug');
const { findExisting, archiveExisting }                     = require('../lib/store');

// 先把上传内容缓存到内存，业务侧根据冲突情况再决定怎么落盘。
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_BYTES } });

// 提取请求中的 token：优先取 X-Token 头（PlayerX 客户端在用），兜底再看 query/body
function _extractToken(req) {
    const h = req.header('X-Token') || req.header('x-token');
    if (h) return String(h);
    if (req.query && req.query.token) return String(req.query.token);
    if (req.body  && req.body.token)  return String(req.body.token);
    return '';
}

function handle(req, res) {
    if (!req.file) return res.status(400).json({ ok: false, error: 'missing file field' });

    const user  = safeSlug(req.body.user, 'anon');
    const tag   = safeSlug(req.body.tag,  'default');
    // mode 默认 'aigc'（保障旧客户端上传仍能入库）。
    // 同时走 safeSlug 安全过滤，避免被人费心传个路径注入。
    const mode  = safeSlug(req.body.mode, 'aigc');
    const force = String(req.body.force || '').trim() === '1';

    // 冲突检测：同 (user, tag, mode) 才算冲突，不同 mode 可同时存在
    const existing = findExisting(user, tag, mode);
    if (existing.length > 0 && !force) {
        return res.status(409).json({
            ok: false,
            needConfirm: true,
            user, tag, mode,
            message: `已存在 ${existing.length} 份同 (user=${user}, tag=${tag}, mode=${mode}) 的记录，确认覆盖？`,
            existing: existing.map(it => ({
                name: it.name, size: it.size, mtime: it.mtime.toISOString()
            })),
        });
    }

    // 强制覆盖：先把旧的归档
    let archived = [];
    if (existing.length > 0 && force) {
        archived = archiveExisting(user, tag, mode);
    }

    // 落盘：文件名中加入 mode 段。
    ensureDirs();
    const filename = `${user}__${tag}__${mode}__${tsNow()}.csv`;
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
        user, tag, mode,
    });
    console.log(`[upload] ${filename} (${size} bytes, mode=${mode}, archived=${archived.length}) from ${req.ip}`);
}

// Upload token 校验：作为独立中间件，挂在 multer 之前，
// 这样 token 错误时不会浪费带宽读取 multipart 文件。
function checkUploadToken(req, res, next) {
    const expected = getUploadToken();
    if (!expected) return next();   // 配置为空 → 关闭鉴权
    const got = _extractToken(req);
    if (got !== expected) {
        return res.status(401).json({
            ok: false,
            error: 'INVALID_TOKEN',
            message: '上传被拒绝：token 不匹配，请向管理员获取正确的 token',
        });
    }
    next();
}

module.exports = {
    multerMiddleware: upload.single('file'),
    checkUploadToken,
    handle,
};

