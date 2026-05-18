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

    // 管理员登录相关
    const adminLoginBtn = $('adminLoginBtn');
    const loginMask     = $('loginMask');
    const loginInput    = $('loginInput');
    const loginErr      = $('loginErr');
    const loginOkBtn    = $('loginOkBtn');
    const loginCancelBtn= $('loginCancelBtn');

    // 上传 Token 设置弹窗
    const tokenSettingsBtn = $('tokenSettingsBtn');
    const tokenMask        = $('tokenMask');
    const tokenInput       = $('tokenInput');
    const tokenErr         = $('tokenErr');
    const tokenSaveBtn     = $('tokenSaveBtn');
    const tokenCancelBtn   = $('tokenCancelBtn');

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
        mode: '',           // 当前选中的模式 Tab（'' = 全部）
        modes: {},          // 后端返回的各模式计数，用于 Tab 徽章
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

    // ────────── 管理员登录 / 鉴权 ──────────
    const auth = {
        token: localStorage.getItem('px_admin_token') || '',
        enabled: true, // 默认假设启用，启动时再请求确认
    };
    const isLoggedIn = () => !!auth.token;

    // 给写操作专用：自动带上 X-Admin-Token，拿到 401 时清掉本地 token 并提示
    async function adminFetch(pathname, opts) {
        opts = opts || {};
        const headers = Object.assign({}, opts.headers || {});
        if (auth.token) headers['X-Admin-Token'] = auth.token;
        const r = await fetch(pathname, Object.assign({}, opts, { headers }));
        if (r.status === 401) {
            // 服务端拒绝：清掉本地 token，弹登录
            auth.token = '';
            localStorage.removeItem('px_admin_token');
            updateAuthUi();
            showToast('该操作需要管理员登录', 'err');
            openLoginDialog();
        }
        return r;
    }

    // 同步管理类按钮（删除 / 归档 / 批量）的可用性 + 视觉锁定态
    function updateAuthUi() {
        const logged = isLoggedIn();
        // 顶栏按钮
        if (adminLoginBtn) {
            if (!auth.enabled) {
                adminLoginBtn.hidden = true; // 服务端关闭了鉴权，不显示按钮
            } else {
                adminLoginBtn.hidden = false;
                if (logged) {
                    adminLoginBtn.textContent = '👤 已登录（点击退出）';
                    adminLoginBtn.classList.add('is-logged');
                    adminLoginBtn.title = '点击退出管理员登录';
                } else {
                    adminLoginBtn.textContent = '🔒 用户登录';
                    adminLoginBtn.classList.remove('is-logged');
                    adminLoginBtn.title = '登录后才能执行删除 / 归档等管理操作';
                }
            }
        }
        // “上传 Token ”按钮仅在管理员登录后可见
        if (tokenSettingsBtn) {
            tokenSettingsBtn.hidden = !(auth.enabled && logged);
        }
        // 主列表的批量按钮：未登录时统一锁死并提示
        const lockTip = '需要管理员登录后才能操作';
        const setLock = (btn, locked) => {
            if (!btn) return;
            if (locked) {
                btn.classList.add('lock-disabled');
                btn.dataset.lockTip = lockTip;
                btn.title = lockTip;
            } else {
                btn.classList.remove('lock-disabled');
                delete btn.dataset.lockTip;
                btn.title = '';
            }
        };
        if (auth.enabled && !logged) {
            setLock(archiveSelBtn, true);
            setLock(deleteSelBtn, true);
        } else {
            setLock(archiveSelBtn, false);
            setLock(deleteSelBtn, false);
        }
        // 行内 "删除" 按钮：通过 class 标记，由 syncSelectionUi/render 后再统一处理
        document.querySelectorAll('button.row-act.danger[data-act="delete"]').forEach(b => {
            if (auth.enabled && !logged) {
                b.classList.add('lock-disabled');
                b.title = lockTip;
            } else {
                b.classList.remove('lock-disabled');
                b.title = '';
            }
        });
        // 归档抽屉的删除/批删按钮
        const archDelSel    = document.getElementById('archiveDelSelBtn');
        const archDelFolder = document.getElementById('archiveDelFolderBtn');
        if (auth.enabled && !logged) {
            setLock(archDelSel, true);
            setLock(archDelFolder, true);
        } else {
            setLock(archDelSel, false);
            setLock(archDelFolder, false);
        }
    }

    function openLoginDialog() {
        if (!loginMask) return;
        loginErr.hidden = true;
        loginErr.textContent = '';
        loginInput.value = '';
        loginMask.hidden = false;
        setTimeout(() => loginInput.focus(), 50);
    }
    function closeLoginDialog() {
        if (!loginMask) return;
        loginMask.hidden = true;
    }
    async function doAdminLogin() {
        const pwd = loginInput.value || '';
        if (!pwd.trim()) { loginErr.textContent = '请输入密码'; loginErr.hidden = false; return; }
        loginOkBtn.disabled = true;
        try {
            const r = await fetch('/api/admin/login', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ password: pwd }),
            });
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) {
                loginErr.textContent = j.error || '登录失败';
                loginErr.hidden = false;
                loginInput.select();
                return;
            }
            auth.token = j.token || '';
            if (auth.token) localStorage.setItem('px_admin_token', auth.token);
            closeLoginDialog();
            updateAuthUi();
            showToast('登录成功，可以执行管理操作了', 'ok');
        } catch (e) {
            loginErr.textContent = '网络错误：' + e.message;
            loginErr.hidden = false;
        } finally {
            loginOkBtn.disabled = false;
        }
    }
    async function doAdminLogout() {
        const tk = auth.token;
        auth.token = '';
        localStorage.removeItem('px_admin_token');
        updateAuthUi();
        try {
            await fetch('/api/admin/logout', {
                method: 'POST',
                headers: tk ? { 'X-Admin-Token': tk } : {},
            });
        } catch (_) { /* 忽略 */ }
        showToast('已退出登录', 'ok');
    }
    async function fetchAuthInfo() {
        try {
            const r = await fetch('/api/admin/auth-info');
            const j = await r.json();
            auth.enabled = !!j.authEnabled;
        } catch (_) {
            auth.enabled = true;
        }
        updateAuthUi();
    }

    if (adminLoginBtn) {
        adminLoginBtn.addEventListener('click', () => {
            if (isLoggedIn()) doAdminLogout();
            else              openLoginDialog();
        });
    }
    if (loginCancelBtn) loginCancelBtn.addEventListener('click', closeLoginDialog);
    if (loginOkBtn)     loginOkBtn.addEventListener('click', doAdminLogin);
    if (loginInput) loginInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') doAdminLogin();
        if (e.key === 'Escape') closeLoginDialog();
    });
    if (loginMask) loginMask.addEventListener('click', (e) => {
        if (e.target === loginMask) closeLoginDialog(); // 点遮罩关闭
    });

    // ────────── 上传 Token 设置弹窗 ──────────
    function openTokenDialog() {
        if (!tokenMask) return;
        tokenErr.hidden = true;
        tokenErr.textContent = '';
        tokenInput.value = '';
        tokenInput.placeholder = '加载中…';
        tokenMask.hidden = false;
        // 拉当前 token
        adminFetch('/api/settings/upload-token').then(async (r) => {
            if (r.status === 401) { tokenMask.hidden = true; return; }
            const j = await r.json().catch(() => ({}));
            if (r.ok && j.ok) {
                tokenInput.value = j.token || '';
                tokenInput.placeholder = '如：123456';
                setTimeout(() => { tokenInput.focus(); tokenInput.select(); }, 30);
            } else {
                tokenErr.textContent = j.error || '读取 Token 失败';
                tokenErr.hidden = false;
            }
        }).catch((e) => {
            tokenErr.textContent = '网络错误：' + e.message;
            tokenErr.hidden = false;
        });
    }
    function closeTokenDialog() {
        if (tokenMask) tokenMask.hidden = true;
    }
    async function saveUploadToken() {
        const v = (tokenInput.value || '').trim();
        // 留空 = 关闭鉴权，二次确认
        if (!v && !confirm('Token 留空将关闭上传鉴权（任何人都能上传），确定继续？')) {
            return;
        }
        tokenSaveBtn.disabled = true;
        try {
            const r = await adminFetch('/api/settings/upload-token', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ token: v }),
            });
            if (r.status === 401) return;
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) {
                tokenErr.textContent = j.error || '保存失败';
                tokenErr.hidden = false;
                return;
            }
            closeTokenDialog();
            showToast(v ? `上传 Token 已更新为 ${v}` : '上传鉴权已关闭', 'ok');
        } catch (e) {
            tokenErr.textContent = '网络错误：' + e.message;
            tokenErr.hidden = false;
        } finally {
            tokenSaveBtn.disabled = false;
        }
    }
    if (tokenSettingsBtn) tokenSettingsBtn.addEventListener('click', openTokenDialog);
    if (tokenCancelBtn)   tokenCancelBtn.addEventListener('click', closeTokenDialog);
    if (tokenSaveBtn)     tokenSaveBtn.addEventListener('click', saveUploadToken);
    if (tokenInput) tokenInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') saveUploadToken();
        if (e.key === 'Escape') closeTokenDialog();
    });
    if (tokenMask) tokenMask.addEventListener('click', (e) => {
        if (e.target === tokenMask) closeTokenDialog();
    });

    // 用拦截器在写操作前提示登录：未登录时点击锁定按钮就直接弹登录窗
    function guardWrite(actionFn, btn) {
        if (auth.enabled && !isLoggedIn()) {
            showToast('该操作需要管理员登录', 'warn');
            openLoginDialog();
            return false;
        }
        return true;
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
            // 带上当前 Tab 的 mode；空串 = 全部。
            // 后端同时返回 modes 汇总，包含全部模式的计数，以保证 Tab 徽章始终是全量实际值。
            const url = state.mode
                ? '/api/list?mode=' + encodeURIComponent(state.mode)
                : '/api/list';
            const r = await api(url);
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const j = await r.json();
            state.items = Array.isArray(j.items) ? j.items : [];
            state.modes = (j.modes && typeof j.modes === 'object') ? j.modes : {};
            // 切换 Tab 后，不在当前模式下的勾选项丢弃，避免“隐形勾选”脱同。
            const visible = new Set(state.items.map(it => it.name));
            for (const n of [...state.selected]) {
                if (!visible.has(n)) state.selected.delete(n);
            }
            applyFilterAndSort();
            renderKpi();
            renderModeTabs();
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
            const modeHtml = renderModePill(it.mode);
            const checked = state.selected.has(it.name) ? ' checked' : '';
            return `
                <tr${checked ? ' class="sel"' : ''}>
                    <td class="col-check"><input type="checkbox" class="row-chk" data-name="${escHtml(it.name)}"${checked}></td>
                    <td>${userHtml}</td>
                    <td>${tagHtml}</td>
                    <td>${modeHtml}</td>
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

    // 模式胶囊：不同模式走不同颜色，走不同 CSS 变量。
    function renderModePill(mode) {
        const m = (mode || 'subjective').toLowerCase();
        // 显示文案：subjective → 主观评分；quality → 质量比较
        const labelMap = { subjective: '主观评分', quality: '质量比较', off: '关闭' };
        const label = labelMap[m] || m;
        return `<span class="mode-pill mode-${escHtml(m)}" title="评分模式：${escHtml(label)}">${escHtml(label)}</span>`;
    }

    // 根据 modes 汇总刷新顶部 Tab 徽章。
    function renderModeTabs() {
        const tabs = document.querySelectorAll('#modeTabs .mode-tab');
        if (!tabs.length) return;
        const counts = state.modes || {};
        let total = 0;
        for (const k in counts) total += (+counts[k] || 0);
        tabs.forEach(t => {
            const m = t.dataset.mode || '';
            const span = t.querySelector('.mode-tab-count');
            if (span) {
                const v = m === '' ? total : (+counts[m] || 0);
                span.textContent = v;
            }
            const active = (m === state.mode);
            t.classList.toggle('is-active', active);
            t.setAttribute('aria-selected', active ? 'true' : 'false');
        });
    }

    function renderKpi() {
        const arr = state.items;
        const users = new Set(arr.map(x => x.user || ''));
        // (user, tag, mode) 三元组才是一个独立的评分组，不同模式不能被合并计。
        const tags  = new Set(arr.map(x => `${x.user}__${x.tag}__${x.mode || 'subjective'}`));
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
            const r = await adminFetch('/api/files/' + encodeURIComponent(name), { method: 'DELETE' });
            if (r.status === 401) { if (btn) btn.disabled = false; return; }
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

        // 鉴权联动：按钮 disabled 状态刷新后，同步未登录的锁定提示
        if (typeof updateAuthUi === 'function') updateAuthUi();
    }

    async function archiveSelected() {
        const names = [...state.selected];
        if (names.length === 0) return;
        if (!guardWrite()) return;
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
            const r = await adminFetch('/api/archive', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ names, folder: f }),
            });
            if (r.status === 401) { archiveSelBtn.disabled = (state.selected.size === 0); return; }
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
        if (!guardWrite()) return;
        if (!window.confirm(`确定删除选中的 ${names.length} 份评分文件吗？\n\n此操作不可恢复。`)) return;
        deleteSelBtn.disabled = true;
        try {
            setStatus('warn', '删除中…');
            const r = await adminFetch('/api/files/bulk-delete', {
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
            if (!guardWrite()) return;
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
                    // stars 用色块直观显示；上限从同一行的 mode 列（若有）推断
                    if (header[i] && header[i].toLowerCase() === 'stars') {
                        const n = parseInt(v, 10);
                        const max = inferMaxStars(header, r);
                        const lbl = Number.isFinite(n) ? renderStars(n, max) : escHtml(v);
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

    function renderStars(n, max) {
        const cap = Number.isFinite(max) && max > 0 ? max : 5;
        if (n < 0) n = 0; if (n > cap) n = cap;
        const filled = '★'.repeat(n);
        const empty  = '☆'.repeat(cap - n);
        return '<span class="stars" title="' + n + ' / ' + cap + '">' +
               '<span class="stars-filled">' + filled + '</span>' +
               '<span class="stars-empty">'  + empty  + '</span>' +
               '</span>';
    }

    // 从预览表格中推断当前行的最大星级：
    //   - 优先看同行 mode 列（后端 ／merge 输出都会携带）
        //   - 取不到则回退为 5（主观评分默认）
    function inferMaxStars(header, row) {
        const idx = header.findIndex(h => String(h || '').toLowerCase() === 'mode');
        if (idx >= 0) {
            const m = String((row && row[idx]) || '').trim().toLowerCase();
            if (m === 'quality')    return 2;
            if (m === 'subjective') return 5;
        }
        return 5;
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
    // 合并全部：跟随当前 Tab 限定 mode，避免两个模式被一起合出。
    mergeAll.addEventListener('click',    () => {
        const params = new URLSearchParams({ all: '1' });
        if (state.mode) params.set('mode', state.mode);
        const fileTag = state.mode ? `_${state.mode}` : '';
        downloadFile('/api/merge?' + params.toString(), `playerx_all${fileTag}.csv`);
    });

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
        if (typeof updateAuthUi === 'function') updateAuthUi();
    }
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
        if (!guardWrite()) return;
        if (!window.confirm(`确定从归档「${folder}」中删除该文件？\n\n${name}\n\n此操作不可恢复。`)) return;
        if (btn) btn.disabled = true;
        try {
            const r = await adminFetch(
                `/api/archive/file/${encodeURIComponent(folder)}/${encodeURIComponent(name)}`,
                { method: 'DELETE' },
            );
            if (r.status === 401) { if (btn) btn.disabled = false; return; }
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
        if (!guardWrite()) return;
        if (!window.confirm(`确定从归档「${folder}」中删除选中的 ${names.length} 份文件？\n\n此操作不可恢复。`)) return;
        archiveDelSelBtn.disabled = true;
        try {
            const r = await adminFetch('/api/archive/bulk-delete', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ folder, names }),
            });
            if (r.status === 401) { archiveDelSelBtn.disabled = (archive.selected.size === 0); return; }
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
        if (!guardWrite()) return;
        if (!window.confirm(`确定删除整个归档文件夹「${folder}」？\n\n该文件夹下的所有 csv 都会被删除，此操作不可恢复。`)) return;
        archiveDelFolderBtn.disabled = true;
        try {
            const r = await adminFetch('/api/archive/folder/' + encodeURIComponent(folder), { method: 'DELETE' });
            if (r.status === 401) { archiveDelFolderBtn.disabled = false; return; }
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

    // 模式 Tab 切换：点一下重拉列表，能够看到所选模式下的只读记录
    const modeTabsEl = $('modeTabs');
    if (modeTabsEl) {
        modeTabsEl.addEventListener('click', (e) => {
            const btn = e.target.closest('.mode-tab');
            if (!btn) return;
            const m = btn.dataset.mode || '';
            if (m === state.mode) return;
            state.mode = m;
            renderModeTabs();
            fetchList();
        });
    }

    // ────────── 列宽拖拽（主表 #filesTable） ──────────
    // 让用户像 Finder/资源管理器那样能直接拖动列宽：
    //   - 通过 <colgroup><col data-col="..."> 控制宽度，避免与 nth-child 选择器耦合；
    //   - 文件名列（data-col="name"）不直接拖宽，它由 table-layout:fixed 自动占据剩余空间；
    //   - 拖动相邻列时，文件名列会自然让出 / 收回空间，符合直觉；
    //   - 自定义宽度持久化到 localStorage，刷新后恢复。
    const COL_WIDTHS_KEY = 'PlayerX.colWidths.v1';
    const COL_MIN_WIDTH = 60;     // 最小列宽，避免拖到 0 让内容糊在一起
    const COL_MAX_WIDTH = 800;    // 上限，防误操作把单列拉得过宽

    function loadSavedColWidths() {
        try {
            const raw = localStorage.getItem(COL_WIDTHS_KEY);
            if (!raw) return {};
            const obj = JSON.parse(raw);
            return (obj && typeof obj === 'object') ? obj : {};
        } catch (_) { return {}; }
    }
    function saveColWidth(colKey, px) {
        const cur = loadSavedColWidths();
        cur[colKey] = px;
        try { localStorage.setItem(COL_WIDTHS_KEY, JSON.stringify(cur)); } catch (_) {}
    }
    function applySavedColWidths(table) {
        const saved = loadSavedColWidths();
        const cols = table.querySelectorAll('colgroup > col[data-col]');
        cols.forEach(col => {
            const k = col.dataset.col;
            // 文件名列从不写死宽度，让它继续吃剩余空间；即便用户「不小心」改过也忽略
            if (k === 'name') return;
            if (saved[k]) col.style.width = saved[k] + 'px';
        });
    }

    function initColumnResizing(table) {
        if (!table || table.dataset.resizableInit === '1') return;
        table.dataset.resizableInit = '1';

        // 先把保存过的宽度灌进去
        applySavedColWidths(table);

        const ths = table.querySelectorAll('thead th[data-col]');
        ths.forEach(th => {
            const colKey = th.dataset.col;
            // 文件名列不需要拖（它是「弹性列」，由邻列让出来），其余列都给一个手柄
            if (colKey === 'name') return;
            // 操作列在最右，再挂手柄会越界出表格右边缘，体验差且没意义，跳过
            if (colKey === 'actions') return;
            // 复选列太窄也没必要拖，跳过
            if (colKey === 'check') return;

            const grip = document.createElement('span');
            grip.className = 'col-resizer';
            grip.title = '拖动以调整列宽';
            // 阻止冒泡到 th 的排序点击逻辑（th.sortable 会触发排序）
            grip.addEventListener('click', (e) => { e.stopPropagation(); });
            grip.addEventListener('mousedown', (e) => {
                e.preventDefault();
                e.stopPropagation();
                startColResize(table, colKey, e.clientX, grip);
            });
            th.appendChild(grip);
        });
    }

    function startColResize(table, colKey, startX, gripEl) {
        const col = table.querySelector(`colgroup > col[data-col="${colKey}"]`);
        if (!col) return;
        // 起始宽度优先取 col.style.width；没有的话退回到对应 th 的实际宽
        const th = table.querySelector(`thead th[data-col="${colKey}"]`);
        const startWidth = parseInt(col.style.width, 10) || (th ? th.getBoundingClientRect().width : 100);

        document.body.classList.add('col-resizing');
        gripEl.classList.add('is-dragging');

        const onMove = (ev) => {
            const dx = ev.clientX - startX;
            let w = Math.round(startWidth + dx);
            if (w < COL_MIN_WIDTH) w = COL_MIN_WIDTH;
            if (w > COL_MAX_WIDTH) w = COL_MAX_WIDTH;
            col.style.width = w + 'px';
        };
        const onUp = () => {
            document.removeEventListener('mousemove', onMove);
            document.removeEventListener('mouseup', onUp);
            document.body.classList.remove('col-resizing');
            gripEl.classList.remove('is-dragging');
            // 落点写入 localStorage
            const finalW = parseInt(col.style.width, 10);
            if (finalW > 0) saveColWidth(colKey, finalW);
        };
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onUp);
    }

    // ────────── 启动 ──────────
    (async function init() {
        await fetchStatus();
        await fetchAuthInfo();   // 拉取鉴权状态，更新顶栏登录按钮和管理按钮的锁定态
        await fetchList();
        updateAuthUi();          // 列表渲染后再刷一次（同步行内删除按钮的锁定态）
        // 表头是静态的，初始化一次即可；列宽的持久化由 localStorage 维护
        initColumnResizing(document.getElementById('filesTable'));
    })();
})();
