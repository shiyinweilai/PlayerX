/**
 * src/api/delete.js — DELETE /files/:name
 *
 * 删除单个 CSV（Web 面板"删除"按钮使用）。
 * 防越权：与 files.js 一致，只接受 uploads/ 下扁平 .csv 文件名。
 */
const fs   = require('fs');
const path = require('path');

const { UPLOAD_DIR, ensureDirs } = require('../lib/paths');

function handle(req, res) {
    ensureDirs();
    const name = (req.params.name || '').toString();

    if (!/^[A-Za-z0-9._\-\u4e00-\u9fa5]+\.csv$/.test(name)) {
        return res.status(400).json({ ok: false, error: 'invalid file name' });
    }
    const fp = path.join(UPLOAD_DIR, name);
    if (!fs.existsSync(fp)) {
        return res.status(404).json({ ok: false, error: 'not found' });
    }
    try {
        fs.unlinkSync(fp);
        return res.json({ ok: true, name });
    } catch (e) {
        return res.status(500).json({ ok: false, error: e.message || 'unlink failed' });
    }
}

module.exports = { handle };
