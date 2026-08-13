/**
 * src/api/models.js — 模型源目录管理
 *
 * 数据存储: models-config.json（项目根目录）
 * 格式: { sources: [ { id, name, path, models: [string] } ] }
 */
const fs     = require('fs');
const path   = require('path');
const multer = require('multer');

const {
    ROOT_DIR,
    ASSETS_DIR,
    ensureDirs,
    resolveSourcePath,
    relativizeSourcePath,
} = require('../lib/paths');

const DATA_FILE = path.join(__dirname, '../../models-config.json');

function loadData() {
    try { if (fs.existsSync(DATA_FILE)) return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); } catch (_) {}
    return { sources: [] };
}
function saveData(data) { fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2), 'utf8'); }
function genId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 8); }

function normalizeIncomingPath(p) {
    if (!p) return '';
    const t = String(p).trim();
    // 相对路径（含 assets/ 前缀）统一走 resolveSourcePath，保证 assets 迁入
    // data/ 后依然能定位到正确位置。
    return path.isAbsolute(t) ? t : resolveSourcePath(t);
}
function sanitizeFolderName(raw) {
    let s = String(raw || '').trim();
    s = s.split(/[\\/]/).pop() || '';
    s = s.replace(/[^\w一-龥\- .]/g, '_').replace(/^\.+/, '').trim();
    if (!s) s = `folder_${Date.now().toString(36)}`;
    if (s.length > 80) s = s.slice(0, 80);
    return s;
}

// GET /api/models
function handleList(req, res) {
    const data = loadData();
    res.json({ ok: true, sources: data.sources });
}

// POST /api/models
function handleCreate(req, res) {
    const { name: rawName, path: dirPath, scope, owner } = req.body || {};
    const data = loadData();
    const absPath = normalizeIncomingPath(dirPath);
    let storedPath = '';
    if (absPath) {
        try { if (fs.existsSync(absPath) && fs.statSync(absPath).isDirectory()) storedPath = relativizeSourcePath(absPath); }
            catch (_) {}
        if (!storedPath) storedPath = path.isAbsolute(dirPath || '') ? absPath : relativizeSourcePath(absPath);
    }
    const name = rawName || `测试集${data.sources.length + 1}`;
    const entry = { id: genId(), name, path: storedPath, models: [], scope: scope || 'personal', owner: owner || '' };
    data.sources.unshift(entry);
    saveData(data);
    res.json({ ok: true, source: entry });
}

// PUT /api/models/:id
function handleUpdate(req, res) {
    const { id } = req.params;
    const data = loadData();
    const idx = data.sources.findIndex(s => s.id === id);
    if (idx === -1) return res.status(404).json({ ok: false, error: '未找到该源' });
    const u = req.body || {};
    if (u.name !== undefined) data.sources[idx].name = u.name;
    if (u.path !== undefined) {
        const ap = normalizeIncomingPath(u.path);
        data.sources[idx].path = path.isAbsolute(u.path || '') ? ap : relativizeSourcePath(ap);
    }
    if (u.models !== undefined) data.sources[idx].models = u.models;
    if (u.scope !== undefined) data.sources[idx].scope = u.scope;
    if (u.owner !== undefined) data.sources[idx].owner = u.owner;
    saveData(data);
    res.json({ ok: true, source: data.sources[idx] });
}

// DELETE /api/models/:id
function handleDelete(req, res) {
    const { id } = req.params;
    const data = loadData();
    const idx = data.sources.findIndex(s => s.id === id);
    if (idx === -1) return res.status(404).json({ ok: false, error: '未找到该源' });
    data.sources.splice(idx, 1);
    saveData(data);
    res.json({ ok: true });
}

// POST /api/models/scan
function handleScan(req, res) {
    const { path: dirPath } = req.body || {};
    if (!dirPath) return res.status(400).json({ ok: false, error: '缺少 path' });
    const target = normalizeIncomingPath(dirPath);
    try {
        if (!fs.existsSync(target) || !fs.statSync(target).isDirectory())
            return res.status(400).json({ ok: false, error: `目录不存在: ${target}` });
        const entries = fs.readdirSync(target, { withFileTypes: true });
        const dirs = entries.filter(e => e.isDirectory() && !e.name.startsWith('.')).map(e => e.name).sort();
        const dirsInfo = dirs.map(d => {
            let hc = false;
            try { const sub = fs.readdirSync(path.join(target, d), { withFileTypes: true }); hc = sub.some(e => e.isDirectory() && !e.name.startsWith('.')); } catch (_) {}
            return { name: d, hasChildren: hc };
        });
        res.json({ ok: true, dirs, dirsInfo });
    } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
}

