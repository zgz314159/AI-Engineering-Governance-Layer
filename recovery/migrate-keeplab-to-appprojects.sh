#!/usr/bin/env bash
# migrate-keeplab-to-appprojects.sh — trusted-terminal KeepLab directory move.
#
# Delivery: git show <FULL_SHA>:recovery/migrate-keeplab-to-appprojects.sh | bash -s
# No sudo required for the directory move (operator-owned trees). Broker unit sync
# is optional via --sync-broker and DOES require root (re-runs install-broker from
# the same --aegl-commit).
#
# Same-filesystem: rename (mv). Cross-filesystem: STOP (never copy+delete).
# On any failure: print STOP_AT=… and exit non-zero. No retries. No backups,
# Trash, archives, or placeholder symlinks at the old path.
set -uo pipefail

SRC="/home/zhong/Projects/KeepLab-Relay"
DST="/home/zhong/AppProjects/KeepLab-Relay"
APP_PARENT="/home/zhong/AppProjects"
PROJECTS_ROOT="/home/zhong/Projects"
AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
AEGL_COMMIT=""
SYNC_BROKER=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:-}"; shift 2 ;;
    --dst) DST="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --aegl-commit) AEGL_COMMIT="${2:-}"; shift 2 ;;
    --sync-broker) SYNC_BROKER=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) printf 'MIGRATE_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'MIGRATE_ERROR: %s\n' "$*" >&2; exit 1; }

say "KEEPLAB_MIGRATE begin src=$SRC dst=$DST dry_run=$DRY_RUN sync_broker=$SYNC_BROKER"

# --- preconditions (fail closed) ------------------------------------------- #
[ -d "$SRC" ] || stop precheck_src_missing "source missing: $SRC"
[ -e "$DST" ] && stop precheck_dst_exists "destination already exists (refuse overwrite/merge): $DST"
[ -L "$SRC" ] && stop precheck_src_symlink "source is a symlink: $SRC"
[ -d "$SRC/.git" ] || [ -f "$SRC/.git" ] || stop precheck_src_not_git "source is not a git checkout: $SRC"

APP_PARENT="$(dirname "$DST")"
if [ -e "$APP_PARENT" ]; then
  [ -d "$APP_PARENT" ] || stop precheck_parent_not_dir "AppProjects parent is not a directory: $APP_PARENT"
  [ -L "$APP_PARENT" ] && stop precheck_parent_symlink "AppProjects parent is a symlink: $APP_PARENT"
fi

src_dev="$(stat -c '%d' "$SRC")"
parent_for_dev="$APP_PARENT"
[ -d "$parent_for_dev" ] || parent_for_dev="$(dirname "$APP_PARENT")"
dst_dev="$(stat -c '%d' "$parent_for_dev")"
[ "$src_dev" = "$dst_dev" ] || stop precheck_cross_filesystem \
  "cross-filesystem move refused (src_dev=$src_dev dst_parent_dev=$dst_dev); report only — no copy+delete"

# Active AEGL tasks bound to this KeepLab tree (exact project or worktree under SRC)
ACTIVE_TASKS=()
TASKS_ROOT="${AEGL_TASKS_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/aegl/tasks}"
SRC_REAL="$(realpath "$SRC")"
if [ -d "$TASKS_ROOT" ]; then
  while IFS= read -r meta; do
    [ -f "$meta" ] || continue
    eval "$(python3 - "$meta" "$SRC_REAL" <<'PY'
import json, os, sys
meta, src = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(meta))
except Exception:
    raise SystemExit(0)
proj = os.path.realpath(d["project"]) if d.get("project") else ""
wt = os.path.realpath(d["worktree"]) if d.get("worktree") else ""
hit = proj == src or (wt and (wt == src or wt.startswith(src + os.sep)))
if hit:
    print("hit=1")
    print("proj=%s" % proj)
    print("wt=%s" % wt)
PY
)"
    [ "${hit:-0}" = 1 ] && ACTIVE_TASKS+=("$meta project=${proj:-?} worktree=${wt:-?}")
    unset hit proj wt
  done < <(find "$TASKS_ROOT" -maxdepth 2 -name task.json 2>/dev/null)
fi
if [ "${#ACTIVE_TASKS[@]}" -gt 0 ]; then
  say "ACTIVE_KEEPLAB_TASKS:"
  printf '  %s\n' "${ACTIVE_TASKS[@]}"
  stop precheck_active_keeplab_tasks \
    "stop those KeepLab task(s) first (discard/finish); Chrome/Bridge/Supervisor untouched"
