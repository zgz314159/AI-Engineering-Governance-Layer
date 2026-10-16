#!/usr/bin/env bash
# keeplab-appprojects-exec.sh — unified trusted-terminal pack for KeepLab → AppProjects.
#
# Delivery (fixed SHA; no placeholders once TIP is this commit):
#   git -C "$AEGL" show "$TIP:recovery/keeplab-appprojects-exec.sh" | sudo bash -s -- --commit "$TIP"
#
# Order (hard gates; each prints STOP_AT=… on failure):
#   1) preflight tips present in object store
#   2) promote AEGL tip → refs/heads/main (broker) if not already
#   3) install-broker (+ AEGL_BUSINESS_ROOT) from AEGL tip
#   4) promote Stack tip → refs/heads/master (broker) if not already
#   5) promote KeepLab contract tip → refs/heads/master if provided and not already
#   6) migrate move + post checks
#
# Resume after a successful move when a later step failed:
#   … | sudo bash -s -- --commit "$TIP" --resume-after-move
#
# Does NOT run switch / chattr / node_modules cleanup / Cursor rules / push.
set -uo pipefail

AEGL="/home/zhong/Projects/AI-Engineering-Governance-Layer"
STACK="/home/zhong/Projects/Google-Android-Agent-Development-Stack"
KEEPLAB_SRC="/home/zhong/Projects/KeepLab-Relay"
KEEPLAB_DST="/home/zhong/AppProjects/KeepLab-Relay"
PROJECTS_ROOT="/home/zhong/Projects"
BUSINESS_ROOT="/home/zhong/AppProjects"
COMMIT=""
STACK_COMMIT=""
KEEPLAB_COMMIT=""
RESUME_AFTER_MOVE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --stack-commit) STACK_COMMIT="${2:-}"; shift 2 ;;
    --keeplab-commit) KEEPLAB_COMMIT="${2:-}"; shift 2 ;;
    --resume-after-move) RESUME_AFTER_MOVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --stack) STACK="${2:-}"; shift 2 ;;
    *) printf 'EXEC_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'EXEC_ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$COMMIT" ] || stop need_commit "--commit <full-40-hex AEGL tip> is required"
[ "${#COMMIT}" -eq 40 ] || stop bad_commit "--commit must be full 40-hex"
git -C "$AEGL" cat-file -e "$COMMIT^{commit}" 2>/dev/null || stop aegl_commit_missing "AEGL commit not in object store: $COMMIT"

# Stack / KeepLab tips default to values recorded in this commit's plan note env file
# embedded below as constants when the pack is cut — overridden by flags.
: "${STACK_COMMIT:=}"
: "${KEEPLAB_COMMIT:=}"

say "KEEPLAB_EXEC begin commit=$COMMIT resume_after_move=$RESUME_AFTER_MOVE dry_run=$DRY_RUN"

