/**
 * src/api/auth.js — 管理员登录 / 写操作鉴权
 *
 * 设计目标：
 *   - 默认匿名访问可读 / 可下载 / 可合并下载（list / files / merge / preview / archive 浏览）
 *   - 写操作（删除 / 归档 / 批量删除）必须登录后才能执行
 *
 * 实现：
 *   - 管理员密码：环境变量 PLAYERX_ADMIN_PASSWORD，默认 'admin123'
 *   - 登录接口：POST /api/admin/login  body: { password }  → 返回 { ok, token }
 *   - 鉴权：客户端请求头 X-Admin-Token 携带返回的 token
 *   - token 存内存（重启失效，无需持久化），登出从 Set 中移除
 */
const crypto = require('crypto');

function resolveAdminPassword() {
    const raw = process.env.PLAYERX_ADMIN_PASSWORD;
    if (raw === undefined) return 'admin123';
    return String(raw); // 允许显式空字符串 = 关闭鉴权
}

const _validTokens = new Set();

function _genToken() {
    return crypto.randomBytes(24).toString('hex');
}

// 登录处理：验证密码，颁发 token
function handleAdminLogin(req, res) {
    const expected = resolveAdminPassword();
    // 密码为空 = 关闭鉴权，任意密码都能登录
    if (!expected) {
        return res.json({ ok: true, token: '', authDisabled: true });
    }
    const got = (req.body && typeof req.body.password === 'string') ? req.body.password : '';
    if (got !== expected) {
        return res.status(401).json({ ok: false, error: '密码错误' });
    }
    const token = _genToken();
    _validTokens.add(token);
    res.json({ ok: true, token });
}

// 登出处理：作废 token
function handleAdminLogout(req, res) {
    const got = req.header('X-Admin-Token') || '';
    if (got) _validTokens.delete(got);
    res.json({ ok: true });
}

// 写操作鉴权中间件：校验 X-Admin-Token
function requireAdmin(req, res, next) {
    const expected = resolveAdminPassword();
    // 密码为空 = 关闭鉴权，直接放行
    if (!expected) return next();

    const got = req.header('X-Admin-Token') || '';
    if (!got || !_validTokens.has(got)) {
        return res.status(401).json({
            ok: false,
            error: 'NOT_LOGGED_IN',
            message: '该操作需要管理员登录',
        });
    }
    next();
}

// 状态查询：是否启用了鉴权（供前端首屏判断要不要显示登录按钮）
function isAuthEnabled() {
    return !!resolveAdminPassword();
}

// ── 兼容旧导出：上游可能仍依赖 makeAuth ──
function makeAuth(token) {
    return function checkToken(req, res, next) {
        if (!token) return next();
        const got = req.header('X-Token') || req.query.token;
        if (got !== token) {
            return res.status(401).json({ ok: false, error: '[AUTH] token 不匹配' });
        }
        next();
    };
}

module.exports = {
    handleAdminLogin,
    handleAdminLogout,
    requireAdmin,
    isAuthEnabled,
    makeAuth,
};
