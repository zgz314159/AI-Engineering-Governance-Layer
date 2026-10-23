#!/usr/bin/env bash
# trusted-delivery.sh — inner delivery (run from outer root-only copy).
#
# Outer wrap (subshell; sudo sha256sum; keep outer dir mode 0700; EXIT cleans outer only):
#   See PARENT-ENTRY-BIND.md / Round 58 terminal block — OUTER_RDIR holds only this
#   script; this process creates a separate inner RDIR for installers.
#
# Inner cleanup: worktree remove failure keeps EXT + git registration (no rm -rf EXT).
# No safe.directory=*. No worktree remove --force. Broker decision≠expected ⇒ stop.
set -euo pipefail

TIP=""; DEV=""; AEGL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tip) TIP="${2:-}"; shift 2 ;;
    --dev) DEV="${2:-}"; shift 2 ;;
    --aegl) AEGL="${2:-}"; shift 2 ;;
    *) printf 'DELIVERY_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { printf 'DELIVERY_ERROR: must run as root\n' >&2; exit 1; }
[ -n "$TIP" ] && [ "${#TIP}" -eq 40 ] || { printf 'DELIVERY_ERROR: --tip <40-hex> required\n' >&2; exit 1; }
case "$TIP" in [0-9a-f]*) ;; *) printf 'DELIVERY_ERROR: --tip must be 40-hex\n' >&2; exit 1 ;; esac
[ -n "$DEV" ] && [ -d "$DEV/.git" ] || { printf 'DELIVERY_ERROR: --dev git checkout required\n' >&2; exit 1; }
[ -n "$AEGL" ] && [ -d "$AEGL/.git" ] || { printf 'DELIVERY_ERROR: --aegl formal repo required\n' >&2; exit 1; }

# Independent new task-id. Do NOT reuse parent-entry-bind-r57 (prior failed record);
# do NOT clear /var/lib/aegl-promote registry; do NOT treat old registration as approval.
TASK_ID=parent-entry-bind-r59
SOCK=/run/aegl-promote/broker.sock
LIBPROMOTE=/usr/local/lib/aegl-promote
BROKER_BIN=$LIBPROMOTE/aegl-promote-broker
BROKER_USER=aegl-promote
AI_USER=aegl-ai
PROJECTS_ROOT=/home/zhong/Projects
BUSINESS_ROOT=/home/zhong/AppProjects

RDIR=""; EXT=""
CLEAN_PATHS=()
DELIVERY_SUCCEEDED=0

