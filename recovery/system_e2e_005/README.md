# SYSTEM-E2E-005 — de-inlined CLI checks with trusted preparation (PREPARATION ONLY)

`SYSTEM-E2E-005` is derived from the `SYSTEM-E2E-004` source. The business content, the
two-call plan (one consolidated read, one ordered execution), the model, the 120 s budget,
the 10 s cleanup grace, the guard and the independent acceptance baseline are unchanged.
`SYSTEM-E2E-001`/`002`/`003`/`004` and their history are untouched.

## Why this round exists

Both 004 terminal calls returned `exit_code=-1` with `status=blocked` and the observer
recorded `err=tool_error`. What is **proven** is the mechanism that produces that class of
envelope: the flattened CLI checks are judged dangerous by Hermes' own detector, and a
single-query (`--oneshot`) session defaults `approvals.single_query_mode` to `deny`, so the
command is refused before it is spawned. Measured on the real detector:

| 004 check | detector verdict |
| --- | --- |
| `read` | `script execution via heredoc` |
| `execute` | `script execution via -e/-c flag` |

`SYSTEM-E2E-001`/`002` used plain commands and were not affected; `003` and `004` did.

This is **not** a diagnosis of the 004 history. The raw `tool_result` text and traceback of
those two calls were never persisted, so the exact error string each call produced is
**UNKNOWN**, and the 004 `exit_code=124` task outcome stays **UNKNOWN** as well. This round
removes a reproduced, independent blocker; it does not claim either historical error is
confirmed, nor that 004 is fixed.

## What changed, and what did not

Five auxiliary read-only scripts now hold the fixed business code that used to be inline
(`<<'PY'` heredocs and `python3 -B -c '…'` one-liners), in the new read-only input bundle
directory `inputs/checks/`:

| Script | Replaces | Semantics |
| --- | --- | --- |
| `read_manifest_check.py` | the read heredoc | verifies every manifest member hash and `READY`, prints `READ_STAGE=CONTRACT_OK …` |
| `inputs_pin_path.py` | the `read` `-c` one-liner | prints `read_first[0].path` from `project-context.json` |
| `pin_worktree.py` | the `execute` `WT=` one-liner | prints `worktree` from the PIN |
| `write_result.py` | the `result` heredoc | writes `RESULT.json` from the generated artifacts |
| `check_result.py` | the `result_check` heredoc | re-reads `RESULT.json`, asserts it equals the artifacts and the frozen baseline |

Nothing else in the check flow changed: the same `STAGE=` labels, the same order
(`worktree → target → inputs → copy → hash_manifest → build_contract → validate → result →
result_check → done`), the same `trap`-based fail-fast, the same `INPUTS_OK` /
`EXEC_SUMMARY` / `EXEC_STAGE=COMPLETE` markers and the same 8/1/1/READY/0 baseline.

The scripts are ordinary, reviewable Python files: no encoding, no `eval`, no dynamic
generation, no network, and no business code hidden elsewhere. They read only; the only
writer is `write_result.py`, which writes `RESULT.json` in the worktree like before.

`allowed_paths` is still exactly `project`, and `inputs/` stays read-only. The auxiliary
scripts are declared inputs, not a new writable scope.

## Input bundle

The original **17** business inputs are byte-for-byte identical to 004; the 5 new scripts are
appended to `inputs/INPUTS.sha256` as separately declared members (22 lines total). The
input hash check, the acceptance baseline and every existing assertion are unchanged.

## Fixed values

| Item | Value |
| --- | --- |
| Task id | `SYSTEM-E2E-005` |
| Fixture id | `FIXTURE-B1-CONTRACT` |
| Stack / generator | `specification/compiler` at `cf52c3595fcdd642041f1308f554cecfebcb775d` |
| IAP baseline | `177680708739a72a0d70bc6a9664245b00a2ef08` |
| `SOURCE.sha256` | `c04ead8893e324738ee28ab1cdc03f5ca5065e2b509abf1fb82f0cc5365e4b03` |
| `INPUTS.sha256` | `15a34b86f42ec2e0f6ba668cdeb19d5e18de82239f03209fa6421b5995c06814` |
| Compiled manifest | `c5cf4264e3311cb6b28fbb411de8fa049aca55b11c9bb40f8b0b6f643944e036` |
| Generated prompt | `57eb8fd879f56f28cebae1ead1458b4addeedc8c1684c693518dd6b9fb7507cc` |
| Preparation entry | `prepare.sh` = `80fa5f09f94b4c559601f06d51795915b3167a1c16abb9887e2708ffd3a4c869` |
| Outer entry | `trusted-entry.sh` = `10899a20eee768c0bd5a11309d649f7923ce78d7ea9b3b5f24e033f9ac46f289` |
| Acceptance checker | `accept.py` = `9de90cdccbe160d0d2d6ec7d543deae7a8c8c872867d38071b05cfc313e09ebc` |
| Dependency pins | `DEPENDENCY-PINS.sha256` = `d04358440144ae8a05657e057fe3bd608f48407f41b30e827cb17acfded89fd9` |
| Launcher predecessor | `def13354e27797af82535c2bd1c9bbcb4acde4b6abec0004e2ce53fd2fe45ba6` |
| Launcher candidate | `a7c75e2d8277b0ebdcb7b467a7375ad1863086828f4a01e5bce55664e36865d3` |

Auxiliary scripts (also pinned in `prepare.sh` and `accept.py`):