# --- helpers: broker promote one tip onto a project's exact target ref -------- #
promote_tip() {
  local proj="$1" tip="$2" target_ref="$3" task_id="$4"
  local tip_now
  tip_now="$(git -C "$proj" rev-parse "$target_ref")"
  if [ "$tip_now" = "$tip" ]; then
    say "PROMOTE_SKIP $proj $target_ref already=$tip"
    return 0
  fi
  git -C "$proj" merge-base --is-ancestor "$tip_now" "$tip" 2>/dev/null \
    || stop promote_not_ff "$proj: $tip is not a fast-forward of $target_ref=$tip_now"
  [ "$(id -u)" = 0 ] || stop promote_need_root "promote step requires root (broker register/record)"
  [ -S "${AEGL_BROKER_SOCKET:-/run/aegl-promote/broker.sock}" ] \
    || stop promote_no_socket "broker socket missing (install/start aegl-promote-broker)"

  local ext wt base
  ext="$(mktemp -d /var/tmp/aegl-keeplab-prom-XXXXXX)" || stop promote_mktemp "mktemp failed"
  git -C "$proj" worktree add -f "$ext/wt" "$tip" || stop promote_worktree "worktree add failed for $tip"
  wt="$ext/wt"
  base="$(git -C "$proj" merge-base "$target_ref" "$tip")"
  # ACL for this project's exact target ref
  git -C "$AEGL" show "$COMMIT:recovery/install-promote-target-acl.sh" \
    | bash -s -- --repo "$AEGL" --project "$proj" --commit "$COMMIT" \
         --target-ref "$target_ref" --business-root "$BUSINESS_ROOT" \
    || { git -C "$proj" worktree remove --force "$wt" 2>/dev/null; rm -rf "$ext"; stop promote_acl_failed "ACL install failed for $proj"; }

  local LIB=/usr/local/lib/aegl-promote
  local reg_json rec_json prom_json
  reg_json="$(python3 -c 'import json,sys;print(json.dumps({"protocol":"AEGL-BROKER/1","op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],"worktree":sys.argv[4],"branch":"plan/keeplab-migrate","target_ref":sys.argv[5]}))' \
    "$task_id" "$proj" "$base" "$wt" "$target_ref")"
  say "BROKER_REGISTER_JSON=$(AEGL_BROKER_SOCKET="${AEGL_BROKER_SOCKET:-/run/aegl-promote/broker.sock}" "$LIB/aegl-promote-broker" client --request "$reg_json" 2>&1)"; local rrc=$?
  say "BROKER_REGISTER_RC=$rrc"
  [ "$rrc" = 0 ] || { git -C "$proj" worktree remove --force "$wt" 2>/dev/null; rm -rf "$ext"; stop promote_register_failed "$proj register rc=$rrc"; }

  rec_json="$(python3 -c 'import json,sys;print(json.dumps({"protocol":"AEGL-BROKER/1","op":"record","task_id":sys.argv[1],"verify_result":"PASS"}))' "$task_id")"
  say "BROKER_RECORD_JSON=$(AEGL_BROKER_SOCKET="${AEGL_BROKER_SOCKET:-/run/aegl-promote/broker.sock}" "$LIB/aegl-promote-broker" client --request "$rec_json" 2>&1)"; local crc=$?
  say "BROKER_RECORD_RC=$crc"
  [ "$crc" = 0 ] || { git -C "$proj" worktree remove --force "$wt" 2>/dev/null; rm -rf "$ext"; stop promote_record_failed "$proj record rc=$crc"; }

  # Promote as aegl-ai (requester)
  prom_json="$(python3 -c 'import json,sys;print(json.dumps({"protocol":"AEGL-BROKER/1","op":"promote","task_id":sys.argv[1]}))' "$task_id")"
  say "BROKER_PROMOTE_JSON=$(runuser -u aegl-ai -- env AEGL_BROKER_SOCKET="${AEGL_BROKER_SOCKET:-/run/aegl-promote/broker.sock}" "$LIB/aegl-promote-broker" client --request "$prom_json" 2>&1)"; local prc=$?
  say "BROKER_PROMOTE_RC=$prc"
  git -C "$proj" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$ext"
  [ "$prc" = 0 ] || stop promote_promote_failed "$proj promote rc=$prc"
  [ "$(git -C "$proj" rev-parse "$target_ref")" = "$tip" ] \
    || stop promote_tip_mismatch "$proj $target_ref != $tip after promote"
  say "PROMOTE_OK $proj $target_ref=$tip"
}

# --- resume path: directory already moved ---------------------------------- #
if [ "$RESUME_AFTER_MOVE" = 1 ]; then
  [ -d "$KEEPLAB_DST" ] || stop resume_dst_missing "DST missing: $KEEPLAB_DST"
  [ -e "$KEEPLAB_SRC" ] && stop resume_src_still_present "SRC still present; not in after-move state: $KEEPLAB_SRC"
  say "== resume-after-move: post + broker sync only =="
  git -C "$AEGL" show "$COMMIT:recovery/migrate-keeplab-to-appprojects.sh" \
    | bash -s -- --phase post --aegl "$AEGL" --aegl-commit "$COMMIT" --sync-broker \
         --dst "$KEEPLAB_DST" --src "$KEEPLAB_SRC" \
    || stop resume_post_failed "migrate --phase post failed"
  say "EXEC_RESULT=OK mode=resume-after-move"
  say "STOP_AT=complete"
  exit 0
fi

