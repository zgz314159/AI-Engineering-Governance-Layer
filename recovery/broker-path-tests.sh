#!/usr/bin/env bash
# Focused check for THIS round only: the broker's local /v1 -> upstream base-path mapping.
# It starts the REAL broker against a stub upstream and asserts the forwarded paths.
set -u
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER="$AEGL_ROOT/recovery/model_broker.py"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; LOG="$T/paths"; SOCK="$T/broker.sock"; PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
: > "$T/cred.env"; echo "COMMANDCODE_API_KEY=dummy-not-a-real-key" > "$T/cred.env"

cat > "$T/upstream.py" <<'PY'
import http.server, sys
log = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _go(self):
        open(log, "a", encoding="utf-8").write(self.path + "\n")
        body = b"{}"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = _go
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
cat > "$T/client.py" <<'PY'
import socket, sys
sock = sys.argv[1]; method = sys.argv[2]; path = sys.argv[3]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sock)
body = b"{}"
head = "%s %s HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % (method, path, len(body))
s.sendall(head.encode() + body)
data = b""
while True:
    chunk = s.recv(65536)
    if not chunk: break
    data += chunk
print(data.decode("latin-1").split("\r\n")[0])
PY

python3 "$T/upstream.py" "$PORT" "$LOG" & UP=$!
python3 "$BROKER" serve --socket "$SOCK" --upstream "http://127.0.0.1:$PORT/provider/v1" --credential-file "$T/cred.env" >"$T/broker.out" 2>"$T/broker.err" & BP=$!
cleanup(){ kill "$BP" "$UP" 2>/dev/null; wait "$BP" "$UP" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] && ok "broker started against the stub upstream" || { no "broker did not start"; exit 1; }

send(){ printf '%s' "$(python3 "$T/client.py" "$SOCK" "$@")"; }

# --- the two paths from the real failure + query + trailing slash ------------------ #
send POST /v1/chat/completions >/dev/null
send GET  /v1/models            >/dev/null
send GET  "/v1/models?limit=3"  >/dev/null
send POST /v1/chat/completions/ >/dev/null
send GET  /provider/v1/models   >/dev/null
for _ in $(seq 1 30); do [ "$(wc -l < "$LOG")" -ge 5 ] && break; sleep 0.1; done

FWD=(); while IFS= read -r l; do FWD+=("$l"); done < "$LOG"
exp=(/provider/v1/chat/completions /provider/v1/models "/provider/v1/models?limit=3" /provider/v1/chat/completions/ /provider/v1/models)
for i in "${!exp[@]}"; do
  if [ "${FWD[$i]:-}" = "${exp[$i]}" ]; then ok "forwarded ${exp[$i]}"; else no "expected '${exp[$i]}', got '${FWD[$i]:-<none>}'"; fi
done
printf '%s\n' "${FWD[@]:-}" | grep -q '/provider/v1/v1/' && no "the duplicated /v1/v1 path is still produced" || ok "no duplicated /v1/v1 path"

# --- minimal routing log: method/in/fwd/status only, no secrets -------------------- #
grep -q 'AEGL_MODEL_ROUTE method=POST in=/v1/chat/completions fwd=/provider/v1/chat/completions status=200' "$T/broker.out" \
  && ok "route log records method, inbound, forwarded and status" || no "route log missing or wrong: $(grep -c AEGL_MODEL_ROUTE "$T/broker.out")"
grep -q 'dummy-not-a-real-key' "$T/broker.out" && no "a credential appears in the broker log" || ok "no credential in the broker log"
grep 'AEGL_MODEL_ROUTE' "$T/broker.out" | grep -qi 'authorization:\|content-type:\|user-agent:' && no "headers appear in the routing log" || ok "the routing log carries no headers (only method/in/fwd/status)"

echo "BROKER_PATH_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
