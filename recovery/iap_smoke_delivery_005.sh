#!/usr/bin/env bash
# iap_smoke_delivery.sh — staged package for the IAP **S0 integration smoke**.
#
# S0 is NOT the business milestone: the business M1 is 建设方案 §8 P0 (real vision
# smoke), which stays a separate, unexecuted item. S0 only proves the trusted chain
# carries an ImageAnalysisFactory task and yields verifiable read-only evidence.
#
# Identity split:
#   * root  — baseline control, worktree creation, permissions, contract install, registration.
#   * zhong — campaign, browser adapter and session I/O (the operator's own environment).
# The bridge state path is FIXED; a root-HOME resolution is a hard stop.
#
#   run_smoke.sh                  # prep stages, stop at PREP_COMPLETE (no model, no send)
#   run_smoke.sh --stage <s>      # one stage
#   run_smoke.sh --execute        # prep + send + wait + round + accept
#   run_smoke.sh --status
set -uo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_SRC="$PKG/contract/IAP-SMOKE-005"
IAP="${IAP:-/home/zhong/AndroidStudioProjects/ImageAnalysisFactory}"
STACK="${STACK:-/home/zhong/Projects/Google-Android-Agent-Development-Stack}"
TASK_ID="IAP-SMOKE-005"
TASK_ROOT="${TASK_ROOT:-/var/tmp/IAP-SMOKE-005}"
WORKTREE="${WORKTREE:-$TASK_ROOT/project}"
SCRATCH="${SCRATCH:-$TASK_ROOT/scratch}"
PKG_DEST="/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/IAP-SMOKE-005"
BRIDGE_DIR="/home/zhong/.local/state/google-android-agent-stack/bridge"
STACK_BRIDGE="$STACK/orchestration/hermes/bridge"
PLAN_FILE="Command_Code_DeepSeek_大规模图片智能分析工厂_建设方案_v1.0.md"
EXPECT_MANIFEST_SHA="f743a68ed056405df2fb1ba828d9ec923a2577af5207eeff2fce9e0978e96453"
EXPECT_BASE="${EXPECT_BASE:-177680708739a72a0d70bc6a9664245b00a2ef08}"
OPERATOR="zhong"; OPERATOR_HOME="/home/zhong"; OP_PATH="/usr/local/bin:/usr/bin:/bin:/home/zhong/.local/bin"
CDP_URL="http://127.0.0.1:9333"
LEDGER="${LEDGER:-/var/lib/aegl-smoke/$TASK_ID}"
CAMPAIGN_ID="IAP-SMOKE-005"
SUPERVISOR_ROOT="/home/zhong/.local/state/google-android-agent-stack/supervisor"
HELPER="$PKG/bin/iap_round_verdict.py"
SANDBOX_DIR="/usr/local/lib/aegl-model"
SANDBOX_BIN="$SANDBOX_DIR/aegl-hermes-sandbox"
SANDBOX_PAYLOAD="$PKG/payload/aegl-hermes-sandbox"
SANDBOX_BEFORE_SHA="06aab45259a1fe2e220260dc962137c227468e49f5d6027cfb9fc534380ee41a"
SANDBOX_AFTER_SHA="70de6baae488a45f15bf83e280300bfeecd6694549b9ecc028ba81a7d8542932"
SANDBOX_ALLOWLIST='DIAG_ENABLED_TASKS=" BRIDGE-DIAG-003 BRIDGE-VERIFY-004 BRIDGE-VERIFY-007 BRIDGE-VERIFY-008 IAP-SMOKE-003 IAP-SMOKE-004 IAP-SMOKE-005 "'
# The broker is NOT touched by this package: it must already be the reviewed candidate.
BROKER_BIN="$SANDBOX_DIR/model_broker.py"
BROKER_SHA="ab0d4c36cb27f1b23cc1510f3650f10df8375dd72db4078eb2a99ad41d93c3e3"
EXPECT_COMMON="/home/zhong/AndroidStudioProjects/ImageAnalysisFactory/.git"
EXPECT_HELPER_SHA="f93bbfdd286e6a554c10edcdda6dd40a20d32d1ffbcb17dc56091bbeac8ac50a"
EXPECT_BRIDGE_SEQ="9"
REGISTRY="${REGISTRY:-/var/lib/aegl-model/registry.json}"
# whitelisted diagnostic summary (metadata only; the raw arg is never printed)
DIAG_SINK_DIR="/var/tmp/aegl-diag/$TASK_ID"
DIAG_HELPER="$PKG/bin/iap_diag_summary.py"
CURRENT_STAGE=""; FAIL_REPORTED=0

