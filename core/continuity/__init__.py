"""AEGL Continuity Layer (v1.3).

Turns "current engineering state" + "session handoff semantics" into a
portable, resumable checkpoint stored in ``<root>/.aegl/continuity/``.

Deliberately small (see the v1.3 build plan):

* ``state.json`` is the machine-readable truth, collected from Git / VERSION / CI.
* ``HANDOFF.md`` and ``NEXT-SESSION.md`` are human/agent-readable projections.
* ``resume`` is a *lightweight* consistency check — never a hard gate.
* ``events.jsonl`` records phase-level changes only, not every shell command.

This package never runs a full build, bootstrap or repository AI analysis.
"""
from __future__ import annotations

__all__ = [
    "collector",
    "commands",
    "events",
    "history",
    "memory",
    "renderer",
    "resume",
    "secrets",
    "state",
]
