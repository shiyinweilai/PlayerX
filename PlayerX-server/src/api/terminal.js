/**
 * src/api/terminal.js — 在线终端 v3
 *
 * 模式：
 *   plain          bash -c         最快 (~5ms)，无别名/函数
 *   login-first    bash -lc        慢 (~1s)，用一次捕获 env+alias
 *   login-cached   bash -c + 缓存  快 (~5ms)，env 生效，别名生效
 *
 * 修复：
 *   - spawn 时清理 BASH_FUNC_* / IFS 垃圾变量
 *   - stderr 过滤 "error importing function definition for …" 噪音
 *   - login-cached 注入固定别名（ll/la/l），绕过 bashrc 非交互保护
 */
const { spawn } = require('child_process');
const fs       = require('fs');
const path     = require('path');
const os       = require('os');
const { ROOT_DIR } = require('../lib/paths');

const MAX_OUTPUT_BYTES   = 64 * 1024;
const DEFAULT_TIMEOUT_MS = 30 * 1000;
const MAX_TIMEOUT_MS     = 5 * 60 * 1000;
const LOGIN_CACHE_TTL_MS = 30 * 60 * 1000;

const ALIASES_CACHE_FILE = path.join(os.tmpdir(), 'px-login-shell-aliases.sh');

// 固定虚拟别名：所有 login-cached 模式自动注入
const FIXED_ALIASES = [
  'shopt -s expand_aliases',
  "alias ll='ls -la'",
  "alias la='ls -A'",
  "alias l='ls -CF'",
].join('\n');

let cachedLoginShell = null;
let pendingCapture = null;

// 当前正在运行的子进程（最近一个），供外部中止用
let currentChild = null;
let currentChildId = 0;

function cleanEnv(extra) {
    const e = {};
    for (const k of Object.keys(process.env)) {
        if (k.startsWith('BASH_FUNC_')) continue;
        if (k.startsWith('IFS')) continue;
        e[k] = process.env[k];
    }
    e.TERM = 'xterm-256color';
    e.FORCE_COLOR = '0';
    if (extra) Object.assign(e, extra);
    return e;
}

function cleanStderr(raw) {
    return raw.split('\n')
        .filter(l => !l.includes('error importing function definition for'))
        .filter(l => !l.startsWith('/bin/bash: ') || l.includes('command not found'))
        .join('\n');
}

function fingerprint(cwd) {
    return JSON.stringify({ cwd: String(cwd||''), h: os.hostname() });
}

function getCachedEnv(cwd) {
    if (!cachedLoginShell) return null;
    if (cachedLoginShell.fp !== fingerprint(cwd)) return null;
    if (Date.now() - cachedLoginShell.ts > LOGIN_CACHE_TTL_MS) return null;
    return cachedLoginShell.env;
}

function captureLoginShellEnv(cwd) {
    return new Promise((resolve) => {
        const child = spawn('/bin/bash', ['-lc',
            'echo __ENV__;env;echo __END__;echo __ALIAS__;shopt -s expand_aliases;alias;echo __END__'
        ], { cwd: cwd || ROOT_DIR, env: cleanEnv() });
        let out = '';
        child.stdout.on('data', d => out += d.toString('utf8'));
        child.on('close', () => {
            const envM = out.match(/__ENV__\n([\s\S]*?)\n__END__/);
            const aliasM = out.match(/__ALIAS__\n([\s\S]*?)\n__END__/);
            if (!envM) { resolve(null); return; }
            const env = {};
            for (const l of envM[1].split('\n')) {
                const eq = l.indexOf('=');
                if (eq > 0) env[l.slice(0, eq)] = l.slice(eq + 1);
            }
            if (aliasM && aliasM[1]) {
                const lines = aliasM[1].split('\n').filter(l => l.startsWith('alias '));
                if (lines.length > 0) {
                    try { fs.writeFileSync(ALIASES_CACHE_FILE,
                        '# PlayerX login-shell aliases\nshopt -s expand_aliases\n' +
                        lines.map(l => l.replace(/^alias\s+/, 'alias ')).join('\n') + '\n', 'utf8'); } catch (_) {}
                }
            }
            resolve({ env, ts: Date.now() });
        });
        child.on('error', () => resolve(null));
    });
}

