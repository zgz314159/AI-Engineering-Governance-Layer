# GT1 — trusted bundle delivery, promotion, sync, install, and root acceptance

## 0. Delivery record

- Functional payload: `e5f31c8227353e60683c86a6092b93561da30c74`
- Baseline: `d36f073ba98fd00e2678d773d06aa44723a0b728`
- Final promotion tip: the commit containing the GT1 payload **and** this delivery
  package. The exact tip SHA and manifest SHA are returned in the review reply; they are
  intentionally not written into the commit itself.
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

Only this path is created by the installer:

```text
/usr/local/lib/aegl-model-task/                                  root:root 0755
/usr/local/lib/aegl-model-task/bin/                              root:root 0755
/usr/local/lib/aegl-model-task/bin/aegl-model-task               root:root 0755
/usr/local/lib/aegl-model-task/recovery/                         root:root 0755
/usr/local/lib/aegl-model-task/recovery/model_task_registry.py   root:root 0644
```

The promotion/sync intentionally updates AEGL `main` from the baseline to the final tip
and syncs the formal checkout HEAD/index/worktree through the existing
`sync_formal_to_tip`. The broker registry receives one runtime task entry. No change is
made to `/usr/local/lib/aegl-model`, broker unit/whitelist, mounts, ACL policy, systemd,
formal `.git` permissions, global Git config, or other projects. The real
`/var/lib/aegl-model/registry.json` is not written; the acceptance uses a private mount
namespace.

Temporary inputs (cleaned on success, preserved and printed on failure):

- zhong: `/var/tmp/gt1-delivery-bundle.*.bundle`
- root: `/var/tmp/aegl-gt1-input.*` (root 0700, ACL `aegl-promote:r-x` only)
- root: `/root/gt1-bootstrap.*`, `/root/gt1-delivery.*`, `/root/gt1-payload.*`
- root: `/var/tmp/aegl-gt1-cand-*` (candidate worktree; removed without `--force`)
- acceptance: `/var/tmp/aegl-model-task-accept-*` (private mount namespace)

## 2. Trusted identity model

- **zhong**: all Git reads/exports of the fixed development checkout. The checkout is a
  linked-worktree gitfile; Git itself confirms the worktree, exact tip, baseline, and
  payload. zhong creates the candidate bundle and the delivery-file archive stream.
- **root**: creates the root-exclusive bootstrap/input directories, copies the zhong
  bundle into the trusted input directory, verifies hashes, runs the extracted delivery
  script, install, acceptance, and cleanup.
- **aegl-promote**: reads only the root-controlled trusted bundle copy and the formal
  repo. It runs `bundle verify`, `list-heads`, `fetch`, `formal_pre_cas_check`,
  candidate worktree, `sync_formal_to_tip`, and formal-object-store extraction. It never
  reads the zhong-private development object store.
- **aegl-ai**: broker `promote` requester and the non-root CLI acceptance probe.
- Root does not run git in an AI-modifiable checkout. No global `safe.directory` is used.
  The zhong Git reads use the normal zhong identity. The trusted bundle is root-owned,
  hash-verified, and readable only by root plus `aegl-promote` via ACL; `aegl-ai` cannot
  modify it.

The root input directory is under `/var/tmp`, which the trusted identity can traverse;
the bundle is not placed in `/root` and then assumed accessible to `aegl-promote`.

## 3. What `deliver-gt1.sh` does

The script is run as root from a root-exclusive copy. It never executes a script from
`/var/tmp` directly.

1. `STAGE=import`: verifies the bundle file's root ownership, non-group/other-writable
   mode, SHA-256, and `aegl-promote` readability. `aegl-promote` runs
   `git bundle verify`, `list-heads` (head must be `TIP refs/heads/gt1/model-task-registry`),
   and `git fetch <bundle> refs/heads/gt1/model-task-registry:...`. It then verifies the
   tip object, baseline/payload ancestry, temporary ref, and the two payload file hashes.
2. `STAGE=pre_cas`: extracts the existing `BEGIN_FORMAL_SYNC` block from the final tip's
   `recovery/keeplab-appprojects-exec.sh` (read as `aegl-promote`, written to a root-only
   file), verifies it contains `formal_pre_cas_check` and `sync_formal_to_tip`, sources
   it, and calls `formal_pre_cas_check "$AEGL" main`. It requires
   `FORMAL_BASELINE_OID == d36f073…` and refuses real dirty/formal changes.
3. `STAGE=candidate`: creates a temporary candidate worktree from the formal repo at
   the final tip; verifies HEAD, clean state, base == baseline, and that `aegl-ai`
   cannot write it. The candidate path is printed as `CANDIDATE_DIR=...`.
