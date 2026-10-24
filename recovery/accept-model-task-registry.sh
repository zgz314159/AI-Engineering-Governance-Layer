#!/usr/bin/env bash
# One-shot root acceptance for the installed GT1 CLI.
#
# Scope: TEMPORARY REGISTRY, private mount namespace. The real
# /var/lib/aegl-model/registry.json is never written; only its SHA-256 is
# compared before/after. No model, API, sandbox-model run, or broker call.
set -euo pipefail

GT1_COMMIT="e5f31c8227353e60683c86a6092b93561da30c74"
CLI="/usr/local/lib/aegl-model-task/bin/aegl-model-task"
MOD="/usr/local/lib/aegl-model-task/recovery/model_task_registry.py"
CLI_SHA="edb38c2155f617417c8f225128144fba94c822db317a799613fa5e9203669b6e"
MOD_SHA="0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de"
REAL_REG="/var/lib/aegl-model/registry.json"

say() { printf '%s\n' "$*"; }
fail() { printf 'ACCEPT_FAILED step=%s reason=%s: %s\n' "$1" "$2" "${3:-}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail root not_root "run as root from a trusted terminal"
for tool in unshare mount setpriv sha256sum stat python3 id; do
  command -v "$tool" >/dev/null 2>&1 || fail dependencies missing_tool "$tool"
done
[ -x "$CLI" ] || fail installed cli_missing "$CLI"
[ -f "$MOD" ] || fail installed module_missing "$MOD"
[ -d /var/lib/aegl-model ] || fail installed model_dir_missing "/var/lib/aegl-model"

printf '%s  %s\n' "$CLI_SHA" "$CLI" | sha256sum -c - >/dev/null || fail installed cli_hash
printf '%s  %s\n' "$MOD_SHA" "$MOD" | sha256sum -c - >/dev/null || fail installed module_hash
test "$(stat -c '%U:%G %a' /usr/local/lib/aegl-model-task)" = "root:root 755" || fail installed dir_mode
test "$(stat -c '%U:%G %a' "$CLI")" = "root:root 755" || fail installed cli_mode
test "$(stat -c '%U:%G %a' "$MOD")" = "root:root 644" || fail installed module_mode

TMP="$(mktemp -d /var/tmp/aegl-model-task-accept.XXXXXX)" || fail tmp mkdir
chmod 0700 "$TMP"
cleaned=0
cleanup() {
  if [ "$cleaned" -eq 0 ]; then
    chmod -R u+rwX "$TMP" 2>/dev/null || true
    rm -rf "$TMP" 2>/dev/null || true
    if [ -e "$TMP" ]; then
      say "ACCEPT_CLEANUP=FAILED path=$TMP"
      return 1
    fi
    cleaned=1
    say "ACCEPT_CLEANUP=OK"
  fi
  return 0
}
trap 'cleanup || true' EXIT

TASK="$TMP/task"
mkdir -p "$TASK/project" "$TASK/scratch" "$TASK/formal/.git" "$TASK/contract"
chown aegl-ai:aegl-ai "$TASK/project" "$TASK/scratch" || fail fixtures chown
chmod 0750 "$TASK/project" "$TASK/scratch"
cat > "$TASK/contract/project-context.json" <<EOF
{"source_root":"$TASK"}
EOF
cat > "$TASK/contract/implementation-contract.json" <<EOF
{"allowed_paths":["project/"]}
EOF
chown -R root:root "$TASK/contract" "$TASK/formal"
chmod 0555 "$TASK/contract"
chmod 0444 "$TASK/contract/project-context.json" "$TASK/contract/implementation-contract.json"
chmod 0755 "$TASK" "$TASK/formal" "$TASK/formal/.git"

MODEL="$TMP/model"
mkdir -p "$MODEL"
cat > "$MODEL/registry.json" <<EOF
{"existing-task":{"worktree":"$TASK/project","scratch":"$TASK/scratch","project":"$TASK/formal","contract_package":"$TASK/contract"}}
EOF
chown root:root "$MODEL" "$MODEL/registry.json"
chmod 0755 "$MODEL"
chmod 0644 "$MODEL/registry.json"

real_state() {
  if [ -e "$REAL_REG" ]; then
    sha256sum "$REAL_REG" | awk '{print $1}'
  else
    printf 'ABSENT\n'
  fi
}
REAL_BEFORE="$(real_state)" || fail real_registry read_before

"$CLI" --help >"$TMP/help.out" 2>&1 || fail installed cli_import
say "ACCEPT_INSTALLED_CLI_IMPORT=OK"

NOBODY_UID="$(id -u nobody)" || fail nonroot nobody_uid
NOBODY_GID="$(id -g nobody)" || fail nonroot nobody_gid
set +e
env PYTHONDONTWRITEBYTECODE=1 setpriv --reuid="$NOBODY_UID" --regid="$NOBODY_GID" --clear-groups --no-new-privs -- \
  "$CLI" register --task-id accept-task --worktree "$TASK/project" --scratch "$TASK/scratch" \
  --project "$TASK/formal" --contract-package "$TASK/contract" >"$TMP/nonroot.out" 2>&1
NONROOT_RC=$?
set -e
[ "$NONROOT_RC" -eq 2 ] || fail nonroot exit "rc=$NONROOT_RC"
grep -q 'reason=not_root' "$TMP/nonroot.out" || fail nonroot message
say "ACCEPT_NON_ROOT_REGISTER=REJECTED"

run_cli_ns() {
  unshare --mount --propagation private -- bash -c '
    set -euo pipefail
    mount --bind "$1" /var/lib/aegl-model
    shift
    "$@"
  ' _ "$MODEL" "$@"
}

run_cli_ns "$CLI" register --task-id accept-task --worktree "$TASK/project" --scratch "$TASK/scratch" \
  --project "$TASK/formal" --contract-package "$TASK/contract" >"$TMP/register.out" 2>&1 \
  || fail root_register command_failed
grep -q 'REGISTERED task_id=accept-task' "$TMP/register.out" || fail root_register output
say "ACCEPT_ROOT_REGISTER=REGISTERED"

python3 - "$MODEL/registry.json" <<'PY' || fail existing_entry not_preserved
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if set(data) != {"existing-task", "accept-task"}:
    raise SystemExit(sorted(data))
PY
say "ACCEPT_EXISTING_ENTRY=PRESERVED"

REG_STAT="$(stat -c '%U:%G %a' "$MODEL/registry.json")"
LOCK_STAT="$(stat -c '%U:%G %a' "$MODEL/registry.json.lock")"
[ "$REG_STAT" = "root:root 644" ] || fail registry_mode "$REG_STAT"
[ "$LOCK_STAT" = "root:root 600" ] || fail lock_mode "$LOCK_STAT"
say "ACCEPT_REGISTRY_OWNER_MODE=$REG_STAT"
say "ACCEPT_LOCK_OWNER_MODE=$LOCK_STAT"

BEFORE_DUP="$(sha256sum "$MODEL/registry.json" | awk '{print $1}')"
set +e
run_cli_ns "$CLI" register --task-id accept-task --worktree "$TASK/project" --scratch "$TASK/scratch" \
  --project "$TASK/formal" --contract-package "$TASK/contract" >"$TMP/duplicate.out" 2>&1
DUP_RC=$?
set -e
[ "$DUP_RC" -eq 3 ] || fail duplicate exit "rc=$DUP_RC"
grep -q 'reason=duplicate_task_id' "$TMP/duplicate.out" || fail duplicate message
AFTER_DUP="$(sha256sum "$MODEL/registry.json" | awk '{print $1}')"
[ "$BEFORE_DUP" = "$AFTER_DUP" ] || fail duplicate bytes_changed
say "ACCEPT_DUPLICATE=REJECTED"

REAL_AFTER="$(real_state)" || fail real_registry read_after
[ "$REAL_BEFORE" = "$REAL_AFTER" ] || fail real_registry changed
say "ACCEPT_REAL_REGISTRY_UNCHANGED=OK"

cleanup || fail cleanup failed
say "ACCEPT_SCOPE=TEMPORARY_REGISTRY_PRIVATE_MOUNTNS"
say "ROOT_CLI_ACCEPTANCE=PASS (temporary registry)"
