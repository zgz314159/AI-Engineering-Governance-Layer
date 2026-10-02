"""CLI orchestration for the optional persistent-memory backend (v1.4).

Keeps the ``aegl memory ...`` surface thin and the Beads specifics inside
``backends/beads.py``. Every command is fail-soft: a missing or broken Beads
backend is reported as a WARNING, never a crash or a Continuity failure.
"""
from __future__ import annotations

import json
from pathlib import Path

from . import memory, secrets, state

INSTALL_GUIDANCE = (
    "Beads CLI ('bd') is not available. AEGL Continuity still works fully.\n"
    "To enable persistent work memory, install Beads (tested: v1.3.1):\n"
    "  brew install beads            # macOS / Linux\n"
    "  npm install -g @beads/bd\n"
    "  # or download a release binary:\n"
    "  https://github.com/gastownhall/beads/releases/tag/v1.3.1\n"
    "AEGL never downloads or vendors Beads automatically."
)


def _emit(obj: dict) -> None:
    print(json.dumps(obj, indent=2, ensure_ascii=False))


def _config(root: Path) -> dict:
    return state.load_config(root)


def _backend(root: Path, force_beads: bool = False):
    cfg = _config(root)
    if force_beads:
        cfg = {**cfg, "memoryBackend": "beads"}
    return memory.load_backend(cfg, root), cfg


def brief(root: Path) -> dict:
    """A small, bounded memory summary for ``aegl resume --with-memory``."""
    backend, _ = _backend(root)
    health = backend.health()
    result = {
        "backend": backend.name,
        "available": health.get("available", False),
        "version": health.get("version"),
        "supported": health.get("supported", False),
        "initialized": health.get("initialized", False),
        "healthy": health.get("healthy", False),
        "readyCount": None,
        "currentTask": None,
    }
    if backend.name == "beads" and result["healthy"]:
        ready = backend.ready_summary()
        result["readyCount"] = ready.get("count")
        current = backend.current_work()
        result["currentTask"] = current.get("id") if current else None
    return result


# --------------------------------------------------------------------------- #
# aegl memory status
# --------------------------------------------------------------------------- #

def do_status(root: Path, as_json: bool = False) -> int:
    backend, _ = _backend(root)
    health = backend.health()
    report = {
        "backend": backend.name,
        "available": health.get("available", False),
        "version": health.get("version"),
        "supported": health.get("supported", False),
        "initialized": health.get("initialized", False),
        "healthy": health.get("healthy", False),
        "dataDir": health.get("dataDir"),
        "telemetry": health.get("telemetry"),
        "testedVersion": health.get("testedVersion"),
        "readyCount": None,
        "currentTask": None,
    }
    if backend.name == "beads" and report["healthy"]:
        ready = backend.ready_summary()
        report["readyCount"] = ready.get("count")
        current = backend.current_work()
        report["currentTask"] = current.get("id") if current else None

    if as_json:
        _emit(report)
        return 0

    print("AEGL Persistent Memory")
    print("----------------------")
    print(f"Backend: {report['backend']}")
    print(f"Available: {str(report['available']).lower()}")
    print(f"Version: {report['version'] or '(none)'}")
    print(f"Supported: {str(report['supported']).lower()}")
    print(f"Initialized: {str(report['initialized']).lower()}")
    print(f"Data dir: {report['dataDir'] or '(none)'}")
    print(f"Telemetry: {report['telemetry']}")
    print(f"Ready count: {report['readyCount'] if report['readyCount'] is not None else '(n/a)'}")
    print(f"Current task: {report['currentTask'] or '(none)'}")
    return 0


# --------------------------------------------------------------------------- #
# aegl memory setup beads
# --------------------------------------------------------------------------- #

def do_setup(root: Path, target: str = "beads", as_json: bool = False) -> int:
    if target != "beads":
        if as_json:
            _emit({"ok": False, "error": f"unknown backend: {target}"})
        else:
            print(f"Unknown memory backend: {target} (only 'beads' is supported)")
        return 2

    backend, cfg = _backend(root, force_beads=True)
    result = backend.setup()

    if not result.get("ok"):
        if as_json:
            _emit(result)
            return 1
        print("AEGL Memory Setup (beads)")
        print("-------------------------")
        if result.get("error") == "missing-binary":
            print(INSTALL_GUIDANCE)
        elif result.get("error") == "unsupported-version":
            print(f"WARNING: bd {result.get('version')} is outside the supported "
                  f"1.3.x window (tested: {backend.tested_version}).")
            print("Refusing to initialise with an untested Beads version.")
        else:
            print(f"Setup failed: {result.get('error')}")
            if result.get("stderr"):
                print(result["stderr"])
        return 1

    cfg["memoryBackend"] = "beads"
    state.save_config(root, cfg)

    if as_json:
        _emit({**result, "memoryBackend": "beads"})
        return 0

    print("AEGL Memory Setup (beads)")
    print("-------------------------")
    print("Beads backend enabled")
    print(f"Beads version: {result.get('version')}")
    print(f"Data directory: {result.get('dataDir')}")
    print("Telemetry: disabled (BD_DISABLE_METRICS=1, DO_NOT_TRACK=1)")
    print("Stealth mode: enabled (no agent files, no git hooks, no commit)")
    print("Continuity config: memoryBackend = beads")
    print("")
    print("Next:")
    print("  aegl memory status")
    print("  bd ready        (via: aegl bd ready)")
    return 0


