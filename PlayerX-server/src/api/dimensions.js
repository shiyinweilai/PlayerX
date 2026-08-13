/**
 * src/api/dimensions.js — 评分配置管理接口
 *
 * 存储：data/configs/ 目录，每个 .json 文件为一份配置
 * JSON 格式：{ "type": "多维评分", "task": "...", "scale": "...", "dimensions": [...] }
 *
 * 接口：
 *   GET  /api/configs              → 返回所有配置文件列表（公开）
 *   GET  /api/configs/:name        → 返回指定配置内容（公开）
 *   PUT  /api/configs/:name        → 新建/更新指定配置（管理员）
 *   DELETE /api/configs/:name      → 删除指定配置（管理员）
 *
 *   GET  /api/active-config        → 返回当前所有模式绑定 { bindings: { mode: configName[] } }（公开）
 *   PUT  /api/active-config        → 绑定/解绑：{ name, mode } 将配置绑定到模式；已绑定则解绑（toggle）（管理员）
 *
 *   GET  /api/dimensions           → 返回激活配置内容（公开，供播放器拉取）
 *                                    ?mode=xxx 按模式返回对应激活配置；无参数兼容旧行为（multi_dim）
 *   PUT  /api/dimensions           → 兼容旧客户端，写入 multi_dim.json（管理员）
 *
 * 激活存储格式（configs/_active.json）：
 *   { "bindings": { "multi_dim": ["配置名", "配置名2"], "subjective": ["配置名3"], ... } }
 *   兼容旧格式：{ "name": "配置名" } → 自动迁移为 { "bindings": { "multi_dim": ["配置名"] } }
 *   兼容旧格式：bindings 中字符串值 → 自动转为单元素数组
 */
const fs = require('fs');
const path = require('path');

const { CONFIGS_DIR } = require('../lib/paths');

// 旧版单文件路径（兼容迁移）
const LEGACY_DIM_FILE = path.join(__dirname, '../../dimensions.json');

// 激活配置记录文件（存在 configs/ 目录下）
const ACTIVE_CONFIG_FILE = path.join(CONFIGS_DIR, '_active.json');

// 模式顺序与显示文案（用于根据绑定同步 json.type）
const MODE_LABELS = {
    multi_dim: '多维评分',
    subjective: '主观评分',
    quality: '质量比较',
    quality_slide: '质量比较2',
    test: '测试模式',
};
const MODE_ORDER = ['multi_dim', 'subjective', 'quality', 'quality_slide', 'test'];

/** 绑定互斥化：同一个配置名只允许出现在一个模式下（按 MODE_ORDER 优先级保留） */
function normalizeBindingsExclusive(bindings) {
    const src = bindings && typeof bindings === 'object' ? bindings : {};
    const out = {};
    const occupied = new Set();
    const modeSeq = [
        ...MODE_ORDER,
        ...Object.keys(src).filter(m => !MODE_ORDER.includes(m)),
    ];
    for (const mode of modeSeq) {
        const names = Array.isArray(src[mode]) ? src[mode] : (src[mode] ? [src[mode]] : []);
        const kept = [];
        for (const name of names) {
            if (!name || occupied.has(name)) continue;
            occupied.add(name);
            kept.push(name);
        }
        if (kept.length) out[mode] = kept;
    }
    return out;
}

/** 读取所有模式绑定 { mode -> configName[] }，不存在则返回 {} */
function getActiveBindings() {
    try {
        if (fs.existsSync(ACTIVE_CONFIG_FILE)) {
            const obj = JSON.parse(fs.readFileSync(ACTIVE_CONFIG_FILE, 'utf8'));
            // 兼容旧格式 { name: '...' } → 自动迁移为 multi_dim 绑定
            if (obj.name && !obj.bindings) {
                return normalizeBindingsExclusive({ multi_dim: [obj.name] });
            }
            const raw = obj.bindings || {};
            // 兼容旧格式：字符串值 → 单元素数组，并做互斥归一化
            const normalized = {};
            for (const [mode, val] of Object.entries(raw)) {
                normalized[mode] = Array.isArray(val) ? val : [val];
            }
            return normalizeBindingsExclusive(normalized);
        }
    } catch (_) { }
    return {};
}

