#!/usr/bin/env bash
# migrate-keeplab-to-appprojects.sh — trusted-terminal KeepLab directory move.
#
# Delivery: git show <FULL_SHA>:recovery/migrate-keeplab-to-appprojects.sh | bash -s -- …
#
# Phases:
#   precheck     — fail-closed gates (no move). Default with --dry-run.
#   move         — mkdir AppProjects + mv (requires SRC present).
#   post         — verify DST; optional broker unit sync. SRC may be gone.
#   all          — precheck → move → post (default).
#   resume-post  — after a successful move when a later step failed: post only.
#
# Same-filesystem: rename (mv). Cross-filesystem: STOP (never copy+delete).
# On any failure: print STOP_AT=… and exit non-zero. No retries. No backups,
# Trash, archives, or placeholder symlinks at the old path.
set -uo pipefail

SRC="/home/zhong/Projects/KeepLab-Relay"
DST="/home/zhong/AppProjects/KeepLab-Relay"
PROJECTS_ROOT="/home/zhong/Projects"
AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
STACK="/home/zhong/Projects/Google-Android-Agent-Development-Stack"
AEGL_COMMIT=""
SYNC_BROKER=0
DRY_RUN=0
PHASE="all"
REQUIRE_PATCHES=1

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:-}"; shift 2 ;;
    --dst) DST="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --stack) STACK="${2:-}"; shift 2 ;;
    --projects-root) PROJECTS_ROOT="${2:-}"; shift 2 ;;
    --aegl-commit) AEGL_COMMIT="${2:-}"; shift 2 ;;
    --sync-broker) SYNC_BROKER=1; shift ;;
    --dry-run) DRY_RUN=1; PHASE="precheck"; REQUIRE_PATCHES=0; shift ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    --resume-post) PHASE="resume-post"; shift ;;
    --no-require-patches) REQUIRE_PATCHES=0; shift ;;
    *) printf 'MIGRATE_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$PHASE" in
  precheck|move|post|all|resume-post) ;;
  *) printf 'MIGRATE_ERROR: invalid --phase %s\n' "$PHASE" >&2; exit 2 ;;
esac
[ "$PHASE" = resume-post ] && PHASE=post

say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'MIGRATE_ERROR: %s\n' "$*" >&2; exit 1; }

APP_PARENT="$(dirname "$DST")"

# Operator path contract (zhong). Never use sudo/root HOME for task discovery.
OPERATOR_USER="${SUDO_USER:-zhong}"
[ "$OPERATOR_USER" = root ] && OPERATOR_USER=zhong
OPERATOR_HOME="$(getent passwd "$OPERATOR_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$OPERATOR_HOME" ] || OPERATOR_HOME="/home/zhong"

resolve_tasks_root() {
  # Mirrors aegl-task: AEGL_TASKS_ROOT → AEGL_STATE_HOME/tasks → <state>/aegl/tasks
  # but the default state home is the operator's, not sudo's HOME/XDG.
  if [ -n "${AEGL_TASKS_ROOT:-}" ]; then
    printf '%s' "$AEGL_TASKS_ROOT"
  elif [ -n "${AEGL_STATE_HOME:-}" ]; then
    printf '%s' "$AEGL_STATE_HOME/tasks"
  else
    printf '%s' "$OPERATOR_HOME/.local/state/aegl/tasks"
  fi
}

say "KEEPLAB_MIGRATE begin phase=$PHASE src=$SRC dst=$DST dry_run=$DRY_RUN sync_broker=$SYNC_BROKER"
say "OPERATOR_USER=$OPERATOR_USER OPERATOR_HOME=$OPERATOR_HOME"

# Project-code checks (doctor / imports) always as operator — never root.
as_operator() {
  if [ "$(id -u)" = 0 ]; then
    runuser -u "$OPERATOR_USER" -- "$@"
  else
    "$@"
  fi
}

