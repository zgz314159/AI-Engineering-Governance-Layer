"""Pluggable persistent-memory backend registry (v1.4).

v1.3 reserved this seam with only the ``none`` backend. v1.4 adds ``beads`` —
an OPTIONAL backend that drives the official ``bd`` CLI (see
``core/continuity/backends/beads.py``). The base class keeps the v1.3
``store``/``query`` handoff hook and adds the narrow v1.4 read/remember
contract. Unknown ``memoryBackend`` values fall back to ``none`` rather than
failing, preserving the v1.3 "never error on config" rule.
"""
from __future__ import annotations

from pathlib import Path

from . import state

# Contract shared by every backend. The ``none`` backend is the v1.3 baseline
# and stays the guaranteed fallback whenever Beads is absent or incompatible.
class PersistentMemoryBackend:
    """Interface a persistent-memory backend must implement."""

    name = "none"

    def __init__(self, root: Path | None = None, config: dict | None = None):
        self.root = Path(root) if root else Path.cwd()
        self.config = config or {}

    # -- v1.3 handoff hook (unchanged) ----------------------------------- #

    def available(self) -> bool:
        return False

    def store(self, root: Path, snapshot: dict) -> None:
        """Persist a handoff snapshot. The default backend is a no-op."""

    def query(self, root: Path) -> list[dict]:
        """Return previously persisted snapshots. The default returns none."""
        return []

    # -- v1.4 narrow contract (safe defaults) ---------------------------- #

    def version(self) -> str | None:
        return None

    def supported(self) -> bool:
        return False

    def initialized(self) -> bool:
        return False

    def health(self) -> dict:
        return {
            "backend": self.name,
            "binary": False,
            "available": False,
            "version": None,
            "supported": False,
            "initialized": False,
            "dataDir": None,
            "telemetry": "n/a",
            "healthy": False,
            "summary": None,
        }

    def summary(self) -> dict | None:
        return None

    def ready_summary(self, limit: int | None = None) -> dict:
        return {"count": None, "items": [], "error": "unavailable"}

    def current_work(self) -> dict | None:
        return None

    def memories(self) -> dict:
        return {}

    def prime(self, memories_only: bool = False) -> str | None:
        return None

    def remember(self, key: str, value: str) -> dict:
        return {"ok": False, "error": "unavailable"}

    def forget(self, key: str) -> dict:
        return {"ok": False, "error": "unavailable"}

    def reference_summary(self, ready_limit: int | None = None) -> dict:
        """A read-only summary for ``state.json`` — never a copy of the graph."""
        return {
            "backend": self.name,
            "available": False,
            "readyCount": None,
            "currentTask": None,
            "checkedAt": state.iso(),
        }


class NoneBackend(PersistentMemoryBackend):
    name = "none"


def load_backend(config: dict | None, root: Path | None = None) -> PersistentMemoryBackend:
    """Resolve the configured backend; unknown values fall back to ``none``."""
    requested = (config or {}).get("memoryBackend", "none")
    if requested == "beads":
        from .backends.beads import BeadsMemoryBackend

        return BeadsMemoryBackend(root=root, config=config or {})
    return NoneBackend(root=root, config=config or {})


# Alias kept for readability at call sites that want the mapping explicitly.
REGISTRY = {"none": NoneBackend}
