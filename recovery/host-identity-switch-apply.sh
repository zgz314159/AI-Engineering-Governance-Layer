#!/usr/bin/env bash
# host-identity-switch-apply.sh — SWITCH pack only (separate from prepare).
#
#   git -C "$AEGL" show "$TIP:recovery/host-identity-switch-apply.sh" \
#     | sudo bash -s -- --commit "$TIP"
#
# Requires: prepare-pack stamp, broker-verified, cleared deps removed,
# tip ancestor of refs/heads/main, SCRIPT_CACHE present.
# Does NOT re-run switch-preflight.
set -euo pipefail

COMMIT=""; AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) printf 'STOP_AT=bad_option\nSWITCH_ERROR: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'SWITCH_ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$COMMIT" ] || stop need_commit "--commit required"
[ "${#COMMIT}" -eq 40 ] || stop bad_sha "40-hex required"
git -C "$AEGL" cat-file -e "$COMMIT^{commit}" 2>/dev/null || stop commit_missing "$COMMIT"

boot(){
  git -C "$AEGL" show "$COMMIT:recovery/host-identity-bootstrap.sh" \
    | bash -s -- --commit "$COMMIT" --aegl "$AEGL" "$@"
}

say "HOST_IDENTITY_SWITCH_APPLY begin commit=$COMMIT"

if [ "$DRY_RUN" = 1 ]; then
  boot plan
  say "SWITCH_DRY_RUN=OK"
  exit 0
fi

[ "$(id -u)" = 0 ] || stop need_root "switch-apply requires root"

# Refuse if tip not promoted.
git -C "$AEGL" merge-base --is-ancestor "$COMMIT" refs/heads/main \
  || stop tip_not_promoted "$COMMIT not on refs/heads/main — promote before switch-apply"

STAMP="/var/lib/aegl/host-identity/preflight-${COMMIT}.ok"
[ -f "$STAMP" ] || stop need_prepare_stamp "missing $STAMP — run prepare pack first (do not re-run preflight here)"

say "== S1 switch (--skip-preflight; uses stamp + SCRIPT_CACHE) =="
boot --skip-preflight switch

say "== S2 verify =="
boot verify

say "HOST_IDENTITY_SWITCH_APPLY_RESULT=OK"
say "PARENT_RENAME_PROTECTION=PACK_IN_TIP_NOT_INSTALLED"
say "AI_BOUNDARY=BLOCKED until parent rename addressed separately"
say "STOP_AT=complete"
