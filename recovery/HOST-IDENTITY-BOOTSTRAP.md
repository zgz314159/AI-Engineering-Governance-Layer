# Host identity — Plan A packs (post-migrate)

Three **separate** trusted packs (do not chain prepare→switch in one session):

1. `host-identity-prepare.sh` — materialize scripts, preflight once (stamp), broker-bind, deps-wire (reuse), prepare
2. `host-identity-cleanup.sh` — delete only `DELETE_CLEARED` `node_modules` paths (`--apply`)
3. `host-identity-switch-apply.sh` — after tip on `main`; uses stamp + `--skip-preflight`; switch + verify

`host-identity-exec.sh` is retired as a chained pack.

## Operator env (sudo-safe)

Resolves `OPERATOR_HOME`, `pnpm`, `node`, store from the operator identity (`SUDO_USER`), not sudo `HOME`/`PATH`. Overrides: `--pnpm`, `--node`, `--pnpm-store`, `--deps-stage`, `--operator-home`.

## Post-switch Git

Scripts are materialized to `/var/lib/aegl/host-identity/scripts/<TIP>/` **before** chown. Later ACL/git use that cache or broker + command-level `safe.directory=<exact path>` (no global/`*`).

## Architecture-guard fixture

- Stale `.git` gitfile (wrong relative `gitdir`); canonical module worktree = `upstream/architecture-guard`
- Delete cleared only as parent-ignored untracked specify `--dev` copy — **not** via upstream `ls-files=0`

## RuleSync entry

`AEGL_RULESYNC_CLI` honored by `bridge/linux/50-positive-test.sh` and `aegl-recovery test_all` **after this tip is on main**. `doctor` does not use RuleSync. Isolation branch ≠ formal entry.

## Gaps

`PARENT_RENAME_PROTECTION=UNRESOLVED` · `AI_BOUNDARY=BLOCKED`
