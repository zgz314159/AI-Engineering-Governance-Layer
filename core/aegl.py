#!/usr/bin/env python3
"""AEGL core CLI — technology-agnostic front end for the target-project adapters.

Commands:
  aegl adapters                     List adapter descriptors.
  aegl inspect <project>            Scan a project (read-only) -> project profile.
  aegl attach  <project> [--dry-run] Generate the AEGL governance overlay.
  aegl verify  <project>            Run the adapter's governance gate.
  aegl detach  <project> [--dry-run] Remove only AEGL-created integration.

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
IMPLEMENTED = ["kotlin"]  # detection priority order


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
    result = {
        "matched": True,
        "adapter": lang,
        "adapterVersion": profile["adapterVersion"],
        "project": str(project.resolve()),
        "technology": {
            "language": "kotlin",
            "buildSystem": "gradle",
            "android": profile["indicators"]["androidPlugin"],
        },
        "governance": {
            "existingDetekt": profile["indicators"]["existingDetekt"],
            "existingKonsist": profile["indicators"]["existingKonsist"],
            "existingCI": profile["indicators"]["existingCI"],
            "existingClaude": profile["indicators"]["existingClaude"],
            "existingAgents": profile["indicators"]["existingAgents"],
            "existingArchitectureTests": profile["indicators"]["existingArchitectureTests"],
        },
        "indicators": profile["indicators"],
        "packagePrefix": mod.package_prefix(project.resolve()),
        "existingLayers": mod.existing_layers(project.resolve(), mod.package_prefix(project.resolve())),
        "attached": (project / ".aegl/manifest.json").exists(),
    }
    if args.write:
        target = project.resolve() / ".aegl/project-profile.json"
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


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="aegl", description="AEGL target-project governance CLI")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("adapters", help="List adapter descriptors").set_defaults(func=cmd_adapters)

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

    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
