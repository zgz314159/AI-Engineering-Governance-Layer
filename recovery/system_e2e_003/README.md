# SYSTEM-E2E-003 — two-call authoring draft (not prepared, not registered)

Authoring inputs only. `SYSTEM-E2E-001` and `SYSTEM-E2E-002` are consumed and untouched.
No task scene, registry entry or diagnostic sink was created for 003.

The inputs are derived from SYSTEM-E2E-002 with the same fixture, compiler, schemas,
`INPUTS.sha256` and frozen acceptance. Only the task identity, paths and the ordering of
the executor instructions changed.

## Fixed sources and hashes

| Item | Value |
| --- | --- |
| Task id | `SYSTEM-E2E-003` |
| Fixture id | `FIXTURE-B1-CONTRACT` |
| Stack / generator | `specification/compiler` at `73024141b8f2153ee9a7299832f58ddf08356039` |
| Compiler hashes | hash_manifest `bdd6acb5…`, build_contract `8de6d838…`, validate_package `c64dbcc8…`, spec_lib `300b3492…`, VERSION `e9dd8507…` |
| Declared inputs | `INPUTS.sha256` = `509cbc0f44d8294d4059a77397c4bfae95071caabb64844ce2f2ff3cc260eec6` |
| Authored inputs | `SOURCE.sha256` = `bde7693e5da60ddc77aa169af74167a96c3b4debf9ffa8fe178dc23a5303a16d` |
| Compiled manifest (fixed basename) | `ed644f2089040f504b877000f8efa64760492eb6b6a4a49408504397f06cc52a` |
| Generated executor prompt | `efe8d7f2754bf1d01da8f806b3c88e3cbc254939b40c931cc59dc7f30bdda377` |

The manifest and prompt hashes are the deterministic outputs for the authored files and
the fixed package basename `SYSTEM-E2E-003`. The future preparation must still generate
and verify them from this draft.

## Required executor order

The generated prompt has exactly two CLI checks:

1. `read` — one terminal call: verify the contract manifest and READY, then print
   implementation-contract, project-context, the declared INPUTS-PIN, requirements,
   acceptance, design, DESIGN, tasks and verification-intent in order. No separate
   read_file calls.
2. `execute` — one terminal call: read the worktree from the prepared INPUTS-PIN, reject an
   existing `e2e`/`RESULT.json` or link, verify every input hash in a subshell, copy the
   fixture, run hash_manifest/build_contract/validate_package once each, extract the
   actual summary into RESULT.json, perform the result check inside the same call, and
   print `EXEC_STAGE=COMPLETE`. No compiler/validation re-run.

After the second call the executor only gives the final reply. Host acceptance is
out-of-session. The task goal, requirements, acceptance, design and verification intent
all point to this same pair; the generated prompt contains no separate copy/hash/build/
validate/result checks and no re-run instruction.

## Offline results

- Isolated recompilation: `STATUS=READY`, five gates PASS, errors=0; `8/1/1/READY/0`.
- `read` command: `READ_STAGE=CONTRACT_OK entries=8 ready=READY` … `READ_STAGE=COMPLETE`.
- `execute` command: `INPUTS_OK`, three compiler records, `STATUS=READY`, `RESULT_WRITTEN`,
  `EXEC_SUMMARY` with `SYSTEM-E2E-003` and 8/1/1/READY/0, `EXEC_STAGE=COMPLETE`.
- Rejections: existing `e2e` and dangling `RESULT.json` link → `EXEC_FAIL stage=target`;
  input hash failure → `stage=inputs` with no copy/RESULT; empty requirements →
  `stage=build_contract` with no RESULT; stale authored hash → `READ_FAIL`.
- The fixture/compiler/schema bytes are identical to SYSTEM-E2E-002 (`INPUTS.sha256`
  unchanged and `sha256sum -c` passes).

The offline READY and command checks used an isolated mapping (temporary source_root and
INPUTS-PIN); no real `/var/tmp/SYSTEM-E2E-003` scene was created. Real root/bwrap, guard
admission, model behavior and diagnostic persistence are NOT_RUN.

## Boundaries

No changes to build_contract.py, launcher, broker, observer, guard, wrapper, prepare.sh,
accept.py, model configuration, the 120 s budget or the frozen acceptance. No deployment
package, registration, send, round, recover or model call.
