#!/usr/bin/env python3
"""In-sandbox diagnostic pre/post tool observer client.

OBSERVER ONLY. It never blocks, modifies arguments, prints a directive, retries or leaves
a background process. It forwards a fixed scalar subset of the Hermes hook payload to the
trusted controller socket; the controller stores controller numeric ids and fixed classes.
The full tool_call_id is sent only for in-memory correlation; it is never persisted.
Bodies, args, results, stdout/stderr, error messages, headers and credentials never leave
this process. Any failure (missing socket, timeout, bad reply) is silent and exits 0, so a
missing observation stays UNKNOWN rather than looking complete.

CLI: tool_event_client.py --socket PATH --event pre_tool_call|post_tool_call [--timeout S]
"""

from __future__ import annotations

import argparse
import json
import socket
import sys


def _picked(payload: dict, extra: dict, key: str):
    """Promoted top-level when present, else the pinned wire's ``extra`` bag."""
    value = payload.get(key)
    if value is None or value == "":
        value = extra.get(key)
    return value


def _exit_code(extra: dict):
    """Only an integer exit_code from a terminal-style result; never the body itself."""
    result = extra.get("result") if isinstance(extra, dict) else None
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except ValueError:
            return None
    if isinstance(result, dict):
        value = result.get("exit_code")
        if isinstance(value, int) and not isinstance(value, bool):
            return value
    return None


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--event", required=True, choices=("pre_tool_call", "post_tool_call"))
    ap.add_argument("--timeout", type=float, default=0.5)
    args = ap.parse_args(argv)

    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:  # noqa: BLE001 - observation must never disturb the tool
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    seen_event = str(payload.get("hook_event_name") or "")
    if seen_event and seen_event != args.event:
        return 0

    extra = payload.get("extra") if isinstance(payload.get("extra"), dict) else {}
    # Pinned Hermes wire (agent/shell_hooks.py::_payload_fields): only tool_name, tool_input,
    # session_id and cwd are promoted; tool_call_id/status/error_type/duration_ms/result are
    # under `extra`. Read both so the client stays correct if a field is ever promoted.
    duration = _picked(payload, extra, "duration_ms")
    message = {
        "hook_event_name": args.event,
        "tool_call_id": str(_picked(payload, extra, "tool_call_id") or ""),
        "tool_name": str(payload.get("tool_name") or ""),
        "status": str(_picked(payload, extra, "status") or ""),
        "error_type": str(_picked(payload, extra, "error_type") or ""),
        "duration_ms": duration if isinstance(duration, int) and not isinstance(duration, bool) else None,
    }
    exit_code = _exit_code(extra)
    if exit_code is not None:
        message["exit_code"] = exit_code

    body = json.dumps(message, ensure_ascii=False).encode("utf-8")
    request = ("POST /tool-event HTTP/1.1\r\nHost: aegl-controller\r\n"
               "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)).encode("utf-8") + body
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(max(0.05, float(args.timeout)))
    try:
        sock.connect(args.socket)
        sock.sendall(request)
        try:
            while sock.recv(4096):
                pass
        except OSError:
            pass
    except OSError:
        pass
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001 - never surface anything to the tool path
        raise SystemExit(0)
