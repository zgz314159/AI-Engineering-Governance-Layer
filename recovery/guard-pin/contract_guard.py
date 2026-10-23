#!/usr/bin/env python3
"""Frozen-Contract write guard for the Hermes ``pre_tool_call`` hook (P0B-CLOSE).

Purpose
-------
Move the frozen Implementation Contract's path boundary from prompt-only prose into a
**machine-readable, fail-closed runtime check** on every write-class tool call, without
modifying Hermes core.

How it plugs in
---------------
The pinned Hermes (``vgit.af90026``) honours a shell hook on ``pre_tool_call``:

  * stdin  : JSON ``{hook_event_name, tool_name, tool_input, session_id, cwd, profile, extra}``
             (``agent/shell_hooks.py::_payload_fields``)
  * stdout : JSON ``{"action":"block","message":...}`` (or Claude-Code ``{"decision":"block",...}``)
  * exit   : ``0`` allow, ``2`` block (``BLOCK_EXIT_CODE``)
  * ``fail_closed: true`` makes spawn-error / timeout / unparseable stdout ALSO block.

Allow must print nothing: on a fail-closed blocking hook, a non-zero exit or non-JSON
stdout is itself treated as a block (``_evaluate_result``).

Contract source of truth
------------------------
The guard reads the *frozen* package, never a re-typed copy:

  * ``implementation-contract.json`` — ``allowed_paths`` / ``forbidden_paths`` decide
    ALLOW vs BLOCK. Project-relative, as the compiler requires.
  * ``project-context.json`` — ``path_classes`` supplies the human-facing class label
    (PRODUCTION_IMMUTABLE / BENCHMARK_SOURCE / TEST_SOURCE / RUNTIME_EPHEMERAL /
    EVIDENCE_OUTPUT / FORBIDDEN) and ``source_root`` the project root.
  * ``manifest.json`` — sha256 of every authored artifact; a mismatch reports
    ``CONTRACT_HASH_MISMATCH`` and the guard keeps failing closed.

Decision semantics (deliberately conservative)
----------------------------------------------
  * inside an allowed path            -> ALLOW
  * inside a forbidden path           -> BLOCK
  * inside the project but unlisted   -> BLOCK (unclassified => fail closed)
  * outside every declared writable root -> BLOCK, labelled OUT_OF_CONTRACT_SCOPE (fail closed)
  * a write verb with no resolvable target -> BLOCK (AMBIGUOUS_WRITE_TARGET)

Only *high-confidence* write intent is extracted from terminal commands (redirection,
tee, cp/mv/install, rm/rmdir, mkdir, touch, truncate, chmod/chown, dd of=, sed -i). A
command whose write target cannot be resolved is treated as ambiguous and blocked; a
genuinely read-only command carries no write verb at all and is allowed.

Any internal error exits 2 (fail closed).
"""

from __future__ import annotations

import json
import os
import re
import sys

GUARD_VERSION = "p0b-close-1"

_HERE = os.path.dirname(os.path.abspath(__file__))
# <projects>/Google-Android-Agent-Development-Stack/orchestration/hermes/evaluation_adapter
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(_HERE)))
_PROJECTS_ROOT = os.path.dirname(_REPO_ROOT)

DEFAULT_PACKAGE = os.path.join(
    _PROJECTS_ROOT, "KeepLab-Relay", "specs", "p0b-close-benchmarkability"
)
DEFAULT_SOURCE_ROOT = _PROJECTS_ROOT

CONTRACT_FILE = "implementation-contract.json"
CONTEXT_FILE = "project-context.json"
MANIFEST_FILE = "manifest.json"

BLOCK_ACTION = "block"

# Path classes this contract models (label vocabulary, from project-context.path_classes).
CLASS_FALLBACK_RULES = (
    (("/.state/", "/.runs/"), "RUNTIME_EPHEMERAL"),
    (("/reports/", "/evidence/", "/results/"), "EVIDENCE_OUTPUT"),
    (("/tests/",), "TEST_SOURCE"),
)
CLASS_FALLBACK_DEFAULT = "CONTRACT_ALLOWED_SOURCE"

