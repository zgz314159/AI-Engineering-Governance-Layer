#!/usr/bin/env python3
"""Assert the isolated check's diagnostic sink from the REAL sandbox run.

Only fixed structural fields are inspected. It never prints model content, tool args,
stdout/stderr or raw ids — and fails if any of them leaked into the sink.

CLI: assert_observation.py --events PATH --forbidden PATH [--fixture PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

FORBIDDEN_FRAGMENTS = ("OBS_OK", "exit 7", "guard-blocked", "obs-ok", "obs-fail", "obs-block")


def load_events(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", required=True)
    ap.add_argument("--forbidden", required=True)
    ap.add_argument("--fixture", default="")
    args = ap.parse_args(argv)

    errors = []
    rows = load_events(args.events)
    model = [r for r in rows if r.get("phase") == "model_response"]
    requests = [r for r in rows if r.get("phase") == "model_tool_request"]
    pre = [r for r in rows if r.get("phase") == "tool_pre_observe"]
    post = [r for r in rows if r.get("phase") == "tool_post_observe"]

    if not model or not any("tool_call" in str(r.get("arg")) for r in model):
        errors.append("no model_response with tool_call")
    if len(requests) != 3:
        errors.append("model_tool_request count %d != 3" % len(requests))
    if any("tool=terminal" not in str(r.get("arg")) for r in requests):
        errors.append("model_tool_request not terminal")
    if len(pre) != 3 or len(post) != 3:
        errors.append("tool pre/post count %d/%d != 3/3" % (len(pre), len(post)))
    for row in pre + post:
        arg = str(row.get("arg") or "")
        if "corr=1" not in arg or "trust=diagnostic" not in arg or "tool=terminal" not in arg:
            errors.append("unexpected observe arg")
            break
    expected_post = [("status=OK", "exit=0"), ("status=ERROR", "exit=7"),
                     ("status=BLOCKED", "exit=UNKNOWN")]
    for row, (status, exit_code) in zip(post, expected_post):
        arg = str(row.get("arg") or "")
        if status not in arg or exit_code not in arg:
            errors.append("post sequence mismatch")
            break
    request_seqs = {r.get("seq") for r in requests}
    observe_seqs = {r.get("seq") for r in pre + post}
    if request_seqs != observe_seqs or None in request_seqs:
        errors.append("controller sequence correlation mismatch")
    if os.path.exists(args.forbidden):
        errors.append("guard-blocked file exists")
    raw = open(args.events, encoding="utf-8").read()
    for fragment in FORBIDDEN_FRAGMENTS:
        if fragment in raw:
            errors.append("sink leaked %s" % fragment)
            break
    if args.fixture and args.fixture in raw:
        errors.append("sink leaked the fixture path")

    if errors:
        for error in errors:
            print("OBS_ASSERT=FAIL reason=%s" % error)
        return 1
    print("OBS_ASSERT=PASS pre=%d post=%d requests=%d" % (len(pre), len(post), len(requests)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
