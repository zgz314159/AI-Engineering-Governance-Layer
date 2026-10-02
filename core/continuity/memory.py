"""Reserved pluggable persistent-memory backend (build plan §18).

v1.3 ships only the ``none`` backend: the Continuity Layer keeps working with
the local snapshot alone. A real ``beads`` backend is deliberately deferred to
v1.4 so this release's scope does not grow.
"""
from __future__ import annotations

from pathlib import Path


class PersistentMemoryBackend:
    """Interface a future backend (e.g. Beads) must implement."""

    name = "none"

    def available(self) -> bool:
        return False

    def store(self, root: Path, snapshot: dict) -> None:
        """Persist a handoff snapshot. The default backend is a no-op."""

    def query(self, root: Path) -> list[dict]:
        """Return previously persisted snapshots. The default returns none."""
        return []


class NoneBackend(PersistentMemoryBackend):
    name = "none"


def load_backend(config: dict | None) -> PersistentMemoryBackend:
    requested = (config or {}).get("memoryBackend", "none")
    # Only "none" exists in v1.3; unknown requests fall back to none rather than
    # failing, and "beads" is documented as the v1.4 target.
    return NoneBackend()
