#!/usr/bin/env python3
"""Create every mount TARGET that lives under the read-only /home/zhong skeleton.

bwrap requires each bind/tmpfs/overlay DESTINATION to already exist with a type that
matches its SOURCE. This derives the target list from the ACTUAL generated argv — so a
newly added mount can never be forgotten — and creates only what is missing inside
$RUN/stage/home-zhong. It never touches the real /home/zhong or any project, and never
overwrites existing content (config.yaml, profiles, ...).

CLI: prepare_targets.py <spec.json> <skeleton_dir>
"""

from __future__ import annotations

import json
import os
import sys

SKELETON_PREFIX = "/home/zhong"


def create(target: str, kind: str) -> str:
    """kind: 'dir' or 'file'. Returns 'created' / 'exists' / 'type-mismatch'."""
    parent = os.path.dirname(target)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if kind == "dir":
        if os.path.isdir(target):
            return "exists"
        if os.path.exists(target):
            return "type-mismatch"
        os.makedirs(target, exist_ok=True)
        return "created"
    if os.path.isfile(target):
        return "exists"
    if os.path.exists(target):
        return "type-mismatch"
    with open(target, "a", encoding="utf-8"):
        pass
    return "created"


def kind_of(source: str) -> str:
    if not os.path.exists(source):
        # the launcher creates its stage files first; flag it rather than guess silently
        print("TARGET_SOURCE_MISSING %s (treated as a dir target)" % source)
        return "dir"
    return "file" if os.path.isfile(source) else "dir"


def targets_from_argv(argv, skeleton):
    """Yield (target_path, kind) for every destination under /home/zhong."""
    out = []
    i = 0
    while i < len(argv):
        opt = argv[i]
        if opt in ("--ro-bind", "--bind") and i + 2 < len(argv):
            src, dest = argv[i + 1], argv[i + 2]
            if dest == SKELETON_PREFIX or dest.startswith(SKELETON_PREFIX + "/"):
                out.append((skeleton + dest[len(SKELETON_PREFIX):], kind_of(src)))
            i += 3
            continue
        if opt in ("--tmpfs", "--tmp-overlay") and i + 1 < len(argv):
            dest = argv[i + 1]
            if dest == SKELETON_PREFIX or dest.startswith(SKELETON_PREFIX + "/"):
                out.append((skeleton + dest[len(SKELETON_PREFIX):], "dir"))
            i += 2
            continue
        i += 1
    return out


def main(argv):
    spec = json.load(open(argv[1], encoding="utf-8"))
    skeleton = argv[2].rstrip("/")
    bad = 0
    for target, kind in targets_from_argv(spec["argv"], skeleton):
        result = create(target, kind)
        if result == "type-mismatch":
            print("TARGET_TYPE_MISMATCH %s (%s)" % (target, kind))
            bad = 1
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