function getOrCaptureLoginShell(cwd) {
    const c = getCachedEnv(cwd);
    if (c) return Promise.resolve(c);
    if (pendingCapture) return pendingCapture;
    pendingCapture = captureLoginShellEnv(cwd).then(r => {
        pendingCapture = null;
        if (r && r.env) {
            cachedLoginShell = { env: r.env, ts: Date.now(), fp: fingerprint(cwd) };
            console.log('[terminal] login env cached (%d entries)', Object.keys(r.env).length);
            return r.env;
        }
        return null;
    }).catch(e => { pendingCapture = null; console.error('[terminal]', e.message); return null; });
    return pendingCapture;
}

function execCommand(req, res) {
    const body = req.body || {};
    const command = String(body.command || '').trim();
    const cwd     = body.cwd ? String(body.cwd) : ROOT_DIR;
    const timeout = Math.min(MAX_TIMEOUT_MS, Math.max(1000, +body.timeout || DEFAULT_TIMEOUT_MS));
    const wantLogin = body.login === true;

    if (!command) return res.status(400).json({ ok: false, error: '命令为空' });

    const banned = [/\bcurl\s+.*\|\s*(sh|bash|zsh)\b/i, /\bnc\s+-e\b/i, /\bbash\s+-i\b/i, /\bsocat\b.*exec/i];
    for (const re of banned) {
        if (re.test(command)) return res.status(400).json({ ok: false, error: '拒绝执行（疑似反弹 shell）' });
    }

// 拒绝交互式命令（会卡死直到超时）：
    //   1) 永远交互式：vim/vi/nano/emacs/less/more/man/top/htop/tmux/screen/ssh/expect
    //      （这些没有非交互模式，只能拒绝）
    //   2) REPL 裸命令（不带任何参数）：python/node/bash/sh/mysql 等
    //   √ python /path/script.py、node -e '...'、mysql -e '...' 都正常放行
    const interactiveOnly = /^\s*(vim?|nano|emacs|less|more|man|top|htop|iotop|iftop|tmux|screen|ssh|telnet|expect|script)\b/m;
    const replBare      = /^\s*(python3?|ipython|node|jshell|bash|sh|zsh|fish|mysql|psql|redis-cli|mongosh|sqlite3?|nc|ftp)\s*$/m;
    if (interactiveOnly.test(command)) {
        return res.status(400).json({ ok: false, hint: 'interactive-rejected', error: `⚠ 该命令是交互式工具，无法在终端面板中使用` });
    }
    if (replBare.test(command)) {
        return res.status(400).json({ ok: false, hint: 'interactive-rejected',
            error: '⚠ 拒绝进入 REPL（会一直占用直到超时）\n请用非交互形式：\n  python -c "code"\n  python script.py\n  node -e "code"\n  mysql -e "SQL"\n  cat file.txt 代替 less',
        });
    }

    const cachedEnv = wantLogin ? getCachedEnv(cwd) : null;
    const isFirst = wantLogin && !cachedEnv;

    if (isFirst) { runCmd(command, cwd, timeout, req, res, 'login-first'); getOrCaptureLoginShell(cwd); return; }
    runCmd(command, cwd, timeout, req, res, wantLogin ? 'login-cached' : 'plain', cachedEnv);
}

