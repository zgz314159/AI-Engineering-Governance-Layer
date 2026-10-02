"""Render state.json into the human/agent-readable projections.

HANDOFF.md is the "warm" context; NEXT-SESSION.md is the very short "hot"
context (build plan §7/§8/§19). Markdown is a projection only — never the
canonical store.
"""
from __future__ import annotations


def _clean(value: str, default: str = "(not set)") -> str:
    return value if isinstance(value, str) and value.strip() else default


def _bullets(items, empty: str = "- (none)") -> str:
    if not isinstance(items, list):
        return empty
    items = [str(i).strip() for i in items if str(i).strip()]
    if not items:
        return empty
    return "\n".join(f"- {item}" for item in items)


def _working_tree(dirty) -> str:
    return "dirty" if dirty else "clean"


def render_handoff(snapshot: dict) -> str:
    project = snapshot.get("project", {})
    repo = snapshot.get("repository", {})
    ci = snapshot.get("ci", {})
    phase = snapshot.get("phase", {})
    work = snapshot.get("work", {})
    nxt = snapshot.get("next", {})

    lines = [
        "# AEGL Session Handoff",
        "",
        f"Generated: {_clean(snapshot.get('generatedAt'), '')}",
        "",
        "## Verified State",
        "",
        f"Version:\n{_clean(project.get('version'))}",
        "",
        f"Branch:\n{_clean(repo.get('branch'))}",
        "",
        f"HEAD:\n{_clean(repo.get('head'))}",
        "",
        f"Working Tree:\n{_working_tree(repo.get('dirty'))}",
        "",
        f"CI:\n{_clean(ci.get('status'))}",
        "",
        f"Phase:\n{_clean(phase.get('name'))} ({_clean(phase.get('status'), 'unknown')})",
        "",
        "## Current Goal",
        "",
        _clean(work.get("goal")),
        "",
        "## Current Work",
        "",
        _clean(work.get("currentTask")),
        "",
        "## Completed",
        "",
        _bullets(work.get("completed")),
        "",
        "## In Progress",
        "",
        _bullets(work.get("inProgress")),
        "",
        "## Blocked",
        "",
        _bullets(work.get("blocked")),
        "",
        "## Decisions",
        "",
        _bullets(work.get("importantDecisions")),
        "",
        "## Failed / Rejected Approaches",
        "",
        _bullets(work.get("failedApproaches")),
        "",
        "## Do Not Repeat",
        "",
        _bullets(work.get("doNotRepeat")),
        "",
        "## Known Risks",
        "",
        _bullets(work.get("knownRisks")),
        "",
        "## Next Action",
        "",
        _clean(nxt.get("action")),
        "",
    ]
    command = nxt.get("command")
    if isinstance(command, str) and command.strip():
        lines.extend(["```", command.strip(), "```", ""])
    lines.extend([
        "## Open Questions",
        "",
        _bullets(work.get("openQuestions")),
        "",
        "> HANDOFF.md is a projection of `.aegl/continuity/state.json` (canonical).",
        "",
    ])
    return "\n".join(lines)


def render_next_session(snapshot: dict) -> str:
    project = snapshot.get("project", {})
    repo = snapshot.get("repository", {})
    work = snapshot.get("work", {})
    nxt = snapshot.get("next", {})

    lines = [
        "# Next Session",
        "",
        "Project:",
        f"{_clean(project.get('name'))} ({_clean(project.get('version'))})",
        "",
        "Branch:",
        _clean(repo.get("branch")),
        "",
        "Goal:",
        _clean(work.get("goal")),
        "",
        "Already done:",
        _bullets(work.get("completed"), "- (none recorded)"),
        "",
        "Do not redo:",
        _bullets(work.get("doNotRepeat"), "- (none recorded)"),
        "",
        "Next:",
        _clean(nxt.get("action")),
        "",
        "Start with:",
        "```",
        "aegl resume",
        "```",
        "",
        "Read only if needed:",
        "- .aegl/continuity/HANDOFF.md",
        "- .aegl/continuity/state.json",
        "",
    ]
    return "\n".join(lines)
