#!/usr/bin/env python3
"""Read step, part 2: print the declared read_first path from project-context.json.

Extracted verbatim from the SYSTEM-E2E-004 inline ``python3 -B -c`` one-liner whose whole
body was ``import json; print(json.load(open("project-context.json", encoding="utf-8"))["read_first"][0]["path"])``.
The relative file name is unchanged and resolves against the caller's cwd, which is
``$HERMES_CONTRACT_PACKAGE`` in that call. Read-only; prints the path only.

Usage: inputs_pin_path.py
"""

import json

print(json.load(open("project-context.json", encoding="utf-8"))["read_first"][0]["path"])
