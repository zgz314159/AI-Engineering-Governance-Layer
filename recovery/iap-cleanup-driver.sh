#!/usr/bin/env bash
# iap-cleanup-driver.sh — cleanup-ONLY, precise, resumable finisher for the IAP delivery.
#
# Root only. Never re-runs import/register/record/promote/formal-sync/install, never
# edits the broker/model-task registry, never runs `rm -rf`, `git worktree prune`,
# `--force`, backups or archives, and never relaxes staging/formal-tree permissions.
#
# Errexit discipline: an EXPECTED non-zero result (no admin match, stale marker, ref
# absent) is always consumed by an explicit `if`/`||` construct, never left as a bare
# command, so `set -e` cannot abort silently. An UNEXPECTED failure is reported by an
# ERR/EXIT trap with stage, function, line and the original exit code.
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
# Authoritative, FIXED Bridge state directory — never derived from $HOME / sudo HOME.
BRIDGE_DIR="${BRIDGE_DIR:-/home/zhong/.local/state/google-android-agent-stack/bridge}"
BRIDGE_STATE="$BRIDGE_DIR/state.json"
BRIDGE_PENDING="$BRIDGE_DIR/pending_result.json"
GITLINK_PATH="${GITLINK_PATH:-references/architecture-templates}"
CAND_SUFFIX="${CAND_SUFFIX:--candidate}"

REPOS=(); ATTEMPTS=(); ROOTCOPIES=()
LEDGER=""; BINDING_ANCHOR=""; BINDING_ATTEMPTS=""
FAIL_REPORTED=0

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
  local a
  BINDING_ANCHOR="$(sha256sum "$PKG/MANIFEST.sha256" 2>/dev/null | awk '{print $1}')" || BINDING_ANCHOR=""
  BINDING_ANCHOR="${BINDING_ANCHOR:-NOMANIFEST}"
  BINDING_ATTEMPTS="$(for a in "${ATTEMPTS[@]}"; do att_field "$a" 1; done | paste -sd, -)"
  return 0
}

row_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
att_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
require_root() {
  if [ "$CLEANUP_ALLOW_NONROOT" != 1 ] && [ "$(id -u)" -ne 0 ]; then
    die not_root "stage '${CURRENT_STAGE}' needs root"
  fi
  return 0
}

marker_text() { printf 'anchor=%s attempts=%s stage=%s' "$BINDING_ANCHOR" "$BINDING_ATTEMPTS" "$1"; }
mark() {
  mkdir -p "$LEDGER" || die marker_dir "$LEDGER"
  marker_text "$1" > "$LEDGER/$1.done" || die marker_write "$LEDGER/$1.done"
  return 0
}
done_marker() {
  local f="$LEDGER/$1.done"
  if [ ! -f "$f" ]; then return 1; fi
  if [ "$(cat "$f")" != "$(marker_text "$1")" ]; then
    say "MARKER_STALE $1 (anchor/attempts changed; re-running)"
    return 1
  fi
  return 0
}

# --- git with exact command-scoped trust + real diagnostics ------------------------ #
git_argv() { # <repo> <args...>
  local repo="$1" real; shift
  if ! real="$(realpath -e "$repo" 2>/dev/null)"; then printf 'UNRESOLVED'; return 1; fi
  printf 'git -c safe.directory=%s -C %s %s' "$real" "$repo" "$*"
}

run_git() { # <op> <repo> <args...>; prints stdout, dies with diagnostics on failure
  local op="$1" repo="$2" real out err rc raw argv; shift 2
  if ! real="$(realpath -e "$repo" 2>/dev/null)"; then die git_repo_unresolved "op=$op repo=$repo"; fi
  argv="$(git_argv "$repo" "$@")" || argv="git -C $repo $*"
  out="$(mktemp)"; err="$(mktemp)"
  # the git status is an EXPECTED result to be inspected: consume it in a condition so
  # the ERR trap does not fire on a failure this function is about to report itself
  if git -c "safe.directory=$real" -C "$repo" "$@" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    raw="$(head -c 400 "$err" | tr '\n' ' ')"
    rm -f "$out" "$err"
    die git_failed "op=$op argv='$argv' rc=$rc stderr=${raw:-<empty>}"
  fi
  cat "$out"; rm -f "$out" "$err"
  return 0
}

