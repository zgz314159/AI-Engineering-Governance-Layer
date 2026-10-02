#!/usr/bin/env python3
"""AEGL Persistent Work Memory (Beads adapter) smoke test — v1.4.

Self-contained. Three layers:

  * ``none`` backend — Continuity must be fully functional with no Beads.
  * stub ``bd`` (``fixtures/memory/fake-bin/bd``) — runner/version/JSON/timeout/
    error coverage, hermetic and network-free.
  * real ``bd`` (``--bd /path/to/bd``) — integration: stealth setup, BEADS_DIR,
    DAG/ready semantics, remember/prime, secret rejection, graceful fallback,
    and the negative RuleSync tests (AGENTS.md / CLAUDE.md / hooks untouched).

Assertions here are the v1.4 acceptance criteria. The script exits non-zero on
any failure.
"""
from __future__ import annotations

import argparse
import hashlib
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
FAKE_BD = REPO / "fixtures" / "memory" / "fake-bin" / "bd"

REAL_BD: str | None = None
FAKE_BIN: str = str(FAKE_BD)


class Failure(Exception):
    """Raised when an assertion fails."""


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

def _base_env(env: dict | None) -> dict:
    out = dict(os.environ)
    out["AEGL_CONTINUITY_SKIP_CI"] = "1"
    out.pop("PYTHONPATH", None)
    if env:
        out.update(env)
    return out


def aegl(root: Path, *args: str, env: dict | None = None, timeout: int = 180):
    return subprocess.run(
        [sys.executable, str(AEGL_PY), *args, "--root", str(root)],
        text=True, capture_output=True, env=_base_env(env), timeout=timeout,
    )


def aegl_bd(root: Path, *args: str, env: dict | None = None, timeout: int = 180):
    return subprocess.run(
        [sys.executable, str(AEGL_PY), "bd", "--root", str(root), *args],
        text=True, capture_output=True, env=_base_env(env), timeout=timeout,
    )


def aegl_json(root: Path, *args: str, env: dict | None = None) -> dict:
    proc = aegl(root, *args, "--json", env=env)
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


def make_repo(name: str = "proj", extra: dict | None = None) -> Path:
    root = Path(tempfile.mkdtemp(prefix=f"aegl-mem-{name}-"))
    (root / "src").mkdir(parents=True)
    (root / "src" / "app.txt").write_text("x\n", encoding="utf-8")
    (root / "VERSION").write_text("1.4.0-dev\n", encoding="utf-8")
    for rel, content in (extra or {}).items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    git(root, "init", "-q")
    git(root, "config", "user.email", "memory@test.invalid")
    git(root, "config", "user.name", "Memory Test")
    git(root, "add", "-A")
    git(root, "commit", "-qm", "init")
    return root


