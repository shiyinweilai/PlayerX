/**
 * src/api/settings.js — 后端面板用配置接口
 *
 * 接口（均需要管理员登录后才能调用，由 index.js 套上 requireAdmin 中间件）：
 *   GET  /api/settings/upload-token  → { ok, token, isDefault }
 *   PUT  /api/settings/upload-token  body { token: string }  → { ok, token }
 *
 * 规则：
 *   - token 用普通字符串保存，前端按"显示/隐藏"原文展示即可
 *   - 不强制最小长度，但前端会做基本校验（避免误清空导致关闭鉴权）
 */
const { getUploadToken, setUploadToken } = require('../lib/paths');

function handleGet(_req, res) {
    const token = getUploadToken();
    res.json({
        ok: true,
        token,
        enabled: !!token,                   // 空字符串 = 关闭鉴权
        isDefault: token === '123456',
    });
}

function handlePut(req, res) {
    const body = req.body || {};
    if (typeof body.token !== 'string') {
        return res.status(400).json({ ok: false, error: 'token 字段必须为字符串' });
    }
    // 允许显式空字符串 = 关闭鉴权（前端会做二次确认）
    const v = body.token.trim();
    setUploadToken(v);
    res.json({ ok: true, token: v, enabled: !!v });
}

module.exports = { handleGet, handlePut };
