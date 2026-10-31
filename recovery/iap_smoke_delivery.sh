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
CONTRACT_SRC="$PKG/contract/IAP-SMOKE-001"
IAP="${IAP:-/home/zhong/AndroidStudioProjects/ImageAnalysisFactory}"
STACK="${STACK:-/home/zhong/Projects/Google-Android-Agent-Development-Stack}"
TASK_ID="IAP-SMOKE-001"
TASK_ROOT="${TASK_ROOT:-/var/tmp/IAP-SMOKE-001}"
WORKTREE="${WORKTREE:-$TASK_ROOT/project}"
SCRATCH="${SCRATCH:-$TASK_ROOT/scratch}"
PKG_DEST="/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/IAP-SMOKE-001"
BRIDGE_DIR="/home/zhong/.local/state/google-android-agent-stack/bridge"
STACK_BRIDGE="$STACK/orchestration/hermes/bridge"
PLAN_FILE="Command_Code_DeepSeek_大规模图片智能分析工厂_建设方案_v1.0.md"
EXPECT_MANIFEST_SHA="bfa09df94e7736ab79aa9e6f356b0fd335a0b64aa0a3c11eb0477b66e2471186"
EXPECT_BASE="${EXPECT_BASE:-177680708739a72a0d70bc6a9664245b00a2ef08}"
OPERATOR="zhong"; OPERATOR_HOME="/home/zhong"; OP_PATH="/usr/local/bin:/usr/bin:/bin:/home/zhong/.local/bin"
CDP_URL="http://127.0.0.1:9333"
LEDGER="${LEDGER:-/var/lib/aegl-smoke/$TASK_ID}"
CURRENT_STAGE=""; FAIL_REPORTED=0

say() { printf '%s\n' "$*"; }
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
  local f i=1 got want
  for f in orchestration/hermes/bridge/projects.py orchestration/hermes/bridge/protocol.py \
           orchestration/hermes/bridge/contract_executor.py orchestration/hermes/bridge/bridge_cli.py; do
    case "$i" in 1) want=b09dd5e1a435d83383fbcc30ca440e96192e87f7a074b3972a4cc269c188b080 ;;
              2) want=d2e5c8d87ed42f37507266b308f92674182d1770af07aa50edcecbac59076f99 ;;
              3) want=c4a612cc8533baa8433bd2040a2ea91d8590b79c87450454f3bddb2fac0dbcd5 ;;
              4) want=15e3b14042730b3e7bb4aaab79d28182b3ace5bdd7a3aa022c3ebb9940cdc2e8 ;; esac
    got="$(sha256sum "$STACK/$f" 2>/dev/null | awk '{print $1}')"
    [ "$got" = "$want" ] || die stack_hash "$f=${got:-unreadable}"
    i=$((i+1))
  done
}

# --------------------------------------------------------------------------- #
stage_preflight() {
  say "[preflight] baseline state / evidence / stack / state path"
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
  assert_operator_state_path
  say "PREFLIGHT_OK evidence=absent stack=0b04e179 state=$(operator_state_path)"
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
  local st; st="$(baseline_state)"
  say "BASELINE_STATE=$st"
  case "$st" in
    ROOT_EMPTY_INIT) die git_meta_root_owned "run --stage repair-git-owner (scoped to .git) before baseline" ;;
    UNKNOWN) die baseline_unknown "unexpected .git state; refusing init/add/commit" ;;
    HAS_COMMIT)
      local files dirty
      files="$(op_git -c core.quotePath=false ls-files | sort | paste -sd, -)"
      dirty="$(op_git status --porcelain)"
      [ "$files" = "$PLAN_FILE" ] || die baseline_foreign "tracked=$files (expected only the plan)"
      [ -z "$dirty" ] || die baseline_dirty "uncommitted changes present"
      say "BASELINE_EXISTS_OK commit=$(op_git rev-parse HEAD) tracked=1"
      return 0 ;;
    ABSENT|ZHONG_EMPTY_INIT)
      local id n e
      id="$(op_git_id)"; n="$(sed -n '1p' <<< "$id")"; e="$(sed -n '2p' <<< "$id")"
      if [ "$st" = ABSENT ]; then op_git init -q -b main || die git_init "$IAP"; fi
      op_git -c user.name="$n" -c user.email="$e" add -- "$PLAN_FILE" || die git_add "$PLAN_FILE"
      op_git -c user.name="$n" -c user.email="$e" commit -q -m "IAP baseline: plan only" || die git_commit
      local files; files="$(op_git -c core.quotePath=false ls-files | sort | paste -sd, -)"
      [ "$files" = "$PLAN_FILE" ] || die baseline_scope "tracked=$files"
      say "BASELINE_OK author=$n commit=$(op_git rev-parse HEAD) tracked=1" ;;
  esac
}

