# GT1 — one-shot trusted install and root acceptance package

## 0. Delivery record (including the over-budget verification)

- Code candidate: `e5f31c8227353e60683c86a6092b93561da30c74`
- Candidate parent: `866c1d2b108d9911809bf5c542d1ad7351340599`
- Baseline: `d36f073ba98fd00e2678d773d06aa44723a0b728`
- Delivery package: this commit (the exact SHA is returned in the review reply)

This round's centralized verification was run **three times**, exceeding the original
one-rerun budget:

1. Run 1 after the fixes: 23 tests, **11 errors + 5 failures**. Cause: test fixture
   default umask made the contract directory/files group/other-writable (0775/0664).
2. Run 2 after fixing fixture directory/file modes: 23 tests, **10 errors + 4 failures**.
   Cause: the fixture registry file was created as 0664 by `write_text`.
3. Run 3 after fixing the fixture registry mode: **23/23 PASS**, 0.132s.

The failures are not erased. Only test fixture permissions changed between runs 1–3;
production logic was not changed in response to those failures. No system re-audit was
performed.

## 1. Fixed install layout

```text
/usr/local/lib/aegl-model-task/bin/aegl-model-task
/usr/local/lib/aegl-model-task/recovery/model_task_registry.py
```

- The `bin/../recovery` import relationship is preserved.
- Directories: `root:root 0755`; CLI: `root:root 0755`; module: `root:root 0644`.
- Nothing under `/usr/local/lib/aegl-model` (launcher/modules) is modified.
- The install script stops if `/usr/local/lib/aegl-model-task` already exists; it never
  overwrites unknown files.
- Only the two files below are extracted from the fixed commit, into a root-exclusive
  `/root/gt1-install-src.XXXXXX` directory, and SHA-256 verified before any install:

| Path | SHA-256 | Mode |
|---|---|---|
| `bin/aegl-model-task` | `edb38c2155f617417c8f225128144fba94c822db317a799613fa5e9203669b6e` | 0755 |
| `recovery/model_task_registry.py` | `0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de` | 0644 |

The installer uses `git archive` as root only for the fixed external checkout and a
per-command `safe.directory` for that checkout and its gitdir/common dir. It does not
change the formal tree, its `.git` permissions, or any global Git config. It does not
execute any source-tree script.

## 2. Install command (human, root, fixed candidate)

```bash
# The external checkout must be at the delivery commit (the commit returned in the
# review reply), clean, with e5f31c8... present in its history.
sudo /var/tmp/aegl-cursor-project-rules-dev/recovery/install-model-task-registry.sh \
  --source /var/tmp/aegl-cursor-project-rules-dev \
  --commit e5f31c8227353e60683c86a6092b93561da30c74
```

Expected success output:

```text
INSTALL_SOURCE_COMMIT=e5f31c8227353e60683c86a6092b93561da30c74
INSTALL_BASELINE=d36f073ba98fd00e2678d773d06aa44723a0b728
INSTALL_FILE bin/aegl-model-task sha256=edb38c... mode=0755 owner=root:root
INSTALL_FILE recovery/model_task_registry.py sha256=0b9376... mode=0644 owner=root:root
INSTALL_TARGET=/usr/local/lib/aegl-model-task
INSTALL_IMPACT=only /usr/local/lib/aegl-model-task created; /usr/local/lib/aegl-model and all other paths untouched
INSTALL=OK
```

Failure-stop:

- Not root, usage error, commit/parent/baseline mismatch, dirty source, target exists,
  untrusted parent, archive/hash/file-list mismatch, stage mode/hash mismatch: prints
  `INSTALL_FAILED reason=<reason>` and exits 1.
- A pre-install failure creates no target. The root-exclusive extraction/stage dirs are
  removed by the trap.
- If the final atomic move succeeds but post-move verification fails, the script prints
  `INSTALL_FAILED reason=<reason>` and exits 1 **without deleting the target**; stop and
  inspect. It does not create a backup or rollback copy.

## 3. Root acceptance command (temporary registry only)

```bash
sudo /var/tmp/aegl-cursor-project-rules-dev/recovery/accept-model-task-registry.sh
```

This is **not** a real business registration and **not** a Hermes execution. It is a
root CLI acceptance against a temporary registry mapped to the fixed path in a private
mount namespace.

What it proves:

- installed CLI import path works (`--help`);
- non-root `register` is rejected with exit 2 and `reason=not_root`;
- root can register one valid temporary task;
- duplicate `task_id` is rejected, the existing entry and first task remain;
- temporary registry is `root:root 644`, lock is `root:root 600`;
- atomic write succeeds; temporary files are cleaned;
- the real `/var/lib/aegl-model/registry.json` SHA-256 is unchanged before/after;
- the temporary fixture tree is removed.

Fixtures and contracts are under `/var/tmp/aegl-model-task-accept.XXXXXX`, outside the
project. They are created from scratch (never a copy of the production registry) and
removed on exit. No model, API, sandbox-model run, or broker call is made.

Expected success output:

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

Failure-stop:

- Missing installed files, hash/mode mismatch, missing tools, no private mount namespace,
  non-root test not returning 2/`reason=not_root`, root register not printing
  `REGISTERED`, duplicate not returning 3/`reason=duplicate_task_id`, changed bytes,
  wrong registry/lock owner/mode, or changed real registry: prints
  `ACCEPT_FAILED step=<step> reason=<reason>` and exits 1.
- The trap removes the temporary fixture tree. There is no fallback that writes the real
  registry, and no re-run of the 23 registration tests.

## 4. Candidate object import, broker promotion, formal sync

These steps are for the candidate `e5f31c8...`, not for this delivery-scripts commit.
They reuse the existing broker; no new promotion system, whitelist, mount, permission
policy, or other project is changed. They are **not executed in this round**.

### 4.1 Candidate object import

The candidate's objects live in the external common repo
`/var/tmp/aegl-parent-protection-dev-6yv9e5/repo/.git`, not in the formal AEGL object
store. Import the exact candidate through a temporary promote worktree and a bundle.

```bash
set -euo pipefail
AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer
BASE=d36f073ba98fd00e2678d773d06aa44723a0b728
CAND=e5f31c8227353e60683c86a6092b93561da30c74
EXT_COMMON=/var/tmp/aegl-parent-protection-dev-6yv9e5/repo
PROMOTE_WT=/var/tmp/aegl-gt1-promote-e5f31c8
BUNDLE=/var/tmp/gt1-e5f31c8.bundle

# as zhong: temporary promote worktree at the exact candidate
git -C "$EXT_COMMON" worktree add -b gt1-promote-e5f31c8 "$PROMOTE_WT" "$CAND"
git -C "$PROMOTE_WT" bundle create "$BUNDLE" gt1-promote-e5f31c8 "^$BASE"
git -C "$PROMOTE_WT" bundle verify "$BUNDLE"
git -C "$PROMOTE_WT" bundle list-heads "$BUNDLE"   # must show CAND and the temp branch
```

Then copy/verify the bundle into a root-controlled, `aegl-broker`-readable directory and
import it as the formal repo owner. Do not run a user-tree script as root.

```bash
# root: copy and verify the bundle
BUNDLE_SHA=$(sha256sum "$BUNDLE" | awk '{print $1}')
IMPORT_DIR=$(mktemp -d /root/gt1-import.XXXXXX)
chmod 0750 "$IMPORT_DIR"
chgrp aegl-broker "$IMPORT_DIR"
install -o root -g aegl-broker -m 0640 "$BUNDLE" "$IMPORT_DIR/gt1-e5f31c8.bundle"
test "$(sha256sum "$IMPORT_DIR/gt1-e5f31c8.bundle" | awk '{print $1}')" = "$BUNDLE_SHA"

# aegl-promote: import the verified bundle into the formal object store
sudo -u aegl-promote env HOME=/tmp GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$AEGL" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
  fetch "$IMPORT_DIR/gt1-e5f31c8.bundle" \
  refs/heads/gt1-promote-e5f31c8:refs/heads/gt1/model-task-registry

# verify object + target baseline
sudo -u aegl-promote git -C "$AEGL" cat-file -e "$CAND^{commit}"
test "$(sudo -u aegl-promote git -C "$AEGL" rev-parse refs/heads/gt1/model-task-registry)" = "$CAND"
test "$(sudo -u aegl-promote git -C "$AEGL" rev-parse refs/heads/main)" = "$BASE"
```

### 4.2 Broker register / record / promote