# --------------------------------------------------------------------------- #
# precheck helpers
# --------------------------------------------------------------------------- #
scan_keeplab_tasks() {
  # Data-only JSON parse. Never eval shell from task.json. Paths may contain
  # spaces or metacharacters. Unreadable/unparseable metadata → hard stop.
  local tasks_root="$1" src_real="$2"
  TASK_SCAN_JSON="$(python3 - "$tasks_root" "$src_real" <<'PY'
import json, os, sys

tasks_root, src = sys.argv[1], sys.argv[2]
out = {"tasks_root": tasks_root, "errors": [], "hits": []}

if not os.path.isdir(tasks_root):
    out["tasks_root_missing"] = True
    json.dump(out, sys.stdout, sort_keys=True)
    sys.exit(0)

for dirpath, dirnames, filenames in os.walk(tasks_root):
    # only task.json at depth <= 2 under tasks_root
    rel = os.path.relpath(dirpath, tasks_root)
    depth = 0 if rel == "." else rel.count(os.sep) + 1
    if depth > 2:
        dirnames[:] = []
        continue
    if "task.json" not in filenames:
        continue
    meta = os.path.join(dirpath, "task.json")
    try:
        with open(meta, encoding="utf-8") as fh:
            data = json.load(fh)
    except OSError as exc:
        out["errors"].append({"path": meta, "reason": "unreadable:%s" % exc})
        continue
    except json.JSONDecodeError as exc:
        out["errors"].append({"path": meta, "reason": "json_decode:%s" % exc})
        continue
    if not isinstance(data, dict):
        out["errors"].append({"path": meta, "reason": "not_a_json_object"})
        continue
    proj_raw = data.get("project")
    wt_raw = data.get("worktree")
    try:
        proj = os.path.realpath(proj_raw) if isinstance(proj_raw, str) and proj_raw else ""
        wt = os.path.realpath(wt_raw) if isinstance(wt_raw, str) and wt_raw else ""
    except OSError as exc:
        out["errors"].append({"path": meta, "reason": "path_resolve:%s" % exc})
        continue
    hit = bool(proj == src or (wt and (wt == src or wt.startswith(src + os.sep))))
    if hit:
        out["hits"].append({
            "path": meta,
            "id": data.get("id"),
            "project": proj_raw,
            "worktree": wt_raw,
        })

json.dump(out, sys.stdout, sort_keys=True)
sys.exit(0)
PY
)" || stop precheck_task_scan_failed "task scan python failed"
  python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(2 if d.get("errors") else 1 if d.get("hits") else 0)' <<<"$TASK_SCAN_JSON"
  return $?
}

check_formal_patches() {
  # Isolation-branch commits are NOT live until formal tips + installed broker carry them.
  say "== patch liveness (formal entries / installed broker / live guard) =="
  local aegl_main stack_master
  aegl_main="$(git -C "$AEGL" rev-parse refs/heads/main 2>/dev/null)" \
    || stop precheck_aegl_main_missing "AEGL refs/heads/main missing"
  stack_master="$(git -C "$STACK" rev-parse refs/heads/master 2>/dev/null)" \
    || stop precheck_stack_master_missing "Stack refs/heads/master missing"
  say "AEGL_MAIN=$aegl_main"
  say "STACK_MASTER=$stack_master"

  # Formal AEGL tree must expose business_root (bin/aegl-task is the formal entry).
  grep -q 'BUSINESS_ROOT\|AEGL_BUSINESS_ROOT' "$AEGL/bin/aegl-task" \
    || stop precheck_aegl_task_unpatched \
      "formal AEGL bin/aegl-task lacks business-root resolve (promote path tip to main first)"
  grep -q 'business_root' "$AEGL/recovery/promotion_core.py" \
    || stop precheck_aegl_core_unpatched \
      "formal AEGL recovery/promotion_core.py lacks business_root (promote path tip to main first)"
  # Installed broker copy (runtime) — not the isolation worktree.
  if [ -f /usr/local/lib/aegl-promote/promotion_core.py ]; then
    grep -q 'business_root' /usr/local/lib/aegl-promote/promotion_core.py \
      || stop precheck_installed_broker_unpatched \
        "installed /usr/local/lib/aegl-promote lacks business_root (install-broker from promoted tip)"
  else
    stop precheck_installed_broker_missing "installed broker lib missing: /usr/local/lib/aegl-promote"
  fi
  if [ -f /etc/systemd/system/aegl-promote-broker.service ]; then
    grep -q 'AEGL_BUSINESS_ROOT=' /etc/systemd/system/aegl-promote-broker.service \
      || stop precheck_broker_unit_no_business_root \
        "broker unit missing AEGL_BUSINESS_ROOT (reinstall-broker with --business-root)"
  else
    stop precheck_broker_unit_missing "broker unit missing"
  fi

  # Live Hermes guard is the formal Stack file (not an installed copy).
  local guard="$STACK/orchestration/hermes/evaluation_adapter/contract_guard.py"
  [ -f "$guard" ] || stop precheck_guard_missing "live guard missing: $guard"
  grep -q '_resolve_keeplab_root\|_project_rel\|AEGL_BUSINESS_ROOT' "$guard" \
    || stop precheck_stack_guard_unpatched \
      "formal Stack contract_guard lacks KeepLab business-root resolve (promote Stack tip to master first)"
  say "LIVE_GUARD=$guard"
  say "PATCH_LIVENESS=OK"
}

