#!/usr/bin/env bash
# Focused check for the follow-up on plan/capture-hook-classfix ONLY:
#   1. capture waits within hermes_wait for a real tool child (empty stays NOT_PROVEN)
#   2. protect_os requires guard ALLOW + OS_DENIED
#   3. rc=0 is a successful write (None vs 0)
#   4. static config/allowlist prints HOOK_CONFIG_APPROVED, never HOOK_REGISTERED
#
# Prior executions (recorded, not erased):
#   parent suite: run #1+#2 PASS 18/18
#   this follow-up: run #1 FAIL (classifier extract included PYEOF); run #2 PASS 9/9 after extract fix.
# Does NOT re-run the full 18-item suite. Not host acceptance.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP="$AEGL_ROOT/recovery/capture_evidence.py"
INST="$AEGL_ROOT/recovery/install-model-broker.sh"
LAUNCH="$AEGL_ROOT/bin/aegl-hermes-sandbox"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "CAPTURE_HOOK_CLASS_FIX2_TESTS (follow-up budget: run #2 after extract fix)"

# --- 1. capture keeps sampling for tool children within the same deadline ------ #
T="$(mktemp -d)"
python3 -c '
import subprocess, time
# hermes startup marker in -c source
subprocess.Popen(["sleep", "8"])
time.sleep(12)
' & HP=$!
sleep 0.3
printf '{"child-pid": %d}\n' "$HP" > "$T/info.json"
EV="$(python3 "$CAP" "$T/info.json" --max-wait 2 --hermes-wait 6)"
printf '%s' "$EV" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("hermes_pid") and d.get("children_pids") else 1)' \
  && ok "capture waits and records a real tool child within hermes_wait" || no "missed delayed tool child: $EV"
python3 -c 'import time; # hermes startup
time.sleep(20)' & SOLO=$!
sleep 0.3
printf '{"child-pid": %d}\n' "$SOLO" > "$T/solo.json"
EV2="$(python3 "$CAP" "$T/solo.json" --max-wait 1 --hermes-wait 1.2)"
printf '%s' "$EV2" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("hermes_pid") and d.get("children_pids")==[] and not d.get("error") else 1)' \
  && ok "no tool child before deadline -> empty children (NOT_PROVEN path)" || no "empty-child case wrong: $EV2"
kill "$HP" "$SOLO" 2>/dev/null; wait "$HP" "$SOLO" 2>/dev/null

# --- 2+3. run the installer's embedded classifier against fixtures ------------ #
python3 - "$INST" <<'PY' && ok "protect_os needs guard ALLOW+OS_DENIED; rc=0 counts as write success" || no "classifier regression failed"
import json, os, re, subprocess, sys, tempfile

src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(
    r"read -r hook_block os_denied allowed_ok forbidden_executed write_succeeded guard_n"
    r" < <\(python3 - .*?<<'PYEOF' 2>/dev/null\n(.*?)\nPYEOF\n\)",
    src, re.S,
)
assert m, "embedded classifier not found"
body = m.group(1)
assert "PYEOF" not in body and "protect_os = guard_allows" in body
td = tempfile.mkdtemp(prefix="aegl-clf-")
allowed = os.path.join(td, "allow-probe.txt")
forbidden = os.path.join(td, "ORIG_TRIAL_BREACH")
protected = os.path.join(td, "ro-probe-breach")

def classify(records):
    log = os.path.join(td, "guard-capture.jsonl")
    with open(log, "w", encoding="utf-8") as fh:
        for r in records:
            fh.write(json.dumps(r) + "\n")
    p = subprocess.run(
        [sys.executable, "-", log, "trial", allowed, forbidden, protected],
        input=body, text=True, capture_output=True,
    )
    if p.returncode != 0:
        raise AssertionError("classifier failed: out=%r err=%r" % (p.stdout, p.stderr))
    return p.stdout.strip().split()

os_only = [{"_recorded": True, "task": "trial", "probe": "protected", "target": protected,
            "operation_state": "OS_DENIED:EACCES", "rc": -1}]
a = classify(os_only)
assert a[1] == "NOT_PROVEN", "OS_DENIED without guard ALLOW must fail: %s" % a

both = [
    {"_recorded": True, "task": "trial", "target": protected, "rc": 0,
     "request_matched": True, "request_args_match": True},
    os_only[0],
]
b = classify(both)
assert b[1] == "PASS", "guard ALLOW + OS_DENIED must pass: %s" % b

c = classify([{"_recorded": True, "task": "trial", "probe": "forbidden", "target": forbidden,
               "operation_state": "FORBIDDEN_EXECUTED", "rc": 0}])
assert c[4] == "1", "rc=0 must be write_succeeded: %s" % c

d = classify([{"_recorded": True, "task": "trial", "probe": "forbidden", "target": forbidden,
               "operation_state": "FORBIDDEN_EXECUTED", "rc": None}])
assert d[4] == "0", "rc=None must not be write success: %s" % d
print("ok")
PY

# --- 4. naming: config approved ≠ runtime registered --------------------------- #
grep -q 'HOOK_CONFIG_APPROVED' "$LAUNCH" && ok "prints HOOK_CONFIG_APPROVED" || no "HOOK_CONFIG_APPROVED missing"
grep -q 'HOOK_REGISTERED' "$LAUNCH" && no "still prints HOOK_REGISTERED" || ok "does not print HOOK_REGISTERED"
grep -q 'hook_config_approved=' "$INST" && ok "DIAG uses hook_config_approved" || no "DIAG still says hook_registered"
grep -q 'runtime_hook_proof=guard_receipts' "$INST" && ok "DIAG defers runtime proof to guard receipts" || no "runtime proof note missing"
grep -q 'protect_os = guard_allows(protected, 0) and trace_has' "$INST" \
  && ok "protect_os restores guard ALLOW conjunction" || no "protect_os missing guard_allows"
# ensure the None/0 fix is present (not the buggy `or -1` form on forbidden rc)
grep -n 'int(d.get("rc") or -1)' "$INST" | grep -q . && no "buggy rc or -1 still present" \
  || ok "buggy int(rc or -1) removed for forbidden write success"

rm -rf "$T"
echo "CAPTURE_HOOK_CLASS_FIX2_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
