/**
 * src/api/archive.js — 归档目录的批量操作 + 浏览/下载/删除
 *
 *  归档操作（uploads → archive）:
 *    POST   /api/archive                       { names, folder }
 *    POST   /api/files/bulk-delete             { names }
 *
 *  归档浏览（archive/<folder>/...）：
 *    GET    /api/archive/folders               列出所有归档文件夹（含统计）
 *    GET    /api/archive/list?folder=xxx       列出某归档文件夹内 csv
 *    GET    /api/archive/file/:folder/:name    下载某归档文件
 *    GET    /api/archive/preview/:folder/:name 预览某归档 csv
 *    DELETE /api/archive/file/:folder/:name    删除单个归档文件（空文件夹自动 rmdir）
 *    DELETE /api/archive/folder/:folder        删除整个归档文件夹（连带其中所有 csv）
 *    POST   /api/archive/bulk-delete           { folder, names } 批量删除归档
 *
 * 防越权：
 *   - name 严格白名单：与 files.js / delete.js 一致（扁平 .csv）。
 *   - folder 严格白名单：仅允许 [A-Za-z0-9._\-\u4e00-\u9fa5 ] 1~64 位，且不能以 . 开头。
 *     （禁止 / \ : 等任何路径分隔符与上跳。）
 */
const fs   = require('fs');
const path = require('path');

const { UPLOAD_DIR, ARCHIVE_DIR, ensureDirs } = require('../lib/paths');

const NAME_RE   = /^[A-Za-z0-9._\-\u4e00-\u9fa5]+\.csv$/;
const FOLDER_RE = /^[A-Za-z0-9._\-\u4e00-\u9fa5 ]{1,64}$/;

function ensureArchive() {
    ensureDirs();
    fs.mkdirSync(ARCHIVE_DIR, { recursive: true });
}

function isValidFolder(s) {
    return typeof s === 'string'
        && FOLDER_RE.test(s)
        && !s.startsWith('.');
}

function resolveArchiveFolder(folderRaw) {
    if (!isValidFolder(folderRaw)) return null;
    const dir = path.join(ARCHIVE_DIR, folderRaw);
    // 二次校验：解析结果必须仍在 ARCHIVE_DIR 之内
    const rel = path.relative(ARCHIVE_DIR, dir);
    if (rel.startsWith('..') || path.isAbsolute(rel)) return null;
    return dir;
}

function pickNames(body) {
    const arr = body && Array.isArray(body.names) ? body.names : [];
    // 去重 + 类型过滤
    const seen = new Set();
    const out = [];
    for (const x of arr) {
        const s = (x == null ? '' : String(x)).trim();
        if (!s || seen.has(s)) continue;
        seen.add(s);
        out.push(s);
    }
    return out;
}

function tsSuffix() {
    const d = new Date();
    const pad = (x) => String(x).padStart(2, '0');
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

// ────────── CSV 解析（与 preview.js 保持一致；保留在本模块以避免循环依赖） ──────────
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
    if (cur !== '' || row.length > 0) {
        row.push(cur);
        if (row.length > 1 || row[0] !== '') out.push(row);
    }
    return out;
}

// ────────── 归档操作（uploads → archive） ──────────

// POST /api/archive
function handleArchive(req, res) {
    ensureArchive();
    const folderRaw = (req.body && req.body.folder ? String(req.body.folder) : '').trim();
    const names = pickNames(req.body);

    if (!isValidFolder(folderRaw)) {
        return res.status(400).json({ ok: false, error: 'invalid folder name' });
    }
    if (names.length === 0) {
        return res.status(400).json({ ok: false, error: 'names required' });
    }

    const dstDir = path.join(ARCHIVE_DIR, folderRaw);
    fs.mkdirSync(dstDir, { recursive: true });

    const moved  = [];
    const failed = [];

    for (const n of names) {
        if (!NAME_RE.test(n)) { failed.push({ name: n, error: 'invalid name' }); continue; }
        const src = path.join(UPLOAD_DIR, n);
        if (!fs.existsSync(src)) { failed.push({ name: n, error: 'not found' }); continue; }

        // 重名时挂时间戳，避免覆盖
        let dst = path.join(dstDir, n);
        if (fs.existsSync(dst)) {
            const ext  = path.extname(n);
            const stem = n.slice(0, n.length - ext.length);
            dst = path.join(dstDir, `${stem}.${tsSuffix()}${ext}`);
        }
        try {
            fs.renameSync(src, dst);
            moved.push({ name: n, archived: path.basename(dst) });
        } catch (e) {
            // 跨设备 rename 失败时，回退到 copy + unlink
            try {
                fs.copyFileSync(src, dst);
                fs.unlinkSync(src);
                moved.push({ name: n, archived: path.basename(dst) });
            } catch (e2) {
                failed.push({ name: n, error: e2.message || 'archive failed' });
            }
        }
    }

    return res.json({
        ok: true,
        folder: folderRaw,
        moved,
        failed,
        movedCount:  moved.length,
        failedCount: failed.length,
    });
}

