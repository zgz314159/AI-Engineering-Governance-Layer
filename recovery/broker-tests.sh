#!/usr/bin/env bash
# broker-tests.sh — targeted tests for the trusted-registry broker (run as a unit).
#
# Prior executions of this script (recorded, not erased):
#   round 12: 3 runs (1 test-harness bug, 1 merge-identity bug, then 13/13 on the old design)
#   this round: 1 run (below), + at most one re-verify after a concrete fix.
#
# Same-uid here: this proves FUNCTIONAL correctness only, never the independent
# identity boundary. The broker is started from a FLAT installed layout (launcher +
# modules in one dir) so case (6) — "the installed layout can start" — is exercised.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
CORE="$AEGL_ROOT/recovery/promotion_core.py"

ST="$(mktemp -d /var/tmp/aegl-broker-tests-XXXXXX)" || { echo "mktemp failed"; exit 2; }
PROOT="$ST/projects"; REG="$ST/registry"; SOCK="$ST/broker.sock"; LIB="$ST/lib"
mkdir -p "$PROOT" "$REG" "$LIB"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ [ -n "${BPID:-}" ] && kill "$BPID" 2>/dev/null; wait "${BPID:-}" 2>/dev/null; chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

# --- flat "installed" layout: launcher + python modules in ONE dir ------------- #
install_layout(){
  install -m 0755 "$AEGL_ROOT/bin/aegl-promote-broker" "$LIB/aegl-promote-broker"
  install -m 0644 "$AEGL_ROOT/recovery/promotion_broker.py" "$LIB/promotion_broker.py"
  install -m 0644 "$AEGL_ROOT/recovery/promotion_core.py" "$LIB/promotion_core.py"
}
BROKER="$LIB/aegl-promote-broker"

req(){ "$BROKER" client --request "$1" 2>/dev/null; }
dec(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("decision",""))
except Exception: print("PARSE_ERROR")' 2>/dev/null; }
digest(){ python3 "$AEGL_ROOT/recovery/promotion_core.py" digest "$1" "$2" "$3"; }

new_project(){ local d="$PROOT/$1"; mkdir -p "$d"; git -C "$d" init -q
  ( cd "$d" && echo base > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ); printf '%s' "$d"; }
base_of(){ git -C "$1" rev-parse HEAD; }

# make_wt <project> <branch> <setup-cmd>  -> prints worktree path
make_wt(){ local proj="$1" br="$2" setup="$3"; local wt="$ST/wt-$br"
  git -C "$proj" worktree add -q -b "$br" "$wt" HEAD
  ( cd "$wt" && eval "$setup" )
  printf '%s' "$wt"; }

# --- fixtures ----------------------------------------------------------------- #
APP="$(new_project Google-Android-Agent-Development-Stack)"
BASE="$(base_of "$APP")"

install_layout
[ -f "$BROKER" ] || { echo "install layout missing launcher"; exit 2; }
export AEGL_BROKER_SOCKET="$SOCK" AEGL_BROKER_REGISTRY_DIR="$REG" PROJECTS_ROOT="$PROOT" \
       AEGL_PROJECT_ALLOWLIST="Google-Android-Agent-Development-Stack" \
       AEGL_BROKER_ALLOW_REQUESTERS="$(id -u)" AEGL_BROKER_ALLOW_RECORDERS="$(id -u)"
"$BROKER" serve >"$ST/broker.log" 2>&1 &
BPID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
if [ -S "$SOCK" ]; then ok "installed layout starts (flat launcher+modules)"; else no "installed layout did not start"; cat "$ST/broker.log"; exit 2; fi

# --- 1. tampered task/acceptance cannot obtain promotion authorization --------- #
WT1="$(make_wt "$APP" r1 'echo one > one.txt')"; D1="$(digest "$WT1" "$BASE" r1)"
# a fake, AI-writable acceptance file that the broker must ignore
mkdir -p "$ST/tasks/r1"; printf 'PASS\n' > "$ST/tasks/r1/verify.status"; echo '{"id":"r1"}' > "$ST/tasks/r1/task.json"
r="$(req "{\"op\":\"promote\",\"task_id\":\"r1\"}")"; d="$(dec "$r")"
[ "$d" = REJECTED ] && ok "unregistered task + fake verify.status -> REJECTED (${r##*decision*})" || no "tampered acceptance authorized ($d)"
# registered but never recorded (no acceptance record) -> REJECTED
req "{\"op\":\"register\",\"task_id\":\"r1\",\"project\":\"$APP\",\"base\":\"$BASE\",\"worktree\":\"$WT1\",\"branch\":\"r1\"}" >/dev/null
r="$(req "{\"op\":\"promote\",\"task_id\":\"r1\"}")"; d="$(dec "$r")"
[ "$d" = REJECTED ] && ok "registered without an acceptance record -> REJECTED" || no "missing record authorized ($d)"

