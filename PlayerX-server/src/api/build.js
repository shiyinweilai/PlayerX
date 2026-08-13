/**
 * src/api/build.js — POST /api/build
 *
 * 盲评构建接口（纯 JS 实现，对应 blind_build.py 的 build() 函数）：
 *   读取配置 → 解析样本 → 检查源文件 → 分组 → 复制视频 → 写 map → 自检。
 * 仅已登录管理员可用（由 auth.requireAdmin 中间件保证）。
 *
 * 请求 body:
 *   { config: { src_model_dir, dst_dir, models, n_groups, seed, ... } }
 *
 * 响应:
 *   { ok: true, data: { samples, models, groups, blind, mapRows, mapCsv, verifyOk, details } }
 */
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');

// ─────────────────────────────────────────────────────────────────────
//  种子化随机数生成器（LCG，与 Python random.Random 行为类似）
// ─────────────────────────────────────────────────────────────────────

function createRng(seed) {
    let s = (seed || 42) >>> 0;
    return {
        /** 返回 [0, 1) 的浮点数 */
        next() {
            s = (s * 1664525 + 1013904223) >>> 0;
            return s / 4294967296;
        },
        /** Fisher-Yates 洗牌（原地） */
        shuffle(arr) {
            for (let i = arr.length - 1; i > 0; i--) {
                const j = Math.floor(this.next() * (i + 1));
                [arr[i], arr[j]] = [arr[j], arr[i]];
            }
            return arr;
        },
    };
}

// ─────────────────────────────────────────────────────────────────────
//  工具
// ─────────────────────────────────────────────────────────────────────

function labelNames(n) {
    return Array.from({ length: n }, (_, i) => String.fromCharCode(65 + i));
}

function groupNames(n) {
    return Array.from({ length: n }, (_, i) => `g${i + 1}`);
}

function md5(filePath) {
    return crypto.createHash('md5').update(fs.readFileSync(filePath)).digest('hex');
}

function resolveSamples(cfg) {
    if (cfg.samples && cfg.samples.length > 0) return [...cfg.samples].sort((a, b) => a - b);

    const exclude = new Set(cfg.exclude_samples || []);

    // 自动从模型目录扫描 *.mp4 文件名，提取数字作为样本编号。
    // 扫描所有模型目录的并集，确保一个样本在所有模型中至少都存在（这是构建的前提）。
    // 解析每个 model 项：
    //   1) srcDir 明确给出 → 相对 srcDir 解析
    //   2) srcDir 缺失但 model 是相对路径且包含 / → 自动按 ROOT_DIR 解析
    //      （前端"从模型管理加载"时就是这种：models = ["assets/quality/quality/g1/A", ...]）
    const srcDir = cfg.src_model_dir;
    const models = cfg.models || [];
    if (models.length > 0) {
        const { ROOT_DIR } = require('../lib/paths');
        const anchor = srcDir || ROOT_DIR;
        // 取所有模型的交集：每个样本在每个模型目录下都要有同名文件
        let common = null;
        for (const m of models) {
            const d = path.isAbsolute(m) ? m : path.join(anchor, m);
            if (!fs.existsSync(d) || !fs.statSync(d).isDirectory()) continue;
            const nums = new Set(
                fs.readdirSync(d)
                    .filter(f => /\.mp4$/.test(f))
                    .map(f => parseInt(f.replace(/\.mp4$/i, ''), 10))
                    .filter(n => !isNaN(n))
            );
            if (common === null) common = nums;
            else common = new Set([...common].filter(n => nums.has(n)));
        }
        if (common && common.size > 0) {
            return [...common].filter(n => !exclude.has(n)).sort((a, b) => a - b);
        }
        // 目录都读不到时，给出更明确的提示
        throw new Error('样本列表为空：未指定 samples，且所有模型目录下都找不到 *.mp4 文件（请检查 src_model_dir / models 配置或手动填写 samples）');
    }

    // 兜底：兼容历史行为（理论上不会走到这里，因为 build 必然传 models）
    return Array.from({ length: 100 }, (_, i) => i + 1).filter(n => !exclude.has(n));
}

