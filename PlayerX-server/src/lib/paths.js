/**
 * src/lib/paths.js — 服务侧基础路径与常量
 *
 * 单点维护：上传目录 / 归档目录 / 上传上限 / 每槽位归档保留份数 / 上传 Token。
 * 业务模块（upload/list/merge/archive/settings）一律从这里取路径与配置。
 */
const fs   = require('fs');
const path = require('path');

// 工程根（PlayerX-server/）
const ROOT_DIR = path.resolve(__dirname, '..', '..');

const UPLOAD_DIR  = path.join(ROOT_DIR, 'uploads');
const ARCHIVE_DIR = path.join(ROOT_DIR, 'archive');
const WEB_DIR     = path.join(ROOT_DIR, 'src', 'web');
// 构建任务产物目录：每个 tag 一个子目录
const TASKS_DIR = path.join(ROOT_DIR, 'tasks');
// 测试源安装包（zip）托管目录：客户端按 testSource.url 直接从此下载
const TESTSRC_DIR = path.join(ROOT_DIR, 'testsrc');
// 分析结果分享快照（任意人通过链接即可查看，永久有效直到管理员删除）
const SHARES_DIR = path.join(ROOT_DIR, 'shares');
// 管理员手动上传的模型文件夹根（用于"模型管理"页面的"上传文件夹"功能）
// 所有通过上传接口创建的源目录都会放在这里；路径以 "assets/<name>" 的相对
// 形式存储到 models-config.json，这样整个目录被迁到其他机器上后无需改配置
// 也能正确解析到 assets/<name>。
const ASSETS_DIR = path.join(ROOT_DIR, 'assets');

// 运行时可变配置（管理面板修改后会写入此文件，重启也生效）
const CONFIG_FILE = path.join(ROOT_DIR, 'config.json');

// 单文件上限：10MB（CSV 远到不了这个量级，纯防呆）
const MAX_BYTES = 10 * 1024 * 1024;

// 每个 (user, tag) 槽位最多保留的历史归档数；更早的物理删除
const ARCHIVE_KEEP = 20;

// ─────────────────────────────────────────────────────────────
// 上传 Token 配置
//
// 优先级：config.json > 环境变量 PLAYERX_TOKEN > 默认 '123456'
//   - 默认 '123456'：默认开启鉴权
//   - 在 config.json 中显式置为 '' 或环境变量设为 '-'：关闭鉴权
//
// 配置由 settings 路由实时改写到 config.json，无需重启。
// ─────────────────────────────────────────────────────────────
function _readConfigFile() {
    try {
        const raw = fs.readFileSync(CONFIG_FILE, 'utf8');
        const obj = JSON.parse(raw);
        return (obj && typeof obj === 'object') ? obj : {};
    } catch (_) {
        return {};
    }
}

function _writeConfigFile(obj) {
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(obj, null, 2), 'utf8');
}

function getUploadToken() {
    // 1) config.json 中显式设置（包括显式空字符串：关闭鉴权）
    const cfg = _readConfigFile();
    if (Object.prototype.hasOwnProperty.call(cfg, 'uploadToken')) {
        return String(cfg.uploadToken || '');
    }
    // 2) 环境变量
    const raw = process.env.PLAYERX_TOKEN;
    if (raw !== undefined) {
        const v = raw.trim();
        return v === '-' ? '' : v;
    }
    // 3) 默认
    return '123456';
}

function setUploadToken(value) {
    const cfg = _readConfigFile();
    cfg.uploadToken = String(value == null ? '' : value);
    _writeConfigFile(cfg);
    return cfg.uploadToken;
}

// 旧名兼容：现存代码里若仍有 resolveToken() 调用，行为保持一致。
function resolveToken() {
    return getUploadToken();
}

// 在每个会读/写这两个目录的入口都先调一下，保证运行期手工删了目录也能自愈。
// 否则 readdirSync 会抛 ENOENT，整个接口就 500/400 给客户端。
function ensureDirs() {
    fs.mkdirSync(UPLOAD_DIR, { recursive: true });
    fs.mkdirSync(ARCHIVE_DIR, { recursive: true });
    fs.mkdirSync(TASKS_DIR, { recursive: true });
    fs.mkdirSync(TESTSRC_DIR, { recursive: true });
    fs.mkdirSync(SHARES_DIR, { recursive: true });
    fs.mkdirSync(ASSETS_DIR, { recursive: true });
}

// ─────────────────────────────────────────────────────────────
// 路径解析助手：把存储在配置里的 path 统一还原为绝对路径
//
// 规则：
//   - 以 / 开头 → 当作绝对路径直接返回（兼容老数据）
//   - 以 assets/ 开头 → 相对 ROOT_DIR 解析（推荐：服务器迁移后无需改）
//   - 其他相对路径 → 相对 ROOT_DIR 解析（兜底）
//
// 解析后的路径再做一次 realpath（如果存在），避免符号链接导致的相对路径歧义。
// 不存在时不抛错，原样返回调用方处理。
// ─────────────────────────────────────────────────────────────
function resolveSourcePath(storedPath) {
    if (!storedPath) return '';
    if (path.isAbsolute(storedPath)) {
        try { return fs.realpathSync(storedPath); } catch (_) { return storedPath; }
    }
    const abs = path.resolve(ROOT_DIR, storedPath);
    try { return fs.realpathSync(abs); } catch (_) { return abs; }
}

// 把绝对路径转回相对 ROOT_DIR 的存储形式（如 "assets/foo"），用于写入
// models-config.json。如果该绝对路径就在 ROOT_DIR 下，就用相对形式；
// 否则保留绝对路径（外部挂载的目录无法用相对形式表达）。
function relativizeSourcePath(absPath) {
    if (!absPath) return '';
    const rel = path.relative(ROOT_DIR, absPath);
    if (!rel.startsWith('..') && !path.isAbsolute(rel)) {
        return rel.replace(/\\/g, '/');
    }
    return absPath;
}

module.exports = {
    ROOT_DIR,
    UPLOAD_DIR,
    ARCHIVE_DIR,
    WEB_DIR,
    TASKS_DIR,
    TESTSRC_DIR,
    SHARES_DIR,
    ASSETS_DIR,
    CONFIG_FILE,
    MAX_BYTES,
    ARCHIVE_KEEP,
    getUploadToken,
    setUploadToken,
    resolveToken,
    ensureDirs,
    resolveSourcePath,
    relativizeSourcePath,
};