say() { printf '%s\n' "$*"; }
# Emit ONLY the structured CAMPAIGN_ROUND_DIAG lines already captured (never the raw
# stdout/stderr of the campaign).
emit_round_diag() { # <round.out>
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  grep -E '^CAMPAIGN_ROUND_DIAG ' -- "$f" || :
}
die() { FAIL_REPORTED=1; if [ -n "${FAIL_MARK:-}" ] && [ ! -e "$FAIL_MARK" ]; then : > "$FAIL_MARK" 2>/dev/null; fi; printf 'SMOKE_FAILED stage=%s reason=%s: %s\n' "${CURRENT_STAGE:-none}" "$1" "${2:-}" >&2; exit 1; }
require_root() { if [ "${SMOKE_ALLOW_NONROOT:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then die not_root "${CURRENT_STAGE}"; fi; }

ANCHOR="$(sha256sum "$PKG/MANIFEST.sha256" 2>/dev/null | awk '{print $1}')"; ANCHOR="${ANCHOR:-NOMANIFEST}"
mark() { mkdir -p "$LEDGER" || die ledger_dir "$LEDGER"; printf 'anchor=%s stage=%s\n' "$ANCHOR" "$1" > "$LEDGER/$1.done" || die ledger_write "$1"; }
done_marker() { local f="$LEDGER/$1.done"; if [ ! -f "$f" ]; then return 1; fi; if [ "$(cat "$f")" != "anchor=$ANCHOR stage=$1" ]; then say "MARKER_STALE $1"; return 1; fi; return 0; }

# --- operator-side execution (never root's HOME, never sudo -E) ------------------- #
_op_env() { if [ "$(id -u)" -eq 0 ]; then printf 'runuser'; else printf 'direct'; fi; }
as_op() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$OPERATOR" -- env -i HOME="$OPERATOR_HOME" PATH="$OP_PATH" BU_CDP_URL="$CDP_URL" LANG=C.UTF-8 "$@"; else env -i HOME="$OPERATOR_HOME" PATH="$OP_PATH" LANG=C.UTF-8 "$@"; fi; }
op_py() { local snippet="$1"; shift; as_op /usr/bin/python3 -c "$snippet" "$@"; }
# op_py_env <snippet> [VAR=VAL...] -- [args...]
op_py_env() {
  local snippet="$1"; shift
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  if [ "${1:-}" = "--" ]; then shift; fi
  as_op env "${envs[@]}" /usr/bin/python3 -c "$snippet" "$@"
}

# --- sandbox-identity access probes (PAM-free drop + ACL-aware access(2)) ---------- #
# The probe must answer the SAME question the kernel answers for the aegl-ai sandbox
# identity. Two host hazards are removed:
#   * runuser/PAM is not used to drop: a service account with a nologin shell and no
#     home is fine because setpriv execs the command directly (never a login shell);
#   * the host `test` binary is not trusted: some hosts ship a Rust/uutils coreutils
#     `test` that reads mode bits only and IGNORES POSIX ACLs, which false-negatively
#     rejects the aegl-ai traversal ACL on the task root. access(2) honors ACLs, so we
#     evaluate with os.access as the dropped identity instead.
AI_USER="aegl-ai"
AI_HOME="/home/aegl-ai"
AI_GROUP="$(id -gn "$AI_USER" 2>/dev/null)" || die ai_group "cannot resolve group of $AI_USER"
[ -n "$AI_GROUP" ] || die ai_group "empty group for $AI_USER"
AI_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ai_uid() { id -u "$AI_USER"; }
ai_gid() { id -g "$AI_USER"; }
# Drop to the sandbox identity with a CONTROLLED environment: never the caller's HOME
# (root's), never any inherited Git plumbing/env, never global/system Git config. This
# keeps the probe from reading /root/.gitconfig or ~/.config/git and from being steered
# by GIT_DIR / GIT_WORK_TREE / GIT_CONFIG_* leaking in from the parent shell.
as_ai() {
  setpriv --reuid="$(ai_uid)" --regid="$(ai_gid)" --clear-groups --no-new-privs -- \
    env -i PATH="$AI_PATH" LANG=C.UTF-8 HOME="$AI_HOME" \
        XDG_CONFIG_HOME="$AI_HOME/.config" XDG_CACHE_HOME="$AI_HOME/.cache" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
        "$@"
}
AI_ACCESS_ERR=""
_ACCESS_PY='import os,sys
sys.exit(0 if os.access(sys.argv[2], {"r":os.R_OK,"w":os.W_OK,"x":os.X_OK}[sys.argv[1]]) else 1)'
ai_access() { # <r|w|x> <path> -> rc 0 when $AI_USER may access <path> (parent traversal included)
  local mode="$1" path="$2" out
  out="$(as_ai /usr/bin/python3 -I -c "$_ACCESS_PY" "$mode" "$path" 2>&1)" || { AI_ACCESS_ERR="$out"; return 1; }
  return 0
}
# The gate operator also evaluates the worktree with real git (the Bridge contract check
# runs as the campaign/operator identity), so it too needs traverse on the task root.
# Same ACL-aware access(2) as $AI_USER — never the ACL-blind host `test` — via the
# operator's own environment (as_op, the operator's HOME, not root's).
op_access() { # <r|w|x> <path> -> rc 0 when $OPERATOR may access <path>
  local mode="$1" path="$2"
  as_op /usr/bin/python3 -I -c "$_ACCESS_PY" "$mode" "$path" >/dev/null 2>&1
}

# Read-only: first ancestor directory (root downward) the sandbox identity cannot
# traverse, or nothing when the whole chain is walkable.
chain_blocker() { # <path> -> prints the first blocking dir, or nothing
  local target="$1" p cur part; local -a parts=()
  p="$(realpath -e "$target" 2>/dev/null)" || { printf '%s' "$target"; return; }
  IFS=/ read -r -a parts <<< "${p#/}"
  cur=""
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    cur="$cur/$part"
    ai_access x "$cur" || { printf '%s' "$cur"; return; }
  done
}

# every other entry. Refuses on any surprise (missing/odd mask, conflicting entry,
# non-directory or symlink) instead of expanding access, and proves afterwards that the
# ONLY difference is the added aegl-ai x entry.
# Read-only walk of a required target's full ancestor chain. The ONLY directory that may

operator_state_path() {
  op_py 'import sys;sys.path.insert(0,sys.argv[1]);import bridge_state;print(bridge_state.state_dir())' "$STACK_BRIDGE"
}
assert_operator_state_path() {
  local got; got="$(operator_state_path 2>&1)" || die operator_state_failed "$got"
  [ "$got" = "$BRIDGE_DIR" ] || die operator_state_path "$got != $BRIDGE_DIR (root HOME must not be used)"
  [ -f "$BRIDGE_DIR/state.json" ] || die bridge_missing "$BRIDGE_DIR/state.json"
  [ ! -e "$BRIDGE_DIR/pending_result.json" ] || die bridge_pending "pending_result.json present"
  return 0
}

chain_now() {
  op_py 'import json,sys;d=json.load(open(sys.argv[1]));print("seq=%s nonce=%s in_reply_to=%s"%(d["expected_sequence"],d["expected_nonce"],d["expected_in_reply_to"]))' "$BRIDGE_DIR/state.json"
}

stack_hashes_ok() {
  # Runtime file pins generated from the promoted Stack commit
  # (f32d18a4f1479854d3c28bcf21b1e31391041243); campaign_supervisor.py is included
  # because this run actually invokes it. The check is strict — never relaxed.
  local f i=1 got want
  for f in orchestration/hermes/bridge/projects.py orchestration/hermes/bridge/protocol.py \
           orchestration/hermes/bridge/contract_executor.py orchestration/hermes/bridge/bridge_cli.py \
           orchestration/hermes/supervisor/campaign_supervisor.py; do
    case "$i" in 1) want=b09dd5e1a435d83383fbcc30ca440e96192e87f7a074b3972a4cc269c188b080 ;;
              2) want=d2e5c8d87ed42f37507266b308f92674182d1770af07aa50edcecbac59076f99 ;;
              3) want=ee68e51db72f068ee5a52328dd01ac1844082b1ee26cd2eb5516f6163af6c0a7 ;;
              4) want=16ab151de72bb99f9c7e5eaea51bedd2d456e35d0560c0a8f3fd7d70c518c3aa ;;
              5) want=d4f736cd70624621027070bf386c88821b79cef051c3a06b65921f4d916901c2 ;; esac
    got="$(sha256sum "$STACK/$f" 2>/dev/null | awk '{print $1}')"
    [ "$got" = "$want" ] || die stack_hash "$f=${got:-unreadable}"
    i=$((i+1))
  done
}

broker_has_ok() {
  # This package never installs the broker: it must already be the reviewed candidate.
  local got
  got="$(sha256sum "$BROKER_BIN" 2>/dev/null | awk '{print $1}')"
  [ "$got" = "$BROKER_SHA" ] \
    || die broker_hash "installed model_broker.py ${got:-unreadable} != $BROKER_SHA"
  say "BROKER_OK sha=$got"
}

# --- whitelisted diagnostic summary: metadata only, the raw arg is never printed ------ #
diag_summary() { # <events.jsonl>
  say "CONNECT_DIAG_BEGIN"
  if [ ! -f "$1" ]; then
    say "CONNECT_DIAG=ABSENT"
  elif [ ! -f "$DIAG_HELPER" ]; then
    say "CONNECT_DIAG=NO_HELPER"
  else
    /usr/bin/python3 "$DIAG_HELPER" "$1" 2>&1 || say "CONNECT_DIAG=SUMMARY_FAILED"
  fi
  say "CONNECT_DIAG_END"
}

# --------------------------------------------------------------------------- #
# --- the ONLY deployed change: add this task to the sandbox diagnostic allowlist ------- #
deployed_hashes(){ # hashes of the OTHER installed aegl-model files (must not change)
  local f
  for f in aegl-model-broker aegl-model-config model_broker.py git_meta_mounts.sh \
           capture_evidence.py diag_events.py bind_fd_exec.py sandbox_spec.py prepare_targets.py \
           exec_spec.py drop_verify.py loopback_shim.py model_config.py guard_hook_client.py \
           guard/contract_guard.py; do
    [ -f "$SANDBOX_DIR/$f" ] || die deployed_missing "$SANDBOX_DIR/$f"
    sha256sum "$SANDBOX_DIR/$f"
  done
}

