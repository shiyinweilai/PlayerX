/**
 * src/web/app-terminal.js — 在线终端面板
 *
 * 功能：
 *   - 多个标签页（每个 tab 一个独立的命令历史 + 输出缓冲区）
 *   - 命令历史：↑↓ 翻历史、Tab 触发文件名补全（通过 POST 一条 `complete <token>` 指令调用 bash 自动补全，结果回填到输入框）
 *   - Ctrl+L 清屏
 *   - 执行期间显示运行中状态 + 当前命令；超时/取消都有提示
 *   - 输出超过 64KB 自动截断并提示
 *
 * 与 app-init.js 的对接：renderTerminalPage() 是入口，
 * switchModule('terminal') 时由 app-core 调用。
 */
(function () {
    'use strict';

    // 复用 adminFetch / showToast（与其它页面一致），在 app-core 里注册到全局
    const adminFetch = window.adminFetch || (async (url, opts) => fetch(url, Object.assign({ credentials: 'include' }, opts)));

    // 状态：每个 tab 一个 sessions 项
    const sessions = [];
    let activeIdx = 0;
    let meta = null;             // 后端返回的 cwd / host / timeout 等

    function newSession() {
        return {
            history: [],         // 所有提交过的命令
            cursor: -1,          // ↑↓ 当前位置（-1 表示在"最新"之后")
            running: false,      // 是否正在执行命令
            buffer: '',          // 当前累积的输出缓冲（DOM 中的内容）
        };
    }

    // ── 输出辅助：把纯文本转成安全的 HTML（保留换行 + 转义） ──
    function escapeHtml(s) {
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }
    function withClass(text, cls) {
        return `<div class="${cls}">${escapeHtml(text)}</div>`;
    }

    // ── 终端输出：分两类块（命令回显 / 输出） ──
    function appendBlock(outEl, html, cls) {
        const div = document.createElement('div');
        div.className = `term-block ${cls}`;
        div.innerHTML = html;
        outEl.appendChild(div);
        // 自动滚动到底部
        outEl.scrollTop = outEl.scrollHeight;
    }

    // ── 写入"用户键入的命令" + 结果 ──
    function writeCommand(s, outEl, prompt, cwdShort) {
        appendBlock(outEl, `<span class="term-cmd-prompt">${escapeHtml(prompt)}</span> <span class="term-cmd-cwd">[${escapeHtml(cwdShort)}]</span> <span class="term-cmd-text">${escapeHtml(s.command)}</span>`, 'term-cmd');
    }

    function writeStdout(outEl, text) {
        if (!text) return;
        appendBlock(outEl, escapeHtml(text), 'term-out');
    }
    function writeStderr(outEl, text) {
        if (!text) return;
        appendBlock(outEl, escapeHtml(text), 'term-err');
    }
    function writeMeta(outEl, info) {
        const dur = (info.durationMs / 1000).toFixed(2);
        const parts = [];
        parts.push(`exit ${info.code == null ? '?' : info.code}`);
        parts.push(`${dur}s`);
        if (info.killed) parts.push('<span class="term-warn">已终止</span>');
        if (info.truncated) parts.push('<span class="term-warn">输出被截断</span>');
        appendBlock(outEl, parts.join(' · '), 'term-meta');
    }

    // ── 渲染工具栏 tabs + 主舞台 ──
    function renderTabs(container, onSelect, onAdd, onClose) {
        const html = sessions.map((s, i) => {
            const isActive = i === activeIdx;
            const label = s.title || `tab-${i + 1}`;
            return `
                <div class="term-tab ${isActive ? 'active' : ''}" data-idx="${i}">
                    <span class="term-tab-title">${escapeHtml(label)}</span>
                    <span class="term-tab-close" data-action="close" data-tip="关闭">×</span>
                </div>
            `;
        }).join('');
        container.innerHTML = html + `
            <div class="term-tab term-tab-add" data-tip="新建标签" data-action="add">+</div>
        `;
        // 绑定
        container.querySelectorAll('.term-tab').forEach(el => {
            const idx = +el.dataset.idx;
            if (isNaN(idx)) {
                el.addEventListener('click', () => onAdd());
            } else {
                el.querySelector('.term-tab-title').addEventListener('click', () => onSelect(idx));
                el.querySelector('.term-tab-close').addEventListener('click', (e) => {
                    e.stopPropagation();
                    onClose(idx);
                });
            }
        });
    }

    // ── Tab 标题：默认 #1，也可以是 `cd xxx` 后变 cwd ──
    function deriveTabTitle(s, defaultTitle) {
        // 找最近一次"裸 cd <dir>" 作为标题（更直观）
        for (let i = s.history.length - 1; i >= 0; i--) {
            const cmd = s.history[i].trim();
            const m = /^cd\s+(\S+)/.exec(cmd);
            if (m) {
                const dir = m[1].replace(/^['"]|['"]$/g, '');
                return dir.length > 16 ? dir.slice(0, 14) + '…' : dir;
            }
        }
        return defaultTitle;
    }



    // 缓存徽章：根据 meta.loginCached 显示状态
    function updateCacheBadge() {
        const badge = document.getElementById('termCacheBadge');
        const refreshBtn = document.getElementById('termRefreshCacheBtn');
        if (!badge) return;
        const lc = meta.loginCached;
        if (!lc) {
            badge.hidden = true;
            if (refreshBtn) refreshBtn.hidden = true;
            return;
        }
        badge.hidden = false;
        if (refreshBtn) refreshBtn.hidden = false;
        const ageSec = Math.max(0, lc.ageSeconds || 0);
        const ageMin = Math.floor(ageSec / 60);
        let ageText;
        if (ageMin < 1) ageText = `${ageSec}s`;
        else if (ageMin < 60) ageText = `${ageMin}m`;
        else ageText = `${Math.floor(ageMin / 60)}h`;
        badge.textContent = `cached ${ageText}`;
        badge.title = `登录 shell 环境已缓存\nTTL: ${Math.round(lc.ttlSeconds / 60)}min\n点击 ↻ 刷新重新捕获`;
        badge.className = `term-cache-badge ${meta.loginCapturing ? 'capturing' : 'ready'}`;
    }

    // 拉取最新 meta（用于开启登录模式时拿到最新缓存状态）
    async function refreshMeta() {
        try {
            const r = await adminFetch('/api/terminal/meta');
            const j = await r.json();
            if (j.ok) {
                meta.loginCached = j.loginCached;
                meta.loginCapturing = j.loginCapturing;
                updateCacheBadge();
            }
        } catch (_) { }
    }

    // ── 主入口 ──
    async function renderTerminalPage(container) {
        if (!meta) {
            try {
                const r = await adminFetch('/api/terminal/meta');
                meta = await r.json();
                if (!meta.ok) throw new Error(meta.error || '无法获取终端元信息');
            } catch (e) {
                container.innerHTML = `<div class="term-page"><div class="term-header"><div class="term-title">终端</div><div class="term-sub" style="color:#ef4444">初始化失败: ${escapeHtml(e.message)}</div></div></div>`;
                return;
            }
        }

        if (sessions.length === 0) {
            sessions.push(Object.assign(newSession(), { title: '#1', cwd: meta.cwd }));
            activeIdx = 0;
        }

        const cwdShort = meta.cwd.length > 32 ? meta.cwd.replace(/^\/data\//, '~/') : meta.cwd;

        container.innerHTML = `
            <div class="term-page">
                <div class="term-header">
                    <div class="term-header-left">
                        <span class="term-title-text">终端 · 服务器命令行</span>
                        <span class="term-meta-sep">·</span>
                        <span class="term-meta-item"><span class="term-meta-key">host</span>=<span class="term-meta-val">${escapeHtml(meta.host)}</span></span>
                        <span class="term-meta-item"><span class="term-meta-key">user</span>=<span class="term-meta-val">${escapeHtml(meta.user)}</span></span>
                        <span class="term-meta-item"><span class="term-meta-key">cwd</span>=<span class="term-meta-val term-cwd" id="termRootDir" title="${escapeHtml(meta.cwd)}">${escapeHtml(meta.cwd)}</span></span>
                        <span class="term-meta-item"><span class="term-meta-key">timeout</span>=<span class="term-meta-val">${(meta.defaultTimeoutMs / 1000) | 0}s</span></span>
                    </div>
                    <div class="term-header-right">
                        <span class="term-upload-msg" id="termUploadMsg" hidden></span>
                        <div class="term-upload-result" id="termUploadResult" hidden>
                            <span class="term-upload-result-label">已上传到</span>
                            <code class="term-upload-result-path" id="termUploadResultPath" title=""></code>
                            <button class="term-upload-result-icon" id="termUploadResultCopy" data-tip="复制路径">
                                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                    <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
                                    <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
                                </svg>
                            </button>
                            <button class="term-upload-result-close" id="termUploadResultClose" data-tip="关闭">×</button>
                        </div>
                        <div class="term-upload-split" id="termUploadSplit">
                            <button class="term-upload-main" id="termUploadMainBtn" data-tip="上传文件到 assets/">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                                    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                                    <polyline points="17 8 12 3 7 8"/>
                                    <line x1="12" y1="3" x2="12" y2="15"/>
                                </svg>
                                上传
                            </button>
                            <button class="term-upload-caret" id="termUploadCaretBtn" data-tip="选择文件或文件夹">
                                <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">
                                    <polyline points="6 9 12 15 18 9"/>
                                </svg>
                            </button>
                            <div class="term-upload-menu" id="termUploadMenu" hidden>
                                <button class="term-upload-menu-item" data-kind="file">
                                    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                                        <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/>
                                        <polyline points="14 2 14 8 20 8"/>
                                    </svg>
                                    上传文件
                                </button>
                                <button class="term-upload-menu-item" data-kind="folder">
                                    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                                        <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
                                    </svg>
                                    上传文件夹
                                </button>
                            </div>
                            <input type="file" id="termUploadInput" multiple hidden />
                        </div>
                        <div class="term-upload-settings" id="termUploadSettings">
                            <button class="term-upload-settings-btn" id="termUploadSettingsBtn" data-tip="上传设置（自动解压 / 目标目录）">
                                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                                    <circle cx="12" cy="12" r="3"/>
                                    <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>
                                </svg>
                            </button>
                            <div class="term-upload-settings-panel" id="termUploadSettingsPanel" hidden>
                                <div class="term-settings-title">上传设置</div>
                                <label class="term-settings-row">
                                    <span class="term-settings-label">压缩包自动解压</span>
                                    <input type="checkbox" id="termUploadAutoExtract" checked />
                                </label>
                                <label class="term-settings-row">
                                    <span class="term-settings-label">目标目录</span>
                                    <input type="text" id="termUploadTargetDir" placeholder="assets/" spellcheck="false" autocomplete="off" />
                                </label>
                                <div class="term-settings-hint">默认 <code>assets/</code>（相对 data/）；填 <code>assets/foo</code> 可传到子目录。上传后若需改名/移动，可直接在终端用 <code>mv</code> 调整。</div>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="term-toolbar">
                    <div class="term-tabs" id="termTabs"></div>
                    <div class="term-toolbar-right">
                        <label class="term-toggle" data-tip="登录 shell 模式（加载 .bashrc 等）">
                            <input type="checkbox" id="termLoginToggle" />
                            <span>登录模式</span>
                            <span class="term-cache-badge" id="termCacheBadge" hidden></span>
                        </label>
                        <button class="term-btn term-btn-ghost" id="termRefreshCacheBtn" data-tip="刷新登录 shell 环境缓存" hidden>↻ 刷新</button>
                        <button class="term-btn term-btn-ghost" id="termClearBtn" data-tip="清空当前终端输出">清屏</button>
                    </div>
                </div>

                <div class="term-stage">
                    <div class="term-output" id="termOutput" tabindex="0" aria-label="终端输出"></div>
                    <div class="term-input-row">
                        <span class="term-prompt" id="termPrompt">$</span>
                        <input type="text" class="term-input" id="termInput"
                            placeholder="输入命令后回车（↑↓ 翻历史，Tab 补全，Ctrl+L 清屏）"
                            spellcheck="false" autocomplete="off" autocapitalize="off" autocorrect="off" />
                        <button class="term-btn term-btn-danger" id="termKillBtn" hidden data-tip="中止当前命令（Ctrl+C）">
                            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round">
                                <rect x="6" y="6" width="12" height="12" rx="1"/>
                            </svg>
                            终止
                        </button>
                        <button class="term-btn term-btn-primary" id="termRunBtn">执行 ↵</button>
                    </div>
                </div>
            </div>
            <div class="term-upload-modal" id="termUploadModal" hidden>
                <div class="term-modal-backdrop" id="termModalBackdrop"></div>
                <div class="term-modal-panel">
                    <div class="term-modal-title">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                            <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                            <polyline points="17 8 12 3 7 8"/>
                            <line x1="12" y1="3" x2="12" y2="15"/>
                        </svg>
                        <span id="termModalTitle">上传预览</span>
                        <button class="term-modal-close" id="termModalClose">&times;</button>
                    </div>
                    <div class="term-modal-body">
                        <div class="term-modal-info" id="termModalInfo"></div>
                        <div class="term-modal-files" id="termModalFiles"></div>
                        <div id="termModalProgress" hidden>
                            <div class="term-modal-progress-bar"><div class="term-modal-progress-fill" id="termModalBar"></div></div>
                            <div class="term-modal-progress-text" id="termModalProgressText"></div>
                        </div>
                    </div>
                    <div class="term-modal-footer">
                        <button class="term-btn term-btn-ghost" id="termModalCancel">取消</button>
                        <button class="term-btn term-btn-primary" id="termModalConfirm">开始上传</button>
                    </div>
                </div>
            </div>
        `;

        const outEl = container.querySelector('#termOutput');
        const inputEl = container.querySelector('#termInput');
        const runBtn = container.querySelector('#termRunBtn');
        const killBtn = container.querySelector('#termKillBtn');
        const tabsEl = container.querySelector('#termTabs');
        const promptEl = container.querySelector('#termPrompt');

        function rerenderTabs() {
            renderTabs(tabsEl,
                (idx) => { activeIdx = idx; rerenderTabs(); rerenderOutput(); focusInput(); },
                () => {
                    sessions.push(Object.assign(newSession(), { title: '#' + (sessions.length + 1), cwd: meta.cwd }));
                    activeIdx = sessions.length - 1;
                    rerenderTabs(); rerenderOutput(); focusInput();
                },
                (idx) => {
                    if (sessions.length === 1) {
                        // 至少留一个 tab，清空它
                        sessions[0] = Object.assign(newSession(), { title: '#1' });
                        activeIdx = 0;
                    } else {
                        sessions.splice(idx, 1);
                        if (activeIdx >= sessions.length) activeIdx = sessions.length - 1;
                    }
                    rerenderTabs(); rerenderOutput(); focusInput();
                });
        }

        function rerenderOutput() {
            outEl.innerHTML = sessions[activeIdx].buffer || '';
            outEl.scrollTop = outEl.scrollHeight;
            const title = deriveTabTitle(sessions[activeIdx], `#${activeIdx + 1}`);
            sessions[activeIdx].title = title;
            const tabEl = tabsEl.querySelector(`.term-tab[data-idx="${activeIdx}"] .term-tab-title`);
            if (tabEl) tabEl.textContent = title;
        }

        function appendAndSave(html) {
            const div = document.createElement('div');
            div.innerHTML = html;
            // 真实插入 DOM
            while (div.firstChild) outEl.appendChild(div.firstChild);
            sessions[activeIdx].buffer = outEl.innerHTML;
            outEl.scrollTop = outEl.scrollHeight;
        }

        function writeLine(kind, text, isError) {
            let cls;
            if (kind === 'err') cls = 'term-err' + (isError ? ' is-error' : '');
            else if (kind === 'meta') cls = 'term-meta' + (isError ? ' has-error' : '');
            else if (kind === 'cmd') cls = 'term-cmd';
            else cls = 'term-out';
            appendAndSave(`<div class="term-block ${cls}">${escapeHtml(text)}</div>`);
        }

        function focusInput() { inputEl.focus(); }

        rerenderTabs();
        rerenderOutput();
        updateCacheBadge();
        focusInput();

        // ── 登录模式开关 ──
        const loginToggle = container.querySelector('#termLoginToggle');
        loginToggle.addEventListener('change', () => {
            if (loginToggle.checked) refreshMeta();   // 开启时拉最新 meta 看缓存状态
        });

        // ── 显式刷新登录 shell 缓存（用户改了 .bashrc 后用） ──
        container.querySelector('#termRefreshCacheBtn').addEventListener('click', async () => {
            try {
                const r = await adminFetch('/api/terminal/refresh', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ cwd: sessions[activeIdx].cwd || meta.cwd }),
                });
                const j = await r.json();
                if (!j.ok) throw new Error(j.error);
                refreshMeta();
            } catch (_) { }
        });

        // ── 清屏 ──
        container.querySelector('#termClearBtn').addEventListener('click', () => {
            sessions[activeIdx].buffer = '';
            outEl.innerHTML = '';
            focusInput();
        });

        // ── 同步顶栏 cwd 显示 + 输入行 [cwd] 提示 ──
        function updateCmdPromptCwd() {
            const cwdRoot = container.querySelector('#termRootDir');
            if (cwdRoot) {
                cwdRoot.textContent = meta.cwd;
                cwdRoot.title = meta.cwd;
            }
            // 命令回显的 [cwd] 用 per-tab cwd
        }

        // ── 上传文件 / 文件夹 ── 用 adminFetch（cookie 维持登录态）──
        const uploadMsg = container.querySelector('#termUploadMsg');
        const fileInput = container.querySelector('#termUploadInput');
        const uploadResult = container.querySelector('#termUploadResult');
        const resultPathEl = container.querySelector('#termUploadResultPath');
        const resultCopyBtn = container.querySelector('#termUploadResultCopy');
        const resultCloseBtn = container.querySelector('#termUploadResultClose');

        // 当前要复制的路径（单条或多条换行拼接）
        let currentCopyPaths = [];

        // 复制到剪贴板（带降级）
        async function copyToClipboard(text) {
            try {
                if (navigator.clipboard && window.isSecureContext) {
                    await navigator.clipboard.writeText(text);
                    return true;
                }
            } catch (_) { }
            // 降级：临时 textarea + execCommand
            try {
                const ta = document.createElement('textarea');
                ta.value = text;
                ta.style.position = 'fixed';
                ta.style.opacity = '0';
                document.body.appendChild(ta);
                ta.select();
                const ok = document.execCommand('copy');
                document.body.removeChild(ta);
                return ok;
            } catch (_) {
                return false;
            }
        }

        // 显示成功结果：路径 + 复制按钮
        // 展示用相对路径（简短直观），复制时补成绝对路径（savedTo）
        function showUploadResult(json) {
            const displayPaths = [];
            const absPaths = [];
            const collect = (rel, savedTo) => {
                if (!rel) return;
                displayPaths.push(rel);
                absPaths.push(savedTo || rel);
            };
            collect(json.relativePath, json.savedTo);
            if (Array.isArray(json.files)) {
                json.files.forEach(f => collect(f.relativePath, f.savedTo));
            }
            if (displayPaths.length === 0) return;

            // 隐藏旧的简单消息，避免叠加
            if (uploadMsg) uploadMsg.hidden = true;

            currentCopyPaths = absPaths;
            let displayText;
            if (displayPaths.length === 1) {
                displayText = displayPaths[0];
            } else if (displayPaths.length <= 3) {
                displayText = displayPaths.join(', ');
            } else {
                displayText = `${displayPaths.slice(0, 2).join(', ')} …等 ${displayPaths.length} 个文件`;
            }
            if (resultPathEl) {
                resultPathEl.textContent = displayText;
                resultPathEl.title = absPaths.join('\n');
            }
            if (uploadResult) uploadResult.hidden = false;
        }

        // 复制按钮：复制完整路径列表
        if (resultCopyBtn) {
            resultCopyBtn.addEventListener('click', async () => {
                if (currentCopyPaths.length === 0) return;
                const text = currentCopyPaths.join('\n');
                const ok = await copyToClipboard(text);
                const original = resultCopyBtn.innerHTML;
                resultCopyBtn.innerHTML = ok ? '✓' : '✗';
                resultCopyBtn.disabled = true;
                setTimeout(() => {
                    resultCopyBtn.innerHTML = original;
                    resultCopyBtn.disabled = false;
                }, 1200);
            });
        }

        // 关闭按钮
        if (resultCloseBtn) {
            resultCloseBtn.addEventListener('click', () => {
                if (uploadResult) uploadResult.hidden = true;
                currentCopyPaths = [];
            });
        }

        // 上传设置（localStorage 持久化）：自动解压 + 目标目录
        const UPLOAD_SETTINGS_KEY = 'PlayerX.terminal.uploadSettings.v2';
        function readUploadSettings() {
            try {
                const raw = localStorage.getItem(UPLOAD_SETTINGS_KEY);
                if (raw) {
                    const o = JSON.parse(raw);
                    return {
                        // 默认勾选：字段缺失（老数据）时也视为 true，仅当用户明确取消过才为 false
                        autoExtract: o.autoExtract !== false,
                        targetDir: String(o.targetDir || '').trim(),
                    };
                }
            } catch (_) { }
            return { autoExtract: true, targetDir: '' };
        }
        function saveUploadSettings(s) {
            try { localStorage.setItem(UPLOAD_SETTINGS_KEY, JSON.stringify(s)); } catch (_) { }
        }

        function setUploadMsg(text, cls) {
            uploadMsg.hidden = false;
            uploadMsg.className = 'term-upload-msg' + (cls ? ' ' + cls : '');
            uploadMsg.textContent = text;
        }

        function throbber(files, word) {
            let dots = 0;
            return setInterval(() => {
                dots = (dots + 1) % 4;
                setUploadMsg(`上传中${'.'.repeat(dots)} ${files.length} ${word}`, 'progress');
            }, 400);
        }

        async function performUpload(files, isFolderMode) {
            if (files.length === 0) return;
            const word = isFolderMode ? '个文件夹' : '个文件';
            const fd = new FormData();
            for (const f of files) {
                // 文件夹上传：用 webkitRelativePath 保留子目录结构
                // 文件上传：用 f.name
                const name = isFolderMode && f.webkitRelativePath ? f.webkitRelativePath : f.name;
                fd.append('file', f, name);
            }

            // 附加上传设置：目标目录 + 自动解压
            const settings = readUploadSettings();
            if (settings.targetDir) fd.append('targetDir', settings.targetDir);
            if (settings.autoExtract) fd.append('autoExtract', '1');

            const hammer = throbber(files, word);
            try {
                const r = await adminFetch('/api/models/upload-folder', { method: 'POST', body: fd });
                const j = await r.json();
                if (!j.ok) throw new Error(j.error);

                // 成功：在上传按钮左侧显示路径 + 复制按钮
                showUploadResult(j);
            } catch (err) {
                setUploadMsg(`✗ ${err.message}`, 'err');
                setTimeout(() => { uploadMsg.hidden = true; }, 6000);
            } finally {
                clearInterval(hammer);
                if (fileInput) fileInput.value = '';
            }
        }

        // 文件按钮：保持原有逻辑
        if (fileInput) fileInput.addEventListener('change', e => performUpload(Array.from(e.target.files || []), false));

        // 文件夹：FAPI 或降级（提取为独立函数，被下拉菜单项复用）
        const modal = container.querySelector('#termUploadModal');
        let pendingFolderFiles = [];

        function openModal(title, info) {
            container.querySelector('#termModalTitle').textContent = title;
            container.querySelector('#termModalInfo').innerHTML = info;
            const filesEl = container.querySelector('#termModalFiles');
            filesEl.innerHTML = pendingFolderFiles.map((f, i) => {
                const rel = f.webkitRelativePath || f.name;
                const mb = (f.size / 1024).toFixed(1);
                return `<div class="term-modal-file"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg><span class="term-modal-file-name">${escapeHtml(rel)}</span><span class="term-modal-file-size">${mb} KB</span></div>`;
            }).join('');
            modal.hidden = false;
            container.querySelector('#termModalProgress').hidden = true;
            container.querySelector('#termModalConfirm').disabled = false;
        }

        function closeModal() {
            modal.hidden = true;
            pendingFolderFiles = [];
        }

        container.querySelector('#termModalBackdrop').addEventListener('click', closeModal);
        container.querySelector('#termModalClose').addEventListener('click', closeModal);
        container.querySelector('#termModalCancel').addEventListener('click', closeModal);
        container.querySelector('#termModalConfirm').addEventListener('click', async () => {
            if (pendingFolderFiles.length === 0) return;
            container.querySelector('#termModalProgress').hidden = false;
            container.querySelector('#termModalConfirm').disabled = true;
            const bar = container.querySelector('#termModalBar');
            const txt = container.querySelector('#termModalProgressText');
            bar.style.width = '0%';
            txt.textContent = '上传中…';
            // simple throbber
            let pct = 0;
            const intv = setInterval(() => { pct = Math.min(pct + 5, 90); bar.style.width = pct + '%'; }, 200);

            try {
                await performUpload(pendingFolderFiles, true);
                bar.style.width = '100%';
                txt.textContent = '✓ 上传完成';
                setTimeout(closeModal, 1500);
            } catch (_) {
                txt.textContent = '✗ 上传失败';
            } finally {
                clearInterval(intv);
            }
        });

        // 选择文件夹的函数（FAPI 优先，降级用 webkitdirectory input）
        // 创建一个隐藏的 folder input 作为降级方案
        const folderInput = document.createElement('input');
        folderInput.type = 'file';
        folderInput.setAttribute('webkitdirectory', '');
        folderInput.setAttribute('directory', '');
        folderInput.multiple = true;
        folderInput.style.display = 'none';
        container.appendChild(folderInput);

        folderInput.addEventListener('change', (e) => {
            const files = Array.from(e.target.files || []);
            if (files.length === 0) return;
            pendingFolderFiles = files;
            // 获取文件夹名（webkitRelativePath 第一段）
            const folderName = (files[0].webkitRelativePath || '').split('/')[0] || '文件夹';
            const totalKB = (files.reduce((s, f) => s + f.size, 0) / 1024).toFixed(1);
            openModal(`上传文件夹：${folderName}`,
                `<span class="term-meta-key">${folderName}</span> — ${files.length} 个文件、${totalKB} KB`);
            folderInput.value = '';
        });

        async function pickFolder() {
            if (window.showDirectoryPicker) {
                try {
                    const dirHandle = await window.showDirectoryPicker({ mode: 'read' });
                    pendingFolderFiles = [];
                    async function walkDir(handle, prefix) {
                        for await (const [name, child] of handle.entries()) {
                            const rel = prefix ? prefix + '/' + name : name;
                            if (child.kind === 'file') {
                                const f = await child.getFile();
                                Object.defineProperty(f, 'webkitRelativePath', { value: rel });
                                pendingFolderFiles.push(f);
                            } else {
                                await walkDir(child, rel);
                            }
                        }
                    }
                    await walkDir(dirHandle, dirHandle.name);
                    if (pendingFolderFiles.length === 0) {
                        setUploadMsg('⚠ 文件夹为空', 'err');
                        setTimeout(() => { uploadMsg.hidden = true; }, 3000);
                        return;
                    }
                    const totalMB = (pendingFolderFiles.reduce((s, f) => s + f.size, 0) / 1024).toFixed(1);
                    openModal(`上传文件夹：${dirHandle.name}`,
                        `<span class="term-meta-key">${dirHandle.name}</span> — ${pendingFolderFiles.length} 个文件、${totalMB} KB`);
                } catch (err) {
                    if (err.name !== 'AbortError') setUploadMsg(`✗ ${err.message}`, 'err');
                }
            } else {
                // 降级：使用 webkitdirectory input
                folderInput.click();
            }
        }

        // 主按钮：上传文件（直接触发 file input）
        const uploadMainBtn = container.querySelector('#termUploadMainBtn');
        if (uploadMainBtn) {
            uploadMainBtn.addEventListener('click', () => {
                if (fileInput) fileInput.click();
            });
        }

        // 下拉三角 + 菜单
        const caretBtn = container.querySelector('#termUploadCaretBtn');
        const menu = container.querySelector('#termUploadMenu');
        function closeMenu() { if (menu) menu.hidden = true; }
        if (caretBtn && menu) {
            caretBtn.addEventListener('click', e => {
                e.stopPropagation();
                menu.hidden = !menu.hidden;
            });
            // 菜单项点击
            menu.querySelectorAll('.term-upload-menu-item').forEach(item => {
                item.addEventListener('click', async () => {
                    closeMenu();
                    const kind = item.dataset.kind;
                    if (kind === 'file') {
                        if (fileInput) fileInput.click();
                    } else if (kind === 'folder') {
                        await pickFolder();
                    }
                });
            });
            // 点击其他区域关闭菜单
            document.addEventListener('click', e => {
                if (menu && !menu.hidden && !container.querySelector('#termUploadSplit').contains(e.target)) {
                    closeMenu();
                }
            });
        }

        // ── 上传设置面板：自动解压 + 目标目录 ──
        const settingsWrap = container.querySelector('#termUploadSettings');
        const settingsBtn = container.querySelector('#termUploadSettingsBtn');
        const settingsPanel = container.querySelector('#termUploadSettingsPanel');
        const autoExtractChk = container.querySelector('#termUploadAutoExtract');
        const targetDirInput = container.querySelector('#termUploadTargetDir');

        function closeSettingsPanel() { if (settingsPanel) settingsPanel.hidden = true; }
        function applySettingsToUI(s) {
            if (autoExtractChk) autoExtractChk.checked = s.autoExtract;
            if (targetDirInput) targetDirInput.value = s.targetDir;
        }
        applySettingsToUI(readUploadSettings());

        if (settingsBtn && settingsPanel) {
            settingsBtn.addEventListener('click', e => {
                e.stopPropagation();
                settingsPanel.hidden = !settingsPanel.hidden;
                if (!settingsPanel.hidden) closeMenu();
            });
            // 面板内部点击不关闭
            settingsPanel.addEventListener('click', e => e.stopPropagation());
            // 自动解压开关
            if (autoExtractChk) {
                autoExtractChk.addEventListener('change', () => {
                    const s = readUploadSettings();
                    s.autoExtract = autoExtractChk.checked;
                    saveUploadSettings(s);
                });
            }
            // 目标目录输入：失焦/回车时保存
            if (targetDirInput) {
                const persistTarget = () => {
                    const s = readUploadSettings();
                    s.targetDir = targetDirInput.value.trim();
                    saveUploadSettings(s);
                };
                targetDirInput.addEventListener('change', persistTarget);
                targetDirInput.addEventListener('keydown', e => {
                    if (e.key === 'Enter') { persistTarget(); closeSettingsPanel(); }
                });
            }
            // 点击其他区域关闭面板
            document.addEventListener('click', e => {
                if (settingsPanel && !settingsPanel.hidden && settingsWrap && !settingsWrap.contains(e.target)) {
                    closeSettingsPanel();
                }
            });
        }

        // ── Ctrl+L 在输入框聚焦时清屏 ──
        inputEl.addEventListener('keydown', (e) => {
            if (e.ctrlKey && e.key === 'l') { e.preventDefault(); container.querySelector('#termClearBtn').click(); return; }
            if (e.key === 'ArrowUp' && !inputEl.value) { e.preventDefault(); navigateHistory(-1); return; }
            if (e.key === 'ArrowDown' && !inputEl.value) { e.preventDefault(); navigateHistory(1); return; }
            if (e.key === 'Tab') { e.preventDefault(); tabComplete(); return; }
        });

        // ── 执行命令 ──
        async function runCommand() {
            const s = sessions[activeIdx];
            if (s.running) return;
            const cmd = inputEl.value.trim();
            if (!cmd) return;
            const cwdForRun = s.cwd || meta.cwd;

            // echo
            const cwdShort = cwdForRun.length > 32 ? cwdForRun.replace(/^\/data\//, '~/') : cwdForRun;
            const ts = new Date().toTimeString().slice(0, 8);   // HH:MM:SS
            // 用 innerHTML 注入：时间戳 span + 转义后的命令文本
            appendAndSave(
                `<div class="term-block term-cmd">` +
                `<span class="term-cmd-ts">${ts}</span> ` +
                `<span class="term-cmd-prompt">${escapeHtml(promptEl.textContent)}</span> ` +
                `<span class="term-cmd-cwd">[${escapeHtml(cwdShort)}]</span> ` +
                `<span class="term-cmd-text">${escapeHtml(cmd)}</span>` +
                `</div>`
            );

            // 入栈历史
            s.history.push(cmd);
            s.cursor = s.history.length;

            s.running = true;
            runBtn.disabled = true;
            runBtn.textContent = '执行中…';
            if (killBtn) killBtn.hidden = false;

            try {
                const r = await adminFetch('/api/terminal/exec', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        command: cmd,
                        cwd: cwdForRun,
                        login: container.querySelector('#termLoginToggle')?.checked || false,
                    }),
                });
                const data = await r.json();
                if (!data.ok) {
                    const msg = data.error || '执行失败';
                    if (data.hint === 'interactive-rejected') {
                        writeLine('meta', '━━ 交互式命令已被拒绝 ━━');
                        msg.split('\n').forEach(l => writeLine('err', l, true));
                        writeLine('meta', '━━━━━━━━━━━━━━━━━━━━━━━━━');
                    } else {
                        writeLine('err', `[错误] ${msg}`, true);
                    }
                } else {
                    const isError = (data.code != null && data.code !== 0) || data.killed;
                    if (data.stdout) {
                        const text = data.stdout;
                        if (data.command && /\b(ls\b|ll\b|find\b|tree\b|dir\b)/.test(data.command)) {
                            appendAndSave(`<div class="term-block term-out">${colorizeLsOutput(text)}</div>`);
                        } else {
                            writeLine('out', text);
                        }
                    }
                    if (data.stderr) writeLine('err', data.stderr, isError);
                    const dur = (data.durationMs / 1000).toFixed(2);
                    const flag = data.killed ? ' · 已终止' : (data.truncated ? ' · 输出被截断' : '');
                    writeLine('meta', `exit ${data.code == null ? '?' : data.code} · ${dur}s${flag}`, isError);
                    if (data.killed) writeLine('meta', `（命令被超时或用户取消打断）`);

                    if (data.shellMode === 'login-first') {
                        writeLine('meta', '（登录模式 · 首次启动，已捕获登录 shell 环境，之后命令会复用缓存）');
                        refreshMeta();
                    } else if (data.shellMode === 'login-cached') {
                        writeLine('meta', '（登录模式 · 复用缓存）');
                    }

                    // 智能 cd：只更新当前 tab 的 cwd
                    const m = /^cd\s+(.+?)\s*(?:&&.*)?$/.exec(cmd.trim());
                    if (m && data.code === 0) {
                        const target = m[1].replace(/^['"]|['"]$/g, '');
                        if (pathIsSafe(target)) {
                            s.cwd = pathIsAbsolute(target) ? target : pathJoin(s.cwd || cwdForRun, target);
                            updateCmdPromptCwd();
                        }
                    }
                }
            } catch (e) {
                writeLine('err', `[网络错误] ${e.message}`);
            } finally {
                s.running = false;
                runBtn.disabled = false;
                runBtn.textContent = '执行 ↵';
                if (killBtn) killBtn.hidden = true;
                inputEl.value = '';
                focusInput();
                rerenderTabs();   // 更新 tab 标题（可能是 cd 后的新 cwd）
            }
        }

        runBtn.addEventListener('click', runCommand);
        inputEl.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); runCommand(); }
            // Ctrl+C 终止（仅在命令运行时生效）
            if (e.ctrlKey && e.key === 'c' && killBtn && !killBtn.hidden) {
                e.preventDefault();
                killCurrentCommand();
            }
        });

        // 终止按钮：调用后端 /api/terminal/kill
        async function killCurrentCommand() {
            if (!killBtn) return;
            killBtn.disabled = true;
            try {
                const r = await adminFetch('/api/terminal/kill', { method: 'POST' });
                const j = await r.json();
                if (!j.ok && j.error) {
                    writeLine('err', `[终止] ${j.error}`, /*isError*/ true);
                } else {
                    writeLine('meta', '（用户主动终止）');
                }
            } catch (e) {
                writeLine('err', `[终止失败] ${e.message}`, true);
            } finally {
                killBtn.disabled = false;
            }
        }
        if (killBtn) killBtn.addEventListener('click', killCurrentCommand);

        // ── 历史导航 ──
        function navigateHistory(dir) {
            const s = sessions[activeIdx];
            if (s.history.length === 0) return;
            s.cursor = Math.max(-1, Math.min(s.history.length, s.cursor + dir));
            // cursor === history.length 表示"最新位置之后"（输入框为空）
            inputEl.value = s.cursor === s.history.length ? '' : s.history[s.cursor];
            // 移到最后
            setTimeout(() => inputEl.setSelectionRange(inputEl.value.length, inputEl.value.length), 0);
        }

        // ── Tab 补全 ──
        async function tabComplete() {
            const s = sessions[activeIdx];
            const val = inputEl.value;
            const cursor = inputEl.selectionStart || val.length;
            // 找光标左侧最后一个空白
            const left = val.slice(0, cursor);
            const m = /([^\s]+)$/.exec(left);
            if (!m) return;
            const token = m[1];
            // 用 compgen 风格的 complete：用 readline 不可行，简单的实现：
            //   bash -lc "compgen -o default -- '<token>'"   — 但需要真实的 bash 上下文。
            //   改用更简单的办法：尝试把 token 当路径，让 bash 自动补全：
            //     ls -1 <dir>/* | head -n 50
            // 更通用：直接走 bash 内置的 tab 补全比较复杂；这里做个简化版：
            //   如果 token 含 / 或者以 . 开头：列出该目录匹配项
            //   否则：列出当前目录下以 token 开头的文件名
            const sep = token.lastIndexOf('/');
            const dir = sep >= 0 ? token.slice(0, sep) : '.';
            const base = sep >= 0 ? token.slice(sep + 1) : token;
            const listCmd = `cd ${shellEscape(dir)} 2>/dev/null && compgen -o default -- ${shellEscape(base)} 2>/dev/null | head -n 50`;
            try {
                const r = await adminFetch('/api/terminal/exec', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        command: listCmd,
                        cwd: sessions[activeIdx].cwd || meta.cwd,
                        timeout: 5000,
                        login: container.querySelector('#termLoginToggle')?.checked || false,
                    }),
                });
                const data = await r.json();
                if (!data.ok || !data.stdout) return;
                const candidates = data.stdout.split('\n').filter(Boolean);
                if (candidates.length === 0) return;
                // 公共前缀
                const prefix = commonPrefix(candidates);
                const replacement = sep >= 0 ? dir + '/' + prefix : prefix;
                const newVal = val.slice(0, cursor - token.length) + replacement + val.slice(cursor);
                inputEl.value = newVal;
                inputEl.setSelectionRange(cursor - token.length + replacement.length, cursor - token.length + replacement.length);
            } catch (_) { }
        }
    }

    // ── 工具函数 ──
    function commonPrefix(arr) {
        if (arr.length === 0) return '';
        let p = arr[0];
        for (const s of arr) {
            while (!s.startsWith(p)) {
                p = p.slice(0, -1);
                if (!p) return '';
            }
        }
        return p;
    }
    function shellEscape(s) {
        // 单引号包裹，内部的单引号用 '\''
        return `'${String(s).replace(/'/g, `'\\''`)}'`;
    }
    function pathIsAbsolute(p) { return typeof p === 'string' && p.startsWith('/'); }
    function pathIsSafe(p) { return typeof p === 'string' && !p.includes('\0'); }
    function pathJoin(a, b) {
        if (b.startsWith('/')) return b;
        const sep = a.endsWith('/') ? '' : '/';
        // 简单处理 ..
        const parts = (a + sep + b).split('/').filter(Boolean);
        const stack = [];
        for (const seg of parts) {
            if (seg === '.') continue;
            if (seg === '..') { stack.pop(); continue; }
            stack.push(seg);
        }
        return '/' + stack.join('/');
    }

    // ── ls 输出着色：给文件名按类型着色 ──
    const LS_COLOR_RULES = [
        { re: /\/$/m, cls: 'term-ls-dir', desc: '目录' },
        { re: /\*$/m, cls: 'term-ls-exe', desc: '可执行' },
        { re: /@$/m, cls: 'term-ls-sym', desc: '符号链接' },
        { re: /[|=]$/m, cls: 'term-ls-fifo', desc: '管道/套接字' },
        { re: /\.(tar|gz|bz2|xz|zip|7z|rar|tgz|tbz|txz)$/i, cls: 'term-ls-archive', desc: '归档' },
        { re: /\.(png|jpg|jpeg|gif|svg|webp|bmp|ico|mp4|mkv|avi|mov|webm|wmv|flv|mp3|wav|flac|ogg|aac|wma)$/i, cls: 'term-ls-media', desc: '媒体' },
        { re: /\.(pdf|docx?|xlsx?|pptx?|csv|tsv|md|rst|txt|json|yaml|yml|toml|xml|html?|css|jsx?|tsx?|py|rb|go|rs|java|c|cpp|h|hpp|sh|bash|zsh|fish)$/i, cls: 'term-ls-doc', desc: '代码/文档' },
        { re: /(?:^|\s)\.\S+/m, cls: 'term-ls-dot', desc: '隐藏文件' },
    ];

    function colorizeLine(line) {
        if (!line || line.trim() === '') return escapeHtml(line);
        const trimmed = line.trimEnd();
        const indent = line.slice(0, line.length - trimmed.length);
        let base = trimmed;
        for (const rule of LS_COLOR_RULES) {
            if (rule.re.test(base)) {
                return indent + `<span class="${rule.cls}">${escapeHtml(base)}</span>`;
            }
        }
        return indent + escapeHtml(base);
    }

    function colorizeLsOutput(text) {
        return text.split('\n').map(colorizeLine).join('\n');
    }

    // 暴露给 switchModule
    window.renderTerminalPage = renderTerminalPage;
})();