# PRODUCT — ImageAnalysisFactory chain onboarding (S0)

## Product
`ImageAnalysisFactory` is a local, repeatable batch image-analysis framework built on the
Command Code CLI + DeepSeek V4.1 Flash vision backend. It is a standing business project
whose full build is specified by
`Command_Code_DeepSeek_大规模图片智能分析工厂_建设方案_v1.0.md`.

## Change Request
Authorize one disposable task worktree and a single `EVIDENCE.txt` for a deterministic,
read-only acceptance that the project can traverse the existing trusted
ChatGPT -> Supervisor -> Bridge -> Hermes control chain under its own project identity.
No business feature is implemented by this contract.

Milestone: **S0 integration smoke**. This is NOT the ImageAnalysisFactory
M1/P0 business acceptance and must not be reported as such.

## Scope
- Read the disposable task worktree (a git worktree of the formal ImageAnalysisFactory tree).
- Run four read-only commands only: `id -un`, `pwd`, `git rev-parse HEAD`, `python3 --version`.
- Write their raw output to `EVIDENCE.txt` in the task worktree, exactly four labeled lines and nothing else; expected values, failure notes and any other reporting stay in the final assistant response.
- Return the real Hermes execution outcome to the bridge.

## Non-Goals
- No image analysis, no model call, no DeepSeek/Command Code inference.
- No change to the formal ImageAnalysisFactory tree, the Stack, or AEGL.
- No promotion, no push, no registration, no install.
- No business write of any kind.

## Contract Metadata
```json
{
  "experiment": {
    "experiment_id": "IAP-SMOKE",
    "experiment_type": "SPEC_FIRST_GREENFIELD",
    "matched_control_available": false,
    "contract_id": "IAP-SMOKE-007",
    "mode": "greenfield"
  },
  "feature": {
    "feature_id": "IAP-BRIDGE-ONBOARD",
    "title": "ImageAnalysisFactory chain onboarding (read-only acceptance)",
    "summary": "Authorize one disposable worktree and EVIDENCE.txt for a deterministic, read-only proof that an ImageAnalysisFactory task traverses the trusted ChatGPT->Supervisor->Bridge->Hermes chain."
  },
  "scope": [
    "Read-only commands inside the disposable task worktree",
    "Write exactly EVIDENCE.txt inside that worktree, four labeled lines and nothing else",
    "Return the real sandbox execution outcome"
  ],
  "non_goals": [
    "Image analysis or any model call",
    "Formal source or host change",
    "Promotion or push",
    "Business write"
  ],
  "unresolved_questions": []
}
```
