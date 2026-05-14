# PlayerX 评分收集服务

最简后端：客户端 → POST CSV → 服务端落盘 → 你随时合并取数。

## 启动

```bash
cd PlayerX-server
npm install        # 仅首次
npm start          # 默认监听 0.0.0.0:8765
```

自定义端口/鉴权：

```bash
PORT=9000 PLAYERX_TOKEN=mySecret123 node server.js
```

启动成功后浏览器打开 `http://<本机 IP>:8765/` 看到状态页即正常。

## 局域网验证流程

1. 服务端在你 Mac 上跑：`npm start`
2. 同一 Wi-Fi 下查本机 IP：`ipconfig getifaddr en0`（macOS）
3. 客户端在「评分数据」对话框设置：
   - 上传地址 = `http://<本机 IP>:8765/upload`
   - Token：默认空即可（如启动时设置了 PLAYERX_TOKEN，这里要填一致）
4. 点「☁ 上传到云端」 → 服务端控制台会打印 `[upload] xxx.csv` 日志
5. 浏览器访问 `http://<本机 IP>:8765/list` 看落盘文件
6. 一键合并下载：`http://<本机 IP>:8765/merge`

## 接口

| Method | Path     | 说明                                  |
| ------ | -------- | ------------------------------------- |
| GET    | `/`      | 健康检查（HTML）                      |
| POST   | `/upload`| 上传 CSV，字段：`file` / `user` / `client` |
| GET    | `/list`  | 已收 CSV 列表（JSON）                 |
| GET    | `/merge` | 全部 CSV 合并下载（仅保留一行表头）   |

## 文件落盘规则

`uploads/<user>_<yyyy-MM-dd_HH-mm-ss>.csv`

- 用户名做了字符净化（仅留字母数字、下划线、横线、点、汉字）
- 同一人多次上传 = 多个版本快照（带时间戳），不会互相覆盖
- 单文件最大 10MB（CSV 远远不会到这个量级）

## 部署到团队服务器

把这个目录整体拷过去，`npm install && npm start` 即可。
建议用 `pm2` 守护：

```bash
npm i -g pm2
pm2 start server.js --name playerx-server
pm2 save
```
