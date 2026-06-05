#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/update-online.sh"

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
grep -q -- "--backup-only" "$help_out" || fail "--help should mention --backup-only"
grep -q -- "--wait-idle" "$help_out" || fail "--help should mention --wait-idle"

bad_out=$(mktemp)
if run_capture "$bad_out" "$SCRIPT" --does-not-exist; then
    fail "unknown option should fail"
fi
grep -q "Unknown option" "$bad_out" || fail "unknown option should explain the failure"

backup_only_out=$(mktemp)
run_capture "$backup_only_out" "$SCRIPT" --dry-run --backup-only --data-dir "$REPO_ROOT" || fail "backup-only dry run should exit 0"
grep -q "DRY_RUN: would create config/data backup" "$backup_only_out" || fail "backup-only dry run should include config backup"
grep -q "DRY_RUN: would create PostgreSQL dump" "$backup_only_out" || fail "backup-only dry run should include postgres dump"
if grep -q "docker compose pull" "$backup_only_out"; then
    fail "backup-only dry run should not pull images"
fi

skip_backup_out=$(mktemp)
run_capture "$skip_backup_out" "$SCRIPT" --dry-run --skip-backup --data-dir "$REPO_ROOT" || fail "skip-backup dry run should exit 0"
grep -q "Skipping backup" "$skip_backup_out" || fail "skip-backup dry run should report skipped backup"
grep -q "DRY_RUN: docker compose pull sub2api" "$skip_backup_out" || fail "skip-backup dry run should pull app image"
grep -q "DRY_RUN: docker compose up -d --no-deps sub2api" "$skip_backup_out" || fail "skip-backup dry run should recreate only app"

echo "update-online smoke tests passed"
