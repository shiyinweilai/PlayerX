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
                         adminLoginBtn.textContent = '已登录（点击退出）';
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
        // 「手动上传」按钮仅在管理员登录后可见
        const manualUploadLabel = $('manualUploadLabel');
        if (manualUploadLabel) {
            manualUploadLabel.style.display = (auth.enabled && logged) ? '' : 'none';
        }
        // 「分析选中」按钮仅在管理员登录后可用
        const analyzeSelBtn = $('analyzeSelBtn');
        if (analyzeSelBtn) {
            if (auth.enabled && !logged) {
                analyzeSelBtn.classList.add('lock-disabled');
                analyzeSelBtn.title = '需要管理员登录后才能操作';
            } else {
                analyzeSelBtn.classList.remove('lock-disabled');
                analyzeSelBtn.title = '对选中的文件执行盲评分析（仅管理员）';
            }
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

    // ── 模块路由（sidebar 导航） ──
    const MODULES = {
        dashboard:{ section: () => $('pageDashboard'), hash: '#dashboard' },
        files:    { section: () => $('pageFiles'),hash: '#files' },
        tasks:    { section: () => dimPage,         hash: '#tasks' },
        models:   { section: () => $('pageModels'),   hash: '#models' },
        analyze:  { section: () => $('pageAnalyze'),  hash: '#analyze' },
        archive:  { section: () => $('pageArchive'),  hash: '#archive' },
     settings: { section: () => $('pageSettings'), hash: '#settings' },
    };
    let currentModule = 'files';

    function switchModule(name, skipHashUpdate) {
        if (!MODULES[name]) name = 'files';
        // 隐藏所有 section
        Object.values(MODULES).forEach(m => { const el = m.section(); if (el) el.hidden = true; });
        // 显示目标
        const target = MODULES[name].section();
        if (target) target.hidden = false;
        // sidebar 高亮
        document.querySelectorAll('.nav-item').forEach(el => {
            el.classList.toggle('active', el.dataset.module === name);
        });
        // hash
        if (!skipHashUpdate) history.replaceState(null, '', MODULES[name].hash);
        currentModule = name;
        // 各模块进入时的初始化
        if (name === 'tasks') { dimPageOpen = true; loadConfigList(); }
        else { dimPageOpen = false; }
     if (name === 'archive') { loadArchiveFolders(); }
        if (name === 'models') { renderModelsPage(); }
        if (name === 'tasks' && window.PXTasks && typeof window.PXTasks.onShow === 'function') {
   window.PXTasks.onShow();
        }
    }

        // ═══════════════════════════════════════════════════════════════
    //模型管理模块
    // ═══════════════════════════════════════════════════════════════
    let modelsData = [];
    let modelsScope = 'all'; // 'all' | 'personal' | 'team'

    async function renderModelsPage() {
        const container = document.querySelector('.models-page');
        if (!container) return;
        container.innerHTML = '<div style="padding:40px;color:#64748b;text-align:center">加载中...</div>';
        try {
            const r = await adminFetch('/api/models');
            const j = await r.json();
            if (!j.ok) throw new Error(j.error || 'Failed');
            modelsData = j.sources || [];
        } catch (e) {
            container.innerHTML = `<div style="padding:40px;color:#ef4444;text-align:center">加载失败: ${e.message}</div>`;
            return;
        }
        renderModelsContent(container);
    }

    function renderModelsContent(container) {
        //过滤scope
        const filtered = modelsScope === 'all' ? modelsData : modelsData.filter(s => (s.scope || 'personal') === modelsScope);

        const sourcesHtml = filtered.map((src) => {
            const realIdx = modelsData.indexOf(src);
            const scope = src.scope || 'personal';
            const ownerName = src.owner || '个人';
 const scopeLabel = scope === 'team' ? '团队' : `${ownerName}`;
            const modelsHtml = (src.models || []).map(m =>
                `<span class="mdl-tag">${escHtml(m)}<button class="mdl-tag-rm" data-src="${realIdx}" data-model="${escHtml(m)}">&times;</button></span>`
            ).join('');
     return `
 <div class="mdl-source-card" data-idx="${realIdx}">
<div class="mdl-source-header">
      <input class="mdl-source-name-input" data-idx="${realIdx}" value="${escHtml(src.name)}" title="点击编辑名称" />
     <span class="mdl-source-path">${escHtml(src.path)}</span>
     <span class="mdl-source-scope ${scope}">${scopeLabel}</span>
    <div class="mdl-source-actions">
 <button class="mdl-btn mdl-btn-del" data-idx="${realIdx}" title="删除此源目录"><span class="mdl-btn-shadow"></span><span class="mdl-btn-edge mdl-btn-edge-red"></span><span class="mdl-btn-front mdl-btn-front-red">删除</span></button>
      </div>
   </div>
       <div class="mdl-models-wrap" data-idx="${realIdx}" style="cursor:pointer">
          <svg class="inline-icon mdl-wrap-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
  ${modelsHtml || '<span class="mdl-empty">点击展开</span>'}
 </div>
                <div class="mdl-tree-panel" data-idx="${realIdx}" style="display:none"></div>
            </div>`;
        }).join('');

        container.innerHTML = `
            <div class="mdl-header-row">
                <div>
            <h2 class="mdl-page-title"><svg class="inline-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/><line x1="12" y1="11" x2="12" y2="17"/><line x1="9" y1="14" x2="15" y2="14"/></svg> 模型源目录管理</h2>
                    <p class="mdl-page-desc">管理多个源目录，勾选即添加模型。支持个人/团队分组与多级子目录展开。</p>
                </div>
                <div class="mdl-scope-tabs">
                    <button class="mdl-scope-tab ${modelsScope==='all'?'active':''}" data-scope="all">全部</button>
        <button class="mdl-scope-tab ${modelsScope==='personal'?'active':''}" data-scope="personal"><svg class="inline-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg> 个人</button>
       <button class="mdl-scope-tab ${modelsScope==='team'?'active':''}" data-scope="team"><svg class="inline-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg> 团队</button>
                </div>
            </div>
            <div class="mdl-add-row">
                <input class="mdl-add-name" placeholder="测试集名称" />
                <input class="mdl-add-path" placeholder="源目录路径（如：/data/models/daxin）" />
                <input class="mdl-add-owner" placeholder="归属人（如：张三）" />
                <select class="mdl-add-scope">
        <option value="personal">个人</option>
     <option value="team">团队</option>
                </select>
       <button class="mdl-btn mdl-btn-add"><span class="mdl-btn-blob"></span><span class="mdl-btn-inner">＋ 添加</span></button>
            </div>
            <div class="mdl-sources-list">${sourcesHtml || '<div class="mdl-empty-page">暂无源目录，请在上方添加</div>'}</div>`;

        bindModelsEvents(container);
    }

    //保存模型列表到后端（即时保存）
    async function saveModels(idx) {
        const src = modelsData[idx];
        try {
            await adminFetch(`/api/models/${src.id}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ models: src.models })
            });
        } catch (e) { console.error('模型保存失败', e); }
    }

    // 渲染目录树节点
    function renderTreeNode(dirs, parentPath, idx, existing, dirsInfo) {
        return dirs.map((d, i) => {
            const fullPath = parentPath + '/' + d;
   const checked = existing.has(d) || existing.has(fullPath) ? 'checked' : '';
 const hasChildren = dirsInfo ? dirsInfo[i].hasChildren : true;
return `<div class="mdl-tree-node">
         <label class="mdl-tree-item">
     <input type="checkbox" class="mdl-tree-cb" value="${escHtml(d)}" data-full="${escHtml(fullPath)}" ${checked}>
             <span class="mdl-tree-name">${escHtml(d)}</span>
          </label>
    ${hasChildren ? `<button class="mdl-tree-expand" data-path="${escHtml(fullPath)}" title="展开子目录">▶</button>` : ''}
   <div class="mdl-tree-children" data-parent="${escHtml(fullPath)}" style="display:none"></div>
            </div>`;
        }).join('');
    }

    function bindModelsEvents(container) {
        // scope tabs切换
        container.querySelectorAll('.mdl-scope-tab').forEach(tab => {
            tab.addEventListener('click', () => {
                modelsScope = tab.dataset.scope;
                renderModelsContent(container);
            });
        });

        // 添加源目录
        const addBtn = container.querySelector('.mdl-btn-add');
        if (addBtn) addBtn.addEventListener('click', async () => {
            const name = container.querySelector('.mdl-add-name').value.trim() || `测试集${modelsData.length + 1}`;
            const dirPath = container.querySelector('.mdl-add-path').value.trim() || '';
            const scope = container.querySelector('.mdl-add-scope').value;
  const owner = container.querySelector('.mdl-add-owner').value.trim();
            try {
                const r = await adminFetch('/api/models', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ name, path: dirPath, scope, owner })
                });
                const j = await r.json();
                if (!j.ok) throw new Error(j.error);
                modelsData.push(j.source);
                renderModelsContent(container);
            } catch (e) { alert('添加失败: ' + e.message); }
        });

 // 原地编辑测试集名称
container.querySelectorAll('.mdl-source-name-input').forEach(input => {
            let saving = false;
            const save = async () => {
      if (saving) return;
        const idx = +input.dataset.idx;
            const src = modelsData[idx];
                const newName = input.value.trim();
    if (!newName || newName === src.name) { input.value = src.name; return; }
   saving = true;
     try {
     const r = await adminFetch(`/api/models/${src.id}`, {
           method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: newName })
        });
         const j = await r.json();
                    if (!j.ok) throw new Error(j.error);
              modelsData[idx].name = newName;
          } catch (e) { alert('修改名称失败: ' + e.message); input.value = src.name; }
      saving = false;
            };
       input.addEventListener('blur', save);
            input.addEventListener('keydown', (e) => {
     if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
    if (e.key === 'Escape') { input.value = modelsData[+input.dataset.idx].name; input.blur(); }
  });
        });

        // 删除源目录
        container.querySelectorAll('.mdl-btn-del').forEach(btn => {
            btn.addEventListener('click', async () => {
                const idx = +btn.dataset.idx;
         const src = modelsData[idx];
    try {
    const r = await adminFetch(`/api/models/${src.id}`, { method: 'DELETE' });
                    const j = await r.json();
                    if (!j.ok) throw new Error(j.error);
                    modelsData.splice(idx, 1);
                    renderModelsContent(container);
                } catch (e) { alert('删除失败: ' + e.message); }
            });
        });

// 点击模型区域展开树
 container.querySelectorAll('.mdl-models-wrap').forEach(wrap => {
         wrap.addEventListener('click', async (e) => {
      // 如果点击的是标签删除按钮，不触发展开
 if (e.target.closest('.mdl-tag-rm')) return;
 const idx = +wrap.dataset.idx;
    const src = modelsData[idx];
     const panel = container.querySelector(`.mdl-tree-panel[data-idx="${idx}"]`);
 if (!panel) return;
    if (panel.style.display !== 'none') { panel.style.display = 'none'; return; }
                panel.innerHTML = '<span class="mdl-tree-loading">⏳ 扫描目录中...</span>';
 panel.style.display = 'block';
           try {
       const r = await adminFetch('/api/models/scan', {
     method: 'POST',
             headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: src.path })
   });
       const j = await r.json();
           if (!j.ok) throw new Error(j.error);
    const existing = new Set(src.models || []);
    const treeHtml = renderTreeNode(j.dirs, src.path, idx, existing, j.dirsInfo);
    panel.innerHTML = `<div class="mdl-tree-toolbar">
  <button class="mdl-tree-collapse" data-idx="${idx}" title="收起"><svg class="inline-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="18 15 12 9 6 15"/></svg> 收起</button>
    <input class="mdl-tree-filter" data-idx="${idx}" placeholder="输入关键字过滤..." />
    <label class="mdl-tree-selectall-label"><input type="checkbox" class="mdl-tree-selectall-cb" data-idx="${idx}" /> 全选</label>
    </div>
    <div class="mdl-tree-root">${treeHtml}</div>`;
         bindTreeEvents(panel, idx, container);
         // 绑定收起按钮
         panel.querySelector('.mdl-tree-collapse').addEventListener('click', () => {
panel.style.display = 'none';
         });
         // 绑定过滤框
      panel.querySelector('.mdl-tree-filter').addEventListener('input', function() {
             const keyword = this.value.trim().toLowerCase();
   panel.querySelectorAll('.mdl-tree-node').forEach(node => {
     const name = node.querySelector(':scope > .mdl-tree-item > .mdl-tree-name');
      if (!name) return;
     const match = !keyword || name.textContent.toLowerCase().includes(keyword);
         node.style.display = match ? '' : 'none';
 // 如果匹配，确保所有父节点也可见
      if (match && keyword) {
       let parent = node.parentElement;
         while (parent && !parent.classList.contains('mdl-tree-root')) {
   if (parent.classList.contains('mdl-tree-node')) parent.style.display = '';
  if (parent.classList.contains('mdl-tree-children')) parent.style.display = 'block';
     parent = parent.parentElement;
       }
         }
          });
     });
 // 绑定全选checkbox
     panel.querySelector('.mdl-tree-selectall-cb').addEventListener('change', async function() {
 const cbs = panel.querySelectorAll('.mdl-tree-cb');
   const visibleCbs = Array.from(cbs).filter(cb => cb.closest('.mdl-tree-node').style.display !== 'none');
    const isChecked = this.checked;
    const src = modelsData[idx];
    if (isChecked) {
        // 全选：将所有可见的加入
        visibleCbs.forEach(cb => { cb.checked = true; });
        const newModels = visibleCbs.map(cb => cb.value);
        src.models = [...new Set([...(src.models || []), ...newModels])];
    } else {
    // 取消全选：移除所有可见的
        const visibleVals = new Set(visibleCbs.map(cb => cb.value));
        visibleCbs.forEach(cb => { cb.checked = false; });
        src.models = (src.models || []).filter(m => !visibleVals.has(m));
    }
    await saveModels(idx);
    // 更新标签显示
    const wrap = container.querySelector(`.mdl-source-card[data-idx="${idx}"] .mdl-models-wrap`);
 if (wrap) {
      const modelsHtml = src.models.map(m =>
            `<span class="mdl-tag">${escHtml(m)}<button class="mdl-tag-rm" data-src="${idx}" data-model="${escHtml(m)}">&times;</button></span>`
        ).join('');
        wrap.innerHTML = '<svg class="inline-icon mdl-wrap-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg> ' + (modelsHtml || '<span class="mdl-empty">点击展开</span>');
        wrap.querySelectorAll('.mdl-tag-rm').forEach(btn2 => {
  btn2.addEventListener('click', async () => {
          const model2 = btn2.dataset.model;
                modelsData[idx].models = modelsData[idx].models.filter(m => m !== model2);
  await saveModels(idx);
  renderModelsContent(container);
   });
        });
    }
  });
 } catch (e) {
         panel.innerHTML = `<span style="color:#ef4444;font-size:12px">扫描失败: ${e.message}</span>`;
    }
       });
        });

        // 删除单个模型标签
        container.querySelectorAll('.mdl-tag-rm').forEach(btn => {
            btn.addEventListener('click', async () => {
                const idx = +btn.dataset.src;
                const model = btn.dataset.model;
                modelsData[idx].models = (modelsData[idx].models || []).filter(m => m !== model);
                await saveModels(idx);
                renderModelsContent(container);
            });
        });
    }

    function bindTreeEvents(panel, idx, container) {
        //勾选即时添加/移除模型
        panel.addEventListener('change', async (e) => {
            if (!e.target.classList.contains('mdl-tree-cb')) return;
            const val = e.target.value;
            const src = modelsData[idx];
            if (!src.models) src.models = [];
            if (e.target.checked) {
                if (!src.models.includes(val)) src.models.push(val);
            } else {
                src.models = src.models.filter(m => m !== val);
            }
            await saveModels(idx);
            // 更新标签显示
            const wrap = container.querySelector(`.mdl-source-card[data-idx="${idx}"] .mdl-models-wrap`);
            if (wrap) {
                const modelsHtml = src.models.map(m =>
                    `<span class="mdl-tag">${escHtml(m)}<button class="mdl-tag-rm" data-src="${idx}" data-model="${escHtml(m)}">&times;</button></span>`
                ).join('');
                wrap.innerHTML = '<svg class="inline-icon mdl-wrap-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg> ' + (modelsHtml || '<span class="mdl-empty">点击展开</span>');
                wrap.querySelectorAll('.mdl-tag-rm').forEach(btn2 => {
                    btn2.addEventListener('click', async () => {
                        const model2 = btn2.dataset.model;
                        modelsData[idx].models = modelsData[idx].models.filter(m => m !== model2);
                        await saveModels(idx);
                        renderModelsContent(container);
                    });
                });
            }
        });

        // 展开子目录
        panel.querySelectorAll('.mdl-tree-expand').forEach(btn => {
            btn.addEventListener('click', async function() {
                const subPath = this.dataset.path;
                const childrenDiv = this.nextElementSibling;
                if (!childrenDiv) return;
                if (childrenDiv.style.display !== 'none') {
                    childrenDiv.style.display = 'none';
                    this.textContent = '▶';
                    return;
                }
                if (childrenDiv.dataset.loaded) {
                    childrenDiv.style.display = 'block';
                    this.textContent = '▼';
                    return;
                }
                this.textContent = '…';
                try {
                    const r = await adminFetch('/api/models/scan', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ path: subPath })
                    });
                    const j = await r.json();
                    if (!j.ok) throw new Error(j.error);
                    if (j.dirs.length === 0) {
                        this.textContent = '·';
                        this.disabled = true;
                        return;
                    }
  const existing = new Set(modelsData[idx].models || []);
      childrenDiv.innerHTML = renderTreeNode(j.dirs, subPath, idx, existing, j.dirsInfo);
                    childrenDiv.dataset.loaded = '1';
                    childrenDiv.style.display = 'block';
                    this.textContent = '▼';
                    // 递归绑定子级展开按钮
                    childrenDiv.querySelectorAll('.mdl-tree-expand').forEach(subBtn => {
                        subBtn.addEventListener('click', async function() {
                            const sp = this.dataset.path;
                            const cd = this.nextElementSibling;
                            if (!cd) return;
                            if (cd.style.display !== 'none') { cd.style.display = 'none'; this.textContent = '▶'; return; }
                            if (cd.dataset.loaded) { cd.style.display = 'block'; this.textContent = '▼'; return; }
                            this.textContent = '…';
                            try {
                                const r2 = await adminFetch('/api/models/scan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path: sp }) });
                                const j2 = await r2.json();
                                if (!j2.ok) throw new Error(j2.error);
         if (j2.dirs.length === 0) { this.textContent = '·'; this.disabled = true; return; }
          const ex2 = new Set(modelsData[idx].models || []);
              cd.innerHTML = renderTreeNode(j2.dirs, sp, idx, ex2, j2.dirsInfo);
                                cd.dataset.loaded = '1';
                                cd.style.display = 'block';
                                this.textContent = '▼';
                            } catch (e2) { this.textContent = '!'; }
                        });
                    });
                } catch (e) { this.textContent = '!'; }
            });
        });
    }

    // ── 页面开关（兼容旧接口，内部走模块路由） ──
    function showDimPage(skipHashUpdate) { switchModule('tasks', skipHashUpdate); }
    function hideDimPage() { switchModule('files'); exitDimEdit(); }

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
                     ${admin ? `<button class="dim-activate-btn ghost-btn" data-name="${escHtml(c.name)}" title="绑定/解绑模式"><svg class="inline-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg> 绑定</button>` : ''}
                        ${admin ? `<button class="dim-copy-btn ghost-btn" data-name="${escHtml(c.name)}" title="复制一份此配置">复制</button>` : ''}
                 ${admin ? `<button class="dim-sidebar-del ghost-btn" data-name="${escHtml(c.name)}" title="删除此配置"><svg class="inline-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg></button>` : ''}
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
        dimActiveTab = 'dims';   // 切换配置时回到「维度」Tab
        // 高亮侧边栏
        dimSidebarList.querySelectorAll('.dim-sidebar-item').forEach(el => {
            el.classList.toggle('is-active', el.dataset.name === name);
        });
        exitDimEdit();
        dimView.innerHTML = '<div class="dim-view-loading">加载中…</div>';
        dimView.style.display = '';
        // 更新 URL hash，方便分享直达链接
        if (dimPageOpen) history.replaceState(null, '', '#tasks/' + encodeURIComponent(name));
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

    // ── 自定义确认弹窗（替代 window.confirm）──
    function pxConfirm(msg, { title = '提示', confirmText = '确定', cancelText = '取消', danger = false } = {}) {
        return new Promise(resolve => {
            const overlay = document.createElement('div');
            Object.assign(overlay.style, {
                position:'fixed',top:'0',left:'0',right:'0',bottom:'0',zIndex:'10000',
                background:'rgba(0,0,0,.35)',backdropFilter:'blur(2px)',
                display:'flex',alignItems:'center',justifyContent:'center'
            });
            const box = document.createElement('div');
            Object.assign(box.style, {
                background:'#fff',borderRadius:'14px',padding:'28px 32px 22px',
                minWidth:'340px',maxWidth:'440px',boxShadow:'0 8px 40px rgba(0,0,0,.18)',
                animation:'none'
            });
            const okColor = danger ? '#ff4d4f' : '#4a9eff';
            box.innerHTML = `
                <div style="font-size:16px;font-weight:700;margin-bottom:10px;color:#222">${escHtml(title)}</div>
                <div style="font-size:14px;color:#555;line-height:1.6;margin-bottom:22px">${escHtml(msg)}</div>
                <div style="display:flex;justify-content:flex-end;gap:10px">
                    <button class="_pxCfmC" style="padding:8px 20px;border-radius:8px;font-size:14px;border:none;cursor:pointer;font-weight:500;background:#f0f0f0;color:#555">${escHtml(cancelText)}</button>
                    <button class="_pxCfmO" style="padding:8px 20px;border-radius:8px;font-size:14px;border:none;cursor:pointer;font-weight:500;background:${okColor};color:#fff">${escHtml(confirmText)}</button>
                </div>`;
            overlay.appendChild(box);
            document.body.appendChild(overlay);
            const close = (val) => { overlay.remove(); document.removeEventListener('keydown', escHandler); resolve(val); };
            box.querySelector('._pxCfmO').addEventListener('click', () => close(true));
            box.querySelector('._pxCfmC').addEventListener('click', () => close(false));
            overlay.addEventListener('click', (e) => { if (e.target === overlay) close(false); });
            const escHandler = (e) => { if (e.key === 'Escape') close(false); };
            document.addEventListener('keydown', escHandler);
            box.querySelector('._pxCfmO').focus();
        });
    }

    // ── 删除配置 ──
    async function deleteConfig(name) {
        const yes = await pxConfirm(`确定删除配置「${name}」？此操作不可恢复。`, { title: '删除配置', confirmText: '删除', danger: true });
        if (!yes) return;
        try {
            const r = await adminFetch(`/api/configs/${encodeURIComponent(name)}`, { method: 'DELETE' });
            if (r.status === 401) return;
            const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) { showToast('❌ ' + (j.error || '删除失败'), 'err'); return; }
            showToast('✅ ' + j.message, 'ok');
            if (dimCurrentName === name) {
                dimCurrentName = null;
                dimRawData = null;
                dimView.innerHTML = '<div class="dim-view-loading">请从右侧选择配置</div>';
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

    // ── 配置详情 Tab 状态 ──
    // 维度卡片 / Checklist / 测试源 三大区块改为 Tab 切换展示，
    // 避免长页从上往下滚动看不全。切换配置时重置为「维度」。
    let dimActiveTab = 'dims';

    // ── 卡片渲染 ──
    function renderDimCards(obj) {
        const admin = isLoggedIn();
        const metaItems = [];
        if (obj && obj.type)  metaItems.push(`<span class="dim-meta-item dim-meta-type"><span class="dim-meta-label">评测类型</span><span class="dim-meta-val">${escHtml(obj.type)}</span></span>`);
        // 评测任务：可内联编辑
        metaItems.push(`<span class="dim-meta-item dim-meta-task"><span class="dim-meta-label">评测任务</span><span class="dim-meta-val dim-meta-editable" data-field="task" title="点击编辑">${escHtml((obj && obj.task) || '（未填写，点击添加）')}</span></span>`);
        // 备注 tag：可内联编辑
        metaItems.push(`<span class="dim-meta-item dim-meta-tag"><span class="dim-meta-label">备注 tag</span><span class="dim-meta-val dim-meta-editable" data-field="tag" title="点击编辑">${escHtml((obj && obj.tag) || '（未填写，点击添加）')}</span></span>`);
        const metaHtml = metaItems.length ? `<div class="dim-cards-meta">${metaItems.join('<span class="dim-meta-sep">·</span>')}</div>` : '';

        // ── Tab 栏 ──
   const tabs = [
 ['dims', '维度'],
    ['checklist',  'Checklist'],
     ['testers',    '测试人'],
     ['build',      '🔨 构建'],
     ];
        const tabsHtml = `<div class="dim-tabbar">${tabs.map(([id, label]) =>
            `<button class="dim-tab${dimActiveTab === id ? ' is-active' : ''}" data-tab="${id}">${label}</button>`
        ).join('')}</div>`;

 // ── Tab 内容：只渲染当前 Tab ──
        let contentHtml = '';
        if (dimActiveTab === 'checklist') {
 contentHtml = renderChecklistPreview(obj ? obj.checklists : null, obj ? obj.checklist_config : null, admin);
     } else if (dimActiveTab === 'testers') {
   contentHtml = renderTestersSection(obj, admin);
    } else if (dimActiveTab === 'build') {
     contentHtml = renderBuildSection(obj, admin);
        } else {
            if (!obj || !Array.isArray(obj.dimensions) || obj.dimensions.length === 0) {
      contentHtml = `<div class="dim-checklist-section">
      <div class="dim-cl-header">
   <span class="dim-cl-title">维度</span>
       <span class="dim-cl-subtitle">评分维度及等级定义</span>
 </div>
   <div class="dim-cl-body">
                <div class="dim-view-loading">暂无维度配置</div>
    ${admin ? `<button class="dim-add-dim-btn">＋ 添加维度</button>` : ''}
            </div>
        </div>`;
  } else {
     const cardsHtml = obj.dimensions.map((d, idx) => renderDimCardHtml(d, idx, obj.dimensions.length, admin)).join('');
   const addDimBtn = admin ? `<button class="dim-add-dim-btn">＋ 添加维度</button>` : '';
     contentHtml = `<div class="dim-checklist-section">
        <div class="dim-cl-header">
    <span class="dim-cl-title">维度</span>
              <span class="dim-cl-subtitle">评分维度及等级定义</span>
 </div>
 <div class="dim-cl-body">
  <div class="dim-cards-grid">${cardsHtml}</div>
 <div class="dim-bottom-actions">${addDimBtn}</div>
        </div>
        </div>`;
      }
        }

        dimView.innerHTML = metaHtml + tabsHtml + contentHtml;

        // 渲染后绑定事件（延迟到 innerHTML 写入后）
        setTimeout(() => {
    bindMetaInlineEdit();
   bindDimTabs();
            if (admin) bindCardEdit(obj || { dimensions: [] });
         if (dimActiveTab === 'build' && admin) bindBuildTabEvents();
        }, 0);
    }

    /** Tab 切换绑定：切换后整体重渲染（状态保存在 dimActiveTab） */
    function bindDimTabs() {
        dimView.querySelectorAll('.dim-tab').forEach(btn => {
         btn.addEventListener('click', () => {
       const tab = btn.dataset.tab;
         if (!tab || tab === dimActiveTab) return;
             dimActiveTab = tab;
     let data;
       try { data = JSON.parse(dimRawData); } catch (_) { data = { dimensions: [] }; }
      renderDimCards(data);
   });
      });
    }

    /** 构建 Tab 事件绑定 */
    function bindBuildTabEvents() {
      const runBtn = dimView.querySelector('.dim-build-run-btn');
      if (runBtn) runBtn.addEventListener('click', runBuildAction);

      // ── 展开/折叠右侧测试源面板 ──
      const toggleBtn = dimView.querySelector('.dim-build-toggle-ts');
  if (toggleBtn) {
   toggleBtn.addEventListener('click', () => {
       const right = dimView.querySelector('.dim-build-right');
    if (right) {
          right.classList.toggle('dim-build-right--collapsed');
  toggleBtn.textContent = right.classList.contains('dim-build-right--collapsed') ? '⚙ 测试源' : '✕ 收起';
 }
          });
      }

 // ── 从模型管理加载模型列表 ──
   const loadModelsBtn = dimView.querySelector('.dim-build-load-models');
   if (loadModelsBtn) {
      loadModelsBtn.addEventListener('click', async () => {
      const picker = dimView.querySelector('.dim-build-model-picker');
    if (!picker) return;
          if (picker.style.display !== 'none') { picker.style.display = 'none'; return; }

     picker.innerHTML = '<span class="dim-build-picker-loading">加载中...</span>';
          picker.style.display = 'block';

          try {
  const resp = await adminFetch('/api/models');
      const data = await resp.json();
 if (!data.ok) { picker.innerHTML = `<span class="dim-build-picker-err">\u274c ${data.error}</span>`; return; }

    const sources = data.sources || [];
            if (sources.length === 0) {
    picker.innerHTML = '<span class="dim-build-picker-err">暂无模型源目录，请先到「模型管理」添加</span>';
  return;
            }

 // 按测试集名字列出，点击直接导入
            let listHtml = '<div class="dim-build-picker-list">';
            sources.forEach((src, idx) => {
              const modelCount = (src.models || []).length;
          listHtml += `<div class="dim-build-picker-source-item" data-src-idx="${idx}">
    <span class="dim-build-picker-source-name">${escHtml(src.name)}</span>
         <span class="dim-build-picker-source-count">${modelCount} 个模型</span>
    </div>`;
            });
   listHtml += '</div>';

  picker.innerHTML = listHtml;

 // 点击测试集名字直接导入所有模型
    const ta = dimView.querySelector('[data-bf="models"]');
   picker.querySelectorAll('.dim-build-picker-source-item').forEach(item => {
         item.addEventListener('click', () => {
     const srcIdx = +item.dataset.srcIdx;
        const src = sources[srcIdx];
  const models = (src.models || []).map(m => src.path + '/' + m);
      if (models.length === 0) {
              item.classList.add('dim-build-picker-source-empty');
                item.querySelector('.dim-build-picker-source-count').textContent = '暂无模型';
          setTimeout(() => item.classList.remove('dim-build-picker-source-empty'), 1500);
   return;
   }
       if (ta) { ta.value = models.join('\n'); ta.dispatchEvent(new Event('change')); }
      picker.style.display = 'none';
     });
       });
          } catch (e) {
 picker.innerHTML = `<span class="dim-build-picker-err">\u274c 请求失败: ${e.message}</span>`;
        }
   });
      }

      // ── 自动保存：构建配置字段变化时自动持久化到 JSON ──
      let buildSaveTimer = null;
  const autosaveBuild = () => {
          if (buildSaveTimer) clearTimeout(buildSaveTimer);
 buildSaveTimer = setTimeout(() => { saveBuildConfig(true); }, 600);
      };
   dimView.querySelectorAll('[data-bf]').forEach(el => {
          el.addEventListener('change', autosaveBuild);
          if (el.tagName === 'TEXTAREA' || el.type === 'text' || !el.type) {
         el.addEventListener('blur', autosaveBuild);
       }
    });
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
             ? `<button class="dim-del-dim-btn ghost-btn" data-dim="${idx}" title="删除此维度"><svg class="inline-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg> 删除</button>`
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
                     <span class="dim-cl-title">Checklist</span>
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

    // ── 构建配置 Tab ──
    function renderBuildSection(obj, admin) {
        const b = (obj && obj.build && typeof obj.build === 'object') ? obj.build : {};
      const tag = (obj && obj.tag) || '';

        // size: xs=60px, sm=80px, md=140px, lg=240px, xl=100%
    const fld = (label, id, val, ph, size) => {
            const szCls = 'dim-build-sz-' + (size || 'md');
   return `<div class="dim-build-field ${szCls}"><label class="dim-build-label">${escHtml(label)}</label>`
                + (admin
  ? `<input class="dim-build-input" data-bf="${id}" value="${escHtml(val || '')}" placeholder="${escHtml(ph || '')}">`
     : `<span class="dim-build-val">${escHtml(val || ph || '—')}</span>`)
    + `</div>`;
        };

        const selFld = (label, id, val, opts, size) => {
    const szCls = 'dim-build-sz-' + (size || 'sm');
            return `<div class="dim-build-field ${szCls}"><label class="dim-build-label">${escHtml(label)}</label>`
      + (admin
 ? `<select class="dim-build-input" data-bf="${id}">${opts.map(([v, t]) => `<option value="${escHtml(v)}"${val === v ? ' selected' : ''}>${escHtml(t)}</option>`).join('')}</select>`
         : `<span class="dim-build-val">${escHtml(opts.find(o => o[0] === val)?.[1] || val || '—')}</span>`)
         + `</div>`;
     };

     const models = Array.isArray(b.models) ? b.models.join('\n') : '';
  const samples = Array.isArray(b.samples) ? b.samples.join(',') : '';
        const excludeSamples = Array.isArray(b.exclude_samples) ? b.exclude_samples.join(',') : '';

        const syncToTs = b.sync_to_testsrc !== false; // 默认勾选

        let bodyHtml = `
        <div class="dim-build-grp">
        <div class="dim-build-grp-title">路径配置</div>
   <div class="dim-build-grid">
       ${fld('首帧目录', 'first_frames_dir', b.companions ? b.companions.first_frames_dir : '', 'first_frames', 'half')}
       ${fld('Prompt CSV', 'prompt_csv', b.companions ? b.companions.prompt_csv : '', 'prompt.csv', 'half')}
      </div>
        </div>
        <div class="dim-build-grp">
        <div class="dim-build-grp-title">构建参数</div>
   <div class="dim-build-grid">
             ${fld('组数', 'n_groups', String(b.n_groups || 5), '5', 'xs')}
    ${fld('种子', 'seed', String(b.seed != null ? b.seed : 42), '42', 'xs')}
${selFld('盲评', 'blind', String(b.blind !== false), [['true', '是'], ['false', '否']], 'xs')}
    ${fld('样本列表', 'samples', samples, '留空默认1~100，如1,2,3,5', 'md')}
    ${fld('排除样本', 'exclude_samples', excludeSamples, '如 10,20', 'sm')}
    ${fld('Prompt 列名', 'prompt_cols', b.companions && b.companions.prompt_cols ? b.companions.prompt_cols.join(',') : '', 'image,prompt,en_prompt', 'lg')}
      </div>
        </div>
        <div class="dim-build-grp">
                   <div class="dim-build-grp-title">模型列表${admin ? '<button class="dim-build-load-models" title="从模型管理加载"><svg class="inline-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg> 从模型管理加载</button>' : ''}</div>
   ${admin
     ? `<textarea class="dim-build-input dim-build-models" data-bf="models" rows="4" placeholder="每行一个模型（路径格式：源目录/模型名）">${escHtml(models)}</textarea>`
   : `<pre class="dim-build-val" style="white-space:pre-wrap">${escHtml(models || '（未配置）')}</pre>`}
            ${admin ? '<div class="dim-build-model-picker" style="display:none"></div>' : ''}
 </div>`;

        if (admin) {
      bodyHtml += `
<div class="dim-build-actions">
     <select class="dim-build-action-sel">
    <option value="build">build（构建盲评包）</option>
        <option value="analyze">analyze（反解分析）</option>
   <option value="verify">verify（审计校验）</option>
<option value="rank">rank（排名统计）</option>
  </select>
          <button class="primary-btn dim-build-run-btn">▶ 执行</button>
    <label class="dim-build-sync-label"><input type="checkbox" class="dim-build-sync-cb" data-bf="sync_to_testsrc" ${syncToTs ? 'checked' : ''}> 同步zip到测试源</label>
    <span class="dim-build-status" id="dimBuildStatus"></span>
     </div>`;
    }

        // 测试源部分（右列，默认折叠）
        const tsHtml = renderTestSourceSection(obj, admin);

        return `<div class="dim-build-combined">
          <div class="dim-build-left">
 <div class="dim-build-section dim-checklist-section">
     <div class="dim-cl-header">
 <span class="dim-cl-title">🔨 构建配置</span>
    <span class="dim-cl-subtitle">Tag 自动使用「备注 tag」字段；输出目录 = tag 同名；构建后自动 zip 到 testsrc</span>
    <button class="dim-build-toggle-ts" title="展开测试源配置">⚙ 测试源</button>
   </div>
 <div class="dim-cl-body dim-build-body">${bodyHtml}</div>
</div>
      </div>
       <div class="dim-build-right dim-build-right--collapsed">
  <div class="dim-build-right-inner">${tsHtml}</div>
</div>
        </div>`;
    }

    /** 从构建 Tab 表单读取 build 配置对象 */
    function readBuildForm() {
     const get = (id) => {
            const el = dimView.querySelector(`[data-bf="${id}"]`);
         return el ? el.value.trim() : '';
     };
   const parseList = (s) => s.split(/[,，\s]+/).filter(Boolean);
        const parseIntList = (s) => s.split(/[,，\s]+/).filter(Boolean).map(Number).filter(n => !isNaN(n));

        const build = {};
        // models 直接保留绝对路径（后端支持绝对路径模型目录，不需要 src_model_dir）
        const modelsRaw = get('models');
        build.models = modelsRaw.split(/\n+/).map(s => s.trim()).filter(Boolean);
   build.n_groups = parseInt(get('n_groups')) || 5;
        build.seed = parseInt(get('seed'));
        if (isNaN(build.seed)) build.seed = 42;
    build.blind = get('blind') !== 'false';
        build.group_mode = 'fresh';

 const samplesRaw = get('samples');
   if (samplesRaw) build.samples = parseIntList(samplesRaw);
        const exclRaw = get('exclude_samples');
   if (exclRaw) build.exclude_samples = parseIntList(exclRaw);

        // companions
    const ffDir = get('first_frames_dir');
        const pCsv = get('prompt_csv');
        const pCols = get('prompt_cols');
    if (ffDir || pCsv || pCols) {
            build.companions = {};
if (ffDir) build.companions.first_frames_dir = ffDir;
   if (pCsv) build.companions.prompt_csv = pCsv;
          if (pCols) build.companions.prompt_cols = parseList(pCols);
  }

        // 同步到测试源选项
        const syncCb = dimView.querySelector('.dim-build-sync-cb');
        build.sync_to_testsrc = syncCb ? syncCb.checked : true;

        return build;
    }

    /** 保存构建配置到当前评分规则 JSON 中（silent=true 时不弹提示） */
async function saveBuildConfig(silent) {
if (!dimCurrentName) { if (!silent) showToast('❌ 未选择配置', 'err'); return; }
        let data;
 try { data = JSON.parse(dimRawData); } catch (_) { data = {}; }
        data.build = readBuildForm();
   try {
            const r = await adminFetch(`/api/configs/${encodeURIComponent(dimCurrentName)}`, {
      method: 'PUT',
   headers: { 'Content-Type': 'application/json' },
           body: JSON.stringify(data),
            });
    if (r.status === 401) return;
            const j = await r.json().catch(() => ({}));
      if (!r.ok || !j.ok) { if (!silent) showToast('❌ ' + (j.error || '保存失败'), 'err'); return; }
            dimRawData = JSON.stringify(data, null, 2);
   if (!silent) showToast('✅ 构建配置已保存', 'ok');
        } catch (e) {
          if (!silent) showToast('❌ 网络错误：' + e.message, 'err');
        }
    }

    /** 执行构建/分析操作 */
    async function runBuildAction() {
     if (!dimCurrentName) { showToast('❌ 未选择配置', 'err'); return; }
        // 先持久化当前表单的 build 配置
await saveBuildConfig(true);
        let data;
 try { data = JSON.parse(dimRawData); } catch (_) { data = {}; }
        const build = readBuildForm();
        const tag = data.tag || dimCurrentName;
        // 用 tag 作为 dst_dir（相对路径，后端基于 tasks/ 目录解析）
        build.tag = tag;
        if (!build.dst_dir) build.dst_dir = tag;
  // map_csv 统一放在 tasks/map/ 目录下
        if (!build.map_csv) build.map_csv = `map/map_${tag}.csv`;

        const actionSel = dimView.querySelector('.dim-build-action-sel');
      const action = actionSel ? actionSel.value : 'build';
        const statusEl = dimView.querySelector('#dimBuildStatus');

        const actionLabels = { build: '构建中…', analyze: '分析中…', verify: '校验中…', rank: '统计中…' };
     if (statusEl) statusEl.textContent = actionLabels[action] || '执行中…';

        const apiPath = action === 'build' ? '/api/build' : '/api/analyze';
        const body = action === 'build'
            ? { config: build }
        : { config: build, action };

        try {
            const r = await adminFetch(apiPath, {
    method: 'POST',
             headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
    });
            if (r.status === 401) { if (statusEl) statusEl.textContent = ''; return; }
  const j = await r.json().catch(() => ({}));
            if (!r.ok || !j.ok) {
  showToast('❌ ' + (j.error || '执行失败'), 'err');
         if (statusEl) statusEl.textContent = '❌ 失败';
     return;
            }
     // 构建成功后根据勾选决定是否 zip 到 testsrc
            if (action === 'build' && j.data && j.data.dstDir && build.sync_to_testsrc) {
             if (statusEl) statusEl.textContent = '压缩中…';
                try {
           const zr = await adminFetch('/api/build/zip', {
     method: 'POST',
        headers: { 'Content-Type': 'application/json' },
body: JSON.stringify({ dstDir: j.data.dstDir, tag }),
    });
           const zj = await zr.json().catch(() => ({}));
  if (zr.ok && zj.ok) {
        showToast(`✅ 构建完成并已压缩 → ${zj.zipName}`, 'ok');
           if (statusEl) statusEl.textContent = `✅ ${zj.zipName}`;
        // 自动填写测试源 url 并刷新右侧面板
        if (zj.zipName) {
      data.build = build;
            if (!data.testSource) data.testSource = {};
         data.testSource.url = `/testsrc/${zj.zipName}`;
  dimRawData = JSON.stringify(data, null, 2);
    // 保存配置（含更新后的 testSource.url）
      await adminFetch(`/api/configs/${encodeURIComponent(dimCurrentName)}`, {
     method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(data),
        });
        // 刷新右侧测试源面板
        const rightPanel = dimView.querySelector('.dim-build-right-inner');
     if (rightPanel) {
        rightPanel.innerHTML = renderTestSourceSection(data, true);
  bindTestSourceEvents();
            // 自动展开右侧面板以显示更新
            const right = dimView.querySelector('.dim-build-right');
   if (right) right.classList.remove('dim-build-right--collapsed');
         const toggleBtn = dimView.querySelector('.dim-build-toggle-ts');
   if (toggleBtn) toggleBtn.textContent = '✕ 收起';
        }
  }
           } else {
     showToast('⚠️ 构建成功但压缩失败：' + (zj.error || ''), 'err');
     if (statusEl) statusEl.textContent = '⚠️ 压缩失败';
          }
      } catch (ze) {
                    showToast('⚠️ 构建成功但压缩异常：' + ze.message, 'err');
              if (statusEl) statusEl.textContent = '⚠️ 压缩异常';
           }
     } else {
       showToast('✅ 执行完成', 'ok');
        if (statusEl) statusEl.textContent = '✅ 完成';
            }
        } catch (e) {
  showToast('❌ 网络错误：' + e.message, 'err');
            if (statusEl) statusEl.textContent = '❌ 网络错误';
        }
    }

    // ── 测试源自动化配置区（testSource 对象）──────────────────────────────
    // 客户端点「接受」后按此配置全自动执行：下载 → 解压 → 按 laneDirs 导入对比
    // → 绑定参考图/提示词 → 进入打分界面。结构见 PlayerX 端 _startTestSourceAutomation。
    function renderTestSourceSection(obj, admin) {
        const ts = (obj && obj.testSource && typeof obj.testSource === 'object') ? obj.testSource : null;
        if (!ts && !admin) return '';

        const delCfgBtn = (admin && ts)
            ? `<button class="dim-ts-delcfg-btn ghost-btn" title="移除整个 testSource 配置（客户端将回退为仅下载或不动）">移除配置</button>`
            : '';

        let bodyHtml = '';
        if (!ts) {
            bodyHtml = `<div class="dim-ts-empty">未配置测试源自动化：客户端点「接受」后仅应用评分配置，不会自动下载/导入。</div>`
                + `<button class="dim-cl-add-btn dim-ts-add-btn">＋ 添加测试源配置</button>`;
        } else {
            const fields = [
                ['url',          'zip 下载地址（必填）：相对路径 /testsrc/xx.zip 随服务器迁移免改；COS 等绝对地址原样使用'],
                ['workDir',      '下载 + 解压目录（支持 ~ 开头，默认系统 Downloads）'],
                ['rootDir',      '内容根目录 = zip 内顶层目录名（相对 workDir；"/" 开头视为绝对路径）'],
                ['group',        '默认组别（可选）：内容根下含 g1/g2 等分组目录时，客户端「接受」后弹窗选组，此处为默认选中组'],
                ['promptCsv',    '提示词 CSV（相对内容根；留空则不绑定）'],
            ];
            const rowsHtml = fields.map(([f, tip]) => {
                const v = ts[f] || '';
                const valHtml = admin
                    ? `<span class="dim-ts-val dim-ts-editable${v ? '' : ' dim-card-placeholder'}" data-ts-field="${f}" title="${escHtml(tip)}；点击编辑">${escHtml(v || '（未填写）')}</span>`
                    : `<span class="dim-ts-val${v ? '' : ' dim-card-placeholder'}">${escHtml(v || '—')}</span>`;
                // url 指向本服务器托管包时打个标，一眼区分 COS 外链
                const hostedBadge = (f === 'url' && /\/testsrc\//.test(v))
                    ? '<span class="dim-ts-hosted-badge" title="该 zip 托管在本服务器上，客户端走内网下载">服务器托管</span>'
                    : '';
                return `<div class="dim-ts-row"><span class="dim-ts-fname" title="${escHtml(tip)}">${f}</span>${valHtml}${hostedBadge}</div>`;
            }).join('');

            const lanes = Array.isArray(ts.laneDirs) ? ts.laneDirs : [];
            const laneChips = lanes.map((d, i) =>
                `<span class="dim-ts-lane-chip">${escHtml(d)}${admin ? `<button class="dim-ts-lane-del" data-lane-idx="${i}" title="移除该路">✕</button>` : ''}</span>`
            ).join('');
            const laneAddHtml = admin
                ? `<input class="dim-ts-lane-input" placeholder="目录名，如 C" title="回车或点 ＋ 添加一路"><button class="dim-ts-lane-add" title="添加一路">＋</button>`
                : '';
            const lanesRow = `<div class="dim-ts-row">
                <span class="dim-ts-fname" title="参与对比的子目录（相对内容根），按顺序对应客户端第 1..N 路">laneDirs</span>
                <span class="dim-ts-lanes">${laneChips}${laneAddHtml}</span>
            </div>`;

            // 参考图目录：新写法 referenceDirs（数组，最多 2 个，对应客户端两个参考图窗口）；
            // 兼容展示旧写法 referenceDir（单字符串，视为第 1 个；下次编辑时自动迁移为数组）。
            const refDirs = Array.isArray(ts.referenceDirs)
                ? ts.referenceDirs.filter(d => typeof d === 'string' && d.trim())
                : (ts.referenceDir && String(ts.referenceDir).trim() ? [String(ts.referenceDir).trim()] : []);
            const refChips = refDirs.map((d, i) =>
                `<span class="dim-ts-lane-chip dim-ts-ref-chip" title="第 ${i + 1} 张参考图窗口">${escHtml(d)}${admin ? `<button class="dim-ts-ref-del" data-ref-idx="${i}" title="移除该参考图目录">✕</button>` : ''}</span>`
            ).join('');
            const refAddHtml = (admin && refDirs.length < 2)
                ? `<input class="dim-ts-ref-input" placeholder="目录名，如 second_frames" title="回车或点 ＋ 添加（最多 2 个，对应两个参考图窗口）"><button class="dim-ts-ref-add" title="添加参考图目录">＋</button>`
                : (admin ? `<span class="dim-ts-ref-cap" title="客户端只有两个参考图窗口">（已达 2 张上限）</span>` : '');
            const refsRow = `<div class="dim-ts-row">
                <span class="dim-ts-fname" title="参考图目录（相对内容根），按顺序对应客户端第 1/2 个参考图窗口；留空则不绑定">referenceDirs</span>
                <span class="dim-ts-lanes">${refChips || '<span class="dim-card-placeholder">（未配置，不绑定参考图）</span>'}${refAddHtml}</span>
            </div>`;

            bodyHtml = rowsHtml + lanesRow + refsRow;
        }

        return `<div class="dim-ts-section dim-checklist-section">
            <div class="dim-cl-header dim-ts-header">
                  <span class="dim-cl-title">测试源</span>
                <span class="dim-cl-subtitle">客户端点「接受」后自动：下载 → 解压 → 导入对比 → 绑定参考图/提示词 → 进入打分</span>
                ${admin ? '<button class="dim-ts-upload-btn ghost-btn" title="选择 zip 上传到本服务器，成功后自动填入 url 字段">⇪ 上传 zip 到服务器</button><input type="file" class="dim-ts-upload-input" accept=".zip,application/zip" style="display:none">' : ''}
                ${delCfgBtn}
            </div>
            <div class="dim-cl-body dim-ts-body">
                ${bodyHtml}
            </div>
        </div>`;
    }

    /** groupMap 字符串 → 结构化组别数组：[{name:'g1', members:['张三']}]（按首次出现排序，同名去重） */
    function parseGroupMap(raw) {
        const out = []; const idx = {};
        String(raw || '').split(/[,，;；\n]+/).forEach(ent => {
            const kv = ent.split(/[:：]/);
            if (kv.length < 2) return;
            const n = kv[0].trim();
            const g = kv.slice(1).join(':').trim();
            if (!n || !g) return;
            if (idx[g] === undefined) { idx[g] = out.length; out.push({ name: g, members: [] }); }
            const grp = out[idx[g]];
            if (!grp.members.includes(n)) grp.members.push(n);
        });
        return out;
    }

    /** 结构化组别数组 → groupMap 字符串（空组自动丢弃） */
    function serializeGroupMap(groups) {
        const parts = [];
        groups.forEach(g => (g.members || []).forEach(m => parts.push(m + ':' + g.name)));
        return parts.join(', ');
    }

    /** 渲染模型（读取兼容三种历史格式，按优先级）：
     *  ① 新结构：ts.groups 为对象 {"g1": ["a","b"], "g2": []} —— 空组 = 空数组，天然支持预配置；
     *  ② 过渡结构：ts.groups 数组（组声明）+ ts.groupMap 字符串（名单映射）；
     *  ③ 最旧结构：仅 ts.groupMap 字符串。 */
    function buildTesterModel(ts) {
        if (ts.groups && typeof ts.groups === 'object' && !Array.isArray(ts.groups)) {
            return Object.keys(ts.groups).map(name => ({
                name,
                members: Array.isArray(ts.groups[name]) ? ts.groups[name].slice() : []
            }));
        }
        const declared = Array.isArray(ts.groups)
            ? ts.groups.map(s => String(s || '').trim()).filter(Boolean) : [];
        const mg = parseGroupMap(ts.groupMap);
        const byName = {};
        mg.forEach(g => { byName[g.name] = g; });
        const out = []; const seen = {};
        declared.forEach(n => {
            if (seen[n]) return;
            seen[n] = true;
            out.push({ name: n, members: byName[n] ? byName[n].members.slice() : [] });
        });
        mg.forEach(g => {
            if (seen[g.name]) return;
            seen[g.name] = true;
            out.push({ name: g.name, members: g.members.slice() });
        });
        return out;
    }

    /** 把组别模型按新结构写回 ts：groups 对象；同时清掉旧字段（groupMap 字符串）。
     *  对象键序即模型顺序（JS/JSON 字符串键保序），手动复制 JSON 也直观。 */
    function writeTesterModel(ts, model) {
        const obj = {};
        model.forEach(g => { obj[g.name] = (g.members || []).slice(); });
        ts.groups = obj;
        delete ts.groupMap;
    }

    // 测试人名单过滤词（模块级状态：分区刷新后保持并重应用）
    let dimTesterFilter = '';

    /** 渲染「测试人」Tab：按组别管理评分人名单（groups 声明空组 + groupMap 名单） */
    function renderTestersSection(obj, admin) {
        const ts = (obj && obj.testSource && typeof obj.testSource === 'object') ? obj.testSource : {};
        const groups = buildTesterModel(ts);
        // 左右结构：组名居左固定，名单芯片在右侧流式排布（g1 + 人1, 人2 …）
        // 删组 ✕ 独立在组名芯片外：与「点组名改名」热区完全分开，避免误触/判定纠缠
        // 所有操作以组名（data-gname）为键，空组同样可渲染/可编辑
        const cards = groups.map((g) => `
            <div class="dim-tester-card" data-gname="${escHtml(g.name)}">
                <span class="dim-tester-gname" ${admin ? `data-gname="${escHtml(g.name)}" title="点击编辑组名"` : ''}>${escHtml(g.name)}</span>
                ${admin ? `<button class="dim-tester-gdel" data-gname="${escHtml(g.name)}" title="删除该组（成员一并移除）">✕</button>` : ''}
                <span class="dim-tester-count">${g.members.length} 人</span>
                <div class="dim-tester-members">
                    ${g.members.map(m => `<span class="dim-tester-chip" data-name="${escHtml(m)}">${escHtml(m)}${admin ? `<button class="dim-tester-del" data-gname="${escHtml(g.name)}" data-name="${escHtml(m)}" title="移除该评分人">✕</button>` : ''}</span>`).join('')}
                    ${admin ? `<input class="dim-tester-input" data-gname="${escHtml(g.name)}" placeholder="名字，回车添加" title="回车添加评分人到该组；同名评分人会自动从其它组移入本组（一人一组）">` : ''}
                </div>
            </div>`).join('');
        const emptyHtml = groups.length === 0
            ? `<div class="dim-ts-empty">暂无组别。${admin ? '点右上角「＋ 新增一组」开始分配测试人；' : ''}未分配名单的客户端接受测试源时仍会弹窗手动选组。</div>`
            : '';
        return `<div class="dim-testers-section dim-checklist-section">
            <div class="dim-cl-header">
           <span class="dim-cl-title">测试人</span>
                <span class="dim-cl-subtitle">评分人按组别分配：客户端「接受」时命中名单即免选组、自动进入对应组别打分（一人一组）</span>
                <span style="flex:1"></span>
                ${groups.length > 0 ? `<input class="dim-tester-filter" placeholder="🔍 过滤组名 / 名字" value="${escHtml(dimTesterFilter)}">` : ''}
                ${admin ? '<button class="dim-tester-add-group" title="新增一个组别（如 g2）">＋ 新增一组</button>' : ''}
            </div>
            <div class="dim-cl-body dim-testers-body">
                ${cards}${emptyHtml}
            </div>
        </div>`;
    }

    /** 应用测试人过滤（纯客户端 DOM，不改数据）：组名命中整组显示，否则按名字逐个过滤 */
    function applyTesterFilter() {
        const q = dimTesterFilter.trim().toLowerCase();
        dimView.querySelectorAll('.dim-tester-card').forEach(card => {
            const gname = (card.dataset.gname || '').toLowerCase();
            const gMatch = q.length > 0 && gname.indexOf(q) >= 0;
            let visibleCount = 0;
            card.querySelectorAll('.dim-tester-chip').forEach(chip => {
                const show = q.length === 0 || gMatch
                    || (chip.dataset.name || '').toLowerCase().indexOf(q) >= 0;
                chip.style.display = show ? '' : 'none';
                if (show) visibleCount++;
            });
            card.style.display = (q.length === 0 || gMatch || visibleCount > 0) ? '' : 'none';
        });
    }

    /** 就地重渲染测试人分区 */
    function refreshTestersSection() {
        let data;
        try { data = JSON.parse(dimRawData); } catch (_) { return; }
        const sec = dimView.querySelector('.dim-testers-section');
        if (!sec) return;
        const tmp = document.createElement('div');
        tmp.innerHTML = renderTestersSection(data, isLoggedIn());
        sec.replaceWith(tmp.firstElementChild);
        bindTestersEvents();
        if (dimTesterFilter) applyTesterFilter();
    }

    /** 就地重渲染测试源分区（避免整页刷新打断其他编辑焦点） */
    function refreshTestSourceSection() {
        let data;
        try { data = JSON.parse(dimRawData); } catch (_) { return; }
        const sec = dimView.querySelector('.dim-ts-section');
        if (!sec) return;
        const tmp = document.createElement('div');
        tmp.innerHTML = renderTestSourceSection(data, isLoggedIn());
        sec.replaceWith(tmp.firstElementChild);
        bindTestSourceEvents();
    }

    /** 修改 testSource 并持久化 + 就地刷新分区（测试源 / 测试人两个 Tab 各自检测存在性） */
    async function mutateTestSource(mutator) {
        let latest;
        try { latest = JSON.parse(dimRawData); } catch (_) { return; }
        if (!latest.testSource || typeof latest.testSource !== 'object') latest.testSource = {};
        mutator(latest.testSource, latest);
        await persistDimData(latest);
        refreshTestSourceSection();
        refreshTestersSection();
    }

    /** 测试人 Tab 事件绑定（管理员）：组内增删名单、新增/改名/删除组、过滤 */
    function bindTestersEvents() {
        if (!isLoggedIn()) return;
        // 名单过滤（组名命中整组显示，否则按名字逐个过滤）
        const filterInp = dimView.querySelector('.dim-tester-filter');
        if (filterInp) {
            filterInp.addEventListener('input', () => {
                dimTesterFilter = filterInp.value;
                applyTesterFilter();
            });
        }
        // 添加评分人到组（回车提交；一人一组：自动从其它组移出）
        dimView.querySelectorAll('.dim-tester-input').forEach(inp => {
            inp.addEventListener('keydown', (e) => {
                if (e.key !== 'Enter') return;
                e.preventDefault();
                const v = inp.value.trim();
                if (!v) return;
                const gname = inp.dataset.gname || '';
                mutateTestSource(ts => {
                    const model = buildTesterModel(ts);
                    const g = model.find(x => x.name === gname);
                    if (!g) return;
                    if (g.members.includes(v)) return;
                    model.forEach(og => { og.members = og.members.filter(m => m !== v); });
                    g.members.push(v);
                    writeTesterModel(ts, model);
                });
            });
        });
        // 移除评分人（新结构下空数组即空组，名单清空组仍在，便于预配置）
        dimView.querySelectorAll('.dim-tester-del').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const gname = btn.dataset.gname || '';
                const name = btn.dataset.name;
                mutateTestSource(ts => {
                    const model = buildTesterModel(ts);
                    const g = model.find(x => x.name === gname);
                    if (!g) return;
                    g.members = g.members.filter(m => m !== name);
                    writeTesterModel(ts, model);
                });
            });
        });
        // 新增一组：新增一行「组名 + 成员（可留空）」两个键入框，空组同样保存
        //（空组写入 ts.groups 声明数组；groupMap 只承载名单，客户端零改动）。
        // 组名回车 → 跳成员框；成员回车 / ✓ → 提交；Esc / ✕ → 取消。
        const addGBtn = dimView.querySelector('.dim-tester-add-group');
        if (addGBtn) addGBtn.addEventListener('click', () => {
            if (dimView.querySelector('.dim-tester-newg-row')) return;
            const row = document.createElement('div');
            row.className = 'dim-tester-card dim-tester-newg-row';
            row.innerHTML =
                '<input class="dim-tester-newg-input dim-ng-name" placeholder="组名，如 g3">' +
                '<input class="dim-tester-input dim-ng-member" placeholder="成员（可留空）">' +
                '<button class="dim-tester-newg-ok" title="创建该组">✓</button>' +
                '<button class="dim-tester-newg-cancel" title="取消">✕</button>';
            const body = dimView.querySelector('.dim-testers-body');
            if (body) body.insertBefore(row, body.firstChild);
            else addGBtn.parentElement.insertBefore(row, addGBtn);
            const nameInp = row.querySelector('.dim-ng-name');
            const memberInp = row.querySelector('.dim-ng-member');
            nameInp.focus();
            const cancel = () => { if (row.isConnected) row.remove(); };
            const commit = () => {
                const gname = nameInp.value.trim();
                const member = memberInp.value.trim();
                if (!gname) { nameInp.focus(); return; }
                let data;
                try { data = JSON.parse(dimRawData); } catch (_) { return; }
                const ts = (data && data.testSource) || {};
                if (buildTesterModel(ts).some(g => g.name === gname)) {
                    showToast('组「' + gname + '」已存在', 'err');
                    return;
                }
                mutateTestSource(ts2 => {
                    const model = buildTesterModel(ts2);
                    model.push({ name: gname, members: member ? [member] : [] });
                    writeTesterModel(ts2, model);
                });
            };
            nameInp.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') { cancel(); return; }
                if (e.key !== 'Enter') return;
                e.preventDefault();
                memberInp.focus();
            });
            memberInp.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') { cancel(); return; }
                if (e.key !== 'Enter') return;
                e.preventDefault();
                commit();
            });
            row.querySelector('.dim-tester-newg-ok').addEventListener('click', (e) => {
                e.stopPropagation();
                commit();
            });
            row.querySelector('.dim-tester-newg-cancel').addEventListener('click', (e) => {
                e.stopPropagation();
                cancel();
            });
            // 焦点完全离开该行且两框皆空 → 自动取消（relatedTarget 判定避免框间切换误杀）
            const maybeCancel = () => {
                setTimeout(() => {
                    if (!row.isConnected) return;
                    if (row.contains(document.activeElement)) return;
                    if (!nameInp.value.trim() && !memberInp.value.trim()) cancel();
                }, 0);
            };
            nameInp.addEventListener('blur', maybeCancel);
            memberInp.addEventListener('blur', maybeCancel);
        });
        // 编辑组名（点击组名芯片 → 行内输入框；模型键改名，成员归属随键走）
        dimView.querySelectorAll('.dim-tester-gname').forEach(el => {
            el.addEventListener('click', (e) => {
                e.stopPropagation();
                if (el.querySelector('input')) return;
                const oldName = el.dataset.gname || '';
                const input = document.createElement('input');
                input.className = 'dim-tester-gname-input';
                input.value = oldName;
                el.textContent = '';
                el.appendChild(input);
                input.focus();
                input.select();
                let done = false;
                const finish = (commit) => {
                    if (done) return;
                    done = true;
                    const v = input.value.trim();
                    if (!commit || !v || v === oldName) { refreshTestersSection(); return; }
                    mutateTestSource(ts => {
                        const model = buildTesterModel(ts);
                        if (model.some(g => g.name === v)) {
                            showToast('组名「' + v + '」已存在', 'err');
                            return;
                        }
                        const g = model.find(x => x.name === oldName);
                        if (g) g.name = v;
                        writeTesterModel(ts, model);
                    });
                };
                input.addEventListener('keydown', (ev) => {
                    if (ev.key === 'Enter') { ev.preventDefault(); finish(true); }
                    else if (ev.key === 'Escape') finish(false);
                });
                input.addEventListener('blur', () => finish(true));
            });
        });
        // 删除组（成员一并移除）
        dimView.querySelectorAll('.dim-tester-gdel').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const gname = btn.dataset.gname || '';
                mutateTestSource(ts => {
                    writeTesterModel(ts, buildTesterModel(ts).filter(g => g.name !== gname));
                });
            });
        });
    }

    /** testSource 单字段行内编辑（url / workDir / rootDir / referenceDir / promptCsv） */
    function startTsFieldEdit(el) {
        if (el.querySelector('input')) return;
        const field = el.dataset.tsField;
        let data;
        try { data = JSON.parse(dimRawData); } catch (_) { return; }
        const ts = data.testSource || {};
        const currentVal = ts[field] || '';
        const placeholders = {
            url:          'https://.../bench_xxx.zip',
            workDir:      '~/Downloads',
            rootDir:      'bench_xxx（zip 内顶层目录名）',
            referenceDir: 'first_frames',
            promptCsv:    'prompt.csv',
        };
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'dim-meta-inline-input';
        input.value = currentVal;
        input.placeholder = placeholders[field] || '';
        el.innerHTML = '';
        el.appendChild(input);
        input.focus();
        input.select();
        input.addEventListener('blur', () => {
            const newVal = input.value.trim();
            if ((currentVal || '') === newVal) { refreshTestSourceSection(); return; }
            mutateTestSource(ts2 => {
                if (newVal) ts2[field] = newVal; else delete ts2[field];
            });
        });
        input.addEventListener('keydown', e => {
            if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
            if (e.key === 'Escape') { refreshTestSourceSection(); }
        });
    }

    /** 测试源分区事件绑定（管理员） */
    function bindTestSourceEvents() {
        if (!isLoggedIn()) return;
        // 字段行内编辑
        dimView.querySelectorAll('.dim-ts-editable').forEach(el => {
            el.addEventListener('click', (e) => { e.stopPropagation(); startTsFieldEdit(el); });
        });
        // 添加配置（带与客户端一致的默认结构）
        const addBtn = dimView.querySelector('.dim-ts-add-btn');
        if (addBtn) addBtn.addEventListener('click', () => {
            mutateTestSource(ts => {
                ts.url = ts.url || '';
                ts.workDir = ts.workDir || '~/Downloads';
                ts.rootDir = ts.rootDir || '';
                ts.laneDirs = Array.isArray(ts.laneDirs) ? ts.laneDirs : ['A', 'B'];
                ts.referenceDirs = Array.isArray(ts.referenceDirs) ? ts.referenceDirs : ['first_frames'];
                ts.promptCsv = ts.promptCsv || 'prompt.csv';
            });
        });
        // 上传 zip 到服务器（成功后自动回填 url 字段并保存）
        const upBtn = dimView.querySelector('.dim-ts-upload-btn');
        const upInput = dimView.querySelector('.dim-ts-upload-input');
        if (upBtn && upInput) {
            upBtn.addEventListener('click', (e) => { e.stopPropagation(); upInput.click(); });
            upInput.addEventListener('change', async () => {
                const f = upInput.files && upInput.files[0];
                if (!f) return;
                const oldText = upBtn.textContent;
                upBtn.disabled = true;
                upBtn.textContent = '上传中…';
                try {
                    const fd = new FormData();
                    fd.append('file', f, f.name);
                    const r = await adminFetch('/api/testsrc/upload', { method: 'POST', body: fd });
                    const data = await r.json().catch(() => null);
                    if (!r.ok || !data || !data.ok) {
                        throw new Error((data && data.error) || ('HTTP ' + r.status));
                    }
                    // 存相对路径（/testsrc/xxx.zip）：客户端自动按当前配置的服务器
                    // origin 拼接，迁移服务器后配置原样拷贝即可，url 无需手改；
                    // mutateTestSource 内部会保存并刷新分区
                    //
                    // 自动识别策略：
                    //   - url：永远更新为新 zip 的地址
                    //   - rootDir：用新 zip 的内容（zip 顶层目录或文件名）覆盖；上传后用户仍可手动改
                    //   - laneDirs / referenceDirs / promptCsv：用服务端 zip 分析结果覆盖；
                    //     若新 zip 没识别到对应项（返回空），则保留旧值不破坏
                    //   - groups：服务端识别到组目录时合并（保留旧成员，新增空组），不会清空已有成员
                    mutateTestSource(ts => {
                        ts.url = data.url;
                        // rootDir：优先用服务端 zip 分析结果，否则用文件名（去 .zip）
                        const zipRootDir = (data.suggestions && data.suggestions.rootDir) || '';
                        ts.rootDir = zipRootDir || data.name.replace(/\.zip$/i, '');
                        if (data.suggestions) {
                            const s = data.suggestions;
                            if (Array.isArray(s.laneDirs) && s.laneDirs.length > 0) {
                                ts.laneDirs = s.laneDirs;
                            }
                            if (Array.isArray(s.referenceDirs) && s.referenceDirs.length > 0) {
                                ts.referenceDirs = s.referenceDirs;
                            }
                            if (s.promptCsv) {
                                ts.promptCsv = s.promptCsv;
                            }
                            // groups：合并识别到的新组，保留旧成员
                            if (Array.isArray(s.groups) && s.groups.length > 0) {
                                if (!ts.groups || typeof ts.groups !== 'object' || Array.isArray(ts.groups)) {
                                    ts.groups = {};
                                }
                                s.groups.forEach(gname => {
                                    if (!ts.groups[gname]) ts.groups[gname] = [];
                                });
                                // 清理旧字段
                                delete ts.groupMap;
                            }
                        }
                    });
                    const fillMsg = [];
                    if (data.suggestions) {
                        if (data.suggestions.rootDir) {
                            fillMsg.push('rootDir=' + data.suggestions.rootDir);
                        }
                        if (data.suggestions.laneDirs && data.suggestions.laneDirs.length) {
                            fillMsg.push('laneDirs=' + data.suggestions.laneDirs.join(','));
                        }
                        if (data.suggestions.referenceDirs && data.suggestions.referenceDirs.length) {
                            fillMsg.push('refDirs=' + data.suggestions.referenceDirs.join(','));
                        }
                        if (data.suggestions.promptCsv) {
                            fillMsg.push('promptCsv=' + data.suggestions.promptCsv);
                        }
                        if (data.suggestions.groups && data.suggestions.groups.length) {
                            fillMsg.push('groups=' + data.suggestions.groups.join(','));
                        }
                    }
                    const extraInfo = fillMsg.length > 0 ? '（已自动识别：' + fillMsg.join(' / ') + '）' : '';
                    showToast('已上传并填入测试源地址（相对路径，随服务器迁移）：' + data.name + extraInfo, 'ok');
                } catch (err) {
                    showToast('上传失败：' + err.message, 'err');
                } finally {
                    upBtn.disabled = false;
                    upBtn.textContent = oldText;
                    upInput.value = '';
                }
            });
        }
        // 移除整个配置
        const delCfg = dimView.querySelector('.dim-ts-delcfg-btn');
        if (delCfg) delCfg.addEventListener('click', async () => {
            if (!confirm('确定移除测试源配置？客户端点「接受」后将不再自动下载/导入。')) return;
            let latest;
            try { latest = JSON.parse(dimRawData); } catch (_) { return; }
            delete latest.testSource;
            await persistDimData(latest);
            refreshTestSourceSection();
        });
        // lane 删除
        dimView.querySelectorAll('.dim-ts-lane-del').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const i = +btn.dataset.laneIdx;
                mutateTestSource(ts => {
                    if (Array.isArray(ts.laneDirs)) ts.laneDirs.splice(i, 1);
                });
            });
        });
        // lane 添加（按钮 / 回车）
        const laneInput = dimView.querySelector('.dim-ts-lane-input');
        const laneAdd = dimView.querySelector('.dim-ts-lane-add');
        const commitLane = () => {
            if (!laneInput) return;
            const v = (laneInput.value || '').trim().replace(/^\/+|\/+$/g, '');
            if (!v) return;
            mutateTestSource(ts => {
                if (!Array.isArray(ts.laneDirs)) ts.laneDirs = [];
                if (!ts.laneDirs.includes(v)) ts.laneDirs.push(v);
            });
        };
        if (laneAdd) laneAdd.addEventListener('click', commitLane);
        if (laneInput) laneInput.addEventListener('keydown', e => {
            if (e.key === 'Enter') { e.preventDefault(); commitLane(); }
        });

        // ── referenceDirs 芯片编辑（最多 2 个；提交时自动把旧 referenceDir 迁移为数组）──
        const refWrite = (mutator) => {
            mutateTestSource(ts => {
                // 先规范化：无数组时从旧单值字段派生
                if (!Array.isArray(ts.referenceDirs)) {
                    ts.referenceDirs = (ts.referenceDir && String(ts.referenceDir).trim())
                        ? [String(ts.referenceDir).trim()] : [];
                }
                mutator(ts.referenceDirs);
                if (ts.referenceDirs.length === 0) delete ts.referenceDirs;
                delete ts.referenceDir;   // 旧字段统一下线
            });
        };
        dimView.querySelectorAll('.dim-ts-ref-del').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const i = +btn.dataset.refIdx;
                refWrite(arr => arr.splice(i, 1));
            });
        });
        const refInput = dimView.querySelector('.dim-ts-ref-input');
        const refAdd = dimView.querySelector('.dim-ts-ref-add');
        const commitRef = () => {
            if (!refInput) return;
            const v = (refInput.value || '').trim().replace(/^\/+|\/+$/g, '');
            if (!v) return;
            refWrite(arr => { if (!arr.includes(v) && arr.length < 2) arr.push(v); });
        };
        if (refAdd) refAdd.addEventListener('click', commitRef);
        if (refInput) refInput.addEventListener('keydown', e => {
            if (e.key === 'Enter') { e.preventDefault(); commitRef(); }
        });
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

        // 测试源自动化配置区事件绑定
        bindTestSourceEvents();
        // 测试人 Tab 事件绑定（分区不存在时内部查询为空，自然无操作）
        bindTestersEvents();

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
        input.placeholder = field === 'tag' ? '例如 test1 / 终评' : '请输入评测任务名称';
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
                showToast(`✅ 已更新${field === 'tag' ? '备注 tag' : '评测任务'}`, 'ok');
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

    // ── 手动上传（管理员，上传到 uploads/） ─────────────
    const manualUploadLabel = $('manualUploadLabel');
    const manualUploadInput = $('manualUploadInput');
    if (manualUploadLabel && manualUploadInput) {
        manualUploadInput.addEventListener('change', async () => {
            const file = manualUploadInput.files && manualUploadInput.files[0];
            if (!file) return;
            const oldText = manualUploadLabel.querySelector('span').textContent;
            try {
                manualUploadLabel.querySelector('span').textContent = '⏳ 上传中…';
                manualUploadLabel.style.pointerEvents = 'none';
                const fd = new FormData();
                fd.append('file', file);
                const res = await adminFetch('/api/manual-upload', { method: 'POST', body: fd });
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                const data = await res.json();
                if (!data.ok) throw new Error(data.error || '上传失败');
                showToast(`✅ 已上传 ${data.saved} (${fmtSize(data.size)})`);
                await fetchList(); // 刷新文件列表
            } catch (e) {
                showToast(`❌ 上传失败: ${e.message}`);
            } finally {
                manualUploadLabel.querySelector('span').textContent = oldText;
                manualUploadLabel.style.pointerEvents = '';
                manualUploadInput.value = ''; // 允许重复选同一文件
            }
        });
    }

    // ── 盲评分析：切换到分析模块并传递选中文件 ─────────────
    const analyzeSelBtn = $('analyzeSelBtn');
    if (analyzeSelBtn) {
     analyzeSelBtn.addEventListener('click', () => {
      if (!guardWrite()) return;
            const names = [...state.selected];
  if (names.length === 0) { showToast('请先勾选要分析的文件', 'warn'); return; }
     switchModule('tasks');
     // 切换到构建 tab 并选择 analyze
 setTimeout(() => {
    const buildTab = document.querySelector('.dim-tab[data-tab="build"]');
      if (buildTab) buildTab.click();
      setTimeout(() => {
          const sel = document.querySelector('.dim-build-action-sel');
          if (sel) { sel.value = 'analyze'; }
      }, 100);
    }, 100);
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
        // 分析选中：未选中时禁用
        const analyzeBtn = $('analyzeSelBtn');
        if (analyzeBtn) analyzeBtn.disabled = (n === 0);

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
        // 直接用当天日期作为归档文件夹名（不弹窗）
        const f = (() => {
            const d = new Date();
            const pad = (x) => String(x).padStart(2, '0');
            return `${d.getFullYear()}${pad(d.getMonth()+1)}${pad(d.getDate())}`;
        })();
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
            // 若归档页正打开，顺手刷新它，保证刚归档进去的文件立刻可见
            if (currentModule === 'archive') loadArchiveFolders();
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

    // ────────── 归档库（页面模块） ──────────
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
        switchModule('archive');
    }
    function closeArchiveDrawer() {
        switchModule('files');
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
                   ? `合并下载选中（${n}）`
      : '合并下载（全部）';
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
// 解析 #tasks 或 #tasks/<configName>，返回 { isTasks, configName }
    function _parseHash() {
        const h = decodeURIComponent(location.hash || '');
 if (h === '#tasks') return { isTasks: true, configName: null };
        const m = h.match(/^#tasks\/(.+)$/);
     if (m) return { isTasks: true, configName: m[1] };
        return { isTasks: false, configName: null };
    }
    function _getHashConfig() {
        return _parseHash().configName;
    }

    // ── Sidebar 导航绑定 ──
    document.querySelectorAll('.nav-item').forEach(el => {
        el.addEventListener('click', () => {
            switchModule(el.dataset.module);
        });
    });

    // ── 设置页逻辑 ──
    (function initSettings() {
        const tokenView = $('stTokenView');
        const tokenEdit = $('stTokenEdit');
        const serverInfo = $('stServerInfo');
        if (tokenEdit) {
            tokenEdit.addEventListener('click', () => {
                if (!guardWrite()) return;
                openTokenDialog();
            });
        }
        const pageSettings = $('pageSettings');
        if (!pageSettings) return;
        async function refreshTokenView() {
            if (!tokenView) return;
            if (!isLoggedIn()) { tokenView.textContent = '（需登录后查看）'; return; }
            try {
                const r = await adminFetch('/api/settings/upload-token');
                const j = await r.json();
                if (j.ok) tokenView.textContent = j.token ? `已设置（${j.token.length} 位）` : '未设置（关闭鉴权）';
            } catch (_) { tokenView.textContent = '获取失败'; }
        }
        const observer = new MutationObserver(() => {
            if (!pageSettings.hidden) {
                refreshTokenView();
                if (serverInfo && serverInfo.textContent === '—') {
                    fetch('/api/status').then(r => r.json()).then(j => {
                        serverInfo.textContent = `PlayerX-server v${j.version || '?'} · 运行中`;
                    }).catch(() => { serverInfo.textContent = '连接失败'; });
                }
            }
        });
        observer.observe(pageSettings, { attributes: true, attributeFilter: ['hidden'] });
    })();

    // ── 自定义确认弹窗（替代原生 window.confirm） ──
    function confirmDialog(title, msg, icon) {
        return new Promise((resolve) => {
            const mask = $('confirmMask');
            const titleEl = $('confirmTitle');
            const msgEl = $('confirmMsg');
            const iconEl = $('confirmIcon');
            const okBtn = $('confirmOk');
            const cancelBtn = $('confirmCancel');
            if (!mask) { resolve(window.confirm(msg)); return; }
            titleEl.textContent = title || '确认操作';
            msgEl.textContent = msg || '';
            iconEl.textContent = icon || '⚠️';
            mask.hidden = false;
            function cleanup(result) {
                mask.hidden = true;
                okBtn.removeEventListener('click', onOk);
                cancelBtn.removeEventListener('click', onCancel);
                mask.removeEventListener('click', onMask);
                document.removeEventListener('keydown', onKey);
                resolve(result);
            }
            function onOk() { cleanup(true); }
            function onCancel() { cleanup(false); }
            function onMask(e) { if (e.target === mask) cleanup(false); }
            function onKey(e) {
                if (e.key === 'Enter') { e.preventDefault(); cleanup(true); }
                if (e.key === 'Escape') cleanup(false);
            }
            okBtn.addEventListener('click', onOk);
            cancelBtn.addEventListener('click', onCancel);
            mask.addEventListener('click', onMask);
            document.addEventListener('keydown', onKey);
            okBtn.focus();
        });
    }

    // ── 暴露共享 API 给 admin-analyze.js / admin-tasks.js ──
    window.PX = {
        adminFetch,
        isLoggedIn,
        showToast,
        escHtml,
        openLoginDialog,
        updateAuthUi,
        getSelectedFiles: () => [...state.selected],
        switchModule,
        openArchive: openArchiveDrawer,
        openTokenSettings: openTokenDialog,
        confirmDialog,
    };

    // ────────── 启动 ──────────
    (async function init() {
        await fetchStatus();
        await fetchAuthInfo();   // 拉取鉴权状态，更新顶栏登录按钮和管理按钮的锁定态
        await fetchList();
        updateAuthUi();          // 列表渲染后再刷一次（同步行内删除按钮的锁定态）
        // 表头是静态的，初始化一次即可；列宽的持久化由 localStorage 维护
        initColumnResizing(document.getElementById('filesTable'));
        // 检测 URL hash，支持直达链接
        const h = location.hash || '';
    if (_parseHash().isTasks) {
        switchModule('tasks', true);
      } else if (h === '#dashboard') {
            switchModule('dashboard', true);
        } else if (h === '#analyze') {
            switchModule('analyze', true);
        } else if (h === '#settings') {
            switchModule('settings', true);
        } else if (h === '#archive') {
            switchModule('archive', true);
        } else if (h === '#models') {
            switchModule('models', true);
        } else if (h === '#analyze') {
            switchModule('analyze', true);
        }
    })();

    // ═══════════════════════════════════════════════════════════════════════
    // 分析结果模块 —— 独立面板，按 tag 自动查找 map CSV + 评分文件 → 反解排名
    // ═══════════════════════════════════════════════════════════════════════
    (function initAnalyzeModule() {
        const tagSel    = $('analyzeTagSel');
        const runBtn    = $('analyzeRunBtn');
        const statusEl  = $('analyzeStatus');
        const resultDiv = $('analyzeResult');
        const emptyDiv  = $('analyzeEmpty');
        if (!tagSel || !runBtn) return;

        // ── 加载可用 tag（从 uploads/ 目录中扫描所有独立 tag）──
        async function loadTags() {
  try {
      const r = await fetch('/api/list');
    if (!r.ok) return;
        const j = await r.json();
         const tags = new Set();
       (j.items || []).forEach(f => { if (f.tag) tags.add(f.tag); });
    tagSel.innerHTML = '';
                [...tags].sort().forEach(t => {
           const o = document.createElement('option');
                o.value = t; o.textContent = t;
          tagSel.appendChild(o);
       });
            } catch(e) { console.warn('loadTags:', e); }
        }

        // 面板激活时刷新 tag 列表
        const obs = new MutationObserver(() => {
            const sec = $('pageAnalyze');
            if (sec && !sec.hidden) loadTags();
        });
        const sec = $('pageAnalyze');
        if (sec) obs.observe(sec, { attributes: true, attributeFilter: ['hidden'] });

        // ── 执行分析 ──
        runBtn.addEventListener('click', async () => {
            const tag = tagSel.value;
            if (!tag) { showToast('请选择 Tag', 'warn'); return; }
            statusEl.textContent = '分析中…';
            runBtn.disabled = true;
            resultDiv.style.display = 'none';
            emptyDiv.style.display = 'none';
            try {
                const r = await adminFetch('/api/analyze', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ tag, action: 'rank' })
                });
                const j = await r.json();
                if (!r.ok || !j.ok) throw new Error(j.error || '执行失败');
                renderAnalyzeResult(j.data, tag);
                statusEl.textContent = '✅ 完成';
            } catch(e) {
                showToast('❌ ' + e.message, 'err');
                statusEl.textContent = '❌ ' + e.message;
                emptyDiv.style.display = '';
            } finally { runBtn.disabled = false; }
        });

        // ── 渲染结果 ──
        function renderAnalyzeResult(data, tag) {
            resultDiv.style.display = '';
    emptyDiv.style.display = 'none';
      //统计卡片
     $('azStatFiles').textContent  = data.fileCount || '-';
         $('azStatRows').textContent   = data.filtered || data.raw || '-';
 $('azStatDedup').textContent  = data.deduped   || '-';
   $('azStatGroups').textContent = data.completeGroups || '-';
            // 排名表
        const rankTb = document.querySelector('#azRankTable tbody');
      rankTb.innerHTML = '';
            (data.models || []).forEach((m, i) => {
   const tr = document.createElement('tr');
          tr.innerHTML = `<td>${i+1}</td><td><b>${esc(m.name || m.model || '')}</b></td><td>${m.strength != null ? m.strength.toFixed(4) : (m.bt != null ? m.bt.toFixed(3) : '-')}</td><td>${m.elo != null ? Math.round(m.elo) : '-'}</td><td>${m.mean != null ? m.mean.toFixed(2) : (m.winRate != null ? (m.winRate*100).toFixed(1)+'%' : '-')}</td>`;
                rankTb.appendChild(tr);
 });
            // 成对检验表
            const pairTb = document.querySelector('#azPairTable tbody');
 pairTb.innerHTML = '';
      (data.pairs || []).forEach(p => {
        const tr = document.createElement('tr');
          const sig = p.significant === '**' ? '⭐⭐' : p.significant === '*' ? '⭐' : '';
          tr.innerHTML = `<td>${esc(p.modelA || p.a || '')}</td><td>${esc(p.modelB || p.b || '')}</td><td>${p.aWins}</td><td>${p.bWins}</td><td>${p.signP != null ? p.signP.toFixed(4) : (p.p != null ? p.p.toFixed(4) : '-')}</td><td>${sig || (p.significant || '')}</td>`;
     pairTb.appendChild(tr);
 });
    }
        function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }
    })();
})();
