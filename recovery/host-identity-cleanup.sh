#!/usr/bin/env bash
# host-identity-cleanup.sh — CLEANUP pack: delete only DELETE_CLEARED node_modules.
#
#   git -C "$AEGL" show "$TIP:recovery/host-identity-cleanup.sh" \
#     | sudo bash -s -- --commit "$TIP" --apply
#
# Without --apply: print cleared paths only.
# Does NOT run preflight/switch/promote. No backups. No old-path symlinks.
set -euo pipefail

COMMIT=""; AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) printf 'STOP_AT=bad_option\nCLEANUP_ERROR: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'CLEANUP_ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$COMMIT" ] || stop need_commit "--commit required"
[ "${#COMMIT}" -eq 40 ] || stop bad_sha "40-hex required"

# Resolve cleared paths via bootstrap cleanup-plan (no delete).
mapfile -t LINES < <(
  git -C "$AEGL" show "$COMMIT:recovery/host-identity-bootstrap.sh" \
    | bash -s -- --commit "$COMMIT" --aegl "$AEGL" cleanup-plan 2>/dev/null \
    | grep '^CLEANUP_RM=' || true
)

if [ "${#LINES[@]}" -eq 0 ]; then
  stop cleanup_none "no CLEANUP_RM lines (ownership not cleared)"
fi

say "HOST_IDENTITY_CLEANUP begin apply=$APPLY"
for line in "${LINES[@]}"; do
  path="${line#CLEANUP_RM=}"
  # path may be shell-quoted
  eval "p=$path"
  say "  TARGET=$p"
  if [ "$APPLY" = 1 ]; then
    [ "$(id -u)" = 0 ] || stop need_root "--apply requires root"
    [ -e "$p" ] || { say "  skip absent"; continue; }
    # Exact path gate: must be one of the two known FREEZE leaves.
    case "$p" in
      /home/zhong/Projects/AI-Engineering-Governance-Layer/upstream/rulesync/node_modules|\
      /home/zhong/Projects/AI-Engineering-Governance-Layer/fixture/.specify/extensions/architecture-guard/node_modules)
        rm -rf -- "$p"
        say "  REMOVED=$p"
        ;;
      *) stop cleanup_path_refuse "refusing path outside allowlist: $p" ;;
    esac
  fi
done

if [ "$APPLY" = 1 ]; then
  say "HOST_IDENTITY_CLEANUP_RESULT=OK applied=1"
else
  say "HOST_IDENTITY_CLEANUP_RESULT=OK applied=0 (pass --apply to delete)"
fi
say "STOP_AT=complete"
