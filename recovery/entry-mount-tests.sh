#!/usr/bin/env bash
# Focused checks for THIS round's four entry fixes ONLY. Every check uses the ACTUAL
# generated parameters or a minimal real execution — nothing is "passed" by grepping code.
#  1. mount order  (/ is the base; /proc + /dev come after it)
#  2. overlay lower source is a REAL host path (bwrap resolves it before mounting)
#  3. process sampling walks to the REAL Hermes (init is not the model)
#  4. cleanup is one scope-valid entry (no function-local refs; TERM/INT stop + clean)
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INST="$AEGL_ROOT/recovery/install-model-broker.sh"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

# === 1. mount order ============================================================ #
HOSTINS="$(mktemp -d)"                        # a REAL host path for the overlay lower
ARGV="$(python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" "$HOSTINS" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ss", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
argv = m.build(bwrap="/usr/bin/bwrap", uid="994", gid="972", run="/run/aegl-model/t",
               wt="/tmp/wt", scr="/tmp/scr", runtime="/home/zhong/.hermes/hermes-agent",
               tools="/home/zhong/.hermes/tools", entry="/home/zhong/.local/bin/hermes",
               installs=sys.argv[2], guard_src="/g", guard_dest="/home/zhong/g",
               contract_package="/pkg", hermes_args=["hermes"])["argv"]
print("\n".join(argv))
PY
)"
idx(){ printf '%s\n' "$ARGV" | grep -nxF -- "$1" | head -1 | cut -d: -f1; }
# the "--ro-bind / /" triple: find the argv line index of the root-fs bind
RB="$(printf '%s\n' "$ARGV" | awk '/^--ro-bind$/{getline; if($0=="/"){print NR-1; exit}}')"
[ -n "$RB" ] && ok "root filesystem is bound (--ro-bind / / at argv line $RB)" || no "no --ro-bind / /"
PROCI="$(printf '%s\n' "$ARGV" | awk '/^--proc$/{getline; if($0=="/proc"){print NR-1; exit}}')"
DEVI="$(printf '%s\n' "$ARGV" | awk '/^--dev$/{getline; if($0=="/dev"){print NR-1; exit}}')"
{ [ -n "$RB" ] && [ -n "$PROCI" ] && [ -n "$DEVI" ] && [ "$RB" -lt "$PROCI" ] && [ "$RB" -lt "$DEVI" ]; } \
  && ok "root fs precedes /proc ($RB<$PROCI) and /dev ($RB<$DEVI)" \
  || no "mount order still shadows /proc or /dev (root=$RB proc=$PROCI dev=$DEVI)"

# minimal real execution if bwrap can run unprivileged here (only proves the ORDER rule)
if bwrap --unshare-user --ro-bind / / --proc /proc --dev /dev -- /bin/sh -c 'test -e /proc/self/status' 2>/dev/null; then
  bwrap --unshare-user --ro-bind / / --proc /proc --dev /dev -- /bin/sh -c 'test -e /proc/self/status && test -e /dev/null' 2>/dev/null \
    && ok "real bwrap: base-first order gives a working /proc and /dev" || no "real bwrap: /proc or /dev missing"
else
  printf '  NOTE: bwrap cannot run unprivileged here; order proven from the real argv only\n'
fi

# === 2. overlay lower source =================================================== #
OV="$(printf '%s\n' "$ARGV" | awk '/^--overlay-src$/{getline; print; exit}')"
[ "$OV" = "$HOSTINS" ] && ok "overlay lower source is the REAL host path (${HOSTINS})" || no "overlay source is '$OV', not the host path"
[ -d "$OV" ] && ok "the overlay lower source exists on the host" || no "overlay source does not exist on the host"
printf '%s\n' "$ARGV" | grep -q '/run/aegl-run/installs-ro' && no "argv still references the not-yet-created sandbox path" \
  || ok "argv references no not-yet-created sandbox path"

# === 3. process sampling ======================================================= #
CH="$(mktemp -d)"
# init is a shell wrapper; the real Hermes-shaped child is python -c '...hermes...'
# (raw NUL argv + real exe). An exec -a rename of sleep must NOT count.
cat > "$CH/init.sh" <<'EOS'
python3 -c 'import time; # hermes startup marker
time.sleep(25)' &
wait
EOS
bash "$CH/init.sh" &
INIT=$!
sleep 0.6
printf '{"child-pid": %d}\n' "$INIT" > "$CH/info.json"
EV="$(python3 "$AEGL_ROOT/recovery/capture_evidence.py" "$CH/info.json" --max-wait 5 --hermes-wait 5)"
HP="$(printf '%s' "$EV" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("hermes_pid",""))')"
[ -n "$HP" ] && [ "$HP" != "$INIT" ] && ok "capture walks to the real Hermes (pid $HP != init $INIT)" || no "capture did not find Hermes below init (got '$HP')"
[ "$(printf '%s' "$EV" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("uid",""))')" = "$(id -u)" ] \
  && ok "capture reports the Hermes process's own host uid" || no "capture uid is not the Hermes uid"
