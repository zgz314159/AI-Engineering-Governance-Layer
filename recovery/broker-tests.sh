#!/usr/bin/env bash
# broker-tests.sh — targeted tests for the trusted-registry broker (one consolidated run).
#
# Same-uid here proves FUNCTIONAL logic only. Independent-UID acceptance lives in
# recovery/install-broker.sh --self-test. Full-stack FF / target-bind / ACL checks live
# in recovery/promote-stack-tests.sh (run separately, once + optional re-verify).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"

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
reason(){ printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("reason",""))
except Exception: print("")' 2>/dev/null; }

new_project(){ local d="$PROOT/$1"; mkdir -p "$d"; git -C "$d" init -q
  ( cd "$d" && echo base > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base )
  local bname
  bname="$(AEGL_ROOT="$AEGL_ROOT" python3 -c 'import os,sys;sys.path.insert(0,os.environ["AEGL_ROOT"]+"/recovery");import promotion_core as c;print(c.target_ref_for(sys.argv[1]).rsplit("/",1)[-1])' "$1")"
  git -C "$d" branch -M "$bname"
  printf '%s' "$d"; }
base_of(){ git -C "$1" rev-parse HEAD; }
# Candidate worktree: commit the setup so freeze_candidate_commit can bind a real tip.
make_wt(){ local proj="$1" br="$2" setup="$3"; local wt="$ST/wt-$br"
  git -C "$proj" worktree add -q -b "$br" "$wt" HEAD
  ( cd "$wt" && eval "$setup" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "cand-$br" )
  printf '%s' "$wt"; }
reg(){
  local ref
  ref="$(AEGL_ROOT="$AEGL_ROOT" python3 -c 'import os,sys;sys.path.insert(0,os.environ["AEGL_ROOT"]+"/recovery");import promotion_core as c;print(c.target_ref_for(os.path.basename(sys.argv[1])))' "$2")"
  req "$(python3 -c 'import json,sys;print(json.dumps({"op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],"worktree":sys.argv[4],"branch":sys.argv[5],"target_ref":sys.argv[6]}))' \
    "$1" "$2" "$3" "$4" "$5" "$ref")" >/dev/null
}

APP="$(new_project Google-Android-Agent-Development-Stack)"
BASE="$(base_of "$APP")"
OTHER_BR_OID=""
git -C "$APP" branch keep-other HEAD
OTHER_BR_OID="$(git -C "$APP" rev-parse keep-other)"
install_layout
[ -f "$BROKER" ] || { echo "install layout missing launcher"; exit 2; }

# --- production defaults separate the roles --------------------------------- #
default_recorders="$(env -u AEGL_BROKER_ALLOW_RECORDERS python3 -c "import sys;sys.path.insert(0,'$AEGL_ROOT/recovery');import promotion_broker as b;print(sorted(b.recorder_uids()))")"
case "$default_recorders" in
  "[0]") ok "production recorder default is root only (AI identity excluded)" ;;
  *) no "production recorder default = $default_recorders (expected [0])" ;;
esac

export AEGL_BROKER_SOCKET="$SOCK" AEGL_BROKER_REGISTRY_DIR="$REG" PROJECTS_ROOT="$PROOT" \
       AEGL_PROJECT_ALLOWLIST="Google-Android-Agent-Development-Stack" \
       AEGL_BROKER_ALLOW_REQUESTERS="$(id -u)" AEGL_BROKER_ALLOW_RECORDERS="$(id -u)"
"$BROKER" serve >"$ST/broker.log" 2>&1 &
BPID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] && ok "installed flat layout starts" || { no "installed layout did not start"; cat "$ST/broker.log"; exit 2; }

# --- unregistered / missing record ------------------------------------------ #
WT1="$(make_wt "$APP" r1 'echo one > one.txt')"
[ "$(dec "$(req '{"op":"promote","task_id":"r1"}')")" = REJECTED ] && ok "unregistered task -> REJECTED" || no "tampered acceptance authorized"
reg r1 "$APP" "$BASE" "$WT1" r1
[ "$(dec "$(req '{"op":"promote","task_id":"r1"}')")" = REJECTED ] && ok "registered without record -> REJECTED" || no "missing record authorized"

# --- approved tip promotes + history preserved on main ---------------------- #
req '{"op":"record","task_id":"r1","verify_result":"PASS"}' >/dev/null
TIP1="$(git -C "$WT1" rev-parse HEAD)"
d1="$(req '{"op":"promote","task_id":"r1"}')"
[ "$(dec "$d1")" = APPLIED ] && ok "approved tip promotes" || no "approved promote ($(dec "$d1") $(reason "$d1"))"
MAIN1="$(git -C "$APP" rev-parse refs/heads/master)"
{ [ "$MAIN1" = "$TIP1" ] && git -C "$APP" merge-base --is-ancestor "$TIP1" refs/heads/master; } \
  && ok "main is the approved tip (history preserved)" || no "main tip mismatch main=$MAIN1 tip=$TIP1"
