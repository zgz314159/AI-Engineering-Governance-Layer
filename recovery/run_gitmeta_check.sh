#!/usr/bin/env bash
# run_check.sh — no-model Git-metadata verification for one task worktree.
# Root only. Runs from a root-exclusive, manifest-verified copy (see bootstrap.sh).
#   run_check.sh
# Cross-UID execution (the sandbox drop and the host identity probe) is REPORTED, never assumed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
LAUNCHER="$LIB/aegl-hermes-sandbox"
CHECK="$HERE/gitmeta.check"
TASK="${TASK:-IAP-SMOKE-004}"
WT="${WT:-/var/tmp/IAP-SMOKE-004/project}"
BASE="${EXPECT_BASE:-177680708739a72a0d70bc6a9664245b00a2ef08}"
AI_USER="${AEGL_AI_USER:-aegl-ai}"
AI_HOME="${AEGL_AI_HOME:-/home/aegl-ai}"
SETPRIV=/usr/bin/setpriv
FAIL=0

say() { printf '%s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { say NOT_ROOT; exit 1; }
[ -f "$LAUNCHER" ] || { say "MISSING launcher $LAUNCHER"; exit 1; }
[ -f "$CHECK" ] || { say "MISSING check $CHECK"; exit 1; }
AI_UID="$(id -u "$AI_USER")" || { say "MISSING identity $AI_USER"; exit 1; }
AI_GID="$(id -g "$AI_USER")"
TMPD="$(mktemp -d /root/aegl-gitmeta-check.XXXXXX)"; chmod 0700 "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

show() { grep -aE "$1" "$2" || true; }

say "=== 0. host, the SAME identity (baseline: MUST pass) ==="
"$SETPRIV" --reuid="$AI_UID" --regid="$AI_GID" --clear-groups --no-new-privs -- \
  env -i PATH=/usr/bin:/bin HOME="$AI_HOME" LANG=C.UTF-8 \
  git -c "safe.directory=$WT" -C "$WT" rev-parse HEAD >"$TMPD/host.out" 2>"$TMPD/host.err"
hrc=$?
say "HOST_HEAD=$(head -c 200 "$TMPD/host.out" | tr -d '\n')"
say "HOST_ERR=$(head -c 400 "$TMPD/host.err" | tr '\n' ' ')"
say "HOST_RC=$hrc"
[ "$hrc" -eq 0 ] || FAIL=1

run_launcher() { # <extra args...>  -> writes $TMPD/run.log, sets RUN_RC
  local log="$1"; shift
  AEGL_MODEL_LIBDIR="$LIB" AEGL_AI_USER="$AI_USER" AEGL_AI_GROUP="$(id -gn "$AI_USER")" \
    /bin/bash "$LAUNCHER" --task "$TASK" --check "$(cat "$CHECK")" "$@" > "$log" 2>&1
  RUN_RC=$?
}

say "=== 1. pre-fix mount set (expected to FAIL) ==="
run_launcher "$TMPD/baseline.log" --check-baseline
show '^(check mode|  git metadata|COMMON=|COMMON_RC=|REV_PARSE_|STATUS_RC=|PERM_|CHECK_FAILURES=|BLOCKED)' "$TMPD/baseline.log"
say "BASELINE_RC=$RUN_RC"
if [ "$RUN_RC" -eq 0 ]; then say "BASELINE_UNEXPECTED_PASS"; FAIL=1; fi

say "=== 2. fixed mount set (expected to PASS) ==="
run_launcher "$TMPD/fixed.log"
show '^(check mode|  git metadata|COMMON=|COMMON_RC=|REV_PARSE_|STATUS_RC=|PERM_|CHECK_FAILURES=|BLOCKED)' "$TMPD/fixed.log"
say "FIXED_RC=$RUN_RC"
if [ "$RUN_RC" -ne 0 ]; then FAIL=1; fi
grep -qxF "REV_PARSE_HEAD=$BASE" "$TMPD/fixed.log" || { say "FIXED_HEAD_MISMATCH"; FAIL=1; }

say "GITMETA_CHECK_FAILURES=$FAIL"
[ "$FAIL" -eq 0 ] && say GITMETA_CHECK_OK
exit "$FAIL"
