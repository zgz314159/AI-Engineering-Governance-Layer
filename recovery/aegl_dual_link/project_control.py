#!/usr/bin/env python3
"""Per-project ChatGPT control-conversation binding for AEGL dual-link.

Resolution order (first hit wins):
  1. explicit URL argument / HERMES_CHATGPT_CONTROL_URL (must be valid)
  2. map by AEGL project id (by_aegl_project)
  3. map by longest matching cwd prefix under projects
  4. if require_binding: raise; else default pinned URL

Different coding projects must not share one ChatGPT advisor thread.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

# No shared default ChatGPT URL — calendar and system projects must bind explicitly.
DEFAULT_CONTROL_URL = ""
CONTROL_URL_RE = re.compile(r"^https://chatgpt\.com/c/[A-Za-z0-9._-]{1,128}$")
ENV_URL = "HERMES_CHATGPT_CONTROL_URL"
ENV_MAP = "AEGL_PROJECT_CONTROL_MAP"
DEFAULT_MAP = Path.home() / ".local/share/aegl-dual-link/project-control-map.json"


class ControlBindError(RuntimeError):
    pass


def map_path() -> Path:
    raw = os.environ.get(ENV_MAP)
    return Path(raw) if raw else DEFAULT_MAP


def load_map(path: Path | None = None) -> dict:
    p = path or map_path()
    if not p.is_file():
        return {"version": 1, "require_binding": True, "projects": {}, "by_aegl_project": {}}
    data = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ControlBindError("project-control-map root must be object")
    data.setdefault("projects", {})
    data.setdefault("by_aegl_project", {})
    data.setdefault("require_binding", True)
    return data


def validate_url(url: str) -> str:
    if not isinstance(url, str) or not CONTROL_URL_RE.match(url):
        raise ControlBindError(
            "control_url must match https://chatgpt.com/c/<conversation-id>; got %r" % (url,)
        )
    return url


def _normalize_cwd(cwd: str | None) -> str | None:
    if not cwd:
        return None
    return str(Path(cwd).expanduser().resolve())


def resolve_control_url(
    *,
    explicit: str | None = None,
    aegl_project: str | None = None,
    cwd: str | None = None,
    allow_env: bool = True,
) -> str:
    """Return the ChatGPT conversation URL for this project context."""
    if explicit not in (None, ""):
        return validate_url(explicit)
    if allow_env:
        env = os.environ.get(ENV_URL)
        if env not in (None, ""):
            return validate_url(env)

    data = load_map()
    if aegl_project:
        by = data.get("by_aegl_project") or {}
        if aegl_project in by:
            return validate_url(by[aegl_project])

    abs_cwd = _normalize_cwd(cwd)
    if abs_cwd:
        projects = data.get("projects") or {}
        # longest prefix match
        best = None
        best_len = -1
        for key, meta in projects.items():
            try:
                root = str(Path(key).expanduser().resolve())
            except OSError:
                continue
            if abs_cwd == root or abs_cwd.startswith(root + os.sep):
                if len(root) > best_len:
                    url = meta.get("control_url") if isinstance(meta, dict) else meta
                    if url:
                        best = url
                        best_len = len(root)
        if best:
            return validate_url(best)
        # also match aegl_project embedded in meta when cwd matches
        for key, meta in projects.items():
            if not isinstance(meta, dict):
                continue
            if meta.get("aegl_project") and aegl_project and meta["aegl_project"] == aegl_project:
                return validate_url(meta["control_url"])

    if data.get("require_binding", True) or not DEFAULT_CONTROL_URL:
        raise ControlBindError(
            "no ChatGPT control_url bound for aegl_project=%r cwd=%r; "
            "run: dual-link-operator.sh bind-control --cwd <dir> --url https://chatgpt.com/c/<id>"
            % (aegl_project, abs_cwd)
        )
    return validate_url(DEFAULT_CONTROL_URL)


def bind_control(*, cwd: str, url: str, aegl_project: str | None = None, note: str | None = None) -> dict:
    abs_cwd = _normalize_cwd(cwd)
    if not abs_cwd:
        raise ControlBindError("cwd required")
    url = validate_url(url)
    p = map_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    data = load_map(p)
    entry = {"control_url": url}
    if aegl_project:
        entry["aegl_project"] = aegl_project
        data.setdefault("by_aegl_project", {})[aegl_project] = url
    if note:
        entry["note"] = note
    data.setdefault("projects", {})[abs_cwd] = entry
    data["version"] = int(data.get("version") or 1)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(p)
    return {"cwd": abs_cwd, "control_url": url, "aegl_project": aegl_project, "map": str(p)}


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("resolve")
    r.add_argument("--cwd")
    r.add_argument("--aegl-project")
    r.add_argument("--url")
    b = sub.add_parser("bind")
    b.add_argument("--cwd", required=True)
    b.add_argument("--url", required=True)
    b.add_argument("--aegl-project")
    b.add_argument("--note")
    args = ap.parse_args()
    if args.cmd == "resolve":
        print(resolve_control_url(explicit=args.url, aegl_project=args.aegl_project, cwd=args.cwd))
    else:
        print(json.dumps(bind_control(cwd=args.cwd, url=args.url, aegl_project=args.aegl_project, note=args.note),
                         ensure_ascii=False))
