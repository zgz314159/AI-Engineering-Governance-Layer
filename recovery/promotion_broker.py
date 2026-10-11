#!/usr/bin/env python3
"""AEGL trust broker — trusted task registry + promotion of the approved exact content.

The broker is the independent identity that authorizes and applies a promotion. It
does not trust the AI: the requester is authenticated by ``SO_PEERCRED`` (the kernel
peer uid, not a client-supplied token), and the *project target, task baseline and
approved candidate content* are bound by a **broker-owned registry**, never by the
AI-writable ``task.json`` / ``verify.status``.

Ops (bounded; a request carries ``op`` + ``task_id`` only — never a shell command,
never a path):

  register  (recorder uid)  bind  task_id -> {project, base, worktree, branch}
  record    (recorder uid)  bind  task_id -> approved candidate digest (verify PASS)
  validate  (requester uid) re-pin the candidate vs the registry; no change on failure
  promote   (requester uid) validate, then apply the exact approved content
  status                    read-only registry summary

The candidate is re-pinned at validate/promote time (:func:`promotion_core.candidate_digest`)
so files or branches swapped after the check are refused. Git apply disables hooks and
untrusted exec entry points; candidate code is never executed here. Promotions are
serialized by an flock.

Modes: ``serve`` (daemon) · ``client`` (used by ``bin/aegl-task``).
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import socket
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import promotion_core  # noqa: E402

PROTOCOL = "AEGL-BROKER/1"
TASK_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
OPS = frozenset({"register", "record", "validate", "promote", "status"})

DEFAULT_REGISTRY_DIR = "/var/lib/aegl-promote"
REGISTRY_FILE = "registry.json"


def _split_ids(raw: str):
    out = set()
    for item in (raw or "").split(","):
        item = item.strip()
        if item.isdigit():
            out.add(int(item))
        elif item:
            try:
                import pwd

                out.add(pwd.getpwnam(item).pw_uid)
            except (KeyError, ImportError):
                pass
    return out


def requester_uids() -> set:
    return _split_ids(os.environ.get("AEGL_BROKER_ALLOW_REQUESTERS", "")) or _split_ids("aegl-ai")


def recorder_uids() -> set:
    return _split_ids(os.environ.get("AEGL_BROKER_ALLOW_RECORDERS", "")) or _split_ids("root,0,zhong")


def project_allowlist() -> set:
    raw = os.environ.get("AEGL_PROJECT_ALLOWLIST", "")
    return {x.strip() for x in raw.split(",") if x.strip()} or set(promotion_core.ALLOWED_PROJECT_DIRS)


def registry_dir() -> str:
    d = os.environ.get("AEGL_BROKER_REGISTRY_DIR") or DEFAULT_REGISTRY_DIR
    return os.path.realpath(d)


def _load_registry(regdir: str) -> dict:
    path = os.path.join(regdir, REGISTRY_FILE)
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def _save_registry(regdir: str, registry: dict) -> None:
    os.makedirs(regdir, exist_ok=True)
    try:
        os.chmod(regdir, 0o700)
    except OSError:
        pass
    path = os.path.join(regdir, REGISTRY_FILE)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, (json.dumps(registry, sort_keys=True, indent=2) + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def _peer_uid(conn: socket.socket) -> int:
    try:
        cred = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", cred)
        return int(uid)
    except OSError:
        return -1


def _authorized_project(project: str) -> str:
    proj = os.path.realpath(project)
    if os.path.dirname(proj) != promotion_core.projects_root():
        raise ValueError("project is not directly under the projects root")
    if os.path.basename(proj) not in project_allowlist():
        raise ValueError("project is not in the allowlist")
    if not os.path.isdir(proj):
        raise ValueError("project dir missing")
    return proj


def _op_register(request: dict, registry: dict) -> dict:
    task_id = request.get("task_id")
    if not isinstance(task_id, str) or not TASK_ID_RE.match(task_id):
        return {"decision": "REJECTED", "reason": "invalid_task_id"}
    try:
        proj = _authorized_project(request.get("project"))
    except ValueError as exc:
        return {"decision": "REJECTED", "reason": str(exc)}
    base = request.get("base")
    if not isinstance(base, str) or not base:
        return {"decision": "REJECTED", "reason": "missing_base"}
    if promotion_core._git(proj, "rev-parse", "--verify", "--quiet", base).returncode != 0:
        return {"decision": "REJECTED", "reason": "unknown_base"}
    worktree = request.get("worktree")
    if not isinstance(worktree, str) or not os.path.isdir(worktree):
        return {"decision": "REJECTED", "reason": "worktree_missing"}
    branch = request.get("branch")
    if not isinstance(branch, str) or not branch:
        return {"decision": "REJECTED", "reason": "missing_branch"}
    registry[task_id] = {
        "project": proj, "base": base, "worktree": os.path.realpath(worktree), "branch": branch,
        "approved_digest": None,
    }
    return {"decision": "REGISTERED", "task_id": task_id}


def _op_record(request: dict, registry: dict) -> dict:
    task_id = request.get("task_id")
    entry = registry.get(task_id)
    if not entry:
        return {"decision": "REJECTED", "reason": "task_not_registered"}
    if request.get("verify_result") != "PASS":
        return {"decision": "REJECTED", "reason": "verify_not_passed"}
    digest = request.get("candidate_digest")
    if not isinstance(digest, str) or not DIGEST_RE.match(digest):
        return {"decision": "REJECTED", "reason": "invalid_candidate_digest"}
    entry["approved_digest"] = digest
    entry["verify_result"] = "PASS"
    return {"decision": "RECORDED", "task_id": task_id}


def _check_candidate(entry: dict) -> dict:
    wt, base, branch = entry["worktree"], entry["base"], entry["branch"]
    if not entry.get("approved_digest"):
        return {"decision": "REJECTED", "reason": "candidate_not_recorded"}
    actual = promotion_core.candidate_digest(wt, base, branch)
    if actual != entry["approved_digest"]:
        return {"decision": "REJECTED", "reason": "candidate_content_swapped"}
    return promotion_core.validate_candidate(wt, base, branch)


def handle_request(request: dict, peer_uid: int, regdir: str, lock_fd: int) -> dict:
    op = request.get("op")
    if op not in OPS:
        return {"decision": "REJECTED", "reason": "unsupported_op"}
    if op == "status":
        registry = _load_registry(regdir)
        return {"decision": "OK", "registered": len(registry),
                "recorded": sum(1 for e in registry.values() if e.get("approved_digest"))}
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    try:
        registry = _load_registry(regdir)
        if op in ("register", "record"):
            if peer_uid not in recorder_uids():
                return {"decision": "REJECTED", "reason": "unauthorized_recorder"}
            result = _op_register(request, registry) if op == "register" else _op_record(request, registry)
            if result["decision"] in ("REGISTERED", "RECORDED"):
                _save_registry(regdir, registry)
            return result
        # requester-only ops
        if peer_uid not in requester_uids():
            return {"decision": "REJECTED", "reason": "unauthorized_requester"}
        task_id = request.get("task_id")
        entry = registry.get(task_id) if isinstance(task_id, str) else None
        if not entry:
            return {"decision": "REJECTED", "reason": "task_not_registered"}
        verdict = _check_candidate(entry)
        verdict["task_id"] = task_id
        if op == "validate" or verdict["decision"] != "VALIDATED":
            return verdict
        applied = promotion_core.apply(entry["project"], entry["worktree"], entry["branch"], task_id)
        applied["task_id"] = task_id
        return applied
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)


def _readline(conn: socket.socket) -> str:
    data = b""
    while b"\n" not in data and len(data) < 65536:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    return data.split(b"\n", 1)[0].decode("utf-8", "replace").strip()


def _serve_conn(conn: socket.socket, regdir: str, lock_fd: int) -> None:
    peer = _peer_uid(conn)
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
    result = handle_request(request, peer, regdir, lock_fd)
    conn.sendall(("%s RESULT %s\n" % (PROTOCOL, json.dumps(result, sort_keys=True))).encode())


def serve(sock_path: str) -> int:
    regdir = registry_dir()
    os.makedirs(regdir, exist_ok=True)
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    lock_fd = os.open(sock_path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    os.chmod(sock_path, 0o660)
    server.listen(8)
    print("AEGL_PROMOTE_BROKER listening=%s protocol=%s registry=%s" % (sock_path, PROTOCOL, regdir), flush=True)
    try:
        while True:
            conn, _ = server.accept()
            try:
                _serve_conn(conn, regdir, lock_fd)
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


def client(sock_path: str, request: dict) -> int:
    nonce = os.urandom(8).hex()
    try:
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(120.0)
        sock.connect(sock_path)
    except OSError as exc:
        print(json.dumps({"decision": "UNREACHABLE", "reason": str(exc)}))
        return 2
    try:
        sock.sendall(("%s PING %s\n" % (PROTOCOL, nonce)).encode())
        if _readline(sock) != "%s PONG %s" % (PROTOCOL, nonce):
            print(json.dumps({"decision": "UNREACHABLE", "reason": "handshake_failed"}))
            return 2
        sock.sendall(("%s REQUEST %s\n" % (PROTOCOL, json.dumps(request))).encode())
        reply = _readline(sock)
    finally:
        sock.close()
    parts = reply.split(" ", 2)
    if len(parts) != 3 or parts[0] != PROTOCOL or parts[1] != "RESULT":
        print(json.dumps({"decision": "UNREACHABLE", "reason": "bad_reply"}))
        return 2
    print(parts[2])
    decision = json.loads(parts[2]).get("decision", "")
    return {"APPLIED": 0, "VALIDATED": 0, "OK": 0, "REGISTERED": 0, "RECORDED": 0}.get(decision, 3 if decision == "REJECTED" else 4)


def main(argv):
    if not argv:
        print("usage: promotion_broker.py serve --socket PATH | client --socket PATH --request JSON")
        return 2
    mode = argv[0]
    opts = {}
    i = 1
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opts[argv[i][2:]] = argv[i + 1]
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
        raw = opts.get("request")
        if not sock or not raw:
            print("client requires --socket and --request")
            return 2
        return client(os.path.abspath(sock), json.loads(raw))
    print("unknown mode: %s" % mode)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
