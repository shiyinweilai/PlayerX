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
            return `
                <tr>
                    <td>${userHtml}</td>
                    <td>${tagHtml}</td>
                    <td><span class="fname" title="${escHtml(it.name)}">${escHtml(it.name)}</span></td>
                    <td class="num">${fmtSize(it.size)}</td>
                    <td class="num">${escHtml(fmtTime(it.mtime))}</td>
                    <td class="actions">
                        <button class="row-act" data-act="download" data-name="${escHtml(it.name)}">下载</button>
                    </td>
                </tr>`;
        }).join('');
        tbody.innerHTML = html;
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

    // ────────── 下载 ──────────
    async function downloadFile(url, fallbackName) {
        try {
            setStatus('warn', '下载中…');
            const r = await api(url);
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

    // 行内下载按钮（事件委托）
    tbody.addEventListener('click', (e) => {
        const btn = e.target.closest('button[data-act]');
        if (!btn) return;
        if (btn.dataset.act === 'download') {
            const name = btn.dataset.name;
            downloadFile('/api/files/' + encodeURIComponent(name), name);
        }
    });

    // 合并下载
    mergeLatest.addEventListener('click', () => downloadFile('/api/merge', 'playerx_latest.csv'));
    mergeAll.addEventListener('click',    () => downloadFile('/api/merge?all=1', 'playerx_all.csv'));

    // ────────── 启动 ──────────
    (async function init() {
        await fetchStatus();
        await fetchList();
    })();
})();