function csvCell(v) {
    const s = (v == null ? '' : String(v));
    if (/[",\r\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
    return s;
}

function loadCsv(filePath) {
    let txt = fs.readFileSync(filePath, 'utf8');
    if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);
    const lines = txt.split(/\r?\n/).filter(l => l.trim().length > 0);
    if (lines.length === 0) return [];
    const headers = parseCsvLine(lines[0]);
    return lines.slice(1).map(line => {
        const cells = parseCsvLine(line);
        const row = {};
        headers.forEach((h, i) => { row[h] = cells[i] !== undefined ? cells[i] : ''; });
        return row;
    });
}

function parseCsvLine(line) {
    const cells = [];
    let cur = '', inQuotes = false;
    for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (ch === '"') {
            if (inQuotes && line[i + 1] === '"') { cur += '"'; i++; }
            else inQuotes = !inQuotes;
        } else if (ch === ',' && !inQuotes) {
            cells.push(cur); cur = '';
        } else {
            cur += ch;
        }
    }
    cells.push(cur);
    return cells;
}

// ─────────────────────────────────────────────────────────────────────
//  分组
// ─────────────────────────────────────────────────────────────────────

function assignGroups(samples, nGroups, rng) {
    const pool = [...samples];
    rng.shuffle(pool);
    const base = Math.floor(pool.length / nGroups);
    const extra = pool.length % nGroups;
    const assn = {};
    let i = 0;
    for (let gi = 0; gi < nGroups; gi++) {
        const g = `g${gi + 1}`;
        const size = gi < extra ? base + 1 : base;
        for (const n of pool.slice(i, i + size)) assn[n] = g;
        i += size;
    }
    return assn;
}

function reuseGroups(samples, reuseCsv) {
    const rows = loadCsv(reuseCsv);
    const ref = {};
    for (const r of rows) {
        const n = parseInt((r.filename || '').replace(/\.\w+$/, ''), 10);
        if (!isNaN(n)) ref[n] = r.group;
    }
    const missing = samples.filter(n => !(n in ref));
    if (missing.length > 0) throw new Error(`reuse 源缺样本: ${missing.join(',')}`);
    const result = {};
    for (const n of samples) result[n] = ref[n];
    return result;
}

// ─────────────────────────────────────────────────────────────────────
//  前置检查
// ─────────────────────────────────────────────────────────────────────

function checkSources(srcDir, models, samples) {
    const { ROOT_DIR } = require('../lib/paths');
    const anchor = srcDir || ROOT_DIR;
    const need = new Set(samples.map(n => `${n}.mp4`));
    for (const m of models) {
        // 模型路径如果本身就是绝对路径则直接使用，否则拼 srcDir
        const d = path.isAbsolute(m) ? m : path.join(anchor, m);
        if (!fs.existsSync(d) || !fs.statSync(d).isDirectory()) {
            throw new Error(`模型目录不存在: ${d}`);
        }
        const have = new Set(fs.readdirSync(d).filter(f => f.endsWith('.mp4')));
        const missing = [...need].filter(f => !have.has(f));
        if (missing.length > 0) {
            throw new Error(`${path.basename(d)}: 缺${missing.length}文件 ${missing.slice(0, 10).join(',')}`);
        }
    }
}

function loadPrompts(comp, samples) {
    const rows = loadCsv(comp.prompt_csv);
    const byN = {};
    for (const r of rows) {
        const n = parseInt((r.Image || '').replace(/\.\w+$/, ''), 10);
        if (!isNaN(n)) byN[n] = r;
    }
    const missing = samples.filter(n => !(n in byN));
    if (missing.length > 0) throw new Error(`prompt.csv 缺样本: ${missing.join(',')}`);
    return byN;
}

// ─────────────────────────────────────────────────────────────────────
//  核心：盲评目录构建
// ─────────────────────────────────────────────────────────────────────

