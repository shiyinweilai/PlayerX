/**
 * src/api/preview.js — GET /preview/:name
 *
 * 在线预览 uploads/ 下某个 csv 的内容，返回结构化 JSON（表头 + 行数组），
 * 由 Web 面板渲染成表格。读取严格走白名单，防止越权。
 *
 * 查询参数：
 *   - limit  默认 500，最大 5000（再多体验也不好，建议下载到本地看）
 *
 * 返回：
 *   {
 *     ok: true,
 *     name, size, mtime,
 *     header: ['updated_at','rater','folder','file_name','stars'],
 *     rows:   [[...], [...], ...],
 *     total:  数据行总数（不含表头）,
 *     shown:  实际返回的行数,
 *     truncated: 是否被 limit 截断
 *   }
 */
const fs   = require('fs');
const path = require('path');

const { UPLOAD_DIR, ensureDirs } = require('../lib/paths');

// 极简 CSV 解析：处理 , " \n（与客户端 RatingStore::parseCsvLine 等价）
// 注意：CSV 字段内允许换行（被引号包裹），所以这里逐字符扫描，不能简单 split('\n')。
function parseCsv(text) {
    const out = [];
    let row = [];
    let cur = '';
    let inQuote = false;
    for (let i = 0; i < text.length; ++i) {
        const c = text[i];
        if (inQuote) {
            if (c === '"') {
                if (i + 1 < text.length && text[i + 1] === '"') {
                    cur += '"';
                    ++i;
                } else {
                    inQuote = false;
                }
            } else {
                cur += c;
            }
        } else {
            if (c === ',') {
                row.push(cur);
                cur = '';
            } else if (c === '"') {
                inQuote = true;
            } else if (c === '\n' || c === '\r') {
                // 行结束（吃掉 \r\n 中的 \n）
                row.push(cur);
                cur = '';
                if (row.length > 1 || row[0] !== '') out.push(row);
                row = [];
                if (c === '\r' && text[i + 1] === '\n') ++i;
            } else {
                cur += c;
            }
        }
    }
    // 最后一行（没有结尾换行的情况）
    if (cur !== '' || row.length > 0) {
        row.push(cur);
        if (row.length > 1 || row[0] !== '') out.push(row);
    }
    return out;
}

function handle(req, res) {
    ensureDirs();
    const name = (req.params.name || '').toString();

    // 与 files.js 同款白名单：只允许 uploads/ 直接子项
    if (!/^[A-Za-z0-9._\-\u4e00-\u9fa5]+\.csv$/.test(name)) {
        return res.status(400).json({ ok: false, error: 'invalid file name' });
    }
    const fp = path.join(UPLOAD_DIR, name);
    if (!fs.existsSync(fp)) {
        return res.status(404).json({ ok: false, error: 'not found' });
    }

    let limit = parseInt(req.query.limit, 10);
    if (!Number.isFinite(limit) || limit <= 0) limit = 500;
    if (limit > 5000) limit = 5000;

    let txt;
    try {
        txt = fs.readFileSync(fp, 'utf8');
    } catch (e) {
        return res.status(500).json({ ok: false, error: 'read failed: ' + e.message });
    }
    // 剥 BOM
    if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);

    const all = parseCsv(txt);
    if (all.length === 0) {
        return res.json({
            ok: true, name,
            header: [], rows: [], total: 0, shown: 0, truncated: false,
            size: 0, mtime: null,
        });
    }
    const header = all[0];
    const dataRows = all.slice(1);
    const total = dataRows.length;
    const truncated = total > limit;
    const rows = truncated ? dataRows.slice(0, limit) : dataRows;

    let st;
    try { st = fs.statSync(fp); } catch (_) { st = null; }

    res.json({
        ok: true,
        name,
        header,
        rows,
        total,
        shown: rows.length,
        truncated,
        size:  st ? st.size : 0,
        mtime: st ? st.mtime.toISOString() : null,
    });
}

module.exports = { handle };
