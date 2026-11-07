#!/usr/bin/env python3
"""Assert one specific guard-capture record from the real broker/guard path.

It correlates the record to the exact tool_call_id AND target basename of the request
under test, then checks the actual persisted guard_capture.run_guard structure:
verdict.action == block, guard rc == 2, _recorded == True, request correlation fields,
terminal operation/name, and no error/refusal. The broker sets evidence="appended" only
on the in-memory result AFTER guard_capture.record() returns, so the file record has no
evidence field; this assertion does not require one. Raw ids, target, arguments, stdout
and messages are never printed.

CLI: assert_guard_capture.py --capture PATH --call-id ID --target-basename NAME
                              [--task ID]
"""

from __future__ import annotations

import argparse
import json
import os
import sys


def _fail(reason: str) -> int:
    print("GUARD_CAPTURE=FAIL reason=%s" % reason)
    return 1


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", required=True)
    ap.add_argument("--call-id", required=True)
    ap.add_argument("--target-basename", required=True)
    ap.add_argument("--task", default="")
    args = ap.parse_args(argv)

    try:
        rows = [json.loads(line) for line in open(args.capture, encoding="utf-8") if line.strip()]
    except (OSError, ValueError):
        return _fail("capture_unreadable")

    matches = [r for r in rows
               if isinstance(r, dict)
               and str(r.get("tool_call_id") or "") == args.call_id
               and os.path.basename(str(r.get("target") or "")) == args.target_basename]
    if len(matches) != 1:
        return _fail("correlation_mismatch")
    rec = matches[0]

    verdict = rec.get("verdict")
    if isinstance(verdict, str):
        try:
            verdict = json.loads(verdict)
        except ValueError:
            verdict = None
    if not isinstance(verdict, dict) or verdict.get("action") != "block":
        return _fail("verdict_not_block")
    if rec.get("rc") != 2:
        return _fail("guard_rc_not_block")
    if rec.get("_recorded") is not True:
        return _fail("record_incomplete")
    if rec.get("request_matched") is not True:
        return _fail("request_not_matched")
    if rec.get("request_args_match") is not True:
        return _fail("request_args_not_matched")
    if rec.get("operation") != "terminal" or rec.get("request_name") != "terminal":
        return _fail("operation_mismatch")
    if rec.get("error"):
        return _fail("record_error")
    if rec.get("refused_reason"):
        return _fail("request_refused")
    if args.task and str(rec.get("task") or "") != args.task:
        return _fail("task_mismatch")

    print("GUARD_CAPTURE=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