Use the existing broker client. Bind the exact candidate, baseline, promote worktree,
and target ref. The fixed broker task id below is an example for this promotion; if it
already exists in the broker registry, stop and choose a new one manually. It is not a
Hermes task.

```bash
BROKER=/usr/local/lib/aegl-promote/promotion_broker.py
SOCK=/run/aegl-promote/broker.sock
TASK_ID=gt1-e5f31c8-20261024

REGISTER_REQ='{"protocol":"AEGL-BROKER/1","op":"register","task_id":"gt1-e5f31c8-20261024","project":"/home/zhong/Projects/AI-Engineering-Governance-Layer","base":"d36f073ba98fd00e2678d773d06aa44723a0b728","worktree":"/var/tmp/aegl-gt1-promote-e5f31c8","branch":"gt1-promote-e5f31c8","target_ref":"refs/heads/main"}'
sudo /usr/bin/python3 "$BROKER" client --socket "$SOCK" --request "$REGISTER_REQ"

RECORD_REQ='{"protocol":"AEGL-BROKER/1","op":"record","task_id":"gt1-e5f31c8-20261024","verify_result":"PASS"}'
sudo /usr/bin/python3 "$BROKER" client --socket "$SOCK" --request "$RECORD_REQ"

PROMOTE_REQ='{"protocol":"AEGL-BROKER/1","op":"promote","task_id":"gt1-e5f31c8-20261024"}'
sudo -u aegl-ai env AEGL_BROKER_SOCKET="$SOCK" \
  /usr/bin/python3 "$BROKER" client --socket "$SOCK" --request "$PROMOTE_REQ"
```

Check the returned `decision` value, not just exit 0:

- register: require `"decision":"REGISTERED"`;
- record: require `"decision":"RECORDED"`;
- promote: require `"decision":"APPLIED"`.

Then verify the ref:

```bash
test "$(sudo -u aegl-promote git -C "$AEGL" rev-parse refs/heads/main)" = "$CAND"
```

Authorization boundary: the direct broker client is authorized by `SO_PEERCRED`
(`aegl-ai` for promote, `root` for register/record) and the socket allowlists. The
`aegl-task` wrapper adds a controller-token check; the direct client does not perform
that check. Do not describe the direct client as token-authorized.

After a successful promote, remove the temporary import ref (the candidate is reachable
from `main`):

```bash
sudo -u aegl-promote git -C "$AEGL" update-ref -d refs/heads/gt1/model-task-registry
```

### 4.3 Formal checkout sync

The broker updates the ref only; formal working-tree sync is a separate trusted state.
Reuse AEGL's existing procedure: clean formal checkout, `git switch main`, no
`reset --hard`, `git clean`, `stash`, or new deployment system. If the formal checkout is
already on `main` and the working tree is stale, stop and use the AEGL owner's existing
sync procedure; do not invent a destructive reset.

```bash
# read-only preflight
sudo -u aegl-promote git -C "$AEGL" status --porcelain        # must be empty
sudo -u aegl-promote git -C "$AEGL" rev-parse --abbrev-ref HEAD
test "$(sudo -u aegl-promote git -C "$AEGL" rev-parse refs/heads/main)" = "$CAND"

# existing AEGL switch step (only if HEAD is not main and the tree is clean)
sudo -u aegl-promote env HOME=/tmp GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$AEGL" switch main

# verify
test "$(sudo -u aegl-promote git -C "$AEGL" rev-parse HEAD)" = "$CAND"
test -z "$(sudo -u aegl-promote git -C "$AEGL" status --porcelain)"
```

Clean up only the temporary import/promotion artifacts:

```bash
git -C "$EXT_COMMON" worktree remove --force "$PROMOTE_WT"
git -C "$EXT_COMMON" branch -D gt1-promote-e5f31c8
rm -f "$BUNDLE"
rm -rf "$IMPORT_DIR"
```

## 5. Explicit non-actions in this preparation round

No sudo, no installation, no real registry write, no formal promotion, no push, no
Microcourse-Studio creation, no real business task registration, no model/API call, no
sandbox-model re-run. Only the new install/acceptance scripts' syntax and the fixed file
manifest were checked.

```text
GT1_INSTALLED=NOT_DONE
ROOT_CLI_ACCEPTANCE=NOT_RUN
MICROCOURSE_PROJECT_CREATED=NO
REAL_TASK_REGISTERED=NO
```
