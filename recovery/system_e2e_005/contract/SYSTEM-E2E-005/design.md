# Implementation Design — System contract-compile closed-loop acceptance (SYSTEM-E2E-005)

## Architecture
The disposable task root is `/var/tmp/SYSTEM-E2E-005`; its `project/` child is a detached
git worktree of the formal `ImageAnalysisFactory` tree owned by `aegl-ai`. The contract
`source_root` is the task root and `allowed_paths` is exactly `project`, so the launcher,
registration tool, Contract Guard and validator resolve the same source_root-relative
paths. The contract package is root-controlled under the trusted AEGL area and is mounted
read-only. It carries a declared input bundle (`inputs/fixture`, `inputs/compiler`,
`inputs/contracts`, `inputs/INPUTS.sha256`) whose bytes are pinned by SHA-256. The executor
reads only that bundle, copies the fixture into its writable worktree and runs the three
declared compiler entry points there. The host acceptance reads the registry entry, the
compiled worktree copy and the root-owned input bundle, and never trusts the model reply.

## Data Flow
1. Trusted preparation verifies the pinned source hashes, creates the task root and the
   detached worktree, and writes a root-owned `INPUTS-PIN.json` at the task root.
2. Preparation compiles this authored contract with the same pinned compiler and installs
   the resulting package under the trusted contract root; it does not execute anything.
3. Call 1 (one consolidated read): verify `manifest.json` and `READY.json`, then read
   `implementation-contract.json`, `project-context.json`, the declared `INPUTS-PIN.json`,
   `requirements.md`, `acceptance.md`, `design.md`, `DESIGN.md`, `tasks.md` and
   `verification-intent.json` in that order. No separate read_file calls.
4. Call 2 (one ordered execution): start at the worktree recorded in `INPUTS-PIN.json`,
   reject an existing `e2e` or `RESULT.json`, verify `inputs/INPUTS.sha256` in a subshell,
   copy `inputs/fixture` to `e2e/valid_package`, run the three compiler entry points once
   each, extract the actual summary into `RESULT.json`, and perform the result check inside
   the same call. No compiler or validation command is re-run.
5. The independent host acceptance is out-of-session: it recomputes manifest member hashes
   and input hashes, re-reads every artifact, and compares the summary with the actual
   values. The executor does not run it.

## File Structure Plan

**MUST TOUCH**
| File | Role | Expected change |
| --- | --- | --- |
| `project/RESULT.json` | evidence | create exactly seven keys with actual-derived values |
| `project/e2e/valid_package/**` | compiled fixture copy | copy of the frozen fixture plus generated artifacts |

**MAY TOUCH**
| File | Role | Expected change |
| --- | --- | --- |
| (none) | - | - |

**MUST NOT TOUCH**
- `$HERMES_CONTRACT_PACKAGE/**` — root-owned read-only inputs, compiler and contract.
- any path outside the disposable task worktree.
- the formal ImageAnalysisFactory, Stack or AEGL trees.

## Selector Contract
No UI. `RESULT.json` (contract path `project/RESULT.json`) is the evidence artifact.

## Contract Metadata
```json
{
  "decisions": [
    { "id": "DEC-001", "statement": "The contract package carries the only compiler, schema and fixture bytes the executor may use, each pinned in inputs/INPUTS.sha256.", "rationale": "Keeps provenance explicit and prevents undeclared code or data from being fetched at runtime." },
    { "id": "DEC-002", "statement": "RESULT.json counts and status are extracted at runtime from the generated artifacts; no expected count is embedded in the extraction step.", "rationale": "Prevents a pre-filled template from masquerading as a result." },
    { "id": "DEC-003", "statement": "The compiler runs exactly once per entry point in the declared order; any failure stops the task without repair, retry or alternate source.", "rationale": "Keeps the acceptance a real single-pass execution rather than an autonomous repair loop." },
    { "id": "DEC-004", "statement": "Host acceptance recomputes manifest member hashes and input hashes independently of the model reply.", "rationale": "A model statement or a zero exit code is not evidence." },
    { "id": "DEC-005", "statement": "Any task-scoped diagnostic capture for SYSTEM-E2E-005 must use the existing /var/tmp/aegl-diag mechanism and remain observational only.", "rationale": "Keeps diagnostics within the existing facility without changing guard authorization or tool behavior." },
    { "id": "DEC-006", "statement": "The executor uses exactly two terminal calls: one consolidated read and one ordered execution; the result check is inside the second call and host acceptance is out-of-session.", "rationale": "Removes duplicate reads and the separate verification re-run without weakening any check." }
  ],
  "assumptions": [
    { "id": "ASM-001", "statement": "The frozen valid_package fixture compiles offline to READY with 8 manifest entries, 1 requirement, 1 task and 0 errors." },
    { "id": "ASM-002", "statement": "The formal ImageAnalysisFactory tree provides the registered project identity and a clean detached worktree baseline." }
  ],
  "data_change": {
    "schema_version_current": 0,
    "schema_version_target": 0,
    "migration_required": false,
    "notes": "No persisted schema."
  },
  "ui_change": {
    "surfaces": [],
    "selectors_added": []
  },
  "selector_contract": [],
  "stop_conditions": [
    "The declared input bundle is missing or a pinned hash does not match.",
    "The fixture copy or a compiler entry point is missing.",
    "A compiler entry point exits non-zero or the validator reports non-READY.",
    "An existing e2e target or RESULT.json, or a link, is present.",
    "A frozen decision is contradicted.",
    "The worktree is not the registered detached worktree of the formal source root."
  ]
}
```