stage_sandbox_diag() {
  require_root
  [ -f "$SANDBOX_PAYLOAD" ] || die sandbox_payload "missing payload: $SANDBOX_PAYLOAD"
  [ -f "$SANDBOX_BIN" ] || die sandbox_bin "missing installed sandbox: $SANDBOX_BIN"
  # BEFORE any replacement: the candidate must be the approved payload AND carry EXACTLY the
  # expected allowlist (all existing entries kept, only IAP-SMOKE-005 added).
  local ph
  ph="$(sha256sum "$SANDBOX_PAYLOAD" | awk '{print $1}')"
  [ "$ph" = "$SANDBOX_AFTER_SHA" ] || die sandbox_payload_hash "$ph != $SANDBOX_AFTER_SHA"
  grep -qxF -- "$SANDBOX_ALLOWLIST" "$SANDBOX_PAYLOAD" \
    || die sandbox_payload_allowlist "candidate does not carry exactly: $SANDBOX_ALLOWLIST"
  # the Git-metadata helper must already be deployed, exactly, and not a symlink
  [ -f "$SANDBOX_DIR/git_meta_mounts.sh" ] || die helper_missing "$SANDBOX_DIR/git_meta_mounts.sh"
  [ ! -L "$SANDBOX_DIR/git_meta_mounts.sh" ] || die helper_symlink "$SANDBOX_DIR/git_meta_mounts.sh"
  [ "$(sha256sum "$SANDBOX_DIR/git_meta_mounts.sh" | awk '{print $1}')" = "$EXPECT_HELPER_SHA" ] \
    || die helper_hash "$(stat -c '%U:%G %a' "$SANDBOX_DIR/git_meta_mounts.sh") $(sha256sum "$SANDBOX_DIR/git_meta_mounts.sh" | awk '{print $1}')"
  [ "$(stat -c '%U:%G %a' "$SANDBOX_DIR/git_meta_mounts.sh")" = "root:root 755" ] \
    || die helper_mode "$(stat -c '%U:%G %a' "$SANDBOX_DIR/git_meta_mounts.sh")"
  [ "$(sha256sum "$BROKER_BIN" | awk '{print $1}')" = "$BROKER_SHA" ] || die broker_unknown "$BROKER_BIN"
  [ ! -e "$SANDBOX_BIN.new" ] \
    || die sandbox_staging "$SANDBOX_BIN.new exists (unknown staged content; refusing to overwrite)"
  [ ! -e "$SANDBOX_DIR/git_meta_mounts.sh.new" ] \
    || die helper_staging "$SANDBOX_DIR/git_meta_mounts.sh.new exists (unknown staged content)"
  local before after snap_before snap_after
  before="$(sha256sum "$SANDBOX_BIN" | awk '{print $1}')"
  say "SANDBOX_BEFORE=$before"
  if [ "$before" = "$SANDBOX_AFTER_SHA" ]; then
    say "SANDBOX_ALREADY_WIRED (installed hash is already the new one)"
  else
    [ "$before" = "$SANDBOX_BEFORE_SHA" ] \
      || die sandbox_baseline "installed sandbox hash $before != expected baseline $SANDBOX_BEFORE_SHA"
    snap_before="$(deployed_hashes)"
    install -o root -g root -m 0755 -- "$SANDBOX_PAYLOAD" "$SANDBOX_BIN.new" || die sandbox_stage "$SANDBOX_BIN.new"
    mv -f -- "$SANDBOX_BIN.new" "$SANDBOX_BIN" || die sandbox_swap "$SANDBOX_BIN"
    after="$(sha256sum "$SANDBOX_BIN" | awk '{print $1}')"
    [ "$after" = "$SANDBOX_AFTER_SHA" ] || die sandbox_after "installed hash $after != $SANDBOX_AFTER_SHA"
    snap_after="$(deployed_hashes)"
    [ "$snap_before" = "$snap_after" ] \
      || die sandbox_side_effect "a deployed sibling changed (broker/model/credentials/guard must stay untouched)"
  fi
  grep -qxF -- "$SANDBOX_ALLOWLIST" "$SANDBOX_BIN" \
    || die sandbox_allowlist "allowlist line is not exactly the expected one"
  say "SANDBOX_OK hash=$SANDBOX_AFTER_SHA allowlist=IAP-SMOKE-005 (only addition)"
}

stage_preflight() {
  say "[preflight] baseline state / evidence / stack / state path"
  # no write of any kind may happen before the live Bridge is the expected one
  bridge_ok || die bridge_before_writes "$(chain_now)"
  # FIRST: read-only verification of every pre-existing 005 artifact — nothing is created,
  # owned, re-permissioned or rewritten before this passes.
  verify_existing_scene
  # ONLY THEN: the real chain snapshot is taken BEFORE any install or task write; an existing
  # one must already match and is never overwritten (a later snapshot proves nothing).
  if [ -e "$LEDGER/chain.before_prep" ]; then
    [ -s "$LEDGER/chain.before_prep" ] || die snapshot_empty "$LEDGER/chain.before_prep"
    [ "$(cat "$LEDGER/chain.before_prep")" = "$(chain_now)" ] \
      || die chain_snapshot_mismatch "$(cat "$LEDGER/chain.before_prep") != $(chain_now)"
    say "CHAIN_SNAPSHOT_REUSED $LEDGER/chain.before_prep"
  else
    mkdir -p "$LEDGER" || die ledger_dir
    chain_now > "$LEDGER/chain.before_prep" || die snapshot_write
    say "CHAIN_SNAPSHOT_SAVED $(cat "$LEDGER/chain.before_prep")"
  fi
  local st files dirty
  st="$(baseline_state)"
  say "PREFLIGHT_BASELINE_STATE=$st"
  case "$st" in
    ABSENT|ZHONG_EMPTY_INIT)
      say "PREFLIGHT_BASELINE=resumable ($st)" ;;
    ROOT_EMPTY_INIT)
      die git_meta_root_owned "run --stage repair-git-owner first (.git is a root-owned empty init)" ;;
    HAS_COMMIT)
      files="$(op_git -c core.quotePath=false ls-files | sort | paste -sd, -)"
      dirty="$(op_git status --porcelain)"
      [ "$files" = "$PLAN_FILE" ] || die baseline_foreign "tracked=$files (expected only the plan)"
      [ -z "$dirty" ] || die baseline_dirty "uncommitted changes present"
      head="$(op_git rev-parse HEAD)"
      [ "$head" = "$EXPECT_BASE" ] || die baseline_head "$head != $EXPECT_BASE"
      say "PREFLIGHT_BASELINE=approved commit=$head" ;;
    *)
      die baseline_unknown "unrecognised .git state; refusing to proceed" ;;
  esac
  [ ! -e "$WORKTREE/EVIDENCE.txt" ] || die evidence_exists "$WORKTREE/EVIDENCE.txt"
  stack_hashes_ok
  broker_has_ok
  assert_operator_state_path
  say "PREFLIGHT_OK evidence=absent stack=f32d18a broker=ab0d4c3 state=$(operator_state_path)"
}

# --- baseline identity: ALWAYS the operator (zhong), never root -------------------- #
iap_real() { realpath -e "$IAP" 2>/dev/null || die iap_unresolved "$IAP"; }
op_git() { local real; real="$(iap_real)"; if [ "$(id -u)" -eq 0 ]; then
    runuser -u "$OPERATOR" -- env -i HOME="$OPERATOR_HOME" PATH="$OP_PATH" LANG=C.UTF-8 git -c "safe.directory=$real" -C "$IAP" "$@"
  else env -i HOME="$OPERATOR_HOME" PATH="$OP_PATH" LANG=C.UTF-8 git -c "safe.directory=$real" -C "$IAP" "$@"; fi; }
