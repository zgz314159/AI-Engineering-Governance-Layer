# Host identity bootstrap — Plan A (post-migrate execution prep)

Preparation for the three formal trees only. **This tip does not** run formal
`switch`, delete in-tree `node_modules`, push, or deploy Cursor rules.

## Scope

| Tree | Path |
|---|---|
| AEGL | `/home/zhong/Projects/AI-Engineering-Governance-Layer` |
| Stack | `/home/zhong/Projects/Google-Android-Agent-Development-Stack` |
| KeepLab | `/home/zhong/AppProjects/KeepLab-Relay` |

- `zhong` / `aegl-ai`: no write to formal source or `.git`; `aegl-promote` owns trees and can CAS + sync.
- Operator read via `aegl-ro` (refresh login after first `usermod -aG`).
- Hermes/guard: sandbox root bind-mounts `contract_guard.py`; verifier checks source readable.
- **PARENT_RENAME_PROTECTION=UNRESOLVED** — no Projects/AppProjects chattr.
- Hardlinks: scanned and **refused** before any formal chown (no silent SKIP→OK).

## Modes

| Mode | Effect |
|---|---|
| `plan` | print only |
| `prepare` / host prep | accounts/groups (may create `aegl-ro`) — not claimed as zero host change |
| `deps-plan` | freeze two paths; owning-repo `ls-files` (not parent alone) |
| `deps-wire` | rsync package+lock → external root; `pnpm install --frozen-lockfile`; entry wrappers + checks; delete prep printed only |
| `broker-bind` | tip/file match + registry landed promote evidence; `--write-marker` only then |
| `switch-preflight` | root: host prep → one throwaway repo → `_switch_tree` → deny zhong/aegl-ai → broker CAS + broker sync; non-root `NOT_RUN` |
| `switch` | hardlink scan → three trees → ACL `--post-owner-switch`; `--skip-preflight` if already run |
| `verify` | zhong **and** aegl-ai write denies; broker write; operator read |

## Trusted delivery

```bash
AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer
TIP=<FULL_40_HEX>
git -C "$AEGL" show "$TIP:recovery/host-identity-bootstrap.sh" \
  | sudo bash -s -- --commit "$TIP" --aegl "$AEGL" <mode>
git -C "$AEGL" show "$TIP:recovery/host-identity-exec.sh" \
  | sudo bash -s -- --commit "$TIP"
```

## External deps

- Production: `/var/lib/aegl/rebuildable-deps` + `/etc/aegl/rebuildable-deps.env`
- Non-root wire: `~/.local/state/aegl/rebuildable-deps-stage`
- Entries: `$ROOT/bin/rulesync`, `$ROOT/bin/architecture-guard`; `AEGL_RULESYNC_CLI` consumed by `bin/aegl-recovery`
- Formal in-tree delete is operator-gated after wire checks; this tip does not delete

## Post-owner ACL

`install-promote-target-acl.sh --post-owner-switch`: broker may write body (sync);
zhong/aegl-ai still denied. Pre-switch ACL still forbids broker worktree write.
