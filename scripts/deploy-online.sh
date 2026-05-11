#!/bin/bash
set -euo pipefail

# ============================================
# Sub2API 在线部署脚本
# 仓库：https://github.com/KaminDeng/sub2api-helper
# 使用方法：bash scripts/deploy-online.sh
# ============================================

# ---------- 可配置参数 ----------
DATA_DIR="$HOME/sub2api"
SERVER_PORT=8080
ADMIN_EMAIL="admin@sub2api.local"
ADMIN_PASSWORD=""
TZ="Asia/Shanghai"
HTTPS_DOMAIN=""
HTTPS_PORT=8443
HTTPS_CERT_FULLCHAIN=""
HTTPS_CERT_KEY=""
HTTPS_ONLY=true            # 启用 HTTPS 时关闭明文 HTTP 端口；设 false 同时保留 SERVER_PORT
HOST_GATEWAY_ALIAS=true    # 为 sub2api 注入 host.docker.internal 别名（指向下面的 NETWORK_GATEWAY）
HOST_LOOPBACK_RELAY_PORTS=()  # 例如 (3000 8080)：为每个端口启动 socat sidecar，把宿主机 127.0.0.1:<port> 中继到 docker 桥网关，sub2api 通过 host.docker.internal:<port> 访问
NETWORK_SUBNET="172.28.0.0/16"  # 固定 sub2api-network 子网，确保 socat 绑定 IP 与防火墙规则稳定
NETWORK_GATEWAY="172.28.0.1"
ADD_UFW_RULES=true         # 部署后自动给中继端口加 UFW 放行规则（仅当 ufw 已启用）
# --------------------------------

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

GITHUB_RAW="https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy"
COMPOSE_URL="$GITHUB_RAW/docker-compose.local.yml"
ENV_EXAMPLE_URL="$GITHUB_RAW/.env.example"
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
ENV_FILE="$DATA_DIR/.env"
DOWNLOAD_RETRY=3

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
generate_secret() { openssl rand -hex 32; }

# ---------- [0/5] 系统检测 ----------

echo ""
echo "========================================="
echo "  Sub2API 在线部署脚本"
echo "  https://github.com/KaminDeng/sub2api-helper"
echo "========================================="
echo ""

print_info "[0/5] 系统环境检测"

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    echo "  架构：ARM64"
else
    echo "  架构：AMD64"
fi

detect_compose_cmd() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# 检查 Docker
if ! command -v docker &>/dev/null; then
    print_warn "Docker 未安装，将自动安装..."
    NEED_INSTALL_DOCKER=true
else
    echo "  Docker：$(docker --version 2>/dev/null || echo '已安装')"
    NEED_INSTALL_DOCKER=false
fi

# 检查 Docker Compose
COMPOSE_CMD=$(detect_compose_cmd)
if [ -z "$COMPOSE_CMD" ]; then
    print_warn "Docker Compose 未安装"
    NEED_INSTALL_COMPOSE=true
else
    echo "  Compose：$COMPOSE_CMD"
    NEED_INSTALL_COMPOSE=false
fi

# 检查 openssl
if ! command -v openssl &>/dev/null; then
    print_error "openssl 未安装，此工具用于生成安全随机密钥"
    echo "  安装方法："
    echo "    Debian/Ubuntu: sudo apt-get install -y openssl"
    echo "    RHEL/CentOS:   sudo yum install -y openssl"
    exit 1
fi
echo "  openssl：$(openssl version 2>/dev/null || echo '已安装')"

# 检查 HTTPS 证书
if [ -n "$HTTPS_DOMAIN" ]; then
    if [ -z "$HTTPS_CERT_FULLCHAIN" ] || [ -z "$HTTPS_CERT_KEY" ]; then
        print_error "已启用 HTTPS（HTTPS_DOMAIN=$HTTPS_DOMAIN），但未设置证书路径"
        echo "  请设置 HTTPS_CERT_FULLCHAIN 和 HTTPS_CERT_KEY 后重试"
        exit 1
    fi
    if [ ! -r "$HTTPS_CERT_FULLCHAIN" ]; then
        print_error "证书文件不存在或不可读：$HTTPS_CERT_FULLCHAIN"
        exit 1
    fi
    if [ ! -r "$HTTPS_CERT_KEY" ]; then
        print_error "证书密钥文件不存在或不可读：$HTTPS_CERT_KEY"
        exit 1
    fi
    echo "  HTTPS 证书检查通过"
