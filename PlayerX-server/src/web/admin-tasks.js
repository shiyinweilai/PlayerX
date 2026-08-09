/**
 * PlayerX-server 任务管理模块（内嵌于主页面）
 *
 * 盲评构建：配置管理 + 表单/JSON 编辑 + 执行构建 + 展示结果。
 * 依赖 window.PX（由 app.js 暴露）提供的共享 API。
 * 对外暴露 window.PXTasks = { onShow() }
 */
(function () {
    'use strict';

    const $ = (id) => document.getElementById(id);
    const PX = () => window.PX;

    // ── 模块状态 ──
    let currentConfig = null;
    let configs = [];
    let isJsonMode = false;
    let initialized = false;
    let currentAction = 'build';

    // ── 工具 ──
    function esc(s) { return PX().escHtml(s); }
    function toast(msg, kind) { PX().showToast(msg, kind); }
    function adminFetch(path, opts) { return PX().adminFetch(path, opts); }
    function isLoggedIn() { return PX().isLoggedIn(); }
    function openLogin() { PX().openLoginDialog(); }

    // ── Action 切换 ──
    const actionLabels = {
        build: '▶ 执行构建',
        rank: '▶ 执行排名',
    };
    function onActionChange() {
        const actionSel = $('tkAction');
        const selected = actionSel ? actionSel.value : currentAction;
        currentAction = selected === 'rank' ? 'rank' : 'build';
        const btn = $('tkRun');
        btn.textContent = actionLabels[currentAction] || '▶ 执行';
        // 更新 loading 文案
        const loadingText = $('tkLoadingText');
        if (loadingText) {
            const labels = { build: '构建中…', rank: '统计中…' };
            loadingText.textContent = labels[currentAction] || '执行中…';
        }
    }

    // ── Tab 切换 ──
    function switchTab(name) {
        document.querySelectorAll('#pageTasks .an-tab').forEach(t => {
            t.classList.toggle('active', t.dataset.tab === name);
        });
        document.querySelectorAll('#pageTasks .an-tab-page').forEach(p => {
            p.classList.toggle('active', p.id === 'tkTab' + name.charAt(0).toUpperCase() + name.slice(1));
        });
    }

    // ── 表单 ↔ JSON 同步 ──
    function jsonToForm(obj) {
        $('tf_tag').value = obj.tag || '';
        $('tf_nGroups').value = obj.n_groups || 5;
        $('tf_seed').value = obj.seed || 42;
        $('tf_blind').value = obj.blind !== false ? 'true' : 'false';
        $('tf_groupMode').value = obj.group_mode || 'fresh';
        $('tf_reuseMap').value = obj.reuse_map_csv || '';
        $('tf_models').value = (obj.models || []).join('\n');
        $('tf_srcDir').value = obj.src_model_dir || '';
        $('tf_dstDir').value = obj.dst_dir || '';
        $('tf_mapCsv').value = obj.map_csv || '';
        $('tf_deanonCsv').value = obj.deanon_csv || 'playerx_selected_deanon.csv';
        $('tf_samples').value = (obj.samples || []).join(',');
        $('tf_excludeSamples').value = (obj.exclude_samples || []).join(',');
        $('tf_excludeRaters').value = (obj.exclude_raters || []).join(',');
        // companions
        const comp = obj.companions || {};
        $('tf_ffDir').value = comp.first_frames_dir || '';
        $('tf_promptCsv').value = comp.prompt_csv || '';
        $('tf_promptCols').value = (comp.prompt_cols || ['Image', 'prompt', 'en_prompt']).join(',');
        // 分析配置
        $('tf_dimensions').value = (obj.dimensions || ['multi_总分']).join(',');
        $('tf_analyzeInput').value = obj.analyze_input || '';
        $('tf_analyzeOutput').value = obj.analyze_output || '';
    }

    function formToJson() {
        const parseList = (s) => s.split(/[,\n]/).map(x => x.trim()).filter(Boolean);
        const parseNumList = (s) => s.split(/[,\n]/).map(x => parseInt(x.trim(), 10)).filter(n => !isNaN(n));
        const obj = {};
        const tag = $('tf_tag').value.trim();
        if (tag) obj.tag = tag;
        obj.n_groups = parseInt($('tf_nGroups').value, 10) || 5;
        obj.seed = parseInt($('tf_seed').value, 10) || 42;
        obj.blind = $('tf_blind').value === 'true';
        obj.group_mode = $('tf_groupMode').value;
        const reuseMap = $('tf_reuseMap').value.trim();
        if (reuseMap) obj.reuse_map_csv = reuseMap;
        obj.models = parseList($('tf_models').value);
        const srcDir = $('tf_srcDir').value.trim();
        if (srcDir) obj.src_model_dir = srcDir;
        const dstDir = $('tf_dstDir').value.trim();
        if (dstDir) {
            obj.dst_dir = dstDir;
        } else if (obj.tag) {
            obj.dst_dir = obj.tag;
        }
        const mapCsv = $('tf_mapCsv').value.trim();
        if (mapCsv) obj.map_csv = mapCsv;
        obj.deanon_csv = $('tf_deanonCsv').value.trim() || 'playerx_selected_deanon.csv';
        const samples = parseNumList($('tf_samples').value);
        if (samples.length > 0) obj.samples = samples;
        const excludeSamples = parseNumList($('tf_excludeSamples').value);
        if (excludeSamples.length > 0) obj.exclude_samples = excludeSamples;
        const excludeRaters = parseList($('tf_excludeRaters').value);
        if (excludeRaters.length > 0) obj.exclude_raters = excludeRaters;
        // companions
        const ffDir = $('tf_ffDir').value.trim();
        const promptCsv = $('tf_promptCsv').value.trim();
        if (ffDir || promptCsv) {
            obj.companions = {};
            if (ffDir) obj.companions.first_frames_dir = ffDir;
            if (promptCsv) obj.companions.prompt_csv = promptCsv;
            const promptCols = parseList($('tf_promptCols').value);
            if (promptCols.length > 0) obj.companions.prompt_cols = promptCols;
        }
        // 分析配置
        const dimensions = $('tf_dimensions').value.trim();
        if (dimensions) obj.dimensions = parseList(dimensions);
        const analyzeInput = $('tf_analyzeInput').value.trim();
        if (analyzeInput) obj.analyze_input = analyzeInput;
        const analyzeOutput = $('tf_analyzeOutput').value.trim();
        if (analyzeOutput) obj.analyze_output = analyzeOutput;
        return obj;
    }

    function jsonTextToObj() { return JSON.parse($('tkJsonEditor').value); }
    function objToJsonText(obj) { $('tkJsonEditor').value = JSON.stringify(obj, null, 2); }
    function getCurrentConfigObj() { return isJsonMode ? jsonTextToObj() : formToJson(); }

    // ── 模式切换 ──
    function setJsonMode(on) {
        isJsonMode = on;
        $('tkFormMode').style.display = on ? 'none' : '';
        $('tkJsonMode').classList.toggle('visible', on);
        $('tkToggleJson').textContent = on ? '表单编辑' : '直接编辑 JSON';
        $('tkToggleJson').classList.toggle('active-mode', on);
        $('tkFmtJson').style.display = on ? '' : 'none';
        if (on) {
            try { objToJsonText(formToJson()); } catch (_) { }
        } else {
            try {
                jsonToForm(jsonTextToObj());
                $('tkJsonErr').style.display = 'none';
            } catch (e) {
                $('tkJsonErr').textContent = 'JSON 格式错误: ' + e.message;
                $('tkJsonErr').style.display = 'block';
                return;
            }
        }
    }

    // ── 配置列表（复用 analyze-configs API，bench_config 格式相同） ──
    async function loadConfigList() {
        const listEl = $('tkCfgList');
        try {
            const r = await fetch('/api/configs');
            const j = await r.json();
            if (!j.ok) throw new Error(j.error || '加载失败');
            // 从评分规则配置列表中获取，只展示含 build 配置的
            configs = (j.configs || []).map(c => ({
                name: c.name,
                tag: c.tag || '',
                models: c.build ? (c.build.models || []).length : 0,
                hasBuild: !!c.build,
            }));
            renderConfigList();
        } catch (e) {
            listEl.innerHTML = `<div class="an-cfg-empty" style="color:var(--danger)">加载失败: ${esc(e.message)}</div>`;
        }
    }

    function renderConfigList() {
        const listEl = $('tkCfgList');
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
                try {
                    const r = await adminFetch(`/api/configs/${encodeURIComponent(name)}`, { method: 'DELETE' });
                    const j = await r.json();
                    if (!j.ok) throw new Error(j.error);
                    if (currentConfig === name) { currentConfig = null; $('tkCfgName').textContent = ''; }
                    await loadConfigList();
                } catch (e2) { toast('删除失败: ' + e2.message, 'err'); }
            });
        });
    }

    async function selectConfig(name) {
        currentConfig = name;
        renderConfigList();
        try {
            const r = await fetch(`/api/configs/${encodeURIComponent(name)}`);
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const text = await r.text();
            const fullObj = JSON.parse(text);
            // 从评分规则 JSON 中提取 build 子对象作为任务配置
            const obj = fullObj.build || {};
            // 如果评分规则有 tag 但 build 没有，继承过来
            if (!obj.tag && fullObj.tag) obj.tag = fullObj.tag;
            objToJsonText(obj);
            jsonToForm(obj);
            $('tkCfgName').textContent = name;
            $('tkJsonErr').style.display = 'none';
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
            // 创建一个带 build 字段的评分规则配置
            const newCfg = {
                tag: 'subj_test',
                dimensions: [],
                build: {
                    src_model_dir: '/path/to/models',
                    models: [
                    ],
                    n_groups: 5,
                    blind: true,
                    seed: 42,
                    group_mode: 'fresh',
                    dimensions: ['multi_总分'],
                },
            };
            const r = await adminFetch(`/api/configs/${encodeURIComponent(trimmed)}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(newCfg),
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
            $('tkJsonErr').style.display = 'none';
        } catch (e) {
            $('tkJsonErr').textContent = 'JSON 格式错误: ' + e.message;
            $('tkJsonErr').style.display = 'block';
        }
    }

    async function saveConfig() {
        if (!currentConfig) { toast('请先选择配置', 'warn'); return; }
        if (!isLoggedIn()) { toast('请先登录', 'warn'); openLogin(); return; }
        let obj;
        try { obj = getCurrentConfigObj(); }
        catch (e) {
            $('tkJsonErr').textContent = 'JSON 格式错误: ' + e.message;
            $('tkJsonErr').style.display = 'block';
            return;
        }
        $('tkJsonErr').style.display = 'none';
        try {
            // 先读取完整的评分规则 JSON
            const fr = await fetch(`/api/configs/${encodeURIComponent(currentConfig)}`);
            let fullObj = {};
            if (fr.ok) { try { fullObj = await fr.json(); } catch (_) { } }
            // 把构建配置写入 build 字段（不影响其他字段）
            fullObj.build = obj;
            const r = await adminFetch(`/api/configs/${encodeURIComponent(currentConfig)}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(fullObj),
            });
            const j = await r.json();
            if (!j.ok) throw new Error(j.error);
            toast(`已保存「${currentConfig}」`, 'ok');
            await loadConfigList();
        } catch (e) { toast('保存失败: ' + e.message, 'err'); }
    }

    // ── 渲染构建结果 ──
    function renderResults(data) {
        const kpiCards = $('tkKpis');
        const detail = $('tkDetail');

        const kpis = [
            { label: '样本数', value: data.samples },
            { label: '模型数', value: data.models },
            { label: '组数', value: data.groups },
            { label: '盲评', value: data.blind ? '是' : '否' },
            { label: 'Map 行数', value: data.mapRows },
            { label: '自检', value: data.verifyOk ? '✅ 通过' : '❌ 失败' },
        ];
        kpiCards.innerHTML = kpis.map(k =>
            `<div class="an-kpi"><div class="l">${k.label}</div><div class="v">${k.value}</div></div>`
        ).join('');

        let html = `
            <div class="an-sec">
                <div class="sec-h">构建信息</div>
                <table class="an-tbl">
                    <tr><th>项</th><th>值</th></tr>
                    <tr><td>种子</td><td>${data.seed}</td></tr>
                    <tr><td>盲评模式</td><td>${data.blind ? '是' : '否'}</td></tr>
                    <tr><td>输出目录</td><td style="font-size:11px">${esc(data.dstDir || '')}</td></tr>
                    <tr><td>Map CSV</td><td style="font-size:11px">${esc(data.mapCsv || '（非盲评，无 map）')}</td></tr>
                </table>
            </div>`;

        if (data.verifyDetails && data.verifyDetails.length > 0) {
            html += `<div class="an-details"><b>自检问题:</b><br>${data.verifyDetails.map(x => esc(x)).join('<br>')}</div>`;
        } else {
            html += `<div class="an-sec"><div class="sec-h">自检结果 <span class="an-badge ok">全部通过</span></div></div>`;
        }

        detail.innerHTML = html;
    }

    // ── 执行操作（build/rank） ──
    async function runAction() {
        if (!isLoggedIn()) { toast('请先登录', 'warn'); openLogin(); return; }
        if (!currentConfig) { toast('请先选择一个配置', 'warn'); return; }

        let config;
        try { config = getCurrentConfigObj(); }
        catch (e) {
            $('tkJsonErr').textContent = 'JSON 格式错误: ' + e.message;
            $('tkJsonErr').style.display = 'block';
            return;
        }
        $('tkJsonErr').style.display = 'none';

        const action = currentAction === 'rank' ? 'rank' : 'build';
        const actionNames = { build: '构建', rank: '排名' };
        const actionName = actionNames[action] || action;

        // build 会清空输出目录，确认一下
        if (action === 'build' && config.dst_dir) {
            const ok = await PX().confirmDialog('确认构建',
                `构建将清空并重建输出目录：\n${config.dst_dir}\n\n确定继续？`, '📦');
            if (!ok) return;
        }

        switchTab('results');
        $('tkEmpty').hidden = true;
        $('tkResultsArea').hidden = true;
        $('tkLoading').hidden = false;
        const loadingText = $('tkLoadingText');
        if (loadingText) loadingText.textContent = actionName + '中…';
        const runBtn = $('tkRun');
        runBtn.disabled = true;
        runBtn.textContent = '⏳ ' + actionName + '中…';

        try {
            // 根据 tag 确定文件夹结构
            const tag = config.tag || config.dst_dir || currentConfig;
            // 所有操作共用 tag 作为根目录
            if (!config.dst_dir) config.dst_dir = tag;

            const apiPath = action === 'build' ? '/api/build' : '/api/analyze';
            const r = await adminFetch(apiPath, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ config, action }),
            });
            if (!r.ok) throw new Error(`HTTP ${r.status}`);
            const data = await r.json();
            if (!data.ok) throw new Error(data.error || actionName + '失败');

            $('tkLoading').hidden = true;
            $('tkResultsArea').hidden = false;
            if (action === 'build') {
                renderResults(data.data);
                // 构建成功后自动 zip 到 testsrc
                if (data.data && data.data.dstDir) {
                    toast('📦 正在压缩…', 'info');
                    try {
                        const zr = await adminFetch('/api/build/zip', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ dstDir: data.data.dstDir, tag }),
                        });
                        const zj = await zr.json();
                        if (zr.ok && zj.ok) {
                            toast(`✅ 已压缩 → testsrc/${zj.zipName}`, 'ok');
                        } else {
                            toast('⚠️ 压缩失败：' + (zj.error || ''), 'err');
                        }
                    } catch (ze) {
                        toast('⚠️ 压缩异常：' + ze.message, 'err');
                    }
                }
            } else {
                renderAnalyzeResults(data.data, action);
            }
            toast('✅ ' + actionName + '完成', 'ok');
        } catch (e) {
            $('tkLoading').hidden = true;
            $('tkEmpty').hidden = false;
            toast(`❌ ${actionName}失败: ${e.message}`, 'err');
        } finally {
            runBtn.disabled = false;
            runBtn.textContent = actionLabels[action];
        }
    }

    // ── 渲染排名结果 ──
    function renderAnalyzeResults(data, action) {
        const kpiCards = $('tkKpis');
        const detail = $('tkDetail');

        if (action !== 'rank') {
            kpiCards.innerHTML = '';
            detail.innerHTML = '<div class="an-sec">仅支持执行排名</div>';
            return;
        }

        const kpis = [
            { label: '模型数', value: data.models || '-' },
            { label: '维度', value: data.dimension || '-' },
            { label: '最高分', value: data.topScore != null ? data.topScore.toFixed(2) : '-' },
            { label: '状态', value: data.success ? '✅ 完成' : '❌ 失败' },
        ];
        kpiCards.innerHTML = kpis.map(k =>
            `<div class="an-kpi"><div class="l">${k.label}</div><div class="v">${k.value}</div></div>`
        ).join('');
        detail.innerHTML = data.ranking ? `<div class="an-sec"><div class="sec-h">排名结果</div><pre style="font-size:12px;white-space:pre-wrap">${esc(data.ranking)}</pre></div>` : '';
    }

    // ── 文件选择 ──
    function pickFile() {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = '.csv,.json';
        input.onchange = () => {
            if (input.files.length > 0) {
                const file = input.files[0];
                const dataSrc = $('tkDataSrc');
                if (dataSrc) dataSrc.textContent = '数据源：' + file.name;
                if ($('tf_analyzeInput')) $('tf_analyzeInput').value = file.name;
            }
        };
        input.click();
    }

    // ── 对外接口 ──
    window.PXTasks = {
        onShow() {
            if (!initialized) {
                initModule();
                initialized = true;
            }
            loadConfigList();
        },
    };

    // ── 初始化（懒加载） ──
    function initModule() {
        // Tab 切换
        document.querySelectorAll('#pageTasks .an-tab').forEach(tab => {
            tab.addEventListener('click', () => switchTab(tab.dataset.tab));
        });
        // 模式切换
        $('tkToggleJson').addEventListener('click', () => setJsonMode(!isJsonMode));
        $('tkFmtJson').addEventListener('click', formatJson);
        $('tkSaveCfg').addEventListener('click', saveConfig);
        // 新建配置
        $('tkAddCfg').addEventListener('click', addConfig);
        // Action 切换（仅 build/rank；无选择器时默认 build）
        const actionSel = $('tkAction');
        if (actionSel) actionSel.addEventListener('change', onActionChange);
        // 文件选择
        const pickBtn = $('tkPickBtn');
        if (pickBtn) pickBtn.addEventListener('click', pickFile);
        // 高级路径配置折叠
        const pathAdvToggle = $('tkPathAdvToggle');
        const pathAdvPanel = $('tkPathAdvPanel');
        if (pathAdvToggle && pathAdvPanel) {
            pathAdvToggle.addEventListener('click', () => {
                const open = !pathAdvPanel.hidden;
                pathAdvPanel.hidden = open;
                pathAdvToggle.textContent = open ? '高级路径配置 ▸' : '高级路径配置 ▾';
                pathAdvToggle.classList.toggle('open', !open);
            });
        }
        // 运行
        $('tkRun').addEventListener('click', runAction);
        // 初始化 action 状态
        onActionChange();
    }
})();
