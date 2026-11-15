#!/usr/bin/env python3
"""Focused offline regression: request-side idle must not truncate a slow response.

Case 1 is the original long response gap. Case 2 is the short reproduced failure:
request idle 0.2 s, headers at 0.05 s, body at 0.4 s. The response direction has no
direction idle; it is bounded only by the tunnel deadline.
"""
from __future__ import annotations

import http.server
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import shutil

sys.path.insert(0, str(Path(__file__).resolve().parent))
import loopback_shim  # noqa: E402

BODY = b'{"choices":[{"message":{"content":"ok"}}]}'
CASES = (
    {"name": "long-response", "idle": 2.0, "max_tunnel": 5.0,
     "header_delay": 0.6, "delay": 2.05},
    {"name": "idle-0.2", "idle": 0.2, "max_tunnel": 2.0,
     "header_delay": 0.05, "delay": 0.4},
)


class SlowUpstream(http.server.BaseHTTPRequestHandler):
    header_delay = 0.0
    delay = 0.0

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        time.sleep(type(self).header_delay)
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.flush()
        time.sleep(max(0.0, type(self).delay - type(self).header_delay))
        self.wfile.write(BODY)
        self.wfile.flush()

    def log_message(self, *args):
        pass


def _wait_socket(path: Path, proc: subprocess.Popen, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists():
        if proc.poll() is not None or time.monotonic() >= deadline:
            raise AssertionError("broker did not become ready")
        time.sleep(0.01)


def _stop_broker(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        group = os.getpgid(proc.pid)
    except OSError:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        return
    try:
        os.killpg(group, signal.SIGTERM)
    except OSError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(group, signal.SIGKILL)
        except OSError:
            pass
        proc.wait(timeout=5)


def run_case(case: dict, base: Path) -> None:
    case_dir = base / case["name"]
    case_dir.mkdir()
    sock_path = case_dir / "model.sock"
    key_path = case_dir / "key"
    key_path.write_text("LOCAL_TEST_ONLY", encoding="utf-8")
    SlowUpstream.header_delay = case["header_delay"]
    SlowUpstream.delay = case["delay"]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SlowUpstream)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    broker_log = case_dir / "broker.err"
    broker_out = case_dir / "broker.out"
    broker = None
    shim_thread = None
    client = shim_side = None
    ok = False
    try:
        with broker_out.open("w") as out, broker_log.open("w") as err:
            broker = subprocess.Popen(
                [sys.executable, str(Path(__file__).with_name("model_broker.py")),
                 "serve", "--socket", str(sock_path),
                 "--upstream", "http://127.0.0.1:%d/provider/v1" % server.server_port,
                 "--credential-file", str(key_path), "--credential-env", "UNSET_TEST_KEY"],
                env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"},
                stdout=out, stderr=err, start_new_session=True,
            )
        _wait_socket(sock_path, broker)
        loopback_shim.IDLE_TIMEOUT = case["idle"]
        loopback_shim.MAX_TUNNEL_SECONDS = case["max_tunnel"]
        client, shim_side = socket.socketpair()
        shim_thread = threading.Thread(
            target=loopback_shim._handle, args=(shim_side, str(sock_path)), daemon=True)
        shim_thread.start()
        client.settimeout(max(5.0, case["delay"] + 3.0))
        body = b'{"model":"LOCAL_TEST","messages":[]}'
        client.sendall(
            b"POST /v1/chat/completions HTTP/1.1\r\nHost: local\r\n"
            b"Content-Length: " + str(len(body)).encode() +
            b"\r\nConnection: close\r\n\r\n" + body
        )
        started = time.monotonic()
        response = b""
        while True:
            part = client.recv(65536)
            if not part:
                break
            response += part
        elapsed = time.monotonic() - started
        assert response.startswith(b"HTTP/1.1 200 "), response[:80]
        assert response.endswith(BODY), response[-80:]
        assert elapsed >= case["delay"], "response completed before delayed body: %.2fs" % elapsed
        ok = True
        print("SHIM_IDLE_%s=OK elapsed=%.2fs" % (case["name"].upper(), elapsed))
    finally:
        if client is not None:
            client.close()
        if shim_side is not None:
            shim_side.close()
        if shim_thread is not None:
            shim_thread.join(2.0)
        if broker is not None:
            _stop_broker(broker)
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=5)
    if ok:
        shutil.rmtree(case_dir)
    else:
        print("PRESERVED_DIR=%s" % case_dir, file=sys.stderr)


def main() -> int:
    base = Path(tempfile.mkdtemp(prefix="aegl-shim-idle-", dir="/var/tmp"))
    failed = False
    try:
        for case in CASES:
            run_case(case, base)
    except Exception:
        failed = True
        print("SHIM_IDLE_SCENE=%s" % base, file=sys.stderr)
        raise
    finally:
        if not failed:
            try:
                base.rmdir()
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
