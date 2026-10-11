#!/usr/bin/env python3
"""Trusted CONTROLLER-side capture of the real pre_tool_call guard verdict.

The controller runs the GUARD ITSELF as a subprocess under a FIXED unprivileged runner,
feeds it the hook payload on stdin, and takes the guard's RAW stdout and exit code. It never
trusts anything the AI could write, and root never imports or in-lines user-writable code.

Fail-closed rules enforced here:
  * NO runner (or an unparseable runner spec) => refuse to run at all. Never fall back to
    running the guard with the broker's identity/credentials.
  * the guard runs with a minimal environment allowlist — it does not inherit the broker's
    credentials or its full environment.
  * if the evidence directory is not controller-private (or recording fails) the caller gets
    an explicit error and MUST block; it never returns an acceptable ALLOW.

CLI:
    guard_capture.py evaluate --guard PATH --runner ARG [--runner ARG ...] \
        [--evidence-dir DIR --ai-uid N --ai-gid N --task ID --operation OP --target TGT] < payload
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

# the guard needs the frozen contract path; nothing else is inherited
ENV_ALLOWLIST = ("HERMES_CONTRACT_PACKAGE",)


def tool_call_id(payload: dict) -> str:
    """Read the real tool-call id from the Hermes hook payload (top level or inside ``extra``)."""
    if not isinstance(payload, dict):
        return ""
    for key in ("tool_call_id", "call_id", "tool_use_id"):
        if payload.get(key):
            return str(payload[key])
    extra = payload.get("extra")
    if isinstance(extra, dict):
        for key in ("tool_call_id", "call_id", "tool_use_id", "id"):
            if extra.get(key):
                return str(extra[key])
    return ""


def run_guard(guard: str, payload: dict, runner=(), timeout: float = 20.0) -> dict:
    """Run the guard under the fixed runner and return its RAW return code and stdout."""
    if not runner:
        return {"rc": None, "stdout": "", "verdict": None, "error": "no_runner_configured"}
    env = {"PATH": "/usr/bin:/bin"}
    for key in ENV_ALLOWLIST:
        if key in os.environ:
            env[key] = os.environ[key]
    cmd = [*runner, sys.executable, guard]
    try:
        proc = subprocess.run(cmd, input=json.dumps(payload).encode("utf-8"),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
                              env=env)
    except subprocess.TimeoutExpired:
        return {"rc": None, "stdout": "", "verdict": None, "error": "guard_timeout"}
    except OSError as exc:
        return {"rc": None, "stdout": "", "verdict": None,
                "error": "guard_exec_failed:%s" % type(exc).__name__}
    out = proc.stdout.decode("utf-8", "replace")
    try:
        verdict = json.loads(out) if out.strip() else None
    except ValueError:
        verdict = None
    return {"rc": proc.returncode, "stdout": out, "verdict": verdict, "error": None}


def _unsafe(mode: int, uid: int, gid: int, ai_uid: int, ai_gid: int) -> bool:
    """True when the AI identity could add/replace/remove entries in this directory."""
    if uid == ai_uid:
        return True                                   # owned by the AI
    if (mode & 0o020) and gid == ai_gid:
        return True                                   # group-writable by the AI's group
    if mode & 0o002:                                  # other-writable
        return not (mode & 0o1000)                    # only a sticky dir resists replacement
    return False


def evidence_dir_is_trusted(evidence_dir: str, ai_uid: int, ai_gid: int) -> bool:
    """The evidence dir AND its whole ancestor chain must be safe from the AI identity."""
    path = os.path.abspath(evidence_dir)
    if not os.path.isdir(path):
        return False
    current = path
    while True:
        try:
            st = os.stat(current)
        except OSError:
            return False
        if _unsafe(st.st_mode, st.st_uid, st.st_gid, ai_uid, ai_gid):
            return False
        parent = os.path.dirname(current)
        if parent == current:
            return True
        current = parent


def record(evidence_dir: str, ai_uid: int, ai_gid: int, entry: dict) -> str:
    """Append one evidence record; REFUSES unless the directory is controller-private.

    The terminal marker ``_recorded`` is written INTO the record itself, so a reader can tell a
    fully written line from a truncated one (setting the status only in the return value left
    the file without it, which made the acceptance ignore every record).
    """
    if not evidence_dir_is_trusted(evidence_dir, ai_uid, ai_gid):
        return "refused_untrusted_dir"
    payload = dict(entry)
    payload["_recorded"] = True
    line = json.dumps(payload, ensure_ascii=False)
    try:
        fd = os.open(os.path.join(evidence_dir, "guard-capture.jsonl"),
                     os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
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
    ap.add_argument("--ai-gid", type=int, default=-1)
    ap.add_argument("--task", default="")
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
    result["tool_call_id"] = tool_call_id(payload)
    result["operation"] = args.operation or str(payload.get("tool_name") or "")
    result["target"] = args.target
    result["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    if args.evidence_dir:
        status = record(args.evidence_dir, args.ai_uid, args.ai_gid, result)
        result["evidence"] = status
        if status != "appended":
            # an unrecorded verdict is not acceptable evidence -> fail closed
            result["error"] = "evidence_not_recorded:%s" % status
            result["rc"] = None
    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0 if result.get("error") is None else 3


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
