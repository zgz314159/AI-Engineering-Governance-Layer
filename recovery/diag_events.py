#!/usr/bin/env python3
"""AEGL diagnostic event sink (BRIDGE-DIAG-003) — minimal, monotonic, non-sensitive.

One JSON line per phase is appended to ``$AEGL_DIAG_DIR/events.jsonl`` with a
SYSTEM-WIDE monotonic timestamp (``time.monotonic_ns()``), so the sandbox, the model
broker and any other process on this host can be ordered on one clock regardless of
wall-clock changes.

Only whitelisted, non-sensitive fields are ever written:

    task   — the task id (or $AEGL_TASK)
    phase  — the stage label
    mono_ns— monotonic timestamp (ns)
    status — an integer status/code (HTTP status, guard rc, ...)
    bytes  — an integer byte count
    error  — a short exception type / error name
    arg    — a SHORT label (HTTP method+path, tool name, verdict action)

Request/response bodies, headers, credentials and the environment are NEVER written.
If ``$AEGL_DIAG_DIR`` is unset the helper is a no-op, so it can never fire in a normal
run. ``emit()`` never raises and never blocks the caller.

CLI (for the shell launcher):
    diag_events.py --phase PHASE [--task ID] [--status N] [--bytes N] [--error NAME] [--arg LABEL]
"""

from __future__ import annotations

import json
import os
import sys
import time


def _record(phase, *, task=None, status=None, bytes_=None, error=None, arg=None) -> dict:
    rec = {"phase": str(phase or ""), "mono_ns": time.monotonic_ns()}
    name = task if task else os.environ.get("AEGL_TASK")
    if name:
        rec["task"] = str(name)
    if isinstance(status, int):
        rec["status"] = status
    if isinstance(bytes_, int) and bytes_ >= 0:
        rec["bytes"] = bytes_
    if error:
        rec["error"] = str(error)[:64]
    if arg:
        rec["arg"] = str(arg)[:200]
    return rec


def emit(phase, *, task=None, status=None, bytes_=None, error=None, arg=None, dir_=None) -> None:
    directory = dir_ or os.environ.get("AEGL_DIAG_DIR") or ""
    if not directory:
        return
    line = json.dumps(_record(phase, task=task, status=status, bytes_=bytes_,
                              error=error, arg=arg), ensure_ascii=False) + "\n"
    try:
        fd = os.open(os.path.join(directory, "events.jsonl"),
                     os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


def main(argv) -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", required=True)
    ap.add_argument("--task", default="")
    ap.add_argument("--status", type=int, default=None)
    ap.add_argument("--bytes", dest="bytes_", type=int, default=None)
    ap.add_argument("--error", default="")
    ap.add_argument("--arg", default="")
    a = ap.parse_args(argv)
    emit(a.phase, task=a.task, status=a.status, bytes_=a.bytes_, error=a.error, arg=a.arg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
