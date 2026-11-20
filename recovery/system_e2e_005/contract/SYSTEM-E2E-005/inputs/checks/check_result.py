#!/usr/bin/env python3
"""Execute step: re-read RESULT.json, compare it with the actual artifacts and the frozen
baseline, then print the summary.

Extracted verbatim from the SYSTEM-E2E-004 inline heredoc body of the result-check stage,
with the task identity changed to SYSTEM-E2E-005. Read-only except for nothing: it writes no
file and is the in-call result check, not the host acceptance.

Usage: check_result.py
"""

import json
from pathlib import Path

pkg = Path("e2e/valid_package")
result = json.loads(Path("RESULT.json").read_text(encoding="utf-8"))
manifest = json.loads((pkg / "manifest.json").read_text(encoding="utf-8"))
contract = json.loads((pkg / "implementation-contract.json").read_text(encoding="utf-8"))
report = json.loads((pkg / "validation-report.json").read_text(encoding="utf-8"))
actual = {
    "task_id": "SYSTEM-E2E-005",
    "fixture_id": contract["contract_id"],
    "manifest_entries": len(manifest["entries"]),
    "requirements": len(contract["requirements"]),
    "tasks": len(contract["tasks"]),
    "validator_status": report["status"],
    "errors": len(report["errors"]),
}
assert set(result) == set(actual), (sorted(result), sorted(actual))
assert result == actual, (result, actual)
assert result == {
    "task_id": "SYSTEM-E2E-005",
    "fixture_id": "FIXTURE-B1-CONTRACT",
    "manifest_entries": 8,
    "requirements": 1,
    "tasks": 1,
    "validator_status": "READY",
    "errors": 0,
}
print("EXEC_SUMMARY " + json.dumps(result, sort_keys=True))
