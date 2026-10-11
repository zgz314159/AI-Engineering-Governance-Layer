#!/usr/bin/env bash
# broker-tests.sh — targeted tests for the trusted-registry broker (one consolidated run).
#
# Prior executions (recorded, not erased):
#   round 12: 3 runs (2 test-harness defects, then 13/13 on the old digest design)
#   round 13: 4 runs (3 test-harness defects, then 12/12 on the registry design)
#   this round: 1 run below, + at most one re-verify after a concrete fix.
#
# Same-uid here proves FUNCTIONAL logic only. The independent-UID acceptance lives in
# recovery/install-broker.sh --self-test and is NOT this same-uid run.
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

new_project(){ local d="$PROOT/$1"; mkdir -p "$d"; git -C "$d" init -q
  ( cd "$d" && echo base > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ); printf '%s' "$d"; }
base_of(){ git -C "$1" rev-parse HEAD; }
make_wt(){ local proj="$1" br="$2" setup="$3"; local wt="$ST/wt-$br"
  git -C "$proj" worktree add -q -b "$br" "$wt" HEAD
  ( cd "$wt" && eval "$setup" )
  printf '%s' "$wt"; }
reg(){ req "{\"op\":\"register\",\"task_id\":\"$1\",\"project\":\"$2\",\"base\":\"$3\",\"worktree\":\"$4\",\"branch\":\"$5\"}" >/dev/null; }

APP="$(new_project Google-Android-Agent-Development-Stack)"
BASE="$(base_of "$APP")"
install_layout
[ -f "$BROKER" ] || { echo "install layout missing launcher"; exit 2; }

# --- 2. production defaults separate the roles (checked before any override) --- #
default_recorders="$(env -u AEGL_BROKER_ALLOW_RECORDERS python3 -c "import sys;sys.path.insert(0,'$AEGL_ROOT/recovery');import promotion_broker as b;print(sorted(b.recorder_uids()))")"
case "$default_recorders" in
  "[0]") ok "production recorder default is root only (AI identity excluded)" ;;
  *) no "production recorder default = $default_recorders (expected [0])" ;;
esac

export AEGL_BROKER_SOCKET="$SOCK" AEGL_BROKER_REGISTRY_DIR="$REG" PROJECTS_ROOT="$PROOT" \
       AEGL_PROJECT_ALLOWLIST="Google-Android-Agent-Development-Stack" \
       AEGL_BROKER_ALLOW_REQUESTERS="$(id -u)" AEGL_BROKER_ALLOW_RECORDERS="$(id -u)"   # TEST-ONLY override
"$BROKER" serve >"$ST/broker.log" 2>&1 &
BPID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] && ok "installed flat layout starts" || { no "installed layout did not start"; cat "$ST/broker.log"; exit 2; }

# --- 1/3/4. tampered task / missing acceptance -> no authorization ------------- #
WT1="$(make_wt "$APP" r1 'echo one > one.txt')"
mkdir -p "$ST/tasks/r1"; printf 'PASS\n' > "$ST/tasks/r1/verify.status"; echo '{"id":"r1"}' > "$ST/tasks/r1/task.json"
[ "$(dec "$(req '{"op":"promote","task_id":"r1"}')")" = REJECTED ] && ok "unregistered task + fake verify.status -> REJECTED" || no "tampered acceptance authorized"
reg r1 "$APP" "$BASE" "$WT1" r1
[ "$(dec "$(req '{"op":"promote","task_id":"r1"}')")" = REJECTED ] && ok "registered without an acceptance record -> REJECTED" || no "missing record authorized"

# --- 5. approved content promotes + merged ------------------------------------ #
req '{"op":"record","task_id":"r1","verify_result":"PASS"}' >/dev/null
[ "$(dec "$(req '{"op":"promote","task_id":"r1"}')")" = APPLIED ] && ok "approved content promotes" || no "approved promote"
git -C "$APP" cat-file -e HEAD:one.txt 2>/dev/null && ok "approved change merged" || no "approved change not merged"

# --- 8. exact object: a worktree swap after record does not change what applies #
WT8="$(make_wt "$APP" r8 'echo approved > eight.txt')"
reg r8 "$APP" "$BASE" "$WT8" r8
req '{"op":"record","task_id":"r8","verify_result":"PASS"}' >/dev/null
echo SWAPPED > "$WT8/eight.txt"      # tamper AFTER the object was recorded
d8="$(dec "$(req '{"op":"promote","task_id":"r8"}')")"
content="$(git -C "$APP" show HEAD:eight.txt 2>/dev/null | tr -d '\n')"
{ [ "$d8" = APPLIED ] && [ "$content" = approved ]; } && ok "applies the recorded object; worktree swap ignored" || no "exact object apply ($d8 content=$content)"

