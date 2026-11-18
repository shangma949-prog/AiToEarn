# 本机隔离运行

单一入口是 `deploy/local/aitoearnctl.sh`。口令、登录令牌、pid 和日志只写入 `deploy/local/.runtime/`，该目录已在 `.gitignore`。

```bash
bash deploy/local/aitoearnctl.sh start
bash deploy/local/aitoearnctl.sh status
bash deploy/local/aitoearnctl.sh check
bash deploy/local/aitoearnctl.sh restart
bash deploy/local/aitoearnctl.sh stop
bash deploy/local/aitoearnctl.sh stop --all
```

`start` 拉起 MongoDB、Redis、RustFS、server、ai、本机代理和网页。`restart` 先停应用再启动，默认保留数据库卷。`stop --all` 才停止容器，不删除卷。

前提：Docker、Node.js 22、pnpm 10.33，以及 `/etc/hosts` 中的 `127.0.0.1 rustfs.local`。第一次启动会生成 `secrets.env`。已有数据卷时不要换掉其中的数据库口令。

网页地址是 `http://127.0.0.1:6061/zh-CN`。`AUTO_LOGIN_TOKEN` 只是本地进程环境里的合成登录，不是邮箱、短信或平台身份验证。代理 `127.0.0.1:7080` 把 `/ai`、`/agent` 转到 3010，其余转到 3002。四个应用端口都绑定 `127.0.0.1`。

已构建的 server/ai 用 `node dist/apps/<app>/src/main.js` 启动，并通过 `register-dist.cjs` 把 `@yikart/*` 指到 `dist/libs`。没有构建产物时才退回 `nx serve`。网页优先使用 `.next/standalone`。

`check` 确认标题为「页面合成草稿」的记录仍在，封面对象可以下载，并且 API 列表还能读到它。

## 本次实测资源

生产形态常驻大约：server 304MB、ai 238MB、网页 97MB、代理 56MB、MongoDB 183MB、RustFS 125MB、Redis 10MB。合计约 1.1GB RSS。空闲时容器 CPU 低于 1%。启动约 10 秒，启动期间可用内存比启动前少约 700MB。

开发形态的 `nx serve` 加 `next dev` 曾到约 7GB RSS，不适合内存余量只有 2GB 的机器。

磁盘：Mongo 镜像 1.19GB、RustFS 镜像 488MB、Redis 镜像 58MB，数据卷约 305MB。后端 `node_modules` 985MB，网页 `node_modules` 872MB，standalone 171MB。`nx build` 的 dist 只有 12MB，仍要依赖这份 `node_modules`，不能单独拷走运行。没有构建或上传公共镜像。

## 依赖边界

可以自己完成、且不调用收费接口：基础设施、素材上传、草稿读写、健康检查、平台目录、B站授权 URL 的本地拼接、未来时间的发布记录落库。

必须由使用者向平台申请或授权后才能继续，仓库不包含这些密钥：

- 抖音：开放平台 `clientId`/`clientSecret` 和小程序 `miniApp`。授权会请求 `open.douyin.com`。默认配置是 `hidden`。
- B站：开放平台 `clientId`/`clientSecret`。真正换票和投稿访问 `api.bilibili.com`、`member.bilibili.com`。
- 小红书：浏览器插件和已登录的创作者站才能发笔记。服务端只绑定作品链接。线下分享签名需要 `appKey`/`appSecret`，地址是 `edith.xiaohongshu.com`。
- AI 生成和 Agent：`ai.openai`、`ai.gemini`、`ai.anthropic`、`ai.volcengine`、`ai.grok`、`ai.dashscope` 或 `ai.relay` 的密钥。空密钥可以启动并返回模型目录，不能生成。
- 官方 Relay：`relay.apiKey` 配 `aitoearn.cn` 或 `aitoearn.ai`。本地配置会删掉 `relay`，避免空密钥也被转到官方。

没有任务市场、钱包或结算服务。不要把合成登录当成真实账号验证，也不要在没有平台授权时点击发布。
