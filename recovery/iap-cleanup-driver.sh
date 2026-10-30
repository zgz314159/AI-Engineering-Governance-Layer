#!/usr/bin/env bash
# iap-cleanup-driver.sh — cleanup-ONLY, precise, resumable finisher for the IAP delivery.
#
# Root only. Never re-runs import/register/record/promote/formal-sync/install, never
# edits the broker/model-task registry, never runs `rm -rf`, `git worktree prune`,
# `--force`, backups or archives, and never relaxes staging/formal-tree permissions.
#
# Git discipline:
#   * every mutating/querying git call goes through run_git / git_probe;
#   * trust is granted per COMMAND and per EXACT resolved repository path
#     (`-c safe.directory=<realpath>`) — never a wildcard, never global config;
#   * a git failure reports the operation, the argv, the exit code and git's own
#     (bounded) stderr, then stops. Failures are NEVER collapsed into a sentinel such
#     as UNREADABLE, and an ownership error is NOT assumed to be a permission problem.
set -uo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./cleanup-iap-candidates.sh
source "$PKG/lib/cleanup-iap-candidates.sh"

CLEANUP_ALLOW_NONROOT="${CLEANUP_ALLOW_NONROOT:-0}"
LEDGER_ROOT="${LEDGER_ROOT:-/var/lib/aegl-cleanup}"
CLEANUP_ID="${CLEANUP_ID:-iap-cleanup-3f172931-a41e8c53}"

STACK_REPO="${STACK_REPO:-/home/zhong/Projects/Google-Android-Agent-Development-Stack}"
AEGL_REPO="${AEGL_REPO:-/home/zhong/Projects/AI-Engineering-Governance-Layer}"
EXPECTED_STACK_TIP="${EXPECTED_STACK_TIP:-0b04e1798fffb17ec78aaf096065b9990ec65b0e}"
EXPECTED_AEGL_TIP="${EXPECTED_AEGL_TIP:-a387a501916600fc8feaab6da249d3a2c4764b8d}"
MODULE_PATH="${MODULE_PATH:-/usr/local/lib/aegl-model-task/recovery/model_task_registry.py}"
EXPECTED_MODULE_SHA="${EXPECTED_MODULE_SHA:-baa7133e990a9009256068ac75b772a79d426a45678cd010b8301cdb6dc41491}"
# Authoritative, FIXED Bridge state directory — never derived from $HOME / sudo HOME /
# root's ~. Overridable only for tests.
BRIDGE_DIR="${BRIDGE_DIR:-/home/zhong/.local/state/google-android-agent-stack/bridge}"
BRIDGE_STATE="$BRIDGE_DIR/state.json"
BRIDGE_PENDING="$BRIDGE_DIR/pending_result.json"
GITLINK_PATH="${GITLINK_PATH:-references/architecture-templates}"
CAND_SUFFIX="${CAND_SUFFIX:--candidate}"

REPOS=(); ATTEMPTS=(); ROOTCOPIES=()
LEDGER=""; BINDING_ANCHOR=""; BINDING_ATTEMPTS=""

load_tables() {
  LEDGER="$LEDGER_ROOT/$CLEANUP_ID"
  REPOS=(
    "stack|$STACK_REPO|refs/heads/master|$EXPECTED_STACK_TIP"
    "aegl|$AEGL_REPO|refs/heads/main|$EXPECTED_AEGL_TIP"
  )
  if [ -n "${CLEANUP_ATTEMPTS:-}" ]; then
    IFS=$'\n' read -r -d '' -a ATTEMPTS <<< "$CLEANUP_ATTEMPTS" || true
  else
    ATTEMPTS=(
      "3f1729319a8f07d6|/var/tmp/aegl-iap-3f1729319a8f07d6|/var/lib/aegl-delivery/iap-3f1729319a8f07d6"
      "a41e8c5348895588|/var/tmp/aegl-iap-a41e8c5348895588|/var/lib/aegl-delivery/iap-a41e8c5348895588"
    )
  fi
  if [ -n "${CLEANUP_ROOTCOPIES:-}" ]; then
    IFS=$'\n' read -r -d '' -a ROOTCOPIES <<< "$CLEANUP_ROOTCOPIES" || true
  else
    ROOTCOPIES=(
      "/root/iap-delivery.Jo0vY2" "/root/iap-bootstrap.rH2xck"
      "/root/iap-delivery.MwS5po" "/root/iap-bootstrap.XuuAPn"
    )
  fi
  BINDING_ANCHOR="$(sha256sum "$PKG/MANIFEST.sha256" 2>/dev/null | awk '{print $1}')"
  BINDING_ANCHOR="${BINDING_ANCHOR:-NOMANIFEST}"
  BINDING_ATTEMPTS="$(for a in "${ATTEMPTS[@]}"; do att_field "$a" 1; done | paste -sd, -)"
}

