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
import itertools
import json
import os
import re
import socket
import ssl
import sys
import urllib.parse

try:  # BRIDGE-DIAG-003: structured, non-sensitive phase events; never breaks the broker
    import diag_events as _diag
except Exception:  # noqa: BLE001
    _diag = None


def _ev(phase, **kw) -> None:
    if _diag is None:
        return
    try:
        _diag.emit(phase, **kw)
    except Exception:  # noqa: BLE001 - diagnostics must never disturb the data path
        pass


DEFAULT_AUTH_HEADER = "Authorization"
DEFAULT_AUTH_PREFIX = "Bearer "

# Native local model-server probe paths (LM Studio / Ollama / llama.cpp / vLLM). They are
# NOT OpenAI-compatible endpoints: they are answered LOCALLY with a plain 404 (no model
# catalog, no fake 200, no context length, no server-type hint, no credential, no upstream
# connection), so a startup probe can never block the task. The real catalog `/v1/models`
# is deliberately NOT here, and `/api/v1/models` is never rewritten to `/v1/models`.
LOCAL_PROBE_PATHS = frozenset({
    "/api/v1/models",
    "/api/tags",
    "/v1/props",
    "/props",
    "/version",
})


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

# Content-free request sequence numbers (BRIDGE-DIAG-003): the broker is single-threaded, so
# a monotonic counter per request kind lets the reader locate the LAST incomplete request.
_MODEL_REQ_SEQ = itertools.count(1)
_GUARD_REQ_SEQ = itertools.count(1)


def _record_request(call_id, name, arguments) -> None:
    """Store one assembled tool call; arguments are parsed only after full assembly."""
    parsed = None
    if arguments:
        try:
            parsed = json.loads(arguments)
        except ValueError:
            parsed = None
    REQUEST_INDEX[call_id] = {"name": name or "", "args": parsed if isinstance(parsed, dict) else None,
                              "assembled": bool(arguments)}


def _index_requests(payload: bytes) -> None:
    """Store the tool requests the UPSTREAM MODEL really returned.

    A normal response is parsed as structured JSON. An SSE response is accumulated per
    (choice index, tool_call index) — id, function name and argument fragments are joined in
    order and the arguments are parsed only once assembled; no cross-fragment regex guessing.
    """
    text = payload.decode("utf-8", "replace")
    stripped = text.lstrip()
    if stripped.startswith("{"):
        try:
            data = json.loads(text)
        except ValueError:
            return
        for choice in data.get("choices") or []:
            message = choice.get("message") or {}
            for call in message.get("tool_calls") or []:
                function = call.get("function") or {}
                if call.get("id"):
                    _record_request(call["id"], function.get("name"), function.get("arguments"))
        return

    # SSE: accumulate deltas by (choice index, tool index)
    acc = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        chunk = line[5:].strip()
        if not chunk or chunk == "[DONE]":
            continue
        try:
            data = json.loads(chunk)
        except ValueError:
            continue
        for choice in data.get("choices") or []:
            for delta in (choice.get("delta") or {}).get("tool_calls") or []:
                key = (choice.get("index", 0), delta.get("index", 0))
                slot = acc.setdefault(key, {"id": "", "name": "", "args": ""})
                if delta.get("id"):
                    slot["id"] = delta["id"]
                function = delta.get("function") or {}
                if function.get("name"):
                    slot["name"] += function["name"]
                if function.get("arguments"):
                    slot["args"] += function["arguments"]
    for slot in acc.values():
        if slot["id"]:
            _record_request(slot["id"], slot["name"], slot["args"])


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
    guard_seq = next(_GUARD_REQ_SEQ)
    _ev("guard_call", seq=guard_seq, arg=str(payload.get("tool_name") or ""))
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
    raw_target = str(tool_input.get("path") or "")
    if not raw_target:
        match = re.search(r">>?\s*['\"]?([^\s'\"]+)", str(tool_input.get("command") or ""))
        raw_target = match.group(1) if match else ""
    result["target"] = os.path.normpath(raw_target) if raw_target else ""
    # STRICT, fail-closed correlation with a REAL model tool request: id, name and the FULL
    # argument values must all agree; a missing/unparsable/mismatching request refuses the tool.
    request = REQUEST_INDEX.get(result["tool_call_id"]) if result["tool_call_id"] else None
    result["request_matched"] = bool(request)
    result["request_name"] = str((request or {}).get("name") or "")
    result["request_args"] = (request or {}).get("args")
    args_match = False
    reason = ""
    if not result["tool_call_id"]:
        reason = "hook carried no tool_call_id"
    elif request is None:
        reason = "no such tool request from the model"
    elif result["request_name"] != result["operation"]:
        reason = "tool name mismatch (%s vs %s)" % (result["request_name"], result["operation"])
    elif request.get("args") is None:
        reason = "request arguments missing or unparsable"
    else:
        args_match = request["args"] == tool_input
        if not args_match:
            reason = "argument values differ from the model request"
    result["request_args_match"] = args_match
    if reason:
        result["refused_reason"] = reason
        result["rc"] = None            # refuse the tool: it never runs on an unproven request
        result["error"] = "request_correlation_failed"
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
    _ev("guard_verdict",
        seq=guard_seq,
        status=(result.get("rc") if isinstance(result.get("rc"), int) else None),
        arg=str((result.get("verdict") or {}).get("action") or "") or None,
        error=result.get("error"))
    out = json.dumps(result, ensure_ascii=False).encode("utf-8")
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(out) + out)


def _answer_local_probe(conn: socket.socket, method: str, path_only: str) -> None:
    """Answer a native model-server probe LOCALLY, honestly: 404, no upstream, no credential."""
    payload = json.dumps({
        "error": {
            "message": "endpoint not supported by this server",
            "type": "unsupported_endpoint",
            "param": None,
            "code": None,
        }
    }, separators=(",", ":")).encode("utf-8")
    head = (
        "HTTP/1.1 404 Not Found\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n\r\n" % len(payload)
    ).encode("latin-1")
    try:
        conn.sendall(head + payload)
    except OSError:
        pass
    print("AEGL_MODEL_ROUTE method=%s in=%s fwd=LOCAL_UNSUPPORTED status=404"
          % (method, path_only), flush=True)


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

    # native model-server probes are answered locally and NEVER reach the upstream
    probe_path = path.split("?", 1)[0]
    if probe_path in LOCAL_PROBE_PATHS:
        _answer_local_probe(conn, method, probe_path)
        return

    req_seq = next(_MODEL_REQ_SEQ)
    _ev("broker_req_recv", seq=req_seq, arg="%s %s" % (method, path.split("?", 1)[0]))

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
        _ev("upstream_req_start", seq=req_seq, arg=target)
        up.request(method, target, body=body if body else None, headers=fwd)
        resp = up.getresponse()
        _ev("upstream_resp_headers", seq=req_seq, status=resp.status)
        # minimal routing record: method, inbound path, forwarded path, status ONLY
        print("AEGL_MODEL_ROUTE method=%s in=%s fwd=%s status=%d" % (method, path, target, resp.status), flush=True)
        payload = resp.read()
        _ev("upstream_body_read_done", seq=req_seq, status=resp.status, bytes_=len(payload))
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
        _ev("client_handoff_done", seq=req_seq, status=resp.status, bytes_=len(payload))
    except Exception as exc:  # noqa: BLE001 — log the route only, never the message/headers/body
        _ev("upstream_error", seq=req_seq, error=type(exc).__name__)
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
