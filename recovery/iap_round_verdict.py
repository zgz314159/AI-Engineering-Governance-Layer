#!/usr/bin/env python3
"""iap_round_verdict.py — machine verdicts for one IAP S0 round and its acceptance.

`round` mode decides whether ONE campaign round actually completed. The campaign exits
with rc=3 for BOTH the normal LIMIT_REACHED stop and SAFETY_STOP, so rc alone is never
treated as success or failure: the verdict combines the campaign's terminal outcome, the
task RESULT in the bridge journal, the result hash and the bridge chain state. It never
retries and never resends.

`accept` mode reports four INDEPENDENT verdicts — task result, four-line evidence, process
cleanup and automatic result send status — built from this task's structured diagnostic
(CAMPAIGN_ROUND_DIAG) and exact identities (no global process scan). BLOCKED, a missing
record, UNKNOWN or ALREADY_PRESENT never counts as a complete success.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PY_LINE_RE = re.compile(r"^python3 --version: Python (3\.\d+\.\d+)$")
DIAG_PREFIX = "CAMPAIGN_ROUND_DIAG "


def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def journal_entries(path):
    entries = []
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except ValueError:
                continue
    except OSError:
        pass
    return entries


def last_result(journal, task_id, sequence):
    found = None
    for entry in journal:
        if (entry.get("event") == "RESULT" and entry.get("task_id") == task_id
                and entry.get("sequence") == sequence):
            found = entry
    return found


def parse_diag(round_out):
    line = None
    try:
        for raw in Path(round_out).read_text(encoding="utf-8").splitlines():
            if raw.startswith(DIAG_PREFIX):
                line = raw[len(DIAG_PREFIX):]
    except OSError:
        return None
    if not line:
        return None
    fields = {}
    for part in line.split(" "):
        if "=" in part:
            key, value = part.split("=", 1)
            fields[key] = value
    return fields


def mode_round(args):
    campaign = load_json(Path(args.supervisor_root) / args.campaign_id / "state.json") or {}
    bridge = load_json(Path(args.bridge_dir) / "state.json") or {}
    pending = (Path(args.bridge_dir) / "pending_result.json").exists()
    result = last_result(journal_entries(Path(args.bridge_dir) / "journal.jsonl"),
                         args.task_id, args.sequence)
    result_sha = result.get("result_sha256") if result else None

    reasons = []
    if args.rc not in (0, 3):
        reasons.append("unexpected_rc=%s" % args.rc)
    if campaign.get("terminal_outcome") != "LIMIT_REACHED":
        reasons.append("campaign_outcome=%s" % (campaign.get("terminal_outcome") or "MISSING"))
    if result is None:
        reasons.append("task_result=MISSING")
    if bridge.get("expected_sequence") != args.sequence + 1:
        reasons.append("chain_sequence=%s (want %s)" % (bridge.get("expected_sequence"), args.sequence + 1))
    if pending:
        reasons.append("pending_result=PRESENT")
    if bridge.get("status") != "WAITING_FOR_GPT":
        reasons.append("bridge_status=%s" % (bridge.get("status") or "MISSING"))
    if result is not None and bridge.get("last_result_sha256") != result_sha:
        reasons.append("result_hash_mismatch")

    print("VERDICT=%s" % ("COMPLETED" if not reasons else "STOP"))
    print("campaign_rc=%s" % args.rc)
    print("campaign_outcome=%s" % (campaign.get("terminal_outcome") or "MISSING"))
    print("task_outcome=%s" % (result.get("outcome") if result else "MISSING"))
    print("task_exit_code=%s" % (result.get("exit_code") if result else "MISSING"))
    print("result_sha256=%s" % (result_sha or "MISSING"))
    print("bridge_status=%s" % (bridge.get("status") or "MISSING"))
    print("expected_sequence=%s" % (bridge.get("expected_sequence")
                                    if bridge.get("expected_sequence") is not None else "MISSING"))
    print("pending_result=%s" % ("PRESENT" if pending else "ABSENT"))
    if reasons:
        print("REASONS=%s" % "; ".join(reasons))
    return 0 if not reasons else 1


def evidence_verdict(worktree, prep_binding):
    try:
        binding = json.loads(Path(prep_binding).read_text(encoding="utf-8"))
        lines = [l.rstrip("\n") for l in
                 Path(worktree, "EVIDENCE.txt").read_text(encoding="utf-8").splitlines()]
    except Exception as exc:  # noqa: BLE001
        return "FAIL", "unreadable:%s" % type(exc).__name__
    if len(lines) != 4:
        return "FAIL", "lines=%d" % len(lines)
    if lines[0] != "id -un: aegl-ai":
        return "FAIL", "identity"
    if lines[1] != "pwd: " + str(binding.get("worktree")):
        return "FAIL", "worktree"
    if lines[2] != "git rev-parse HEAD: " + str(binding.get("commit")):
        return "FAIL", "revision"
    if not PY_LINE_RE.fullmatch(lines[3]):
        return "FAIL", "runtime"
    return "PASS", "four-lines"


def mode_accept(args):
    diag = parse_diag(args.round_out) or {}
    result = last_result(journal_entries(Path(args.bridge_dir) / "journal.jsonl"),
                         args.task_id, args.sequence)
    ev_verdict, ev_detail = evidence_verdict(args.worktree, args.prep_binding)

    task_ok = result is not None and result.get("outcome") == "SUCCESS"
    task_detail = (result.get("outcome") if result else "MISSING")
    cleanup = diag.get("cleanup", "MISSING")
    send = diag.get("send_status", "MISSING")

    print("ACCEPT_TASK_RESULT=%s detail=%s exit_code=%s"
          % ("PASS" if task_ok else "FAIL", task_detail,
             result.get("exit_code") if result else "MISSING"))
    print("ACCEPT_EVIDENCE=%s detail=%s" % (ev_verdict, ev_detail))
    print("ACCEPT_CLEANUP=%s detail=%s" % ("PASS" if cleanup == "CONFIRMED" else "FAIL", cleanup))
    print("ACCEPT_SEND=%s detail=%s" % ("PASS" if send == "CONFIRMED_SENT" else "FAIL", send))

    failures = []
    if not task_ok:
        failures.append("task_result=%s" % task_detail)
    if ev_verdict != "PASS":
        failures.append("evidence=%s" % ev_detail)
    if cleanup != "CONFIRMED":
        failures.append("cleanup=%s" % cleanup)
    if send != "CONFIRMED_SENT":
        failures.append("send=%s" % send)
    print("ACCEPT_RESULT=%s" % ("PASS" if not failures else "FAIL"))
    if failures:
        print("ACCEPT_REASONS=%s" % "; ".join(failures))
    return 0 if not failures else 1


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("round", "accept"), required=True)
    ap.add_argument("--task-id", required=True)
    ap.add_argument("--sequence", type=int, required=True)
    ap.add_argument("--bridge-dir", required=True)
    ap.add_argument("--rc", type=int)
    ap.add_argument("--campaign-id")
    ap.add_argument("--supervisor-root")
    ap.add_argument("--round-out")
    ap.add_argument("--worktree")
    ap.add_argument("--prep-binding")
    args = ap.parse_args(argv)
    if args.mode == "round":
        if args.rc is None or not args.campaign_id or not args.supervisor_root:
            print("VERDICT=STOP\nREASONS=arguments", file=sys.stderr)
            return 1
        return mode_round(args)
    if not args.round_out or not args.worktree or not args.prep_binding:
        print("ACCEPT_RESULT=FAIL\nACCEPT_REASONS=arguments", file=sys.stderr)
        return 1
    return mode_accept(args)


if __name__ == "__main__":
    raise SystemExit(main())
