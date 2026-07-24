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
        // "上传 Token "按钮仅在管理员登录后可见
        if (tokenSettingsBtn) {
            tokenSettingsBtn.hidden = !(auth.enabled && logged);
        }
        // 维度页面的「编辑配置」「＋新建」按钮仅在管理员登录后可见
        const dimEditBtnEl = $('dimEditBtn');
        if (dimEditBtnEl) {
            dimEditBtnEl.style.display = (auth.enabled && logged) ? '' : 'none';
        }
        const dimAddBtnEl = $('dimAddBtn');
        if (dimAddBtnEl) {
            dimAddBtnEl.style.display = (auth.enabled && logged) ? '' : 'none';
        }
        // 如果维度页面已打开，刷新侧边栏（更新删除按钮可见性）
        if (dimPageOpen && typeof loadConfigList === 'function') loadConfigList();
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

    // ────────── 维度规则独立页面（多配置文件管理）──────────
    const dimPageBtn        = $('dimPageBtn');
    const dimPage           = $('dimPage');
    const dimPageCloseBtn   = $('dimPageCloseBtn');
    const dimView           = $('dimView');
    const dimEditorSection  = $('dimEditorSection');
    const dimEditor         = $('dimEditor');
    const dimErr            = $('dimErr');
    const dimEditBtn        = $('dimEditBtn');
    const dimFormatBtn      = $('dimFormatBtn');
    const dimSaveBtn        = $('dimSaveBtn');
    const dimCancelEditBtn  = $('dimCancelEditBtn');
    const dimSidebarList    = $('dimSidebarList');
    const dimAddBtn         = $('dimAddBtn');

    // 主内容区（模式Tab/卡片/工具栏/表格）
    const mainContent = [
        $('modeTabs'), document.querySelector('.cards'),
        document.querySelector('.toolbar'), document.querySelector('.table-wrap'),
        document.querySelector('.footer'),
    ];

    let dimPageOpen    = false;
    let dimEditing     = false;
    let dimRawData     = null;   // 当前选中配置的原始 JSON 字符串
    let dimCurrentName = null;   // 当前选中的配置文件名（不含 .json）
    let dimActiveBindings = {};  // { mode -> configName } 所有模式的绑定关系

    // 模式 id -> 显示标签
    const MODE_LABELS = {
        multi_dim:     '多维评分',
        subjective:    '主观评分',
        quality:       '质量比较',
        quality_slide: '质量比较2',
        test:          '测试模式',
    };
    const MODE_ORDER = ['multi_dim', 'subjective', 'quality', 'quality_slide', 'test'];

    function modeLabel(mode) { return MODE_LABELS[mode] || mode; }

    // ── 页面开关 ──
    function showDimPage(skipHashUpdate) {
        dimPageOpen = true;
        dimPage.hidden = false;
        mainContent.forEach(el => { if (el) el.style.display = 'none'; });
        if (!skipHashUpdate) history.replaceState(null, '', '#rules');
        loadConfigList();
    }

    function hideDimPage() {
        dimPageOpen = false;
        dimPage.hidden = true;
        mainContent.forEach(el => { if (el) el.style.display = ''; });
        exitDimEdit();
        history.replaceState(null, '', location.pathname + location.search);
    }

    // ── 左侧：加载配置列表 ──
    async function loadConfigList() {
        dimSidebarList.innerHTML = '<div class="dim-sidebar-loading">加载中…</div>';
        try {
            const r = await fetch('/api/configs?_=' + Date.now());
            const j = await r.json();
            if (!r.ok || !j.ok) throw new Error(j.error || 'HTTP ' + r.status);
            dimActiveBindings = j.bindings || {};
            renderSidebarList(j.configs || []);
            // 自动选中第一个有激活绑定的配置，否则选第一个
            const configs = j.configs || [];
            if (configs.length > 0) {
                // 优先从 URL hash 恢复选中配置（支持分享直达链接）
                const hashConfig = _getHashConfig();
                const hashMatch = hashConfig && configs.find(c => c.name === hashConfig);
                if (hashMatch) {
                    selectConfig(hashMatch.name);
                } else {
                    const activeNames = Object.values(dimActiveBindings);
                    const firstActive = configs.find(c => activeNames.includes(c.name));
                    selectConfig(firstActive ? firstActive.name : configs[0].name);
                }
            } else {
                dimView.innerHTML = '<div class="dim-view-loading">暂无配置，请拖入 .json 文件或点击「＋」新建</div>';
            }
        } catch (e) {
            dimSidebarList.innerHTML = `<div class="dim-sidebar-loading dim-sidebar-err">⚠️ ${escHtml(e.message)}</div>`;
        }
    }

    function renderSidebarList(configs) {
        if (!configs.length) {
            dimSidebarList.innerHTML = '<div class="dim-sidebar-loading">暂无配置</div>';
            return;
        }
        const admin = isLoggedIn();
        dimSidebarList.innerHTML = configs.map(c => {
            // 该配置绑定了哪些模式（兼容新格式数组和旧格式字符串）
            const activeModes = MODE_ORDER.filter(m => {
                const v = dimActiveBindings[m];
                return Array.isArray(v) ? v.includes(c.name) : v === c.name;
            });
            const badgesHtml = activeModes.map(m =>
                `<span class="dim-active-badge" data-mode="${m}" title="已绑定到模式：${modeLabel(m)}">${modeLabel(m)}</span>`
            ).join('');
            const dragHandle = admin
                ? `<span class="dim-sidebar-drag-handle" title="拖动调整顺序">⠿</span>`
                : '';
            return `
            <div class="dim-sidebar-item ${c.name === dimCurrentName ? 'is-active' : ''}${admin ? ' dim-sidebar-item-draggable' : ''}" data-name="${escHtml(c.name)}"${admin ? ' draggable="true"' : ''}>
                <div class="dim-sidebar-item-main">
                    ${dragHandle}
                    <span class="dim-sidebar-item-type" title="双击重命名">${escHtml(c.type || c.name)}</span>
                    ${badgesHtml}
                </div>
                <div class="dim-sidebar-item-row2">
                    <span class="dim-sidebar-item-task">${c.task ? escHtml(c.task) : ''}</span>
                    <div class="dim-sidebar-item-actions">
                        ${admin ? `<button class="dim-activate-btn ghost-btn" data-name="${escHtml(c.name)}" title="绑定/解绑模式">📌 绑定</button>` : ''}
                        ${admin ? `<button class="dim-copy-btn ghost-btn" data-name="${escHtml(c.name)}" title="复制一份此配置">复制</button>` : ''}
                        ${admin ? `<button class="dim-sidebar-del ghost-btn" data-name="${escHtml(c.name)}" title="删除此配置">🗑</button>` : ''}
                    </div>
                </div>
            </div>
        `}).join('');

        // 点击选中
        dimSidebarList.querySelectorAll('.dim-sidebar-item').forEach(el => {
            el.addEventListener('click', (e) => {
                if (e.target.closest('.dim-sidebar-del')) return;
                if (e.target.closest('.dim-activate-btn')) return;
                if (e.target.closest('.dim-copy-btn')) return;
                if (e.target.closest('.dim-sidebar-rename-input')) return;
                if (e.target.closest('.dim-sidebar-drag-handle')) return;
                selectConfig(el.dataset.name);
            });
        });

        // 双击重命名（仅管理员）
        if (admin) {
            dimSidebarList.querySelectorAll('.dim-sidebar-item-type').forEach(span => {
                span.addEventListener('dblclick', (e) => {
                    e.stopPropagation();
                    const item = span.closest('.dim-sidebar-item');
                    if (!item) return;
                    startRenameConfig(item, span);
                });
            });
        }

        // 绑定按钮 → 弹出模式选择下拉
        dimSidebarList.querySelectorAll('.dim-activate-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                showBindModePopup(btn, btn.dataset.name);
            });
        });

        // 复制按钮
        dimSidebarList.querySelectorAll('.dim-copy-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                copyConfig(btn.dataset.name);
            });
        });

        // 删除按钮
        dimSidebarList.querySelectorAll('.dim-sidebar-del').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                deleteConfig(btn.dataset.name);
            });
        });

        // 拖拽排序（仅管理员）
        if (admin) {
            _bindSidebarDragSort();
        }
    }

    /** 拖拽排序：绑定 dim-sidebar-item 的 drag & drop 事件 */
    function _bindSidebarDragSort() {
        let dragSrcName = null;
        dimSidebarList.querySelectorAll('.dim-sidebar-item-draggable').forEach(item => {
            item.addEventListener('dragstart', e => {
                dragSrcName = item.dataset.name;
                item.classList.add('dim-sidebar-item-dragging');
                e.dataTransfer.effectAllowed = 'move';
                e.dataTransfer.setData('text/plain', dragSrcName);
                e.stopPropagation(); // 防止冒泡到页面级文件拖入监听
            });
            item.addEventListener('dragend', () => {
                item.classList.remove('dim-sidebar-item-dragging');
                dimSidebarList.querySelectorAll('.dim-sidebar-item').forEach(el => {
                    el.classList.remove('dim-sidebar-item-drag-over-top', 'dim-sidebar-item-drag-over-bottom');
                });
                dragSrcName = null;
            });
            item.addEventListener('dragover', e => {
                if (!dragSrcName || item.dataset.name === dragSrcName) return;
                e.preventDefault();
                e.dataTransfer.dropEffect = 'move';
                const rect = item.getBoundingClientRect();
                const isTop = e.clientY < rect.top + rect.height / 2;
                dimSidebarList.querySelectorAll('.dim-sidebar-item').forEach(el => {
                    el.classList.remove('dim-sidebar-item-drag-over-top', 'dim-sidebar-item-drag-over-bottom');
                });
                item.classList.add(isTop ? 'dim-sidebar-item-drag-over-top' : 'dim-sidebar-item-drag-over-bottom');
            });
            item.addEventListener('dragleave', () => {
                item.classList.remove('dim-sidebar-item-drag-over-top', 'dim-sidebar-item-drag-over-bottom');
            });
            item.addEventListener('drop', e => {
                e.preventDefault();
                e.stopPropagation();
                const targetName = item.dataset.name;
                if (!dragSrcName || dragSrcName === targetName) return;
                // 计算插入位置
                const rect = item.getBoundingClientRect();
                const insertBefore = e.clientY < rect.top + rect.height / 2;
                // 重排 DOM 中的 item 顺序
                const allItems = Array.from(dimSidebarList.querySelectorAll('.dim-sidebar-item'));
                const srcEl = allItems.find(el => el.dataset.name === dragSrcName);
                const tgtEl = item;
                if (!srcEl) return;
                if (insertBefore) {
                    dimSidebarList.insertBefore(srcEl, tgtEl);
                } else {
                    dimSidebarList.insertBefore(srcEl, tgtEl.nextSibling);
                }
                // 读取新顺序并保存
                const newOrder = Array.from(dimSidebarList.querySelectorAll('.dim-sidebar-item')).map(el => el.dataset.name);
                fetch('/api/configs-order', {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ order: newOrder }),
                    credentials: 'include',
                }).catch(() => {});
            });
        });
    }

    // ── 绑定模式下拉弹窗 ──
    let _bindPopup = null;
    function showBindModePopup(anchorBtn, configName) {
        // 关闭已有弹窗
        if (_bindPopup) { _bindPopup.remove(); _bindPopup = null; }
        const popup = document.createElement('div');
        popup.className = 'dim-bind-popup';
        popup.innerHTML = MODE_ORDER.map(mode => {
            const boundVal = dimActiveBindings[mode];
            // 兼容新格式（数组）和旧格式（字符串）
            const boundArr = Array.isArray(boundVal) ? boundVal : (boundVal ? [boundVal] : []);
            const isBound = boundArr.includes(configName);
            const otherBound = boundArr.filter(n => n !== configName);
            return `<div class="dim-bind-item ${isBound ? 'is-bound' : ''}" data-mode="${mode}" data-name="${escHtml(configName)}">
                <span class="dim-bind-check">${isBound ? '✓' : ''}</span>
                <span class="dim-bind-label">${modeLabel(mode)}</span>
                ${otherBound.length > 0 ? `<span class="dim-bind-other" title="同模式还绑定：${otherBound.map(escHtml).join('、')}">+${otherBound.length}个</span>` : ''}
            </div>`;
        }).join('');
        document.body.appendChild(popup);
        _bindPopup = popup;

        // 定位到按钮下方
        const rect = anchorBtn.getBoundingClientRect();
        popup.style.position = 'fixed';
        popup.style.zIndex = '9999';
        // 先渲染再定位
        requestAnimationFrame(() => {
            const pw = popup.offsetWidth;
            const ph = popup.offsetHeight;
            let left = rect.left;
            let top  = rect.bottom + 4;
            if (left + pw > window.innerWidth - 8) left = window.innerWidth - pw - 8;
            if (top + ph > window.innerHeight - 8) top = rect.top - ph - 4;
            popup.style.left = left + 'px';
            popup.style.top  = top  + 'px';
        });

        // 点击模式项 → 绑定/解绑
        popup.querySelectorAll('.dim-bind-item').forEach(item => {
            item.addEventListener('click', async (e) => {
                e.stopPropagation();
                const mode = item.dataset.mode;
                const name = item.dataset.name;
                popup.remove(); _bindPopup = null;
                await toggleBindMode(name, mode);
            });
        });

        // 点击外部关闭
        setTimeout(() => {
            document.addEventListener('click', function closePopup() {
                if (_bindPopup) { _bindPopup.remove(); _bindPopup = null; }
                document.removeEventListener('click', closePopup);
            }, { once: true });
        }, 0);
    }

    // ── 绑定/解绑配置到模式 ──
    async function toggleBindMode(name, mode) {
        try {
            const r = await adminFetch('/api/active-config', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name, mode }),
            });
            if (r.status === 401) return;
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) { showToast('❌ ' + (j.error || '操作失败'), 'err'); return; }
            dimActiveBindings = j.bindings || {};
            if (j.action === 'bound') {
                showToast(`✅ 已将「${name}」绑定到「${modeLabel(mode)}」`, 'ok');
            } else {
                showToast(`✅ 已解绑「${name}」与「${modeLabel(mode)}」`, 'ok');
            }
            // 重新渲染侧边栏（不重新请求列表）
            const items = dimSidebarList.querySelectorAll('.dim-sidebar-item');
            items.forEach(el => {
                const cName = el.dataset.name;
                const main = el.querySelector('.dim-sidebar-item-main');
                if (!main) return;
                // 移除旧 badges
                main.querySelectorAll('.dim-active-badge').forEach(b => b.remove());
                // 重新生成 badges（兼容新格式数组和旧格式字符串）
                const activeModes = MODE_ORDER.filter(m => {
                    const v = dimActiveBindings[m];
                    return Array.isArray(v) ? v.includes(cName) : v === cName;
                });
                activeModes.forEach(m => {
                    const badge = document.createElement('span');
                    badge.className = 'dim-active-badge';
                    badge.dataset.mode = m;
                    badge.title = `已绑定到模式：${modeLabel(m)}`;
                    badge.textContent = modeLabel(m);
                    main.appendChild(badge);
                });
            });
        } catch (e) {
            showToast('❌ 网络错误：' + e.message, 'err');
        }
    }

    // ── 复制配置 ──
    async function copyConfig(name) {
        try {
            const r = await fetch(`/api/configs/${encodeURIComponent(name)}?_=` + Date.now());
            const text = await r.text();
            if (!r.ok) throw new Error('HTTP ' + r.status);
            let obj;
            try { obj = JSON.parse(text); } catch (e) { throw new Error('JSON 解析失败'); }
            // 生成新名称：原名 + _copy（若已存在则加时间戳）
            const newName = name + '_copy_' + Date.now();
            obj.type = (obj.type || name) + ' (副本)';
            const newRaw = JSON.stringify(obj, null, 2);
            const saveR = await adminFetch(`/api/configs/${encodeURIComponent(newName)}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: newRaw,
            });
            if (saveR.status === 401) return;
            const j = await saveR.json().catch(() => ({}));
            if (!saveR.ok || !j.ok) { showToast('❌ ' + (j.error || '复制失败'), 'err'); return; }
            showToast(`✅ 已复制为「${newName}」`, 'ok');
            await loadConfigList();
            selectConfig(newName);
        } catch (e) {
            showToast('❌ 复制失败：' + e.message, 'err');
        }
    }

    function startRenameConfig(itemEl, spanEl) {
        if (itemEl.querySelector('.dim-sidebar-rename-input')) return; // 已在编辑中
        const oldName = itemEl.dataset.name;
        const oldText = spanEl.textContent;
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'dim-sidebar-rename-input';
        input.value = oldText;
        spanEl.replaceWith(input);
        input.focus();
        input.select();

        async function commitRename() {
            const newName = input.value.trim();
            input.replaceWith(spanEl); // 先还原 span
            if (!newName || newName === oldText) return;
            // 读取当前配置内容，更新 type 字段，然后用新名保存，再删旧名
            try {
                const r = await fetch(`/api/configs/${encodeURIComponent(oldName)}?_=` + Date.now());
                const text = await r.text();
                let parsed;
                try { parsed = JSON.parse(text); } catch (_) { parsed = {}; }
                parsed.type = newName;
                const newFileName = newName.replace(/\s+/g, '_');
                // 保存新文件
                const saveR = await adminFetch(`/api/configs/${encodeURIComponent(newFileName)}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(parsed, null, 2),
                });
                if (saveR.status === 401) return;
                const saveJ = await saveR.json().catch(() => ({}));
                if (!saveR.ok || !saveJ.ok) { showToast('❌ 重命名失败：' + (saveJ.error || ''), 'err'); return; }
                // 删除旧文件（如果名字变了）
                if (newFileName !== oldName) {
                    await adminFetch(`/api/configs/${encodeURIComponent(oldName)}`, { method: 'DELETE' });
                    if (dimCurrentName === oldName) dimCurrentName = newFileName;
                }
                showToast(`✅ 已重命名为「${newName}」`, 'ok');
                loadConfigList();
            } catch (e) {
                showToast('❌ 重命名失败：' + e.message, 'err');
            }
        }

        input.addEventListener('blur', commitRename);
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
            if (e.key === 'Escape') { input.replaceWith(spanEl); }
        });
    }

    // ── 选中某个配置，加载并展示 ──
    async function selectConfig(name) {
        dimCurrentName = name;
        // 高亮侧边栏
        dimSidebarList.querySelectorAll('.dim-sidebar-item').forEach(el => {
            el.classList.toggle('is-active', el.dataset.name === name);
        });
        exitDimEdit();
        dimView.innerHTML = '<div class="dim-view-loading">加载中…</div>';
        dimView.style.display = '';
        // 更新 URL hash，方便分享直达链接
        if (dimPageOpen) history.replaceState(null, '', '#rules/' + encodeURIComponent(name));
        try {
            const r = await fetch(`/api/configs/${encodeURIComponent(name)}?_=` + Date.now());
            const text = await r.text();
            if (!r.ok) {
                let msg = 'HTTP ' + r.status;
                try { msg = JSON.parse(text).error || msg; } catch (_) {}
                throw new Error(msg);
            }
            dimRawData = text;
            renderDimCards(JSON.parse(text));
        } catch (e) {
            dimView.innerHTML = `<div class="dim-view-loading dim-view-err">⚠️ 加载失败：${escHtml(e.message)}</div>`;
        }
    }

    // ── 删除配置 ──
    async function deleteConfig(name) {
        if (!confirm(`确定删除配置「${name}」？此操作不可恢复。`)) return;
        try {
            const r = await adminFetch(`/api/configs/${encodeURIComponent(name)}`, { method: 'DELETE' });
            if (r.status === 401) return;
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) { showToast('❌ ' + (j.error || '删除失败'), 'err'); return; }
            showToast('✅ ' + j.message, 'ok');
            if (dimCurrentName === name) {
                dimCurrentName = null;
                dimRawData = null;
                dimView.innerHTML = '<div class="dim-view-loading">请从左侧选择配置</div>';
            }
            loadConfigList();
        } catch (e) {
            showToast('❌ 网络错误：' + e.message, 'err');
        }
    }

    // ── 新建配置（直接进编辑器，不弹 prompt） ──
    function promptNewConfig() {
        // 用时间戳生成临时文件名，保存时会根据 type 字段自动更新
        const tmpName = 'new_' + Date.now();
        const template = JSON.stringify({
            type: '新配置',
            task: '',
            scale: '1-5 Likert 整数',
            dimensions: [
                { key: '维度1', definition: '请填写维度说明', levels: [
                    { score: 5, label: '优秀', description: '' },
                    { score: 4, label: '良好', description: '' },
                    { score: 3, label: '一般', description: '' },
                    { score: 2, label: '较差', description: '' },
                    { score: 1, label: '很差', description: '' }
                ]}
            ]
        }, null, 2);
        dimCurrentName = tmpName;
        dimRawData = template;
        // 清除侧边栏高亮（新建尚未保存）
        dimSidebarList.querySelectorAll('.dim-sidebar-item').forEach(el => el.classList.remove('is-active'));
        // 直接进入编辑模式
        dimView.style.display = 'none';
        dimEditorSection.style.display = 'flex';
        dimEditBtn.style.display = 'none';
        dimFormatBtn.style.display = '';
        dimSaveBtn.style.display = '';
        dimCancelEditBtn.style.display = '';
        dimErr.style.display = 'none';
        dimEditor.value = template;
        setTimeout(() => dimEditor.focus(), 30);
    }

    // ── 卡片渲染 ──
    function renderDimCards(obj) {
        if (!obj || !Array.isArray(obj.dimensions) || obj.dimensions.length === 0) {
            const admin = isLoggedIn();
            dimView.innerHTML = `<div class="dim-view-loading">暂无维度配置${admin ? '' : ''}</div>`
                + (admin ? `<div style="padding:0 28px"><button class="dim-add-dim-btn ghost-btn" style="margin-top:8px">＋ 添加维度</button></div>` : '');
            if (admin) setTimeout(() => bindCardEdit(obj || { dimensions: [] }), 0);
            return;
        }
        const admin = isLoggedIn();
        const metaItems = [];
        if (obj.type)  metaItems.push(`<span class="dim-meta-item dim-meta-type"><span class="dim-meta-label">评测类型</span><span class="dim-meta-val">${escHtml(obj.type)}</span></span>`);
        // 评测任务：可内联编辑
        metaItems.push(`<span class="dim-meta-item dim-meta-task"><span class="dim-meta-label">评测任务</span><span class="dim-meta-val dim-meta-editable" data-field="task" title="点击编辑">${escHtml(obj.task || '（未填写，点击添加）')}</span></span>`);
        if (obj.scale) metaItems.push(`<span class="dim-meta-item dim-meta-muted dim-meta-scale"><span class="dim-meta-icon">📏</span>${escHtml(obj.scale)}</span>`);
        // 备注 tag：可内联编辑
        metaItems.push(`<span class="dim-meta-item dim-meta-tag"><span class="dim-meta-label">备注 tag</span><span class="dim-meta-val dim-meta-editable" data-field="tag" title="点击编辑">${escHtml(obj.tag || '（未填写，点击添加）')}</span></span>`);
        // 测试源 URL：可内联编辑（管理员专属）
        if (admin) metaItems.push(`<span class="dim-meta-item dim-meta-test-source"><span class="dim-meta-label">🔗 测试源</span><span class="dim-meta-val dim-meta-editable" data-field="testSourceUrl" title="点击编辑测试源下载地址">${escHtml(obj.testSourceUrl || '（未填写，点击添加）')}</span></span>`);
        const metaHtml = metaItems.length ? `<div class="dim-cards-meta">${metaItems.join('<span class="dim-meta-sep">·</span>')}</div>` : '';

        // 渲染后绑定内联编辑事件（延迟到 innerHTML 写入后）
        setTimeout(() => {
            bindMetaInlineEdit();
            if (admin) bindCardEdit(obj);
        }, 0);

        const cardsHtml = obj.dimensions.map((d, idx) => renderDimCardHtml(d, idx, obj.dimensions.length, admin)).join('');
        const addDimBtn = admin ? `<button class="dim-add-dim-btn ghost-btn">＋ 添加维度</button>` : '';

        // 渲染 checklist 预览区域
        const checklistHtml = renderChecklistPreview(obj.checklists, obj.checklist_config, admin);

        dimView.innerHTML = metaHtml + `<div class="dim-cards-grid">${cardsHtml}</div>`
            + `<div class="dim-bottom-actions" style="display:flex;align-items:center;padding:0 28px;gap:0">${addDimBtn}</div>`
            + checklistHtml;
    }

    /** 渲染单张维度卡片 HTML（纯字符串，不绑定事件） */
    function renderDimCardHtml(d, idx, totalDims, admin) {
        const levels = Array.isArray(d.levels) ? d.levels : [];
        const totalStars = levels.length;

        const levelsHtml = levels.map((lv, lvIdx) => {
            const score = lv.score != null ? lv.score : '';
            const filledStars = Math.max(0, +score || 0);
            const emptyStars  = Math.max(0, totalStars - filledStars);
            const starsHtml = admin
                ? `<span class="dim-level-stars-edit" data-dim="${idx}" data-lv="${lvIdx}" title="点击调整分值">`
                    + '★'.repeat(filledStars) + '☆'.repeat(emptyStars)
                    + `</span>`
                : `<span class="dim-level-stars">${'★'.repeat(filledStars)}${'☆'.repeat(emptyStars)}</span>`;

            const labelEl = admin
                ? `<span class="dim-card-editable dim-level-label${lv.label ? '' : ' dim-card-placeholder'}" data-dim="${idx}" data-lv="${lvIdx}" data-field="label" title="点击编辑标签">${escHtml(lv.label || '点击填写标签')}</span>`
                : `<span class="dim-level-label">${escHtml(lv.label || '')}</span>`;

            const descEl = admin
                ? `<div class="dim-card-editable dim-level-desc${lv.description ? '' : ' dim-card-placeholder'}" data-dim="${idx}" data-lv="${lvIdx}" data-field="description" title="点击编辑描述">${escHtml(lv.description || '点击填写描述')}</div>`
                : `<div class="dim-level-desc">${escHtml(lv.description || '')}</div>`;

            const delBtn = admin
                ? `<button class="dim-del-lv-btn ghost-btn" data-dim="${idx}" data-lv="${lvIdx}" title="删除此等级">✕</button>`
                : '';

            const lvDragHandle = admin
                ? `<span class="dim-lv-drag-handle" title="左右拖动调整顺序">⠿</span>`
                : '';

            return `<div class="dim-level${admin ? ' dim-level-admin' : ''}" data-dim="${idx}" data-lv="${lvIdx}" data-score="${escHtml(String(score))}"${admin ? ' draggable="true"' : ''}>
                ${delBtn}
                ${lvDragHandle}
                <div class="dim-level-score">
                    <span class="dim-level-num">${escHtml(String(score))}</span>
                    ${starsHtml}
                    ${labelEl}
                </div>
                ${descEl}
            </div>`;
        }).join('');

        const addLvBtn = admin
            ? `<div class="dim-add-lv-cell"><button class="dim-add-lv-btn ghost-btn" data-dim="${idx}" title="添加等级">＋</button></div>`
            : '';

        const dragHandle = admin
            ? `<span class="dim-drag-handle" title="拖动调整顺序">⠿</span>`
            : '';

        const keyEl = admin
            ? `<span class="dim-card-editable dim-card-key${d.key ? '' : ' dim-card-placeholder'}" data-dim="${idx}" data-field="key" title="点击编辑维度名">${escHtml(d.key || '点击填写维度名')}</span>`
            : `<span class="dim-card-key">${escHtml(d.key || '')}</span>`;

        const defEl = admin
            ? `<div class="dim-card-editable dim-card-def${d.definition ? '' : ' dim-card-placeholder'}" data-dim="${idx}" data-field="definition" title="点击编辑说明">${escHtml(d.definition || '点击添加维度说明')}</div>`
            : (d.definition ? `<div class="dim-card-def">${escHtml(d.definition)}</div>` : '');

        const delDimBtn = admin
            ? `<button class="dim-del-dim-btn ghost-btn" data-dim="${idx}" title="删除此维度">🗑 删除</button>`
            : '';

        return `<div class="dim-card${admin ? ' dim-card-draggable' : ''}" data-dim="${idx}" draggable="${admin ? 'true' : 'false'}">
            <div class="dim-card-left">
                <div class="dim-card-header">
                    ${dragHandle}
                    <span class="dim-card-index">${idx + 1}</span>
                    ${keyEl}
                </div>
                ${defEl}
                ${delDimBtn}
            </div>
            <div class="dim-card-levels">
                ${levelsHtml}
                ${addLvBtn}
            </div>
        </div>`;
    }

    /** 渲染 checklist 预览区域（admin 下所有字段原地可编辑） */
    function renderChecklistPreview(checklists, checklistConfig, admin) {
        const items = Array.isArray(checklists) ? checklists : [];
        if (items.length === 0 && !admin) return '';
        const exclusiveKey = (checklistConfig && checklistConfig.exclusive_key) || '';
        const rowsHtml = items.map((item, idx) => {
            const isExclusive = item.key === exclusiveKey || item.exclusive;
            const exclusiveBadge = admin
                ? `<span class="dim-cl-excl-badge ${isExclusive ? 'is-on' : 'is-off'}" data-cl-idx="${idx}" title="点击切换互斥">互斥</span>`
                : (isExclusive ? `<span class="dim-cl-excl-badge is-on">互斥</span>` : '');
            const delBtn = admin ? `<button class="dim-cl-del-btn" data-idx="${idx}" title="删除">✕</button>` : '';

            const labelCls = 'dim-cl-editable dim-cl-label' + (item.label ? '' : ' dim-card-placeholder');
            const keyCls   = 'dim-cl-editable dim-cl-key'   + (item.key ? '' : ' dim-card-placeholder');
            const defCls   = 'dim-cl-editable dim-cl-def'   + (item.definition ? '' : ' dim-card-placeholder');

            const labelHtml = admin
                ? `<span class="${labelCls}" data-cl-idx="${idx}" data-cl-field="label" title="点击编辑名称">${escHtml(item.label || '点击填写名称')}</span>`
                : `<span class="dim-cl-label">${escHtml(item.label || item.key)}</span>`;
            const keyHtml = admin
                ? `<span class="${keyCls}" data-cl-idx="${idx}" data-cl-field="key" title="点击编辑 key（英文标识）">${escHtml(item.key || 'key')}</span>`
                : '';
            const defHtml = admin
                ? `<span class="${defCls}" data-cl-idx="${idx}" data-cl-field="definition" title="点击编辑悬浮说明">${escHtml(item.definition || '点击添加悬浮说明')}</span>`
                : (item.definition ? `<span class="dim-cl-def">${escHtml(item.definition)}</span>` : '');

            const fieldLabel = (text, type) => `<span class="dim-cl-fname dim-cl-fname-${type}">${text}</span>`;
            return `<div class="dim-cl-row" data-idx="${idx}">
                ${admin ? `<div class="dim-cl-cell dim-cl-cell-key">
                    ${fieldLabel('标签键', 'key')}
                    ${keyHtml}
                </div>` : ''}
                <div class="dim-cl-cell dim-cl-cell-label">
                    ${admin ? fieldLabel('标签值', 'label') : ''}
                    ${labelHtml}
                </div>
                <div class="dim-cl-cell dim-cl-cell-def">
                    ${admin ? fieldLabel('描述', 'def') : ''}
                    ${defHtml}
                </div>
                ${exclusiveBadge}
                ${delBtn}
            </div>`;
        }).join('');
        const addRowBtn = admin ? `<button class="dim-cl-add-btn">＋ 添加选项</button>` : '';
        const exclusiveHint = exclusiveKey
            ? `<span class="dim-cl-hint">互斥 key: <code>${escHtml(exclusiveKey)}</code></span>`
            : '';
        const emptyHtml = items.length === 0
            ? '<div class="dim-cl-empty">暂无选项，点击下方添加</div>'
            : '';
        return `<div class="dim-checklist-section">
            <div class="dim-cl-header">
                <span class="dim-cl-title">📋 Checklist</span>
                <span class="dim-cl-subtitle">打分后弹出的问题标记</span>
                ${exclusiveHint}
            </div>
            <div class="dim-cl-body">
                ${rowsHtml}
                ${emptyHtml}
                ${addRowBtn}
            </div>
        </div>`;
    }

    // ── 卡片可视化编辑：事件绑定 ──
    function bindCardEdit(obj) {
        if (!isLoggedIn()) return;

        // 内联编辑：维度名 / 维度说明 / level标签 / level描述
        dimView.querySelectorAll('.dim-card-editable').forEach(el => {
            el.addEventListener('click', () => startCardFieldEdit(el));
        });

        // 星星点击：调整分值
        dimView.querySelectorAll('.dim-level-stars-edit').forEach(el => {
            el.addEventListener('click', (e) => {
                const dimIdx = +el.dataset.dim;
                const lvIdx  = +el.dataset.lv;
                const rect   = el.getBoundingClientRect();
                const relX   = e.clientX - rect.left;
                const starW  = rect.width / (el.textContent.length || 1);
                const clicked = Math.ceil(relX / starW);
                patchDimData(data => {
                    data.dimensions[dimIdx].levels[lvIdx].score = clicked;
                    // 同步 dim-level-num
                    const card = dimView.querySelector(`.dim-card[data-dim="${dimIdx}"]`);
                    if (card) {
                        const lvEl = card.querySelector(`.dim-level[data-lv="${lvIdx}"]`);
                        if (lvEl) lvEl.querySelector('.dim-level-num').textContent = clicked;
                    }
                    // 重新渲染该卡片的星星
                    refreshCard(dimIdx, data);
                });
            });
        });

        // 删除等级
        dimView.querySelectorAll('.dim-del-lv-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const dimIdx = +btn.dataset.dim;
                const lvIdx  = +btn.dataset.lv;
                patchDimData(data => {
                    data.dimensions[dimIdx].levels.splice(lvIdx, 1);
                    // 删除后重新按降序连续分配 score（1~N）
                    const lvs = data.dimensions[dimIdx].levels;
                    const n = lvs.length;
                    lvs.forEach((l, i) => { l.score = n - i; });
                    refreshCard(dimIdx, data);
                });
            });
        });

        // 添加等级
        dimView.querySelectorAll('.dim-add-lv-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const dimIdx = +btn.dataset.dim;
                patchDimData(data => {
                    const levels = data.dimensions[dimIdx].levels || [];
                    // 追加新等级，然后按降序重新分配 score（1~N 连续，最左最高）
                    levels.push({ score: 0, label: '新等级', description: '' });
                    const n = levels.length;
                    levels.forEach((l, i) => { l.score = n - i; });
                    data.dimensions[dimIdx].levels = levels;
                    refreshCard(dimIdx, data);
                });
            });
        });

        // 删除维度
        dimView.querySelectorAll('.dim-del-dim-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const dimIdx = +btn.dataset.dim;
                patchDimData(data => {
                    data.dimensions.splice(dimIdx, 1);
                    renderDimCards(data);
                });
            });
        });

        // 拖拽排序（卡片上下）
        _bindDimDragSort();

        // 等级列左右拖拽排序
        _bindLevelDragSort(null);

        // 添加维度
        const addDimBtn = dimView.querySelector('.dim-add-dim-btn');
        if (addDimBtn) {
            addDimBtn.addEventListener('click', () => {
                patchDimData(data => {
                    data.dimensions.push({
                        key: '新维度',
                        definition: '',
                        levels: [
                            { score: 5, label: '优秀', description: '' },
                            { score: 4, label: '良好', description: '' },
                            { score: 3, label: '一般', description: '' },
                            { score: 2, label: '较差', description: '' },
                            { score: 1, label: '很差', description: '' }
                        ]
                    });
                    renderDimCards(data);
                    setTimeout(() => dimView.scrollTo({ top: dimView.scrollHeight, behavior: 'smooth' }), 50);
                });
            });
        }

        // 编辑 checklist 单项：直接对 DOM 元素挂 click，跟 .dim-card-editable 一致
        // 行内编辑：label / key / definition
        dimView.querySelectorAll('.dim-cl-editable').forEach(el => {
            el.addEventListener('click', (e) => {
                e.stopPropagation();
                startChecklistFieldEdit(el);
            });
        });

        // 互斥徽章：点击切换
        dimView.querySelectorAll('.dim-cl-excl-badge[data-cl-idx]').forEach(badge => {
            badge.addEventListener('click', (e) => {
                e.stopPropagation();
                const idx = +badge.dataset.clIdx;
                patchDimData(data => {
                    if (!Array.isArray(data.checklists) || !data.checklists[idx]) return;
                    const item = data.checklists[idx];
                    const cfg = data.checklist_config = data.checklist_config || { multiple: true };
                    const isNowExcl = (cfg.exclusive_key === item.key) || !!item.exclusive;
                    if (isNowExcl) {
                        delete item.exclusive;
                        if (cfg.exclusive_key === item.key) delete cfg.exclusive_key;
                    } else {
                        // 单一互斥：清除其他项 exclusive 标志
                        data.checklists.forEach(x => { delete x.exclusive; });
                        item.exclusive = true;
                        cfg.exclusive_key = item.key;
                    }
                    renderDimCards(data);
                });
            });
        });

        // 删除按钮
        dimView.querySelectorAll('.dim-cl-del-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const idx = +btn.dataset.idx;
                patchDimData(data => {
                    if (Array.isArray(data.checklists)) {
                        const removedKey = (data.checklists[idx] || {}).key;
                        data.checklists.splice(idx, 1);
                        if (data.checklist_config && data.checklist_config.exclusive_key === removedKey) {
                            delete data.checklist_config.exclusive_key;
                        }
                        if (data.checklists.length === 0) delete data.checklists;
                    }
                    renderDimCards(data);
                });
            });
        });

        // 添加选项按钮
        const addChecklistBtn = dimView.querySelector('.dim-cl-add-btn');
        if (addChecklistBtn) {
            addChecklistBtn.addEventListener('click', () => {
                let data;
                try { data = JSON.parse(dimRawData); } catch (_) { return; }
                if (!Array.isArray(data.checklists)) data.checklists = [];
                const existing = new Set(data.checklists.map(x => x.key));
                let n = data.checklists.length + 1;
                let k = 'item_' + n;
                while (existing.has(k)) { n += 1; k = 'item_' + n; }
                // 服务端校验要求 key 和 label 都非空，给一个默认 label 避免 400
                data.checklists.push({ key: k, label: '新选项', definition: '' });
                const newIdx = data.checklists.length - 1;
                persistDimData(data).then(() => {
                    renderDimCards(data);
                    setTimeout(() => {
                        const el = dimView.querySelector(`.dim-cl-editable[data-cl-idx="${newIdx}"][data-cl-field="label"]`);
                        if (el) startChecklistFieldEdit(el);
                    }, 50);
                });
            });
        }
    }

    /** Checklist 单字段行内编辑（label / key / definition） */
    function startChecklistFieldEdit(el) {
        if (el.querySelector('input,textarea')) return;
        const idx   = +el.dataset.clIdx;
        const field = el.dataset.clField; // 'label' | 'key' | 'definition'
        const isMultiline = (field === 'definition');

        let data;
        try { data = JSON.parse(dimRawData); } catch (_) { return; }
        const item = (data.checklists || [])[idx];
        if (!item) return;
        const currentVal = item[field] || '';
        const origHtml = el.innerHTML;
        const placeholders = { key: 'key', label: '点击填写名称', definition: '点击添加悬浮说明' };

        const commit = async (rawVal) => {
            let newVal = (rawVal || '').trim();
            // key 空值回退到旧值，避免破坏数据结构
            if (field === 'key' && !newVal) newVal = item.key;
            // label 空值回退（服务端要求 label 非空）
            if (field === 'label' && !newVal) newVal = item.label || '新选项';

            // 读取最新的 dimRawData 再改（避免中间被别的编辑覆盖）
            let latest;
            try { latest = JSON.parse(dimRawData); } catch (_) { return; }
            if (!latest.checklists || !latest.checklists[idx]) return;
            const target = latest.checklists[idx];

            if (field === 'key') {
                const oldKey = target.key;
                target.key = newVal;
                if (latest.checklist_config && latest.checklist_config.exclusive_key === oldKey) {
                    latest.checklist_config.exclusive_key = newVal;
                }
            } else if (newVal) {
                target[field] = newVal;
            } else {
                delete target[field];
            }
            await persistDimData(latest);

            // 只更新当前节点，不整体重刷（避免打断其他字段的编辑焦点）
            const showVal = (field === 'key' ? newVal : (newVal || ''));
            if (showVal) {
                el.classList.remove('dim-card-placeholder');
                el.innerHTML = escHtml(showVal);
            } else {
                el.classList.add('dim-card-placeholder');
                el.innerHTML = escHtml(placeholders[field] || '');
            }
        };

        // 【关键】进入编辑前锁定宿主 span 的实测宽高，编辑结束时释放
        // 这样 input width:100% 完全等于点击前的实际宽度，绝对不跳变
        const rect = el.getBoundingClientRect();
        const lockedWidth  = rect.width;
        const lockedHeight = rect.height;
        const prevStyle = {
            width:     el.style.width,
            height:    el.style.height,
            minWidth:  el.style.minWidth,
            maxWidth:  el.style.maxWidth,
            padding:   el.style.padding,
            boxSizing: el.style.boxSizing,
        };
        el.style.width     = lockedWidth + 'px';
        el.style.height    = lockedHeight + 'px';
        el.style.minWidth  = lockedWidth + 'px';
        el.style.maxWidth  = lockedWidth + 'px';
        el.style.padding   = '0';
        el.style.boxSizing = 'border-box';
        const releaseLock = () => {
            el.style.width     = prevStyle.width;
            el.style.height    = prevStyle.height;
            el.style.minWidth  = prevStyle.minWidth;
            el.style.maxWidth  = prevStyle.maxWidth;
            el.style.padding   = prevStyle.padding;
            el.style.boxSizing = prevStyle.boxSizing;
        };

        // 编辑态输入框附带 field 类型 class（用于 CSS 精确控制宽度/字体，避免宽度突变）
        const fieldCls = 'dim-cl-inline-' + field; // -label / -key / -definition

        if (isMultiline) {
            const ta = document.createElement('textarea');
            ta.className = 'dim-cl-inline-input dim-cl-inline-textarea ' + fieldCls;
            ta.value = currentVal;
            ta.rows = 1;
            el.innerHTML = '';
            el.appendChild(ta);
            ta.focus();
            ta.select();
            let done = false;
            ta.addEventListener('blur', async () => {
                if (done) return;
                done = true;
                await commit(ta.value);
                releaseLock();
            });
            ta.addEventListener('keydown', e => {
                if (e.key === 'Escape') { done = true; el.innerHTML = origHtml; releaseLock(); }
                if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); ta.blur(); }
            });
        } else {
            const input = document.createElement('input');
            input.type = 'text';
            input.className = 'dim-cl-inline-input ' + fieldCls;
            input.value = currentVal;
            el.innerHTML = '';
            el.appendChild(input);
            input.focus();
            input.select();
            let done = false;
            input.addEventListener('blur', async () => {
                if (done) return;
                done = true;
                await commit(input.value);
                releaseLock();
            });
            input.addEventListener('keydown', e => {
                if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
                if (e.key === 'Escape') { done = true; el.innerHTML = origHtml; releaseLock(); }
            });
        }
    }

    /** 打开 checklist 整体 JSON 编辑 modal */
    function openChecklistModal() {
        let data;
        try { data = JSON.parse(dimRawData); } catch (_) { return; }
        const current = {
            checklists: data.checklists || [],
            checklist_config: data.checklist_config || { multiple: true, exclusive_key: '' }
        };
        const modal = document.createElement('div');
        modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:9999;display:flex;align-items:center;justify-content:center';
        modal.innerHTML = `
            <div style="background:#fff;border-radius:8px;padding:24px;width:560px;max-height:80vh;overflow-y:auto;box-shadow:0 8px 32px rgba(0,0,0,.2)">
                <div style="display:flex;align-items:center;margin-bottom:16px">
                    <span style="font-size:16px;font-weight:600;flex:1">编辑 Checklist JSON</span>
                    <button id="ck-modal-close" style="background:none;border:none;font-size:18px;cursor:pointer;color:#888">✕</button>
                </div>
                <div style="font-size:12px;color:#888;margin-bottom:8px">直接编辑 checklists 数组和 checklist_config，保存后立即生效</div>
                <textarea id="ck-modal-editor" style="width:100%;height:320px;font-family:monospace;font-size:13px;border:1px solid #ddd;border-radius:4px;padding:8px;box-sizing:border-box;resize:vertical">${escHtml(JSON.stringify(current, null, 2))}</textarea>
                <div id="ck-modal-err" style="color:#e44;font-size:12px;margin-top:6px;display:none"></div>
                <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:12px">
                    <button id="ck-modal-cancel" class="ghost-btn">取消</button>
                    <button id="ck-modal-save" style="background:#0a64f0;color:#fff;border:none;border-radius:4px;padding:6px 18px;cursor:pointer;font-size:14px">保存</button>
                </div>
            </div>`;
        document.body.appendChild(modal);
        const editor = modal.querySelector('#ck-modal-editor');
        const errEl  = modal.querySelector('#ck-modal-err');
        const close  = () => document.body.removeChild(modal);
        modal.querySelector('#ck-modal-close').addEventListener('click', close);
        modal.querySelector('#ck-modal-cancel').addEventListener('click', close);
        modal.querySelector('#ck-modal-save').addEventListener('click', () => {
            let parsed;
            try { parsed = JSON.parse(editor.value); }
            catch (e) { errEl.textContent = 'JSON 格式错误：' + e.message; errEl.style.display = ''; return; }
            if (!Array.isArray(parsed.checklists)) { errEl.textContent = '缺少 checklists 数组'; errEl.style.display = ''; return; }
            for (const item of parsed.checklists) {
                if (!item.key || !item.label) { errEl.textContent = '每项必须包含 key 和 label'; errEl.style.display = ''; return; }
            }
            patchDimData(d => {
                d.checklists = parsed.checklists;
                if (parsed.checklist_config) d.checklist_config = parsed.checklist_config;
                renderDimCards(d);
            });
            close();
        });
        modal.addEventListener('click', e => { if (e.target === modal) close(); });
        setTimeout(() => editor.focus(), 30);
    }

    /** 打开单条 checklist 选项编辑 modal（新增 idx=-1，编辑 idx>=0） */
    function openChecklistItemModal(item, idx) {
        let data;
        try { data = JSON.parse(dimRawData); } catch (_) { return; }
        const isNew = idx < 0;
        const cur = item || { key: '', label: '', definition: '', exclusive: false };
        const modal = document.createElement('div');
        modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:9999;display:flex;align-items:center;justify-content:center';
        modal.innerHTML = `
            <div style="background:#fff;border-radius:8px;padding:24px;width:420px;box-shadow:0 8px 32px rgba(0,0,0,.2)">
                <div style="display:flex;align-items:center;margin-bottom:16px">
                    <span style="font-size:15px;font-weight:600;flex:1">${isNew ? '添加 Checklist 选项' : '编辑 Checklist 选项'}</span>
                    <button id="cki-close" style="background:none;border:none;font-size:18px;cursor:pointer;color:#888">✕</button>
                </div>
                <label style="font-size:13px;color:#555">Key（英文标识）</label>
                <input id="cki-key" value="${escHtml(cur.key)}" style="width:100%;margin:4px 0 12px;padding:6px 8px;border:1px solid #ddd;border-radius:4px;font-size:13px;box-sizing:border-box" placeholder="如 action_issue" />
                <label style="font-size:13px;color:#555">Label（显示名称）</label>
                <input id="cki-label" value="${escHtml(cur.label)}" style="width:100%;margin:4px 0 12px;padding:6px 8px;border:1px solid #ddd;border-radius:4px;font-size:13px;box-sizing:border-box" placeholder="如 动作有问题" />
                <label style="font-size:13px;color:#555">Definition（悬浮说明，可选）</label>
                <textarea id="cki-def" style="width:100%;margin:4px 0 12px;padding:6px 8px;border:1px solid #ddd;border-radius:4px;font-size:13px;box-sizing:border-box;height:72px;resize:vertical" placeholder="详细说明...">${escHtml(cur.definition || '')}</textarea>
                <label style="display:flex;align-items:center;gap:6px;font-size:13px;color:#555;margin-bottom:16px">
                    <input id="cki-exclusive" type="checkbox" ${cur.exclusive ? 'checked' : ''} />
                    互斥项（勾选后自动取消其他选项）
                </label>
                <div id="cki-err" style="color:#e44;font-size:12px;margin-bottom:8px;display:none"></div>
                <div style="display:flex;justify-content:flex-end;gap:8px">
                    <button id="cki-cancel" class="ghost-btn">取消</button>
                    <button id="cki-save" style="background:#0a64f0;color:#fff;border:none;border-radius:4px;padding:6px 18px;cursor:pointer;font-size:14px">保存</button>
                </div>
            </div>`;
        document.body.appendChild(modal);
        const errEl = modal.querySelector('#cki-err');
        const close = () => document.body.removeChild(modal);
        modal.querySelector('#cki-close').addEventListener('click', close);
        modal.querySelector('#cki-cancel').addEventListener('click', close);
        modal.querySelector('#cki-save').addEventListener('click', () => {
            const key   = modal.querySelector('#cki-key').value.trim();
            const label = modal.querySelector('#cki-label').value.trim();
            const def   = modal.querySelector('#cki-def').value.trim();
            const excl  = modal.querySelector('#cki-exclusive').checked;
            if (!key)   { errEl.textContent = 'Key 不能为空'; errEl.style.display = ''; return; }
            if (!label) { errEl.textContent = 'Label 不能为空'; errEl.style.display = ''; return; }
            const newItem = { key, label };
            if (def)  newItem.definition = def;
            if (excl) newItem.exclusive  = true;
            patchDimData(d => {
                if (!Array.isArray(d.checklists)) d.checklists = [];
                if (isNew) {
                    d.checklists.push(newItem);
                } else {
                    d.checklists[idx] = newItem;
                }
                // 如果有互斥项，自动更新 checklist_config.exclusive_key
                if (excl) {
                    d.checklist_config = d.checklist_config || { multiple: true };
                    d.checklist_config.exclusive_key = key;
                }
                renderDimCards(d);
            });
            close();
        });
        modal.addEventListener('click', e => { if (e.target === modal) close(); });
        setTimeout(() => modal.querySelector('#cki-key').focus(), 30);
    }

    // ── 原 bindCardEdit 结束标记（勿删）──
    function _bindCardEditEnd() {}

    /** 拖拽排序：绑定 dim-card 的 drag & drop 事件 */
    function _bindDimDragSort() {
        const grid = dimView.querySelector('.dim-cards-grid');
        if (!grid) return;
        let dragSrcIdx = -1;

        grid.querySelectorAll('.dim-card-draggable').forEach(card => {
            card.addEventListener('dragstart', e => {
                dragSrcIdx = +card.dataset.dim;
                card.classList.add('dim-card-dragging');
                e.dataTransfer.effectAllowed = 'move';
                e.dataTransfer.setData('text/plain', dragSrcIdx);
            });
            card.addEventListener('dragend', () => {
                card.classList.remove('dim-card-dragging');
                grid.querySelectorAll('.dim-card').forEach(c => c.classList.remove('dim-card-drag-over'));
            });
            card.addEventListener('dragover', e => {
                e.preventDefault();
                e.dataTransfer.dropEffect = 'move';
                const targetIdx = +card.dataset.dim;
                if (targetIdx !== dragSrcIdx) {
                    grid.querySelectorAll('.dim-card').forEach(c => c.classList.remove('dim-card-drag-over'));
                    card.classList.add('dim-card-drag-over');
                }
            });
            card.addEventListener('dragleave', () => {
                card.classList.remove('dim-card-drag-over');
            });
            card.addEventListener('drop', e => {
                e.preventDefault();
                const targetIdx = +card.dataset.dim;
                if (targetIdx === dragSrcIdx) return;
                patchDimData(data => {
                    const dims = data.dimensions;
                    const [moved] = dims.splice(dragSrcIdx, 1);
                    dims.splice(targetIdx, 0, moved);
                    renderDimCards(data);
                });
            });
        });
    }

    /** 等级列左右拖拽排序：绑定每张卡片内 dim-level 的 drag & drop 事件
     *  @param {Element} [singleCard] 传入则只绑定该卡片，否则绑定所有卡片
     */
    function _bindLevelDragSort(singleCard) {
        const cards = singleCard ? [singleCard] : Array.from(dimView.querySelectorAll('.dim-card'));
        cards.forEach(card => {
            const dimIdx = +card.dataset.dim;
            const levelsContainer = card.querySelector('.dim-card-levels');
            if (!levelsContainer) return;

            let dragSrcLvIdx = -1;

            levelsContainer.querySelectorAll('.dim-level[draggable="true"]').forEach(lvEl => {
                lvEl.addEventListener('dragstart', e => {
                    // 如果是从内联编辑输入框触发，忽略
                    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
                        e.preventDefault();
                        return;
                    }
                    dragSrcLvIdx = +lvEl.dataset.lv;
                    lvEl.classList.add('dim-lv-dragging');
                    e.dataTransfer.effectAllowed = 'move';
                    e.dataTransfer.setData('text/plain', dragSrcLvIdx);
                    // 阻止冒泡，防止触发卡片的 dragstart
                    e.stopPropagation();
                });

                lvEl.addEventListener('dragend', () => {
                    lvEl.classList.remove('dim-lv-dragging');
                    levelsContainer.querySelectorAll('.dim-level').forEach(el => {
                        el.classList.remove('dim-lv-drag-over-left', 'dim-lv-drag-over-right');
                    });
                    dragSrcLvIdx = -1;
                });

                lvEl.addEventListener('dragover', e => {
                    e.preventDefault();
                    e.stopPropagation();
                    e.dataTransfer.dropEffect = 'move';
                    const targetLvIdx = +lvEl.dataset.lv;
                    if (targetLvIdx === dragSrcLvIdx) return;
                    levelsContainer.querySelectorAll('.dim-level').forEach(el => {
                        el.classList.remove('dim-lv-drag-over-left', 'dim-lv-drag-over-right');
                    });
                    // 判断鼠标在目标列的左半还是右半，决定插入方向
                    const rect = lvEl.getBoundingClientRect();
                    const midX = rect.left + rect.width / 2;
                    if (e.clientX < midX) {
                        lvEl.classList.add('dim-lv-drag-over-left');
                    } else {
                        lvEl.classList.add('dim-lv-drag-over-right');
                    }
                });

                lvEl.addEventListener('dragleave', () => {
                    lvEl.classList.remove('dim-lv-drag-over-left', 'dim-lv-drag-over-right');
                });

                lvEl.addEventListener('drop', e => {
                    e.preventDefault();
                    e.stopPropagation();
                    const targetLvIdx = +lvEl.dataset.lv;
                    if (targetLvIdx === dragSrcLvIdx) return;

                    // 判断插入到目标左侧还是右侧
                    const rect = lvEl.getBoundingClientRect();
                    const midX = rect.left + rect.width / 2;
                    const insertBefore = e.clientX < midX;

                    patchDimData(data => {
                        const levels = data.dimensions[dimIdx].levels;
                        // 取出被拖拽的等级
                        const [moved] = levels.splice(dragSrcLvIdx, 1);
                        // 重新计算插入位置（splice 后索引可能偏移）
                        let insertIdx = targetLvIdx;
                        if (dragSrcLvIdx < targetLvIdx) insertIdx--;
                        if (!insertBefore) insertIdx++;
                        insertIdx = Math.max(0, Math.min(insertIdx, levels.length));
                        levels.splice(insertIdx, 0, moved);

                        // 拖拽后按从左到右降序重新分配 score（最左边最高分）
                        const scores = levels.map(l => +l.score || 0).slice().sort((a, b) => b - a);
                        levels.forEach((l, i) => { l.score = scores[i]; });

                        data.dimensions[dimIdx].levels = levels;
                        refreshCard(dimIdx, data);
                    });
                });
            });
        });
    }

    /** 内联编辑卡片字段（维度名/说明/level标签/level描述） */
    function startCardFieldEdit(el) {
        if (el.querySelector('input,textarea')) return;
        const dimIdx  = +el.dataset.dim;
        const lvIdx   = el.dataset.lv !== undefined ? +el.dataset.lv : -1;
        const field   = el.dataset.field;
        const isMultiline = (field === 'definition' || field === 'description');

        let currentVal = '';
        try {
            const data = JSON.parse(dimRawData || '{}');
            if (lvIdx >= 0) {
                currentVal = (data.dimensions[dimIdx].levels[lvIdx][field]) || '';
            } else {
                currentVal = (data.dimensions[dimIdx][field]) || '';
            }
        } catch (_) {}

        const origHtml = el.innerHTML;

        if (isMultiline) {
            const ta = document.createElement('textarea');
            ta.className = 'dim-card-inline-input dim-card-inline-textarea';
            ta.value = currentVal;
            ta.rows = 3;
            el.innerHTML = '';
            el.appendChild(ta);
            ta.focus();
            ta.select();

            async function commitTa() {
                const newVal = ta.value.trim();
                if (newVal) {
                    el.classList.remove('dim-card-placeholder');
                    el.innerHTML = escHtml(newVal);
                } else {
                    el.classList.add('dim-card-placeholder');
                    el.innerHTML = escHtml('点击添加维度说明');
                }
                await saveCardField(dimIdx, lvIdx, field, newVal);
            }
            ta.addEventListener('blur', commitTa);
            ta.addEventListener('keydown', e => {
                if (e.key === 'Escape') { el.innerHTML = origHtml; ta.removeEventListener('blur', commitTa); }
            });
        } else {
            const input = document.createElement('input');
            input.type = 'text';
            input.className = 'dim-card-inline-input';
            input.value = currentVal;
            el.innerHTML = '';
            el.appendChild(input);
            input.focus();
            input.select();

            async function commitIn() {
                const newVal = input.value.trim();
                const placeholders = { key: '点击填写维度名', label: '点击填写标签', description: '点击填写描述' };
                if (newVal) {
                    el.classList.remove('dim-card-placeholder');
                    el.innerHTML = escHtml(newVal);
                } else {
                    el.classList.add('dim-card-placeholder');
                    el.innerHTML = escHtml(placeholders[field] || '');
                }
                await saveCardField(dimIdx, lvIdx, field, newVal);
            }
            input.addEventListener('blur', commitIn);
            input.addEventListener('keydown', e => {
                if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
                if (e.key === 'Escape') { el.innerHTML = origHtml; input.removeEventListener('blur', commitIn); }
            });
        }
    }

    /** 保存单个字段到后端，同步更新 dimRawData */
    async function saveCardField(dimIdx, lvIdx, field, newVal) {
        if (!dimRawData) return;
        let data;
        try { data = JSON.parse(dimRawData); } catch (_) { return; }
        if (lvIdx >= 0) {
            data.dimensions[dimIdx].levels[lvIdx][field] = newVal;
        } else {
            data.dimensions[dimIdx][field] = newVal;
        }
        await persistDimData(data);
    }

    /** 修改内存数据并保存（传入 mutator 函数，mutator 直接修改 data 对象） */
    function patchDimData(mutator) {
        if (!dimRawData) return;
        let data;
        try { data = JSON.parse(dimRawData); } catch (_) { return; }
        mutator(data);
        persistDimData(data);
    }

    /** 将 data 序列化、保存到后端，并更新 dimRawData */
    async function persistDimData(data) {
        const newRaw = JSON.stringify(data, null, 2);
        try {
            const r = await adminFetch(`/api/configs/${encodeURIComponent(dimCurrentName)}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: newRaw,
            });
            if (r.status === 401) return;
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) { showToast('❌ ' + (j.error || '保存失败'), 'err'); return; }
            dimRawData = newRaw;
            showToast('✅ 已保存', 'ok');
        } catch (e) {
            showToast('❌ 网络错误：' + e.message, 'err');
        }
    }

    /** 重新渲染单张卡片（不刷新整个视图，避免丢失焦点） */
    function refreshCard(dimIdx, data) {
        const card = dimView.querySelector(`.dim-card[data-dim="${dimIdx}"]`);
        if (!card) return;
        const newHtml = renderDimCardHtml(data.dimensions[dimIdx], dimIdx, data.dimensions.length, true);
        const tmp = document.createElement('div');
        tmp.innerHTML = newHtml;
        const newCard = tmp.firstElementChild;
        card.replaceWith(newCard);
        // 重新绑定该卡片内的事件
        newCard.querySelectorAll('.dim-card-editable').forEach(el => {
            el.addEventListener('click', () => startCardFieldEdit(el));
        });
        newCard.querySelectorAll('.dim-level-stars-edit').forEach(el => {
            el.addEventListener('click', (e) => {
                const dIdx = +el.dataset.dim;
                const lIdx = +el.dataset.lv;
                const rect = el.getBoundingClientRect();
                const relX = e.clientX - rect.left;
                const starW = rect.width / (el.textContent.length || 1);
                const clicked = Math.ceil(relX / starW);
                patchDimData(d2 => {
                    d2.dimensions[dIdx].levels[lIdx].score = clicked;
                    refreshCard(dIdx, d2);
                });
            });
        });
        newCard.querySelectorAll('.dim-del-lv-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                patchDimData(d2 => {
                    const dIdx = +btn.dataset.dim;
                    d2.dimensions[dIdx].levels.splice(+btn.dataset.lv, 1);
                    // 删除后重新按降序连续分配 score（1~N）
                    const lvs = d2.dimensions[dIdx].levels;
                    const n = lvs.length;
                    lvs.forEach((l, i) => { l.score = n - i; });
                    refreshCard(dIdx, d2);
                });
            });
        });
        newCard.querySelectorAll('.dim-add-lv-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                patchDimData(d2 => {
                    const dIdx = +btn.dataset.dim;
                    const lvs = d2.dimensions[dIdx].levels || [];
                    // 追加新等级，然后按降序重新分配 score（1~N 连续，最左最高）
                    lvs.push({ score: 0, label: '新等级', description: '' });
                    const n = lvs.length;
                    lvs.forEach((l, i) => { l.score = n - i; });
                    d2.dimensions[dIdx].levels = lvs;
                    refreshCard(dIdx, d2);
                });
            });
        });
        newCard.querySelectorAll('.dim-del-dim-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                patchDimData(d2 => {
                    d2.dimensions.splice(+btn.dataset.dim, 1);
                    renderDimCards(d2);
                });
            });
        });
        // 重新绑定该卡片的等级拖拽排序
        _bindLevelDragSort(newCard);
    }

    // ── 顶部 meta 行内联编辑（task / tag 字段） ──
    function bindMetaInlineEdit() {
        if (!isLoggedIn()) return;
        dimView.querySelectorAll('.dim-meta-editable').forEach(span => {
            span.addEventListener('click', () => startMetaEdit(span));
        });
    }

    function startMetaEdit(span) {
        if (span.querySelector('input')) return; // 已在编辑中
        const field = span.dataset.field;
        const currentVal = (() => {
            try { return JSON.parse(dimRawData || '{}')[field] || ''; } catch (_) { return ''; }
        })();
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'dim-meta-inline-input';
        input.value = currentVal;
        input.placeholder = field === 'tag' ? '例如 test1 / 终评' : field === 'testSourceUrl' ? 'https://your-cdn.com/test-source.zip' : '请输入评测任务名称';
        span.innerHTML = '';
        span.appendChild(input);
        input.focus();
        input.select();

        async function commit() {
            const newVal = input.value.trim();
            // 还原显示
            span.innerHTML = escHtml(newVal || '（未填写，点击添加）');
            if (!dimRawData) return;
            let obj;
            try { obj = JSON.parse(dimRawData); } catch (_) { return; }
            if (obj[field] === newVal) return; // 无变化
            obj[field] = newVal;
            const newRaw = JSON.stringify(obj, null, 2);
            try {
                const r = await adminFetch(`/api/configs/${encodeURIComponent(dimCurrentName)}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: newRaw,
                });
                if (r.status === 401) return;
                const j = await r.json().catch(() => ({}));
                if (!r.ok || !j.ok) { showToast('❌ ' + (j.error || '保存失败'), 'err'); return; }
                dimRawData = newRaw;
                showToast(`✅ 已更新${field === 'tag' ? '备注 tag' : field === 'testSourceUrl' ? '测试源 URL' : '评测任务'}`, 'ok');
                loadConfigList(); // 刷新侧边栏（任务名可能显示在侧边栏）
            } catch (e) {
                showToast('❌ 网络错误：' + e.message, 'err');
            }
        }

        input.addEventListener('blur', commit);
        input.addEventListener('keydown', e => {
            if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
            if (e.key === 'Escape') {
                // 取消：还原原始值
                span.innerHTML = escHtml(currentVal || '（未填写，点击添加）');
                input.removeEventListener('blur', commit);
                input.removeEventListener('blur', commit);
            }
        });
    }

    // ── 进入编辑模式 ──
    function enterDimEdit() {
        dimEditing = true;
        dimEditorSection.style.display = 'flex';
        dimView.style.display = 'none';
        dimEditBtn.style.display = 'none';
        dimFormatBtn.style.display = '';
        dimSaveBtn.style.display = '';
        dimCancelEditBtn.style.display = '';
        dimErr.style.display = 'none';
        dimErr.textContent = '';
        try {
            const obj = JSON.parse(dimRawData || '{}');
            dimEditor.value = JSON.stringify(obj, null, 2);
        } catch (_) {
            dimEditor.value = dimRawData || '';
        }
        setTimeout(() => dimEditor.focus(), 30);
    }

    function exitDimEdit() {
        dimEditing = false;
        dimEditorSection.style.display = 'none';
        dimView.style.display = '';
        dimEditBtn.style.display = isLoggedIn() ? '' : 'none';
        dimFormatBtn.style.display = 'none';
        dimSaveBtn.style.display = 'none';
        dimCancelEditBtn.style.display = 'none';
        dimErr.style.display = 'none';
    }

    // ── 保存配置 ──
    async function saveDimensions() {
        const raw = (dimEditor.value || '').trim();
        if (!raw) { dimErr.textContent = '内容不能为空'; dimErr.style.display = ''; return; }
        let parsed;
        try { parsed = JSON.parse(raw); }
        catch (e) { dimErr.textContent = 'JSON 格式错误：' + e.message; dimErr.style.display = ''; return; }
        if (!parsed.dimensions || !Array.isArray(parsed.dimensions) || parsed.dimensions.length === 0) {
            dimErr.textContent = '缺少 dimensions 数组或为空';
            dimErr.style.display = '';
            return;
        }
        // 文件名：优先用当前选中，否则用 type 字段
        const saveName = dimCurrentName || (parsed.type ? parsed.type.replace(/\s+/g, '_') : 'new_config');
        dimSaveBtn.disabled = true;
        try {
            const r = await adminFetch(`/api/configs/${encodeURIComponent(saveName)}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: raw,
            });
            if (r.status === 401) return;
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) { dimErr.textContent = j.error || '保存失败'; dimErr.style.display = ''; return; }
            dimRawData = raw;
            dimCurrentName = saveName;
            exitDimEdit();
            renderDimCards(parsed);
            showToast(`✅ ${j.message || '已保存'}`, 'ok');
            loadConfigList(); // 刷新侧边栏
        } catch (e) {
            dimErr.textContent = '网络错误：' + e.message;
            dimErr.style.display = '';
        } finally {
            dimSaveBtn.disabled = false;
        }
    }

    // ── 事件绑定 ──
    if (dimPageBtn)       dimPageBtn.addEventListener('click', showDimPage);
    if (dimPageCloseBtn)  dimPageCloseBtn.addEventListener('click', hideDimPage);
    if (dimEditBtn)       dimEditBtn.addEventListener('click', enterDimEdit);
    if (dimCancelEditBtn) dimCancelEditBtn.addEventListener('click', exitDimEdit);
    if (dimSaveBtn)       dimSaveBtn.addEventListener('click', saveDimensions);
    if (dimAddBtn)        dimAddBtn.addEventListener('click', promptNewConfig);
    if (dimFormatBtn) {
        dimFormatBtn.addEventListener('click', () => {
            try {
                dimEditor.value = JSON.stringify(JSON.parse(dimEditor.value), null, 2);
                dimErr.style.display = 'none';
            } catch (e) {
                dimErr.textContent = 'JSON 格式错误：' + e.message;
                dimErr.style.display = '';
            }
        });
    }
    if (dimEditor) {
        dimEditor.addEventListener('keydown', (e) => {
            if ((e.ctrlKey || e.metaKey) && e.key === 's') {
                e.preventDefault();
                saveDimensions();
            }
        });
    }

    // ── 拖拽上传 JSON（整个左侧区域 + 底部拖拽区，拖入=新增配置） ──
    const dimDropZone = $('dimDropZone');
    const dimDropSub  = $('dimDropSub');
    const dimSidebar  = $('dimSidebar');

    async function handleDroppedJson(text) {
        let parsed;
        try { parsed = JSON.parse(text); }
        catch (e) { showToast('❌ JSON 解析失败：' + e.message, 'err'); return; }
        if (!parsed.dimensions || !Array.isArray(parsed.dimensions) || parsed.dimensions.length === 0) {
            showToast('❌ 缺少 dimensions 数组或为空', 'err');
            return;
        }
        const rawText = JSON.stringify(parsed, null, 2);
        // 用 type 字段推断文件名；没有 type 则用时间戳
        const newName = parsed.type
            ? parsed.type.replace(/\s+/g, '_')
            : 'import_' + Date.now();
        dimCurrentName = newName;
        dimRawData = rawText;
        if (dimEditing) exitDimEdit();
        renderDimCards(parsed);

        if (isLoggedIn()) {
            // 管理员：直接保存到服务器，刷新左侧列表
            try {
                const r = await adminFetch(`/api/configs/${encodeURIComponent(newName)}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: rawText,
                });
                if (r.status === 401) return;
                const j = await r.json().catch(() => ({}));
                if (!r.ok || !j.ok) {
                    showToast('❌ 保存失败：' + (j.error || '未知错误'), 'err');
                    return;
                }
                showToast(`✅ 已导入并保存「${parsed.type || newName}」，共 ${parsed.dimensions.length} 个维度`, 'ok');
                loadConfigList(); // 刷新左侧列表，显示新文件名
            } catch (e) {
                showToast('❌ 网络错误：' + e.message, 'err');
            }
        } else {
            // 未登录：仅本地预览
            dimSidebarList.querySelectorAll('.dim-sidebar-item').forEach(el => el.classList.remove('is-active'));
            showToast(`👁 本地预览：${parsed.dimensions.length} 个维度（未登录，不会保存到服务器）`, 'ok');
        }
    }

    function readJsonFile(file) {
        if (!file) return;
        if (!file.name.endsWith('.json') && file.type !== 'application/json') {
            showToast('❌ 请拖入 .json 文件', 'err');
            return;
        }
        const reader = new FileReader();
        reader.onload = (ev) => handleDroppedJson(ev.target.result);
        reader.onerror = () => showToast('❌ 文件读取失败', 'err');
        reader.readAsText(file, 'utf-8');
    }

    // 顶部上传按钮（点击选择文件）
    const dimUploadInput = $('dimUploadInput');
    if (dimUploadInput) {
        dimUploadInput.addEventListener('change', () => {
            if (dimUploadInput.files[0]) {
                readJsonFile(dimUploadInput.files[0]);
                dimUploadInput.value = ''; // 允许重复选同一文件
            }
        });
    }

    // 整个评分规则页面响应拖拽（左侧+右侧大区域均可）
    // 只有拖入外部文件时才显示蓝色边框，页面内元素拖拽不触发
    function _isFileDrag(e) {
        return e.dataTransfer && Array.from(e.dataTransfer.types).includes('Files');
    }
    if (dimPage) {
        dimPage.addEventListener('dragenter', (e) => { if (!_isFileDrag(e)) return; e.preventDefault(); dimPage.classList.add('drag-over'); });
        dimPage.addEventListener('dragover',  (e) => { if (!_isFileDrag(e)) return; e.preventDefault(); dimPage.classList.add('drag-over'); });
        dimPage.addEventListener('dragleave', (e) => {
            if (!dimPage.contains(e.relatedTarget)) dimPage.classList.remove('drag-over');
        });
        dimPage.addEventListener('drop', (e) => {
            e.preventDefault();
            dimPage.classList.remove('drag-over');
            if (e.dataTransfer.files && e.dataTransfer.files[0]) readJsonFile(e.dataTransfer.files[0]);
        });
    }

    // 底部拖拽区点击 = 文件选择器
    if (dimDropZone) {
        dimDropZone.addEventListener('click', () => {
            const input = document.createElement('input');
            input.type = 'file';
            input.accept = '.json,application/json';
            input.onchange = () => readJsonFile(input.files[0]);
            input.click();
        });
    }



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
    // 显示文案统一走顶部 MODE_LABELS / modeLabel()，避免这里再定义局部 labelMap
    // 造成 multi_dim / quality_slide 等新增模式漏译（图上表现为英文原文透出）。
    // 特殊值 off 走 labelMap 覆盖："关闭"。
    function renderModePill(mode) {
        const m = (mode || 'subjective').toLowerCase();
        const label = (m === 'off') ? '关闭' : modeLabel(m);
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

    // ── Hash 工具函数 ──
    // 解析 #rules 或 #rules/<configName>，返回 { isRules, configName }
    function _parseHash() {
        const h = decodeURIComponent(location.hash || '');
        if (h === '#rules') return { isRules: true, configName: null };
        const m = h.match(/^#rules\/(.+)$/);
        if (m) return { isRules: true, configName: m[1] };
        return { isRules: false, configName: null };
    }
    function _getHashConfig() {
        return _parseHash().configName;
    }

    // ────────── 启动 ──────────
    (async function init() {
        await fetchStatus();
        await fetchAuthInfo();   // 拉取鉴权状态，更新顶栏登录按钮和管理按钮的锁定态
        await fetchList();
        updateAuthUi();          // 列表渲染后再刷一次（同步行内删除按钮的锁定态）
        // 表头是静态的，初始化一次即可；列宽的持久化由 localStorage 维护
        initColumnResizing(document.getElementById('filesTable'));
        // 检测 URL hash，支持直达链接：#rules 或 #rules/<configName>
        if (_parseHash().isRules) showDimPage(true);
    })();
})();
