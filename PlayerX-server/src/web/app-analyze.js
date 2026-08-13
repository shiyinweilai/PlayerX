// ═══════════════════════════════════════════════════════════════════════
// 分析结果模块 —— 多 Tag 对比 + 折线图 + 模型排名表格
// ═══════════════════════════════════════════════════════════════════════
(function initAnalyzeModule() {
    const tagSel = $('analyzeTagSel');
    const tagMenu = $('analyzeTagMenu');
    const tagChips = $('analyzeTagChips');
    const tagClearBtn = $('analyzeTagClear');
    const runBtn = $('analyzeRunBtn');
    const shareBtn = $('analyzeShareBtn');
    const statusEl = $('analyzeStatus');
    const resultDiv = $('analyzeResult');
    const analyzeTooltip = $('analyzeTooltip');

    // 一级 tab 页面切换（"排名对照" / "问题诊断与详细排名"）
    const pagePanelRank = $('azPagePanelRank');
    const pagePanelDetail = $('azPagePanelDetail');
    const pageTabsBar = $('azPageTabs');
    function switchAnalyzePage(page) {
        document.querySelectorAll('.analyze-page-tab').forEach(btn => {
            btn.classList.toggle('is-active', btn.dataset.page === page);
        });
        if (pagePanelRank)   pagePanelRank.hidden   = (page !== 'rank');
        if (pagePanelDetail) pagePanelDetail.hidden = (page !== 'detail');
        // 切回 Tab 1：清 currentDetailTag，矩阵表无高亮（保留用户上次选择但不让界面看着"被锁"）
        if (page === 'rank' && currentDetailTag !== null) {
            currentDetailTag = null;
            currentRankTagIdx = 0;
            currentPairTagIdx = 0;
            renderMatrixTable();
        }
    }
    document.querySelectorAll('.analyze-page-tab').forEach(btn => {
        btn.addEventListener('click', () => switchAnalyzePage(btn.dataset.page));
    });
    const emptyDiv = $('analyzeEmpty');
    const statsGrid = $('azStatsGrid');
    const rankSection = $('azRankSection');
    const pairSection = $('azPairSection');
    const matrixSection = $('azMatrixSection');
    const tagTabs = $('azTagTabs');
    const pairTagTabs = $('azPairTagTabs');
    if (!tagSel || !runBtn) return;
    // 兼容：tagTabs/pairTagTabs 已废弃，统一用共享标签栏（azSharedTagTabs）

    const ANALYZE_RANK_COL_KEY = 'PlayerX.analyze.rank.colWidths.v1';
    const ANALYZE_PAIR_COL_KEY = 'PlayerX.analyze.pair.colWidths.v1';

    function ensureAnalyzeDefaultWidths() {
        const rankTable = $('azRankTable');
        const pairTable = $('azPairTable');
        if (rankTable) rankTable.style.width = 'auto';
        if (pairTable) pairTable.style.width = 'auto';
    }

    function initAnalyzeColumnResizing() {
        const rankSkip = ['model'];
        const pairSkip = ['modelA', 'modelB'];
        try {
            const r = JSON.parse(localStorage.getItem(ANALYZE_RANK_COL_KEY) || '{}');
            let rk = false;
            rankSkip.forEach(k => { if (r[k]) { delete r[k]; rk = true; } });
            if (rk) localStorage.setItem(ANALYZE_RANK_COL_KEY, JSON.stringify(r));
            const p = JSON.parse(localStorage.getItem(ANALYZE_PAIR_COL_KEY) || '{}');
            let pk = false;
            pairSkip.forEach(k => { if (p[k]) { delete p[k]; pk = true; } });
            if (pk) localStorage.setItem(ANALYZE_PAIR_COL_KEY, JSON.stringify(p));
        } catch (_) {}
        ensureAnalyzeDefaultWidths();
        initColumnResizing($('azRankTable'), { storageKey: ANALYZE_RANK_COL_KEY, skipCols: rankSkip });
        initColumnResizing($('azPairTable'), { storageKey: ANALYZE_PAIR_COL_KEY, skipCols: pairSkip });
    }

    initAnalyzeColumnResizing();

    let analyzeTags = [];
    let selectedTags = [];          // 当前选中的 Tag 列表
    let multiTagResults = [];       // 批量分析结果 [{tag, models, pairs, ...}]
    let currentRankTagIdx = 0;      // 当前表格展示的 Tag 索引
    let currentPairTagIdx = 0;
    // 当前「详细区域」绑定的 Tag：决定问题维度诊断 + 模型排名 + 成对检验显示哪个 Tag。
    // 单 Tag 模式：固定为唯一 Tag；多 Tag 模式：用户点矩阵表行 / Tag tabs 切换。
    let currentDetailTag = null;

    // ── Tag 多选逻辑 ──────────────────────────────────────────

    function toggleTag(tag) {
        const idx = selectedTags.indexOf(tag);
        if (idx >= 0) selectedTags.splice(idx, 1);
        else selectedTags.push(tag);
        renderTagChips();
        renderTagOptions(tagSel.value || '');
    }

    function renderTagChips() {
        if (!tagChips) return;
        tagChips.innerHTML = selectedTags.map(t =>
            `<span class="analyze-tag-chip">${esc(t)}<button class="analyze-tag-chip-rm" data-tag="${esc(t)}">&times;</button></span>`
        ).join('');
        tagChips.querySelectorAll('.analyze-tag-chip-rm').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                toggleTag(btn.dataset.tag);
            });
        });
        // 控制最右侧"清空"按钮的可见性
        if (tagClearBtn) tagClearBtn.style.display = selectedTags.length > 0 ? '' : 'none';
    }

    // 清空按钮（仅在有选中时显示）
    if (tagClearBtn) {
        tagClearBtn.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            selectedTags = [];
            renderTagChips();
            renderTagOptions(tagSel.value || '');
            tagSel.focus();
        });
    }

    function renderTagOptions(keyword = '') {
        if (!tagMenu) return;
        const kw = String(keyword || '').trim().toLowerCase();
        const matched = analyzeTags.filter(t => {
            if (kw && !t.tag.toLowerCase().includes(kw)) return false;
            return tagInTimeRange(t);
        });
        tagMenu.innerHTML = '';

        // ── 过滤工具条（时间预设 + 起止日期） ──
        const toolbar = document.createElement('div');
        toolbar.className = 'analyze-tag-toolbar';
        toolbar.innerHTML = `
            <div class="analyze-tag-presets">
                <button type="button" data-preset="all" ${tagTimeRange.preset === 'all' && !tagTimeRange.from && !tagTimeRange.to ? 'class="is-active"' : ''}>全部</button>
                <button type="button" data-preset="today" ${tagTimeRange.preset === 'today' ? 'class="is-active"' : ''}>今天</button>
                <button type="button" data-preset="7d" ${tagTimeRange.preset === '7d' ? 'class="is-active"' : ''}>7天</button>
                <button type="button" data-preset="30d" ${tagTimeRange.preset === '30d' ? 'class="is-active"' : ''}>30天</button>
                <button type="button" data-role="select-all" class="analyze-tag-select-all" title="全选当前过滤范围内的 Tag">全选</button>
            </div>
            <div class="analyze-tag-dates">
                <input type="date" data-role="from" value="${tagTimeRange.from || ''}" title="起始日期">
                <span>→</span>
                <input type="date" data-role="to" value="${tagTimeRange.to || ''}" title="结束日期">
            </div>
        `;
        tagMenu.appendChild(toolbar);

        // 全选按钮：把当前过滤范围内的 tag 按 max mtime 倒序加入
        const selectAllBtn = toolbar.querySelector('[data-role="select-all"]');
        if (selectAllBtn) {
            selectAllBtn.addEventListener('mousedown', e => e.preventDefault());
            selectAllBtn.addEventListener('click', e => {
                e.stopPropagation();
                const sortedByTime = [...matched].sort((a, b) => b.max - a.max);
                selectedTags = sortedByTime.map(t => t.tag);
                renderTagChips();
                renderTagOptions(tagSel.value || '');
            });
        }

        toolbar.querySelectorAll('.analyze-tag-presets button:not([data-role="select-all"])').forEach(btn => {
            btn.addEventListener('mousedown', e => e.preventDefault());
            btn.addEventListener('click', e => {
                e.stopPropagation();
                tagTimeRange.preset = btn.dataset.preset;
                renderTagOptions(tagSel.value || '');
            });
        });
        toolbar.querySelectorAll('.analyze-tag-dates input').forEach(input => {
            // 阻止 input 上的 mousedown 冒泡，否则外层 document click 会关闭下拉
            input.addEventListener('mousedown', e => e.preventDefault());
            input.addEventListener('change', e => {
                e.stopPropagation();
                tagTimeRange[input.dataset.role] = input.value;
                tagTimeRange.preset = 'custom';
                renderTagOptions(tagSel.value || '');
            });
            input.addEventListener('click', e => {
                e.stopPropagation();
                // Chrome/Edge 支持 showPicker()，直接调用即可在任意位置点击弹出日历
                if (typeof input.showPicker === 'function') {
                    try { input.showPicker(); } catch (_) {}
                }
            });
            // 防止日期 input 内部点击冒泡关闭下拉
            input.addEventListener('focus', e => e.stopPropagation());
            input.addEventListener('blur', e => { /* 保留，不关下拉 */ });
        });

        if (!matched.length) {
            const empty = document.createElement('div');
            empty.className = 'analyze-tag-option is-empty';
            empty.textContent = '无匹配 Tag';
            tagMenu.appendChild(empty);
            return;
        }
        matched.forEach(t => {
            const checked = selectedTags.includes(t.tag);
            const opt = document.createElement('button');
            opt.type = 'button';
            opt.className = 'analyze-tag-option' + (checked ? ' is-checked' : '');
            const dateStr = new Date(t.max).toISOString().slice(0, 10);
            opt.innerHTML = `<span class="analyze-tag-check">${checked ? '☑' : '☐'}</span> ${esc(t.tag)}<span class="analyze-tag-time">${dateStr}</span>`;
            opt.addEventListener('mousedown', (e) => e.preventDefault());
            opt.addEventListener('click', () => toggleTag(t.tag));
            tagMenu.appendChild(opt);
        });
    }

    function openTagDropdown() {
        renderTagOptions(tagSel.value || '');
        if (tagMenu) tagMenu.hidden = false;
    }

    function closeTagDropdown() {
        if (tagMenu) tagMenu.hidden = true;
    }

    async function loadTags() {
        try {
            const r = await fetch('/api/list');
            if (!r.ok) return;
            const j = await r.json();
            // 收集每个 tag 下的最早/最晚 mtime，用于时间过滤
            const tagInfo = new Map();  // tag -> {min, max}
            (j.items || []).forEach(f => {
                if (!f.tag || !f.mtime) return;
                const t = new Date(f.mtime).getTime();
                if (isNaN(t)) return;
                const cur = tagInfo.get(f.tag);
                if (!cur) tagInfo.set(f.tag, { min: t, max: t });
                else { if (t < cur.min) cur.min = t; if (t > cur.max) cur.max = t; }
            });
            analyzeTags = [...tagInfo.entries()]
                .map(([tag, t]) => ({ tag, min: t.min, max: t.max }))
                .sort((a, b) => a.tag.localeCompare(b.tag));
            renderTagOptions(tagSel.value || '');
        } catch (e) { console.warn('loadTags:', e); }
    }

    // ── 时间过滤器状态 ──
    let tagTimeRange = { preset: 'all', from: '', to: '' };  // preset: all/today/7d/30d

    function tagInTimeRange(tagInfo) {
        const r = tagTimeRange;
        if (r.preset === 'all' && !r.from && !r.to) return true;
        let fromTs = 0, toTs = Infinity;
        const now = Date.now();
        if (r.preset === 'today') {
            const d = new Date(); d.setHours(0, 0, 0, 0); fromTs = d.getTime();
            toTs = now;
        } else if (r.preset === '7d') {
            fromTs = now - 7 * 86400e3; toTs = now;
        } else if (r.preset === '30d') {
            fromTs = now - 30 * 86400e3; toTs = now;
        }
        if (r.from) { const v = new Date(r.from).getTime(); if (!isNaN(v)) fromTs = Math.max(fromTs, v); }
        if (r.to) { const v = new Date(r.to).getTime() + 86400e3; if (!isNaN(v)) toTs = Math.min(toTs, v); }
        // 至少有一个文件的 mtime 落在区间内
        return tagInfo.max >= fromTs && tagInfo.min <= toTs;
    }

    const obs = new MutationObserver(() => {
        const sec = $('pageAnalyze');
        if (sec && !sec.hidden) loadTags();
    });
    const sec = $('pageAnalyze');
    if (sec) obs.observe(sec, { attributes: true, attributeFilter: ['hidden'] });

    tagSel.addEventListener('focus', openTagDropdown);
    tagSel.addEventListener('click', openTagDropdown);
    tagSel.addEventListener('input', () => openTagDropdown());
    tagSel.addEventListener('keydown', (e) => {
        if (e.key === 'ArrowDown') {
            e.preventDefault();
            openTagDropdown();
            const first = tagMenu && tagMenu.querySelector('.analyze-tag-option:not(.is-empty)');
            if (first) first.focus();
        } else if (e.key === 'Escape') {
            closeTagDropdown();
        }
    });

    document.addEventListener('mousedown', (e) => {
        const field = $('analyzeTagField');
        if (!field) return;
        if (!field.contains(e.target)) closeTagDropdown();
    });

    function setAnalyzeStatus(text, type) {
        statusEl.textContent = text || '';
        statusEl.className = `analyze-status ${type ? 'is-' + type : ''}`.trim();
    }

    function hideAnalyzeSections() {
        if (rankSection) rankSection.hidden = true;
        if (pairSection) pairSection.hidden = true;
        if (matrixSection) matrixSection.hidden = true;
    }

    // ── 配色方案持久化 + 重渲染 ──────────────────────────────

    let lastRankData = null;
    const colorSchemeSel = document.getElementById('azRankColorScheme');
    if (colorSchemeSel && !colorSchemeSel._bound) {
        colorSchemeSel._bound = true;
        colorSchemeSel.addEventListener('change', () => {
            if (lastRankData) renderCurrentRankTable();
        });
    }

    // ── 色阶（与之前逻辑一致）─────────────────────────────────

    const COLOR_STOPS = [
        { n: 0.000, r: 0xD3, g: 0x2F, b: 0x2F },
        { n: 0.125, r: 0xF4, g: 0x43, b: 0x36 },
        { n: 0.250, r: 0xFF, g: 0x52, b: 0x52 },
        { n: 0.375, r: 0xFF, g: 0xCD, b: 0xD2 },
        { n: 0.500, r: 0xFF, g: 0xFF, b: 0xFF },
        { n: 0.625, r: 0xC8, g: 0xE6, b: 0xC9 },
        { n: 0.750, r: 0x4C, g: 0xAF, b: 0x50 },
        { n: 1.000, r: 0x38, g: 0x8E, b: 0x3C },
    ];

    function colorFromStops(norm) {
        if (norm == null) return null;
        for (let k = 0; k < COLOR_STOPS.length - 1; k++) {
            const a = COLOR_STOPS[k], b = COLOR_STOPS[k + 1];
            if (norm < a.n || norm > b.n) continue;
            const t = (norm - a.n) / (b.n - a.n);
            const r = Math.round(a.r + (b.r - a.r) * t);
            const g = Math.round(a.g + (b.g - a.g) * t);
            const bv = Math.round(a.b + (b.b - a.b) * t);
            return `rgb(${r},${g},${bv})`;
        }
        return norm <= 0 ? 'rgb(211,47,47)' : 'rgb(56,142,60)';
    }

    function textColorFor(norm) {
        if (norm == null) return '';
        if (norm < 0.25) return '#fff';
        if (norm < 0.45) return '#333';
        return '#1f2937';
    }

    const clamp01 = x => Math.max(0, Math.min(1, x));

    function normFor(col, m) {
        if (col === 'share') {
            const v = m.strength;
            if (v == null) return null;
            if (v >= 0.4) return clamp01(0.75 + (v - 0.4) / 0.6 * 0.25);
            if (v >= 0.15) return clamp01((v - 0.15) / 0.25 * 0.75);
            return clamp01(v / 0.15 * 0.3);
        }
        if (col === 'elo') {
            const v = m.elo;
            if (v == null) return null;
            if (v >= 50) return clamp01(0.7 + (v - 50) / 450 * 0.3);
            if (v >= -50) return clamp01(0.3 + (v + 50) / 100 * 0.4);
            return clamp01(0.3 - (Math.abs(v) - 50) / 450 * 0.3);
        }
        if (col === 'mean') {
            const v = m.mean;
            if (v == null) return null;
            if (v >= 4) return clamp01(0.7 + (v - 4) / 1 * 0.3);
            if (v >= 3) return clamp01(0.3 + (v - 3) / 1 * 0.4);
            return clamp01(0.3 - (3 - v) / 3 * 0.3);
        }
        if (col === 'ci') {
            if (m.ciLower == null || m.ciUpper == null) return null;
            const width = m.ciUpper - m.ciLower;
            if (width <= 0.5) return clamp01(0.7 + (0.5 - width) / 0.5 * 0.3);
            if (width <= 1.5) return clamp01(0.7 - (width - 0.5) / 1.0 * 0.4);
            return clamp01(0.3 - Math.min((width - 1.5) / 3.0, 1) * 0.3);
        }
        return null;
    }

    function getColorScheme() {
        const el = document.getElementById('azRankColorScheme');
        return el ? el.value : 'none';
    }

    function styleFor(norm) {
        const scheme = getColorScheme();
        if (scheme === 'none' || norm == null) return '';
        const bg = colorFromStops(norm);
        const tc = textColorFor(norm);
        if (scheme === 'text') return `color:${bg}`;
        return `background:${bg};color:${tc}`;
    }

    // ── 排名表渲染（按当前选中的 Tag）─────────────────────────

    function renderRankTable(tbody, models) {
        tbody.innerHTML = '';
        (models || []).forEach((m) => {
            const tr = document.createElement('tr');
            const n = m.n != null ? m.n : '-';
            const mean = m.mean != null ? m.mean.toFixed(3) : '-';
            const ciLower = m.ciLower != null ? m.ciLower.toFixed(3) : null;
            const ciUpper = m.ciUpper != null ? m.ciUpper.toFixed(3) : null;
            const ci = (ciLower != null && ciUpper != null) ? `[${ciLower}, ${ciUpper}]` : '-';
            const btShare = m.strength != null ? m.strength.toFixed(3) : '-';
            const btElo = m.elo != null ? (m.elo >= 0 ? '+' : '') + m.elo.toFixed(1) : '-';

            const nStyle = styleFor(null);
            const meanStyle = styleFor(normFor('mean', m));
            const ciStyle = styleFor(normFor('ci', m));
            const shareStyle = styleFor(normFor('share', m));
            const eloStyle = styleFor(normFor('elo', m));

            tr.innerHTML = `<td><b>${esc(m.name || m.model || '')}</b></td>`
                + `<td class="${nStyle ? 'clr' : ''}" style="${nStyle}">${n}</td>`
                + `<td class="${meanStyle ? 'clr' : ''}" style="${meanStyle}">${mean}</td>`
                + `<td class="${ciStyle ? 'clr' : ''}" style="${ciStyle}">${ci}</td>`
                + `<td class="${shareStyle ? 'clr' : ''}" style="${shareStyle}">${btShare}</td>`
                + `<td class="${eloStyle ? 'clr' : ''}" style="${eloStyle}">${btElo}</td>`;
            tbody.appendChild(tr);
        });
    }

    // 找 currentDetailTag 在 multiTagResults 里的 idx（找不到则 0）
    function getDetailTagIdx() {
        if (!multiTagResults.length) return -1;
        if (!currentDetailTag) return 0;
        const idx = multiTagResults.findIndex(r => r.tag === currentDetailTag);
        return idx >= 0 ? idx : 0;
    }

    function renderCurrentRankTable() {
        if (!multiTagResults.length) return;
        const idx = getDetailTagIdx();
        currentRankTagIdx = idx;
        currentPairTagIdx = idx;  // 两个表格同步
        const data = multiTagResults[idx];
        lastRankData = data;
        renderRankTable(document.querySelector('#azRankTable tbody'), data.models || []);
        renderSharedTagTabs();
    }

    function renderPairTable(tbody, pairs) {
        tbody.innerHTML = '';
        (pairs || []).forEach(p => {
            const tr = document.createElement('tr');
            const sigRaw = p.significant || '';
            const sigClass = sigRaw === '**' || sigRaw === '*' ? 'is-significant' : 'is-ns';
            const sigText = sigRaw === '**' ? '显著（p<0.01）' : sigRaw === '*' ? '显著（p<0.05）' : 'ns';
            tr.innerHTML = `<td>${esc(p.modelA || p.a || '')}</td>`
                + `<td>${esc(p.modelB || p.b || '')}</td>`
                + `<td>${p.aWins}</td><td>${p.bWins}</td>`
                + `<td>${p.signP != null ? p.signP.toFixed(4) : (p.p != null ? p.p.toFixed(4) : '-')}</td>`
                + `<td><span class="sig-badge ${sigClass}">${sigText}</span></td>`;
            tbody.appendChild(tr);
        });
    }

    function renderCurrentPairTable() {
        if (!multiTagResults.length) return;
        const idx = getDetailTagIdx();
        currentPairTagIdx = idx;
        currentRankTagIdx = idx;  // 两个表格同步
        const data = multiTagResults[idx];
        renderPairTable(document.querySelector('#azPairTable tbody'), data.pairs || []);
        renderSharedTagTabs();
    }

    // ── 共享 Tag 切换栏（独立放在表格上方，两个表格共用） ──

    const sharedTabsBar = $('azSharedTabsBar');
    const sharedTagTabs = $('azSharedTagTabs');

    function renderSharedTagTabs() {
        if (!sharedTagTabs) return;
        if (multiTagResults.length < 2) {
            if (sharedTabsBar) sharedTabsBar.hidden = true;
            sharedTagTabs.innerHTML = '';
            return;
        }
        if (sharedTabsBar) sharedTabsBar.hidden = false;
        sharedTagTabs.innerHTML = multiTagResults.map((r, i) =>
            `<button class="analyze-tag-tab${i === currentRankTagIdx ? ' is-active' : ''}" data-idx="${i}">${esc(r.tag)}</button>`
        ).join('');
        sharedTagTabs.querySelectorAll('.analyze-tag-tab').forEach(btn => {
            btn.addEventListener('click', () => {
                const idx = +btn.dataset.idx;
                currentRankTagIdx = idx;
                currentPairTagIdx = idx;  // 同步
                currentDetailTag = multiTagResults[idx]?.tag || null;
                renderCurrentRankTable();
                renderCurrentPairTable();
                renderProblemStats();
                renderMatrixTable();  // 重新渲染以更新 Tag 名高亮
            });
        });
    }

    // ── 多 Tag 排名对照表（替代原折线图）───────────────────────
    // 行 = 排名（rank 1..N），列 = 每个 Tag，
    // 单元格 = 该 Tag 下该排名的模型 + Mean / BT_Elo。
    // Rank 1/2/3 用金/银/铜色背景 + 🥇🥈🥉 标识。

    const MATRIX_TAG_PALETTE = [
        { bg: 'linear-gradient(180deg, #eff6ff, #dbeafe)', fg: '#1e3a8a' }, // 蓝
        { bg: 'linear-gradient(180deg, #fef3c7, #fde68a)', fg: '#78350f' }, // 琥珀
        { bg: 'linear-gradient(180deg, #dcfce7, #bbf7d0)', fg: '#14532d' }, // 绿
        { bg: 'linear-gradient(180deg, #fce7f3, #fbcfe8)', fg: '#831843' }, // 粉
        { bg: 'linear-gradient(180deg, #f3e8ff, #e9d5ff)', fg: '#581c87' }, // 紫
        { bg: 'linear-gradient(180deg, #cffafe, #a5f3fc)', fg: '#155e75' }, // 青
        { bg: 'linear-gradient(180deg, #ffedd5, #fed7aa)', fg: '#7c2d12' }, // 橙
        { bg: 'linear-gradient(180deg, #f1f5f9, #e2e8f0)', fg: '#334155' }, // 石板
    ];

    function renderMatrixTable() {
        if (multiTagResults.length < 2) {
            if (matrixSection) matrixSection.hidden = true;
            return;
        }
        if (matrixSection) matrixSection.hidden = false;

        // maxRank = 各 Tag 下最大模型数（按下标对齐）。
        const maxRank = Math.max(...multiTagResults.map(r => (r.models || []).length), 0);
        if (maxRank <= 0) {
            if (matrixSection) matrixSection.hidden = true;
            return;
        }

        // 表头：Tag | #1 | #2 | #3 | ... | #maxRank
        const thead = $('azMatrixThead');
        if (!thead) return;
        thead.innerHTML = '';
        const headTr = document.createElement('tr');
        headTr.appendChild(makeMatrixTh('Tag', 'matrix-th-tagcol'));
        for (let r = 1; r <= maxRank; r++) {
            headTr.appendChild(makeMatrixTh('#' + r, 'matrix-th-rank-cell'));
        }
        thead.appendChild(headTr);

        // tbody：每行 = 一个 Tag，每列 = 该 Tag 排名列表中的位置（按下标）。
        // 这样 tag 数量增长时纵向滚动天然友好（与"看每个 tag 排名"的盲评习惯一致）。
        const tbody = $('azMatrixTbody');
        if (!tbody) return;
        tbody.innerHTML = '';
        multiTagResults.forEach((r, idx) => {
            const color = MATRIX_TAG_PALETTE[idx % MATRIX_TAG_PALETTE.length];
            const row = document.createElement('tr');
            row.className = `matrix-row matrix-row-tag matrix-row-tag-${idx % MATRIX_TAG_PALETTE.length}`;
            if (r.tag === currentDetailTag) row.classList.add('matrix-row-active');

            // 第一列：Tag 名（冻结 + 可点击切换详情区域；当前选中加 is-active 高亮）
            const tagTd = document.createElement('td');
            tagTd.className = 'matrix-td-tagcol';
            tagTd.textContent = r.tag || `tag${idx + 1}`;
            if (r.tag === currentDetailTag) tagTd.classList.add('is-active');
            tagTd.setAttribute('data-tooltip', '点击跳转到「问题诊断与详细排名」');
            // JS 注入 tooltip：fixed 定位，规避父容器 overflow 裁切（首行 Tag 上方也能显示）
            tagTd.addEventListener('mouseenter', () => {
                if (analyzeTooltip) {
                    analyzeTooltip.textContent = '点击跳转到「问题诊断与详细排名」';
                    analyzeTooltip.hidden = false;
                    const r = tagTd.getBoundingClientRect();
                    analyzeTooltip.style.left = (r.left + r.width / 2) + 'px';
                    analyzeTooltip.style.top  = (r.top - 8) + 'px';
                }
            });
            tagTd.addEventListener('mouseleave', () => {
                if (analyzeTooltip) analyzeTooltip.hidden = true;
            });
            tagTd.addEventListener('click', () => {
                if (currentDetailTag === r.tag) {
                    // 已是当前 Tag，单纯切到详情页
                    switchAnalyzePage('detail');
                    return;
                }
                currentDetailTag = r.tag;
                currentRankTagIdx = idx;
                currentPairTagIdx = idx;
                renderMatrixTable();       // 重新渲染，更新高亮
                renderProblemStats();      // 刷新问题诊断
                renderCurrentRankTable();  // 刷新模型排名
                renderCurrentPairTable();  // 刷新成对检验
                switchAnalyzePage('detail'); // 切到「问题诊断与详细排名」tab
            });
            row.appendChild(tagTd);

            // 后续列：每个排名位
            for (let rowIdx = 0; rowIdx < maxRank; rowIdx++) {
                const displayRank = rowIdx + 1;
                const m = (r.models || [])[rowIdx];
                row.appendChild(makeMatrixTd(m, displayRank));
            }
            tbody.appendChild(row);
        });
    }

    function makeMatrixTh(text, cls) {
        const th = document.createElement('th');
        th.className = cls;
        th.textContent = text;
        return th;
    }

    function makeMatrixTd(m, displayRank) {
        const td = document.createElement('td');
        td.className = 'matrix-td-cell';
        if (!m) {
            td.classList.add('matrix-td-empty');
            td.textContent = '—';
            return td;
        }
        // 排名用 m.rank（后端 Bradley-Terry 排名），不是 m.n（n 是样本数）。
        // 行号 displayRank 是位置（按下标对齐），m.rank 才是该 Tag 内的真实 BT 排名。
        const actualRank = (m.rank != null) ? m.rank : displayRank;
        const medal = actualRank === 1 ? '🥇' : actualRank === 2 ? '🥈' : actualRank === 3 ? '🥉' : '';
        const fullName = m.name || m.model || '—';
        const short = shortModelName(fullName);
        const mean = m.mean != null ? m.mean.toFixed(3) : '—';
        const elo = m.elo != null ? Math.round(m.elo) : '—';

        td.title = `${fullName}\nBT 排名: ${actualRank} · 样本数: ${m.n != null ? m.n : '—'}`;
        td.innerHTML =
            `<div class="matrix-cell-name">` +
                (medal ? `<span class="matrix-medal">${medal}</span>` : '') +
                `<span class="matrix-name-text">${escapeHtmlMatrix(short)}</span>` +
                `<span class="matrix-cell-rank-badge">#${actualRank}</span>` +
            `</div>` +
            `<div class="matrix-cell-meta">Mean <b>${mean}</b> · Elo ${elo}</div>`;
        return td;
    }

    function shortModelName(name) {
        if (!name) return '—';
        // 取最后一段路径（去掉多级目录前缀）
        const last = String(name).split('/').pop() || String(name);
        return last;
    }

    function escapeHtmlMatrix(s) {
        return String(s).replace(/[&<>"']/g, c => (
            { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
        ));
    }

    // ── 问题维度诊断报告：每 Tag 一张热力表 ─────────────────────
    // 数据来源：multiTagResults[i].problemStats = { keys: [...], perModel: { "modelA": { "action_issue": 0.3, ... }, ... } }
    // 单元格颜色深度 ∝ 被勾选率；为 0 留白。
    // 空数据时（problemStats.keys.length === 0）显示引导文案，等客户端启用 checklist 同步后自动填充。

    const PROBLEM_LABEL_MAP = {
        action_issue:    '提示词遵循',
        physics_issue:   '物理规则',
        product_issue:   '商品一致',
        person_issue:    '人物一致',
        no_issue:        '都没问题',
    };

    function renderProblemStats() {
        const section = $('azProblemSection');
        const body = $('azProblemBody');
        if (!section || !body) return;
        if (!multiTagResults.length) {
            section.hidden = true;
            return;
        }
        // 单 Tag 模式：currentDetailTag 默认就指向唯一那个 Tag
        if (!currentDetailTag) currentDetailTag = multiTagResults[0].tag;
        const idx = getDetailTagIdx();
        const r = multiTagResults[idx];
        if (!r) {
            section.hidden = true;
            return;
        }
        section.hidden = false;
        body.innerHTML = '';

        const ps = r.problemStats || { keys: [], perModel: {} };
        const keys = ps.keys || [];

        if (keys.length === 0) {
            // 没有 checklist 数据时直接隐藏整个问题维度诊断 section
            section.hidden = true;
            return;
        }

        // 单 Tag 卡片：只渲染 currentDetailTag 的诊断
        const card = document.createElement('div');
        card.className = 'analyze-problem-card';

        // 标题：Tag 名（统一灰白，由 CSS 兜底）
        const head = document.createElement('div');
        head.className = 'analyze-problem-card-head';
        head.textContent = r.tag || `tag${idx + 1}`;
        card.appendChild(head);

        // 表
        const tableWrap = document.createElement('div');
        tableWrap.className = 'analyze-table-wrap';
        const table = document.createElement('table');
        table.className = 'analyze-table analyze-problem-table';

        // thead
        const thead = document.createElement('thead');
        const headTr = document.createElement('tr');
        headTr.appendChild(makeProblemTh('#', 'problem-th-rank-cell'));
        headTr.appendChild(makeProblemTh('模型', 'problem-th-model'));
        keys.forEach(k => {
            headTr.appendChild(makeProblemTh(PROBLEM_LABEL_MAP[k] || k, 'problem-th-key'));
        });
        thead.appendChild(headTr);
        table.appendChild(thead);

        // tbody：行 = 模型（按 BT 排名升序）
        const tbody = document.createElement('tbody');
        const models = (r.models || []).slice();
        const hasData = keys.length > 0 && ps.perModel && Object.keys(ps.perModel).length > 0;
        if (!hasData) {
            const tr = document.createElement('tr');
            const td = document.createElement('td');
            td.colSpan = keys.length + 2;
            td.className = 'analyze-problem-td-empty';
            td.textContent = '该 Tag 下暂无 checklist 数据';
            tr.appendChild(td);
            tbody.appendChild(tr);
        } else {
            models.forEach(m => {
                const tr = document.createElement('tr');
                // # 排名列（用 m.rank，即该 Tag 内的真实 BT 排名）
                const rankTd = document.createElement('td');
                rankTd.className = 'analyze-problem-td-rank';
                rankTd.textContent = (m.rank != null) ? '#' + m.rank : '—';
                tr.appendChild(rankTd);
                const nameTd = document.createElement('td');
                nameTd.className = 'analyze-problem-td-model';
                nameTd.textContent = shortModelName(m.name || m.model || '—');
                nameTd.title = m.name || m.model || '';
                tr.appendChild(nameTd);
                keys.forEach(k => {
                    const rate = (ps.perModel[m.name] || {})[k] || 0;
                    tr.appendChild(makeProblemTd(k, rate));
                });
                tbody.appendChild(tr);
            });
        }
        table.appendChild(tbody);

        tableWrap.appendChild(table);
        card.appendChild(tableWrap);
        body.appendChild(card);
    }

    function makeProblemTh(text, cls) {
        const th = document.createElement('th');
        th.className = cls;
        th.textContent = text;
        return th;
    }

    function makeProblemTd(key, rate) {
        const td = document.createElement('td');
        td.className = 'analyze-problem-td-cell';
        // 颜色：no_issue 越高越绿（好），其他 key 越高越红（差）
        // 颜色强度按 rate 线性插值
        const pct = Math.round(rate * 100);
        let bg, fg = '#0f172a';
        if (key === 'no_issue') {
            // 绿系
            bg = rateToGreen(rate);
        } else {
            // 红/橙系（缺陷）
            bg = rateToRed(rate);
        }
        td.style.background = bg;
        td.title = `${PROBLEM_LABEL_MAP[key] || key}: ${pct}%`;
        td.innerHTML = `<span class="problem-pct">${pct}<span class="problem-pct-pct">%</span></span>`;
        return td;
    }

    function rateToGreen(rate) {
        // rate 0 → 白，rate 1 → 深绿
        if (rate <= 0) return '#ffffff';
        const a = Math.min(1, rate);
        // 底色 #ecfdf5 淡绿
        return `rgba(16, 185, 129, ${(a * 0.45).toFixed(2)})`;
    }
    function rateToRed(rate) {
        if (rate <= 0) return '#ffffff';
        const a = Math.min(1, rate);
        // 底色淡红，rate 大时更深
        return `rgba(239, 68, 68, ${(a * 0.5).toFixed(2)})`;
    }

    // ── 主渲染入口 ───────────────────────────────────────────

    function renderAnalyzeResult(results) {
        resultDiv.style.display = '';
        emptyDiv.style.display = 'none';
        hideAnalyzeSections();

        multiTagResults = results;
        // 默认详情 Tag = null（不预设选中，矩阵表不显示高亮；详情面板按
        // getDetailTagIdx 回退到第一个 Tag 显示，让用户切到 Tab 2 立即看到内容）
        currentDetailTag = null;
        currentRankTagIdx = 0;
        currentPairTagIdx = 0;

        // 统计汇总（取第一个 Tag 的 stats）
        const first = results[0] || {};
        $('azStatTagCount').textContent = results.length;
        $('azStatFiles').textContent = results.reduce((s, r) => s + (r.fileCount || 0), 0);
        $('azStatRows').textContent = first.filtered ?? first.raw ?? '-';
        $('azStatGroups').textContent = first.completeGroups ?? '-';

        if (statsGrid) statsGrid.hidden = false;
        if (rankSection) rankSection.hidden = false;
        if (pairSection) pairSection.hidden = false;

        // 矩阵表在内部按 multiTagResults.length 决定是否隐藏（< 2 时隐藏）
        // 单 Tag 模式：直接展示该 Tag 的诊断 + 详情
        renderCurrentRankTable();
        renderCurrentPairTable();
        renderMatrixTable();
        renderProblemStats();

        // 单 Tag 时：隐藏 Tab 栏，自动跳转详情页
        if (results.length < 2) {
            if (pageTabsBar) pageTabsBar.hidden = true;
            currentDetailTag = results[0]?.tag || null;
            currentRankTagIdx = 0;
            currentPairTagIdx = 0;
            renderCurrentRankTable();
            renderCurrentPairTable();
            renderProblemStats();
            switchAnalyzePage('detail');
        } else {
            if (pageTabsBar) pageTabsBar.hidden = false;
            switchAnalyzePage('rank');
        }

        if (shareBtn && !window.__PX_SHARE_MODE__) shareBtn.disabled = false;
    }

    // ── 分享功能 ──────────────────────────────────────────────

    let _currentShareId = null;
    let _lastAnalyzeData = null;
    let _lastShareInfo = null;

    function setShareMode(on) {
        window.__PX_SHARE_MODE__ = !!on;
        if (shareBtn) shareBtn.style.display = on ? 'none' : '';
        if (tagSel) tagSel.disabled = on;
        if (runBtn) runBtn.disabled = on;
        if (emptyDiv) emptyDiv.style.display = on ? 'none' : '';
    }

    async function copyShareLink() {
        const data = _lastAnalyzeData;
        if (!data) { showToast('请先执行分析', 'warn'); return; }
        if (shareBtn) shareBtn.disabled = true;
        try {
            const tag = selectedTags.join(',');
            const r = await adminFetch('/api/analyze/share', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ tag, data, filesNames: [] }),
            });
            const j = await r.json();
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            _lastShareInfo = { id: j.id, shareUrl: j.shareUrl, createdAt: j.createdAt, tag };
            const fullUrl = `${window.location.protocol}//${window.location.host}${window.location.pathname}?share=${j.id}`;
            const ok = await _copyToClipboard(fullUrl);
            showToast(ok ? ('已复制分享链接') : ('分享已创建'), 'ok');
        } catch (e) {
            showToast('创建分享失败：' + e.message, 'err');
        } finally {
            if (shareBtn) shareBtn.disabled = false;
        }
    }

    async function _copyToClipboard(text) {
        try {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                await navigator.clipboard.writeText(text);
                return true;
            }
        } catch (_) {}
        try {
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed'; ta.style.left = '-9999px';
            document.body.appendChild(ta);
            ta.select();
            const ok = document.execCommand('copy');
            document.body.removeChild(ta);
            return ok;
        } catch (_) { return false; }
    }

    async function loadShareSnapshot(id) {
        setShareMode(true);
        _currentShareId = id;
        try {
            const r = await fetch(`/api/analyze/share/${id}`);
            const j = await r.json();
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            const snap = j.snapshot;
            if (tagSel) tagSel.value = snap.tag || '';
            if (snap.data && Array.isArray(snap.data)) {
                renderAnalyzeResult(snap.data);
            } else if (snap.data && snap.data.models) {
                // 旧格式单 Tag 数据
                multiTagResults = [{ tag: snap.tag || 'snapshot', ...snap.data }];
                renderAnalyzeResult(multiTagResults);
            }
        } catch (e) {
            showToast('分享加载失败：' + e.message, 'err');
            emptyDiv.style.display = '';
        }
    }

    function tryEnterShareFromUrl() {
        const m = window.location.search.match(/[?&]share=([A-Za-z0-9]{6,16})/);
        if (!m) return false;
        const id = m[1];
        try {
            if (typeof currentModule !== 'undefined' && currentModule !== 'analyze') {
                if (typeof switchModule === 'function') switchModule('analyze');
            }
        } catch (_) {}
        loadShareSnapshot(id);
        return true;
    }

    if (shareBtn) shareBtn.addEventListener('click', copyShareLink);

    const _obs2 = new MutationObserver(() => {
        const sec = $('pageAnalyze');
        if (sec && !sec.hidden) tryEnterShareFromUrl();
    });
    if (sec) _obs2.observe(sec, { attributes: true, attributeFilter: ['hidden'] });
    setTimeout(() => { tryEnterShareFromUrl(); }, 50);

    // ── 批量分析执行 ──────────────────────────────────────────

    async function runRankNow(opts = {}) {
        const names = Array.isArray(opts.names) ? opts.names.filter(Boolean) : null;
        const fromSelected = !!(names && names.length > 0);
        if (window.__PX_SHARE_MODE__) return;

        // 默认从用户在分析页选中的 tag 出发
        let tagsToUse = [...selectedTags];

        // 来自"分析选中"等外部入口：若传入了 tag（且非空），用它覆盖。
        // 修复：从评分文件页"分析选中"跳转过来时，opts.tag 之前被忽略，
        // 导致 tagsToUse 为空、函数静默 return，页面卡在"准备开始分析"。
        if (fromSelected && opts.tag != null) {
            const t = String(opts.tag).trim();
            if (t) tagsToUse = [t];
        }

        // 如果输入框有值但不在 tagsToUse 中，追加
        const inputTag = String(tagSel.value || '').trim();
        if (inputTag && !tagsToUse.includes(inputTag)) {
            tagsToUse = [inputTag];
        }

        if (tagsToUse.length === 0) {
            if (!opts.silentNoTag) showToast('请选择至少一个 Tag', 'warn');
            return;
        }

        setAnalyzeStatus('', '');
        runBtn.disabled = true;
        if (shareBtn) shareBtn.disabled = true;
        resultDiv.style.display = 'none';
        emptyDiv.style.display = 'none';

        try {
            // 统一走批量 API（单 Tag 也兼容）
            const r = await adminFetch('/api/analyze', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ tags: tagsToUse, action: 'rank' }),
            });
            const j = await r.json();
            if (!r.ok || !j.ok) throw new Error(j.error || '执行失败');
            if (j.errors && j.errors.length) {
                console.warn('[analyze/batch] 部分 Tag 失败:', j.errors);
                // 自动过滤无效 tag：服务端返回 errors 的 tag 视为"无有效数据"，
                // 从 selectedTags 移除 + 重新渲染 chip UI，并在顶部弹明显弹窗提醒。
                const invalidTags = j.errors.map(e => e.tag).filter(Boolean);
                if (invalidTags.length) {
                    const before = selectedTags.length;
                    selectedTags = selectedTags.filter(t => !invalidTags.includes(t));
                    if (selectedTags.length !== before) renderTagChips();
                    const detail = j.errors
                        .map(e => `${e.tag}${e.error ? `（${e.error}）` : ''}`)
                        .join('；');
                    showTopAlert(
                        `已自动过滤 ${invalidTags.length} 个无效 Tag`,
                        `这些 Tag 没有有效评分数据，已从选择中移除：${detail}`,
                        'warn'
                    );
                }
            }
            multiTagResults = j.results || [];
            _lastAnalyzeData = multiTagResults;
            if (multiTagResults.length === 0) {
                const errMsg = (j.errors && j.errors[0] && j.errors[0].error) || '所有 Tag 分析均失败';
                throw new Error(errMsg);
            }

            renderAnalyzeResult(multiTagResults);
            setAnalyzeStatus('', '');
        } catch (e) {
            showToast('' + e.message, 'err');
            setAnalyzeStatus('失败：' + e.message, 'error');
            emptyDiv.style.display = '';
        } finally {
            runBtn.disabled = false;
        }
    }

    runBtn.addEventListener('click', () => runRankNow());

    window.PXAnalyze = {
        runRankNow,
        loadShareSnapshot,
    };

    function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }
})();
