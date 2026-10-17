#!/usr/bin/env python3
"""AEGL trust broker — trusted registry + exact-object promotion.

Authorization is by kernel peer uid (``SO_PEERCRED``) against two allowlists, so the
roles are separated in production:

* **recorders** (trusted control identity — currently manual root) run ``register`` /
  ``record``. The AI-running identity is NOT a recorder and can never declare
  ``verify_result=PASS``.
* **requesters** (the AI identity) may only ``validate`` / ``promote`` a task that a
  recorder already registered and approved.

``register`` binds ``target_ref`` (``refs/heads/main``) and the current target OID.
``record`` freezes the candidate tip's full commit OID + tree OID (clean worktree),
runs content classification on that tree, and requires ``base`` to be an ancestor of
the candidate so history is preservable. ``promote`` re-checks the target OID and
fast-forwards the bound ref to **exactly that commit** — never a worktree re-read,
never a mutable branch name, never a commit-tree snapshot. A failed check, a changed
target tip or a non-fast-forward leaves the target unchanged. Candidate code is never
executed here.

Ops: register · record · validate · promote · status. Modes: serve · client.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import socket
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import promotion_core  # noqa: E402

PROTOCOL = "AEGL-BROKER/1"
TASK_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
OPS = frozenset({"register", "record", "validate", "promote", "status"})

DEFAULT_REGISTRY_DIR = "/var/lib/aegl-promote"
REGISTRY_FILE = "registry.json"

# Same production gate as require-entry-binds.sh / aegl-hermes-sandbox.
# Host entry is /usr/local/lib/aegl-promote/promotion_broker.py after install-broker + restart;
# tip source alone does not update the running broker.
ENTRY_BIND_POLICY = "/etc/aegl/entry-bind/policy"
ENTRY_BIND_CHECKER = "/usr/local/lib/aegl-entry-bind/require-entry-binds.sh"


def require_entry_binds_before_apply() -> dict | None:
    """Refuse formal apply when pack is deployed but live RW self-binds are not OK.

    Returns None when allowed (not deployed, or deployed+live OK).
    Returns a REJECTED decision dict when the gate fails.
    """
    if not os.path.exists(ENTRY_BIND_POLICY):
        return None
    if not os.path.isfile(ENTRY_BIND_CHECKER) or not os.access(ENTRY_BIND_CHECKER, os.X_OK):
        return {
            "decision": "REJECTED",
            "reason": "entry_bind_checker_missing",
            "checker": ENTRY_BIND_CHECKER,
        }
    try:
        proc = subprocess.run(
            [ENTRY_BIND_CHECKER],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        return {
            "decision": "REJECTED",
            "reason": "entry_bind_checker_exec_failed",
            "detail": str(exc),
        }
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        if len(detail) > 500:
            detail = detail[-500:]
        return {
            "decision": "REJECTED",
            "reason": "entry_bind_not_live",
            "detail": detail,
        }
    return None


def _split_ids(raw: str) -> set:
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


# PRODUCTION defaults: recorders are the trusted control identity (root) only; the
# AI-running identity is never a recorder. The AI identity may only request.
# (The test harness overrides these to a single uid; that is test-only.)
def requester_uids() -> set:
    return _split_ids(os.environ.get("AEGL_BROKER_ALLOW_REQUESTERS", "")) or _split_ids("aegl-ai")


def recorder_uids() -> set:
    return _split_ids(os.environ.get("AEGL_BROKER_ALLOW_RECORDERS", "")) or _split_ids("root,0")


def project_allowlist() -> set:
    raw = os.environ.get("AEGL_PROJECT_ALLOWLIST", "")
    return {x.strip() for x in raw.split(",") if x.strip()} or set(promotion_core.ALLOWED_PROJECT_DIRS)


def registry_dir() -> str:
    return os.path.realpath(os.environ.get("AEGL_BROKER_REGISTRY_DIR") or DEFAULT_REGISTRY_DIR)


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
    """Authorize a registered project under exactly one allowlisted root.

    System names must sit directly under ``PROJECTS_ROOT``; business names
    (KeepLab) under ``AEGL_BUSINESS_ROOT``. The allow root is never expanded to
    ``$HOME`` or any other parent.
    """
    if not isinstance(project, str) or not project:
        raise ValueError("project path missing")
    proj = os.path.realpath(project)
    name = os.path.basename(proj)
    parent = os.path.dirname(proj)
    if name not in project_allowlist():
        raise ValueError("project is not in the allowlist")
    if name in promotion_core.ALLOWED_SYSTEM_PROJECT_DIRS:
        if parent != promotion_core.projects_root():
            raise ValueError("system project is not directly under the projects root")
    elif name in promotion_core.ALLOWED_BUSINESS_PROJECT_DIRS:
        if parent != promotion_core.business_root():
            raise ValueError("business project is not directly under the business root")
    else:
        # Custom allowlist entries (tests): system-root children only.
        if parent != promotion_core.projects_root():
            raise ValueError("project is not directly under the projects root")
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
    if not isinstance(base, str) or promotion_core._git(proj, "rev-parse", "--verify", "--quiet", base).returncode != 0:
        return {"decision": "REJECTED", "reason": "unknown_base"}
    worktree = request.get("worktree")
    if not isinstance(worktree, str) or not os.path.isdir(worktree):
        return {"decision": "REJECTED", "reason": "worktree_missing"}
    if not isinstance(request.get("branch"), str) or not request.get("branch"):
        return {"decision": "REJECTED", "reason": "missing_branch"}
    target_ref = request.get("target_ref")
    allowed_refs = promotion_core.allowed_target_refs(os.path.basename(proj))
    if not isinstance(target_ref, str) or target_ref not in allowed_refs:
        return {"decision": "REJECTED", "reason": "invalid_target_ref"}
    target_oid = promotion_core.ref_oid(proj, target_ref)
    if not target_oid or len(target_oid) != 40:
        return {"decision": "REJECTED", "reason": "target_ref_missing"}
    # base must be an ancestor of (or equal to) the bound target tip so classification
    # and fast-forward share one history line.
    if not promotion_core.is_ancestor(proj, base, target_oid) and base != target_oid:
        return {"decision": "REJECTED", "reason": "base_not_on_target_history"}
    registry[task_id] = {
        "project": proj, "base": base, "worktree": os.path.realpath(worktree),
        "branch": request["branch"], "target_ref": target_ref, "target_oid": target_oid,
        "approved_tree": None, "approved_commit": None,
    }
    return {"decision": "REGISTERED", "task_id": task_id,
            "target_ref": target_ref, "target_oid": target_oid}


def _op_record(request: dict, registry: dict) -> dict:
    task_id = request.get("task_id")
    entry = registry.get(task_id)
    if not entry:
        return {"decision": "REJECTED", "reason": "task_not_registered"}
    if request.get("verify_result") != "PASS":
        return {"decision": "REJECTED", "reason": "verify_not_passed"}
    wt, base, proj = entry["worktree"], entry["base"], entry["project"]
    try:
        commit, tree = promotion_core.freeze_candidate_commit(wt)
    except RuntimeError as exc:
        return {"decision": "REJECTED", "reason": "candidate_freeze_failed: %s" % exc}
    # Ensure the frozen tip is available in the project object store (same repo /
    # shared objects via worktree).
    if promotion_core._git(proj, "cat-file", "-e", "%s^{commit}" % commit).returncode != 0:
        return {"decision": "REJECTED", "reason": "candidate_commit_not_in_project"}
    actual_tree = promotion_core.object_tree(proj, commit)
    if actual_tree != tree:
        return {"decision": "REJECTED", "reason": "object_inconsistent"}
    if not promotion_core.is_ancestor(proj, base, commit) and base != commit:
        return {"decision": "REJECTED", "reason": "base_not_ancestor_of_candidate"}
    if not promotion_core.is_ancestor(proj, entry["target_oid"], commit) and entry["target_oid"] != commit:
        return {"decision": "REJECTED", "reason": "target_not_ancestor_of_candidate"}
    rejected = promotion_core.classify_tree(proj, base, tree, wt)
    if rejected:
        reasons = sorted({r["reject"] for r in rejected})
        return {"decision": "REJECTED", "reason": "rejected_changes: " + ",".join(reasons)}
    entry["approved_tree"] = tree
    entry["approved_commit"] = commit
    entry["verify_result"] = "PASS"
    return {"decision": "RECORDED", "task_id": task_id, "approved_tree": tree, "approved_commit": commit}


def _check_object(entry: dict) -> dict:
    if not entry.get("approved_tree") or not entry.get("approved_commit"):
        return {"decision": "REJECTED", "reason": "candidate_not_recorded"}
    proj, commit, tree = entry["project"], entry["approved_commit"], entry["approved_tree"]
    actual = promotion_core.object_tree(proj, commit)
    if actual is None:
        return {"decision": "REJECTED", "reason": "object_missing"}
    if actual != tree:
        return {"decision": "REJECTED", "reason": "object_inconsistent"}
    return {"decision": "VALIDATED", "approved_tree": tree, "approved_commit": commit}


def handle_request(request: dict, peer_uid: int, regdir: str, lock_fd: int) -> dict:
    op = request.get("op")
    if op not in OPS:
        return {"decision": "REJECTED", "reason": "unsupported_op"}
    if op == "status":
        registry = _load_registry(regdir)
        return {"decision": "OK", "registered": len(registry),
                "recorded": sum(1 for e in registry.values() if e.get("approved_commit"))}
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
        if peer_uid not in requester_uids():
            return {"decision": "REJECTED", "reason": "unauthorized_requester"}
        task_id = request.get("task_id")
        entry = registry.get(task_id) if isinstance(task_id, str) else None
        if not entry:
            return {"decision": "REJECTED", "reason": "task_not_registered"}
        verdict = _check_object(entry)
        verdict["task_id"] = task_id
        if op == "validate" or verdict["decision"] != "VALIDATED":
            return verdict
        target_ref = entry.get("target_ref")
        target_oid = entry.get("target_oid")
        if not target_ref or not target_oid:
            return {"decision": "REJECTED", "reason": "target_not_bound", "task_id": task_id}
        # Production entry-bind gate (server-side; not only aegl-task client).
        gate = require_entry_binds_before_apply()
        if gate is not None:
            gate["task_id"] = task_id
            return gate
        # Apply the EXACT approved commit onto the bound ref — no worktree re-read,
        # no branch name, no checkout of the formal tree.
        applied = promotion_core.apply_to_ref(
            entry["project"], entry["approved_commit"], target_ref, target_oid, task_id)
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
    return {"APPLIED": 0, "VALIDATED": 0, "OK": 0, "REGISTERED": 0, "RECORDED": 0}.get(
        decision, 3 if decision == "REJECTED" else 4)


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
