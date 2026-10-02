"""Lightweight handoff consistency check + resume brief rendering.

Only branch / HEAD / working tree / version are compared (build plan §15).
CI is displayed but never a hard gate. A STALE handoff is a warning that must
not stop the new agent from working (build plan §29).
"""
from __future__ import annotations

from datetime import datetime, timezone

from . import state


def _repo(current: dict) -> dict:
    return current.get("repository", {})


def compare(snapshot: dict, current: dict) -> dict:
    recorded_repo = snapshot.get("repository", {})
    current_repo = _repo(current)

    recorded_head = recorded_repo.get("head") or ""
    current_head = current_repo.get("head") or ""

    branch_match = recorded_repo.get("branch") == current_repo.get("branch")
    head_match = recorded_head == current_head
    version_match = (snapshot.get("project", {}) or {}).get("version") == \
        (current.get("project", {}) or {}).get("version")

    recorded_dirty = bool(recorded_repo.get("dirty"))
    current_dirty = bool(current_repo.get("dirty"))
    dirty_warning = (not recorded_dirty) and current_dirty

    reasons: list[str] = []
    if not branch_match:
        reasons.append("branch changed")
    if not head_match:
        reasons.append("HEAD changed")
    if not version_match:
        reasons.append("version changed")

    result = {
        "status": "VALID" if not reasons else "STALE",
        "branch": {"recorded": recorded_repo.get("branch"), "current": current_repo.get("branch"),
                   "match": branch_match},
        "head": {"recorded": recorded_head, "current": current_head, "match": head_match},
        "version": {"recorded": (snapshot.get("project", {}) or {}).get("version"),
                    "current": (current.get("project", {}) or {}).get("version"),
                    "match": version_match},
        "workingTree": {"recorded": "dirty" if recorded_dirty else "clean",
                        "current": "dirty" if current_dirty else "clean",
                        "warning": dirty_warning},
        "reasons": reasons,
    }

    generated_at = state.parse_iso(snapshot.get("generatedAt", ""))
    if generated_at is not None:
        age = int((datetime.now(timezone.utc) - generated_at).total_seconds())
        result["handoffAgeSeconds"] = max(age, 0)
    else:
        result["handoffAgeSeconds"] = None
    return result


def _line(label: str, recorded, current, match: bool) -> str:
    status = "PASS" if match else "FAIL"
    return (
        f"Recorded {label}: {recorded}\n"
        f"Current  {label}: {current}\n"
        f"{status}"
    )


def render_resume(snapshot: dict, comparison: dict, current: dict) -> str:
    work = snapshot.get("work", {}) or {}
    nxt = snapshot.get("next", {}) or {}
    ci = snapshot.get("ci", {}) or {}

    lines = ["AEGL Resume", "-----------"]
    lines.append(_line("branch", comparison["branch"]["recorded"],
                       comparison["branch"]["current"], comparison["branch"]["match"]))
    lines.append("")
    lines.append(_line("HEAD", comparison["head"]["recorded"],
                       comparison["head"]["current"], comparison["head"]["match"]))
    lines.append("")
    lines.append(_line("version", comparison["version"]["recorded"],
                       comparison["version"]["current"], comparison["version"]["match"]))
    lines.append("")
    lines.append(
        f"Working tree: {comparison['workingTree']['current']}\n"
        f"{'WARNING' if comparison['workingTree']['warning'] else 'PASS'}"
    )
    lines.append("")

    age = comparison.get("handoffAgeSeconds")
    if age is not None:
        minutes = age // 60
        lines.append(f"Handoff age: {minutes} minute(s)")
        lines.append("")

    lines.append(f"HANDOFF STATUS: {comparison['status']}")
    if comparison["status"] == "STALE":
        lines.append("Repository changed since handoff.")
        for reason in comparison["reasons"]:
            if reason == "HEAD changed":
                lines.append(f"Recorded HEAD: {comparison['head']['recorded']}")
                lines.append(f"Current  HEAD: {comparison['head']['current']}")
            elif reason == "branch changed":
                lines.append(f"Recorded branch: {comparison['branch']['recorded']}")
                lines.append(f"Current  branch: {comparison['branch']['current']}")
            elif reason == "version changed":
                lines.append(f"Recorded version: {comparison['version']['recorded']}")
                lines.append(f"Current  version: {comparison['version']['current']}")
        lines.append("Recommendation: inspect the new commits before continuing.")
        lines.append("NOTE: STALE is a warning, not a block. You may continue.")
    else:
        lines.append("Repository matches the recorded handoff.")
    lines.append("")

    if comparison["workingTree"]["warning"]:
        lines.append("WARNING: working tree is dirty but the handoff recorded it clean.")
        lines.append("Uncommitted work exists; review it before continuing.")
        lines.append("")

    if isinstance(ci.get("status"), str):
        lines.append(f"CI (recorded): {ci.get('status')} (informational, not a gate)")
        lines.append("")

    do_not_repeat = [str(x) for x in (work.get("doNotRepeat") or []) if str(x).strip()]
    if do_not_repeat:
        lines.append("DO NOT REPEAT:")
        for item in do_not_repeat:
            lines.append(f"- {item}")
        lines.append("")

    blocked = [str(x) for x in (work.get("blocked") or []) if str(x).strip()]
    if blocked:
        lines.append("BLOCKED:")
        for item in blocked:
            lines.append(f"- {item}")
        lines.append("")

    lines.append(f"Goal: {work.get('goal') or '(not set)'}")
    lines.append(f"Next: {nxt.get('action') or '(not set)'}")
    command = nxt.get("command")
    if isinstance(command, str) and command.strip():
        lines.append(f"Next command: {command.strip()}")
    lines.append("")
    lines.append("Read .aegl/continuity/NEXT-SESSION.md for the short hot context.")
    return "\n".join(lines)