row_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
att_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
require_root() { [ "$CLEANUP_ALLOW_NONROOT" = 1 ] || [ "$(id -u)" -eq 0 ] || die not_root "stage '${CURRENT_STAGE}' needs root"; }

marker_text() { printf 'anchor=%s attempts=%s stage=%s' "$BINDING_ANCHOR" "$BINDING_ATTEMPTS" "$1"; }
mark() { mkdir -p "$LEDGER"; marker_text "$1" > "$LEDGER/$1.done"; }
done_marker() {
  local f="$LEDGER/$1.done"
  [ -f "$f" ] || return 1
  [ "$(cat "$f")" = "$(marker_text "$1")" ] || { say "MARKER_STALE $1 (anchor/attempts changed; re-running)"; return 1; }
  return 0
}

# --- git with exact command-scoped trust + real diagnostics ------------------------ #
git_argv() { # <repo> <args...> -> one argv line (exact resolved repo trust, no wildcard)
  local repo="$1" real; shift
  real="$(realpath -e "$repo" 2>/dev/null)" || { printf 'UNRESOLVED'; return 1; }
  printf 'git -c safe.directory=%s -C %s %s' "$real" "$repo" "$*"
}

# run_git <op> <repo> <args...> : prints stdout; on any failure dies with diagnostics.
run_git() {
  local op="$1" repo="$2" real out err rc raw argv; shift 2
  real="$(realpath -e "$repo" 2>/dev/null)" || die git_repo_unresolved "op=$op repo=$repo"
  argv="$(git_argv "$repo" "$@")"
  GIT_CALLS+=("$argv")
  out="$(mktemp)"; err="$(mktemp)"
  git -c "safe.directory=$real" -C "$repo" "$@" >"$out" 2>"$err"; rc=$?
  if [ "$rc" -ne 0 ]; then
    raw="$(head -c 400 "$err" | tr '\n' ' ')"
    rm -f "$out" "$err"
    die git_failed "op=$op argv='$argv' rc=$rc stderr=${raw:-<empty>}"
  fi
  cat "$out"; rm -f "$out" "$err"
}

# git_probe <op> <repo> <args...> : 0 = success, 1 = "not found" (expected), else dies.
git_probe() {
  local op="$1" repo="$2" real err rc raw argv; shift 2
  real="$(realpath -e "$repo" 2>/dev/null)" || die git_repo_unresolved "op=$op repo=$repo"
  argv="$(git_argv "$repo" "$@")"
  GIT_CALLS+=("$argv")
  err="$(mktemp)"
  git -c "safe.directory=$real" -C "$repo" "$@" >/dev/null 2>"$err"; rc=$?
  if [ "$rc" -gt 1 ]; then
    raw="$(head -c 400 "$err" | tr '\n' ' ')"
    rm -f "$err"
    die git_failed "op=$op argv='$argv' rc=$rc stderr=${raw:-<empty>}"
  fi
  rm -f "$err"; return "$rc"
}

GIT_CALLS=()

