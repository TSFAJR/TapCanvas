# 阿里云基础版部署

唯一上游：https://github.com/anymouschina/TapCanvas 。个人仓库：https://github.com/TSFAJR/TapCanvas 。首次官方基线：`c2c825a3855247441f9a8a1fa057fc275d5ca72e`。

本配置供 2 核、约 4 GB 内存的单人基础试用。支持登录、项目、手工画布及持久化；未配置模型供应商，生成和媒体 Worker 不启动。没有执行付费模型验收。API 自带的本地资产目录持久化，对象存储另行配置。

官方初始化 SQL 含预置供应商渠道凭据。基础发布在应用初始化前运行 `basic-model-policy.sh`，清空本部署渠道凭据并停用所有能力路由，防止种子数据被误报为模型可用；发布前备份保留原状态。以后明确进入模型配置阶段，先在 runtime.env 设置 `TAPCANVAS_BASIC_NO_MODELS=0`，再配置自己的渠道，否则下一次基础发布会清除渠道凭据。该选项缺省为 1，非法值会中止发布。

## 开发与更新

`origin` 是个人 Fork，`upstream` 是官方仓库。`main` 跟踪官方，`develop` 保存部署和二开。功能从 `develop` 建独立分支；不要直接修改线上 release。

```bash
git fetch origin
git switch develop
git pull --ff-only origin develop
git switch -c feat/my-feature
```

使用 Node 22.19.0、pnpm 10.8.1。Web 开发按官方 README；本地开发使用独立数据库和 `.env`，不能连接线上数据。官方更新执行 `bash ops/aliyun-basic/sync-upstream.sh`，解决冲突并测试后开 PR 到 develop。不要自动覆盖线上。

## 构建和发布

`Basic deployment images` 工作流在 develop 提交时运行：检查编排、测试和构建 Web、构建 API/Bridge/New API，再推送 GHCR。镜像名为 `ghcr.io/tsfajr/tap-canvas-{web,api,agents-bridge,new-api}`，tag 是完整源码 SHA；最终 `deployment-manifest` artifact 包含 digest 锁定的 `images.env`。服务器不编译。GHCR 包需对部署服务器可读；不得为此公开凭据。

首次准备 `/srv/tap-canvas` Git 仓库和 `/etc/tap-canvas/runtime.env`（权限 600），数据目录位于 `/data/tap-canvas`。把 manifest 放到服务器，再执行：

```bash
git -C /srv/tap-canvas fetch origin develop
sudo bash /srv/tap-canvas/ops/aliyun-basic/deploy.sh /absolute/path/images.env
sudo bash /data/tap-canvas/current/source/ops/aliyun-basic/health.sh
```

发布创建独立源码 worktree、分阶段迁移、按依赖启动并验证健康，记录 `version.json`、镜像摘要及初始化日志；成功后切换 current/previous。失败时保留日志和数据并关闭前端入口，不能把迁移失败当作已发布。

容器项目名固定 `tapcanvas`。只开放 Web 80，API 8788、网关 4455、Bridge 8799 仅回环监听；数据库和 Redis 不映射宿主端口。旧 AID Studio 和宿主 Nginx 必须保持停止。

部署脚本不从网络自动执行主分支代码，不接受浮动镜像标签，不会清理旧项目、旧镜像或数据卷。

## 配置

`runtime.env` 至少包含：POSTGRES_DB、POSTGRES_USER、POSTGRES_PASSWORD、JWT_SECRET、INTERNAL_WORKER_TOKEN、AGENTS_BRIDGE_TOKEN、NEW_API_INTERNAL_TOKEN、NEW_API_SESSION_SECRET、NEW_API_CRYPTO_SECRET、NEW_API_USD_EXCHANGE_RATE、TAPCANVAS_ADMIN_USERNAME、TAPCANVAS_ADMIN_PASSWORD、NEW_API_ROOT_USERNAME、NEW_API_ROOT_PASSWORD。

