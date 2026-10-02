"""Beads persistent-memory backend (AEGL v1.4). OPTIONAL and fail-soft.

AEGL owns session continuity; Beads owns the long-horizon work graph. This
module is the *only* place AEGL talks to Beads, and it does so exclusively
through the official ``bd`` CLI as a subprocess — never the Dolt database,
never the Go module.

Design rules (see ``docs/research/AEGL-v1.4-BEADS-INTEGRATION-ANALYSIS.md``):

* **Thin** — every method is one ``subprocess.run(["bd", ...])`` with a fixed
  timeout, parsed from ``--json``. No shell interpolation, no user argv.
* **Narrow** — read + ``remember``. Task lifecycle (create/claim/close/dep)
  stays with the agent via ``aegl bd ...``; AEGL does not mirror the whole CLI.
* **Fail-soft** — every failure returns empty/``None``/an error dict; nothing
  here is allowed to break ``aegl resume`` / ``aegl handoff``.
* **Redacting** — ``remember`` refuses any value that trips ``secrets``.
* **Isolated** — ``BEADS_DIR=<root>/.aegl/beads`` and telemetry disabled
  (``BD_DISABLE_METRICS=1``, ``DO_NOT_TRACK=1``) on every invocation.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from .. import secrets, state

# Exact version the adapter was tested against (see versions.json["beads"]).
TESTED_VERSION = "1.3.1"
# Narrow compatibility window: the 1.3.x line only. Anything else degrades to
# "unavailable" rather than trusting a CLI whose contract may have moved.
SUPPORTED_MAJOR = 1
SUPPORTED_MINOR = 3

DEFAULT_BEADS_DIR = ".aegl/beads"
DEFAULT_PREFIX = "bd"

TIMEOUT_PROBE = 3      # --version / where / status / ready / memories
TIMEOUT_DEFAULT = 5    # write-ish calls on the explicit path
TIMEOUT_PRIME = 15     # explicit `aegl memory prime`
TIMEOUT_INIT = 90      # one-time `bd init`

# Applied to every bd invocation AEGL controls.
TELEMETRY_ENV = {
    "BD_DISABLE_METRICS": "1",
    "DO_NOT_TRACK": "1",
    "BD_NON_INTERACTIVE": "1",
    "NO_COLOR": "1",
}

_VERSION_RE = re.compile(r"\b(\d+)\.(\d+)\.(\d+)\b")


def parse_version(text: str | None) -> str | None:
    """Extract ``X.Y.Z`` from ``bd version 1.3.1 (c1c4b642a)``."""
    if not isinstance(text, str):
        return None
    match = _VERSION_RE.search(text)
    return f"{match.group(1)}.{match.group(2)}.{match.group(3)}" if match else None


def version_supported(version: str | None) -> bool:
    if not version:
        return False
    parts = version.split(".")
    try:
        return int(parts[0]) == SUPPORTED_MAJOR and int(parts[1]) == SUPPORTED_MINOR
    except (ValueError, IndexError):
        return False


def _extract_json(text: str):
    """Best-effort JSON decode of a bd stdout stream (tolerates noise)."""
    if not text:
        return None
    stripped = text.strip()
    try:
        return json.loads(stripped)
    except ValueError:
        pass
    for opener, closer in (("[", "]"), ("{", "}")):
        start = stripped.find(opener)
        end = stripped.rfind(closer)
        if start != -1 and end > start:
            try:
                return json.loads(stripped[start:end + 1])
            except ValueError:
                continue
    return None


@dataclass
class RunResult:
    """Outcome of one ``bd`` invocation. ``error`` is a coarse machine tag."""

    ok: bool
    returncode: int | None = None
    stdout: str = ""
    stderr: str = ""
    error: str | None = None  # missing | timeout | oserror | invalid-json | failed
    data: object = None

    def as_dict(self) -> dict:
        return {"ok": self.ok, "returncode": self.returncode, "error": self.error}


class BeadsRunner:
    """Single, uniform subprocess entry point for the ``bd`` CLI."""

    def __init__(self, root: Path, beads_dir: Path | None = None,
                 binary: str | None = None, env: dict | None = None,
                 timeout: int = TIMEOUT_DEFAULT):
        self.root = Path(root)
        self.beads_dir = Path(beads_dir) if beads_dir else self.root / DEFAULT_BEADS_DIR
        self._binary = binary
        self._env_extra = dict(env or {})
        self.timeout = timeout
        self._version: str | None = None
        self._version_read = False

    # -- discovery -------------------------------------------------------- #

    def binary(self) -> str | None:
        """Resolve the bd binary.

        Precedence: ``$AEGL_BEADS_BIN`` (explicit path override, used by tests
        and CI to pin a binary) → constructor override → ``PATH``. A configured
        path that does not exist resolves to ``None`` so a missing bd is
        reported honestly instead of failing later.
        """
        candidate = os.environ.get("AEGL_BEADS_BIN") or self._binary
        if candidate:
            return candidate if os.path.exists(candidate) else None
        return shutil.which("bd")

    def binary_present(self) -> bool:
        return self.binary() is not None

    def env(self) -> dict:
        env = dict(os.environ)
        env.update(TELEMETRY_ENV)
        env.update(self._env_extra)
        env["BEADS_DIR"] = str(self.beads_dir)
        return env

    # -- execution -------------------------------------------------------- #

    def run(self, args: list[str], *, timeout: int | None = None,
            want_json: bool = False, cwd: Path | None = None) -> RunResult:
        binary = self.binary()
        if not binary:
            return RunResult(ok=False, error="missing")
        try:
            proc = subprocess.run(
                [binary, *args],
                cwd=str(cwd or self.root),
                env=self.env(),
                text=True,
                capture_output=True,
                timeout=timeout or self.timeout,
            )
        except FileNotFoundError:
            return RunResult(ok=False, error="missing")
        except subprocess.TimeoutExpired:
            return RunResult(ok=False, error="timeout")
        except OSError as exc:  # pragma: no cover - defensive
            return RunResult(ok=False, error="oserror", stderr=str(exc))

        result = RunResult(
            ok=proc.returncode == 0,
            returncode=proc.returncode,
            stdout=proc.stdout or "",
            stderr=proc.stderr or "",
        )
        if want_json:
            result.data = _extract_json(result.stdout)
            if result.ok and result.data is None and result.stdout.strip():
                result.error = "invalid-json"
        if not result.ok and result.error is None:
            result.error = "failed"
        return result

    def run_passthrough(self, args: list[str]) -> int:
        """Run ``bd`` with inherited stdio (used by ``aegl bd ...``)."""
        binary = self.binary()
        if not binary:
            print("aegl: 'bd' was not found on PATH.", file=sys.stderr)
            print("Install Beads, or run: aegl memory setup beads", file=sys.stderr)
            return 127
        try:
            proc = subprocess.run(
                [binary, *args], cwd=str(self.root), env=self.env(), text=True,
            )
        except FileNotFoundError:
            return 127
        except OSError as exc:  # pragma: no cover - defensive
            print(f"aegl: failed to run bd: {exc}", file=sys.stderr)
            return 126
        return proc.returncode

    # -- capability ------------------------------------------------------- #

    def version(self) -> str | None:
        if not self._version_read:
            self._version_read = True
            result = self.run(["--version"], timeout=TIMEOUT_PROBE)
            if result.ok:
                self._version = parse_version(result.stdout or result.stderr)
        return self._version

    def supported(self) -> bool:
        return version_supported(self.version())

    def initialized(self) -> bool:
        return ((self.beads_dir / "config.yaml").exists()
                or (self.beads_dir / "metadata.json").exists())

    def available(self) -> bool:
        """True only when bd exists AND reports a version inside the window."""
        return self.binary_present() and self.supported()


class BeadsMemoryBackend:
    """Narrow, read-mostly Beads contract used by the Continuity Layer."""

    name = "beads"

    def __init__(self, root: Path | None = None, config: dict | None = None,
                 runner: BeadsRunner | None = None):
        self.config = config or {}
        self.root = Path(root) if root else Path.cwd()
        beads_cfg = (self.config.get("memory", {}) or {}).get("beads", {}) or {}
        rel = beads_cfg.get("dir") or DEFAULT_BEADS_DIR
        beads_dir = Path(rel)
        if not beads_dir.is_absolute():
            beads_dir = self.root / beads_dir
        self.data_dir_rel = rel
        self.prefix = beads_cfg.get("prefix") or DEFAULT_PREFIX
        self.ready_limit = int(beads_cfg.get("readyLimit", 5))
        self.tested_version = beads_cfg.get("testedVersion", TESTED_VERSION)
        self.runner = runner or BeadsRunner(
            self.root,
            beads_dir=beads_dir,
            timeout=int(beads_cfg.get("timeoutSeconds", TIMEOUT_DEFAULT)),
        )

    # -- capability ------------------------------------------------------- #

    def available(self) -> bool:
        return self.runner.available()

    def binary_present(self) -> bool:
        return self.runner.binary_present()

    def version(self) -> str | None:
        return self.runner.version()

    def supported(self) -> bool:
        return self.runner.supported()

    def initialized(self) -> bool:
        return self.runner.initialized()

    # -- setup ------------------------------------------------------------ #

    def _init_args(self) -> list[str]:
        # `-p` pins a stable ID prefix (otherwise bd derives one from the cwd
        # basename, which is arbitrary and surprising across machines).
        args = ["init", "--stealth"]
        if self.prefix:
            args += ["-p", str(self.prefix)]
        return args

    def setup(self, gitignore: bool = True) -> dict:
        """Initialise the Beads workspace at ``BEADS_DIR`` (never agent files).

        ``bd init --stealth`` never touches AGENTS.md / CLAUDE.md / .cursor /
        .codex / .claude, installs no git hooks and makes no commit — which is
        exactly what keeps RuleSync the single source of truth for agent rules.
        """
        result = {
            "backend": self.name,
            "dataDir": str(self.runner.beads_dir),
            "stealth": True,
            "telemetry": "disabled",
        }
        if not self.binary_present():
            return {**result, "ok": False, "error": "missing-binary"}
        version = self.version()
        if version is None:
            return {**result, "ok": False, "error": "version-unreadable"}
        result["version"] = version
        if not self.supported():
            return {**result, "ok": False, "error": "unsupported-version"}

        already = self.initialized()
        if not already:
            # The workspace gate needs the parent of BEADS_DIR to pre-exist.
            self.runner.beads_dir.parent.mkdir(parents=True, exist_ok=True)
            run = self.runner.run(self._init_args(), timeout=TIMEOUT_INIT)
            if not run.ok:
                return {**result, "ok": False, "error": "init-failed",
                        "returncode": run.returncode,
                        "stderr": (run.stderr or "").strip()[-500:]}
        result["alreadyInitialized"] = already
        result["initialized"] = self.initialized()
        result["ok"] = result["initialized"]
        if gitignore:
            result["gitignore"] = self._ensure_gitignored()
        return result

    def _ensure_gitignored(self) -> str:
        """Keep the Dolt runtime data out of Git, git-internally (stealth)."""
        exclude = self.root / ".git" / "info" / "exclude"
        if not exclude.parent.is_dir():
            return "not-a-git-repo"
        try:
            text = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
        except OSError:
            return "unreadable"
        if ".aegl/beads/" in text:
            return "already-ignored"
        block = ("\n# AEGL persistent work memory (added by aegl memory setup beads)\n"
                 ".aegl/beads/\n.aegl/beads.gate.lock\n")
        try:
            with open(exclude, "a", encoding="utf-8", newline="\n") as fh:
                if text and not text.endswith("\n"):
                    fh.write("\n")
                fh.write(block)
        except OSError:
            return "unwritable"
        return "added"

    # -- read ------------------------------------------------------------- #

    def health(self) -> dict:
        binary = self.binary_present()
        version = self.version() if binary else None
        supported = version_supported(version)
        initialized = self.initialized()
        report = {
            "backend": self.name,
            "binary": binary,
            "available": binary and supported,
            "version": version,
            "supported": supported,
            "initialized": initialized,
            "testedVersion": self.tested_version,
            "dataDir": self.data_dir_rel,
            "telemetry": "disabled",
            "healthy": False,
            "summary": None,
        }
        if report["available"] and initialized:
            summary = self.summary()
            if summary is not None:
                report["summary"] = summary
                report["healthy"] = True
        return report

    def summary(self) -> dict | None:
        run = self.runner.run(["status", "--json"], timeout=TIMEOUT_PROBE, want_json=True)
        if not run.ok or not isinstance(run.data, dict):
            return None
        raw = run.data.get("summary", {}) or {}
        return {
            "ready": raw.get("ready_issues", 0),
            "open": raw.get("open_issues", 0),
            "inProgress": raw.get("in_progress_issues", 0),
            "blocked": raw.get("blocked_issues", 0),
            "closed": raw.get("closed_issues", 0),
            "total": raw.get("total_issues", 0),
        }

    def ready_summary(self, limit: int | None = None) -> dict:
        limit = limit or self.ready_limit
        run = self.runner.run(
            ["ready", "--json", "--limit", str(limit)], timeout=TIMEOUT_PROBE, want_json=True
        )
        if not run.ok or not isinstance(run.data, list):
            return {"count": None, "items": [], "error": run.error or "failed"}
        items = [
            {"id": i.get("id"), "title": i.get("title"), "priority": i.get("priority")}
            for i in run.data[:limit] if isinstance(i, dict)
        ]
        return {"count": len(items), "items": items}

    def current_work(self) -> dict | None:
        run = self.runner.run(
            ["list", "--json", "--status", "in_progress", "--limit", "5"],
            timeout=TIMEOUT_PROBE, want_json=True,
        )
        if not run.ok or not isinstance(run.data, list) or not run.data:
            return None
        issue = run.data[0]
        if not isinstance(issue, dict):
            return None
        return {
            "id": issue.get("id"),
            "title": issue.get("title"),
            "status": issue.get("status"),
            "assignee": issue.get("assignee"),
        }

    def memories(self) -> dict:
        run = self.runner.run(["memories", "--json"], timeout=TIMEOUT_PROBE, want_json=True)
        if not run.ok or not isinstance(run.data, dict):
            return {}
        return {k: v for k, v in run.data.items() if k != "schema_version"}

    def prime(self, memories_only: bool = False) -> str | None:
        args = ["prime"] + (["--memories-only"] if memories_only else [])
        run = self.runner.run(args, timeout=TIMEOUT_PRIME)
        return run.stdout if run.ok else None

    # -- write (explicit, redacted) --------------------------------------- #

    def remember(self, key: str, value: str) -> dict:
        # Defence in depth: the command layer already redacts, but never let a
        # credential reach `bd remember` even if a caller forgets.
        if secrets.redact_text(value) != value:
            return {"ok": False, "error": "secret"}
        if not self.available() or not self.initialized():
            return {"ok": False, "error": "unavailable"}
        args = ["remember", value]
        if key:
            args += ["--key", key]
        run = self.runner.run(args, timeout=self.runner.timeout)
        return {"ok": run.ok, "error": None if run.ok else (run.error or "failed"),
                "returncode": run.returncode, "stderr": (run.stderr or "").strip()[-300:]}

    def forget(self, key: str) -> dict:
        if not self.available() or not self.initialized():
            return {"ok": False, "error": "unavailable"}
        run = self.runner.run(["forget", key], timeout=self.runner.timeout)
        return {"ok": run.ok, "error": None if run.ok else (run.error or "failed")}

    # -- bridge: reference only, never a copy ----------------------------- #

    def store(self, root: Path, snapshot: dict) -> None:
        """Handoff hook. Deliberately a no-op.

        Beads owns the work graph; AEGL must never auto-create issues or copy
        a handoff into the DB. The reference summary is composed separately by
        :meth:`reference_summary` and stored in ``state.json`` only.
        """

    def query(self, root: Path) -> list[dict]:
        return []

    def reference_summary(self, ready_limit: int | None = None) -> dict:
        report = self.health()
        ref = {
            "backend": self.name,
            "available": report["available"],
            "supported": report["supported"],
            "initialized": report["initialized"],
            "beadsVersion": report["version"],
            "dataDir": self.data_dir_rel,
            "readyCount": None,
            "currentTask": None,
            "checkedAt": state.iso(),
        }
        if report["healthy"]:
            summary = report["summary"] or {}
            ref["readyCount"] = summary.get("ready")
            current = self.current_work()
            ref["currentTask"] = current.get("id") if current else None
        return ref
