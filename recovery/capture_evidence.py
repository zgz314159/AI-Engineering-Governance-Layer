#!/usr/bin/env python3
"""Capture trusted identity/namespace evidence from the ACTUAL sandbox child.

bwrap's ``--info-fd`` writes ``{"child-pid": N}`` once the container is up. This helper
polls that file, and while the child is still ALIVE reads the child's uid and pid
namespace from the host ``/proc``. It never trusts the model's own output.

CLI: capture_evidence.py <info_file> [--max-wait 30]
Prints JSON {"child_pid": N, "uid": "994", "ns": "pid:[N]", "alive": true} or {"error": ...}.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time


def read_info(path: str):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        pid = data.get("child-pid")
        return int(pid) if pid else None
    except (OSError, ValueError, TypeError):
        return None


def capture(info_file: str, max_wait: float = 30.0) -> dict:
    deadline = time.monotonic() + max_wait
    pid = None
    while time.monotonic() < deadline:
        pid = read_info(info_file)
        if pid and os.path.isdir("/proc/%d" % pid):
            break
        time.sleep(0.1)
    if not pid:
        return {"error": "no_child_pid"}
    if not os.path.isdir("/proc/%d" % pid):
        return {"error": "child_gone_before_capture", "child_pid": pid}
    uid = ""
    try:
        with open("/proc/%d/status" % pid, encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("Uid:"):
                    uid = line.split()[1]
                    break
    except OSError:
        pass
    try:
        ns = os.readlink("/proc/%d/ns/pid" % pid)
    except OSError:
        ns = ""
    return {"child_pid": pid, "uid": uid, "ns": ns, "alive": os.path.isdir("/proc/%d" % pid)}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("info_file")
    ap.add_argument("--max-wait", type=float, default=30.0)
    args = ap.parse_args(argv)
    print(json.dumps(capture(args.info_file, args.max_wait), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