// ─────────────────────────────────────────────────────────────
// POST /api/models/upload-folder
//
// 字段：file=<任意文件>
//
// 行为：直接把文件存到 <DATA_DIR>/assets/<filename>（data/assets）。
//       不做任何解压、拍平、MD5、models-config.json 修改。
//       后续若要添加到源列表，用户自行到"模型管理"页面添加。
// ─────────────────────────────────────────────────────────────
const zipUpload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: 2 * 1024 * 1024 * 1024 },
    preservePath: true,    // 保留 webkitRelativePath 中的子目录路径（不被 path.basename 截断）
});

// 拒绝 path traversal / 绝对路径
function _safeJoin(base, entryName) {
    if (path.isAbsolute(entryName)) return null;
    if (entryName.split(/[\\/]/).some(seg => seg === '..')) return null;
    const resolved = path.resolve(base, entryName);
    if (!resolved.startsWith(base + path.sep) && resolved !== base) return null;
    return resolved;
}

function handleUploadFolder(req, res) {
    const files = req.files || (req.file ? [req.file] : []);
    if (files.length === 0) return res.status(400).json({ ok: false, error: '缺少文件字段 file' });

    ensureDirs();

    const saved = [];
    let totalSize = 0;
    try {
        for (const f of files) {
            const rawOrig = f.originalname || `upload_${Date.now()}`;
            // 把 latin1 → utf8 还原中文文件名（multer 默认 latin1）
            let decoded = Buffer.from(rawOrig, 'latin1').toString('utf8');

            // 决定 target 路径：
            //   1) 含 / （webKitRelativePath 形式）：folderUpload 模式
            //      → 把路径里第一段（根目录名）当 folderName，里面是子目录
            //   2) 不含 /：单文件模式
            let target, fileNameForReport;
            if (decoded.includes('/')) {
                // 文件夹模式：建子目录保留结构
                const parts = decoded.split('/').filter(Boolean);
                const rootName = sanitizeFolderName(parts[0]);
                const innerRel = parts.slice(1).join('/');

                // 创建（或复用）根目录
                let rootDir = path.join(ASSETS_DIR, rootName);
                let counter = 1;
                while (fs.existsSync(rootDir) && !fs.statSync(rootDir).isDirectory()) {
                    rootDir = path.join(ASSETS_DIR, `${rootName}_${counter}`);
                    counter++;
                }
                fs.mkdirSync(rootDir, { recursive: true });

                // 写入完整子路径
                const dst = innerRel ? _safeJoin(rootDir, innerRel) : null;
                if (!dst) {
                    console.warn('[upload] skip unsafe path:', decoded);
                    continue;
                }
                fs.mkdirSync(path.dirname(dst), { recursive: true });
                fs.writeFileSync(dst, f.buffer);
                target = dst;
                fileNameForReport = path.relative(ASSETS_DIR, dst);
            } else {
                // 单文件模式
                fileNameForReport = path.basename(decoded) || `upload_${Date.now()}`;
                target = path.join(ASSETS_DIR, fileNameForReport);
                let counter = 1;
                while (fs.existsSync(target)) {
                    const p = path.parse(fileNameForReport);
                    target = path.join(ASSETS_DIR, `${p.name}_${++counter}${p.ext}`);
                }
                fs.writeFileSync(target, f.buffer);
            }
            totalSize += f.size;
            saved.push({ original: decoded, savedTo: target, relativePath: relativizeSourcePath(target), size: f.size });
        }
    } catch (e) {
        for (const s of saved) {
            try { fs.rmSync(s.savedTo, { force: true }); } catch (_) {}
        }
        return res.status(500).json({ ok: false, error: '写入文件失败: ' + e.message });
    }

    if (files.length === 1) {
        res.json({ ok: true, ...saved[0], fileCount: 1 });
    } else {
        res.json({ ok: true, fileCount: saved.length, totalSize, files: saved });
    }
    console.log(`[models.upload-folder] uploaded ${saved.length} files, total ${(totalSize / 1024).toFixed(1)} KB`);
}

module.exports = {
    handleList, handleCreate, handleUpdate, handleDelete, handleScan,
    handleUploadFolder,
    zipUploadMiddleware: zipUpload.array('file'),
    resolveSourcePath, relativizeSourcePath, ROOT_DIR,
};