4. `STAGE=broker_register` / `RECORD` / `PROMOTE`: root sends register and record;
   `aegl-ai` sends promote. The broker task id is generated at runtime as
   `gt1-delivery-<timestamp>-<pid>` and is independent; an existing id is refused.
   Every reply is parsed; decisions must be `REGISTERED`, `RECORDED`, `APPLIED`; the
   returned `approved_commit` must equal the final tip.
5. `STAGE=candidate_cleanup`: `git worktree remove` **without `--force`**; `rmdir` only
   if empty. No `branch -D`. A failed or unexpected cleanup keeps the scene and exits
   nonzero.
6. `STAGE=formal_sync`: calls the existing `sync_formal_to_tip "$AEGL" "$TIP" main
   "$BASELINE"` as `aegl-promote`; verifies main, HEAD, branch `main`, and clean
   index/worktree. A bare `git switch main` is not used as a substitute for sync.
7. `STAGE=extract_delivery`: after promotion/sync, extracts the delivery scripts,
   manifest, documentation, and the two payload files from the **formal object store**
   as `aegl-promote`, into a root-exclusive directory. It verifies the exact file list
   and every manifest hash. The installer does not depend on the development tree.
8. `STAGE=install`: runs the extracted installer with `--payload-dir` (root-exclusive,
   `root:root 0700`). It installs only `/usr/local/lib/aegl-model-task`.
9. `STAGE=accept`: runs the extracted temporary-registry root acceptance.
10. `STAGE=cleanup`: removes only the explicitly allocated candidate/root temp paths.
    Success is printed only after cleanup succeeds.

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

## 5. Complete command from a normal zhong terminal

The final tip SHA and manifest SHA are supplied by the review reply. The payload and
baseline are fixed. The block uses explicit `sudo`/`sudo -u aegl-promote` identity
blocks and runs in a subshell; it prints the final command exit code.