function runCmd(command, cwd, timeout, req, res, shellMode, cachedEnv) {
    const t0 = Date.now();

    // 1) 先对原命令做 ls/ll 重写（保证登录缓存模式的前缀不会被破坏）
    //   裸 `ll` → `ls -la -F --color=never`（不依赖别名）
    //   裸 `ls` → `ls -F --color=never`
    //   用户显式带参数（ls -l / ls -lah / ll -t）的不动
    const rewritten = command.replace(/(^|\n)(\s*)(ls|ll)(?=\s*(?:&&|\|\||;|$))/g, (m, nl, lead, cmd) => {
        if (cmd === 'll') return `${nl}${lead}ls -la -F --color=never`;
        return `${nl}${lead}ls -F --color=never`;
    });

    // 2) 登录缓存模式：前缀 source 别名文件 + 注入固定别名（绕过 .bashrc 非交互保护）
    let script = rewritten;
    if (shellMode === 'login-cached') {
        const p = [];
        if (fs.existsSync(ALIASES_CACHE_FILE)) p.push(`source ${shQuote(ALIASES_CACHE_FILE)}`);
        p.push(FIXED_ALIASES);
        script = p.join('\n') + '\n' + rewritten;
    }

    const child = spawn('/bin/bash', [shellMode === 'login-first' ? '-lc' : '-c', script], {
        cwd,
        env: shellMode === 'login-cached' && cachedEnv ? cleanEnv(cachedEnv) : cleanEnv(),
    });

    // 记录到全局供 /api/terminal/kill 调用
    const childId = ++currentChildId;
    currentChild = { child, id: childId, command, t0 };
    // 子进程结束/出错时清掉引用
    child.on('close', () => { if (currentChild && currentChild.id === childId) currentChild = null; });
    child.on('error', () => { if (currentChild && currentChild.id === childId) currentChild = null; });

    let out = Buffer.alloc(0), err = Buffer.alloc(0), trunc = false, killed = false, timer;

    function append(b, c) {
        if (b.length + c.length > MAX_OUTPUT_BYTES) { trunc = true; return b.slice(0, MAX_OUTPUT_BYTES); }
        return Buffer.concat([b, c]);
    }
    child.stdout.on('data', d => out = append(out, d));
    child.stderr.on('data', d => err = append(err, d));

    let aborted = false;
    req.on('aborted', () => { aborted = true; if (!child.killed) { killed = true; child.kill('SIGKILL'); } });
    res.on('close', () => { if (!res.headersSent && !aborted) { aborted = true; if (!child.killed) { killed = true; child.kill('SIGKILL'); } } });
    timer = setTimeout(() => { killed = true; try { child.kill('SIGKILL'); } catch (_) {} }, timeout);

    child.on('error', (e) => { clearTimeout(timer); return res.status(500).json({ ok: false, error: '启动失败: ' + e.message }); });
    child.on('close', (code, signal) => {
        clearTimeout(timer);
        const rawErr = err.toString('utf8');
        res.json({
            ok: true, command, cwd, code, signal: signal || null,
            stdout: out.toString('utf8'),
            stderr: cleanStderr(rawErr),
            durationMs: Date.now() - t0, killed, truncated: trunc,
            truncatedReason: trunc ? `输出超过 ${MAX_OUTPUT_BYTES} 字节，已截断` : null,
            host: os.hostname(), user: (process.getuid && os.userInfo().username) || 'unknown',
            shellMode,
        });
    });
}

function refreshLoginShell(req, res) {
    const cwd = (req.body && req.body.cwd) ? String(req.body.cwd) : ROOT_DIR;
    pendingCapture = null; cachedLoginShell = null;
    try { fs.unlinkSync(ALIASES_CACHE_FILE); } catch (_) {}
    captureLoginShellEnv(cwd).then(r => {
        if (!r) return res.status(500).json({ ok: false, error: '捕获失败' });
        cachedLoginShell = { env: r.env, ts: Date.now(), fp: fingerprint(cwd) };
        res.json({ ok: true, envCount: Object.keys(r.env).length, path: r.env.PATH || '', cachedAt: cachedLoginShell.ts });
    });
}

// 中止当前正在执行的命令（先 SIGTERM 让进程收尾，超时 500ms 后 SIGKILL 强杀）
function handleKill(req, res) {
    if (!currentChild) {
        return res.json({ ok: false, error: '当前没有正在执行的命令', killed: false });
    }
    const target = currentChild;
    try { target.child.kill('SIGTERM'); } catch (_) {}
    // 500ms 后强杀（兜底）
    setTimeout(() => {
        try { if (!target.child.killed) target.child.kill('SIGKILL'); } catch (_) {}
    }, 500);
    res.json({ ok: true, killed: true, command: target.command, id: target.id });
}

function metaInfo(req, res) {
    res.json({
        ok: true, cwd: ROOT_DIR, host: os.hostname(),
        user: (process.getuid && os.userInfo().username) || 'unknown',
        platform: os.platform(), maxTimeoutMs: MAX_TIMEOUT_MS, defaultTimeoutMs: DEFAULT_TIMEOUT_MS,
        maxOutputBytes: MAX_OUTPUT_BYTES,
        loginCached: cachedLoginShell ? { cachedAt: cachedLoginShell.ts, ageSeconds: Math.round((Date.now()-cachedLoginShell.ts)/1000), ttlSeconds: Math.round(LOGIN_CACHE_TTL_MS/1000) } : null,
        loginCapturing: pendingCapture != null,
    });
}

function shQuote(s) { return `'${String(s).replace(/'/g, `'\\''`)}'`; }

module.exports = { execCommand, metaInfo, refreshLoginShell, handleKill };
