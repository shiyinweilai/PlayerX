/**
 * src/api/status.js — GET /api/status
 *
 * 给 Web 面板首屏渲染用：返回服务名/版本号/当前时间。
 * 服务端已不再做鉴权，因此 tokenRequired 恒为 false（保留字段是为了不破坏前端旧逻辑）。
 */
const pkg = require('../../package.json');

function makeHandler() {
    return function handle(_req, res) {
        res.json({
            ok: true,
            name: pkg.name,
            version: pkg.version,
            tokenRequired: false,
            time: new Date().toISOString(),
        });
    };
}

module.exports = { makeHandler };
