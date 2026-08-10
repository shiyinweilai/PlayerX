// ═══════════════════════════════════════════════════════════════════════
// 分析结果模块 —— 独立面板，按 tag 自动查找 map CSV + 评分文件 → 反解排名
// ═══════════════════════════════════════════════════════════════════════
(function initAnalyzeModule() {
    const tagSel = $('analyzeTagSel');
    const tagMenu = $('analyzeTagMenu');
    const verifyCb = $('analyzeDoVerify');
    const runBtn = $('analyzeRunBtn');
    const shareBtn = $('analyzeShareBtn');
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
        // 不再设默认列宽，统一让浏览器按内容自适应；
        // 表格 width: 100% 改为 auto，避免剩余列被强制拉伸。
        // 已保存的用户自定义宽度（localStorage）仍生效。
        const rankTable = $('azRankTable');
        const pairTable = $('azPairTable');
        if (rankTable) rankTable.style.width = 'auto';
        if (pairTable) pairTable.style.width = 'auto';
    }

    function initAnalyzeColumnResizing() {
        // 模型名列表不参与列宽持久化与拖拽，按内容自动撑开
        const rankSkip = ['model'];
        const pairSkip = ['modelA', 'modelB'];
        // 清掉旧版本可能存档的旧宽度（这些列后续改为自适应）
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
        initColumnResizing($('azRankTable'), {
            storageKey: ANALYZE_RANK_COL_KEY,
            skipCols: rankSkip,
        });
        initColumnResizing($('azPairTable'), {
            storageKey: ANALYZE_PAIR_COL_KEY,
            skipCols: pairSkip,
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
        // 渲染前先清掉模型列可能残留的 inline width（之前版本或拖拽存进 col.style.width
        // 都会强制截断），让浏览器按本次数据里最长的名字自动撑开。
        const rankTable = $('azRankTable');
        const pairTable = $('azPairTable');
        if (rankTable) {
            const c = rankTable.querySelector('colgroup > col[data-col="model"]');
            if (c) c.style.width = '';
        }
        if (pairTable) {
            pairTable.querySelectorAll('colgroup > col[data-col="modelA"], colgroup > col[data-col="modelB"]').forEach(c => c.style.width = '');
        }

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
        // 启用分享按钮（仅非分享快照模式）
        if (shareBtn && !window.__PX_SHARE_MODE__) shareBtn.disabled = false;
    }

    // ── 分享功能 ──────────────────────────────────────────
    // 维护当前 share 模式状态：URL 携带 ?share=xxx 时进入只读展示
    let _currentShareId = null;
    let _lastAnalyzeData = null;
    let _lastShareInfo = null; // { id, shareUrl, createdAt, tag }

    function setShareMode(on) {
        window.__PX_SHARE_MODE__ = !!on;
        if (shareBtn) shareBtn.style.display = on ? 'none' : '';
        // 关闭必要控件
        if (tagSel)    tagSel.disabled = on;
        if (runBtn)    runBtn.disabled = on;
        if (emptyDiv)  emptyDiv.style.display = on ? 'none' : '';
    }

    function fmtShareTime(iso) {
        if (!iso) return '—';
        try {
            const d = new Date(iso);
            if (isNaN(d.getTime())) return iso;
            const pad = n => String(n).padStart(2, '0');
            return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
        } catch (_) { return iso; }
    }

    // ── 管理员：保存快照 + 复制链接 ──────────────────────────
    async function copyShareLink() {
        const data = _lastAnalyzeData;
        if (!data) { showToast('请先执行分析', 'warn'); return; }
        if (shareBtn) shareBtn.disabled = true;
        try {
            const tag = (tagSel.value || '').trim();
            const r = await adminFetch('/api/analyze/share', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    tag,
                    data,
                    filesNames: (data.items || []).map(it => it.name).filter(Boolean),
                }),
            });
            const j = await r.json();
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            _lastShareInfo = { id: j.id, shareUrl: j.shareUrl, createdAt: j.createdAt, tag };
            const fullUrl = `${window.location.protocol}//${window.location.host}${window.location.pathname}?share=${j.id}`;
            const ok = await _copyToClipboard(fullUrl);
            showToast(ok ? (`✅ 已复制分享链接：${fullUrl}`) : (`分享已创建：${fullUrl}`), 'ok');
        } catch (e) {
            showToast('❌ 创建分享失败：' + e.message, 'err');
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
            ta.style.position = 'fixed';
            ta.style.left = '-9999px';
            document.body.appendChild(ta);
            ta.select();
            const ok = document.execCommand('copy');
            document.body.removeChild(ta);
            return ok;
        } catch (_) { return false; }
    }

    // ── 公开：根据 ?share= 加载只读快照 ───────────────────────
    async function loadShareSnapshot(id) {
        setShareMode(true);
        _currentShareId = id;
        try {
            const r = await fetch(`/api/analyze/share/${id}`);
            const j = await r.json();
            if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
            const snap = j.snapshot;
            if (tagSel) tagSel.value = snap.tag || '';
            renderAnalyzeResult(snap.data);
        } catch (e) {
            showToast('❌ 分享加载失败：' + e.message, 'err');
            emptyDiv.style.display = '';
        }
    }

    // ── 路由：URL 含 ?share=xxx 时进入只读模式 ─────────────────
    function tryEnterShareFromUrl() {
        const m = window.location.search.match(/[?&]share=([A-Za-z0-9]{6,16})/);
        if (!m) return false;
        const id = m[1];
        // 切换到分析模块（确保可见）
        try {
            if (typeof currentModule !== 'undefined' && currentModule !== 'analyze') {
                if (typeof switchModule === 'function') switchModule('analyze');
            }
        } catch (_) {}
        loadShareSnapshot(id);
        return true;
    }

    // 绑定分享按钮
    if (shareBtn) shareBtn.addEventListener('click', copyShareLink);

    // 当面板激活时尝试 URL 分享 + 刷新分享列表
    const _obs2 = new MutationObserver(() => {
        const sec = $('pageAnalyze');
        if (sec && !sec.hidden) {
            tryEnterShareFromUrl();
        }
    });
    if (sec) _obs2.observe(sec, { attributes: true, attributeFilter: ['hidden'] });
    // 启动时也跑一次（防止当前就在 analyze 模块）
    setTimeout(() => { tryEnterShareFromUrl(); }, 50);

    async function runRankNow(opts = {}) {
        const names = Array.isArray(opts.names) ? opts.names.filter(Boolean) : null;
        const tag = (opts.tag != null ? String(opts.tag) : String(tagSel.value || '')).trim();
        const fromSelected = !!(names && names.length > 0);

        // 分享快照模式下不允许手动执行
        if (window.__PX_SHARE_MODE__) return;

        // 手动触发（非“分析选中”）时要求有 tag
        if (!fromSelected && !tag) {
            if (!opts.silentNoTag) showToast('请选择 Tag', 'warn');
            return;
        }

        if (tag && tagSel.value !== tag) tagSel.value = tag;

        setAnalyzeStatus('', '');
        runBtn.disabled = true;
        if (shareBtn) shareBtn.disabled = true;
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
            _lastAnalyzeData = j.data;
            renderAnalyzeResult(j.data);
            setAnalyzeStatus('', '');
        } catch (e) {
            showToast('❌ ' + e.message, 'err');
            setAnalyzeStatus('失败：' + e.message, 'error');
            emptyDiv.style.display = '';
        } finally {
            runBtn.disabled = false;
            // 分享按钮在 renderAnalyzeResult 中已根据状态启用
        }
    }

    // ── 手动执行 rank（按 Tag）──
    runBtn.addEventListener('click', () => runRankNow());

    // 暴露给“分析选中”按钮：切页后直接执行
    window.PXAnalyze = {
        runRankNow,
        loadShareSnapshot,
    };

    function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }
})();
