/**
 * src/api/analyze.js — POST /api/analyze
 *
 * 盲评分析接口（纯 JS 实现，不依赖 Python）：
 *   把选中的 CSV 合并 → analyze/verify/rank → 返回结构化 JSON。
 * 仅已登录管理员可用（由 auth.requireAdmin 中间件保证）。
 *
 * 请求 body:
 *   { names: ["file1.csv", ...], config: { tag, models, ... }, action: "analyze"|"verify"|"rank" }
 *
 * 核心逻辑与 blind_analyze.py 一一对应，JS 版返回结构化数据而非 stdout。
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const { UPLOAD_DIR, ensureDirs } = require('../lib/paths');
const { parseName } = require('../lib/slug');

const NAME_RE = /^[A-Za-z0-9._\-一-龥]+\.csv$/;

// ─────────────────────────────────────────────────────────────────────
//  CSV 工具（纯 JS，兼容 UTF-8 BOM）
// ─────────────────────────────────────────────────────────────────────

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

function csvCell(v) {
    const s = (v == null ? '' : String(v));
    if (/[",\r\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
    return s;
}

// ─────────────────────────────────────────────────────────────────────
//  合并选中文件 → 临时 CSV（含 tag,mode 列）
// ─────────────────────────────────────────────────────────────────────

function mergeSelectedToTemp(names) {
    ensureDirs();
    const allFiles = new Set(fs.readdirSync(UPLOAD_DIR).filter(n => n.endsWith('.csv')));
    const valid = [];
    const seen = new Set();
    for (const n of names) {
        if (!NAME_RE.test(n)) continue;
        if (!allFiles.has(n)) continue;
        if (seen.has(n)) continue;
        seen.add(n);
        valid.push(n);
    }
    if (valid.length === 0) throw new Error('没有有效的选中文件');

    const lines = [];
    let first = true;
    for (const n of valid) {
        let txt;
        try { txt = fs.readFileSync(path.join(UPLOAD_DIR, n), 'utf8'); }
        catch (_) { continue; }
        if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);
        const meta = parseName(n) || {};
        const tag = meta.tag || '';
        const mode = meta.mode || 'subjective';
        const tagCell = csvCell(tag);
        const modeCell = csvCell(mode);
        const rows = txt.split(/\r?\n/);
        for (let i = 0; i < rows.length; i++) {
            const line = rows[i];
            if (i === 0) {
                if (!first) continue;
                lines.push(line + ',tag,mode');
                continue;
            }
            if (line.length === 0) { lines.push(line); continue; }
            lines.push(line + ',' + tagCell + ',' + modeCell);
        }
        first = false;
    }
    if (lines.length === 0) throw new Error('选中文件合并后为空');

    const tmp = path.join(os.tmpdir(), `playerx_analyze_${Date.now()}.csv`);
    fs.writeFileSync(tmp, '﻿' + lines.join('\n'), 'utf8');
    return tmp;
}

// ─────────────────────────────────────────────────────────────────────
//  analyze: Filter → Dedup → De-anonymize
// ─────────────────────────────────────────────────────────────────────

function cmdAnalyze(cfg) {
    const srcDir = cfg.src_model_dir;
    const dstDir = cfg.dst_dir;
    const mapPath = cfg.map_csv;
    const rawPath = cfg.raw_csv;
    const deanonCsv = path.join(dstDir, cfg.deanon_csv || 'playerx_selected_deanon.csv');

    const models = cfg.models;
    const labels = models.map((_, i) => String.fromCharCode(65 + i));
    const dims = cfg.dimensions || ['multi_总分'];
    const tag = cfg.tag || '';
    const samples = resolveSamples(cfg);
    const expect = new Set(samples.map(n => `${n}.mp4`));
    const exclude = new Set(cfg.exclude_raters || []);

    // 读取 map
    const mapRows = loadCsv(mapPath);
    const srcOf = {};
    const grpOf = {};
    for (const r of mapRows) {
        srcOf[r.filename] = r;
        grpOf[r.filename] = r.group;
    }

    // Filter: tag + A/B/C + 样本集内 + 未排除评分员
    const raw = loadCsv(rawPath);
    for (const r of raw) {
        r.folder = (r.folder || '').split('/').pop();  // 兼容完整路径
    }
    let filtered = [];
    let nExcl = 0;
    // tag 为空时不做 tag 过滤（选中文件直接分析）
    const matchTag = (r) => !tag || (r.tag || '') === tag;
    for (const r of raw) {
        const ok = matchTag(r) && labels.includes(r.folder)
            && expect.has(r.file_name) && !exclude.has(r.rater || '');
        if (ok) filtered.push(r);
        else if (matchTag(r) && labels.includes(r.folder)
            && expect.has(r.file_name) && exclude.has(r.rater || '')) nExcl++;
    }
    const dropped = raw.length - filtered.length - nExcl;
    if (filtered.length === 0) {
        throw new Error(`筛选后 0 行：请检查 tag="${tag}" 是否与选中文件匹配、folder 是否为 A/B/C、file_name 是否在样本集内。原始 ${raw.length} 行全部不匹配。`);
    }

    // Dedup: 取每 key 最新 updated_at
    const useDimKey = dims.length > 1;
    const latest = {};
    for (const r of filtered) {
        const key = useDimKey
            ? [r.rater, r.file_name, r.folder, r.slide_type || ''].join('|')
            : [r.rater, r.file_name, r.folder].join('|');
        if (!latest[key] || (r.updated_at || '') > (latest[key].updated_at || '')) {
            latest[key] = r;
        }
    }
    const clean = Object.values(latest);

    // De-anonymize: A/B/C → 真实模型
    const deanon = [];
    for (const r of clean) {
        const m = srcOf[r.file_name];
        if (!m) continue;
        const row = Object.assign({}, r);
        row.group = m.group;
        row.model = m[`${r.folder}_source`];
        row.eval_mode = 'blind';
        deanon.push(row);
    }

    // 写 deanon CSV
    const cols = [...new Set([...Object.keys(clean[0] || {}), 'group', 'model', 'eval_mode'])];
    fs.mkdirSync(dstDir, { recursive: true });
    const out = [cols.map(csvCell).join(',')];
    for (const r of deanon) out.push(cols.map(c => csvCell(r[c] || '')).join(','));
    fs.writeFileSync(deanonCsv, out.join('\n'), 'utf8');

    return {
        raw: raw.length,
        filtered: filtered.length,
        dropped,
        excluded: nExcl,
        deduped: clean.length,
        removed: filtered.length - clean.length,
        deanonRows: deanon.length,
        deanonCsv,
    };
}

// ─────────────────────────────────────────────────────────────────────
//  verify: 独立审计 (L1 磁盘文件 + L2 数据行)
// ─────────────────────────────────────────────────────────────────────

function md5(filePath) {
    return crypto.createHash('md5').update(fs.readFileSync(filePath)).digest('hex');
}

function cmdVerify(cfg) {
    const srcDir = cfg.src_model_dir;
    const dstDir = cfg.dst_dir;
    const mapPath = cfg.map_csv;
    const rawPath = cfg.raw_csv;
    const deanonCsv = path.join(dstDir, cfg.deanon_csv || 'playerx_selected_deanon.csv');

    const models = new Set(cfg.models);
    const labels = cfg.models.map((_, i) => String.fromCharCode(65 + i));
    const dims = cfg.dimensions || ['multi_总分'];
    const tag = cfg.tag || '';
    const samples = resolveSamples(cfg);
    const expect = new Set(samples.map(n => `${n}.mp4`));
    const exclude = new Set(cfg.exclude_raters || []);

    // map 基础索引（与 blind_build.py 一致，后续 L1/L2 共用）
    const mapRows = loadCsv(mapPath);
    const srcOf = {};
    for (const r of mapRows) srcOf[r.filename] = r;

    // 组优先从 map 推导；若 map 异常为空再回退 n_groups
    const groupsFromMap = [...new Set(mapRows.map(r => r.group).filter(Boolean))]
        .sort((a, b) => {
            const ai = parseInt(String(a).replace(/^\D+/, ''), 10);
            const bi = parseInt(String(b).replace(/^\D+/, ''), 10);
            if (!Number.isNaN(ai) && !Number.isNaN(bi)) return ai - bi;
            return String(a).localeCompare(String(b));
        });
    const nGroups = cfg.n_groups || 1;
    const groups = groupsFromMap.length > 0
        ? groupsFromMap
        : Array.from({ length: nGroups }, (_, i) => `g${i + 1}`);

    const details = [];
    let ok = true;
    const skipL1 = !!cfg.skipL1;   // 跳过 L1 磁盘文件审计（仅做 L2 数据校验）

    // ── L1: map ↔ 磁盘文件 ──
    let l1 = 'SKIPPED';

    if (!skipL1) {
        const onDisk = {};
        for (const g of groups) onDisk[g] = {};
        for (const g of groups) for (const lb of labels) onDisk[g][lb] = new Set();

        for (const r of mapRows) {
            const sources = labels.map(lb => r[`${lb}_source`]);
            if (new Set(sources).size !== models.size || !sources.every(s => models.has(s))) {
                details.push(`FAIL 排列 ${r.filename}`);
                ok = false;
            }
            const g = r.group, fn = r.filename;
            for (const lb of labels) {
                const model = r[`${lb}_source`];
                const blindF = path.join(dstDir, g, lb, fn);
                const srcF = path.join(srcDir, model, fn);
                if (!fs.existsSync(blindF)) {
                    details.push(`MISSING ${blindF}`);
                    ok = false;
                    continue;
                }
                if (md5(blindF) !== md5(srcF)) {
                    details.push(`MD5 FAIL ${blindF}`);
                    ok = false;
                }
                onDisk[g][lb].add(fn);
            }
        }
        for (const g of groups) {
            for (const lb of labels) {
                const dir = path.join(dstDir, g, lb);
                const actual = fs.existsSync(dir)
                    ? new Set(fs.readdirSync(dir).filter(f => f.endsWith('.mp4'))) : new Set();
                const expected = onDisk[g][lb];
                if (actual.size !== expected.size || ![...actual].every(f => expected.has(f))) {
                    details.push(`STRAY ${g}/${lb}: 差异=${[...actual].filter(f => !expected.has(f))}`);
                    ok = false;
                }
            }
        }
        l1 = ok ? 'OK' : 'FAIL';
    }

    // ── L2: deanon CSV ↔ 独立重新推导 ──
    let l2Ok = true;
    const useDimKey = dims.length > 1;

    const raw = loadCsv(rawPath);
    for (const r of raw) {
        r.folder = (r.folder || '').split('/').pop();
    }
    // tag 为空时不做 tag 过滤（选中文件直接分析）
    const matchTag2 = (r) => !tag || (r.tag || '') === tag;
    const filtered2 = raw.filter(r =>
        matchTag2(r) && labels.includes(r.folder)
        && expect.has(r.file_name) && !exclude.has(r.rater || ''));

    const latest2 = {};
    for (const r of filtered2) {
        const key = useDimKey
            ? [r.rater, r.file_name, r.folder, r.slide_type || ''].join('|')
            : [r.rater, r.file_name, r.folder].join('|');
        if (!latest2[key] || (r.updated_at || '') > (latest2[key].updated_at || '')) {
            latest2[key] = r;
        }
    }

    const recomputed = {};
    for (const [key, r] of Object.entries(latest2)) {
        const m = srcOf[r.file_name];
        if (!m) continue;
        recomputed[key] = {
            updated_at: r.updated_at, rater: r.rater,
            file_name: r.file_name, folder: r.folder,
            stars: r.stars || '', slide_type: r.slide_type || '',
            group: m.group, model: m[`${r.folder}_source`],
            eval_mode: 'blind',
        };
    }

    const deanonRows = loadCsv(deanonCsv);
    const deanonByKey = {};
    for (const r of deanonRows) {
        const key = useDimKey
            ? [r.rater, r.file_name, r.folder, r.slide_type || ''].join('|')
            : [r.rater, r.file_name, r.folder].join('|');
        deanonByKey[key] = r;
    }

    // 比对 key 集合
    const recomputedKeys = new Set(Object.keys(recomputed));
    const deanonKeys = new Set(Object.keys(deanonByKey));
    const miss = [...recomputedKeys].filter(k => !deanonKeys.has(k)).length;
    const extra = [...deanonKeys].filter(k => !recomputedKeys.has(k)).length;
    if (miss > 0 || extra > 0) {
        details.push(`L2 key集合: 缺${miss} 多${extra}`);
        l2Ok = false;
    }

    // 逐 key 逐字段比对
    const checkFields = ['updated_at', 'rater', 'file_name', 'stars', 'slide_type', 'group', 'model', 'eval_mode'];
    let mismatches = 0;
    for (const key of Object.keys(recomputed)) {
        if (!deanonByKey[key]) continue;
        const a = recomputed[key], b = deanonByKey[key];
        for (const f of checkFields) {
            if (String(b[f] || '') !== String(a[f] || '')) {
                mismatches++;
                if (mismatches <= 5) details.push(`字段不一致 ${key}[${f}]: 期望=${a[f]} 实际=${b[f]}`);
                l2Ok = false;
                break;
            }
        }
    }
    const l2 = l2Ok ? 'OK' : 'FAIL';

    // L1 跳过时，总体结果只看 L2
    const l1Ok = skipL1 ? true : ok;
    const overall = (l1Ok && l2Ok) ? '全部通过' : '有问题';

    return {
        l1, l2, overall,
        skipL1,
        recomputedCount: Object.keys(recomputed).length,
        deanonCount: Object.keys(deanonByKey).length,
        mismatches, details,
    };
}

// ─────────────────────────────────────────────────────────────────────
//  rank: Bradley-Terry + 成对显著性（纯 JS）
// ─────────────────────────────────────────────────────────────────────

function signTestP(k, n) {
    if (n === 0) return 1.0;
    const m = Math.min(k, n - k);
    const nln2 = n * Math.log(0.5);
    // log-space: log(C(n,x) * 0.5^n)
    const terms = [];
    for (let x = 0; x <= m; x++) {
        terms.push(lgamma(n + 1) - lgamma(x + 1) - lgamma(n - x + 1) + nln2);
    }
    const hi = Math.max(...terms);
    return Math.min(2 * Math.exp(hi) * terms.reduce((s, t) => s + Math.exp(t - hi), 0), 1.0);
}

function lgamma(x) {
    // Lanczos approximation (sufficient for our precision)
    const g = 7;
    const c = [0.99999999999980993, 676.5203681218851, -1259.1392167224028,
        771.32342877765313, -176.61502916214059, 12.507343278686905,
        -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7];
    if (x < 0.5) {
        return Math.log(Math.PI / Math.sin(Math.PI * x)) - lgamma(1 - x);
    }
    x -= 1;
    let sum = c[0];
    for (let i = 1; i < g + 2; i++) sum += c[i] / (x + i);
    const t = x + g + 0.5;
    return 0.5 * Math.log(2 * Math.PI) + (x + 0.5) * Math.log(t) - t + Math.log(sum);
}

function bradleyTerry(modelSet, wins, ties) {
    const W = {};
    const N = {};
    for (const m of modelSet) W[m] = 0;
    for (let i = 0; i < modelSet.length; i++) {
        for (let j = i + 1; j < modelSet.length; j++) {
            const a = modelSet[i], b = modelSet[j];
            const wi = wins[`${a}|${b}`] || 0;
            const wj = wins[`${b}|${a}`] || 0;
            const t = ties[[a, b].sort().join('|')] || 0;
            W[a] += wi + 0.5 * t;
            W[b] += wj + 0.5 * t;
            N[[a, b].sort().join('|')] = wi + wj + t;
        }
    }

    let bt = {};
    for (const m of modelSet) bt[m] = 1.0;
    for (let iter = 0; iter < 10000; iter++) {
        const newBt = {};
        for (const i of modelSet) {
            let denom = 0;
            for (const j of modelSet) {
                if (j === i) continue;
                const key = [i, j].sort().join('|');
                denom += (N[key] || 0) / (bt[i] + bt[j]);
            }
            newBt[i] = denom > 0 ? W[i] / denom : bt[i];
        }
        // 几何平均归一化
        const logSum = Object.values(newBt).reduce((s, v) => s + Math.log(v), 0);
        const gm = Math.exp(logSum / modelSet.length);
        for (const k of Object.keys(newBt)) newBt[k] /= gm;
        // 收敛检查
        const maxDiff = Math.max(...modelSet.map(m => Math.abs(newBt[m] - bt[m])));
        bt = newBt;
        if (maxDiff < 1e-12) break;
    }
    return bt;
}

function cmdRank(cfg) {
    const dstDir = cfg.dst_dir;
    const deanonCsv = path.join(dstDir, cfg.deanon_csv || 'playerx_selected_deanon.csv');

    const rows = loadCsv(deanonCsv);
    const blind = rows.filter(r => r.eval_mode === 'blind');
    const modelSet = [...new Set(blind.map(r => r.model))].sort();
    if (modelSet.length < 2) throw new Error('至少需要 2 个模型');

    // 按 (评分员, 样本) 分组，只保留完整组
    const groups = {};
    for (const r of blind) {
        const key = `${r.rater}|${r.file_name}`;
        if (!groups[key]) groups[key] = {};
        groups[key][r.model] = parseInt(r.stars, 10);
    }
    const complete = Object.values(groups).filter(sc =>
        modelSet.every(m => m in sc));
    const G = complete.length;

    // 每模型分数
    const scores = {};
    for (const m of modelSet) scores[m] = [];
    for (const sc of complete) {
        for (const m of modelSet) scores[m].push(sc[m]);
    }

    // 成对胜/负/平
    const wins = {};
    const ties = {};
    for (const sc of complete) {
        for (let i = 0; i < modelSet.length; i++) {
            for (let j = i + 1; j < modelSet.length; j++) {
                const a = modelSet[i], b = modelSet[j];
                const key = [a, b].sort().join('|');
                if (sc[a] > sc[b]) wins[`${a}|${b}`] = (wins[`${a}|${b}`] || 0) + 1;
                else if (sc[b] > sc[a]) wins[`${b}|${a}`] = (wins[`${b}|${a}`] || 0) + 1;
                else ties[key] = (ties[key] || 0) + 1;
            }
        }
    }

    const bt = bradleyTerry(modelSet, wins, ties);
    const btSum = Object.values(bt).reduce((s, v) => s + v, 0);
    const btPct = {}, btElo = {}, btRank = {};
    for (const m of modelSet) {
        btPct[m] = bt[m] / btSum;
        btElo[m] = 400 * Math.log10(bt[m]);
    }
    const sorted = [...modelSet].sort((a, b) => bt[b] - bt[a]);
    sorted.forEach((m, i) => { btRank[m] = i + 1; });

    // 模型表
    const models = sorted.map(m => {
        const s = scores[m];
        const mu = s.reduce((a, b) => a + b, 0) / s.length;
        const sd = Math.sqrt(s.reduce((a, b) => a + (b - mu) ** 2, 0) / s.length);
        const h = 1.96 * sd / Math.sqrt(s.length);
        return {
            name: m, n: s.length,
            mean: +mu.toFixed(4),
            ciLower: +(mu - h).toFixed(4),
            ciUpper: +(mu + h).toFixed(4),
            strength: +btPct[m].toFixed(4),
            elo: +btElo[m].toFixed(1),
            rank: btRank[m],
        };
    });

    // 对比表
    const nPairs = modelSet.length * (modelSet.length - 1) / 2;
    const bonf = 0.05 / nPairs;
    const pairs = [];
    for (let i = 0; i < modelSet.length; i++) {
        for (let j = i + 1; j < modelSet.length; j++) {
            const a = modelSet[i], b = modelSet[j];
            const key = [a, b].sort().join('|');
            const wi = wins[`${a}|${b}`] || 0;
            const wj = wins[`${b}|${a}`] || 0;
            const t = ties[key] || 0;
            const sp = (wi + wj) > 0 ? signTestP(wi, wi + wj) : 1.0;
            pairs.push({
                modelA: a, modelB: b,
                aWins: wi, bWins: wj, ties: t,
                aWinRate: +(wi / G).toFixed(4),
                bWinRate: +(wj / G).toFixed(4),
                signP: +sp.toFixed(6),
                significant: sp < bonf ? '**' : sp < 0.05 ? '*' : 'ns',
            });
        }
    }

    // 写 CSV（兼容 Python 版输出格式）
    // 新规则：有 tag 时写入 tasks/{tag}_map/ 下固定文件名；无 tag 仍用历史时间戳命名
    let rankCsv;
    let pairCsv;
    if (cfg.tag) {
        const { TASKS_DIR } = require('../lib/paths');
        const mapDir = path.join(TASKS_DIR, `${cfg.tag}_map`);
        fs.mkdirSync(mapDir, { recursive: true });
        rankCsv = path.join(mapDir, 'model_ranking.csv');
        pairCsv = path.join(mapDir, 'pairwise_significance.csv');
    } else {
        rankCsv = path.join(dstDir, `model_ranking_${Date.now()}.csv`);
        pairCsv = path.join(dstDir, `pairwise_significance_${Date.now()}.csv`);
        fs.mkdirSync(dstDir, { recursive: true });
    }

    const rankHeader = '模型,样本数,均值,CI95下,CI95上,BT强度,BT_Elo,BT排名';
    const rankRows = models.map(m =>
        [m.name, m.n, m.mean, m.ciLower, m.ciUpper, m.strength, m.elo, m.rank].map(csvCell).join(','));
    fs.writeFileSync(rankCsv, '﻿' + [rankHeader, ...rankRows].join('\n'), 'utf8');

    const pairHeader = `模型A,模型B,A胜,B胜,平,A胜率,B胜率,signP,显著.05,显著${bonf.toFixed(4)}`;
    const pairRows = pairs.map(p =>
        [p.modelA, p.modelB, p.aWins, p.bWins, p.ties, p.aWinRate, p.bWinRate, p.signP,
        p.significant !== 'ns' ? 1 : 0, p.significant === '**' ? 1 : 0].map(csvCell).join(','));
    fs.writeFileSync(pairCsv, '﻿' + [pairHeader, ...pairRows].join('\n'), 'utf8');

    return {
        models, pairs, completeGroups: G,
        rankCsv, pairCsv, bonf: +bonf.toFixed(4),
    };
}

// ─────────────────────────────────────────────────────────────────────
//  样本列表解析
// ─────────────────────────────────────────────────────────────────────

function resolveSamples(cfg) {
    if (cfg.samples && cfg.samples.length > 0) return [...cfg.samples].sort((a, b) => a - b);
    const exclude = new Set(cfg.exclude_samples || []);
    return Array.from({ length: 100 }, (_, i) => i + 1).filter(n => !exclude.has(n));
}

// ─────────────────────────────────────────────────────────────────────
//  主入口
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
//  批量分析：多个 Tag 一次请求返回
// ─────────────────────────────────────────────────────────────────────

function handleBatch(req, res) {
    const { tags, names, config, action } = req.body || {};
    console.log('[analyze/batch] 收到请求: action=%s, tags=%j, names=%d', action, tags, (names || []).length);

    if (!Array.isArray(tags) || tags.length === 0) {
        return res.status(400).json({ ok: false, error: 'missing tags array' });
    }
    if (tags.length > 20) {
        return res.status(400).json({ ok: false, error: 'tags 数量不能超过 20' });
    }

    const act = action || 'rank';
    if (!['analyze', 'verify', 'rank'].includes(act)) {
        return res.status(400).json({ ok: false, error: 'invalid action' });
    }

    const results = [];
    const errors = [];

    for (const tag of tags) {
        const tagStr = String(tag).trim();
        if (!tagStr) continue;
        try {
            const reqBody = { names, config, action: act, tag: tagStr };
            // 直接调用内部方法：merge + analyze + rank
            let resolvedNames = names;
            const { UPLOAD_DIR } = require('../lib/paths');
            if (!Array.isArray(resolvedNames) || resolvedNames.length === 0) {
                const allFiles = fs.readdirSync(UPLOAD_DIR).filter(f => f.endsWith('.csv'));
                resolvedNames = allFiles.filter(f => {
                    const parts = f.split('__');
                    return parts.length >= 2 && parts[1] === tagStr;
                });
                if (resolvedNames.length === 0) {
                    errors.push({ tag: tagStr, error: '未找到评分文件' });
                    continue;
                }
            }

            let tmpCsv = null;
            try {
                tmpCsv = mergeSelectedToTemp(resolvedNames);
                const cfg = Object.assign({}, config || {});
                cfg.raw_csv = tmpCsv;
                cfg.tag = tagStr;

                // 自动定位 map CSV
                const { TASKS_DIR } = require('../lib/paths');
                const mapCandidates = [
                    path.join(TASKS_DIR, `${tagStr}_map`, 'map.csv'),
                    path.join(TASKS_DIR, tagStr, 'map.csv'),
                    path.join(TASKS_DIR, tagStr, `map_${tagStr}.csv`),
                ];
                for (const c of mapCandidates) {
                    if (fs.existsSync(c)) { cfg.map_csv = c; break; }
                }
                cfg.dst_dir = path.join(TASKS_DIR, `${tagStr}_map`);
                cfg.deanon_csv = cfg.deanon_csv || 'deanon.csv';

                // 从 map CSV 自动推断 models
                if (!cfg.models && cfg.map_csv && fs.existsSync(cfg.map_csv)) {
                    const mapLines = fs.readFileSync(cfg.map_csv, 'utf8').replace(/\r/g, '').split('\n');
                    const cols = (mapLines[0] || '').split(',').map(c => c.trim()).filter(c => c.endsWith('_source'));
                    if (cols.length > 0 && mapLines.length > 1) {
                        const vals = mapLines[1].split(',').map(v => v.trim());
                        const headerArr = (mapLines[0] || '').split(',').map(c => c.trim());
                        cfg.models = cols.map(c => {
                            const idx = headerArr.indexOf(c);
                            return idx >= 0 ? vals[idx] : c.replace('_source', '');
                        });
                    }
                }
                if (!cfg.models || cfg.models.length === 0) {
                    errors.push({ tag: tagStr, error: '无法确定 models' });
                    continue;
                }

                const analyzeData = cmdAnalyze(cfg);
                const rankData = cmdRank(cfg);
                results.push({
                    tag: tagStr,
                    fileCount: resolvedNames.length,
                    ...analyzeData,
                    ...rankData,
                });
            } finally {
                if (tmpCsv) try { fs.unlinkSync(tmpCsv); } catch (_) { }
            }
        } catch (e) {
            console.error(`[analyze/batch] tag=${tagStr} 错误:`, e.message);
            errors.push({ tag: tagStr, error: e.message });
        }
    }

    res.json({
        ok: true,
        results,
        errors: errors.length > 0 ? errors : undefined,
    });
}

function handle(req, res) {
    const { names, config, action, tag, verify } = req.body || {};

    // 批量分析路由
    if (req.body && Array.isArray(req.body.tags)) {
        return handleBatch(req, res);
    }

    console.log('[analyze] 收到请求: action=%s, tag=%s, names=%d, config=%j', action, tag, (names || []).length, config);

    const act = action || 'rank';
    const rawVerify = (req.body && (req.body.verify ?? req.body.doVerify)) ?? verify;
    const doVerify = (() => {
        if (typeof rawVerify === 'string') {
            const v = rawVerify.trim().toLowerCase();
            return ['1', 'true', 'yes', 'on'].includes(v);
        }
        return !!rawVerify;
    })();
    if (!['analyze', 'verify', 'rank'].includes(act)) {
        return res.status(400).json({ ok: false, error: 'invalid action, must be analyze/verify/rank' });
    }

    //── 按 tag 自动联动配置 + 查找 map CSV；names 为空时再按 tag 自动搜集评分文件 ──
    let resolvedNames = names;
    let autoMapCsv = null;
    let autoConfig = null;  // 从 configs/ 目录自动定位到的配置

    if (tag) {
        const { UPLOAD_DIR, TASKS_DIR, CONFIGS_DIR } = require('../lib/paths');

        // 自动联动配置文件：扫描 configs/ 目录，找到 build.tag === tag 的配置
        if (fs.existsSync(CONFIGS_DIR)) {
            const configFiles = fs.readdirSync(CONFIGS_DIR).filter(f => f.endsWith('.json'));
            for (const cf of configFiles) {
                try {
                    const cfgData = JSON.parse(fs.readFileSync(path.join(CONFIGS_DIR, cf), 'utf8'));
                    if (cfgData.build && cfgData.build.tag === tag) {
                        autoConfig = cfgData;
                        console.log('[analyze] 自动联动配置文件: %s (build.tag=%s)', cf, tag);
                        break;
                    }
                } catch (e) { /* skip invalid json */ }
            }
        }

        // 自动查找 map CSV（新规则优先，保留极少量历史回退）
        // 新：tasks/{tag}_map/map.csv
        // 旧：tasks/{tag}/map.csv / tasks/{tag}/map_{tag}.csv
        const mapCandidates = [
            path.join(TASKS_DIR, `${tag}_map`, 'map.csv'),
            path.join(TASKS_DIR, tag, 'map.csv'),
            path.join(TASKS_DIR, tag, `map_${tag}.csv`),
        ];
        for (const c of mapCandidates) {
            if (fs.existsSync(c)) { autoMapCsv = c; break; }
        }
        console.log('[analyze] 自动定位 map CSV: %s', autoMapCsv || '未找到');

        // names 缺失时，才按 tag 自动匹配评分文件
        if (!Array.isArray(names) || names.length === 0) {
            const allFiles = fs.readdirSync(UPLOAD_DIR).filter(f => f.endsWith('.csv'));
            resolvedNames = allFiles.filter(f => {
                // 文件名格式：user__tag__mode__ts.csv（双下划线分割）
                const parts = f.split('__');
                return parts.length >= 2 && parts[1] === tag;
            });
            if (resolvedNames.length === 0) {
                return res.status(400).json({ ok: false, error: `没有找到 tag="${tag}" 的评分文件` });
            }
            console.log('[analyze] tag=%s 自动匹配到 %d 个评分文件', tag, resolvedNames.length);
        }
    }

    if (!Array.isArray(resolvedNames) || resolvedNames.length === 0) {
        return res.status(400).json({ ok: false, error: 'missing names array（或 tag 未匹配到文件）' });
    }

    let tmpCsv = null;
    try {
        // 1. 合并选中文件 → 临时 CSV
        console.log('[analyze] 步骤1: 合并选中文件...');
        tmpCsv = mergeSelectedToTemp(resolvedNames);
        console.log('[analyze] 合并完成: %s (%d bytes)', tmpCsv, fs.statSync(tmpCsv).size);

        // 2. 构建配置（解析相对路径 + 自动检测 tag）
        console.log('[analyze] 步骤2: 构建配置...');
        const cfg = Object.assign({}, config || {});
        cfg.raw_csv = tmpCsv;
        if (tag) cfg.tag = tag;
        // map_csv 优先用 auto检测到的
        if (autoMapCsv && !cfg.map_csv) cfg.map_csv = autoMapCsv;

        // 合并自动联动的配置文件中的 build 字段（提供 samples/exclude_samples/n_groups 等）
        if (autoConfig && autoConfig.build) {
            const bc = autoConfig.build;
            if (bc.samples && !cfg.samples) cfg.samples = bc.samples;
            if (bc.exclude_samples && !cfg.exclude_samples) cfg.exclude_samples = bc.exclude_samples;
            if (bc.n_groups && !cfg.n_groups) cfg.n_groups = bc.n_groups;
            if (bc.models && !cfg.models) cfg.models = bc.models;
            if (bc.map_csv && !cfg.map_csv) cfg.map_csv = bc.map_csv;
            // 注意：永远忽略 build.dst_dir，强制统一写到 tasks/{tag}_map，
            // 避免与 build 产物 (map.csv / model_ranking.csv 等) 分裂到不同目录。
            if (bc.seed != null && cfg.seed == null) cfg.seed = bc.seed;
            console.log('[analyze] 已合并 build 配置: samples=%j, exclude=%j, n_groups=%s',
                cfg.samples, cfg.exclude_samples, cfg.n_groups);
        }

        // src_model_dir 支持相对路径（相对 ROOT_DIR 解析），方便服务器迁移后仍可定位。
        if (cfg.src_model_dir && !path.isAbsolute(cfg.src_model_dir)) {
            const { resolveSourcePath } = require('../lib/paths');
            cfg.src_model_dir = resolveSourcePath(cfg.src_model_dir);
            console.log('[analyze] src_model_dir 相对路径解析: %s', cfg.src_model_dir);
        }

        // map_csv 若为相对路径，从 tasks 目录解析
        const { TASKS_DIR } = require('../lib/paths');
        // dst_dir 强制为 tasks/{tag}_map（无 tag 兜底到 _default_map），保证所有产物集中
        cfg.dst_dir = path.join(TASKS_DIR, tag ? `${tag}_map` : '_default_map');
        // deanon 固定名（统一按 {tag}_map 隔离）
        if (!cfg.deanon_csv) cfg.deanon_csv = 'deanon.csv';
        if (cfg.map_csv && !path.isAbsolute(cfg.map_csv)) {
            const candidate = path.join(TASKS_DIR, cfg.map_csv);
            console.log('[analyze] map_csv 相对路径解析: %s → %s (存在: %s)', cfg.map_csv, candidate, fs.existsSync(candidate));
            if (fs.existsSync(candidate)) cfg.map_csv = candidate;
        }

        // 将合并后的 CSV 拷贝到输出目录：固定名 merged.csv（无 tag 兜底用时间戳）
        const mergedDst = tag
            ? path.join(cfg.dst_dir, 'merged.csv')
            : path.join(cfg.dst_dir, `merged_${Date.now()}.csv`);
        fs.mkdirSync(cfg.dst_dir, { recursive: true });
        fs.copyFileSync(tmpCsv, mergedDst);
        console.log('[analyze] 合并 CSV 已保存到: %s', mergedDst);

        console.log('[analyze] 最终配置: %j', cfg);

        // 如果 cfg.models 缺失（独立分析面板不传 models），从 map CSV 自动推断：
        // map CSV 表头含 A_source / B_source / C_source ...，列数即模型数，
        // 取第一行数据的各 *_source 值作为 models 名称。
        if (!cfg.models && cfg.map_csv && fs.existsSync(cfg.map_csv)) {
            const mapLines = fs.readFileSync(cfg.map_csv, 'utf8').replace(/\r/g, '').split('\n');
            const mapHeader = mapLines[0] || '';
            const cols = mapHeader.split(',').map(c => c.trim()).filter(c => c.endsWith('_source'));
            if (cols.length > 0 && mapLines.length > 1) {
                // 从第一行数据中提取模型名
                const vals = mapLines[1].split(',').map(v => v.trim());
                const headerArr = mapHeader.split(',').map(c => c.trim());
                cfg.models = cols.map(c => {
                    const idx = headerArr.indexOf(c);
                    return idx >= 0 ? vals[idx] : c.replace('_source', '');
                });
                console.log('[analyze] 从 map CSV 自动推断 models: %j', cfg.models);
            }
        }
        if (!cfg.models || cfg.models.length === 0) {
            throw new Error('无法确定 models：请确保 map CSV 存在且包含 A_source/B_source 等列');
        }

        // 3. 执行：rank 前自动先跑 analyze 生成 deanon CSV
        let data;
        const verifyCfg = { ...cfg };
        // 未提供 src_model_dir 时自动跳过 L1（避免 path.join(undefined, ...)）
        if (!verifyCfg.src_model_dir) verifyCfg.skipL1 = true;

        if (act === 'analyze') {
            console.log('[analyze] 步骤3: 执行 cmdAnalyze...');
            data = cmdAnalyze(cfg);
        } else if (act === 'verify') {
            console.log('[analyze] 步骤3: 先跑 analyze，再执行 cmdVerify...');
            const analyzeData = cmdAnalyze(cfg);
            const verifyData = cmdVerify(verifyCfg);
            data = {
                ...analyzeData,
                verify: verifyData,
                fileCount: resolvedNames.length,
            };
        } else if (act === 'rank') {
            // 先跑 analyze 生成 deanon CSV，再跑 rank
            console.log('[analyze] 步骤3: 先跑 analyze 生成 deanon CSV...');
            const analyzeData = cmdAnalyze(cfg);
            console.log('[analyze] analyze 完成，执行 cmdRank...');
            const rankData = cmdRank(cfg);
            data = {
                ...analyzeData,
                ...rankData,
                fileCount: resolvedNames.length,
            };
            if (doVerify) {
                console.log('[analyze] 执行可选 verify...');
                data.verify = cmdVerify(verifyCfg);
            }
        }
        console.log('[analyze] 执行完成');

        // 4. 清理临时文件
        try { fs.unlinkSync(tmpCsv); } catch (_) { }

        res.json({ ok: true, action: act, data });
    } catch (e) {
        console.error('[analyze] 错误:', e.message, e.stack);
        if (tmpCsv) try { fs.unlinkSync(tmpCsv); } catch (_) { }
        return res.status(400).json({ ok: false, error: e.message });
    }
}

module.exports = { handle };
