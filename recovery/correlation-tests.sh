#!/usr/bin/env bash
# Focused check for the TWO new junctions only (strict request correlation; separate
# guard/strace correlation). Local behaviour only — NOT host acceptance.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER="$AEGL_ROOT/recovery/model_broker.py"
CLIENT="$AEGL_ROOT/recovery/guard_hook_client.py"
TRACE="$AEGL_ROOT/recovery/trace_capture.py"
INST="$AEGL_ROOT/recovery/install-model-broker.sh"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; SOCK="$T/b.sock"; PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
ALLOWED_CMD="echo ok > '$T/wt/allow-probe.txt'"
mkdir -p "$T/wt/ro-probe"

cat > "$T/guard.py" <<'EOS'
import json, sys
p = json.loads(sys.stdin.read() or "{}")
cmd = (p.get("tool_input") or {}).get("command", "")
if "forbidden" in cmd:
    sys.stdout.write(json.dumps({"action": "block", "message": "stub-guard-block"}))
    sys.exit(2)
sys.exit(0)
EOS
cat > "$T/up_json.py" <<EOS
import http.server, json, sys
ARGS = json.dumps({"command": """$ALLOWED_CMD"""})
BODY = json.dumps({"choices": [{"message": {"tool_calls": [
    {"id": "call_1", "function": {"name": "terminal", "arguments": ARGS}}]}}]}).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(200); self.send_header("Content-Length", str(len(BODY))); self.end_headers(); self.wfile.write(BODY)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOS
cat > "$T/up_sse.py" <<EOS
import http.server, json, sys
FRAG = json.dumps({"command": """$ALLOWED_CMD"""})
CH = []
for i, part in enumerate([FRAG[:20], FRAG[20:]]):
    piece = {"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": part}}]}}
    if i == 0:
        piece["delta"]["tool_calls"][0]["id"] = "call_9"
        piece["delta"]["tool_calls"][0]["function"]["name"] = "terminal"
    CH.append(("data: " + json.dumps({"choices": [piece]}) + "\\n\\n").encode())
CH.append(b"data: [DONE]\\n\\n")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for c in CH: self.wfile.write(c)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOS
: > "$T/cred.env"; echo "COMMANDCODE_API_KEY=dummy" > "$T/cred.env"

start(){ python3 "$1" "$PORT" & UPID=$!; sleep 0.4
  AEGL_GUARD_PATH="$T/guard.py" AEGL_GUARD_RUNNER="$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1:]))' /usr/bin/env)" \
  AEGL_TASK=trial AEGL_GUARD_AI_UID=994 AEGL_GUARD_AI_GID=994 \
    python3 "$BROKER" serve --socket "$SOCK" --upstream "http://127.0.0.1:$PORT/provider/v1" --credential-file "$T/cred.env" >"$T/b.log" 2>"$T/b.err" & BID=$!
  for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done; }
stop(){ kill "$BID" "$UPID" 2>/dev/null; wait "$BID" "$UPID" 2>/dev/null; rm -f "$SOCK"; }
cleanup(){ kill "${BID:-}" "${UPID:-}" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

ask(){ python3 "$CLIENT" --socket "$SOCK" --timeout 10 <<EOF
$1
EOF
}
model(){ python3 - "$SOCK" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1])
body = b'{"stream": false}'
s.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
while s.recv(65536): pass
PY
}

# === 1. strict correlation (JSON response) ====================================== #
start "$T/up_json.py"; model
ask "{\"tool_name\":\"terminal\",\"tool_call_id\":\"call_1\",\"tool_input\":{\"command\":\"$ALLOWED_CMD\"}}" >"$T/ok.out" 2>/dev/null; RC=$?
{ [ "$RC" = 0 ]; } && ok "id+name+full args match -> tool allowed" || no "matching request was refused (rc=$RC)"
ask '{"tool_name":"terminal","tool_call_id":"call_1","tool_input":{"command":"echo evil > /etc/other"}}' >"$T/mis.out" 2>/dev/null; RC=$?
{ [ "$RC" = 2 ] && grep -q '"action": "block"' "$T/mis.out"; } && ok "argument mismatch -> REFUSED (tool cannot run)" || no "mismatch not refused (rc=$RC)"
ask '{"tool_name":"terminal","tool_call_id":"call_zzz","tool_input":{"command":"echo x"}}' >"$T/unk.out" 2>/dev/null; RC=$?
[ "$RC" = 2 ] && ok "unknown tool_call_id -> REFUSED" || no "unknown id not refused (rc=$RC)"
ask "{\"tool_name\":\"write_file\",\"tool_call_id\":\"call_1\",\"tool_input\":{\"command\":\"$ALLOWED_CMD\"}}" >"$T/nm.out" 2>/dev/null; RC=$?
[ "$RC" = 2 ] && ok "tool NAME mismatch -> REFUSED" || no "name mismatch not refused (rc=$RC)"
stop

# === 2. SSE fragments assembled by index ======================================== #
start "$T/up_sse.py"; model
ask "{\"tool_name\":\"terminal\",\"tool_call_id\":\"call_9\",\"tool_input\":{\"command\":\"$ALLOWED_CMD\"}}" >"$T/sse.out" 2>/dev/null; RC=$?
{ [ "$RC" = 0 ]; } && ok "SSE fragments assembled by choice/tool index -> matched" || no "SSE assembly failed (rc=$RC)"
stop

# === 3. trace parser: exact target, write-intent, full detail =================== #
cat > "$T/tr.log" <<EOF
12345 openat(AT_FDCWD, "$T/wt/allow-probe.txt", O_WRONLY|O_CREAT|O_TRUNC, 0666) = 7
12345 openat(AT_FDCWD, "$T/wt/ro-probe/breach", O_WRONLY|O_CREAT, 0666) = -1 EACCES (Permission denied)
12345 openat(AT_FDCWD, "$T/wt/allow-probe.txt", O_RDONLY) = 8
12345 openat(AT_FDCWD, "$T/wt/allow-probe.txt.bak", O_WRONLY|O_CREAT, 0666) = 9
EOF
EV="$T/ev"; mkdir -p "$EV"; chmod 700 "$EV"
python3 "$TRACE" parse --log "$T/tr.log" --task trial --allowed "$T/wt/allow-probe.txt" \
  --forbidden "$T/off/ORIG" --protected "$T/wt/ro-probe/breach" --evidence-dir "$EV" --ai-uid 994 --ai-gid 994 >/dev/null
N="$(grep -c '"probe"' "$EV/guard-capture.jsonl")"
[ "$N" = 2 ] && ok "exactly two probe records (read-only open and .bak excluded)" || no "unexpected record count: $N"
grep -q '"operation_state": "WRITE_OK"' "$EV/guard-capture.jsonl" && ok "allowed write captured (WRITE_OK)" || no "allowed write missing"
grep -q 'OS_DENIED:EACCES' "$EV/guard-capture.jsonl" && ok "protected denial captured with its errno" || no "protected denial missing"
grep -q '"pid": 12345' "$EV/guard-capture.jsonl" && ok "record carries the real pid" || no "pid missing"
grep -q 'allow-probe.txt.bak' "$EV/guard-capture.jsonl" && no "a prefix path leaked in" || ok "EXACT target matching (no prefix path recorded)"

echo "CORRELATION_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
