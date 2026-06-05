#!/bin/bash
set -euo pipefail

# ============================================
# Sub2API VPS 备份本地同步脚本
# 在本机拉取/推送 VPS 上的 sub2api 备份文件
# ============================================

COMMAND=""
SSH_HOST=""
SSH_USER="${USER:-root}"
SSH_PORT=22
REMOTE_BACKUP_DIR="~/sub2api-backups"
REMOTE_RESTORE_DIR="~/sub2api-restore"
REMOTE_HELPER_DIR="~/sub2api-helper"
REMOTE_DATA_DIR="~/sub2api"
LOCAL_DIR="$PWD/sub2api-backups"
CREATE_REMOTE_BACKUP=true
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
Usage: bash scripts/sync-vps-backups.sh <command> [options]

Commands:
  pull    Create a remote backup by default, then download backup files to this machine
  push    Upload local backup files to the VPS restore directory
  list    List remote backup files

Options:
  --host HOST                 VPS host or IP (required)
  --user USER                 SSH user (default: current local user)
  --port PORT                 SSH port (default: 22)
  --local-dir PATH            Local backup directory (default: ./sub2api-backups)
  --remote-backup-dir PATH    Remote backup directory (default: ~/sub2api-backups)
  --remote-restore-dir PATH   Remote restore directory for push (default: ~/sub2api-restore)
  --remote-helper-dir PATH    Remote sub2api-helper directory (default: ~/sub2api-helper)
  --remote-data-dir PATH      Remote deployed sub2api data dir (default: ~/sub2api)
  --no-create                 For pull: do not run remote update-online.sh --backup-only first
  --dry-run                   Print planned SSH/transfer commands without changing anything
  -h, --help                  Show this help

Examples:
  bash scripts/sync-vps-backups.sh pull --host your-vps-ip --user user --port 22
  bash scripts/sync-vps-backups.sh push --host your-vps-ip --user user --port 22
  bash scripts/sync-vps-backups.sh list --host your-vps-ip --user user --port 22
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

if [ $# -eq 0 ]; then
    usage
    exit 2
fi

case "$1" in
    pull|push|list)
        COMMAND=$1
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        print_error "Unknown command: $1"
        echo ""
        usage
        exit 2
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --host)
            SSH_HOST=${2:-}
            [ -n "$SSH_HOST" ] || { print_error "--host requires a value"; exit 2; }
            shift 2
            ;;
        --user)
            SSH_USER=${2:-}
            [ -n "$SSH_USER" ] || { print_error "--user requires a value"; exit 2; }
            shift 2
            ;;
        --port)
            SSH_PORT=${2:-}
            require_number "--port" "$SSH_PORT"
            shift 2
            ;;
        --local-dir)
            LOCAL_DIR=${2:-}
            [ -n "$LOCAL_DIR" ] || { print_error "--local-dir requires a value"; exit 2; }
            shift 2
            ;;
        --remote-backup-dir)
            REMOTE_BACKUP_DIR=${2:-}
            [ -n "$REMOTE_BACKUP_DIR" ] || { print_error "--remote-backup-dir requires a value"; exit 2; }
            shift 2
            ;;
        --remote-restore-dir)
            REMOTE_RESTORE_DIR=${2:-}
            [ -n "$REMOTE_RESTORE_DIR" ] || { print_error "--remote-restore-dir requires a value"; exit 2; }
            shift 2
            ;;
        --remote-helper-dir)
            REMOTE_HELPER_DIR=${2:-}
            [ -n "$REMOTE_HELPER_DIR" ] || { print_error "--remote-helper-dir requires a value"; exit 2; }
            shift 2
            ;;
        --remote-data-dir)
            REMOTE_DATA_DIR=${2:-}
            [ -n "$REMOTE_DATA_DIR" ] || { print_error "--remote-data-dir requires a value"; exit 2; }
            shift 2
            ;;
        --no-create)
            CREATE_REMOTE_BACKUP=false
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

if [ -z "$SSH_HOST" ]; then
    print_error "--host is required"
    exit 2
fi

SSH_TARGET="${SSH_USER}@${SSH_HOST}"

quote_remote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

