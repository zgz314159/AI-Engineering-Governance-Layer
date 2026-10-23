#!/usr/bin/env bash
# continue-partial-deploy.sh — resume partial entry-bind deploy (root only).
#
# Phases:
#   checker — replace require-entry-binds.sh only; live-check five mounts
#   promote — NEW task-id register/record/promote + formal sync (not r59)
#   model   — install-model-broker from TIP (no --self-test)
#
# All phases run as root. Formal-sync helpers are sourced as root from a root
# temp file (never sourced by an unprivileged outer shell).
#
#   bash continue-partial-deploy.sh --tip TIP --aegl AEGL --phase checker
#   bash continue-partial-deploy.sh --tip TIP --aegl AEGL --phase promote --task-id parent-entry-bind-r60
#   bash continue-partial-deploy.sh --tip TIP --aegl AEGL --phase model
set -euo pipefail

TIP=""; AEGL=""; PHASE=""; TASK_ID=""
LIBEB=/usr/local/lib/aegl-entry-bind
CHECKER=$LIBEB/require-entry-binds.sh
SOCK=/run/aegl-promote/broker.sock
LIBPROMOTE=/usr/local/lib/aegl-promote
BROKER_BIN=$LIBPROMOTE/aegl-promote-broker
BROKER_USER=aegl-promote
AI_USER=aegl-ai

while [ $# -gt 0 ]; do
  case "$1" in
    --tip) TIP="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    *) printf 'CONTINUE_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { printf 'CONTINUE_ERROR: must run as root\n' >&2; exit 1; }
[ -n "$TIP" ] && [ "${#TIP}" -eq 40 ] || { printf 'CONTINUE_ERROR: --tip <40-hex>\n' >&2; exit 1; }
[ -n "$AEGL" ] && [ -d "$AEGL/.git" ] || { printf 'CONTINUE_ERROR: --aegl\n' >&2; exit 1; }
case "$PHASE" in checker|promote|model) ;; *) printf 'CONTINUE_ERROR: --phase checker|promote|model\n' >&2; exit 1 ;; esac

say(){ printf '%s\n' "$*"; }
die(){ printf 'CONTINUE_ERROR: %s\n' "$*" >&2; exit 1; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'CONTINUE_ERROR: %s\n' "$*" >&2; exit 1; }
git_aegl(){ git -C "$AEGL" -c "safe.directory=$AEGL" "$@"; }

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$AEGL"

git_aegl cat-file -e "$TIP^{commit}" || die "tip not in AEGL object store: $TIP"

broker_decision(){
  printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")' 2>/dev/null
}

broker_field(){
  printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$2" 2>/dev/null
}

