#!/usr/bin/env python3
"""Two-phase sandbox mount helper.

Phase 1 (this process, root): open each declared SOURCE with a file descriptor, so a
source under a directory the AI uid cannot traverse (e.g. /home/zhong, mode 0750) is
opened by root and never re-resolved inside the sandbox's user namespace.

Phase 2: exec ``bwrap`` with ``--ro-bind-fd`` / ``--bind-fd`` for those sources, so the
bind never needs to resolve the source path as the unprivileged uid.

Input (stdin): JSON {"fds": {name: path}, "argv": [ ... ]} where an argv element may be
{"bind_fd": name, "dest": path, "mode": "ro"|"rw", "file": bool}.
"""

from __future__ import annotations

import json
import os
import sys


def main() -> int:
    spec = json.load(sys.stdin)
    fds = {}
    for name, path in spec.get("fds", {}).items():
        flags = os.O_RDONLY
        try:
            if os.path.isdir(path):
                flags |= os.O_DIRECTORY
        except OSError:
            return 2
        fd = os.open(path, flags)
        os.set_inheritable(fd, True)
        fds[name] = fd
    info_fd = spec.get("info_fd")
    if info_fd not in (None, "", 0):
        try:
            os.set_inheritable(int(info_fd), True)
        except (OSError, ValueError):
            pass
    argv = []
    for item in spec.get("argv", []):
        if isinstance(item, dict) and "bind_fd" in item:
            name = item["bind_fd"]
            if name not in fds:
                sys.stderr.write("bind_fd: unknown source %r\n" % name)
                return 2
            argv += ["--bind-fd" if item.get("mode") == "rw" else "--ro-bind-fd", str(fds[name]), item["dest"]]
        else:
            argv.append(str(item))
    if not argv:
        sys.stderr.write("bind_fd: empty argv\n")
        return 2
    os.execvp(argv[0], argv)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
