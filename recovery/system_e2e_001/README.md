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

Read-only source/hash/identity check (no root, no writes):

```bash
bash /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_001/prepare.sh --verify-only
```

Full preparation must not run `prepare.sh` from this user-writable checkout. The root
entry below creates a unique root-private stage, copies the three entry files and every
declared member, verifies the pinned entry hashes and the whole copied member set, rejects
links and undeclared files, and only then executes the verified copy.

Entry pins:

| File | SHA-256 |
| --- | --- |
| `prepare.sh` | `60a7babe5a3df5d1ce2512637f00a1b4ea875a2974ecaa7751570f0d1d58d6f0` |
| `accept.py` | `a554931771b1498d462f68adfd1852e61824faccfcfcfc142b938f7493f77bdd` |
| `SOURCE.sha256` | `958c89103edc05df35997e4891ebfafde8101ab93871289f34091274c233c6a1` |

```bash
sudo env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  bash -s <<'ROOT_ENTRY'
set -euo pipefail
umask 077
SRC=/var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_001
BASE=/var/lib/aegl-model/prep-entry
ENTRY_SHA=60a7babe5a3df5d1ce2512637f00a1b4ea875a2974ecaa7751570f0d1d58d6f0
ACCEPT_SHA=a554931771b1498d462f68adfd1852e61824faccfcfcfc142b938f7493f77bdd
SOURCE_SHA=958c89103edc05df35997e4891ebfafde8101ab93871289f34091274c233c6a1
[ ! -L "$BASE" ] || { echo "ENTRY_FAIL base_link" >&2; exit 1; }
[ ! -e "$BASE" ] || [ -d "$BASE" ] || { echo "ENTRY_FAIL base_type" >&2; exit 1; }
install -d -m 0700 -o root -g root "$BASE"
STAGE="$(mktemp -d "$BASE/SYSTEM-E2E-001.XXXXXX")"
echo "ROOT_STAGE=$STAGE"
LOG="$STAGE/prep.log"
for f in prepare.sh accept.py SOURCE.sha256; do
  [ -f "$SRC/$f" ] && [ ! -L "$SRC/$f" ] || { echo "ENTRY_FAIL missing_or_link $f" >&2; exit 1; }
done
cp --no-dereference -- "$SRC/prepare.sh" "$STAGE/prepare.sh"
cp --no-dereference -- "$SRC/accept.py" "$STAGE/accept.py"
cp --no-dereference -- "$SRC/SOURCE.sha256" "$STAGE/SOURCE.sha256"
printf '%s  accept.py\n%s  prepare.sh\n%s  SOURCE.sha256\n' "$ACCEPT_SHA" "$ENTRY_SHA" "$SOURCE_SHA" \
  | ( cd "$STAGE" && sha256sum --strict -c - ) || { echo "ENTRY_FAIL entry_hash" >&2; exit 1; }
( cd "$SRC" && sha256sum --strict -c SOURCE.sha256 ) >/dev/null \
  || { echo "ENTRY_FAIL source_members" >&2; exit 1; }
EXPECTED="$STAGE.expected"; ACTUAL="$STAGE.actual"
printf '%s\n' SOURCE.sha256 accept.py prepare.sh > "$EXPECTED"
while IFS= read -r line; do
  rel="${line#*  }"
  case "$rel" in
    ''|/*|*..*) echo "ENTRY_FAIL bad_member $rel" >&2; exit 1 ;;
  esac
  [ -f "$SRC/$rel" ] && [ ! -L "$SRC/$rel" ] || { echo "ENTRY_FAIL member $rel" >&2; exit 1; }
  mkdir -p "$STAGE/$(dirname "$rel")"
  cp --no-dereference -- "$SRC/$rel" "$STAGE/$rel"
  printf '%s\n' "$rel" >> "$EXPECTED"
done < "$STAGE/SOURCE.sha256"
( cd "$STAGE" && sha256sum --strict -c SOURCE.sha256 ) >/dev/null \
  || { echo "ENTRY_FAIL copied_members" >&2; exit 1; }
[ -z "$(find "$STAGE" -type l -print -quit)" ] || { echo "ENTRY_FAIL symlink_in_stage" >&2; exit 1; }
sort -o "$EXPECTED" "$EXPECTED"
( cd "$STAGE" && find . -type f -printf '%P\n' | sort ) > "$ACTUAL"
diff -u "$EXPECTED" "$ACTUAL" || { echo "ENTRY_FAIL undeclared_or_missing" >&2; exit 1; }
rm -- "$EXPECTED" "$ACTUAL"
set +e
bash "$STAGE/prepare.sh" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "ROOT_ENTRY_EXIT=$rc LOG=$LOG STAGE=$STAGE"
exit "$rc"
ROOT_ENTRY
```

The entry prints `ROOT_STAGE=<dir>`, writes the preparation log to `<ROOT_STAGE>/prep.log`,
and exits with the preparation's real status. Success is:

```text
PREP_COMPLETE task=SYSTEM-E2E-001 contract=<path> manifest_sha256=<64 hex>
```

On failure it prints `ENTRY_FAIL ...` or `PREP_FAILED ...`, keeps the stage and log, and
does not retry, roll back or overwrite an existing scene. No model is called and nothing
is sent. The retained compile staging directory is printed as `STAGE_RETAINED=` and is not
deleted.

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
launches the fixed root wrapper -> installed sandbox -> Hermes for one controlled task
execution (the number of model requests inside the 120 s task is reported from the actual
record, not pre-claimed as one), writes a durable pending result, sends exactly one result
message and advances the chain. It stops at the first failure.

## Independent host acceptance

```bash
python3 -B /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_001/accept.py
```

Read-only. It recomputes the outer package manifest, every declared input hash, every
compiled manifest member hash and the fixture-copy hashes; re-reads
`manifest.json`, `implementation-contract.json`, `validation-report.json` and `READY.json`;
checks the registry entry and the worktree binding. It also requires the exact frozen
authored member set, the five frozen READY gates (`schema`, `traceability`, `boundaries`,
`acceptance`, `hashes`) with no extra gate, and the frozen values
`FIXTURE-B1-CONTRACT` / 8 / 1 / 1 / `READY` / 0, both between the artifacts and in
`RESULT.json`. Success is:

```text
{"decision": "ACCEPT=OK", ...}
```

Missing files, extra fields, wrong types, invalid JSON, run-time source changes or an
inconsistent summary fail with `ACCEPT=FAIL code=...`.

## Launcher allowlist

The installed launcher has no per-task execution allowlist; the root registry is the
allowlist. `DIAG_ENABLED_TASKS` only enables diagnostic capture and is not needed here, so
no allowlist entry is proposed or installed.
