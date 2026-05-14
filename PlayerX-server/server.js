/**
 * server.js — PlayerX 评分 CSV 收集服务（启动器）
 *
 * 这个文件刻意保持极简，只负责：
 *   1. 读取端口
 *   2. 挂载 src/web/ 下的静态前端（首页 / Web 面板）
 *   3. 挂载 src/api/ 下的所有业务路由
 *   4. 监听端口
 *
 * 业务实现全部在 ./src/ 下：
 *   src/api/{upload,list,merge,files,status,index}.js
 *   src/lib/{paths,slug,store}.js
 *   src/web/{index.html,style.css,app.js}
 *
 * 启动：
 *   npm install                              # 仅首次
 *   node server.js                           # 默认 0.0.0.0:8765
 *   PORT=9000 node server.js                 # 自定义端口
 *
 * 注：服务端**不做鉴权**，仅适用于受信任的内网/局域网部署。
 *     如果未来需要鉴权，请在反向代理（Nginx/Caddy）层加。
 */
const express = require('express');
const path    = require('path');

const { WEB_DIR, UPLOAD_DIR, ARCHIVE_DIR, ARCHIVE_KEEP, ensureDirs } = require('./src/lib/paths');
const { mountApi } = require('./src/api');

// ── 配置 ──────────────────────────────────────────────────────────────
const PORT  = parseInt(process.env.PORT || '8765', 10);
ensureDirs();

const app = express();

// 1) 静态前端：/web/* → src/web/*
//    评分服务通常局域网部署、前端代码会迭代修改；
//    若浏览器命中本地缓存的旧 app.js / style.css，会出现"改了不生效"的诡异现象，
//    所以这里关闭客户端缓存（仅几个小文件，无性能负担），并显式回 no-cache。
app.use('/web', express.static(WEB_DIR, {
    fallthrough: true,
    etag: false,
    lastModified: false,
    maxAge: 0,
    cacheControl: false,
    setHeaders(res) {
        res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.setHeader('Expires', '0');
    },
}));

// 2) 根路径直接给 Web 面板（index.html）
app.get('/', (_req, res) => {
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
    res.sendFile(path.join(WEB_DIR, 'index.html'));
});

// 3) 挂载 API（包含 /upload /list /merge /files /api/status 等）
mountApi(app);

// 4) multer / 自定义错误兜底
app.use((err, _req, res, _next) => {
    console.error('[error]', err);
    res.status(400).json({ ok: false, error: err.message || 'unknown error' });
});

app.listen(PORT, '0.0.0.0', () => {
    console.log(`PlayerX server listening on http://0.0.0.0:${PORT}`);
    console.log(`  uploads dir : ${UPLOAD_DIR}`);
    console.log(`  archive dir : ${ARCHIVE_DIR}  (keep latest ${ARCHIVE_KEEP} per slot)`);
    console.log(`  auth        : disabled (LAN-only)`);
    console.log(`  web panel   : http://localhost:${PORT}/`);
});
