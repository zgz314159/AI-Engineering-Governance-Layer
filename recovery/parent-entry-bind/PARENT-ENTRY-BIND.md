# Parent / project entry RW self-bind pack

Protects **five** directory entrypoints against non-privileged rename/replace by
making each path a RW self-bind mountpoint (`mount --bind PATH PATH`).

## Paths (fixed)

| Order (start) | Path | Unit (`systemd-escape -p --suffix=mount`) |
|---|---|---|
| 1 | `/home/zhong/Projects` | `home-zhong-Projects.mount` |
| 2 | `/home/zhong/AppProjects` | `home-zhong-AppProjects.mount` |
| 3 | `…/AI-Engineering-Governance-Layer` | `home-zhong-Projects-AI\x2dEngineering\x2dGovernance\x2dLayer.mount` |
| 4 | `…/Google-Android-Agent-Development-Stack` | `home-zhong-Projects-Google\x2dAndroid\x2dAgent\x2dDevelopment\x2dStack.mount` |
| 5 | `…/KeepLab-Relay` | `home-zhong-AppProjects-KeepLab\x2dRelay.mount` |

Parents start before children (`Requires=` / `After=` on child units). Stop reverses via systemd.

## What this does / does not

- **Does:** block rename/exchange of those five entry names (mountpoint → typically `EBUSY`).
- **Does not:** block writes inside project trees by the broker owner; siblings under Projects/AppProjects remain normal directories; no chattr; no fstab edits; no agent-instruction overwrite.

## Evidence (trial)

`recovery/parent-rename-bind-mount-trial.sh` was validated out-of-tree (private mountns)
before this tip. Incorporating the file into source does **not** claim older baselines
contained it. Do not re-run that trial as part of install.

## Install / remove

See `recovery/install-parent-entry-bind.sh` (default `--plan`; explicit `--apply` / `--remove`).

Installed artifacts:

- `/etc/systemd/system/aegl-entry-bind.target`
- `/etc/systemd/system/home-zhong-*.mount` (five units)
- `/usr/local/lib/aegl-entry-bind/require-entry-binds.sh`
- `/usr/local/lib/aegl-entry-bind/PARENT-ENTRY-BIND.md`
- `/etc/aegl/entry-bind/policy` (lists paths + commit; **not** sufficient alone)

## Enforcement wiring

When `/etc/aegl/entry-bind/policy` exists, controlled entries call
`require-entry-binds.sh`, which refuses unless **every** policy path is an exact
`findmnt --mountpoint` hit. No policy ⇒ no claim / no enforce (pack not installed).

Wired from:

- `bin/aegl-task` (`task promote` / `register` / `record`)
- `recovery/host-identity-bootstrap.sh` (`switch_preconditions`)

## Conflicts

Installer stops if: fstab already has the Where path; a unit file exists with
different content; a path is already a mountpoint without our active unit.
No overwrite, no stacked binds.

## Status labels

- `FORMAL_DEPLOY=NOT_DONE` until a trusted terminal runs `--apply` after promote
- Live mount proof after reboot: `NOT_RUN` until observed
- `AI_BOUNDARY=BLOCKED`