quote_remote_path() {
    case "$1" in
        "~")
            printf "~"
            ;;
        "~/"*)
            printf "~/%s" "$(quote_remote "${1:2}")"
            ;;
        *)
            quote_remote "$1"
            ;;
    esac
}

run_local() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY_RUN: $*"
    else
        "$@"
    fi
}

run_ssh() {
    local remote_cmd=$1
    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY_RUN: ssh -p $SSH_PORT $SSH_TARGET $remote_cmd"
    else
        ssh -p "$SSH_PORT" "$SSH_TARGET" "$remote_cmd"
    fi
}

transfer_pull() {
    local remote_pattern
    remote_pattern="${SSH_TARGET}:${REMOTE_BACKUP_DIR%/}/sub2api-*"
    if command -v rsync &>/dev/null; then
        run_local rsync -avz -e "ssh -p $SSH_PORT" "$remote_pattern" "$LOCAL_DIR/"
    else
        print_warn "rsync 未安装，回退到 scp"
        run_local scp -P "$SSH_PORT" "$remote_pattern" "$LOCAL_DIR/"
    fi
}

transfer_push() {
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$LOCAL_DIR" -maxdepth 1 -type f -name 'sub2api-*' -print0 2>/dev/null || true)

    if [ "$DRY_RUN" != "true" ] && [ ${#files[@]} -eq 0 ]; then
        print_error "本机目录没有找到 sub2api-* 备份文件：$LOCAL_DIR"
        exit 1
    fi

    if command -v rsync &>/dev/null; then
        if [ "$DRY_RUN" = "true" ] && [ ${#files[@]} -eq 0 ]; then
            run_local rsync -avz -e "ssh -p $SSH_PORT" "${LOCAL_DIR%/}/sub2api-*" "${SSH_TARGET}:${REMOTE_RESTORE_DIR%/}/"
        else
            run_local rsync -avz -e "ssh -p $SSH_PORT" "${files[@]}" "${SSH_TARGET}:${REMOTE_RESTORE_DIR%/}/"
        fi
    else
        print_warn "rsync 未安装，回退到 scp"
        if [ "$DRY_RUN" = "true" ] && [ ${#files[@]} -eq 0 ]; then
            run_local scp -P "$SSH_PORT" "${LOCAL_DIR%/}/sub2api-*" "${SSH_TARGET}:${REMOTE_RESTORE_DIR%/}/"
        else
            run_local scp -P "$SSH_PORT" "${files[@]}" "${SSH_TARGET}:${REMOTE_RESTORE_DIR%/}/"
        fi
    fi
}

echo ""
echo "========================================="
echo "  Sub2API VPS 备份本地同步脚本"
echo "========================================="
echo ""
print_info "命令：$COMMAND"
print_info "VPS：$SSH_TARGET:$SSH_PORT"
print_info "本机目录：$LOCAL_DIR"
print_info "远端备份目录：$REMOTE_BACKUP_DIR"
print_info "远端恢复目录：$REMOTE_RESTORE_DIR"

case "$COMMAND" in
    list)
        run_ssh "ls -lh $(quote_remote_path "$REMOTE_BACKUP_DIR")/sub2api-* 2>/dev/null || true"
        ;;
    pull)
        run_local mkdir -p "$LOCAL_DIR"
        if [ "$CREATE_REMOTE_BACKUP" = "true" ]; then
            print_info "先在 VPS 上生成最新备份"
            run_ssh "cd $(quote_remote_path "$REMOTE_HELPER_DIR") && bash scripts/update-online.sh --backup-only --data-dir $(quote_remote_path "$REMOTE_DATA_DIR") --backup-dir $(quote_remote_path "$REMOTE_BACKUP_DIR")"
        else
            print_warn "按 --no-create 跳过远端新备份生成"
        fi
        print_info "拉取备份到本机"
        transfer_pull
        ;;
    push)
        print_info "创建远端恢复目录"
        run_ssh "mkdir -p $(quote_remote_path "$REMOTE_RESTORE_DIR")"
        print_info "推送本机备份到 VPS"
        transfer_push
        ;;
esac

echo ""
echo "========================================="
echo "  同步流程结束"
echo "========================================="
