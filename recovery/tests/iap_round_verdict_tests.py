#!/usr/bin/env python3
"""Isolated check for the IAP-SMOKE-002 round/acceptance verdicts.

Drives the ACTUAL production helper (recovery/iap_round_verdict.py) over a temp bridge
state/journal and campaign state. No Chrome, no Bridge writes, no model, no root.

Primary scenario: the single campaign round returns rc=3 with LIMIT_REACHED, a task
RESULT, the advanced chain and no pending — the verdict is COMPLETED, i.e. acceptance
continues. Genuine anomalies (SAFETY_STOP, missing RESULT, un-advanced chain, pending)
must STOP. Acceptance must not let BLOCKED / MISSING / UNKNOWN / ALREADY_PRESENT pass.
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
HELPER = HERE.parent / "iap_round_verdict.py"
DRIVER = HERE.parent / "iap_smoke_delivery_002.sh"
TASK_ID = "IAP-SMOKE-002"
SEQ = 7
RESULT_SHA = "7" * 64
COMMIT = "c" * 40


def run_helper(args):
    return subprocess.run([sys.executable, str(HELPER)] + args,
                          capture_output=True, text=True)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="iap-round-verdict-")
        self.root = Path(self.tmp.name)
        self.bridge = self.root / "bridge"
        self.supervisor = self.root / "supervisor"
        self.bridge.mkdir()
        (self.supervisor / "IAP-SMOKE-002").mkdir(parents=True)
        self.write_state()
        self.write_journal()

    def tearDown(self):
        self.tmp.cleanup()

    def write_state(self, *, status="WAITING_FOR_GPT", sequence=SEQ + 1, last_sha=RESULT_SHA):
        (self.bridge / "state.json").write_text(json.dumps({
            "expected_sequence": sequence, "expected_nonce": "n", "expected_in_reply_to": "r",
            "status": status, "last_task_id": TASK_ID, "last_result_sha256": last_sha}))

    def write_journal(self, *, outcome="SUCCESS", with_result=True, exit_code=0):
        lines = []
        if with_result:
            lines.append({"event": "RESULT", "task_id": TASK_ID, "sequence": SEQ,
                          "outcome": outcome, "exit_code": exit_code, "result_sha256": RESULT_SHA})
        (self.bridge / "journal.jsonl").write_text("\n".join(json.dumps(x) for x in lines) + "\n")

    def write_campaign(self, *, outcome="LIMIT_REACHED"):
        (self.supervisor / "IAP-SMOKE-002" / "state.json").write_text(json.dumps({
            "campaign_id": "IAP-SMOKE-002", "status": "PAUSED", "terminal_outcome": outcome,
            "round_count": 1, "max_rounds": 1}))

    def round_verdict(self, rc=3):
        return run_helper(["--mode", "round", "--task-id", TASK_ID, "--sequence", str(SEQ),
                           "--bridge-dir", str(self.bridge), "--rc", str(rc),
                           "--campaign-id", "IAP-SMOKE-002",
                           "--supervisor-root", str(self.supervisor)])

    # -- acceptance fixtures ------------------------------------------------- #
    def write_accept_fixtures(self, *, diag_cleanup="CONFIRMED",
                              diag_send="CONFIRMED_SENT", diag=True, task_outcome="SUCCESS"):
        self.write_journal(outcome=task_outcome)
        self.worktree = self.root / "project"
        self.worktree.mkdir()
        (self.worktree / "EVIDENCE.txt").write_text(
            "id -un: aegl-ai\npwd: %s\ngit rev-parse HEAD: %s\npython3 --version: Python 3.14.7\n"
            % (self.worktree, COMMIT))
        self.binding = self.root / "PREP-BINDING.json"
        self.binding.write_text(json.dumps({"worktree": str(self.worktree), "commit": COMMIT}))
        self.round_out = self.root / "round.out"
        if diag:
            self.round_out.write_text(
                "CAMPAIGN_ROUND_DIAG task_id=%s stage=EXECUTED exit_code=0 timed_out=False "
                "timeout_phases=UNKNOWN cleanup=%s send_status=%s result_sha256=%s\n"
                % (TASK_ID, diag_cleanup, diag_send, RESULT_SHA))
        else:
            self.round_out.write_text("CAMPAIGN_NOTICE something else\n")

    def accept_verdict(self):
        return run_helper(["--mode", "accept", "--task-id", TASK_ID, "--sequence", str(SEQ),
                           "--bridge-dir", str(self.bridge), "--round-out", str(self.round_out),
                           "--worktree", str(self.worktree), "--prep-binding", str(self.binding)])


class RoundVerdict(Base):
    def test_rc3_limit_reached_completes_and_acceptance_continues(self):
        self.write_campaign(outcome="LIMIT_REACHED")
        r = self.round_verdict(rc=3)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("VERDICT=COMPLETED", r.stdout)
        self.assertIn("expected_sequence=8", r.stdout)
        self.assertIn("pending_result=ABSENT", r.stdout)

    def test_rc3_safety_stop_is_not_completion(self):
        self.write_campaign(outcome="SAFETY_STOP")
        r = self.round_verdict(rc=3)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("VERDICT=STOP", r.stdout)
        self.assertIn("campaign_outcome=SAFETY_STOP", r.stdout)

    def test_missing_task_result_is_not_completion(self):
        self.write_campaign(outcome="LIMIT_REACHED")
        self.write_journal(with_result=False)
        r = self.round_verdict(rc=3)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("task_result=NOT_OBSERVED", r.stdout)

    def test_pending_or_unadvanced_chain_stops(self):
        self.write_campaign(outcome="LIMIT_REACHED")
        (self.bridge / "pending_result.json").write_text("{}")
        self.write_state(sequence=SEQ)  # chain did not advance
        r = self.round_verdict(rc=3)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("pending_result=PRESENT", r.stdout)
        self.assertIn("chain_sequence=%s" % SEQ, r.stdout)


class AcceptVerdict(Base):
    def test_all_good_passes(self):
        self.write_accept_fixtures()
        r = self.accept_verdict()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for line in ("ACCEPT_TASK_RESULT=PASS", "ACCEPT_EVIDENCE=PASS",
                     "ACCEPT_CLEANUP=PASS", "ACCEPT_SEND=PASS", "ACCEPT_RESULT=PASS"):
            self.assertIn(line, r.stdout)

    def test_blocked_is_not_success(self):
        self.write_accept_fixtures(task_outcome="BLOCKED")
        r = self.accept_verdict()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ACCEPT_TASK_RESULT=FAIL", r.stdout)
        self.assertIn("ACCEPT_RESULT=FAIL", r.stdout)

    def test_already_present_is_not_auto_send_success(self):
        self.write_accept_fixtures(diag_send="ALREADY_PRESENT")
        r = self.accept_verdict()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ACCEPT_SEND=FAIL", r.stdout)
        self.assertIn("ACCEPT_RESULT=FAIL", r.stdout)

    def test_unknown_cleanup_is_not_success(self):
        self.write_accept_fixtures(diag_cleanup="UNKNOWN")
        r = self.accept_verdict()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ACCEPT_CLEANUP=FAIL", r.stdout)

    def test_missing_diagnostic_is_not_success(self):
        self.write_accept_fixtures(diag=False)
        r = self.accept_verdict()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ACCEPT_CLEANUP=FAIL", r.stdout)
        self.assertIn("ACCEPT_SEND=FAIL", r.stdout)

    def test_blocked_124_missing_evidence_shows_diag_and_four_verdicts(self):
        # One round completes, but the task result is BLOCKED/124 and EVIDENCE.txt is absent.
        self.write_campaign(outcome="LIMIT_REACHED")
        self.write_journal(outcome="BLOCKED", exit_code=124)
        self.worktree = self.root / "project"
        self.worktree.mkdir()                      # EVIDENCE.txt deliberately absent
        self.binding = self.root / "PREP-BINDING.json"
        self.binding.write_text(json.dumps({"worktree": str(self.worktree), "commit": COMMIT}))
        line = ("CAMPAIGN_ROUND_DIAG task_id=%s stage=EXECUTED exit_code=124 timed_out=True "
                "timeout_phases=KILL,TERM cleanup=CONFIRMED send_status=CONFIRMED_SENT "
                "result_sha256=%s" % (TASK_ID, RESULT_SHA))
        self.round_out = self.root / "round.out"
        self.round_out.write_text(line + "\n")

        # (1) the round still counts as COMPLETED, so acceptance continues
        r = self.round_verdict(rc=3)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("VERDICT=COMPLETED", r.stdout)
        self.assertIn("task_outcome=BLOCKED", r.stdout)
        self.assertIn("task_exit_code=124", r.stdout)

        # (2) the driver's own emitter surfaces exactly that structured line (not raw output)
        e = subprocess.run(["/bin/bash", "-c", 'source "$1"; emit_round_diag "$2"', "_",
                            str(DRIVER), str(self.round_out)], capture_output=True, text=True)
        self.assertEqual(e.returncode, 0, e.stderr)
        self.assertEqual(e.stdout.strip(), line)

        # (3) acceptance prints all four verdicts and fails — no early exit on missing evidence
        a = self.accept_verdict()
        self.assertNotEqual(a.returncode, 0)
        for key in ("ACCEPT_TASK_RESULT=FAIL", "ACCEPT_EVIDENCE=FAIL",
                    "ACCEPT_CLEANUP=PASS", "ACCEPT_SEND=PASS", "ACCEPT_RESULT=FAIL"):
            self.assertIn(key, a.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
