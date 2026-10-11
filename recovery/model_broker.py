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
import socket
import ssl
import sys
import urllib.parse

DEFAULT_AUTH_HEADER = "Authorization"
DEFAULT_AUTH_PREFIX = "Bearer "


def _load_credential(env_name: str, path: str) -> str:
    """Read the credential from the EXISTING env var, else an explicit file.

    Never printed, never written to the trial directory. The trusted component reads it
    at its original location only.
    """
    if env_name and os.environ.get(env_name, "").strip():
        return os.environ[env_name].strip()
    if path and os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as handle:
            value = handle.read().strip()
        if value:
            return value
    raise SystemExit("model broker: no credential (set %s or pass --credential-file)" % env_name)


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

    url = urllib.parse.urlsplit(upstream)
    base_path = url.path.rstrip("/")
    # join without duplicating a shared prefix (avoid e.g. /v1/v1/...)
    if base_path and (path == base_path or path.startswith(base_path + "/")):
        target = path
    else:
        target = (base_path + path) if base_path else path
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
        payload = resp.read()
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
    p.add_argument("--credential-env", default="COMMANDCODE_API_KEY")
    p.add_argument("--auth-header", default=DEFAULT_AUTH_HEADER)
    args = parser.parse_args(argv)
    credential = _load_credential(args.credential_env, args.credential_file)
    if args.auth_header.lower() == "authorization":
        credential = credential if credential.lower().startswith(("bearer ", "token ")) else DEFAULT_AUTH_PREFIX + credential
    return serve(args.socket, args.upstream, credential, args.auth_header)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