check_active_keeplab_entries() {
  # Narrow checks of known KeepLab-referencing runtime entries — not a host-wide scan.
  say "== active KeepLab-referencing entries (narrow) =="
  local hermes_cfg="$OPERATOR_HOME/.hermes/profiles/android-stack/config.yaml"
  if [ -f "$hermes_cfg" ]; then
    if grep -n 'KeepLab-Relay\|contract_guard' "$hermes_cfg" >/dev/null 2>&1; then
      say "HERMES_PROFILE=$hermes_cfg"
      grep -n 'contract_guard\|KeepLab-Relay' "$hermes_cfg" | head -20 || true
    fi
  else
    say "HERMES_PROFILE=absent ($hermes_cfg)"
  fi
  # Formal recovery doctor as operator (HOME/XDG); never root importing recovery entry.
  if [ -x "$AEGL/bin/aegl-recovery" ]; then
    local kr
    kr="$(as_operator env PROJECTS_ROOT="$PROJECTS_ROOT" AEGL_BUSINESS_ROOT="$APP_PARENT" \
      HOME="$OPERATOR_HOME" \
      "$AEGL/bin/aegl-recovery" doctor 2>/dev/null | grep '^keeplab=' || true)"
    say "AEGL_RECOVERY_KEEPLAB=${kr:-unresolved}"
  fi
}

phase_precheck() {
  say "== phase precheck =="
  if [ "$PHASE" != post ] && [ ! -d "$SRC" ] && [ -d "$DST" ]; then
    stop precheck_already_moved \
      "SRC absent and DST present — use --phase post|--resume-post (do not re-run move)"
  fi
  [ -d "$SRC" ] || stop precheck_src_missing "source missing: $SRC"
  [ -e "$DST" ] && stop precheck_dst_exists "destination already exists (refuse overwrite/merge): $DST"
  [ -L "$SRC" ] && stop precheck_src_symlink "source is a symlink: $SRC"
  [ -d "$SRC/.git" ] || [ -f "$SRC/.git" ] || stop precheck_src_not_git "source is not a git checkout: $SRC"

  if [ -e "$APP_PARENT" ]; then
    [ -d "$APP_PARENT" ] || stop precheck_parent_not_dir "AppProjects parent is not a directory: $APP_PARENT"
    [ -L "$APP_PARENT" ] && stop precheck_parent_symlink "AppProjects parent is a symlink: $APP_PARENT"
  fi

  local src_dev parent_for_dev dst_dev
  src_dev="$(stat -c '%d' "$SRC")"
  parent_for_dev="$APP_PARENT"
  [ -d "$parent_for_dev" ] || parent_for_dev="$(dirname "$APP_PARENT")"
  dst_dev="$(stat -c '%d' "$parent_for_dev")"
  [ "$src_dev" = "$dst_dev" ] || stop precheck_cross_filesystem \
    "cross-filesystem move refused (src_dev=$src_dev dst_parent_dev=$dst_dev); report only — no copy+delete"

  local tasks_root src_real scan_rc
  tasks_root="$(resolve_tasks_root)"
  src_real="$(realpath "$SRC")"
  say "TASKS_ROOT=$tasks_root (operator path contract; not sudo HOME)"
  scan_rc=0
  scan_keeplab_tasks "$tasks_root" "$src_real" || scan_rc=$?
  say "TASK_SCAN=$TASK_SCAN_JSON"
  if [ "$scan_rc" = 2 ]; then
    stop precheck_task_metadata_error \
      "task.json unreadable or unparseable under $tasks_root — fix or remove bad metadata (not treated as idle)"
  fi
  if [ "$scan_rc" = 1 ]; then
    stop precheck_active_keeplab_tasks \
      "KeepLab-bound AEGL task(s) present — discard/finish those only; Chrome/Bridge/Supervisor untouched"
  fi

  local wt_lines wt_count
  wt_lines="$(git -C "$SRC" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')"
  wt_count="$(printf '%s\n' "$wt_lines" | grep -c . || true)"
  if [ "${wt_count:-0}" -gt 1 ]; then
    say "KEEPLAB_WORKTREES:"
    printf '  %s\n' "$wt_lines"
    stop precheck_extra_worktrees "remove/finish extra KeepLab worktrees before move"
  fi

  PRE_HEAD="$(git -C "$SRC" rev-parse HEAD)"
  PRE_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
  PRE_PORCELAIN="$(git -C "$SRC" status --porcelain)"
  say "PRE_HEAD=$PRE_HEAD"
  say "PRE_BRANCH=$PRE_BRANCH"
  say "PRE_PORCELAIN_BYTES=${#PRE_PORCELAIN}"

  check_active_keeplab_entries
  if [ "$REQUIRE_PATCHES" = 1 ]; then
    check_formal_patches
  else
    say "PATCH_LIVENESS=SKIPPED (--no-require-patches)"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    say "DRY_RUN=1 — would mkdir -p $APP_PARENT && mv $SRC $DST"
    say "STOP_AT=dry_run_ok"
    exit 0
  fi
  say "PRECHECK_OK=1"
}

