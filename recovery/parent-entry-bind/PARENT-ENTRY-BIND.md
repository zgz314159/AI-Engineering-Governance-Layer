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

Parents start before children (`Requires=` / `After=` on child units). Stop uses
**explicit reverse order** (children → parents → target); active unit name alone
is not pack ownership.

## What this does / does not

- **Does:** block rename/exchange of those five entry names (mountpoint → typically `EBUSY`).
- **Does not:** block writes inside project trees by the broker owner; siblings under Projects/AppProjects remain normal directories; no chattr; no fstab edits; no agent-instruction overwrite.

## Evidence (trial)

`recovery/parent-rename-bind-mount-trial.sh` was validated out-of-tree (private mountns)
before this tip. Incorporating the file into source does **not** claim older baselines
contained it. Do not re-run that trial as part of install.

## Production gate (`require-entry-binds.sh`)

Fixed policy path (no environment override):

- `/etc/aegl/entry-bind/policy`

| State | Behavior |
|---|---|
| Policy absent | `ENTRY_BIND_STATE=NOT_DEPLOYED` — exit 0; **not** “protection OK” |
| Policy present | Installed checker must exist; policy must list exactly the five paths; each must be an exact `findmnt --mountpoint` with **bind/rbind + rw** (not arbitrary mountpoint, not RO bind). Fail closed on missing checker, corrupt policy, or missing mounts. |

Installed checker path: `/usr/local/lib/aegl-entry-bind/require-entry-binds.sh`

## Enforcement wiring (host entry ≠ tip source)

Same checker is called from:

| Host entry | When | How tip reaches host |
|---|---|---|
| `/usr/local/lib/aegl-model/aegl-hermes-sandbox` | Before sandbox prepare | `recovery/install-model-broker.sh --commit <TIP>` |
| `/usr/local/lib/aegl-promote/promotion_broker.py` | Before `apply_to_ref` | `recovery/install-broker.sh --commit <TIP>` + `systemctl restart aegl-promote-broker` |
| `bin/aegl-task` / host-identity switch | Defense-in-depth | Task binary from tip or PATH; **not** a substitute for broker/Hermes gates |

**Source tip alone does not update installed launcher/broker.** After promote, reinstall
model + promote broker from the fixed SHA for those gates to take effect on the host.

## Install / remove

See `recovery/install-parent-entry-bind.sh` (default `--plan`; explicit `--apply` / `--remove`).

Installed artifacts:

- `/etc/systemd/system/aegl-entry-bind.target`
- `/etc/systemd/system/home-zhong-*.mount` (five units)
- `/usr/local/lib/aegl-entry-bind/require-entry-binds.sh`
- `/usr/local/lib/aegl-entry-bind/PARENT-ENTRY-BIND.md`
- `/etc/aegl/entry-bind/policy` (lists paths + commit; **not** sufficient alone)

### Ownership / uninstall

- Same-named active mount unit ≠ owned by this pack.
- Ownership requires: unit file at `/etc/systemd/system/<unit>` (not symlink), content
  hash match to tip, no `.d` drop-ins, `FragmentPath` match, empty `DropInPaths`.
- Unknown/foreign/symlink/drop-in → refuse (no overwrite, no stack).
- `--remove`: ownership check first; reverse stop; verify unmounted; on failure keep
  policy+units and exit non-zero; delete only hash-matched exact files (no `rm -rf` LIBDIR).

## Trusted delivery

zhong must not read formal `.git` after host-identity switch. Use:

1. Trusted import of tip objects into formal AEGL (`git fetch` with command-level
   `safe.directory=<exact path>` only — never `*`).
2. Normal broker register/record/promote onto `refs/heads/main`.
3. Root extracts installer from fixed SHA into a root-only directory, verifies
   sha256, then runs that copy — never `sudo` a user-writable tree script.

## Status labels

- `FORMAL_DEPLOY=NOT_DONE` until a trusted terminal runs `--apply` after promote
- Live mount / broker+Hermes reinstall proof: `NOT_RUN` until observed
- `AI_BOUNDARY=BLOCKED`