# controller (root) git: exact command-scoped trust, errors propagate, no global config
ctl_git() { local path="$1"; shift; local real; real="$(realpath -e "$path" 2>/dev/null)" || die git_path_unresolved "$path"
  if [ "$(id -u)" -eq 0 ]; then
    git -c "safe.directory=$real" -C "$path" "$@"
  else
    git -c "safe.directory=$real" -C "$path" "$@"
  fi
}
ctl_git_argv() { local path="$1"; shift; printf 'git -c safe.directory=%s -C %s %s' "$(realpath -e "$path")" "$path" "$*"; }
wt_registered() { ctl_git "$IAP" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | grep -Fxq -- "$WORKTREE"; }

op_git_id() { # explicit identity for this run only; never writes global config
  printf '%s\n%s\n' "${IAP_GIT_NAME:-zgz314159}" "${IAP_GIT_EMAIL:-zgz314159@gmail.com}"
}

baseline_state() { # ABSENT | ZHONG_EMPTY_INIT | ROOT_EMPTY_INIT | HAS_COMMIT | UNKNOWN
  local gitd="$IAP/.git" owner objects idx=0 refs logs=0
  if [ ! -e "$gitd" ]; then printf 'ABSENT'; return 0; fi
  if [ ! -d "$gitd" ] || [ -L "$gitd" ]; then printf 'UNKNOWN'; return 0; fi
  owner="$(stat -c '%U' "$gitd")"
  objects="$(find "$gitd/objects" -type f 2>/dev/null | wc -l)"
  if [ -e "$gitd/index" ]; then idx=1; fi
  if [ -e "$gitd/logs" ]; then logs=1; fi
  refs="$(ls -A "$gitd/refs/heads" 2>/dev/null | wc -l)"
  if op_git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then printf 'HAS_COMMIT'; return 0; fi
  if [ "$objects" -eq 0 ] && [ "$idx" -eq 0 ] && [ "$refs" -eq 0 ] && [ "$logs" -eq 0 ]; then
    case "$owner" in
      "$OPERATOR") printf 'ZHONG_EMPTY_INIT' ;;
      root) printf 'ROOT_EMPTY_INIT' ;;
      *) printf 'UNKNOWN' ;;
    esac
    return 0
  fi
  printf 'UNKNOWN'
}

stage_baseline() {
  require_root
  # VERIFY ONLY. This entry never initialises, adds, commits or repairs anything: an
  # unexpected state stops the run so the operator can look at it.
  local st files dirty head
  st="$(baseline_state)"
  say "BASELINE_STATE=$st"
  [ "$st" = HAS_COMMIT ] || die baseline_unexpected "$st (this entry never creates or repairs a baseline)"
  files="$(op_git -c core.quotePath=false ls-files | sort | paste -sd, -)"
  [ "$files" = "$PLAN_FILE" ] || die baseline_foreign "tracked=$files (expected only the plan)"
  dirty="$(op_git status --porcelain)"
  [ -z "$dirty" ] || die baseline_dirty "uncommitted changes present"
  head="$(op_git rev-parse HEAD)"
  [ "$head" = "$EXPECT_BASE" ] || die baseline_head "$head != $EXPECT_BASE"
  say "BASELINE_VERIFIED commit=$head tracked=1 clean=1"
}

stage_worktree() {
  require_root
  local base; base="$(ctl_git "$IAP" rev-parse HEAD)" || die base_query
  install -d -m 0750 "$TASK_ROOT" || die task_root "$TASK_ROOT"
  if [ "$(id -u)" -eq 0 ]; then chown root:root "$TASK_ROOT" || die task_root_chown; fi
  if [ -e "$WORKTREE" ]; then
    wt_registered || die worktree_unknown "$WORKTREE exists but is not a registered worktree (preserved)"
    [ "$(ctl_git "$WORKTREE" rev-parse HEAD)" = "$base" ] || die worktree_head_mismatch
    [ -z "$(ctl_git "$WORKTREE" status --porcelain)" ] || die worktree_dirty "$WORKTREE (preserved)"
    say "WORKTREE_EXISTS_OK (verified, reusing)"
  else
    if wt_registered; then die worktree_registered_missing "$WORKTREE is registered but absent (preserved; no prune)"; fi
    ctl_git "$IAP" worktree add --detach "$WORKTREE" "$base" || die worktree_add "$WORKTREE"
  fi
  if [ "$(id -u)" -eq 0 ]; then chown -R aegl-ai:aegl-ai "$WORKTREE" || die worktree_chown; fi
  chmod -R u=rwX,go=rX "$WORKTREE" || die worktree_chmod
  local got; got="$(ctl_git "$WORKTREE" rev-parse HEAD)"
  [ "$got" = "$base" ] || die worktree_head "$got != $base"
  say "WORKTREE_OK $WORKTREE detached=$base"
}

