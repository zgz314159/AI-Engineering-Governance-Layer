#!/usr/bin/env bash
# promote-stack-preconsume.sh — STACK-ONLY, broker-CAS promotion of the IAP S0
# pre-consume recovery entry.
#
# Formal project: /home/zhong/Projects/Google-Android-Agent-Development-Stack
# target_ref:     refs/heads/master  (the only ref the broker allows for this project)
#
# The formal pre-CAS / sync / cleanup logic lives in promote_stack_sync.py, which calls
# the EXISTING iap_delivery.Delivery verifier (index AND worktree joint checks, exact
# known-gitlink handling, git restore). Nothing here re-implements it and nothing swallows
# a Git failure. This driver only orchestrates: bundle -> candidate ref -> worktree ->
# broker register/record/validate/promote -> sync -> final checks -> precise cleanup.
#
# Group names are QUERIED (aegl-promote's primary group is aegl-broker).
# A failure preserves the scene; cleanup is non-forced and precise.
set -Eeuo pipefail

FORMAL=/home/zhong/Projects/Google-Android-Agent-Development-Stack
SRC=/var/tmp/IAP-CONTROL-DEV/stack
BASE=0b04e1798fffb17ec78aaf096065b9990ec65b0e
COMMIT=1b4014ad73dbf7f0552040274fe20e3b6209fa60
TARGET_REF=refs/heads/master
BRANCH=master
PROJECTS_ROOT=/home/zhong/Projects
SRC_BRANCH=feat/bridge-preconsume-recovery
TASK_ID=iap-smoke-preconsume-recovery
CAND_REF=refs/aegl-candidate/$TASK_ID
REC_DIR=/var/lib/aegl-promote/tasks
REC="$REC_DIR/$TASK_ID.json"
BROKER_BIN=/usr/local/lib/aegl-promote/aegl-promote-broker
SOCK=/run/aegl-promote/broker.sock
BROKER_USER=aegl-promote
AI_USER=aegl-ai
GITLINK_PATH=references/architecture-templates
GITLINK_KNOWN_OID=4a3b2a141f457f1312c8dc52d6cbea6c9592af72
BRIDGE_CLI_SHA=da14822baf4ae188f52db2f1ed9ee37bc7560c03edcb20cf717a6c972e07d2a8
TEST_SHA=4e748b12e4098c885d98ea669b476e9603441beb7a4b6fb0f61385477e52c4f9
SYNC_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/promote_stack_sync.py"

EXT=""
say(){ printf '%s\n' "$*"; }
fail(){ printf 'STACK_PROMOTE_ERROR: %s\n' "$*" >&2; exit 1; }

BROKER_GID="$(id -g "$BROKER_USER")"
BROKER_GROUP="$(getent group "$BROKER_GID" | cut -d: -f1)"
[ -n "$BROKER_GROUP" ] || fail "cannot resolve primary group for $BROKER_USER"

git_formal(){
  runuser -u "$BROKER_USER" -- git \
    -c "safe.directory=$FORMAL" -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false -c core.attributesFile=/dev/null \
    -C "$FORMAL" "$@"
}
git_src(){
  git -c "safe.directory=$SRC" -c core.hooksPath=/dev/null -C "$SRC" "$@"
}

# Formal pre_cas / sync / cleanup through the shared verifier (Git runs as the owner).
# `python3 -I` (isolated): no PYTHONPATH / user site / install-dir module can shadow the
# verified, colocated copy of iap_delivery.py that the wrapper imports explicitly.
formal_op(){ # <pre_cas|sync>
  python3 -I "$SYNC_HELPER" --mode "$1" --project "$FORMAL" --target-ref "$TARGET_REF" \
    --base "$BASE" --final "$COMMIT" --ledger "$REC_DIR" \
    --gitlink-path "$GITLINK_PATH" --gitlink-oid "$GITLINK_KNOWN_OID"
}
cleanup_op(){
  python3 -I "$SYNC_HELPER" --mode cleanup --project "$FORMAL" --commit "$COMMIT" \
    --candidate-ref "$CAND_REF" --record "$REC" --ledger "$REC_DIR"
}