def must(cond: bool, message: str) -> None:
    if not cond:
        raise Failure(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def state_of(root: Path) -> dict:
    return json.loads(read(root / ".aegl" / "continuity" / "state.json"))


def ids(proc_out: str) -> list[str]:
    return [i["id"] for i in json.loads(proc_out)]


# --------------------------------------------------------------------------- #
# none backend
# --------------------------------------------------------------------------- #

def test_none_backend() -> str:
    root = make_repo("none")
    status = aegl(root, "memory", "status")
    must(status.returncode == 0, f"status failed: {status.stdout}{status.stderr}")
    must("Backend: none" in status.stdout, "status did not report backend none")

    ready = aegl(root, "memory", "ready")
    must(ready.returncode == 1, "ready on none backend must be a soft failure")
    must("none" in ready.stdout.lower(), "ready should explain the none backend")

    prime = aegl(root, "memory", "prime")
    must(prime.returncode == 1, "prime on none backend must be a soft failure")
    must("Continuity" not in prime.stderr, "prime must not crash")

    handoff = aegl(root, "handoff", "--goal", "g", "--next", "n")
    must(handoff.returncode == 0, f"handoff failed without Beads: {handoff.stdout}")
    must("memory" not in state_of(root), "none backend must not add a memory block")

    resume = aegl(root, "resume")
    must(resume.returncode == 0, "resume must work without Beads")
    must("HANDOFF STATUS" in resume.stdout, "resume output missing")
    return "none backend isolated"


def test_none_resume_with_memory() -> str:
    root = make_repo("none-with-mem")
    aegl(root, "handoff", "--goal", "g", "--next", "n")
    proc = aegl(root, "resume", "--with-memory")
    must(proc.returncode == 0, "resume --with-memory must not fail")
    must("Persistent Memory" in proc.stdout, "memory brief section missing")
    must("Backend: none" in proc.stdout, "none backend not reported in brief")
    return "none brief ok"


# --------------------------------------------------------------------------- #
# stub bd
# --------------------------------------------------------------------------- #

def _fake_env(mode: str | None = None, version: str | None = None, binary: str | None = None) -> dict:
    env = {"AEGL_BEADS_BIN": binary or FAKE_BIN}
    if mode:
        env["FAKE_BD_MODE"] = mode
    if version:
        env["FAKE_BD_VERSION"] = version
    return env


def test_fake_runner() -> str:
    root = make_repo("fake")
    env = _fake_env()
    setup = aegl(root, "memory", "setup", "beads", env=env)
    must(setup.returncode == 0, f"fake setup failed: {setup.stdout}{setup.stderr}")
    must((root / ".aegl" / "beads" / "config.yaml").exists(), "setup did not create BEADS_DIR")

    data = aegl_json(root, "memory", "status", env=env)
    must(data["backend"] == "beads", data)
    must(data["available"] is True, data)
    must(data["version"] == "1.3.1", f"version parse failed: {data['version']}")
    must(data["supported"] is True, data)
    must(data["initialized"] is True, data)
    must(data["telemetry"] == "disabled", data)
    must(isinstance(data["readyCount"], int), data)

    rem = aegl(root, "memory", "remember", "arch-guard", "Architecture Guard must use pnpm", env=env)
    must(rem.returncode == 0, f"remember failed: {rem.stdout}{rem.stderr}")
    mem = json.loads(aegl_bd(root, "memories", "--json", env=env).stdout)
    must(mem.get("arch-guard") == "Architecture Guard must use pnpm", mem)
    return "fake runner ok"


def test_fake_unsupported_version() -> str:
    # A fresh repo: setup must refuse an unsupported version outright.
    fresh = make_repo("fake-ver-fresh")
    env_bad = _fake_env(version="2.0.0")
    setup = aegl(fresh, "memory", "setup", "beads", env=env_bad)
    must(setup.returncode == 1, "setup must refuse an unsupported version")
    must("outside the supported" in setup.stdout, setup.stdout)

    # A configured repo: an unsupported bd degrades cleanly at runtime.
    root = make_repo("fake-ver")
    aegl(root, "memory", "setup", "beads", env=_fake_env())
    data = aegl_json(root, "memory", "status", env=env_bad)
    must(data["available"] is False, data)
    must(data["supported"] is False, data)
    must(data["version"] == "2.0.0", data)

    aegl(root, "handoff", "--goal", "g", "--next", "n", env=env_bad)
    must(aegl(root, "resume", env=env_bad).returncode == 0, "resume must survive unsupported bd")
    return "unsupported version degrades"


def test_fake_invalid_json() -> str:
    root = make_repo("fake-json")
    env = _fake_env()
    aegl(root, "memory", "setup", "beads", env=env)
    proc = aegl(root, "memory", "status", env=_fake_env(mode="invalid-json"))
    must(proc.returncode == 0, "invalid JSON must not crash status")
    must("Ready count: (n/a)" in proc.stdout, proc.stdout)
    return "invalid json degraded"


def test_fake_timeout() -> str:
    root = make_repo("fake-timeout")
    env = _fake_env()
    aegl(root, "memory", "setup", "beads", env=env)

    start = time.perf_counter()
    status = aegl(root, "memory", "status", env=_fake_env(mode="timeout"))
    elapsed = time.perf_counter() - start
    must(status.returncode == 0, "timeout must not crash status")
    must(elapsed < 8.0, f"status did not time out promptly ({elapsed:.2f}s)")

    start = time.perf_counter()
    ready = aegl(root, "memory", "ready", env=_fake_env(mode="timeout"))
    elapsed = time.perf_counter() - start
    must(ready.returncode == 1, "timed-out ready must be a soft failure")
    must(elapsed < 8.0, f"ready did not time out promptly ({elapsed:.2f}s)")
    return f"timeouts bounded ({elapsed:.1f}s)"


def test_fake_uninitialized() -> str:
    root = make_repo("fake-uninit")
    env = _fake_env()
    # Configure the beads backend, then remove the workspace so it is
    # "configured but uninitialized" (a realistic partial state).
    aegl(root, "memory", "setup", "beads", env=env)
    shutil.rmtree(root / ".aegl" / "beads")
    data = aegl_json(root, "memory", "status", env=env)
    must(data["available"] is True, data)
    must(data["initialized"] is False, data)

    ready = aegl(root, "memory", "ready", env=env)
    must(ready.returncode == 1, "uninitialized ready must be a soft failure")
    must(aegl(root, "handoff", "--goal", "g", "--next", "n", env=env).returncode == 0,
         "handoff must survive an uninitialized Beads workspace")
    return "uninitialized degrades"


def test_secret_rejection() -> str:
    root = make_repo("secret")
    env = _fake_env()
    aegl(root, "memory", "setup", "beads", env=env)

    token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    proc = aegl(root, "memory", "remember", f"TOKEN={token}", env=env)
    must(proc.returncode == 1, "secret memory must be rejected")
    must("REJECTED" in proc.stdout, proc.stdout)
    must(token not in proc.stdout, "the secret must never be echoed")

    mem = json.loads(aegl_bd(root, "memories", "--json", env=env).stdout)
    must(token not in json.dumps(mem), "secret must not reach the Beads store")

    # --key path too
    proc2 = aegl(root, "memory", "remember", "safe-content", "--key", "safe", env=env)
    must(proc2.returncode == 0, f"non-secret remember should succeed: {proc2.stdout}")
    return "secrets rejected before bd"


# --------------------------------------------------------------------------- #
# semantic regression (no bd needed)
# --------------------------------------------------------------------------- #

def test_next_action_normalization() -> str:
    root = make_repo("normalize")
    proc = aegl(root, "handoff", "--goal", "g", "--next", "publish v1.3.0",
                "--do-not-repeat", "publish v1.3.0",
                "--do-not-repeat", "re-run completed gates")
    must(proc.returncode == 0, f"handoff failed: {proc.stdout}")
    snapshot = state_of(root)
    must(snapshot["next"]["action"] == "publish v1.3.0", "next action not recorded")
    must(snapshot["work"]["doNotRepeat"] == ["re-run completed gates"],
         f"nextAction leaked into doNotRepeat: {snapshot['work']['doNotRepeat']}")

    # A non-conflicting doNotRepeat is preserved verbatim.
    root2 = make_repo("normalize2")
    aegl(root2, "handoff", "--goal", "g", "--next", "ship it",
         "--do-not-repeat", "republish the v1.3.0 tag")
    must(state_of(root2)["work"]["doNotRepeat"] == ["republish the v1.3.0 tag"],
         "unrelated doNotRepeat item was dropped")
    return "nextAction/doNotRepeat normalized"


# --------------------------------------------------------------------------- #
# real bd integration
# --------------------------------------------------------------------------- #

def _real_env() -> dict:
    return {"AEGL_BEADS_BIN": REAL_BD or ""}


def test_real_setup_stealth() -> str:
    root = make_repo("real-stealth", extra={
        "AGENTS.md": "# AGENTS\n\nRuleSync owns this file.\n",
        "CLAUDE.md": "# CLAUDE\n\nRuleSync owns this file too.\n",
    })
    agents, claude = root / "AGENTS.md", root / "CLAUDE.md"
    agents_hash, claude_hash = sha256(agents), sha256(claude)
    hooks_before = subprocess.run(["git", "config", "--get", "core.hooksPath"], cwd=root,
                                  text=True, capture_output=True).stdout.strip()
    commits_before = git(root, "rev-list", "--count", "HEAD").stdout.strip()

    setup = aegl(root, "memory", "setup", "beads", env=_real_env())
    must(setup.returncode == 0, f"real setup failed: {setup.stdout}\n{setup.stderr}")

    must(sha256(agents) == agents_hash, "AGENTS.md was mutated by Beads setup")
    must(sha256(claude) == claude_hash, "CLAUDE.md was mutated by Beads setup")
    must("BEGIN BEADS INTEGRATION" not in read(agents), "Beads injected an AGENTS.md block")
    must("BEGIN BEADS INTEGRATION" not in read(claude), "Beads injected a CLAUDE.md block")

    hooks_after = subprocess.run(["git", "config", "--get", "core.hooksPath"], cwd=root,
                                 text=True, capture_output=True).stdout.strip()
    must(hooks_after == hooks_before, f"core.hooksPath changed: {hooks_before!r} -> {hooks_after!r}")
    must(git(root, "rev-list", "--count", "HEAD").stdout.strip() == commits_before,
         "Beads setup created a commit")
    dirty = git(root, "status", "--porcelain", "--", "AGENTS.md", "CLAUDE.md").stdout.strip()
    must(dirty == "", f"agent files show as modified: {dirty}")

    must((root / ".aegl" / "beads" / "config.yaml").exists(), "BEADS_DIR not initialised")
    must((root / ".aegl" / "beads.gate.lock").exists(), "gate lock (sibling of BEADS_DIR) missing")
    ignore = subprocess.run(["git", "check-ignore", "-q", ".aegl/beads/config.yaml"], cwd=root)
    must(ignore.returncode == 0, ".aegl/beads is not git-ignored")
    return "stealth setup, no agent/hook/commit mutation"


def test_real_status() -> str:
    root = make_repo("real-status")
    aegl(root, "memory", "setup", "beads", env=_real_env())
    data = aegl_json(root, "memory", "status", env=_real_env())
    must(data["backend"] == "beads", data)
    must(data["available"] is True, data)
    must(data["supported"] is True, data)
    must(data["initialized"] is True, data)
    must(data["version"].startswith("1.3."), f"unexpected version {data['version']}")
    must(data["telemetry"] == "disabled", data)
    must(isinstance(data["readyCount"], int), data)
    return f"real status {data['version']}"


def test_real_lifecycle_dag() -> str:
    root = make_repo("real-dag")
    env = _real_env()
    aegl(root, "memory", "setup", "beads", env=env)

    a = json.loads(aegl_bd(root, "create", "Task A", "-t", "task", "--json", env=env).stdout)["id"]
    b = json.loads(aegl_bd(root, "create", "Task B", "-t", "task", "--json", env=env).stdout)["id"]
    aegl_bd(root, "dep", "add", b, a, env=env)

    must(ids(aegl_bd(root, "ready", "--json", env=env).stdout) == [a],
         "ready must gate the dependent task")
    aegl_bd(root, "update", a, "--claim", env=env)
    must(ids(aegl_bd(root, "ready", "--json", env=env).stdout) == [],
         "claimed work must leave the ready queue")
    aegl_bd(root, "close", a, "-r", "done", env=env)
    must(ids(aegl_bd(root, "ready", "--json", env=env).stdout) == [b],
         "closing a blocker must release its dependent")

    # `aegl memory ready` is a thin wrapper — same result as bd.
    proc = aegl(root, "memory", "ready", env=env)
    must(proc.returncode == 0 and b in proc.stdout, f"memory ready mismatch: {proc.stdout}")
    return "DAG + ready semantics from Beads"


def test_real_remember_prime() -> str:
    root = make_repo("real-mem")
    env = _real_env()
    aegl(root, "memory", "setup", "beads", env=env)
    aegl(root, "memory", "remember", "arch-guard", "Architecture Guard must use pnpm", env=env)

    prime = aegl(root, "memory", "prime", "--memories-only", env=env)
    must(prime.returncode == 0, f"prime failed: {prime.stdout}{prime.stderr}")
    must("Architecture Guard must use pnpm" in prime.stdout, "memory not present in prime")

    secret = "sk-abcdefghijklmnopqrstuvwxyz0123456789"
    reject = aegl(root, "memory", "remember", f"API_KEY={secret}", env=env)
    must(reject.returncode == 1, "real secret memory must be rejected")
    must(secret not in reject.stdout, "secret echoed")
    mem = json.loads(aegl_bd(root, "memories", "--json", env=env).stdout)
    must(secret not in json.dumps(mem), "secret reached the real Beads store")
    return "remember/prime + secret rejection"


def test_real_handoff_reference() -> str:
    root = make_repo("real-handoff")
    env = _real_env()
    aegl(root, "memory", "setup", "beads", env=env)
    a = json.loads(aegl_bd(root, "create", "Current work", "-t", "task", "--json", env=env).stdout)["id"]
    aegl_bd(root, "update", a, "--claim", env=env)

    handoff = aegl(root, "handoff", "--goal", "g", "--next", "n", env=env)
    must(handoff.returncode == 0, f"handoff failed: {handoff.stdout}")
    memory = state_of(root).get("memory", {})
    must(memory.get("backend") == "beads", memory)
    must(memory.get("available") is True, memory)
    must(isinstance(memory.get("readyCount"), int), memory)
    must(memory.get("currentTask") == a, f"currentTask not referenced: {memory}")

    # Reference only — never a copy of the work graph.
    allowed = {"backend", "available", "supported", "initialized", "beadsVersion",
               "dataDir", "readyCount", "currentTask", "checkedAt"}
    extra = set(memory) - allowed
    must(not extra, f"memory block carries unexpected (graph-like) data: {extra}")

    text = read(root / ".aegl" / "continuity" / "HANDOFF.md")
    must("## Persistent Memory (reference)" in text, "HANDOFF.md missing memory section")
    return "reference-only handoff block"


def test_real_disable() -> str:
    root = make_repo("real-disable")
    env = _real_env()
    aegl(root, "memory", "setup", "beads", env=env)
    aegl(root, "memory", "remember", "keep-me", "durable fact", env=env)
    aegl(root, "handoff", "--goal", "g", "--next", "n", env=env)

    disable = aegl(root, "memory", "disable", env=env)
    must(disable.returncode == 0, f"disable failed: {disable.stdout}")
    data = aegl_json(root, "memory", "status", env=env)
    must(data["backend"] == "none", data)
    # Data preserved on disk.
    must((root / ".aegl" / "beads" / "config.yaml").exists(), "disable deleted the Beads data")
    must(aegl(root, "resume", env=env).returncode == 0, "resume must work after disable")
    return "disable preserves data"


def test_real_graceful_broken() -> str:
    root = make_repo("real-broken")
    env = _real_env()
    aegl(root, "memory", "setup", "beads", env=env)

    broken = {"AEGL_BEADS_BIN": "/nonexistent/bd-does-not-exist"}
    data = aegl_json(root, "memory", "status", env=broken)
    must(data["available"] is False, data)
    must(aegl(root, "memory", "ready", env=broken).returncode == 1, "broken ready must be soft")
    must(aegl(root, "handoff", "--goal", "g", "--next", "n", env=broken).returncode == 0,
         "handoff must survive a broken bd")
    must(aegl(root, "resume", env=broken).returncode == 0, "resume must survive a broken bd")
    return "broken bd degrades to warning"


# --------------------------------------------------------------------------- #
# runner
# --------------------------------------------------------------------------- #

TESTS = [
    ("none backend", test_none_backend),
    ("none resume --with-memory", test_none_resume_with_memory),
    ("stub bd runner", test_fake_runner),
    ("stub unsupported version", test_fake_unsupported_version),
    ("stub invalid json", test_fake_invalid_json),
    ("stub timeout", test_fake_timeout),
    ("stub uninitialized", test_fake_uninitialized),
    ("secret rejection", test_secret_rejection),
    ("nextAction/doNotRepeat", test_next_action_normalization),
]

REAL_TESTS = [
    ("real setup stealth", test_real_setup_stealth),
    ("real status", test_real_status),
    ("real lifecycle DAG", test_real_lifecycle_dag),
    ("real remember/prime", test_real_remember_prime),
    ("real handoff reference", test_real_handoff_reference),
    ("real disable", test_real_disable),
    ("real graceful broken", test_real_graceful_broken),
]


def main() -> int:
    global REAL_BD, FAKE_BIN
    parser = argparse.ArgumentParser()
    parser.add_argument("--bd", default=os.environ.get("AEGL_BEADS_BIN") or None,
                        help="Path to a real bd binary for the integration tests")
    parser.add_argument("--no-real", action="store_true", help="Skip the real-bd integration tests")
    args = parser.parse_args()

    if not FAKE_BD.exists():
        print(f"fake bd not found at {FAKE_BD}")
        return 2
    if REAL_BD is None and args.bd:
        REAL_BD = args.bd

    print("AEGL Persistent Work Memory smoke test")
    print("======================================")
    failures = 0
    for name, fn in TESTS:
        try:
            detail = fn()
        except Failure as exc:
            failures += 1
            print(f"FAIL  {name}: {exc}")
        else:
            print(f"PASS  {name}" + (f"  ({detail})" if detail else ""))

    if args.no_real or not REAL_BD:
        print("SKIP  real bd integration tests (no --bd given)")
    else:
        for name, fn in REAL_TESTS:
            try:
                detail = fn()
            except Failure as exc:
                failures += 1
                print(f"FAIL  {name}: {exc}")
            else:
                print(f"PASS  {name}" + (f"  ({detail})" if detail else ""))

    print("======================================")
    if failures:
        print(f"RESULT: FAIL ({failures} failing)")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
