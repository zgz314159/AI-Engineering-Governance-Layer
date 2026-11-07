#!/usr/bin/env python3
"""Exact structural assertion for the isolated observation sink.

Fixed fields are parsed and compared literally per controller call sequence; substring
matching is not used (exit=70 must never satisfy exit=7). Each expected model tool
request must have exactly one pre and one post observation, in order, with no extra,
duplicate, missing or uncorrelated events.

CLI: assert_observation.py --events PATH --forbidden PATH [--fixture PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

FORBIDDEN_FRAGMENTS = ("OBS_OK", "exit 7", "guard-blocked", "obs-ok", "obs-fail", "obs-block")


def _arg_fields(arg: str) -> dict:
    fields = {}
    for token in str(arg or "").split():
        if "=" in token:
            key, value = token.split("=", 1)
            fields[key] = value
    return fields


def _load(path: str) -> list:
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def _single_by_seq(rows, label, errors):
    by_seq = {}
    for row in rows:
        seq = row.get("seq")
        if not isinstance(seq, int) or isinstance(seq, bool):
            errors.append("%s has no integer sequence" % label)
            continue
        if seq in by_seq:
            errors.append("%s duplicate sequence" % label)
            continue
        by_seq[seq] = row
    return by_seq


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", required=True)
    ap.add_argument("--forbidden", required=True)
    ap.add_argument("--fixture", default="")
    args = ap.parse_args(argv)

    errors = []
    try:
        rows = _load(args.events)
    except (OSError, ValueError):
        print("OBS_ASSERT=FAIL reason=events_unreadable")
        return 1

    model = [r for r in rows if r.get("phase") == "model_response"]
    requests = [r for r in rows if r.get("phase") == "model_tool_request"]
    pre_rows = [r for r in rows if r.get("phase") == "tool_pre_observe"]
    post_rows = [r for r in rows if r.get("phase") == "tool_post_observe"]
    rejected = [r for r in rows if r.get("phase") == "tool_event_rejected"]
    duplicate = [r for r in rows if r.get("phase") == "tool_event_duplicate"]

    if not model or not any("tool_call" in _arg_fields(r.get("arg")).get("flags", "") for r in model):
        errors.append("model_response_missing_tool_call")

    expected = []
    for row in requests:
        fields = _arg_fields(row.get("arg"))
        seq = row.get("seq")
        if fields.get("tool") != "terminal":
            errors.append("request_not_terminal")
        if not isinstance(seq, int) or isinstance(seq, bool):
            errors.append("request_without_sequence")
            continue
        expected.append(seq)
    if len(expected) != 3:
        errors.append("request_count != 3")
    if len(set(expected)) != len(expected):
        errors.append("request_sequences_not_unique")

    pre_by_seq = _single_by_seq(pre_rows, "pre", errors)
    post_by_seq = _single_by_seq(post_rows, "post", errors)
    if len(pre_rows) != 3:
        errors.append("pre_count != 3")
    if len(post_rows) != 3:
        errors.append("post_count != 3")
    if rejected:
        errors.append("unexpected_rejected_events")
    if duplicate:
        errors.append("unexpected_duplicate_events")
    if set(pre_by_seq) != set(expected):
        errors.append("pre_sequences_mismatch")
    if set(post_by_seq) != set(expected):
        errors.append("post_sequences_mismatch")

    if [r.get("seq") for r in pre_rows] != expected:
        errors.append("pre_order_mismatch")
    if [r.get("seq") for r in post_rows] != expected:
        errors.append("post_order_mismatch")

    expect_post = [("OK", "0"), ("ERROR", "7"), ("BLOCKED", "UNKNOWN")]
    for index, seq in enumerate(expected):
        pre = pre_by_seq.get(seq)
        post = post_by_seq.get(seq)
        if pre is None or post is None:
            continue
        pf = _arg_fields(pre.get("arg"))
        qf = _arg_fields(post.get("arg"))
        if pf.get("when") != "pre" or qf.get("when") != "post":
            errors.append("observation_when_mismatch")
        if pf.get("corr") != "1" or qf.get("corr") != "1":
            errors.append("observation_not_correlated")
        if pf.get("tool") != "terminal" or qf.get("tool") != "terminal":
            errors.append("observation_tool_mismatch")
        if pf.get("src") != "hook" or pf.get("trust") != "diagnostic":
            errors.append("observation_trust_label_mismatch")
        if qf.get("src") != "hook" or qf.get("trust") != "diagnostic":
            errors.append("observation_trust_label_mismatch")
        want_status, want_exit = expect_post[index]
        if qf.get("status") != want_status:
            errors.append("post_status_mismatch")
        if qf.get("exit") != want_exit:
            errors.append("post_exit_mismatch")

    if os.path.exists(args.forbidden):
        errors.append("guard_blocked_file_exists")
    with open(args.events, encoding="utf-8") as fh:
        raw = fh.read()
    for fragment in FORBIDDEN_FRAGMENTS:
        if fragment in raw:
            errors.append("sink_leaked_forbidden_fragment")
            break
    if args.fixture and args.fixture in raw:
        errors.append("sink_leaked_fixture_path")

    if errors:
        for error in sorted(set(errors)):
            print("OBS_ASSERT=FAIL reason=%s" % error)
        return 1
    print("OBS_ASSERT=PASS requests=%d pre=%d post=%d" % (len(expected), len(pre_rows), len(post_rows)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
