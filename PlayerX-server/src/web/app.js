/* ============================================================
 * PlayerX-server Web Panel — 前端逻辑
 *
 * 仅依赖原生 fetch + DOM API。功能：
 *   1. 拉 /api/status 显示版本
 *   2. 拉 /api/list 渲染列表 + KPI
 *   3. 文件名/标签/评分人 实时搜索过滤
 *   4. 列头点击切换排序（user/tag/name/size/mtime）
 *   5. 单文件下载 / 合并下载（最新 / 全部）
 *
 * 服务端不做鉴权（局域网部署）；本面板不再提供 Token 设置入口。
 * ============================================================ */

(function () {
    'use strict';

    // ────────── DOM 引用 ──────────
    const $ = (id) => document.getElementById(id);
    const tbody         = $('filesTbody');
    const emptyHint     = $('emptyHint');
    const searchInput   = $('searchInput');
    const refreshBtn    = $('refreshBtn');
    const mergeLatest   = $('mergeLatestBtn');
    const mergeAll      = $('mergeAllBtn');
    const selAll        = $('selAll');
    const selInfo       = $('selInfo');
    const selCount      = $('selCount');
    const archiveSelBtn = $('archiveSelBtn');
    const deleteSelBtn  = $('deleteSelBtn');

    const serverStatus  = $('serverStatus');
    const serverStatusText = $('serverStatusText');
    const appVer        = $('appVer');

    const kpiCount = $('kpiCount');
    const kpiUsers = $('kpiUsers');
    const kpiTags  = $('kpiTags');
    const kpiSize  = $('kpiSize');

    // ────────── 状态 ──────────
    let state = {
        items: [],
        filtered: [],
        sortKey: 'mtime',
        sortDesc: true,
        loading: false,     // /api/list 是否正在请求（刷新按钮防抖）
        selected: new Set(),// 已勾选的文件名
    };

    // ────────── 工具 ──────────
    function fmtSize(n) {
        if (!Number.isFinite(n) || n < 0) return '—';
        if (n < 1024) return n + ' B';
        if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
        return (n / 1024 / 1024).toFixed(2) + ' MB';
    }

    function fmtTime(iso) {
        const d = new Date(iso);
        if (Number.isNaN(d.getTime())) return iso || '—';
        const pad = (x) => String(x).padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }

    function escHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function showToast(msg, kind) {
        const t = $('toast');
        if (!t) return;
        t.textContent = msg;
        t.className = 'toast show ' + (kind || '');
        t.hidden = false;
        clearTimeout(showToast._tm);
        showToast._tm = setTimeout(() => { t.classList.remove('show'); t.hidden = true; }, 2400);
    }

    function setStatus(kind, text) {
        serverStatus.classList.remove('ok', 'warn', 'err');
        if (kind) serverStatus.classList.add(kind);
        serverStatusText.textContent = text;
    }

    // ────────── 网络 ──────────
    async function api(pathname, opts) {
        return fetch(pathname, Object.assign({
            headers: { 'Accept': 'application/json' },
        }, opts || {}));
    }

    async function fetchStatus() {
        try {
            const r = await fetch('/api/status');
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const j = await r.json();
            appVer.textContent = `${j.name} v${j.version}`;
            setStatus('ok', '已连接');
        } catch (e) {
            setStatus('err', '服务异常');
        }
    }

    async function fetchList() {
        if (state.loading) return;
        state.loading = true;
        refreshBtn.disabled = true;
        try {
            const r = await api('/api/list');
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const j = await r.json();
            state.items = Array.isArray(j.items) ? j.items : [];
            applyFilterAndSort();
            renderKpi();
            setStatus('ok', '已连接');
        } catch (e) {
            setStatus('err', '加载失败');
            showToast('加载失败：' + e.message, 'err');
        } finally {
            state.loading = false;
            refreshBtn.disabled = false;
        }
    }

    // ────────── 过滤 / 排序 / 渲染 ──────────
    function applyFilterAndSort() {
        const q = (searchInput.value || '').trim().toLowerCase();
        let arr = state.items.slice();
        if (q) {
            arr = arr.filter(it =>
                (it.user || '').toLowerCase().includes(q) ||
                (it.tag  || '').toLowerCase().includes(q) ||
                (it.name || '').toLowerCase().includes(q));
        }
        const key = state.sortKey;
        const dir = state.sortDesc ? -1 : 1;
        arr.sort((a, b) => {
            let av = a[key], bv = b[key];
            if (key === 'size') { av = +av || 0; bv = +bv || 0; }
            else if (key === 'mtime') { av = new Date(av).getTime(); bv = new Date(bv).getTime(); }
            else { av = String(av || '').toLowerCase(); bv = String(bv || '').toLowerCase(); }
            if (av < bv) return -1 * dir;
            if (av > bv) return  1 * dir;
            return 0;
        });
        state.filtered = arr;
        renderTable();
    }

    function renderTable() {
        const arr = state.filtered;
        if (arr.length === 0) {
            tbody.innerHTML = '';
            emptyHint.hidden = false;
            return;
        }
        emptyHint.hidden = true;
        const html = arr.map(it => {
            const tagHtml = it.tag
                ? `<span class="tag-pill">${escHtml(it.tag)}</span>`
                : `<span class="tag-pill muted">default</span>`;
            const userHtml = it.user
                ? escHtml(it.user)
                : `<span class="tag-pill muted">anon</span>`;
            const checked = state.selected.has(it.name) ? ' checked' : '';
            return `
                <tr${checked ? ' class="sel"' : ''}>
                    <td class="col-check"><input type="checkbox" class="row-chk" data-name="${escHtml(it.name)}"${checked}></td>
                    <td>${userHtml}</td>
                    <td>${tagHtml}</td>
                    <td><span class="fname" title="${escHtml(it.name)}">${escHtml(it.name)}</span></td>
                    <td class="num">${fmtSize(it.size)}</td>
                    <td class="num">${escHtml(fmtTime(it.mtime))}</td>
                    <td class="actions">
                        <button class="row-act" data-act="preview" data-name="${escHtml(it.name)}">查看</button>
                        <button class="row-act" data-act="download" data-name="${escHtml(it.name)}">下载</button>
                        <button class="row-act danger" data-act="delete" data-name="${escHtml(it.name)}">删除</button>
                    </td>
                </tr>`;
        }).join('');
        tbody.innerHTML = html;
        syncSelectionUi();
    }

    function renderKpi() {
        const arr = state.items;
        const users = new Set(arr.map(x => x.user || ''));
        const tags  = new Set(arr.map(x => `${x.user}__${x.tag}`));
        const total = arr.reduce((s, x) => s + (+x.size || 0), 0);
        kpiCount.textContent = arr.length;
        kpiUsers.textContent = users.size;
        kpiTags.textContent  = tags.size;
        kpiSize.textContent  = fmtSize(total);
    }

    // ────────── 下载（POST 形态：把响应直接保存为文件） ──────────
    async function downloadResponse(promiseOrResp, fallbackName) {
        try {
            setStatus('warn', '下载中…');
            const r = await Promise.resolve(promiseOrResp);
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const blob = await r.blob();
            let name = fallbackName || 'download.csv';
            const cd = r.headers.get('Content-Disposition') || '';
            const m = /filename="?([^"]+)"?/i.exec(cd);
            if (m) name = m[1];
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = name;
            document.body.appendChild(a);
            a.click();
            setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 0);
            setStatus('ok', '下载完成');
            showToast(`已下载：${name}`, 'ok');
        } catch (e) {
            setStatus('err', '下载失败');
            showToast('下载失败：' + e.message, 'err');
        }
    }

    // ────────── 下载 ──────────
    async function downloadFile(url, fallbackName) {
        return downloadResponse(api(url), fallbackName);
    }

    // ────────── 删除 ──────────
    async function deleteFile(name, btn) {
        if (!name) return;
        if (!window.confirm(`确定删除这份评分文件吗？\n\n${name}\n\n此操作不可恢复。`)) return;
        if (btn) btn.disabled = true;
        try {
            setStatus('warn', '删除中…');
            const r = await fetch('/api/files/' + encodeURIComponent(name), { method: 'DELETE' });
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            // 如果当前抽屉正在预览该文件，一并关闭
            if (previewName === name) closePreview();
            setStatus('ok', '已删除');
            showToast(`已删除：${name}`, 'ok');
            await fetchList();
        } catch (e) {
            setStatus('err', '删除失败');
            showToast('删除失败：' + e.message, 'err');
            if (btn) btn.disabled = false;
        }
    }

    // ────────── 勾选 / 批量动作 ──────────
    function syncSelectionUi() {
        const n = state.selected.size;
        if (selCount) selCount.textContent = String(n);
        if (selInfo)  selInfo.hidden = (n === 0);
        if (archiveSelBtn) archiveSelBtn.disabled = (n === 0);
        if (deleteSelBtn)  deleteSelBtn.disabled  = (n === 0);
        // 合并下载（选中）：未选中时禁用
        if (mergeLatest) mergeLatest.disabled = (n === 0);

        // 表头全选复选框：与当前 filtered 可见行联动
        if (selAll) {
            const visible = state.filtered;
            if (visible.length === 0) {
                selAll.checked = false;
                selAll.indeterminate = false;
            } else {
                let on = 0;
                for (const it of visible) if (state.selected.has(it.name)) on++;
                selAll.checked       = (on === visible.length);
                selAll.indeterminate = (on > 0 && on < visible.length);
            }
        }
    }

    async function archiveSelected() {
        const names = [...state.selected];
        if (names.length === 0) return;
        const def = (() => {
            const d = new Date();
            const pad = (x) => String(x).padStart(2, '0');
            return `${d.getFullYear()}${pad(d.getMonth()+1)}${pad(d.getDate())}`;
        })();
        const folder = window.prompt(
            `归档选中的 ${names.length} 份文件到哪个文件夹？\n\n仅允许中文 / 字母 / 数字 / . _ - 空格（1~64 位）。`,
            def,
        );
        if (folder == null) return; // 用户取消
        const f = folder.trim();
        if (!/^[A-Za-z0-9._\-\u4e00-\u9fa5 ]{1,64}$/.test(f) || f.startsWith('.')) {
            showToast('归档文件夹名不合法', 'err');
            return;
        }
        archiveSelBtn.disabled = true;
        try {
            setStatus('warn', '归档中…');
            const r = await fetch('/api/archive', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ names, folder: f }),
            });
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            const ok = j.movedCount || 0;
            const fail = j.failedCount || 0;
            // 如果预览抽屉正在预览被归档的文件，关闭
            for (const m of (j.moved || [])) {
                if (previewName === m.name) { closePreview(); break; }
            }
            // 清理本地勾选
            for (const m of (j.moved || [])) state.selected.delete(m.name);
            setStatus('ok', '归档完成');
            showToast(
                `归档到 archive/${j.folder}/：成功 ${ok}${fail ? `，失败 ${fail}` : ''}`,
                fail ? 'warn' : 'ok',
            );
            await fetchList();
            // 若归档抽屉正打开，顺手刷新它，保证刚归档进去的文件立刻可见
            if (typeof archiveDrawer !== 'undefined' && archiveDrawer
                && archiveDrawer.classList.contains('open')) {
                loadArchiveFolders();
            }
        } catch (e) {
            setStatus('err', '归档失败');
            showToast('归档失败：' + e.message, 'err');
        } finally {
            archiveSelBtn.disabled = (state.selected.size === 0);
        }
    }

    async function bulkDeleteSelected() {
        const names = [...state.selected];
        if (names.length === 0) return;
        if (!window.confirm(`确定删除选中的 ${names.length} 份评分文件吗？\n\n此操作不可恢复。`)) return;
        deleteSelBtn.disabled = true;
        try {
            setStatus('warn', '删除中…');
            const r = await fetch('/api/files/bulk-delete', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ names }),
            });
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            const ok = j.deletedCount || 0;
            const fail = j.failedCount || 0;
            for (const n of (j.deleted || [])) {
                if (previewName === n) { closePreview(); break; }
            }
            for (const n of (j.deleted || [])) state.selected.delete(n);
            setStatus('ok', '已删除');
            showToast(
                `已删除 ${ok} 份${fail ? `，失败 ${fail}` : ''}`,
                fail ? 'warn' : 'ok',
            );
            await fetchList();
        } catch (e) {
            setStatus('err', '删除失败');
            showToast('删除失败：' + e.message, 'err');
        } finally {
            deleteSelBtn.disabled = (state.selected.size === 0);
        }
    }

    // ────────── 事件绑定 ──────────
    searchInput.addEventListener('input', applyFilterAndSort);
    refreshBtn.addEventListener('click', () => { fetchList(); });

    // 列头排序
    document.querySelectorAll('thead th.sortable').forEach(th => {
        th.addEventListener('click', () => {
            const k = th.dataset.key;
            if (state.sortKey === k) state.sortDesc = !state.sortDesc;
            else { state.sortKey = k; state.sortDesc = (k === 'mtime' || k === 'size'); }
            document.querySelectorAll('thead th.sortable').forEach(x => {
                x.textContent = x.textContent.replace(/[\u00A0\s]?[⌃⌄]$/, '');
            });
            th.textContent = th.textContent + (state.sortDesc ? ' ⌄' : ' ⌃');
            applyFilterAndSort();
        });
    });

    // 行内按钮（事件委托）：预览 / 下载 / 删除
    tbody.addEventListener('click', (e) => {
        // 勾选复选框
        const chk = e.target.closest('input.row-chk');
        if (chk) {
            const name = chk.dataset.name;
            if (chk.checked) state.selected.add(name);
            else             state.selected.delete(name);
            const tr = chk.closest('tr');
            if (tr) tr.classList.toggle('sel', chk.checked);
            syncSelectionUi();
            return;
        }
        const btn = e.target.closest('button[data-act]');
        if (!btn) return;
        const name = btn.dataset.name;
        if (btn.dataset.act === 'download') {
            downloadFile('/api/files/' + encodeURIComponent(name), name);
        } else if (btn.dataset.act === 'preview') {
            openPreview(name);
        } else if (btn.dataset.act === 'delete') {
            deleteFile(name, btn);
        }
    });

    // 表头全选：全选/取消当前过滤后的可见行
    if (selAll) {
        selAll.addEventListener('click', () => {
            const on = selAll.checked;
            for (const it of state.filtered) {
                if (on) state.selected.add(it.name);
                else    state.selected.delete(it.name);
            }
            // 重新渲染以同步行内 checkbox 状态
            renderTable();
        });
    }

    if (archiveSelBtn) archiveSelBtn.addEventListener('click', archiveSelected);
    if (deleteSelBtn)  deleteSelBtn.addEventListener('click', bulkDeleteSelected);

    // ────────── CSV 预览（右侧抽屉） ──────────
    const previewMask     = $('previewMask');     // 这里复用原有 id，实际是抽屉本体
    const previewTitle    = $('previewTitle');
    const previewMeta     = $('previewMeta');
    const previewBody     = $('previewBody');
    const previewClose    = $('previewClose');
    const previewDownload = $('previewDownload');
    let previewName = '';
    let previewDownloadUrl = '';

    function closePreview() {
        previewMask.classList.remove('open');
        // 动画结束后隐藏，避免遮住右侧表格交互
        setTimeout(() => {
            if (!previewMask.classList.contains('open')) {
                previewMask.hidden = true;
                previewBody.innerHTML = '';
                previewMeta.textContent = '';
                previewName = '';
            }
        }, 220);
    }

    // opts 可选：{ url, downloadUrl, title }
    //   - url:         预览数据的 GET 接口（默认 /api/preview/<name>）
    //   - downloadUrl: 抽屉里“下载”按钮要打开的 URL（默认 /api/files/<name>）
    //   - title:       自定义抽屉标题，默认就是 name
    async function openPreview(name, opts) {
        opts = opts || {};
        previewName = name;
        previewDownloadUrl = opts.downloadUrl || ('/api/files/' + encodeURIComponent(name));
        previewMask.hidden = false;
        // 下一帧再加 open 才会触发 transition
        requestAnimationFrame(() => previewMask.classList.add('open'));
        previewTitle.textContent = opts.title || name;
        previewMeta.textContent = '';
        previewBody.innerHTML = '<div class="preview-loading">加载中…</div>';
        try {
            const url = opts.url || ('/api/preview/' + encodeURIComponent(name));
            const r = await api(url);
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const j = await r.json();
            if (!j.ok) throw new Error(j.error || '预览失败');
            renderPreview(j);
        } catch (e) {
            previewBody.innerHTML =
                '<div class="preview-error">预览失败：' + escHtml(e.message) + '</div>';
        }
    }

    function renderPreview(j) {
        const header = Array.isArray(j.header) ? j.header : [];
        const rows   = Array.isArray(j.rows)   ? j.rows   : [];

        // 顶部 meta：行数 / 大小 / 时间 / 截断提示
        const metaParts = [];
        metaParts.push('共 ' + j.total + ' 行');
        if (j.truncated) metaParts.push('已展示前 ' + j.shown + ' 行');
        if (j.size != null) metaParts.push(fmtSize(j.size));
        if (j.mtime) metaParts.push(fmtTime(j.mtime));
        previewMeta.textContent = metaParts.join('  ·  ');

        if (header.length === 0) {
            previewBody.innerHTML = '<div class="preview-loading">文件为空</div>';
            return;
        }

        // 哪些列右对齐 / 用等宽数字：stars 列 + 任何全是数字的列
        const numCols = new Set();
        header.forEach((h, idx) => {
            const lc = String(h || '').toLowerCase();
            if (lc === 'stars' || lc === 'size' || lc === 'file_size') {
                numCols.add(idx);
            }
        });

        const thHtml = header.map((h, i) => {
            const cls = numCols.has(i) ? ' class="num"' : '';
            return '<th' + cls + '>' + escHtml(h) + '</th>';
        }).join('');

        const trHtml = rows.map(r => {
            const tds = header.map((_, i) => {
                const v = r[i] == null ? '' : String(r[i]);
                if (numCols.has(i)) {
                    // stars 用色块直观显示
                    if (header[i] && header[i].toLowerCase() === 'stars') {
                        const n = parseInt(v, 10);
                        const lbl = Number.isFinite(n) ? renderStars(n) : escHtml(v);
                        return '<td class="num stars-cell">' + lbl + '</td>';
                    }
                    return '<td class="num">' + escHtml(v) + '</td>';
                }
                return '<td>' + escHtml(v) + '</td>';
            }).join('');
            return '<tr>' + tds + '</tr>';
        }).join('');

        previewBody.innerHTML =
            '<div class="preview-table-wrap">' +
              '<table class="preview-table">' +
                '<thead><tr>' + thHtml + '</tr></thead>' +
                '<tbody>' + trHtml + '</tbody>' +
              '</table>' +
            '</div>';
    }

    function renderStars(n) {
        if (n < 0) n = 0; if (n > 5) n = 5;
        const filled = '★'.repeat(n);
        const empty  = '☆'.repeat(5 - n);
        return '<span class="stars" title="' + n + ' / 5">' +
               '<span class="stars-filled">' + filled + '</span>' +
               '<span class="stars-empty">'  + empty  + '</span>' +
               '</span>';
    }

    previewClose.addEventListener('click', closePreview);
    previewDownload.addEventListener('click', () => {
        if (!previewName) return;
        downloadFile(previewDownloadUrl || ('/api/files/' + encodeURIComponent(previewName)), previewName);
    });
    document.addEventListener('keydown', (e) => {
        if (previewMask.classList.contains('open') && e.key === 'Escape') closePreview();
    });

    // 合并下载
    mergeLatest.addEventListener('click', () => {
        const names = [...state.selected];
        if (names.length === 0) {
            showToast('请先勾选要合并的文件', 'warn');
            return;
        }
        downloadResponse(
            fetch('/api/merge', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ names }),
            }),
            'playerx_selected.csv',
        );
    });
    mergeAll.addEventListener('click',    () => downloadFile('/api/merge?all=1', 'playerx_all.csv'));

    // ────────── 归档库抽屉 ──────────
    const archiveDrawer        = $('archiveDrawer');
    const archiveCloseBtn      = $('archiveClose');
    const archiveRefreshBtn    = $('archiveRefresh');
    const openArchiveBtn       = $('openArchiveBtn');
    const archiveMeta          = $('archiveMeta');
    const archiveFolderListEl  = $('archiveFolderList');
    const archiveFoldersEmpty  = $('archiveFoldersEmpty');
    const archiveFilesHint     = $('archiveFilesHint');
    const archiveFilesWrap     = $('archiveFilesWrap');
    const archiveFilesTbody    = $('archiveFilesTbody');
    const archiveFilesToolbar  = $('archiveFilesToolbar');
    const archiveSelAll        = $('archiveSelAll');
    const archiveSelInfo       = $('archiveSelInfo');
    const archiveSelCount      = $('archiveSelCount');
    const archiveDelSelBtn     = $('archiveDelSelBtn');
    const archiveDelFolderBtn  = $('archiveDelFolderBtn');
    const archiveDownloadSelBtn= $('archiveDownloadSelBtn');
    const archiveMergeBtn      = $('archiveMergeBtn');

    const archive = {
        folders: [],     // [{name,count,size,mtime}]
        currentFolder: '',
        files: [],       // [{name,size,mtime}]
        selected: new Set(),
    };

    function openArchiveDrawer() {
        archiveDrawer.hidden = false;
        requestAnimationFrame(() => archiveDrawer.classList.add('open'));
        loadArchiveFolders();
    }
    function closeArchiveDrawer() {
        archiveDrawer.classList.remove('open');
        setTimeout(() => {
            if (!archiveDrawer.classList.contains('open')) {
                archiveDrawer.hidden = true;
            }
        }, 220);
    }

    async function loadArchiveFolders() {
        try {
            const r = await api('/api/archive/folders');
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const j = await r.json();
            if (!j.ok) throw new Error(j.error || '加载失败');
            archive.folders = Array.isArray(j.folders) ? j.folders : [];
            renderArchiveFolders();
            // 当前选中的文件夹仍然存在则刷新其内容；否则默认选中第一个，避免右侧一片空白
            if (archive.currentFolder && archive.folders.find(f => f.name === archive.currentFolder)) {
                await loadArchiveFiles(archive.currentFolder);
            } else if (archive.folders.length > 0) {
                await loadArchiveFiles(archive.folders[0].name);
            } else {
                archive.currentFolder = '';
                archive.files = [];
                archive.selected.clear();
                renderArchiveFiles();
            }
        } catch (e) {
            showToast('归档加载失败：' + e.message, 'err');
        }
    }

    function renderArchiveFolders() {
        const list = archive.folders;
        archiveFoldersEmpty.hidden = (list.length > 0);
        const totalFolders = list.length;
        const totalFiles = list.reduce((s, x) => s + (+x.count || 0), 0);
        const totalSize  = list.reduce((s, x) => s + (+x.size  || 0), 0);
        archiveMeta.textContent = `${totalFolders} 个文件夹  ·  ${totalFiles} 份 csv  ·  ${fmtSize(totalSize)}`;

        archiveFolderListEl.innerHTML = list.map(f => {
            const active = (f.name === archive.currentFolder) ? ' active' : '';
            const sub = `${f.count} 份  ·  ${fmtSize(f.size)}` + (f.mtime ? `  ·  ${fmtTime(f.mtime)}` : '');
            return `<li class="archive-folder${active}" data-folder="${escHtml(f.name)}">
                <span class="folder-icon">📁</span>
                <span class="folder-meta">
                    <span class="folder-name">${escHtml(f.name)}</span>
                    <span class="folder-sub">${escHtml(sub)}</span>
                </span>
            </li>`;
        }).join('');
    }

    async function loadArchiveFiles(folder) {
        const switching = (archive.currentFolder !== folder);
        archive.currentFolder = folder;
        archive.selected.clear();
        renderArchiveFolders(); // 高亮
        // 切换文件夹时不再显示"加载中…"占位：保留旧表格，加载完成后一次性刷新
        if (switching) {
            archiveFilesHint.hidden = true;
        }
        try {
            const r = await api('/api/archive/list?folder=' + encodeURIComponent(folder));
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const j = await r.json();
            if (!j.ok) throw new Error(j.error || '加载失败');
            archive.files = Array.isArray(j.items) ? j.items : [];
            renderArchiveFiles();
        } catch (e) {
            archiveFilesHint.textContent = '加载失败：' + e.message;
            archiveFilesHint.hidden = false;
            archiveFilesWrap.hidden = true;
        }
    }

    function renderArchiveFiles() {
        if (!archive.currentFolder) {
            archiveFilesHint.textContent = '从左侧选择一个归档文件夹查看内容。';
            archiveFilesHint.hidden = false;
            archiveFilesWrap.hidden = true;
            archiveFilesToolbar.hidden = true;
            return;
        }
        if (archive.files.length === 0) {
            archiveFilesHint.textContent = '此文件夹为空。';
            archiveFilesHint.hidden = false;
            archiveFilesWrap.hidden = true;
            archiveFilesToolbar.hidden = false;
            syncArchiveSelUi();
            return;
        }
        archiveFilesHint.hidden = true;
        archiveFilesWrap.hidden = false;
        archiveFilesToolbar.hidden = false;

        const folder = archive.currentFolder;
        archiveFilesTbody.innerHTML = archive.files.map(it => {
            const checked = archive.selected.has(it.name) ? ' checked' : '';
            return `<tr${checked ? ' class="sel"' : ''}>
                <td class="col-check"><input type="checkbox" class="arch-row-chk" data-name="${escHtml(it.name)}"${checked}></td>
                <td class="col-fname"><span class="fname" title="${escHtml(it.name)}">${escHtml(it.name)}</span></td>
                <td class="num col-size">${fmtSize(it.size)}</td>
                <td class="num col-mtime">${escHtml(fmtTime(it.mtime))}</td>
                <td class="actions col-actions">
                    <button class="row-act" data-act="preview"  data-name="${escHtml(it.name)}">查看</button>
                    <button class="row-act" data-act="download" data-name="${escHtml(it.name)}">下载</button>
                </td>
            </tr>`;
        }).join('');
        syncArchiveSelUi();
    }

    function syncArchiveSelUi() {
        const n = archive.selected.size;
        archiveSelCount.textContent = String(n);
        archiveSelInfo.hidden = (n === 0);
        archiveDelSelBtn.disabled = (n === 0);
        if (archiveDownloadSelBtn) archiveDownloadSelBtn.disabled = (n === 0);
        if (archiveMergeBtn) {
            // 合并下载：选中时合并所选；未选中时合并整个文件夹（只要文件夹有文件就可用）
            archiveMergeBtn.disabled = (archive.files.length === 0);
            archiveMergeBtn.textContent = (n > 0)
                ? `⬇ 合并下载选中（${n}）`
                : '⬇ 合并下载（全部）';
        }
        if (archiveSelAll) {
            const visible = archive.files;
            if (visible.length === 0) {
                archiveSelAll.checked = false;
                archiveSelAll.indeterminate = false;
            } else {
                let on = 0;
                for (const it of visible) if (archive.selected.has(it.name)) on++;
                archiveSelAll.checked       = (on === visible.length);
                archiveSelAll.indeterminate = (on > 0 && on < visible.length);
            }
        }
    }

    // 文件夹列表点击：切换当前文件夹
    archiveFolderListEl.addEventListener('click', (e) => {
        const li = e.target.closest('li.archive-folder');
        if (!li) return;
        const folder = li.dataset.folder;
        if (folder && folder !== archive.currentFolder) loadArchiveFiles(folder);
    });

    // 右侧文件行：勾选 + 行内操作
    archiveFilesTbody.addEventListener('click', (e) => {
        const chk = e.target.closest('input.arch-row-chk');
        if (chk) {
            const name = chk.dataset.name;
            if (chk.checked) archive.selected.add(name);
            else             archive.selected.delete(name);
            const tr = chk.closest('tr');
            if (tr) tr.classList.toggle('sel', chk.checked);
            syncArchiveSelUi();
            return;
        }
        const btn = e.target.closest('button[data-act]');
        if (!btn) return;
        const name = btn.dataset.name;
        const folder = archive.currentFolder;
        if (!folder || !name) return;
        if (btn.dataset.act === 'download') {
            downloadFile(`/api/archive/file/${encodeURIComponent(folder)}/${encodeURIComponent(name)}`, name);
        } else if (btn.dataset.act === 'preview') {
            openPreview(name, {
                url:         `/api/archive/preview/${encodeURIComponent(folder)}/${encodeURIComponent(name)}`,
                downloadUrl: `/api/archive/file/${encodeURIComponent(folder)}/${encodeURIComponent(name)}`,
                title:       `[${folder}] ${name}`,
            });
        } else if (btn.dataset.act === 'delete') {
            deleteArchivedFile(name, btn);
        }
    });

    archiveSelAll.addEventListener('click', () => {
        const on = archiveSelAll.checked;
        for (const it of archive.files) {
            if (on) archive.selected.add(it.name);
            else    archive.selected.delete(it.name);
        }
        renderArchiveFiles();
    });

    async function deleteArchivedFile(name, btn) {
        const folder = archive.currentFolder;
        if (!folder || !name) return;
        if (!window.confirm(`确定从归档「${folder}」中删除该文件？\n\n${name}\n\n此操作不可恢复。`)) return;
        if (btn) btn.disabled = true;
        try {
            const r = await fetch(
                `/api/archive/file/${encodeURIComponent(folder)}/${encodeURIComponent(name)}`,
                { method: 'DELETE' },
            );
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            archive.selected.delete(name);
            showToast(`已删除：${name}`, 'ok');
            // 关闭可能正在预览此文件的抽屉
            if (previewName === name) closePreview();
            await loadArchiveFolders();
        } catch (e) {
            showToast('删除失败：' + e.message, 'err');
            if (btn) btn.disabled = false;
        }
    }

    archiveDelSelBtn.addEventListener('click', async () => {
        const folder = archive.currentFolder;
        const names = [...archive.selected];
        if (!folder || names.length === 0) return;
        if (!window.confirm(`确定从归档「${folder}」中删除选中的 ${names.length} 份文件？\n\n此操作不可恢复。`)) return;
        archiveDelSelBtn.disabled = true;
        try {
            const r = await fetch('/api/archive/bulk-delete', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ folder, names }),
            });
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            const ok = j.deletedCount || 0, fail = j.failedCount || 0;
            for (const n of (j.deleted || [])) {
                archive.selected.delete(n);
                if (previewName === n) closePreview();
            }
            showToast(`已删除 ${ok} 份${fail ? `，失败 ${fail}` : ''}`, fail ? 'warn' : 'ok');
            await loadArchiveFolders();
        } catch (e) {
            showToast('删除失败：' + e.message, 'err');
        } finally {
            archiveDelSelBtn.disabled = (archive.selected.size === 0);
        }
    });

    archiveDelFolderBtn.addEventListener('click', async () => {
        const folder = archive.currentFolder;
        if (!folder) return;
        if (!window.confirm(`确定删除整个归档文件夹「${folder}」？\n\n该文件夹下的所有 csv 都会被删除，此操作不可恢复。`)) return;
        archiveDelFolderBtn.disabled = true;
        try {
            const r = await fetch('/api/archive/folder/' + encodeURIComponent(folder), { method: 'DELETE' });
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            showToast(`已删除文件夹：${folder}（${j.deletedCount || 0} 份）`, 'ok');
            // 当前预览中若来自该文件夹则关掉
            closePreview();
            archive.currentFolder = '';
            archive.files = [];
            archive.selected.clear();
            await loadArchiveFolders();
        } catch (e) {
            showToast('删除文件夹失败：' + e.message, 'err');
        } finally {
            archiveDelFolderBtn.disabled = false;
        }
    });

    openArchiveBtn.addEventListener('click', openArchiveDrawer);
    archiveCloseBtn.addEventListener('click', closeArchiveDrawer);
    archiveRefreshBtn.addEventListener('click', () => loadArchiveFolders());

    // 下载选中：浏览器无原生 zip，按顺序逐个触发下载
    if (archiveDownloadSelBtn) {
        archiveDownloadSelBtn.addEventListener('click', async () => {
            const folder = archive.currentFolder;
            const names = [...archive.selected];
            if (!folder || names.length === 0) return;
            archiveDownloadSelBtn.disabled = true;
            try {
                for (const n of names) {
                    await downloadFile(
                        `/api/archive/file/${encodeURIComponent(folder)}/${encodeURIComponent(n)}`,
                        n,
                    );
                    // 给浏览器一点时间处理多文件下载
                    await new Promise((r) => setTimeout(r, 120));
                }
            } finally {
                archiveDownloadSelBtn.disabled = (archive.selected.size === 0);
            }
        });
    }

    // 合并下载：未选中=合并整个文件夹；选中=仅合并所选
    if (archiveMergeBtn) {
        archiveMergeBtn.addEventListener('click', () => {
            const folder = archive.currentFolder;
            if (!folder) return;
            const names = [...archive.selected];
            if (names.length > 0) {
                downloadResponse(
                    fetch('/api/archive/merge/' + encodeURIComponent(folder), {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ names }),
                    }),
                    `archive_${folder}_selected.csv`,
                );
            } else {
                downloadFile(
                    '/api/archive/merge/' + encodeURIComponent(folder),
                    `archive_${folder}.csv`,
                );
            }
        });
    }

    // ────────── 启动 ──────────
    (async function init() {
        await fetchStatus();
        await fetchList();
    })();
})();
