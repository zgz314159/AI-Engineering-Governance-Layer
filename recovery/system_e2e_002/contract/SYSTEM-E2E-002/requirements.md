# Requirements — System contract-compile closed-loop acceptance (SYSTEM-E2E-002)

## Requirements

### REQ-SYSE2E-002 — Compile the frozen fixture exactly once
- Statement: The task must verify the declared input bundle, copy the frozen `valid_package` fixture into the disposable worktree, and run the three declared compiler entry points once each in order without repairing the compiler or editing the fixture.
- Conditions: Under the controlled Hermes sandbox for project `ImageAnalysisFactory`, reading only the declared input bundle and writing only under the allowed `project` path.
- Expected: The fixture copy compiles to `STATUS=READY` with the generated manifest, contract, validation report and readiness artifacts present; `RESULT.json` reports counts and status extracted from those artifacts.
- Edge case: A missing input, hash mismatch, non-zero compiler exit or non-READY status stops the task and is reported; it is never repaired, retried or filled with expected values.
- Acceptance: AC-SYSE2E-002
- Tasks: TASK-01
