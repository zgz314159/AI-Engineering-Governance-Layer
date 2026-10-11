#!/usr/bin/env bash
# Focused check for the NEW trusted-guard-capture interface ONLY. It proves interface-local
# behaviour; it is NOT real isolation acceptance.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER="$AEGL_ROOT/recovery/model_broker.py"
CLIENT="$AEGL_ROOT/recovery/guard_hook_client.py"
CAP="$AEGL_ROOT/recovery/guard_capture.py"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; SOCK="$T/broker.sock"; EVID="$T/evidence"; MARK="$T/guard-called"
mkdir -p "$EVID"; chmod 700 "$EVID"
cat > "$T/stub_guard.py" <<PY
import json, sys
payload = json.loads(sys.stdin.read() or "{}")
open("$MARK", "a", encoding="utf-8").write("called\n")   # side effect: real execution proof
if "forbidden" in json.dumps(payload):
    sys.stdout.write(json.dumps({"action": "block", "message": "stub-guard-block"}))
    sys.exit(2)
sys.exit(0)
PY
: > "$T/cred.env"; echo "COMMANDCODE_API_KEY=dummy" > "$T/cred.env"

start_broker(){ # $1 = extra env name/value pairs
  env "$@" AEGL_TASK=trial-1 AEGL_GUARD_EVIDENCE="$EVID" AEGL_GUARD_AI_UID=994 \
    python3 "$BROKER" serve --socket "$SOCK" --upstream "http://127.0.0.1:1/provider/v1" \
      --credential-file "$T/cred.env" >"$T/broker.out" 2>"$T/broker.err" &
  BP=$!
  for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
}
kill_broker(){ kill "$BP" 2>/dev/null; wait "$BP" 2>/dev/null; rm -f "$SOCK"; }

ask(){ python3 "$CLIENT" --socket "$SOCK" --timeout 10 <<EOF
$1
EOF
}

# === 1. the CONTROLLER runs the guard and returns its raw stdout + exit code ====== #
start_broker AEGL_GUARD_PATH="$T/stub_guard.py"
[ -S "$SOCK" ] && ok "controller socket is up" || no "controller socket missing"
OUT="$(ask '{"tool_name":"terminal","tool_call_id":"tc-1","tool_input":{"command":"echo forbidden > x"}}')"; RC=$?
[ "$RC" = 2 ] && ok "block verdict reproduced: exit code 2" || no "expected exit 2, got $RC"
case "$OUT" in *stub-guard-block*) ok "the guard's RAW stdout was returned verbatim";; *) no "raw stdout missing: $OUT";; esac
[ -s "$MARK" ] && ok "the controller really EXECUTED the guard (side effect observed)" || no "the guard was never executed"
grep -q '"task": "trial-1"' "$EVID/guard-capture.jsonl" 2>/dev/null && grep -q '"tool_call_id": "tc-1"' "$EVID/guard-capture.jsonl" \
  && grep -q '"operation": "terminal"' "$EVID/guard-capture.jsonl" \
  && ok "evidence ties task + real tool_call_id + operation to the call" || no "evidence association missing"
grep -q '"rc": 2' "$EVID/guard-capture.jsonl" && ok "evidence records the raw return code" || no "evidence rc missing"

OUT="$(ask '{"tool_name":"write_file","tool_call_id":"tc-2","tool_input":{"path":"/tmp/ok"}}')"; RC=$?
[ "$RC" = 0 ] && ok "allow verdict reproduced: exit code 0" || no "expected exit 0, got $RC"
kill_broker

# === 2. evidence dir owned by the AI identity is REFUSED ========================== #
OUT="$(python3 "$CAP" evaluate --guard "$T/stub_guard.py" --evidence-dir "$EVID" \
       --ai-uid "$(id -u)" --task t --tool-call-id c --operation terminal <<< '{}' 2>/dev/null)"
case "$OUT" in *refused_untrusted_dir*) ok "an AI-writable evidence dir is refused (no fake evidence)";; *) no "AI-writable dir accepted: $OUT";; esac

# === 3. fail closed ============================================================== #
python3 "$CLIENT" --socket "$T/does-not-exist.sock" --timeout 3 <<< '{}' >"$T/c1" 2>/dev/null; RC=$?
{ [ "$RC" = 2 ] && grep -q '"action": "block"' "$T/c1" && grep -qi unreachable "$T/c1"; } \
  && ok "no controller -> explicit BLOCK (fail closed)" || no "client did not fail closed (rc=$RC)"
start_broker
OUT="$(ask '{"tool_name":"terminal","tool_call_id":"tc-3"}')"; RC=$?
{ [ "$RC" = 2 ]; } && ok "no guard configured -> BLOCK (never a silent allow)" || no "no-guard case did not block (rc=$RC)"
kill_broker

rm -rf "$T"
echo "GUARD_CAPTURE_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