# --------------------------------------------------------------------------- #
stage_preflight() {
  require_root
  local row name repo ref want got
  for row in "${REPOS[@]}"; do
    name="$(row_field "$row" 1)"; repo="$(row_field "$row" 2)"; ref="$(row_field "$row" 3)"
    want="$(row_field "$row" 4)"
    got="$(run_git "rev-parse $name $ref" "$repo" rev-parse "$ref")"
    [ "$got" = "$want" ] || die preflight_ref "$name $ref=$got want=$want"
    got="$(run_git "rev-parse $name HEAD" "$repo" rev-parse HEAD)"
    [ "$got" = "$want" ] || die preflight_head "$name HEAD=$got want=$want"
    say "PREFLIGHT_OK ref+head=$name $got"
  done
  got="$(sha256sum "$MODULE_PATH" 2>/dev/null | awk '{print $1}')"
  [ "$got" = "$EXPECTED_MODULE_SHA" ] || die preflight_module "$MODULE_PATH=$got want=$EXPECTED_MODULE_SHA"
  say "PREFLIGHT_OK module=$got"
  local tree_oid idx_mode idx_oid _ignored
  tree_oid="$(run_git "rev-parse HEAD:$GITLINK_PATH" "$STACK_REPO" rev-parse "HEAD:$GITLINK_PATH")"
  read -r idx_mode idx_oid _ignored < <(run_git "ls-files -s $GITLINK_PATH" "$STACK_REPO" ls-files -s -- "$GITLINK_PATH")
  [ "$idx_mode" = "160000" ] || die preflight_gitlink_mode "$GITLINK_PATH mode=$idx_mode"
  [ "$idx_oid" = "$tree_oid" ] || die preflight_gitlink_drift "$GITLINK_PATH index=$idx_oid head=$tree_oid"
  say "PREFLIGHT_OK gitlink=$GITLINK_PATH $idx_oid"
  [ -e "$BRIDGE_STATE" ] || die preflight_bridge_missing "$BRIDGE_STATE (fixed path, not derived from HOME)"
  [ -r "$BRIDGE_STATE" ] || die preflight_bridge_unreadable "$BRIDGE_STATE"
  python3 - "$BRIDGE_STATE" "$BRIDGE_PENDING" <<'PY' || die preflight_bridge "state invalid, or status/sequence/pending mismatch"
import json, sys, os
path, pending = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception as exc:
    print("bridge_state_bad_json", type(exc).__name__, file=sys.stderr); raise SystemExit(1)
missing = [k for k in ("status", "expected_sequence") if k not in d]
if missing:
    print("bridge_state_missing_field", ",".join(missing), file=sys.stderr); raise SystemExit(1)
if d.get("status") != "WAITING_FOR_GPT":
    print("bridge_status_mismatch", d.get("status"), file=sys.stderr); raise SystemExit(1)
if d.get("expected_sequence") != 5:
    print("bridge_sequence_mismatch", d.get("expected_sequence"), file=sys.stderr); raise SystemExit(1)
if os.path.exists(pending):
    print("bridge_pending_present", pending, file=sys.stderr); raise SystemExit(1)
PY
  say "PREFLIGHT_OK bridge=WAITING_FOR_GPT/seq5/no-pending ($BRIDGE_DIR)"
}

