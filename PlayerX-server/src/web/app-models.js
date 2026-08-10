'use strict';
// ═══════════════════════════════════════════════════════════════
//模型管理模块
// ═══════════════════════════════════════════════════════════════
let modelsData = [];
let modelsScope = 'all'; // 'all' | 'personal' | 'team'

function renderModelsNeedLogin(container) {
    if (!container) return;
    container.innerHTML = `
            <div class="mdl-login-guard">
                <div class="mdl-login-guard-icon">🔒</div>
                <div class="mdl-login-guard-title">需要登录后访问模型管理</div>
                <div class="mdl-login-guard-desc">请先输入管理员密码，再进行模型目录查看与管理</div>
                <button class="mdl-btn mdl-btn-add mdl-login-guard-btn">立即登录</button>
            </div>`;
    const btn = container.querySelector('.mdl-login-guard-btn');
    if (btn) btn.addEventListener('click', () => openLoginDialog());
}

async function renderModelsPage() {
    const container = document.querySelector('.models-page');
    if (!container) return;

    if (auth.enabled && !isLoggedIn()) {
        renderModelsNeedLogin(container);
        openLoginDialog();
        return;
    }

    container.innerHTML = '<div style="padding:40px;color:#64748b;text-align:center">加载中...</div>';
    try {
        const r = await adminFetch('/api/models');
        if (r.status === 401) {
            renderModelsNeedLogin(container);
            return;
        }
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
                    <button class="mdl-scope-tab ${modelsScope === 'all' ? 'active' : ''}" data-scope="all">全部</button>
        <button class="mdl-scope-tab ${modelsScope === 'personal' ? 'active' : ''}" data-scope="personal"><svg class="inline-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg> 个人</button>
       <button class="mdl-scope-tab ${modelsScope === 'team' ? 'active' : ''}" data-scope="team"><svg class="inline-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg> 团队</button>
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
                panel.querySelector('.mdl-tree-filter').addEventListener('input', function () {
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
                panel.querySelector('.mdl-tree-selectall-cb').addEventListener('change', async function () {
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
        btn.addEventListener('click', async function () {
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
                    subBtn.addEventListener('click', async function () {
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

