# sub2api-helper

Sub2API Docker 在线一键部署辅助工具。

> [Sub2API](https://github.com/Wei-Shaw/sub2api) 是一个一站式 AI API 网关平台，支持将 Claude / OpenAI / Gemini 等多账号统一管理和 API 分发。

## 仓库内容

```
├── scripts/
│   ├── deploy-online.sh      # 在线一键部署脚本
│   ├── update-online.sh      # 已有部署的备份 + 友好更新脚本
│   └── sync-vps-backups.sh   # 本机拉取/推送 VPS 备份脚本
├── docs/blog/
│   └── blog-cn.md            # 完整部署教程
└── readme.md                 # 本文件
```

## 快速开始

```bash
git clone https://github.com/KaminDeng/sub2api-helper.git
cd sub2api-helper
bash scripts/deploy-online.sh
```

脚本会自动完成系统检测、Docker 安装、密钥生成、容器启动，3-5 分钟即可部署完成。

## VPS 快速部署

从本地通过 SSH 控制远程 VPS 一键部署，常见于云服务器（阿里云、腾讯云、Vultr、DigitalOcean 等）场景。

### 三种部署模式

| 模式 | 适用场景 | 需要配置 |
|------|----------|----------|
| **A：纯 HTTP** | 内网 / 测试环境 | 仅 `SERVER_PORT` |
| **B：HTTPS（已有证书）** | 80/443 已被占用的 VPS（推荐） | `HTTPS_DOMAIN` + `HTTPS_PORT` + 证书路径 |
| **C：HTTPS（自动 ACME）** | 80 端口空闲，想自动签发证书 | 脚本未内置，需自行扩展 `Caddyfile` |

### 模式 B 完整步骤（命令可直接复制）

```bash
# 1. SSH 到 VPS
ssh user@vps.example.com

# 2. 探测环境
docker --version && docker compose version
for p in 8088 8443 8444; do ss -tln | grep -q ":$p " && echo "$p BUSY" || echo "$p FREE"; done
sudo find /etc/letsencrypt /opt -name '*.pem' 2>/dev/null | grep -E 'live|cert'
```

找一个空闲端口（如 `8088`）和一个空闲 HTTPS 端口（如 `8444`），并确认证书文件路径。

```bash
# 3. 拉取脚本
curl -fsSL https://raw.githubusercontent.com/KaminDeng/sub2api-helper/main/scripts/deploy-online.sh -o deploy.sh

# 4. 编辑关键变量（替换为你的实际值）
sed -i 's|^SERVER_PORT=.*|SERVER_PORT=8088|' deploy.sh
sed -i 's|^HTTPS_DOMAIN=.*|HTTPS_DOMAIN="api.example.com"|' deploy.sh
sed -i 's|^HTTPS_PORT=.*|HTTPS_PORT=8444|' deploy.sh
sed -i 's|^HTTPS_CERT_FULLCHAIN=.*|HTTPS_CERT_FULLCHAIN="/etc/letsencrypt/live/example.com/fullchain.pem"|' deploy.sh
sed -i 's|^HTTPS_CERT_KEY=.*|HTTPS_CERT_KEY="/etc/letsencrypt/live/example.com/privkey.pem"|' deploy.sh

# 5. 执行部署
bash deploy.sh

# 6. 防火墙放行 HTTPS 端口（脚本结尾会提示）
sudo ufw allow 8444/tcp
```

```bash
# 7. 验证
curl -sI http://localhost:8088 | head -3
curl -sI https://api.example.com:8444 | head -3
```

### 从本地一键远程部署（Advanced）

```bash
scp scripts/deploy-online.sh user@vps:/tmp/deploy.sh
ssh user@vps 'sed -i "s|SERVER_PORT=8080|SERVER_PORT=8088|" /tmp/deploy.sh && bash /tmp/deploy.sh'
```

### 常见 VPS 坑

| 坑 | 解决 |
|------|------|
| 80/443 被宿主 nginx 占用 | 用 `HTTPS_PORT=8443+`，模式 B |
| docker 命令需要 sudo | 把用户加入 docker 组：`sudo usermod -aG docker $USER` 后重登 |
| 云控制台未开放端口 | 安全组 / 防火墙放行对应端口 |
| 证书路径权限不足 | 确认部署用户对证书目录有读权限 |

## 部署完成后

- 访问 `http://<服务器IP>:8080`
- 管理员邮箱：`admin@sub2api.local`
- 管理员密码：脚本输出显示，或在日志中查看 `docker compose logs | grep 'admin password'`
- **请立即修改默认密码**

## 更新已有部署

已有实例不要直接重跑 `deploy-online.sh`。部署脚本会重新生成 `.env` 中的数据库密码、JWT 密钥和 TOTP 加密密钥；对已有实例，推荐使用更新脚本：

```bash
cd sub2api-helper
bash scripts/update-online.sh
```

脚本默认会：

- 备份配置、`data/`、PostgreSQL 逻辑 dump、Redis `dump.rdb`
- 拉取 `weishaw/sub2api:latest`
- 只重建 `sub2api` 应用容器：`docker compose up -d --no-deps sub2api`
- 不重启 PostgreSQL、Redis、Caddy、host-relay
- 更新后轮询 `/health`，并打印容器状态和最近日志

常用选项：

```bash
# 只备份，不更新
bash scripts/update-online.sh --backup-only

# 先等 8444/8080/8443 上没有活跃连接，再更新
bash scripts/update-online.sh --wait-idle --max-active-connections 0

# 自定义连接统计端口
bash scripts/update-online.sh --wait-idle --active-ports 8444,8088

# 指定部署目录和健康检查地址
bash scripts/update-online.sh \
  --data-dir /home/user/sub2api \
  --health-url https://127.0.0.1:8444/health

# 演练，不实际改动
bash scripts/update-online.sh --dry-run
```

> 单实例 Docker 更新无法保证真正零中断。该脚本通过预备份、预拉镜像、只替换应用容器，把影响窗口压到应用容器重建和启动的几秒级。

## 本机维护 VPS 备份

如果你希望在本机长期保存 VPS 备份，或换 VPS 时从本机把历史备份推送到新机器，可以使用同步脚本：

```bash
# 查看 VPS 上已有备份
bash scripts/sync-vps-backups.sh list \
  --host your-vps-ip \
  --user user \
  --port 22

# 在 VPS 上生成最新备份，并拉取到本机 ./sub2api-backups
bash scripts/sync-vps-backups.sh pull \
  --host your-vps-ip \
  --user user \
  --port 22

# 只拉取已有备份，不在 VPS 上生成新备份
bash scripts/sync-vps-backups.sh pull \
  --host your-vps-ip \
  --user user \
  --port 22 \
  --no-create

# 把本机 ./sub2api-backups 里的备份推送到新 VPS 的 ~/sub2api-restore
bash scripts/sync-vps-backups.sh push \
  --host new-vps.example.com \
  --user user \
  --port 22
```

常用参数：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--local-dir` | `./sub2api-backups` | 本机备份目录 |
| `--remote-backup-dir` | `~/sub2api-backups` | VPS 上保存备份的目录 |
| `--remote-restore-dir` | `~/sub2api-restore` | `push` 时上传到 VPS 的恢复目录 |
| `--remote-helper-dir` | `~/sub2api-helper` | VPS 上 helper 仓库目录，`pull` 默认会在这里执行备份脚本 |
| `--remote-data-dir` | `~/sub2api` | VPS 上已有部署目录 |
| `--dry-run` | 关闭 | 只打印将执行的 SSH / 传输命令 |

说明：
- `pull` 默认会先通过 SSH 在 VPS 上执行 `update-online.sh --backup-only`，再把 `sub2api-*` 备份文件拉到本机。
- `push` 只上传备份文件到新 VPS 的恢复目录，不会自动导入数据库，也不会覆盖线上服务。
- 优先使用 `rsync`；如果本机没有 `rsync`，脚本会回退到 `scp`。

推荐维护节奏：
- 日常维护：定期在本机执行 `pull`，让本机保留一份最新可恢复备份。
- 换 VPS 前：先对旧 VPS 执行一次 `pull`，确认本机备份文件存在。
- 新 VPS 准备好后：执行 `push` 把本机备份上传到新 VPS，再按下方恢复流程导入数据。

## 更换 VPS / 恢复历史数据

迁移到新 VPS 时，推荐先在旧 VPS 生成标准备份，再把备份文件传到新 VPS 恢复。**不要只复制 `data/` 目录**；`.env`、PostgreSQL 数据和证书挂载路径同样关键。

### 旧 VPS：生成备份

```bash
cd sub2api-helper
bash scripts/update-online.sh --backup-only --data-dir ~/sub2api
ls -lh ~/sub2api-backups
```

需要带走的文件通常包括：

| 文件 | 作用 |
|------|------|
| `sub2api-config-data-*.tar.gz` | `docker-compose.yml`、`.env`、`Caddyfile`、`data/` |
| `sub2api-postgres-*.sql.gz` | PostgreSQL 逻辑备份，包含账号、渠道、Key、用量等核心数据 |
| `sub2api-redis-*.rdb` | Redis 快照，建议一并迁移 |
| HTTPS 证书目录 | 如果 `docker-compose.override.yml` 挂载了宿主机证书路径，例如 `/opt/dpconn/certs` |

从本机推送到新 VPS 示例（先确保本机 `./sub2api-backups` 里已有旧 VPS 备份）：

```bash
bash scripts/sync-vps-backups.sh push \
  --host new-vps.example.com \
  --user user \
  --port 22
```

### 新 VPS：恢复并启动

先安装 Docker / Compose，或先运行一次 `deploy-online.sh` 让脚本安装依赖。若运行过空部署，请先停止并挪走空数据目录，避免和历史数据混用。

```bash
mkdir -p ~/sub2api ~/sub2api-restore
cd ~/sub2api

# 1. 恢复配置和 data/
tar -xzf ~/sub2api-restore/sub2api-config-data-YYYYMMDD-HHMMSS.tar.gz

# 2. 启动数据库和 Redis
docker compose up -d postgres redis

# 3. 等 PostgreSQL 就绪
until docker exec sub2api-postgres pg_isready -U sub2api -d sub2api; do sleep 2; done

# 4. 恢复 PostgreSQL
gunzip -c ~/sub2api-restore/sub2api-postgres-YYYYMMDD-HHMMSS.sql.gz \
  | docker exec -i sub2api-postgres psql -U sub2api -d sub2api

# 5. 恢复 Redis（可选但推荐）
docker compose stop redis
docker cp ~/sub2api-restore/sub2api-redis-YYYYMMDD-HHMMSS.rdb sub2api-redis:/data/dump.rdb
docker compose up -d redis

# 6. 启动全部服务
docker compose up -d

# 7. 验证
curl -ksS https://127.0.0.1:8444/health || curl -sS http://127.0.0.1:8080/health
```

如果 `.env` 中的 `POSTGRES_USER` / `POSTGRES_DB` 不是默认值，请把上面 `pg_isready`、`psql` 命令里的 `sub2api` 改成你的实际值。域名迁移后还要检查 DNS、安全组、防火墙端口，以及 HTTPS 证书路径是否和 `docker-compose.override.yml` 中的挂载一致。

## 配置说明

编辑脚本顶部的参数区域即可自定义：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `DATA_DIR` | `$HOME/sub2api` | 数据持久化目录 |
| `SERVER_PORT` | `8080` | Web 访问端口 |
| `ADMIN_EMAIL` | `admin@sub2api.local` | 管理员邮箱 |
| `ADMIN_PASSWORD` | 留空 | 管理员密码（留空则自动生成） |
| `TZ` | `Asia/Shanghai` | 时区 |

> 进阶：如需让 sub2api 容器访问宿主机 `127.0.0.1:<port>` 服务（含仅绑回环的本地 API、SSH 反向隧道落地端口等），见下方「让 sub2api 容器访问宿主机回环端口」章节。

## HTTPS（可选）

如需 HTTPS 访问，在脚本顶部设置以下 4 个变量即可启用 Caddy 反向代理（**需自行准备证书，不支持自动 ACME**）：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `HTTPS_DOMAIN` | 留空 | 留空=纯 HTTP；填写你的域名则启用 HTTPS |
| `HTTPS_PORT` | `8443` | HTTPS 监听端口 |
| `HTTPS_CERT_FULLCHAIN` | 留空 | 证书 fullchain.pem 的宿主机绝对路径 |
| `HTTPS_CERT_KEY` | 留空 | 证书 privkey.pem 的宿主机绝对路径 |
| `HTTPS_ONLY` | `true` | 启用 HTTPS 时关闭明文 HTTP 端口；设 `false` 同时保留 HTTP |

**示例**（使用 Let's Encrypt 已有证书）：

```bash
HTTPS_DOMAIN="api.example.com"
HTTPS_PORT=8443
HTTPS_CERT_FULLCHAIN="/etc/letsencrypt/live/example.com/fullchain.pem"
HTTPS_CERT_KEY="/etc/letsencrypt/live/example.com/privkey.pem"
```

说明：
- 不会自动申请证书，需要你已有证书（certbot/acme.sh 任意方式均可）
- 证书续期由你原有机制处理；Caddy 监视证书文件，更新后自动 reload，无需重启
- 适合 80/443 已被其他服务占用的 VPS
- 若 80/443 空闲且想自动 ACME，请直接用 caddy 官方文档自行扩展

## 让 sub2api 容器访问宿主机回环端口（可选）

适用场景：sub2api 上游 API 是宿主机上的 `http://127.0.0.1:<port>` 服务（例如某个本地代理、SSH 反向隧道落地端口、其他 Docker 项目映射到宿主机的端口），但宿主机这些服务**只绑定 127.0.0.1**，不能改成 `0.0.0.0`。

容器内的 `127.0.0.1` 指向容器自身，无法直接访问宿主机回环；又因 Docker 桥默认隔离，host-gateway 的标准做法对“仅绑回环”的服务无效。本脚本提供一个开箱即用的中继方案：

- **socat sidecar**：以 `network_mode: host` 启动一个 `alpine/socat` 容器，把宿主机 `127.0.0.1:<port>` 中继到 docker 桥网关 `<NETWORK_GATEWAY>:<port>`
- **`host.docker.internal` 别名**：把该域名指向同一个网关 IP，sub2api 内代码用 `http://host.docker.internal:<port>` 即可
- **固定子网 + 网关**：override 内固定 `sub2api-network` 的 subnet/gateway，确保 socat 绑定 IP 与 UFW 规则在容器/网络重建后仍然稳定
- **自动 UFW 放行**：部署末尾会检测 UFW 状态，若启用则自动加一条 `from <NETWORK_SUBNET> to <NETWORK_GATEWAY> port <port> proto tcp` 的放行规则

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `HOST_GATEWAY_ALIAS` | `true` | 在 sub2api 容器内注入 `host.docker.internal` 别名 |
| `HOST_LOOPBACK_RELAY_PORTS` | `()` | 留空=禁用；填入数组（例 `(3000)`）则为每个端口启动一个 socat sidecar |
| `NETWORK_SUBNET` | `172.28.0.0/16` | sub2api-network 固定子网 |
| `NETWORK_GATEWAY` | `172.28.0.1` | sub2api-network 固定网关；`host.docker.internal` 与 socat 都指向此 IP |
| `ADD_UFW_RULES` | `true` | 部署末尾自动配 UFW；UFW 未启用时打印手动命令 |

**示例**：让 sub2api 访问宿主机 `127.0.0.1:3000` 上的 New-API：

```bash
# 编辑 deploy-online.sh 顶部
HOST_LOOPBACK_RELAY_PORTS=(3000)
# 其它默认即可
```

部署完成后，sub2api 内只需把 API 上游配置成 `http://host.docker.internal:3000` 就能透传到宿主机回环。

### 在 sub2api 渠道里配置上游池子（重要）

完成上面网络层中继后，**还需要去 sub2api 管理后台改渠道（Channel）的 Base URL**——否则会报 `dial tcp 127.0.0.1:<port>: connect: connection refused`，因为容器内的 `127.0.0.1` 永远是容器自己。

打通同一 VPS 内的多个池子（New-API、One-API、其它中转池）的标准做法：

| 上游池子在宿主机的位置 | 渠道里应填的 Base URL |
|------------------------|------------------------|
| `http://127.0.0.1:3000` | `http://host.docker.internal:3000` |
| `http://127.0.0.1:8080` | `http://host.docker.internal:8080` |
| 通过 nginx/caddy 反代后的 `https://api.example.com` | 直接填该公网域名即可，不用走中继 |

**操作步骤**：

1. 登录 sub2api 后台 → 渠道列表 → 编辑目标渠道
2. 把代理 / Base URL 字段中的 `127.0.0.1`（或 `localhost`）替换为 `host.docker.internal`，端口不变
3. 保存后用「测试」按钮自检

**批量改（直接走数据库）**：

```bash
# 1. 先看一眼有多少行命中（确认表名/字段名）
docker exec sub2api-postgres psql -U sub2api -d sub2api \
  -c "SELECT id,name,type,base_url FROM channels
      WHERE base_url LIKE '%127.0.0.1%' OR base_url LIKE '%localhost%';"

# 2. 批量替换（先备份）
docker exec sub2api-postgres pg_dump -U sub2api -d sub2api -t channels > channels-backup.sql
docker exec sub2api-postgres psql -U sub2api -d sub2api \
  -c "UPDATE channels
      SET base_url = REPLACE(REPLACE(base_url,'127.0.0.1','host.docker.internal'),'localhost','host.docker.internal')
      WHERE base_url LIKE '%127.0.0.1%' OR base_url LIKE '%localhost%';"
```

> 字段名因 sub2api 版本可能不同（`base_url` / `proxy_url` / `endpoint`），先 SELECT 确认再 UPDATE。

**新增一个池子时的 checklist**：

1. 池子在宿主机上监听了哪个端口？记为 `<P>`
2. `<P>` 是否已加入 `HOST_LOOPBACK_RELAY_PORTS`？没有则加上、重跑 `deploy-online.sh` 或手动追加 socat sidecar + UFW 规则
3. 在容器里测一次：`docker exec sub2api wget -qSO- http://host.docker.internal:<P>/ | head -3`，必须能通
4. 在 sub2api 后台加渠道，Base URL 写 `http://host.docker.internal:<P>`

**安全说明**：
- socat 仅绑定到自定义 docker 桥网关（不是 `0.0.0.0`、不是 `docker0`），不会暴露到 VPS 公网
- UFW 规则限定 `from <NETWORK_SUBNET>`，只放行 sub2api-network 内的容器
- 若你的项目对宿主机 `127.0.0.1:<port>` 有更严格的“仅本机访问”策略（例如反向 SSH 隧道项目），等同于授权了 sub2api 容器访问该端口，请评估后再启用

## 架构支持

Docker Compose 自动适配 AMD64 / ARM64 架构，脚本无需做架构判断。

## 详细教程

完整的部署教程和常见问题排查请参考 [部署指南](docs/blog/blog-cn.md)。

## 相关链接

- [Sub2API 上游仓库](https://github.com/Wei-Shaw/sub2api)
- [New-API Helper](https://github.com/KaminDeng/new-api-helper)（同系列的 New-API 部署工具）
