#!/usr/bin/env bash
# promote-stack-preconsume.sh — STACK-ONLY, broker-CAS promotion of the IAP S0
# pre-consume recovery entry.
#
# Formal project: /home/zhong/Projects/Google-Android-Agent-Development-Stack
# target_ref:     refs/heads/master  (the only ref the broker allows for this project)
#
# Design notes (corrections from the earlier draft):
#   * group names are QUERIED, never assumed from the user name (aegl-promote's primary
#     group is aegl-broker);
#   * the formal sync is the verified baseline-lag implementation (see _formal_sync_lib,
#     adapted from recovery/keeplab-appprojects-exec.sh): after the broker CAS moved the
#     ref, the index/worktree still sit at the approved baseline; that lag is verified and
#     then synchronised with `git restore --source=HEAD --staged --worktree`; a real user
#     modification is refused and PRESERVED. `git switch` is only ever used to attach the
#     branch — never as the sync — and `checkout -f` is never used;
#   * the known gitlink is identified by exact path + HEAD/index OIDs, never by "status
#     non-empty" and never by ignoring the submodule wholesale;
#   * a resumed run (CAS already applied) verifies the existing broker approval and the
#     final ref, then performs SYNC/FINAL ONLY — no register/record/promote;
#   * no forced/recursive deletion and no failure-time auto-cleanup; a failure preserves
#     the scene. Success performs precise, non-recursive cleanup;
#   * every Git call passes an exact command-level safe.directory.
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
BROKER_BIN=/usr/local/lib/aegl-promote/aegl-promote-broker
SOCK=/run/aegl-promote/broker.sock
BROKER_USER=aegl-promote
AI_USER=aegl-ai
GITLINK_PATH=references/architecture-templates
GITLINK_KNOWN_OID=4a3b2a141f457f1312c8dc52d6cbea6c9592af72
BRIDGE_CLI_SHA=da14822baf4ae188f52db2f1ed9ee37bc7560c03edcb20cf717a6c972e07d2a8
TEST_SHA=4e748b12e4098c885d98ea669b476e9603441beb7a4b6fb0f61385477e52c4f9

EXT=""
say(){ printf '%s\n' "$*"; }
fail(){ printf 'STACK_PROMOTE_ERROR: %s\n' "$*" >&2; exit 1; }

# Trusted identities/groups are QUERIED, never derived from the user name.
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

# --------------------------------------------------------------------------- #
# Verified formal-tree pre-CAS / sync implementation (self-contained body).
# Reused verbatim-in-shape from recovery/keeplab-appprojects-exec.sh.
# Env: PROJ BRANCH TIP BASELINE_OID FORMAL_MODE (pre_cas|sync)
# --------------------------------------------------------------------------- #
_formal_sync_lib(){
  cat <<'EOS'
set -euo pipefail
cd "$PROJ"

blob_at(){
  local treeish="$1" path="$2" out=""
  out="$(git rev-parse --verify "$treeish:$path" 2>/dev/null)" || out=""
  [ -n "$out" ] && printf '%s' "$out" || printf 'MISSING'
}
unchanged_gitlink(){
  local path="$1" treeish="$2" meta mode oid head_oid
  meta="$(git ls-files -s -- "$path" 2>/dev/null || true)"
  meta="$(printf '%s\n' "$meta" | awk 'NR==1{print; exit}')"
  [ -n "$meta" ] || return 1
  mode="$(printf '%s' "$meta" | awk '{print $1}')"
  oid="$(printf '%s' "$meta" | awk '{print $2}')"
  [ "$mode" = "160000" ] || return 1
  head_oid="$(blob_at "$treeish" "$path")"
  [ "$head_oid" != "MISSING" ] || return 1
  [ "$oid" = "$head_oid" ]
}
real_dirty(){
  local treeish="$1" line path
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    path="${line:3}"; path="${path#\"}"; path="${path%\"}"
    unchanged_gitlink "$path" "$treeish" && continue
    printf '%s\n' "$line"
  done < <(git status --porcelain || true)
}
pick_sample(){
  git ls-tree -r --name-only HEAD | awk '
    { names[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        cmd = "git ls-files -s -- " names[i]
        if ((cmd | getline meta) > 0) {
          close(cmd); split(meta, a, " ")
          if (a[1] != "160000") { print names[i]; exit }
        } else close(cmd)
      }
      if (n >= 1) print names[1]
    }'
}

MODE="${FORMAL_MODE:?}"
case "$MODE" in
pre_cas)
  printf "FORMAL_BASELINE_REF=%s\n" "$(git rev-parse "refs/heads/$BRANCH")"
  printf "FORMAL_BASELINE_HEAD=%s\n" "$(git rev-parse HEAD)"
  real="$(real_dirty HEAD || true)"
  if [ -n "${real:-}" ]; then
    printf "STOP_AT=formal_dirty_preserved\n" >&2
    printf "EXEC_ERROR: real user modifications present; refusing CAS (preserving worktree)\n" >&2
    printf "%s\n" "$real" >&2
    exit 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    path="${line:3}"; path="${path#\"}"; path="${path%\"}"
    unchanged_gitlink "$path" HEAD || { printf "STOP_AT=formal_gitlink_drift\n" >&2; exit 1; }
    printf "FORMAL_GITLINK_OK path=%s index=%s\n" "$path" "$(git ls-files -s -- "$path" | awk '{print $2}')"
  done < <(git status --porcelain || true)
  printf "FORMAL_PRE_CAS_OK=1\n"
  ;;