fi

# 检查端口占用
check_port() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":$port " && return 0 || return 1
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":$port " && return 0 || return 1
    else
        return 1
    fi
}

PORTS_TO_CHECK=()
PORT_NAMES=()
PORT_CONFLICTS=()

if [ -n "$HTTPS_DOMAIN" ] && [ "$HTTPS_ONLY" = "true" ]; then
    : # HTTPS-only 模式：sub2api 不暴露到宿主机，跳过 SERVER_PORT 检查
else
    PORTS_TO_CHECK+=($SERVER_PORT)
    PORT_NAMES+=("Sub2API Web ($SERVER_PORT)")
fi

if [ -n "$HTTPS_DOMAIN" ]; then
    PORTS_TO_CHECK+=($HTTPS_PORT)
    PORT_NAMES+=("HTTPS (Caddy) ($HTTPS_PORT)")
fi

for i in "${!PORTS_TO_CHECK[@]}"; do
    port=${PORTS_TO_CHECK[$i]}
    name=${PORT_NAMES[$i]}
    if check_port "$port"; then
        PORT_CONFLICTS+=("$name")
    fi
done

if [ ${#PORT_CONFLICTS[@]} -gt 0 ]; then
    print_error "以下端口被占用："
    for conflict in "${PORT_CONFLICTS[@]}"; do
        echo "  - $conflict"
    done
    echo ""
    echo "  请修改脚本顶部的 SERVER_PORT 变量，或停止占用端口的服务后重试。"
    echo ""
    exit 1
fi
echo "  端口检查：通过"

# 检查 Docker 组权限，决定是否需要 sudo
DOCKER_PREFIX=""
if ! docker ps &>/dev/null 2>&1; then
    if [ "$(id -u)" = "0" ]; then
        : # running as root, fine
    else
        print_warn "当前用户无法直接操作 Docker，将使用 sudo"
        DOCKER_PREFIX="sudo"
    fi
fi

echo "  所有检测通过"
echo ""

# ---------- [1/5] 安装依赖 ----------

print_info "[1/5] 安装依赖"

install_docker() {
    if [ "$NEED_INSTALL_DOCKER" = false ] && [ "$NEED_INSTALL_COMPOSE" = false ]; then
        echo "  Docker 和 Compose 均已安装，跳过"
        return
    fi

    if command -v apt-get &>/dev/null; then
        echo "  检测到 Debian/Ubuntu，使用 apt 安装..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq docker.io docker-compose-v2 2>/dev/null || \
        sudo apt-get install -y -qq docker.io docker-compose 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        echo "  检测到 RHEL/CentOS，使用 yum 安装..."
        sudo yum install -y docker docker-compose 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        echo "  检测到 Fedora，使用 dnf 安装..."
        sudo dnf install -y docker docker-compose 2>/dev/null || true
    else
        echo "  使用 Docker 官方安装脚本..."
        curl -fsSL https://get.docker.com | sudo bash
    fi

    sudo systemctl start docker 2>/dev/null || true
    sudo systemctl enable docker 2>/dev/null || true

    if ! getent group docker | grep -q "$USER"; then
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        print_warn "已将当前用户加入 docker 组，可能需要重新登录或执行 'newgrp docker'"
    fi
}

install_docker

# 重新检测 Compose
COMPOSE_CMD=$(detect_compose_cmd)
if [ -z "$COMPOSE_CMD" ]; then
    print_error "Docker Compose 安装失败，请手动安装后重试"
    echo "  参考：https://docs.docker.com/compose/install/"
    exit 1
fi
echo "  Compose 命令：$COMPOSE_CMD"

# 安装 Docker 后重新探测权限（group membership 同会话内不生效）
if [ "$NEED_INSTALL_DOCKER" = true ] || [ "$NEED_INSTALL_COMPOSE" = true ]; then
    if ! docker ps &>/dev/null 2>&1; then
        if [ "$(id -u)" != "0" ]; then
            DOCKER_PREFIX="sudo"
            print_warn "docker 组成员关系需要重新登录才生效，本次运行将使用 sudo"
        fi
    fi
fi

# ---------- [2/5] 创建数据目录 ----------

print_info "[2/5] 创建数据目录"
mkdir -p "$DATA_DIR"/{data,postgres_data,redis_data}
echo "  数据目录：$DATA_DIR"
echo "  ├── data/"
echo "  ├── postgres_data/"
echo "  └── redis_data/"

# ---------- [3/5] 下载部署文件 ----------

print_info "[3/5] 下载部署文件"

download_file() {
    local url=$1
    local dest=$2
    local retry=0

    while [ $retry -lt $DOWNLOAD_RETRY ]; do
        if command -v wget &>/dev/null; then
            if wget -q --timeout=30 -O "$dest" "$url" 2>/dev/null; then
                return 0
            fi
        elif command -v curl &>/dev/null; then
            if curl -fsSL --connect-timeout 30 -o "$dest" "$url" 2>/dev/null; then
                return 0
            fi
        else
            print_error "需要 curl 或 wget，请先安装"
            exit 1
        fi
        retry=$((retry + 1))
        if [ $retry -lt $DOWNLOAD_RETRY ]; then
            print_warn "下载失败，重试 ($retry/$DOWNLOAD_RETRY)..."
            sleep 2
        fi
    done
    return 1
}

echo "  下载 docker-compose.local.yml → $COMPOSE_FILE"
if ! download_file "$COMPOSE_URL" "$COMPOSE_FILE"; then
    print_error "下载 docker-compose.yml 失败，请检查网络连接"
    echo "  如果位于中国大陆，可能需要代理或手动下载："
    echo "  curl -o $COMPOSE_FILE $COMPOSE_URL"
    exit 1
fi

echo "  下载 .env.example → $ENV_FILE"
if ! download_file "$ENV_EXAMPLE_URL" "$ENV_FILE"; then
    print_error ".env.example 下载失败，请检查网络连接"
    exit 1
fi

# ---------- [4/5] 生成 .env ----------

print_info "[4/5] 生成环境配置"

JWT_SECRET=$(generate_secret)
TOTP_ENCRYPTION_KEY=$(generate_secret)
POSTGRES_PASSWORD=$(generate_secret)

is_gnu_sed() { sed --version >/dev/null 2>&1; }

# Replace secret placeholders with generated values
# Handle GNU sed vs BSD sed (macOS)
if is_gnu_sed; then
    sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" "$ENV_FILE"
    sed -i "s|^TOTP_ENCRYPTION_KEY=.*|TOTP_ENCRYPTION_KEY=$TOTP_ENCRYPTION_KEY|" "$ENV_FILE"
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" "$ENV_FILE"
    sed -i "s|^SERVER_PORT=.*|SERVER_PORT=$SERVER_PORT|" "$ENV_FILE"
    sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|" "$ENV_FILE"
    sed -i "s|^TZ=.*|TZ=$TZ|" "$ENV_FILE"
    if [ -n "$ADMIN_PASSWORD" ]; then
        sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$ADMIN_PASSWORD|" "$ENV_FILE"
    fi
else
    # macOS/BSD sed 分支（Linux 不会走到这里，GNU sed 已被 is_gnu_sed 捕获）
    sed -i '' "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" "$ENV_FILE"
    sed -i '' "s|^TOTP_ENCRYPTION_KEY=.*|TOTP_ENCRYPTION_KEY=$TOTP_ENCRYPTION_KEY|" "$ENV_FILE"
    sed -i '' "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" "$ENV_FILE"
    sed -i '' "s|^SERVER_PORT=.*|SERVER_PORT=$SERVER_PORT|" "$ENV_FILE"
    sed -i '' "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|" "$ENV_FILE"
    sed -i '' "s|^TZ=.*|TZ=$TZ|" "$ENV_FILE"
    if [ -n "$ADMIN_PASSWORD" ]; then
        sed -i '' "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$ADMIN_PASSWORD|" "$ENV_FILE"
    fi
fi

chmod 600 "$ENV_FILE"
echo "  .env 已生成：$ENV_FILE"
echo "  POSTGRES_PASSWORD=${POSTGRES_PASSWORD:0:16}..."
echo "  JWT_SECRET=${JWT_SECRET:0:16}..."
if [ -n "$ADMIN_PASSWORD" ]; then
    echo "  ADMIN_PASSWORD=*** (已自定义)"
else
    echo "  ADMIN_PASSWORD=未设置（首次启动自动生成）"
fi

# 构建 sub2api 服务级 override 片段（host-gateway / HTTPS-only 关闭明文端口）
SUB2API_OVERRIDE_LINES=""
if [ "$HOST_GATEWAY_ALIAS" = "true" ]; then
    SUB2API_OVERRIDE_LINES+=$'    extra_hosts:\n      - "host.docker.internal:'"$NETWORK_GATEWAY"$'"\n'
fi
if [ -n "$HTTPS_DOMAIN" ] && [ "$HTTPS_ONLY" = "true" ]; then
    SUB2API_OVERRIDE_LINES+=$'    ports: !reset []\n'
fi

if [ -n "$HTTPS_DOMAIN" ]; then
    cat > "$DATA_DIR/Caddyfile" <<CADDY_EOF
{
    admin off
    auto_https off
}

:8443 {
    tls /certs/fullchain.pem /certs/privkey.pem
    encode gzip
    reverse_proxy sub2api:8080
}
CADDY_EOF
    echo "  Caddyfile 已生成：$DATA_DIR/Caddyfile"
fi

if [ -n "$SUB2API_OVERRIDE_LINES" ] || [ -n "$HTTPS_DOMAIN" ] || [ ${#HOST_LOOPBACK_RELAY_PORTS[@]} -gt 0 ]; then
    {
        echo "services:"
        if [ -n "$SUB2API_OVERRIDE_LINES" ]; then
            echo "  sub2api:"
            printf '%s' "$SUB2API_OVERRIDE_LINES"
            echo ""
        fi
        if [ ${#HOST_LOOPBACK_RELAY_PORTS[@]} -gt 0 ]; then
            for relay_port in "${HOST_LOOPBACK_RELAY_PORTS[@]}"; do
                cat <<RELAY_EOF
  host-relay-${relay_port}:
    image: alpine/socat:latest
    container_name: sub2api-host-relay-${relay_port}
    network_mode: host
    restart: unless-stopped
    command: ["TCP-LISTEN:${relay_port},bind=${NETWORK_GATEWAY},fork,reuseaddr", "TCP:127.0.0.1:${relay_port}"]

RELAY_EOF
            done
        fi
        if [ -n "$HTTPS_DOMAIN" ]; then
            cat <<OVERRIDE_EOF
  caddy:
    image: caddy:2-alpine
    container_name: sub2api-caddy
    restart: unless-stopped
    ports:
      - "${HTTPS_PORT}:8443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ${HTTPS_CERT_FULLCHAIN}:/certs/fullchain.pem:ro
      - ${HTTPS_CERT_KEY}:/certs/privkey.pem:ro
      - ./caddy_data:/data
      - ./caddy_config:/config
    networks:
      - sub2api-network
    depends_on:
      - sub2api
OVERRIDE_EOF
        fi
        if [ ${#HOST_LOOPBACK_RELAY_PORTS[@]} -gt 0 ]; then
            cat <<NET_EOF

networks:
  sub2api-network:
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}
          gateway: ${NETWORK_GATEWAY}
NET_EOF
        fi
    } > "$DATA_DIR/docker-compose.override.yml"
    echo "  docker-compose.override.yml 已生成：$DATA_DIR/docker-compose.override.yml"
    if [ ${#HOST_LOOPBACK_RELAY_PORTS[@]} -gt 0 ]; then
        echo "  host-loopback 中继端口：${HOST_LOOPBACK_RELAY_PORTS[*]}（容器内通过 host.docker.internal:<port> 访问）"
    fi
fi

# ---------- [5/5] 容器部署 ----------

print_info "[5/5] 容器部署，启动服务..."

cd "$DATA_DIR"

$DOCKER_PREFIX $COMPOSE_CMD down --remove-orphans 2>/dev/null || true

if ! $DOCKER_PREFIX $COMPOSE_CMD up -d 2>&1; then
    print_error "容器启动失败，以下是最近日志："
    echo ""
    $DOCKER_PREFIX $COMPOSE_CMD logs --tail=50 2>/dev/null || true
    echo ""
    echo "常见排查方向："
    echo "  1. 端口冲突 - 检查 $SERVER_PORT 是否被占用"
    echo "  2. 磁盘空间 - df -h 检查可用空间"
    echo "  3. 权限问题 - 尝试 sudo $COMPOSE_CMD up -d"
    exit 1
fi

# 等待服务就绪
echo "  等待服务初始化..."
for i in {1..30}; do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$SERVER_PORT" 2>/dev/null | grep -q "200\|302\|401"; then
        echo "  服务就绪"
        break
    fi
    if [ $i -eq 30 ]; then
        print_warn "服务启动较慢，请稍后手动检查"
    fi
    sleep 2
done

# host-loopback 中继：自动放行 UFW
if [ ${#HOST_LOOPBACK_RELAY_PORTS[@]} -gt 0 ] && [ "$ADD_UFW_RULES" = "true" ]; then
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        for relay_port in "${HOST_LOOPBACK_RELAY_PORTS[@]}"; do
            rule_comment="sub2api host-loopback relay :$relay_port"
            if sudo ufw status | grep -q "$rule_comment"; then
                echo "  UFW 规则已存在：$rule_comment"
            else
                sudo ufw allow from "$NETWORK_SUBNET" to "$NETWORK_GATEWAY" port "$relay_port" proto tcp comment "$rule_comment" >/dev/null
                echo "  UFW 已放行：$NETWORK_SUBNET → $NETWORK_GATEWAY:$relay_port/tcp"
            fi
        done
    else
        print_warn "UFW 未启用或未安装；如有其他防火墙，请手动放行：from $NETWORK_SUBNET to $NETWORK_GATEWAY port {${HOST_LOOPBACK_RELAY_PORTS[*]}} proto tcp"
    fi
fi

# 如果 ADMIN_PASSWORD 未设置，尝试从日志提取
DETECTED_ADMIN_PW=""
if [ -z "$ADMIN_PASSWORD" ]; then
    sleep 3
    # 用更宽松的正则提取密码（取最后一段看起来像密码的 token）
    DETECTED_ADMIN_PW=$($DOCKER_PREFIX $COMPOSE_CMD logs 2>/dev/null | grep -i "admin password" | tail -1 | grep -oE "[A-Za-z0-9_=-]{12,}" | tail -1 || echo "")
fi

# 检测本机 IP
if command -v hostname &>/dev/null; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
else
    SERVER_IP="localhost"
fi

echo ""
echo "========================================="
echo "  Sub2API 部署完成！"
echo ""
if [ -n "$HTTPS_DOMAIN" ]; then
    echo "  HTTPS 地址：https://${HTTPS_DOMAIN}:${HTTPS_PORT}"
    if [ "$HTTPS_ONLY" = "true" ]; then
        echo "  HTTP 端口：已关闭（HTTPS_ONLY=true）"
    else
        echo "  HTTP 地址：http://${SERVER_IP}:${SERVER_PORT}（同时保留）"
    fi
    echo "  证书自动由宿主机维护，Caddy 检测到文件变化会自动 reload"
else
    echo "  访问地址：http://${SERVER_IP}:${SERVER_PORT}"
fi
echo "  默认邮箱：$ADMIN_EMAIL"
if [ -n "$ADMIN_PASSWORD" ]; then
    echo "  管理员密码：$ADMIN_PASSWORD"
elif [ -n "$DETECTED_ADMIN_PW" ]; then
    echo "  管理员密码：$DETECTED_ADMIN_PW (从日志获取)"
else
    echo "  未能从日志自动提取管理员密码，请手动执行以下命令查看："
    echo "    cd $DATA_DIR && $COMPOSE_CMD logs | grep -i password"
fi
echo ""
echo "  请立即登录并修改默认密码！"
echo ""
echo "  常用命令："
echo "    cd $DATA_DIR"
echo "    $COMPOSE_CMD logs -f     # 查看实时日志"
echo "    $COMPOSE_CMD restart     # 重启服务"
echo "    $COMPOSE_CMD down        # 停止服务"
echo ""
if [ -n "$HTTPS_DOMAIN" ]; then
    PORT_TO_OPEN="$HTTPS_PORT"
else
    PORT_TO_OPEN="$SERVER_PORT"
fi
echo "  云 VPS 提示：如无法访问，请在云控制台安全组 / 防火墙开放端口 ${PORT_TO_OPEN}/tcp"
echo "    Ubuntu/Debian (ufw):  sudo ufw allow ${PORT_TO_OPEN}/tcp"
echo "    RHEL/CentOS (firewalld): sudo firewall-cmd --add-port=${PORT_TO_OPEN}/tcp --permanent && sudo firewall-cmd --reload"
echo "========================================="