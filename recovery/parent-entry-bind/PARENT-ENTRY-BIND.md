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

## Production gate (`require-entry-binds.sh`)

Fixed policy: `/etc/aegl/entry-bind/policy` (no env override).

| State | Behavior |
|---|---|
| Policy absent | `NOT_DEPLOYED` / `not_claimed` — not “protection OK” |
| Policy present | Installed checker + exact five paths; each verified as RW **self-bind** |

Self-bind verification (no `findmnt OPTIONS` bind/rbind token):

1. Trusted unit at `/etc/systemd/system/<unit>`: `What=Where=<path>`, Options include `rw`; not a symlink; no drop-ins; `FragmentPath` match
2. Exact `findmnt --mountpoint` TARGET
3. `FSROOT` == path; SOURCE bracket form if present must equal path
4. `/proc/self/mountinfo` root == mountpoint == path with explicit `rw` (not `ro`)

Parse-only samples: `mountinfo-samples.txt` via
`require-entry-binds.sh --check-mountinfo-sample …` (**not** host mount acceptance).

## Ownership / uninstall

- Active unit name ≠ ownership.
- Scan all systemd unit search paths; foreign same-name unit/drop-in/`FragmentPath` ⇒ refuse **before write** (even if `/etc/systemd/system` lacks the file).
- `--remove`: ownership first; reverse stop; verify unmounted; keep policy/units on failure; exact-file delete only.

## Host entry wiring

| Host entry | When | How tip reaches host |
|---|---|---|
| `/usr/local/lib/aegl-model/aegl-hermes-sandbox` | Before sandbox prepare | `install-model-broker.sh` |
| `/usr/local/lib/aegl-promote/promotion_broker.py` | Before `apply_to_ref` | `install-broker.sh` + restart |
| `aegl-task` / host-identity | Defense-in-depth | Not a substitute for broker/Hermes |

## Trusted delivery

Outer wrap (subshell): extract `trusted-delivery.sh` into **OUTER_RDIR** mode `0700`,
`GOT=$(sudo sha256sum …)` (do not chmod the directory wider), EXIT deletes only that
script + `rmdir` OUTER_RDIR, then prints `DELIVERY_EXIT_CODE`.

Inner script creates a separate **inner RDIR** for installers:

1. Import objects (`safe.directory=<exact>` only)
2. **Install fixed promote broker from tip + restart + sha256 match** (before promote;
   not promote approval; required so running `classify_tree` sees NUL path parse)
3. New independent `task_id` (e.g. `parent-entry-bind-r59`); never reuse
   `parent-entry-bind-r57`; never clear registry
4. `formal_pre_cas_check` → register/record/promote → `sync_formal_to_tip`
5. Install entry-bind pack + model broker (promote broker already at tip)
6. Inner EXIT: preserve EXT on worktree remove failure; `DELIVERY_RESULT=OK` only if cleanup final=0

## Status

- `FORMAL_DEPLOY=NOT_DONE` until trusted terminal runs delivery `--apply` path
- Live host mount proof: `NOT_RUN` until observed
- `AI_BOUNDARY=BLOCKED`
