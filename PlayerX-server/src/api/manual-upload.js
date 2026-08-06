/**
 * src/api/manual-upload.js — POST /api/manual-upload
 *
 * 管理员通过 Web 面板手动上传文件到 uploads/ 目录。
 * 仅已登录管理员可用（由 auth.requireAdmin 中间件保证）。
 *
 * 字段：
 *   file=<任意文件>
 *
 * 行为：
 *   - 保留原始文件名（安全过滤后）
 *   - 同名文件直接覆盖（管理员操作，不做归档）
 *   - 返回 { ok, saved, size, mtime }
 */
const fs     = require('fs');
const path   = require('path');
const multer = require('multer');

const { UPLOAD_DIR, ensureDirs } = require('../lib/paths');

// 内存缓存，业务侧决定怎么落盘（与 upload.js 一致）
const upload = multer({
    storage: multer.memoryStorage(),
    limits:  { fileSize: 500 * 1024 * 1024 }, // 500MB 上限
});

function handle(req, res) {
    if (!req.file) {
        return res.status(400).json({ ok: false, error: 'missing file field' });
    }

    // 安全化文件名：仅防止路径穿越，保留原始命名（管理员上传，信任源）
    const rawName = req.file.originalname || 'unnamed';
    // 浏览器 multipart 上传时中文等非 ASCII 字符以 Latin-1 编码传输，
    // 需要还原为 UTF-8 才能正确显示中文文件名
    let base = path.basename(Buffer.from(rawName, 'latin1').toString('utf8'));
    // 防止空文件名
    if (!base || base === '.' || base === '..') {
        base = `upload_${Date.now()}.bin`;
    }
    const filename = base;
    const dst = path.join(UPLOAD_DIR, filename);

    ensureDirs();
    fs.writeFileSync(dst, req.file.buffer);
    const stat = fs.statSync(dst);

    res.json({
        ok: true,
        saved: filename,
        path: dst,
        size: stat.size,
        mtime: stat.mtime.toISOString(),
    });
    console.log(`[manual-upload] ${filename} (${stat.size} bytes) from admin ${req.ip}`);
}

module.exports = {
    multerMiddleware: upload.single('file'),
    handle,
};
