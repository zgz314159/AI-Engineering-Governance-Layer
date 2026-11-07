#!/usr/bin/env python3
"""Deliberately unavailable observer client used ONLY to simulate observer failure.

It reads and discards stdin, never connects, never prints, and exits 0. The guard client,
broker, launcher and tool executor remain the real candidate code. Substitution scope:
only bin/tool_event_client.py in the dedicated observer-failure view.
"""

from __future__ import annotations

import sys


def main() -> int:
    try:
        sys.stdin.read()
    except Exception:  # noqa: BLE001
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
