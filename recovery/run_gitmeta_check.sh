#!/usr/bin/env bash
# run_check.sh — no-model Git-metadata verification for one task worktree.
# Root only. Runs from a root-exclusive, manifest-verified copy (see bootstrap.sh).
#   run_check.sh
# baseline is EXPECTED to reproduce the Git-level failure (COMMON_RC=128 / REV_PARSE_RC=128);
# fixed is EXPECTED to reach the same internal check and satisfy HEAD/status/permissions.
# The Git-level rc and the check's aggregate exit code are reported separately. Logs are
# kept and their location printed on failure; on success only this run's known files go.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
LAUNCHER="$LIB/aegl-hermes-sandbox"
CHECK="$HERE/gitmeta.check"
CHECK_SHA="82242ad031db3d5c7705bd5e8ff0f8bec39f57a6e38267f7d51e5876d9e4e076"
TASK="${TASK:-IAP-SMOKE-004}"
WT="${WT:-/var/tmp/IAP-SMOKE-004/project}"
BASE="${EXPECT_BASE:-177680708739a72a0d70bc6a9664245b00a2ef08}"
AI_USER="${AEGL_AI_USER:-aegl-ai}"
AI_HOME="${AEGL_AI_HOME:-/home/aegl-ai}"
SETPRIV=/usr/bin/setpriv
FAIL=0

say() { printf '%s\n' "$*"; }
hide() { printf '%s\n' "$*" | tr '\n' ' ' | head -c 400; }
[ "$(id -u)" -eq 0 ] || { say NOT_ROOT; exit 1; }
for f in "$LAUNCHER" "$CHECK"; do [ -f "$f" ] || { say "MISSING $f"; exit 1; }; done
GOT="$(sha256sum "$CHECK" | awk '{print $1}')"
say "CHECK_PAYLOAD_SHA=$GOT"
[ "$GOT" = "$CHECK_SHA" ] || { say CHECK_PAYLOAD_MISMATCH; exit 1; }
AI_UID="$(id -u "$AI_USER")" || { say "MISSING identity $AI_USER"; exit 1; }
AI_GID="$(id -g "$AI_USER")"
TMPD="$(mktemp -d /root/aegl-gitmeta-check.XXXXXX)"; chmod 0700 "$TMPD"

run_launcher() { # <log> [extra args...] -> RUN_RC
  local log="$1"; shift
  AEGL_MODEL_LIBDIR="$LIB" AEGL_AI_USER="$AI_USER" AEGL_AI_GROUP="$(id -gn "$AI_USER")" \
    /bin/bash "$LAUNCHER" --task "$TASK" --check "$(cat "$CHECK")" "$@" > "$log" 2>&1
  RUN_RC=$?
}
field() { sed -n "s/^$2=//p" "$1" | tail -1; }
show() { grep -aE "$1" "$2" || true; }
PAT='^(check mode|  git metadata|  post-drop entries|    drop_verify=|    exec_spec=|    exec |COMMON=|COMMON_RC=|REV_PARSE_|STATUS_RC=|PERM_|CHECK_FAILURES=|BLOCKED)'

say "=== 0. host, the SAME identity (baseline sanity: MUST pass) ==="
"$SETPRIV" --reuid="$AI_UID" --regid="$AI_GID" --clear-groups --no-new-privs -- \
  env -i PATH=/usr/bin:/bin HOME="$AI_HOME" LANG=C.UTF-8 \
  git -c "safe.directory=$WT" -C "$WT" rev-parse HEAD >"$TMPD/host.out" 2>"$TMPD/host.err"
hrc=$?
say "HOST_HEAD=$(head -c 200 "$TMPD/host.out" | tr -d '\n')"
say "HOST_ERR=$(hide "$(cat "$TMPD/host.err")")"
say "HOST_RC=$hrc"
[ "$hrc" -eq 0 ] || FAIL=1

say "=== 1. pre-fix mount set (expected: reach the internal check and FAIL there) ==="
run_launcher "$TMPD/baseline.log" --check-baseline
show "$PAT" "$TMPD/baseline.log"
say "BASELINE_EXIT=$RUN_RC"
say "BASELINE_GIT_RC=$(field "$TMPD/baseline.log" REV_PARSE_RC)"
say "BASELINE_COMMON_RC=$(field "$TMPD/baseline.log" COMMON_RC)"
if grep -qxF 'REV_PARSE_RC=128' "$TMPD/baseline.log" && grep -qxF 'COMMON_RC=128' "$TMPD/baseline.log"; then
  say "BASELINE_REPRODUCED=YES"
else
  say "BASELINE_NOT_REPRODUCED (the internal Git check was not reached / did not fail as expected)"
  FAIL=1
fi
if [ "$RUN_RC" -eq 0 ]; then say "BASELINE_EXIT_UNEXPECTEDLY_ZERO"; FAIL=1; fi

say "=== 2. fixed mount set (expected: reach the internal check and PASS) ==="
run_launcher "$TMPD/fixed.log"
show "$PAT" "$TMPD/fixed.log"
say "FIXED_EXIT=$RUN_RC"
say "FIXED_GIT_RC=$(field "$TMPD/fixed.log" REV_PARSE_RC)"
say "FIXED_STATUS_RC=$(field "$TMPD/fixed.log" STATUS_RC)"
say "FIXED_CHECK_EXIT=$(field "$TMPD/fixed.log" CHECK_FAILURES)"
ok=1
grep -qxF 'REV_PARSE_RC=0' "$TMPD/fixed.log" || ok=0
grep -qxF "REV_PARSE_HEAD=$BASE" "$TMPD/fixed.log" || ok=0
grep -qxF 'STATUS_RC=0' "$TMPD/fixed.log" || ok=0
grep -qxF 'CHECK_FAILURES=0' "$TMPD/fixed.log" || ok=0
for k in core refs objects config; do
  grep -qxF "PERM_$k writable=False mount_ro=True" "$TMPD/fixed.log" || ok=0
done
[ "$RUN_RC" -eq 0 ] || ok=0
if [ "$ok" -eq 1 ]; then say "FIXED_OK=YES"; else say "FIXED_OK=NO"; FAIL=1; fi

say "GITMETA_CHECK_FAILURES=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  rm -f "$TMPD/host.out" "$TMPD/host.err" "$TMPD/baseline.log" "$TMPD/fixed.log"
  rmdir "$TMPD" 2>/dev/null
  say GITMETA_CHECK_OK
else
  say "GITMETA_CHECK_LOGS_KEPT=$TMPD"
fi
exit "$FAIL"