function copyBlind(samples, groupOf, models, labels, srcDir, dstDir, comp,
                   promptByN, promptCols, ffDirs, rng) {
    const { ROOT_DIR } = require('../lib/paths');
    const anchor = srcDir || ROOT_DIR;
    const groups = [...new Set(Object.values(groupOf))].sort((a, b) => parseInt(a.slice(1)) - parseInt(b.slice(1)));

    // 创建目录（先清空旧目录）
    if (fs.existsSync(dstDir)) fs.rmSync(dstDir, { recursive: true, force: true });
    for (const g of groups) {
        for (const lb of labels) {
            fs.mkdirSync(path.join(dstDir, g, lb), { recursive: true });
        }
        if (comp) {
            // 为每个参考帧目录创建对应子目录
            for (const ffEntry of ffDirs) {
                fs.mkdirSync(path.join(dstDir, g, ffEntry.name), { recursive: true });
            }
        }
    }

    // 复制视频
    const mapRows = [];
    for (const n of samples) {
        const fn = `${n}.mp4`;
        const g = groupOf[n];
        const perm = [...models];
        rng.shuffle(perm);

        const row = { group: g, filename: fn };
        for (let i = 0; i < labels.length; i++) {
            const lb = labels[i];
            const model = perm[i];
            const modelDir = path.isAbsolute(model) ? model : path.join(anchor, model);
            fs.copyFileSync(path.join(modelDir, fn), path.join(dstDir, g, lb, fn));
            row[`${lb}_source`] = path.basename(model);
        }
        mapRows.push(row);

        // 复制每个参考帧目录的图片
        if (comp) {
            for (const ffEntry of ffDirs) {
                const ffSrc = path.join(ffEntry.dir, `${n}.png`);
                if (fs.existsSync(ffSrc)) {
                    fs.copyFileSync(ffSrc, path.join(dstDir, g, ffEntry.name, `${n}.png`));
                }
            }
        }
    }

    // 各组 prompt.csv
    if (comp) {
        for (const g of groups) {
            const ns = samples.filter(n => groupOf[n] === g).sort((a, b) => a - b);
            const promptPath = path.join(dstDir, g, 'prompt.csv');
            const header = promptCols.map(csvCell).join(',');
            const lines = [header];
            for (const n of ns) {
                lines.push(promptCols.map(c => csvCell(promptByN[n][c] || '')).join(','));
            }
            fs.writeFileSync(promptPath, lines.join('\n'), 'utf8');
        }
    }

    return mapRows;
}