stage_repair_git_owner() { # root: scoped repair of THIS run's root-created empty init
  require_root
  local gitd="$IAP/.git" objects refs extra
  [ -d "$gitd" ] || die repair_absent "$gitd"
  [ ! -L "$gitd" ] || die repair_symlink "$gitd"
  [ "$(stat -c '%U' "$gitd")" = root ] || die repair_not_root_owned "$(stat -c '%U' "$gitd")"
  objects="$(find "$gitd/objects" -type f 2>/dev/null | wc -l)"
  refs="$(ls -A "$gitd/refs/heads" 2>/dev/null | wc -l)"
  [ "$objects" -eq 0 ] || die repair_objects "objects=$objects (not an empty init)"
  [ "$refs" -eq 0 ] || die repair_refs "refs/heads non-empty"
  [ ! -e "$gitd/index" ] || die repair_index "index exists"
  [ ! -e "$gitd/logs" ] || die repair_logs "logs exist"
  extra="$(find "$IAP" -mindepth 1 -maxdepth 1 ! -name .git ! -name "$PLAN_FILE" -print -quit)"
  [ -z "$extra" ] || die repair_tree "unexpected member: $extra"
  chown -R "$OPERATOR:$OPERATOR" "$gitd" || die repair_chown
  say "REPAIR_OK scope=$gitd owner=$OPERATOR (no delete/reset/clean; business tree untouched)"
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
  install -d -o aegl-ai -g aegl-ai -m 0750 "$SCRATCH" || die scratch
  setfacl -m u:aegl-ai:x "$TASK_ROOT" || die acl_task_root
  setfacl -m u:aegl-ai:x "$commondir" || die acl_commondir
  setfacl -R -m u:aegl-ai:rX "$commondir/objects" "$commondir/refs" || die acl_objects_refs
  if [ -e "$gitdir/HEAD" ]; then setfacl -m u:aegl-ai:r "$gitdir/HEAD" || die acl_gitdir_head; fi
  if [ -e "$commondir/config" ]; then setfacl -m u:aegl-ai:r "$commondir/config" || die acl_config; fi
  if [ -e "$commondir/packed-refs" ]; then setfacl -m u:aegl-ai:r "$commondir/packed-refs" || die acl_packed; fi
  setfacl -R -m u:aegl-ai:rwX "$gitdir" || die acl_admin "$gitdir"
  printf '%s\n%s\n' "$gitdir" "$commondir" > "$LEDGER/paths" || die ledger_paths
  say "ACL_OK admin=$gitdir (rwX) objects/refs=$commondir (rX)"
}

