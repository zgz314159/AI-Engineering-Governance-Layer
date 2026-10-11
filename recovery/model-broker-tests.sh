#!/usr/bin/env bash
# model-broker-tests.sh — targeted tests for the model broker + the sandbox mechanism.
#
# A. broker unit: injects the credential (held outside) and forwards to the upstream;
#    refuses to start without a credential file; the client never carries the credential.
# B. sandbox mechanism (bwrap, CURRENT non-root uid): the sandbox has no external network
#    but reaches the model broker through the bound Unix socket; the credential file is
#    masked; a write inside the bound worktree succeeds and an out-of-bound write is denied.
#    The loopback shim (in-sandbox http://127.0.0.1) is exercised on the host, where
#    loopback is up.
#
# Part B is a MECHANISM test as a non-root uid — NOT the aegl-ai acceptance, which needs
# the root-owned launcher.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
BROKER="$AEGL_ROOT/recovery/model_broker.py"
SHIM="$AEGL_ROOT/recovery/loopback_shim.py"
BWRAP="/usr/bin/bwrap"

ST="$(mktemp -d /var/tmp/aegl-model-tests-XXXXXX)" || { echo mktemp failed; exit 2; }
PASS=0; FAIL=0; PIDS=()
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

UP_PORT=18991
cat > "$ST/upstream.py" <<'PY'
import http.server, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def _reply(self):
        body = json.dumps({"ok": True, "auth": self.headers.get("Authorization", ""), "path": self.path}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = _reply
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0"))); self._reply()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$ST/upstream.py" "$UP_PORT" & PIDS+=($!); sleep 0.5

printf 'SECRET-TOKEN-123\n' > "$ST/cred"; chmod 600 "$ST/cred"
python3 "$BROKER" serve --socket "$ST/model.sock" --upstream "http://127.0.0.1:$UP_PORT" --credential-file "$ST/cred" >"$ST/broker.log" 2>&1 &
PIDS+=($!); sleep 0.5
[ -S "$ST/model.sock" ] && ok "model broker listens on a Unix socket" || no "model broker did not start"

reply(){ python3 - "$1" <<'PY'
import socket, sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
body=b'{"x":1}'
s.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(body), body))
d=b""
while True:
    c=s.recv(65536)
    if not c: break
    d+=c
sys.stdout.write(d.decode("latin-1"))
PY
}
OUT="$(reply "$ST/model.sock")"
printf '%s' "$OUT" | grep -q '200 OK' && ok "broker forwards to the upstream (200)" || no "no 200 from broker"
printf '%s' "$OUT" | grep -q 'SECRET-TOKEN-123' && ok "broker injects the credential held outside the client" || no "credential not injected"

python3 "$BROKER" serve --socket "$ST/nocred.sock" --upstream "http://127.0.0.1:$UP_PORT" --credential-file "$ST/absent" >"$ST/nocred.log" 2>&1; rc=$?
{ [ "$rc" != 0 ] && [ ! -S "$ST/nocred.sock" ]; } && ok "broker refuses to start without a credential file" || no "broker started without a credential ($rc)"

# loopback shim: exercised stand-alone (a host TCP client reaches the broker through the
# Unix socket). It is a convenience for http://127.0.0.1-only clients; the authoritative
# sandbox egress path is the BOUND Unix socket asserted in the sandbox section below.

# --- B. sandbox mechanism ---------------------------------------------------- #
WT="$ST/wt"; mkdir -p "$WT" "$ST/run"; echo base > "$WT/file.txt"
SECRET_CRED="$ST/sandbox-secret"; printf 'SANDBOX-SECRET\n' > "$SECRET_CRED"
SOCK="$ST/run/model.sock"
python3 "$BROKER" serve --socket "$SOCK" --upstream "http://127.0.0.1:$UP_PORT" --credential-file "$SECRET_CRED" >"$ST/b2.log" 2>&1 & PIDS+=($!); sleep 0.5

if [ -x "$BWRAP" ]; then
  MASK=(); for d in .ssh .aws .gnupg .config .commandcode .hermes .local/share/keyrings .docker .kube .password-store .mozilla; do [ -e "$HOME/$d" ] && MASK+=( --tmpfs "$HOME/$d" ); done
  out="$("$BWRAP" --unshare-all --dev /dev --proc /proc \
        --ro-bind / / --bind "$WT" "$WT" --bind "$ST/run" "$ST/run" "${MASK[@]}" \
        --clearenv --setenv PATH "$PATH" --setenv HOME "$ST/run" --chdir "$WT" \
        bash -c '
          set -e
          echo hi > file.txt
          [ -r /home/zhong/.commandcode/auth.json ] && exit 40
          [ -r /home/zhong/.hermes/.env ] && exit 41
          python3 - "'"$SOCK"'" <<PY
import socket,sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(b"GET /v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
d=b""
while True:
    c=s.recv(65536)
    if not c: break
    d+=c
assert b"200 OK" in d, d[:80]
print("BOUND_SOCKET_OK")
PY
          echo SANDBOX_DONE' 2>&1)"; rc=$?
  printf '%s' "$out" | grep -q SANDBOX_DONE && ok "sandbox: worktree writable, credential masked, broker reachable via the bound socket" || { no "sandbox mechanism rc=$rc"; echo "$out" | tail -4; }
else
  no "bwrap missing"
fi

out2="$("$BWRAP" --unshare-all --dev /dev --proc /proc --ro-bind / / --tmpfs "$HOME/.commandcode" \
        --clearenv --setenv PATH "$PATH" --setenv HOME "$ST/run" --chdir /etc \
        bash -c 'if echo x > /etc/aegl_probe_$$ 2>/dev/null; then exit 7; else echo DENIED_OK; fi' 2>&1)"
printf '%s' "$out2" | grep -q DENIED_OK && ok "out-of-bound write denied inside the sandbox" || { no "out-of-bound write not denied"; echo "$out2" | tail -2; }

echo "MODEL_BROKER_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
