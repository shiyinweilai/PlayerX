/**
 * src/lib/slug.js — 文件名安全片段 / 时间戳 / 命名解析
 *
 * 文件名规则：`<user>__<tag>__<mode>__<ts>.csv`
 *   双下划线分隔，便于 parseName() 反向解析；
 *   user / tag / mode 中可能出现的非法字符通过 safeSlug() 替成下划线。
 *   mode 是「评分模式」标识，路径中带上它后，同一 (user, tag) 在不同模式下互不冲突。
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

// 解析文件名 → { user, tag, mode, ts }；返回 null 表示不符合命名规则。
//   新格式：<user>__<tag>__<mode>__<ts>.csv （四段）
//   旧格式（无 mode）：<user>__<tag>__<ts>.csv → mode 设为 'aigc'（默认模式）
//   早期格式（无 tag）：<user>_<ts>.csv → tag '' / mode 'aigc'
function parseName(name) {
    if (!name.toLowerCase().endsWith('.csv')) return null;
    const stem = name.slice(0, -4);
    // 新格式：4 段（含 mode）
    //   名字 / tag / mode / ts 都可能含中文，但 mode 是从服务端 slugified 后的小写 ASCII，
    //   这里采取强化符集，避免与旧格式误判。
    const m4 = stem.match(/^(.+?)__(.+?)__([A-Za-z0-9_\-]{2,32})__([0-9T:_\-\.]+)$/);
    if (m4) return { user: m4[1], tag: m4[2], mode: m4[3], ts: m4[4] };
    // 旧格式：3 段
    const m3 = stem.match(/^(.+?)__(.+?)__([0-9T:_\-\.]+)$/);
    if (m3) return { user: m3[1], tag: m3[2], mode: 'aigc', ts: m3[3] };
    // 更早格式：单下划线 + 时间戳
    const m2 = stem.match(/^(.+)_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})$/);
    if (m2) return { user: m2[1], tag: '', mode: 'aigc', ts: m2[2] };
    return { user: stem, tag: '', mode: 'aigc', ts: '' };
}

module.exports = { safeSlug, tsNow, parseName };
