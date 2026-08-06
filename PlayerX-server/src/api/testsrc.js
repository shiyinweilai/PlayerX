/**
 * src/api/testsrc.js — 测试源安装包（zip）托管
 *
 * 背景：
 *   配置的 testSource.url 原先只能指向 COS 等公网地址。
 *   内网部署时把 zip 直接放到评分服务器上，客户端下载走内网带宽，
 *   通常比 COS 公网更快，也不依赖外网连通性。
 *
 * 提供：
 *   GET    /testsrc/<name>        静态下载（在 server.js 挂载，express.static 自带 Range/etag）
 *   GET    /api/testsrc/list      包列表（匿名可读，与 list/files 等读接口一致）
 *   POST   /api/testsrc/upload    上传 zip（需管理员，multer 磁盘存储，支持大文件）
 *   DELETE /api/testsrc/:name     删除（需管理员）
 *
 * 安全：
 *   - 文件名一律 path.basename 去路径，并再拒绝一次分隔符，防路径逃逸
 *   - 写操作走 requireAdmin（X-Admin-Token），与配置/归档写操作一致
 *   - 服务定位受信任内网，下载不设鉴权
 */
const fs     = require('fs');
const path   = require('path');
const multer = require('multer');
const AdmZip = require('adm-zip');

const { TESTSRC_DIR } = require('../lib/paths');
const { requireAdmin } = require('./auth');

// 上传大小上限：测试源 zip 通常几百 MB，放宽到 4GB
//（上传 CSV 的 MAX_BYTES=10MB 是针对评分 CSV 的，不适用于此）
const MAX_ZIP_BYTES = 4 * 1024 * 1024 * 1024;

function sanitizeName(raw) {
    const base = path.basename(String(raw || '')).trim();
    if (!base || base === '.' || base === '..') return null;
    if (/[\\/]/.test(base)) return null;
    return base;
}

function fileInfo(name) {
    let size = 0, mtime = '';
    try {
        const st = fs.statSync(path.join(TESTSRC_DIR, name));
        size = st.size;
        mtime = st.mtime.toISOString();
    } catch (_) { /* 忽略 */ }
    return { name, size, mtime, url: '/testsrc/' + encodeURIComponent(name) };
}

/**
 * 分析 zip 包结构，返回建议字段：
 *   - rootDir:       zip 内顶层目录名
 *   - laneDirs:      自动识别的对比路目录（如 A/B/C）
 *   - referenceDirs: 自动识别的参考图目录（如 first_frames）
 *   - promptCsv:     自动识别的提示词文件（如 prompt.csv）
 *   - groups:        自动识别的组目录（如 g1/g2）
 *   - allDirs:       rootDir 下所有子目录列表（供前端参考）
 *
 * 智能下钻：如果 rootDir 下一层是"组目录"（g1, g2, group1 等），
 *   自动下钻到第一个组里去识别 laneDirs / referenceDirs / promptCsv。
 *   这样既支持「rootDir/A/...」的扁平结构，也支持「rootDir/g1/A/...」的分组结构。
 */
