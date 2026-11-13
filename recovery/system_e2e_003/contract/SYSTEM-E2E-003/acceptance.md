# Acceptance Criteria — System contract-compile closed-loop acceptance (SYSTEM-E2E-003)

## Acceptance Criteria

### AC-SYSE2E-003 — Actual compiled artifacts and RESULT.json agree
- Given: the controlled sandbox executed TASK-01 exactly once in the disposable worktree
- When: the worktree copy and the root-controlled contract input bundle are inspected read-only
- Then: `project/e2e/valid_package` contains a compiled fixture whose `manifest.json` has exactly 8 entries and whose `implementation-contract.json` has exactly 1 requirement and 1 task with `contract_id` `FIXTURE-B1-CONTRACT`; `validation-report.json` reports `status` `READY` with zero errors and `READY.json` also reports `READY`; every manifest member hash recomputes; every declared input still matches its pinned SHA-256; and `project/RESULT.json` has exactly the keys `task_id`, `fixture_id`, `manifest_entries`, `requirements`, `tasks`, `validator_status`, `errors` with `task_id` `SYSTEM-E2E-003`, `fixture_id` `FIXTURE-B1-CONTRACT`, integers 8, 1, 1, `validator_status` `READY` and `errors` 0, all matching the actual artifacts
- Verification: a deterministic read-only host check recomputes the manifest member hashes and the declared input hashes, re-reads every generated artifact, compares the summary with the actual values, and rejects missing files, extra fields, wrong types, invalid JSON or inconsistent values; a model statement or a zero process exit is not acceptance
- Session boundary: the host verification runs outside the executor session; the executor must not run accept.py or re-run any compile or validation command
- PC1 Step: PC1-01
