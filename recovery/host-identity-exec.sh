#!/usr/bin/env bash
# host-identity-exec.sh — trusted-terminal pack for host identity switch (Plan A).
#
#   git -C "$AEGL" show "$TIP:recovery/host-identity-exec.sh" \
#     | sudo bash -s -- --commit "$TIP"
#
# Order (fail-stop; STOP_AT on error):
#   0  switch-preflight (throwaway cross-UID; before any formal permission change)
#   1  broker-bind (match installed broker to tip; optional --write-marker)
#   2  deps-plan (freeze two node_modules + external rebuild wiring; no delete)
#   3  prepare (accounts/groups; no project chown)
#   4  stop here unless --apply-switch (formal switch is gated and destructive)
#
# Does NOT push, does not Cursor-rules deploy, does not chattr Projects/AppProjects.
set -euo pipefail

COMMIT=""; AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
APPLY_SWITCH=0; WRITE_MARKER=0; DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --apply-switch) APPLY_SWITCH=1; shift ;;
    --write-marker) WRITE_MARKER=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) printf 'STOP_AT=bad_option\nHOST_EXEC_ERROR: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'HOST_EXEC_ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$COMMIT" ] || stop need_commit "--commit <40-hex> required"
case "$COMMIT" in [0-9a-f]*) ;; *) stop bad_sha "commit must be 40-hex" ;; esac
[ "${#COMMIT}" -eq 40 ] || stop bad_sha "commit must be 40-hex"
git -C "$AEGL" cat-file -e "$COMMIT^{commit}" 2>/dev/null || stop commit_missing "$COMMIT"

boot(){
  local mode="$1"; shift
  git -C "$AEGL" show "$COMMIT:recovery/host-identity-bootstrap.sh" \
    | bash -s -- --commit "$COMMIT" --aegl "$AEGL" "$@" "$mode"
}

say "HOST_IDENTITY_EXEC begin commit=$COMMIT dry_run=$DRY_RUN apply_switch=$APPLY_SWITCH"

if [ "$DRY_RUN" = 1 ]; then
  boot plan
  say "DRY_RUN_RESULT=OK"
  say "STOP_AT=dry_run_ok"
  exit 0
fi

[ "$(id -u)" = 0 ] || stop need_root "full host-identity exec requires root"

say "== 0. switch-preflight (throwaway; before formal perms) =="
boot switch-preflight

say "== 1. broker-bind (no reinstall) =="
if [ "$WRITE_MARKER" = 1 ]; then
  boot broker-bind --write-marker
else
  boot broker-bind
fi

say "== 2. deps-plan (no delete) =="
boot deps-plan

say "== 3. prepare =="
boot prepare

if [ "$APPLY_SWITCH" = 1 ]; then
  say "== 4. switch (three formal trees only) =="
  boot switch
  say "== 5. verify =="
  boot verify
  say "HOST_IDENTITY_EXEC_RESULT=OK switched=1"
else
  say "== 4. switch = SKIPPED (pass --apply-switch after deps removed + marker written) =="
  say "HOST_IDENTITY_EXEC_RESULT=OK switched=0"
  say "NEXT=remove frozen node_modules after external rebuild wiring; then re-run with --write-marker --apply-switch"
fi
say "STOP_AT=complete"
