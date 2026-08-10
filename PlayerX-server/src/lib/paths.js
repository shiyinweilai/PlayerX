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
}

module.exports = {
    ROOT_DIR,
    UPLOAD_DIR,
    ARCHIVE_DIR,
    WEB_DIR,
    TASKS_DIR,
    TESTSRC_DIR,
    SHARES_DIR,
    CONFIG_FILE,
    MAX_BYTES,
    ARCHIVE_KEEP,
    getUploadToken,
    setUploadToken,
    resolveToken,
    ensureDirs,
};