/** 写入所有模式绑定（保留附加字段，如 order） */
function setActiveBindings(bindings) {
    ensureConfigsDir();
    let prev = {};
    try {
        if (fs.existsSync(ACTIVE_CONFIG_FILE)) {
            prev = JSON.parse(fs.readFileSync(ACTIVE_CONFIG_FILE, 'utf8')) || {};
        }
    } catch (_) { }
    fs.writeFileSync(ACTIVE_CONFIG_FILE, JSON.stringify({ ...prev, bindings }, null, 2), 'utf8');
}

/** 兼容旧接口：获取 multi_dim 模式绑定的第一个配置名（不含 .json），不存在则返回 null */
function getActiveConfigName() {
    const b = getActiveBindings();
    const arr = b['multi_dim'];
    return (Array.isArray(arr) && arr.length > 0) ? arr[0] : null;
}

/** 根据绑定关系计算配置应有的 type（未绑定则待绑定） */
function getTypeFromBindings(bindings, configName) {
    for (const mode of MODE_ORDER) {
        const names = bindings[mode];
        if (Array.isArray(names) && names.includes(configName)) {
            return MODE_LABELS[mode] || mode;
        }
    }
    for (const [mode, names] of Object.entries(bindings || {})) {
        if (Array.isArray(names) && names.includes(configName)) {
            return MODE_LABELS[mode] || mode;
        }
    }
    return '待绑定';
}

/** 将单个配置文件的 json.type 同步为绑定对应类型 */
function syncConfigTypeByBindings(configName, bindings) {
    const file = path.join(CONFIGS_DIR, configName + '.json');
    if (!fs.existsSync(file)) return null;
    try {
        const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
        const nextType = getTypeFromBindings(bindings, configName);
        if (obj.type !== nextType) {
            obj.type = nextType;
            fs.writeFileSync(file, JSON.stringify(obj, null, 2), 'utf8');
        }
        return nextType;
    } catch (_) {
        return null;
    }
}

/** 批量同步所有配置的 json.type */
function syncAllConfigTypesByBindings(bindings) {
    ensureConfigsDir();
    const files = fs.readdirSync(CONFIGS_DIR).filter(f => f.endsWith('.json') && f !== '_active.json');
    for (const f of files) {
        syncConfigTypeByBindings(f.replace(/\.json$/, ''), bindings);
    }
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
            } catch (_) { }
        }
        // 迁移完成后删除旧文件，防止每次请求都触发重建
        try { fs.unlinkSync(LEGACY_DIM_FILE); } catch (_) { }
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
        const bindings = getActiveBindings(); // { mode -> configName[] }
        syncAllConfigTypesByBindings(bindings);
        // 反转：configName -> [mode, ...]
        const configModes = {};
        for (const [mode, names] of Object.entries(bindings)) {
            for (const name of names) {
                if (!configModes[name]) configModes[name] = [];
                configModes[name].push(mode);
            }
        }
        // 读取自定义排序
        let orderList = [];
        try {
            if (fs.existsSync(ACTIVE_CONFIG_FILE)) {
                const obj = JSON.parse(fs.readFileSync(ACTIVE_CONFIG_FILE, 'utf8'));
                orderList = Array.isArray(obj.order) ? obj.order : [];
            }
        } catch (_) { }

        const allFiles = fs.readdirSync(CONFIGS_DIR)
            .filter(f => f.endsWith('.json') && f !== '_active.json')
            .map(f => {
                const name = f.replace(/\.json$/, '');
                let meta = { name, type: getTypeFromBindings(bindings, name), task: '', activeForModes: configModes[name] || [] };
                try {
                    const obj = JSON.parse(fs.readFileSync(path.join(CONFIGS_DIR, f), 'utf8'));
                    meta.type = obj.type || meta.type;
                    meta.task = obj.task || '';
                    meta.tag = obj.tag || '';
                    // 返回 build 摘要供任务管理使用
                    if (obj.build) {
                        meta.build = {
                            models: obj.build.models || [],
                            src_model_dir: obj.build.src_model_dir || '',
                        };
                    }
                } catch (_) { }
                return meta;
            });

        // 按 order 排序：order 中有的按顺序排前面，其余追加到末尾
        const nameToMeta = {};
        allFiles.forEach(m => { nameToMeta[m.name] = m; });
        const ordered = [];
        orderList.forEach(n => { if (nameToMeta[n]) { ordered.push(nameToMeta[n]); delete nameToMeta[n]; } });
        Object.values(nameToMeta).forEach(m => ordered.push(m));

        res.json({ ok: true, configs: ordered, bindings });
    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    }
}

