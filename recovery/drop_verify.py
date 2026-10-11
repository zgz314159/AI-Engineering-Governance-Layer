#!/usr/bin/env python3
"""Fixed trusted drop entry: confirm the identity/capability handoff, then exec the runner.

It runs as the FIRST in-sandbox process AFTER setpriv has switched to the host aegl-ai. It
verifies the ACTUAL kernel state of THIS process:
  * real/effective/saved UID and GID equal the host aegl-ai ids
  * CapEff, CapPrm, CapInh, CapAmb are all zero
  * NoNewPrivs == 1
  * no supplementary groups remain
It records only the UID/GID, the capability sets and the restriction state — never a
credential or the full environment. If any check fails it prints the actual state and the
first failure, and exits non-zero so the model never starts. On success it execs the runner.

CLI: drop_verify.py --uid U --gid G -- <cmd...>
"""

from __future__ import annotations

import argparse
import os
import sys


def status_field(text: str, key: str) -> str:
    for line in text.splitlines():
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip()
    return ""


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--uid", required=True)
    ap.add_argument("--gid", required=True)
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    args = ap.parse_args(argv)
    cmd = args.rest[1:] if args.rest[:1] == ["--"] else args.rest
    if not cmd:
        print("DROP_HANDOFF_FAIL no command to run")
        return 2

    with open("/proc/self/status", encoding="utf-8") as handle:
        st = handle.read()
    uid_line = status_field(st, "Uid").split()
    gid_line = status_field(st, "Gid").split()
    caps = {k: status_field(st, k) for k in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb")}
    nnp = status_field(st, "NoNewPrivs")
    groups = status_field(st, "Groups")

    print("DROP_HANDOFF uid=%s gid=%s caps=eff:%s prm:%s inh:%s amb:%s bnd:%s nnp=%s groups=[%s]" % (
        uid_line[1] if len(uid_line) > 1 else "?", gid_line[1] if len(gid_line) > 1 else "?",
        caps["CapEff"], caps["CapPrm"], caps["CapInh"], caps["CapAmb"], caps["CapBnd"], nnp, groups))

    reasons = []
    if len(uid_line) < 3 or any(u != args.uid for u in uid_line[:3]):
        reasons.append("uid %s != %s" % (uid_line, args.uid))
    if len(gid_line) < 3 or any(g != args.gid for g in gid_line[:3]):
        reasons.append("gid %s != %s" % (gid_line, args.gid))
    for key in ("CapEff", "CapPrm", "CapInh", "CapAmb"):
        if caps[key].strip("0") != "":
            reasons.append("%s=%s" % (key, caps[key]))
    if nnp != "1":
        reasons.append("NoNewPrivs=%s" % nnp)
    if groups.strip():
        reasons.append("supplementary groups=[%s]" % groups)
    if reasons:
        print("DROP_HANDOFF_FAIL " + "; ".join(reasons))
        return 1

    os.execvp(cmd[0], cmd)
    return 127


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
