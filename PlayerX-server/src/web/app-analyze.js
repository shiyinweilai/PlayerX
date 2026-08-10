// ═══════════════════════════════════════════════════════════════════════
// 分析结果模块 —— 独立面板，按 tag 自动查找 map CSV + 评分文件 → 反解排名
// ═══════════════════════════════════════════════════════════════════════
(function initAnalyzeModule() {
    const tagSel = $('analyzeTagSel');
    const tagMenu = $('analyzeTagMenu');
    const verifyCb = $('analyzeDoVerify');
    const runBtn = $('analyzeRunBtn');
    const statusEl = $('analyzeStatus');
    const resultDiv = $('analyzeResult');
    const emptyDiv = $('analyzeEmpty');
    const statsGrid = $('azStatsGrid');
    const rankSection = $('azRankSection');
    const pairSection = $('azPairSection');
    if (!tagSel || !runBtn) return;

    const ANALYZE_RANK_COL_KEY = 'PlayerX.analyze.rank.colWidths.v1';
    const ANALYZE_PAIR_COL_KEY = 'PlayerX.analyze.pair.colWidths.v1';

    function ensureAnalyzeDefaultWidths() {
        const rankDefaults = { rank: 56, bt: 120, elo: 120, win: 120 };
        const pairDefaults = { aWins: 120, bWins: 120, p: 120, sig: 120 };

        const rankTable = $('azRankTable');
        const pairTable = $('azPairTable');

        if (rankTable) {
            const saved = loadSavedColWidths(ANALYZE_RANK_COL_KEY);
            rankTable.querySelectorAll('colgroup > col[data-col]').forEach(col => {
                const k = col.dataset.col;
                if (saved[k]) return;
                if (rankDefaults[k]) col.style.width = rankDefaults[k] + 'px';
            });
        }

        if (pairTable) {
            const saved = loadSavedColWidths(ANALYZE_PAIR_COL_KEY);
            pairTable.querySelectorAll('colgroup > col[data-col]').forEach(col => {
                const k = col.dataset.col;
                if (saved[k]) return;
                if (pairDefaults[k]) col.style.width = pairDefaults[k] + 'px';
            });
        }
    }

    function initAnalyzeColumnResizing() {
        ensureAnalyzeDefaultWidths();
        initColumnResizing($('azRankTable'), {
            storageKey: ANALYZE_RANK_COL_KEY,
            skipCols: [],
        });
        initColumnResizing($('azPairTable'), {
            storageKey: ANALYZE_PAIR_COL_KEY,
            skipCols: [],
        });
    }

    initAnalyzeColumnResizing();

    let analyzeTags = [];

    function renderTagOptions(keyword = '') {
        if (!tagMenu) return;
        const kw = String(keyword || '').trim().toLowerCase();
        const matched = analyzeTags.filter(t => !kw || t.toLowerCase().includes(kw)).slice(0, 200);
        tagMenu.innerHTML = '';
        if (!matched.length) {
            const empty = document.createElement('div');
            empty.className = 'analyze-tag-option is-empty';
            empty.textContent = '无匹配 Tag';
            tagMenu.appendChild(empty);
            return;
        }
        matched.forEach(t => {
            const opt = document.createElement('button');
            opt.type = 'button';
            opt.className = 'analyze-tag-option';
            opt.textContent = t;
            opt.addEventListener('mousedown', (e) => e.preventDefault());
            opt.addEventListener('click', () => {
                tagSel.value = t;
                closeTagDropdown();
            });
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

    // ── 加载可用 tag（从 uploads/ 目录中扫描所有独立 tag）──
    async function loadTags() {
        try {
            const r = await fetch('/api/list');
            if (!r.ok) return;
            const j = await r.json();
            const tags = new Set();
            (j.items || []).forEach(f => { if (f.tag) tags.add(f.tag); });
            analyzeTags = [...tags].sort();
            // 默认保持留空，不自动填充最新/第一个 tag
            renderTagOptions(tagSel.value || '');
        } catch (e) { console.warn('loadTags:', e); }
    }

    // 面板激活时刷新 tag 列表
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
        } else if (e.key === 'Enter' && tagMenu && !tagMenu.hidden) {
            const first = tagMenu.querySelector('.analyze-tag-option:not(.is-empty)');
            if (first) {
                e.preventDefault();
                first.click();
            }
        }
    });

    document.addEventListener('mousedown', (e) => {
        const field = tagSel.closest('.analyze-tag-field');
        if (!field) return;
        if (!field.contains(e.target)) closeTagDropdown();
    });

    function setAnalyzeStatus(text, type) {
        statusEl.textContent = text || '';
        statusEl.className = `analyze-status ${type ? `is-${type}` : ''}`.trim();
    }

    function hideAnalyzeSections() {
        if (rankSection) rankSection.hidden = true;
        if (pairSection) pairSection.hidden = true;
    }

    function renderRankTables(data) {
        // 排名表
        const rankTb = document.querySelector('#azRankTable tbody');
        rankTb.innerHTML = '';
        (data.models || []).forEach((m, i) => {
            const tr = document.createElement('tr');
            tr.innerHTML = `<td><span class="rank-index">${i + 1}</span></td><td><b>${esc(m.name || m.model || '')}</b></td><td>${m.strength != null ? m.strength.toFixed(4) : (m.bt != null ? m.bt.toFixed(3) : '-')}</td><td>${m.elo != null ? Math.round(m.elo) : '-'}</td><td>${m.mean != null ? m.mean.toFixed(2) : (m.winRate != null ? (m.winRate * 100).toFixed(1) + '%' : '-')}</td>`;
            rankTb.appendChild(tr);
        });

        // 成对检验表
        const pairTb = document.querySelector('#azPairTable tbody');
        pairTb.innerHTML = '';
        (data.pairs || []).forEach(p => {
            const tr = document.createElement('tr');
            const sigRaw = p.significant || '';
            const sigClass = sigRaw === '**' || sigRaw === '*' ? 'is-significant' : 'is-ns';
            const sigText = sigRaw === '**' ? '显著（p<0.01）' : sigRaw === '*' ? '显著（p<0.05）' : 'ns';
            tr.innerHTML = `<td>${esc(p.modelA || p.a || '')}</td><td>${esc(p.modelB || p.b || '')}</td><td>${p.aWins}</td><td>${p.bWins}</td><td>${p.signP != null ? p.signP.toFixed(4) : (p.p != null ? p.p.toFixed(4) : '-')}</td><td><span class="sig-badge ${sigClass}">${sigText}</span></td>`;
            pairTb.appendChild(tr);
        });
    }

    function renderAnalyzeResult(data) {
        resultDiv.style.display = '';
        emptyDiv.style.display = 'none';
        hideAnalyzeSections();

        // 仅展示 rank 结果 + 反解状态 + verify 概况
        $('azStatFiles').textContent = data.fileCount ?? '-';
        $('azStatRows').textContent = data.filtered ?? data.raw ?? '-';
        $('azStatDedup').textContent = data.deduped ?? '-';
        $('azStatGroups').textContent = data.completeGroups ?? '-';
        const deanonOk = Number(data.deanonRows || 0) > 0;
        $('azStatDeanonOk').textContent = deanonOk ? `成功（${data.deanonRows}）` : '失败';
        if (statsGrid) statsGrid.hidden = false;
        if (rankSection) rankSection.hidden = false;
        if (pairSection) pairSection.hidden = false;
        renderRankTables(data || {});
    }

    async function runRankNow(opts = {}) {
        const names = Array.isArray(opts.names) ? opts.names.filter(Boolean) : null;
        const tag = (opts.tag != null ? String(opts.tag) : String(tagSel.value || '')).trim();
        const fromSelected = !!(names && names.length > 0);

        // 手动触发（非“分析选中”）时要求有 tag
        if (!fromSelected && !tag) {
            if (!opts.silentNoTag) showToast('请选择 Tag', 'warn');
            return;
        }

        if (tag && tagSel.value !== tag) tagSel.value = tag;

        setAnalyzeStatus('', '');
        runBtn.disabled = true;
        resultDiv.style.display = 'none';
        emptyDiv.style.display = 'none';

        try {
            const payload = { action: 'rank' };
            if (fromSelected) {
                payload.names = names;
                if (tag) payload.tag = tag;
            } else {
                payload.tag = tag;
            }

            const r = await adminFetch('/api/analyze', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            const j = await r.json();
            if (!r.ok || !j.ok) throw new Error(j.error || '执行失败');
            renderAnalyzeResult(j.data);
            setAnalyzeStatus('', '');
        } catch (e) {
            showToast('❌ ' + e.message, 'err');
            setAnalyzeStatus('失败：' + e.message, 'error');
            emptyDiv.style.display = '';
        } finally {
            runBtn.disabled = false;
        }
    }

    // ── 手动执行 rank（按 Tag）──
    runBtn.addEventListener('click', () => runRankNow());

    // 暴露给“分析选中”按钮：切页后直接执行
    window.PXAnalyze = {
        runRankNow,
    };

    function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }
})();
