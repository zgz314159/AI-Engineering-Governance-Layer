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
import re
import sys

_ADDR = re.compile(r"\baddr=(\d+)")
_FAMILY = re.compile(r"\bfamily=(IPv4|IPv6)")
_ELAPSED = re.compile(r"\belapsed_ms=(\d+)")
_RESOLVED = re.compile(r"\bresolved=(\d+)")
_VERSION = re.compile(r"\bversion=(TLSv1\.[0-9])")

_INT_FIELDS = ("seq", "status", "bytes")
_STR_FIELDS = ("task", "error")


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
    if len(sys.argv) != 2:
        print("DIAG_SUMMARY_FAILED reason=usage: iap_diag_summary.py <events.jsonl>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(summarise(sys.argv[1]))