phase_move() {
  say "== phase move =="
  [ -d "$SRC" ] || stop move_src_missing \
    "source missing: $SRC — if already moved, use --phase post|--resume-post"
  [ -e "$DST" ] && stop move_dst_exists "destination already exists: $DST"
  mkdir -p "$APP_PARENT" || stop mkdir_appprojects "mkdir failed: $APP_PARENT"
  [ -e "$DST" ] && stop race_dst_exists "destination appeared before mv: $DST"
  mv "$SRC" "$DST" || stop mv_failed "mv failed: $SRC -> $DST"
  [ -e "$SRC" ] && stop old_path_still_present "old path still exists after mv: $SRC"
  [ -d "$DST" ] || stop dst_missing_after_mv "destination missing after mv: $DST"

  POST_HEAD="$(git -C "$DST" rev-parse HEAD)"
  POST_BRANCH="$(git -C "$DST" rev-parse --abbrev-ref HEAD)"
  POST_PORCELAIN="$(git -C "$DST" status --porcelain)"
  [ -n "${PRE_HEAD:-}" ] || PRE_HEAD="$POST_HEAD"
  [ -n "${PRE_BRANCH:-}" ] || PRE_BRANCH="$POST_BRANCH"
  [ "${PRE_PORCELAIN+x}" = x ] || PRE_PORCELAIN="$POST_PORCELAIN"
  [ "$POST_HEAD" = "$PRE_HEAD" ] || stop git_head_mismatch "HEAD changed: pre=$PRE_HEAD post=$POST_HEAD"
  [ "$POST_BRANCH" = "$PRE_BRANCH" ] || stop git_branch_mismatch "branch changed: pre=$PRE_BRANCH post=$POST_BRANCH"
  [ "$POST_PORCELAIN" = "$PRE_PORCELAIN" ] || stop git_porcelain_mismatch "working tree status changed across move"
  say "POST_HEAD=$POST_HEAD"
  say "POST_BRANCH=$POST_BRANCH"
  say "GIT_PRESERVED=yes"
  say "MOVE_OK=1"
}