stage_permissions() {
  require_root
  done_marker baseline || die prerequisite_not_done baseline
  local gitdir commondir
  gitdir="$(ctl_git "$WORKTREE" rev-parse --absolute-git-dir)" || die gitdir_resolve
  commondir="$(ctl_git "$WORKTREE" rev-parse --git-common-dir)" || die commondir_resolve
  case "$commondir" in /*) : ;; *) commondir="$WORKTREE/$commondir" ;; esac
  commondir="$(realpath -e "$commondir")" || die commondir_realpath
  say "GITDIR=$gitdir COMMONDIR=$commondir"
  # CHECK FIRST, GRANT LAST — and only on the TASK's OWN directories. The formal repository's
  # Git metadata is never widened: the helper copies only this task's worktree admin into a
  # per-task view and root mounts the shared metadata read-only, so neither the sandbox
  # identity nor the gate needs a new right on the formal .git.
  install -d -o "$AI_USER" -g "$AI_GROUP" -m 0750 "$SCRATCH" || die scratch
  if ! ai_access x "$TASK_ROOT"; then setfacl -m u:"$AI_USER":x "$TASK_ROOT" || die acl_task_root; fi
  if ! op_access x "$TASK_ROOT"; then setfacl -n -m u:"$OPERATOR":x "$TASK_ROOT" || die acl_task_root_operator; fi
  # the formal metadata must NOT be writable by the sandbox identity, and we must not make it so
  if ai_access w "$commondir"; then die formal_commondir_writable "$commondir writable by $AI_USER"; fi
  if ai_access w "$gitdir"; then die formal_gitdir_writable "$gitdir writable by $AI_USER"; fi
  if ai_access w "$commondir/objects" || ai_access w "$commondir/refs" || ai_access w "$commondir/config"; then
    die formal_metadata_writable "objects/refs/config writable by $AI_USER under $commondir"
  fi
  # the rights this task actually needs, checked (not granted) — report precisely and stop
  ai_access x "$TASK_ROOT" || die need_traverse "$AI_USER needs x on $TASK_ROOT"
  op_access x "$TASK_ROOT" || die need_traverse "$OPERATOR needs x on $TASK_ROOT"
  ai_access w "$WORKTREE" || die need_write "$AI_USER needs w on $WORKTREE"
  ai_access w "$SCRATCH" || die need_write "$AI_USER needs w on $SCRATCH"
  ai_access r "$WORKTREE/$PLAN_FILE" || die need_read "$AI_USER needs r on $WORKTREE/$PLAN_FILE"
  op_access r "$WORKTREE" || die need_read "$OPERATOR needs r on $WORKTREE"
  printf '%s\n%s\n' "$gitdir" "$commondir" > "$LEDGER/paths" || die ledger_paths
  say "PERMISSIONS_OK existing-access-only task-root-traverse=$AI_USER,$OPERATOR formal-git-metadata=untouched (no ACL added to $commondir)"
}

# --- live state acceptance: NEVER skipped by a done marker ----------------------------- #
registry_fields_ok() { # <path> <task> -> 0 only when all FOUR fields match exactly
  local reg="${REGISTRY:-$REGISTRY_PATH}" task="$1" want wt scr proj con got
  [ -f "$reg" ] || { REGISTRY_DIFF="registry unreadable: $reg"; return 1; }
  want="$(python3 - "$reg" "$task" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1], encoding="utf-8"))
e = reg.get(sys.argv[2]) or {}
print("\n".join(str(e.get(k) or "") for k in ("worktree", "scratch", "project", "contract_package")))
PY
)" || { REGISTRY_DIFF="registry unreadable/unparsable: $reg"; return 1; }
  got="$(printf '%s\n%s\n%s\n%s\n' "$TASK_ROOT/project" "$SCRATCH" "$IAP" "$PKG_DEST")"
  [ "$want" = "$got" ] || { REGISTRY_DIFF="wanted=[$got] registry=[$want]"; return 1; }
  return 0
}

verify_existing_scene() { # read-only; every already-present 005 artifact, wherever it lives
  require_root
  local any=0
  for p in "$TASK_ROOT" "$WORKTREE" "$SCRATCH" "$LEDGER" "$PKG_DEST"; do
    [ -L "$p" ] && die existing_symlink "$p is a symlink (preserved, not followed)"
  done
  [ -e "$TASK_ROOT" ] && [ ! -d "$TASK_ROOT" ] && die existing_unknown "$TASK_ROOT is not a directory"
  if [ -e "$PKG_DEST" ]; then
    any=1
    [ -f "$PKG_DEST/manifest.json" ] || die existing_contract "$PKG_DEST"
    [ "$(sha256sum "$PKG_DEST/manifest.json" | awk '{print $1}')" = "$EXPECT_MANIFEST_SHA" ] \
      || die existing_contract_hash "$(sha256sum "$PKG_DEST/manifest.json" | awk '{print $1}')"
    /usr/bin/python3 - "$PKG_DEST" <<'MEMPYP' || die existing_contract_members "$PKG_DEST"
import hashlib, json, os, sys
m = json.load(open(os.path.join(sys.argv[1], "manifest.json"), encoding="utf-8"))
for e in m.get("entries", []):
    f = os.path.join(sys.argv[1], e["path"])
    if not os.path.isfile(f) or hashlib.sha256(open(f, "rb").read()).hexdigest() != e["sha256"]:
        sys.exit("bad %s" % e["path"])
MEMPYP
  fi
  if [ -e "$REGISTRY" ]; then
    local has=0
    python3 - "$REGISTRY" "$TASK_ID" <<'PY' || die existing_registry_unreadable "$REGISTRY (read/parse failed; not treated as 'no 005')"
import json, sys
try:
    reg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:
    sys.stderr.write("%s: %s\n" % (type(exc).__name__, exc)); sys.exit(2)
sys.exit(0 if sys.argv[2] in reg else 1)
PY
    has=$?
    [ "$has" -eq 1 ] || { any=1; registry_fields_ok "$TASK_ID" || die existing_registry "$REGISTRY_DIFF"; }
  fi
  if [ -e "$TASK_ROOT/PREP-BINDING.json" ]; then
    any=1
    binding_accept "$TASK_ROOT/PREP-BINDING.json" "$WORKTREE" "$EXPECT_BASE" "$PKG_DEST"
  fi
  if [ -d "$LEDGER" ]; then
    any=1
    # an existing ledger without a prep-start snapshot is an abnormal scene: stop, never
    # backfill it here and then call the scene verified
    [ -f "$LEDGER/chain.before_prep" ] || die existing_ledger "$LEDGER exists without chain.before_prep"
    for m in "$LEDGER"/*.done; do
      [ -e "$m" ] || continue
      grep -q "^anchor=$ANCHOR stage=$(basename "$m" .done)$" "$m" \
        || die existing_marker "$m is stale (unknown anchor/stage)"
    done
  fi
  [ "$any" -eq 0 ] && say "EXISTING_SCENE=none (first prep)" || say "EXISTING_SCENE_VERIFIED"
}

verify_live_state() {
  require_root
  # 005's own scene, verified field by field — never trusted from a marker
  [ -d "$TASK_ROOT" ] && [ ! -L "$TASK_ROOT" ] || die live_task_root "$TASK_ROOT"
  [ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || die live_worktree "$WORKTREE"
  [ -d "$SCRATCH" ] && [ ! -L "$SCRATCH" ] || die live_scratch "$SCRATCH"
  gitdir="$(cat "$LEDGER/paths" 2>/dev/null | sed -n '1p')"
  commondir="$(cat "$LEDGER/paths" 2>/dev/null | sed -n '2p')"
  [ -n "$gitdir" ] && [ -n "$commondir" ] || die live_paths "no recorded git paths"
  [ "$(ctl_git "$WORKTREE" rev-parse --absolute-git-dir)" = "$gitdir" ] || die live_gitdir_changed
  local cq; cq="$(ctl_git "$WORKTREE" rev-parse --git-common-dir)"
  case "$cq" in /*) : ;; *) cq="$WORKTREE/$cq" ;; esac
  [ "$(realpath -e "$cq")" = "$commondir" ] || die live_commondir_changed
  [ "$(ctl_git "$WORKTREE" rev-parse HEAD)" = "$EXPECT_BASE" ] || die live_head
  # the 005 worktree's OWN clean state, keeping Git's real exit code
  local st sterr="$LEDGER/live.status.err" src=0
  st="$(ctl_git "$WORKTREE" status --porcelain 2>"$sterr")" || src=$?
  [ "$src" -eq 0 ] || die live_status_rc "rc=$src $(head -c 400 "$sterr" | tr '\n' ' ')"
  [ -z "$st" ] || die live_worktree_dirty "005 worktree is dirty: $st"
  # the formal IAP tree stays a SEPARATE, independent check
  [ -z "$(op_git status --porcelain)" ] || die live_formal_dirty "formal IAP tree is dirty"
  /usr/bin/python3 - "$PKG_DEST" <<'MEMPYP' || die live_contract_members "$PKG_DEST"
import hashlib, json, os, sys
m = json.load(open(os.path.join(sys.argv[1], "manifest.json"), encoding="utf-8"))
for e in m.get("entries", []):
    f = os.path.join(sys.argv[1], e["path"])
    if not os.path.isfile(f):
        sys.exit("missing %s" % e["path"])
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != e["sha256"]:
        sys.exit("hash %s" % e["path"])
MEMPYP
  # the ONE acceptor: content, owner, mode, non-symlink, and all three fields
  binding_accept "$TASK_ROOT/PREP-BINDING.json" "$WORKTREE" "$EXPECT_BASE" "$PKG_DEST"
  [ -f "$PKG_DEST/implementation-contract.json" ] || die live_contract_missing "$PKG_DEST"
  [ -f "$PKG_DEST/manifest.json" ] || die live_contract_manifest "$PKG_DEST"
  [ "$(sha256sum "$PKG_DEST/manifest.json" | awk '{print $1}')" = "$EXPECT_MANIFEST_SHA" ] \
    || die live_contract_hash "$(sha256sum "$PKG_DEST/manifest.json" | awk '{print $1}')"
  local rf="ok"
  registry_fields_ok "$TASK_ID" || rf="$REGISTRY_DIFF"
  [ "$rf" = "ok" ] || die live_registry "$rf"
  [ ! -e "$WORKTREE/EVIDENCE.txt" ] || die live_evidence "$WORKTREE/EVIDENCE.txt exists (prep must not create it)"
  say "LIVE_STATE_OK registry=4/4 contract=binding=$EXPECT_MANIFEST_SHA evidence=absent"
}

bridge_ok() { # 0 only for the expected live Bridge state — parsed independently
  local pending="${PENDING_PATH:-$BRIDGE_DIR/pending_result.json}"
  op_py 'import json,os,sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
pending = sys.argv[2]
ok = (p.get("status") == "WAITING_FOR_GPT"
      and str(p.get("expected_sequence")) == sys.argv[3]
      and not os.path.exists(pending))
if not ok:
    sys.stderr.write("bridge status=%s seq=%s pending=%s\n"
                     % (p.get("status"), p.get("expected_sequence"), os.path.exists(pending)))
sys.exit(0 if ok else 1)' "$BRIDGE_DIR/state.json" "$pending" "$EXPECT_BRIDGE_SEQ"
}

# --- in-sandbox Git metadata check (no model, no send, no shim) ------------------------ #
# The host-side probe below cannot see this: the sandbox overlays /home/zhong with a
# skeleton, so unless the worktree's Git metadata is re-mounted Git cannot resolve HEAD.
sandbox_check_cmd() { cat "$PKG/bin/gitmeta.check"; }

sandbox_git_check() {
  local cmd_file="$LEDGER/sandbox-git-check.cmd" out rc=0
  sandbox_check_cmd > "$cmd_file" || die probe_sandbox_cmd "$cmd_file"
  out="$( "$SANDBOX_BIN" --task "$TASK_ID" --check "$(cat "$cmd_file")" 2>&1 )" || rc=$?
  printf '%s\n' "$out" > "$LEDGER/sandbox-git-check.out"
  [ "$rc" -eq 0 ] || die probe_sandbox_exit "launcher --check exited $rc"
  printf '%s\n' "$out" | grep -qxF "COMMON=$EXPECT_COMMON" \
    || die probe_sandbox_common "$(printf '%s\n' "$out" | grep '^COMMON=' | tr '\n' ' ')"
  printf '%s\n' "$out" | grep -E '^(COMMON=|COMMON_RC=|REV_PARSE_RC=|REV_PARSE_HEAD=|STATUS_RC=|PERM_|CHECK_FAILURES=)' || true
  printf '%s\n' "$out" | grep -qxF 'REV_PARSE_RC=0' \
    || die probe_sandbox_rev_parse "rc=$rc $(printf '%s\n' "$out" | grep -E '^(COMMON=|COMMON_RC=|REV_PARSE_(RC|ERR)=)' | tr '\n' ' ')"
  printf '%s\n' "$out" | grep -qxF "REV_PARSE_HEAD=$EXPECT_BASE" \
    || die probe_sandbox_head "$(printf '%s\n' "$out" | grep '^REV_PARSE_HEAD=' | tr '\n' ' ')"
  printf '%s\n' "$out" | grep -qxF 'STATUS_RC=0' || die probe_sandbox_status "rc=$rc"
  local k
  for k in core refs objects config; do
    printf '%s\n' "$out" | grep -qxF "PERM_$k writable=False mount_ro=True" \
      || die probe_sandbox_perm "$k $(printf '%s\n' "$out" | grep "^PERM_$k " | tr '\n' ' ')"
  done
  printf '%s\n' "$out" | grep -qxF 'CHECK_FAILURES=0' || die probe_sandbox_fail "rc=$rc"
  say "PROBE_SANDBOX_GIT_OK HEAD=$EXPECT_BASE status=0 formal-metadata read-only (os.access + mount ro)"
}

stage_probe() {
  require_root
  local gitdir commondir base st head
  gitdir="$(sed -n '1p' "$LEDGER/paths")"; commondir="$(sed -n '2p' "$LEDGER/paths")"
  base="$(ctl_git "$IAP" rev-parse HEAD)"
  # Re-check the FULL ancestor chain of every required target with the same dropped
  # identity (read-only), so a breakpoint names the exact blocking directory.
  local q blk
  for q in "$TASK_ROOT" "$commondir" "$gitdir" "$WORKTREE" "$SCRATCH"; do
    blk="$(chain_blocker "$q")"; [ -z "$blk" ] || die probe_chain "$q blocked_at=$blk"
  done
  ai_access x "$TASK_ROOT" || die probe_traverse "$TASK_ROOT ${AI_ACCESS_ERR:-}"
  ai_access x "$commondir" || die probe_commondir "$commondir ${AI_ACCESS_ERR:-}"
  ai_access r "$WORKTREE/$PLAN_FILE" || die probe_read "$WORKTREE/$PLAN_FILE ${AI_ACCESS_ERR:-}"
  ai_access w "$WORKTREE" || die probe_write "$WORKTREE ${AI_ACCESS_ERR:-}"
  ai_access w "$SCRATCH" || die probe_scratch "$SCRATCH ${AI_ACCESS_ERR:-}"
  # Git is invoked with return code, stdout and stderr kept apart: rc decides pass/fail,
  # stdout is the value under test, stderr is diagnostics only (never mixed into it).
  local gerr="$LEDGER/probe.git.stderr" grc
  : > "$gerr" || die ledger_stderr "$gerr"
  head="$(as_ai git -c "safe.directory=$WORKTREE" -C "$WORKTREE" rev-parse HEAD 2>"$gerr")" \
    || { grc=$?; die probe_git "rc=$grc stderr=$(tr -d '\n' <"$gerr")"; }
  [ "$head" = "$base" ] || die probe_git_head "$head != $base"
  st="$(as_ai git -c "safe.directory=$WORKTREE" -C "$WORKTREE" status --porcelain 2>"$gerr")" \
    || { grc=$?; die probe_status "rc=$grc stderr=$(tr -d '\n' <"$gerr")"; }
  [ -z "$st" ] || die probe_dirty "$st"
  if ai_access w "$commondir/refs"; then die probe_refs "$commondir/refs writable"; fi
  if ai_access w "$commondir/config"; then die probe_config "config writable"; fi
  if ai_access w "$commondir/objects"; then die probe_objects "object DB writable"; fi
  if ai_access w "$IAP"; then die probe_formal "$IAP writable"; fi
  # same identity, same worktree — but inside the REAL sandbox mounts, not on the host
  sandbox_git_check
  say "PROBE_OK traverse/read/write(worktree,scratch)/git=HEAD+status; formal refs/config/objects/tree read-only (access(2), ACL-aware); in-sandbox git metadata OK"
}

stage_contract() {
  require_root
  done_marker baseline || die prerequisite_not_done baseline
  install -d -o root -g root -m 0755 /var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts || die contract_dir
  if [ ! -e "$PKG_DEST" ]; then
    cp -a "$CONTRACT_SRC" "$PKG_DEST" || die contract_copy
    chown -R root:root "$PKG_DEST" || die contract_chown
    chmod -R go-w "$PKG_DEST" || die contract_chmod
  fi
  local got; got="$(sha256sum "$PKG_DEST/manifest.json" | awk '{print $1}')"
  [ "$got" = "$EXPECT_MANIFEST_SHA" ] || die contract_hash "$got"
  [ "$(python3 -c "import json;print(json.load(open('$PKG_DEST/READY.json'))['status'])")" = READY ] || die contract_ready
  say "CONTRACT_OK $PKG_DEST"
}

binding_write() { # <path> <worktree> <commit> <contract_package>
  local path="$1"
  [ ! -e "$path" ] || die binding_exists "$path (refusing to overwrite; verify it instead)"
  printf '{"worktree":"%s","commit":"%s","contract_package":"%s"}\n' "$2" "$3" "$4" > "$path" || die binding_write
  chown root:root "$path" || die binding_chown
  chmod 0644 "$path" || die binding_chmod
}

binding_accept() { # <path> <worktree> <commit> <contract_package>
  local path="$1"
  [ -f "$path" ] || die binding_missing "$path"
  [ ! -L "$path" ] || die binding_symlink "$path"
  [ "$(stat -c '%U:%G %a' "$path")" = "root:root 644" ] || die binding_mode "$(stat -c '%U:%G %a' "$path")"
  /usr/bin/python3 - "$path" "$2" "$3" "$4" <<'BINDPY' || die binding_mismatch "$path (refusing to overwrite)"
import json, os, sys
b = json.load(open(sys.argv[1], encoding="utf-8"))
if os.path.realpath(b.get("worktree", "")) != os.path.realpath(sys.argv[2]):
    sys.exit("worktree")
if b.get("commit") != sys.argv[3]:
    sys.exit("commit")
if os.path.realpath(b.get("contract_package", "")) != os.path.realpath(sys.argv[4]):
    sys.exit("contract_package")
BINDPY
}

stage_binding() {
  require_root
  done_marker baseline || die prerequisite_not_done baseline
  local base path="$TASK_ROOT/PREP-BINDING.json"
  base="$(ctl_git "$IAP" rev-parse HEAD)"
  [ "$base" = "$EXPECT_BASE" ] || die binding_baseline "$base != $EXPECT_BASE"
  [ "$(ctl_git "$WORKTREE" rev-parse HEAD)" = "$base" ] || die binding_worktree_head
  if [ -e "$path" ]; then
    binding_accept "$path" "$WORKTREE" "$base" "$PKG_DEST"
    say "PREP_BINDING_REUSED (verified) commit=$base"
  else
    binding_write "$path" "$WORKTREE" "$base" "$PKG_DEST"
    binding_accept "$path" "$WORKTREE" "$base" "$PKG_DEST"
    say "PREP_BINDING_OK commit=$base"
  fi
}

stage_register() {
  require_root
  done_marker baseline || die prerequisite_not_done baseline
  local reg=/usr/local/lib/aegl-model-task/bin/aegl-model-task
  [ -x "$reg" ] || die registrar_missing "$reg"
  if "$reg" show --task-id "$TASK_ID" >/dev/null 2>&1; then say "REGISTER_EXISTS (verify only)"; else
    "$reg" register --task-id "$TASK_ID" --worktree "$WORKTREE" --scratch "$SCRATCH" \
      --project "$IAP" --contract-package "$PKG_DEST" || die register
  fi
  "$reg" show --task-id "$TASK_ID" || die register_show
  say "REGISTER_OK $TASK_ID"
}

stage_ready() {
  require_root
  assert_operator_state_path
  [ ! -e "$WORKTREE/EVIDENCE.txt" ] || die evidence_exists "$WORKTREE/EVIDENCE.txt"
  chain_now > "$LEDGER/chain.at_ready" || die ledger_chain
  say "READY_OK $(cat "$LEDGER/chain.at_ready")"
  say "NEXT(prep complete): no model was called and nothing was sent. Run --execute to send once."
}

# --- explicit, one-shot operator stages -------------------------------------------- #
stage_send() {
  require_root
  done_marker ready || die prerequisite_not_done ready
  verify_live_state           # a reused prep is re-verified before anything is sent
  assert_operator_state_path
  local now; now="$(chain_now)"
  local want; want="$(cat "$LEDGER/chain.at_ready")"
  [ "$now" = "$want" ] || die chain_changed "$now != $want"
  local seq nonce reply token text prev
  seq="$(sed -n 's/^seq=\([^ ]*\).*/\1/p' <<< "$want")"
  nonce="$(sed -n 's/.*nonce=\([^ ]*\).*/\1/p' <<< "$want")"
  reply="$(sed -n 's/.*in_reply_to=\([^ ]*\).*/\1/p' <<< "$want")"
  token="IAP-SMOKE-REQ-${nonce:0:16}"
  prev="$(op_py 'import sys;sys.path.insert(0,sys.argv[1]);import chatgpt_adapter as a;print(a.read_latest_assistant()["sha256"])' "$STACK_BRIDGE")" || die assistant_read "$prev"
  printf '%s\n' "$prev" > "$LEDGER/assistant.prev_sha"
  text=$(cat <<EOF
请在**你已完成的 assistant 回复**里原样输出下面这一个控制块（不要放进用户消息，不要改动任何字段）。请求标识：$token

<<<HERMES_TASK_V1>>>
{"protocol":"HERMES_TASK_V1","task_id":"$TASK_ID","sequence":$seq,"nonce":"$nonce","in_reply_to":"$reply","project":"ImageAnalysisFactory","action":"EXECUTE_CONTRACT","contract_package":"$PKG_DEST","contract_manifest_sha256":"$EXPECT_MANIFEST_SHA","risk":"LOW","max_runtime_s":120}
<<<END_HERMES_TASK_V1>>>
EOF
)
  local out; out="$(op_py_env 'import os,sys;sys.path.insert(0,sys.argv[1]);import chatgpt_adapter as a;print(a.send_once(os.environ["IAP_TEXT"],os.environ["IAP_TOKEN"],exact=False)["status"])' IAP_TEXT="$text" IAP_TOKEN="$token" -- "$STACK_BRIDGE" 2>&1)" || die send_failed "$out"
  case "$out" in
    CONFIRMED_SENT) say "SEND_OK status=CONFIRMED_SENT (single attempt, no resend)" ;;
    ALREADY_PRESENT) say "SEND_OK status=ALREADY_PRESENT (not an automatic-send PASS)" ;;
    SEND_UNCERTAIN) die send_uncertain "single attempt unconfirmed; no resend, human resolver required" ;;
    *) die send_status "$out" ;;
  esac
}

