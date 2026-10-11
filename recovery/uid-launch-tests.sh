#!/usr/bin/env bash
# uid-launch-tests.sh — targeted tests for this round (no root).
#
# Covers the one part that can be exercised without root: the trusted component parses
# the EXISTING credential file as DATA ONLY — a shell payload in that (user-writable) file
# must never execute. The independent-UID runtime/socket checks need root and are NOT_RUN.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
BROKER="$AEGL_ROOT/recovery/model_broker.py"

ST="$(mktemp -d /var/tmp/aegl-uid-launch-XXXXXX)" || { echo mktemp failed; exit 2; }
PASS=0; FAIL=0; PIDS=()
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

UP_PORT=18993
cat > "$ST/up.py" <<'PY'
import http.server, sys, json
SEEN=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(SEEN,"w").write(self.headers.get("Authorization",""))
        b=b'{"ok":1}'; self.send_response(200); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    do_POST=do_GET
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
python3 "$ST/up.py" "$UP_PORT" "$ST/seen" & PIDS+=($!); sleep 0.5

# a user-writable credential file with a valid key AND shell payloads
cat > "$ST/cred.env" <<EOF
# existing credential source (user-writable)
COMMANDCODE_API_KEY=REAL-KEY-XYZ
EVIL1=\$(touch $ST/PWNED_DOLLAR)
EVIL2=\`touch $ST/PWNED_BACKTICK\`
export COMMANDCODE_EXTRA=\$(touch $ST/PWNED_EXPORT)
EOF
grep -q 'touch' "$ST/cred.env" || no "payload not written to the fixture"

# no env var present: the broker must read the file as DATA
env -u COMMANDCODE_API_KEY python3 "$BROKER" serve --socket "$ST/m.sock" \
  --upstream "http://127.0.0.1:$UP_PORT" --credential-source "$ST/cred.env" >"$ST/b.log" 2>&1 &
PIDS+=($!); sleep 0.5
[ -S "$ST/m.sock" ] && ok "broker reads the credential from the source file as data" || no "broker did not start"

python3 - "$ST/m.sock" <<'PY' >/dev/null 2>&1
import socket, sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(b"GET /v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
while s.recv(4096): pass
PY
sleep 0.2
grep -q 'REAL-KEY-XYZ' "$ST/seen" 2>/dev/null && ok "the literal key was read and injected" || no "key not injected"
{ [ ! -e "$ST/PWNED_DOLLAR" ] && [ ! -e "$ST/PWNED_BACKTICK" ] && [ ! -e "$ST/PWNED_EXPORT" ]; } \
  && ok "shell payloads in the credential file were NOT executed" \
  || no "credential file was executed (payload side effects present)"

# missing key -> the broker refuses (no fallback, no new key)
env -u COMMANDCODE_API_KEY python3 "$BROKER" serve --socket "$ST/n.sock" \
  --upstream "http://127.0.0.1:$UP_PORT" --credential-source "$ST/empty.env" >"$ST/n.log" 2>&1; rc=$?
{ [ "$rc" != 0 ] && [ ! -S "$ST/n.sock" ]; } && ok "broker refuses when the source has no key" || no "broker started without a key"

# --- D. trial gate fails closed ---------------------------------------------- #
TG="$AEGL_ROOT/recovery/trial_gate.py"
gv(){ python3 "$TG" "$@" | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])'; }
[ "$(gv 1 1 1 1 1 1 0)" = NOT_RUN ] && ok "launch failure => NOT_RUN" || no "launch-failure gate"
[ "$(gv 0 0 1 1 1 1 0)" = FAIL ] && ok "missing RESULT => FAIL" || no "missing-RESULT gate"
[ "$(gv 0 1 0 1 1 1 0)" = FAIL ] && ok "missing identity/namespace evidence => FAIL" || no "missing-evidence gate"
[ "$(gv 0 1 1 0 1 1 0)" = FAIL ] && ok "uid mismatch => FAIL" || no "uid gate"
[ "$(gv 0 1 1 1 0 1 0)" = FAIL ] && ok "shared pid namespace => FAIL" || no "ns gate"
[ "$(gv 0 1 1 1 1 0 0)" = FAIL ] && ok "protected write not attempted => FAIL" || no "write-attempt gate"
[ "$(gv 0 1 1 1 1 1 1)" = FAIL ] && ok "protected write succeeded => FAIL" || no "breach gate"
[ "$(gv 0 1 1 1 1 1 0)" = PASS ] && ok "all evidence good => PASS" || no "pass gate"

# --- E. entry fix checks ------------------------------------------------------ #
# E1. flat install layout carries every referenced module (simulated, no root)
FLAT="$ST/flat"; mkdir -p "$FLAT"
ALL_FILES=(bin/aegl-model-broker bin/aegl-hermes-sandbox recovery/model_broker.py recovery/loopback_shim.py recovery/exec_spec.py recovery/trial_gate.py recovery/sandbox_spec.py recovery/capture_evidence.py)
for f in "${ALL_FILES[@]}"; do
  if grep -q "$(basename "$f")" <(grep -m1 '^FILES=' "$AEGL_ROOT/recovery/install-model-broker.sh"); then
    [ -f "$AEGL_ROOT/$f" ] && cp "$AEGL_ROOT/$f" "$FLAT/$(basename "$f")" || no "worktree file missing: $f"
  else
    no "FILES omits $(basename "$f")"
  fi
done
fm=0; for m in aegl-model-broker aegl-hermes-sandbox model_broker.py loopback_shim.py exec_spec.py sandbox_spec.py capture_evidence.py trial_gate.py; do [ -s "$FLAT/$m" ] || { fm=1; no "flat layout missing $m"; }; done
[ "$fm" = 0 ] && ok "flat install layout carries every referenced module"
grep -q 'for f in "${FILES\[@\]}"' "$AEGL_ROOT/recovery/install-model-broker.sh" && ok "install loop iterates all FILES" || no "install loop does not iterate FILES"

# E2. generated bwrap argv includes the writable task mounts
SPEC_OUT="$(python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" <<'PY'
import sys, importlib.util, json
p = sys.argv[1]
spec = importlib.util.spec_from_file_location("ss", p); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
argv = m.build(bwrap="bwrap", uid="994", gid="972", run="/run/a", wt="/wt", scr="/scr",
               runtime="/r", tools="/t", entry="/e", installs="/i", guard_src="/g",
               guard_dest="/home/zhong/g", contract_package="/pkg", info_fd="", hermes_args=["hermes"])["argv"]
def binds(src):
    return any(argv[i] == "--bind" and argv[i+1] == src and argv[i+2] == src for i in range(len(argv)-2))
print("OK" if binds("/wt") and binds("/scr") else "MISSING")
PY
)"
[ "$SPEC_OUT" = OK ] && ok "generated argv has writable --bind for worktree and scratch" || no "argv missing writable task mounts ($SPEC_OUT)"

# E3. live-process evidence capture (uid/namespace while alive)
sleep 30 & SL=$!
echo "{\"child-pid\": $SL}" > "$ST/info.json"
ev="$(python3 "$AEGL_ROOT/recovery/capture_evidence.py" "$ST/info.json" --max-wait 5)"
if python3 -c 'import json,sys;d=json.loads(sys.argv[1]); assert d.get("uid")==sys.argv[2], d; assert d.get("alive") is True, d; assert d.get("ns"), d' "$ev" "$(id -u)" 2>/dev/null; then
  ok "captured the live child's uid + pid namespace"
else
  no "live evidence capture failed ($ev)"
fi
kill "$SL" 2>/dev/null
miss="$(python3 "$AEGL_ROOT/recovery/capture_evidence.py" "$ST/absent.json" --max-wait 1)"
printf '%s' "$miss" | grep -q 'no_child_pid' && ok "capture fails closed when the info fd is absent" || no "missing info not reported ($miss)"

# E4. required runtime paths referenced by the entry (host accessibility)
RP_OK=1
for p in /home/zhong/.local/bin/hermes /home/zhong/.hermes/hermes-agent /home/zhong/.hermes/tools \
         /home/zhong/.hermes/profiles/android-stack/config.yaml "$AEGL_ROOT/recovery/loopback_shim.py"; do
  [ -e "$p" ] || { RP_OK=0; no "referenced runtime path missing: $p"; }
done
grep -q '^hooks:' /home/zhong/.hermes/profiles/android-stack/config.yaml && ok "android-stack profile carries the guard hooks" || { RP_OK=0; no "profile has no hooks block"; }
GD="$(grep -oE '/[^ ]*contract_guard\.py' /home/zhong/.hermes/profiles/android-stack/config.yaml | head -1)"; GD="${GD%/*}"
{ [ -n "$GD" ] && [ -d "$GD" ]; } && ok "contract-guard source dir present (${GD})" || { RP_OK=0; no "guard source dir missing"; }
[ "$RP_OK" = 1 ] && ok "all entry-referenced runtime paths resolve" || no "some referenced paths missing"

# --- F. contract wiring (focused check) --------------------------------------- #
FC="$ST/fc"; WT2="$FC/Google-Android-Agent-Development-Stack/trial-wt"; PKG="$ST/fc-contract"
mkdir -p "$WT2" "$FC/scratch"; echo TOK > "$WT2/INPUT.txt"
if python3 "$AEGL_ROOT/recovery/make_trial_contract.py" --projects-root "$FC" \
     --allowed "Google-Android-Agent-Development-Stack/trial-wt/" \
     --forbidden "Google-Android-Agent-Development-Stack/reports/,KeepLab-Relay/" \
     --read-first "Google-Android-Agent-Development-Stack/trial-wt/INPUT.txt" --out "$PKG" >/dev/null 2>&1; then
  ok "focused: trial contract compiles READY via the existing compiler"
else
  no "focused: trial contract did not compile"
fi
GUARD=/home/zhong/Projects/Google-Android-Agent-Development-Stack/orchestration/hermes/evaluation_adapter/contract_guard.py
HERMES_CONTRACT_PACKAGE="$PKG" bash -c "printf '{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$WT2/out.txt\"},\"cwd\":\"$WT2\"}' | python3 '$GUARD' >/dev/null 2>&1"
[ $? -eq 0 ] && ok "focused: real guard ALLOWS the authorized task output" || no "focused: guard did not allow the authorized output"
HERMES_CONTRACT_PACKAGE="$PKG" bash -c "printf '{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"/home/zhong/Projects/KeepLab-Relay/x\"},\"cwd\":\"$WT2\"}' | python3 '$GUARD' >/dev/null 2>&1"
[ $? -eq 2 ] && ok "focused: real guard BLOCKS an out-of-bound target" || no "focused: guard did not block the out-of-bound target"
SA="$(python3 - "$AEGL_ROOT/recovery/sandbox_spec.py" "$PKG" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("ss", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
argv = m.build(bwrap="bwrap", uid="994", gid="972", run="/run/a", wt="/wt", scr="/scr",
               runtime="/r", tools="/t", entry="/e", installs="/i", guard_src="/g",
               guard_dest="/home/zhong/g", contract_package=sys.argv[2], info_fd="", hermes_args=["hermes"])["argv"]
has_bind = any(argv[i] == "--ro-bind" and argv[i+1] == sys.argv[2] and argv[i+2] == sys.argv[2] for i in range(len(argv)-2))
has_env = any(argv[i] == "--setenv" and argv[i+1] == "HERMES_CONTRACT_PACKAGE" and argv[i+2] == sys.argv[2] for i in range(len(argv)-2))
print("OK" if has_bind and has_env else "MISSING")
PY
)"
[ "$SA" = OK ] && ok "focused: argv has the read-only contract mount + HERMES_CONTRACT_PACKAGE env" || no "focused: argv missing contract wiring ($SA)"

echo "UID_LAUNCH_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
