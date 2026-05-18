/**
 * src/api/list.js — GET /list
 *
 * 列出 uploads/ 目录下所有 CSV，附带 user / tag / mode / size / mtime。
 * 支持 ?mode=subjective|quality|... 仅返回该模式下的记录；不传 = 全部。
 *
 * 同时返回 modes 汇总（{ subjective: 3, quality: 1 }），方便 Web 端按模式分桶/做 Tab。
 */
const { listAll } = require('../lib/store');

function handle(req, res) {
    const wanted = (req.query && req.query.mode != null) ? String(req.query.mode).trim() : '';

    const all = listAll();

    // 模式分桶统计：基于「全部」做汇总，让前端 Tab 上能看到各模式条目数。
    const modes = {};
    for (const it of all) {
        const m = it.mode || 'subjective';
        modes[m] = (modes[m] || 0) + 1;
    }

    const filtered = wanted
        ? all.filter(it => (it.mode || 'subjective') === wanted)
        : all;

    const items = filtered.map(it => ({
        name:  it.name,
        user:  it.user,
        tag:   it.tag,
        mode:  it.mode || 'subjective',
        size:  it.size,
        mtime: it.mtime.toISOString(),
    }));
    res.json({ ok: true, count: items.length, mode: wanted || '', modes, items });
}

module.exports = { handle };
