# IAP-SMOKE-008 prep-r1 — new-task S0 preparation (no model)

This package prepares a **new** `IAP-SMOKE-008` S0 scene. It does not continue
`IAP-SMOKE-007`, does not replay any consumed task, and contains no 006-specific
continuation authorization. The default entry stops at `PREP_COMPLETE`: no send, no
campaign round, no model call, no `EVIDENCE.txt`.

S0 is not the business milestone and not M1/P0 acceptance. 008 remains an S0
integration observation.

## Authoring input and contract provenance

- AEGL source: `/var/tmp/IAP-CONTROL-DEV/aegl`, branch `fix/iap-delivery`
- AEGL source predecessor: `d02f82e56e0129cffea8e03b413415e70e1d3bd6`
- production candidate (unchanged): `926c34fbecf1157c2ae88e57e85ef67f6f82de33`
- authoring-input work copy:
  `/var/tmp/iap-s0-authoring-work/IAP-INTEGRATION-PREP`
- committed authoring input: commit
  `bd57188e762172b3abf5bb46877bc93a0400dd89`,
  `contracts/IAP-M1-001/tasks.md` SHA-256
  `09859ee581796b9bfd29680245ba24224d707e1e807779fd6b82e479c3906429`
  (only that one line was committed; the original repo remains at `841ed86…` with
  its other uncommitted changes untouched)
- the 008 contract was derived from the **committed** authoring input, not from the
  consumed 007 artifacts; only the task ID/task-root substitutions and the S0 label
  were applied
- generator: `/var/tmp/IAP-CONTROL-DEV/stack`, commit
  `f45b1ae5a34f4ee9b0c6496ff141c127e2601d1f`,
  `specification/compiler/build_contract.py` SHA-256
  `8de6d8384549195d51b5a13fe0175a743a41c5d5143219e6b9ce54a3099a770c`
  (`hash_manifest.py` → `build_contract.py` → `validate_package.py`)
- 008 contract manifest: `12931e961343ed2f9b8975ceb703f169427f61bbdc8c13bb9d804d94216527f1`
- 008 `EXECUTOR-PROMPT.md`: `c8c68c1d5a7cba8a065ab78ca0ece407709b28185fef421423639b74e8c1698e`
- 008 `tasks.md`: `8d2f790557d8e263385cdf263cdaae24b9c27a875bb0cdb9e590f6efbb7e63c1`
- contract gates: `schema=PASS traceability=PASS boundaries=PASS acceptance=PASS
  hashes=PASS`; `READY.json status=READY`
- baseline (unchanged): `177680708739a72a0d70bc6a9664245b00a2ef08`
- model, provider/route and the 120 s budget are unchanged

The reviewed TASK-01 execution order is in the authoring input and therefore in the
generated `EXECUTOR-PROMPT.md`: one ordered information-gathering pass for the existing
reads, manifest verification and `PREP-BINDING` read; then the four real commands and the
four labeled `EVIDENCE.txt` lines once; then the existing evidence check and immediate
stop. A non-zero required step stops and reports; no autonomous repair loop. The actual
outputs, binding comparison, guard, four-line format and budget are unchanged. Evidence is
still produced by the model task inside the sandbox; the host/Bridge never pre-writes it.

## Verified identity and state (read-only)

- Bridge: `WAITING_FOR_GPT`, `expected_sequence=12`, `pending_result.json` **ABSENT**
- `/var/tmp/IAP-SMOKE-008` **ABSENT**
- ledger `/var/lib/aegl-smoke/IAP-SMOKE-008` **ABSENT**
- registry has **no** `IAP-SMOKE-008` entry
- supervisor has **no** `IAP-SMOKE-008` campaign directory (`CLEAN`)
- contract target
  `/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/IAP-SMOKE-008`
  **ABSENT**
- `/var/tmp/aegl-diag` is `root:root 0700`; an ordinary user therefore reports
  `DIAG_SINK=UNKNOWN`. The root preflight checks the existing 008 sink **first** and
  treats `UNKNOWN` as a hard stop, never as absent.

## Installed pins (verified only; not reinstalled)

