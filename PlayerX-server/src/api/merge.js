/**
 * src/api/merge.js — GET /merge
 *
 * 合并 uploads/ 下的 csv 一键下载：
 *   - 默认仅每个 (user, tag) 的最新一份，避免重复行膨胀
 *   - ?all=1 时把目录里所有 csv（含历史）并入
 *
 * 输出 UTF-8 with BOM 的标准 CSV，多份文件只保留首份的表头。
 */
const fs   = require('fs');
const path = require('path');

const { UPLOAD_DIR, ensureDirs } = require('../lib/paths');
const { parseName }              = require('../lib/slug');

function handle(req, res) {
    ensureDirs();
    const all = req.query.all === '1';
    let files = fs.readdirSync(UPLOAD_DIR).filter(n => n.toLowerCase().endsWith('.csv'));

    if (!all) {
        // 按 (user, tag) 取 mtime 最新的那个
        const bucket = new Map();
        for (const n of files) {
            const meta = parseName(n) || {};
            const key = `${meta.user || ''}__${meta.tag || ''}`;
            const st = fs.statSync(path.join(UPLOAD_DIR, n));
            const cur = bucket.get(key);
            if (!cur || cur.mtime < st.mtime) bucket.set(key, { name: n, mtime: st.mtime });
        }
        files = [...bucket.values()].sort((a, b) => a.name < b.name ? -1 : 1).map(x => x.name);
    } else {
        files.sort();
    }

    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.set('Content-Disposition', 'attachment; filename="playerx_all.csv"');
    let first = true;
    for (const n of files) {
        let txt = fs.readFileSync(path.join(UPLOAD_DIR, n), 'utf8');
        if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);
        const lines = txt.split(/\r?\n/);
        if (lines.length === 0) continue;
        if (first) {
            res.write('\uFEFF');
            res.write(lines.join('\n'));
            first = false;
        } else {
            res.write('\n' + lines.slice(1).join('\n'));
        }
    }
    if (first) res.write('\uFEFFupdated_at,rater,file_name,stars\n');
    res.end();
}

module.exports = { handle };
