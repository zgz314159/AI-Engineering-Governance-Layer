# Trusted Hermes task registry (GT1)

`aegl-model-task` is a root-only registrar/query tool for the existing Hermes task
registry. It changes neither the launcher nor the registry format.

- Production registry: `/var/lib/aegl-model/registry.json`
- Format: `task_id -> {worktree, scratch, project, contract_package}`
- Lock file: `/var/lib/aegl-model/registry.json.lock` (stable, exclusive `flock`)
- AI identity checked for task dirs: `aegl-ai` (fixed; no env/CLI override)

## Commands

```text
aegl-model-task register --task-id ID --worktree PATH --scratch PATH \
                         --project PATH --contract-package PATH
aegl-model-task show --task-id ID
aegl-model-task list
```

`register` requires root. The path is fixed; there is no `--registry` option and no
environment override. `show` and `list` are read-only and may run as non-root if the
registry is readable.

The following is an **example**, not a production registration. The task id and paths
are unassigned until the controller allocates them:

```text
# EXAMPLE ONLY
aegl-model-task register \
  --task-id example-task \
  --worktree /var/lib/aegl-model/tasks/example-task/project \
  --scratch /var/lib/aegl-model/tasks/example-task/scratch \
  --project /home/zhong/AppProjects/Microcourse-Studio \
  --contract-package /var/lib/aegl-model/contracts/example-task
```

## Validation before any replacement

- `task_id` matches `[A-Za-z0-9._-]{1,64}`.
- `worktree` and `scratch` exist, are directories, are not symlinks, are under
  `/tmp`, `/var/tmp`, `/run/aegl-*` or `/var/lib/aegl-*`, and are owned by `aegl-ai`.
- `project` exists, is a directory, and contains `.git`.
- `contract_package` is a real directory containing regular
  `implementation-contract.json` and `project-context.json` files.
- The contract `source_root` contains the worktree, and the worktree-relative path is
  authorized by `allowed_paths`.
- No submitted script, shell text, or `eval` is executed.

The existing registry is read and validated under the lock. Duplicate `task_id` is
rejected; all other entries are preserved.

## Atomic write

The tool writes a same-directory temporary file, fsyncs it, `os.replace`s it, then
fsyncs the directory. Errors before `os.replace` leave the original registry
byte-for-byte unchanged and remove the temporary file. If `os.replace` succeeds but the
directory fsync fails, the tool reports
`REPLACED_DURABILITY_UNCERTAIN reason=dir_fsync_failed` and does not claim the old file
is unchanged. No backup/archive/snapshot rollback is used.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | not root (register) or usage error |
| 3 | validation rejected (task id, path, owner, contract relation, duplicate) |
| 4 | registry/lock invalid, not root-owned, or AI identity missing |
| 5 | registry replaced but directory fsync failed (durability uncertain) |
| 6 | lock/write/replace I/O failure before a confirmed replacement |
| 7 | `show` task not found |

## Installation impact

This task ships source only. It does **not** install the tool, touch
`/usr/local`, `/var/lib`, systemd, ACLs, mounts, the launcher, the broker, or any
project. A later trusted installation must copy the approved commit's
`bin/aegl-model-task` and `recovery/model_task_registry.py`, set root ownership/mode,
and run the root-only acceptance separately.