// POST /api/files/bulk-delete  （uploads/）
function handleBulkDelete(req, res) {
    ensureDirs();
    const names = pickNames(req.body);
    if (names.length === 0) {
        return res.status(400).json({ ok: false, error: 'names required' });
    }
    const deleted = [];
    const failed  = [];
    for (const n of names) {
        if (!NAME_RE.test(n)) { failed.push({ name: n, error: 'invalid name' }); continue; }
        const fp = path.join(UPLOAD_DIR, n);
        if (!fs.existsSync(fp)) { failed.push({ name: n, error: 'not found' }); continue; }
        try {
            fs.unlinkSync(fp);
            deleted.push(n);
        } catch (e) {
            failed.push({ name: n, error: e.message || 'unlink failed' });
        }
    }
    return res.json({
        ok: true,
        deleted,
        failed,
        deletedCount: deleted.length,
        failedCount:  failed.length,
    });
}

// ────────── 归档浏览 ──────────

// 给定归档子目录，返回 [{name,size,mtime}]，按 mtime 倒序
function readArchiveFolder(dir) {
    if (!fs.existsSync(dir)) return [];
    return fs.readdirSync(dir)
        .filter(n => n.toLowerCase().endsWith('.csv') && NAME_RE.test(n))
        .map(n => {
            const st = fs.statSync(path.join(dir, n));
            return { name: n, size: st.size, mtime: st.mtime };
        })
        .sort((a, b) => b.mtime - a.mtime);
}

// GET /api/archive/folders
function handleListFolders(_req, res) {
    ensureArchive();
    const folders = [];
    let entries = [];
    try {
        entries = fs.readdirSync(ARCHIVE_DIR, { withFileTypes: true });
    } catch (_) { entries = []; }
    for (const ent of entries) {
        if (!ent.isDirectory()) continue;
        if (!isValidFolder(ent.name)) continue;
        const dir = path.join(ARCHIVE_DIR, ent.name);
        const items = readArchiveFolder(dir);
        const total = items.reduce((s, x) => s + (+x.size || 0), 0);
        const latest = items.length ? items[0].mtime : null;
        folders.push({
            name:  ent.name,
            count: items.length,
            size:  total,
            mtime: latest,
        });
    }
    folders.sort((a, b) => {
        const av = a.mtime ? a.mtime.getTime() : 0;
        const bv = b.mtime ? b.mtime.getTime() : 0;
        return bv - av;
    });
    res.json({ ok: true, folders });
}

// GET /api/archive/list?folder=xxx
function handleListFolderFiles(req, res) {
    ensureArchive();
    const folderRaw = (req.query.folder == null ? '' : String(req.query.folder)).trim();
    const dir = resolveArchiveFolder(folderRaw);
    if (!dir) return res.status(400).json({ ok: false, error: 'invalid folder' });
    if (!fs.existsSync(dir)) return res.status(404).json({ ok: false, error: 'folder not found' });
    const items = readArchiveFolder(dir);
    res.json({ ok: true, folder: folderRaw, items });
}

// GET /api/archive/file/:folder/:name  （下载）
function handleDownloadArchived(req, res) {
    ensureArchive();
    const folderRaw = (req.params.folder || '').toString();
    const name      = (req.params.name   || '').toString();
    const dir = resolveArchiveFolder(folderRaw);
    if (!dir) return res.status(400).json({ ok: false, error: 'invalid folder' });
    if (!NAME_RE.test(name)) return res.status(400).json({ ok: false, error: 'invalid file name' });
    const fp = path.join(dir, name);
    if (!fs.existsSync(fp)) return res.status(404).json({ ok: false, error: 'not found' });
    res.download(fp, name);
}

// GET /api/archive/preview/:folder/:name
function handlePreviewArchived(req, res) {
    ensureArchive();
    const folderRaw = (req.params.folder || '').toString();
    const name      = (req.params.name   || '').toString();
    const dir = resolveArchiveFolder(folderRaw);
    if (!dir) return res.status(400).json({ ok: false, error: 'invalid folder' });
    if (!NAME_RE.test(name)) return res.status(400).json({ ok: false, error: 'invalid file name' });
    const fp = path.join(dir, name);
    if (!fs.existsSync(fp)) return res.status(404).json({ ok: false, error: 'not found' });

    let limit = parseInt(req.query.limit, 10);
    if (!Number.isFinite(limit) || limit <= 0) limit = 500;
    if (limit > 5000) limit = 5000;

    let txt;
    try { txt = fs.readFileSync(fp, 'utf8'); }
    catch (e) { return res.status(500).json({ ok: false, error: 'read failed: ' + e.message }); }
    if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);

    const all = parseCsv(txt);
    if (all.length === 0) {
        return res.json({
            ok: true, name, folder: folderRaw,
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
        name, folder: folderRaw,
        header, rows, total,
        shown: rows.length, truncated,
        size:  st ? st.size : 0,
        mtime: st ? st.mtime.toISOString() : null,
    });
}