// ─────────────────────────────────────────────────────────────
// GET /api/active-config — 返回所有模式绑定
// ─────────────────────────────────────────────────────────────
function handleGetActive(_req, res) {
    setCors(res);
    ensureConfigsDir();
    const bindings = getActiveBindings(); // { mode -> configName[] }
    // 清理已被删除的配置
    let changed = false;
    for (const [mode, names] of Object.entries(bindings)) {
        const filtered = names.filter(name => {
            const file = path.join(CONFIGS_DIR, name + '.json');
            return fs.existsSync(file);
        });
        if (filtered.length !== names.length) {
            if (filtered.length === 0) delete bindings[mode];
            else bindings[mode] = filtered;
            changed = true;
        }
    }
    if (changed) setActiveBindings(bindings);
    res.json({ ok: true, bindings });
}

// ─────────────────────────────────────────────────────────────
// PUT /api/active-config — 绑定/解绑配置到模式（管理员）
// body: { name, mode }  将配置 name 绑定到 mode（toggle：已绑定则移除，未绑定则追加）
// ─────────────────────────────────────────────────────────────
function handleSetActive(req, res) {
    ensureConfigsDir();
    const { name, mode } = req.body || {};
    if (!name) return res.status(400).json({ ok: false, error: '缺少 name 字段' });
    if (!mode) return res.status(400).json({ ok: false, error: '缺少 mode 字段' });
    const safed = safeName(name);
    if (!safed) return res.status(400).json({ ok: false, error: '非法配置名' });
    const file = path.join(CONFIGS_DIR, safed + '.json');
    if (!fs.existsSync(file)) return res.status(404).json({ ok: false, error: '配置不存在' });
    try {
        const bindings = getActiveBindings(); // { mode -> configName[] }

        let prevMode = null;
        for (const [m, names] of Object.entries(bindings)) {
            if (Array.isArray(names) && names.includes(safed)) {
                prevMode = m;
                break;
            }
        }

        let action;
        if (prevMode === mode) {
            // 点中当前模式：解绑
            bindings[mode] = (bindings[mode] || []).filter(n => n !== safed);
            if (!bindings[mode].length) delete bindings[mode];
            action = 'unbound';
        } else {
            // 互斥绑定：先从所有模式移除，再绑定到目标模式
            for (const m of Object.keys(bindings)) {
                const next = (bindings[m] || []).filter(n => n !== safed);
                if (next.length) bindings[m] = next;
                else delete bindings[m];
            }
            bindings[mode] = [...(bindings[mode] || []), safed];
            action = prevMode ? 'rebound' : 'bound';
        }

        const finalBindings = normalizeBindingsExclusive(bindings);
        setActiveBindings(finalBindings);
        syncAllConfigTypesByBindings(finalBindings);

        const msg = action === 'unbound'
            ? `已解绑「${safed}」与模式「${mode}」`
            : (action === 'rebound'
                ? `已将「${safed}」从「${prevMode}」切换为「${mode}」`
                : `已将「${safed}」绑定到模式「${mode}」（当前共 ${finalBindings[mode] ? finalBindings[mode].length : 0} 个）`);
        res.json({ ok: true, action, message: msg, bindings: finalBindings, prevMode: prevMode || '' });
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
        const bindings = getActiveBindings();
        syncConfigTypeByBindings(name, bindings);
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
    // checklists 字段可选，若存在则校验格式
    if (parsed.checklists !== undefined) {
        if (!Array.isArray(parsed.checklists)) {
            return res.status(400).json({ ok: false, error: 'checklists 必须是数组' });
        }
        for (const item of parsed.checklists) {
            if (!item.key || !item.label) {
                return res.status(400).json({ ok: false, error: 'checklists 每项必须包含 key 和 label 字段' });
            }
        }
    }

    try {
        const bindings = getActiveBindings();
        parsed.type = getTypeFromBindings(bindings, name);
        fs.writeFileSync(path.join(CONFIGS_DIR, name + '.json'), JSON.stringify(parsed, null, 2), 'utf8');
        res.json({
            ok: true,
            message: `已保存「${name}」，共 ${parsed.dimensions.length} 个维度`,
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

        const bindings = getActiveBindings();
        let changed = false;
        for (const [mode, names] of Object.entries(bindings)) {
            const filtered = (Array.isArray(names) ? names : []).filter(n => n !== name);
            if (filtered.length !== names.length) {
                changed = true;
                if (filtered.length === 0) delete bindings[mode];
                else bindings[mode] = filtered;
            }
        }
        if (changed) {
            setActiveBindings(bindings);
            syncAllConfigTypesByBindings(bindings);
        }

        res.json({ ok: true, message: `已删除配置「${name}」` });
    } catch (e) {
        res.status(500).json({ ok: false, error: '删除失败：' + e.message });
    }
}

// ─────────────────────────────────────────────────────────────
// 兼容旧接口：GET /api/dimensions → 返回激活配置内容（供播放器拉取）
// ?mode=xxx 按模式返回对应激活配置；无参数时兼容旧行为（multi_dim）
// ─────────────────────────────────────────────────────────────
function handleGet(req, res) {
    setCors(res);
    ensureConfigsDir();

    const bindings = getActiveBindings(); // { mode -> configName[] }
    // 按 mode 参数查找绑定的第一个配置名（兼容旧客户端）
    const mode = req.query && req.query.mode;
    let activeName = null;
    if (mode && bindings[mode] && bindings[mode].length > 0) {
        activeName = bindings[mode][0];
    } else if (!mode) {
        // 无 mode 参数：兼容旧行为，优先 multi_dim 第一个，其次任意一个绑定
        const multiArr = bindings['multi_dim'];
        const anyArr = Object.values(bindings)[0];
        activeName = (multiArr && multiArr[0]) || (anyArr && anyArr[0]) || null;
    }

    if (activeName) {
        const activeFile = path.join(CONFIGS_DIR, activeName + '.json');
        if (fs.existsSync(activeFile)) {
            try {
                syncConfigTypeByBindings(activeName, bindings);
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

    const modeDesc = mode ? `模式「${mode}」` : '任何模式';
    return res.status(404).json({ ok: false, error: `${modeDesc}尚未绑定激活配置，请在管理面板中设置` });
}

// ─────────────────────────────────────────────────────────────
// 兼容旧接口：PUT /api/dimensions → 写入 multi_dim.json
// ─────────────────────────────────────────────────────────────
function handlePut(req, res) {
    req.params = { name: 'multi_dim' };
    handlePutOne(req, res);
}

// ─────────────────────────────────────────────────────────────
// PUT /api/configs-order — 保存配置列表排序（管理员）
// body: { order: ['name1', 'name2', ...] }
// ─────────────────────────────────────────────────────────────
function handleReorder(req, res) {
    ensureConfigsDir();
    const { order } = req.body || {};
    if (!Array.isArray(order)) return res.status(400).json({ ok: false, error: '缺少 order 数组' });
    try {
        let active = {};
        if (fs.existsSync(ACTIVE_CONFIG_FILE)) {
            try { active = JSON.parse(fs.readFileSync(ACTIVE_CONFIG_FILE, 'utf8')); } catch (_) { }
        }
        active.order = order;
        fs.writeFileSync(ACTIVE_CONFIG_FILE, JSON.stringify(active, null, 2), 'utf8');
        res.json({ ok: true });
    } catch (e) {
        res.status(500).json({ ok: false, error: '保存排序失败：' + e.message });
    }
}

module.exports = { handleList, handleGetOne, handlePutOne, handleDeleteOne, handleGetActive, handleSetActive, handleGet, handlePut, handleReorder };
