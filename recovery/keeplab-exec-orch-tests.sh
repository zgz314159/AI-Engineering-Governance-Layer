#!/usr/bin/env bash
# keeplab-exec-orch-tests.sh — minimal orchestration regression for KeepLab exec pack.
# First run once; after a concrete fix, at most one re-verify.
# No model / browser / recovery / full APK.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
EXEC="$AEGL_ROOT/recovery/keeplab-appprojects-exec.sh"
ST="$(mktemp -d /var/tmp/aegl-keeplab-orch-XXXXXX)" || { echo "mktemp failed"; exit 2; }
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

# --- 1) static: proven patterns present (reuse, not simplified) ------------- #
grep -q 'broker_client_call' "$EXEC" && grep -q 'BROKER_.*_RC=' "$EXEC" \
  && grep -q 'approved_commit' "$EXEC" && grep -q 'setfacl' "$EXEC" \
  && grep -q 'cleanup_all' "$EXEC" && grep -q 'sync_formal_to_tip' "$EXEC" \
  && ok "exec reuses broker RC/JSON + ACL + approved_commit + sync" \
  || no "exec missing proven promote patterns"

if grep -nE '^[[:space:]]*git[[:space:]]+(reset[[:space:]]+--hard|clean|stash)' "$EXEC"; then
  no "exec uses forbidden reset/clean/stash"
else
  ok "no reset/hard/clean/stash"
fi

# KeepLab promote after move in planned order
python3 - <<PY
from pathlib import Path
t = Path("$EXEC").read_text()
i_move = t.find("== 4. migrate directory move")
i_kl = t.find("== 5. KeepLab tip")
assert i_move > 0 and i_kl > i_move, (i_move, i_kl)
assert "promote KeepLab" in t
assert "KEEPLAB_DST" in t
print("ORDER_OK")
PY
[ $? -eq 0 ] && ok "KeepLab promote ordered after move" || no "KeepLab promote order"

# dry-run requires three SHAs
OUT="$(bash "$EXEC" --dry-run --commit "$(printf 'a%.0s' {1..40})" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "$OUT" | grep -qE 'STOP_AT=need_stack_commit|STOP_AT=bad_sha' \
  && ok "dry-run requires stack/keeplab SHAs" || no "dry-run SHA gate ($rc $OUT)"

# --- 2) broker reject stops (throwaway broker) ------------------------------ #
PROOT="$ST/projects"; REG="$ST/registry"; SOCK="$ST/broker.sock"; LIB="$ST/lib"
mkdir -p "$PROOT" "$REG" "$LIB"
install -m 0755 "$AEGL_ROOT/bin/aegl-promote-broker" "$LIB/aegl-promote-broker"
install -m 0644 "$AEGL_ROOT/recovery/promotion_broker.py" "$LIB/promotion_broker.py"
install -m 0644 "$AEGL_ROOT/recovery/promotion_core.py" "$LIB/promotion_core.py"
BROKER="$LIB/aegl-promote-broker"
export AEGL_BROKER_SOCKET="$SOCK" AEGL_BROKER_REGISTRY_DIR="$REG" PROJECTS_ROOT="$PROOT" \
       AEGL_BUSINESS_ROOT="$ST/AppProjects" \
       AEGL_PROJECT_ALLOWLIST="Google-Android-Agent-Development-Stack,KeepLab-Relay,AI-Engineering-Governance-Layer" \
       AEGL_BROKER_ALLOW_REQUESTERS="$(id -u)" AEGL_BROKER_ALLOW_RECORDERS="$(id -u)"
mkdir -p "$ST/AppProjects"
"$BROKER" serve >"$ST/broker.log" 2>&1 &
BPID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { no "broker start"; exit 2; }

