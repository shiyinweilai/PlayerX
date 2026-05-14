/**
 * src/api/index.js — API 路由聚合
 *
 * 对外暴露 mountApi(app)：
 *   - 把所有业务接口挂到 Express app
 *   - 服务端不做鉴权（局域网内部使用，简化部署与排障）
 *   - 同时保留旧路径（/upload /list /merge）兼容历史客户端，
 *     新增带前缀的 /api/* 给 Web 面板使用
 *
 * 注：客户端 / Web 面板仍可在请求头里带 X-Token，本服务一律忽略它，
 *      不再返回 401。前端"Token"按钮只是本地软约束，防止误传。
 */
const upload  = require('./upload');
const list    = require('./list');
const merge   = require('./merge');
const files   = require('./files');
const status  = require('./status');

function mountApi(app) {
    // 不需要鉴权：保留 /api/status 仅用于前端探活与展示版本号
    app.get('/api/status', status.makeHandler());

    app.post('/upload',     upload.multerMiddleware, upload.handle);
    app.post('/api/upload', upload.multerMiddleware, upload.handle);

    app.get('/list',     list.handle);
    app.get('/api/list', list.handle);

    app.get('/merge',     merge.handle);
    app.get('/api/merge', merge.handle);

    app.get('/files/:name',     files.handle);
    app.get('/api/files/:name', files.handle);
}

module.exports = { mountApi };
