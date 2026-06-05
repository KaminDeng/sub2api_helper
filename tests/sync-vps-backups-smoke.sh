#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/sync-vps-backups.sh"

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

run_capture() {
    local outfile=$1
    shift
    set +e
    "$@" >"$outfile" 2>&1
    local status=$?
    set -e
    return "$status"
}

if [ ! -x "$SCRIPT" ]; then
    fail "missing executable script: $SCRIPT"
fi

help_out=$(mktemp)
run_capture "$help_out" "$SCRIPT" --help || fail "--help should exit 0"
grep -q "Usage:" "$help_out" || fail "--help should print Usage"
grep -q "pull" "$help_out" || fail "--help should mention pull"
grep -q "push" "$help_out" || fail "--help should mention push"
grep -q "list" "$help_out" || fail "--help should mention list"

bad_out=$(mktemp)
if run_capture "$bad_out" "$SCRIPT" nope; then
    fail "unknown command should fail"
fi
grep -q "Unknown command" "$bad_out" || fail "unknown command should explain the failure"

pull_out=$(mktemp)
run_capture "$pull_out" "$SCRIPT" pull --dry-run --host example.com --user root --port 2222 --local-dir "$REPO_ROOT/.tmp-backups" || fail "pull dry run should exit 0"
grep -q "DRY_RUN: ssh -p 2222 root@example.com" "$pull_out" || fail "pull dry run should check remote files"
grep -q "cd ~/'sub2api-helper'" "$pull_out" || fail "pull dry run should preserve remote home-relative helper path"
grep -q "DRY_RUN: rsync" "$pull_out" || fail "pull dry run should use rsync/scp"

push_out=$(mktemp)
run_capture "$push_out" "$SCRIPT" push --dry-run --host example.com --user root --port 2222 --local-dir "$REPO_ROOT/.tmp-backups" || fail "push dry run should exit 0"
grep -q "DRY_RUN: ssh -p 2222 root@example.com" "$push_out" || fail "push dry run should create remote dir"
grep -q "DRY_RUN: rsync" "$push_out" || fail "push dry run should use rsync/scp"

list_out=$(mktemp)
run_capture "$list_out" "$SCRIPT" list --dry-run --host example.com --user root --port 2222 || fail "list dry run should exit 0"
grep -q "DRY_RUN: ssh -p 2222 root@example.com" "$list_out" || fail "list dry run should use ssh"

echo "sync-vps-backups smoke tests passed"
