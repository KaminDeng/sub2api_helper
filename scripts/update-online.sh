#!/bin/bash
set -euo pipefail

# ============================================
# Sub2API 在线更新与备份脚本
# 仓库：https://github.com/KaminDeng/sub2api-helper
# 使用方法：bash scripts/update-online.sh
# ============================================

DATA_DIR="$HOME/sub2api"
BACKUP_DIR="$HOME/sub2api-backups"
SERVICE_NAME="sub2api"
HEALTH_PATH="/health"
HEALTH_URL=""
ACTIVE_PORTS=(8444 8080 8443)
CUSTOM_ACTIVE_PORTS=false
MAX_ACTIVE_CONNECTIONS=0
WAIT_IDLE=false
WAIT_IDLE_TIMEOUT=120
SKIP_BACKUP=false
BACKUP_ONLY=false
DRY_RUN=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: bash scripts/update-online.sh [options]

Update an existing Sub2API Docker Compose deployment with backups.

Options:
  --data-dir PATH              Existing deployment directory (default: \$HOME/sub2api)
  --backup-dir PATH            Backup output directory (default: \$HOME/sub2api-backups)
  --service NAME               App service/container name (default: sub2api)
  --health-url URL             Full health-check URL after update
  --health-path PATH           Health path used when URL is auto-detected (default: /health)
  --active-ports LIST          Comma-separated ports checked by --wait-idle (default: 8444,8080,8443)
  --wait-idle                  Wait until active HTTP(S) connections are below the threshold
  --max-active-connections N   Active connection threshold for --wait-idle (default: 0)
  --wait-idle-timeout N        Seconds to wait for idle connections (default: 120)
  --skip-backup                Update without creating backups
  --backup-only                Create backups and exit without updating
  --dry-run                    Print planned operations without changing anything
  -h, --help                   Show this help

Examples:
  bash scripts/update-online.sh
  bash scripts/update-online.sh --wait-idle --max-active-connections 0
  bash scripts/update-online.sh --backup-only
EOF
}

require_number() {
    local name=$1
    local value=$2
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        print_error "$name must be a non-negative integer: $value"
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir)
            DATA_DIR=${2:-}
            [ -n "$DATA_DIR" ] || { print_error "--data-dir requires a value"; exit 2; }
            shift 2
            ;;
        --backup-dir)
            BACKUP_DIR=${2:-}
            [ -n "$BACKUP_DIR" ] || { print_error "--backup-dir requires a value"; exit 2; }
            shift 2
            ;;
        --service)
            SERVICE_NAME=${2:-}
            [ -n "$SERVICE_NAME" ] || { print_error "--service requires a value"; exit 2; }
            shift 2
            ;;
        --health-url)
            HEALTH_URL=${2:-}
            [ -n "$HEALTH_URL" ] || { print_error "--health-url requires a value"; exit 2; }
            shift 2
            ;;
        --health-path)
            HEALTH_PATH=${2:-}
            [ -n "$HEALTH_PATH" ] || { print_error "--health-path requires a value"; exit 2; }
            shift 2
            ;;
        --active-ports)
            ports_value=${2:-}
            [ -n "$ports_value" ] || { print_error "--active-ports requires a value"; exit 2; }
            IFS=',' read -r -a ACTIVE_PORTS <<< "$ports_value"
            for active_port in "${ACTIVE_PORTS[@]}"; do
                require_number "--active-ports" "$active_port"
            done
            CUSTOM_ACTIVE_PORTS=true
            shift 2
            ;;
        --wait-idle)
            WAIT_IDLE=true
            shift
            ;;
        --max-active-connections)
            MAX_ACTIVE_CONNECTIONS=${2:-}
            require_number "--max-active-connections" "$MAX_ACTIVE_CONNECTIONS"
            shift 2
            ;;
        --wait-idle-timeout)
            WAIT_IDLE_TIMEOUT=${2:-}
            require_number "--wait-idle-timeout" "$WAIT_IDLE_TIMEOUT"
            shift 2
            ;;
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --backup-only)
            BACKUP_ONLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo ""
            usage
            exit 2
            ;;
    esac
done

if [ "$SKIP_BACKUP" = "true" ] && [ "$BACKUP_ONLY" = "true" ]; then
    print_error "--skip-backup and --backup-only cannot be used together"
    exit 2
fi

DATA_DIR=${DATA_DIR%/}
BACKUP_DIR=${BACKUP_DIR%/}

run_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY_RUN: $*"
    else
        "$@"
    fi
}

detect_compose_cmd() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

compose() {
    # shellcheck disable=SC2086
    $COMPOSE_CMD "$@"
}

