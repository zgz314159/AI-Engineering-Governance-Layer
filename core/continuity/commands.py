"""Continuity command orchestration (status / handoff / resume / history / check).

Kept thin: the heavy lifting lives in collector / state / renderer / resume /
history / events. Handoff is a relay tool, not a CI run — it only reads cheap
Git facts and (optionally) the latest CI run id.
"""
from __future__ import annotations

import json
from pathlib import Path

from . import collector, events, history, memory, renderer, resume, state


# --------------------------------------------------------------------------- #
# Semantic (agent-provided) work state
# --------------------------------------------------------------------------- #

def _merge_work(root: Path, args) -> dict:
    previous = (state.read_state(root) or {}).get("work", {})
    incoming = state.read_work(root)

    merged = {
        "goal": "", "currentTask": "",
        "completed": [], "inProgress": [], "blocked": [], "failedApproaches": [],
        "importantDecisions": [], "doNotRepeat": [], "knownRisks": [], "openQuestions": [],
    }
    for source in (previous, incoming):
        if not isinstance(source, dict):
            continue
        for key in merged:
            if key in source:
                merged[key] = source[key]

    if getattr(args, "goal", None):
        merged["goal"] = args.goal
    if getattr(args, "task", None):
        merged["currentTask"] = args.task
    if getattr(args, "do_not_repeat", None):
        merged["doNotRepeat"] = list(args.do_not_repeat)
    return merged


def _merge_phase(root: Path, args) -> dict:
    phase = {"name": "Continuity Layer", "status": "in_progress"}
    for source in ((state.read_state(root) or {}).get("phase"),
                   state.read_work(root).get("phase")):
        if isinstance(source, dict):
            phase.update(source)
    if getattr(args, "phase", None):
        phase["name"] = args.phase
    return phase


def _merge_next(root: Path, args) -> dict:
    nxt = {"action": "", "command": ""}
    for source in ((state.read_state(root) or {}).get("next"),
                   state.read_work(root).get("next")):
        if isinstance(source, dict):
            nxt.update(source)
    if getattr(args, "next", None):
        nxt["action"] = args.next
    if getattr(args, "next_command", None):
        nxt["command"] = args.next_command
    return nxt


def build_snapshot(root: Path, args) -> tuple[dict, dict]:
    """Collect machine facts and merge the agent-provided semantic state."""
    # Read config without writing it: any write here would dirty the working
    # tree before we collect it, corrupting the recorded dirty/clean fact.
    cfg = state.load_config(root)
    include_ci = bool(cfg.get("includeCi", True))
    facts = collector.collect(root, include_ci=include_ci)
    repo = facts["repository"]

    snapshot = {
        "schemaVersion": state.SCHEMA_VERSION,
        "generatedAt": state.iso(),
        "project": facts["project"],
        "repository": {
            "branch": repo.get("branch"),
            "head": repo.get("head"),
            "dirty": repo.get("dirty"),
            "remote": repo.get("remote"),
            "latestCommit": repo.get("latestCommit"),
            "latestTag": repo.get("latestTag"),
        },
        "ci": facts["ci"],
        "phase": _merge_phase(root, args),
        "work": _merge_work(root, args),
        "next": _merge_next(root, args),
    }
    # Persist defaults only after the facts have been collected.
    if not state.config_path(root).exists():
        state.save_config(root, state.DEFAULT_CONFIG)
    return state.normalize_state(snapshot), cfg


def _emit(obj: dict) -> None:
    print(json.dumps(obj, indent=2, ensure_ascii=False))


def _handoff_age_seconds(snapshot: dict | None) -> int | None:
    if not snapshot:
        return None
    generated = state.parse_iso(snapshot.get("generatedAt", ""))
    if generated is None:
        return None
    return max(int((state.utcnow() - generated).total_seconds()), 0)


# --------------------------------------------------------------------------- #
# status
# --------------------------------------------------------------------------- #

def do_status(root: Path, as_json: bool = False) -> int:
    snapshot = state.read_state(root)
    repo = collector.collect_repository(root)
    version = collector.read_version(root)
    phase = (snapshot or {}).get("phase", {}) or {}
    ci = (snapshot or {}).get("ci", {}) or {}

    age = _handoff_age_seconds(snapshot)
    result = {
        "version": version,
        "branch": repo.get("branch"),
        "head": repo.get("head"),
        "dirty": repo.get("dirty"),
        "ci": ci.get("status") if snapshot else None,
        "phase": phase.get("name") if snapshot else None,
        "phaseStatus": phase.get("status") if snapshot else None,
        "handoff": "present" if snapshot else "absent",
        "handoffAgeSeconds": age,
    }
    if as_json:
        _emit(result)
        return 0

    age_text = "n/a" if age is None else f"{age // 60} minute(s)"
    print("AEGL Project Status")
    print("-------------------")
    print(f"Version: {result['version']}")
    print(f"Branch: {result['branch']}")
    print(f"HEAD: {result['head']}")
    print(f"Working Tree: {'dirty' if result['dirty'] else 'clean'}")
    print(f"CI: {result['ci'] or 'unknown'}")
    print(f"Current Phase: {result['phase'] or '(no handoff)'}")
    print(f"Handoff: {result['handoff']}")
    print(f"Handoff age: {age_text}")
    return 0


