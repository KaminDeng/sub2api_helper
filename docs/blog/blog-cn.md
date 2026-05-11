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

# 更新到最新版
docker compose pull && docker compose up -d

# 备份数据
tar -czf sub2api-backup-$(date +%Y%m%d).tar.gz ~/sub2api/data
```

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