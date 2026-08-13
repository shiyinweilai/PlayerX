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
    const emptyDiv = $('analyzeEmpty');
    const statsGrid = $('azStatsGrid');
    const rankSection = $('azRankSection');
    const pairSection = $('azPairSection');
    const chartSection = $('azChartSection');
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
                const sortedByTime = [...matched].sort((a, b) => a.max - b.max);
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
        if (chartSection) chartSection.hidden = true;
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

    function renderCurrentRankTable() {
        if (!multiTagResults.length) return;
        const idx = Math.min(currentRankTagIdx, multiTagResults.length - 1);
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
        const idx = Math.min(currentPairTagIdx, multiTagResults.length - 1);
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
                renderCurrentRankTable();
                renderCurrentPairTable();
            });
        });
    }

    // ── Chart.js 折线图 ───────────────────────────────────────

    let chartInstances = {};

    function destroyCharts() {
        Object.values(chartInstances).forEach(c => { try { c.destroy(); } catch (_) {} });
        chartInstances = {};
    }

    function renderCharts() {
        if (multiTagResults.length < 2) {
            if (chartSection) chartSection.hidden = true;
            destroyCharts();
            return;
        }
        if (chartSection) chartSection.hidden = false;

        const tags = multiTagResults.map(r => r.tag);

        // 收集所有模型（跨 Tag 去重）
        const allModels = new Set();
        multiTagResults.forEach(r => (r.models || []).forEach(m => allModels.add(m.name || m.model)));
        const modelList = [...allModels];

        // 构建每个指标的数据：{ model: [val_per_tag, ...] }
        function buildSeries(accessor) {
            return modelList.map(model => {
                const data = multiTagResults.map(r => {
                    const m = (r.models || []).find(x => (x.name || x.model) === model);
                    return m ? accessor(m) : null;
                });
                return { label: model, data };
            });
        }

        const eloSeries = buildSeries(m => m.elo);
        const shareSeries = buildSeries(m => m.strength);
        const meanSeries = buildSeries(m => m.mean);

        const chartColors = [
            '#3b82f6', '#ef4444', '#10b981', '#f59e0b', '#8b5cf6',
            '#ec4899', '#06b6d4', '#f97316', '#14b8a6', '#6366f1',
            '#84cc16', '#d946ef',
        ];

        function makeChart(canvasId, series, yLabel) {
            const ctx = document.getElementById(canvasId);
            if (!ctx) return;
            const canvas = ctx.getContext('2d');
            const datasets = series.map((s, i) => ({
                label: s.label,
                data: s.data,
                borderColor: chartColors[i % chartColors.length],
                backgroundColor: chartColors[i % chartColors.length] + '20',
                tension: 0.3,
                spanGaps: false,
                pointRadius: 5,
                pointHoverRadius: 8,
            }));
            chartInstances[canvasId] = new Chart(canvas, {
                type: 'line',
                data: { labels: tags, datasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    onClick: (e, els) => {
                        // 点击数据点 → 切换表格当前 Tag
                        if (!els || !els.length) return;
                        const idx = els[0].index;
                        if (idx >= 0 && idx < multiTagResults.length) {
                            currentRankTagIdx = idx;
                            currentPairTagIdx = idx;
                            renderCurrentRankTable();
                            renderCurrentPairTable();
                        }
                    },
                    plugins: {
                        legend: {
                            position: 'bottom',
                            labels: { boxWidth: 12, padding: 12, font: { size: 11 }, usePointStyle: true },
                        },
                    },
                    scales: {
                        x: { title: { display: true, text: 'Tag', font: { size: 12 } } },
                        y: { title: { display: true, text: yLabel, font: { size: 12 } } },
                    },
                },
            });
        }

        destroyCharts();
        makeChart('azChartElo', eloSeries, 'BT_Elo');
        makeChart('azChartShare', shareSeries, 'BT_share');
        makeChart('azChartMean', meanSeries, 'Mean');
    }

    // ── 主渲染入口 ───────────────────────────────────────────

    function renderAnalyzeResult(results) {
        resultDiv.style.display = '';
        emptyDiv.style.display = 'none';
        hideAnalyzeSections();

        multiTagResults = results;

        // 统计汇总（取第一个 Tag 的 stats）
        const first = results[0] || {};
        $('azStatTagCount').textContent = results.length;
        $('azStatFiles').textContent = results.reduce((s, r) => s + (r.fileCount || 0), 0);
        $('azStatRows').textContent = first.filtered ?? first.raw ?? '-';
        $('azStatGroups').textContent = first.completeGroups ?? '-';

        if (statsGrid) statsGrid.hidden = false;
        if (rankSection) rankSection.hidden = false;
        if (pairSection) pairSection.hidden = false;

        currentRankTagIdx = 0;
        currentPairTagIdx = 0;
        renderCurrentRankTable();
        renderCurrentPairTable();
        renderCharts();

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

        let tagsToUse = fromSelected ? [] : [...selectedTags];

        // 如果输入框有值但不在 selectedTags 中，追加
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
                if (j.results && j.results.length) {
                    showToast(`部分 Tag 失败：${j.errors.map(e => `${e.tag}:${e.error}`).join('; ')}`, 'warn');
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