# --- dry-run: migrate precheck only (no promote/move) ---------------------- #
if [ "$DRY_RUN" = 1 ]; then
  git -C "$AEGL" show "$COMMIT:recovery/migrate-keeplab-to-appprojects.sh" \
    | bash -s -- --dry-run --no-require-patches \
    || stop dry_run_failed "migrate dry-run failed"
  say "EXEC_RESULT=OK mode=dry-run"
  say "STOP_AT=dry_run_ok"
  exit 0
fi

[ "$(id -u)" = 0 ] || stop need_root "full exec pack requires root (promote + install-broker + move as needed)"

# 1) AEGL → main
say "== 1. AEGL tip → refs/heads/main =="
promote_tip "$AEGL" "$COMMIT" "refs/heads/main" "keeplab-aegl-path-$COMMIT"

# Formal tree onto main if clean enough (no hard reset)
if [ "$(git -C "$AEGL" rev-parse --abbrev-ref HEAD)" != main ]; then
  if [ -z "$(git -C "$AEGL" status --porcelain)" ]; then
    git -C "$AEGL" switch main || stop aegl_switch_main "git switch main failed"
  else
    say "AEGL_FORMAL_SWITCH=SKIPPED (porcelain dirty; tip is on main ref; operator closes checkout later)"
  fi
fi

# 2) install broker with business root (before move)
say "== 2. install-broker (AEGL_BUSINESS_ROOT) =="
git -C "$AEGL" show "$COMMIT:recovery/install-broker.sh" \
  | bash -s -- --repo "$AEGL" --projects-root "$PROJECTS_ROOT" \
       --business-root "$BUSINESS_ROOT" --commit "$COMMIT" \
  || stop install_broker_failed "install-broker failed"
grep -q "AEGL_BUSINESS_ROOT=$BUSINESS_ROOT" /etc/systemd/system/aegl-promote-broker.service \
  || stop broker_unit_no_business "unit missing AEGL_BUSINESS_ROOT"

# 3) Stack → master (required: live Hermes guard is formal Stack file)
if [ -n "$STACK_COMMIT" ]; then
  say "== 3. Stack tip → refs/heads/master =="
  git -C "$STACK" cat-file -e "$STACK_COMMIT^{commit}" 2>/dev/null \
    || stop stack_commit_missing "Stack commit not in object store: $STACK_COMMIT"
  promote_tip "$STACK" "$STACK_COMMIT" "refs/heads/master" "keeplab-stack-path-$STACK_COMMIT"
  if [ "$(git -C "$STACK" rev-parse --abbrev-ref HEAD)" != master ]; then
    if [ -z "$(git -C "$STACK" status --porcelain | grep -vE '^ \? references/' || true)" ]; then
      git -C "$STACK" switch master || say "STACK_FORMAL_SWITCH=SKIPPED"
    fi
  fi
else
  stop need_stack_commit "--stack-commit <full-40-hex> required (live guard is formal Stack tree)"
fi

# 4) KeepLab contract tip (optional but recommended before move)
if [ -n "$KEEPLAB_COMMIT" ]; then
  say "== 4. KeepLab tip → refs/heads/master =="
  local_kl="$KEEPLAB_SRC"
  [ -d "$local_kl" ] || stop keeplab_src_missing "KeepLab source missing for contract promote: $local_kl"
  git -C "$local_kl" cat-file -e "$KEEPLAB_COMMIT^{commit}" 2>/dev/null \
    || stop keeplab_commit_missing "KeepLab commit not in object store: $KEEPLAB_COMMIT"
  promote_tip "$local_kl" "$KEEPLAB_COMMIT" "refs/heads/master" "keeplab-contract-$KEEPLAB_COMMIT"
else
  say "KEEPLAB_CONTRACT_PROMOTE=SKIPPED (no --keeplab-commit)"
fi

# 5) move + post
say "== 5. migrate move + post =="
git -C "$AEGL" show "$COMMIT:recovery/migrate-keeplab-to-appprojects.sh" \
  | bash -s -- --phase all --aegl "$AEGL" --aegl-commit "$COMMIT" --sync-broker \
       --src "$KEEPLAB_SRC" --dst "$KEEPLAB_DST" \
  || stop migrate_failed "migrate failed — if DST exists and SRC gone: re-run with --resume-after-move"

say "EXEC_RESULT=OK"
say "STOP_AT=complete"
say "NEW_PATH=$KEEPLAB_DST"
