/**
 * src/lib/store.js — uploads/archive 目录的读写工具
 *
 * 仅做"目录扫描 + 文件搬移"，不涉及 HTTP；
 * upload/list/merge 接口都会复用 listAll() / findExisting() / archiveExisting()。
 */
const fs   = require('fs');
const path = require('path');

const { UPLOAD_DIR, ARCHIVE_DIR, ARCHIVE_KEEP, ensureDirs } = require('./paths');
const { parseName } = require('./slug');

// 列出 uploads/ 中所有 csv（[{name,user,tag,size,mtime}]，按 mtime 倒序）
function listAll() {
    ensureDirs();
    return fs.readdirSync(UPLOAD_DIR)
        .filter(n => n.toLowerCase().endsWith('.csv'))
        .map(n => {
            const meta = parseName(n) || {};
            const st = fs.statSync(path.join(UPLOAD_DIR, n));
            return {
                name: n,
                user: meta.user || '',
                tag:  meta.tag  || '',
                size: st.size,
                mtime: st.mtime,
            };
        })
        .sort((a, b) => b.mtime - a.mtime);
}

// 同 (user, tag) 已存在的 csv 文件列表（按 mtime 倒序）
function findExisting(user, tag) {
    return listAll().filter(it => it.user === user && it.tag === tag);
}

// 把 (user, tag) 现有文件全部归档到 archive/<user>__<tag>/，并裁剪到 ARCHIVE_KEEP 份
function archiveExisting(user, tag) {
    const slot = path.join(ARCHIVE_DIR, `${user}__${tag || 'default'}`);
    fs.mkdirSync(slot, { recursive: true });
    const moved = [];
    for (const it of findExisting(user, tag)) {
        const dst = path.join(slot, it.name);
        try {
            fs.renameSync(path.join(UPLOAD_DIR, it.name), dst);
            moved.push(it.name);
        } catch (e) {
            console.warn('[archive] rename failed:', e.message);
        }
    }
    // 裁剪：按 mtime 倒序保留最新 N 份，其余删除
    const all = fs.readdirSync(slot)
        .filter(n => n.toLowerCase().endsWith('.csv'))
        .map(n => ({ name: n, mtime: fs.statSync(path.join(slot, n)).mtime }))
        .sort((a, b) => b.mtime - a.mtime);
    for (const old of all.slice(ARCHIVE_KEEP)) {
        try { fs.unlinkSync(path.join(slot, old.name)); }
        catch (e) { console.warn('[archive] prune failed:', e.message); }
    }
    return moved;
}

module.exports = { listAll, findExisting, archiveExisting };
