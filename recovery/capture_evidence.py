#!/usr/bin/env python3
"""Capture trusted identity/namespace evidence from the ACTUAL Hermes process.

bwrap's ``--info-fd`` writes ``{"child-pid": N}`` — that pid is the sandbox's FIRST
process (the trusted drop entry), NOT the model. This helper waits for the real Hermes
process to appear in that process's descendant tree, then while it is ALIVE reads the
HOST uid and pid namespace of Hermes itself and of its tool subprocesses. The root
prep/init process is never used as a stand-in, and an empty children list is never
counted as "all children passed".

CLI: capture_evidence.py <info_file> [--max-wait 30] [--hermes-wait 240]
Prints JSON {"child_pid":N,"hermes_pid":N,"uid":"..","ns":"pid:[..]","children_uids":[...],
"children_pids":[...],"alive":true} or {"error":"hermes_not_found",...}.
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


def ns_of(pid: int) -> str:
    try:
        return os.readlink("/proc/%d/ns/pid" % pid)
    except OSError:
        return ""


def cmdline(pid: int) -> str:
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as handle:
            return handle.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    except OSError:
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


def descendants(pid: int):
    out = []
    frontier = [pid]
    while frontier:
        current = frontier.pop()
        for child in child_pids(current):
            if child not in out:
                out.append(child)
                frontier.append(child)
    return out


def is_hermes(pid: int) -> bool:
    cmd = cmdline(pid)
    return "hermes" in cmd and ("chat" in cmd or "-p " in cmd)


def capture(info_file: str, max_wait: float = 30.0, hermes_wait: float = 240.0) -> dict:
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

    # walk the trusted chain until the REAL Hermes process exists (init is not the model)
    hermes_pid = None
    end = time.monotonic() + hermes_wait
    while time.monotonic() < end:
        for candidate in [pid] + descendants(pid):
            if is_hermes(candidate):
                hermes_pid = candidate
                break
        if hermes_pid:
            break
        if not os.path.isdir("/proc/%d" % pid):
            return {"error": "init_gone_before_hermes", "child_pid": pid}
        time.sleep(0.2)
    if not hermes_pid:
        return {"error": "hermes_not_found", "child_pid": pid}

    kids = descendants(hermes_pid)
    return {"child_pid": pid, "hermes_pid": hermes_pid,
            "uid": uid_of(hermes_pid), "ns": ns_of(hermes_pid),
            "children_uids": sorted({uid_of(k) for k in kids} - {""}),
            "children_pids": kids,
            "alive": os.path.isdir("/proc/%d" % hermes_pid)}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("info_file")
    ap.add_argument("--max-wait", type=float, default=30.0)
    ap.add_argument("--hermes-wait", type=float, default=240.0)
    args = ap.parse_args(argv)
    print(json.dumps(capture(args.info_file, args.max_wait, args.hermes_wait), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
