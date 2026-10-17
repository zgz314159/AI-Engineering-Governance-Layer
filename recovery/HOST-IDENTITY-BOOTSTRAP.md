# Host identity bootstrap — Plan A execution prep (post KeepLab migrate)

Preparation wiring for the three formal trees only. **This tip does not** run
`sudo`/`prepare`/`switch`/`verify` as delivered; no formal permission change, no
`node_modules` delete, no push, no Cursor rules deploy.

## Scope (permission switch — when later approved)

| Tree | Path |
|---|---|
| AEGL | `/home/zhong/Projects/AI-Engineering-Governance-Layer` |
| Stack | `/home/zhong/Projects/Google-Android-Agent-Development-Stack` |
| KeepLab | `/home/zhong/AppProjects/KeepLab-Relay` |

- Target: `zhong` and `aegl-ai` cannot write formal source or `.git` metadata; `aegl-promote` still can promote; operator retains read via group `aegl-ro` (refresh login / `newgrp` after first `usermod -aG`).
- **No** recursive `chattr`/`chown` of whole `/home/zhong/Projects` or `/home/zhong/AppProjects`.
- **PARENT_RENAME_PROTECTION=UNRESOLVED** — parent replace/rename is not closed this round; file non-write ≠ complete isolation.

## Modes

| Mode | Effect |
|---|---|
| `plan` | print; change nothing |
| `prepare` | accounts/groups/`/var/lib/aegl-ai` only |
| `deps-plan` | freeze the two listed `node_modules` + external rebuild wiring; **no delete** |
| `broker-bind` | match installed broker files to `--commit` tip; optional `--write-marker` with evidence (not a bare touch) |
| `switch-preflight` | throwaway cross-UID + broker CAS; **NOT_RUN** without root |
| `switch` | three trees only; gated on marker + deps absent; runs preflight first |
| `verify` | non-mutating `builtin test -w` as target identities |
| `selftest` | destructive probes only under `/var/tmp` |
| `broker-plan` | print handoff; does not install |

Failures print `STOP_AT=<phase>` and exit non-zero. Write checks use Bash builtin under `runuser`, never `/usr/bin/test`.

## Trusted delivery (fixed full SHA; piped OK)

`--commit <40-hex>` is required for `broker-bind` / `switch-preflight` / `switch`. Path resolution does not depend on `BASH_SOURCE` when piped:

```bash
AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer
TIP=<FULL_40_HEX_OF_THIS_COMMIT>
git -C "$AEGL" show "$TIP:recovery/host-identity-bootstrap.sh" \
  | sudo bash -s -- --commit "$TIP" --aegl "$AEGL" <mode>
# Or the exec pack (preflight → broker-bind → deps-plan → prepare; switch gated):
git -C "$AEGL" show "$TIP:recovery/host-identity-exec.sh" \
  | sudo bash -s -- --commit "$TIP"
```

## Generated deps (exact two; wiring only this round)

| path | role |
|---|---|
| `…/fixture/.specify/extensions/architecture-guard/node_modules` | tests/dev packages |
| `…/upstream/rulesync/node_modules` | pnpm tree (many hardlinks) |

External rebuild roots (declared, not created here):

- `/var/lib/aegl/rebuildable-deps/rulesync/node_modules`
- `/var/lib/aegl/rebuildable-deps/architecture-guard/node_modules`

`bin/aegl-recovery` RuleSync freshness uses `upstream/rulesync/dist/cli` (prebuilt). Populate `EXTERNAL_*` + `NODE_PATH` **before** any formal in-tree delete. This tip does not delete.

## Hardlinks / symlinks

- `find -P` (no symlink follow).
- Files with `nlink>1` are **skipped** for bulk `chown` (not retargeted outside the tree).
- Executable bit preserved (0750 vs 0640).

## Remaining gates before formal `switch`

1. `broker-bind --write-marker` after tip/file match (reuse installed broker; do not reinstall).
2. Operator removes the two frozen `node_modules` **after** external rebuild wiring.
3. Root runs `switch-preflight` (must PASS) then `switch` (or `host-identity-exec.sh --write-marker --apply-switch`).

`AI_BOUNDARY` stays blocked until switch lands. Parent rename protection remains a separate gap.