# --- 9. content binding covers symlink target + file mode --------------------- #
WT9="$(make_wt "$APP" r9 'echo runnable > tool.sh && chmod +x tool.sh && ln -s tool.sh link.sh')"
reg r9 "$APP" "$BASE" "$WT9" r9
req '{"op":"record","task_id":"r9","verify_result":"PASS"}' >/dev/null
d9="$(dec "$(req '{"op":"promote","task_id":"r9"}')")"
mode="$(git -C "$APP" ls-tree HEAD tool.sh | awk '{print $1}')"
linkmode="$(git -C "$APP" ls-tree HEAD link.sh | awk '{print $1}')"
{ [ "$d9" = APPLIED ] && [ "$mode" = 100755 ] && [ "$linkmode" = 120000 ]; } && ok "symlink target + exec mode bound and applied ($mode/$linkmode)" || no "mode/symlink binding ($d9 $mode/$linkmode)"

# --- 6. committed violating content still rejected ---------------------------- #
WT6="$(make_wt "$APP" r6 'mkdir -p build && echo z > build/app.class && git add -A && git -c user.email=t@t -c user.name=t commit -qm bad')"
reg r6 "$APP" "$BASE" "$WT6" r6
d6="$(dec "$(req '{"op":"record","task_id":"r6","verify_result":"PASS"}')")"
[ "$d6" = REJECTED ] && ok "committed violating content -> record REJECTED" || no "committed violation allowed ($d6)"
git -C "$APP" cat-file -e HEAD:build/app.class 2>/dev/null && no "violating content merged" || ok "target unchanged after reject"

# --- 7. candidate verify-layout.sh never runs as the broker ------------------- #
SIDE="$ST/broker_side_effect"
WT7="$(make_wt "$APP" r7 'echo ok > r7.txt')"
mkdir -p "$WT7/scripts"; printf '#!/bin/sh\ntouch %s\n' "$SIDE" > "$WT7/scripts/verify-layout.sh"; chmod +x "$WT7/scripts/verify-layout.sh"
reg r7 "$APP" "$BASE" "$WT7" r7
req '{"op":"record","task_id":"r7","verify_result":"PASS"}' >/dev/null
req '{"op":"promote","task_id":"r7"}' >/dev/null
[ -e "$SIDE" ] && no "candidate verify-layout.sh executed by the broker" || ok "candidate script not executed by the broker"

# --- 10. disallowed project target rejected ----------------------------------- #
BAD="$(new_project Testapp)"; BB="$(base_of "$BAD")"; WT10="$(make_wt "$BAD" r10 'echo x > x.txt')"
reg r10 "$BAD" "$BB" "$WT10" r10
[ "$(dec "$(req '{"op":"promote","task_id":"r10"}')")" = REJECTED ] && ok "disallowed project not registered -> REJECTED" || no "disallowed project handled"

# --- 11. unsupported op ------------------------------------------------------- #
[ "$(dec "$(req "{\"op\":\"kill\",\"task_id\":\"r1\"}")")" = REJECTED ] && ok "unsupported op rejected" || no "unsupported op"

# --- 12. candidate clean filter must NOT run (frozen object built filter-free) - #
SIDE2="$ST/filter_side_effect"
WT12="$(make_wt "$APP" r12 'echo x > data.txt')"
printf '*.evil filter=evilfilter\n' > "$WT12/.gitattributes"
printf '#!/bin/sh\ntouch %s\n' "$SIDE2" > "$ST/evilfilter.sh"; chmod +x "$ST/evilfilter.sh"
git -C "$APP" config filter.evilfilter.process "$ST/evilfilter.sh"
echo payload > "$WT12/data.evil"
reg r12 "$APP" "$BASE" "$WT12" r12
req '{"op":"record","task_id":"r12","verify_result":"PASS"}' >/dev/null
req '{"op":"promote","task_id":"r12"}' >/dev/null
[ -e "$SIDE2" ] && no "candidate clean filter executed by the broker" || ok "clean filter not executed (frozen object built filter-free)"

# --- 13. object-bound symlink escape rejected --------------------------------- #
WT13="$(make_wt "$APP" r13 'echo ok > x.txt && ln -s /etc/passwd escape')"
reg r13 "$APP" "$BASE" "$WT13" r13
d13="$(dec "$(req '{"op":"record","task_id":"r13","verify_result":"PASS"}')")"
[ "$d13" = REJECTED ] && ok "object-bound symlink escape rejected" || no "object symlink escape allowed ($d13)"

echo "BROKER_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
