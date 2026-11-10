# Requirements — ImageAnalysisFactory chain onboarding (S0)

## Requirements

### REQ-IAP-001 — Read-only onboarding evidence
- Statement: The task must run only read-only identity, path, revision and runtime commands in the disposable ImageAnalysisFactory worktree and write their raw output to `EVIDENCE.txt`.
- Conditions: When the controlled Hermes sandbox executes this contract for project `ImageAnalysisFactory`.
- Expected: `EVIDENCE.txt` contains exactly four labeled lines — the actual sandbox user, worktree path, git HEAD and Python runtime line — and nothing else; no other file is written. Expected values, failure notes and any other reporting are not written to the file; they belong in the final assistant response.
- Edge case: Any missing command or sandbox failure must be reported as a real failure, never filled in by the bridge.
- Acceptance: AC-IAP-001
- Tasks: TASK-01
