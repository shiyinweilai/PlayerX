/**
 * PlayerX-server 盲评分析模块（内嵌于主页面）
 *
 * 依赖 window.PX（由 app.js 暴露）提供的共享 API。
 * 对外暴露 window.PXAnalyze = { setFiles(names), onShow() }
 */
(function () {
    'use strict';

    const $ = (id) => document.getElementById(id);
    const PX = () => window.PX;

    // ── 模块状态 ──
    let currentConfig = null;
    let configs = [];
    let isJsonMode = false;
    let analyzeFiles = [];   // 当前选中的分析文件
    let initialized = false;

    // ── 工具 ──
    function esc(s) { return PX().escHtml(s); }
    function toast(msg, kind) { PX().showToast(msg, kind); }
    function adminFetch(path, opts) { return PX().adminFetch(path, opts); }
    function isLoggedIn() { return PX().isLoggedIn(); }
    function openLogin() { PX().openLoginDialog(); }

    // ── Tab 切换 ──
    function switchTab(name) {
        document.querySelectorAll('.an-tab').forEach(t => {
            t.classList.toggle('active', t.dataset.tab === name);
        });
        document.querySelectorAll('.an-tab-page').forEach(p => {
            p.classList.toggle('active', p.id === 'anTab' + name.charAt(0).toUpperCase() + name.slice(1));
        });
    }

    // ── 表单 ↔ JSON 同步 ──
    function jsonToForm(obj) {
        $('af_tag').value = obj.tag || '';
        $('af_nGroups').value = obj.n_groups || 5;
        $('af_groupMode').value = obj.group_mode || 'fresh';
        $('af_seed').value = obj.seed || 42;
        $('af_models').value = (obj.models || []).join('\n');
        $('af_srcDir').value = obj.src_model_dir || '';
        $('af_dstDir').value = obj.dst_dir || '';
        $('af_mapCsv').value = obj.map_csv || '';
        $('af_deanonCsv').value = obj.deanon_csv || 'playerx_selected_deanon.csv';
        $('af_samples').value = (obj.samples || []).join(',');
        $('af_excludeSamples').value = (obj.exclude_samples || []).join(',');
        $('af_excludeRaters').value = (obj.exclude_raters || []).join(',');
        $('af_dimensions').value = (obj.dimensions || ['multi_总分']).join(',');
    }

    function formToJson() {
        const parseList = (s) => s.split(/[,\n]/).map(x => x.trim()).filter(Boolean);
        const parseNumList = (s) => s.split(/[,\n]/).map(x => parseInt(x.trim(), 10)).filter(n => !isNaN(n));
        const obj = {};
        const tag = $('af_tag').value.trim();
        if (tag) obj.tag = tag;
        obj.n_groups = parseInt($('af_nGroups').value, 10) || 5;
        obj.group_mode = $('af_groupMode').value;
        obj.seed = parseInt($('af_seed').value, 10) || 42;
        obj.models = parseList($('af_models').value);
        const srcDir = $('af_srcDir').value.trim();
        if (srcDir) obj.src_model_dir = srcDir;
        const dstDir = $('af_dstDir').value.trim();
        if (dstDir) obj.dst_dir = dstDir;
        const mapCsv = $('af_mapCsv').value.trim();
        if (mapCsv) obj.map_csv = mapCsv;
        obj.deanon_csv = $('af_deanonCsv').value.trim() || 'playerx_selected_deanon.csv';
        const samples = parseNumList($('af_samples').value);
        if (samples.length > 0) obj.samples = samples;
        const excludeSamples = parseNumList($('af_excludeSamples').value);
        if (excludeSamples.length > 0) obj.exclude_samples = excludeSamples;
        const excludeRaters = parseList($('af_excludeRaters').value);
        if (excludeRaters.length > 0) obj.exclude_raters = excludeRaters;
        const dims = parseList($('af_dimensions').value);
        if (dims.length > 0) obj.dimensions = dims;
        return obj;
    }

    function jsonTextToObj() { return JSON.parse($('anJsonEditor').value); }
    function objToJsonText(obj) { $('anJsonEditor').value = JSON.stringify(obj, null, 2); }

    function getCurrentConfigObj() {
        return isJsonMode ? jsonTextToObj() : formToJson();
    }

    // ── 模式切换 ──
    function setJsonMode(on) {
        isJsonMode = on;
        $('anFormMode').style.display = on ? 'none' : '';
        $('anJsonMode').classList.toggle('visible', on);
        $('anToggleJson').textContent = on ? '表单编辑' : '直接编辑 JSON';
        $('anToggleJson').classList.toggle('active-mode', on);
        $('anFmtJson').style.display = on ? '' : 'none';
        if (on) {
            try { objToJsonText(formToJson()); } catch (_) {}
        } else {
            try {
                jsonToForm(jsonTextToObj());
                $('anJsonErr').style.display = 'none';
            } catch (e) {
                $('anJsonErr').textContent = 'JSON 格式错误: ' + e.message;
                $('anJsonErr').style.display = 'block';
                return;
            }
        }
    }

    // ── 配置列表 ──
    async function loadConfigList() {
        const listEl = $('anCfgList');
        try {
            const r = await fetch('/api/analyze-configs');
            const j = await r.json();
            if (!j.ok) throw new Error(j.error || '加载失败');
            configs = j.configs || [];
            renderConfigList();
        } catch (e) {
            listEl.innerHTML = `<div class="an-cfg-empty" style="color:var(--danger)">加载失败: ${esc(e.message)}</div>`;
        }
    }

    function renderConfigList() {
        const listEl = $('anCfgList');
        if (configs.length === 0) {
            listEl.innerHTML = `<div class="an-cfg-empty">暂无配置，点击 ＋ 新建</div>`;
            return;
        }
        listEl.innerHTML = configs.map(c => `
            <div class="an-cfg-item ${c.name === currentConfig ? 'active' : ''}" data-name="${esc(c.name)}">
                <div class="n">${esc(c.name)}</div>
                <div class="m">${c.tag ? 'tag: ' + esc(c.tag) : ''} · ${c.models || 0} 模型</div>
                <span class="del" data-del="${esc(c.name)}" title="删除">×</span>
            </div>
        `).join('');

        listEl.querySelectorAll('.an-cfg-item').forEach(el => {
            el.addEventListener('click', (e) => {
                if (e.target.classList.contains('del')) return;
                selectConfig(el.dataset.name);
            });
        });
        listEl.querySelectorAll('.del').forEach(el => {
            el.addEventListener('click', async (e) => {
                e.stopPropagation();
                const name = el.dataset.del;
                const ok = await PX().confirmDialog('删除配置', `确定删除配置「${name}」？`, '🗑️');
                if (!ok) return;
                try {
                    const r = await adminFetch(`/api/analyze-configs/${encodeURIComponent(name)}`, { method: 'DELETE' });
                    const j = await r.json();
                    if (!j.ok) throw new Error(j.error);
                    toast(`已删除「${name}」`, 'ok');
                    if (currentConfig === name) { currentConfig = null; $('anCfgName').textContent = ''; }
                    await loadConfigList();
                } catch (e2) { toast('删除失败: ' + e2.message, 'err'); }
            });
        });
    }

    async function selectConfig(name) {
        currentConfig = name;
        renderConfigList();
        try {
            const r = await fetch(`/api/analyze-configs/${encodeURIComponent(name)}`);
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const text = await r.text();
            const obj = JSON.parse(text);
            objToJsonText(obj);
            jsonToForm(obj);
            $('anCfgName').textContent = name;
            $('anJsonErr').style.display = 'none';
            setJsonMode(false);
            switchTab('editor');
        } catch (e) {
            toast('加载配置失败: ' + e.message, 'err');
        }
    }

    // ── 新建配置 ──
    async function addConfig() {
        if (!isLoggedIn()) { toast('请先登录', 'warn'); openLogin(); return; }
        const trimmed = 'config_' + (configs.length + 1);
     try {
         const defaultCfg = {
tag: '',
              src_model_dir: '/data/daxinli/projects/HOIVLMBench',
       dst_dir: '',
      models: [
           'wan2.2_14b_gptc_lora6000x8',
           'wan2.2_14b_highonly_sft_aligned_5000x56',
  'wan2.2_14b_sft_aligned_10000x56',
             ],
     n_groups: 5,
   map_csv: 'map_subj.csv',
            deanon_csv: 'playerx_selected_deanon.csv',
       };
  const r = await adminFetch(`/api/analyze-configs/${encodeURIComponent(trimmed)}`, {
 method: 'PUT',
       headers: { 'Content-Type': 'application/json' },
         body: JSON.stringify(defaultCfg),
    });
          const j = await r.json();
    if (!j.ok) throw new Error(j.error);
 await loadConfigList();
    selectConfig(trimmed);
    } catch (e) { toast('创建失败: ' + e.message, 'err'); }
    }

    // ── JSON 格式化 / 保存 ──
    function formatJson() {
        try {
            objToJsonText(jsonTextToObj());
            $('anJsonErr').style.display = 'none';
        } catch (e) {
            $('anJsonErr').textContent = 'JSON 格式错误: ' + e.message;
            $('anJsonErr').style.display = 'block';
        }
    }

    async function saveConfig() {
        if (!currentConfig) { toast('请先选择配置', 'warn'); return; }
        if (!isLoggedIn()) { toast('请先登录', 'warn'); openLogin(); return; }
        let obj;
        try { obj = getCurrentConfigObj(); }
        catch (e) {
            $('anJsonErr').textContent = 'JSON 格式错误: ' + e.message;
            $('anJsonErr').style.display = 'block';
            return;
        }
        $('anJsonErr').style.display = 'none';
        try {
            const r = await adminFetch(`/api/analyze-configs/${encodeURIComponent(currentConfig)}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(obj),
            });
            const j = await r.json();
            if (!j.ok) throw new Error(j.error);
            toast(`已保存「${currentConfig}」`, 'ok');
            await loadConfigList();
        } catch (e) { toast('保存失败: ' + e.message, 'err'); }
    }

    // ── 文件选择器 ──
    async function openFilePicker() {
        const mask = $('anFileMask');
        const listEl = $('anFileList');
        listEl.innerHTML = '<div style="padding:16px;text-align:center;color:var(--text-dim)">加载中…</div>';
        mask.hidden = false;
        try {
            const r = await fetch('/list');
            const j = await r.json();
            const items = (j.items || []).filter(it => it.name.endsWith('.csv'));
            if (items.length === 0) {
                listEl.innerHTML = '<div style="padding:16px;text-align:center;color:var(--text-dim)">暂无 CSV 文件</div>';
                return;
            }
            listEl.innerHTML = items.map(it => `
                <label class="an-file-item">
                    <input type="checkbox" value="${esc(it.name)}" ${analyzeFiles.includes(it.name) ? 'checked' : ''}>
                    <span class="fn">${esc(it.name)}</span>
                    <span style="color:var(--text-dim);font-size:11px">${(it.size / 1024).toFixed(1)} KB</span>
                </label>
            `).join('');
        } catch (e) {
            listEl.innerHTML = `<div style="padding:16px;text-align:center;color:var(--danger)">加载失败: ${esc(e.message)}</div>`;
        }
    }

    function confirmFilePicker() {
        const checked = document.querySelectorAll('#anFileList input[type="checkbox"]:checked');
        analyzeFiles = [...checked].map(cb => cb.value);
        updateDataSrcLabel();
        $('anFileMask').hidden = true;
    }

    function updateDataSrcLabel() {
        const el = $('anDataSrc');
        if (!el) return;
        if (analyzeFiles.length === 0) {
            el.textContent = '数据源：未选择文件';
        } else {
            el.textContent = `数据源：${analyzeFiles.length} 个文件`;
            el.title = analyzeFiles.join('\n');
        }
    }

    // ── 渲染结果 ──
    function renderResults(data) {
        const kpiCards = $('anKpis');
        const detail = $('anDetail');
        const action = data.action;
        const d = data.data;

        let kpis = [];
        if (action === 'analyze') {
            kpis = [
                { label: '原始行数', value: d.raw },
                { label: '筛选后', value: d.filtered },
                { label: '去重后', value: d.deduped },
                { label: 'deanon 行数', value: d.deanonRows },
            ];
        } else if (action === 'verify') {
            kpis = [
                { label: 'L1 磁盘审计', value: d.l1 === 'SKIPPED' ? '跳过' : d.l1 },
                { label: 'L2 数据审计', value: d.l2 },
                { label: '推导行数', value: d.recomputedCount },
                { label: 'deanon 行数', value: d.deanonCount },
            ];
        } else if (action === 'rank') {
            kpis = [
                { label: '模型数', value: d.models.length },
                { label: '完整组', value: d.completeGroups },
                { label: '对比对数', value: d.pairs.length },
                { label: 'Bonferroni', value: d.bonf },
            ];
        }
        kpiCards.innerHTML = kpis.map(k =>
            `<div class="an-kpi"><div class="l">${k.label}</div><div class="v">${k.value}</div></div>`
        ).join('');

        let html = '';
        if (action === 'analyze') {
            html += `
                <div class="an-sec">
                    <div class="sec-h">筛选统计</div>
                    <table class="an-tbl">
                        <tr><th>指标</th><th>值</th></tr>
                        <tr><td>原始行数</td><td>${d.raw}</td></tr>
                        <tr><td>筛选后</td><td>${d.filtered}</td></tr>
                        <tr><td>无关丢弃</td><td>${d.dropped}</td></tr>
                        <tr><td>排除评分员</td><td>${d.excluded}</td></tr>
                        <tr><td>去重后</td><td>${d.deduped}</td></tr>
                        <tr><td>移除重复</td><td>${d.removed}</td></tr>
                        <tr><td>deanon 行数</td><td>${d.deanonRows}</td></tr>
                    </table>
                    <div class="an-out">输出: ${esc(d.deanonCsv || '')}</div>
                </div>`;
        }
        if (action === 'verify') {
            html += `
                <div class="an-sec">
                    <div class="sec-h">审计结果 <span class="an-badge ${d.overall === '全部通过' ? 'ok' : 'fail'}">${d.overall}</span></div>
                    <table class="an-tbl">
                        <tr><th>审计项</th><th>结果</th></tr>
                        <tr><td>L1 磁盘文件↔map</td><td><span class="an-badge ${d.l1 === 'OK' ? 'ok' : d.l1 === 'SKIPPED' ? 'skip' : 'fail'}">${d.l1 === 'SKIPPED' ? '跳过' : d.l1}</span></td></tr>
                        <tr><td>L2 deanon↔独立推导</td><td><span class="an-badge ${d.l2 === 'OK' ? 'ok' : 'fail'}">${d.l2}</span></td></tr>
                        <tr><td>推导行数</td><td>${d.recomputedCount}</td></tr>
                        <tr><td>deanon 行数</td><td>${d.deanonCount}</td></tr>
                        <tr><td>不一致字段</td><td>${d.mismatches}</td></tr>
                    </table>`;
            if (d.details && d.details.length > 0) {
                html += `<div class="an-details"><b>问题详情:</b><br>${d.details.map(x => esc(x)).join('<br>')}</div>`;
            }
            html += `</div>`;
        }
        if (action === 'rank') {
            html += `
                <div class="an-sec">
                    <div class="sec-h">模型排名</div>
                    <table class="an-tbl">
                        <tr><th>模型</th><th>n</th><th>均值</th><th>95%CI</th><th>强度</th><th>Elo</th><th>排名</th></tr>
                        ${d.models.map(m => `
                            <tr>
                                <td title="${esc(m.name)}">${esc(m.name)}</td>
                                <td>${m.n}</td>
                                <td>${m.mean}</td>
                                <td>[${m.ciLower}, ${m.ciUpper}]</td>
                                <td>${m.strength}</td>
                                <td>${m.elo >= 0 ? '+' : ''}${m.elo}</td>
                                <td><b>${m.rank}</b></td>
                            </tr>
                        `).join('')}
                    </table>
                </div>
                <div class="an-sec">
                    <div class="sec-h">两两对比 <span style="font-size:11px;color:var(--text-dim);font-weight:400">signP &lt; ${d.bonf} 显著</span></div>
                    <table class="an-tbl">
                        <tr><th>对比</th><th>A胜</th><th>B胜</th><th>平</th><th>signP</th><th>显著</th></tr>
                        ${d.pairs.map(p => `
                            <tr>
                                <td title="${esc(p.modelA)} vs ${esc(p.modelB)}">${esc(p.modelA)} vs ${esc(p.modelB)}</td>
                                <td>${p.aWins}</td>
                                <td>${p.bWins}</td>
                                <td>${p.ties}</td>
                                <td>${p.signP}</td>
                                <td><span class="an-badge ${p.significant === '**' ? 'sig' : p.significant === '*' ? 'ok' : 'ns'}">${p.significant}</span></td>
                            </tr>
                        `).join('')}
                    </table>
                    <div class="an-out">结果保存: ${esc(d.rankCsv || '')} | ${esc(d.pairCsv || '')}</div>
                </div>`;
        }
        detail.innerHTML = html;
    }

    // ── 运行分析 ──
    async function runAnalysis() {
        if (!isLoggedIn()) { toast('请先登录', 'warn'); openLogin(); return; }
        if (analyzeFiles.length === 0) { toast('请先选择分析文件', 'warn'); openFilePicker(); return; }
        if (!currentConfig) { toast('请先选择一个配置', 'warn'); return; }

        const action = $('anAction').value;
        let config;
        try { config = getCurrentConfigObj(); }
        catch (e) {
            $('anJsonErr').textContent = 'JSON 格式错误: ' + e.message;
            $('anJsonErr').style.display = 'block';
            return;
        }
        $('anJsonErr').style.display = 'none';

        switchTab('results');
        $('anEmpty').hidden = true;
        $('anResultsArea').hidden = true;
        $('anLoading').hidden = false;
        const runBtn = $('anRun');
        runBtn.disabled = true;
        runBtn.textContent = '⏳ 分析中…';

        try {
            const r = await adminFetch('/api/analyze', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ names: analyzeFiles, config, action }),
            });
            if (!r.ok) throw new Error(`HTTP ${r.status}`);
            const data = await r.json();
            if (!data.ok) throw new Error(data.error || '分析失败');

            $('anLoading').hidden = true;
            $('anResultsArea').hidden = false;
            renderResults(data);
            toast(`✅ ${action} 分析完成`, 'ok');
        } catch (e) {
            $('anLoading').hidden = true;
            $('anEmpty').hidden = false;
            toast(`❌ 分析失败: ${e.message}`, 'err');
        } finally {
            runBtn.disabled = false;
            runBtn.textContent = '▶ 运行分析';
        }
    }

    // ── 对外接口 ──
    window.PXAnalyze = {
        setFiles(names) {
            analyzeFiles = [...names];
            updateDataSrcLabel();
        },
        onShow() {
            if (!initialized) {
                initModule();
                initialized = true;
            }
            loadConfigList();
        },
    };

    // ── 初始化（懒加载，首次进入模块时执行） ──
    function initModule() {
        // Tab 切换
        document.querySelectorAll('.an-tab').forEach(tab => {
            tab.addEventListener('click', () => switchTab(tab.dataset.tab));
        });
        // 模式切换
        $('anToggleJson').addEventListener('click', () => setJsonMode(!isJsonMode));
        $('anFmtJson').addEventListener('click', formatJson);
        $('anSaveCfg').addEventListener('click', saveConfig);
        // 新建配置
        $('anAddCfg').addEventListener('click', addConfig);
        // 运行
        $('anRun').addEventListener('click', runAnalysis);
        // 文件选择器
        $('anPickBtn').addEventListener('click', openFilePicker);
        $('anFileOk').addEventListener('click', confirmFilePicker);
        $('anFileCancel').addEventListener('click', () => { $('anFileMask').hidden = true; });
        $('anFileMask').addEventListener('click', (e) => {
            if (e.target === $('anFileMask')) $('anFileMask').hidden = true;
        });
        updateDataSrcLabel();
    }
})();
