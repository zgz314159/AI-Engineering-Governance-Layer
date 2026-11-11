# Implementation Design — ImageAnalysisFactory chain onboarding (S0)

## Architecture
The disposable task root is `/var/tmp/IAP-SMOKE-008`; its `project/` child is a git
worktree of the formal `ImageAnalysisFactory` tree owned by `aegl-ai`. The contract
`source_root` is the task root and `allowed_paths` is exactly `project`, so the
launcher, registration tool, Contract Guard and validator resolve the same
source_root-relative paths. The contract package is root-controlled under the trusted
AEGL area; the sandbox mounts it read-only so `EXECUTOR-PROMPT.md` is visible at its
real path. The trusted binding is NOT part of that package: it is the root-owned
`PREP-BINDING.json` at the task root (`<task root>/PREP-BINDING.json`), outside the
read-only contract package. Hermes runs under the existing frozen `android-stack`
profile with the existing model config; no profile or provider change is introduced.

## Data Flow
1. The operator creates `/var/tmp/IAP-SMOKE-008/project` as a git worktree of the formal
   ImageAnalysisFactory HEAD, registers `IAP-SMOKE-008`, and writes a root-owned
   `PREP-BINDING.json` at the task root (`/var/tmp/IAP-SMOKE-008/PREP-BINDING.json`) with
   that exact worktree and commit; the contract package never contains the binding.
2. The bridge validates the project binding, then the wrapper passes the registered
   task and the contract prompt to the installed `aegl-hermes-sandbox`.
3. Hermes runs the read-only commands in the task worktree and writes exactly four
   labeled lines to `EVIDENCE.txt` there. The file contains nothing else: expected
   values, failure notes and any other reporting belong in the final assistant
   response, never in `EVIDENCE.txt`.
4. The bridge reports the real process outcome. A separate read-only acceptance check
   compares `EVIDENCE.txt` with the root-owned `PREP-BINDING.json` and records its
   SHA-256; it never rewrites the evidence.

## File Structure Plan

**MUST TOUCH**
| File | Role | Expected change |
| --- | --- | --- |
| `EVIDENCE.txt` | evidence | create exactly four labeled lines |

**MAY TOUCH**
| File | Role | Expected change |
| --- | --- | --- |
| (none) | - | - |

**MUST NOT TOUCH**
- `project/src/**` — no business source exists yet; not authorized.
- any path outside the disposable task worktree.

## Selector Contract
No UI. `EVIDENCE.txt` (contract path `project/EVIDENCE.txt`) is the evidence artifact.

## Contract Metadata
```json
{
  "decisions": [
    { "id": "DEC-001", "statement": "The disposable task root is the contract source_root; allowed_paths is exactly 'project'.", "rationale": "Keeps the worktree, registration, Guard and validator aligned on one source_root-relative path." },
    { "id": "DEC-002", "statement": "The expected task commit is bound after the commit by a root-owned PREP-BINDING.json at the task root, outside the read-only contract package; the contract does not embed its own commit SHA.", "rationale": "Avoids a self-referential commit hash while keeping the acceptance expected value trusted, and keeps the binding out of the read-only contract package." },
    { "id": "DEC-003", "statement": "EVIDENCE.txt contains exactly the four labeled real command-output lines and nothing else; expected values, failure notes and any other reporting go only in the final assistant response.", "rationale": "Keeps the evidence file a deterministic four-line artifact while preserving full failure reporting for the operator." }
  ],
  "assumptions": [
    { "id": "ASM-001", "statement": "The formal ImageAnalysisFactory tree is a git repository with a baseline commit before onboarding." }
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
    "A required file is missing.",
    "A frozen decision is contradicted.",
    "The worktree is not a git worktree of the declared formal source root."
  ]
}
```
