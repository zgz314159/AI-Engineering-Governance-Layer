#!/usr/bin/env bash
# keeplab-appprojects-exec.sh — unified trusted-terminal pack for KeepLab → AppProjects.
#
# Reuses the proven promote-to-main-stack patterns (cross-UID ACL on candidate,
# broker RC+JSON capture, decision + approved_commit gates, EXIT cleanup).
# Does NOT invent a parallel promote framework.
#
#   git -C "$AEGL" show "$AEGL_TIP:recovery/keeplab-appprojects-exec.sh" \
#     | sudo bash -s -- \
#         --commit "$AEGL_TIP" \
#         --stack-commit "$STACK_TIP" \
#         --keeplab-commit "$KEEPLAB_TIP"
#
# Order:
#   0) preflight three SHAs + refs + ancestors + project state + planned steps
#   1) promote AEGL tip → refs/heads/main + sync formal index/worktree
#   2) install-broker (AEGL_BUSINESS_ROOT) from AEGL tip
#   3) promote Stack tip → refs/heads/master + sync formal (live Hermes guard)
#   4) migrate directory move
#   5) promote KeepLab tip → refs/heads/master at NEW path + sync
#   6) final post checks as operator (not root importing formal-tree code)
#
# Resume after move when a later step failed:
#   … | sudo bash -s -- --commit … --stack-commit … --keeplab-commit … --resume-after-move
#
# No switch/chattr/node_modules/Cursor rules/push. No reset --hard / clean / stash.
set -euo pipefail

AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
STACK="/home/zhong/Projects/Google-Android-Agent-Development-Stack"
KEEPLAB_SRC="/home/zhong/Projects/KeepLab-Relay"
KEEPLAB_DST="/home/zhong/AppProjects/KeepLab-Relay"
PROJECTS_ROOT="/home/zhong/Projects"
BUSINESS_ROOT="/home/zhong/AppProjects"
COMMIT=""; STACK_COMMIT=""; KEEPLAB_COMMIT=""
RESUME_AFTER_MOVE=0; DRY_RUN=0

BROKER_USER="aegl-promote"
AI_USER="aegl-ai"
OP_USER="zhong"
LIBDIR=/usr/local/lib/aegl-promote
SOCK=/run/aegl-promote/broker.sock
BROKER_BIN="$LIBDIR/aegl-promote-broker"

EXT=""
ACTIVE_PROJ=""
cleanup_all(){
  if [ -n "${EXT:-}" ] && [ -d "$EXT" ]; then
    if [ -n "${ACTIVE_PROJ:-}" ]; then
      git -C "$ACTIVE_PROJ" worktree remove --force "$EXT/wt" 2>/dev/null || true
    fi
    chmod -R u+w "$EXT" 2>/dev/null || true
    rm -rf "$EXT"
  fi
  EXT=""; ACTIVE_PROJ=""
}
trap cleanup_all EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --stack-commit) STACK_COMMIT="${2:-}"; shift 2 ;;
    --keeplab-commit) KEEPLAB_COMMIT="${2:-}"; shift 2 ;;
    --resume-after-move) RESUME_AFTER_MOVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --stack) STACK="${2:-}"; shift 2 ;;
    *) printf 'STOP_AT=bad_option\nEXEC_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'EXEC_ERROR: %s\n' "$*" >&2; exit 1; }

# Capture broker client JSON + rc without set -e hiding the body (same as promote-to-main-stack).
broker_client_call() {
  local label="$1" req="$2" as_user="${3:-}"
  local out="" rc=0
  set +e
  if [ -n "$as_user" ]; then
    out="$(runuser -u "$as_user" -- env AEGL_BROKER_SOCKET="$SOCK" \
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

require_hex40() {
  local name="$1" val="$2"
  case "$val" in [0-9a-f]*) : ;; *) stop bad_sha "$name must be full 40-hex" ;; esac
  [ "${#val}" -eq 40 ] || stop bad_sha "$name must be full 40-hex (got ${#val})"
}

