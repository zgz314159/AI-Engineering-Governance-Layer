#!/usr/bin/env python3
"""AEGL model broker — trusted egress + credential handoff for a sandboxed Hermes.

The broker runs OUTSIDE the sandbox on a Unix socket. It is the only component that
holds a model credential (read from a root-owned file) and the only one with network
egress. A sandboxed client reaches it through a bound Unix socket; the broker rewrites
the request to the real provider endpoint and injects the credential. The sandboxed
process never sees the credential and cannot open a direct external connection.

    serve  --socket <unix> --upstream <https base> --credential-file <path> [--auth-header NAME]
    client --socket <unix> --path /v1/models [--method GET] [--data ...]   # manual probe

stdlib only. The credential value is read once and never logged.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import socket
import ssl
import sys
import urllib.parse

DEFAULT_AUTH_HEADER = "Authorization"
DEFAULT_AUTH_PREFIX = "Bearer "


def _parse_dotenv_data(path: str, name: str) -> str:
    """Read ``NAME=value`` from a file as DATA — never sourced or eval'd.

    No shell syntax, no command substitution, no expansion: the file is opened and
    scanned line by line; only a literal ``NAME=`` line is honoured.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return ""
    for line in lines:
        text = line.strip()
        if not text or text.startswith("#") or "=" not in text:
            continue
        key, _, value = text.partition("=")
        key = key.strip()
        if key.startswith("export "):
            key = key[len("export "):].strip()
        if key != name:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if value:
            return value
    return ""


def _load_credential(env_name: str, source_file: str, path: str) -> str:
    """Credential from the env, else the EXISTING source file parsed as data.

    Never printed, never written to the trial directory, and never executed.
    """
    if env_name and os.environ.get(env_name, "").strip():
        return os.environ[env_name].strip()
    if source_file:
        value = _parse_dotenv_data(source_file, env_name or "COMMANDCODE_API_KEY")
        if value:
            return value
    if path and os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as handle:
            value = handle.read().strip()
        if value:
            return value
    raise SystemExit("model broker: no credential (env %s / source %s)" % (env_name, source_file or "-"))


def _read_headers(conn: socket.socket) -> tuple:
    data = b""
    while b"\r\n\r\n" not in data and b"\n\n" not in data and len(data) < 1 << 20:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
    if b"\r\n\r\n" in data:
        head, _, rest = data.partition(b"\r\n\r\n")
    else:
        head, _, rest = data.partition(b"\n\n")
    return head.decode("latin-1"), rest


def _map_path(base_path: str, path: str) -> str:
    """Map the client's local ``/v1`` API prefix onto the upstream base path.

    The sandbox talks to ``<base_url>/v1/...`` (what the provider SDK appends); the broker's
    fixed upstream already carries its own API base (e.g. ``/provider/v1``). A blind join
    produced ``/provider/v1/v1/chat/completions``. Here the ``/v1`` prefix is REPLACED by the
    upstream base path — no global replace, and the upstream host is never taken from the
    request.
    """
    if not base_path:
        return path
    local = "/v1"
    if path == local or path.startswith(local + "/"):
        return base_path + path[len(local):]
    if path == base_path or path.startswith(base_path + "/"):
        return path
    return base_path + path


# The broker remembers the tool requests the UPSTREAM MODEL actually returned, so a hook's
# tool_call_id/name/args can be correlated with a real model request instead of trusting a
# non-empty id. Populated from the model response body (plain JSON or SSE deltas).
REQUEST_INDEX: dict = {}


def _index_requests(payload: bytes) -> None:
    text = payload.decode("utf-8", "replace")
    for match in re.finditer(r'"id"\s*:\s*"(call_[^"]+)"', text):
        REQUEST_INDEX.setdefault(match.group(1), {"name": "", "args": None})
    for match in re.finditer(r'"id"\s*:\s*"(call_[^"]+)"[\s\S]{0,400}?"name"\s*:\s*"([^"]*)"', text):
        REQUEST_INDEX.setdefault(match.group(1), {"name": "", "args": None})["name"] = match.group(2)
    for match in re.finditer(r'"id"\s*:\s*"(call_[^"]+)"[\s\S]{0,800}?"arguments"\s*:\s*"((?:[^"\\]|\\.)*)"', text):
        try:
            REQUEST_INDEX.setdefault(match.group(1), {"name": "", "args": None})["args"] = json.loads('"%s"' % match.group(2))
        except ValueError:
            pass