function copyDirect(samples, models, srcDir, dstDir, rng) {
    const { ROOT_DIR } = require('../lib/paths');
    const anchor = srcDir || ROOT_DIR;
    for (const n of samples) {
        const fn = `${n}.mp4`;
        for (const model of models) {
            const modelDir = path.isAbsolute(model) ? model : path.join(anchor, model);
            const d = path.join(dstDir, path.basename(model));
            fs.mkdirSync(d, { recursive: true });
            fs.copyFileSync(path.join(modelDir, fn), path.join(d, fn));
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
//  自检
// ─────────────────────────────────────────────────────────────────────

function verify(dstDir, srcDir, models, labels, groupOf, mapRows, comp) {
    const groups = [...new Set(Object.values(groupOf))].sort((a, b) => parseInt(a.slice(1)) - parseInt(b.slice(1)));
    const details = [];
    let ok = true;

    // 组大小
    for (const g of groups) {
        const expect = Object.values(groupOf).filter(v => v === g).length;
        const actual = mapRows.filter(r => r.group === g).length;
        if (actual !== expect) {
            details.push(`FAIL 组${g}大小: ${actual} (期望${expect})`);
            ok = false;
        }
    }

    // 排列完整 + MD5
    const onDisk = {};
    for (const g of groups) { onDisk[g] = {}; for (const lb of labels) onDisk[g][lb] = new Set(); }
    for (const r of mapRows) {
        const sources = labels.map(lb => r[`${lb}_source`]);
        if (new Set(sources).size !== models.length || !sources.every(s => models.includes(s))) {
            details.push(`FAIL 排列 ${r.filename}: ${sources.join(',')}`);
            ok = false;
            continue;
        }
        const g = r.group, fn = r.filename;
        for (const lb of labels) {
            const model = r[`${lb}_source`];
            const blindF = path.join(dstDir, g, lb, fn);
            const srcF = path.join(srcDir, model, fn);
            if (!fs.existsSync(blindF) || md5(blindF) !== md5(srcF)) {
                details.push(`FAIL MD5 ${blindF}`);
                ok = false;
            }
            onDisk[g][lb].add(fn);
        }
    }

    // 杂散文件
    for (const g of groups) {
        for (const lb of labels) {
            const dir = path.join(dstDir, g, lb);
            const actual = fs.existsSync(dir)
                ? new Set(fs.readdirSync(dir).filter(f => f.endsWith('.mp4'))) : new Set();
            const expected = onDisk[g][lb];
            const stray = [...actual].filter(f => !expected.has(f));
            if (stray.length > 0) {
                details.push(`FAIL 杂散 ${g}/${lb}: ${stray.join(',')}`);
                ok = false;
            }
        }
    }

    // 配套文件交叉
    if (comp) {
        for (const g of groups) {
            const expect = new Set(
                Object.entries(groupOf).filter(([_, gg]) => gg === g).map(([n]) => `${n}.png`)
            );
            // 检测目标目录下所有非 label 目录（即参考帧目录）
            const gDir = path.join(dstDir, g);
            const subDirs = fs.readdirSync(gDir, { withFileTypes: true })
                .filter(d => d.isDirectory() && !labels.includes(d.name))
                .map(d => d.name);
            for (const refDir of subDirs) {
                const ffPath = path.join(gDir, refDir);
                const ff = new Set(fs.readdirSync(ffPath).filter(f => f.endsWith('.png')));
                const ffDiff = [...expect].filter(f => !ff.has(f));
                if (ffDiff.length > 0) {
                    details.push(`FAIL ${refDir} ${g}:缺 ${ffDiff.slice(0, 5).join(',')}`);
                    ok = false;
                }
            }
        }
    }

    // map 不泄漏
    const mapFiles = [];
    function findMap(dir) {
        if (!fs.existsSync(dir)) return;
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, entry.name);
            if (entry.isDirectory()) findMap(full);
            else if (entry.name.startsWith('map')) mapFiles.push(full);
        }
    }
    findMap(dstDir);
    if (mapFiles.length > 0) {
        details.push(`FAIL map泄漏: ${mapFiles.join(',')}`);
        ok = false;
    }

    return { ok, details };
}

// ─────────────────────────────────────────────────────────────────────
//  写 map CSV
// ─────────────────────────────────────────────────────────────────────

function writeMap(mapCsv, mapRows, labels) {
    const cols = ['group', 'filename', ...labels.map(lb => `${lb}_source`)];
    fs.mkdirSync(path.dirname(mapCsv), { recursive: true });
    const header = cols.map(csvCell).join(',');
    const lines = [header];
    for (const r of mapRows) {
        lines.push(cols.map(c => csvCell(r[c] || '')).join(','));
    }
    fs.writeFileSync(mapCsv, lines.join('\n'), 'utf8');
}

// ─────────────────────────────────────────────────────────────────────
//  顶层：构建盲评
// ─────────────────────────────────────────────────────────────────────

function cmdBuild(cfg) {
    // src_model_dir 支持相对 ROOT_DIR 的相对路径（如 "assets/foo"），
    // 这里解析为绝对路径并写回 cfg，避免路径迁移后构建失败。
    //
    // models 不在这里预解析：每个 model 项可能是
    //   - 相对于 srcDir 的子路径（前端构建表单传入的"quality/g1/A"）
    //   - 已经是绝对路径（模型管理页面保存的 data-full）
    //   - 相对 ROOT_DIR 的完整路径（前端"从模型管理加载"传的 "assets/quality/quality/g1/A"）
    // 下游所有函数 (checkSources / copyBlind / copyDirect) 都用
    //   `path.isAbsolute(m) ? m : path.join(anchor, m)`
    // 其中 anchor = srcDir 或 ROOT_DIR（前者缺失时兜底），兼容所有三种情况。
    const { ROOT_DIR } = require('../lib/paths');
    const { resolveSourcePath } = require('../lib/paths');
    if (cfg.src_model_dir && !path.isAbsolute(cfg.src_model_dir)) {
        cfg.src_model_dir = resolveSourcePath(cfg.src_model_dir);
    }
    const srcDir  = cfg.src_model_dir;
    const dstDir  = cfg.dst_dir;
    const models  = cfg.models || [];
    const labels  = labelNames(models.length);
    const nGroups = cfg.n_groups || 1;
    const blind   = cfg.blind !== false;
    const comp    = cfg.companions || null;

    const samples= resolveSamples(cfg);
    const promptByN   = comp ? loadPrompts(comp, samples) : {};
    const promptCols  = comp ? (comp.prompt_cols || ['Image', 'prompt', 'en_prompt']) : [];
    //参考帧目录：支持逗号分隔多个路径，每项{ dir: 绝对路径, name: basename }
    const ffDirs = comp ? (comp.first_frames_dir || '').split(/[,，]+/).map(d => d.trim()).filter(Boolean).map(d => ({
        dir: d,
        name: path.basename(d)
    })) : [];

    const seed = cfg.seed || 42;
    const rng  = createRng(seed);

    // map_csv 兜底：若前端没传（或者路径不合法），按 dst_dir + '/map.csv' 派生；
    // 同时再支持相对 ROOT_DIR 解析。
    let mapCsv = cfg.map_csv;
    if (!mapCsv && dstDir) {
        mapCsv = path.join(dstDir, 'map.csv');
    }
    if (mapCsv && !path.isAbsolute(mapCsv)) {
        // 优先按 dst_dir 解析（产物都在 tasks/ 下），否则按 ROOT_DIR
        const anchor = dstDir ? path.dirname(dstDir) : ROOT_DIR;
        mapCsv = path.join(anchor, mapCsv);
    }
    cfg.map_csv = mapCsv;

    const info = {
        samples: samples.length,
        models: models.length,
        groups: nGroups,
        blind,
        seed,
    };

    checkSources(srcDir, models, samples);

    const mode = cfg.group_mode || 'fresh';
    let groupOf;
    if (mode === 'reuse') {
        groupOf = reuseGroups(samples, cfg.reuse_map_csv);
    } else {
        groupOf = assignGroups(samples, nGroups, rng);
    }

    if (blind) {
        const mapRows = copyBlind(samples, groupOf, models, labels, srcDir, dstDir,
                                  comp, promptByN, promptCols, ffDirs, rng);
        writeMap(mapCsv, mapRows, labels);
        const v = verify(dstDir, srcDir, models, labels, groupOf, mapRows, comp);
        return {
            ...info,
            mapRows: mapRows.length,
            mapCsv,
            dstDir,
            verifyOk: v.ok,
            verifyDetails: v.details,
        };
    } else {
        copyDirect(samples, models, srcDir, dstDir, rng);
        return {
            ...info,
            mapRows: 0,
            mapCsv: null,
            dstDir,
            verifyOk: true,
            verifyDetails: [],
        };
    }
}

// ─────────────────────────────────────────────────────────────────────
//  主入口
// ─────────────────────────────────────────────────────────────────────

function handle(req, res) {
    const { config } = req.body || {};
    if (!config || typeof config !== 'object') {
        return res.status(400).json({ ok: false, error: 'missing config object' });
    }
    if (!config.dst_dir) {
        return res.status(400).json({ ok: false, error: '缺少 dst_dir' });
    }
    if (!config.models || !Array.isArray(config.models) || config.models.length === 0) {
        return res.status(400).json({ ok: false, error: '缺少 models 数组或为空' });
    }

    // 解析相对路径：以 tasks 目录为基准（产物存放在 <ROOT>/tasks/<tag>/ 下）
    const { TASKS_DIR } = require('../lib/paths');
    const cfg = Object.assign({}, config);
    if (cfg.map_csv && !path.isAbsolute(cfg.map_csv)) {
        cfg.map_csv = path.join(TASKS_DIR, cfg.map_csv);
    }
    if (cfg.reuse_map_csv && !path.isAbsolute(cfg.reuse_map_csv)) {
        const c = path.join(TASKS_DIR, cfg.reuse_map_csv);
        if (fs.existsSync(c)) cfg.reuse_map_csv = c;
    }
    if (cfg.companions) {
        cfg.companions = Object.assign({}, cfg.companions);
      if (cfg.companions.prompt_csv && !path.isAbsolute(cfg.companions.prompt_csv)) {
      const c = path.join(TASKS_DIR, cfg.companions.prompt_csv);
 if (fs.existsSync(c)) cfg.companions.prompt_csv = c;
        }
        if (cfg.companions.first_frames_dir && !path.isAbsolute(cfg.companions.first_frames_dir)) {
 const c = path.join(TASKS_DIR, cfg.companions.first_frames_dir);
   if (fs.existsSync(c)) cfg.companions.first_frames_dir = c;
   }
    }
    // dst_dir 若为相对路径，基于 tasks 目录解析（产物 → <ROOT>/tasks/<tag>/，如 subj）
    if (cfg.dst_dir && !path.isAbsolute(cfg.dst_dir)) {
        cfg.dst_dir = path.join(TASKS_DIR, cfg.dst_dir);
    }

    console.log('[build] 收到构建请求: models=%d, n_groups=%d, blind=%s',
        cfg.models.length, cfg.n_groups || 1, cfg.blind !== false);

    try {
        const data = cmdBuild(cfg);
        console.log('[build] 构建完成: samples=%d, mapRows=%d, verifyOk=%s',
            data.samples, data.mapRows, data.verifyOk);
        res.json({ ok: true, data });
    } catch (e) {
        console.error('[build] 构建失败:', e.message);
        res.status(400).json({ ok: false, error: e.message });
    }
}

module.exports = { handle };

// ─────────────────────────────────────────────────────────────────────
//  POST /api/build/zip — 将构建输出目录压缩为 zip 放到 testsrc/
// ─────────────────────────────────────────────────────────────────────

const archiver = require('archiver');

const { TESTSRC_DIR } = require('../lib/paths');

function handleZip(req, res) {
    const { dstDir, tag } = req.body || {};
    if (!dstDir) {
        return res.status(400).json({ ok: false, error: '缺少 dstDir 参数' });
    }
    if (!fs.existsSync(dstDir)) {
        return res.status(400).json({ ok: false, error: `输出目录不存在: ${dstDir}` });
    }

    // 确保 testsrc 目录存在
    if (!fs.existsSync(TESTSRC_DIR)) {
        fs.mkdirSync(TESTSRC_DIR, { recursive: true });
    }

  const zipName = (tag || path.basename(dstDir)) + '.zip';
    const zipPath = path.join(TESTSRC_DIR, zipName);

    // 如果已存在旧 zip，先删除
    if (fs.existsSync(zipPath)) {
        try { fs.unlinkSync(zipPath); } catch (_) {}
    }

    const output = fs.createWriteStream(zipPath);
    const archive = archiver('zip', { zlib: { level: 6 } });

    output.on('close', () => {
      console.log('[build/zip] 压缩完成: %s (%d bytes)', zipName, archive.pointer());
        res.json({ ok: true, zipName, zipPath, size: archive.pointer() });
    });

    archive.on('error', (err) => {
        console.error('[build/zip] 压缩失败:', err.message);
        res.status(500).json({ ok: false, error: '压缩失败: ' + err.message });
    });

    archive.pipe(output);
    // 将整个 dstDir 目录内容添加到 zip 根目录，顶层目录名为 tag
  archive.directory(dstDir, tag || path.basename(dstDir));
    archive.finalize();
}

module.exports.handleZip = handleZip;

// ─────────────────────────────────────────────────────────────────────
//  POST /api/build/list-models — 列出源模型目录下的子目录
// ─────────────────────────────────────────────────────────────────────

function handleListModels(req, res) {
    const { src_model_dir } = req.body || {};
    if (!src_model_dir) return res.status(400).json({ ok: false, error: '缺少 src_model_dir' });
    try {
        if (!fs.existsSync(src_model_dir) || !fs.statSync(src_model_dir).isDirectory()) {
            return res.status(400).json({ ok: false, error: `目录不存在: ${src_model_dir}` });
        }
        const entries = fs.readdirSync(src_model_dir, { withFileTypes: true });
        const dirs = entries
            .filter(e => e.isDirectory() && !e.name.startsWith('.'))
            .map(e => e.name)
            .sort();
        res.json({ ok: true, dirs });
    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    }
}

module.exports.handleListModels = handleListModels;
