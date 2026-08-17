/**
 * src/api/index.js — API 路由聚合
 *
 * 对外暴露 mountApi(app)：
 *   - 把所有业务接口挂到 Express app
 *   - 读操作（list / files / merge / preview / 归档浏览 / 归档下载 / 归档合并）匿名可访问
 *   - 写操作（删除 / 归档 / 批量删除 / 删除归档文件 / 删除归档文件夹）需要管理员登录
 *   - 同时保留旧路径（/upload /list /merge）兼容历史客户端
 */
const express = require('express');

const upload       = require('./upload');
const manualUpload  = require('./manual-upload');
const analyze      = require('./analyze');
const analyzeShare = require('./analyze-share');
const analyzeCfgs  = require('./analyze-configs');
const build        = require('./build');
const list     = require('./list');
const merge    = require('./merge');
const files    = require('./files');
const preview  = require('./preview');
const status   = require('./status');
const del      = require('./delete');
const archive  = require('./archive');
const auth     = require('./auth');
const settings   = require('./settings');
const dimensions = require('./dimensions');
const testsrc    = require('./testsrc');
const models     = require('./models');
const dashboard  = require('./dashboard');
const terminal   = require('./terminal');

function mountApi(app) {
    // ── 公开接口 ─────────────────────────────────────────────
    app.get('/api/status', status.makeHandler());
    app.get('/api/dashboard', dashboard.handle);

    // ── 上传路径兼容 ──────────────────────────────────────────
    // 用户在播放器「上传设置」里很容易只填基址（如 http://host:2026 或带尾斜杠），
    // 不带 /upload 路径。为避免请求被静态中间件吞掉变成"看似成功实际没收到"，
    // 这里把以下所有 path 上的 POST 都路由到上传 handler：
    //   POST /  /upload  /upload/  /api/upload  /api/upload/
    // （客户端侧也已做归一化补 /upload，这里是双保险）
    const uploadChain = [upload.checkUploadToken, upload.multerMiddleware, upload.handle];
    const uploadPaths = ['/', '/upload', '/upload/', '/api/upload', '/api/upload/'];
    for (const p of uploadPaths) app.post(p, ...uploadChain);

    // 列表 / 下载 / 合并下载 / 预览：匿名可访问
    app.get('/list',     list.handle);
    app.get('/api/list', list.handle);

    app.get('/merge',     merge.handle);
    app.get('/api/merge', merge.handle);
    const jsonParserMerge = express.json({ limit: '1mb' });
    app.post('/merge',     jsonParserMerge, merge.handle);
    app.post('/api/merge', jsonParserMerge, merge.handle);

    app.get('/files/:name',     files.handle);
    app.get('/api/files/:name', files.handle);

    app.get('/preview/:name',     preview.handle);
    app.get('/api/preview/:name', preview.handle);

    // 归档浏览 / 下载 / 预览 / 合并：匿名可访问
    app.get('/api/archive/folders',                 archive.handleListFolders);
    app.get('/api/archive/list',                    archive.handleListFolderFiles);
    app.get('/api/archive/file/:folder/:name',      archive.handleDownloadArchived);
    app.get('/api/archive/preview/:folder/:name',   archive.handlePreviewArchived);
    app.get('/api/archive/merge/:folder',           archive.handleMergeArchived);

    // ── 管理员登录 / 登出 ─────────────────────────────────────
    const jsonAuth = express.json({ limit: '8kb' });
    app.post('/api/admin/login',  jsonAuth, auth.handleAdminLogin);
    app.post('/api/admin/logout',           auth.handleAdminLogout);
    app.get('/api/admin/auth-info', (_req, res) => {
        res.json({ ok: true, authEnabled: auth.isAuthEnabled() });
    });

    // ── 受保护接口（写操作）────────────────────────────────────
    const jsonParser = express.json({ limit: '256kb' });

    app.delete('/files/:name',     auth.requireAdmin, del.handle);
    app.delete('/api/files/:name', auth.requireAdmin, del.handle);

    // 上传 Token 设置（仅管理员可读写）
    app.get('/api/settings/upload-token', auth.requireAdmin, settings.handleGet);
    app.put('/api/settings/upload-token', auth.requireAdmin, jsonParser, settings.handlePut);

    // 管理员手动上传（仅登录管理员可用）
    app.post('/api/manual-upload', auth.requireAdmin, manualUpload.multerMiddleware, manualUpload.handle);

    // 盲评分析（仅登录管理员可用）
    app.post('/api/analyze', auth.requireAdmin, express.json({ limit: '1mb' }), analyze.handle);

    // 盲评分析结果分享快照（公开读，登录写）
    //   GET    /api/analyze/share/:id  公开（带链接者皆可查看）
    //   POST   /api/analyze/share      登录管理员创建快照
    //   GET    /api/analyze/shares     登录管理员列出所有快照
    //   DELETE /api/analyze/share/:id  登录管理员删除快照
    const jsonShare = express.json({ limit: '1mb' });
    app.get('/api/analyze/share/:id',                  analyzeShare.handleGetShare);
    app.post('/api/analyze/share',   auth.requireAdmin, jsonShare,     analyzeShare.handleCreateShare);
    app.get('/api/analyze/shares',   auth.requireAdmin,                  analyzeShare.handleListShares);
    app.delete('/api/analyze/share/:id', auth.requireAdmin,             analyzeShare.handleDeleteShare);

    // 盲评构建（仅登录管理员可用）
    app.post('/api/build', auth.requireAdmin, express.json({ limit: '1mb' }), build.handle);
    app.post('/api/build/zip', auth.requireAdmin, express.json({ limit: '1mb' }), build.handleZip);
    app.post('/api/build/list-models', auth.requireAdmin, express.json({ limit: '1mb' }), build.handleListModels);

    //模型源目录管理
    app.get('/api/models',auth.requireAdmin, models.handleList);
    app.post('/api/models/scan',    auth.requireAdmin, express.json({ limit: '1mb' }), models.handleScan);
    app.post('/api/models',auth.requireAdmin, express.json({ limit: '1mb' }), models.handleCreate);
    app.put('/api/models/:id',      auth.requireAdmin, express.json({ limit: '1mb' }), models.handleUpdate);
    app.delete('/api/models/:id',   auth.requireAdmin, models.handleDelete);
    // 上传模型文件夹（zip 包，解压到 assets/<name> 并自动建源）
    app.post('/api/models/upload-folder',
        auth.requireAdmin,
        models.zipUploadMiddleware,
        models.handleUploadFolder);

    // 在线终端（管理员登录后才可用）
    app.get ('/api/terminal/meta',    auth.requireAdmin, terminal.metaInfo);
    app.post('/api/terminal/exec',    auth.requireAdmin, express.json({ limit: '16kb' }), terminal.execCommand);
    app.post('/api/terminal/refresh', auth.requireAdmin, express.json({ limit: '4kb' }),  terminal.refreshLoginShell);
    app.post('/api/terminal/kill',    auth.requireAdmin, terminal.handleKill);

    // 浏览 assets 目录（供任务管理路径选择）
    app.post('/api/browse-assets', auth.requireAdmin, express.json({ limit: '1mb' }), (req, res) => {
        const fs = require('fs');
        const path = require('path');
        const { ASSETS_DIR } = require('../lib/paths');
        const { subdir = '' } = req.body || {};
        const target = subdir ? path.join(ASSETS_DIR, subdir) : ASSETS_DIR;
        // 安全检查：不允许 .. 越界
        if (!path.resolve(target).startsWith(path.resolve(ASSETS_DIR))) {
            return res.json({ ok: false, error: '路径越界' });
        }
        try {
            const entries = fs.readdirSync(target, { withFileTypes: true });
            const items = entries
                .filter(e => !e.name.startsWith('.'))
                .map(e => ({ name: e.name, isDir: e.isDirectory() }))
                .sort((a, b) => {
                    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
                    return a.name.localeCompare(b.name);
                });
            res.json({ ok: true, base: ASSETS_DIR, items });
        } catch (err) {
            res.json({ ok: true, base: ASSETS_DIR, items: [] });
        }
    });

    // 盲评分析配置管理（GET 公开，写操作需管理员）
    app.get('/api/analyze-configs',              analyzeCfgs.handleList);
    app.get('/api/analyze-configs/:name',        analyzeCfgs.handleGetOne);
    app.put('/api/analyze-configs/:name',        auth.requireAdmin, jsonParser, analyzeCfgs.handlePutOne);
    app.delete('/api/analyze-configs/:name',     auth.requireAdmin, analyzeCfgs.handleDeleteOne);

    // 多配置文件管理（GET 公开，写操作需管理员）
    app.get('/api/configs',              dimensions.handleList);
    app.put('/api/configs-order',        auth.requireAdmin, jsonParser, dimensions.handleReorder);
    app.get('/api/configs/:name',        dimensions.handleGetOne);
    app.put('/api/configs/:name',        auth.requireAdmin, jsonParser, dimensions.handlePutOne);
    app.delete('/api/configs/:name',     auth.requireAdmin, dimensions.handleDeleteOne);
    // 激活配置（GET 公开，PUT 需管理员）
    app.get('/api/active-config',        dimensions.handleGetActive);
    app.put('/api/active-config',        auth.requireAdmin, jsonParser, dimensions.handleSetActive);
    // 兼容旧接口（GET 公开返回激活配置，PUT 需管理员）
    app.get('/api/dimensions', dimensions.handleGet);
    app.put('/api/dimensions', auth.requireAdmin, jsonParser, dimensions.handlePut);

    app.post('/api/archive',           auth.requireAdmin, jsonParser, archive.handleArchive);
    app.post('/api/files/bulk-delete', auth.requireAdmin, jsonParser, archive.handleBulkDelete);

    app.delete('/api/archive/file/:folder/:name', auth.requireAdmin, archive.handleDeleteArchivedFile);
    app.delete('/api/archive/folder/:folder',     auth.requireAdmin, archive.handleDeleteArchiveFolder);
    app.post('/api/archive/bulk-delete',          auth.requireAdmin, jsonParser, archive.handleBulkDeleteArchived);

    // 归档合并：POST 形态（带 names 子集）也允许匿名访问，仅是合并下载
    app.post('/api/archive/merge/:folder', jsonParser, archive.handleMergeArchived);

    // 测试源安装包（zip）托管：list 匿名可读，upload/delete 需管理员
    //（静态下载 /testsrc/<name> 在 server.js 挂载）
    testsrc(app);
}

module.exports = { mountApi };
