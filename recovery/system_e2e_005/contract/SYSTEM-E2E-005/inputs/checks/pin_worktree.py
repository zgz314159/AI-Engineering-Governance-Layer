#!/usr/bin/env python3
"""Execute step: print the `worktree` field of the declared INPUTS-PIN.json.

Extracted verbatim from the SYSTEM-E2E-004 inline ``python3 -B -c`` one-liner whose whole
body was ``import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["worktree"])``.
The pin file still arrives as ``sys.argv[1]``. Read-only.

Usage: pin_worktree.py <INPUTS-PIN.json>
"""

import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["worktree"])
