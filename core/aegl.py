#!/usr/bin/env python3
"""AEGL core CLI — technology-agnostic front end for the target-project adapters.

Commands:
  aegl adapters                     List adapter descriptors.
  aegl inspect <project>            Scan a project (read-only) -> project profile.
  aegl attach  <project> [--dry-run] Generate the AEGL governance overlay.
  aegl verify  <project>            Run the adapter's governance gate.
  aegl detach  <project> [--dry-run] Remove only AEGL-created integration.

Continuity Layer (v1.3):
  aegl status   [--root R] [--json]          Current machine facts + handoff age.
  aegl handoff  [--root R] [--goal ...] ...  Write a resumable session handoff.
  aegl resume   [--root R] [--json] [--with-memory]  Lightweight consistency check.
  aegl continuity history [--root R] [--json]  List handoff snapshots.
  aegl continuity check    [--root R] [--json]  Diagnostic schema check (never a gate).

Persistent Work Memory (v1.4, OPTIONAL — Beads via the official `bd` CLI):
  aegl memory status [--root R] [--json]     Backend availability / health.
  aegl memory setup beads [--root R]         Initialise Beads (stealth, no agent files).
  aegl memory prime [--memories-only] [--json]  Inject Beads workflow + memories.
  aegl memory remember [KEY] VALUE [--key K] [--value V]  Store a durable fact (redacted).
  aegl memory ready [--limit N] [--json]     Ready work straight from `bd ready`.
  aegl memory disable [--root R]             Switch backend off (never deletes data).
  aegl bd <bd args...>                       Run `bd` with AEGL's environment applied.

The core never scans a parent directory: it only touches the path the user names.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADAPTERS_DIR = ROOT / "adapters"
IMPLEMENTED = ["android", "kotlin"]  # detection priority order

# The Continuity Layer (v1.3) ships with the core.
from continuity import commands as continuity  # noqa: E402
from continuity import memory_commands  # noqa: E402


def _load_adapter(lang: str):
    path = ADAPTERS_DIR / lang / "adapter.py"
    spec = importlib.util.spec_from_file_location(f"aegl_adapter_{lang}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _descriptors() -> list[dict]:
    out = []
    for d in sorted(p for p in ADAPTERS_DIR.iterdir() if p.is_dir()):
        j = d / "adapter.json"
        if j.exists():
            out.append(json.loads(j.read_text(encoding="utf-8")))
    return out


def _select(project: Path):
    """Return (lang, module, profile) for the first matching implemented adapter."""
    for lang in IMPLEMENTED:
        mod = _load_adapter(lang)
        profile = mod.detect(project)
        if profile.get("matched"):
            return lang, mod, profile
    return None, None, None


def _emit(obj: dict, code: int = 0) -> int:
    print(json.dumps(obj, indent=2))
    return code


def cmd_adapters(args) -> int:
    return _emit({"adapters": _descriptors()})


def cmd_version(args) -> int:
    vfile = ROOT / "VERSION"
    version = vfile.read_text(encoding="utf-8").strip() if vfile.exists() else "0.0.0"
    return _emit({"aeglVersion": version})


def cmd_inspect(args) -> int:
    project = Path(args.project)
    if not project.is_dir():
        return _emit({"error": f"not a directory: {project}"}, 2)
    lang, mod, profile = _select(project)
    if not lang:
        return _emit({
            "matched": False,
            "message": "No implemented adapter matched this project.",
            "adapters": _descriptors(),
        }, 3)
    resolved = project.resolve()
    # The technology-specific profile is owned by the adapter; the core stays
    # technology-agnostic and only adds the fields common to every adapter.
    summary = mod.inspect_summary(resolved, profile) if hasattr(mod, "inspect_summary") else {}
    result = {
        "matched": True,
        "adapter": lang,
        "adapterVersion": profile.get("adapterVersion", "0.0.0"),
        "project": str(resolved),
        **summary,
        "indicators": profile.get("indicators", {}),
        "attached": (project / ".aegl/manifest.json").exists(),
    }
    if args.write:
        target = resolved / ".aegl/project-profile.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        result["wroteProfile"] = str(target)
    return _emit(result)


def cmd_attach(args) -> int:
    project = Path(args.project)
    if not project.is_dir():
        return _emit({"error": f"not a directory: {project}"}, 2)
    lang, mod, _ = _select(project)
    if not lang:
        return _emit({"error": "no implemented adapter matched; refusing to attach"}, 3)
    manifest = mod.attach(project, dry_run=args.dry_run)
    return _emit({"adapter": lang, **manifest})


def cmd_verify(args) -> int:
    project = Path(args.project)
    if not project.is_dir():
        return _emit({"error": f"not a directory: {project}"}, 2)
    lang, mod, _ = _select(project)
    if not lang:
        return _emit({"error": "no implemented adapter matched"}, 3)
    result = mod.verify(project)
    result["adapter"] = lang
    result["project"] = str(project.resolve())
    return _emit(result, 0 if result.get("ok") else 1)


def cmd_detach(args) -> int:
    project = Path(args.project)
    if not project.is_dir():
        return _emit({"error": f"not a directory: {project}"}, 2)
    lang, mod, _ = _select(project)
    if not lang:
        return _emit({"error": "no implemented adapter matched"}, 3)
    result = mod.detach(project, dry_run=args.dry_run)
    return _emit({"adapter": lang, **result}, 0 if "error" not in result else 4)


def _croot(args) -> Path:
    return Path(args.root).resolve()


def cmd_status(args) -> int:
    return continuity.do_status(_croot(args), args.json)


def cmd_handoff(args) -> int:
    return continuity.do_handoff(_croot(args), args)


def cmd_resume(args) -> int:
    return continuity.do_resume(_croot(args), args.json,
                                with_memory=getattr(args, "with_memory", False))


def cmd_memory(args) -> int:
    root = _croot(args)
    sub = args.memory_command
    if sub == "status":
        return memory_commands.do_status(root, args.json)
    if sub == "setup":
        return memory_commands.do_setup(root, args.target, args.json)
    if sub == "prime":
        return memory_commands.do_prime(root, args.memories_only, args.json)
    if sub == "remember":
        if getattr(args, "value", None) is not None:
            key, value = args.key, args.value
        elif getattr(args, "extra", None) is not None:
            key, value = args.content, args.extra
        elif getattr(args, "content", None) is not None:
            key, value = args.key, args.content
        else:
            return _emit({"error": "no memory content given"}, 2)
        return memory_commands.do_remember(root, key, value, args.json)
    if sub == "ready":
        return memory_commands.do_ready(root, args.limit, args.json)
    if sub == "disable":
        return memory_commands.do_disable(root, args.json)
    return _emit({"error": f"unknown memory command: {sub}"}, 2)


def cmd_bd(args) -> int:
    bd_args = list(getattr(args, "bd_args", []) or [])
    if bd_args and bd_args[0] == "--":
        bd_args = bd_args[1:]
    return memory_commands.do_bd(_croot(args), bd_args)


def cmd_continuity(args) -> int:
    root = _croot(args)
    if args.continuity_command == "history":
        return continuity.do_history(root, args.json)
    if args.continuity_command == "check":
        return continuity.do_check(root, args.json)
    return _emit({"error": f"unknown continuity command: {args.continuity_command}"}, 2)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="aegl", description="AEGL target-project governance CLI")
    sub = p.add_subparsers(dest="command", required=True)

    def add_continuity_args(parser: argparse.ArgumentParser) -> None:
        parser.add_argument("--root", default=str(ROOT),
                            help="Project root whose .aegl/continuity is used (default: AEGL root)")
        parser.add_argument("--json", action="store_true", help="Emit JSON instead of text")

    sub.add_parser("adapters", help="List adapter descriptors").set_defaults(func=cmd_adapters)
    sub.add_parser("version", help="Print the AEGL version").set_defaults(func=cmd_version)

    pi = sub.add_parser("inspect", help="Scan a project (read-only)")
    pi.add_argument("project")
    pi.add_argument("--write", action="store_true", help="Write .aegl/project-profile.json")
    pi.set_defaults(func=cmd_inspect)

    pa = sub.add_parser("attach", help="Generate the AEGL governance overlay")
    pa.add_argument("project")
    pa.add_argument("--dry-run", action="store_true", dest="dry_run")
    pa.set_defaults(func=cmd_attach)

    pv = sub.add_parser("verify", help="Run the adapter governance gate")
    pv.add_argument("project")
    pv.set_defaults(func=cmd_verify)

    pd = sub.add_parser("detach", help="Remove AEGL-created integration only")
    pd.add_argument("project")
    pd.add_argument("--dry-run", action="store_true", dest="dry_run")
    pd.set_defaults(func=cmd_detach)

    # --- Continuity Layer (v1.3) --------------------------------------------
    ps = sub.add_parser("status", help="Show current project facts and handoff age")
    add_continuity_args(ps)
    ps.set_defaults(func=cmd_status)

    ph = sub.add_parser("handoff", help="Write a resumable session handoff")
    add_continuity_args(ph)
    ph.add_argument("--goal", help="Current goal (semantic)")
    ph.add_argument("--task", help="Current task (semantic)")
    ph.add_argument("--phase", help="Current phase name (semantic)")
    ph.add_argument("--next", help="Next action (semantic)")
    ph.add_argument("--next-command", dest="next_command", help="Command to run next")
    ph.add_argument("--do-not-repeat", dest="do_not_repeat", action="append",
                    help="Add a 'do not repeat' item (repeatable)")
    ph.set_defaults(func=cmd_handoff)

    pr = sub.add_parser("resume", help="Lightweight handoff consistency check")
    add_continuity_args(pr)
    pr.add_argument("--with-memory", dest="with_memory", action="store_true",
                    help="Also print a bounded persistent-memory summary (opt-in)")
    pr.set_defaults(func=cmd_resume)

    pc = sub.add_parser("continuity", help="Continuity Layer utilities")
    csub = pc.add_subparsers(dest="continuity_command", required=True)
    for name, help_text in (("history", "List handoff snapshots"),
                            ("check", "Diagnose the handoff (never a release gate)")):
        cp = csub.add_parser(name, help=help_text)
        add_continuity_args(cp)
    pc.set_defaults(func=cmd_continuity)

    # --- Persistent Work Memory (v1.4, OPTIONAL) ----------------------------
    pm = sub.add_parser("memory", help="Optional persistent work memory (Beads)")
    msub = pm.add_subparsers(dest="memory_command", required=True)

    ms = msub.add_parser("status", help="Show backend availability, version and health")
    add_continuity_args(ms)

    msetup = msub.add_parser("setup", help="Initialise a memory backend (stealth)")
    msetup.add_argument("target", nargs="?", default="beads", help="Backend to set up (beads)")
    add_continuity_args(msetup)

    mprime = msub.add_parser("prime", help="Print Beads workflow context + memories")
    mprime.add_argument("--memories-only", dest="memories_only", action="store_true",
                        help="Print only the persistent-memories section")
    add_continuity_args(mprime)

    mrem = msub.add_parser("remember", help="Store a durable project fact (secret-redacted)")
    mrem.add_argument("content", nargs="?", help="Memory content (or KEY when VALUE is given)")
    mrem.add_argument("extra", nargs="?", help="Memory content when KEY is the first positional")
    mrem.add_argument("--key", help="Explicit memory key")
    mrem.add_argument("--value", help="Explicit memory content")
    add_continuity_args(mrem)

    mready = msub.add_parser("ready", help="Show ready work straight from `bd ready`")
    mready.add_argument("--limit", type=int, default=None, help="Max ready items to show")
    add_continuity_args(mready)

    mdis = msub.add_parser("disable", help="Switch persistent memory off (data preserved)")
    add_continuity_args(mdis)

    pm.set_defaults(func=cmd_memory)

    pbd = sub.add_parser("bd", help="Run the Beads CLI with AEGL's environment applied")
    pbd.add_argument("--root", default=str(ROOT),
                     help="Project root whose .aegl/beads is used (default: AEGL root)")
    pbd.add_argument("bd_args", nargs=argparse.REMAINDER,
                     help="Arguments passed through to bd (e.g. `aegl bd ready --json`)")
    pbd.set_defaults(func=cmd_bd)

    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
