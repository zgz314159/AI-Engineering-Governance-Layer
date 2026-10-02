"""Immutable handoff snapshots under ``.aegl/continuity/history/``.

One ``<id>.json`` + ``<id>.md`` per handoff. The first version only saves and
lists snapshots — no time travel (build plan §17).
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from . import state


def snapshot_id(dt: datetime | None = None) -> str:
    dt = dt or datetime.now(timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def save_snapshot(root: Path, snapshot: dict, handoff_md: str,
                  snap_id: str | None = None) -> dict:
    snap_id = snap_id or snapshot_id()
    directory = state.history_dir(root)
    json_path = directory / f"{snap_id}.json"
    md_path = directory / f"{snap_id}.md"
    state.write_json(json_path, snapshot)
    state.write_atomic(md_path, handoff_md)
    return {"id": snap_id, "json": str(json_path), "md": str(md_path)}


def list_snapshots(root: Path) -> list[dict]:
    directory = state.history_dir(root)
    if not directory.is_dir():
        return []
    out: list[dict] = []
    for json_path in sorted(directory.glob("*.json"), reverse=True):
        snap = state.read_json(json_path, {}) or {}
        repo = snap.get("repository", {}) if isinstance(snap, dict) else {}
        out.append({
            "id": json_path.stem,
            "json": str(json_path),
            "md": str(json_path.with_suffix(".md")),
            "generatedAt": snap.get("generatedAt") if isinstance(snap, dict) else None,
            "branch": repo.get("branch"),
            "head": repo.get("head"),
            "version": (snap.get("project", {}) or {}).get("version") if isinstance(snap, dict) else None,
        })
    return out


def prune(root: Path, limit: int) -> list[str]:
    """Delete the oldest snapshots beyond ``limit`` (build plan §38)."""
    if limit is None or limit < 0:
        return []
    removed: list[str] = []
    for snap in list_snapshots(root)[limit:]:
        for key in ("json", "md"):
            path = Path(snap[key])
            if path.exists():
                path.unlink()
        removed.append(snap["id"])
    return removed