sync)
  cur="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$cur" != "$BRANCH" ]; then
    git switch "$BRANCH"
  fi
  test "$(git rev-parse "refs/heads/$BRANCH")" = "$TIP"
  test "$(git rev-parse HEAD)" = "$TIP"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    path="${line:3}"; path="${path#\"}"; path="${path%\"}"
    if unchanged_gitlink "$path" HEAD; then
      printf "SYNC_GITLINK_UNCHANGED path=%s\n" "$path"; continue
    fi
    meta="$(git ls-files -s -- "$path" 2>/dev/null || true)"
    meta="$(printf '%s\n' "$meta" | awk 'NR==1{print; exit}')"
    mode="$(printf '%s' "$meta" | awk '{print $1}')"
    idx_oid="$(printf '%s' "$meta" | awk '{print $2}')"
    new_blob="$(blob_at HEAD "$path")"
    old_blob="MISSING"
    if [ -n "${BASELINE_OID:-}" ]; then old_blob="$(blob_at "$BASELINE_OID" "$path")"; fi
    if [ "$mode" = "160000" ]; then
      # Gitlink lag after CAS: index still at baseline OID is expected; other OID = user change.
      if [ "$idx_oid" = "$new_blob" ] || [ "$idx_oid" = "$old_blob" ]; then
        printf "SYNC_EXPECTED_GITLINK_LAG path=%s\n" "$path"; continue
      fi
      printf "STOP_AT=formal_gitlink_changed\n" >&2
      printf "EXEC_ERROR: gitlink index changed for %s; preserving\n" "$path" >&2
      exit 1
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
      wt_blob="$(git hash-object -t blob -- "$path" 2>/dev/null || echo MISSING)"
    else
      wt_blob="MISSING"
    fi
    if [ "$wt_blob" = "$old_blob" ] || [ "$wt_blob" = "$new_blob" ]; then
      printf "SYNC_EXPECTED_LAG path=%s\n" "$path"; continue
    fi
    printf "STOP_AT=formal_dirty_preserved\n" >&2
    printf "EXEC_ERROR: new user modification on %s (not baseline lag); preserving\n" "$path" >&2
    printf "%s\n" "$line" >&2
    exit 1
  done < <(git status --porcelain || true)

  git restore --source=HEAD --staged --worktree -- .
  test "$(git rev-parse HEAD)" = "$TIP"
  test "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH"

  real="$(real_dirty HEAD || true)"
  if [ -n "${real:-}" ]; then
    printf "STOP_AT=formal_sync_leftover\n" >&2
    printf "EXEC_ERROR: leftover dirty after restore\n%s\n" "$real" >&2
    exit 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    path="${line:3}"; path="${path#\"}"; path="${path%\"}"
    unchanged_gitlink "$path" HEAD
  done < <(git status --porcelain || true)

  sample="$(pick_sample)"
  test -n "$sample"
  if [ "$(git ls-files -s -- "$sample" | awk '{print $1}')" != "160000" ]; then
    want="$(git rev-parse "HEAD:$sample")"
    got="$(git hash-object -t blob -- "$sample")"
    test "$want" = "$got"
  fi
  printf "SYNC_FORMAL_OK sample=%s\n" "$sample"
  ;;
*)
  printf "STOP_AT=formal_bad_mode\n" >&2; exit 2 ;;
esac
EOS
}

formal_op(){ # <pre_cas|sync>  (runs as the trusted formal owner)
  local mode="$1"
  runuser -u "$BROKER_USER" -- env \
    PROJ="$FORMAL" BRANCH="$BRANCH" TIP="$COMMIT" BASELINE_OID="$BASE" FORMAL_MODE="$mode" \
    bash -c "$(_formal_sync_lib)"
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
  [ -d "$FORMAL/.git" ] || fail "formal repo missing: $FORMAL/.git"
  [ "$(basename "$FORMAL")" = "Google-Android-Agent-Development-Stack" ] || fail "formal project basename mismatch"
  [ "$(realpath "$(dirname "$FORMAL")")" = "$(realpath "$PROJECTS_ROOT")" ] || fail "formal project not directly under the projects root"
  systemctl is-active --quiet aegl-promote-broker || fail "aegl-promote-broker not active"
  [ -S "$SOCK" ] || fail "broker socket missing: $SOCK"
  runuser -u "$AI_USER" -- test -S "$SOCK" || fail "$AI_USER cannot access $SOCK"
}

