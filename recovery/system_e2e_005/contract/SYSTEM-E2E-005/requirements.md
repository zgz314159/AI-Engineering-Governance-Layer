# Requirements — System contract-compile closed-loop acceptance (SYSTEM-E2E-005)

## Requirements

### REQ-SYSE2E-003 — One consolidated read and one ordered execution
- Statement: The executor must use exactly two terminal calls: one consolidated read that verifies the contract manifest and READY and reads implementation-contract, project-context, the declared INPUTS-PIN and the remaining author documents; and one ordered execution that verifies all declared input hashes in a subshell, copies the frozen fixture, runs the three declared compiler entry points once each in order, extracts the actual summary into RESULT.json and performs the result check inside the same call. No separate read_file, no re-run of a compile or validation command, and no tool call after the execution call.
- Conditions: Under the controlled Hermes sandbox for project `ImageAnalysisFactory`, reading only the declared contract package and input bundle and writing only under the allowed `project` path.
- Expected: The execution call prints INPUTS_OK, the three compiler records, STATUS=READY with zero errors, the actual RESULT summary and EXEC_STAGE=COMPLETE; RESULT.json contains counts and status extracted from the generated artifacts, not expected constants.
- Edge case: A missing input, hash mismatch, existing target or link, non-zero compiler exit or non-READY status stops the current call and is reported with its stage and real rc; it is never repaired, retried, overwritten or filled with expected values.
- Acceptance: AC-SYSE2E-003
- Tasks: TASK-01