# KeepLab under Projects must be rejected (business root required)
KL_OLD="$PROOT/KeepLab-Relay"; mkdir -p "$KL_OLD"
git -C "$KL_OLD" init -q
( cd "$KL_OLD" && echo x > r.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm t )
git -C "$KL_OLD" branch -M master
BASE="$(git -C "$KL_OLD" rev-parse HEAD)"
WT="$ST/wt-old"; git -C "$KL_OLD" worktree add -q -b c1 "$WT" HEAD
( cd "$WT" && echo y > y.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm c )
REQ="$(python3 -c 'import json,sys;print(json.dumps({"op":"register","task_id":"rej1","project":sys.argv[1],"base":sys.argv[2],"worktree":sys.argv[3],"branch":"c1","target_ref":"refs/heads/master"}))' "$KL_OLD" "$BASE" "$WT")"
OUTR="$("$BROKER" client --request "$REQ" 2>&1)"; RCR=$?
DEC="$(printf '%s' "$OUTR" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE")')"
{ [ "$DEC" = REJECTED ] || [ "$RCR" != 0 ]; } \
  && ok "broker rejects KeepLab under Projects" || no "KeepLab under Projects accepted ($DEC $OUTR)"

# KeepLab under AppProjects registers
KL_NEW="$ST/AppProjects/KeepLab-Relay"
rm -rf "$KL_NEW"
mkdir -p "$KL_NEW"
git -C "$KL_NEW" init -q
( cd "$KL_NEW" && echo x > r.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm t )
git -C "$KL_NEW" branch -M master
BASE2="$(git -C "$KL_NEW" rev-parse HEAD)"
WT2="$ST/wt-new"; git -C "$KL_NEW" worktree add -q -b c2 "$WT2" HEAD
( cd "$WT2" && echo z > z.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm c2 )
REQ2="$(python3 -c 'import json,sys;print(json.dumps({"op":"register","task_id":"ok1","project":sys.argv[1],"base":sys.argv[2],"worktree":sys.argv[3],"branch":"c2","target_ref":"refs/heads/master"}))' "$KL_NEW" "$BASE2" "$WT2")"
OUT2="$("$BROKER" client --request "$REQ2" 2>&1)"
DEC2="$(printf '%s' "$OUT2" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("decision",""))')"
[ "$DEC2" = REGISTERED ] && ok "broker accepts KeepLab under AppProjects" || no "AppProjects KeepLab ($DEC2 $OUT2)"

kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null; unset BPID

# --- 3) checked-out target branch: ref update + restore sync ---------------- #
REPO="$ST/formal"; mkdir -p "$REPO"
git -C "$REPO" init -q
( cd "$REPO" && echo v1 > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm v1 )
git -C "$REPO" branch -M main
V1="$(git -C "$REPO" rev-parse HEAD)"
# second commit on side, then update-ref main (simulate broker CAS) while checked out on main
git -C "$REPO" checkout -q -b cand
( cd "$REPO" && echo v2 > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm v2 )
V2="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
# worktree still v1 content; move main ref like broker update-ref
git -C "$REPO" update-ref refs/heads/main "$V2"
# HEAD now points at V2 via main, but file may still be v1 until restore
test "$(git -C "$REPO" rev-parse HEAD)" = "$V2"
# sync without reset --hard
(
  cd "$REPO"
  porcelain="$(git status --porcelain || true)"
  # after update-ref, status is typically dirty-looking vs index
  git restore --source=HEAD --staged --worktree -- .
  test "$(git rev-parse HEAD)" = "$V2"
  test -z "$(git status --porcelain)"
  test "$(cat f.txt)" = "v2"
  want="$(git rev-parse HEAD:f.txt)"
  got="$(git hash-object -t blob -- f.txt)"
  test "$want" = "$got"
) && ok "checked-out branch sync restores files to tip" || no "formal sync after update-ref"

# dirty preserve: refuse sync when modified
echo dirt >> "$REPO/f.txt"
(
  cd "$REPO"
  porcelain="$(git status --porcelain | grep -vE '^.. references/' || true)"
  test -n "$porcelain"
) && ok "dirty formal tree detected for preserve" || no "dirty detect"

echo "KEEPLAB_ORCH_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
