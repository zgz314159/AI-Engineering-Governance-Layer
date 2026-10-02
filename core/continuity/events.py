"""Append-only Continuity event log.

Records *meaningful* phase changes only — never every shell command, and no
event-sourcing platform (build plan §9). Values are redacted before writing.
"""
from __future__ import annotations

import json
from pathlib import Path

from . import secrets, state

EVENT_TYPES = (
    "phase_started",
    "phase_completed",
    "task_started",
    "task_completed",
    "decision",
    "blocked",
    "unblocked",
    "handoff_created",
    "resume_started",
    "resume_completed",
)


def append_event(root: Path, event_type: str, **fields) -> dict:
    record = {"ts": state.iso(), "type": event_type}
    for key, value in fields.items():
        if value is not None:
            record[key] = value
    record = secrets.clean_obj(record)

    path = state.events_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    return record


def read_events(root: Path, limit: int | None = None) -> list[dict]:
    path = state.events_path(root)
    if not path.exists():
        return []
    out: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    if limit is not None:
        return out[-limit:]
    return out
