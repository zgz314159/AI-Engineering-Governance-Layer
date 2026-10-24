# GT1 — trusted delivery, promotion, sync, install, and root acceptance

## 0. Delivery record

- Functional payload: `e5f31c8227353e60683c86a6092b93561da30c74`
- Baseline: `d36f073ba98fd00e2678d773d06aa44723a0b728`
- Final promotion tip: the commit containing the GT1 payload **and** this delivery
  package. The exact tip SHA is returned in the review reply and must be supplied to
  the command below; it is intentionally not written into the commit itself.
- The final tip, not the payload-only commit, is promoted.

Centralized verification was run **three times**, exceeding the original one-rerun
budget:

1. Run 1: 23 tests, **11 errors + 5 failures**. Cause: test fixture default umask made
   the contract directory/files group/other-writable (0775/0664).
2. Run 2: 23 tests, **10 errors + 4 failures**. Cause: the fixture registry file was
   created as 0664 by `write_text`.
3. Run 3: **23/23 PASS**, 0.132s.

The failures are preserved in this record. Only fixture permissions changed between
runs; production logic was not changed because of them. No system re-audit was done.

## 1. Fixed host impact

Only this path is created:

```text
/usr/local/lib/aegl-model-task/                                  root:root 0755
/usr/local/lib/aegl-model-task/bin/                              root:root 0755
/usr/local/lib/aegl-model-task/bin/aegl-model-task               root:root 0755
/usr/local/lib/aegl-model-task/recovery/                         root:root 0755
/usr/local/lib/aegl-model-task/recovery/model_task_registry.py   root:root 0644
```

Not touched: `/usr/local/lib/aegl-model` (launcher/modules), formal AEGL `.git`
permissions, global Git config, mounts, ACL policy, systemd, broker whitelist, other
projects. The installer stops if the target already exists and never overwrites unknown
files. Pre-install failures create no target; a post-move verification failure keeps the
target for inspection and exits nonzero.

## 2. Trusted identity model

- Root: bootstrap copy, hash verification, execution of the extracted delivery scripts,
  install, and cleanup of explicitly allocated root paths.
- `aegl-promote`: all git reads/fetches/archives of the formal repo and the fixed
  development checkout; pre-CAS check; candidate worktree; formal sync; object import.
- `aegl-ai`: broker `promote` requester and the non-root CLI acceptance probe.
- No root git status/archive in an AI-modifiable checkout. No global
  `safe.directory`; only command-level `-c safe.directory=<exact dev path>` for the
  fixed import/archive read.
- The candidate worktree is created from the formal repo at the final tip. Its temp
  parent is root-owned 0750 with an ACL granting `aegl-promote` only; `aegl-ai` cannot
  write it.

## 3. What `deliver-gt1.sh` does

The script is run as root from a root-exclusive copy. It never executes a script from
`/var/tmp` directly.

1. `STAGE=import`: `aegl-promote` fetches the final tip from the fixed development
   checkout into the formal object store using the existing `git fetch <DEV> <TIP>`
   import pattern. It verifies the tip object, payload ancestry, baseline ancestry, and
   the two payload file hashes.
2. `STAGE=pre_cas`: extracts the existing `BEGIN_FORMAL_SYNC` block from the final tip's
   `recovery/keeplab-appprojects-exec.sh` (read as `aegl-promote`, written to a
   root-only file), verifies it contains `formal_pre_cas_check` and
   `sync_formal_to_tip`, sources it, and calls `formal_pre_cas_check "$AEGL" main`.
   It requires `FORMAL_BASELINE_OID == d36f073…` and refuses real dirty/formal changes.
3. `STAGE=candidate`: creates a temporary candidate worktree from the formal repo at
   the final tip; verifies HEAD, clean state, base == baseline, and that `aegl-ai`
   cannot write it.
4. `STAGE=broker_register` / `RECORD` / `PROMOTE`: root sends register and record;
   `aegl-ai` sends promote. The broker task id is generated at runtime as
   `gt1-delivery-<timestamp>-<pid>` and is independent; an existing id is refused. Every reply is parsed; decisions must be `REGISTERED`,
   `RECORDED`, `APPLIED`; the returned `approved_commit` must equal the final tip.
5. `STAGE=candidate_cleanup`: `git worktree remove` **without `--force`**; `rmdir` only
   if empty. No `branch -D`. A failed or unexpected cleanup keeps the scene and exits
   nonzero.
6. `STAGE=formal_sync`: calls the existing `sync_formal_to_tip "$AEGL" "$TIP" main
   "$BASELINE"` as `aegl-promote`; verifies main, HEAD, branch `main`, and clean
   index/worktree. A bare `git switch main` is not used as a substitute for sync.
7. `STAGE=extract_delivery`: after promotion/sync, extracts the delivery scripts,
   manifest, documentation, and the two payload files from the **formal object store**
   as `aegl-promote`, into a root-exclusive directory. It verifies every manifest hash.
   The installer no longer depends on a development tree.
8. `STAGE=install`: runs the extracted installer with `--payload-dir` (root-exclusive,
   `root:root 0700`). It installs only `/usr/local/lib/aegl-model-task`.
9. `STAGE=accept`: runs the extracted temporary-registry root acceptance.
10. `STAGE=cleanup`: removes only the explicitly allocated candidate/root temp paths.
    The success marker is printed only after cleanup succeeds. On failure the bootstrap
`$BOOT` is kept and printed; on success it is removed only after the delivery script's
cleanup and success marker.

## 4. Temporary-registry root acceptance

