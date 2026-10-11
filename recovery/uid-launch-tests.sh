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

echo "UID_LAUNCH_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