git_probe() { # <op> <repo> <args...>; 0 found, 1 absent (expected), else die
  local op="$1" repo="$2" real err rc raw argv; shift 2
  if ! real="$(realpath -e "$repo" 2>/dev/null)"; then die git_repo_unresolved "op=$op repo=$repo"; fi
  argv="$(git_argv "$repo" "$@")" || argv="git -C $repo $*"
  err="$(mktemp)"
  if git -c "safe.directory=$real" -C "$repo" "$@" >/dev/null 2>"$err"; then rc=0; else rc=$?; fi
  if [ "$rc" -gt 1 ]; then
    raw="$(head -c 400 "$err" | tr '\n' ' ')"
    rm -f "$err"
    die git_failed "op=$op argv='$argv' rc=$rc stderr=${raw:-<empty>}"
  fi
  rm -f "$err"; return "$rc"
}

# --- admin-entry location by EXACT gitdir match (never by name) -------------------- #
find_admin_for() { # <repo> <candidate> -> prints the single admin dir; rc 0/1/2
  local repo="$1" cand="$2" target gd content resolved
  local -a matches=()
  target="$(realpath -m -- "$cand/.git")"
  for gd in "$repo"/.git/worktrees/*/gitdir; do
    [ -f "$gd" ] && [ ! -L "$gd" ] || continue
    content="$(cat "$gd" 2>/dev/null)" || continue
    [ -n "$content" ] || continue
    case "$content" in /*) : ;; *) content="$(dirname "$gd")/$content" ;; esac
    resolved="$(realpath -m -- "$content")"
    if [ "$resolved" = "$target" ]; then matches+=("$(dirname "$gd")"); fi
  done
  if [ "${#matches[@]}" -eq 0 ]; then return 1; fi
  if [ "${#matches[@]}" -gt 1 ]; then return 2; fi
  printf '%s' "${matches[0]}"
  return 0
}

classify_candidate() { # <repo> <candidate>
  local repo="$1" cand="$2" admin_rc=0 ds
  find_admin_for "$repo" "$cand" >/dev/null || admin_rc=$?
  ds="$(dir_state "$cand")"
  if [ "$admin_rc" -eq 0 ]; then
    case "$ds" in
      MISSING|EMPTY) printf '%s_REGISTERED' "$ds" ;;
      NONEMPTY)
        if git_safe "$cand" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
           && [ -z "$(git_safe "$cand" status --porcelain 2>/dev/null)" ]; then
          printf 'CLEAN_REGISTERED'
        else
          printf 'DIRTY_REGISTERED'
        fi ;;
      *) printf 'RESIDUE_UNREGISTERED' ;;
    esac
  else
    case "$ds" in
      MISSING) printf 'ABSENT' ;;
      EMPTY)   printf 'EMPTY_UNREGISTERED' ;;
      *)       printf 'RESIDUE_UNREGISTERED' ;;
    esac
  fi
  return 0
}

stage_preflight() {
  require_root
  local row name repo ref want got
  for row in "${REPOS[@]}"; do
    name="$(row_field "$row" 1)"; repo="$(row_field "$row" 2)"; ref="$(row_field "$row" 3)"
    want="$(row_field "$row" 4)"
    got="$(run_git "rev-parse $name $ref" "$repo" rev-parse "$ref")"
    if [ "$got" != "$want" ]; then die preflight_ref "$name $ref=$got want=$want"; fi
    got="$(run_git "rev-parse $name HEAD" "$repo" rev-parse HEAD)"
    if [ "$got" != "$want" ]; then die preflight_head "$name HEAD=$got want=$want"; fi
    say "PREFLIGHT_OK ref+head=$name $got"
  done
  got="$(sha256sum "$MODULE_PATH" 2>/dev/null | awk '{print $1}')" || got=""
  if [ "$got" != "$EXPECTED_MODULE_SHA" ]; then die preflight_module "$MODULE_PATH=${got:-unreadable} want=$EXPECTED_MODULE_SHA"; fi
  say "PREFLIGHT_OK module=$got"
  local tree_oid idx_mode idx_oid _ignored
  tree_oid="$(run_git "rev-parse HEAD:$GITLINK_PATH" "$STACK_REPO" rev-parse "HEAD:$GITLINK_PATH")"
  read -r idx_mode idx_oid _ignored < <(run_git "ls-files -s $GITLINK_PATH" "$STACK_REPO" ls-files -s -- "$GITLINK_PATH")
  if [ "$idx_mode" != "160000" ]; then die preflight_gitlink_mode "$GITLINK_PATH mode=$idx_mode"; fi
  if [ "$idx_oid" != "$tree_oid" ]; then die preflight_gitlink_drift "$GITLINK_PATH index=$idx_oid head=$tree_oid"; fi
  say "PREFLIGHT_OK gitlink=$GITLINK_PATH $idx_oid"
  if [ ! -e "$BRIDGE_STATE" ]; then die preflight_bridge_missing "$BRIDGE_STATE (fixed path, not derived from HOME)"; fi
  if [ ! -r "$BRIDGE_STATE" ]; then die preflight_bridge_unreadable "$BRIDGE_STATE"; fi
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
  return 0
}

prove_and_drop_admin() { # <repo> <admin-dir> <candidate> <approved_commit>
  local repo="$1" adm="$2" cand="$3" appr="$4" wtname gd cd hd entry
  wtname="$(basename "$adm")"
  case "$adm" in "$repo"/.git/worktrees/*) : ;; *) die admin_outside "$adm" ;; esac
  if [ ! -d "$adm" ] || [ -L "$adm" ]; then die admin_missing "$adm"; fi
  if [ ! -d "$repo/.git/worktrees" ] || [ -L "$repo/.git/worktrees" ]; then die admin_parent "$repo/.git/worktrees"; fi
  if [ -n "$(find "$adm" -mindepth 1 -maxdepth 1 -type l -print -quit 2>/dev/null)" ]; then die admin_symlink "$adm"; fi
  for entry in "$adm"/* "$adm"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "$(basename "$entry")" in
      gitdir|HEAD|commondir|index|ORIG_HEAD|logs|refs) ;;
      *) die admin_unexpected "$entry" ;;
    esac
  done
  if [ -e "$adm/locked" ]; then die admin_locked "$adm/locked"; fi
  gd="$adm/gitdir"
  if [ ! -f "$gd" ] || [ -L "$gd" ]; then die admin_gitdir "$gd"; fi
  if [ "$(cat "$gd")" != "$cand/.git" ]; then die admin_gitdir_foreign "$(cat "$gd") != $cand/.git"; fi
  cd="$adm/commondir"
  if [ ! -f "$cd" ] || [ -L "$cd" ]; then die admin_commondir "$cd"; fi
  if [ "$(cd "$adm" && realpath -e "$(cat "$cd")" 2>/dev/null)" != "$(realpath -e "$repo/.git")" ]; then
    die admin_commondir_foreign "$(cat "$cd")"
  fi
  hd="$(cat "$adm/HEAD" 2>/dev/null)"
  case "$hd" in
    "ref: "*) if [ "$(run_git "rev-parse admin HEAD $wtname" "$repo" rev-parse --verify "${hd#ref: }")" != "$appr" ]; then die admin_head "${hd#ref: } != $appr"; fi ;;
    *) if [ "$hd" != "$appr" ]; then die admin_head "$hd != $appr"; fi ;;
  esac
  say "ADMIN_PROOF_OK $adm (gitdir/commondir/HEAD/locked/entries verified)"
  rm -r -- "$adm" || die admin_remove "$wtname"
  if [ -e "$adm" ]; then die admin_left "$adm"; fi
  return 0
}

cleanup_candidate() { # <repo> <candidate> <approved_commit>
  local repo="$1" cand="$2" appr="$3" st act adm admin_rc=0
  find_admin_for "$repo" "$cand" >/dev/null || admin_rc=$?
  if [ "$admin_rc" -eq 2 ]; then die admin_ambiguous "$cand (more than one admin entry references it; refusing)"; fi
  st="$(classify_candidate "$repo" "$cand")"
  act="$(plan_action "$st")"
  adm=""
  if [ "$admin_rc" -eq 0 ]; then adm="$(find_admin_for "$repo" "$cand")"; fi
  say "CANDIDATE path=$cand state=$st action=$act admin=${adm:-none}"
  case "$act" in
    REMOVE_WORKTREE)
      run_git "worktree remove $cand" "$repo" worktree remove -- "$cand" >/dev/null
      admin_rc=0; find_admin_for "$repo" "$cand" >/dev/null || admin_rc=$?
      if [ "$admin_rc" -eq 0 ]; then die admin_left "$cand"; fi
      if [ -e "$cand" ]; then die dir_left "$cand"; fi
      ;;
    DROP_ADMIN_ENTRY)
      if [ -z "$adm" ]; then die admin_ambiguous_or_missing "$cand (expected exactly one admin entry)"; fi
      prove_and_drop_admin "$repo" "$adm" "$cand" "$appr"
      if [ -d "$cand" ]; then rmdir -- "$cand" || die rmdir_empty "$cand"; fi
      ;;
    DELETE_EMPTY_DIR) rmdir -- "$cand" || die rmdir_empty "$cand" ;;
    REFUSE_DIRTY)     die dirty_candidate "$cand has real modifications; preserved" ;;
    REFUSE_RESIDUE)   die residue "$cand is present but has no exact admin entry; preserved" ;;
    NOTHING)          say "CANDIDATE_ABSENT $cand" ;;
    *)                die unknown_action "$act for $st" ;;
  esac
  return 0
}

stage_candidates() {
  require_root
  local att aid aroot row name repo cand appr
  for att in "${ATTEMPTS[@]}"; do
    aid="$(att_field "$att" 1)"; aroot="$(att_field "$att" 2)"
    if [ ! -e "$aroot" ]; then say "ATTEMPT_ABSENT $aroot"; continue; fi
    for row in "${REPOS[@]}"; do
      name="$(row_field "$row" 1)"; repo="$(row_field "$row" 2)"; appr="$(row_field "$row" 4)"
      cand="$aroot/$name$CAND_SUFFIX"
      CURRENT_STAGE="candidates:$aid:$name"
      cleanup_candidate "$repo" "$cand" "$appr"
    done
    say "ATTEMPT_CANDIDATES_DONE $aid"
  done
  return 0
}

stage_temp_refs() {
  require_root
  local att aid aroot row name repo ref want got
  for att in "${ATTEMPTS[@]}"; do
    aid="$(att_field "$att" 1)"; aroot="$(att_field "$att" 2)"
    if [ ! -e "$aroot" ]; then continue; fi
    for row in "${REPOS[@]}"; do
      name="$(row_field "$row" 1)"; repo="$(row_field "$row" 2)"
      ref="refs/iap-candidate/$name"; want="$(row_field "$row" 4)"
      if git_probe "rev-parse $ref" "$repo" rev-parse --verify --quiet "$ref"; then
        got="$(run_git "rev-parse $ref" "$repo" rev-parse --verify "$ref")"
        if [ "$got" != "$want" ]; then die temp_ref_oid "$aid $ref=$got want=$want"; fi
        run_git "update-ref -d $ref" "$repo" update-ref -d "$ref" >/dev/null
        say "TEMP_REF_DELETED $aid $ref ($got)"
      else
        say "TEMP_REF_ABSENT $aid $ref"
      fi
    done
  done
  return 0
}

stage_attempt_roots() {
  require_root
  local att aid aroot ldir
  for att in "${ATTEMPTS[@]}"; do
    aid="$(att_field "$att" 1)"; aroot="$(att_field "$att" 2)"; ldir="$(att_field "$att" 3)"
    if [ -e "$aroot" ]; then
      if [ -n "$(ls -A "$aroot" 2>/dev/null)" ]; then
        say "ATTEMPT_RESIDUE $aroot:"
        if ! ls -la "$aroot" >&2; then say "ATTEMPT_RESIDUE_LIST_FAILED $aroot"; fi
        die attempt_not_empty "$aroot (preserved)"
      fi
      rmdir -- "$aroot" || die rmdir_attempt "$aroot"
      say "ATTEMPT_ROOT_REMOVED $aroot"
    else
      say "ATTEMPT_ROOT_ABSENT $aroot"
    fi
    if [ -e "$ldir" ]; then
      rm -r -- "$ldir" || die ledger_remove "$ldir"
      say "ATTEMPT_LEDGER_REMOVED $ldir"
    fi
  done
  return 0
}

stage_rootcopies() {
  require_root
  local p
  for p in "${ROOTCOPIES[@]}"; do
    if [ -e "$p" ]; then rm -r -- "$p" || die rootcopy_remove "$p"; say "ROOTCOPY_REMOVED $p"; fi
  done
  return 0
}

stage_verify_clean() {
  require_root
  local att aid aroot ldir row name repo cand ref p bad=0 admin_rc
  for att in "${ATTEMPTS[@]}"; do
    aid="$(att_field "$att" 1)"; aroot="$(att_field "$att" 2)"; ldir="$(att_field "$att" 3)"
    if [ -e "$aroot" ]; then say "REMAINS $aroot"; bad=1; fi
    if [ -e "$ldir" ]; then say "REMAINS $ldir"; bad=1; fi
    for row in "${REPOS[@]}"; do
      name="$(row_field "$row" 1)"; repo="$(row_field "$row" 2)"
      cand="$aroot/$name$CAND_SUFFIX"
      admin_rc=0; find_admin_for "$repo" "$cand" >/dev/null || admin_rc=$?
      if [ "$admin_rc" -ne 1 ]; then say "REMAINS admin($admin_rc) for $cand"; bad=1; fi
      ref="refs/iap-candidate/$name"
      if git_probe "rev-parse $ref" "$repo" rev-parse --verify --quiet "$ref"; then
        say "REMAINS $ref"; bad=1
      fi
    done
  done
  for p in "${ROOTCOPIES[@]}"; do if [ -e "$p" ]; then say "REMAINS $p"; bad=1; fi; done
  if [ "$bad" -ne 0 ]; then die residual_scene "remaining paths above (preserved)"; fi
  say "CLEANUP_VERIFIED=clean"
  return 0
}

STAGES=(preflight candidates temp-refs attempt-roots rootcopies verify-clean)
stage_name_to_fn() { printf 'stage_%s' "${1//-/_}"; }

on_abort() { # rc line cmd  (ERR trap: reports the abort point once, no env dump)
  local rc="$1" line="$2" cmd="$3"
  if [ "$rc" -eq 0 ]; then return 0; fi
  if [ "${FAIL_REPORTED:-0}" = 1 ]; then return 0; fi
  if [ -n "${CLEANUP_FAIL_MARK:-}" ] && [ -e "$CLEANUP_FAIL_MARK" ]; then return 0; fi
  FAIL_REPORTED=1
  printf 'CLEANUP_ABORT stage=%s func=%s line=%s rc=%s cmd=%s\n' \
    "${CURRENT_STAGE:-none}" "${FUNCNAME[1]:-main}" "$line" "$rc" \
    "$(printf '%s' "$cmd" | head -c 200)" >&2
}
on_exit() { # EXIT trap: catches a bare non-zero exit with no printed reason
  local rc="$1"
  if [ "$rc" -eq 0 ]; then return 0; fi
  if [ "${FAIL_REPORTED:-0}" = 1 ]; then return 0; fi
  if [ -n "${CLEANUP_FAIL_MARK:-}" ] && [ -e "$CLEANUP_FAIL_MARK" ]; then return 0; fi
  FAIL_REPORTED=1
  printf 'CLEANUP_ABORT stage=%s func=exit line=0 rc=%s cmd=<exit>\n' "${CURRENT_STAGE:-none}" "$rc" >&2
}

main() {
  set -Eeuo pipefail
  CLEANUP_FAIL_MARK="${TMPDIR:-/tmp}/.iap-cleanup-fail.$$"
  export CLEANUP_FAIL_MARK
  rm -f "$CLEANUP_FAIL_MARK" 2>/dev/null || if [ -e "$CLEANUP_FAIL_MARK" ]; then say "FAIL_MARK_CLEANUP_FAILED $CLEANUP_FAIL_MARK"; fi
  trap 'on_abort "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap 'on_exit "$?"' EXIT
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
      if [ "$op" = "$only" ]; then break; fi
      if ! done_marker "$op"; then die prerequisite_not_done "$op (before $only)"; fi
    done
    CURRENT_STAGE="$only"; "$(stage_name_to_fn "$only")"; return 0
  fi
  for op in "${STAGES[@]}"; do
    if [ -n "$from" ] && [ "$started" -eq 0 ]; then
      if [ "$op" = "$from" ]; then started=1; else continue; fi
    fi
    if [ "$op" != verify-clean ] && done_marker "$op"; then say "SKIP $op (done)"; continue; fi
    CURRENT_STAGE="$op"
    "$(stage_name_to_fn "$op")"
    mark "$op"
  done
  say "CLEANUP_RESULT=OK id=$CLEANUP_ID"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -Eeuo pipefail
  main "$@"
fi
