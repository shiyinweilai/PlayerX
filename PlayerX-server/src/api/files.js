/**
 * src/api/files.js — GET /files/:name
 *
 * 单文件下载（Web 面板 "下载" 按钮使用）。
 * 防越权：只允许下载 uploads/ 直接子项，禁止任何路径分隔符 / 特殊符号。
 */
const fs   = require('fs');
const path = require('path');

const { UPLOAD_DIR, ensureDirs } = require('../lib/paths');

function handle(req, res) {
    ensureDirs();
    const name = (req.params.name || '').toString();

    // 严格白名单：只接受形如 user__tag__ts.csv 的扁平名
    if (!/^[A-Za-z0-9._\-\u4e00-\u9fa5]+\.csv$/.test(name)) {
        return res.status(400).json({ ok: false, error: 'invalid file name' });
    }
    const fp = path.join(UPLOAD_DIR, name);
    if (!fs.existsSync(fp)) return res.status(404).json({ ok: false, error: 'not found' });

    res.download(fp, name);
}

module.exports = { handle };
