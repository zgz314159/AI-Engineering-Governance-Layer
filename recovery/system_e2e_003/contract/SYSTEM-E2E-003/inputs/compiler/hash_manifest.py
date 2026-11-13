#!/usr/bin/env python3
"""Generate or verify manifest.json (sha256 of every authored artifact).

Usage:
  python3 hash_manifest.py <spec-package-dir>            # write manifest.json
  python3 hash_manifest.py <spec-package-dir> --verify   # verify, do not write

Exit: 0 ok, 1 missing/mismatch, 2 error.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from spec_lib import AUTHORED, MANIFEST_FILE, load_json, sha256_file, write_json


def build_manifest(pkg: str) -> tuple[dict, list[str]]:
    entries = []
    missing = []
    for name, role, required, source in AUTHORED:
        full = os.path.join(pkg, name)
        if not os.path.exists(full):
            if required:
                missing.append(name)
            continue
        entries.append(
            {
                "path": name,
                "sha256": sha256_file(full),
                "size": os.path.getsize(full),
                "role": role,
                "required": required,
                "source": source,
            }
        )
    manifest = {
        "package": os.path.basename(os.path.normpath(pkg)),
        "generated_by": "specification/compiler/hash_manifest.py",
        "algorithm": "sha256",
        "entries": entries,
    }
    return manifest, missing


def verify_manifest(pkg: str, manifest: dict) -> list[str]:
    problems: list[str] = []
    by_path = {entry["path"]: entry for entry in manifest.get("entries", [])}
    for name, _role, required, _source in AUTHORED:
        full = os.path.join(pkg, name)
        if not os.path.exists(full):
            problems.append(f"{name}: missing")
            continue
        entry = by_path.get(name)
        if entry is None:
            problems.append(f"{name}: absent from manifest")
            continue
        if sha256_file(full) != entry["sha256"]:
            problems.append(f"{name}: sha256 mismatch")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Hash a spec package into manifest.json")
    parser.add_argument("package")
    parser.add_argument("--verify", action="store_true", help="verify without writing")
    args = parser.parse_args(argv)

    pkg = os.path.abspath(args.package)
    if not os.path.isdir(pkg):
        print(f"ERROR: not a directory: {pkg}", file=sys.stderr)
        return 2

    if args.verify:
        path = os.path.join(pkg, MANIFEST_FILE)
        if not os.path.exists(path):
            print(f"ERROR: {MANIFEST_FILE} not found", file=sys.stderr)
            return 2
        problems = verify_manifest(pkg, load_json(path))
        if problems:
            for problem in problems:
                print(f"HASH_MISMATCH {problem}", file=sys.stderr)
            return 1
        print(f"MANIFEST=OK package={os.path.basename(pkg)}")
        return 0

    manifest, missing = build_manifest(pkg)
    if missing:
        for name in missing:
            print(f"ERROR: required artifact missing: {name}", file=sys.stderr)
        return 1
    write_json(os.path.join(pkg, MANIFEST_FILE), manifest)
    print(f"MANIFEST=WROTE entries={len(manifest['entries'])} package={manifest['package']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
