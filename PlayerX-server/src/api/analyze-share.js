/**
 * src/api/analyze-share.js — 分析结果分享快照
 *
 * 用途：把当前 /api/analyze 的结果固化到 shares/<id>.json，
 *       任何人通过 /api/analyze/share/<id> 只读访问。
 *       快照永久有效，除非管理员显式删除。
 *
 * 存储：shares/<id>.json，一个 id 一份 JSON 文件：
 *   {
 *     id, tag, createdAt, filesNames, data   // data 即 /api/analyze 返回的 j.data
 *   }
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const { SHARES_DIR, ensureDirs } = require('../lib/paths');

const ID_RE = /^[A-Za-z0-9]{6,16}$/;

function _genId() {
    // 8 字符 Url-safe，足以避免日常冲突；冲突时再回退重生成
    return crypto.randomBytes(6).toString('base64').replace(/[+/=]/g, '').slice(0, 8);
}

// POST /api/analyze/share  (admin)  body: { tag, data, filesNames? }
//   → { ok: true, id, createdAt, shareUrl, publicUrl }
function handleCreateShare(req, res) {
    const body = req.body || {};
    const tag = String(body.tag || '').trim();
    const data = body.data;
    if (!data || typeof data !== 'object') {
        return res.status(400).json({ ok: false, error: '缺少 data 字段' });
    }
    ensureDirs();
    // 同一 tag 已存在分享则复用：返回旧链接，不重复创建。
    if (tag) {
        try {
            const existed = fs.readdirSync(SHARES_DIR).filter(f => f.endsWith('.json'));
            for (const f of existed) {
                try {
                    const meta = JSON.parse(fs.readFileSync(path.join(SHARES_DIR, f), 'utf8'));
                    if ((meta.tag || '') === tag) {
                        const id = meta.id;
                        const publicUrl = '/api/analyze/share/' + id;
                        const shareUrl = shareUrlRel2Abs(req, publicUrl);
                        return res.json({ ok: true, id, createdAt: meta.createdAt, shareUrl, publicUrl, reused: true });
                    }
                } catch (_) {}
            }
        } catch (_) {}
    }
    // 生成不重复 id（最多尝试 8 次）
    let id = _genId();
    for (let i = 0; i < 8; i++) {
        const candidate = path.join(SHARES_DIR, id + '.json');
        if (!fs.existsSync(candidate)) break;
        id = _genId();
    }
    const createdAt = new Date().toISOString();
    const snapshot = {
        id,
        tag,
        createdAt,
        filesNames: Array.isArray(body.filesNames) ? body.filesNames.slice(0, 200) : [],
        data,
    };
    fs.writeFileSync(path.join(SHARES_DIR, id + '.json'), JSON.stringify(snapshot), 'utf8');
    const publicUrl = '/api/analyze/share/' + id;
    const shareUrl = shareUrlRel2Abs(req, publicUrl);
    return res.json({ ok: true, id, createdAt, shareUrl, publicUrl });
}

function shareUrlRel2Abs(req, publicPath) {
    if (req && req.headers && req.headers.host) {
        const proto = (req.headers['x-forwarded-proto'] || req.protocol || 'http').toString().split(',')[0];
        return `${proto}://${req.headers.host}${publicPath}`;
    }
    return publicPath;
}

// GET /api/analyze/share/:id  （公开，无需登录）
function handleGetShare(req, res) {
    const id = String(req.params.id || '');
    if (!ID_RE.test(id)) return res.status(400).json({ ok: false, error: 'id 不合法' });
    const file = path.join(SHARES_DIR, id + '.json');
    if (!fs.existsSync(file)) {
        return res.status(404).json({ ok: false, error: '分享不存在或已删除' });
    }
    try {
        const raw = fs.readFileSync(file, 'utf8');
        const obj = JSON.parse(raw);
        return res.json({ ok: true, snapshot: obj });
    } catch (e) {
        return res.status(500).json({ ok: false, error: '快照解析失败' });
    }
}

// GET /api/analyze/shares  (admin)  列出所有分享（仅摘要，不返回 data 全文）
function handleListShares(_req, res) {
    ensureDirs();
    let files = [];
    try { files = fs.readdirSync(SHARES_DIR).filter(f => f.endsWith('.json')); } catch (_) {}
    const items = [];
    for (const f of files) {
        try {
            const raw = fs.readFileSync(path.join(SHARES_DIR, f), 'utf8');
            const obj = JSON.parse(raw);
            items.push({
                id: obj.id,
                tag: obj.tag || '',
                createdAt: obj.createdAt,
                fileCount: Array.isArray(obj.filesNames) ? obj.filesNames.length : 0,
                modelCount: Array.isArray(obj.data && obj.data.models) ? obj.data.models.length : 0,
                size: Buffer.byteLength(raw, 'utf8'),
            });
        } catch (_) {}
    }
    items.sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
    return res.json({ ok: true, items });
}

// DELETE /api/analyze/share/:id  (admin)
function handleDeleteShare(req, res) {
    const id = String(req.params.id || '');
    if (!ID_RE.test(id)) return res.status(400).json({ ok: false, error: 'id 不合法' });
    const file = path.join(SHARES_DIR, id + '.json');
    if (!fs.existsSync(file)) {
        return res.status(404).json({ ok: false, error: '分享不存在' });
    }
    try { fs.unlinkSync(file); } catch (e) {
        return res.status(500).json({ ok: false, error: '删除失败：' + e.message });
    }
    return res.json({ ok: true });
}

module.exports = {
    handleCreateShare,
    handleGetShare,
    handleListShares,
    handleDeleteShare,
};
