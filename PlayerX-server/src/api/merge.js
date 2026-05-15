/**
 * src/api/merge.js — GET/POST /merge & /api/merge
 *
 * 合并 uploads/ 下的 csv 一键下载：
 *   - 默认仅每个 (user, tag) 的最新一份，避免重复行膨胀
 *   - ?all=1 时把目录里所有 csv（含历史）并入
 *   - ?names=a.csv,b.csv 或 POST body { names: [...] } 时只合并这个子集
 *     （names 与 all 同时存在时，names 优先；用于"合并下载选中"）
 *
 * 输出 UTF-8 with BOM 的标准 CSV，多份文件只保留首份的表头。
 */
const fs   = require('fs');
const path = require('path');

const { UPLOAD_DIR, ensureDirs } = require('../lib/paths');
const { parseName }              = require('../lib/slug');

const NAME_RE = /^[A-Za-z0-9._\-\u4e00-\u9fa5]+\.csv$/;

// CSV 字段转义：含逗号/引号/换行时用双引号包裹并把引号翻倍
function csvCell(v) {
    const s = (v == null ? '' : String(v));
    if (/[",\r\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
    return s;
}

// 把一份 csv 的内容（已去 BOM）按行附加 tag 列：
//   - withHeader=true：首行视为表头，追加 ",tag"
//   - withHeader=false：跳过首行（用于第二份及以后的拼接，丢掉它的表头）
//   - 其他非空行末尾追加 ",<tag>"；空行原样保留
function appendTagToCsv(text, tag, withHeader) {
    const cell = csvCell(tag);
    const lines = text.split(/\r?\n/);
    const out = [];
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (i === 0) {
            if (!withHeader) continue; // 第二份起跳过它的表头
            out.push(line.length === 0 ? line : line + ',tag');
            continue;
        }
        if (line.length === 0) { out.push(line); continue; }
        out.push(line + ',' + cell);
    }
    return out.join('\n');
}

function pickNamesFromReq(req) {
    // POST body.names: array
    if (req.body && Array.isArray(req.body.names)) {
        return req.body.names.map(x => String(x || '').trim()).filter(Boolean);
    }
    // GET query.names: 逗号分隔字符串 或 数组
    const q = req.query ? req.query.names : null;
    if (Array.isArray(q)) return q.map(x => String(x || '').trim()).filter(Boolean);
    if (typeof q === 'string' && q) {
        return q.split(',').map(s => s.trim()).filter(Boolean);
    }
    return [];
}

function handle(req, res) {
    ensureDirs();

    const all = req.query && req.query.all === '1';
    const requested = pickNamesFromReq(req);
    const useSubset = requested.length > 0;

    // 列出 uploads 目录
    let allFiles;
    try {
        allFiles = fs.readdirSync(UPLOAD_DIR).filter(n => n.toLowerCase().endsWith('.csv'));
    } catch (_) { allFiles = []; }

    let files;
    if (useSubset) {
        // 走 names 白名单：严格校验 + 只保留实际存在的
        const set = new Set(allFiles);
        const seen = new Set();
        files = [];
        for (const n of requested) {
            if (!NAME_RE.test(n))   continue;
            if (!set.has(n))        continue;
            if (seen.has(n))        continue;
            seen.add(n);
            files.push(n);
        }
        files.sort();
    } else if (!all) {
        // 按 (user, tag) 取 mtime 最新的那个
        const bucket = new Map();
        for (const n of allFiles) {
            const meta = parseName(n) || {};
            const key = `${meta.user || ''}__${meta.tag || ''}`;
            const st = fs.statSync(path.join(UPLOAD_DIR, n));
            const cur = bucket.get(key);
            if (!cur || cur.mtime < st.mtime) bucket.set(key, { name: n, mtime: st.mtime });
        }
        files = [...bucket.values()].sort((a, b) => a.name < b.name ? -1 : 1).map(x => x.name);
    } else {
        files = allFiles.slice().sort();
    }

    // 导出文件名：选中合并 → playerx_selected.csv；全部 → playerx_all.csv；默认最新 → playerx_latest.csv
    let outName = 'playerx_latest.csv';
    if (useSubset) outName = 'playerx_selected.csv';
    else if (all)  outName = 'playerx_all.csv';

    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.set('Content-Disposition', `attachment; filename="${outName}"`);

    let first = true;
    for (const n of files) {
        let txt;
        try { txt = fs.readFileSync(path.join(UPLOAD_DIR, n), 'utf8'); }
        catch (_) { continue; }
        if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);
        const meta = parseName(n) || {};
        const tag = meta.tag || '';
        const out = appendTagToCsv(txt, tag, first);
        if (out.length === 0) continue;
        if (first) {
            res.write('\uFEFF');
            res.write(out);
            first = false;
        } else {
            res.write('\n' + out);
        }
    }
    if (first) res.write('\uFEFFupdated_at,rater,folder,file_name,stars,tag\n');
    res.end();
}

module.exports = { handle };