# --------------------------------------------------------------------------- #
# terminal write-intent extraction (high-confidence only)
# --------------------------------------------------------------------------- #

_REDIRECT = re.compile(r"(?:^|[^0-9>])>{1,2}\|?\s*([^\s;&|<>()]+)")
_TEE = re.compile(r"(?:^|[;&|]\s*|&&\s*)tee\b([^\n;&|]*)")
_SED_INPLACE = re.compile(r"(?:^|[;&|]\s*|&&\s*)sed\b([^\n;&|]*)")
_DD_OF = re.compile(r"\bdd\b[^\n;&|]*?\bof=([^\s;&|]+)")
_VERBS = {
    # verb -> (write-target count; -1 = every argument)
    "cp": (1, False),
    "mv": (1, False),
    "install": (1, False),
    "rsync": (1, False),
    "rm": (-1, False),
    "rmdir": (-1, False),
    "mkdir": (-1, False),
    "touch": (-1, False),
    "truncate": (-1, False),
    "tee": (-1, False),
    # Metadata-only verbs: only an explicit slash-bearing target is treated as a write, so
    # `chmod +x script.sh` never produces a phantom unclassified target.
    "chmod": (-1, True),
    "chown": (-1, True),
    "chgrp": (-1, True),
}
_VERB_RE = re.compile(
    r"(?:^|[;&|]\s*|&&\s*|\|\s*)(python3?\s+\S+\s+)?(" + "|".join(sorted(_VERBS)) + r")\b([^\n;&|]*)"
)
_LEADING_CD = re.compile(r"^\s*cd\s+([^\s;&|]+)\s*(?:&&|;)")
_NUMERIC = re.compile(r"^[0-9]+([.][0-9]*)?[KMGkmg]?$")
_MODE_SPEC = re.compile(r"^[+-]?[rwxXstugo]+$")
_OWNER_SPEC = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*:[A-Za-z_][A-Za-z0-9_.-]*$")


def _strip_quotes(token: str) -> str:
    token = token.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        return token[1:-1]
    return token


def _shell_tokens(chunk: str) -> list:
    """Split a verb's argument chunk into tokens, dropping flags and shell noise."""
    out = []
    for raw in chunk.split():
        tok = _strip_quotes(raw)
        if not tok or tok.startswith("-"):
            continue
        if tok in ("|", "&&", ";", ">", ">>", "2>&1"):
            continue
        if _NUMERIC.match(tok) or _MODE_SPEC.match(tok) or _OWNER_SPEC.match(tok):
            continue  # a size, a permission mode or an owner spec is not a write target
        out.append(tok)
    return out


def _leading_cd_base(command: str, base_cwd: str) -> str:
    m = _LEADING_CD.match(command)
    if not m:
        return base_cwd
    target = _strip_quotes(m.group(1))
    if os.path.isabs(target):
        return target
    return os.path.normpath(os.path.join(base_cwd, target))


def terminal_write_candidates(command: str, base_cwd: str) -> tuple:
    """Return (candidates, saw_write_verb).

    ``candidates`` are raw target strings (absolute or relative to ``base_cwd``) that a
    high-confidence write pattern produced. Extraction is intentionally narrow: a command
    with no write verb and no redirection yields no candidates and is allowed.
    """
    candidates: list = []
    saw_verb = False

    for m in _REDIRECT.finditer(command):
        target = _strip_quotes(m.group(1))
        if target and target not in ("/dev/null", "&1", "&2"):
            candidates.append(target)
            saw_verb = True

    m = _DD_OF.search(command)
    if m:
        candidates.append(_strip_quotes(m.group(1)))
        saw_verb = True

    for m in _TEE.finditer(command):
        saw_verb = True
        candidates.extend(_shell_tokens(m.group(1)))

    for m in _SED_INPLACE.finditer(command):
        chunk = m.group(1)
        if "-i" not in chunk:
            continue
        saw_verb = True
        for tok in _shell_tokens(chunk):
            candidates.append(tok)

    for m in _VERB_RE.finditer(command):
        verb = m.group(2)
        saw_verb = True
        toks = _shell_tokens(m.group(3))
        count, require_slash = _VERBS[verb]
        if require_slash:
            toks = [t for t in toks if "/" in t]
        if not toks:
            continue
        candidates.extend(toks if count < 0 else toks[-count:])

    return candidates, saw_verb