# Inner EXIT cleanup. Never masks a non-zero incoming status with success.
# On worktree remove failure: keep EXT + git registration; do not rm -rf EXT.
cleanup_all(){
  local incoming=$?
  local final="$incoming"
  local wt_err="" p

  if [ -n "${EXT:-}" ] && [ -d "${EXT}/wt" ]; then
    set +e
    wt_err="$(git -C "$AEGL" -c "safe.directory=$AEGL" worktree remove "$EXT/wt" 2>&1)"
    local wt_rc=$?
    set -e
    if [ "$wt_rc" -ne 0 ]; then
      printf 'CLEANUP_ERROR: worktree remove failed — keeping candidate and git registration\n' >&2
      printf 'CLEANUP_ERROR: EXT=%s\n' "$EXT" >&2
      printf 'CLEANUP_ERROR: wt=%s\n' "$EXT/wt" >&2
      printf 'CLEANUP_ERROR: reason=%s\n' "${wt_err:-unknown}" >&2
      printf 'CLEANUP_ERROR: not recursively deleting EXT\n' >&2
      [ "$final" -eq 0 ] && final=1
    else
      if [ -d "$EXT" ]; then
        if ! rmdir "$EXT" 2>/dev/null; then
          printf 'CLEANUP_ERROR: EXT not empty after worktree remove: %s (left in place)\n' "$EXT" >&2
          [ "$final" -eq 0 ] && final=1
        else
          EXT=""
        fi
      else
        EXT=""
      fi
    fi
  elif [ -n "${EXT:-}" ] && [ -d "${EXT:-}" ] && [ ! -e "${EXT}/wt" ]; then
    if ! rmdir "$EXT" 2>/dev/null; then
      printf 'CLEANUP_ERROR: EXT not empty (no wt): %s (left in place)\n' "$EXT" >&2
      [ "$final" -eq 0 ] && final=1
    else
      EXT=""
    fi
  fi

  # Inner RDIR: delete only this run's extracted files, then rmdir (never rm -rf RDIR).
  for p in ${CLEAN_PATHS[@]+"${CLEAN_PATHS[@]}"}; do
    [ -n "$p" ] || continue
    if [ -f "$p" ]; then
      rm -f "$p" || {
        printf 'CLEANUP_ERROR: failed to remove extracted file %s\n' "$p" >&2
        [ "$final" -eq 0 ] && final=1
      }
    fi
  done
  if [ -n "${RDIR:-}" ] && [ -d "${RDIR:-}" ]; then
    if ! rmdir "$RDIR" 2>/dev/null; then
      printf 'CLEANUP_ERROR: inner RDIR not empty after file deletes: %s\n' "$RDIR" >&2
      [ "$final" -eq 0 ] && final=1
    else
      RDIR=""
    fi
  fi

  if [ "$incoming" -ne 0 ]; then
    final="$incoming"
  fi
  if [ "$final" -ne 0 ]; then
    printf 'DELIVERY_CLEANUP_FINAL=%s (not success; no DELIVERY_RESULT=OK)\n' "$final" >&2
    exit "$final"
  fi
  if [ "$DELIVERY_SUCCEEDED" != 1 ]; then
    printf 'DELIVERY_CLEANUP_FINAL=1 (exit without DELIVERY_RESULT=OK)\n' >&2
    exit 1
  fi
  # Only print success after cleanup completed with final=0.
  say "DELIVERY_RESULT=OK tip=$TIP"
  say "FORMAL_DEPLOY=UNITS_STARTED_AND_BROKERS_REINSTALLED"
  say "AI_BOUNDARY=BLOCKED"
}
trap cleanup_all EXIT

say(){ printf '%s\n' "$*"; }
die(){ printf 'DELIVERY_ERROR: %s\n' "$*" >&2; exit 1; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'DELIVERY_ERROR: %s\n' "$*" >&2; exit 1; }

git_aegl(){ git -C "$AEGL" -c "safe.directory=$AEGL" "$@"; }
git_dev(){ git -C "$DEV" -c "safe.directory=$DEV" "$@"; }

