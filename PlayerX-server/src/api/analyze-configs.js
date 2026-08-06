/**
 * src/api/analyze-configs.js — 盲评分析配置管理接口
 *
 * 存储：服务器根目录 analyze-configs/ 目录，每个 .json 文件为一份分析配置。
 * JSON 格式与 blind_analyze.py 的 config 兼容（tag, models, map_csv, src_model_dir, ...）
 *
 * 接口：
 *   GET    /api/analyze-configs           → 返回所有配置列表（公开）
 *   GET    /api/analyze-configs/:name     → 返回指定配置内容（公开）
 *   PUT    /api/analyze-configs/:name     → 新建/更新指定配置（管理员）
 *   DELETE /api/analyze-configs/:name     → 删除指定配置（管理员）
 */
const fs   = require('fs');
const path = require('path');

const CONFIGS_DIR = path.join(__dirname, '../../analyze-configs');

/** 确保目录存在，并迁移 bench_config.json（如果存在） */
function ensureDir() {
    if (!fs.existsSync(CONFIGS_DIR)) fs.mkdirSync(CONFIGS_DIR, { recursive: true });
    // 迁移旧 bench_config.json
    const legacy = '/data/rbyang/script/bench_config.json';
    if (fs.existsSync(legacy)) {
        const dest = path.join(CONFIGS_DIR, 'bench_config.json');
        if (!fs.existsSync(dest)) {
            try {
                fs.copyFileSync(legacy, dest);
            } catch (_) {}
        }
    }
}

/** 安全校验文件名 */
function safeName(name) {
    return /^[a-zA-Z0-9_\-一-龥]{1,64}$/.test(name) ? name : null;
}

function setCors(res) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
}

// GET /api/analyze-configs — 列表
function handleList(_req, res) {
    setCors(res);
    ensureDir();
    try {
        const files = fs.readdirSync(CONFIGS_DIR)
            .filter(f => f.endsWith('.json'))
            .map(f => {
                const name = f.replace(/\.json$/, '');
                let meta = { name, tag: '', models: 0 };
                try {
                    const obj = JSON.parse(fs.readFileSync(path.join(CONFIGS_DIR, f), 'utf8'));
                    meta.tag = obj.tag || '';
                    meta.models = Array.isArray(obj.models) ? obj.models.length : 0;
                } catch (_) {}
                return meta;
            });
        res.json({ ok: true, configs: files });
    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    }
}

// GET /api/analyze-configs/:name — 获取单个
function handleGetOne(req, res) {
    setCors(res);
    ensureDir();
    const name = safeName(req.params.name);
    if (!name) return res.status(400).json({ ok: false, error: '非法文件名' });
    const file = path.join(CONFIGS_DIR, name + '.json');
    if (!fs.existsSync(file)) return res.status(404).json({ ok: false, error: '配置不存在' });
    try {
        const raw = fs.readFileSync(file, 'utf8');
        JSON.parse(raw);
        res.send(raw);
    } catch (e) {
        res.status(500).json({ ok: false, error: '配置文件损坏：' + e.message });
    }
}

// PUT /api/analyze-configs/:name — 新建/更新
function handlePutOne(req, res) {
    ensureDir();
    const name = safeName(req.params.name);
    if (!name) return res.status(400).json({ ok: false, error: '非法文件名' });

    const body = req.body;
    let raw;
    if (typeof body === 'string') raw = body;
    else if (body && typeof body === 'object') raw = JSON.stringify(body, null, 2);
    else return res.status(400).json({ ok: false, error: '请求体不能为空' });

    let parsed;
    try { parsed = JSON.parse(raw); }
    catch (e) { return res.status(400).json({ ok: false, error: 'JSON 格式错误：' + e.message }); }

    if (!parsed.models || !Array.isArray(parsed.models) || parsed.models.length === 0) {
        return res.status(400).json({ ok: false, error: '缺少 models 数组或为空' });
    }

    try {
        fs.writeFileSync(path.join(CONFIGS_DIR, name + '.json'), JSON.stringify(parsed, null, 2), 'utf8');
        res.json({ ok: true, name, message: `已保存「${name}」` });
    } catch (e) {
        res.status(500).json({ ok: false, error: '写入失败：' + e.message });
    }
}

// DELETE /api/analyze-configs/:name — 删除
function handleDeleteOne(req, res) {
    ensureDir();
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

module.exports = { handleList, handleGetOne, handlePutOne, handleDeleteOne, CONFIGS_DIR };
