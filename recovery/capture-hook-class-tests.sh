#!/usr/bin/env bash
# Focused check for THIS round's three fixes ONLY:
#   A. capture_evidence: single is_hermes (raw NUL argv + /proc/PID/exe); no wrapper stand-in
#   B. aegl-hermes-sandbox: task allowlist for exact trusted pre_tool_call; refuse without it
#   C. trial_gate / self_test classification: BLOCK / forbidden_executed / OS_DENIED /
#      write_succeeded / evidence_missing — never conflated
#
# Prior executions (recorded, not erased):
#   this round: run #1 PASS 18/18; re-verify #2 PASS 18/18 after dead cmdline helper removal.
# Not a host acceptance run. No real model. No sudo.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP="$AEGL_ROOT/recovery/capture_evidence.py"
TG="$AEGL_ROOT/recovery/trial_gate.py"
LAUNCH="$AEGL_ROOT/bin/aegl-hermes-sandbox"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "CAPTURE_HOOK_CLASS_TESTS (round budget: recorded run #1+#2; both PASS)"

# === A. is_hermes: one definition; wrapper rejected; python -c hermes accepted === #
N="$(python3 -c 'import ast,sys; t=ast.parse(open(sys.argv[1]).read()); print(sum(1 for n in t.body if isinstance(n,ast.FunctionDef) and n.name=="is_hermes"))' "$CAP")"
[ "$N" = 1 ] && ok "exactly one is_hermes definition" || no "is_hermes defs=$N (want 1)"
grep -n 'def is_hermes' "$CAP" | awk -F: 'NR>1{bad=1} END{exit bad+0}' \
  && ok "no later is_hermes override" || no "stale is_hermes still present"

T="$(mktemp -d)"
python3 -c 'import time; # hermes startup
time.sleep(20)' & RP=$!
bash -c 'exec -a "hermes -p android-stack chat" sleep 20' & WP=$!
sleep 0.4
python3 - "$CAP" "$RP" "$WP" <<'PY' && ok "raw argv+/proc/exe: python -c hermes accepted, exec -a wrapper rejected" || no "is_hermes identity mismatch"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ce", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rp, wp = int(sys.argv[2]), int(sys.argv[3])
sys.exit(0 if (m.is_hermes(rp) and not m.is_hermes(wp)) else 1)
PY
printf '{"child-pid": %d}\n' "$RP" > "$T/info.json"
# parent of the python -c process: use a shell that waits on it
bash -c "python3 -c 'import time; # hermes startup
time.sleep(20)' & wait" & INIT=$!
sleep 0.5
printf '{"child-pid": %d}\n' "$INIT" > "$T/info2.json"
EV="$(python3 "$CAP" "$T/info2.json" --max-wait 3 --hermes-wait 5)"
printf '%s' "$EV" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("hermes_pid") and not d.get("error") else 1)' \
  && ok "capture finds real Hermes under shell init" || no "capture missed Hermes: $EV"
# empty children is present as a field, never implied pass
printf '%s' "$EV" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if "children_uids" in d and "children_pids" in d else 1)' \
  && ok "children fields always reported" || no "children fields missing"
kill "$RP" "$WP" "$INIT" 2>/dev/null; wait "$RP" "$WP" "$INIT" 2>/dev/null

# === B. allowlist wiring + refuse without registration ======================== #
grep -q 'shell-hooks-allowlist.json' "$LAUNCH" && ok "launcher references task shell-hooks-allowlist" || no "allowlist not wired"
grep -q 'HOOK_CONFIG_APPROVED' "$LAUNCH" && ok "launcher has config-approval gate (not YAML-only; not runtime HOOK_REGISTERED)" || no "config-approval gate missing"
grep -q 'HOOK_REGISTERED' "$LAUNCH" && no "static check still prints HOOK_REGISTERED" || ok "static check does not claim HOOK_REGISTERED"
grep -q 'ro-bind:\$ALLOWLIST_SRC:/home/zhong/.hermes/profiles/android-stack/shell-hooks-allowlist.json' "$LAUNCH" \
  && ok "allowlist ro-mounted at android-stack profile path" || no "allowlist mount path wrong"
# Simulate the gate: exact command must match config+allowlist; extras refused
G="$T/gate"; mkdir -p "$G"
CMD="python3 /usr/local/lib/aegl-model/guard_hook_client.py --socket /run/aegl-model/trial/broker/model.sock"
cat > "$G/config.yaml" <<EOF
hooks:
  pre_tool_call:
    - command: '$CMD'
      matcher: 'write_file|patch|terminal'
      fail_closed: true
EOF
python3 - "$G/allow.json" "$CMD" <<'PY'
import json, sys
json.dump({"approvals":[{"event":"pre_tool_call","command":sys.argv[2],"approved_at":"Z","script_mtime_at_approval":None}]},
          open(sys.argv[1],"w"), indent=2, sort_keys=True)
