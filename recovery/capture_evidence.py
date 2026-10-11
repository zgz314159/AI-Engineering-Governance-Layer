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


def uid_of(pid: int) -> str:
    try:
        with open("/proc/%d/status" % pid, encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("Uid:"):
                    return line.split()[1]
    except OSError:
        pass
    return ""


def child_pids(pid: int):
    """The process's live children, from the host /proc (task/*/children)."""
    pids = []
    try:
        for tid in os.listdir("/proc/%d/task" % pid):
            try:
                with open("/proc/%d/task/%s/children" % (pid, tid), encoding="utf-8") as handle:
                    pids += [int(x) for x in handle.read().split()]
            except OSError:
                pass
    except OSError:
        pass
    return pids


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
    try:
        ns = os.readlink("/proc/%d/ns/pid" % pid)
    except OSError:
        ns = ""
    kids = child_pids(pid)
    return {"child_pid": pid, "uid": uid_of(pid), "ns": ns,
            "children_uids": sorted({uid_of(k) for k in kids} - {""}),
            "children_pids": kids,
            "alive": os.path.isdir("/proc/%d" % pid)}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("info_file")
    ap.add_argument("--max-wait", type=float, default=30.0)
    args = ap.parse_args(argv)
    print(json.dumps(capture(args.info_file, args.max_wait), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
