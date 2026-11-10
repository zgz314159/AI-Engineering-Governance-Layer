# IAP-SMOKE-007 prep-r1 — new-task S0 preparation (no model)

This package prepares a **new** `IAP-SMOKE-007` S0 scene. It does not continue
`IAP-SMOKE-006`, does not migrate old markers, and does not copy the 006-specific
continuation authorization. The default entry stops at `PREP_COMPLETE`: no send, no
campaign round, no model call, no `EVIDENCE.txt`.

S0 is not the business milestone and not M1/P0 acceptance. 007 remains an S0
integration observation.

## Source and contract provenance

- AEGL source: `/var/tmp/IAP-CONTROL-DEV/aegl`, branch `fix/iap-delivery`
- production candidate (unchanged): `926c34fbecf1157c2ae88e57e85ef67f6f82de33`
- check source predecessor: `9aef5378dabeb17a8a0152404f32bd8434d3a4b2`
- frozen 006 S0 contract it derives from: manifest
  `e47d44349b6f401814afb7381aba1df41eb4921ea7de0a91c52087c56c54d640`
  (already consumed; **not** modified by this package)
- derivation: only the task/contract IDs and the 006 → 007 task-root/worktree paths were
  changed; the package was rebuilt with the **unchanged** specification compiler
  (`specification/compiler/hash_manifest.py` → `build_contract.py` →
  `validate_package.py`)
- 007 contract manifest: `b84391b570bdc3512f675f3741b9d62151268612302d20fe8ec38200ea867b71`
- 007 contract gates: `schema=PASS traceability=PASS boundaries=PASS acceptance=PASS
  hashes=PASS`; `READY.json status=READY`
- baseline (unchanged): `177680708739a72a0d70bc6a9664245b00a2ef08`
- model, provider/route and the 120 s budget are unchanged

## Verified identity and state (ordinary user, read-only)

- Bridge: `WAITING_FOR_GPT`, `expected_sequence=11`, `pending_result.json` **ABSENT**
- `/var/tmp/IAP-SMOKE-007` **ABSENT**
- ledger `/var/lib/aegl-smoke/IAP-SMOKE-007` **ABSENT**
- registry has **no** `IAP-SMOKE-007` entry
- supervisor has **no** `IAP-SMOKE-007` campaign directory (`CLEAN`)
- contract target
  `/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/IAP-SMOKE-007`
  **ABSENT**; contracts parent `root:root 0755` **PRESENT**
- `/var/tmp/aegl-diag` is `root:root 0700`; an ordinary user therefore reports
  `DIAG_SINK=UNKNOWN`. The root preflight checks the existing 007 sink **first** and treats
  `UNKNOWN` as a hard stop, never as absent. It never treats a permission error as absence.

## Installed pins (verified only; not reinstalled)

| file | SHA-256 | owner:group | mode |
|---|---|---|---|
| `aegl-hermes-sandbox` (predecessor) | `f3e556f079d14c6e4dd7173cd3a571b6e8a32527db12dc91aae44fbf75929479` | root:root | 0755 |
| `model_broker.py` | `7aa88b1831ca18fdbe9b14273321a90b352bb6026299b9bb9c26d4ca9b8ee59a` | root:root | 0644 |
| `tool_event_client.py` | `f70630cacfdcb1afd5eff08ad20ada9737c91b097a42741a122a0fa651df83bf` | root:root | 0644 |
| `tool_observer_config.py` | `424369561202ca48f122b8116fc6b2ebca8cbb1d108dbeb04674608b807591c3` | root:root | 0644 |
| `guard/contract_guard.py` | `19f6be638c37b28d401820b7a4562f852a459188cbfa793f757668fe9b330455` | root:root | 0444 |
| `git_meta_mounts.sh` | `f93bbfdd286e6a554c10edcdda6dd40a20d32d1ffbcb17dc56091bbeac8ac50a` | root:root | 0755 |

The only deployed change is the launcher diagnostic allowlist: one line, appending
`IAP-SMOKE-007` after all existing entries. New payload SHA-256:
`dc954c59ed4cadf6c7567679045c1d35cd529f3b19237228b1bb08dc6048d4f5`.
The broker, both observer modules, the guard and the helper are neither modified nor
reinstalled.

## Contract and stage order

- contract source: `contract/IAP-SMOKE-007`
- target: the trusted contracts path for `IAP-SMOKE-007`
- the corrected task-root `PREP-BINDING` rule and the **exactly four-line** `EVIDENCE`
  rule are retained for 007:
  `id -un: aegl-ai`,
  `pwd: /var/tmp/IAP-SMOKE-007/project`,
  `git rev-parse HEAD: <PREP-BINDING.json commit>`,
  `python3 --version: <actual>`.
  The commit is taken from the root-owned trusted `PREP-BINDING.json`, never embedded in
  the contract.
- host binding check: regular file, non-symlink, numeric `0:0`, mode `0644`, content
  matches worktree/commit/contract. Sandbox check: readable, not writable, mode `0644`,
  content match. Sandbox owner names (`nobody:nogroup`) are diagnostic only.
- stage order: `preflight → sandbox_diag → baseline → worktree → permissions → contract
  → binding → register → probe → ready`. The registration order
  `contract → binding → register → probe → ready` is preserved.
- default entry only prepares and stops at `PREP_COMPLETE`. `--execute` must be given
  explicitly; it was not run in this round.

## Verification performed

```sh
/var/tmp/IAP-SMOKE-007-prep-r1/bin/run_smoke.sh --self-test
```

Result: `SELFTEST pass=23 fail=0`. Coverage: package integrity; shell/Python syntax;
contract validator on a temporary copy; contract consistency (007 IDs/paths and the
four-line evidence rule); launcher payload/allowlist; the six installed pins; Stack
pins; Bridge state; `DIAG_SINK=UNKNOWN` and permission handling; task-root/ledger/
registry/supervisor/contract states; absence of 006 continuation code; PREP stage order;
and sink-first preflight ordering. `--status` was also run as an ordinary user.

The self-test records explicit files and directories at creation. On success it removes
them with non-forced `rm` and reverse `rmdir`; on an assertion or cleanup failure it
keeps the scene and reports `SCENE_KEPT`. There is no recursive force delete, force/prune,
gate relaxation or unknown-state repair.

## NOT_RUN

- real root prep and any real `IAP-SMOKE-007` scene creation/registration;
- launcher installation (the payload is packaged, not deployed);
- model call, send, wait, round or accept;
- `r10` root check rerun (its PASS result is preserved as-is);
- the unchanged 23-item production suite;
- any Bridge/registry/supervisor write, any 001–006 replay, and any deployment.
