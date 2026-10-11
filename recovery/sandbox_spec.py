#!/usr/bin/env python3
"""Build the bwrap argv for the Hermes sandbox — the ONE argv builder.

Mount + drop split (this round's fix):
  * the ROOT phase does ONLY bwrap's mount/pid/net isolation and the declared-path
    mounts. It does NOT create a user namespace, so the in-sandbox ids are the HOST
    ids (never a namespace uid mistaken for the host uid). Root resolves the 0750
    /home/zhong sources directly — no `--ro-bind-fd` fd trick (which failed with
    "mount: /proc/self/fd/N Permission denied").
  * the FIRST in-sandbox process is a fixed, trusted drop entry (`setpriv`): it clears
    supplementary groups, capabilities and the environment, sets no_new_privs, and
    only THEN drops to the host aegl-ai identity and starts the runner.
No model / project code / AI tool runs before the drop.

Kept separate from the shell launcher so the exact argv can be generated and asserted
without root.

CLI:
    sandbox_spec.py --bwrap B --uid U --gid G --run RUN --wt WT --scr SCR \
        --runtime R --tools T --entry E --installs I --guard-src G --guard-dest D \
        --contract-package P [--setpriv S] [--info-fd N] -- <hermes args...>
Prints the JSON spec on stdout: {"argv": [...], "info_fd": N}.
"""

from __future__ import annotations

import argparse
import json
import sys


def build(*, bwrap, uid, gid, run, wt, scr, runtime, tools, entry, installs, guard_src,
          guard_dest, contract_package, setpriv="/usr/bin/setpriv", drop_verify="drop_verify.py",
          info_fd="", hermes_args) -> dict:
    argv = [
        bwrap,
        # isolation WITHOUT a user namespace: the host ids are preserved
        "--unshare-pid", "--unshare-net", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup",
        # the ONLY capabilities the fixed trusted drop program may use — never --cap-add ALL,
        # never let the model keep running as root (the binary itself is NOT setuid/setcap)
        "--cap-drop", "ALL",
        "--cap-add", "CAP_SETUID", "--cap-add", "CAP_SETGID", "--cap-add", "CAP_SETPCAP",
        # 1. the root filesystem FIRST, then the isolated /proc + /dev and the overlays —
        #    a later `--ro-bind / /` would shadow an earlier /proc or /dev
        "--ro-bind", "/", "/",
        "--proc", "/proc",
        "--dev", "/dev",
        # traversable /home/zhong skeleton (the real one is 0750 and unreachable to the AI)
        "--ro-bind", run + "/stage/home-zhong", "/home/zhong",
        # declared runtime sources, mounted by ROOT (root reads the 0750 sources directly)
        "--ro-bind", runtime, "/home/zhong/.hermes/hermes-agent",
        "--ro-bind", tools, "/home/zhong/.hermes/tools",
        "--ro-bind", entry, "/home/zhong/.local/bin/hermes",
        # the installs lower dir must be a REAL host path (bwrap resolves --overlay-src
        # BEFORE mounting, so it can never be a not-yet-created sandbox path); the upper
        # layer is an ephemeral tmp overlay — no permanent host alias, no copy/archive
        "--overlay-src", installs, "--tmp-overlay", "/home/zhong/.hermes/installs",
        # task config + generated android-stack profile (hooks preserved); secrets masked
        "--ro-bind", run + "/stage/home-zhong/.hermes/config.yaml", "/home/zhong/.hermes/config.yaml",
        "--ro-bind", run + "/stage/home-zhong/.hermes/profiles", "/home/zhong/.hermes/profiles",
        "--tmpfs", "/home/zhong/.hermes/sessions",
        "--ro-bind", run + "/stage/empty", "/home/zhong/.hermes/.env",
        # the contract-guard source, at the canonical path the hooks reference
        "--ro-bind", guard_src, guard_dest,
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
        "--die-with-parent", "--chdir", wt,
    ]
    # the FIRST in-sandbox process is the fixed trusted drop entry; it switches uid/gid,
    # clears supplementary groups AND the bounding/inheritable/ambient capability sets, then
    # verifies the ACTUAL kernel state (uid/gid, all Caps=0, NoNewPrivs=1) before the runner.
    argv += [
        setpriv, "--reuid", str(uid), "--regid", str(gid), "--clear-groups",
        "--no-new-privs", "--bounding-set=-all", "--inh-caps=-all", "--ambient-caps=-all",
        "--", "python3", drop_verify, "--uid", str(uid), "--gid", str(gid),
        "--", "bash", run + "/sandbox-run.sh",
    ] + list(hermes_args)
    return {"argv": argv, "info_fd": info_fd}


def main(argv):
    ap = argparse.ArgumentParser()
    for name in ("bwrap", "uid", "gid", "run", "wt", "scr", "runtime", "tools", "entry",
                 "installs", "guard-src", "guard-dest", "contract-package"):
        ap.add_argument("--" + name, required=True)
    ap.add_argument("--setpriv", default="/usr/bin/setpriv")
    ap.add_argument("--drop-verify", default="drop_verify.py")
    ap.add_argument("--info-fd", default="")
    ap.add_argument("hermes", nargs=argparse.REMAINDER)
    args = ap.parse_args(argv)
    hermes = args.hermes[1:] if args.hermes[:1] == ["--"] else args.hermes
    spec = build(bwrap=args.bwrap, uid=args.uid, gid=args.gid, run=args.run, wt=args.wt, scr=args.scr,
                 runtime=args.runtime, tools=args.tools, entry=args.entry, installs=args.installs,
                 guard_src=args.guard_src, guard_dest=args.guard_dest,
                 contract_package=args.contract_package, setpriv=args.setpriv,
                 drop_verify=args.drop_verify, info_fd=args.info_fd, hermes_args=hermes)
    json.dump(spec, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