fi

# Extra worktrees attached to KeepLab
WT_LINES="$(git -C "$SRC" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')"
WT_COUNT="$(printf '%s\n' "$WT_LINES" | grep -c . || true)"
if [ "${WT_COUNT:-0}" -gt 1 ]; then
  say "KEEPLAB_WORKTREES:"
  printf '  %s\n' "$WT_LINES"
  stop precheck_extra_worktrees "remove/finish extra KeepLab worktrees before move"
fi

PRE_HEAD="$(git -C "$SRC" rev-parse HEAD)"
PRE_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
PRE_PORCELAIN="$(git -C "$SRC" status --porcelain)"
say "PRE_HEAD=$PRE_HEAD"
say "PRE_BRANCH=$PRE_BRANCH"
say "PRE_PORCELAIN_BYTES=${#PRE_PORCELAIN}"

if [ "$DRY_RUN" = 1 ]; then
  say "DRY_RUN=1 — would mkdir -p $APP_PARENT && mv $SRC $DST"
  say "STOP_AT=dry_run_ok"
  exit 0
fi

# --- move ------------------------------------------------------------------ #
mkdir -p "$APP_PARENT" || stop mkdir_appprojects "mkdir failed: $APP_PARENT"
[ -e "$DST" ] && stop race_dst_exists "destination appeared before mv: $DST"
mv "$SRC" "$DST" || stop mv_failed "mv failed: $SRC -> $DST"
[ -e "$SRC" ] && stop old_path_still_present "old path still exists after mv (no symlink/backup allowed): $SRC"
[ -d "$DST" ] || stop dst_missing_after_mv "destination missing after mv: $DST"

POST_HEAD="$(git -C "$DST" rev-parse HEAD)"
POST_BRANCH="$(git -C "$DST" rev-parse --abbrev-ref HEAD)"
POST_PORCELAIN="$(git -C "$DST" status --porcelain)"
[ "$POST_HEAD" = "$PRE_HEAD" ] || stop git_head_mismatch "HEAD changed: pre=$PRE_HEAD post=$POST_HEAD"
[ "$POST_BRANCH" = "$PRE_BRANCH" ] || stop git_branch_mismatch "branch changed: pre=$PRE_BRANCH post=$POST_BRANCH"
[ "$POST_PORCELAIN" = "$PRE_PORCELAIN" ] || stop git_porcelain_mismatch "working tree status changed across move"

say "POST_HEAD=$POST_HEAD"
say "POST_BRANCH=$POST_BRANCH"
say "GIT_PRESERVED=yes"

# --- optional broker unit sync (root) -------------------------------------- #
if [ "$SYNC_BROKER" = 1 ]; then
  [ "$(id -u)" = 0 ] || stop sync_broker_need_root "--sync-broker requires root"
  [ -n "$AEGL_COMMIT" ] || stop sync_broker_need_commit "--aegl-commit required with --sync-broker"
  [ -d "$AEGL/.git" ] || stop sync_broker_aegl_missing "AEGL repo missing: $AEGL"
  say "SYNC_BROKER: install-broker from commit=$AEGL_COMMIT business_root=$APP_PARENT"
  git -C "$AEGL" show "$AEGL_COMMIT:recovery/install-broker.sh" \
    | bash -s -- --repo "$AEGL" --projects-root "$PROJECTS_ROOT" \
         --business-root "$APP_PARENT" --commit "$AEGL_COMMIT" \
    || stop sync_broker_install_failed "install-broker failed"
  # Confirm unit carries business root
  grep -q "AEGL_BUSINESS_ROOT=$APP_PARENT" /etc/systemd/system/aegl-promote-broker.service \
    || stop sync_broker_unit_missing_business_root "unit missing AEGL_BUSINESS_ROOT=$APP_PARENT"
fi

# --- post checks (migrate-related only) ------------------------------------ #
git -C "$DST" rev-parse --is-inside-work-tree >/dev/null \
  || stop post_git_inaccessible "git not accessible at $DST"
[ ! -e "$SRC" ] || stop post_old_path_present "old path still present: $SRC"

say "MIGRATE_RESULT=OK"
say "STOP_AT=complete"
say "NEW_PATH=$DST"
say "OLD_PATH_GONE=$SRC"
