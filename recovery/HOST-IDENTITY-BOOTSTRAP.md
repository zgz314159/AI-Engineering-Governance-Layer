# Host identity bootstrap — operating notes (Stage 2 preparation)

**Scope.** This prepares (does not perform) a least-privilege identity boundary for the
AEGL AI boundary. The program `recovery/host-identity-bootstrap.sh` is **dry-run by
default**; `--apply` performs the changes and requires root. Nothing here creates a
backup, archive, snapshot, or timestamped report, and no password is read or stored.
It does **not** make `bwrap` setuid and does **not** open the whole home directory.

## Identities and what each may access

| identity | kind | canonical projects | canonical `.git` | notes |
|---|---|---|---|---|
| `aegl-ai` | system user, nologin, no sudo | **read-only** (in group `aegl-ro`) | **no access** | owns only `/var/lib/aegl-ai` (0700) for its task state |
| `aegl-promote` | system user, nologin | **read/write** (owner) | **read/write** (owner-only) | the trusted promotion owner; drives commit/merge via the broker |
| `zhong` (operator) | existing | **read-only** (in group `aegl-ro`) | **no access** | loses direct write; promotes only through the trusted path |

## How direct writes are blocked (both the AI and the current `zhong` process)

- Canonical project directories become `aegl-promote:aegl-ro` with mode **2750** — owner
  write, group read/traverse, no other. Since neither `aegl-ai` nor `zhong` is the owner,
  **both are denied direct writes** while keeping read-only access.
- Canonical `.git` becomes `aegl-promote:aegl-promote` with mode **2700/0600** — no group
  and no other. The AI cannot read or write canonical Git metadata; the AI works in a
  standalone temporary checkout inside its own state root instead.
- The setgid bit (`2750`) is applied **only to directories**, so new files inherit the
  group; it is never applied to regular files.

## Parent traversal (minimum)

`/home/zhong` is currently `750 zhong:zhong`, so no other uid can even enter it. The
program grants **execute-only** traversal via ACLs (`--x`, no read/list) on
`/home/zhong` and `/home/zhong/Projects` to `aegl-ai` and `aegl-promote`:

```
setfacl -m u:aegl-ai:--x -m u:aegl-promote:--x /home/zhong
setfacl -m u:aegl-ai:--x -m u:aegl-promote:--x /home/zhong/Projects
```

Mode bits of the parents are **not** changed and the home is not opened up.

## Permission policy (preserves existing regular/executable distinction)

- working-tree directories → `2750`; regular files → `0750` if the file was
  owner-executable, otherwise `0640` (other bits cleared, no setgid on files);
- `.git` directories → `2700`; `.git` files → `0700` exec / `0600` plain;
- symlinks are **never followed and never chowned/chmodded** (`find -P … -type l` is
  excluded); a symlink whose target resolves **outside** its project root aborts the plan;
- only paths under the manifest roots are touched; a broad `chown -R`/`chmod -R` is not
  used — each node class is enumerated and changed by an explicit `find … -exec`.

## Per-change gates

Each step prints, and `--apply` enforces: a **pre-check** (path exists, is not a symlink,
is inside the manifest; account does not already exist), a **fail-closed** rule (the first
failing command aborts; nothing is deleted and no rollback copy is made — the steps are
idempotent and re-runnable), and a **post-change verification** command.

## Commands to review and run (trusted terminal)

```
sudo bash recovery/host-identity-bootstrap.sh --plan     # review: prints every command
sudo bash recovery/host-identity-bootstrap.sh --apply    # perform + verify
```

Verification (part of the program's printed post-checks):

```
runuser -u aegl-ai      -- test -w <project>   # expect FAILURE
runuser -u zhong        -- test -w <project>   # expect FAILURE
runuser -u aegl-promote -- test -w <project>   # expect SUCCESS
find -P <project>/.git -maxdepth 1 -printf '%m %u:%g\n'   # expect 2700 aegl-promote
```

## Sandbox prerequisite (not performed here)

`bwrap` stays unprivileged. If user namespaces remain unavailable, allocate a
subuid/subgid range for the AI user instead of making `bwrap` setuid:

```
usermod --add-subuids 100000-165535 --add-subgids 100000-165535 aegl-ai
```

## Reversal (commands only; no backup is taken)

```
setfacl -x u:aegl-ai,u:aegl-promote /home/zhong /home/zhong/Projects
chown -R zhong:zhong <project>            # per project, after operator review
userdel aegl-ai ; userdel aegl-promote ; groupdel aegl-ro
```

`AI_BOUNDARY=BLOCKED` remains until this bootstrap is actually applied and the acceptance
suite passes; the broker and model-networking stages are not entered before that.
