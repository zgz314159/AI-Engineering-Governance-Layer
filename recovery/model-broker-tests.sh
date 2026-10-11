#!/usr/bin/env bash
# model-broker-tests.sh — targeted tests for the model broker + the in-sandbox shim path.
#
# A. broker unit: reads the EXISTING credential from COMMANDCODE_API_KEY in its env (no new
#    file); injects it; joins the upstream URL without duplicating a shared prefix; refuses
#    to start with no credential.
# B. in-sandbox: in the SAME sandbox network namespace, the loopback shim → Unix socket →
#    broker path returns the FULL HTTP response (headers AND body, read to EOF); the worktree
#    is writable; the real credential paths are masked; an out-of-bound write is denied.
#
# Run as the current (non-root) uid: this exercises the sandbox + shim MECHANISM. It is not
# the aegl-ai acceptance (that needs the root-owned launcher).
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

UP_PORT=18992
cat > "$ST/upstream.py" <<'PY'
import http.server, sys, json
SEEN = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _reply(self):
        with open(SEEN, "w") as fh:
            fh.write(self.headers.get("Authorization", ""))
        body = json.dumps({"ok": True, "path": self.path}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = _reply
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0"))); self._reply()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$ST/upstream.py" "$UP_PORT" "$ST/seen" & PIDS+=($!); sleep 0.5

# A. credential read from the existing env var; upstream with a /v1 base path
export COMMANDCODE_API_KEY="EXISTING-ENV-KEY-987"
python3 "$BROKER" serve --socket "$ST/model.sock" --upstream "http://127.0.0.1:$UP_PORT/v1" >"$ST/broker.log" 2>&1 &
PIDS+=($!); sleep 0.5
[ -S "$ST/model.sock" ] && ok "broker listens (credential from COMMANDCODE_API_KEY, no file)" || no "broker did not start"

reply(){ python3 - "$1" <<'PY'
import socket, sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(b"GET /v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
d=b""
while True:
    c=s.recv(65536)
    if not c: break
    d+=c
sys.stdout.write(d.decode("latin-1"))
PY
}
OUT="$(reply "$ST/model.sock")"; sleep 0.2
printf '%s' "$OUT" | grep -q '200 OK' && ok "broker forwards to the upstream (200)" || no "no 200"
grep -q 'EXISTING-ENV-KEY-987' "$ST/seen" 2>/dev/null && ok "broker injected the existing credential" || no "credential not injected ($(cat "$ST/seen" 2>/dev/null))"
printf '%s' "$OUT" | grep -q '"path": "/v1/models"' && ok "URL joined without duplicating /v1" || no "URL join wrong (see $OUT)"

env -u COMMANDCODE_API_KEY python3 "$BROKER" serve --socket "$ST/nocred.sock" --upstream "http://127.0.0.1:$UP_PORT/v1" >"$ST/nocred.log" 2>&1; rc=$?
{ [ "$rc" != 0 ] && [ ! -S "$ST/nocred.sock" ]; } && ok "broker refuses to start with no credential" || no "broker started without a credential"

# B. in-sandbox shim path
WT="$ST/wt"; mkdir -p "$WT" "$ST/run"; echo base > "$WT/file.txt"
SOCK="$ST/run/model.sock"
COMMANDCODE_API_KEY="SANDBOX-KEY" python3 "$BROKER" serve --socket "$SOCK" --upstream "http://127.0.0.1:$UP_PORT/v1" >"$ST/b2.log" 2>&1 &
PIDS+=($!); sleep 0.5

if [ -x "$BWRAP" ]; then
  MASK=(); for d in .ssh .aws .gnupg .config .commandcode .hermes .local/share/keyrings .docker .kube .password-store .mozilla; do [ -e "$HOME/$d" ] && MASK+=( --tmpfs "$HOME/$d" ); done
  out="$("$BWRAP" --unshare-all --dev /dev --proc /proc \
        --ro-bind / / --ro-bind "$SHIM" "$SHIM" --bind "$WT" "$WT" --bind "$ST/run" "$ST/run" "${MASK[@]}" \
        --clearenv --setenv PATH "$PATH" --setenv HOME "$ST/run" --chdir "$WT" \
        python3 - "$SHIM" "$SOCK" "$ST/run" <<'PY' 2>&1 || true
import os, subprocess, socket, sys, time
shim, sock, home = sys.argv[1], sys.argv[2], sys.argv[3]
# worktree write allowed
open("file.txt", "w").write("hi\n")
# real credential paths masked
for p in ("/home/zhong/.commandcode/auth.json", "/home/zhong/.hermes/.env"):
    if os.path.exists(p):
        print("MASK_FAIL", p); sys.exit(40)
# start the shim INSIDE this sandbox netns, then read the FULL response through it
proc = subprocess.Popen(["python3", shim, "--listen", "127.0.0.1:8877", "--unix", sock],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
s = None
for _ in range(60):
    try:
        s = socket.create_connection(("127.0.0.1", 8877), timeout=2)
        break
    except OSError:
        time.sleep(0.1)
if s is None:
    proc.terminate()
    print("SHIM_START_FAIL", proc.stdout.read().decode("latin-1", "replace")[:400])
    sys.exit(41)
try:
    s.sendall(b"GET /v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    data = b""
    while True:
        c = s.recv(4096)
        if not c:
            break
        data += c
finally:
    proc.terminate()
txt = data.decode("latin-1")
assert "200 OK" in txt, txt[:120]
assert '"ok": true' in txt, "body missing: " + txt[:200]
# the credential the broker injected must NOT be visible to the sandbox
assert "SANDBOX-KEY" not in txt
print("SHIM_IN_SANDBOX_OK")
PY
)"; rc=$?
  printf '%s' "$out" | grep -q SHIM_IN_SANDBOX_OK && ok "sandbox: shim→unix→broker returns the full response (headers+body) in the netns; worktree writable; credential paths masked" || { no "in-sandbox shim path rc=$rc"; echo "$out" | tail -5; }
else
  no "bwrap missing"
fi

out2="$("$BWRAP" --unshare-all --dev /dev --proc /proc --ro-bind / / --tmpfs "$HOME/.commandcode" \
        --clearenv --setenv PATH "$PATH" --setenv HOME "$ST/run" --chdir /etc \
        bash -c 'if echo x > /etc/aegl_probe_$$ 2>/dev/null; then exit 7; else echo DENIED_OK; fi' 2>&1)"
printf '%s' "$out2" | grep -q DENIED_OK && ok "out-of-bound write denied inside the sandbox" || { no "out-of-bound write not denied"; echo "$out2" | tail -2; }

# --- C. Hermes runtime reachable inside the sandbox (read-only mounts + entry) - #
ENTRY="/home/zhong/.local/bin/hermes"
if [ -x "$ENTRY" ] && [ -d /home/zhong/.hermes/hermes-agent ] && [ -d /home/zhong/.hermes/tools ]; then
  rout="$("$BWRAP" --unshare-all --dev /dev --proc /proc --ro-bind / / \
        --tmpfs /home/zhong/.hermes \
        --ro-bind /home/zhong/.hermes/hermes-agent /home/zhong/.hermes/hermes-agent \
        --ro-bind /home/zhong/.hermes/tools /home/zhong/.hermes/tools \
        --ro-bind "$ENTRY" "$ENTRY" \
        --overlay-src /home/zhong/.hermes/installs --tmp-overlay /home/zhong/.hermes/installs \
        --clearenv --setenv PATH "/usr/local/bin:/usr/bin:/bin:/home/zhong/.local/bin" \
        --setenv HOME /tmp --setenv HERMES_HOME /home/zhong/.hermes \
        bash -c '[ -r /home/zhong/.hermes/.env ] && exit 42; [ -r /home/zhong/.hermes/profiles/android-stack/auth.json ] && exit 43; hermes --version' 2>&1)"; rc=$?
  printf '%s' "$rout" | grep -q 'Hermes Agent v' && ok "Hermes runtime + deps run inside the sandbox (real .hermes masked; installs on an ephemeral overlay)" || { no "hermes runtime in sandbox rc=$rc"; echo "$rout" | tail -3; }
else
  no "Hermes entry/runtime/tools not found"
fi

echo "MODEL_BROKER_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