| file | SHA-256 | owner:group | mode |
|---|---|---|---|
| `aegl-hermes-sandbox` (predecessor) | `dc954c59ed4cadf6c7567679045c1d35cd529f3b19237228b1bb08dc6048d4f5` | root:root | 0755 |
| `model_broker.py` | `7aa88b1831ca18fdbe9b14273321a90b352bb6026299b9bb9c26d4ca9b8ee59a` | root:root | 0644 |
| `tool_event_client.py` | `f70630cacfdcb1afd5eff08ad20ada9737c91b097a42741a122a0fa651df83bf` | root:root | 0644 |
| `tool_observer_config.py` | `424369561202ca48f122b8116fc6b2ebca8cbb1d108dbeb04674608b807591c3` | root:root | 0644 |
| `guard/contract_guard.py` | `19f6be638c37b28d401820b7a4562f852a459188cbfa793f757668fe9b330455` | root:root | 0444 |
| `git_meta_mounts.sh` | `f93bbfdd286e6a554c10edcdda6dd40a20d32d1ffbcb17dc56091bbeac8ac50a` | root:root | 0755 |

The only deployed change is the launcher diagnostic allowlist: one line, appending
`IAP-SMOKE-008` after all existing entries. New payload SHA-256:
`0bcb76d1bc4366691d9eb8cd38333bdb4a9d963c28213de21d63accf4d8c733a`.
The broker, both observer modules, the guard and the helper are neither modified nor
reinstalled.

## Launcher pin continuity (prep → execute)

- Preflight accepts exactly two approved launcher hashes, only as a regular non-symlink
  `root:root 0755` file: predecessor `dc954c59…` and the 008 candidate `0bcb76d1…`.
  Any other hash, wrong owner/mode or a symlink stops.
- Final `verify_live_state` and every pre-send path require the **008 candidate** hash
  only; the predecessor is not accepted there.
- The other five component pins remain strict and unchanged.
- Targeted ordinary-user checks cover predecessor admission, candidate execute gate,
  unknown hash, symlink and owner/mode rejection. The owner/mode case uses a `stat` stub,
  so it proves the admission gate only; real root ownership is verified on the installed
  files and in the root path, which remains `NOT_RUN`.

## Contract and stage order

- contract source: `contract/IAP-SMOKE-008`
- target: the trusted contracts path for `IAP-SMOKE-008`
- exactly four labeled `EVIDENCE` lines are retained for `/var/tmp/IAP-SMOKE-008/project`
- host `PREP-BINDING`: regular file, non-symlink, numeric `0:0`, mode `0644`, content
  matches worktree/commit/contract. Sandbox: readable, not writable, mode `0644`, content
  match. Sandbox owner names are diagnostic only.
- stage order: `preflight → sandbox_diag → baseline → worktree → permissions → contract
  → binding → register → probe → ready`. The registration order
  `contract → binding → register → probe → ready` is preserved.
- default entry only prepares and stops at `PREP_COMPLETE`. `--execute` must be given
  explicitly; it was not run in this round.

## Verification performed

```sh
/var/tmp/IAP-SMOKE-008-prep-r1/bin/run_smoke.sh --self-test
```

Result: `SELFTEST pass=30 fail=0`. Coverage: package integrity; shell/Python syntax;
contract validator and regeneration with the declared Stack generator; generator
provenance; 008 contract consistency including the reviewed execution order; launcher
payload/allowlist; six installed pins; launcher predecessor/candidate admission; execute
gate candidate-only hash; launcher owner/mode stub; live-state and pre-send candidate pin;
Stack pins; Bridge seq=12; `DIAG_SINK=UNKNOWN` and permission handling; task-root/ledger/
registry/supervisor/contract states; absence of 006 continuation code; PREP stage order;
and sink-first preflight ordering. `--status` was also run as an ordinary user.

The self-test records explicit files and directories at creation. On success it removes
them with non-forced `rm` and reverse `rmdir`; on an assertion or cleanup failure it
keeps the scene and reports `SCENE_KEPT`. There is no recursive force delete, force/prune,
gate relaxation or unknown-state repair.

## NOT_RUN

- real root PREP and any real `IAP-SMOKE-008` scene creation/registration;
- launcher installation (the payload is packaged, not deployed);
- model call, send, wait, round or accept;
- `r10` root check rerun, the unchanged 23-item production suite, and any old-task replay;
- any Bridge/registry/supervisor write and any deployment.