// 若文件夹已空，自动 rmdir（忽略错误）
function rmdirIfEmpty(dir) {
    try {
        const remain = fs.readdirSync(dir);
        if (remain.length === 0) fs.rmdirSync(dir);
    } catch (_) { /* ignore */ }
}

// DELETE /api/archive/file/:folder/:name
function handleDeleteArchivedFile(req, res) {
    ensureArchive();
    const folderRaw = (req.params.folder || '').toString();
    const name      = (req.params.name   || '').toString();
    const dir = resolveArchiveFolder(folderRaw);
    if (!dir) return res.status(400).json({ ok: false, error: 'invalid folder' });
    if (!NAME_RE.test(name)) return res.status(400).json({ ok: false, error: 'invalid file name' });
    const fp = path.join(dir, name);
    if (!fs.existsSync(fp)) return res.status(404).json({ ok: false, error: 'not found' });
    try {
        fs.unlinkSync(fp);
        rmdirIfEmpty(dir);
        return res.json({ ok: true, name, folder: folderRaw });
    } catch (e) {
        return res.status(500).json({ ok: false, error: e.message || 'unlink failed' });
    }
}

// DELETE /api/archive/folder/:folder
function handleDeleteArchiveFolder(req, res) {
    ensureArchive();
    const folderRaw = (req.params.folder || '').toString();
    const dir = resolveArchiveFolder(folderRaw);
    if (!dir) return res.status(400).json({ ok: false, error: 'invalid folder' });
    if (!fs.existsSync(dir)) return res.status(404).json({ ok: false, error: 'folder not found' });

    const deleted = [];
    const failed  = [];
    let entries = [];
    try { entries = fs.readdirSync(dir); } catch (_) { entries = []; }
    for (const n of entries) {
        // 严格只删 csv，其他未知文件原样保留（更安全）
        if (!n.toLowerCase().endsWith('.csv') || !NAME_RE.test(n)) {
            failed.push({ name: n, error: 'skipped (non-csv)' });
            continue;
        }
        try {
            fs.unlinkSync(path.join(dir, n));
            deleted.push(n);
        } catch (e) {
            failed.push({ name: n, error: e.message || 'unlink failed' });
        }
    }
    rmdirIfEmpty(dir);
    res.json({
        ok: true,
        folder: folderRaw,
        deleted, failed,
        deletedCount: deleted.length,
        failedCount:  failed.length,
        folderRemoved: !fs.existsSync(dir),
    });
}

// POST /api/archive/bulk-delete  { folder, names }
function handleBulkDeleteArchived(req, res) {
    ensureArchive();
    const folderRaw = (req.body && req.body.folder ? String(req.body.folder) : '').trim();
    const dir = resolveArchiveFolder(folderRaw);
    if (!dir) return res.status(400).json({ ok: false, error: 'invalid folder' });
    if (!fs.existsSync(dir)) return res.status(404).json({ ok: false, error: 'folder not found' });
    const names = pickNames(req.body);
    if (names.length === 0) return res.status(400).json({ ok: false, error: 'names required' });

    const deleted = [];
    const failed  = [];
    for (const n of names) {
        if (!NAME_RE.test(n)) { failed.push({ name: n, error: 'invalid name' }); continue; }
        const fp = path.join(dir, n);
        if (!fs.existsSync(fp)) { failed.push({ name: n, error: 'not found' }); continue; }
        try {
            fs.unlinkSync(fp);
            deleted.push(n);
        } catch (e) {
            failed.push({ name: n, error: e.message || 'unlink failed' });
        }
    }
    rmdirIfEmpty(dir);
    res.json({
        ok: true,
        folder: folderRaw,
        deleted, failed,
        deletedCount: deleted.length,
        failedCount:  failed.length,
        folderRemoved: !fs.existsSync(dir),
    });
}

module.exports = {
    handleArchive,
    handleBulkDelete,
    handleListFolders,
    handleListFolderFiles,
    handleDownloadArchived,
    handlePreviewArchived,
    handleDeleteArchivedFile,
    handleDeleteArchiveFolder,
    handleBulkDeleteArchived,
};
