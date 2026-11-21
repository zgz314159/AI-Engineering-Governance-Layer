#!/usr/bin/env python3
"""Whitelisted summary of the AEGL diagnostic sink.

Prints ONLY metadata from an explicit allowlist. The free-form ``arg`` label is NEVER
echoed: for the connection phases it is parsed as a fixed-format record and only the
address index, the address family, the elapsed milliseconds and the resolved count are
re-emitted. Bodies, headers, credentials and the environment are never read or printed.

    iap_diag_summary.py <events.jsonl>
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import stat
import sys

_ADDR = re.compile(r"\baddr=(\d+)")
_FAMILY = re.compile(r"\bfamily=(IPv4|IPv6)")
_ELAPSED = re.compile(r"\belapsed_ms=(\d+)")
_RESOLVED = re.compile(r"\bresolved=(\d+)")
_VERSION = re.compile(r"\bversion=(TLSv1\.[0-9])")

_INT_FIELDS = ("seq", "status", "bytes")
_STR_FIELDS = ("task", "error")


def registered_events(task, *, registry=Path('/var/lib/aegl-model/registry.json'),
                      diag_root=Path('/var/tmp/aegl-diag'), required_uid=0):
    """Resolve only a registered task's root-owned metadata sink; never arbitrary paths."""
    if not isinstance(task, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', task):
        raise ValueError('DIAG_TASK_ID')
    def trusted(path, directory=False):
        s=path.lstat()
        correct_type=stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode)
        if not correct_type or s.st_uid != required_uid or s.st_mode & 0o022:
            raise ValueError('DIAG_UNTRUSTED_PATH')
        return s
    trusted(registry.parent, directory=True)
    trusted(registry)
    entry=json.loads(registry.read_text()).get(task)
    if not isinstance(entry, dict) or not entry.get('contract_package'):
        raise ValueError('DIAG_UNREGISTERED_TASK')
    trusted(diag_root, directory=True)
    sink=diag_root/task
    trusted(sink, directory=True)
    events=sink/'events.jsonl'
    if trusted(events).st_size > 8*1024*1024:
        raise ValueError('DIAG_SINK_TOO_LARGE')
    return events


def summarise(path: str) -> int:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        print("CONNECT_DIAG=ABSENT")
        return 0
    except OSError as exc:
        print("CONNECT_DIAG=UNREADABLE error=%s" % type(exc).__name__)
        return 0

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        out = ["phase=%s" % str(event.get("phase") or "?")[:64]]
        for key in _INT_FIELDS:
            value = event.get(key)
            if isinstance(value, int):
                out.append("%s=%d" % (key, value))
        for key in _STR_FIELDS:
            value = event.get(key)
            if isinstance(value, str) and value:
                out.append("%s=%s" % (key, value[:64]))
        # fixed-format label fields ONLY — the raw arg is never printed
        arg = event.get("arg")
        if isinstance(arg, str):
            for pattern, label in ((_ADDR, "addr"), (_FAMILY, "family"), (_ELAPSED, "elapsed_ms"),
                                   (_RESOLVED, "resolved"), (_VERSION, "version")):
                match = pattern.search(arg)
                if match:
                    out.append("%s=%s" % (label, match.group(1)))
        print("DIAG " + " ".join(out))
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == '--task':
        if os.geteuid() != 0:
            raise SystemExit('DIAG_SUMMARY_FAILED reason=root_required')
        try:
            events=registered_events(sys.argv[2])
        except (OSError, ValueError) as exc:
            print('DIAG_SUMMARY_FAILED reason='+type(exc).__name__,file=sys.stderr)
            raise SystemExit(2)
        raise SystemExit(summarise(str(events)))
    if len(sys.argv) != 2:
        print("DIAG_SUMMARY_FAILED reason=usage: iap_diag_summary.py <events.jsonl>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(summarise(sys.argv[1]))
