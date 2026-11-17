# 本机隔离运行

这些文件用来在一台自己的机器上启动已验证的依赖，并检查草稿和“只有发布记录、没有进入队列”。不要把 `deploy/local/.runtime/` 提交到 git。

## 准备

- Docker、Node.js 22、pnpm 10.33
- `/etc/hosts` 增加一行：`127.0.0.1 rustfs.local`
- 在仓库根目录执行：

```bash
bash deploy/local/start-local.sh
```

脚本会在 `deploy/local/.runtime/secrets.env` 生成口令，拉起只监听 `127.0.0.1` 的 MongoDB 7.0、Redis 7.4 和 RustFS，并写出 git 忽略的：

- `project/aitoearn-backend/apps/aitoearn-server/config/local.config.yaml`
- `project/aitoearn-backend/apps/aitoearn-ai/config/local.config.yaml`

然后按脚本打印的命令启动两个后端。健康检查：

- `curl http://127.0.0.1:3002/health`
- `curl http://127.0.0.1:3010/health`

## 验证

```bash
node deploy/local/verify-local.mjs deploy/local/.runtime
```

断言包括服务健康、上传、草稿读写，以及一条 7 天后的抖音发布记录。记录状态必须是等待发布，Redis 里不能出现对应的 `publish-<任务ID>`。这只证明排期落库，不代表发布队列或平台发布成功。

## 网页

后端起来之后：

```bash
bash deploy/local/start-local.sh --web
```

浏览器打开 `http://127.0.0.1:6061/zh-CN`。`AUTO_LOGIN_TOKEN` 只放在该进程环境里，用来调用网页已有的自动登录。邮箱验证码登录在这个开源后端里没有对应接口。

代理 `deploy/local/api-proxy.mjs` 监听 `127.0.0.1:7080`：`/ai` 和 `/agent` 转到 3010，其余转到 3002。

## 不要做的事

- 不要填写真实社媒密钥后点击授权或发布。
- 不要调用模型生成。本地配置保留空的模型密钥，并去掉 `relay`，避免授权被转到 `aitoearn.ai`。
- 根目录 `docker-compose.yml` 仍包含官方应用镜像；本目录只覆盖已经在本机跑通的数据库、队列和对象存储。
