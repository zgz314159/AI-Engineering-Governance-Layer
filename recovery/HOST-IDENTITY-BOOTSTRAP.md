# Host identity bootstrap — revised design (Stage 2 preparation)

**This round prepares and reviews only.** No `--apply`, no sudo, no write probes on the
official projects were run; no backup/archive/snapshot is created; no password is read or
stored. The script is **dry-run by default**; the controlled switch is a separate,
operator-run `apply` and is deliberately postponed (see "Order" below).

## How to obtain the reviewed script (do not run the in-tree relative path)

The script exists **only on the isolated branch**, not in the canonical working tree:

```
git -C /home/zhong/Projects/AI-Engineering-Governance-Layer \
    show ai-boundary-stage3:recovery/host-identity-bootstrap.sh \
    > /tmp/host-identity-bootstrap.sh
git -C /home/zhong/Projects/AI-Engineering-Governance-Layer \
    show ai-boundary-stage3:recovery/HOST-IDENTITY-BOOTSTRAP.md > /tmp/HOST-IDENTITY-BOOTSTRAP.md
```

`recovery/host-identity-bootstrap.sh` is **not** an executable path inside the canonical
checkout — always run the extracted copy: `sudo bash /tmp/host-identity-bootstrap.sh plan`.

## Identities (explicit groups; `useradd` is not assumed to create them)

| identity | group | access |
|---|---|---|
| `aegl-ai` | `aegl-ai` | **only** `/var/lib/aegl-ai` (its task-checkout root). **No** access to `/home/zhong`, `/home/zhong/Projects`, or any canonical project — not even read. |
| `aegl-promote` | `aegl-broker` | owner of the canonical trees and `.git` (read/write); the promotion/broker identity |
| `zhong` (operator) | `aegl-ro` | read-only on the canonical trees; **no** write; **no** `.git` access |

Groups are created explicitly (`groupadd --system ai/broker/human`) and users are created
with `--gid`, then verified (`id`, `getent group`). The AI user is never added to the
read-only group and receives no ACL on the parents.

## Gap 1 — blocking rename/delete/replace through the writable parent

Today `/home/zhong/Projects` is `775 zhong:zhong`, so the running `zhong` process can
rename/delete/replace the project **entries** even if it cannot write inside them. The fix
does **not move the project body**:

1. `chown aegl-promote:aegl-ro /home/zhong/Projects && chmod 2755` — `zhong` loses write
   on the parent (kernel-enforced by mode/ownership);
2. **`chattr +i /home/zhong/Projects`** — the immutable attribute is kernel-enforced
   (ext4) and prevents creating/renaming/deleting any entry under the parent **and**
   prevents the `Projects` entry itself from being renamed or removed, even by its owner.

This closes the gap at `/home/zhong/Projects` without relocating anything. The acceptance
step proves it (an `mv` of a project as `zhong` must fail with EPERM, and `lsattr` must
show `i`). If the filesystem does not support the immutable attribute, the design is
BLOCKED — no permission switch is applied.

*Residual*: `/home/zhong` itself is owned/writable by `zhong`, but because the `Projects`
entry is immutable it cannot be renamed or deleted; the acceptance check verifies this.

## Gap 2 — verification that actually executes and fails non-zero

`verify` (and `apply`, which calls it) runs real checks and returns non-zero on any leak:
- as `zhong`: cannot write the **project root**, a **nested file**, or **`.git/config`**;
- as `zhong`: cannot **create** an entry in the parent and cannot **rename/replace** a
  project entry (if a rename unexpectedly succeeds it is restored immediately and the run
  FAILS);
- as `aegl-promote`: **can** write the project (positive control);
- `lsattr -d /home/zhong/Projects` must show the `i` flag.

`selftest` runs the same logic against an **isolated throwaway tree** under `/var/tmp`
(unprivileged). Current result: an unprotected tree produces **6 violations** → the
verifier demonstrably fails closed. No official project is touched by the selftest.

## Gap 3 — order that avoids an unusable intermediate state

1. **Prepare** identities + the real promotion broker (no lock on the projects).
2. **Isolated test** the broker on throwaway trees (promotion accepted/rejected paths).
3. **One controlled switch**: `apply` performs ownership/mode + parent immutability, then
   **immediately** runs `verify`; **if verification fails it reverts** (`chattr -i` +
   ownership back) and exits non-zero.
4. **Immediate acceptance** as part of step 3.

The projects are therefore never left locked before a working, isolated-tested broker
exists. `revert` is available as a separate mode (no backup is taken).

## Gap 4 — pre-checks against inodes outside the manifest

Before any bulk change, `preflight` refuses to proceed if a project has **cross-mount
files** (`-printf '%D'` device comparison), **hardlinked files** (`-links +1`, a chown would
affect the linked inode elsewhere), or if a manifest path is a **symlink**/missing. It also
prints the **existing explicit ACL entries** per project for review. Only enumerated nodes
under the three manifest roots are changed, by type, via `find -P … -exec` — never
`chown -R`/`chmod -R`, never following symlinks.

## Known blocker found by the preflight (this round)

The dry-run refused at preflight: the AEGL checkout contains **30,892 hardlinked files**,
**all** under `upstream/rulesync/node_modules/.pnpm` (pnpm's content-addressable store). A
bulk `chown` there would change the ownership of inodes the pnpm store shares **outside**
the manifest, so the program fails closed instead of touching them. Operator decision:
- **(a)** remove/relink the generated dependency trees before the switch
  (`upstream/*/node_modules`, `upstream/*/.venv`) — generated output, not project body; or
- **(b)** exclude generated dependency trees from the ownership switch (prune
  `node_modules`/`.venv`); residual: those trees stay writable by `zhong`.

Choose (a) for full coverage; (b) is quicker but leaves vendored dependencies unprotected.

## Remaining manual steps (operator, trusted terminal)

```
# after the broker exists and has passed its isolated tests:
sudo bash /tmp/host-identity-bootstrap.sh plan     # final review (no changes)
sudo bash /tmp/host-identity-bootstrap.sh apply    # one switch + immediate verify
```

`AI_BOUNDARY=BLOCKED` until the broker is real, the switch is applied, and `verify`
returns zero. The broker and model-networking stages are **not** entered before that.