extract_hash_ok(){
  local src_path="$1" dest="$2" want got
  git_aegl show "$TIP:$src_path" | tee "$dest" >/dev/null
  chmod 0755 "$dest"
  want="$(git_aegl show "$TIP:$src_path" | sha256sum | awk '{print $1}')"
  got="$(sha256sum "$dest" | awk '{print $1}')"
  [ "$want" = "$got" ] || die "hash mismatch for $src_path want=$want got=$got"
  CLEAN_PATHS+=("$dest")
  say "EXTRACT_OK $dest sha256=$got"
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

require_decision(){
  local label="$1" want="$2" dec
  dec="$(broker_decision "$BROKER_LAST_JSON")"
  [ "$dec" = "$want" ] \
    || stop "broker_${label}_refused" \
      "$label decision=$dec want=$want rc=$BROKER_LAST_RC json=$BROKER_LAST_JSON"
}

# --- 0) bind tip + create root-only delivery dir ---
test "$(git_dev rev-parse HEAD)" = "$TIP" \
  || die "DEV HEAD $(git_dev rev-parse HEAD) != --tip $TIP"

RDIR="$(mktemp -d /var/tmp/aegl-entry-bind-root-XXXXXX)" || die "mktemp RDIR failed"
chmod 0700 "$RDIR"
chown root:root "$RDIR"
say "RDIR=$RDIR"

# --- 1) import objects (command-level exact safe.directory only) ---
git_aegl -c "safe.directory=$DEV" fetch "$DEV" "$TIP"
git_aegl cat-file -e "$TIP^{commit}"

# --- 2) extract helpers + three installers into RDIR; hash as root ---
extract_hash_ok recovery/parent-entry-bind/trusted-delivery.sh "$RDIR/trusted-delivery.sh"
extract_hash_ok recovery/install-parent-entry-bind.sh "$RDIR/install-parent-entry-bind.sh"
extract_hash_ok recovery/install-broker.sh "$RDIR/install-broker.sh"
extract_hash_ok recovery/install-model-broker.sh "$RDIR/install-model-broker.sh"

# Formal sync helpers from production markers (reuse; no simplified copy).
git_aegl show "$TIP:recovery/keeplab-appprojects-exec.sh" \
  | sed -n '/^# BEGIN_FORMAL_SYNC$/,/^# END_FORMAL_SYNC$/p' > "$RDIR/formal-sync-lib.sh"
[ -s "$RDIR/formal-sync-lib.sh" ] || die "failed to extract BEGIN_FORMAL_SYNC block"
grep -q 'sync_formal_to_tip' "$RDIR/formal-sync-lib.sh" || die "formal-sync-lib missing sync_formal_to_tip"
CLEAN_PATHS+=("$RDIR/formal-sync-lib.sh")
# Post host-identity switch: aegl-promote owns formal tree (sync as broker, not zhong).
OP_USER="$BROKER_USER"
# shellcheck disable=SC1090
source "$RDIR/formal-sync-lib.sh"

# Root git in child installers: command-level exact safe.directory via env (never *).
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$AEGL"

# --- 3) Ensure installed promote broker matches tip BEFORE promote.
# install-broker.sh already restarts and waits for socket — never restart again here.
# Matching tip + healthy service ⇒ skip install; mismatch ⇒ call installer once.
# This trusted install is NOT promote approval and does not bypass register/record/promote.
say "== ensure promotion broker matches tip (before promote) =="

broker_tip_sha(){
  # tip blob sha256 for one recovery/bin path
  git_aegl show "$TIP:$1" | sha256sum | awk '{print $1}'
}

broker_files_match_tip(){
  local want got src dst
  # Three installed files ↔ tip sources (same set as install-broker.sh FILES).
  for src_dst in \
    "bin/aegl-promote-broker:$LIBPROMOTE/aegl-promote-broker" \
    "recovery/promotion_broker.py:$LIBPROMOTE/promotion_broker.py" \
    "recovery/promotion_core.py:$LIBPROMOTE/promotion_core.py"
  do
    src="${src_dst%%:*}"
    dst="${src_dst#*:}"
    if [ ! -f "$dst" ]; then
      say "  BROKER_FILE_MISSING path=$dst"
      return 1
    fi
    want="$(broker_tip_sha "$src")"
    got="$(sha256sum "$dst" | awk '{print $1}')"
    if [ "$want" != "$got" ]; then
      say "  BROKER_FILE_MISMATCH path=$dst want=$want got=$got"
      return 1
    fi
    say "  BROKER_FILE_MATCH path=$dst sha256=$got"
  done
  return 0
}

wait_broker_socket(){
  # Bounded wait as broker identity (max 5s). Clear step/rc/reason — no silent test.
  local step="wait_broker_socket" i=0 rc=0 err=""
  say "  $step: waiting up to 5s as $BROKER_USER for $SOCK"
  while [ "$i" -lt 50 ]; do
    set +e
    runuser -u "$BROKER_USER" -- test -S "$SOCK"
    rc=$?
    set -e
    if [ "$rc" = 0 ]; then
      say "  $step: OK socket ready after ${i}00ms"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  set +e
  err="$(runuser -u "$BROKER_USER" -- ls -la "$SOCK" 2>&1)"
  set -e
  stop "$step" \
    "socket not usable by $BROKER_USER after 5s path=$SOCK rc=$rc detail=${err:-none}"
}

check_task_registry(){
  # Inspect registry only — never clear; never treat old rows as approval of this tip.
  local reg=/var/lib/aegl-promote/registry.json
  local step="check_task_registry"
  [ "$TASK_ID" != "parent-entry-bind-r57" ] \
    || stop "$step" "refusing task_id=parent-entry-bind-r57 (prior failed candidate)"
  if [ ! -f "$reg" ]; then
    say "  $step: registry absent path=$reg (ok; nothing to clear)"
    return 0
  fi
  python3 - "$reg" "$TASK_ID" "$TIP" <<'PY' || stop "$step" "registry inspect failed"
import json, sys
reg_path, task_id, tip = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(open(reg_path, encoding="utf-8"))
except Exception as exc:
    print("REGISTRY_ERROR parse_failed: %s" % exc, file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print("REGISTRY_ERROR not_a_object", file=sys.stderr)
    sys.exit(1)
old = data.get("parent-entry-bind-r57")
if old is not None:
    print("REGISTRY_NOTE leftover_task=parent-entry-bind-r57 present=yes (not approval; left intact)")
else:
    print("REGISTRY_NOTE leftover_task=parent-entry-bind-r57 present=no")
cur = data.get(task_id)
if cur is None:
    print("REGISTRY_NOTE task_id=%s present=no (fresh register allowed)" % task_id)
    sys.exit(0)
# Existing r59 row: refuse reuse as if it were a new approval of this tip.
ac = cur.get("approved_commit") if isinstance(cur, dict) else None
print("REGISTRY_REFUSE task_id=%s already_registered approved_commit=%s tip=%s" % (
    task_id, ac, tip), file=sys.stderr)
sys.exit(2)
PY
  say "  $step: OK (registry not cleared; r57 not treated as approval)"
}

WANT_CORE="$(broker_tip_sha recovery/promotion_core.py)"
if broker_files_match_tip \
  && systemctl is-active --quiet aegl-promote-broker; then
  say "  BROKER_ALREADY_MATCHES_TIP commit=$TIP — skip install and restart"
else
  say "  BROKER_NEEDS_INSTALL commit=$TIP (mismatch or service not active)"
  set +e
  bash "$RDIR/install-broker.sh" \
    --repo "$AEGL" --projects-root "$PROJECTS_ROOT" --business-root "$BUSINESS_ROOT" --commit "$TIP"
  inst_rc=$?
  set -e
  [ "$inst_rc" = 0 ] \
    || stop ensure_broker_install \
      "install-broker.sh failed rc=$inst_rc (installer owns restart; not retrying here)"
  # No second systemctl restart — installer already restarted and waited.
  broker_files_match_tip \
    || stop ensure_broker_verify "installed broker files still mismatch tip after install-broker"
  set +e
  systemctl is-active --quiet aegl-promote-broker
  act_rc=$?
  set -e
  [ "$act_rc" = 0 ] \
    || stop ensure_broker_active "aegl-promote-broker not active after install-broker rc=$act_rc"
fi
grep -q '_parse_name_status_z' "$LIBPROMOTE/promotion_core.py" \
  || stop ensure_broker_parser "installed promotion_core.py missing NUL name-status parser"
GOT_CORE="$(sha256sum "$LIBPROMOTE/promotion_core.py" | awk '{print $1}')"
[ "$WANT_CORE" = "$GOT_CORE" ] \
  || stop ensure_broker_core "promotion_core.py sha mismatch want=$WANT_CORE got=$GOT_CORE"
say "BROKER_CORE_READY sha256=$GOT_CORE (tip match; not yet promoted)"

wait_broker_socket
check_task_registry
say "TASK_ID=$TASK_ID (independent; registry not cleared)"

# --- 4) pre-CAS: bind actual main baseline; refuse real dirty ---
FORMAL_BASELINE_OID=""
formal_pre_cas_check "$AEGL" main
BASELINE_OID="$FORMAL_BASELINE_OID"
say "FORMAL_BASELINE_OID=$BASELINE_OID"
test "$(git_aegl rev-parse refs/heads/main)" = "$BASELINE_OID"

# --- 5) candidate worktree (no --force on later remove) ---
EXT="$(mktemp -d /var/tmp/aegl-promote-cand-XXXXXX)" || die "mktemp EXT failed"
chmod 0750 "$EXT"
chown root:root "$EXT"
setfacl -m "u:${BROKER_USER}:--x" "$EXT"
git_aegl worktree add "$EXT/wt" "$TIP"
setfacl -R -m "u:${BROKER_USER}:r-X" "$EXT/wt"
WT_GITDIR="$(git -c "safe.directory=$EXT/wt" -C "$EXT/wt" rev-parse --absolute-git-dir)"
[ -n "$WT_GITDIR" ] && [ -d "$WT_GITDIR" ] || die "candidate gitdir missing"
setfacl -R -m "u:${BROKER_USER}:r-X" "$WT_GITDIR"
if runuser -u "$AI_USER" -- touch "$EXT/wt/.ai-probe" 2>/dev/null; then
  rm -f "$EXT/wt/.ai-probe"
  die "aegl-ai can write candidate worktree — ACL too broad"
fi
test -z "$(git -c "safe.directory=$EXT/wt" -C "$EXT/wt" status --porcelain)"

BASE="$(git_aegl merge-base refs/heads/main "$TIP")"
REG_JSON="$(python3 -c 'import json,sys;print(json.dumps({"protocol":"AEGL-BROKER/1","op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],"worktree":sys.argv[4],"branch":"plan/parent-entry-bind","target_ref":"refs/heads/main"}))' \
  "$TASK_ID" "$AEGL" "$BASE" "$EXT/wt")"