stage_wait() {
  require_root
  done_marker send || die prerequisite_not_done send
  local prev; prev="$(cat "$LEDGER/assistant.prev_sha" 2>/dev/null)" || die prev_missing
  local res; res="$(op_py 'import sys;sys.path.insert(0,sys.argv[1]);import chatgpt_adapter as a;r=a.wait_for_new_assistant(sys.argv[2],timeout=180);print(r["status"]);print(r.get("sha256",""))' "$STACK_BRIDGE" "$prev" 2>&1)" || die wait_failed "$res"
  local st; st="$(sed -n '1p' <<< "$res")"
  if [ "$st" != "NEW_ASSISTANT" ]; then
    say "WAITING_FOR_ASSISTANT (no new completed assistant reply within 180s); round will not run"
    printf 'WAITING\n' > "$LEDGER/assistant.state"
    return 0
  fi
  local block; block="$(op_py 'import sys,json;sys.path.insert(0,sys.argv[1]);import chatgpt_adapter as a,protocol as p
m=a.read_latest_assistant(); ex=p.extract_control_message(m.get("text"))
assert ex.get("status")==p.S_ACCEPTED, ex.get("status")
t=ex["task"]; print(json.dumps({"task_id":t["task_id"],"sequence":t["sequence"],"nonce":t["nonce"],"in_reply_to":t["in_reply_to"],"envelope_sha256":ex["task_envelope_sha256"]}))' "$STACK_BRIDGE" 2>&1)" || { say "WAITING_FOR_ASSISTANT (no single valid task block)"; printf 'WAITING\n' > "$LEDGER/assistant.state"; return 0; }
  printf '%s\n' "$block" > "$LEDGER/assistant.block.json"
  python3 - "$LEDGER/assistant.block.json" "$LEDGER/chain.at_ready" <<'PY' || die block_mismatch "assistant block does not match ready chain"
import json,sys
b=json.load(open(sys.argv[1])); c=dict(x.split("=",1) for x in open(sys.argv[2]).read().split())
assert b["task_id"]=="IAP-SMOKE-005" and str(b["sequence"])==c["seq"] and b["nonce"]==c["nonce"] and b["in_reply_to"]==c["in_reply_to"]
PY
  printf 'VERIFIED\n' > "$LEDGER/assistant.state"
  say "ASSISTANT_BLOCK_OK $(cat "$LEDGER/assistant.block.json")"
}

