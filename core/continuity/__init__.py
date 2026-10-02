"""AEGL Continuity Layer (v1.3).

Turns "current engineering state" + "session handoff semantics" into a
portable, resumable checkpoint stored in ``<root>/.aegl/continuity/``.

Deliberately small (see the v1.3 build plan):

* ``state.json`` is the machine-readable truth, collected from Git / VERSION / CI.
* ``HANDOFF.md`` and ``NEXT-SESSION.md`` are human/agent-readable projections.
* ``resume`` is a *lightweight* consistency check — never a hard gate.
* ``events.jsonl`` records phase-level changes only, not every shell command.

v1.4 adds an OPTIONAL persistent-memory backend (``backends/beads.py``) that
drives the ``bd`` CLI. It is never required: Continuity keeps working when it is
absent or incompatible.

This package never runs a full build, bootstrap or repository AI analysis.
"""
from __future__ import annotations

__all__ = [
    "backends",
    "collector",
    "commands",
    "events",
    "history",
    "memory",
    "memory_commands",
    "renderer",
    "resume",
    "secrets",
    "state",
]
