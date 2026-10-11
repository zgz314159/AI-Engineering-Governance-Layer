# Host identity bootstrap — revision 3 (Stage 2 pre-launch blockers)

Preparation only: **no** `prepare`/`switch`/`verify` is run as delivered; no `sudo`, no
change or write probe on the official projects; no backup/archive/snapshot. The program is
dry-run by default (`plan`) and never auto-reverts.

## 1. Generated-dependency cleanup — scheme (a), precise review list

Read-only enumeration found exactly **two** candidate trees (both under the AEGL checkout;
the Google Stack and KeepLab have none):

| path | size | files | tracked | gitignored | symlink | cross-mount |
|---|---|---|---|---|---|---|
| `…/AI-Engineering-Governance-Layer/fixture/.specify/extensions/architecture-guard/node_modules` | 416M | 17,301 | **0** | yes (repo) | no | 0 |
| `…/AI-Engineering-Governance-Layer/upstream/rulesync/node_modules` | 745M | 33,189 | **0** | yes (owning submodule's `.gitignore`) | no | 0 |

Both are untracked, ignored, single-device real directories with **0 tracked files**, so
removing them loses no Git-tracked or unique project source (regenerable from
`package.json`/`pnpm-lock`). Removing `upstream/rulesync/node_modules` also removes the
**30,892 hardlinks** (pnpm store) that made a bulk `chown` touch inodes outside the manifest.
**This round does not delete them** — the operator removes them (scheme (a)); the program
only lists them.

## 2. Acceptance changed to non-mutating checks (destructive probes only in the selftest)

`verify` performs **only** non-mutating checks: `test -w` as the operator on the project
root / a nested file / `.git/config` / the parent, a positive `test -w` as the broker, and
`lsattr` for the immutable flag. No `touch`, no `mv`, no rename of a project entry.

- **What this proves:** the permission bits/owner/ACL deny the operator write, and the
  immutable attribute is set on the parent — i.e. the *permission model* denies the action.
- **What it cannot prove:** that the kernel actually rejects a write/rename; `test -w`
  reflects mode bits and does not itself exercise the immutable attribute. The empirical
  destructive proof (`touch`/`mv`) runs **only** in the isolated `selftest` tree.

## 3. Identity preparation is split from the final switch; no fake restore

- `prepare` — account/group/state-root creation, **idempotent and safely retryable**
  (`getent`/`id` guards before every `groupadd`/`useradd`; `usermod -aG` is a no-op if
  already a member). It makes **no** change to the projects.
- `switch` — the single final permission change. It **refuses to run unless the broker is
  verified** (`/etc/aegl/broker-verified`, root-owned, written only after the broker passes
  its isolated test) and unless the generated-dependency trees are already removed.
- **There is no auto-revert.** An interrupted `chown` cannot be restored to the exact
  original per-file modes, so the program never claims "restored". It is designed so the
  tree stays **readable throughout** (group `aegl-ro` keeps r-x) and the switch is short
  (metadata-only), and on failure it stops and prints the precise partial state. Reversal is
  a **manual, explicitly non-exact** procedure.

## 4. Handoff: review the content and checksum, then a root-controlled path

Do **not** sudo-run a `/tmp` script (the current `zhong` AI can rewrite it). Pin the branch
commit and hash, review the content, then install it root-owned:

```
AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer
git -C "$AEGL" rev-parse ai-boundary-stage3                      # pin the reviewed commit
git -C "$AEGL" show ai-boundary-stage3:recovery/host-identity-bootstrap.sh \
  | tee /tmp/aegl-review.sh | sha256sum                          # review content + hash
sudo install -o root -g root -m 0755 /tmp/aegl-review.sh /usr/local/sbin/aegl-host-bootstrap.sh
sudo sha256sum /usr/local/sbin/aegl-host-bootstrap.sh            # must equal the reviewed hash
```

Run only the root-owned copy: `sudo /usr/local/sbin/aegl-host-bootstrap.sh <mode>`.

## 5. Selftest (isolated only)

`selftest` builds throwaway trees under `/var/tmp` and runs the destructive probes there:
(A) a writable tree → the non-mutating checks must report violations; (B) a `0555` tree →
checks clean and the `touch`/`mv` attempts are denied. Immutability cannot be exercised
without root; it is evidenced at switch time by `lsattr` (and cannot be empirically proven
by the non-mutating acceptance).

## Remaining conditions before the switch can run

1. Broker built and isolated-tested → `/etc/aegl/broker-verified` written.
2. Generated-dependency trees removed (scheme (a)).
3. Root filesystem supports the immutable attribute on `/home/zhong/Projects`.

Until all three hold, **apply is currently not runnable**, and `AI_BOUNDARY=BLOCKED`.

## 6. Trusted promotion broker — install (reviewable; root-owned)

The promotion broker is the independent identity that *validates and applies* promotions.
`bin/aegl-task promote` no longer applies anything: it authenticates, requires a verified
broker, submits a bounded request (`op` + `task_id`) and relays the reply. The AI side can
never pass a shell command or a target path, and never touches the canonical project after
the broker replies.

Files:

- `bin/aegl-promote-broker` — wrapper (`serve` / `client`).
- `recovery/promotion_broker.py` — daemon: `AEGL-BROKER/1` PING/PONG handshake, bounded request
  (op ∈ {validate, promote}, `task_id` regex, task dir proven under the tasks root), serialized
  by an flock; the project target is derived from the task's own `task.json`.
- `recovery/promotion_core.py` — the ONE central gate + apply (also used by `bin/aegl-task verify`).

Install steps (printed by `host-identity-bootstrap.sh broker-plan`; run manually with `sudo`;
`broker-plan` only PRINTS — it never runs sudo and never writes the marker):

1. Install the exact files **from the pinned isolated branch commit** (`git show <pin>:<path>`),
   root-owned under `/usr/local/lib/aegl-promote` (flat layout: launcher + `promotion_broker.py`
   + `promotion_core.py` in ONE directory, so the launcher resolves its module next to itself).
   Do not copy from an unmerged working checkout; verify each installed file's sha256 against
   `git show <pin>:<path> | sha256sum`.
2. Create group `aegl-broker`, add `aegl-ai` to it (socket access), create `/run/aegl-promote`
   (`aegl-promote:aegl-broker` 2770) and the broker-owned registry dir `/var/lib/aegl-promote`
   (`aegl-promote:aegl-broker` 0700).
3. Install a systemd unit running `aegl-promote-broker serve` as `User=aegl-promote`, with the
   registry location and allowlists **explicit**: `AEGL_BROKER_REGISTRY_DIR=/var/lib/aegl-promote`,
   `PROJECTS_ROOT`, `AEGL_PROJECT_ALLOWLIST=Google-Android-Agent-Development-Stack,KeepLab-Relay,
   AI-Engineering-Governance-Layer`, `AEGL_BROKER_ALLOW_REQUESTERS=aegl-ai`,
   `AEGL_BROKER_ALLOW_RECORDERS=root,<operator>`.
4. Run `recovery/broker-tests.sh` as `aegl-promote` against a throwaway tree; **only if it passes**
   write the reviewed pin into root-owned `/etc/aegl/broker-verified` (manual root step).
5. `switch` (the bulk project permission migration + entry lock) still refuses until that marker
   exists — do not run it as part of this step.

Trust model: the broker authorizes by kernel peer uid (`SO_PEERCRED`) against the allowlists, and
binds the project target, baseline and approved candidate content in its own registry — never in the
AI-writable `task.json` / `verify.status`. The candidate is re-pinned at promote time, so swapped
files or branches are refused; candidate scripts are never executed as the broker identity; git
operations disable hooks. Functional acceptance ≠ installed isolation: `broker-tests.sh` runs
same-uid and proves the broker logic only. The independent-identity boundary exists only once the
broker runs as `aegl-promote` with the marker written; `INDEPENDENT_IDENTITY_INSTALLED=NO` until then.