stage_round() {
  require_root
  [ "$(cat "$LEDGER/assistant.state" 2>/dev/null)" = VERIFIED ] || die not_verified "no verified assistant task block; refusing to run a round"
  assert_operator_state_path
  local now want; now="$(chain_now)"; want="$(cat "$LEDGER/chain.at_ready")"
  [ "$now" = "$want" ] || die chain_changed "$now != $want"
  local seq nonce reply rc=0 out verdict
  seq="$(sed -n 's/^seq=\([^ ]*\).*/\1/p' <<< "$want")"
  nonce="$(sed -n 's/.*nonce=\([^ ]*\).*/\1/p' <<< "$want")"
  reply="$(sed -n 's/.*in_reply_to=\([^ ]*\).*/\1/p' <<< "$want")"
  [ -f "$HELPER" ] || die helper "round verdict helper missing: $HELPER"
  out="$( ( cd "$STACK" && as_op env BRIDGE_DIR="$BRIDGE_DIR" /usr/bin/python3 orchestration/hermes/supervisor/campaign_cli.py run \
      --campaign-id "$CAMPAIGN_ID" --milestone S0 --start-sequence "$seq" --start-nonce "$nonce" \
      --start-in-reply-to "$reply" --max-rounds 1 --max-wall-seconds 900 --poll-seconds 5 ) 2>&1 )" || rc=$?
  printf '%s\n' "$out" > "$LEDGER/round.out"
  # Surface the structured diagnostic BEFORE judging any failure.
  emit_round_diag "$LEDGER/round.out"
  # Whitelisted phase summary (address index / family / elapsed only — never the raw arg).
  diag_summary "$DIAG_SINK_DIR/events.jsonl"
  say "ROUND_CAMPAIGN_RC=$rc"
  # rc=3 is shared by LIMIT_REACHED and SAFETY_STOP — never treat it as pass or fail alone.
  verdict="$(/usr/bin/python3 "$HELPER" --mode round --rc "$rc" --campaign-id "$CAMPAIGN_ID" \
      --supervisor-root "$SUPERVISOR_ROOT" --bridge-dir "$BRIDGE_DIR" \
      --task-id "$TASK_ID" --sequence "$seq" 2>&1)" || {
    printf '%s\n' "$verdict"
    die round_incomplete "$(printf '%s\n' "$verdict" | tr '\n' ' ')"
  }
  printf '%s\n' "$verdict"
  say "ROUND_DONE (one bridge round, max-rounds=1, verdict=COMPLETED)"
}

