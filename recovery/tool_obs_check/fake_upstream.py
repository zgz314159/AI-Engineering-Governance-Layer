#!/usr/bin/env python3
"""Synthetic HTTPS model upstream for the isolated tool-observation check.

It never contacts a real model service, never reads credentials and returns only fixed,
harmless tool calls.

Modes:
  main              success command, non-zero-exit command, guard-blocked scratch write
  observer-failure  worktree write (allowed, must execute), guard-blocked scratch write

CLI: fake_upstream.py --cert PEM --key PEM --port-file PATH --block-path ABS
                       [--mode main|observer-failure] [--alive-path ABS]
Writes the chosen 127.0.0.1 port to --port-file, then serves until killed.
"""

from __future__ import annotations

import argparse
import http.server
import json
import ssl
import sys


def _tool_call(call_id: str, command: str) -> dict:
    return {
        "id": "obs-%s" % call_id,
        "object": "chat.completion",
        "created": 0,
        "model": "obs-check",
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": "obs-%s" % call_id,
                    "type": "function",
                    "function": {"name": "terminal", "arguments": json.dumps({"command": command})},
                }],
            },
            "finish_reason": "tool_calls",
        }],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }


def _text() -> dict:
    return {
        "id": "obs-final",
        "object": "chat.completion",
        "created": 0,
        "model": "obs-check",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": "done"},
                     "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        self.rfile.read(length)
        index = self.server.count
        self.server.count += 1
        if self.server.mode == "observer-failure":
            if index == 0:
                response = _tool_call("alive", "sh -c 'printf alive > %s'" % self.server.alive_path)
            elif index == 1:
                response = _tool_call("block2", "sh -c 'printf blocked > %s'" % self.server.block_path)
            else:
                response = _text()
        else:
            if index == 0:
                response = _tool_call("ok", "printf OBS_OK")
            elif index == 1:
                response = _tool_call("fail", "sh -c 'exit 7'")
            elif index == 2:
                response = _tool_call("block", "sh -c 'printf blocked > %s'" % self.server.block_path)
            else:
                response = _text()
        body = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--block-path", required=True)
    ap.add_argument("--mode", choices=("main", "observer-failure"), default="main")
    ap.add_argument("--alive-path", default="")
    args = ap.parse_args(argv)
    if args.mode == "observer-failure" and not args.alive_path:
        raise SystemExit("observer-failure mode needs --alive-path")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.count = 0
    server.mode = args.mode
    server.block_path = args.block_path
    server.alive_path = args.alive_path
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    with open(args.port_file, "w", encoding="utf-8") as fh:
        fh.write(str(server.server_address[1]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