stage_probe() {
  require_root
  local gitdir commondir base st head
  gitdir="$(sed -n '1p' "$LEDGER/paths")"; commondir="$(sed -n '2p' "$LEDGER/paths")"
  base="$(ctl_git "$IAP" rev-parse HEAD)"
  runuser -u aegl-ai -- test -x "$TASK_ROOT" || die probe_traverse "$TASK_ROOT"
  runuser -u aegl-ai -- test -x "$commondir" || die probe_commondir "$commondir"
  runuser -u aegl-ai -- test -r "$WORKTREE/$PLAN_FILE" || die probe_read
  runuser -u aegl-ai -- test -w "$WORKTREE" || die probe_write
  runuser -u aegl-ai -- test -w "$SCRATCH" || die probe_scratch
  head="$(runuser -u aegl-ai -- git -c "safe.directory=$WORKTREE" -C "$WORKTREE" rev-parse HEAD 2>&1)" || die probe_git "$head"
  [ "$head" = "$base" ] || die probe_git_head "$head != $base"
  st="$(runuser -u aegl-ai -- git -c "safe.directory=$WORKTREE" -C "$WORKTREE" status --porcelain 2>&1)" || die probe_status "$st"
  [ -z "$st" ] || die probe_dirty "$st"
  runuser -u aegl-ai -- test ! -w "$commondir/refs" || die probe_refs "$commondir/refs writable"
  runuser -u aegl-ai -- test ! -w "$commondir/config" || die probe_config "config writable"
  runuser -u aegl-ai -- test ! -w "$commondir/objects" || die probe_objects "object DB writable"
  runuser -u aegl-ai -- test ! -w "$IAP" || die probe_formal "$IAP writable"
  say "PROBE_OK traverse/read/write(worktree,scratch)/git=HEAD+status; formal refs/config/objects/tree read-only"
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

stage_binding() {
  require_root
  done_marker baseline || die prerequisite_not_done baseline
  local base; base="$(ctl_git "$IAP" rev-parse HEAD)"
  printf '{"worktree":"%s","commit":"%s"}\n' "$WORKTREE" "$base" > "$TASK_ROOT/PREP-BINDING.json" || die binding_write
  chown root:root "$TASK_ROOT/PREP-BINDING.json" || die binding_chown
  chmod 0644 "$TASK_ROOT/PREP-BINDING.json" || die binding_chmod
  say "PREP_BINDING_OK commit=$base"
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
assert b["task_id"]=="IAP-SMOKE-001" and str(b["sequence"])==c["seq"] and b["nonce"]==c["nonce"] and b["in_reply_to"]==c["in_reply_to"]
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
  local seq nonce reply
  seq="$(sed -n 's/^seq=\([^ ]*\).*/\1/p' <<< "$want")"
  nonce="$(sed -n 's/.*nonce=\([^ ]*\).*/\1/p' <<< "$want")"
  reply="$(sed -n 's/.*in_reply_to=\([^ ]*\).*/\1/p' <<< "$want")"
  ( cd "$STACK" && as_op env BRIDGE_DIR="$BRIDGE_DIR" /usr/bin/python3 orchestration/hermes/supervisor/campaign_cli.py run \
      --campaign-id IAP-SMOKE --milestone S0 --start-sequence "$seq" --start-nonce "$nonce" \
      --start-in-reply-to "$reply" --max-rounds 1 --max-wall-seconds 900 --poll-seconds 5 ) || die round "campaign_cli rc=$?"
  say "ROUND_DONE (one bridge round, max-rounds=1)"
}

stage_accept() {
  require_root
  [ -s "$WORKTREE/EVIDENCE.txt" ] || die evidence_missing
  python3 - "$WORKTREE/EVIDENCE.txt" "$TASK_ROOT/PREP-BINDING.json" <<'PY' || die evidence_mismatch "EVIDENCE does not match PREP-BINDING/identity"
import json,re,sys
ev=[l.rstrip("\n") for l in open(sys.argv[1],encoding="utf-8")]
b=json.load(open(sys.argv[2],encoding="utf-8"))
wt,commit=b["worktree"],b["commit"]
if len(ev)!=4: print("lines=%d"%len(ev)); raise SystemExit(1)
if ev[0]!="id -un: aegl-ai": print(ev[0]); raise SystemExit(1)
if ev[1]!="pwd: "+wt: print(ev[1]); raise SystemExit(1)
if ev[2]!="git rev-parse HEAD: "+commit: print(ev[2]); raise SystemExit(1)
m=re.fullmatch(r"python3 --version: Python (3\.\d+\.\d+)", ev[3])
if not m: print(ev[3]); raise SystemExit(1)
print("OBSERVED_SANDBOX_PYTHON=%s"%m.group(1))
PY
  if pgrep -f "hermes -p android-stack" >/dev/null 2>&1; then die process_left hermes; fi
  if pgrep -f aegl-hermes-sandbox >/dev/null 2>&1; then die process_left sandbox; fi
  say "ACCEPT_EVIDENCE_OK sha256=$(sha256sum "$WORKTREE/EVIDENCE.txt" | awk '{print $1}')"
  say "ACCEPT_PROCESSES_OK"
  say "ACCEPT_SEND=judge from the round output (CONFIRMED_SENT required; ALREADY_PRESENT/manual != auto-send PASS)"
}

PREP_STAGES=(preflight baseline worktree permissions probe contract binding register ready)
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
  for s in "${stages[@]}"; do
    if done_marker "$s"; then say "SKIP $s (done)"; continue; fi
    CURRENT_STAGE="$s"; "stage_${s//-/_}"; mark "$s"
  done
  if [ "$mode" = prep ]; then say "PREP_COMPLETE (no model called, nothing sent)"; fi
}
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