# --------------------------------------------------------------------------- #
# path resolution / classification
# --------------------------------------------------------------------------- #

def _norm(path: str) -> str:
    return path.replace("\\", "/").rstrip("/")


_UNEXPANDED = re.compile(r"[$`]")


def _resolve_full(raw: str, base_cwd: str):
    """Absolute form of a candidate target, or None when it cannot be resolved at all.

    A token carrying an unexpanded shell variable or command substitution is NOT a literal
    path, so it is treated as unresolvable rather than guessed into a project location.
    """
    if not raw:
        return None
    raw = _strip_quotes(raw)
    if not raw:
        return None
    if _UNEXPANDED.search(raw):
        return None
    if os.path.isabs(raw):
        return os.path.normpath(raw)
    if not base_cwd:
        return None
    return os.path.normpath(os.path.join(base_cwd, raw))


def _rel_within(full: str, source_root: str):
    """Project-relative posix path when ``full`` is inside the project root, else None."""
    if full is None:
        return None
    root = os.path.normpath(source_root)
    if full == root:
        return ""
    if not full.startswith(root + os.sep):
        return None
    return _norm(os.path.relpath(full, root))


def resolve_within(raw: str, base_cwd: str, source_root: str):
    """Resolve ``raw`` to a project-relative posix path, or None when out of scope."""
    return _rel_within(_resolve_full(raw, base_cwd), source_root)


def _inside(rel_path: str, pattern: str) -> bool:
    """True when ``rel_path`` is the pattern itself or lies under it."""
    if rel_path == "":
        return False
    p = _norm(pattern)
    if not p:
        return False
    if rel_path == p:
        return True
    return rel_path.startswith(p + "/")


def _longest_label(rel_path: str, path_classes: dict) -> str:
    best = ""
    best_len = -1
    for label, patterns in (path_classes or {}).items():
        for pattern in patterns or []:
            if _inside(rel_path, pattern) and len(_norm(pattern)) > best_len:
                best = label
                best_len = len(_norm(pattern))
    return best


def _derived_label(rel_path: str) -> str:
    probe = "/" + _norm(rel_path) + "/"
    for needles, label in CLASS_FALLBACK_RULES:
        for needle in needles:
            if needle in probe:
                return label
    return CLASS_FALLBACK_DEFAULT


def classify(rel_path: str, allowed: list, forbidden: list, path_classes: dict) -> tuple:
    """Return (decision, class_label, matched_pattern)."""
    for pattern in forbidden:
        if _inside(rel_path, pattern):
            label = _longest_label(rel_path, path_classes) or "FORBIDDEN"
            return "BLOCK", label, pattern
    for pattern in allowed:
        if _inside(rel_path, pattern):
            label = _longest_label(rel_path, path_classes) or _derived_label(rel_path)
            return "ALLOW", label, pattern
    return "BLOCK", "UNCLASSIFIED_FAIL_CLOSED", ""


# --------------------------------------------------------------------------- #
# contract loading
# --------------------------------------------------------------------------- #

