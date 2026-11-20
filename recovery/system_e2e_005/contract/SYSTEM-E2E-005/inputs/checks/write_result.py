#!/usr/bin/env python3
"""Execute step: extract the actual summary from the generated artifacts into RESULT.json.

Extracted verbatim from the SYSTEM-E2E-004 inline heredoc body of the same stage, with the
task identity changed to SYSTEM-E2E-005. Reads only the compiled copy under
``e2e/valid_package`` and writes ``RESULT.json`` in the current directory (the worktree
root), exactly as before.

Usage: write_result.py
"""

import json
from pathlib import Path

pkg = Path("e2e/valid_package")
manifest = json.loads((pkg / "manifest.json").read_text(encoding="utf-8"))
contract = json.loads((pkg / "implementation-contract.json").read_text(encoding="utf-8"))
report = json.loads((pkg / "validation-report.json").read_text(encoding="utf-8"))
ready = json.loads((pkg / "READY.json").read_text(encoding="utf-8"))
result = {
    "task_id": "SYSTEM-E2E-005",
    "fixture_id": contract["contract_id"],
    "manifest_entries": len(manifest["entries"]),
    "requirements": len(contract["requirements"]),
    "tasks": len(contract["tasks"]),
    "validator_status": report["status"],
    "errors": len(report["errors"]),
}
assert ready["status"] == report["status"] == "READY"
assert result["errors"] == 0
Path("RESULT.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print("RESULT_WRITTEN " + json.dumps(result, sort_keys=True))
