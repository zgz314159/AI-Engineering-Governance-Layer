# IAP control-plane delivery

This delivers Stack's multi-project Bridge binding and AEGL's task-registry
ownership check. It does not register or run an ImageAnalysisFactory task, call a
model, send a browser message, change the model route, restart a service, push, or
rewrite the Bridge chain. The existing wrapper is unchanged.

Authoritative sources are `recovery/iap_delivery.py`,
`recovery/iap-delivery-bootstrap.sh`, `recovery/build_iap_delivery.py` and
`recovery/install-model-task-registry.sh` in AEGL. Stack owns its Bridge changes.
Packages are exports of fixed commits, not another source repository.

## Trust and execution

The final delivery message supplies both the bootstrap SHA256 and the full
`MANIFEST.sha256` SHA256. The operator first copies the bootstrap into a fresh root
0700 directory, checks that fixed hash, and only then runs it. The bootstrap copies
the manifest first, verifies its external anchor, copies exactly its members into a
fresh root directory, verifies every file, and starts system Python with `-I`.
Neither a user-writable script nor a self-supplied hash establishes root trust.

The production driver accepts `--verify-only` or the full resume-safe flow. It has
no environment options for changing repositories, user identities or disabling
root checks. Old `--stage`/`--from` switches are rejected. The verified release fixes
the two formal paths, baseline OIDs, target refs and candidate OIDs. Every package
source file is also compared with its object in the candidate AEGL commit before
either project is promoted.

## Sequence and permissions

1. Verify the whole package, live entry-binds, broker service, and both formal
   trees. Stop on any Git failure or genuine uncommitted edit.
2. Copy only bundles into an independent root-owned 0750 staging directory, with
   group `aegl-broker` and 0640 files. The broker can read, not modify, bundles.
   Root's package directory stays 0700. Import objects to
   `refs/aegl-delivery/<anchor-prefix>/<project>`; assert main/master is unchanged.
3. Create a detached candidate worktree at the approved commit, accessible to
   `aegl-promote` only. Check its HEAD, common repository and clean state.
4. Root registers and records that candidate; `aegl-ai` requests promotion through
   the existing broker. Check decisions and the exact approved commit. Only broker
   CAS advances main/master.
5. Check the formal index and files against the approved baseline and candidate
   before restoring source. A new user edit stops the flow without overwriting it.
   The sole dirty-submodule exception is Stack's existing
   `references/architecture-templates` at
   `4a3b2a141f457f1312c8dc52d6cbea6c9592af72`, with unchanged index and tree.
   There is no blanket submodule exemption or ignored Git error.
6. Upgrade the existing task-registry module atomically from the fixed predecessor;
   the CLI bytes do not change. Unknown versions or owner/mode changes stop the
   installation. A verified new version is a no-op; `--help` failure propagates.
7. Verify the two installed files. Remove clean candidate worktrees without force,
   delete only our temporary refs, and remove our exact bundle files/directories.
   Successful bootstrap execution deletes its exact verified package members.

## Interruption and evidence

The driver holds a global root-controlled lock under `/var/lib/aegl-delivery`.
Atomic state is stored in an anchor-bound subdirectory there. It is live resume
state, not an archive of task output. A failure prints the stage and retains the
package and necessary candidate state. There is no automatic retry or rollback.

Explicitly repeat the same trusted bootstrap command to resume the same package.
Do not modify its contents, invent a new delivery ID, clear a registry entry, force
a worktree removal or move a formal ref manually. Resume compares the real target,
broker registration and approved object; a lost record/apply reply does not cause
re-registration or repeat promotion. Marker files alone never prove completion.
An already-final ref without the matching broker approval is rejected.

This flow uses the promoted formal Stack for future Bridge/Supervisor sessions.
It does not update or select the older trusted Stack copy. A future M1 launch must
explicitly use the formal Stack entry, bind to the existing state directory
`/home/zhong/.local/state/google-android-agent-stack/bridge`, and preserve sequence 5.
No M1 launch is included here.

## Local validation

Run from an external AEGL checkout:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s recovery/iap_delivery_tests -v
```

Tests use two temporary project repositories and the actual promotion broker over
a private Unix socket. Record reads the real requested candidate; freeze,
classification and CAS use production code. Broker peers are restricted to the
test user's UID and its test policy points away from the host. Tests cover target
ref preservation, both-repo preflight, Git status failure, candidate identity,
lost record/apply replies, second-repo failure/resume, preservation of post-CAS
staged and unstaged edits, and the exact dirty-submodule exception.

Installation in those flow tests is replaced by a temporary payload-path check.
Installer version classification has separate local checks. Real root install,
service UIDs, mounted formal paths and host promotion remain **NOT_RUN** until the
operator executes the frozen delivery. No local PASS claims those host actions.
