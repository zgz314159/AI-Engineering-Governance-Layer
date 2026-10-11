#!/usr/bin/env python3
"""Build the bwrap argv (and fd-map) for the Hermes sandbox — the ONE argv builder.

Kept separate from the shell launcher so the exact argv can be generated and asserted
without root. It includes the WRITABLE task mounts (worktree + scratch) taken from the
trusted registry, the traversable /home/zhong skeleton, the fd-bound runtime sources
(the 0750 /home/zhong paths root opened), the guard source, and the in-sandbox runner.

CLI:
    sandbox_spec.py --bwrap B --uid U --gid G --run RUN --wt WT --scr SCR \
        --runtime R --tools T --entry E --installs I --guard-src G --guard-dest D \
        [--info-fd N] -- <hermes args...>
Prints the JSON spec on stdout.
"""

from __future__ import annotations

import argparse
import json
import sys


def build(*, bwrap, uid, gid, run, wt, scr, runtime, tools, entry, installs, guard_src,
          guard_dest, contract_package, info_fd, hermes_args) -> dict:
    argv = [
        bwrap, "--unshare-all", "--uid", uid, "--gid", gid, "--dev", "/dev", "--proc", "/proc",
        "--ro-bind", "/", "/",
        # traversable /home/zhong skeleton (the real one is 0750 and unreachable to the AI)
        "--ro-bind", run + "/stage/home-zhong", "/home/zhong",
        {"bind_fd": "runtime", "dest": "/home/zhong/.hermes/hermes-agent"},
        {"bind_fd": "tools", "dest": "/home/zhong/.hermes/tools"},
        {"bind_fd": "entry", "dest": "/home/zhong/.local/bin/hermes"},
        # installs must be writable to the runtime but ephemeral (host untouched)
        "--ro-bind", run + "/stage/run-aegl", "/run/aegl-run",
        {"bind_fd": "installs", "dest": "/run/aegl-run/installs-ro"},
        "--overlay-src", "/run/aegl-run/installs-ro", "--tmp-overlay", "/home/zhong/.hermes/installs",
        # task config + generated android-stack profile (hooks preserved); secrets masked
        "--ro-bind", run + "/stage/home-zhong/.hermes/config.yaml", "/home/zhong/.hermes/config.yaml",
        "--ro-bind", run + "/stage/home-zhong/.hermes/profiles", "/home/zhong/.hermes/profiles",
        "--tmpfs", "/home/zhong/.hermes/sessions",
        "--ro-bind", run + "/stage/empty", "/home/zhong/.hermes/.env",
        # the contract-guard source, at the canonical path the hooks reference
        {"bind_fd": "guard", "dest": guard_dest},
        # the frozen contract package, read-only (the guard reads it)
        "--ro-bind", contract_package, contract_package,
        # WRITABLE task mounts (from the trusted registry) — the ONLY writable project paths
        "--bind", wt, wt,
        "--bind", scr, scr,
        "--bind", run + "/home", run + "/home",
    ]
    if info_fd:
        argv += ["--info-fd", str(info_fd)]
    argv += [
        "--clearenv", "--setenv", "PATH", "/usr/local/bin:/usr/bin:/bin:/home/zhong/.local/bin",
        "--setenv", "HOME", run + "/home", "--setenv", "HERMES_HOME", "/home/zhong/.hermes",
        "--setenv", "TMPDIR", scr, "--setenv", "AEGL_AI_SANDBOX", "1",
        "--setenv", "HERMES_CONTRACT_PACKAGE", contract_package,
        "--die-with-parent", "--chdir", wt, "bash", run + "/sandbox-run.sh",
    ] + list(hermes_args)
    return {"fds": {"runtime": runtime, "tools": tools, "entry": entry, "installs": installs,
                    "guard": guard_src}, "info_fd": info_fd, "argv": argv}


def main(argv):
    ap = argparse.ArgumentParser()
    for name in ("bwrap", "uid", "gid", "run", "wt", "scr", "runtime", "tools", "entry",
                 "installs", "guard-src", "guard-dest", "contract-package"):
        ap.add_argument("--" + name, required=True)
    ap.add_argument("--info-fd", default="")
    ap.add_argument("hermes", nargs=argparse.REMAINDER)
    args = ap.parse_args(argv)
    hermes = args.hermes[1:] if args.hermes[:1] == ["--"] else args.hermes
    spec = build(bwrap=args.bwrap, uid=args.uid, gid=args.gid, run=args.run, wt=args.wt, scr=args.scr,
                 runtime=args.runtime, tools=args.tools, entry=args.entry, installs=args.installs,
                 guard_src=args.guard_src, guard_dest=args.guard_dest,
                 contract_package=args.contract_package, info_fd=args.info_fd, hermes_args=hermes)
    json.dump(spec, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