| Script | sha256 |
| --- | --- |
| `check_result.py` | `dd68400bd8e7ffa9b94a2c4a7964700373cb3ab9e229cfd353bc796125d78d05` |
| `inputs_pin_path.py` | `ac47b633fcf69bc5623e7b842ac6390001bc42417e2a202f7cee4145cc7b0392` |
| `pin_worktree.py` | `fcbe0a51bf2bf93cc532964478f6d43659ae48d152445350bd1550d7d4eb9be3` |
| `read_manifest_check.py` | `128fd40c13fac14fa9109b009a988fe34df7fbca6e9700f8968edd16d6d5e67e` |
| `write_result.py` | `68f4f94b81c0d2fcaa434722a1d612d0a2cb9f0b4070737b6bd03c386622ce88` |

The candidate changes only `DIAG_ENABLED_TASKS`, appending `SYSTEM-E2E-005` after
`SYSTEM-E2E-004`; every old entry and every other byte is preserved (26773 → 26788 bytes,
exactly one differing line). Broker, observer, guard, helper and wrapper are unchanged.

## Order: transport install → outer entry (launcher + prepare.sh)

The dependency pins above are the **post-install** hashes, so the two reviewed transport
fixes must be installed first. Both are already reviewed and neither is part of this round.

1. **Install the reviewed transport fixes** (operator, trusted terminal):

   ```bash
   sudo bash /var/tmp/IAP-CONTROL-DEV/aegl/recovery/install-two-transport-files.sh
   ```

   It replaces only `model_broker.py` (`7aa88b18…` → `b9ff6a51…`) and `loopback_shim.py`
   (`75cf4ad6…` → `40e71b3d…`) and prints `INSTALL_OK model=b9ff6a51… shim=40e71b3d…`.
   The 005 entry fails closed at `dependency_hash` until this succeeds.

2. **Verify the entry digest, then run it** (operator, trusted terminal):

   ```bash
   sha256sum /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_005/trusted-entry.sh
   # expect 10899a20eee768c0bd5a11309d649f7923ce78d7ea9b3b5f24e033f9ac46f289

   sudo env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
     LANG=C.UTF-8 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
     bash /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_005/trusted-entry.sh
   ```

`trusted-entry.sh` is the same outer shape 003/004 used. It does, in this order:

1. creates a root-private stage and copies **only** `trusted-entry.sh`, `prepare.sh`,
   `accept.py`, `SOURCE.sha256`, `DEPENDENCY-PINS.sha256` and every member listed in
   `SOURCE.sha256`; each is verified against its fixed hash, symlinks and undeclared files
   are refused, and the staged set is compared to the declared set;
2. normalises the staged file modes to `0644` — under the entry's `umask 077` a plain `cp`
   produces `0600`, which `prepare.sh`'s auxiliary-input gate would correctly reject — and
   asserts all five staged `checks/*.py` are `0644` regular files;
3. runs the pre-install gates: identity unused (registry + journal), scene absent, Bridge
   `WAITING_FOR_GPT|IDLE` with no pending result and no unresolved accepted entry, no
   active task, `/run/aegl-model` empty;
4. installs **only** the launcher candidate, derived from the fixed predecessor `def13354…`
   by appending `SYSTEM-E2E-005` to `DIAG_ENABLED_TASKS`, and verifies `a7c75e2d…`;
5. runs `bash "$STAGE/prepare.sh"` **from the root-private copy**, tees to `prep.log`, and
   keeps the real `prepare`/`tee` exit codes in `ROOT_ENTRY_EXIT=… TEE_EXIT=…`.

Ownership/mode of every copied member and of the launcher, the re-check immediately before
the launcher replacement, and scene retention on failure are the 003/004 logic, unchanged.
`prepare.sh` itself does scene → compile → install → diag → **register** → **gate**; this
entry adds only the copy/verify, preflight and launcher steps, and claims nothing more.

`bash prepare.sh --verify-only` is the unprivileged, write-free pre-check. In the delivered
tree it currently stops at `PREP_FAILED stage=diag reason=launcher_hash` because the
installed launcher is still the 004 candidate; that is the expected state until step 2 runs.


## Offline / NOT_RUN

- **NOT RUN:** the transport install, the outer entry, the five-stage root preparation, task
  registration, the real `contract_executor.gate`, guard admission, any `--execute`, any model
  call and the independent host acceptance. This round delivered commands only.
- **SYNTHETIC (clearly not 004 history, not business acceptance):** the extracted scripts were
  compared against the 004 inline bodies on identical fixture copies (identical `RESULT.json`
  bytes, identical stdout and exit status); the real `_handle_terminal` was run in a real
  single-query approval context with the default `deny` policy, no yolo and no auto-approval;
  a full two-call run was executed against throwaway packages; and the fail-fast behaviour,
  the auxiliary-input gate and the acceptance checker were exercised against isolated copies.
- **SYNTHETIC entry drill (no sudo, nothing installed):** the entry's copy/verify stage was
  driven against a redirected `BASE`, confirming the 31-member set, the `0644` normalisation
  (without it the staged `prepare.sh` fails `aux_mode`) and the entry's running-copy equality.
  Links, a hash mismatch, an undeclared `checks/*.py` and a forced `0600` mode were each
  refused (`source_members`, `aux_count`, `aux_mode`). The launcher replacement and all later
  stages were not run.
- **UNKNOWN:** the raw `tool_result` error text and traceback of the two 004 calls were never
  persisted (the root diagnostic sink is unreadable to this identity) and the second request's
  normalized command hash matched no reconstruction. The exact 004 error string and the 004
  `exit_code=124` outcome therefore stay UNKNOWN. What this round proves is the *mechanism*
  behind that class of `exit_code=-1 blocked` envelope, not that either historical call has
  been diagnosed, and not that 004 is fixed.