# Sync formal index+worktree to approved tip without reset --hard / clean / stash.
# Branch name already being main/master is NOT treated as source deployed.
sync_formal_to_tip() {
  local proj="$1" tip="$2" branch="$3"
  say "SYNC_FORMAL project=$proj tip=$tip branch=$branch"
  runuser -u "$OP_USER" -- env \
    PROJ="$proj" TIP="$tip" BRANCH="$branch" \
    bash -c '
    set -euo pipefail
    cd "$PROJ"
    porcelain="$(git status --porcelain | grep -vE "^.. references/" || true)"
    if [ -n "$porcelain" ]; then
      printf "STOP_AT=formal_dirty_preserved\n" >&2
      printf "EXEC_ERROR: formal tree has modifications; preserving and refusing sync\n" >&2
      printf "%s\n" "$porcelain" >&2
      exit 1
    fi
    cur="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$cur" != "$BRANCH" ]; then
      git switch "$BRANCH"
    fi
    test "$(git rev-parse "refs/heads/$BRANCH")" = "$TIP"
    # Ref may already equal TIP while index/worktree lag (external update-ref).
    git restore --source=HEAD --staged --worktree -- .
    test "$(git rev-parse HEAD)" = "$TIP"
    test "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH"
    leftover="$(git status --porcelain | grep -vE "^.. references/" || true)"
    test -z "$leftover"
    sample="$(git ls-tree -r --name-only HEAD | head -1)"
    test -n "$sample"
    want="$(git rev-parse "HEAD:$sample")"
    got="$(git hash-object -t blob -- "$sample")"
    test "$want" = "$got"
    printf "SYNC_FORMAL_OK sample=%s\n" "$sample"
  ' || stop formal_sync_failed "formal sync failed for $proj @$tip"
}

