#!/usr/bin/env python3
"""Read step, part 1: verify every manifest member hash and the READY status.

Extracted verbatim from the SYSTEM-E2E-004 inline read heredoc body. The business logic and
the relative file names are unchanged; the caller runs this from
``$HERMES_CONTRACT_PACKAGE`` exactly where the original heredoc ran, so no path is passed
in. Read-only.

Usage: read_manifest_check.py
Exit: 0 verified, 1 refused.
"""

import hashlib
import json
import os


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


manifest = json.load(open("manifest.json", encoding="utf-8"))
for entry in manifest["entries"]:
    path = entry["path"]
    if not os.path.isfile(path) or sha(path) != entry["sha256"]:
        raise SystemExit("READ_FAIL manifest member " + path)
ready = json.load(open("READY.json", encoding="utf-8"))
if ready.get("status") != "READY":
    raise SystemExit("READ_FAIL READY " + str(ready.get("status")))
print("READ_STAGE=CONTRACT_OK entries=%d ready=READY" % len(manifest["entries"]))
