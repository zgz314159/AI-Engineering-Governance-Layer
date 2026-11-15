#!/usr/bin/env python3
"""Focused offline regression: a body-read failure after response headers must not
append a second (502) status line. The true cause is kept on broker stderr. Success
deletes only registered files; failure preserves the scene."""
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

sys.path.insert(0, str(Path(__file__).resolve().parent))

CASE_FILES = ("key", "broker.out", "broker.err", "model.sock")


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


def _group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError as exc:
        raise RuntimeError("cannot inspect broker process group %d: %s"
                           % (pgid, type(exc).__name__)) from exc
    return True


def _stop_broker(proc: subprocess.Popen | None) -> None:
    if proc is None:
        return
    pgid = proc.pid  # start_new_session makes the broker the group leader
    if _group_alive(pgid):
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    deadline = time.monotonic() + 5.0
    while _group_alive(pgid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if _group_alive(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5.0
        while _group_alive(pgid) and time.monotonic() < deadline:
            time.sleep(0.05)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("broker main process did not exit") from exc
    if _group_alive(pgid):
        raise RuntimeError("broker process group %d still alive" % pgid)


def _require_thread_stopped(thread: threading.Thread | None, name: str) -> None:
    if thread is None:
        return
    thread.join(5.0)
    if thread.is_alive():
        raise RuntimeError("%s thread still alive" % name)


def _cleanup_case(case_dir: Path) -> None:
    if not case_dir.is_dir():
        raise RuntimeError("missing case dir %s" % case_dir)
    names = {entry.name for entry in case_dir.iterdir()}
    unknown = sorted(names - set(CASE_FILES))
    if unknown:
        raise RuntimeError("unknown entries %s in %s" % (", ".join(unknown), case_dir))
    for name in CASE_FILES:
        path = case_dir / name
        if path.exists() or path.is_symlink():
            if path.is_dir():
                raise RuntimeError("unexpected directory %s" % path)
            path.unlink()
    case_dir.rmdir()


def main() -> int:
    base = Path(tempfile.mkdtemp(prefix="aegl-broker-truncated-", dir="/var/tmp"))
    try:
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
        passed = False
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
            passed = True
            print("BROKER_TRUNCATED_NO_SECOND_STATUS=OK")
        except BaseException:
            print("PRESERVED_DIR=%s" % case_dir, file=sys.stderr)
            raise
        finally:
            errors = []
            for label, action in (
                ("client", lambda: client.close() if client is not None else None),
                ("broker", lambda: _stop_broker(broker)),
                ("upstream", lambda: (server.shutdown(), server.server_close())),
                ("upstream_thread", lambda: _require_thread_stopped(server_thread, "upstream")),
            ):
                try:
                    action()
                except BaseException as exc:
                    errors.append((label, exc))
            if errors:
                print("PRESERVED_DIR=%s" % case_dir, file=sys.stderr)
                raise RuntimeError("cleanup failed: %s"
                                   % ", ".join("%s=%s" % (label, type(exc).__name__)
                                               for label, exc in errors)) from errors[0][1]
        if not passed:
            raise RuntimeError("case did not pass")
        try:
            _cleanup_case(case_dir)
        except BaseException:
            print("PRESERVED_DIR=%s" % case_dir, file=sys.stderr)
            raise
        try:
            base.rmdir()
        except BaseException:
            print("BROKER_TRUNCATED_SCENE=%s" % base, file=sys.stderr)
            raise
        return 0
    except BaseException:
        print("BROKER_TRUNCATED_SCENE=%s" % base, file=sys.stderr)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
