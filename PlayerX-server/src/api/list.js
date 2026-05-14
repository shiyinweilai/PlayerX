/**
 * src/api/list.js — GET /list
 *
 * 列出 uploads/ 目录下所有 CSV，附带 user / tag / size / mtime。
 * Web 面板与客户端调试都可以直接消费这份 JSON。
 */
const { listAll } = require('../lib/store');

function handle(_req, res) {
    const items = listAll().map(it => ({
        name:  it.name,
        user:  it.user,
        tag:   it.tag,
        size:  it.size,
        mtime: it.mtime.toISOString(),
    }));
    res.json({ ok: true, count: items.length, items });
}

module.exports = { handle };
