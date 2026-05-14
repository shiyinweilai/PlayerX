/**
 * src/lib/slug.js — 文件名安全片段 / 时间戳 / 命名解析
 *
 * 文件名规则：`<user>__<tag>__<ts>.csv`
 *   双下划线分隔，便于 parseName() 反向解析；
 *   user / tag 中可能出现的非法字符通过 safeSlug() 替成下划线。
 */

// 只允许字母数字、下划线、横线、点、汉字；其他一律换成下划线。
// 兜底：空串 → 用调用方提供的 fallback；长度截到 64。
function safeSlug(raw, fallback) {
    const s = (raw || '').toString()
        .replace(/[^A-Za-z0-9._\-\u4e00-\u9fa5]/g, '_')
        .slice(0, 64);
    return s || fallback;
}

// 服务端时间戳：ISO8601 形式去掉冒号点，便于直接做文件名片段。
function tsNow() {
    return new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19);
}

// 解析文件名 → { user, tag, ts }；返回 null 表示不符合命名规则。
//   兼容旧文件 `<user>_<ts>.csv`（无 tag），tag 视作 ''。
function parseName(name) {
    if (!name.toLowerCase().endsWith('.csv')) return null;
    const stem = name.slice(0, -4);
    // 新格式：双下划线分隔
    const m = stem.match(/^(.+?)__(.+?)__([0-9T:_\-\.]+)$/);
    if (m) return { user: m[1], tag: m[2], ts: m[3] };
    // 旧格式：单下划线 + 时间戳
    const m2 = stem.match(/^(.+)_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})$/);
    if (m2) return { user: m2[1], tag: '', ts: m2[2] };
    return { user: stem, tag: '', ts: '' };
}

module.exports = { safeSlug, tsNow, parseName };
