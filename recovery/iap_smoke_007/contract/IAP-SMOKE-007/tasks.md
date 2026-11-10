# Tasks — ImageAnalysisFactory chain onboarding (S0)

## Tasks

### TASK-01 — Run the read-only onboarding check and write EVIDENCE.txt
- Goal: Run `id -un`, `pwd`, `git rev-parse HEAD` and `python3 --version` in `/var/tmp/IAP-SMOKE-007/project`; write exactly four labeled lines to `EVIDENCE.txt` in this order: `id -un: <actual>`, `pwd: <actual>`, `git rev-parse HEAD: <actual>`, `python3 --version: <actual>`; no other lines or files. The file contains nothing else: expected values, failure notes and any other reporting belong in the final assistant response, never in `EVIDENCE.txt`.
_Boundary:_ Read-only inspection and one evidence file only. No formal source or host change.
_Depends:_ none
- Allowed Paths: `project`
- Acceptance: AC-IAP-001
- Verification: `EVIDENCE.txt` in the worktree contains exactly four labeled lines whose values are `aegl-ai`, `/var/tmp/IAP-SMOKE-007/project`, the commit in the root-owned trusted `PREP-BINDING.json` at the task root, and the actual `python3 --version` string; compare with the actual command results; no other line in the file and no other file changed.
- Done When: EVIDENCE.txt is present in the worktree with exactly the four labeled actual values and no other line, and the bridge reports its real process outcome; process exit does not by itself prove task acceptance.
