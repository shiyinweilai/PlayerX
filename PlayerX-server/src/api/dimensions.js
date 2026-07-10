/**
 * src/api/dimensions.js — 评分配置管理接口
 *
 * 存储：服务器根目录 configs/ 目录，每个 .json 文件为一份配置
 * JSON 格式：{ "type": "多维评分", "task": "...", "scale": "...", "dimensions": [...] }
 *
 * 接口：
 *   GET  /api/configs              → 返回所有配置文件列表（公开）
 *   GET  /api/configs/:name        → 返回指定配置内容（公开）
 *   PUT  /api/configs/:name        → 新建/更新指定配置（管理员）
 *   DELETE /api/configs/:name      → 删除指定配置（管理员）
 *
 *   GET  /api/active-config        → 返回当前激活的配置名（公开）
 *   PUT  /api/active-config        → 设置激活配置（管理员）
 *
 *   GET  /api/dimensions           → 返回激活配置内容（公开，供播放器拉取）
 *   PUT  /api/dimensions           → 兼容旧客户端，写入 multi_dim.json（管理员）
 */
const fs   = require('fs');
const path = require('path');

// configs/ 目录存放在项目根目录（server.js 同级）
const CONFIGS_DIR = path.join(__dirname, '../../configs');

// 旧版单文件路径（兼容迁移）
const LEGACY_DIM_FILE = path.join(__dirname, '../../dimensions.json');

// 激活配置记录文件（存在 configs/ 目录下）
const ACTIVE_CONFIG_FILE = path.join(__dirname, '../../configs/_active.json');

/** 读取当前激活的配置名（不含 .json），不存在则返回 null */
function getActiveConfigName() {
    try {
        if (fs.existsSync(ACTIVE_CONFIG_FILE)) {
            const obj = JSON.parse(fs.readFileSync(ACTIVE_CONFIG_FILE, 'utf8'));
            return obj.name || null;
        }
    } catch (_) {}
    return null;
}

/** 写入激活配置名 */
function setActiveConfigName(name) {
    ensureConfigsDir();
    fs.writeFileSync(ACTIVE_CONFIG_FILE, JSON.stringify({ name }, null, 2), 'utf8');
}

/** 确保 configs 目录存在，并迁移旧 dimensions.json */
function ensureConfigsDir() {
    if (!fs.existsSync(CONFIGS_DIR)) {
        fs.mkdirSync(CONFIGS_DIR, { recursive: true });
    }
    // 迁移旧文件（迁移后删除旧文件，避免重复生成）
    if (fs.existsSync(LEGACY_DIM_FILE)) {
        const dest = path.join(CONFIGS_DIR, 'multi_dim.json');
        if (!fs.existsSync(dest)) {
            try {
                let raw = fs.readFileSync(LEGACY_DIM_FILE, 'utf8');
                // 注入 type 字段（如果没有）
                const obj = JSON.parse(raw);
                if (!obj.type) {
                    obj.type = '多维评分';
                    raw = JSON.stringify(obj, null, 2);
                }
                fs.writeFileSync(dest, raw, 'utf8');
            } catch (_) {}
        }
        // 迁移完成后删除旧文件，防止每次请求都触发重建
        try { fs.unlinkSync(LEGACY_DIM_FILE); } catch (_) {}
    }
}

/** 安全校验文件名（只允许字母数字下划线横线，防路径穿越） */
function safeName(name) {
    return /^[a-zA-Z0-9_\-\u4e00-\u9fa5]{1,64}$/.test(name) ? name : null;
}

/** 公共 CORS 头 */
function setCors(res) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
}

// ─────────────────────────────────────────────────────────────
// GET /api/configs — 返回所有配置文件列表
// ─────────────────────────────────────────────────────────────
function handleList(_req, res) {
    setCors(res);
    ensureConfigsDir();
    try {
        const activeName = getActiveConfigName();
        const files = fs.readdirSync(CONFIGS_DIR)
            .filter(f => f.endsWith('.json') && f !== '_active.json')
            .map(f => {
                const name = f.replace(/\.json$/, '');
                let meta = { name, type: '', task: '', active: name === activeName };
                try {
                    const obj = JSON.parse(fs.readFileSync(path.join(CONFIGS_DIR, f), 'utf8'));
                    meta.type = obj.type || '';
                    meta.task = obj.task || '';
                } catch (_) {}
                return meta;
            });
        res.json({ ok: true, configs: files, activeName: activeName || null });
    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    }
}

// ─────────────────────────────────────────────────────────────
// GET /api/active-config — 返回当前激活的配置名
// ─────────────────────────────────────────────────────────────
function handleGetActive(_req, res) {
    setCors(res);
    ensureConfigsDir();
    const name = getActiveConfigName();
    if (!name) return res.json({ ok: true, activeName: null });
    const file = path.join(CONFIGS_DIR, name + '.json');
    if (!fs.existsSync(file)) {
        // 激活的文件已被删除，清除激活记录
        try { fs.unlinkSync(ACTIVE_CONFIG_FILE); } catch (_) {}
        return res.json({ ok: true, activeName: null });
    }
    res.json({ ok: true, activeName: name });
}

