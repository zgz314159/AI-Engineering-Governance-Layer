#!/usr/bin/env python3
"""Per-project ChatGPT control-conversation binding for AEGL dual-link.

Resolution order (first hit wins):
  1. explicit URL argument
  2. HERMES_CHATGPT_CONTROL_URL (must be valid) when allow_env
  3. longest matching cwd prefix under projects  (most specific — different
     worktrees/projects must not collapse onto one AEGL id)
  4. map by AEGL project id (by_aegl_project)
  5. if require_binding: raise (no shared default conversation)

Different coding projects must not share one ChatGPT advisor thread.
bind_control refuses to reuse another project's control_url.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

# No shared default ChatGPT URL — every project must bind explicitly.
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


def _cwd_match_url(data: dict, abs_cwd: str) -> str | None:
    projects = data.get("projects") or {}
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
    return best


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
    abs_cwd = _normalize_cwd(cwd)
    # cwd prefix before by_aegl_project so OfflineTaskCalendar worktrees can still
    # use a distinct advisor chat when their task_root is bound separately.
    if abs_cwd:
        hit = _cwd_match_url(data, abs_cwd)
        if hit:
            return validate_url(hit)

    if aegl_project:
        by = data.get("by_aegl_project") or {}
        if aegl_project in by:
            return validate_url(by[aegl_project])
        # fall through: match aegl_project embedded in projects meta
        for _key, meta in (data.get("projects") or {}).items():
            if isinstance(meta, dict) and meta.get("aegl_project") == aegl_project and meta.get("control_url"):
                return validate_url(meta["control_url"])

    if data.get("require_binding", True) or not DEFAULT_CONTROL_URL:
        raise ControlBindError(
            "no ChatGPT control_url bound for aegl_project=%r cwd=%r; "
            "run: dual-link-operator.sh bind-control --cwd <dir> --url https://chatgpt.com/c/<id>"
            % (aegl_project, abs_cwd)
        )
    return validate_url(DEFAULT_CONTROL_URL)


def _url_owner(data: dict, url: str) -> tuple[str | None, str | None]:
    """Return (cwd_key, aegl_project) already owning this url, if any."""
    for key, meta in (data.get("projects") or {}).items():
        u = meta.get("control_url") if isinstance(meta, dict) else meta
        if u == url:
            proj = meta.get("aegl_project") if isinstance(meta, dict) else None
            return key, proj
    for proj, u in (data.get("by_aegl_project") or {}).items():
        if u == url:
            return None, proj
    return None, None


def bind_control(*, cwd: str, url: str, aegl_project: str | None = None, note: str | None = None) -> dict:
    abs_cwd = _normalize_cwd(cwd)
    if not abs_cwd:
        raise ControlBindError("cwd required")
    url = validate_url(url)
    p = map_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    data = load_map(p)

    owner_cwd, owner_proj = _url_owner(data, url)
    # Same AEGL project may bind multiple coding roots (e.g. RILI umbrella + formal
    # OfflineTaskCalendar_WPF) to one advisor chat. Different AEGL projects may not share.
    if owner_cwd and Path(owner_cwd).resolve() != Path(abs_cwd):
        if not (aegl_project and owner_proj and aegl_project == owner_proj):
            raise ControlBindError(
                "control_url already bound to cwd %r — different projects must use different ChatGPT conversations"
                % (owner_cwd,)
            )
    if owner_proj and aegl_project and owner_proj != aegl_project:
        raise ControlBindError(
            "control_url already bound to aegl_project %r — refuse sharing across %r"
            % (owner_proj, aegl_project)
        )
    # Also refuse assigning a new url that equals another project's when rebinding same cwd is OK
    existing = (data.get("projects") or {}).get(abs_cwd)
    if isinstance(existing, dict) and existing.get("control_url") == url:
        pass  # idempotent rebind

    entry = {"control_url": url}
    if aegl_project:
        # Ensure this aegl_project is not pointed at a different url already used by another project id
        by = data.setdefault("by_aegl_project", {})
        for other, other_url in list(by.items()):
            if other != aegl_project and other_url == url:
                raise ControlBindError(
                    "control_url already used by aegl_project %r — each project needs its own ChatGPT chat"
                    % (other,)
                )
        entry["aegl_project"] = aegl_project
        by[aegl_project] = url
    if note:
        entry["note"] = note
    data.setdefault("projects", {})[abs_cwd] = entry
    data["version"] = int(data.get("version") or 1)
    data["require_binding"] = True
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
    r.add_argument(
        "--no-env",
        action="store_true",
        help="Ignore HERMES_CHATGPT_CONTROL_URL (use map cwd/aegl only)",
    )
    b = sub.add_parser("bind")
    b.add_argument("--cwd", required=True)
    b.add_argument("--url", required=True)
    b.add_argument("--aegl-project")
    b.add_argument("--note")
    args = ap.parse_args()
    if args.cmd == "resolve":
        print(
            resolve_control_url(
                explicit=args.url,
                aegl_project=args.aegl_project,
                cwd=args.cwd,
                allow_env=not args.no_env,
            )
        )
    else:
        print(json.dumps(bind_control(cwd=args.cwd, url=args.url, aegl_project=args.aegl_project, note=args.note),
                         ensure_ascii=False))