def load_contract(package_dir: str) -> dict:
    """Load the frozen package. Raises RuntimeError when it cannot be trusted."""
    contract_path = os.path.join(package_dir, CONTRACT_FILE)
    context_path = os.path.join(package_dir, CONTEXT_FILE)
    manifest_path = os.path.join(package_dir, MANIFEST_FILE)
    for path in (contract_path, context_path):
        if not os.path.isfile(path):
            raise RuntimeError("CONTRACT_MISSING: %s" % path)
    with open(contract_path, encoding="utf-8") as fh:
        contract = json.load(fh)
    with open(context_path, encoding="utf-8") as fh:
        context = json.load(fh)

    integrity = "MANIFEST_NOT_PRESENT"
    if os.path.isfile(manifest_path):
        try:
            import hashlib

            with open(manifest_path, encoding="utf-8") as fh:
                manifest = json.load(fh)
            bad = []
            for entry in manifest.get("entries", []):
                full = os.path.join(package_dir, entry["path"])
                if not os.path.isfile(full):
                    bad.append(entry["path"])
                    continue
                h = hashlib.sha256()
                with open(full, "rb") as fh:
                    h.update(fh.read())
                if h.hexdigest() != entry["sha256"]:
                    bad.append(entry["path"])
            integrity = "MANIFEST_OK" if not bad else "CONTRACT_HASH_MISMATCH:" + ",".join(bad)
        except Exception as exc:  # noqa: BLE001 - integrity failure must never raise upward
            integrity = "MANIFEST_UNREADABLE:%s" % exc

    return {
        "contract": contract,
        "context": context,
        "allowed": list(contract.get("allowed_paths", [])),
        "forbidden": list(contract.get("forbidden_paths", [])),
        "path_classes": dict(context.get("path_classes", {}) or {}),
        "source_root": context.get("source_root") or DEFAULT_SOURCE_ROOT,
        "integrity": integrity,
        "package_dir": os.path.abspath(package_dir),
        "contract_id": contract.get("contract_id"),
    }


# --------------------------------------------------------------------------- #
# evaluation
# --------------------------------------------------------------------------- #

WRITE_TOOLS = {"write_file": "path", "patch": "path"}


def evaluate(*, tool_name: str, tool_input: dict, cwd: str, loaded: dict) -> dict:
    """Return the guard's verdict dict: {decision, class, target, matched, reason}."""
    allowed = loaded["allowed"]
    forbidden = loaded["forbidden"]
    path_classes = loaded["path_classes"]
    source_root = loaded["source_root"]
    tool_input = tool_input or {}

    if loaded["integrity"].startswith("CONTRACT_HASH_MISMATCH"):
        return {
            "decision": "BLOCK",
            "class": "CONTRACT_INTEGRITY_FAILURE",
            "target": None,
            "matched": "",
            "reason": "frozen contract hash mismatch (%s); failing closed" % loaded["integrity"],
        }

    if tool_name in WRITE_TOOLS:
        key = WRITE_TOOLS[tool_name]
        target = tool_input.get(key)
        if not isinstance(target, str) or not target.strip():
            return {
                "decision": "BLOCK",
                "class": "AMBIGUOUS_WRITE_TARGET",
                "target": None,
                "matched": "",
                "reason": "%s called without a resolvable %r argument; failing closed" % (tool_name, key),
            }
        rel = resolve_within(target, cwd, source_root)
        if rel is None:
            return {"decision": "BLOCK", "class": "OUT_OF_CONTRACT_SCOPE", "target": target,
                    "matched": "", "reason": "write target is outside every declared writable root; failing closed"}
        if rel == "":
            return {"decision": "BLOCK", "class": "UNCLASSIFIED_FAIL_CLOSED", "target": target,
                    "matched": "", "reason": "target is the project root itself"}
        decision, label, matched = classify(rel, allowed, forbidden, path_classes)
        return {
            "decision": decision,
            "class": label,
            "target": rel,
            "matched": matched,
            "reason": ("allowed by %s" % matched) if decision == "ALLOW"
            else ("inside protected path %s" % matched if matched
                  else "project path not listed in the frozen contract; failing closed"),
        }

    if tool_name == "terminal":
        command = tool_input.get("command")
        if not isinstance(command, str) or not command.strip():
            return {"decision": "ALLOW", "class": "NO_COMMAND", "target": None, "matched": "",
                    "reason": "terminal call with no command string"}
        base_cwd = tool_input.get("workdir") or cwd or source_root
        if isinstance(base_cwd, str) and base_cwd:
            base_cwd = _leading_cd_base(command, base_cwd)
        candidates, saw_verb = terminal_write_candidates(command, base_cwd)
        if not saw_verb:
            return {"decision": "ALLOW", "class": "READ_ONLY_COMMAND", "target": None, "matched": "",
                    "reason": "no high-confidence write pattern detected"}
        resolved = []
        outside = 0
        for raw in candidates:
            full = _resolve_full(raw, base_cwd)
            if full is None:
                continue
            rel = _rel_within(full, source_root)
            if rel is None:
                outside += 1
                continue
            resolved.append((raw, rel))
        if not resolved:
            if outside:
                return {"decision": "BLOCK", "class": "OUT_OF_CONTRACT_SCOPE", "target": None,
                        "matched": "", "reason": "write target is outside every declared writable root; failing closed"}
            return {"decision": "BLOCK", "class": "AMBIGUOUS_WRITE_TARGET", "target": None,
                    "matched": "",
                    "reason": "write pattern detected but no resolvable target; failing closed"}
        worst = None
        for raw, rel in resolved:
            decision, label, matched = classify(rel, allowed, forbidden, path_classes)
            if decision == "BLOCK":
                worst = {"decision": "BLOCK", "class": label, "target": rel, "matched": matched,
                         "reason": ("inside protected path %s" % matched if matched
                                    else "project path not listed in the frozen contract; failing closed")}
                break
            if worst is None:
                worst = {"decision": "ALLOW", "class": label, "target": rel, "matched": matched,
                         "reason": "allowed by %s" % matched}
        return worst

    return {"decision": "ALLOW", "class": "NOT_A_WRITE_TOOL", "target": None, "matched": "",
            "reason": "tool %r is not covered by the write guard" % tool_name}


