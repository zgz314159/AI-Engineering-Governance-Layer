#!/usr/bin/env python3
"""AEGL trust broker — the independent identity that validates AND applies promotions.

The broker runs as a *different* identity (``aegl-promote``) from the AI. It never
accepts a shell command or an arbitrary target path: a request carries only an
``op`` in {validate, promote} and a ``task_id``. The project target is derived from
the task's own ``task.json`` (never from the request), so the caller cannot widen
the promotion target. Validation + apply is delegated to the ONE central gate
(:mod:`promotion_core`), which re-classifies the candidate, re-checks the content
pin and the allowed project target, and refuses on any failure.

The PING/PONG handshake only proves a broker is *reachable*; it is not
authorization. Authorization is that the promotion is validated and executed here,
by this identity, serialized.

Socket protocol (one connection, at most two request lines)::

    -> AEGL-BROKER/1 PING <nonce>
    <- AEGL-BROKER/1 PONG <nonce>
    -> AEGL-BROKER/1 REQUEST {"op":"promote","request_id":"..","task_id":".."}
    <- AEGL-BROKER/1 RESULT {"decision":"APPLIED|REJECTED|FAILED",".."}

Modes: ``serve`` (daemon) · ``client`` (what ``bin/aegl-task`` uses).
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import promotion_core  # noqa: E402

PROTOCOL = "AEGL-BROKER/1"
TASK_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
ALLOWED_OPS = frozenset({"promote", "validate"})


def _tasks_root() -> str:
    explicit = os.environ.get("AEGL_TASKS_ROOT")
    if explicit:
        return os.path.realpath(explicit)
    state = os.environ.get("AEGL_STATE_HOME") or os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "aegl"
    )
    return os.path.realpath(os.path.join(state, "tasks"))


def _resolve_task(task_id: str) -> str:
    """Task dir for a bounded id, guaranteed to stay under the tasks root."""
    if not isinstance(task_id, str) or not TASK_ID_RE.match(task_id):
        raise ValueError("invalid task_id")
    root = _tasks_root()
    task_dir = os.path.realpath(os.path.join(root, task_id))
    if os.path.dirname(task_dir) != root:
        raise ValueError("task_id escapes the tasks root")
    if not os.path.isfile(os.path.join(task_dir, "task.json")):
        raise ValueError("no such task")
    return task_dir


def handle_request(request: dict, lock_fd: int) -> dict:
    """Validate the bounded request and run the central gate. Never trusts a path."""
    op = request.get("op")
    request_id = request.get("request_id")
    if op not in ALLOWED_OPS:
        return {"decision": "REJECTED", "reason": "unsupported_op"}
    try:
        task_dir = _resolve_task(request.get("task_id"))
    except ValueError as exc:
        return {"decision": "REJECTED", "reason": str(exc)}
    fcntl.flock(lock_fd, fcntl.LOCK_EX)  # promotions are serialized
    try:
        if op == "validate":
            result = promotion_core.validate(task_dir)
        else:
            result = promotion_core.promote(task_dir)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    result = dict(result)
    result["request_id"] = request_id
    result.setdefault("task_id", request.get("task_id"))
    return result


def _readline(conn: socket.socket) -> str:
    data = b""
    while b"\n" not in data and len(data) < 65536:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    return data.split(b"\n", 1)[0].decode("utf-8", "replace").strip()


def _serve_conn(conn: socket.socket, lock_fd: int) -> None:
    first = _readline(conn)
    parts = first.split(" ", 2)
    if len(parts) != 3 or parts[0] != PROTOCOL or parts[1] != "PING":
        conn.sendall(("%s ERROR bad_handshake\n" % PROTOCOL).encode())
        return
    conn.sendall(("%s PONG %s\n" % (PROTOCOL, parts[2])).encode())
    second = _readline(conn)
    if not second:
        return
    chunks = second.split(" ", 2)
    if len(chunks) != 3 or chunks[0] != PROTOCOL or chunks[1] != "REQUEST":
        conn.sendall(("%s RESULT %s\n" % (PROTOCOL, json.dumps({"decision": "REJECTED", "reason": "bad_request"}))).encode())
        return
    try:
        request = json.loads(chunks[2])
        if not isinstance(request, dict):
            raise ValueError
    except ValueError:
        request = {}
    result = handle_request(request, lock_fd)
    conn.sendall(("%s RESULT %s\n" % (PROTOCOL, json.dumps(result, sort_keys=True))).encode())


def serve(sock_path: str) -> int:
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    lock_path = sock_path + ".lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    os.chmod(sock_path, 0o660)  # broker identity + aegl-broker group
    server.listen(8)
    print("AEGL_PROMOTE_BROKER listening=%s protocol=%s" % (sock_path, PROTOCOL), flush=True)
    try:
        while True:
            conn, _ = server.accept()
            try:
                _serve_conn(conn, lock_fd)
            except Exception as exc:  # noqa: BLE001 - never take the broker down
                try:
                    conn.sendall(("%s ERROR %s\n" % (PROTOCOL, type(exc).__name__)).encode())
                except OSError:
                    pass
            finally:
                conn.close()
    finally:
        server.close()
        try:
            os.unlink(sock_path)
        except OSError:
            pass
        os.close(lock_fd)
    return 0


def client(sock_path: str, task_id: str, op: str) -> int:
    nonce = os.urandom(8).hex()
    request_id = os.urandom(8).hex()
    request = {"protocol": PROTOCOL, "op": op, "request_id": request_id, "task_id": task_id}
    try:
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(120.0)
        sock.connect(sock_path)
    except OSError as exc:
        print(json.dumps({"decision": "UNREACHABLE", "reason": str(exc)}))
        return 2
    try:
        sock.sendall(("%s PING %s\n" % (PROTOCOL, nonce)).encode())
        pong = _readline(sock)
        if pong != "%s PONG %s" % (PROTOCOL, nonce):
            print(json.dumps({"decision": "UNREACHABLE", "reason": "handshake_failed"}))
            return 1
        sock.sendall(("%s REQUEST %s\n" % (PROTOCOL, json.dumps(request))).encode())
        reply = _readline(sock)
    finally:
        sock.close()
    parts = reply.split(" ", 2)
    if len(parts) != 3 or parts[0] != PROTOCOL or parts[1] != "RESULT":
        print(json.dumps({"decision": "UNREACHABLE", "reason": "bad_reply"}))
        return 1
    print(parts[2])
    return 0


def main(argv):
    if not argv:
        print("usage: promotion_broker.py serve --socket PATH | client --socket PATH --task ID [--op promote]")
        return 2
    mode = argv[0]
    opts = {}
    i = 1
    while i < len(argv):
        key = argv[i]
        if key.startswith("--") and i + 1 < len(argv):
            opts[key[2:]] = argv[i + 1]
            i += 2
        else:
            i += 1
    if mode == "serve":
        sock = opts.get("socket") or os.environ.get("AEGL_BROKER_SOCKET")
        if not sock:
            print("serve requires --socket or AEGL_BROKER_SOCKET")
            return 2
        return serve(os.path.abspath(sock))
    if mode == "client":
        sock = opts.get("socket") or os.environ.get("AEGL_BROKER_SOCKET")
        if not sock or not opts.get("task"):
            print("client requires --socket and --task")
            return 2
        return client(os.path.abspath(sock), opts["task"], opts.get("op", "promote"))
    print("unknown mode: %s" % mode)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