# Promote tip onto exact target_ref using proven cross-UID candidate + broker gates.
promote_tip() {
  local proj="$1" tip="$2" target_ref="$3" task_id="$4"
  local branch_name="${target_ref#refs/heads/}"
  local tip_now
  tip_now="$(git -C "$proj" rev-parse "$target_ref")"
  if [ "$tip_now" = "$tip" ]; then
    say "PROMOTE_SKIP ref already=$tip — still verifying formal deploy"
    sync_formal_to_tip "$proj" "$tip" "$branch_name"
    return 0
  fi
  git -C "$proj" merge-base --is-ancestor "$tip_now" "$tip" 2>/dev/null \
    || stop promote_not_ff "$proj: $tip is not a fast-forward of $target_ref=$tip_now"

  [ -S "$SOCK" ] || stop promote_no_socket "broker socket missing: $SOCK"
  [ -x "$BROKER_BIN" ] || stop promote_no_broker "broker binary missing: $BROKER_BIN"
  runuser -u "$AI_USER" -- test -S "$SOCK" || stop promote_ai_no_socket "aegl-ai cannot access $SOCK"

  # ACL for exact target ref (fixed commit installer, not worktree)
  git -C "$AEGL" show "$COMMIT:recovery/install-promote-target-acl.sh" \
    | bash -s -- --repo "$AEGL" --project "$proj" --commit "$COMMIT" \
         --target-ref "$target_ref" --business-root "$BUSINESS_ROOT" \
    || stop promote_acl_failed "ACL install failed for $proj $target_ref"

  cleanup_all
  EXT="$(mktemp -d /var/tmp/aegl-keeplab-prom-XXXXXX)" || stop promote_mktemp "mktemp failed"
  ACTIVE_PROJ="$proj"
  chmod 0750 "$EXT"
  chown root:root "$EXT"
  setfacl -m "u:${OP_USER}:rwx" "$EXT"
  runuser -u "$OP_USER" -- git -C "$proj" worktree add -f "$EXT/wt" "$tip" \
    || stop promote_worktree "worktree add failed for $tip"
  setfacl -m "u:${BROKER_USER}:--x" "$EXT"
  setfacl -R -m "u:${BROKER_USER}:r-X" "$EXT/wt"
  local WT_GITDIR
  WT_GITDIR="$(runuser -u "$OP_USER" -- git -c "safe.directory=$EXT/wt" -C "$EXT/wt" rev-parse --absolute-git-dir)"
  [ -n "$WT_GITDIR" ] && [ -d "$WT_GITDIR" ] || stop promote_gitdir "candidate gitdir missing"
  setfacl -R -m "u:${BROKER_USER}:r-X" "$WT_GITDIR"
  if runuser -u "$AI_USER" -- touch "$EXT/wt/.ai-probe" 2>/dev/null; then
    rm -f "$EXT/wt/.ai-probe"
    stop promote_acl_too_broad "aegl-ai can write candidate worktree"
  fi
  local ST_RC=0 ST_OUT
  ST_OUT="$(runuser -u "$OP_USER" -- git -c "safe.directory=$EXT/wt" -C "$EXT/wt" status --porcelain 2>/dev/null)" || ST_RC=$?
  [ "$ST_RC" = 0 ] || stop promote_cand_status "candidate git status failed rc=$ST_RC"
  [ -z "$ST_OUT" ] || stop promote_cand_dirty "candidate worktree dirty"

  local BASE REG_JSON dec APPROVED
  BASE="$(git -C "$proj" merge-base "$target_ref" "$tip")"
  REG_JSON="$(python3 -c 'import json,sys;print(json.dumps({"protocol":"AEGL-BROKER/1","op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],"worktree":sys.argv[4],"branch":"plan/keeplab-migrate","target_ref":sys.argv[5]}))' \
    "$task_id" "$proj" "$BASE" "$EXT/wt" "$target_ref")"

  broker_client_call REGISTER "$REG_JSON"
  dec="$(broker_decision "$BROKER_LAST_JSON")"
  [ "$dec" = REGISTERED ] \
    || stop promote_register_refused "register decision=$dec rc=$BROKER_LAST_RC"

  broker_client_call RECORD "{\"protocol\":\"AEGL-BROKER/1\",\"op\":\"record\",\"task_id\":\"$task_id\",\"verify_result\":\"PASS\"}"
  dec="$(broker_decision "$BROKER_LAST_JSON")"
  [ "$dec" = RECORDED ] \
    || stop promote_record_refused "record decision=$dec rc=$BROKER_LAST_RC"
  APPROVED="$(broker_field "$BROKER_LAST_JSON" approved_commit)"
  [ "$APPROVED" = "$tip" ] || stop promote_approved_mismatch "approved_commit=$APPROVED want=$tip"

  broker_client_call PROMOTE "{\"protocol\":\"AEGL-BROKER/1\",\"op\":\"promote\",\"task_id\":\"$task_id\"}" "$AI_USER"
  dec="$(broker_decision "$BROKER_LAST_JSON")"
  [ "$dec" = APPLIED ] \
    || stop promote_promote_refused "promote decision=$dec rc=$BROKER_LAST_RC"
  [ "$(git -C "$proj" rev-parse "$target_ref")" = "$tip" ] \
    || stop promote_ref_mismatch "$target_ref != $tip after promote"

  cleanup_all
  sync_formal_to_tip "$proj" "$tip" "$branch_name"
  say "PROMOTE_OK $proj $target_ref=$tip"
}

# Final post checks: operator identity only (never root import of formal-tree code).
run_final_post_as_operator() {
  say "== final post checks (as $OP_USER; fixed-commit script) =="
  git -C "$AEGL" show "$COMMIT:recovery/keeplab-appprojects-postcheck.sh" \
    | runuser -u "$OP_USER" -- env \
        AEGL="$AEGL" STACK="$STACK" DST="$KEEPLAB_DST" \
        PROJECTS_ROOT="$PROJECTS_ROOT" AEGL_BUSINESS_ROOT="$BUSINESS_ROOT" \
        bash -s \
    || stop final_post_failed "operator postcheck failed"
}

