#!/usr/bin/env python3
"""Read-only SYSTEM-E2E-004 guard-capture request-field extraction.

Reuses the existing reader's safe load rules (root-owned file, O_NOFOLLOW, bounded size,
task filter, line numbers, file hash) and the same frozen-command normalization. It emits
only fixed model-request fields plus command SHA. It never emits command text, full args,
raw IDs, credentials, or contract body.

The guard-capture row stores `request_args` from the broker's model REQUEST_INDEX.
The hook's executor/session context (cwd, session_id, ...) is not persisted by the guard
capture; this reader reports that absence explicitly instead of inferring it.
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from pathlib import Path

TASK = "SYSTEM-E2E-004"
ROOT = Path("/var/tmp/aegl-diag/SYSTEM-E2E-004")
PACKAGE = Path("/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/SYSTEM-E2E-004")
FIXED = (
    "workdir", "timeout", "background", "pty", "notify",
    "notify_on_complete", "watch_patterns", "heartbeat", "persist_on_release",
)
EXECUTOR_FIELDS = ("cwd", "session_id", "task", "tool_call_id")


def norm(text: str) -> str:
    return text.replace("\r\n", "\n").strip()


def load(name: str):
    try:
        fd = os.open(ROOT / name, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return [], {"current_state": "ABSENT"}
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fh.fileno())
        assert stat.S_ISREG(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022, \
            "UNTRUSTED_DIAG_FILE"
        assert st.st_size <= 16 * 1024 * 1024, "DIAG_FILE_TOO_LARGE"
        raw = fh.read(16 * 1024 * 1024 + 1)
        assert len(raw) <= 16 * 1024 * 1024, "DIAG_FILE_TOO_LARGE"
    rows = []
    invalid = 0
    for line_no, line in enumerate(raw.splitlines(), 1):
        try:
            entry = json.loads(line)
            assert isinstance(entry, dict)
            if entry.get("task") == TASK:
                rows.append((line_no, entry))
        except Exception:
            invalid += 1
    return rows, {
        "current_state": "PRESENT",
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "invalid_lines": invalid,
        "task_rows": len(rows),
    }


def _type_name(value) -> str:
    return type(value).__name__


def _safe_fixed(key: str, value):
    if key == "workdir":
        if isinstance(value, str):
            return {"present": True, "type": "str", "value": value}
        return {"present": True, "type": _type_name(value)}
    if key in ("background", "pty", "notify_on_complete", "persist_on_release"):
        if isinstance(value, bool):
            return {"present": True, "type": "bool", "value": value}
        return {"present": True, "type": _type_name(value)}
    if key in ("timeout", "heartbeat"):
        if isinstance(value, int) and not isinstance(value, bool):
            return {"present": True, "type": "int", "value": value}
        return {"present": True, "type": _type_name(value)}
    if key in ("notify", "watch_patterns"):
        if isinstance(value, bool):
            return {"present": True, "type": "bool", "value": value}
        if isinstance(value, list):
            return {
                "present": True,
                "type": "list",
                "length": len(value),
                "element_types": sorted({_type_name(item) for item in value}),
            }
        return {"present": True, "type": _type_name(value)}
    return {"present": True, "type": _type_name(value)}


def main() -> int:
    if os.geteuid() != 0:
        print(json.dumps({"task": TASK, "reader": "FAIL", "reason": "NOT_ROOT",
                          "side_effect": "none"}, sort_keys=True))
        return 2
    root_stat = ROOT.lstat()
    assert stat.S_ISDIR(root_stat.st_mode) and root_stat.st_uid == 0 \
        and not root_stat.st_mode & 0o022, "UNTRUSTED_DIAG_DIRECTORY"
    guards, file_meta = load("guard-capture.jsonl")
    expected = {}
    try:
        intent = json.loads((PACKAGE / "verification-intent.json").read_text(encoding="utf-8"))
        expected = {
            hashlib.sha256(norm(check["command"]).encode("utf-8")).hexdigest(): check["step"]
            for check in intent.get("cli_checks", [])
            if isinstance(check, dict) and isinstance(check.get("command"), str)
        }
    except Exception:
        expected = {}
    output = []
    for line_no, entry in guards:
        args = entry.get("request_args")
        args = args if isinstance(args, dict) else {}
        command = args.get("command")
        command_sha = hashlib.sha256(norm(command).encode("utf-8")).hexdigest() \
            if isinstance(command, str) else None
        model_args = {
            key: (_safe_fixed(key, args[key]) if key in args else {"present": False})
            for key in FIXED
        }
        executor_presence = {}
        for key in EXECUTOR_FIELDS:
            value = entry.get(key)
            executor_presence[key] = {
                "present": key in entry,
                "type": _type_name(value) if key in entry else None,
            }
        output.append({
            "line": line_no,
            "guard_rc": entry.get("rc") if type(entry.get("rc")) is int else None,
            "action": (entry.get("verdict") or {}).get("action")
            if isinstance(entry.get("verdict"), dict) else "OTHER",
            "recorded": entry.get("_recorded") is True,
            "request_matched": entry.get("request_matched") is True,
            "request_args_match": entry.get("request_args_match") is True,
            "error_present": bool(entry.get("error")),
            "refused_present": bool(entry.get("refused_reason")),
            "command_sha256": command_sha,
            "exact_frozen_command_match": expected.get(command_sha) if command_sha else None,
            "model_args": model_args,
            "model_args_source": "guard_capture.request_args (broker REQUEST_INDEX)",
            "executor_context": {
                "state": "NOT_RECORDED_IN_GUARD_CAPTURE",
                "present_top_level": executor_presence,
            },
        })
    print(json.dumps({
        "task": TASK,
        "guard_capture_file": file_meta,
        "frozen_command_steps": sorted(set(expected.values())),
        "request_fields": output,
        "note": (
            "Request fields come from the model request args. The guard-capture row does "
            "not persist executor-injected cwd/session_id, so they are reported as absent "
            "rather than reconstructed. Command text, full args, raw IDs and contract body "
            "are never emitted."
        ),
    }, ensure_ascii=False, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
