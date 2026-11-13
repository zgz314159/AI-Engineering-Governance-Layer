# SYSTEM-E2E-001 — system contract-compile closed-loop acceptance

This directory freezes one disposable task that compiles the Stack's `valid_package`
fixture with the declared, hash-pinned compiler and writes an artifact-derived
`RESULT.json`. Nothing here sends a chat message, calls a model or executes a task.

## Fixed identity and sources

| Item | Value |
| --- | --- |
| Task id | `SYSTEM-E2E-001` |
| Fixture id | `FIXTURE-B1-CONTRACT` |
| Stack source | `/var/tmp/IAP-CONTROL-DEV/stack` at `73024141b8f2153ee9a7299832f58ddf08356039` |
| Fixture | `specification/tests/fixtures/valid_package` (9 files) |
| Compiler | `hash_manifest.py`, `build_contract.py`, `validate_package.py`, `spec_lib.py`, `VERSION` |
| Schemas | `specification/contracts/*.schema.json` (3 files) |
| Project binding | `ImageAnalysisFactory`, base `177680708739a72a0d70bc6a9664245b00a2ef08` |
| Scene | `/var/tmp/SYSTEM-E2E-001` (`project/` worktree, `scratch/`) |
| Contract install | `/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/SYSTEM-E2E-001` |
| Registry | `/var/lib/aegl-model/registry.json` |

`SOURCE.sha256` pins every authored contract byte and every declared input byte.
`contract/SYSTEM-E2E-001/inputs/INPUTS.sha256` pins the fixture, compiler, VERSION and
schemas that the executor may use. `prepare.sh` embeds the digest of both pin files, the
Stack commit and the ImageAnalysisFactory base commit.

## Trusted preparation (this round: NOT RUN)

```bash
bash /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_001/prepare.sh --verify-only
sudo bash /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_001/prepare.sh
```

Full preparation refuses an existing `SYSTEM-E2E-001` registry entry or scene, verifies
every pinned byte, creates the detached worktree, compiles the authored contract with the
pinned compiler, installs it under the trusted contract root, writes the root-owned
`INPUTS-PIN.json` at the task root and registers the single task. It stops with:

```text
PREP_COMPLETE task=SYSTEM-E2E-001 contract=<path> manifest_sha256=<64 hex>
```

No model is called and nothing is sent. The retained compile staging directory is printed
as `STAGE_RETAINED=` and is not deleted.

## Execution (this round: NOT RUN)

The task block must be produced in the fixed control conversation against the current
chain state; `sequence`, `nonce` and `in_reply_to` must match `bridge_cli.py status` and
must never be copied from a previous task. Its frozen fields are:

```json
{
  "protocol": "HERMES_TASK_V1",
  "task_id": "SYSTEM-E2E-001",
  "project": "ImageAnalysisFactory",
  "action": "EXECUTE_CONTRACT",
  "contract_package": "/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/SYSTEM-E2E-001",
  "contract_manifest_sha256": "<manifest_sha256 from PREP_COMPLETE>",
  "risk": "LOW",
  "max_runtime_s": 120
}
```

Entry, after the approved block is present:

```bash
cd /var/tmp/IAP-CONTROL-DEV/stack
BU_CDP_URL=http://127.0.0.1:9333 AEGL_HERMES_TASK_ID=SYSTEM-E2E-001 \
  python3 -B orchestration/hermes/bridge/bridge_cli.py round
```

One execution, 120 s runtime budget, 10 s wrapper grace, no retry, no recover, no budget
extension. Side effects: reads the control conversation, consumes the task identity,
launches the fixed root wrapper -> installed sandbox -> Hermes (one model call through the
broker), writes a durable pending result, sends exactly one result message and advances
the chain. It stops at the first failure.

## Independent host acceptance

```bash
python3 -B /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_001/accept.py
```

Read-only. It recomputes the outer package manifest, every declared input hash, every
compiled manifest member hash and the fixture-copy hashes; re-reads
`manifest.json`, `implementation-contract.json`, `validation-report.json` and `READY.json`;
checks the registry entry and the worktree binding; and requires `RESULT.json` to have
exactly seven keys with values equal to the artifacts. Success is:

```text
{"decision": "ACCEPT=OK", ...}
```

Missing files, extra fields, wrong types, invalid JSON, run-time source changes or an
inconsistent summary fail with `ACCEPT=FAIL code=...`.

## Launcher allowlist

The installed launcher has no per-task execution allowlist; the root registry is the
allowlist. `DIAG_ENABLED_TASKS` only enables diagnostic capture and is not needed here, so
no allowlist entry is proposed or installed.
