# AEGL-TOOL-OBS-DEPLOY-r1 — four-file observation deployment package

Install-only package for the minimal model/tool observation patch. This round packages
and verifies; it does **not** run the real root install.

## Provenance

- AEGL source: `/var/tmp/IAP-CONTROL-DEV/aegl`
- deployment source commit: the commit that records this package source
- production candidate (unchanged): `926c34fbecf1157c2ae88e57e85ef67f6f82de33`
- check source: `4232cb114f74dbbbf15046cce6e62ec95604bbd7`
- verified r10 root check (not rerun here):
  - anchor: `e458957cd15cab763191b031cc2598af5a4c7c2136fe951c629d40e414081f65`
  - log: `/root/aegl-tool-obs-check-r10.G1DVhS/check.log`
  - result: `OBS_CHECK=PASS`, `CHECK_COMMAND_EXIT=0`
- reused bootstrap: `bin/bootstrap.sh`, the verified `iap_smoke_bootstrap.sh`
  (SHA-256 `74849fba1c53a1f7819e651ce7a0dd4c4ad25dd3b3276d6c99e0816c6c46ea2c`)

## Fixed target and the only allowed changes

Target: `/usr/local/lib/aegl-model` (root:root, mode 0755, not a symlink).

| order | file | candidate SHA-256 | installed before | installed after |
|---|---|---|---|---|
| 1 | `tool_event_client.py` | `f70630ca…651df83bf` | absent | root:root 0644 |
| 2 | `tool_observer_config.py` | `42436956…b807591c3` | absent | root:root 0644 |
| 3 | `model_broker.py` | `7aa88b18…a9b8ee59a` | root:root 0644, `ab0d4c36…d93c3e3` | root:root 0644 |
| 4 | `aegl-hermes-sandbox` | `f3e556f0…b75929479` | root:root 0755, `8c4dd19b…5c933b1eadf5` | root:root 0755 |

The launcher is replaced last. The two new modules are installed first. No other file
is installed, removed or renamed.

## Runtime dependencies verified, never installed

The other twelve files are pinned to the r10 hashes and the current mounted
owner/mode. They are checked before and after the install; they are never written.

| file | SHA-256 | owner:group | mode |
|---|---|---|---|
| `aegl-model-broker` | `e7ca9db0…9917fba9` | root:root | 0755 |
| `guard_capture.py` | `4422f725…d877be1a` | root:root | 0644 |
| `guard_hook_client.py` | `19121446…5265869` | root:root | 0644 |
| `diag_events.py` | `0f79ca1f…47f4f2e` | root:root | 0644 |
| `loopback_shim.py` | `75cf4ad6…e4031d5c` | root:root | 0644 |
| `exec_spec.py` | `cb9e82ff…9ae1546` | root:root | 0644 |
| `sandbox_spec.py` | `1b95ec40…d338b11890` | root:root | 0644 |
| `prepare_targets.py` | `2279cb11…dcd25232` | root:root | 0644 |
| `drop_verify.py` | `a0b9d219…45c5eecc` | root:root | 0644 |
| `model_config.py` | `ef14777e…a3b8a223568f` | root:root | 0644 |
| `git_meta_mounts.sh` | `f93bbfdd…bbeac8ac50a` | root:root | 0755 |
| `guard/contract_guard.py` | `19f6be63…668fe9b330455` | root:root | 0444 |

The guard is the current installed copy (`19f6be63…`). This package never carries or
installs the other `748b346d…` guard version.

## Deployment procedure

The entry is `bin/run_smoke.sh`; the reused bootstrap copies the whole package into a
new root-exclusive directory, verifies the manifest anchor and execs the entry.

Before any write the entry verifies, in order:

1. package manifest, manifest self-hash, payload regular files and candidate hashes;
2. target existence/type, `root:root` and mode 0755;
3. both new targets absent and not symlinks (an existing one stops immediately);
4. the two predecessors: regular file, exact predecessor hash, owner and mode;
5. the twelve dependencies: regular file, exact r10 hash, owner and mode;
6. no active AEGL run: a non-empty `/run/aegl-model`, a symlink/unreadable run root,
   an erroring process probe, or a matching running launcher/broker stops the deploy
   (no process is killed);
7. all four temp paths are registered before first use; an existing stale
   `.aegl-deploy.*` entry or temp collision stops the deploy.

The install then uses explicit same-directory temp files
`<target>/.aegl-deploy.<pid>.<name>`, verifies each temp's hash/owner/mode, and
atomically renames it over the target. A failure stops immediately, keeps the scene
(including any temp and already-installed files), reports
`DEPLOY_FAIL stage=<stage> rc=<real-rc> completed=<stages>` and never retries or
rolls back. After the four installs the entry re-verifies all four payloads and all
twelve dependencies, removes only the registered temp paths, and only then prints
`DEPLOY_OK`.

The entry never starts the launcher and never creates a task scene.

## Ordinary-user self-test

```sh
/var/tmp/AEGL-TOOL-OBS-DEPLOY-r1/bin/run_smoke.sh --self-test
```

Covers package integrity, bash/Python syntax, pin declarations, the active-run
classifier, and the install logic against a temporary fixture target: required order,
temp registration, success verification/cleanup, and stop-on-failure for existing new
targets, predecessor hash, guard hash/mode, missing dependency, symlinked predecessor,
symlinked target, stale temp, and a mid-install rename failure (later files untouched,
no rollback). Stubs are used only for `pgrep` and the failing `mv`; they prove
classification and failure propagation, not a real root install.

Result of this round: `DEPLOY_SELF_TEST pass=6 fail=0`.

## Simulated vs real

- Simulated (ordinary user): package, syntax, pins, active-run classifier, install
  ordering/atomic/failure logic against a temp directory.
- Real (not run this round): root install to `/usr/local/lib/aegl-model`, real active
  AEGL run scan, and post-install root verification.

## NOT_RUN

- real root install and the real active-run scan on the host;
- `r10` root check rerun (its PASS result is preserved as-is);
- the unchanged 23-item production suite;
- any launcher start, task-scene creation, deployment follow-up, Bridge/registration
  change or deployment to another target.

This package contains no check upstream, dummy credential or fixture for the runtime
directory; only the four observation payload files, pins, entry and bootstrap.
