# AEGL dual-link (operator)

Project-agnostic dual-link operator: prepare → submit → host-run (auto-decide),
Cursor inbox watcher, per-project ChatGPT control via CDP. Does **not** send
`HERMES_TASK_V1` to Chrome.

Command Code path: each turn `advise-post` → Chrome advisor → reinject once
(onStop continue / pending prompt). Short gate checklist is appended to reports.

## Helpers in this tree

| File | Role |
|------|------|
| `dual-link-operator.sh` | arm / session-up / enqueue / continue / advise-post / new-control |
| `project_control.py` | per-cwd / aegl_project ChatGPT URL map |
| `ensure-cdp-control.sh` | CDP :9333 + open bound control tab |
| `cdp_chat.py` | IME-safe Chrome launch + new `/c/` bootstrap |
| `advise_post.py` | plain report → ChatGPT; queue pending CC instruction |
| `install-user-share.sh` | install **full** helper set into `~/.local/share/aegl-dual-link/` |
| `aegl-calendar-prepare` / NOPASSWD helpers | calendar prepare ring |

## Canonical location

This directory is the **in-repo** source under AEGL (IAP day-to-day). Runtime:

`~/.local/share/aegl-dual-link/`

Live `project-control-map.json` stays user-local (not committed). Use
`project-control-map.example.json` as a template.

**Separate control URLs** (do not share across aegl_project ids):

- Calendar: `OfflineTaskCalendar_WPF` / `~/EXE/RILI`
- System: `AEGL_System` / `/home/zhong/Projects`
- Smoke / other worktrees: dedicated chats only

Dual-track ledgers (Projects root, user-writable):

- `SYSTEM-FRICTION.md` — system gaps found during business work
- `PROJECTS-SYSTEM-INVENTORY.md` — full capability / gate catalog

## Install / refresh user share from this tree

```bash
bash recovery/aegl_dual_link/install-user-share.sh
# or from IAP:
bash /var/tmp/IAP-CONTROL-DEV/aegl/recovery/aegl_dual_link/install-user-share.sh
```

## Promote into formal Projects AEGL

Objects live on `feat/system-usage` in the IAP checkout
(`/var/tmp/IAP-CONTROL-DEV/aegl`) and on `github`. Advancing
`/home/zhong/Projects/AI-Engineering-Governance-Layer` requires the existing
`aegl-promote` broker / IAP delivery path (root). See
`docs/DUAL-LINK-MIGRATE-TO-PROJECTS.md` and
`/home/zhong/Projects/.cursor/IAP-DELIVER-DUAL-LINK-OPERATOR.md`.