load_env_if_present() {
    [ -f "$DATA_DIR/.env" ] || return 0

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        value=${value%\"}
        value=${value#\"}
        value=${value%\'}
        value=${value#\'}
        case "$key" in
            SERVER_PORT|BIND_HOST|HTTPS_DOMAIN|HTTPS_PORT|POSTGRES_USER|POSTGRES_DB|REDIS_PASSWORD)
                export "$key=$value"
                ;;
        esac
    done < "$DATA_DIR/.env"
}

detect_health_url() {
    if [ -n "$HEALTH_URL" ]; then
        echo "$HEALTH_URL"
        return
    fi

    if [ -n "${HTTPS_DOMAIN:-}" ] && [ -n "${HTTPS_PORT:-}" ]; then
        echo "https://127.0.0.1:${HTTPS_PORT}${HEALTH_PATH}"
        return
    fi

    if [ -f "$DATA_DIR/docker-compose.override.yml" ]; then
        local https_port
        https_port=$(grep -E '^[[:space:]]*-[[:space:]]*"[0-9]+:8443"' "$DATA_DIR/docker-compose.override.yml" 2>/dev/null \
            | head -1 | sed -E 's/.*"([0-9]+):8443".*/\1/' || true)
        if [ -n "$https_port" ]; then
            echo "https://127.0.0.1:${https_port}${HEALTH_PATH}"
            return
        fi
    fi

    echo "http://127.0.0.1:${SERVER_PORT:-8080}${HEALTH_PATH}"
}

add_health_port_to_active_ports() {
    [ "$CUSTOM_ACTIVE_PORTS" = "false" ] || return 0

    local url=$1
    local host_port
    host_port=$(printf '%s\n' "$url" | sed -nE 's|^[a-zA-Z]+://[^/:]+:([0-9]+).*|\1|p')
    [ -n "$host_port" ] || return 0

    local port
    for port in "${ACTIVE_PORTS[@]}"; do
        [ "$port" = "$host_port" ] && return 0
    done
    ACTIVE_PORTS+=("$host_port")
}

active_connection_count() {
    if ! command -v ss &>/dev/null; then
        echo 0
        return
    fi

    local total=0
    local port count
    for port in "${ACTIVE_PORTS[@]}"; do
        count=$(ss -Htan state established "( sport = :$port )" 2>/dev/null | wc -l | tr -d ' ')
        total=$((total + count))
    done
    echo "$total"
}

wait_for_idle() {
    [ "$WAIT_IDLE" = "true" ] || return 0

    print_info "等待连接数降到 <= $MAX_ACTIVE_CONNECTIONS（最多 ${WAIT_IDLE_TIMEOUT}s）"
    local start now active
    start=$(date +%s)
    while true; do
        active=$(active_connection_count)
        echo "  当前活跃连接数：$active"
        if [ "$active" -le "$MAX_ACTIVE_CONNECTIONS" ]; then
            return 0
        fi

        now=$(date +%s)
        if [ $((now - start)) -ge "$WAIT_IDLE_TIMEOUT" ]; then
            print_error "等待空闲超时，仍有 $active 个活跃连接"
            exit 1
        fi
        sleep 5
    done
}

create_backups() {
    if [ "$SKIP_BACKUP" = "true" ]; then
        print_warn "Skipping backup (--skip-backup)"
        return 0
    fi

    local stamp config_backup pg_backup redis_backup
    stamp=$(date +%Y%m%d-%H%M%S)
    config_backup="$BACKUP_DIR/sub2api-config-data-$stamp.tar.gz"
    pg_backup="$BACKUP_DIR/sub2api-postgres-$stamp.sql.gz"
    redis_backup="$BACKUP_DIR/sub2api-redis-$stamp.rdb"

    run_cmd mkdir -p "$BACKUP_DIR"

    print_info "备份配置与 data 目录"
    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY_RUN: would create config/data backup: $config_backup"
    else
        local tar_items=()
        [ -f "$DATA_DIR/docker-compose.yml" ] && tar_items+=("docker-compose.yml")
        [ -f "$DATA_DIR/docker-compose.override.yml" ] && tar_items+=("docker-compose.override.yml")
        [ -f "$DATA_DIR/.env" ] && tar_items+=(".env")
        [ -f "$DATA_DIR/Caddyfile" ] && tar_items+=("Caddyfile")
        [ -d "$DATA_DIR/data" ] && tar_items+=("data")
        if [ ${#tar_items[@]} -gt 0 ]; then
            tar -C "$DATA_DIR" -czf "$config_backup" "${tar_items[@]}"
        else
            print_warn "没有找到可打包的配置/data 文件"
        fi
    fi

    print_info "备份 PostgreSQL（pg_dump）"
    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY_RUN: would create PostgreSQL dump: $pg_backup"
    else
        if docker ps --format '{{.Names}}' | grep -qx 'sub2api-postgres'; then
            docker exec sub2api-postgres pg_dump -U "${POSTGRES_USER:-sub2api}" -d "${POSTGRES_DB:-sub2api}" | gzip > "$pg_backup"
        else
            print_warn "未找到 sub2api-postgres 容器，跳过 PostgreSQL 逻辑备份"
        fi
    fi

    print_info "备份 Redis dump.rdb"
    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY_RUN: would create Redis backup: $redis_backup"
    else
        if docker ps --format '{{.Names}}' | grep -qx 'sub2api-redis'; then
            local redis_cmd=(docker exec)
            if [ -n "${REDIS_PASSWORD:-}" ]; then
                redis_cmd+=(-e "REDISCLI_AUTH=$REDIS_PASSWORD")
            fi
            redis_cmd+=(sub2api-redis redis-cli SAVE)

            if "${redis_cmd[@]}" >/tmp/sub2api-redis-save.log 2>&1; then
                if ! docker cp sub2api-redis:/data/dump.rdb "$redis_backup" >/dev/null 2>&1; then
                    print_warn "Redis SAVE 成功，但复制 dump.rdb 失败"
                fi
            else
                print_warn "Redis SAVE 失败：$(tail -1 /tmp/sub2api-redis-save.log 2>/dev/null || echo unknown)"
            fi
        else
            print_warn "未找到 sub2api-redis 容器，跳过 Redis 备份"
        fi
    fi

    echo "  配置/data：$config_backup"
    echo "  PostgreSQL：$pg_backup"
    echo "  Redis：$redis_backup"
}

wait_for_health() {
    local url=$1
    local health code container_health

    print_info "等待服务健康：$url"
    for i in {1..45}; do
        container_health=$(docker inspect "$SERVICE_NAME" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)
        code=$(curl -ksS -o /tmp/sub2api-update-health -w '%{http_code}' "$url" 2>/dev/null || true)
        printf '  health_check_%02d container=%s http_code=%s\n' "$i" "${container_health:-unknown}" "${code:-000}"
        if [ "$code" = "200" ] && { [ "$container_health" = "healthy" ] || [ "$container_health" = "running" ]; }; then
            cat /tmp/sub2api-update-health 2>/dev/null || true
            echo ""
            return 0
        fi
        sleep 2
    done

    print_error "服务健康检查未通过"
    compose logs --tail=80 "$SERVICE_NAME" || true
    exit 1
}

echo ""
echo "========================================="
echo "  Sub2API 在线更新与备份脚本"
echo "========================================="
echo ""

if [ "$DRY_RUN" != "true" ]; then
    if [ ! -d "$DATA_DIR" ]; then
        print_error "部署目录不存在：$DATA_DIR"
        exit 1
    fi
    if [ ! -f "$DATA_DIR/docker-compose.yml" ]; then
        print_error "未找到 docker-compose.yml：$DATA_DIR/docker-compose.yml"
        exit 1
    fi
fi

COMPOSE_CMD=$(detect_compose_cmd)
if [ -z "$COMPOSE_CMD" ] && [ "$DRY_RUN" != "true" ]; then
    print_error "Docker Compose 未安装或不可用"
    exit 1
elif [ -z "$COMPOSE_CMD" ]; then
    COMPOSE_CMD="docker compose"
fi

load_env_if_present
HEALTH_CHECK_URL=$(detect_health_url)
add_health_port_to_active_ports "$HEALTH_CHECK_URL"

print_info "部署目录：$DATA_DIR"
print_info "备份目录：$BACKUP_DIR"
print_info "应用服务：$SERVICE_NAME"
print_info "健康检查：$HEALTH_CHECK_URL"
print_info "连接统计端口：${ACTIVE_PORTS[*]}"

cd "$DATA_DIR"

create_backups

if [ "$BACKUP_ONLY" = "true" ]; then
    print_info "已完成备份，按 --backup-only 要求不执行更新"
    exit 0
fi

wait_for_idle

if [ "$DRY_RUN" = "true" ]; then
    echo "DRY_RUN: docker compose pull $SERVICE_NAME"
    echo "DRY_RUN: docker compose up -d --no-deps $SERVICE_NAME"
    echo "DRY_RUN: would check health: $HEALTH_CHECK_URL"
    exit 0
fi

running_before=$(docker inspect "$SERVICE_NAME" --format '{{.Image}}' 2>/dev/null || echo "unknown")
active_before=$(active_connection_count)
print_info "当前镜像：$running_before"
print_info "当前活跃连接数：$active_before"

print_info "拉取最新应用镜像"
compose pull "$SERVICE_NAME"

print_info "只重建应用容器（不重启数据库/Redis/Caddy）"
start_ts=$(date +%s)
compose up -d --no-deps "$SERVICE_NAME"
end_ts=$(date +%s)

running_after=$(docker inspect "$SERVICE_NAME" --format '{{.Image}}' 2>/dev/null || echo "unknown")
print_info "重建耗时：$((end_ts - start_ts))s"
print_info "更新后镜像：$running_after"

wait_for_health "$HEALTH_CHECK_URL"

print_info "容器状态"
compose ps

print_info "最近日志"
compose logs --tail=60 "$SERVICE_NAME"

echo ""
echo "========================================="
echo "  Sub2API 更新完成"
echo "========================================="
