"""AEGL runtime path contract (XDG).

Continuity state and Beads data are generated runtime artifacts, so they resolve
OUTSIDE any project checkout, following the XDG Base Directory spec. AEGL never
writes runtime state into a canonical project tree:

    AEGL_STATE_HOME   (if set) IS the AEGL state root, else ${XDG_STATE_HOME:-$HOME/.local/state}/aegl
    AEGL_DATA_HOME    (if set) IS the AEGL data root,  else ${XDG_DATA_HOME:-$HOME/.local/share}/aegl
    AEGL_CACHE_HOME   (if set) IS the AEGL cache root, else ${XDG_CACHE_HOME:-$HOME/.cache}/aegl

The ``AEGL_*`` variables are the FULL root (they are not suffixed with ``aegl``
again), so there is no duplicated ``aegl/aegl`` segment, and an isolated XDG root
(a test workspace) fully drives the paths even when an ``AEGL_*`` variable is
present in the environment.

Per-project state is keyed by a stable slug of the absolute project root so two
checkouts never share continuity/beads state. Explicit directory overrides
(``AEGL_CONTINUITY_DIR`` / ``AEGL_BEADS_DIR``) take precedence; the smoke tests
pin them so their assertions stay on isolated roots.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path


def _root(env: str, xdg: str, fallback: str) -> Path:
    """The AEGL state/data/cache root. ``AEGL_<X>_HOME`` IS the root when set."""
    override = os.environ.get(env)
    if override:
        return Path(os.path.expanduser(os.path.expandvars(override)))
    base = os.environ.get(xdg) or fallback
    return Path(os.path.expanduser(os.path.expandvars(base))) / "aegl"


def state_home() -> Path:
    return _root("AEGL_STATE_HOME", "XDG_STATE_HOME", "~/.local/state")


def data_home() -> Path:
    return _root("AEGL_DATA_HOME", "XDG_DATA_HOME", "~/.local/share")


def cache_home() -> Path:
    return _root("AEGL_CACHE_HOME", "XDG_CACHE_HOME", "~/.cache")


def project_key(root) -> str:
    resolved = str(Path(root).resolve())
    digest = hashlib.sha256(resolved.encode("utf-8")).hexdigest()[:12]
    return f"{Path(resolved).name}-{digest}"


def project_state(root) -> Path:
    return state_home() / "projects" / project_key(root)


def project_data(root) -> Path:
    return data_home() / "projects" / project_key(root)


def project_cache(root) -> Path:
    return cache_home() / "projects" / project_key(root)


def continuity_dir(root) -> Path:
    override = os.environ.get("AEGL_CONTINUITY_DIR")
    if override:
        return Path(os.path.expanduser(override))
    return project_state(root) / "continuity"


def beads_dir(root) -> Path:
    override = os.environ.get("AEGL_BEADS_DIR")
    if override:
        return Path(os.path.expanduser(override))
    return project_state(root) / "beads"


def reports_dir(root) -> Path:
    override = os.environ.get("AEGL_REPORTS_DIR")
    if override:
        return Path(os.path.expanduser(override))
    return project_data(root) / "reports"


if __name__ == "__main__":  # pragma: no cover - manual inspection helper
    import sys

    root = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    table = {
        "state": state_home, "data": data_home, "cache": cache_home,
        "continuity": lambda: continuity_dir(root), "beads": lambda: beads_dir(root),
        "reports": lambda: reports_dir(root),
    }
    name = sys.argv[1] if len(sys.argv) > 1 else "state"
    print(table[name]())
