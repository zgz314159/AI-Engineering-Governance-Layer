#!/usr/bin/env bash
# Root-only trusted delivery for GT1: import final tip -> pre-CAS -> broker
# register/record/promote -> candidate cleanup -> formal sync -> install from
# the formal object store -> temporary-registry root acceptance.
#
# The candidate arrives as a trusted bundle prepared by zhong and copied into a
# root-controlled input directory readable by aegl-promote. aegl-promote never
# reads the original zhong-private development object store. The root process
# only orchestrates, verifies hashes, runs the install/accept scripts from a
# root-exclusive directory, and cleans only explicitly allocated paths.
set -euo pipefail

TIP=""; BUNDLE=""; BUNDLE_SHA=""; AEGL=""
PAYLOAD="e5f31c8227353e60683c86a6092b93561da30c74"
BASELINE="d36f073ba98fd00e2678d773d06aa44723a0b728"
CLI_REL="bin/aegl-model-task"
MOD_REL="recovery/model_task_registry.py"
CLI_SHA="edb38c2155f617417c8f225128144fba94c822db317a799613fa5e9203669b6e"
MOD_SHA="0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de"
TARGET="/usr/local/lib/aegl-model-task"
TASK_ID="gt1-delivery-$(date +%Y%m%dT%H%M%S)-$$"
SOCK="/run/aegl-promote/broker.sock"
BROKER_BIN="/usr/local/lib/aegl-promote/aegl-promote-broker"
BROKER_USER="aegl-promote"
AI_USER="aegl-ai"
BROKER_REG="/var/lib/aegl-promote/registry.json"

say() { printf '%s\n' "$*"; }
die() { printf 'GT1_DELIVERY_ERROR: %s\n' "$*" >&2; exit 1; }
stop() { printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'GT1_DELIVERY_ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tip) TIP="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --bundle-sha256) BUNDLE_SHA="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root from a root-exclusive copy"
[ -n "$TIP" ] && [ "${#TIP}" -eq 40 ] || die "--tip <40-hex> required"
case "$TIP" in [0-9a-f]*) ;; *) die "--tip must be 40-hex" ;; esac
[ "$TIP" != "$PAYLOAD" ] || die "--tip must include the delivery files, not only the payload"
[ -n "$BUNDLE" ] && [ -f "$BUNDLE" ] || die "--bundle file required"
[ ! -L "$BUNDLE" ] || die "bundle must not be a symlink"
[ -n "$BUNDLE_SHA" ] && [ "${#BUNDLE_SHA}" -eq 64 ] || die "--bundle-sha256 <64-hex> required"
case "$BUNDLE_SHA" in *[!0-9a-f]*) die "--bundle-sha256 must be lowercase 64-hex" ;; esac
[ -n "$AEGL" ] || die "--aegl formal repo required"
for tool in runuser git setfacl python3 sha256sum tar mktemp realpath stat sed grep rmdir chmod chown rm; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool $tool"
done
[ -x "$BROKER_BIN" ] || die "broker client missing: $BROKER_BIN"
[ -S "$SOCK" ] || die "broker socket missing: $SOCK"
id "$BROKER_USER" >/dev/null 2>&1 || die "missing user $BROKER_USER"
id "$AI_USER" >/dev/null 2>&1 || die "missing user $AI_USER"
[ ! -e "$TARGET" ] || die "install target already exists: $TARGET"
[ "$(stat -c '%U:%G %a' /usr/local/lib)" = "root:root 755" ] \
  || die "untrusted /usr/local/lib: $(stat -c '%U:%G %a' /usr/local/lib)"
