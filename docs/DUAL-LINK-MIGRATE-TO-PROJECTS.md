# Dual-link / system usage → formal Projects

## What was migrated into AEGL (IAP)

- `recovery/aegl_dual_link/` — operator, project control, NOPASSWD prepare helpers
- Calendar prepare remains under `recovery/calendar_wpf_001/` (product task prep, not dual-link)

## What lives in Stack (IAP)

- Hermes advisor dual-link, Cursor inbox channel, control-url binding, host-run path
- Branch: `feat/system-usage` at `/var/tmp/IAP-CONTROL-DEV/stack`

## Formal Projects trees

| Path | Owner | How to advance |
|------|-------|----------------|
| `/home/zhong/Projects/AI-Engineering-Governance-Layer` | `aegl-promote` | broker CAS / IAP delivery (root) |
| `/home/zhong/Projects/Google-Android-Agent-Development-Stack` | `aegl-promote` | same |

Ordinary user cannot write `.git` or tree files. Do **not** copy IAP trees over
formal paths by hand.

### Operator steps (TTY, sudo once the delivery package exists)

1. Ensure IAP AEGL/Stack `feat/system-usage` is clean and pushed to `github`.
2. Build/run the approved IAP delivery package for the candidate commits (see
   `docs/IAP-DELIVERY.md`) — do not invent a new promote tip.
3. After formal Stack matches dual-link commits, flip
   `STACK_JOBS_PY` default order in `recovery/aegl_dual_link/dual-link-operator.sh`
   to prefer the formal Projects path.
4. Refresh user share: `bash recovery/aegl_dual_link/install-user-share.sh`
5. Bind a **Projects/system** ChatGPT control URL separately from RILI:

```bash
~/.local/share/aegl-dual-link/dual-link-operator.sh bind-control \
  --cwd /home/zhong/Projects \
  --url 'https://chatgpt.com/c/<new-system-conversation-id>' \
  --aegl-project AEGL_System
```

## Projects workspace (user-writable)

- Cursor rule: `/home/zhong/Projects/.cursor/rules/calendar-dual-link.mdc`
- Migration mirror: `/home/zhong/Projects/.aegl-dual-link-src/` (rsync from AEGL recovery)

Calendar product code stays under `~/EXE/RILI` / `OfflineTaskCalendar_WPF`.
