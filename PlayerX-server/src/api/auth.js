/**
 * src/api/auth.js — token 鉴权中间件工厂
 *
 * 文案前缀 "[AUTH] " 是与 PlayerX 客户端约定好的标记：
 * 客户端在 RatingStore 里识别该前缀后，会弹出强提醒并引导去填 token。
 */
function makeAuth(token) {
    return function checkToken(req, res, next) {
        if (!token) return next();
        const got = req.header('X-Token') || req.query.token;
        if (got !== token) {
            const reason = !got
                ? '[AUTH] 服务器已开启鉴权，但客户端未携带 token，请在「⚙ 上传设置」中填写。'
                : '[AUTH] token 不匹配，请在「⚙ 上传设置」中确认 token 是否填写正确。';
            return res.status(401).json({ ok: false, error: reason });
        }
        next();
    };
}

module.exports = { makeAuth };
