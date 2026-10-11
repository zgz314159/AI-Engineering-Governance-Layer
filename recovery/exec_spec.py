#!/usr/bin/env python3
"""Exec the bwrap argv from a sandbox spec (no fd mounts — plain root mounts).

Reads {"argv": [...]} and execv's it. The info-fd (if any) is already open in this
process and its number is embedded in the argv, so bwrap inherits it.
"""

import json
import os
import sys


def main(argv):
    spec = json.load(open(argv[1], encoding="utf-8"))
    cmd = spec["argv"]
    os.execv(cmd[0], cmd)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