# --------------------------------------------------------------------------- #
# handoff
# --------------------------------------------------------------------------- #

def do_handoff(root: Path, args) -> int:
    snapshot, cfg = build_snapshot(root, args)

    errors = state.validate_state(snapshot)
    if errors:
        # Our own snapshot must always satisfy the schema; surface it loudly
        # rather than writing a broken handoff.
        if getattr(args, "json", False):
            _emit({"ok": False, "errors": errors})
        else:
            print("AEGL Handoff")
            print("------------")
            print("State captured: FAIL")
            for err in errors:
                print(f"  - {err}")
        return 1

    state.write_state(root, snapshot)
    handoff_md = renderer.render_handoff(snapshot)
    next_md = renderer.render_next_session(snapshot)

    snap = history.save_snapshot(root, snapshot, handoff_md)
    events.append_event(root, "handoff_created", snapshot=snap["id"])

    state.write_atomic(state.handoff_path(root), handoff_md)
    state.write_atomic(state.next_session_path(root), next_md)

    memory.load_backend(cfg).store(root, snapshot)
    removed = history.prune(root, int(cfg.get("historyLimit", 20)))

    result = {
        "ok": True,
        "snapshot": snap["id"],
        "state": ".aegl/continuity/state.json",
        "handoff": ".aegl/continuity/HANDOFF.md",
        "nextSession": ".aegl/continuity/NEXT-SESSION.md",
        "events": ".aegl/continuity/events.jsonl",
        "history": {"snapshot": snap["id"], "pruned": removed},
        "ci": snapshot["ci"]["status"],
    }
    if getattr(args, "json", False):
        _emit(result)
        return 0

    print("AEGL Handoff")
    print("------------")
    print("State captured: PASS")
    print("Git state: PASS")
    print(f"CI state: {snapshot['ci']['status']}")
    print("HANDOFF.md: written")
    print("NEXT-SESSION.md: written")
    print(f"History snapshot: written ({snap['id']})")
    print("")
    print("Next session can start with:")
    print("  aegl resume")
    return 0


# --------------------------------------------------------------------------- #
# resume
# --------------------------------------------------------------------------- #

def do_resume(root: Path, as_json: bool = False) -> int:
    snapshot = state.read_state(root)
    if snapshot is None:
        message = "NO HANDOFF FOUND. Run: aegl handoff"
        if as_json:
            _emit({"status": "MISSING", "message": message})
        else:
            print("AEGL Resume")
            print("-----------")
            print(message)
        return 1

    events.append_event(root, "resume_started")
    current = collector.collect(root, include_ci=False)
    comparison = resume.compare(snapshot, current)
    events.append_event(root, "resume_completed", status=comparison["status"])

    if as_json:
        _emit({**comparison,
               "goal": (snapshot.get("work", {}) or {}).get("goal"),
               "doNotRepeat": (snapshot.get("work", {}) or {}).get("doNotRepeat", []),
               "blocked": (snapshot.get("work", {}) or {}).get("blocked", []),
               "nextAction": (snapshot.get("next", {}) or {}).get("action")})
        return 0

    print(resume.render_resume(snapshot, comparison, current))
    return 0


# --------------------------------------------------------------------------- #
# continuity history / check
# --------------------------------------------------------------------------- #

def do_history(root: Path, as_json: bool = False) -> int:
    snapshots = history.list_snapshots(root)
    if as_json:
        _emit({"snapshots": snapshots})
        return 0

    print("AEGL Continuity History")
    print("-----------------------")
    if not snapshots:
        print("(no snapshots)")
        return 0
    for snap in snapshots:
        print(f"{snap['id']}  {snap.get('generatedAt') or '-'}  "
              f"{snap.get('branch') or '-'}  {snap.get('head') or '-'}")
    return 0


def do_check(root: Path, as_json: bool = False) -> int:
    """Diagnostic only — never a release gate (build plan §21/§22)."""
    snapshot = state.read_state(root)
    issues: list[str] = []
    if snapshot is None:
        issues.append("state.json is missing (run: aegl handoff)")
    else:
        issues.extend(state.validate_state(snapshot))
        for rel, path in (("HANDOFF.md", state.handoff_path(root)),
                          ("NEXT-SESSION.md", state.next_session_path(root))):
            if not path.exists():
                issues.append(f"{rel} referenced by the handoff is missing")

    ok = not issues
    if as_json:
        _emit({"ok": ok, "diagnostic": True, "issues": issues})
        return 0 if ok else 1

    print("AEGL Continuity Check (diagnostic)")
    print("----------------------------------")
    if ok:
        print("state schema: PASS")
        print("referenced files exist: PASS")
        print("HEAD/timestamps: PASS")
    else:
        for issue in issues:
            print(f"ISSUE: {issue}")
    return 0 if ok else 1