if [ ! -x "$BROKER_BIN" ]; then
  stop broker_bin "broker binary missing or not executable: $BROKER_BIN"
fi
# Socket already waited above; re-check once with clear failure (no silent test).
set +e
runuser -u "$BROKER_USER" -- test -S "$SOCK"
sock_rc=$?
set -e
[ "$sock_rc" = 0 ] \
  || stop broker_socket_pre_register \
    "socket not usable by $BROKER_USER before register path=$SOCK rc=$sock_rc"

broker_client_call REGISTER "$REG_JSON"
require_decision REGISTER REGISTERED

broker_client_call RECORD "{\"protocol\":\"AEGL-BROKER/1\",\"op\":\"record\",\"task_id\":\"$TASK_ID\",\"verify_result\":\"PASS\"}"
require_decision RECORD RECORDED
APPROVED="$(broker_field "$BROKER_LAST_JSON" approved_commit)"
[ "$APPROVED" = "$TIP" ] || stop approved_mismatch "approved_commit=$APPROVED want=$TIP"

broker_client_call PROMOTE "{\"protocol\":\"AEGL-BROKER/1\",\"op\":\"promote\",\"task_id\":\"$TASK_ID\"}" "$AI_USER"
require_decision PROMOTE APPLIED
test "$(git_aegl rev-parse refs/heads/main)" = "$TIP"