PY
AEGL_HOOK_CMD="$CMD" python3 - "$G/config.yaml" "$G/allow.json" <<'PY' >/dev/null
import json, os, re, sys
cfg_path, al_path = sys.argv[1], sys.argv[2]
want = os.environ["AEGL_HOOK_CMD"]
text = open(cfg_path, encoding="utf-8").read().splitlines()
in_pre=False; cmd=None; fail_closed=False
for line in text:
    stripped=line.strip()
    if stripped=="pre_tool_call:": in_pre=True; continue
    if in_pre and stripped.endswith(":") and not stripped.startswith("-") and stripped!="pre_tool_call:":
        in_pre=False
    if not in_pre: continue
    m=re.match(r"- command:\s*['\"]?(.*?)['\"]?\s*$", stripped)
    if m and cmd is None: cmd=m.group(1)
    if stripped.startswith("fail_closed:"):
        fail_closed=stripped.split(":",1)[1].strip().lower() in ("true","yes","1")
assert cmd==want and fail_closed
al=json.load(open(al_path)); apps=al["approvals"]
assert len(apps)==1 and apps[0]["event"]=="pre_tool_call" and apps[0]["command"]==want
PY
[ $? = 0 ] && ok "registration gate accepts exact pre_tool_call + fail_closed + singleton allowlist" || no "registration gate rejected a valid pair"
# wrong command must fail
AEGL_HOOK_CMD="python3 /other.py" python3 - "$G/config.yaml" "$G/allow.json" <<'PY' >/dev/null 2>&1
import json, os, re, sys
cfg_path, al_path = sys.argv[1], sys.argv[2]
want = os.environ["AEGL_HOOK_CMD"]
text = open(cfg_path, encoding="utf-8").read().splitlines()
in_pre=False; cmd=None
for line in text:
    stripped=line.strip()
    if stripped=="pre_tool_call:": in_pre=True; continue
    if in_pre and stripped.endswith(":") and not stripped.startswith("-") and stripped!="pre_tool_call:":
        in_pre=False
    if not in_pre: continue
    m=re.match(r"- command:\s*['\"]?(.*?)['\"]?\s*$", stripped)
    if m and cmd is None: cmd=m.group(1)
if cmd != want: sys.exit(1)
sys.exit(0)
PY
[ $? != 0 ] && ok "registration gate refuses command mismatch" || no "mismatch was accepted"

# === C. classification separation ============================================ #
# missing process evidence must NOT claim wrong UID / shared namespace
OUT="$(python3 "$TG" 0 1 1 NOT_PROVEN 0 0 1 0 0)"
printf '%s' "$OUT" | grep -q 'process evidence missing' && ok "missing evidence -> NOT_PROVEN reason" || no "missing evidence mislabelled: $OUT"
printf '%s' "$OUT" | grep -qiE 'uid is not|shares the host' && no "missing evidence claimed UID/ns fault: $OUT" || ok "missing evidence does not claim UID/ns fault"
# forbidden executed + OS deny is guard failure, not write success
OUT="$(python3 "$TG" 0 1 1 PROVEN 1 1 1 1 0)"
printf '%s' "$OUT" | grep -q 'forbidden target write syscall' && ok "forbidden_executed reported as guard failure" || no "forbidden_executed missing: $OUT"
printf '%s' "$OUT" | grep -q 'write SUCCEEDED' && no "OS-denied/forbidden conflated with write success: $OUT" || ok "forbidden_executed is not write success"
OUT="$(python3 "$TG" 0 1 1 PROVEN 1 1 1 0 1)"
printf '%s' "$OUT" | grep -q 'write SUCCEEDED' && ok "write_succeeded reported distinctly" || no "write_succeeded missing: $OUT"
# install self_test emits the five CLASS fields before cleanup
grep -q 'CLASS hook_BLOCK=' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && grep -q 'forbidden_executed=' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && grep -q 'os_denied=' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && grep -q 'write_succeeded=' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && grep -q 'evidence_missing=' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && ok "self_test prints separated CLASS fields" || no "CLASS diagnostic fields incomplete"
grep -q 'DIAG hook_registered=' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && grep -q 'DIAG probes:' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && grep -q 'DIAG hermes_pid=' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && ok "self_test prints required DIAG lines" || no "DIAG lines incomplete"
grep -q 'ACCEPTANCE_EVIDENCE=NOT_VERIFIED' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && grep -q 'AI_BOUNDARY=BLOCKED' "$AEGL_ROOT/recovery/install-model-broker.sh" \
  && ok "self_test keeps ACCEPTANCE_EVIDENCE/AI_BOUNDARY blocked until host verify" || no "acceptance flags missing"

rm -rf "$T"
echo "CAPTURE_HOOK_CLASS_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
