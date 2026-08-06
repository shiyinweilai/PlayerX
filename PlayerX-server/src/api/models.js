/**
 * src/api/models.js — 模型源目录管理
 *
 * 数据存储: models-config.json（项目根目录）
 * 格式: { sources: [ { id, name, path, models: [string] } ] }
 *
 * API:
 *   GET/api/models           — 获取全部源目录配置
 *   POST /api/models           — 新增源目录
 *   PUT  /api/models/:id       — 更新源目录
 *   DELETE /api/models/:id     — 删除源目录
 *   POST /api/models/scan      — 扫描指定路径下的子目录
 */
const fs   = require('fs');
const path = require('path');

const DATA_FILE = path.join(__dirname, '../../models-config.json');

function loadData() {
    try {
        if (fs.existsSync(DATA_FILE)) {
            return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
        }
    } catch (_) {}
    return { sources: [] };
}

function saveData(data) {
    fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2), 'utf8');
}

function genId() {
    return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

// GET /api/models
function handleList(req, res) {
    const data = loadData();
    res.json({ ok: true, sources: data.sources });
}

// POST /api/models  body: { name, path, scope?, owner? }
function handleCreate(req, res) {
    const { name: rawName, path: dirPath, scope, owner } = req.body || {};
    const data = loadData();
    const existingCount = data.sources.length;
    const name = rawName || `测试集${existingCount + 1}`;
    const entry = { id: genId(), name, path: dirPath || '', models: [], scope: scope || 'personal', owner: owner || '' };
    data.sources.push(entry);
  saveData(data);
    res.json({ ok: true, source: entry });
}

// PUT /api/models/:id  body: { name?, path?, models? }
function handleUpdate(req, res) {
    const { id } = req.params;
    const data = loadData();
    const idx = data.sources.findIndex(s => s.id === id);
    if (idx === -1) return res.status(404).json({ ok: false, error: '未找到该源' });
    const updates = req.body || {};
    if (updates.name !== undefined) data.sources[idx].name = updates.name;
    if (updates.path !== undefined) data.sources[idx].path = updates.path;
    if (updates.models !== undefined) data.sources[idx].models = updates.models;
    if (updates.scope !== undefined) data.sources[idx].scope = updates.scope;
    if (updates.owner !== undefined) data.sources[idx].owner = updates.owner;
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

// POST /api/models/scan  body: { path }
function handleScan(req, res) {
    const { path: dirPath } = req.body || {};
    if (!dirPath) return res.status(400).json({ ok: false, error: '缺少 path' });
    try {
     if (!fs.existsSync(dirPath) || !fs.statSync(dirPath).isDirectory()) {
            return res.status(400).json({ ok: false, error: `目录不存在: ${dirPath}` });
   }
 const entries = fs.readdirSync(dirPath, { withFileTypes: true });
        const dirs = entries
            .filter(e => e.isDirectory() && !e.name.startsWith('.'))
     .map(e => e.name)
            .sort();
        // 检查每个子目录是否还有下级子目录
        const dirsInfo = dirs.map(d => {
            const subPath = path.join(dirPath, d);
     let hasChildren = false;
            try {
    const subEntries = fs.readdirSync(subPath, { withFileTypes: true });
           hasChildren = subEntries.some(e => e.isDirectory() && !e.name.startsWith('.'));
            } catch (_) {}
         return { name: d, hasChildren };
        });
        res.json({ ok: true, dirs, dirsInfo });
    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    }
}

module.exports = { handleList, handleCreate, handleUpdate, handleDelete, handleScan };
