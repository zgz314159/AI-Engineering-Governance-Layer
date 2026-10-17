#!/usr/bin/env bash
# trusted-delivery.sh — complete trusted-terminal delivery for parent-entry tip.
# Extract from fixed SHA into a root-only dir and run THAT copy (never user tree).
#
#   TIP=<40-hex> DEV=... AEGL=...
#   RDIR=$(sudo mktemp -d /var/tmp/aegl-entry-bind-root-XXXXXX)
#   sudo install -o root -g root -m 0700 -d "$RDIR"
#   sudo git -C "$AEGL" -c "safe.directory=$AEGL" show \
#     "$TIP:recovery/parent-entry-bind/trusted-delivery.sh" \
#     | sudo tee "$RDIR/trusted-delivery.sh" >/dev/null
#   sudo chmod 0755 "$RDIR/trusted-delivery.sh"
#   sudo bash "$RDIR/trusted-delivery.sh" --tip "$TIP" --dev "$DEV" --aegl "$AEGL"
#
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

TASK_ID=parent-entry-bind-r57
SOCK=/run/aegl-promote/broker.sock
LIBPROMOTE=/usr/local/lib/aegl-promote
BROKER_BIN=$LIBPROMOTE/aegl-promote-broker
BROKER_USER=aegl-promote
AI_USER=aegl-ai
PROJECTS_ROOT=/home/zhong/Projects
BUSINESS_ROOT=/home/zhong/AppProjects

RDIR=""; EXT=""
CLEAN_PATHS=()

cleanup_all(){
  local p
  if [ -n "${EXT:-}" ] && [ -d "${EXT}/wt" ]; then
    git -C "$AEGL" -c "safe.directory=$AEGL" worktree remove "$EXT/wt" 2>/dev/null || true
  fi
  if [ -n "${EXT:-}" ] && [ -d "${EXT:-}" ]; then
    rm -rf "$EXT"
  fi
  for p in ${CLEAN_PATHS[@]+"${CLEAN_PATHS[@]}"}; do
    [ -n "$p" ] || continue
    if [ -f "$p" ] || [ -d "$p" ]; then
      rm -rf "$p"
    fi
  done
  if [ -n "${RDIR:-}" ] && [ -d "${RDIR:-}" ]; then
    rm -rf "$RDIR"
  fi
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

# --- 3) pre-CAS: bind actual main baseline; refuse real dirty ---
FORMAL_BASELINE_OID=""
formal_pre_cas_check "$AEGL" main
BASELINE_OID="$FORMAL_BASELINE_OID"
say "FORMAL_BASELINE_OID=$BASELINE_OID"
test "$(git_aegl rev-parse refs/heads/main)" = "$BASELINE_OID"

# --- 4) candidate worktree (no --force on later remove) ---
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

[ -S "$SOCK" ] || die "broker socket missing: $SOCK"
[ -x "$BROKER_BIN" ] || die "broker binary missing: $BROKER_BIN"

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
rm -rf "$EXT"
EXT=""

# --- 5) broker-owned formal sync (main/HEAD/index/worktree; no force overwrite) ---
sync_formal_to_tip "$AEGL" "$TIP" main "$BASELINE_OID"
test "$(git_aegl rev-parse refs/heads/main)" = "$TIP"
test "$(git_aegl rev-parse HEAD)" = "$TIP"
test "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$AEGL" -C "$AEGL" rev-parse --abbrev-ref HEAD)" = "main"
test -z "$(runuser -u "$BROKER_USER" -- git -c "safe.directory=$AEGL" -C "$AEGL" status --porcelain)"
say "FORMAL_SYNC_OK main=HEAD=index/worktree @$TIP"

# Root git in child installers: command-level exact safe.directory via env (never *).
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$AEGL"

# --- 6) install entry-bind pack from RDIR copy ---
bash "$RDIR/install-parent-entry-bind.sh" --repo "$AEGL" --commit "$TIP"
bash "$RDIR/install-parent-entry-bind.sh" --repo "$AEGL" --commit "$TIP" --apply
bash /usr/local/lib/aegl-entry-bind/require-entry-binds.sh

# --- 7) reinstall promote + model brokers from RDIR copies (host entry ≠ tip source) ---
bash "$RDIR/install-broker.sh" \
  --repo "$AEGL" --projects-root "$PROJECTS_ROOT" --business-root "$BUSINESS_ROOT" --commit "$TIP"
systemctl restart aegl-promote-broker
systemctl is-active --quiet aegl-promote-broker
test -S "$SOCK"

bash "$RDIR/install-model-broker.sh" --repo "$AEGL" --commit "$TIP"

say "DELIVERY_RESULT=OK tip=$TIP"
say "FORMAL_DEPLOY=UNITS_STARTED_AND_BROKERS_REINSTALLED"
say "AI_BOUNDARY=BLOCKED"
# EXIT trap cleans RDIR + extracted paths
