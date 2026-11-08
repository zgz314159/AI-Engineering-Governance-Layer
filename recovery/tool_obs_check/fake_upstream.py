#!/usr/bin/env python3
"""Synthetic model upstream for the isolated tool-observation check.

It never contacts a real model service, never reads credentials and returns only fixed,
harmless tool calls.

It speaks the request protocol the real client uses:
  * ``GET /v1/models`` (catalog probe) returns a fixed JSON catalog and never advances
    the scenario.
  * ``POST /v1/chat/completions`` with ``stream`` false returns a complete Chat
    Completions JSON object; with ``stream`` true it returns a real ``text/event-stream``
    (tool-call deltas with index/id/name and fragmented ``arguments``, a final
    ``finish_reason`` chunk and ``data: [DONE]``).
  * Any other method/path returns a fixed JSON error, never the default HTML error page.

The scenario step is derived from the conversation in the request (how many completed
tool calls it already carries), so repeated identical requests replay the same step
instead of skipping an unfinished one, and probes never consume a step.

Modes:
  main              success command, non-zero-exit command, guard-blocked scratch write
  observer-failure  worktree write (allowed, must execute), guard-blocked scratch write

CLI: fake_upstream.py --port-file PATH --block-path ABS
                       [--mode main|observer-failure] [--alive-path ABS]
                       [--cert PEM --key PEM]
Writes the chosen 127.0.0.1 port to --port-file, then serves until killed.
Without --cert/--key it serves plain HTTP (used by the local protocol test).
"""

from __future__ import annotations

import argparse
import http.server
import json
import ssl
import sys

MODEL_ID = "obs-check"
TOOL_NAME = "terminal"


def _scenario(mode: str, block_path: str, alive_path: str) -> list[tuple[str, str]]:
    if mode == "observer-failure":
        return [
            ("obs-alive", "sh -c 'printf alive > %s'" % alive_path),
            ("obs-block2", "sh -c 'printf blocked > %s'" % block_path),
        ]
    return [
        ("obs-ok", "printf OBS_OK"),
        ("obs-fail", "sh -c 'exit 7'"),
        ("obs-block", "sh -c 'printf blocked > %s'" % block_path),
    ]


def _step_index(messages: list) -> int:
    """Completed tool turns carried by the request: repeats replay the same step."""
    assistant = 0
    results = 0
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if role == "assistant" and message.get("tool_calls"):
            assistant += 1
        elif role == "tool":
            results += 1
    return max(assistant, results)


def _tool_call(call_id: str, command: str) -> dict:
    return {
        "id": call_id,
        "object": "chat.completion",
        "created": 0,
        "model": MODEL_ID,
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": call_id,
                    "type": "function",
                    "function": {"name": TOOL_NAME, "arguments": json.dumps({"command": command})},
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
        "model": MODEL_ID,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": "done"},
                     "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }


def _fragments(text: str) -> list[str]:
    """Split an argument string into deterministic pieces (at least one)."""
    size = len(text)
    if size < 3:
        return [text]
    first = max(1, size // 3)
    second = max(first + 1, (2 * size) // 3)
    return [text[:first], text[first:second], text[second:]]


def _chunk(delta: dict, finish: str | None) -> dict:
    return {
        "id": "obs-stream",
        "object": "chat.completion.chunk",
        "created": 0,
        "model": MODEL_ID,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }


def _sse_tool(call_id: str, command: str) -> list[dict]:
    pieces = _fragments(json.dumps({"command": command}))
    chunks = [_chunk({
        "role": "assistant",
        "content": None,
        "tool_calls": [{
            "index": 0,
            "id": call_id,
            "type": "function",
            "function": {"name": TOOL_NAME, "arguments": pieces[0]},
        }],
    }, None)]
    for piece in pieces[1:]:
        chunks.append(_chunk({
            "tool_calls": [{"index": 0, "function": {"arguments": piece}}],
        }, None))
    chunks.append(_chunk({}, "tool_calls"))
    return chunks


def _sse_text() -> list[dict]:
    return [
        _chunk({"role": "assistant", "content": "do"}, None),
        _chunk({"content": "ne"}, None),
        _chunk({}, "stop"),
    ]


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "obs-fake-upstream"
    sys_version = ""

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_sse(self, chunks: list[dict]) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode("utf-8"))
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def _send_error_json(self, status: int) -> None:
        self._send_json(status, {"error": {"message": "unsupported request",
                                           "type": "invalid_request_error",
                                           "code": "unsupported request"}})

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/v1/models", "/models"):
            self._send_json(200, {"object": "list", "data": [
                {"id": MODEL_ID, "object": "model", "created": 0, "owned_by": "obs"}]})
            return
        if path.startswith("/v1/models/") or path.startswith("/models/"):
            self._send_json(200, {"id": MODEL_ID, "object": "model", "created": 0,
                                  "owned_by": "obs"})
            return
        self._send_error_json(404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ("/v1/chat/completions", "/chat/completions"):
            self._send_error_json(404)
            return
        try:
            length = int(self.headers.get("content-length", 0))
        except ValueError:
            self._send_error_json(400)
            return
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send_error_json(400)
            return
        if not isinstance(body, dict):
            self._send_error_json(400)
            return
        messages = body.get("messages")
        if not isinstance(messages, list) or not messages:
            self._send_error_json(400)
            return
        steps = self.server.steps
        step = _step_index(messages)
        if step < len(steps):
            call_id, command = steps[step]
            if body.get("stream"):
                self._send_sse(_sse_tool(call_id, command))
            else:
                self._send_json(200, _tool_call(call_id, command))
            return
        if body.get("stream"):
            self._send_sse(_sse_text())
        else:
            self._send_json(200, _text())

    def do_PUT(self):
        self._send_error_json(405)

    def do_DELETE(self):
        self._send_error_json(405)

    def do_PATCH(self):
        self._send_error_json(405)

    def send_error(self, code, message=None, explain=None):
        try:
            self._send_error_json(code)
        except Exception:
            pass

    def log_message(self, *_args):
        pass


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert", default="")
    ap.add_argument("--key", default="")
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--block-path", required=True)
    ap.add_argument("--mode", choices=("main", "observer-failure"), default="main")
    ap.add_argument("--alive-path", default="")
    args = ap.parse_args(argv)
    if args.mode == "observer-failure" and not args.alive_path:
        raise SystemExit("observer-failure mode needs --alive-path")
    if bool(args.cert) != bool(args.key):
        raise SystemExit("--cert and --key must be given together")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.steps = _scenario(args.mode, args.block_path, args.alive_path)
    if args.cert:
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