function analyzeZip(filePath) {
    const suggestions = { rootDir: '', laneDirs: [], referenceDirs: [], promptCsv: '', groups: [], allDirs: [] };
    try {
        const zip = new AdmZip(filePath);
        const entries = zip.getEntries();

        if (entries.length === 0) return suggestions;

        // ── 1. 找出顶层公共目录作为 rootDir ──
        const prefixes = new Map();
        const topLevelDirs = new Set();
        for (const entry of entries) {
            const name = entry.entryName.replace(/\\/g, '/');
            if (entry.isDirectory) {
                const parts = name.split('/').filter(Boolean);
                if (parts.length === 1) topLevelDirs.add(parts[0]);
                continue;
            }
            const slashIdx = name.indexOf('/');
            if (slashIdx > 0) {
                const prefix = name.substring(0, slashIdx);
                prefixes.set(prefix, (prefixes.get(prefix) || 0) + 1);
            }
        }
        for (const d of topLevelDirs) {
            if (!prefixes.has(d)) prefixes.set(d, 0);
        }
        let rootDir = '';
        let maxCount = 0;
        for (const [p, c] of prefixes) {
            if (c > maxCount) { maxCount = c; rootDir = p; }
        }
        if (prefixes.size === 1) {
            rootDir = [...prefixes.keys()][0];
        }
        suggestions.rootDir = rootDir;

        // ── 2. 取出 rootDir 下所有一级子目录（包含子文件时也算）──
        const rootPrefix = rootDir ? rootDir + '/' : '';
        const rootLevelDirs = collectSubdirs(entries, rootPrefix);
        suggestions.allDirs = rootLevelDirs;

        // ── 3. 识别"组目录"（g1, g2, group1, group_2 等），用于智能下钻 ──
        const groupPattern = /^(g|group|grp|set|subset|group_)[_\s-]?\d+$/i;
        const groupDirs = rootLevelDirs.filter(d => groupPattern.test(d));
        const nonGroupDirs = rootLevelDirs.filter(d => !groupPattern.test(d));
        if (groupDirs.length > 0) {
            suggestions.groups = groupDirs;
        }

        // ── 4. 决定在哪一层找 laneDirs / referenceDirs / promptCsv ──
        //   优先级：下钻到组目录内 > rootDir 直下一层
        //   判定：组目录存在且组内有 lane 模式匹配（说明 lanes 藏在组下）则下钻
        let searchLevel = rootLevelDirs;
        let searchPrefix = rootPrefix;
        if (groupDirs.length > 0) {
            // 探查第一个组内是否存在 lane 模式目录
            const firstGroup = groupDirs[0];
            const innerPrefix = rootPrefix + firstGroup + '/';
            const innerDirs = collectSubdirs(entries, innerPrefix);
            const lanePeek = innerDirs.filter(d => /^[A-Za-z]$/.test(d) || /^[0-9]+$/.test(d));
            if (lanePeek.length >= 2) {
                // 组内确实有 lanes，切换到组层
                searchLevel = innerDirs;
                searchPrefix = innerPrefix;
            }
        }

        // ── 5. 识别 laneDirs（常见模式：A/B/C、1/2/3、lane_1/lane_2）──
        const lanePatterns = [
            /^[A-Za-z]$/,                          // 单字母 A, B, C
            /^[0-9]+$/,                            // 纯数字 1, 2, 3
            /^(lane|method)[_\s-]?[0-9]+$/i,       // lane_1, method1
        ];
        const laneCandidates = searchLevel.filter(d => lanePatterns.some(p => p.test(d)));
        if (laneCandidates.length >= 2 && laneCandidates.length <= 10) {
            suggestions.laneDirs = laneCandidates.sort((a, b) => {
                const am = a.match(/\d+/);
                const bm = b.match(/\d+/);
                const na = am ? parseInt(am[0], 10) : 0;
                const nb = bm ? parseInt(bm[0], 10) : 0;
                if (na !== nb) return na - nb;
                return a.localeCompare(b);
            });
        }

        // ── 6. 识别 referenceDirs（参考图目录）──
        const refPattern = /^(first[_\s]?frames?|ref(erence)?[_\s]?frames?|second[_\s]?frames?|input[_\s]?frames?|src[_\s]?frames?)$/i;
        const refCandidates = searchLevel.filter(d => refPattern.test(d));
        if (refCandidates.length > 0) {
            suggestions.referenceDirs = refCandidates.slice(0, 2);
        } else {
            // 显式返回空数组（告诉前端"未识别到"，可让前端决定是否清空）
            suggestions.referenceDirs = [];
        }

        // ── 7. 识别 promptCsv ──
        const promptPattern = /^(prompt|prompts|meta)\.csv$/i;
        for (const entry of entries) {
            const name = entry.entryName.replace(/\\/g, '/');
            if (!name.startsWith(searchPrefix)) continue;
            const relative = name.substring(searchPrefix.length);
            if (promptPattern.test(relative) && !entry.isDirectory) {
                suggestions.promptCsv = relative;
                break;
            }
        }

    } catch (e) {
        console.error('[testsrc] zip 分析失败:', e.message);
    }
    return suggestions;
}