print_plan() {
  say "PLANNED_STEPS<<"
  say "  0 preflight: three SHAs, target refs, ancestors, project state"
  say "  1 promote AEGL $COMMIT -> refs/heads/main + sync formal"
  say "  2 install-broker --business-root $BUSINESS_ROOT from $COMMIT"
  say "  3 promote Stack $STACK_COMMIT -> refs/heads/master + sync formal (live guard)"
  say "  4 migrate mv $KEEPLAB_SRC -> $KEEPLAB_DST"
  say "  5 promote KeepLab $KEEPLAB_COMMIT -> refs/heads/master AT $KEEPLAB_DST + sync"
  say "  6 final post as $OP_USER (resolve/doctor/guard MANIFEST_OK)"
  say "PLANNED_STEPS>>"
}

preflight_all() {
  say "== 0. preflight (no formal mutate) =="
  require_hex40 AEGL_TIP "$COMMIT"
  require_hex40 STACK_TIP "$STACK_COMMIT"
  require_hex40 KEEPLAB_TIP "$KEEPLAB_COMMIT"
  git -C "$AEGL" cat-file -e "$COMMIT^{commit}" 2>/dev/null || stop aegl_commit_missing "$COMMIT"
  git -C "$STACK" cat-file -e "$STACK_COMMIT^{commit}" 2>/dev/null || stop stack_commit_missing "$STACK_COMMIT"
  # KeepLab objects: accept SRC or DST object store
  local kl_repo=""
  if [ -d "$KEEPLAB_SRC/.git" ] || [ -f "$KEEPLAB_SRC/.git" ]; then kl_repo="$KEEPLAB_SRC"
  elif [ -d "$KEEPLAB_DST/.git" ] || [ -f "$KEEPLAB_DST/.git" ]; then kl_repo="$KEEPLAB_DST"
  else stop keeplab_repo_missing "KeepLab missing at SRC and DST"; fi
  git -C "$kl_repo" cat-file -e "$KEEPLAB_COMMIT^{commit}" 2>/dev/null \
    || stop keeplab_commit_missing "$KEEPLAB_COMMIT"

  # Required paths in AEGL tip
  for f in recovery/keeplab-appprojects-exec.sh recovery/keeplab-appprojects-postcheck.sh \
           recovery/migrate-keeplab-to-appprojects.sh \
           recovery/install-broker.sh recovery/install-promote-target-acl.sh \
           recovery/promotion_broker.py recovery/promotion_core.py bin/aegl-promote-broker \
           bin/aegl-task bin/aegl-recovery; do
    git -C "$AEGL" cat-file -e "$COMMIT:$f" 2>/dev/null || stop tip_missing_path "AEGL tip missing $f"
  done
  git -C "$STACK" cat-file -e "$STACK_COMMIT:orchestration/hermes/evaluation_adapter/contract_guard.py" \
    2>/dev/null || stop tip_missing_path "Stack tip missing contract_guard.py"

  local aegl_main stack_master
  aegl_main="$(git -C "$AEGL" rev-parse refs/heads/main)"
  stack_master="$(git -C "$STACK" rev-parse refs/heads/master)"
  say "AEGL_MAIN=$aegl_main"
  say "STACK_MASTER=$stack_master"
  say "KEEPLAB_REPO=$kl_repo"
  say "KEEPLAB_MASTER=$(git -C "$kl_repo" rev-parse refs/heads/master 2>/dev/null || echo missing)"

  # Ancestor / already-at-tip
  if [ "$aegl_main" != "$COMMIT" ]; then
    git -C "$AEGL" merge-base --is-ancestor "$aegl_main" "$COMMIT" \
      || stop aegl_not_ff "$COMMIT not FF of main=$aegl_main"
  fi
  if [ "$stack_master" != "$STACK_COMMIT" ]; then
    git -C "$STACK" merge-base --is-ancestor "$stack_master" "$STACK_COMMIT" \
      || stop stack_not_ff "$STACK_COMMIT not FF of master=$stack_master"
  fi
  local kl_master
  kl_master="$(git -C "$kl_repo" rev-parse refs/heads/master)"
  if [ "$kl_master" != "$KEEPLAB_COMMIT" ]; then
    git -C "$kl_repo" merge-base --is-ancestor "$kl_master" "$KEEPLAB_COMMIT" \
      || stop keeplab_not_ff "$KEEPLAB_COMMIT not FF of master=$kl_master"
  fi

  # Project state (preserve dirt — report only)
  say "AEGL_HEAD_BRANCH=$(git -C "$AEGL" rev-parse --abbrev-ref HEAD)"
  say "AEGL_PORCELAIN_BYTES=$(git -C "$AEGL" status --porcelain | wc -c)"
  say "STACK_HEAD_BRANCH=$(git -C "$STACK" rev-parse --abbrev-ref HEAD)"
  say "STACK_PORCELAIN_BYTES=$(git -C "$STACK" status --porcelain | grep -vE '^.. references/' | wc -c)"
  say "KEEPLAB_HEAD_BRANCH=$(git -C "$kl_repo" rev-parse --abbrev-ref HEAD)"
  say "KEEPLAB_PORCELAIN_BYTES=$(git -C "$kl_repo" status --porcelain | wc -c)"

  print_plan
  say "PREFLIGHT_OK=1"
}

