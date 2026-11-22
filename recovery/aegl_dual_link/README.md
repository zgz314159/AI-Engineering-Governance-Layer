# AEGL dual-link (operator)

Project-agnostic dual-link operator: prepare → submit → host-run (auto-decide),
Cursor inbox watcher, per-project ChatGPT control via CDP. Does **not** send
`HERMES_TASK_V1` to Chrome.

## Canonical location

This directory is the **in-repo** source under AEGL. Runtime install remains:

`~/.local/share/aegl-dual-link/`

Live `project-control-map.json` stays user-local (not committed). Use
`project-control-map.example.json` as a template. Calendar (`OfflineTaskCalendar_WPF` /
`/home/zhong/EXE/RILI`) must keep its own control URL; never reuse it for
`/home/zhong/Projects` system work.

## Install / refresh user share from this tree

```bash
bash recovery/aegl_dual_link/install-user-share.sh
```

## Promote into formal Projects AEGL

Objects live on `feat/system-usage` in the IAP checkout
(`/var/tmp/IAP-CONTROL-DEV/aegl`) and on `github`. Advancing
`/home/zhong/Projects/AI-Engineering-Governance-Layer` requires the existing
`aegl-promote` broker / IAP delivery path (root). See
`docs/DUAL-LINK-MIGRATE-TO-PROJECTS.md`.
