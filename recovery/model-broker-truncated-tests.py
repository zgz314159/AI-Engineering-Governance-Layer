#!/usr/bin/env python3
"""Focused offline regression: a body-read failure after response headers must not
append a second (502) status line. The true cause is kept on broker stderr."""
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


class TruncatedUpstream(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Length", "100")
        self.end_headers()
        self.wfile.write(b"{}")
        self.wfile.flush()
        self.close_connection = True

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


def main() -> int:
    base = Path(tempfile.mkdtemp(prefix="aegl-broker-truncated-", dir="/var/tmp"))
    case_dir = base / "truncated"
    case_dir.mkdir()
    sock_path = case_dir / "model.sock"
    key_path = case_dir / "key"
    key_path.write_text("LOCAL_TEST_ONLY", encoding="utf-8")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TruncatedUpstream)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    broker = None
    client = None
    ok = False
    try:
        with (case_dir / "broker.out").open("w") as out, (case_dir / "broker.err").open("w") as err:
            broker = subprocess.Popen(
                [sys.executable, str(Path(__file__).with_name("model_broker.py")),
                 "serve", "--socket", str(sock_path),
                 "--upstream", "http://127.0.0.1:%d/provider/v1" % server.server_port,
                 "--credential-file", str(key_path), "--credential-env", "UNSET_TEST_KEY"],
                env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"},
                stdout=out, stderr=err, start_new_session=True,
            )
        _wait_socket(sock_path, broker)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5.0)
        client.connect(str(sock_path))
        body = b'{"model":"LOCAL_TEST","messages":[]}'
        client.sendall(
            b"POST /v1/chat/completions HTTP/1.1\r\nHost: local\r\n"
            b"Content-Length: " + str(len(body)).encode() +
            b"\r\nConnection: close\r\n\r\n" + body
        )
        response = b""
        while True:
            part = client.recv(65536)
            if not part:
                break
            response += part
        assert response.startswith(b"HTTP/1.1 200 "), response[:120]
        assert b"HTTP/1.1 502" not in response, response[-120:]
        stderr = (case_dir / "broker.err").read_text(encoding="utf-8")
        assert "IncompleteRead" in stderr, stderr
        ok = True
        print("BROKER_TRUNCATED_NO_SECOND_STATUS=OK")
    finally:
        if client is not None:
            client.close()
        if broker is not None:
            _stop_broker(broker)
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=5)
    if ok:
        shutil.rmtree(case_dir)
        try:
            base.rmdir()
        except OSError:
            pass
    else:
        print("PRESERVED_DIR=%s" % case_dir, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
