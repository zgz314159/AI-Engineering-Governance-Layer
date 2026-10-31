#!/usr/bin/env python3
"""promote_stack_sync.py — production wrapper around the EXISTING formal-sync verifier.

It does not re-implement the checks: it constructs the existing
``iap_delivery.Delivery`` and calls its ``clean_formal`` / ``sync`` methods (index AND
worktree joint verification, exact known-gitlink handling, ``git restore``), so the one
verified implementation is the one on the production path.

Modes:
  pre_cas   verify the formal tree is the approved baseline (only the known gitlink lag)
  sync      broker CAS already moved the ref; verify the approved baseline lag in BOTH
            index and worktree, then restore index+worktree to the candidate. A real
            modification -> refuse and preserve. A failed Git query is fatal (never
            treated as an empty result).
  cleanup   resume cleanup from the trusted per-task record (original candidate paths).

All Git invocations go through ``Delivery.git``: exact command-level safe.directory,
controlled environment, and non-zero exit -> DeliveryError (never swallowed).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import iap_delivery  # noqa: E402

DEFAULT_TARGET_REF = "refs/heads/master"
DEFAULT_GITLINK_PATH = "references/architecture-templates"
DEFAULT_GITLINK_OID = "4a3b2a141f457f1312c8dc52d6cbea6c9592af72"
CAND_DIR_RE = re.compile(r"^/var/tmp/iap-smoke-promote-[A-Za-z0-9]+$")


def _delivery(ledger: str):
    Path(ledger).mkdir(parents=True, exist_ok=True)
    return iap_delivery.Delivery(
        package=ledger, anchor="stack-promote", release={"repos": []},
        ledger=ledger, workspace=ledger,
    )


def _row(args):
    return {
        "name": "stack",
        "path": args.project,
        "target_ref": args.target_ref,
        "base": args.base,
        "final": args.final,
        "gitlinks": {args.gitlink_path: args.gitlink_oid},
    }


def mode_pre_cas(d, args) -> int:
    d.clean_formal(_row(args), args.base)
    print("FORMAL_PRE_CAS_OK=1", flush=True)
    return 0


def mode_sync(d, args) -> int:
    d.sync(_row(args))
    print("SYNC_FORMAL_OK", flush=True)
    return 0


def mode_cleanup(d, args) -> int:
    record = Path(args.record)
    if not record.is_file():
        print("CLEANUP_STOP reason=record_missing:%s" % record, file=sys.stderr)
        return 1
    try:
        rec = json.loads(record.read_text())
    except Exception as exc:  # noqa: BLE001
        print("CLEANUP_STOP reason=record_invalid:%s" % exc, file=sys.stderr)
        return 1
    ext = str(rec.get("ext", ""))
    bundle = str(rec.get("bundle", ""))
    if not CAND_DIR_RE.match(ext):
        print("CLEANUP_STOP reason=record_ext_invalid:%r" % ext, file=sys.stderr)
        return 1
    if bundle and bundle != ext + "/candidate.bundle":
        print("CLEANUP_STOP reason=record_bundle_invalid:%r" % bundle, file=sys.stderr)
        return 1

    # candidate ref — precise deletion with the expected old value
    found = d.git(args.project, "show-ref", "--verify", "--quiet", args.candidate_ref, check=False)
    if found.returncode not in (0, 1):
        print("CLEANUP_STOP reason=ref_query_failed rc=%s" % found.returncode, file=sys.stderr)
        return 1
    if found.returncode == 0:
        d.git(args.project, "update-ref", "-d", args.candidate_ref, args.commit)
        print("CLEANUP_REF_DELETED %s expected=%s" % (args.candidate_ref, args.commit), flush=True)

    # candidate worktree — only ours, only at the candidate commit
    wt = os.path.join(ext, "wt")
    if os.path.exists(wt):
        head = d.git(wt, "rev-parse", "HEAD", check=False)
        if head.returncode != 0 or head.stdout.decode().strip() != args.commit:
            print("CLEANUP_STOP reason=candidate_head_mismatch:%s" % wt, file=sys.stderr)
            return 1
        d.git(args.project, "worktree", "remove", wt)
        print("CLEANUP_WORKTREE_REMOVED %s" % wt, flush=True)

    if bundle and os.path.exists(bundle):
        os.unlink(bundle)
        print("CLEANUP_BUNDLE_REMOVED %s" % bundle, flush=True)

    if os.path.isdir(ext):
        try:
            os.rmdir(ext)
        except OSError:
            print("CLEANUP_STOP reason=leftovers_preserved:%s" % ext, file=sys.stderr)
            return 1

    try:
        os.unlink(record)
    except OSError:
        print("CLEANUP_STOP reason=record_unlink_failed:%s" % record, file=sys.stderr)
        return 1
    print("CLEANUP_DONE", flush=True)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("pre_cas", "sync", "cleanup"), required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--target-ref", default=DEFAULT_TARGET_REF)
    ap.add_argument("--base")
    ap.add_argument("--final")
    ap.add_argument("--commit")
    ap.add_argument("--candidate-ref")
    ap.add_argument("--record")
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--gitlink-path", default=DEFAULT_GITLINK_PATH)
    ap.add_argument("--gitlink-oid", default=DEFAULT_GITLINK_OID)
    args = ap.parse_args(argv)

    d = _delivery(args.ledger)
    try:
        if args.mode in ("pre_cas", "sync"):
            if not args.base or not args.final:
                raise iap_delivery.DeliveryError("base/final required")
            return mode_pre_cas(d, args) if args.mode == "pre_cas" else mode_sync(d, args)
        if not args.commit or not args.candidate_ref or not args.record:
            raise iap_delivery.DeliveryError("commit/candidate-ref/record required for cleanup")
        return mode_cleanup(d, args)
    except iap_delivery.DeliveryError as exc:
        print("SYNC_STOP reason=%s" % exc, file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 - any failure is fatal and reported
        print("SYNC_STOP reason=%s:%s" % (type(exc).__name__, exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
