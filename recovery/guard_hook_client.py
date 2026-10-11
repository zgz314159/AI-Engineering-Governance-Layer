#!/usr/bin/env python3
"""In-sandbox pre_tool_call hook client.

It does NOT decide anything: it forwards the hook payload to the trusted controller over the
task-scoped socket and reproduces the guard's RAW stdout + exit code, so Hermes' fail_closed
hook semantics apply unchanged. Any interface failure (no socket, timeout, bad reply, no
guard configured) produces an explicit BLOCK — the tool never runs without a real verdict.

CLI: guard_hook_client.py --socket PATH
"""

from __future__ import annotations

import argparse
import json
import socket
import sys

BLOCK_ACTION = "block"


def _block(message: str) -> int:
    sys.stdout.write(json.dumps({"action": BLOCK_ACTION, "message": message}, ensure_ascii=False))
    sys.stdout.flush()
    return 2


def ask(sock_path: str, payload: dict, timeout: float) -> dict:
    body = json.dumps(payload).encode("utf-8")
    request = ("POST /guard HTTP/1.1\r\nHost: aegl-controller\r\n"
               "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)).encode("utf-8") + body
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(sock_path)
        sock.sendall(request)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        sock.close()
    raw = b"".join(chunks)
    head, _, response_body = raw.partition(b"\r\n\r\n")
    if not head.startswith(b"HTTP/1.1 200"):
        raise ValueError("controller returned a non-200 reply")
    return json.loads(response_body.decode("utf-8") or "{}")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--timeout", type=float, default=25.0)
    args = ap.parse_args(argv)

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    try:
        reply = ask(args.socket, payload, args.timeout)
    except Exception as exc:  # noqa: BLE001 — fail closed, always
        return _block("trusted guard controller unreachable (%s); refusing the tool call"
                      % type(exc).__name__)

    if reply.get("error") or reply.get("rc") is None:
        return _block("trusted guard capture failed (%s); refusing the tool call"
                      % (reply.get("error") or "no verdict"))

    # reproduce the guard's raw stdout and exit code verbatim
    sys.stdout.write(reply.get("stdout") or "")
    sys.stdout.flush()
    return int(reply.get("rc") or 0)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