broker_client_call(){ # <LABEL> <request-json> [run-as-user]
  local label="$1" req="$2" as_user="${3:-}" out="" rc=0
  set +e
  if [ -n "$as_user" ]; then
    out="$(runuser -u "$as_user" -- env AEGL_BROKER_SOCKET="$SOCK" \
      "$BROKER_BIN" client --socket "$SOCK" --request "$req" 2>&1)"; rc=$?
  else
    out="$(env AEGL_BROKER_SOCKET="$SOCK" \
      "$BROKER_BIN" client --socket "$SOCK" --request "$req" 2>&1)"; rc=$?
  fi
  set -e
  say "BROKER_${label}_RC=$rc"; say "BROKER_${label}_JSON=$out"
  BROKER_LAST_RC=$rc; BROKER_LAST_JSON=$out
}
broker_decision(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")'; }
broker_field(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$2"; }

require_root_and_tools(){
  [ "$(id -u)" -eq 0 ] || fail "must run as root"
  for t in git runuser python3 systemctl getent; do command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t"; done
  for u in "$BROKER_USER" "$AI_USER"; do id "$u" >/dev/null 2>&1 || fail "missing user: $u"; done
  [ -f "$SYNC_HELPER" ] || fail "sync helper missing: $SYNC_HELPER"
  # Complete runtime dependency must load from the STAGED copy before ANY promotion
  # operation (isolated, so no external checkout/PYTHONPATH/install-dir module can serve it).
  [ -f "$(dirname "$SYNC_HELPER")/iap_delivery.py" ] || fail "iap_delivery.py missing beside the verifier"
  python3 -I "$SYNC_HELPER" --help >/dev/null 2>&1 \
    || fail "self-contained dependency load failed (iap_delivery import)"
  [ -d "$FORMAL/.git" ] || fail "formal repo missing: $FORMAL/.git"
  [ "$(basename "$FORMAL")" = "Google-Android-Agent-Development-Stack" ] || fail "formal project basename mismatch"
  [ "$(realpath "$(dirname "$FORMAL")")" = "$(realpath "$PROJECTS_ROOT")" ] || fail "formal project not directly under the projects root"
  systemctl is-active --quiet aegl-promote-broker || fail "aegl-promote-broker not active"
  [ -S "$SOCK" ] || fail "broker socket missing: $SOCK"
  runuser -u "$AI_USER" -- test -S "$SOCK" || fail "$AI_USER cannot access $SOCK"
}

final_verify(){
  [ "$(git_formal rev-parse "$TARGET_REF")" = "$COMMIT" ] || fail "$TARGET_REF != promoted commit"
  [ "$(git_formal rev-parse HEAD)" = "$COMMIT" ] || fail "formal HEAD != promoted commit"
  local head_gl index_gl cand_gl
  head_gl="$(git_formal rev-parse "HEAD:$GITLINK_PATH")" || fail "gitlink absent at HEAD"
  index_gl="$(git_formal ls-files -s -- "$GITLINK_PATH" | awk '{print $2}')"
  cand_gl="$(git_formal rev-parse "$COMMIT:$GITLINK_PATH")" || fail "gitlink absent at candidate"
  [ "$head_gl" = "$GITLINK_KNOWN_OID" ] || fail "gitlink HEAD OID drifted: $head_gl"
  [ "$index_gl" = "$GITLINK_KNOWN_OID" ] || fail "gitlink index OID drifted: $index_gl"
  [ "$cand_gl" = "$GITLINK_KNOWN_OID" ] || fail "gitlink candidate OID drifted: $cand_gl"
  [ "$(sha256sum "$FORMAL/orchestration/hermes/bridge/bridge_cli.py" | awk '{print $1}')" = "$BRIDGE_CLI_SHA" ] \
    || fail "promoted bridge_cli.py hash mismatch"
  [ "$(sha256sum "$FORMAL/orchestration/hermes/bridge/tests/test_preconsume_recovery.py" | awk '{print $1}')" = "$TEST_SHA" ] \
    || fail "promoted test hash mismatch"
  say "FINAL_OK HEAD=$COMMIT gitlink=$GITLINK_KNOWN_OID (head/index/candidate) files=ok"
}

write_record(){
  install -d -o root -g root -m 0700 "$REC_DIR" || fail "record dir"
  python3 -c 'import json,sys
rec={"task_id":sys.argv[1],"ext":sys.argv[2],"bundle":sys.argv[3],"commit":sys.argv[4],"candidate_ref":sys.argv[5]}
open(sys.argv[6],"w").write(json.dumps(rec,sort_keys=True)+"\n")' \
    "$TASK_ID" "$EXT" "$EXT/candidate.bundle" "$COMMIT" "$CAND_REF" "$REC" || fail "record write"
  chown root:root "$REC" || fail "record chown"
  chmod 0600 "$REC" || fail "record chmod"
  say "RECORD_OK $REC"
}

main(){
  require_root_and_tools
  local ref_now
  ref_now="$(git_formal rev-parse "$TARGET_REF")"

  if [ "$ref_now" = "$COMMIT" ]; then
    # ---- CONTINUATION: CAS already applied; sync/final/cleanup only. ---- #
    say "CAS_ALREADY_APPLIED $TARGET_REF=$COMMIT — continuation (no register/record/promote)"
    broker_client_call VALIDATE "{\"op\":\"validate\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
    [ "$BROKER_LAST_RC" -eq 0 ] || fail "validate rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
    [ "$(broker_decision "$BROKER_LAST_JSON")" = VALIDATED ] || fail "existing broker approval not VALIDATED: $BROKER_LAST_JSON"
    [ "$(broker_field "$BROKER_LAST_JSON" approved_commit)" = "$COMMIT" ] || fail "approved_commit mismatch"
    formal_op sync || fail "formal sync failed (scene preserved)"
    final_verify
    cleanup_op || fail "cleanup incomplete (leftovers preserved; overall NOT success)"
    say "STACK_PROMOTE_RESULT=OK mode=continuation master=$(git_formal rev-parse "$TARGET_REF")"
    return 0
  fi

  [ "$ref_now" = "$BASE" ] || fail "unknown $TARGET_REF state: $ref_now"

  [ -d "$SRC/.git" ] || fail "candidate source repo missing: $SRC"
  [ "$(git_src rev-parse "$SRC_BRANCH")" = "$COMMIT" ] || fail "candidate branch tip != candidate"
  [ "$(git_src rev-parse "$COMMIT^")" = "$BASE" ] || fail "candidate parent != formal base"
  [ "$(git_src ls-tree "$COMMIT" "$GITLINK_PATH" | awk '{print $3}')" = "$GITLINK_KNOWN_OID" ] \
    || fail "candidate gitlink differs — refusing to move the submodule pointer"
  local diff
  diff="$(git_src diff --name-only "$BASE" "$COMMIT" | tr '\n' ' ')"
  [ "$diff" = "orchestration/hermes/bridge/bridge_cli.py orchestration/hermes/bridge/tests/test_preconsume_recovery.py " ] \
    || fail "candidate diff is not exactly the two intended files"
  say "PRECHECK_OK base=$BASE commit=$COMMIT target=$TARGET_REF group=$BROKER_GROUP"

  EXT="$(mktemp -d /var/tmp/iap-smoke-promote-XXXXXX)" || fail "mktemp failed"
  chown "$BROKER_USER:$BROKER_GROUP" "$EXT"; chmod 0700 "$EXT"
  write_record
  local bundle="$EXT/candidate.bundle"
  git_src bundle create "$bundle" "$SRC_BRANCH" "^$BASE" >/dev/null || fail "bundle create failed"
  git_src bundle verify "$bundle" >/dev/null || fail "bundle verify failed"
  chown "$BROKER_USER:$BROKER_GROUP" "$bundle"
  say "BUNDLE_OK $bundle group=$BROKER_GROUP"

  git_formal fetch --no-write-fetch-head "$bundle" "$COMMIT:$CAND_REF" >/dev/null || fail "candidate import failed"
  [ "$(git_formal rev-parse "$CAND_REF")" = "$COMMIT" ] || fail "candidate ref != candidate"
  [ "$(git_formal rev-parse "$TARGET_REF")" = "$BASE" ] || fail "import moved $TARGET_REF"
  say "IMPORT_OK $CAND_REF=$COMMIT master=$BASE (unchanged)"

  git_formal worktree add --detach "$EXT/wt" "$COMMIT" >/dev/null || fail "candidate worktree create failed"
  [ "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$EXT/wt" -C "$EXT/wt" rev-parse HEAD)" = "$COMMIT" ] \
    || fail "candidate worktree HEAD != candidate"
  [ "$(sha256sum "$EXT/wt/orchestration/hermes/bridge/bridge_cli.py" | awk '{print $1}')" = "$BRIDGE_CLI_SHA" ] \
    || fail "candidate bridge_cli.py hash mismatch"
  say "CANDIDATE_OK $EXT/wt head=$COMMIT owner=$BROKER_USER:$BROKER_GROUP"

  formal_op pre_cas || fail "formal pre-CAS check failed (scene preserved)"

  local reg_json
  reg_json="$(python3 -c 'import json,sys
print(json.dumps({"op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],
"worktree":sys.argv[4],"branch":sys.argv[5],"target_ref":sys.argv[6]}))' \
    "$TASK_ID" "$FORMAL" "$BASE" "$EXT/wt" "$SRC_BRANCH" "$TARGET_REF")"
  broker_client_call REGISTER "$reg_json"
  [ "$BROKER_LAST_RC" -eq 0 ] || fail "register rc=$BROKER_LAST_RC"
  [ "$(broker_decision "$BROKER_LAST_JSON")" = REGISTERED ] || fail "register refused: $BROKER_LAST_JSON"

  broker_client_call RECORD "{\"op\":\"record\",\"task_id\":\"$TASK_ID\",\"verify_result\":\"PASS\"}"
  [ "$BROKER_LAST_RC" -eq 0 ] || fail "record rc=$BROKER_LAST_RC"
  [ "$(broker_decision "$BROKER_LAST_JSON")" = RECORDED ] || fail "record refused: $BROKER_LAST_JSON"
  [ "$(broker_field "$BROKER_LAST_JSON" approved_commit)" = "$COMMIT" ] || fail "approved_commit != candidate"

  broker_client_call VALIDATE "{\"op\":\"validate\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
  [ "$BROKER_LAST_RC" -eq 0 ] || fail "validate rc=$BROKER_LAST_RC"
  [ "$(broker_decision "$BROKER_LAST_JSON")" = VALIDATED ] || fail "validate refused: $BROKER_LAST_JSON"

  broker_client_call PROMOTE "{\"op\":\"promote\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
  [ "$BROKER_LAST_RC" -eq 0 ] || fail "promote rc=$BROKER_LAST_RC"
  [ "$(broker_decision "$BROKER_LAST_JSON")" = APPLIED ] || fail "promote refused: $BROKER_LAST_JSON"
  [ "$(git_formal rev-parse "$TARGET_REF")" = "$COMMIT" ] || fail "$TARGET_REF != candidate after APPLIED"
  say "PROMOTE_APPLIED $TARGET_REF=$COMMIT"

  formal_op sync || fail "formal sync failed (scene preserved)"
  final_verify
  cleanup_op || fail "cleanup incomplete (leftovers preserved; overall NOT success)"
  say "STACK_PROMOTE_RESULT=OK mode=normal master=$(git_formal rev-parse "$TARGET_REF")"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
