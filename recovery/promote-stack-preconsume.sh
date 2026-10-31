#!/usr/bin/env bash
# promote-stack-preconsume.sh — STACK-ONLY, broker-CAS promotion of the IAP S0
# pre-consume recovery entry.
#
# Corrections over the earlier draft:
#   * no forced/recursive removal and no failure-time auto-cleanup — a failure
#     PRESERVES the scene; success performs only precise, non-recursive cleanup;
#   * every FORMAL Git operation runs as the trusted owner identity (aegl-promote),
#     never as root or zhong;
#   * the formal sync is non-destructive (no `checkout -f`); it refuses rather than
#     clobber real modifications;
#   * the known gitlink state is captured and required to be byte-identical;
#   * the broker client sets AEGL_BROKER_SOCKET on BOTH the root and the AI branch and
#     checks rc, decision and the approved commit;
#   * every Git invocation passes an exact command-level safe.directory.
#
# Formal project: /home/zhong/Projects/Google-Android-Agent-Development-Stack
# target_ref:     refs/heads/master  (the only ref the broker allows for this project)
set -Eeuo pipefail

FORMAL=/home/zhong/Projects/Google-Android-Agent-Development-Stack
SRC=/var/tmp/IAP-CONTROL-DEV/stack
BASE=0b04e1798fffb17ec78aaf096065b9990ec65b0e
COMMIT=1b4014ad73dbf7f0552040274fe20e3b6209fa60
TARGET_REF=refs/heads/master
PROJECTS_ROOT=/home/zhong/Projects
BRANCH=feat/bridge-preconsume-recovery
TASK_ID=iap-smoke-preconsume-recovery
CAND_REF=refs/aegl-candidate/$TASK_ID
BROKER_BIN=/usr/local/lib/aegl-promote/aegl-promote-broker
SOCK=/run/aegl-promote/broker.sock
OP_USER=zhong
BROKER_USER=aegl-promote
AI_USER=aegl-ai
GITLINK_PATH=references/architecture-templates
GITLINK_KNOWN='160000 commit 4a3b2a141f457f1312c8dc52d6cbea6c9592af72	references/architecture-templates'
BRIDGE_CLI_SHA=da14822baf4ae188f52db2f1ed9ee37bc7560c03edcb20cf717a6c972e07d2a8
TEST_SHA=4e748b12e4098c885d98ea669b476e9603441beb7a4b6fb0f61385477e52c4f9

EXT=""
say(){ printf '%s\n' "$*"; }
fail(){ printf 'STACK_PROMOTE_ERROR: %s\n' "$*" >&2; exit 1; }