# --------------------------------------------------------------------------- #
# CLI (hook entry point)
# --------------------------------------------------------------------------- #

def _decision_log_path() -> str:
    _lib = os.path.join(_REPO_ROOT, "scripts", "lib")
    if _lib not in sys.path:
        sys.path.insert(0, _lib)
    import stack_paths  # noqa: PLC0415

    return str(stack_paths.guard_state_root() / "contract-guard-decisions.jsonl")


def _log(verdict: dict, payload: dict) -> None:
    """Best-effort audit trail. Never allowed to influence the verdict."""
    try:
        path = _decision_log_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        import time

        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "guard": GUARD_VERSION,
                "tool": payload.get("tool_name"),
                "decision": verdict["decision"],
                "class": verdict["class"],
                "target": verdict["target"],
                "matched": verdict.get("matched", ""),
                "reason": verdict["reason"],
            }, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001 - an audit failure must never block or unblock a write
        pass


def main(argv=None) -> int:
    package_dir = os.environ.get("HERMES_CONTRACT_PACKAGE") or DEFAULT_PACKAGE
    raw = ""
    try:
        raw = sys.stdin.read()
    except Exception:  # noqa: BLE001
        raw = ""
    payload = {}
    if raw.strip():
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {}
    if not isinstance(payload, dict):
        payload = {}

    tool_name = str(payload.get("tool_name") or "")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    cwd = payload.get("cwd") or ""
    if not isinstance(cwd, str):
        cwd = ""

    try:
        loaded = load_contract(package_dir)
        verdict = evaluate(tool_name=tool_name, tool_input=tool_input, cwd=cwd, loaded=loaded)
    except Exception as exc:  # noqa: BLE001 - fail closed, always
        verdict = {"decision": "BLOCK", "class": "GUARD_ERROR", "target": None, "matched": "",
                   "reason": "contract guard could not load the frozen contract: %s: %s"
                             % (type(exc).__name__, exc)}

    _log(verdict, payload)

    if verdict["decision"] == "BLOCK":
        message = "[P0B-CLOSE CONTRACT GUARD] BLOCK %s (%s) target=%s — %s" % (
            tool_name or "?", verdict["class"], verdict["target"], verdict["reason"])
        sys.stdout.write(json.dumps({"action": BLOCK_ACTION, "message": message}, ensure_ascii=False))
        sys.stdout.flush()
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