# Candidate cleanup WITHOUT --force (unexpected dirty must surface and stop).
git_aegl worktree remove "$EXT/wt" \
  || stop worktree_remove_failed "worktree remove refused (dirty or unexpected state); not using --force"
rmdir "$EXT" \
  || stop ext_not_empty "EXT not empty after worktree remove: $EXT (kept; not rm -rf)"
EXT=""

# --- 6) broker-owned formal sync (main/HEAD/index/worktree; no force overwrite) ---
sync_formal_to_tip "$AEGL" "$TIP" main "$BASELINE_OID"
test "$(git_aegl rev-parse refs/heads/main)" = "$TIP"
test "$(git_aegl rev-parse HEAD)" = "$TIP"
test "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$AEGL" -C "$AEGL" rev-parse --abbrev-ref HEAD)" = "main"
test -z "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$AEGL" -C "$AEGL" status --porcelain)"
say "FORMAL_SYNC_OK main=HEAD=index/worktree @$TIP"

# --- 7) install entry-bind pack + model launcher (promote broker already at tip from step 3) ---
bash "$RDIR/install-parent-entry-bind.sh" --repo "$AEGL" --commit "$TIP"
bash "$RDIR/install-parent-entry-bind.sh" --repo "$AEGL" --commit "$TIP" --apply
bash /usr/local/lib/aegl-entry-bind/require-entry-binds.sh

bash "$RDIR/install-model-broker.sh" --repo "$AEGL" --commit "$TIP"
# Confirm promote broker still matches tip after promote/sync (no silent downgrade).
GOT_CORE2=$(sha256sum "$LIBPROMOTE/promotion_core.py" | awk '{print $1}')
[ "$WANT_CORE" = "$GOT_CORE2" ] || die "promotion_core.py drifted after promote want=$WANT_CORE got=$GOT_CORE2"

DELIVERY_SUCCEEDED=1
# EXIT trap prints DELIVERY_RESULT=OK only after inner cleanup succeeds
