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

const upload   = require('./upload');
const list     = require('./list');
const merge    = require('./merge');
const files    = require('./files');
const preview  = require('./preview');
const status   = require('./status');
const del      = require('./delete');
const archive  = require('./archive');
const auth     = require('./auth');
const settings = require('./settings');

function mountApi(app) {
    // ── 公开接口 ─────────────────────────────────────────────
    app.get('/api/status', status.makeHandler());

    // 上传（来自 PlayerX 客户端）：先校验 X-Token，再走 multer 解析文件
    app.post('/upload',     upload.checkUploadToken, upload.multerMiddleware, upload.handle);
    app.post('/api/upload', upload.checkUploadToken, upload.multerMiddleware, upload.handle);

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

    app.post('/api/archive',           auth.requireAdmin, jsonParser, archive.handleArchive);
    app.post('/api/files/bulk-delete', auth.requireAdmin, jsonParser, archive.handleBulkDelete);

    app.delete('/api/archive/file/:folder/:name', auth.requireAdmin, archive.handleDeleteArchivedFile);
    app.delete('/api/archive/folder/:folder',     auth.requireAdmin, archive.handleDeleteArchiveFolder);
    app.post('/api/archive/bulk-delete',          auth.requireAdmin, jsonParser, archive.handleBulkDeleteArchived);

    // 归档合并：POST 形态（带 names 子集）也允许匿名访问，仅是合并下载
    app.post('/api/archive/merge/:folder', jsonParser, archive.handleMergeArchived);
}

module.exports = { mountApi };
