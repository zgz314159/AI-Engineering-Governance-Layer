#!/usr/bin/env python3
"""Read-only guard-capture request-field extraction.

Reuses the existing reader's safe load rules (root-owned file, O_NOFOLLOW, bounded size,
task filter, line numbers, file hash) and the same frozen-command normalization. It emits
only fixed model-request fields plus command SHA. It never emits command text, full args,
raw IDs, credentials, or contract body.

The guard-capture row stores `request_args` from the broker's model REQUEST_INDEX.
The hook's executor/session context (cwd, session_id, ...) is not persisted by the guard
capture; this reader reports that absence explicitly instead of inferring it.

With --task ID, reuse the same reader for an exact trusted registry binding. Without
arguments the historical SYSTEM-E2E-004 extraction remains unchanged. Command metadata
contains only fixed verbs and references to declared files, never command text.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
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
ARTIFACTS = ("implementation-contract.json", "project-context.json", "manifest.json", "READY.json",
             "PRODUCT.md", "requirements.md", "acceptance.md", "design.md", "DESIGN.md", "tasks.md",
             "verification-intent.json", "EXECUTOR-PROMPT.md")
VERBS = frozenset(("pwd", "ls", "find", "cat", "sed", "head", "tail", "grep", "rg", "test",
                   "sha256sum", "python", "python3", "git", "env", "stat", "echo", "printf",
                   "cd", "mkdir", "touch", "tee", "cp", "mv", "rm", "chmod", "bash"))


def bind_registered(task, *, registry=Path('/var/lib/aegl-model/registry.json'),
                    diag_root=Path('/var/tmp/aegl-diag'),
                    trusted_root=Path('/var/lib/aegl-model/trusted'), required_uid=0):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', task):
        raise ValueError('INVALID_TASK')
    def trusted(path, directory=False):
        st=path.lstat()
        if (not (stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode))
                or st.st_uid != required_uid or st.st_mode & 0o022):
            raise ValueError('UNTRUSTED_BINDING_PATH')
    trusted(registry.parent,True)
    trusted(registry)
    entry=json.loads(registry.read_text()).get(task)
    if not isinstance(entry,dict) or not isinstance(entry.get('contract_package'),str):
        raise ValueError('UNREGISTERED_TASK')
    package=Path(entry['contract_package'])
    parts=package.relative_to(trusted_root).parts
    if len(parts)!=4 or parts[1:3]!=('reports','contracts') or parts[3]!=task or '..' in parts:
        raise ValueError('CONTRACT_BINDING_MISMATCH')
    for path in (trusted_root,*[trusted_root.joinpath(*parts[:i]) for i in range(1,5)]):
        trusted(path,True)
    for name in ('verification-intent.json','project-context.json'):
        trusted(package/name)
    trusted(diag_root,True)
    trusted(diag_root/task,True)
    return diag_root/task,package


def command_metadata(command, package, context):
    """Lexical hints only, not shell semantics; no expansion, execution or raw output."""
    try:
        tokens=shlex.split(command) if isinstance(command,str) else []
    except ValueError:
        return {'state':'UNPARSEABLE'}
    refs=[]
    source_root=context.get('source_root','')
    for token in tokens:
        literal=token.removeprefix('./')
        for name in ARTIFACTS:
            location=None
            if literal==name:
                location='CWD_RELATIVE'
            elif token==str(package/name):
                location='CONTRACT_ABSOLUTE'
            elif token in ('$HERMES_CONTRACT_PACKAGE/'+name,'${HERMES_CONTRACT_PACKAGE}/'+name):
                location='CONTRACT_ENV'
            if location:
                refs.append({'artifact':name,'base':location})
        for i,item in enumerate(context.get('read_first',[])):
            path=item.get('path') if isinstance(item,dict) else None
            if isinstance(path,str) and (literal==path or (source_root and token==str(Path(source_root)/path))):
                refs.append({'read_first_index':i,'base':'SOURCE_ABSOLUTE' if os.path.isabs(token) else 'CWD_RELATIVE'})
    return {'known_shell_words':sorted(set(tokens)&VERBS),'declared_file_refs':refs}


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
    global TASK, ROOT, PACKAGE
    if os.geteuid() != 0:
        print(json.dumps({"task": TASK, "reader": "FAIL", "reason": "NOT_ROOT",
                          "side_effect": "none"}, sort_keys=True))
        return 2
    if len(sys.argv)>1:
        if len(sys.argv)!=3 or sys.argv[1]!='--task':
            raise ValueError('USAGE: --task REGISTERED_ID')
        TASK=sys.argv[2]
        ROOT,PACKAGE=bind_registered(TASK)
    root_stat = ROOT.lstat()
    assert stat.S_ISDIR(root_stat.st_mode) and root_stat.st_uid == 0 \
        and not root_stat.st_mode & 0o022, "UNTRUSTED_DIAG_DIRECTORY"
    guards, file_meta = load("guard-capture.jsonl")
    expected = {}
    context = {}
    try:
        intent = json.loads((PACKAGE / "verification-intent.json").read_text(encoding="utf-8"))
        expected = {
            hashlib.sha256(norm(check["command"]).encode("utf-8")).hexdigest(): check["step"]
            for check in intent.get("cli_checks", [])
            if isinstance(check, dict) and isinstance(check.get("command"), str)
        }
    except Exception:
        expected = {}
    try:
        context=json.loads((PACKAGE/'project-context.json').read_text())
    except (OSError,ValueError):
        pass
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
            "guard_decision": (entry.get("verdict") or {}).get("decision")
            if isinstance(entry.get("verdict"),dict) and entry['verdict'].get('decision') in ('ALLOW','BLOCK') else 'UNKNOWN',
            "recorded": entry.get("_recorded") is True,
            "request_matched": entry.get("request_matched") is True,
            "request_args_match": entry.get("request_args_match") is True,
            "error_present": bool(entry.get("error")),
            "refused_present": bool(entry.get("refused_reason")),
            "command_sha256": command_sha,
            "command_metadata": command_metadata(command, PACKAGE, context),
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