phase_post() {
  say "== phase post (SRC may be absent) =="
  [ -d "$DST" ] || stop post_dst_missing "destination missing: $DST"
  [ -e "$SRC" ] && stop post_old_path_present "old path still present: $SRC"
  git -C "$DST" rev-parse --is-inside-work-tree >/dev/null \
    || stop post_git_inaccessible "git not accessible at $DST"
  say "POST_HEAD=$(git -C "$DST" rev-parse HEAD)"
  say "POST_BRANCH=$(git -C "$DST" rev-parse --abbrev-ref HEAD)"

  if [ "$SYNC_BROKER" = 1 ]; then
    [ "$(id -u)" = 0 ] || stop sync_broker_need_root "--sync-broker requires root"
    [ -n "$AEGL_COMMIT" ] || stop sync_broker_need_commit "--aegl-commit required with --sync-broker"
    [ -d "$AEGL/.git" ] || stop sync_broker_aegl_missing "AEGL repo missing: $AEGL"
    say "SYNC_BROKER: install-broker commit=$AEGL_COMMIT business_root=$APP_PARENT"
    git -C "$AEGL" show "$AEGL_COMMIT:recovery/install-broker.sh" \
      | bash -s -- --repo "$AEGL" --projects-root "$PROJECTS_ROOT" \
           --business-root "$APP_PARENT" --commit "$AEGL_COMMIT" \
      || stop sync_broker_install_failed "install-broker failed"
    grep -q "AEGL_BUSINESS_ROOT=$APP_PARENT" /etc/systemd/system/aegl-promote-broker.service \
      || stop sync_broker_unit_missing_business_root "unit missing AEGL_BUSINESS_ROOT=$APP_PARENT"
  fi

  if [ "$REQUIRE_PATCHES" = 1 ]; then
    # Formal entries must resolve the new path (patches required pre-move).
    if [ -x "$AEGL/bin/aegl-task" ]; then
      local resolved
      resolved="$(PROJECTS_ROOT="$PROJECTS_ROOT" AEGL_BUSINESS_ROOT="$APP_PARENT" \
        bash -c '
          PROJECTS_ROOT="$0"; BUSINESS_ROOT="$1"
          if [ -d "$BUSINESS_ROOT/KeepLab-Relay" ]; then printf %s "$BUSINESS_ROOT/KeepLab-Relay"
          elif [ -d "$PROJECTS_ROOT/KeepLab-Relay" ]; then printf %s "$PROJECTS_ROOT/KeepLab-Relay"
          else printf %s FAIL; fi
        ' "$PROJECTS_ROOT" "$APP_PARENT")"
      [ "$resolved" = "$DST" ] || stop post_task_resolve_mismatch "aegl-task resolve got $resolved want $DST"
      say "TASK_RESOLVE_OK=$resolved"
    fi
    if [ -x "$AEGL/bin/aegl-recovery" ]; then
      local kr
      kr="$(as_operator env PROJECTS_ROOT="$PROJECTS_ROOT" AEGL_BUSINESS_ROOT="$APP_PARENT" \
        HOME="$OPERATOR_HOME" \
        "$AEGL/bin/aegl-recovery" doctor 2>/dev/null | grep '^keeplab=' || true)"
      say "RECOVERY_KEEPLAB=$kr"
      printf '%s\n' "$kr" | grep -q "keeplab=$DST" \
        || stop post_recovery_keeplab_mismatch "aegl-recovery doctor keeplab != $DST ($kr)"
    fi
    local guard="$STACK/orchestration/hermes/evaluation_adapter/contract_guard.py"
    as_operator env PROJECTS_ROOT="$PROJECTS_ROOT" AEGL_BUSINESS_ROOT="$APP_PARENT" \
      python3 - "$guard" "$DST" "$APP_PARENT" "$PROJECTS_ROOT" <<'PY' \
      || stop post_guard_source_root "contract_guard source_root/package check failed"
import importlib.util, os, sys
guard_path, keeplab, business, projects = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("contract_guard", guard_path)
mod = importlib.util.module_from_spec(spec)
os.environ["AEGL_BUSINESS_ROOT"] = business
os.environ["PROJECTS_ROOT"] = projects
spec.loader.exec_module(mod)
pkg = mod.DEFAULT_PACKAGE
assert os.path.isdir(pkg), pkg
kreal = os.path.realpath(keeplab)
assert os.path.realpath(pkg).startswith(kreal + os.sep), pkg
loaded = mod.load_contract(pkg)
root = loaded["source_root"]
assert not (isinstance(root, str) and ("$" in root or "`" in root)), root
print("GUARD_PACKAGE=%s" % pkg)
print("GUARD_SOURCE_ROOT=%s" % root)
PY
  else
    say "POST_FORMAL_ENTRY_CHECKS=SKIPPED (--no-require-patches)"
  fi

  say "MIGRATE_RESULT=OK"
  say "STOP_AT=complete"
  say "NEW_PATH=$DST"
  say "OLD_PATH_GONE=$SRC"
}

# --------------------------------------------------------------------------- #
# dispatch
# --------------------------------------------------------------------------- #
case "$PHASE" in
  precheck)
    phase_precheck
    say "STOP_AT=precheck_ok"
    ;;
  move)
    phase_precheck
    phase_move
    say "STOP_AT=move_ok"
    say "RESUME=git show <TIP>:recovery/migrate-keeplab-to-appprojects.sh | sudo bash -s -- --phase post --aegl-commit <TIP> --sync-broker"
    ;;
  post)
    # post/resume: do not require SRC. Keep REQUIRE_PATCHES as caller set
    # (exec pack leaves it 1; throwaway tests pass --no-require-patches).
    phase_post
    ;;
  all)
    phase_precheck
    phase_move
    phase_post
    ;;
esac
