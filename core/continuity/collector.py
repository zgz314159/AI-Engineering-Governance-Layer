"""Deterministic fact collection for the Continuity Layer.

Collected by the program, never typed by an AI (build plan §5.1):
Git branch / HEAD / dirty, VERSION, tags, latest commit, remote, CI status.

Deliberately cheap: ``git status`` and at most one ``gh run list`` call. It
never runs a build, bootstrap or repository analysis (build plan §12/§32).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

from . import state

CI_TIMEOUT = 6
GIT_TIMEOUT = 5


def _run(args: list[str], cwd: Path, timeout: int = GIT_TIMEOUT) -> str | None:
    try:
        proc = subprocess.run(
            args, cwd=str(cwd), text=True, capture_output=True, timeout=timeout
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def _git(root: Path, *args: str) -> str | None:
    return _run(["git", *args], root)


def is_git_repo(root: Path) -> bool:
    return _git(root, "rev-parse", "--is-inside-work-tree") == "true"


def read_version(root: Path) -> str:
    try:
        return (root / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        return "0.0.0"


def collect_repository(root: Path) -> dict:
    """Collect the repository facts used by state.json and by ``resume``."""
    if not is_git_repo(root):
        return {
            "git": False,
            "branch": "unknown",
            "head": "",
            "dirty": False,
            "remote": None,
            "latestCommit": None,
            "latestTag": None,
            "tags": [],
        }

    branch = _git(root, "rev-parse", "--abbrev-ref", "HEAD") or "HEAD"
    head = _git(root, "rev-parse", "--short", "HEAD") or ""
    porcelain = _git(root, "status", "--porcelain")
    dirty = bool(porcelain)
    remote = "origin" if _git(root, "remote", "get-url", "origin") else None
    latest_commit = _git(root, "log", "-1", "--pretty=%h %s") or None
    tags_raw = _git(root, "tag", "--list", "--sort=-version:refname") or ""
    tags = [t for t in (line.strip() for line in tags_raw.splitlines()) if t]
    return {
        "git": True,
        "branch": branch,
        "head": head,
        "dirty": dirty,
        "remote": remote,
        "latestCommit": latest_commit,
        "latestTag": tags[0] if tags else None,
        "tags": tags,
    }


def collect_ci(root: Path, branch: str, enabled: bool = True) -> dict:
    """Best-effort CI status. Degrades to a recorded status, never blocks."""
    checked_at = state.iso()
    base = {"status": "unknown", "runId": None, "checkedAt": checked_at}

    if not enabled or os.environ.get("AEGL_CONTINUITY_SKIP_CI") == "1":
        return {**base, "status": "skipped"}
    if not shutil.which("gh"):
        return {**base, "status": "unavailable"}

    raw = _run(
        [
            "gh", "run", "list",
            "--branch", branch or "main",
            "--limit", "1",
            "--json", "databaseId,status,conclusion,headSha,url",
        ],
        root,
        timeout=CI_TIMEOUT,
    )
    if raw is None:
        return {**base, "status": "unavailable"}

    try:
        runs = json.loads(raw)
    except ValueError:
        return base
    if not isinstance(runs, list) or not runs:
        return {**base, "status": "none"}

    run = runs[0]
    if run.get("status") != "completed":
        status = "pending"
    else:
        status = run.get("conclusion") or "unknown"
    return {
        "status": status,
        "runId": str(run["databaseId"]) if run.get("databaseId") is not None else None,
        "headSha": run.get("headSha"),
        "url": run.get("url"),
        "checkedAt": state.iso(),
    }


def collect(root: Path, include_ci: bool = True) -> dict:
    """Collect the deterministic part of a state snapshot."""
    repo = collect_repository(root)
    ci = collect_ci(root, repo.get("branch", ""), enabled=include_ci)
    return {
        "project": {"name": root.resolve().name, "version": read_version(root)},
        "repository": repo,
        "ci": ci,
    }