/** 取出某 prefix 下的一级子目录名集合（含子文件时也算） */
function collectSubdirs(entries, prefix) {
    const out = new Set();
    for (const entry of entries) {
        const name = entry.entryName.replace(/\\/g, '/');
        if (!name.startsWith(prefix)) continue;
        const relative = name.substring(prefix.length);
        if (!relative) continue;
        // 一级子目录名 = 第一个 '/' 前的部分
        const slashIdx = relative.indexOf('/');
        if (slashIdx > 0) {
            out.add(relative.substring(0, slashIdx));
        } else if (entry.isDirectory) {
            out.add(relative);
        } else {
            // 裸文件（没有下一级），不当作目录
        }
    }
    return [...out];
}

// multer 磁盘存储：直接写入托管目录，保留原始文件名（同名覆盖，便于同名包更新）
const storage = multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, TESTSRC_DIR),
    filename: (_req, file, cb) => {
        // multer 按 latin1 解析文件名，中文名需转回 utf8
        let name = Buffer.from(file.originalname || 'package.zip', 'latin1').toString('utf8');
        name = sanitizeName(name) || 'package.zip';
        cb(null, name);
    },
});
const upload = multer({
    storage,
    limits: { fileSize: MAX_ZIP_BYTES },
});

function register(app) {
    // 包列表：新上传的排前
    app.get('/api/testsrc/list', (_req, res) => {
        let ents = [];
        try { ents = fs.readdirSync(TESTSRC_DIR, { withFileTypes: true }); } catch (_) {}
        const files = ents
            .filter(e => e.isFile() && !e.name.startsWith('.'))
            .map(e => fileInfo(e.name))
            .sort((a, b) => b.mtime.localeCompare(a.mtime));
        res.json({ ok: true, files });
    });

    // 上传（multipart 字段名 file）
    app.post('/api/testsrc/upload', requireAdmin, upload.single('file'), (req, res) => {
        if (!req.file) {
            return res.status(400).json({ ok: false, error: '缺少文件（multipart 字段名 file）' });
        }
        const name = req.file.filename;
        console.log(`[testsrc] 上传完成: ${name} (${req.file.size} B)`);

        // 分析 zip 内容，返回建议字段
        const zipPath = path.join(TESTSRC_DIR, name);
        const suggestions = name.endsWith('.zip') ? analyzeZip(zipPath) : null;

        const info = fileInfo(name);
        const result = Object.assign({ ok: true }, info);
        if (suggestions) {
            result.suggestions = suggestions;
            console.log(`[testsrc] zip 分析: rootDir="${suggestions.rootDir}", laneDirs=[${suggestions.laneDirs.join(',')}], refDirs=[${suggestions.referenceDirs.join(',')}], promptCsv="${suggestions.promptCsv}"`);
        }
        res.json(result);
    });

    // 删除
    app.delete('/api/testsrc/:name', requireAdmin, (req, res) => {
        const name = sanitizeName(req.params.name);
        if (!name) return res.status(400).json({ ok: false, error: '非法文件名' });
        const full = path.join(TESTSRC_DIR, name);
        if (path.dirname(full) !== TESTSRC_DIR) {
            return res.status(400).json({ ok: false, error: '非法文件名' });
        }
        fs.unlink(full, err => {
            if (err) {
                if (err.code === 'ENOENT') return res.status(404).json({ ok: false, error: '文件不存在' });
                return res.status(500).json({ ok: false, error: err.message });
            }
            console.log(`[testsrc] 已删除: ${name}`);
            res.json({ ok: true, deleted: name });
        });
    });
}

module.exports = register;
