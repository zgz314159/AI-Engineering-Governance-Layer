# Acceptance Criteria — ImageAnalysisFactory chain onboarding (S0)

## Acceptance Criteria

### AC-IAP-001 — Actual read-only onboarding evidence exists

- Given: the controlled sandbox executed TASK-01 in the disposable worktree
- When: the worktree is inspected read-only
- Then: `EVIDENCE.txt` exists with exactly four labeled lines, in order: `id -un: aegl-ai`, `pwd: /var/tmp/IAP-SMOKE-007/project`, `git rev-parse HEAD: <PREP-BINDING.json commit>`, `python3 --version: <actual>`; no other line or file was written. Expected values, failure notes and any other reporting are not written to the file; they belong in the final assistant response.
- Verification: a deterministic read-only check compares the exact lines with the root-owned trusted `PREP-BINDING.json` at the task root and records the SHA-256 of EVIDENCE.txt; missing, extra or mismatched lines fail task acceptance; the check never rewrites, repairs or beautifies the evidence
- PC1 Step: PC1-01