[ "$(stat -c '%U:%G' "$BUNDLE")" = "root:root" ] || die "bundle must be root-owned"
BUNDLE_MODE="$(stat -c '%a' "$BUNDLE")"
if (( (8#$BUNDLE_MODE & 8#022) != 0 )); then die "bundle must not be group/other writable"; fi
printf '%s  %s\n' "$BUNDLE_SHA" "$BUNDLE" | sha256sum -c - >/dev/null || die "bundle hash mismatch"
runuser -u "$BROKER_USER" -- test -r "$BUNDLE" || die "bundle not readable by $BROKER_USER"
runuser -u "$BROKER_USER" -- test -x "$(dirname "$BUNDLE")" || die "bundle dir not traversable by $BROKER_USER"
runuser -u "$BROKER_USER" -- env HOME=/tmp GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$AEGL" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "formal repo is not a work tree: $AEGL"

as_broker() { runuser -u "$BROKER_USER" -- env HOME=/tmp GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$@"; }
git_aegl_broker() { as_broker git -C "$AEGL" "$@"; }

broker_client_call() {
  local label="$1" req="$2" as_user="${3:-}" out="" rc=0
  set +e
  if [ -n "$as_user" ]; then
    out="$(runuser -u "$as_user" -- env HOME=/tmp AEGL_BROKER_SOCKET="$SOCK" \
      "$BROKER_BIN" client --socket "$SOCK" --request "$req" 2>&1)"
    rc=$?
  else
    out="$(AEGL_BROKER_SOCKET="$SOCK" "$BROKER_BIN" client --socket "$SOCK" --request "$req" 2>&1)"
    rc=$?
  fi
  set -e
  say "BROKER_${label}_RC=$rc"
  say "BROKER_${label}_JSON=$out"
  BROKER_LAST_RC=$rc
  BROKER_LAST_JSON=$out
}

broker_decision() {
  printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")' 2>/dev/null
}
broker_field() {
  printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$2" 2>/dev/null
}
require_decision() {
  local label="$1" want="$2" dec
  dec="$(broker_decision "$BROKER_LAST_JSON")"
  [ "$dec" = "$want" ] \
    || stop "broker_${label}_refused" "$label decision=$dec want=$want rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
}

EXT=""; RDIR=""; DRDIR=""; DELIVERY_SUCCEEDED=0
CLEAN_PATHS=()

cleanup_all() {
  local incoming=$?
  local final="$incoming"
  local p d

  if [ -n "${EXT:-}" ] && [ -d "${EXT}/wt" ]; then
    if ! as_broker git -C "$AEGL" worktree remove "$EXT/wt" >/dev/null 2>&1; then
      printf 'CLEANUP_ERROR: worktree remove failed; keeping %s/wt\n' "$EXT" >&2
      final=1
    elif ! rmdir "$EXT" 2>/dev/null; then
      printf 'CLEANUP_ERROR: EXT not empty after worktree remove: %s\n' "$EXT" >&2
      final=1
    else
      EXT=""
    fi
  fi

  for p in ${CLEAN_PATHS[@]+"${CLEAN_PATHS[@]}"}; do
    [ -n "$p" ] || continue
    if [ -f "$p" ]; then
      rm -f "$p" || final=1
    fi
  done
  if [ -n "${DRDIR:-}" ]; then
    for d in "$DRDIR/bin" "$DRDIR/recovery" "$DRDIR/docs"; do
      [ -d "$d" ] || continue
      rmdir "$d" 2>/dev/null || {
        printf 'CLEANUP_ERROR: directory not empty (kept): %s\n' "$d" >&2
        final=1
      }
    done
  fi
  for d in "${RDIR:-}" "${DRDIR:-}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    rmdir "$d" 2>/dev/null || {
      printf 'CLEANUP_ERROR: directory not empty (kept): %s\n' "$d" >&2
      final=1
    }
  done

  if [ "$incoming" -ne 0 ]; then final="$incoming"; fi
  if [ "$final" -ne 0 ]; then
    printf 'GT1_DELIVERY_CLEANUP_FINAL=%s (no success marker)\n' "$final" >&2
    exit "$final"
  fi
  if [ "$DELIVERY_SUCCEEDED" -ne 1 ]; then
    printf 'GT1_DELIVERY_CLEANUP_FINAL=1 (no success marker)\n' >&2
    exit 1
  fi
  say "GT1_DELIVERY_RESULT=OK tip=$TIP"
  say "GT1_FORMAL_SYNC=OK"
  say "GT1_INSTALL=OK"
  say "GT1_ROOT_ACCEPTANCE=PASS (temporary registry)"
}
trap cleanup_all EXIT

# independent broker task id; refuse to reuse an existing registration
if [ -e "$BROKER_REG" ]; then
  set +e
  python3 - "$BROKER_REG" "$TASK_ID" <<'PY'
import json
import sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if sys.argv[2] in data else 1)
PY
  reg_rc=$?
  set -e
  case "$reg_rc" in
    0) stop task_id_exists "$TASK_ID already present in $BROKER_REG" ;;
    1) : ;;
    *) stop broker_registry_unreadable "$BROKER_REG" ;;
  esac
fi

# 1) import the final tip from the trusted bundle into the formal object store
say "STAGE=import"
as_broker git -C "$AEGL" bundle verify "$BUNDLE" || stop bundle_verify_failed
HEADS="$(as_broker git bundle list-heads "$BUNDLE")" || stop bundle_heads_failed
printf '%s\n' "$HEADS" | grep -q "^$TIP refs/heads/gt1/model-task-registry$" \
  || stop bundle_head_mismatch "$HEADS"
