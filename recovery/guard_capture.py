#!/usr/bin/env python3
"""Trusted CONTROLLER-side capture of the real pre_tool_call guard verdict.

The controller runs the GUARD ITSELF as a subprocess (typically as the unprivileged sandbox
identity via setpriv), feeds it the hook payload on stdin, and takes the guard's RAW stdout
and exit code. Nothing here trusts anything the AI could write:

  * the verdict does not come from an AI-writable log, a same-UID socket notification, or a
    client self-report — it is the guard process's own stdout + return code;
  * root never imports or in-lines user-writable project code: the guard is executed as
    data by a subprocess, and the caller supplies the restricted runner;
  * the evidence directory is controller-held — if it (or its parent) is writable by the
    sandbox identity, recording is REFUSED rather than silently trusted;
  * on any failure to run the guard, the result is an explicit failure the caller MUST turn
    into a BLOCK (fail closed) — never a silent skip.

CLI:
    guard_capture.py evaluate --guard PATH [--runner CMD ...] [--timeout N] \
        [--evidence-dir DIR --task ID --tool-call-id C --operation OP --target TGT] < payload
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

BLOCK_RC = 2


def run_guard(guard: str, payload: dict, runner=(), timeout: float = 20.0) -> dict:
    """Run the guard and return its RAW return code and stdout. Never raises."""
    # a restricted runner (e.g. setpriv ... --) execs the interpreter + guard directly
    cmd = [*runner, sys.executable, guard]
    try:
        proc = subprocess.run(cmd, input=json.dumps(payload).encode("utf-8"),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"rc": None, "stdout": "", "error": "guard_timeout"}
    except OSError as exc:
        return {"rc": None, "stdout": "", "error": "guard_exec_failed:%s" % type(exc).__name__}
    out = proc.stdout.decode("utf-8", "replace")
    verdict = None
    try:
        verdict = json.loads(out) if out.strip() else None
    except ValueError:
        verdict = None
    return {"rc": proc.returncode, "stdout": out, "verdict": verdict, "error": None}


def evidence_dir_is_trusted(evidence_dir: str, ai_uid: int) -> bool:
    """True only when the evidence dir and its parent chain are not writable by the AI uid."""
    path = os.path.abspath(evidence_dir)
    if not os.path.isdir(path):
        return False
    current = path
    while True:
        try:
            st = os.stat(current)
        except OSError:
            return False
        mode = st.st_mode
        if st.st_uid == ai_uid:
            return False
        write_bits = 0o222
        if mode & write_bits and (st.st_uid == ai_uid or st.st_gid == ai_uid):
            return False
        parent = os.path.dirname(current)
        if parent == current:
            return True
        current = parent


def record(evidence_dir: str, ai_uid: int, entry: dict) -> str:
    """Append one evidence record; REFUSES when the directory is not controller-held."""
    if not evidence_dir_is_trusted(evidence_dir, ai_uid):
        return "refused_untrusted_dir"
    line = json.dumps(entry, ensure_ascii=False)
    try:
        with open(os.path.join(evidence_dir, "guard-capture.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        return "refused_unwritable"
    return "appended"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["evaluate"])
    ap.add_argument("--guard", required=True)
    ap.add_argument("--runner", action="append", default=[], metavar="ARG")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--evidence-dir", default="")
    ap.add_argument("--ai-uid", type=int, default=-1)
    ap.add_argument("--task", default="")
    ap.add_argument("--tool-call-id", default="")
    ap.add_argument("--operation", default="")
    ap.add_argument("--target", default="")
    args = ap.parse_args(argv)

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    result = run_guard(args.guard, payload, runner=args.runner, timeout=args.timeout)
    result["task"] = args.task
    result["tool_call_id"] = args.tool_call_id or str(payload.get("tool_call_id") or "")
    result["operation"] = args.operation or str(payload.get("tool_name") or "")
    result["target"] = args.target
    result["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    if args.evidence_dir:
        ai_uid = args.ai_uid if args.ai_uid >= 0 else os.getuid()
        result["evidence"] = record(args.evidence_dir, ai_uid, result)
    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    # the CALLER decides the block; this exit only signals a capture-layer failure
    return 0 if result.get("error") is None else 3


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
