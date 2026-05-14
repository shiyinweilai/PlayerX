/**
 * src/lib/paths.js — 服务侧基础路径与常量
 *
 * 单点维护：上传目录 / 归档目录 / 上传上限 / 每槽位归档保留份数 / 默认 token。
 * 业务模块（upload/list/merge/archive）一律从这里取路径，避免散落各处。
 */
const fs   = require('fs');
const path = require('path');

// 工程根（PlayerX-server/）
const ROOT_DIR = path.resolve(__dirname, '..', '..');

const UPLOAD_DIR  = path.join(ROOT_DIR, 'uploads');
const ARCHIVE_DIR = path.join(ROOT_DIR, 'archive');
const WEB_DIR     = path.join(ROOT_DIR, 'src', 'web');

// 单文件上限：10MB（CSV 远到不了这个量级，纯防呆）
const MAX_BYTES = 10 * 1024 * 1024;

// 每个 (user, tag) 槽位最多保留的历史归档数；更早的物理删除
const ARCHIVE_KEEP = 20;

// 鉴权 token：
//   - 默认 '123456'（默认开启鉴权，客户端必须配同样的 token 才能上传/查询）
//   - 通过环境变量 PLAYERX_TOKEN 可覆盖
//   - 显式设为 '-' 表示关闭鉴权
function resolveToken() {
    const raw = process.env.PLAYERX_TOKEN;
    if (raw === undefined) return '123456';
    const v = raw.trim();
    return v === '-' ? '' : v;
}

// 在每个会读/写这两个目录的入口都先调一下，保证运行期手工删了目录也能自愈。
// 否则 readdirSync 会抛 ENOENT，整个接口就 500/400 给客户端。
function ensureDirs() {
    fs.mkdirSync(UPLOAD_DIR, { recursive: true });
    fs.mkdirSync(ARCHIVE_DIR, { recursive: true });
}

module.exports = {
    ROOT_DIR,
    UPLOAD_DIR,
    ARCHIVE_DIR,
    WEB_DIR,
    MAX_BYTES,
    ARCHIVE_KEEP,
    resolveToken,
    ensureDirs,
};
