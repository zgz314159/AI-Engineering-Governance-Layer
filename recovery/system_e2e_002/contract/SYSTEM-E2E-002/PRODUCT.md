# PRODUCT — System contract-compile closed-loop acceptance (SYSTEM-E2E-002)

## Product
The Google Android Agent Development Stack's frozen, deterministic offline contract
compiler (`specification/compiler`) and its `specification/tests/fixtures/valid_package`
fixture.

## Change Request
Authorize exactly one disposable task to compile the frozen `valid_package` fixture with
the declared, hash-pinned compiler, extract the actual summary from the generated
artifacts, and write `RESULT.json`. The contract exercises the existing trusted chain; it
does not change the compiler, the fixture or the acceptance baseline.

## Scope
- Verify the declared read-only input bundle by its pinned SHA-256 list.
- Copy the frozen fixture into the disposable worktree under `e2e/valid_package`.
- Run `hash_manifest.py`, `build_contract.py` and `validate_package.py` exactly once each,
  in order, from the declared input bundle.
- Extract counts and status from the real generated artifacts and write `RESULT.json`.
- Run under the existing task-scoped diagnostic sink for `SYSTEM-E2E-002`; diagnostics
  are observational only and never authorize or prove a tool result.
- Stop. No repair, no fixture edit, no retry and no further exploration.

## Non-Goals
- No compiler, schema, fixture or governance change.
- No repair loop, retry, alternate compiler or undeclared source.
- No new diagnostic framework or expanded capture range.
- No formal project source, host, Bridge, registry or control-plane change.
- No promotion, push, installation or model call beyond the single controlled execution.

## Contract Metadata
```json
{
  "experiment": {
    "experiment_id": "SYSTEM-E2E",
    "experiment_type": "SPEC_FIRST_BROWNFIELD",
    "matched_control_available": false,
    "contract_id": "SYSTEM-E2E-002",
    "mode": "brownfield"
  },
  "feature": {
    "feature_id": "SYSTEM-E2E-COMPILE",
    "title": "System contract-compile closed-loop acceptance",
    "summary": "Authorize one disposable task to compile the frozen valid_package fixture with the declared hash-pinned Stack compiler and report the actual artifact summary."
  },
  "scope": [
    "Verify the declared input bundle hashes",
    "Copy the frozen fixture into the disposable worktree",
    "Run the three declared compiler entry points once each in order",
    "Extract the actual summary and write RESULT.json"
  ],
  "non_goals": [
    "Compiler, schema or fixture change",
    "Repair, retry or undeclared source",
    "Formal source, host or control-plane change",
    "Promotion, push or installation"
  ],
  "unresolved_questions": []
}
```
