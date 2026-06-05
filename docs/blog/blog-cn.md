# Sub2API Docker 一键部署：3 分钟搭建你的私有 AI API 网关

> **GitHub 仓库**：[KaminDeng/sub2api-helper](https://github.com/KaminDeng/sub2api-helper)
>
> 一行命令，从零到运行。支持 AMD64 / ARM64，自动处理 Docker 安装、密钥生成、HTTPS 配置。

---

## 一、你也许遇到过这些痛点

手里攒了好几个 AI API 的 Key —— Claude 的、OpenAI 的、Gemini 的，有些是自己注册的，有些是合租的，还有中转站的。每次用不同工具还要切换 Key，团队协作时要手动分发，速率限制不好管控，用量的可视化更是无从谈起。

**Sub2API** 就是一个解决这些问题的开源 AI API 网关平台，它能：

- 统一管理多个 AI 账号和 API Key
- 按用户/渠道做速率限制和额度分配
- 提供 OpenAI 兼容接口，无缝对接现有工具
- 自带管理后台，用量一目了然

但它的官方部署文档对新手来说还是有点门槛。**sub2api-helper** 就是为此而生 —— 一个开箱即用的 Docker 一键部署辅助脚本。

| 痛点 | 解法 |
|------|------|
| 多 Key 管理混乱 | 统一网关，一个接口调所有模型 |
| Docker 不会装 | 脚本自动检测并安装 |
| 证书配置繁琐 | 内置 Caddy 反代，挂载即用 |
| 容器访问宿主机回环端口 | socat sidecar 中继方案，开箱即用 |
| 部署完不知道怎么排查 | 脚本自带日志、端口检测、防火墙配置 |

---

## 二、一行命令开始

```bash
git clone https://github.com/KaminDeng/sub2api-helper.git
cd sub2api-helper
bash scripts/deploy-online.sh
```

脚本会自动完成以下所有步骤：

```
[0/5] 系统环境检测      → 架构识别、Docker/Compose 检测、端口冲突检查
[1/5] 安装依赖          → 自动安装 Docker（apt/yum/dnf/官方脚本）
[2/5] 创建数据目录      → 持久化目录结构
[3/5] 下载部署文件      → 从上游仓库拉取 compose 配置和 .env 模板
[4/5] 生成环境配置      → openssl 随机密钥、自动注入 .env
[5/5] 容器部署          → docker compose up -d + 健康检查
```

**3-5 分钟**就能从零走到一个跑起来的 Sub2API 实例。

---

## 三、三种部署模式，覆盖你的各种场景

| 模式 | 适用场景 | 配置量 |
|------|----------|--------|
| **A：纯 HTTP** | 内网 / 测试环境 | 零配置，直接跑 |
| **B：HTTPS（已有证书）** | 80/443 被占用的生产 VPS | 填 4 个变量 |
| **C：HTTPS（自动 ACME）** | 80 端口空闲，想自动签发 | 自行扩展 Caddyfile |

### 模式 B 实操（最常用）

```bash
# 1. SSH 到 VPS
ssh user@vps.example.com

# 2. 探测环境
docker --version && docker compose version
for p in 8088 8443 8444; do ss -tln | grep -q ":$p " && echo "$p BUSY" || echo "$p FREE"; done

# 3. 拉取脚本
curl -fsSL https://raw.githubusercontent.com/KaminDeng/sub2api-helper/main/scripts/deploy-online.sh -o deploy.sh

# 4. 修改关键变量
sed -i 's|^SERVER_PORT=.*|SERVER_PORT=8088|' deploy.sh
sed -i 's|^HTTPS_DOMAIN=.*|HTTPS_DOMAIN="api.example.com"|' deploy.sh
sed -i 's|^HTTPS_PORT=.*|HTTPS_PORT=8444|' deploy.sh
sed -i 's|^HTTPS_CERT_FULLCHAIN=.*|HTTPS_CERT_FULLCHAIN="/etc/letsencrypt/live/example.com/fullchain.pem"|' deploy.sh
sed -i 's|^HTTPS_CERT_KEY=.*|HTTPS_CERT_KEY="/etc/letsencrypt/live/example.com/privkey.pem"|' deploy.sh

# 5. 执行
bash deploy.sh
```

---

## 四、高级功能：让容器访问宿主机的回环端口

这是一个非常实用的场景：你的宿主机上跑着 New-API 或者某个 SSH 反向隧道，它们只绑定了 `127.0.0.1`，而 Docker 容器内的 `127.0.0.1` 指向的是容器自己，没法直接访问宿主机。

sub2api-helper 内置了一套 **socat sidecar 中继方案**：

```bash
# 编辑 deploy-online.sh，只需加一行
HOST_LOOPBACK_RELAY_PORTS=(3000)
```

部署完成后，在 Sub2API 后台把渠道 Base URL 写成 `http://host.docker.internal:3000` 就能透传访问宿主机回环端口。脚本还会自动配置 UFW 防火墙规则，确保安全。

| 上游池子在宿主机的位置 | 渠道里应填的 Base URL |
|------------------------|------------------------|
| `http://127.0.0.1:3000` | `http://host.docker.internal:3000` |
| `http://127.0.0.1:8080` | `http://host.docker.internal:8080` |

---

## 五、可配置参数一览

脚本顶部提供了完整的可配置参数，按需修改即可：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `DATA_DIR` | `$HOME/sub2api` | 数据持久化目录 |
| `SERVER_PORT` | `8080` | Web 访问端口 |
| `ADMIN_EMAIL` | `admin@sub2api.local` | 管理员邮箱 |
| `ADMIN_PASSWORD` | 留空 | 留空则首次启动自动生成 |
| `TZ` | `Asia/Shanghai` | 时区 |
| `HTTPS_DOMAIN` | 留空 | 填写域名则启用 HTTPS + Caddy |
| `HTTPS_PORT` | `8443` | HTTPS 监听端口 |
| `NETWORK_SUBNET` | `172.28.0.0/16` | Docker 网桥子网 |
| `HOST_LOOPBACK_RELAY_PORTS` | `()` | 需要中继的宿主机回环端口 |

---

## 六、常见 VPS 坑与解决

| 坑 | 原因 | 解决 |
|------|------|------|
| 80/443 被 nginx 占用 | 宿主已有 Web 服务 | 用模式 B，`HTTPS_PORT=8443+` |
| docker 命令要 sudo | 用户不在 docker 组 | `sudo usermod -aG docker $USER` 后重登 |
| 云控制台安全组没放行 | 云厂商额外防火墙层 | 阿里云/腾讯云/Vultr 安全组放行对应端口 |
| 证书路径权限不足 | 部署用户无读权限 | 确认证书目录权限或使用 sudo |
| GitHub 下载失败 | 国内网络问题 | 手动下载或使用代理 |

---

## 七、部署完成后的第一步

部署成功后，脚本会打印访问地址和管理员密码：

```
=========================================
  Sub2API 部署完成！

  访问地址：http://192.168.1.100:8080
  默认邮箱：admin@sub2api.local
  管理员密码：AbCd1234XyZ... (从日志获取)

  请立即登录并修改默认密码！
=========================================
```

**切记立即修改默认密码。** 然后就可以在后台添加渠道、配置模型映射、生成 API Key 了。

---

## 八、常用运维命令

```bash
cd ~/sub2api

# 查看实时日志
docker compose logs -f

# 重启服务
docker compose restart

# 停止服务
docker compose down

# 更新到最新版（推荐用 helper 脚本，先备份再只重建应用容器）
bash scripts/update-online.sh

# 备份数据
tar -czf sub2api-backup-$(date +%Y%m%d).tar.gz ~/sub2api/data
```

### 更稳的更新方式：先备份，再只替换应用容器

已有部署不要直接重跑 `deploy-online.sh`。一键部署脚本面向首次部署，会重新生成 `.env` 中的 `POSTGRES_PASSWORD`、`JWT_SECRET`、`TOTP_ENCRYPTION_KEY` 等密钥；已有实例更新应使用专门的更新脚本：

```bash
cd sub2api-helper
bash scripts/update-online.sh
```

它会按顺序执行：

1. 备份配置文件和 `data/` 目录
2. 用 `pg_dump` 备份 PostgreSQL
3. 触发 Redis `SAVE` 并复制 `dump.rdb`
4. `docker compose pull sub2api`
5. `docker compose up -d --no-deps sub2api`
6. 轮询 `/health`，打印容器状态和最近日志

因为只重建 `sub2api` 应用容器，所以 PostgreSQL、Redis、Caddy 和 host-relay 不会被重启。单实例 Docker 仍然会有几秒级影响窗口；如果你想尽量避开正在进行的请求，可以先等连接空闲：

```bash
bash scripts/update-online.sh --wait-idle --max-active-connections 0
```

如果你的公网入口不是默认示例端口，可以指定连接统计端口：

```bash
bash scripts/update-online.sh --wait-idle --active-ports 8444,8088
```

常用模式：

```bash
# 只备份，不更新
bash scripts/update-online.sh --backup-only

# 指定部署目录
bash scripts/update-online.sh --data-dir /home/user/sub2api

# 指定健康检查地址
bash scripts/update-online.sh --health-url https://127.0.0.1:8444/health

# 演练，不实际改动
bash scripts/update-online.sh --dry-run
```

### 在本机拉取和推送 VPS 备份

如果你想把 VPS 备份长期保存在本机，或者换 VPS 时先把旧机器备份拉到本机、再推送到新机器，可以使用本机同步脚本：

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

# 把本机备份推送到新 VPS 的 ~/sub2api-restore
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
| `--remote-restore-dir` | `~/sub2api-restore` | `push` 上传到 VPS 的恢复目录 |
| `--remote-helper-dir` | `~/sub2api-helper` | VPS 上 helper 仓库目录 |
| `--remote-data-dir` | `~/sub2api` | VPS 上已有部署目录 |
| `--dry-run` | 关闭 | 只打印 SSH / 传输命令 |

`pull` 默认会先通过 SSH 在 VPS 上执行 `update-online.sh --backup-only`，然后把 `sub2api-*` 文件拉到本机；`push` 只负责上传备份文件，不会自动导入数据库，也不会覆盖线上服务。

推荐维护节奏：

- 日常维护：定期在本机执行 `pull`，保留一份最新可恢复备份
- 换 VPS 前：先对旧 VPS 执行一次 `pull`，确认本机备份文件存在
- 新 VPS 准备好后：执行 `push` 把本机备份上传到新 VPS，再按下面的恢复流程导入数据

### 更换 VPS：自动加载旧机器历史数据

换 VPS 时不要只复制 `~/sub2api/data`，也不要在新机器上跑完空部署后只覆盖部分目录。Sub2API 的核心数据主要在 PostgreSQL，登录状态和 2FA 还依赖 `.env` 中的固定密钥，所以迁移应按“旧机备份 → 新机恢复 → 启动验证”的顺序走。

#### 旧 VPS：生成标准备份

```bash
cd sub2api-helper
bash scripts/update-online.sh --backup-only --data-dir ~/sub2api
ls -lh ~/sub2api-backups
```

你会得到几类文件：

| 文件 | 说明 |
|------|------|
| `sub2api-config-data-*.tar.gz` | 配置、`.env`、`Caddyfile`、`data/` |
| `sub2api-postgres-*.sql.gz` | PostgreSQL 逻辑备份，最关键 |
| `sub2api-redis-*.rdb` | Redis 快照 |

如果启用了 HTTPS 且 `docker-compose.override.yml` 挂载了宿主机证书目录，例如 `/opt/dpconn/certs`，也要迁移该证书目录，或者在新 VPS 上重新签发证书并修改挂载路径。

把备份传到新 VPS：

```bash
bash scripts/sync-vps-backups.sh push \
  --host new-vps.example.com \
  --user user \
  --port 22
```

#### 新 VPS：恢复历史数据

新机器先准备 Docker / Compose。可以先运行一次 `deploy-online.sh` 安装依赖，但如果它已经创建了空数据，请先停服务并挪走空目录：

```bash
cd ~/sub2api 2>/dev/null || true
docker compose down 2>/dev/null || true
mv ~/sub2api ~/sub2api.empty.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
mkdir -p ~/sub2api
```

恢复：

```bash
cd ~/sub2api

# 1. 解出配置和 data/
tar -xzf ~/sub2api-restore/sub2api-config-data-YYYYMMDD-HHMMSS.tar.gz

# 2. 启动数据库和 Redis
docker compose up -d postgres redis

# 3. 等 PostgreSQL ready
until docker exec sub2api-postgres pg_isready -U sub2api -d sub2api; do sleep 2; done

# 4. 导入历史数据库
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

如果你的 `.env` 里改过 `POSTGRES_USER` 或 `POSTGRES_DB`，把上面命令中的 `sub2api` 替换为实际值。迁移完成后，还要检查：

- DNS 是否已指向新 VPS
- 云厂商安全组 / UFW 是否放行了实际访问端口
- `docker-compose.override.yml` 中的证书挂载路径在新 VPS 上是否存在
- 如果使用宿主机回环中继，相关上游服务是否也迁移或仍然可访问

---

## 九、总结

**sub2api-helper** 把 Sub2API 的部署门槛降到了最低。无论你是想在 VPS 上搭建生产环境，还是本地测试，它都能帮你省下大量折腾 Docker 和配置的时间。

- 零依赖（脚本自动装 Docker）
- 多架构（AMD64 / ARM64 自适应）
- 安全的随机密钥生成
- 内置 HTTPS 反向代理
- 宿主回环端口中继方案

如果你也在管理多个 AI API Key，不妨试试 Sub2API + sub2api-helper 的组合。

---

> **GitHub 仓库**：[https://github.com/KaminDeng/sub2api-helper](https://github.com/KaminDeng/sub2api-helper)
>
> 如果这个项目帮到了你，欢迎 Star ⭐ 支持一下。
>
> 上游项目：[Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api)

---

<!--
SEO 标签建议：
CSDN 标签：Docker, Sub2API, AI API 网关, 一键部署, API 管理, Claude API, OpenAI API, 运维自动化
推荐分类：云计算 / DevOps
-->