def _handle_guard(conn: socket.socket, body: bytes) -> None:
    """Controller-side pre_tool_call evaluation: run the guard OURSELVES and return its raw
    stdout + exit code. The AI cannot influence this (its log/socket/self-report is ignored)."""
    import guard_capture  # same directory as this module
    try:
        payload = json.loads(body.decode("utf-8") or "{}")
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    guard = os.environ.get("AEGL_GUARD_PATH") or ""
    try:
        runner = json.loads(os.environ.get("AEGL_GUARD_RUNNER") or "")
    except ValueError:
        runner = []
    if not guard or not isinstance(runner, list) or not runner:
        # no verified guard copy or no fixed unprivileged runner -> FAIL CLOSED
        result = {"rc": None, "stdout": "", "verdict": None,
                  "error": "no_guard_configured" if not guard else "no_runner_configured"}
    else:
        result = guard_capture.run_guard(guard, payload, runner=runner)
    result["task"] = os.environ.get("AEGL_TASK", "")
    result["tool_call_id"] = guard_capture.tool_call_id(payload)   # top level OR extra
    result["operation"] = str(payload.get("tool_name") or "")
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    result["target"] = str(tool_input.get("path") or tool_input.get("command") or "")[:200]
    request = REQUEST_INDEX.get(result["tool_call_id"]) if result["tool_call_id"] else None
    result["request_matched"] = bool(request)
    result["request_name"] = (request or {}).get("name") or ""
    match = None
    if request and request.get("args"):
        try:
            want = set(json.loads(request["args"]).keys())
            match = want == set(tool_input.keys())
        except (ValueError, TypeError):
            match = None
    result["request_args_match"] = match
    evidence = os.environ.get("AEGL_GUARD_EVIDENCE") or ""
    if evidence:
        try:
            ai_uid = int(os.environ.get("AEGL_GUARD_AI_UID") or "-1")
            ai_gid = int(os.environ.get("AEGL_GUARD_AI_GID") or "-1")
        except ValueError:
            ai_uid = ai_gid = -1
        status = guard_capture.record(evidence, ai_uid, ai_gid, result)
        result["evidence"] = status
        if status != "appended":
            result["error"] = "evidence_not_recorded:%s" % status
            result["rc"] = None        # an unrecorded verdict must never allow the tool
    out = json.dumps(result, ensure_ascii=False).encode("utf-8")
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(out) + out)


def _handle(conn: socket.socket, upstream: str, credential: str, auth_header: str) -> None:
    head, body = _read_headers(conn)
    lines = head.split("\r\n") if "\r\n" in head else head.split("\n")
    if not lines or not lines[0]:
        return
    parts = lines[0].split()
    if len(parts) < 2:
        return
    method, path = parts[0], parts[1]
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            key, _, val = line.partition(":")
            headers[key.strip().lower()] = val.strip()
    if "content-length" in headers:
        need = int(headers["content-length"])
        while len(body) < need:
            chunk = conn.recv(65536)
            if not chunk:
                break
            body += chunk
        body = body[:need]

    # the trusted controller ALSO answers pre_tool_call evaluations on this same socket
    if path.split("?")[0] == "/guard":
        _handle_guard(conn, body)
        return

    url = urllib.parse.urlsplit(upstream)
    base_path = url.path.rstrip("/")
    # separate the query BEFORE mapping so it is preserved verbatim
    path_only, qsep, query = path.partition("?")
    target = _map_path(base_path, path_only) + (qsep + query if qsep else "")
    if url.scheme == "https":
        ctx = ssl.create_default_context()
        up = http.client.HTTPSConnection(url.hostname, url.port or 443, context=ctx, timeout=120)
    else:
        up = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=120)
    fwd = {k: v for k, v in headers.items() if k not in ("host", "connection", "content-length", "authorization")}
    fwd["Host"] = url.hostname
    if auth_header.lower() == "authorization":
        fwd["Authorization"] = credential
    else:
        fwd[auth_header] = credential
    fwd["Connection"] = "close"
    try:
        up.request(method, target, body=body if body else None, headers=fwd)
        resp = up.getresponse()
        # minimal routing record: method, inbound path, forwarded path, status ONLY
        print("AEGL_MODEL_ROUTE method=%s in=%s fwd=%s status=%d" % (method, path, target, resp.status), flush=True)
        payload = resp.read()
        _index_requests(payload)
        out = ["HTTP/1.1 %d %s" % (resp.status, resp.reason)]
        for k, v in resp.getheaders():
            if k.lower() in ("transfer-encoding", "connection", "content-length"):
                continue
            out.append("%s: %s" % (k, v))
        out.append("Content-Length: %d" % len(payload))
        out.append("Connection: close")
        out.append("")
        out.append("")
        conn.sendall("\r\n".join(out).encode("latin-1") + payload)
    except Exception as exc:  # noqa: BLE001 — log the route only, never the message/headers/body
        print("AEGL_MODEL_ROUTE method=%s in=%s fwd=%s status=ERROR %s"
              % (method, path, target, type(exc).__name__), flush=True)
        raise
    finally:
        try:
            up.close()
        except Exception:  # noqa: BLE001
            pass


def serve(sock_path: str, upstream: str, credential: str, auth_header: str) -> int:
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    os.chmod(sock_path, 0o600)
    server.listen(16)
    print("AEGL_MODEL_BROKER listening=%s upstream=%s auth_header=%s" % (sock_path, upstream, auth_header), flush=True)
    try:
        while True:
            conn, _ = server.accept()
            try:
                _handle(conn, upstream, credential, auth_header)
            except Exception as exc:  # noqa: BLE001 - never take the broker down
                try:
                    conn.sendall(("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").encode())
                except OSError:
                    pass
                sys.stderr.write("model broker error: %s\n" % type(exc).__name__)
            finally:
                conn.close()
    finally:
        server.close()
        try:
            os.unlink(sock_path)
        except OSError:
            pass
    return 0


def main(argv):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("serve")
    p.add_argument("--socket", required=True)
    p.add_argument("--upstream", required=True)
    p.add_argument("--credential-file", default="")
    p.add_argument("--credential-source", default="")
    p.add_argument("--credential-env", default="COMMANDCODE_API_KEY")
    p.add_argument("--auth-header", default=DEFAULT_AUTH_HEADER)
    args = parser.parse_args(argv)
    credential = _load_credential(args.credential_env, args.credential_source, args.credential_file)
    if args.auth_header.lower() == "authorization":
        credential = credential if credential.lower().startswith(("bearer ", "token ")) else DEFAULT_AUTH_PREFIX + credential
    return serve(args.socket, args.upstream, credential, args.auth_header)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
