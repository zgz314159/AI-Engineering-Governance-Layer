#!/usr/bin/env bash
# host-identity-prepare.sh — PREPARE pack only (not chained to switch).
#
#   git -C "$AEGL" show "$TIP:recovery/host-identity-prepare.sh" \
#     | sudo bash -s -- --commit "$TIP"
#
# Runs once: materialize → switch-preflight (stamp) → broker-bind
# → deps-wire (reuse stage) → prepare accounts.
# Does NOT delete node_modules, does NOT switch permissions, does NOT push.
set -euo pipefail

COMMIT=""; AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
WRITE_MARKER=0; DRY_RUN=0
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --write-marker) WRITE_MARKER=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --pnpm|--node|--pnpm-store|--deps-stage|--operator-home)
      EXTRA+=("$1" "${2:-}"); shift 2 ;;
    --force-deps-reinstall) EXTRA+=("$1"); shift ;;
    *) printf 'STOP_AT=bad_option\nPREPARE_ERROR: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'PREPARE_ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$COMMIT" ] || stop need_commit "--commit <40-hex> required"
[ "${#COMMIT}" -eq 40 ] || stop bad_sha "commit must be 40-hex"
git -C "$AEGL" cat-file -e "$COMMIT^{commit}" 2>/dev/null || stop commit_missing "$COMMIT"

boot(){
  git -C "$AEGL" show "$COMMIT:recovery/host-identity-bootstrap.sh" \
    | bash -s -- --commit "$COMMIT" --aegl "$AEGL" "${EXTRA[@]}" "$@"
}

say "HOST_IDENTITY_PREPARE begin commit=$COMMIT"

if [ "$DRY_RUN" = 1 ]; then
  boot plan
  say "PREPARE_DRY_RUN=OK"
  exit 0
fi

[ "$(id -u)" = 0 ] || stop need_root "prepare pack requires root"

say "== P0 materialize fixed-SHA scripts =="
boot materialize

say "== P1 switch-preflight once (writes stamp; switch pack must not re-run) =="
boot switch-preflight

say "== P2 broker-bind (registry evidence) =="
if [ "$WRITE_MARKER" = 1 ]; then
  boot broker-bind --write-marker
else
  boot broker-bind
fi

say "== P3 deps-wire (reuse stage; operator pnpm/node/store) =="
boot --reuse-deps deps-wire

say "== P4 prepare accounts =="
boot prepare

say "HOST_IDENTITY_PREPARE_RESULT=OK"
say "NEXT_SEPARATE=1) cleanup pack  2) promote this tip to main  3) switch-apply pack"
say "STOP_AT=complete"