git -C "$APP" cat-file -e "refs/heads/master:one.txt" 2>/dev/null && ok "approved change on main" || no "approved change missing"
[ "$(git -C "$APP" rev-parse keep-other)" = "$OTHER_BR_OID" ] && ok "unrelated branch keep-other unchanged" || no "other branch moved"

# --- exact object: worktree swap after record does not change apply --------- #
WT8="$(make_wt "$APP" r8 'echo approved > eight.txt')"
# re-bind target to current main (moved by r1)
BASE8="$(git -C "$APP" rev-parse refs/heads/master)"
reg r8 "$APP" "$BASE8" "$WT8" r8
req '{"op":"record","task_id":"r8","verify_result":"PASS"}' >/dev/null
TIP8="$(git -C "$WT8" rev-parse HEAD)"
echo SWAPPED > "$WT8/eight.txt"      # dirty AFTER freeze
# dirty worktree must not affect promote (apply uses frozen OID); but a *new* record would fail
d8="$(dec "$(req '{"op":"promote","task_id":"r8"}')")"
content="$(git -C "$APP" show refs/heads/master:eight.txt 2>/dev/null | tr -d '\n')"
{ [ "$d8" = APPLIED ] && [ "$content" = approved ] && [ "$(git -C "$APP" rev-parse refs/heads/master)" = "$TIP8" ]; } \
  && ok "applies frozen tip; worktree swap ignored" || no "exact object apply ($d8 content=$content)"

# --- symlink target + file mode bound via committed tip --------------------- #
BASE9="$(git -C "$APP" rev-parse refs/heads/master)"
WT9="$(make_wt "$APP" r9 'echo runnable > tool.sh && chmod +x tool.sh && ln -s tool.sh link.sh')"
reg r9 "$APP" "$BASE9" "$WT9" r9
req '{"op":"record","task_id":"r9","verify_result":"PASS"}' >/dev/null
d9="$(dec "$(req '{"op":"promote","task_id":"r9"}')")"
mode="$(git -C "$APP" ls-tree refs/heads/master tool.sh | awk '{print $1}')"
linkmode="$(git -C "$APP" ls-tree refs/heads/master link.sh | awk '{print $1}')"
{ [ "$d9" = APPLIED ] && [ "$mode" = 100755 ] && [ "$linkmode" = 120000 ]; } \
  && ok "symlink target + exec mode bound and applied ($mode/$linkmode)" || no "mode/symlink binding ($d9 $mode/$linkmode)"

# --- committed violating content still rejected ----------------------------- #
BASE6="$(git -C "$APP" rev-parse refs/heads/master)"
WT6="$(make_wt "$APP" r6 'mkdir -p build && echo z > build/app.class')"
reg r6 "$APP" "$BASE6" "$WT6" r6
d6="$(dec "$(req '{"op":"record","task_id":"r6","verify_result":"PASS"}')")"
[ "$d6" = REJECTED ] && ok "committed violating content -> record REJECTED" || no "committed violation allowed ($d6)"
PRE6="$(git -C "$APP" rev-parse refs/heads/master)"
req '{"op":"promote","task_id":"r6"}' >/dev/null
[ "$(git -C "$APP" rev-parse refs/heads/master)" = "$PRE6" ] && ok "target unchanged after reject" || no "target moved after reject"

# --- dirty worktree at record is rejected ----------------------------------- #
BASE_D="$(git -C "$APP" rev-parse refs/heads/master)"
WT_D="$(make_wt "$APP" rd 'echo ok > rd.txt')"
echo dirt >> "$WT_D/rd.txt"
reg rd "$APP" "$BASE_D" "$WT_D" rd
rd_out="$(req '{"op":"record","task_id":"rd","verify_result":"PASS"}')"
dd="$(dec "$rd_out")"; rdreason="$(reason "$rd_out")"
[ "$dd" = REJECTED ] && ok "dirty worktree -> record REJECTED" || no "dirty worktree recorded ($dd $rdreason)"

# --- candidate script never runs -------------------------------------------- #
SIDE="$ST/broker_side_effect"
BASE7="$(git -C "$APP" rev-parse refs/heads/master)"
WT7="$(make_wt "$APP" r7 'echo ok > r7.txt; mkdir -p scripts; printf "#!/bin/sh\ntouch %s\n" "'"$SIDE"'" > scripts/verify-layout.sh; chmod +x scripts/verify-layout.sh')"
reg r7 "$APP" "$BASE7" "$WT7" r7
req '{"op":"record","task_id":"r7","verify_result":"PASS"}' >/dev/null
req '{"op":"promote","task_id":"r7"}' >/dev/null
[ -e "$SIDE" ] && no "candidate verify-layout.sh executed by the broker" || ok "candidate script not executed by the broker"

