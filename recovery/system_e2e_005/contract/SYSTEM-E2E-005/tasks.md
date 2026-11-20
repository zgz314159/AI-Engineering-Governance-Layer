# Tasks — System contract-compile closed-loop acceptance (SYSTEM-E2E-005)

## Tasks

### TASK-01 — One consolidated read, then one ordered execution
- Goal: Use exactly two terminal calls, in this order, and no other tool call. Call 1: run the `read` CLI check exactly as declared; it verifies the contract manifest and READY and prints implementation-contract, project-context, the declared INPUTS-PIN, requirements, acceptance, design, DESIGN, tasks and verification-intent in that order. Do not issue separate read_file calls or re-read anything. Call 2: run the `execute` CLI check exactly as declared from the worktree root recorded in INPUTS-PIN; it verifies every declared input hash in a subshell, creates a fresh fixture copy, runs hash_manifest, build_contract and validate_package once each in order, extracts the actual summary to RESULT.json, performs the result check inside the same call, and prints EXEC_STAGE=COMPLETE. If call 1 fails, do not start call 2. If call 2 fails, stop immediately with its EXEC_FAIL stage and real rc; do not retry, patch, overwrite or re-run any step. After call 2 succeeds, make no further tool call and give the final reply using only the collected output. Host acceptance is outside this session; do not run accept.py or re-run the compile as verification.
- Boundary: Read-only use of the declared input bundle and contract package; writes limited to `e2e/**` and `RESULT.json` inside the disposable worktree. No formal source, compiler, fixture or host change.
- Depends: none
- Allowed Paths: `project`
- Acceptance: AC-SYSE2E-003
- Verification: The second call performs the in-session result check and prints the actual summary; the independent host acceptance is an out-of-session step and is not re-run by the executor.
- Done When: The second call printed EXEC_STAGE=COMPLETE with RESULT.json derived from the actual artifacts, and the out-of-session host acceptance passes; process exit alone does not prove acceptance.