# --------------------------------------------------------------------------- #
# argument gates
# --------------------------------------------------------------------------- #
[ -n "$COMMIT" ] || stop need_commit "--commit <AEGL full SHA> required"
[ -n "$STACK_COMMIT" ] || stop need_stack_commit "--stack-commit <Stack full SHA> required"
[ -n "$KEEPLAB_COMMIT" ] || stop need_keeplab_commit "--keeplab-commit <KeepLab full SHA> required"

say "KEEPLAB_EXEC begin aegl=$COMMIT stack=$STACK_COMMIT keeplab=$KEEPLAB_COMMIT dry_run=$DRY_RUN resume=$RESUME_AFTER_MOVE"
export AEGL_BROKER_SOCKET="$SOCK"

# --- dry-run: full plan preflight + migrate directory precheck; no mutate --- #
if [ "$DRY_RUN" = 1 ]; then
  preflight_all
  if [ -d "$KEEPLAB_SRC" ]; then
    git -C "$AEGL" show "$COMMIT:recovery/migrate-keeplab-to-appprojects.sh" \
      | bash -s -- --dry-run --no-require-patches \
           --src "$KEEPLAB_SRC" --dst "$KEEPLAB_DST" \
      || stop dry_run_migrate_failed "migrate dry-run failed"
  else
    say "MIGRATE_DRY_RUN=SKIPPED (SRC absent — use --resume-after-move for post-move state)"
  fi
  say "DRY_RUN_RESULT=OK"
  say "NOTE=directory precheck alone is not pack readiness; planned steps listed above"
  say "STOP_AT=dry_run_ok"
  cleanup_all
  trap - EXIT
  exit 0
fi