# --- precise admin-entry removal ---------------------------------------------------- #
prove_and_drop_admin() { # <repo> <candidate> <approved_commit>
  local repo="$1" cand="$2" appr="$3" wtname adm gd cd hd entry
  wtname="$(basename "$cand")"
  adm="$repo/.git/worktrees/$wtname"
  case "$adm" in "$repo"/.git/worktrees/*) : ;; *) die admin_outside "$adm" ;; esac
  [ -d "$adm" ] && [ ! -L "$adm" ] || die admin_missing "$adm"
  [ -d "$repo/.git/worktrees" ] && [ ! -L "$repo/.git/worktrees" ] || die admin_parent "$repo/.git/worktrees"
  [ -z "$(find "$adm" -mindepth 1 -maxdepth 1 -type l -print -quit 2>/dev/null)" ] || die admin_symlink "$adm"
  for entry in "$adm"/* "$adm"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "$(basename "$entry")" in
      gitdir|HEAD|commondir|index|ORIG_HEAD|logs|refs) ;;
      *) die admin_unexpected "$entry" ;;
    esac
  done
  [ ! -e "$adm/locked" ] || die admin_locked "$adm/locked"
  gd="$adm/gitdir"; [ -f "$gd" ] && [ ! -L "$gd" ] || die admin_gitdir "$gd"
  [ "$(cat "$gd")" = "$cand/.git" ] || die admin_gitdir_foreign "$(cat "$gd") != $cand/.git"
  cd="$adm/commondir"; [ -f "$cd" ] && [ ! -L "$cd" ] || die admin_commondir "$cd"
  [ "$(cd "$adm" && realpath -e "$(cat "$cd")" 2>/dev/null)" = "$(realpath -e "$repo/.git")" ] \
    || die admin_commondir_foreign "$(cat "$cd")"
  hd="$(cat "$adm/HEAD" 2>/dev/null)"
  case "$hd" in
    "ref: "*) [ "$(run_git "rev-parse admin HEAD $wtname" "$repo" rev-parse --verify "${hd#ref: }")" = "$appr" ] || die admin_head "${hd#ref: } != $appr" ;;
    *) [ "$hd" = "$appr" ] || die admin_head "$hd != $appr" ;;
  esac
  say "ADMIN_PROOF_OK $adm (gitdir/commondir/HEAD/locked/entries verified)"
  rm -r -- "$adm" || die admin_remove "$wtname"
  [ ! -e "$adm" ] || die admin_left "$adm"
}

cleanup_candidate() { # <repo> <candidate> <approved_commit>
  local repo="$1" cand="$2" appr="$3" wtname st act
  wtname="$(basename "$cand")"
  st="$(worktree_state "$repo" "$wtname" "$cand")"
  act="$(plan_action "$st")"
  say "CANDIDATE path=$cand admin=$wtname state=$st action=$act"
  case "$act" in
    REMOVE_WORKTREE)
      run_git "worktree remove $wtname" "$repo" worktree remove -- "$cand" >/dev/null \
        || die worktree_remove "$cand (the attempt root is not writable by the broker identity; removal must run as root)"
      wt_admin_present "$repo" "$wtname" && die admin_left "$wtname"
      [ ! -e "$cand" ] || die dir_left "$cand"
      ;;
    DROP_ADMIN_ENTRY)
      prove_and_drop_admin "$repo" "$cand" "$appr"
      [ -d "$cand" ] && { rmdir -- "$cand" || die rmdir_empty "$cand"; } || true
      ;;
    DELETE_EMPTY_DIR) rmdir -- "$cand" || die rmdir_empty "$cand" ;;
    REFUSE_DIRTY)     die dirty_candidate "$cand has real modifications; preserved" ;;
    REFUSE_RESIDUE)   die residue "$cand is present but not a registered worktree; preserved" ;;
    NOTHING)          say "CANDIDATE_ABSENT $cand" ;;
    *)                die unknown_action "$act for $st" ;;
  esac
}

stage_candidates() {
  require_root
  local att aid aroot row name repo cand appr
  for att in "${ATTEMPTS[@]}"; do
    aid="$(att_field "$att" 1)"; aroot="$(att_field "$att" 2)"
    [ -e "$aroot" ] || { say "ATTEMPT_ABSENT $aroot"; continue; }
    for row in "${REPOS[@]}"; do
      name="$(row_field "$row" 1)"; repo="$(row_field "$row" 2)"; appr="$(row_field "$row" 4)"
      cand="$aroot/$name$CAND_SUFFIX"
      CURRENT_STAGE="candidates:$aid:$name"
      cleanup_candidate "$repo" "$cand" "$appr"
    done
    say "ATTEMPT_CANDIDATES_DONE $aid"
  done
}

stage_temp_refs() {
  require_root
  local att aid aroot row name repo ref want got
  for att in "${ATTEMPTS[@]}"; do
    aid="$(att_field "$att" 1)"; aroot="$(att_field "$att" 2)"
    [ -e "$aroot" ] || continue
    for row in "${REPOS[@]}"; do
      name="$(row_field "$row" 1)"; repo="$(row_field "$row" 2)"
      ref="refs/iap-candidate/$name"; want="$(row_field "$row" 4)"
      if git_probe "rev-parse $ref" "$repo" rev-parse --verify --quiet "$ref"; then
        got="$(run_git "rev-parse $ref" "$repo" rev-parse --verify "$ref")"
        [ "$got" = "$want" ] || die temp_ref_oid "$aid $ref=$got want=$want"
        run_git "update-ref -d $ref" "$repo" update-ref -d "$ref" >/dev/null
        say "TEMP_REF_DELETED $aid $ref ($got)"
      else
        say "TEMP_REF_ABSENT $aid $ref"
      fi
    done
  done
}

stage_attempt_roots() {
  require_root
  local att aid aroot ldir
  for att in "${ATTEMPTS[@]}"; do
    aid="$(att_field "$att" 1)"; aroot="$(att_field "$att" 2)"; ldir="$(att_field "$att" 3)"
    if [ -e "$aroot" ]; then
      if [ -n "$(ls -A "$aroot" 2>/dev/null)" ]; then
        say "ATTEMPT_RESIDUE $aroot:"; ls -la "$aroot" >&2 || true
        die attempt_not_empty "$aroot (preserved)"
      fi
      rmdir -- "$aroot" || die rmdir_attempt "$aroot"
      say "ATTEMPT_ROOT_REMOVED $aroot"
    else
      say "ATTEMPT_ROOT_ABSENT $aroot"
    fi
    if [ -e "$ldir" ]; then rm -r -- "$ldir" || die ledger_remove "$ldir"; say "ATTEMPT_LEDGER_REMOVED $ldir"; fi
  done
}

stage_rootcopies() {
  require_root
  local p
  for p in "${ROOTCOPIES[@]}"; do
    if [ -e "$p" ]; then rm -r -- "$p" || die rootcopy_remove "$p"; say "ROOTCOPY_REMOVED $p"; fi
  done
}

stage_verify_clean() {
  require_root
  local att aid aroot ldir row name repo ref p bad=0
  for att in "${ATTEMPTS[@]}"; do
    aid="$(att_field "$att" 1)"; aroot="$(att_field "$att" 2)"; ldir="$(att_field "$att" 3)"
    [ -e "$aroot" ] && { say "REMAINS $aroot"; bad=1; }
    [ -e "$ldir" ] && { say "REMAINS $ldir"; bad=1; }
    for row in "${REPOS[@]}"; do
      name="$(row_field "$row" 1)"; repo="$(row_field "$row" 2)"
      wt_admin_present "$repo" "$name$CAND_SUFFIX" && { say "REMAINS $repo/.git/worktrees/$name$CAND_SUFFIX"; bad=1; }
      ref="refs/iap-candidate/$name"
      git_probe "rev-parse $ref" "$repo" rev-parse --verify --quiet "$ref" && { say "REMAINS $ref"; bad=1; }
    done
  done
  for p in "${ROOTCOPIES[@]}"; do [ -e "$p" ] && { say "REMAINS $p"; bad=1; }; done
  [ "$bad" -eq 0 ] || die residual_scene "remaining paths above (preserved)"
  say "CLEANUP_VERIFIED=clean"
}

STAGES=(preflight candidates temp-refs attempt-roots rootcopies verify-clean)
stage_name_to_fn() { printf 'stage_%s' "${1//-/_}"; }

main() {
  set -euo pipefail
  load_tables
  local only="" from="" op started=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) only="${2:-}"; shift 2 ;;
      --from) from="${2:-}"; shift 2 ;;
      *) die usage "unknown argument: $1" ;;
    esac
  done
  if [ -n "$only" ]; then
    for op in "${STAGES[@]}"; do
      [ "$op" = "$only" ] && break
      done_marker "$op" || die prerequisite_not_done "$op (before $only)"
    done
    CURRENT_STAGE="$only"; "$(stage_name_to_fn "$only")"; return
  fi
  for op in "${STAGES[@]}"; do
    if [ -n "$from" ] && [ "$started" -eq 0 ]; then
      [ "$op" = "$from" ] && started=1 || continue
    fi
    if [ "$op" != verify-clean ] && done_marker "$op"; then say "SKIP $op (done)"; continue; fi
    CURRENT_STAGE="$op"
    "$(stage_name_to_fn "$op")"
    mark "$op"
  done
  say "CLEANUP_RESULT=OK id=$CLEANUP_ID"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  main "$@"
fi
