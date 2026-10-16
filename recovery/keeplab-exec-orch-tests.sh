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

# --- 3) real sync_formal_to_tip after update-ref on checked-out branch ------- #
# Extract production formal-sync helpers (BEGIN/END markers) — no simplified copy.
OP_USER="$(id -un)"
export OP_USER
say(){ printf '%s\n' "$*"; }
# Match production stop semantics inside sourced helpers (exit the subshell/process).
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'EXEC_ERROR: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1090
eval "$(python3 - "$EXEC" <<'PY'
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
a = t.index("# BEGIN_FORMAL_SYNC")
b = t.index("# END_FORMAL_SYNC")
print(t[a:b + len("# END_FORMAL_SYNC")])
PY
)"

REPO="$ST/formal"; mkdir -p "$REPO"
git -C "$REPO" init -q
( cd "$REPO" && echo v1 > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm v1 )
git -C "$REPO" branch -M main
V1="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -b cand
( cd "$REPO" && echo v2 > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm v2 )
V2="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
test "$(cat "$REPO/f.txt")" = "v1"

FORMAL_BASELINE_OID=""
if formal_pre_cas_check "$REPO" main && [ "$FORMAL_BASELINE_OID" = "$V1" ]; then
  ok "pre-CAS baseline recorded"
else
  no "pre-CAS baseline"
fi

git -C "$REPO" update-ref refs/heads/main "$V2"
test "$(git -C "$REPO" rev-parse HEAD)" = "$V2"
test "$(cat "$REPO/f.txt")" = "v1"

if sync_formal_to_tip "$REPO" "$V2" main "$V1" \
  && [ "$(cat "$REPO/f.txt")" = "v2" ] \
  && [ "$(git -C "$REPO" rev-parse HEAD)" = "$V2" ] \
  && [ -z "$(git -C "$REPO" status --porcelain)" ] \
  && [ "$(git -C "$REPO" rev-parse HEAD:f.txt)" = "$(git -C "$REPO" hash-object -t blob -- f.txt)" ]; then
  ok "sync_formal_to_tip restores ref/index/file after update-ref"
else
  no "sync_formal_to_tip after update-ref"
fi

# Real user edit must not be overwritten: pre-CAS refuses before ref update.
REPO2="$ST/formal2"; mkdir -p "$REPO2"
git -C "$REPO2" init -q
( cd "$REPO2" && echo a > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm a )
git -C "$REPO2" branch -M main
echo userdirt >> "$REPO2/f.txt"
BEFORE="$(cat "$REPO2/f.txt")"
if ( formal_pre_cas_check "$REPO2" main >/dev/null 2>&1 ); then
  no "pre-CAS should refuse real user dirty"
else
  [ "$(cat "$REPO2/f.txt")" = "$BEFORE" ] \
    && ok "real user dirty preserved (pre-CAS refuse)" \
    || no "user dirty overwritten"
fi

# Post-CAS new user edit: sync refuses and preserves
REPO3="$ST/formal3"; mkdir -p "$REPO3"
git -C "$REPO3" init -q
( cd "$REPO3" && echo a > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm a )
git -C "$REPO3" branch -M main
B1="$(git -C "$REPO3" rev-parse HEAD)"
git -C "$REPO3" checkout -q -b c
( cd "$REPO3" && echo b > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm b )
B2="$(git -C "$REPO3" rev-parse HEAD)"
git -C "$REPO3" checkout -q main
( formal_pre_cas_check "$REPO3" main >/dev/null )
git -C "$REPO3" update-ref refs/heads/main "$B2"
echo sneak >> "$REPO3/f.txt"
SNEAK="$(cat "$REPO3/f.txt")"
if ( sync_formal_to_tip "$REPO3" "$B2" main "$B1" >/dev/null 2>&1 ); then
  no "sync should refuse new user edit after CAS"
else
  [ "$(cat "$REPO3/f.txt")" = "$SNEAK" ] \
    && ok "post-CAS user edit preserved (sync refuse)" \
    || no "post-CAS user edit lost"
fi

# Static: no blanket references/ ignore; no ls-tree|head sample
if grep -nE 'grep -vE.*references/' "$EXEC" | grep -vqE '^\s*#'; then
  no "exec still blanket-ignores references/"
else
  ok "no blanket references/ ignore"
fi
grep -qE 'ls-tree.*\|[[:space:]]*head' "$EXEC" \
  && no "exec still uses ls-tree|head (SIGPIPE risk)" \
  || ok "ls-tree sample fully consumes input"
MIG="$AEGL_ROOT/recovery/migrate-keeplab-to-appprojects.sh"
if grep -q 'as_operator()' "$MIG" \
  && awk '/as_operator env/{f=1} f && /aegl-recovery/{c++; f=0} END{exit !(c>=2)}' "$MIG"; then
  ok "migrate doctor runs via as_operator"
else
  no "migrate doctor not as_operator"
fi

echo "KEEPLAB_ORCH_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