# Final content checks by exact path/OID (head, index, candidate) — never raw status.
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

# Precise, non-recursive cleanup on SUCCESS only. Uses update-ref -d <ref> <expected-oid>.
precise_cleanup(){
  if git_formal show-ref --verify --quiet "$CAND_REF"; then
    git_formal update-ref -d "$CAND_REF" "$COMMIT" || fail "candidate ref removal failed (scene kept)"
    say "CLEANUP_REF_DELETED $CAND_REF expected=$COMMIT"
  fi
  if [ -n "${EXT:-}" ] && [ -e "$EXT/wt" ]; then
    git_formal worktree remove "$EXT/wt" >/dev/null || fail "precise worktree removal failed (scene kept)"
    say "CLEANUP_WORKTREE_REMOVED $EXT/wt"
  fi
  if [ -n "${EXT:-}" ] && [ -f "$EXT/candidate.bundle" ]; then
    rm "$EXT/candidate.bundle" || fail "bundle removal failed (scene kept)"
  fi
  if [ -n "${EXT:-}" ] && [ -d "$EXT" ]; then
    rmdir "$EXT" 2>/dev/null || say "NOTE temp dir retained (not empty): $EXT"
  fi
  say "CLEANUP_DONE (non-forced)"
}

# --------------------------------------------------------------------------- #
main(){
  require_root_and_tools
  local ref_now
  ref_now="$(git_formal rev-parse "$TARGET_REF")"

  if [ "$ref_now" = "$COMMIT" ]; then
    # ---- CONTINUATION: CAS already applied; sync/final only, no repeats. ---- #
    say "CAS_ALREADY_APPLIED $TARGET_REF=$COMMIT — continuation (no register/record/promote)"
    broker_client_call VALIDATE "{\"op\":\"validate\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
    [ "$BROKER_LAST_RC" -eq 0 ] || fail "validate rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
    [ "$(broker_decision "$BROKER_LAST_JSON")" = VALIDATED ] || fail "existing broker approval not VALIDATED: $BROKER_LAST_JSON"
    [ "$(broker_field "$BROKER_LAST_JSON" approved_commit)" = "$COMMIT" ] || fail "approved_commit mismatch"
    formal_op sync || fail "formal sync failed (scene preserved)"
    final_verify
    precise_cleanup
    say "STACK_PROMOTE_RESULT=OK mode=continuation master=$(git_formal rev-parse "$TARGET_REF")"
    return 0
  fi

  [ "$ref_now" = "$BASE" ] || fail "unknown $TARGET_REF state: $ref_now"

  # ---- NORMAL PATH -------------------------------------------------------- #
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
  local bundle="$EXT/candidate.bundle"
  git_src bundle create "$bundle" "$SRC_BRANCH" "^$BASE" >/dev/null || fail "bundle create failed"
  git_src bundle verify "$bundle" >/dev/null || fail "bundle verify failed"
  chown "$BROKER_USER:$BROKER_GROUP" "$bundle"
  say "BUNDLE_OK $bundle sha256=$(sha256sum "$bundle" | awk '{print $1}') group=$BROKER_GROUP"

  git_formal fetch --no-write-fetch-head "$bundle" "$COMMIT:$CAND_REF" >/dev/null || fail "candidate import failed"
  [ "$(git_formal rev-parse "$CAND_REF")" = "$COMMIT" ] || fail "candidate ref != candidate"
  [ "$(git_formal rev-parse "$TARGET_REF")" = "$BASE" ] || fail "import moved $TARGET_REF"
  say "IMPORT_OK $CAND_REF=$COMMIT master=$BASE (unchanged)"

  git_formal worktree add --detach "$EXT/wt" "$COMMIT" >/dev/null || fail "candidate worktree create failed"
  [ "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$EXT/wt" -C "$EXT/wt" rev-parse HEAD)" = "$COMMIT" ] \
    || fail "candidate worktree HEAD != candidate"
  [ -z "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$EXT/wt" -C "$EXT/wt" status --porcelain)" ] \
    || fail "candidate worktree dirty"
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
  precise_cleanup
  say "STACK_PROMOTE_RESULT=OK mode=normal master=$(git_formal rev-parse "$TARGET_REF")"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
