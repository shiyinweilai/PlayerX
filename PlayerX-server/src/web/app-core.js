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
'use strict';
// ────────── DOM 引用 ──────────
const $ = (id) => document.getElementById(id);
const tbody = $('filesTbody');
const emptyHint = $('emptyHint');
const searchInput = $('searchInput');
const mergeLatest = $('mergeLatestBtn');
const mergeAll = $('mergeAllBtn');
const selAll = $('selAll');
const selInfo = $('selInfo');
const selCount = $('selCount');
const archiveSelBtn = $('archiveSelBtn');
const deleteSelBtn = $('deleteSelBtn');

const appVer = $('appVer');

// 管理员登录相关
const adminLoginBtn = $('adminLoginBtn');
const adminLoginLabel = adminLoginBtn ? adminLoginBtn.querySelector('.label') : null;
const loginMask = $('loginMask');
const loginInput = $('loginInput');
const loginErr = $('loginErr');
const loginOkBtn = $('loginOkBtn');
const loginCancelBtn = $('loginCancelBtn');

// 上传 Token 设置弹窗
const tokenSettingsBtn = $('tokenSettingsBtn');
const tokenMask = $('tokenMask');
const tokenInput = $('tokenInput');
const tokenErr = $('tokenErr');
const tokenSaveBtn = $('tokenSaveBtn');
const tokenCancelBtn = $('tokenCancelBtn');

const kpiCount = $('kpiCount');
const kpiUsers = $('kpiUsers');
const kpiTags = $('kpiTags');
const kpiSize = $('kpiSize');

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

let dashboardState = {
    loading: false,
    data: null,
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

// ────────── 顶部明显弹窗 ──────────
// 用于"自动过滤无效 tag"等重要提示。位置：顶部居中（菜单栏下方），
// 样式：图标 + 标题 + 详情 + 关闭按钮；停留 8 秒或可手动关闭。
function showTopAlert(title, detail, kind) {
    const el = $('topAlert');
    if (!el) return;
    el.querySelector('.top-alert-title').textContent = title || '提示';
    el.querySelector('.top-alert-detail').textContent = detail || '';
    el.className = 'top-alert show top-alert-' + (kind || 'warn');
    el.hidden = false;
    clearTimeout(showTopAlert._tm);
    showTopAlert._tm = setTimeout(hideTopAlert, 8000);
}
function hideTopAlert() {
    const el = $('topAlert');
    if (!el || el.hidden) return;
    el.classList.remove('show');
    setTimeout(() => { el.hidden = true; }, 250);
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
                if (adminLoginLabel) adminLoginLabel.textContent = '已登录（点击退出）';
                else adminLoginBtn.textContent = '已登录（点击退出）';
                adminLoginBtn.classList.add('is-logged');
                adminLoginBtn.title = '点击退出管理员登录';
            } else {
                if (adminLoginLabel) adminLoginLabel.textContent = '用户登录';
                else adminLoginBtn.textContent = '用户登录';
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
    const archDelSel = document.getElementById('archiveDelSelBtn');
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
        if (currentModule === 'models') renderModelsPage();
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
        else openLoginDialog();
    });
}
if (loginCancelBtn) loginCancelBtn.addEventListener('click', closeLoginDialog);
if (loginOkBtn) loginOkBtn.addEventListener('click', doAdminLogin);
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
if (tokenCancelBtn) tokenCancelBtn.addEventListener('click', closeTokenDialog);
if (tokenSaveBtn) tokenSaveBtn.addEventListener('click', saveUploadToken);
if (tokenInput) tokenInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') saveUploadToken();
    if (e.key === 'Escape') closeTokenDialog();
});
if (tokenMask) tokenMask.addEventListener('click', (e) => {
    if (e.target === tokenMask) closeTokenDialog();
});

// ────────── 维度规则独立页面（多配置文件管理）──────────
const dimPageBtn = $('dimPageBtn');
const dimPage = $('dimPage');
const dimPageCloseBtn = $('dimPageCloseBtn');
const dimView = $('dimView');
const dimEditorSection = $('dimEditorSection');
const dimEditor = $('dimEditor');
const dimErr = $('dimErr');
const dimEditBtn = $('dimEditBtn');
const dimFormatBtn = $('dimFormatBtn');
const dimSaveBtn = $('dimSaveBtn');
const dimCancelEditBtn = $('dimCancelEditBtn');
const dimSidebarList = $('dimSidebarList');
const dimAddBtn = $('dimAddBtn');

// 主内容区（模式Tab/卡片/工具栏/表格）
const mainContent = [
    $('modeTabs'), document.querySelector('.cards'),
    document.querySelector('.toolbar'), document.querySelector('.table-wrap'),
    document.querySelector('.footer'),
];

let dimPageOpen = false;
let dimEditing = false;
let dimRawData = null;   // 当前选中配置的原始 JSON 字符串
let dimCurrentName = null;   // 当前选中的配置文件名（不含 .json）
let dimActiveBindings = {};  // { mode -> configName } 所有模式的绑定关系

// 模式 id -> 显示标签
const MODE_LABELS = {
    multi_dim: '多维评分',
    subjective: '主观评分',
    quality: '质量比较',
    quality_slide: '质量比较2',
    test: '测试模式',
};
const MODE_ORDER = ['multi_dim', 'subjective', 'quality', 'quality_slide', 'test'];

function modeLabel(mode) { return MODE_LABELS[mode] || mode; }

// ── 模块路由（sidebar 导航） ──
const MODULES = {
    dashboard: { section: () => $('pageDashboard'), hash: '#dashboard' },
    files: { section: () => $('pageFiles'), hash: '#files' },
    tasks: { section: () => dimPage, hash: '#tasks' },
    models: { section: () => $('pageModels'), hash: '#models' },
    analyze: { section: () => $('pageAnalyze'), hash: '#analyze' },
    archive: { section: () => $('pageArchive'), hash: '#archive' },
    settings: { section: () => $('pageSettings'), hash: '#settings' },
    terminal: { section: () => $('pageTerminal'), hash: '#terminal' },
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
    if (name === 'terminal') {
        const sec = document.getElementById('pageTerminal');
        if (sec && typeof window.renderTerminalPage === 'function') {
            window.renderTerminalPage(sec);
        }
    }
    if (name === 'dashboard') { loadDashboard(); }
    if (name === 'tasks' && window.PXTasks && typeof window.PXTasks.onShow === 'function') {
        window.PXTasks.onShow();
    }
}