```bash
(
  set -euo pipefail
  TIP=<EXACT_FINAL_TIP_SHA_FROM_REVIEW_REPLY>
  MANIFEST_SHA=<EXACT_MANIFEST_SHA_FROM_REVIEW_REPLY>
  PAYLOAD=e5f31c8227353e60683c86a6092b93561da30c74
  BASELINE=d36f073ba98fd00e2678d773d06aa44723a0b728
  CLI_SHA=edb38c2155f617417c8f225128144fba94c822db317a799613fa5e9203669b6e
  MOD_SHA=0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de
  DEV=/var/tmp/aegl-cursor-project-rules-dev
  AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer
  REF=refs/heads/gt1/model-task-registry

  # zhong: confirm the gitfile/linked worktree and the exact tip with Git itself.
  test "$(git -C "$DEV" rev-parse --is-inside-work-tree)" = true
  test "$(realpath "$(git -C "$DEV" rev-parse --show-toplevel)")" = "$(realpath "$DEV")"
  test "$(git -C "$DEV" rev-parse HEAD)" = "$TIP"
  test "$(git -C "$DEV" rev-parse "$REF")" = "$TIP"
  git -C "$DEV" cat-file -e "$TIP^{commit}"
  git -C "$DEV" merge-base --is-ancestor "$BASELINE" "$TIP"
  git -C "$DEV" merge-base --is-ancestor "$PAYLOAD" "$TIP"
  test "$(git -C "$DEV" show "$TIP:bin/aegl-model-task" | sha256sum | awk '{print $1}')" = "$CLI_SHA"
  test "$(git -C "$DEV" show "$TIP:recovery/model_task_registry.py" | sha256sum | awk '{print $1}')" = "$MOD_SHA"

  # zhong: export the exact candidate bundle (fixed branch ref + baseline cut).
  BUNDLE_ZHONG=$(mktemp /var/tmp/gt1-delivery-bundle.XXXXXX.bundle)
  git -C "$DEV" bundle create "$BUNDLE_ZHONG" "$REF" "^$BASELINE"
  BUNDLE_SHA=$(sha256sum "$BUNDLE_ZHONG" | awk '{print $1}')
  git -C "$DEV" bundle verify "$BUNDLE_ZHONG"
  git -C "$DEV" bundle list-heads "$BUNDLE_ZHONG" | grep -q "^$TIP $REF$"

  # root: root-exclusive bootstrap dir; zhong streams the fixed delivery files into it.
  BOOT=$(sudo mktemp -d /root/gt1-bootstrap.XXXXXX)
  sudo chmod 0700 "$BOOT"
  git -C "$DEV" archive "$TIP" recovery/deliver-gt1.sh recovery/gt1-install-manifest.txt \
    | sudo tar -x -C "$BOOT"
  sudo sh -c 'echo "$1  $2" | sha256sum -c -' _ "$MANIFEST_SHA" "$BOOT/recovery/gt1-install-manifest.txt"
  DELIVER_SHA=$(sudo awk '$1=="recovery/deliver-gt1.sh"{print $2}' "$BOOT/recovery/gt1-install-manifest.txt")
  test "$(sudo sha256sum "$BOOT/recovery/deliver-gt1.sh" | awk '{print $1}')" = "$DELIVER_SHA"

  # root: trusted input dir, readable by aegl-promote only, not AI-writable.
  INPUT_DIR=$(sudo mktemp -d /var/tmp/aegl-gt1-input.XXXXXX)
  sudo chmod 0700 "$INPUT_DIR"
  sudo chown root:root "$INPUT_DIR"
  sudo setfacl -m u:aegl-promote:r-x "$INPUT_DIR"
  sudo install -o root -g root -m 0400 "$BUNDLE_ZHONG" "$INPUT_DIR/gt1.bundle"
  sudo setfacl -m u:aegl-promote:r-- "$INPUT_DIR/gt1.bundle"
  test "$(sudo sha256sum "$INPUT_DIR/gt1.bundle" | awk '{print $1}')" = "$BUNDLE_SHA"
  sudo -u aegl-promote test -x "$INPUT_DIR"
  sudo -u aegl-promote test -r "$INPUT_DIR/gt1.bundle"

  # aegl-promote: verify the trusted copy's head and prerequisites against the formal repo.
  sudo -u aegl-promote -- env HOME=/tmp GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git bundle list-heads "$INPUT_DIR/gt1.bundle" | grep -q "^$TIP $REF$"
  sudo -u aegl-promote -- env HOME=/tmp GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -C "$AEGL" bundle verify "$INPUT_DIR/gt1.bundle"

  # root: run the root-exclusive, hash-verified delivery script.
  set +e
  sudo "$BOOT/recovery/deliver-gt1.sh" \
    --tip "$TIP" --bundle "$INPUT_DIR/gt1.bundle" --bundle-sha256 "$BUNDLE_SHA" --aegl "$AEGL"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    sudo rm -f "$INPUT_DIR/gt1.bundle" "$BOOT/recovery/deliver-gt1.sh" "$BOOT/recovery/gt1-install-manifest.txt"
    sudo rmdir "$INPUT_DIR" "$BOOT/recovery" "$BOOT"
    rm -f "$BUNDLE_ZHONG"
    printf 'GT1_DELIVERY_INPUT_CLEANUP=OK\n'
    printf 'GT1_DELIVERY_COMMAND_RESULT=OK tip=%s\n' "$TIP"
    exit 0
  else
    printf 'GT1_DELIVERY_INPUT_PRESERVED=%s BUNDLE_ZHONG=%s BOOT=%s\n' \
      "$INPUT_DIR" "$BUNDLE_ZHONG" "$BOOT" >&2
    exit "$rc"
  fi
)
gt1_rc=$?
printf 'GT1_DELIVERY_COMMAND_EXIT=%s\n' "$gt1_rc"
(exit "$gt1_rc")
```

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
GT1_DELIVERY_INPUT_CLEANUP=OK
GT1_DELIVERY_COMMAND_RESULT=OK tip=<TIP>
GT1_DELIVERY_COMMAND_EXIT=0
```

Failure-stop:

- zhong: gitfile/worktree/tip/baseline/payload/hash mismatch, bundle create/verify/head
  mismatch: stop before any root input or promotion.
- root: root-exclusive dir/hash mismatch, bundle not readable by `aegl-promote`, trusted
  bundle head/verify mismatch: stop before running the delivery script.
- `STAGE=import`: bundle hash/verify/head/fetch/ref or payload hash mismatch:
  `STOP_AT=...`; no promotion.
- `STAGE=pre_cas`: `FORMAL_BASELINE_OID != d36f073…`, formal dirty, gitlink drift: stop
  before CAS.
- `STAGE=candidate`: candidate dirty / AI can write / base mismatch: stop; the candidate
  path is printed as `CANDIDATE_DIR=...` and preserved.
- `STAGE=broker_*`: decision not `REGISTERED`/`RECORDED`/`APPLIED`, or approved commit
  not TIP: stop; candidate preserved.
- `STAGE=candidate_cleanup`: worktree remove without force fails, or directory not
  empty: scene preserved, nonzero, no success.
- `STAGE=formal_sync`: sync or main/HEAD/branch/worktree checks fail: no install.
- `STAGE=extract_delivery`: file list or manifest hash mismatch: no install.
- `STAGE=install` / `STAGE=accept`: install/accept failure: nonzero, installed target
  preserved for inspection, no success.
- `STAGE=cleanup`: cleanup failure: scene preserved, nonzero, no success.
- Root input/bootstrap cleanup failure: nonzero; input/boot paths preserved and printed.
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