路径设置：TAPCANVAS_ENV_FILE=/etc/tap-canvas/runtime.env，TAPCANVAS_PROJECT_DATA_ROOT=/data/tap-canvas/project-data，TAPCANVAS_SHARED_ROOT=/data/tap-canvas/shared，TAPCANVAS_NEW_API_DATA_ROOT=/data/tap-canvas/new-api-data，TAPCANVAS_NEW_API_LOG_ROOT=/data/tap-canvas/new-api-logs。NEW_API_PUBLIC_BASE_URL=http://127.0.0.1:4455（管理员通过 SSH 隧道使用），CORS_ALLOWED_ORIGINS 使用实际 Web 来源，WEB_PORT=80，AGENTS_BRIDGE_AUTOSTART=0。不填供应商和云存储密钥，不继承示例厂商地址。Web 在 CI 使用 VITE_API_BASE=/api。

## 备份与恢复

`backup.sh` 暂停写服务和 Redis，导出两个数据库及持久文件，然后恢复服务；每日 04:15（上海时区）触发，有短暂停机。只清理 TapCanvas 下第 8 份以后的完整备份，不处理失败备份或旧项目数据。配置归档包含密钥，仅 root 可读；异地备份同样按密钥保护。

```bash
sudo bash /data/tap-canvas/current/source/ops/aliyun-basic/backup.sh
sudo systemctl status tapcanvas-backup.timer
sudo bash /data/tap-canvas/current/source/ops/aliyun-basic/rollback.sh
sudo bash /data/tap-canvas/current/source/ops/aliyun-basic/restore-drill.sh /data/tap-canvas/backups/备份目录
```

回退仅接受已通过健康检查且 schema 指纹相同的版本。指纹覆盖 Prisma、基础 schema、seed runner 和 New API model/patch；不同指纹必须先评估并恢复配套备份。升级评审仍必须核对数据库变更，指纹不是自动判定 SQL 兼容性的替代品。

首次官方基线存在历史修复与当前 schema 的冲突：旧修复尝试修改已退役的充值字段。兼容代码仅在执行历史 baseline 修复时检查这两个字段是否存在，保留原迁移文件及校验值；baseline 同时实际执行官方社区版支付/SMS 清理迁移。迁移 runner 和兼容模块也计入发布 schema 指纹。

数据恢复步骤：关闭 Web/API/Bridge/New API/Redis，另存当前状态；校验备份 SHA256SUMS；将两个 dump 恢复到新建隔离数据库并验证；需要正式切换时再恢复匹配版本数据库与 files.tar.gz（包括 Redis AOF/RDB 和 Bridge DSH_HOME），恢复对应密钥和镜像 manifest，启动并验收。禁止直接覆盖未经保留的当前数据。

`restore-drill.sh` 自动校验备份并恢复两个隔离数据库，输出各表行数和 schema，不修改生产数据库。演练数据库会保留，复核后按报告中的明确名称清理。发布记录另含实际 Prisma 迁移清单和运行镜像 ID。

前端沿用官方的公开素材 CDN（TOS/R2 公共地址），只用于读取官方内置演示素材；这不等于配置了媒体上传或后端对象存储。

HTTP/IP 部署由 Web 启动层在缺少 `crypto.randomUUID` 时使用 `crypto.getRandomValues` 生成标准 UUID v4；HTTPS 下保留原生实现。这只兼容节点和会话 ID，不启用需要 HTTPS 的 Service Worker 等浏览器功能。

本工作流设置构建参数 `VITE_ALLOW_BASIC_WITHOUT_MODELS=true`：模型检查明确返回未就绪时显示持续提示，允许手工编辑。不会伪造模型可用性，也不会放行配置检查错误；其他构建默认仍采用官方的模型配置弹窗。

HTTP/IP 入口挂载 `http-cookies.conf`，仅移除三个登录 Cookie 的 Secure 标记，使浏览器能在已选定的 HTTP 入口保存会话；HttpOnly、SameSite 与有效期保持原值。迁移到 HTTPS 时必须移除此挂载，恢复浏览器的 Secure 限制。默认 Web 镜像没有该挂载时不改写 Cookie。

日志：`docker compose` 经 common.sh 的 `dc logs` 查看；`journalctl -u tapcanvas-backup.service` 查看备份结果。以 health.sh、OOMKilled、RestartCount、宿主 free/vmstat/df 联合判断健康，网页 200 不代表全部验收通过。
