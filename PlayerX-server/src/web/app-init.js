'use strict';

// ────────── 列宽拖拽（主表 #filesTable） ──────────
// 让用户像 Finder/资源管理器那样能直接拖动列宽：
//   - 通过 <colgroup><col data-col="..."> 控制宽度，避免与 nth-child 选择器耦合；
//   - 文件名列（data-col="name"）不直接拖宽，它由 table-layout:fixed 自动占据剩余空间；
//   - 拖动相邻列时，文件名列会自然让出 / 收回空间，符合直觉；
//   - 自定义宽度持久化到 localStorage，刷新后恢复。
const COL_WIDTHS_KEY = 'PlayerX.colWidths.v1';
const COL_MIN_WIDTH = 60;     // 最小列宽，避免拖到 0 让内容糊在一起
const COL_MAX_WIDTH = 800;    // 上限，防误操作把单列拉得过宽

function loadSavedColWidths(storageKey = COL_WIDTHS_KEY) {
    try {
        const raw = localStorage.getItem(storageKey);
        if (!raw) return {};
        const obj = JSON.parse(raw);
        return (obj && typeof obj === 'object') ? obj : {};
    } catch (_) { return {}; }
}
function saveColWidth(colKey, px, storageKey = COL_WIDTHS_KEY) {
    const cur = loadSavedColWidths(storageKey);
    cur[colKey] = px;
    try { localStorage.setItem(storageKey, JSON.stringify(cur)); } catch (_) { }
}
function applySavedColWidths(table, options = {}) {
    const { storageKey = COL_WIDTHS_KEY, skipCols = ['name'] } = options;
    const skipSet = new Set(skipCols || []);
    const saved = loadSavedColWidths(storageKey);
    const cols = table.querySelectorAll('colgroup > col[data-col]');
    cols.forEach(col => {
        const k = col.dataset.col;
        if (skipSet.has(k)) return;
        if (saved[k]) col.style.width = saved[k] + 'px';
    });
}

function initColumnResizing(table, options = {}) {
    if (!table || table.dataset.resizableInit === '1') return;
    table.dataset.resizableInit = '1';

    const {
        storageKey = COL_WIDTHS_KEY,
        skipCols = ['name', 'actions', 'check'],
    } = options;
    const skipSet = new Set(skipCols || []);

    // 先把保存过的宽度灌进去
    applySavedColWidths(table, { storageKey, skipCols });

    const ths = table.querySelectorAll('thead th[data-col]');
    ths.forEach(th => {
        const colKey = th.dataset.col;
        if (skipSet.has(colKey)) return;

        const grip = document.createElement('span');
        grip.className = 'col-resizer';
        grip.title = '拖动以调整列宽';
        // 阻止冒泡到 th 的排序点击逻辑（th.sortable 会触发排序）
        grip.addEventListener('click', (e) => { e.stopPropagation(); });
        grip.addEventListener('mousedown', (e) => {
            e.preventDefault();
            e.stopPropagation();
            startColResize(table, colKey, e.clientX, grip, storageKey);
        });
        th.appendChild(grip);
    });
}

function startColResize(table, colKey, startX, gripEl, storageKey = COL_WIDTHS_KEY) {
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
        if (finalW > 0) saveColWidth(colKey, finalW, storageKey);
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