# Every Git call: exact command-level trust for the exact repo it touches.
git_formal(){ # formal repo, as the owning trusted identity
  runuser -u "$BROKER_USER" -- git \
    -c "safe.directory=$FORMAL" -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false -c core.attributesFile=/dev/null \
    -C "$FORMAL" "$@"
}
git_src(){ # external candidate source, as its owning identity
  runuser -u "$OP_USER" -- git \
    -c "safe.directory=$SRC" -c core.hooksPath=/dev/null -C "$SRC" "$@"
}
git_wt(){ # candidate worktree, as the owning trusted identity
  runuser -u "$BROKER_USER" -- git \
    -c "safe.directory=$EXT/wt" -c core.hooksPath=/dev/null -C "$EXT/wt" "$@"
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
  say "BROKER_${label}_RC=$rc"
  say "BROKER_${label}_JSON=$out"
  BROKER_LAST_RC=$rc; BROKER_LAST_JSON=$out
}
broker_decision(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")'; }
broker_field(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$2"; }

# --------------------------------------------------------------------------- #
# 0. Preconditions (default deny; a failure preserves everything)
# --------------------------------------------------------------------------- #
[ "$(id -u)" -eq 0 ] || fail "must run as root"
for t in git runuser python3 systemctl; do command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t"; done
for u in "$OP_USER" "$BROKER_USER" "$AI_USER"; do id "$u" >/dev/null 2>&1 || fail "missing user: $u"; done
[ -d "$FORMAL/.git" ] || fail "formal repo missing: $FORMAL/.git"
[ -d "$SRC/.git" ]   || fail "candidate source repo missing: $SRC"
[ "$(basename "$FORMAL")" = "Google-Android-Agent-Development-Stack" ] || fail "formal project basename mismatch"
[ "$(realpath "$(dirname "$FORMAL")")" = "$(realpath "$PROJECTS_ROOT")" ] || fail "formal project not directly under the projects root"
[ "$(git_src rev-parse "$BRANCH")" = "$COMMIT" ] || fail "candidate branch tip != candidate commit"
[ "$(git_src rev-parse "$COMMIT^")" = "$BASE" ] || fail "candidate parent != formal base"
[ "$(git_formal rev-parse "$TARGET_REF")" = "$BASE" ] || fail "formal $TARGET_REF != baseline $BASE"
[ -z "$(git_formal status --porcelain)" ] || fail "formal workspace dirty before promotion"
[ "$(git_src ls-tree "$COMMIT" "$GITLINK_PATH")" = "$GITLINK_KNOWN" ] || fail "candidate gitlink differs — refuse to move the submodule pointer"
GL_BEFORE="$(git_formal ls-tree "$TARGET_REF" "$GITLINK_PATH")"
[ "$GL_BEFORE" = "$GITLINK_KNOWN" ] || fail "formal base gitlink differs from the known state"
DIFF="$(git_src diff --name-only "$BASE" "$COMMIT" | tr '\n' ' ')"
[ "$DIFF" = "orchestration/hermes/bridge/bridge_cli.py orchestration/hermes/bridge/tests/test_preconsume_recovery.py " ] \
  || fail "candidate diff is not exactly the two intended files"
systemctl is-active --quiet aegl-promote-broker || fail "aegl-promote-broker not active"
[ -S "$SOCK" ] || fail "broker socket missing: $SOCK"
runuser -u "$AI_USER" -- test -S "$SOCK" || fail "$AI_USER cannot access $SOCK"
say "PRECHECK_OK base=$BASE commit=$COMMIT target=$TARGET_REF gitlink=known"

# --------------------------------------------------------------------------- #
# 1. Export the fixed commit (ref + ^base; a raw SHA range is an empty bundle)
# --------------------------------------------------------------------------- #
EXT="$(mktemp -d /var/tmp/iap-smoke-promote-XXXXXX)" || fail "mktemp failed"
chown "$BROKER_USER:$BROKER_USER" "$EXT"; chmod 0700 "$EXT"
BUNDLE="$EXT/candidate.bundle"
git -c "safe.directory=$SRC" -c core.hooksPath=/dev/null -C "$SRC" \
  bundle create "$BUNDLE" "$BRANCH" "^$BASE" >/dev/null || fail "bundle create failed"
git -c "safe.directory=$SRC" -c core.hooksPath=/dev/null -C "$SRC" \
  bundle verify "$BUNDLE" >/dev/null || fail "bundle verify failed"
chown "$BROKER_USER:$BROKER_USER" "$BUNDLE"
say "BUNDLE_OK $BUNDLE sha256=$(sha256sum "$BUNDLE" | awk '{print $1}')"

# --------------------------------------------------------------------------- #
# 2. As the trusted owner, import into an INDEPENDENT candidate ref and assert
#    the target ref did not move.
# --------------------------------------------------------------------------- #
git_formal fetch --no-write-fetch-head "$BUNDLE" "$COMMIT:$CAND_REF" >/dev/null \
  || fail "candidate import failed"
[ "$(git_formal rev-parse "$CAND_REF")" = "$COMMIT" ] || fail "candidate ref != candidate commit"
[ "$(git_formal rev-parse "$TARGET_REF")" = "$BASE" ] || fail "import moved $TARGET_REF"
say "IMPORT_OK $CAND_REF=$COMMIT master=$BASE (unchanged)"

# --------------------------------------------------------------------------- #
# 3. Candidate worktree from the FORMAL repo, owned by the trusted identity
# --------------------------------------------------------------------------- #
git_formal worktree add --detach "$EXT/wt" "$COMMIT" >/dev/null || fail "candidate worktree create failed"
[ "$(git_wt rev-parse HEAD)" = "$COMMIT" ] || fail "candidate worktree HEAD != candidate"
ST_RC=0; ST_OUT="$(git_wt status --porcelain 2>/dev/null)" || ST_RC=$?
[ "$ST_RC" = 0 ] || fail "candidate git status failed (rc=$ST_RC)"
[ -z "$ST_OUT" ] || fail "candidate worktree dirty"
[ "$(sha256sum "$EXT/wt/orchestration/hermes/bridge/bridge_cli.py" | awk '{print $1}')" = "$BRIDGE_CLI_SHA" ] \
  || fail "candidate bridge_cli.py hash mismatch"
say "CANDIDATE_OK $EXT/wt head=$COMMIT owner=$BROKER_USER"

# --------------------------------------------------------------------------- #
# 4. Formal pre-CAS re-check
# --------------------------------------------------------------------------- #
[ "$(git_formal rev-parse "$TARGET_REF")" = "$BASE" ] || fail "formal target moved before CAS"
[ -z "$(git_formal status --porcelain)" ] || fail "formal workspace dirty before CAS"
say "PRE_CAS_OK $TARGET_REF=$BASE"

# --------------------------------------------------------------------------- #
# 5. register + record as root; rc, decision and approved commit must all match
# --------------------------------------------------------------------------- #
REG_JSON="$(python3 -c 'import json,sys
print(json.dumps({"op":"register","task_id":sys.argv[1],"project":sys.argv[2],
"base":sys.argv[3],"worktree":sys.argv[4],"branch":sys.argv[5],
"target_ref":sys.argv[6]}))' \
  "$TASK_ID" "$FORMAL" "$BASE" "$EXT/wt" "$BRANCH" "$TARGET_REF")"
broker_client_call REGISTER "$REG_JSON"
[ "$BROKER_LAST_RC" -eq 0 ] || fail "register rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
[ "$(broker_decision "$BROKER_LAST_JSON")" = REGISTERED ] || fail "register refused: $BROKER_LAST_JSON"

broker_client_call RECORD "{\"op\":\"record\",\"task_id\":\"$TASK_ID\",\"verify_result\":\"PASS\"}"
[ "$BROKER_LAST_RC" -eq 0 ] || fail "record rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
[ "$(broker_decision "$BROKER_LAST_JSON")" = RECORDED ] || fail "record refused: $BROKER_LAST_JSON"
APPROVED="$(broker_field "$BROKER_LAST_JSON" approved_commit)"
[ "$APPROVED" = "$COMMIT" ] || fail "approved_commit $APPROVED != candidate $COMMIT"

# --------------------------------------------------------------------------- #
# 6. validate + promote AS the AI identity; require APPLIED
# --------------------------------------------------------------------------- #
broker_client_call VALIDATE "{\"op\":\"validate\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
[ "$BROKER_LAST_RC" -eq 0 ] || fail "validate rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
[ "$(broker_decision "$BROKER_LAST_JSON")" = VALIDATED ] || fail "validate refused: $BROKER_LAST_JSON"

broker_client_call PROMOTE "{\"op\":\"promote\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
[ "$BROKER_LAST_RC" -eq 0 ] || fail "promote rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
[ "$(broker_decision "$BROKER_LAST_JSON")" = APPLIED ] || fail "promote refused: $BROKER_LAST_JSON"
[ "$(git_formal rev-parse "$TARGET_REF")" = "$COMMIT" ] || fail "$TARGET_REF != candidate after APPLIED"
say "PROMOTE_APPLIED $TARGET_REF=$COMMIT"

# --------------------------------------------------------------------------- #
# 7. Non-destructive formal sync (no checkout -f) + final verification
# --------------------------------------------------------------------------- #
CUR_REF="$(git_formal symbolic-ref -q HEAD || true)"
if [ "$CUR_REF" != "$TARGET_REF" ]; then
  # moving a clean tree onto master; git refuses if it would clobber local changes
  git_formal switch master || fail "formal switch refused (local modifications preserved; scene kept)"
fi
[ "$(git_formal symbolic-ref -q HEAD || true)" = "$TARGET_REF" ] || fail "formal HEAD not on master"
[ "$(git_formal rev-parse HEAD)" = "$COMMIT" ] || fail "formal HEAD != promoted commit"
[ -z "$(git_formal status --porcelain)" ] \
  || fail "formal index/worktree not synchronized (no force used; scene preserved)"
GL_AFTER="$(git_formal ls-tree "$TARGET_REF" "$GITLINK_PATH")"
[ "$GL_AFTER" = "$GL_BEFORE" ] || fail "gitlink changed during promotion"
[ "$(sha256sum "$FORMAL/orchestration/hermes/bridge/bridge_cli.py" | awk '{print $1}')" = "$BRIDGE_CLI_SHA" ] \
  || fail "promoted bridge_cli.py hash mismatch"
[ "$(sha256sum "$FORMAL/orchestration/hermes/bridge/tests/test_preconsume_recovery.py" | awk '{print $1}')" = "$TEST_SHA" ] \
  || fail "promoted test hash mismatch"
say "FINAL_OK HEAD=$COMMIT index=clean gitlink=preserved files=ok"

# --------------------------------------------------------------------------- #
# 8. Precise, non-recursive cleanup on SUCCESS only (never on failure)
# --------------------------------------------------------------------------- #
git_formal worktree remove "$EXT/wt" >/dev/null || fail "precise worktree removal failed (scene kept)"
git_formal update-ref -d "$CAND_REF" >/dev/null || fail "candidate ref removal failed (scene kept)"
rm "$BUNDLE" || fail "bundle removal failed (scene kept)"
rmdir "$EXT" || fail "temp dir not empty (scene kept)"
say "CLEANUP_OK candidate ref and worktree removed; temp dir empty"
say "STACK_PROMOTE_RESULT=OK project=$FORMAL commit=$COMMIT master=$(git_formal rev-parse "$TARGET_REF")"
