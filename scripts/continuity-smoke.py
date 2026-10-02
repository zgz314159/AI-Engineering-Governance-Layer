#!/usr/bin/env python3
"""AEGL Continuity Layer smoke test (v1.3).

Self-contained: builds throwaway Git repositories from ``fixtures/continuity/``,
drives the real CLI, and asserts the handoff / resume / history / redaction
behaviour. Never touches the host project or the network.

Covered (build plan §28-§31):
  * handoff generation (state.json / HANDOFF.md / NEXT-SESSION.md / events / history)
  * state schema validation
  * resume valid
  * resume stale (new commit) — warning, exit 0
  * working-tree dirty warning
  * doNotRepeat surfaced by resume
  * secret redaction (no token / password persisted)
  * history snapshot listing
  * performance budget (status/resume < 2s, handoff < 5s)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
AEGL_PY = REPO / "core" / "aegl.py"
FIXTURES = REPO / "fixtures" / "continuity"

sys.path.insert(0, str(REPO / "core"))
from continuity import state as cstate  # noqa: E402


class Failure(Exception):
    """Raised when an assertion fails."""


def aegl(root: Path, *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["AEGL_CONTINUITY_SKIP_CI"] = "1"
    env.pop("PYTHONPATH", None)
    return subprocess.run(
        [sys.executable, str(AEGL_PY), *args, "--root", str(root)],
        text=True, capture_output=True, env=env,
    )


def aegl_json(root: Path, *args: str) -> dict:
    proc = aegl(root, *args, "--json")
    if proc.returncode != 0:
        raise Failure(f"`aegl {' '.join(args)}` failed ({proc.returncode}):\n{proc.stdout}\n{proc.stderr}")
    try:
        return json.loads(proc.stdout)
    except ValueError as exc:
        raise Failure(f"`aegl {' '.join(args)}` did not emit JSON: {proc.stdout!r}") from exc


def git(root: Path, *args: str) -> subprocess.CompletedProcess:
    proc = subprocess.run(["git", *args], cwd=str(root), text=True, capture_output=True)
    if proc.returncode != 0:
        raise Failure(f"git {' '.join(args)} failed: {proc.stderr}")
    return proc


def make_repo(fixture: str) -> Path:
    root = Path(tempfile.mkdtemp(prefix=f"aegl-cont-{fixture}-"))
    shutil.copytree(FIXTURES / fixture, root, dirs_exist_ok=True)
    git(root, "init", "-q")
    git(root, "config", "user.email", "continuity@test.invalid")
    git(root, "config", "user.name", "Continuity Test")
    git(root, "add", "-A")
    git(root, "commit", "-qm", "init")
    return root


def must(cond: bool, message: str) -> None:
    if not cond:
        raise Failure(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# --------------------------------------------------------------------------- #
# Tests
# --------------------------------------------------------------------------- #

def test_handoff_generation() -> str:
    root = make_repo("clean-project")
    proc = aegl(root, "handoff", "--goal", "Implement the continuity layer",
                "--next", "Write the smoke test")
    must(proc.returncode == 0, f"handoff failed: {proc.stdout}\n{proc.stderr}")

    cdir = root / ".aegl" / "continuity"
    for rel in ("state.json", "HANDOFF.md", "NEXT-SESSION.md", "events.jsonl", "config.json"):
        must((cdir / rel).exists(), f"handoff did not create {rel}")

    snapshot = json.loads(read(cdir / "state.json"))
    errors = cstate.validate_state(snapshot)
    must(not errors, f"state schema invalid: {errors}")
    must(snapshot["repository"]["dirty"] is False, "recorded dirty should be False on a clean repo")
    must(snapshot["phase"]["name"] == "Continuity Layer", "phase name mismatch")
    must(snapshot["work"]["goal"] == "Implement the continuity layer", "goal not recorded")

    snapshots = sorted((cdir / "history").glob("*.json"))
    must(len(snapshots) == 1, f"expected 1 history snapshot, found {len(snapshots)}")
    must(snapshots[0].with_suffix(".md").exists(), "history markdown snapshot missing")

    next_md = read(cdir / "NEXT-SESSION.md")
    must("Implement the continuity layer" in next_md, "NEXT-SESSION.md missing goal")
    must("aegl resume" in next_md, "NEXT-SESSION.md missing resume hint")
    must("Do not redo:" in next_md, "NEXT-SESSION.md missing 'Do not redo'")

    handoff_md = read(cdir / "HANDOFF.md")
    must("## Verified State" in handoff_md, "HANDOFF.md missing Verified State")
    must("## Do Not Repeat" in handoff_md, "HANDOFF.md missing Do Not Repeat")
    return "clean-project"


def test_resume_valid() -> str:
    root = make_repo("clean-project")
    aegl(root, "handoff", "--goal", "g", "--next", "n")
    data = aegl_json(root, "resume")
    must(data["status"] == "VALID", f"expected VALID, got {data['status']}: {data}")

    text = aegl(root, "resume").stdout
    must("HANDOFF STATUS: VALID" in text, "text resume did not report VALID")
    must(aegl(root, "resume").returncode == 0, "resume valid must exit 0")
    return "clean-project"


def test_resume_stale_after_new_commit() -> str:
    root = make_repo("changed-head")
    aegl(root, "handoff", "--goal", "g", "--next", "n")
    (root / "src" / "later.txt").write_text("new work\n", encoding="utf-8")
    git(root, "add", "-A")
    git(root, "commit", "-qm", "later commit")

    proc = aegl(root, "resume")
    data = aegl_json(root, "resume")
    must(data["status"] == "STALE", f"expected STALE, got {data['status']}")
    must("HEAD changed" in data["reasons"], f"HEAD change not reported: {data['reasons']}")
    must("HANDOFF STATUS: STALE" in proc.stdout, "text resume did not report STALE")
    must(proc.returncode == 0, "STALE must be a warning (exit 0), not a failure")
    return "changed-head"


def test_dirty_warning() -> str:
    root = make_repo("dirty-project")
    aegl(root, "handoff", "--goal", "g", "--next", "n")
    (root / "src" / "app.txt").write_text("uncommitted change\n", encoding="utf-8")

    data = aegl_json(root, "resume")
    must(data["workingTree"]["warning"] is True, f"expected dirty warning: {data['workingTree']}")
    must(data["workingTree"]["recorded"] == "clean", "handoff should have recorded clean")
    text = aegl(root, "resume").stdout
    must("WARNING" in text, "dirty warning not shown in text output")
    return "dirty-project"


def test_do_not_repeat() -> str:
    root = make_repo("clean-project")
    aegl(root, "handoff", "--goal", "g", "--next", "n", "--do-not-repeat", "setup gradle")
    text = aegl(root, "resume").stdout
    must("DO NOT REPEAT:" in text, "resume did not surface doNotRepeat")
    must("setup gradle" in text, "doNotRepeat item missing from resume output")
    return "clean-project"


SECRETS = [
    "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    "abcdef1234567890",
    "hunter2secret",
]


def test_secret_redaction() -> str:
    root = make_repo("clean-project")
    goal = ("Deploy with Authorization: Bearer abcdef1234567890 and "
            "TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    aegl(root, "handoff", "--goal", goal, "--next", "n",
         "--do-not-repeat", "PASSWORD=hunter2secret")

    cdir = root / ".aegl" / "continuity"
    # No persisted artifact may contain a secret.
    for rel in ("state.json", "HANDOFF.md", "NEXT-SESSION.md", "events.jsonl"):
        blob = read(cdir / rel)
        for secret in SECRETS:
            must(secret not in blob, f"secret leaked into {rel}: {secret}")

    # The goal text (which carried the secrets) is present but redacted.
    for rel in ("state.json", "HANDOFF.md", "NEXT-SESSION.md"):
        must("[REDACTED]" in read(cdir / rel), f"no redaction marker in {rel}")

    snapshot = json.loads(read(cdir / "state.json"))
    must("ghp_" not in json.dumps(snapshot), "provider token leaked into state.json")
    must("Authorization: [REDACTED]" in snapshot["work"]["goal"], "Authorization header not redacted")
    must("TOKEN=[REDACTED]" in snapshot["work"]["goal"], "TOKEN value not redacted")
    return "clean-project"


def test_history_listing() -> str:
    root = make_repo("clean-project")
    aegl(root, "handoff", "--goal", "first", "--next", "n")
    time.sleep(1.05)  # distinct snapshot ids (second resolution)
    aegl(root, "handoff", "--goal", "second", "--next", "n")

    data = aegl_json(root, "continuity", "history")
    must(len(data["snapshots"]) >= 2, f"expected >=2 snapshots, got {len(data['snapshots'])}")
    ids = [s["id"] for s in data["snapshots"]]
    must(ids == sorted(ids, reverse=True), "snapshots not newest-first")

    text = aegl(root, "continuity", "history").stdout
    must("AEGL Continuity History" in text, "history text output missing header")
    return "clean-project"


def test_diagnostic_check() -> str:
    root = make_repo("clean-project")
    aegl(root, "handoff", "--goal", "g", "--next", "n")
    data = aegl_json(root, "continuity", "check")
    must(data["ok"] is True, f"check should pass on a fresh handoff: {data}")

    (root / ".aegl" / "continuity" / "HANDOFF.md").unlink()
    broken = aegl(root, "continuity", "check", "--json")
    must(broken.returncode == 1, "check should flag a missing projection file")
    must(json.loads(broken.stdout)["ok"] is False, "check should report ok=false")
    return "clean-project"


def test_state_schema() -> str:
    root = make_repo("clean-project")
    aegl(root, "handoff", "--goal", "g", "--next", "n")
    snapshot = json.loads(read(root / ".aegl" / "continuity" / "state.json"))
    must(cstate.validate_state(snapshot) == [], "valid snapshot rejected")

    broken = json.loads(json.dumps(snapshot))
    broken["repository"]["head"] = "not-a-sha"
    must(cstate.validate_state(broken), "invalid HEAD was accepted")

    missing = json.loads(json.dumps(snapshot))
    del missing["next"]
    must(cstate.validate_state(missing), "missing next section was accepted")
    return "clean-project"


def test_performance() -> str:
    root = make_repo("clean-project")
    timings: dict[str, float] = {}

    for name, args in (("handoff", ("handoff", "--goal", "g", "--next", "n")),
                       ("status", ("status",)),
                       ("resume", ("resume",))):
        start = time.perf_counter()
        proc = aegl(root, *args)
        timings[name] = time.perf_counter() - start
        must(proc.returncode == 0, f"{name} failed during performance test")

    must(timings["handoff"] < 5.0, f"handoff too slow: {timings['handoff']:.3f}s")
    must(timings["status"] < 2.0, f"status too slow: {timings['status']:.3f}s")
    must(timings["resume"] < 2.0, f"resume too slow: {timings['resume']:.3f}s")
    return f"handoff={timings['handoff']:.2f}s status={timings['status']:.2f}s resume={timings['resume']:.2f}s"


TESTS = [
    ("handoff generation", test_handoff_generation),
    ("state schema", test_state_schema),
    ("resume valid", test_resume_valid),
    ("resume stale", test_resume_stale_after_new_commit),
    ("dirty warning", test_dirty_warning),
    ("doNotRepeat", test_do_not_repeat),
    ("secret redaction", test_secret_redaction),
    ("history snapshot", test_history_listing),
    ("diagnostic check", test_diagnostic_check),
    ("performance", test_performance),
]


def main() -> int:
    print("AEGL Continuity Layer smoke test")
    print("================================")
    failures = 0
    for name, fn in TESTS:
        try:
            detail = fn()
        except Failure as exc:
            failures += 1
            print(f"FAIL  {name}: {exc}")
        else:
            print(f"PASS  {name}" + (f"  ({detail})" if detail else ""))
    print("================================")
    if failures:
        print(f"RESULT: FAIL ({failures} failing)")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