# --------------------------------------------------------------------------- #
# aegl memory prime
# --------------------------------------------------------------------------- #

def do_prime(root: Path, memories_only: bool = False, as_json: bool = False) -> int:
    backend, _ = _backend(root)
    if backend.name != "beads":
        if as_json:
            _emit({"backend": backend.name, "prime": None, "error": "backend-none"})
        else:
            print("Persistent memory backend is 'none'. Run: aegl memory setup beads")
        return 1

    text = backend.prime(memories_only=memories_only)
    if text is None:
        if as_json:
            _emit({"backend": "beads", "prime": None, "error": "unavailable"})
        else:
            print("WARNING: Beads memory context is unavailable (bd missing, "
                  "unsupported version, or workspace not initialized).")
            print("Continuity is unaffected.")
        return 1

    if as_json:
        _emit({"backend": "beads", "memoriesOnly": memories_only, "prime": text})
        return 0
    print(text.rstrip("\n"))
    return 0


# --------------------------------------------------------------------------- #
# aegl memory remember
# --------------------------------------------------------------------------- #

def _looks_secret(text: str) -> bool:
    return isinstance(text, str) and secrets.redact_text(text) != text


def do_remember(root: Path, key: str | None, value: str, as_json: bool = False) -> int:
    # AEGL redacts BEFORE Beads: bd performs no redaction of its own.
    if _looks_secret(value) or (key and _looks_secret(key)):
        message = ("refusing to store memory: the value looks like it contains a "
                   "credential (matched a redaction pattern). Remove the secret "
                   "and retry. Nothing was written.")
        if as_json:
            _emit({"ok": False, "error": "secret-detected", "message": message})
        else:
            print("AEGL Memory Remember")
            print("--------------------")
            print(f"REJECTED: {message}")
        return 1

    backend, _ = _backend(root)
    if backend.name != "beads":
        if as_json:
            _emit({"ok": False, "error": "backend-none"})
        else:
            print("Persistent memory backend is 'none'. Run: aegl memory setup beads")
        return 1

    result = backend.remember(key or "", value)
    if not result.get("ok"):
        if as_json:
            _emit(result)
            return 1
        print("AEGL Memory Remember")
        print("--------------------")
        print(f"WARNING: memory not stored ({result.get('error')}).")
        if result.get("stderr"):
            print(result["stderr"])
        return 1

    if as_json:
        _emit({"ok": True, "key": key, "value": value})
        return 0
    label = key or "(auto)"
    print("AEGL Memory Remember")
    print("--------------------")
    print(f"Remembered [{label}]: {value}")
    return 0


# --------------------------------------------------------------------------- #
# aegl memory ready
# --------------------------------------------------------------------------- #

def do_ready(root: Path, limit: int | None = None, as_json: bool = False) -> int:
    backend, _ = _backend(root)
    if backend.name != "beads":
        if as_json:
            _emit({"backend": backend.name, "ready": None, "error": "backend-none"})
        else:
            print("Persistent memory backend is 'none'. Run: aegl memory setup beads")
        return 1

    ready = backend.ready_summary(limit)
    if as_json:
        _emit({"backend": "beads", **ready})
        return 0 if ready.get("count") is not None else 1

    if ready.get("count") is None:
        print("WARNING: ready work is unavailable (Beads backend not usable).")
        print("Continuity is unaffected.")
        return 1

    print("AEGL Ready Work (from Beads)")
    print("----------------------------")
    if not ready["items"]:
        print("(no ready work)")
        return 0
    for item in ready["items"]:
        print(f"{item['id']}  P{item.get('priority')}  {item.get('title')}")
    return 0


# --------------------------------------------------------------------------- #
# aegl memory disable  (never deletes data)
# --------------------------------------------------------------------------- #

def do_disable(root: Path, as_json: bool = False) -> int:
    cfg = _config(root)
    previous = cfg.get("memoryBackend", "none")
    cfg["memoryBackend"] = "none"
    state.save_config(root, cfg)

    beads_dir = (cfg.get("memory", {}) or {}).get("beads", {}).get("dir", ".aegl/beads")
    if as_json:
        _emit({"ok": True, "backend": "none", "previous": previous,
               "dataPreserved": beads_dir})
        return 0
    print("AEGL Persistent Memory")
    print("----------------------")
    print(f"Backend: none (was: {previous})")
    print(f"Beads data preserved at: {beads_dir}")
    print("Nothing was deleted. Re-enable with: aegl memory setup beads")
    return 0


# --------------------------------------------------------------------------- #
# aegl bd ...  (environment-correct passthrough)
# --------------------------------------------------------------------------- #

def do_bd(root: Path, bd_args: list[str]) -> int:
    """Passthrough to the real ``bd`` with AEGL's environment applied.

    AEGL does not reinterpret lifecycle semantics here — it only sets
    ``BEADS_DIR`` and disables telemetry, then hands off to ``bd``.
    """
    if not bd_args:
        print("usage: aegl bd <bd arguments...>")
        print("example: aegl bd ready --json")
        return 2
    backend, _ = _backend(root, force_beads=True)
    return backend.runner.run_passthrough(list(bd_args))