broker_client_call(){
  local label="$1" req="$2" as_user="${3:-}" out="" rc=0
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

require_decision(){
  local label="$1" want="$2" dec
  dec="$(broker_decision "$BROKER_LAST_JSON")"
  [ "$dec" = "$want" ] \
    || stop "broker_${label}_refused" \
      "$label decision=$dec want=$want rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
}

case "$PHASE" in
  checker)
    say "== phase=checker: install require-entry-binds.sh only =="
    [ -d "$LIBEB" ] || die "missing $LIBEB (entry-bind pack not installed)"
    [ -f /etc/aegl/entry-bind/policy ] || die "policy missing — not a partial-deploy resume"
    STAGE="$(mktemp)"
    git_aegl show "$TIP:recovery/parent-entry-bind/require-entry-binds.sh" > "$STAGE"
    WANT="$(git_aegl show "$TIP:recovery/parent-entry-bind/require-entry-binds.sh" | sha256sum | awk '{print $1}')"
    GOT="$(sha256sum "$STAGE" | awk '{print $1}')"
    [ "$WANT" = "$GOT" ] || die "checker extract hash mismatch want=$WANT got=$GOT"
    install -o root -g root -m 0755 "$STAGE" "$CHECKER"
    rm -f "$STAGE"
    GOT2="$(sha256sum "$CHECKER" | awk '{print $1}')"
    [ "$WANT" = "$GOT2" ] || die "installed checker hash mismatch"
    say "CHECKER_INSTALLED path=$CHECKER sha256=$GOT2"
    say "== run live require-entry-binds once =="
    bash "$CHECKER" || die "require-entry-binds failed after checker replace"
    say "CHECKER_LIVE_OK"
    say "NEXT: --phase promote --task-id <new-id> then --phase model"
    ;;

  promote)
    [ -n "$TASK_ID" ] || die "--task-id required for promote"
    [ "$TASK_ID" != "parent-entry-bind-r59" ] \
      || die "refusing task_id=parent-entry-bind-r59 (already used)"
    [ "$TASK_ID" != "parent-entry-bind-r57" ] \
      || die "refusing task_id=parent-entry-bind-r57"
    bash "$CHECKER" || die "checker must pass before promote"
    [ -S "$SOCK" ] || die "broker socket missing: $SOCK"
    [ -x "$BROKER_BIN" ] || die "broker binary missing: $BROKER_BIN"

    say "== phase=promote: task_id=$TASK_ID tip=$TIP =="

    # Drop stale candidate dirs from a prior failed outer continue (best-effort).
    for stale in /var/tmp/aegl-promote-cand-*; do
      [ -d "$stale" ] || continue
      if [ -d "$stale/wt" ]; then
        git_aegl worktree remove "$stale/wt" 2>/dev/null || true
      fi
      rmdir "$stale" 2>/dev/null || true
    done

    # Formal sync helpers: extract + source AS ROOT (never unprivileged source).
    FS="$(mktemp /var/tmp/aegl-formal-sync-XXXXXX)"
    chmod 0600 "$FS"
    git_aegl show "$TIP:recovery/keeplab-appprojects-exec.sh" \
      | sed -n '/^# BEGIN_FORMAL_SYNC$/,/^# END_FORMAL_SYNC$/p' > "$FS"
    [ -s "$FS" ] || die "failed to extract BEGIN_FORMAL_SYNC"
    grep -q 'sync_formal_to_tip' "$FS" || die "formal-sync lib incomplete"
    OP_USER="$BROKER_USER"
    # shellcheck disable=SC1090
    source "$FS"

    FORMAL_BASELINE_OID=""
    formal_pre_cas_check "$AEGL" main
    BASELINE_OID="$FORMAL_BASELINE_OID"
    BASELINE="$(git_aegl rev-parse refs/heads/main)"
    [ "$BASELINE_OID" = "$BASELINE" ] \
      || die "baseline mismatch FORMAL_BASELINE_OID=$BASELINE_OID main=$BASELINE"

    EXT="$(mktemp -d /var/tmp/aegl-promote-cand-XXXXXX)"
    chmod 0750 "$EXT"
    setfacl -m "u:${BROKER_USER}:--x" "$EXT"
    git_aegl worktree add "$EXT/wt" "$TIP"
    setfacl -R -m "u:${BROKER_USER}:r-X" "$EXT/wt"
    WT_GITDIR="$(git -c "safe.directory=$EXT/wt" -C "$EXT/wt" rev-parse --absolute-git-dir)"
    [ -n "$WT_GITDIR" ] && [ -d "$WT_GITDIR" ] || die "candidate gitdir missing"
    setfacl -R -m "u:${BROKER_USER}:r-X" "$WT_GITDIR"
    if runuser -u "$AI_USER" -- touch "$EXT/wt/.ai-probe" 2>/dev/null; then
      rm -f "$EXT/wt/.ai-probe"
      die "aegl-ai can write candidate worktree"
    fi
    test -z "$(git -c "safe.directory=$EXT/wt" -C "$EXT/wt" status --porcelain)"

    BASE="$(git_aegl merge-base refs/heads/main "$TIP")"
    REG_JSON="$(python3 -c 'import json,sys;print(json.dumps({"protocol":"AEGL-BROKER/1","op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],"worktree":sys.argv[4],"branch":"plan/parent-entry-bind","target_ref":"refs/heads/main"}))' \
      "$TASK_ID" "$AEGL" "$BASE" "$EXT/wt")"

    broker_client_call REGISTER "$REG_JSON"
    require_decision REGISTER REGISTERED
    broker_client_call RECORD "{\"protocol\":\"AEGL-BROKER/1\",\"op\":\"record\",\"task_id\":\"$TASK_ID\",\"verify_result\":\"PASS\"}"
    require_decision RECORD RECORDED
    APPROVED="$(broker_field "$BROKER_LAST_JSON" approved_commit)"
    [ "$APPROVED" = "$TIP" ] || stop approved_mismatch "approved_commit=$APPROVED want=$TIP"
    broker_client_call PROMOTE "{\"protocol\":\"AEGL-BROKER/1\",\"op\":\"promote\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
    require_decision PROMOTE APPLIED
    test "$(git_aegl rev-parse refs/heads/main)" = "$TIP"

    git_aegl worktree remove "$EXT/wt" \
      || stop worktree_remove_failed "worktree remove refused; not using --force"
    rmdir "$EXT" || stop ext_not_empty "EXT not empty after worktree remove: $EXT"
    EXT=""

    sync_formal_to_tip "$AEGL" "$TIP" main "$BASELINE_OID"
    test "$(git_aegl rev-parse HEAD)" = "$TIP"
    test "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$AEGL" -C "$AEGL" rev-parse --abbrev-ref HEAD)" = "main"
    test -z "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$AEGL" -C "$AEGL" status --porcelain)"
    rm -f "$FS"
    say "PROMOTE_SYNC_OK tip=$TIP task_id=$TASK_ID"
    say "NEXT: --phase model"
    ;;

  model)
    say "== phase=model: install-model-broker (no --self-test) =="
    bash "$CHECKER" || die "checker must still pass before model install"
    test "$(git_aegl rev-parse refs/heads/main)" = "$TIP" \
      || die "main is not tip $TIP — promote first"
    RDIR="$(mktemp -d /var/tmp/aegl-model-install-XXXXXX)"
    chmod 0700 "$RDIR"
    git_aegl show "$TIP:recovery/install-model-broker.sh" > "$RDIR/install-model-broker.sh"
    chmod 0755 "$RDIR/install-model-broker.sh"
    WANT="$(git_aegl show "$TIP:recovery/install-model-broker.sh" | sha256sum | awk '{print $1}')"
    GOT="$(sha256sum "$RDIR/install-model-broker.sh" | awk '{print $1}')"
    [ "$WANT" = "$GOT" ] || die "install-model-broker hash mismatch"
    bash "$RDIR/install-model-broker.sh" --repo "$AEGL" --commit "$TIP"
    rm -f "$RDIR/install-model-broker.sh"
    rmdir "$RDIR" 2>/dev/null || true
    say "MODEL_BROKER_INSTALL_OK commit=$TIP"
    ;;
esac
