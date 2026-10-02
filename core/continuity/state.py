"""Continuity state schema, atomic persistence and configuration.

``state.json`` is the Continuity Layer's canonical machine-readable truth.
Everything else (HANDOFF.md / NEXT-SESSION.md) is a projection of it.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from . import secrets

SCHEMA_VERSION = 1
CONTINUITY_REL = Path(".aegl") / "continuity"

DEFAULT_CONFIG: dict = {
    "historyLimit": 20,
    "commitCurrentState": True,
    "commitHistory": False,
    "includeCi": True,
    "redactSecrets": True,
    "memoryBackend": "none",
}

_WORK_LIST_FIELDS = (
    "completed",
    "inProgress",
    "blocked",
    "failedApproaches",
    "importantDecisions",
    "doNotRepeat",
    "knownRisks",
    "openQuestions",
)
_WORK_STR_FIELDS = ("goal", "currentTask")

_HEX_RE = re.compile(r"^[0-9a-fA-F]{4,40}$")


# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #

def continuity_dir(root: Path) -> Path:
    return root / CONTINUITY_REL


def state_path(root: Path) -> Path:
    return continuity_dir(root) / "state.json"


def handoff_path(root: Path) -> Path:
    return continuity_dir(root) / "HANDOFF.md"


def next_session_path(root: Path) -> Path:
    return continuity_dir(root) / "NEXT-SESSION.md"


def events_path(root: Path) -> Path:
    return continuity_dir(root) / "events.jsonl"


def config_path(root: Path) -> Path:
    return continuity_dir(root) / "config.json"


def work_path(root: Path) -> Path:
    return continuity_dir(root) / "work.json"


def history_dir(root: Path) -> Path:
    return continuity_dir(root) / "history"


# --------------------------------------------------------------------------- #
# Time helpers
# --------------------------------------------------------------------------- #

def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime | None = None) -> str:
    dt = dt or utcnow()
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(text: str) -> datetime | None:
    if not isinstance(text, str) or not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


# --------------------------------------------------------------------------- #
# Atomic IO
# --------------------------------------------------------------------------- #

def write_atomic(path: Path, text: str) -> None:
    """Write ``text`` atomically: temp file -> fsync -> rename (build plan §26)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / (path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def write_json(path: Path, obj) -> None:
    write_atomic(path, json.dumps(obj, indent=2, ensure_ascii=False) + "\n")


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #

def load_config(root: Path) -> dict:
    cfg = dict(DEFAULT_CONFIG)
    loaded = read_json(config_path(root), {})
    if isinstance(loaded, dict):
        cfg.update(loaded)
    return cfg


def save_config(root: Path, cfg: dict) -> None:
    write_json(config_path(root), cfg)


def ensure_config(root: Path) -> dict:
    if not config_path(root).exists():
        save_config(root, DEFAULT_CONFIG)
    return load_config(root)


def read_work(root: Path) -> dict:
    work = read_json(work_path(root), {})
    return work if isinstance(work, dict) else {}


# --------------------------------------------------------------------------- #
# State
# --------------------------------------------------------------------------- #

def read_state(root: Path) -> dict | None:
    state = read_json(state_path(root), None)
    return state if isinstance(state, dict) else None


def write_state(root: Path, state: dict) -> None:
    write_json(state_path(root), state)


def validate_state(state) -> list[str]:
    """Return a list of schema violations (empty list == valid).

    This is a structural check only: it never judges whether the *semantics* of
    the handoff are good enough (build plan §21).
    """
    errs: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            errs.append(msg)

    check(isinstance(state, dict), "state is not a JSON object")
    if not isinstance(state, dict):
        return errs

    check(state.get("schemaVersion") == SCHEMA_VERSION,
          f"schemaVersion must be {SCHEMA_VERSION}")
    check(parse_iso(state.get("generatedAt", "")) is not None,
          "generatedAt must be an ISO-8601 timestamp")

    project = state.get("project")
    check(isinstance(project, dict), "project must be an object")
    if isinstance(project, dict):
        check(isinstance(project.get("name"), str) and project.get("name"),
              "project.name must be a non-empty string")
        check(isinstance(project.get("version"), str), "project.version must be a string")

    repo = state.get("repository")
    check(isinstance(repo, dict), "repository must be an object")
    if isinstance(repo, dict):
        check(isinstance(repo.get("branch"), str), "repository.branch must be a string")
        check(isinstance(repo.get("head"), str), "repository.head must be a string")
        head = repo.get("head", "")
        check(head == "" or bool(_HEX_RE.match(head)), "repository.head must be a git SHA")
        check(isinstance(repo.get("dirty"), bool), "repository.dirty must be a boolean")

    ci = state.get("ci")
    check(isinstance(ci, dict), "ci must be an object")
    if isinstance(ci, dict):
        check(isinstance(ci.get("status"), str), "ci.status must be a string")
        check(parse_iso(ci.get("checkedAt", "")) is not None,
              "ci.checkedAt must be an ISO-8601 timestamp")

    phase = state.get("phase")
    check(isinstance(phase, dict), "phase must be an object")
    if isinstance(phase, dict):
        check(isinstance(phase.get("name"), str), "phase.name must be a string")
        check(isinstance(phase.get("status"), str), "phase.status must be a string")

    work = state.get("work")
    check(isinstance(work, dict), "work must be an object")
    if isinstance(work, dict):
        for field in _WORK_STR_FIELDS:
            check(isinstance(work.get(field, ""), str), f"work.{field} must be a string")
        for field in _WORK_LIST_FIELDS:
            val = work.get(field, [])
            check(isinstance(val, list) and all(isinstance(x, str) for x in val),
                  f"work.{field} must be a list of strings")

    nxt = state.get("next")
    check(isinstance(nxt, dict), "next must be an object")
    if isinstance(nxt, dict):
        check(isinstance(nxt.get("action", ""), str), "next.action must be a string")

    return errs


def normalize_state(state: dict) -> dict:
    """Apply secret + path redaction across the state (build plan §35/§36)."""
    return secrets.clean_obj(state)