as_broker git -C "$AEGL" fetch "$BUNDLE" \
  "refs/heads/gt1/model-task-registry:refs/heads/gt1/model-task-registry" \
  || stop bundle_fetch_failed
git_aegl_broker cat-file -e "$TIP^{commit}" || stop tip_object_missing "$TIP"
git_aegl_broker merge-base --is-ancestor "$PAYLOAD" "$TIP" || stop payload_not_ancestor "$PAYLOAD"
git_aegl_broker merge-base --is-ancestor "$BASELINE" "$TIP" || stop baseline_not_ancestor "$BASELINE"
test "$(git_aegl_broker rev-parse refs/heads/gt1/model-task-registry)" = "$TIP" \
  || stop bundle_ref_mismatch
test "$(git_aegl_broker show "$TIP:$CLI_REL" | sha256sum | awk '{print $1}')" = "$CLI_SHA" \
  || stop payload_cli_hash_mismatch
test "$(git_aegl_broker show "$TIP:$MOD_REL" | sha256sum | awk '{print $1}')" = "$MOD_SHA" \
  || stop payload_module_hash_mismatch

# 2) extract and source the existing formal sync helpers (trusted formal object store)
say "STAGE=pre_cas"
RDIR="$(mktemp -d /root/gt1-delivery.XXXXXX)" || die "mktemp RDIR failed"
chmod 0700 "$RDIR"
CLEAN_PATHS+=("$RDIR/formal-sync-lib.sh")
as_broker git -C "$AEGL" show "$TIP:recovery/keeplab-appprojects-exec.sh" \
  | sed -n '/^# BEGIN_FORMAL_SYNC$/,/^# END_FORMAL_SYNC$/p' > "$RDIR/formal-sync-lib.sh"
[ -s "$RDIR/formal-sync-lib.sh" ] || stop formal_sync_lib_empty
grep -q 'sync_formal_to_tip' "$RDIR/formal-sync-lib.sh" || stop formal_sync_lib_incomplete
OP_USER="$BROKER_USER"
# shellcheck disable=SC1090
source "$RDIR/formal-sync-lib.sh"
command -v formal_pre_cas_check >/dev/null 2>&1 || stop formal_pre_cas_missing
command -v sync_formal_to_tip >/dev/null 2>&1 || stop sync_formal_missing

FORMAL_BASELINE_OID=""
formal_pre_cas_check "$AEGL" main
[ "$FORMAL_BASELINE_OID" = "$BASELINE" ] \
  || stop baseline_mismatch "FORMAL_BASELINE_OID=$FORMAL_BASELINE_OID want=$BASELINE"
[ "$(git_aegl_broker rev-parse refs/heads/main)" = "$BASELINE" ] \
  || stop baseline_ref_mismatch

# 3) candidate worktree from the formal repo at the final tip
say "STAGE=candidate"
EXT="$(mktemp -d /var/tmp/aegl-gt1-cand-XXXXXX)" || die "mktemp EXT failed"
chmod 0750 "$EXT"
chown root:root "$EXT"
say "CANDIDATE_DIR=$EXT"
setfacl -m "u:${BROKER_USER}:rwx" "$EXT" || stop candidate_acl_failed
as_broker git -C "$AEGL" worktree add "$EXT/wt" "$TIP" || stop candidate_worktree_failed
test "$(as_broker git -C "$EXT/wt" rev-parse HEAD)" = "$TIP" || stop candidate_head_mismatch
test -z "$(as_broker git -C "$EXT/wt" status --porcelain)" || stop candidate_dirty
if runuser -u "$AI_USER" -- touch "$EXT/wt/.ai-probe" 2>/dev/null; then
  rm -f "$EXT/wt/.ai-probe"
  stop ai_can_write_candidate
fi
BASE="$(git_aegl_broker merge-base refs/heads/main "$TIP")"
[ "$BASE" = "$BASELINE" ] || stop base_mismatch "base=$BASE want=$BASELINE"

# 4) broker: root register/record, aegl-ai promote; check decisions and approved commit
say "STAGE=broker_register"
REG_JSON="$(python3 -c 'import json,sys;print(json.dumps({"protocol":"AEGL-BROKER/1","op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],"worktree":sys.argv[4],"branch":"gt1-delivery","target_ref":"refs/heads/main"}))' \
  "$TASK_ID" "$AEGL" "$BASE" "$EXT/wt")"
