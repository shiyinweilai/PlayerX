/**
 * src/api/dimensions.js — 多维评分维度配置接口
 *
 * 接口：
 *   GET  /api/dimensions          → 返回当前维度配置 JSON（公开，PlayerX 客户端直接拉取）
 *   PUT  /api/dimensions          → 更新维度配置（需管理员登录）body 为 JSON 文本
 *
 * 存储：服务器根目录 dimensions.json（与 uploads/ 同级）
 */
const fs   = require('fs');
const path = require('path');

// dimensions.json 存放在项目根目录（server.js 同级）
const DIM_FILE = path.join(__dirname, '../../dimensions.json');

/** GET /api/dimensions — 公开读取 */
function handleGet(_req, res) {
    // 设置 CORS，允许 PlayerX 客户端（Qt XHR）跨域访问
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Content-Type', 'application/json; charset=utf-8');

    if (!fs.existsSync(DIM_FILE)) {
        return res.status(404).json({ ok: false, error: 'dimensions.json 尚未配置，请先通过管理面板上传' });
    }
    try {
        const raw = fs.readFileSync(DIM_FILE, 'utf8');
        // 验证是合法 JSON
        JSON.parse(raw);
        res.send(raw);
    } catch (e) {
        res.status(500).json({ ok: false, error: '配置文件损坏：' + e.message });
    }
}

/** PUT /api/dimensions — 管理员更新 */
function handlePut(req, res) {
    const body = req.body;

    // body 可能是已解析的对象（express.json 中间件），也可能是原始字符串
    let raw;
    if (typeof body === 'string') {
        raw = body;
    } else if (body && typeof body === 'object') {
        raw = JSON.stringify(body, null, 2);
    } else {
        return res.status(400).json({ ok: false, error: '请求体不能为空' });
    }

    // 验证 JSON 合法性
    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (e) {
        return res.status(400).json({ ok: false, error: 'JSON 格式错误：' + e.message });
    }

    // 基本结构校验
    if (!parsed.dimensions || !Array.isArray(parsed.dimensions) || parsed.dimensions.length === 0) {
        return res.status(400).json({ ok: false, error: '缺少 dimensions 数组或为空' });
    }

    try {
        fs.writeFileSync(DIM_FILE, JSON.stringify(parsed, null, 2), 'utf8');
        res.json({
            ok: true,
            message: `已更新，共 ${parsed.dimensions.length} 个维度`,
            task: parsed.task || '',
            dimensions: parsed.dimensions.map(d => ({ key: d.key, definition: d.definition || '' })),
        });
    } catch (e) {
        res.status(500).json({ ok: false, error: '写入失败：' + e.message });
    }
}

module.exports = { handleGet, handlePut };
