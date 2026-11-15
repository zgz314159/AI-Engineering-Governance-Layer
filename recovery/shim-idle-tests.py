#!/usr/bin/env python3
"""Focused offline regression: a slow model response must survive request-side idle.

The sandbox loopback shim retires an idle direction independently; the broker sends the
upstream status line/headers before it buffers the body. Together these keep the response
direction alive while the request side has nothing more to send.
"""
from __future__ import annotations

import http.server
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import loopback_shim  # noqa: E402

BODY = b'{"choices":[{"message":{"content":"ok"}}]}'
HEADER_DELAY = 0.6
DELAY = 2.05


class SlowUpstream(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        time.sleep(HEADER_DELAY)
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.flush()
        time.sleep(DELAY - HEADER_DELAY)
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


def main() -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SlowUpstream)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix="aegl-shim-idle-", dir="/var/tmp") as tmp:
        base = Path(tmp)
        sock_path = base / "model.sock"
        key_path = base / "key"
        key_path.write_text("LOCAL_TEST_ONLY", encoding="utf-8")
        broker = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("model_broker.py")),
             "serve", "--socket", str(sock_path),
             "--upstream", "http://127.0.0.1:%d/provider/v1" % server.server_port,
             "--credential-file", str(key_path), "--credential-env", "UNSET_TEST_KEY"],
            env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            _wait_socket(sock_path, broker)
            loopback_shim.IDLE_TIMEOUT = 2.0
            client, shim_side = socket.socketpair()
            shim_thread = threading.Thread(
                target=loopback_shim._handle, args=(shim_side, str(sock_path)), daemon=True)
            shim_thread.start()
            try:
                client.settimeout(8.0)
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
                assert elapsed >= DELAY, "response completed before the delayed body: %.2fs" % elapsed
                print("SHIM_IDLE_LONG_RESPONSE=OK elapsed=%.2fs" % elapsed)
            finally:
                client.close()
                shim_thread.join(2.0)
                shim_side.close()
        finally:
            if broker.poll() is None:
                broker.terminate()
                try:
                    broker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    broker.kill()
                    broker.wait(timeout=5)
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