# --- 5a. normal approved content promotes (target then carries the change) ------ #
req "{\"op\":\"record\",\"task_id\":\"r1\",\"verify_result\":\"PASS\",\"candidate_digest\":\"$D1\"}" >/dev/null
r="$(req "{\"op\":\"promote\",\"task_id\":\"r1\"}")"; d="$(dec "$r")"
[ "$d" = APPLIED ] && ok "approved content promotes" || no "approved promote ($d: $r)"
git -C "$APP" cat-file -e HEAD:one.txt 2>/dev/null && ok "approved change merged" || no "approved change not merged"

# --- 2. committed violating content still rejected (target unchanged) ---------- #
WT2="$(make_wt "$APP" r2 'mkdir -p build && echo z > build/app.class && git add -A && git -c user.email=t@t -c user.name=t commit -qm bad')"
D2="$(digest "$WT2" "$BASE" r2)"
req "{\"op\":\"register\",\"task_id\":\"r2\",\"project\":\"$APP\",\"base\":\"$BASE\",\"worktree\":\"$WT2\",\"branch\":\"r2\"}" >/dev/null
req "{\"op\":\"record\",\"task_id\":\"r2\",\"verify_result\":\"PASS\",\"candidate_digest\":\"$D2\"}" >/dev/null
r="$(req "{\"op\":\"promote\",\"task_id\":\"r2\"}")"; d="$(dec "$r")"
[ "$d" = REJECTED ] && ok "committed violating content -> REJECTED" || no "committed violation allowed ($d)"
git -C "$APP" cat-file -e HEAD:build/app.class 2>/dev/null && no "violating content merged" || ok "target unchanged after reject"

# --- 3. candidate verify-layout.sh must NOT run as the broker ------------------ #
SIDE="$ST/broker_side_effect"
WT3="$(make_wt "$APP" r3 'echo ok > r3.txt')"
mkdir -p "$WT3/scripts"
printf '#!/bin/sh\ntouch %s\n' "$SIDE" > "$WT3/scripts/verify-layout.sh"
chmod +x "$WT3/scripts/verify-layout.sh"
D3="$(digest "$WT3" "$BASE" r3)"
req "{\"op\":\"register\",\"task_id\":\"r3\",\"project\":\"$APP\",\"base\":\"$BASE\",\"worktree\":\"$WT3\",\"branch\":\"r3\"}" >/dev/null
req "{\"op\":\"record\",\"task_id\":\"r3\",\"verify_result\":\"PASS\",\"candidate_digest\":\"$D3\"}" >/dev/null
r="$(req "{\"op\":\"promote\",\"task_id\":\"r3\"}")"; d="$(dec "$r")"
[ -e "$SIDE" ] && no "candidate verify-layout.sh executed by the broker" || ok "candidate script not executed by the broker ($d)"

# --- 4. candidate content swapped after record -> REJECTED -------------------- #
WT4="$(make_wt "$APP" r4 'echo four > four.txt')"; D4="$(digest "$WT4" "$BASE" r4)"
req "{\"op\":\"register\",\"task_id\":\"r4\",\"project\":\"$APP\",\"base\":\"$BASE\",\"worktree\":\"$WT4\",\"branch\":\"r4\"}" >/dev/null
req "{\"op\":\"record\",\"task_id\":\"r4\",\"verify_result\":\"PASS\",\"candidate_digest\":\"$D4\"}" >/dev/null
echo swapped >> "$WT4/four.txt"
r="$(req "{\"op\":\"promote\",\"task_id\":\"r4\"}")"; d="$(dec "$r")"
[ "$d" = REJECTED ] && ok "candidate swapped after record -> REJECTED" || no "swapped candidate allowed ($d)"
git -C "$APP" cat-file -e HEAD:four.txt 2>/dev/null && no "swapped content merged" || ok "target unchanged after swapped reject"

# --- 5b. disallowed project target rejected, target unchanged ------------------ #
BAD="$(new_project Testapp)"; BB="$(base_of "$BAD")"
WT5="$(make_wt "$BAD" r5 'echo five > five.txt')"
r="$(req "{\"op\":\"register\",\"task_id\":\"r5\",\"project\":\"$BAD\",\"base\":\"$BB\",\"worktree\":\"$WT5\",\"branch\":\"r5\"}")"; d="$(dec "$r")"
[ "$d" = REJECTED ] && ok "disallowed project rejected at register" || no "disallowed project registered ($d)"

# --- requester/unauthorized op ------------------------------------------------ #
r="$(req "{\"op\":\"kill\",\"task_id\":\"r1\"}")"; d="$(dec "$r")"
[ "$d" = REJECTED ] && ok "unsupported op rejected" || no "unsupported op ($d)"

echo "BROKER_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