# --- disallowed project ----------------------------------------------------- #
BAD="$(new_project Testapp)"; BB="$(base_of "$BAD")"; WT10="$(make_wt "$BAD" r10 'echo x > x.txt')"
reg r10 "$BAD" "$BB" "$WT10" r10
[ "$(dec "$(req '{"op":"promote","task_id":"r10"}')")" = REJECTED ] && ok "disallowed project not registered -> REJECTED" || no "disallowed project handled"

# --- unsupported op --------------------------------------------------------- #
[ "$(dec "$(req "{\"op\":\"kill\",\"task_id\":\"r1\"}")")" = REJECTED ] && ok "unsupported op rejected" || no "unsupported op"

# --- object-bound symlink escape rejected ----------------------------------- #
BASE13="$(git -C "$APP" rev-parse refs/heads/master)"
WT13="$(make_wt "$APP" r13 'echo ok > x.txt && ln -s /etc/passwd escape')"
reg r13 "$APP" "$BASE13" "$WT13" r13
d13="$(dec "$(req '{"op":"record","task_id":"r13","verify_result":"PASS"}')")"
[ "$d13" = REJECTED ] && ok "object-bound symlink escape rejected" || no "object symlink escape allowed ($d13)"

# --- target_oid change rejects promote -------------------------------------- #
BASE_T="$(git -C "$APP" rev-parse refs/heads/master)"
WT_T="$(make_wt "$APP" rt 'echo target > t.txt')"
reg rt "$APP" "$BASE_T" "$WT_T" rt
req '{"op":"record","task_id":"rt","verify_result":"PASS"}' >/dev/null
TREE_T="$(git -C "$APP" rev-parse "refs/heads/master^{tree}")"
SNEAK="$(git -C "$APP" -c user.email=t@t -c user.name=t commit-tree "$TREE_T" -p refs/heads/master -m sneak)"
git -C "$APP" update-ref refs/heads/master "$SNEAK"
d_t="$(req '{"op":"promote","task_id":"rt"}')"
[ "$(dec "$d_t")" = REJECTED ] && [ "$(reason "$d_t")" = target_changed ] \
  && ok "target OID change -> REJECTED target_changed" || no "target change not refused ($(dec "$d_t") $(reason "$d_t"))"


# --- business project under AEGL_BUSINESS_ROOT (KeepLab) --------------------- #
BROOT="$ST/AppProjects"; mkdir -p "$BROOT"
export AEGL_BUSINESS_ROOT="$BROOT" AEGL_PROJECT_ALLOWLIST="Google-Android-Agent-Development-Stack,KeepLab-Relay,AI-Engineering-Governance-Layer"
KL="$(new_project KeepLab-Relay)"; # wrong: new_project puts under PROOT
# relocate KeepLab into business root
rm -rf "$BROOT/KeepLab-Relay"
mv "$KL" "$BROOT/KeepLab-Relay"
KL="$BROOT/KeepLab-Relay"
BASE_KL="$(base_of "$KL")"
WT_KL="$(make_wt "$KL" rkl 'echo biz > biz.txt')"
# restart broker with business root (same socket; kill old)
kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
rm -f "$SOCK"
export AEGL_BROKER_SOCKET="$SOCK" AEGL_BROKER_REGISTRY_DIR="$REG" PROJECTS_ROOT="$PROOT" \
       AEGL_BUSINESS_ROOT="$BROOT" \
       AEGL_PROJECT_ALLOWLIST="Google-Android-Agent-Development-Stack,KeepLab-Relay,AI-Engineering-Governance-Layer" \
       AEGL_BROKER_ALLOW_REQUESTERS="$(id -u)" AEGL_BROKER_ALLOW_RECORDERS="$(id -u)"
"$BROKER" serve >"$ST/broker2.log" 2>&1 &
BPID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
reg rkl "$KL" "$BASE_KL" "$WT_KL" rkl
req '{"op":"record","task_id":"rkl","verify_result":"PASS"}' >/dev/null
dkl="$(dec "$(req '{"op":"promote","task_id":"rkl"}')")"
[ "$dkl" = APPLIED ] && ok "business KeepLab under AppProjects promotes" || no "business KeepLab promote ($dkl)"
# KeepLab left under Projects must reject
BADKL="$PROOT/KeepLab-Relay"; mkdir -p "$BADKL"; git -C "$BADKL" init -q
( cd "$BADKL" && echo z > z.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm z )
git -C "$BADKL" branch -M main
WT_BAD="$(make_wt "$BADKL" rbad 'echo bad > bad.txt')"
reg rbad "$BADKL" "$(base_of "$BADKL")" "$WT_BAD" rbad
[ "$(dec "$(req '{"op":"promote","task_id":"rbad"}')")" = REJECTED ] \
  && ok "KeepLab under Projects root rejected" || no "KeepLab under Projects accepted"

echo "BROKER_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