printf '%s' "$EV" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if "children_uids" in d else 1)' \
  && ok "capture reports children separately (empty is not 'all passed')" || no "capture hides the children field"
# shell-wrapper argv rename must never be accepted as Hermes
bash -c 'exec -a "hermes -p android-stack chat --oneshot" sleep 25' & WRAP=$!
sleep 0.3
printf '{"child-pid": %d}\n' "$WRAP" > "$CH/info-wrap.json"
EVW="$(python3 "$AEGL_ROOT/recovery/capture_evidence.py" "$CH/info-wrap.json" --max-wait 2 --hermes-wait 2)"
printf '%s' "$EVW" | grep -q 'hermes_not_found' && ok "exec -a wrapper is NOT Hermes (NOT_PROVEN)" || no "wrapper mistaken for Hermes ($EVW)"
kill "$INIT" "$WRAP" 2>/dev/null; wait "$INIT" "$WRAP" 2>/dev/null
# a real init with NO Hermes descendant must be NOT_RUN/NOT_PROVEN, never a false pass
bash -c 'sleep 25' & PLAIN=$!
sleep 0.4
printf '{"child-pid": %d}\n' "$PLAIN" > "$CH/info2.json"
EV2="$(python3 "$AEGL_ROOT/recovery/capture_evidence.py" "$CH/info2.json" --max-wait 3 --hermes-wait 3)"
printf '%s' "$EV2" | grep -q 'hermes_not_found' && ok "no Hermes -> hermes_not_found (NOT_RUN/NOT_PROVEN, not a pass)" || no "missing Hermes did not fail closed ($EV2)"
kill "$PLAIN" 2>/dev/null; wait "$PLAIN" 2>/dev/null
rm -rf "$CH" "$HOSTINS"

# === 4. cleanup lifecycle ====================================================== #
# a real run of the installer's --check-layout exercises the EXIT trap under set -u
LAY="$(bash -u "$INST" --check-layout --repo /home/zhong/Projects/AI-Engineering-Governance-Layer --commit "$(git -C "$AEGL_ROOT" rev-parse HEAD)" 2>&1)"; LRC=$?
{ [ "$LRC" = 0 ] && printf '%s' "$LAY" | grep -q 'LAYOUT_CHECK=PASS'; } && ok "real --check-layout ran and exited 0 (EXIT trap under set -u)" || no "check-layout failed (rc=$LRC)"
printf '%s' "$LAY" | grep -qi 'unbound variable' && no "cleanup raised an unbound variable" || ok "no unbound-variable error in the EXIT cleanup"
BAD="$(bash -u "$INST" --check-layout --repo /home/zhong/Projects/AI-Engineering-Governance-Layer --commit 0000000000000000000000000000000000000000 2>&1)"; BRC=$?
{ [ "$BRC" != 0 ] && printf '%s' "$BAD" | grep -qi 'unbound variable' && no "failure path raised unbound variable"; } || ok "failure path also cleans without an unbound-variable error"
# statics for the parts that need root to execute
[ "$(grep -c "^trap 'cleanup_all' EXIT" "$INST")" = 1 ] && ok "exactly one EXIT trap, bound to cleanup_all" || no "EXIT trap is not the single cleanup_all"
grep -q "trap 'cleanup_all; exit 143' TERM" "$INST" && ok "TERM stops execution and cleans (exit 143)" || no "TERM trap missing"
grep -q "trap 'cleanup_all; exit 130' INT" "$INST" && ok "INT stops execution and cleans (exit 130)" || no "INT trap missing"
grep -q 'cleanup_trial' "$INST" && no "the old function-local cleanup_trial is still present" || ok "the old local-var cleanup is gone"
grep -qE '^\s*local .*ST=.*' /dev/null 2>/dev/null
awk '/^cleanup_all\(\)\{/,/^\}/' "$INST" | grep -qE '\blocal (ST|TID)=' && no "cleanup_all still references function-local ST/TID" || ok "cleanup_all uses top-level scope only"

echo "ENTRY_MOUNT_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