# --- resume after move ------------------------------------------------------ #
if [ "$RESUME_AFTER_MOVE" = 1 ]; then
  [ "$(id -u)" = 0 ] || stop need_root "resume-after-move requires root"
  [ -d "$KEEPLAB_DST" ] || stop resume_dst_missing "DST missing: $KEEPLAB_DST"
  [ -e "$KEEPLAB_SRC" ] && stop resume_src_still_present "SRC still present: $KEEPLAB_SRC"
  preflight_all
  # Ensure broker unit has business root (may have failed before)
  if ! grep -q "AEGL_BUSINESS_ROOT=$BUSINESS_ROOT" /etc/systemd/system/aegl-promote-broker.service 2>/dev/null; then
    say "== resume: install-broker =="
    git -C "$AEGL" show "$COMMIT:recovery/install-broker.sh" \
      | bash -s -- --repo "$AEGL" --projects-root "$PROJECTS_ROOT" \
           --business-root "$BUSINESS_ROOT" --commit "$COMMIT" \
      || stop install_broker_failed "install-broker failed"
  fi
  say "== resume: KeepLab promote at DST =="
  promote_tip "$KEEPLAB_DST" "$KEEPLAB_COMMIT" "refs/heads/master" "keeplab-contract-$KEEPLAB_COMMIT"
  run_final_post_as_operator
  cleanup_all
  trap - EXIT
  say "EXEC_RESULT=OK mode=resume-after-move"
  say "STOP_AT=complete"
  exit 0
fi

# --- full pack -------------------------------------------------------------- #
[ "$(id -u)" = 0 ] || stop need_root "full exec pack requires root"
for t in git setfacl runuser python3 systemctl; do
  command -v "$t" >/dev/null 2>&1 || stop missing_tool "$t"
done
id "$OP_USER" >/dev/null 2>&1 || stop missing_user "$OP_USER"
id "$BROKER_USER" >/dev/null 2>&1 || stop missing_user "$BROKER_USER"
id "$AI_USER" >/dev/null 2>&1 || stop missing_user "$AI_USER"

preflight_all
[ -d "$KEEPLAB_SRC" ] || stop src_missing "SRC missing (if already moved: --resume-after-move): $KEEPLAB_SRC"
[ -e "$KEEPLAB_DST" ] && stop dst_exists "DST already exists: $KEEPLAB_DST"

say "== 1. AEGL tip → refs/heads/main =="
promote_tip "$AEGL" "$COMMIT" "refs/heads/main" "keeplab-aegl-$COMMIT"

say "== 2. install-broker (AEGL_BUSINESS_ROOT) =="
git -C "$AEGL" show "$COMMIT:recovery/install-broker.sh" \
  | bash -s -- --repo "$AEGL" --projects-root "$PROJECTS_ROOT" \
       --business-root "$BUSINESS_ROOT" --commit "$COMMIT" \
  || stop install_broker_failed "install-broker failed"
grep -q "AEGL_BUSINESS_ROOT=$BUSINESS_ROOT" /etc/systemd/system/aegl-promote-broker.service \
  || stop broker_unit_no_business "unit missing AEGL_BUSINESS_ROOT"
systemctl is-active --quiet aegl-promote-broker || stop broker_inactive "aegl-promote-broker not active"

say "== 3. Stack tip → refs/heads/master (live guard) =="
promote_tip "$STACK" "$STACK_COMMIT" "refs/heads/master" "keeplab-stack-$STACK_COMMIT"

say "== 4. migrate directory move =="
# move only — post deferred until KeepLab promote at new path
git -C "$AEGL" show "$COMMIT:recovery/migrate-keeplab-to-appprojects.sh" \
  | bash -s -- --phase move --aegl "$AEGL" --aegl-commit "$COMMIT" --no-require-patches \
       --src "$KEEPLAB_SRC" --dst "$KEEPLAB_DST" \
  || stop migrate_move_failed "move failed — if DST exists and SRC gone: --resume-after-move"

say "== 5. KeepLab tip → refs/heads/master at AppProjects (after move) =="
promote_tip "$KEEPLAB_DST" "$KEEPLAB_COMMIT" "refs/heads/master" "keeplab-contract-$KEEPLAB_COMMIT"

say "== 6. final post =="
# Optional broker unit reaffirm (already installed); skip full migrate post SYNC
run_final_post_as_operator

cleanup_all
trap - EXIT
say "EXEC_RESULT=OK"
say "STOP_AT=complete"
say "NEW_PATH=$KEEPLAB_DST"