The acceptance is **not** a real business registration and **not** a Hermes execution.
It uses a private mount namespace to map a temporary registry to
`/var/lib/aegl-model/registry.json` for that process only. The real registry is never
written; only its SHA-256 is compared before/after. Fixtures are created from scratch
outside the project and removed. No model/API/sandbox-model run is performed.

Expected markers:

```text
ACCEPT_INSTALLED_CLI_IMPORT=OK
ACCEPT_NON_ROOT_REGISTER=REJECTED
ACCEPT_ROOT_REGISTER=REGISTERED
ACCEPT_EXISTING_ENTRY=PRESERVED
ACCEPT_REGISTRY_OWNER_MODE=root:root 644
ACCEPT_LOCK_OWNER_MODE=root:root 600
ACCEPT_DUPLICATE=REJECTED
ACCEPT_REAL_REGISTRY_UNCHANGED=OK
ACCEPT_CLEANUP=OK
ACCEPT_SCOPE=TEMPORARY_REGISTRY_PRIVATE_MOUNTNS
ROOT_CLI_ACCEPTANCE=PASS (temporary registry)
```

## 5. Complete trusted terminal command

The final tip SHA and the manifest SHA are supplied by the review reply. Do not execute
before both are assigned. The functional payload and baseline below are fixed.

```bash
set -euo pipefail
TIP=<EXACT_FINAL_TIP_SHA_FROM_REVIEW_REPLY>
MANIFEST_SHA=<EXACT_MANIFEST_SHA_FROM_REVIEW_REPLY>
PAYLOAD=e5f31c8227353e60683c86a6092b93561da30c74
BASELINE=d36f073ba98fd00e2678d773d06aa44723a0b728
DEV=/var/tmp/aegl-cursor-project-rules-dev
AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer
BOOT=$(mktemp -d /root/gt1-bootstrap.XXXXXX)
chmod 0700 "$BOOT"

# aegl-promote reads the fixed delivery files from the final tip; root writes the
# root-exclusive copy. No root git in the development checkout.
runuser -u aegl-promote -- git -C "$DEV" -c "safe.directory=$DEV" archive "$TIP" \
  recovery/deliver-gt1.sh recovery/gt1-install-manifest.txt \
  | tar -x -C "$BOOT"

# root verifies the manifest anchor from the review reply, then the deliver script
echo "$MANIFEST_SHA  $BOOT/recovery/gt1-install-manifest.txt" | sha256sum -c -
DELIVER_SHA=$(awk '$1=="recovery/deliver-gt1.sh"{print $2}' "$BOOT/recovery/gt1-install-manifest.txt")
test "$(sha256sum "$BOOT/recovery/deliver-gt1.sh" | awk '{print $1}')" = "$DELIVER_SHA"

# root executes only the root-exclusive, hash-verified delivery script
set +e
"$BOOT/recovery/deliver-gt1.sh" --tip "$TIP" --dev "$DEV" --aegl "$AEGL"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  rm -f "$BOOT/recovery/deliver-gt1.sh" "$BOOT/recovery/gt1-install-manifest.txt" \
    || { printf 'BOOTSTRAP_CLEANUP_FAILED=%s\n' "$BOOT" >&2; exit 1; }
  rmdir "$BOOT/recovery" "$BOOT" \
    || { printf 'BOOTSTRAP_CLEANUP_FAILED=%s\n' "$BOOT" >&2; exit 1; }
else
  printf 'BOOTSTRAP_PRESERVED=%s\n' "$BOOT" >&2
fi
exit "$rc"
```

The delivery script then imports/promotes/syncs the final tip, extracts the installer
and acceptance script from the formal object store as `aegl-promote`, verifies them,
installs, and runs the temporary-registry acceptance. It does not retain a dependency
on the development checkout for installation.

## 6. Stage output and failure-stop positions

Success stage markers, in order:

```text
STAGE=import
STAGE=pre_cas
STAGE=candidate
STAGE=broker_register
STAGE=broker_record
STAGE=broker_promote
STAGE=candidate_cleanup
STAGE=formal_sync
STAGE=extract_delivery
STAGE=install
STAGE=accept
STAGE=cleanup
GT1_DELIVERY_RESULT=OK tip=<TIP>
GT1_FORMAL_SYNC=OK
GT1_INSTALL=OK
GT1_ROOT_ACCEPTANCE=PASS (temporary registry)
```

Failure-stop:

- Import/tip/payload/baseline hash mismatch: `STOP_AT=...`; no promotion.
- `FORMAL_BASELINE_OID != d36f073…`, formal dirty, gitlink drift: stop before CAS.
- Candidate dirty / AI can write / base mismatch: stop; the candidate path is printed as
  `CANDIDATE_DIR=...` and the scene is preserved.
- Broker decision not `REGISTERED`/`RECORDED`/`APPLIED`, or approved commit not TIP:
  stop; candidate scene is preserved.
- Worktree remove without force fails, or temp dir is non-empty: cleanup error; scene is
  preserved and the process exits nonzero; **no success marker**.
- `sync_formal_to_tip` fails or main/HEAD/branch/worktree checks fail: stop; no install.
- Delivery extraction/hash failure: stop; no install.
- Install or acceptance failure: nonzero; installed target (if any) is preserved for
  inspection; no success marker.
- Success markers are emitted only after cleanup succeeds.

No `worktree remove --force`, no `branch -D`, no `rm -rf` on candidate/unknown paths, no
backup/archive rollback.

This round did not sudo, install, promote, write the real registry, create
Microcourse-Studio, register a real task, run the 23 tests, run the privileged
acceptance, or push.

```text
GT1_INSTALLED=NOT_DONE
ROOT_CLI_ACCEPTANCE=NOT_RUN
MICROCOURSE_PROJECT_CREATED=NO
REAL_TASK_REGISTERED=NO
```