stage_accept() {
  require_root
  [ -s "$LEDGER/round.out" ] || die accept_missing "no round record: $LEDGER/round.out"
  [ -f "$HELPER" ] || die helper "accept verdict helper missing: $HELPER"
  local want seq diag_task verdict
  want="$(cat "$LEDGER/chain.at_ready")"
  seq="$(sed -n 's/^seq=\([^ ]*\).*/\1/p' <<< "$want")"
  diag_task="$(sed -n 's/^CAMPAIGN_ROUND_DIAG .*task_id=\([^ ]*\).*/\1/p' "$LEDGER/round.out" | tail -1)"
  [ "$diag_task" = "$TASK_ID" ] || die accept_diag_task "diagnostic task_id='${diag_task:-MISSING}' != $TASK_ID"
  verdict="$(/usr/bin/python3 "$HELPER" --mode accept --task-id "$TASK_ID" --sequence "$seq" \
      --bridge-dir "$BRIDGE_DIR" --round-out "$LEDGER/round.out" \
      --worktree "$WORKTREE" --prep-binding "$TASK_ROOT/PREP-BINDING.json" 2>&1)" || {
    printf '%s\n' "$verdict"
    die accept_failed "$(printf '%s\n' "$verdict" | tr '\n' ' ')"
  }
  printf '%s\n' "$verdict"
  say "ACCEPT_EVIDENCE_OK sha256=$(sha256sum "$WORKTREE/EVIDENCE.txt" | awk '{print $1}')"
}

PREP_STAGES=(preflight sandbox_diag baseline worktree permissions contract binding register probe ready)
EXEC_STAGES=(send wait round accept)
main() {
  set -Eeuo pipefail
  FAIL_MARK="${TMPDIR:-/tmp}/.iap-smoke-fail.$$"; export FAIL_MARK
  rm -f "$FAIL_MARK" 2>/dev/null || if [ -e "$FAIL_MARK" ]; then say "FAIL_MARK_CLEANUP_FAILED"; fi
  trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$FAIL_REPORTED" != 1 ] && { [ ! -e "${FAIL_MARK:-/nonexistent}" ]; }; then printf "SMOKE_ABORT stage=%s rc=%s cmd=%.160s\n" "${CURRENT_STAGE:-none}" "$rc" "$BASH_COMMAND" >&2; fi' EXIT
  local mode=prep only=""
  while [ $# -gt 0 ]; do case "$1" in --execute) mode=execute; shift ;; --stage) only="${2:-}"; shift 2 ;; --status) mode=status; shift ;; *) die usage "$1" ;; esac; done
  if [ "$mode" = status ]; then say "anchor=$ANCHOR ledger=$LEDGER"; ls -1 "$LEDGER" 2>/dev/null || say "(no stages)"; cat "$BRIDGE_DIR/state.json" 2>/dev/null; return 0; fi
  local stages=()
  if [ -n "${SMOKE_PREP_STAGES:-}" ]; then IFS=: read -r -a stages <<< "$SMOKE_PREP_STAGES"
  else stages=("${PREP_STAGES[@]}"); fi
  if [ "$mode" = execute ]; then stages+=("${EXEC_STAGES[@]}"); fi
  if [ -n "$only" ]; then CURRENT_STAGE="$only"; "stage_${only//-/_}"; mark "$only"; return 0; fi
  local s
  local force=" preflight verify_live_state "
  for s in "${stages[@]}"; do
    case "$force" in *" $s "*) : ;; *) if done_marker "$s"; then say "SKIP $s (done)"; continue; fi ;; esac
    CURRENT_STAGE="$s"; "stage_${s//-/_}"; mark "$s"
  done
  if [ "$mode" = prep ]; then
    verify_live_state
    bridge_ok || die bridge_before_prep "$(chain_now)"
    [ "$(cat "$LEDGER/chain.before_prep" 2>/dev/null)" = "$(chain_now)" ] \
      || die chain_changed_during_prep "$(chain_now) != $(cat "$LEDGER/chain.before_prep" 2>/dev/null)"
    [ ! -e "$WORKTREE/EVIDENCE.txt" ] || die evidence_created "prep must never create EVIDENCE.txt"
    say "BRIDGE_OK status=WAITING_FOR_GPT seq=$EXPECT_BRIDGE_SEQ pending=ABSENT unchanged_during_prep=1"
    say "PREP_COMPLETE (live state verified; no model called, nothing sent, no EVIDENCE.txt)"
  fi
}
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
