# Tasks — System contract-compile closed-loop acceptance (SYSTEM-E2E-002)

## Tasks

### TASK-01 — Compile the frozen fixture once and write RESULT.json
- Goal: Work from this frozen contract only, in one pass, with no alternate source and no retry. First verify the declared input bundle: `cd "$HERMES_CONTRACT_PACKAGE/inputs" && sha256sum -c INPUTS.sha256`; every line must report OK and the command must exit 0. Then create an independent copy in the worktree: `mkdir -p e2e && cp -a "$HERMES_CONTRACT_PACKAGE/inputs/fixture" e2e/valid_package`. Run exactly these three commands once each, in this order, from the current worktree root: `python3 -B "$HERMES_CONTRACT_PACKAGE/inputs/compiler/hash_manifest.py" e2e/valid_package`, then `python3 -B "$HERMES_CONTRACT_PACKAGE/inputs/compiler/build_contract.py" e2e/valid_package`, then `python3 -B "$HERMES_CONTRACT_PACKAGE/inputs/compiler/validate_package.py" e2e/valid_package --project-root e2e/valid_package/project`. If any command exits non-zero, stop and report it; do not repair the compiler, edit the fixture, re-run, or substitute another compiler. After `STATUS=READY` is observed, extract the summary from the real generated artifacts using the extraction template in this file and write `RESULT.json` at the worktree root with exactly those seven keys; never pre-fill expected values. Make no further tool call after RESULT.json exists and report the actual command outputs and exit codes.
- Boundary: Read-only use of the declared input bundle and contract package; writes limited to `e2e/**` and `RESULT.json` inside the disposable worktree. No formal source, compiler, fixture or host change.
- Depends: none
- Allowed Paths: `project`
- Acceptance: AC-SYSE2E-002
- Verification: The host recomputes every manifest member hash and every declared input hash, re-reads `manifest.json`, `implementation-contract.json`, `validation-report.json` and `READY.json`, and requires `RESULT.json` to contain exactly the seven declared keys with values equal to the actual artifacts.
- Done When: RESULT.json is present at the worktree root with exactly the seven keys and actual-derived values, the compiled copy reports `STATUS=READY` with zero errors, and the host acceptance passes; process exit alone does not prove acceptance.

## RESULT.json extraction

Run this after the validator printed `STATUS=READY`, from the worktree root. It reads only
generated artifacts; it does not contain expected counts.

```python
import json
from pathlib import Path

pkg = Path("e2e/valid_package")
manifest = json.loads((pkg / "manifest.json").read_text(encoding="utf-8"))
contract = json.loads((pkg / "implementation-contract.json").read_text(encoding="utf-8"))
report = json.loads((pkg / "validation-report.json").read_text(encoding="utf-8"))
ready = json.loads((pkg / "READY.json").read_text(encoding="utf-8"))

result = {
    "task_id": "SYSTEM-E2E-002",
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
```