// ─────────────────────────────────────────────────────────────
// PUT /api/active-config — 设置激活配置（管理员）
// ─────────────────────────────────────────────────────────────
function handleSetActive(req, res) {
    ensureConfigsDir();
    const { name } = req.body || {};
    if (!name) return res.status(400).json({ ok: false, error: '缺少 name 字段' });
    const safed = safeName(name);
    if (!safed) return res.status(400).json({ ok: false, error: '非法配置名' });
    const file = path.join(CONFIGS_DIR, safed + '.json');
    if (!fs.existsSync(file)) return res.status(404).json({ ok: false, error: '配置不存在' });
    try {
        setActiveConfigName(safed);
        res.json({ ok: true, message: `已激活配置「${safed}」`, activeName: safed });
    } catch (e) {
        res.status(500).json({ ok: false, error: '设置失败：' + e.message });
    }
}

// ─────────────────────────────────────────────────────────────
// GET /api/configs/:name — 返回指定配置内容
// ─────────────────────────────────────────────────────────────
function handleGetOne(req, res) {
    setCors(res);
    ensureConfigsDir();
    const name = safeName(req.params.name);
    if (!name) return res.status(400).json({ ok: false, error: '非法文件名' });
    const file = path.join(CONFIGS_DIR, name + '.json');
    if (!fs.existsSync(file)) return res.status(404).json({ ok: false, error: '配置不存在' });
    try {
        const raw = fs.readFileSync(file, 'utf8');
        JSON.parse(raw); // 验证合法性
        res.send(raw);
    } catch (e) {
        res.status(500).json({ ok: false, error: '配置文件损坏：' + e.message });
    }
}

// ─────────────────────────────────────────────────────────────
// PUT /api/configs/:name — 新建/更新指定配置（管理员）
// ─────────────────────────────────────────────────────────────
function handlePutOne(req, res) {
    ensureConfigsDir();
    const name = safeName(req.params.name);
    if (!name) return res.status(400).json({ ok: false, error: '非法文件名' });

    const body = req.body;
    let raw;
    if (typeof body === 'string') {
        raw = body;
    } else if (body && typeof body === 'object') {
        raw = JSON.stringify(body, null, 2);
    } else {
        return res.status(400).json({ ok: false, error: '请求体不能为空' });
    }

    let parsed;
    try { parsed = JSON.parse(raw); }
    catch (e) { return res.status(400).json({ ok: false, error: 'JSON 格式错误：' + e.message }); }

    if (!parsed.dimensions || !Array.isArray(parsed.dimensions) || parsed.dimensions.length === 0) {
        return res.status(400).json({ ok: false, error: '缺少 dimensions 数组或为空' });
    }

    try {
        fs.writeFileSync(path.join(CONFIGS_DIR, name + '.json'), JSON.stringify(parsed, null, 2), 'utf8');
        res.json({
            ok: true,
            message: `已保存「${parsed.type || name}」，共 ${parsed.dimensions.length} 个维度`,
            name,
            type: parsed.type || '',
            task: parsed.task || '',
            dimensions: parsed.dimensions.map(d => ({ key: d.key, definition: d.definition || '' })),
        });
    } catch (e) {
        res.status(500).json({ ok: false, error: '写入失败：' + e.message });
    }
}

// ─────────────────────────────────────────────────────────────
// DELETE /api/configs/:name — 删除指定配置（管理员）
// ─────────────────────────────────────────────────────────────
function handleDeleteOne(req, res) {
    ensureConfigsDir();
    const name = safeName(req.params.name);
    if (!name) return res.status(400).json({ ok: false, error: '非法文件名' });
    const file = path.join(CONFIGS_DIR, name + '.json');
    if (!fs.existsSync(file)) return res.status(404).json({ ok: false, error: '配置不存在' });
    try {
        fs.unlinkSync(file);
        res.json({ ok: true, message: `已删除配置「${name}」` });
    } catch (e) {
        res.status(500).json({ ok: false, error: '删除失败：' + e.message });
    }
}

// ─────────────────────────────────────────────────────────────
// 兼容旧接口：GET /api/dimensions → 返回激活配置内容（供播放器拉取）
// ─────────────────────────────────────────────────────────────
function handleGet(_req, res) {
    setCors(res);
    ensureConfigsDir();

    // 优先返回激活配置
    const activeName = getActiveConfigName();
    if (activeName) {
        const activeFile = path.join(CONFIGS_DIR, activeName + '.json');
        if (fs.existsSync(activeFile)) {
            try {
                const raw = fs.readFileSync(activeFile, 'utf8');
                JSON.parse(raw);
                return res.send(raw);
            } catch (e) {
                return res.status(500).json({ ok: false, error: '激活配置文件损坏：' + e.message });
            }
        }
    }

    // 兜底：尝试 multi_dim.json（旧版兼容）
    const fallbackFile = path.join(CONFIGS_DIR, 'multi_dim.json');
    if (fs.existsSync(fallbackFile)) {
        try {
            const raw = fs.readFileSync(fallbackFile, 'utf8');
            JSON.parse(raw);
            return res.send(raw);
        } catch (e) {
            return res.status(500).json({ ok: false, error: '配置文件损坏：' + e.message });
        }
    }

    return res.status(404).json({ ok: false, error: '尚未激活任何配置，请在管理面板中设置激活配置' });
}

// ─────────────────────────────────────────────────────────────
// 兼容旧接口：PUT /api/dimensions → 写入 multi_dim.json
// ─────────────────────────────────────────────────────────────
function handlePut(req, res) {
    req.params = { name: 'multi_dim' };
    handlePutOne(req, res);
}

module.exports = { handleList, handleGetOne, handlePutOne, handleDeleteOne, handleGetActive, handleSetActive, handleGet, handlePut };