broker_client_call REGISTER "$REG_JSON"
require_decision REGISTER REGISTERED

say "STAGE=broker_record"
broker_client_call RECORD "{\"protocol\":\"AEGL-BROKER/1\",\"op\":\"record\",\"task_id\":\"$TASK_ID\",\"verify_result\":\"PASS\"}"
require_decision RECORD RECORDED
APPROVED="$(broker_field "$BROKER_LAST_JSON" approved_commit)"
[ "$APPROVED" = "$TIP" ] || stop approved_mismatch "approved_commit=$APPROVED want=$TIP"

say "STAGE=broker_promote"
broker_client_call PROMOTE "{\"protocol\":\"AEGL-BROKER/1\",\"op\":\"promote\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
require_decision PROMOTE APPLIED
[ "$(git_aegl_broker rev-parse refs/heads/main)" = "$TIP" ] || stop main_not_tip_after_promote

# 5) candidate cleanup: no --force, no branch -D; preserve scene on failure
say "STAGE=candidate_cleanup"
as_broker git -C "$AEGL" worktree remove "$EXT/wt" || stop worktree_remove_failed
rmdir "$EXT" || stop ext_not_empty "$EXT"
EXT=""

# 6) existing formal sync: CAS already done; sync HEAD/index/worktree
say "STAGE=formal_sync"
sync_formal_to_tip "$AEGL" "$TIP" main "$BASELINE"
[ "$(git_aegl_broker rev-parse refs/heads/main)" = "$TIP" ] || stop main_not_tip_after_sync
[ "$(git_aegl_broker rev-parse HEAD)" = "$TIP" ] || stop head_not_tip
[ "$(git_aegl_broker rev-parse --abbrev-ref HEAD)" = "main" ] || stop branch_not_main
[ -z "$(git_aegl_broker status --porcelain)" ] || stop worktree_dirty_after_sync

# 7) extract delivery + payload from the formal object store as aegl-promote
say "STAGE=extract_delivery"
DRDIR="$(mktemp -d /root/gt1-payload.XXXXXX)" || die "mktemp DRDIR failed"
chmod 0700 "$DRDIR"
CLEAN_PATHS+=(
  "$DRDIR/$CLI_REL"
  "$DRDIR/$MOD_REL"
  "$DRDIR/recovery/deliver-gt1.sh"
  "$DRDIR/recovery/install-model-task-registry.sh"
  "$DRDIR/recovery/accept-model-task-registry.sh"
  "$DRDIR/recovery/gt1-install-manifest.txt"
  "$DRDIR/docs/GT1-INSTALL-ACCEPTANCE.md"
)
as_broker git -C "$AEGL" archive "$TIP" \
  "$CLI_REL" "$MOD_REL" \
  "recovery/deliver-gt1.sh" \
  "recovery/install-model-task-registry.sh" \
  "recovery/accept-model-task-registry.sh" \
  "recovery/gt1-install-manifest.txt" \
  "docs/GT1-INSTALL-ACCEPTANCE.md" \
  | tar -x -C "$DRDIR" || stop delivery_extract_failed
FILES="$(cd "$DRDIR" && find . -type f -printf '%P\n' | sort)"
EXPECT="$(printf '%s\n' "$CLI_REL" "$MOD_REL" "recovery/deliver-gt1.sh" "recovery/install-model-task-registry.sh" "recovery/accept-model-task-registry.sh" "recovery/gt1-install-manifest.txt" "docs/GT1-INSTALL-ACCEPTANCE.md" | sort)"
[ "$FILES" = "$EXPECT" ] || stop delivery_file_list "unexpected files: $FILES"
[ -f "$DRDIR/recovery/gt1-install-manifest.txt" ] || stop manifest_missing
while read -r rel sha mode; do
  case "$rel" in functional_payload|baseline|tip) continue ;; esac
  [ -n "$rel" ] || continue
  [ -f "$DRDIR/$rel" ] || stop delivery_file_missing "$rel"
  got="$(sha256sum "$DRDIR/$rel" | awk '{print $1}')"
  [ "$got" = "$sha" ] || stop delivery_hash_mismatch "$rel want=$sha got=$got"
done < "$DRDIR/recovery/gt1-install-manifest.txt"

# 8) install from the verified root-exclusive payload, then temporary-registry acceptance
say "STAGE=install"
"$DRDIR/recovery/install-model-task-registry.sh" --payload-dir "$DRDIR"
say "STAGE=accept"
"$DRDIR/recovery/accept-model-task-registry.sh"

DELIVERY_SUCCEEDED=1
say "STAGE=cleanup"
