#!/usr/bin/env bash
# promote-stack-tests.sh — out-of-tree minimal validation for full-stack promote.
#
# First run once; after a concrete fix, at most one re-verify. Does NOT re-run
# model / sandbox / browser / recovery suites.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"

ST="$(mktemp -d /var/tmp/aegl-promote-stack-XXXXXX)" || { echo "mktemp failed"; exit 2; }
PROOT="$ST/projects"; REG="$ST/registry"; SOCK="$ST/broker.sock"; LIB="$ST/lib"
mkdir -p "$PROOT" "$REG" "$LIB"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ [ -n "${BPID:-}" ] && kill "$BPID" 2>/dev/null; wait "${BPID:-}" 2>/dev/null; chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

install -m 0755 "$AEGL_ROOT/bin/aegl-promote-broker" "$LIB/aegl-promote-broker"
install -m 0644 "$AEGL_ROOT/recovery/promotion_broker.py" "$LIB/promotion_broker.py"
install -m 0644 "$AEGL_ROOT/recovery/promotion_core.py" "$LIB/promotion_core.py"
BROKER="$LIB/aegl-promote-broker"
req(){ "$BROKER" client --request "$1" 2>/dev/null; }
dec(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")' 2>/dev/null; }
reason(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("reason",""))
except Exception: print("")' 2>/dev/null; }

APP="$PROOT/AI-Engineering-Governance-Layer"
mkdir -p "$APP"
git -C "$APP" init -q
( cd "$APP" && echo base > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base )
git -C "$APP" branch -M master
MAIN0="$(git -C "$APP" rev-parse refs/heads/master)"
git -C "$APP" branch side-keep HEAD
SIDE0="$(git -C "$APP" rev-parse side-keep)"
# Simulate formal dirty content on a non-main checkout path (file not in git).
echo formal-dirt > "$APP/FORMAL_DIRTY.txt"
DIRT_HASH="$(sha256sum "$APP/FORMAL_DIRTY.txt" | awk '{print $1}')"

# Candidate lineage: two commits ahead of main.
WT="$ST/cand"
git -C "$APP" worktree add -q -b cand "$WT" HEAD
( cd "$WT" && echo f1 > feat.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm c1
  echo f2 >> feat.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm c2 )
TIP="$(git -C "$WT" rev-parse HEAD)"
PARENT="$(git -C "$WT" rev-parse HEAD^)"

export AEGL_BROKER_SOCKET="$SOCK" AEGL_BROKER_REGISTRY_DIR="$REG" PROJECTS_ROOT="$PROOT" \
       AEGL_PROJECT_ALLOWLIST="AI-Engineering-Governance-Layer" \
       AEGL_BROKER_ALLOW_REQUESTERS="$(id -u)" AEGL_BROKER_ALLOW_RECORDERS="$(id -u)"
"$BROKER" serve >"$ST/broker.log" 2>&1 &
BPID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "broker failed to start"; cat "$ST/broker.log"; exit 2; }

# --- 1. happy path: main FF to tip; other branch + dirt untouched ------------ #
req "{\"op\":\"register\",\"task_id\":\"stack1\",\"project\":\"$APP\",\"base\":\"$MAIN0\",\"worktree\":\"$WT\",\"branch\":\"cand\",\"target_ref\":\"refs/heads/master\"}" >/dev/null
req '{"op":"record","task_id":"stack1","verify_result":"PASS"}' >/dev/null
d="$(req '{"op":"promote","task_id":"stack1"}')"
[ "$(dec "$d")" = APPLIED ] && ok "stack promote APPLIED" || no "stack promote $(dec "$d") $(reason "$d")"
[ "$(git -C "$APP" rev-parse refs/heads/master)" = "$TIP" ] && ok "main updated to candidate tip" || no "main not tip"
git -C "$APP" merge-base --is-ancestor "$PARENT" refs/heads/master \
  && ok "main contains candidate parent (history)" || no "parent not on main"
[ "$(git -C "$APP" rev-parse side-keep)" = "$SIDE0" ] && ok "side-keep unchanged" || no "side-keep moved"
[ "$(sha256sum "$APP/FORMAL_DIRTY.txt" | awk '{print $1}')" = "$DIRT_HASH" ] \
  && ok "pre-existing dirty file untouched" || no "dirty file altered"

# --- 2. target OID change rejected ------------------------------------------ #
WT2="$ST/cand2"
git -C "$APP" worktree add -q -b cand2 "$WT2" refs/heads/master
( cd "$WT2" && echo more > more.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm more )
MAIN1="$(git -C "$APP" rev-parse refs/heads/master)"
req "{\"op\":\"register\",\"task_id\":\"stack2\",\"project\":\"$APP\",\"base\":\"$MAIN1\",\"worktree\":\"$WT2\",\"branch\":\"cand2\",\"target_ref\":\"refs/heads/master\"}" >/dev/null
req '{"op":"record","task_id":"stack2","verify_result":"PASS"}' >/dev/null
# Move main via commit-tree + update-ref (no checkout / no formal switch).
TREE="$(git -C "$APP" rev-parse "refs/heads/master^{tree}")"
SNEAK="$(git -C "$APP" -c user.email=t@t -c user.name=t commit-tree "$TREE" -p refs/heads/master -m sneak)"
git -C "$APP" update-ref refs/heads/master "$SNEAK"
d2="$(req '{"op":"promote","task_id":"stack2"}')"
[ "$(dec "$d2")" = REJECTED ] && [ "$(reason "$d2")" = target_changed ] \
  && ok "target OID change REJECTED" || no "target change $(dec "$d2") $(reason "$d2")"
[ "$(git -C "$APP" rev-parse refs/heads/master)" = "$SNEAK" ] && ok "main stays at sneak after reject" || no "main moved on reject"

# --- 3. permission failure is explicit (chmod objects away from broker uid) - #
# Simulate by pointing PROJECTS_ROOT at a project whose .git/refs/heads is unwritable
# to the current process after dropping write bits (same-uid test of update-ref fail).
WT3="$ST/cand3"
# reset main to tip lineage for a fresh FF attempt
git -C "$APP" update-ref refs/heads/master "$TIP"
git -C "$APP" worktree add -q -b cand3 "$WT3" "$TIP"
( cd "$WT3" && echo p > p.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm p )
MAIN3="$(git -C "$APP" rev-parse refs/heads/master)"
req "{\"op\":\"register\",\"task_id\":\"stack3\",\"project\":\"$APP\",\"base\":\"$MAIN3\",\"worktree\":\"$WT3\",\"branch\":\"cand3\",\"target_ref\":\"refs/heads/master\"}" >/dev/null
req '{"op":"record","task_id":"stack3","verify_result":"PASS"}' >/dev/null
chmod a-w "$APP/.git/refs/heads" "$APP/.git/refs/heads/master" 2>/dev/null || true
d3="$(req '{"op":"promote","task_id":"stack3"}')"
chmod u+w "$APP/.git/refs/heads" "$APP/.git/refs/heads/master" 2>/dev/null || true
# Expect FAILED with update_ref (or REJECTED if race); must not silently APPLIED.
case "$(dec "$d3")" in
  FAILED|REJECTED) ok "insufficient write -> explicit $(dec "$d3") ($(reason "$d3"))" ;;
  *) no "permission deny not explicit ($(dec "$d3") $(reason "$d3"))" ;;
esac
[ "$(git -C "$APP" rev-parse refs/heads/master)" = "$MAIN3" ] && ok "main unchanged on perm fail" || no "main moved on perm fail"

echo "PROMOTE_STACK_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
