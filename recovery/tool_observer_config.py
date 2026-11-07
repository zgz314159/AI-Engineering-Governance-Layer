#!/usr/bin/env python3
"""Exact task-local hook wiring: install the diagnostic observers, then verify the
config + allowlist are exactly the approved event+command set.

OBSERVER-ONLY. The guard entry (matcher/fail_closed/command) is preserved verbatim.
No schema, no config switch, no template framework; a line-based edit of the task-local
copy only.

    tool_observer_config.py install <config> --pre-command CMD --post-command CMD
    tool_observer_config.py verify  <config> <allowlist> --guard-command CMD \
        --pre-command CMD --post-command CMD --diagnostics 0|1

Exit 0 = exact wiring, 1 = mismatch/missing/duplicate/extra.
"""

from __future__ import annotations

import argparse
import json
import sys

INDENT_EVENT = "  "
INDENT_FIELD = "      "


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def _block_range(lines, event):
    start = None
    for i, line in enumerate(lines):
        if line.startswith(INDENT_EVENT) and not line.startswith("    ") and line.rstrip() == INDENT_EVENT + event + ":":
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        line = lines[j]
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= 2:
            end = j
            break
    return start, end


def _split_entries(block_lines):
    entries = []
    current = None
    for line in block_lines:
        if line.strip().startswith("- command:"):
            if current is not None:
                entries.append(current)
            current = [line]
        elif current is not None:
            current.append(line)
    if current is not None:
        entries.append(current)
    parsed = []
    for entry in entries:
        data = {"command": "", "matcher": None, "fail_closed": None, "timeout": None}
        for line in entry:
            stripped = line.strip()
            if stripped.startswith("- command:"):
                data["command"] = _unquote(stripped.split(":", 1)[1])
            elif stripped.startswith("matcher:"):
                data["matcher"] = _unquote(stripped.split(":", 1)[1])
            elif stripped.startswith("fail_closed:"):
                data["fail_closed"] = stripped.split(":", 1)[1].strip().lower() in ("true", "yes", "1")
            elif stripped.startswith("timeout:"):
                try:
                    data["timeout"] = int(stripped.split(":", 1)[1].strip())
                except ValueError:
                    data["timeout"] = None
        parsed.append({"lines": entry, "data": data})
    return parsed


def _entry_lines(command, matcher=None, fail_closed=None, timeout=None):
    out = ["    - command: '%s'" % command]
    if matcher is not None:
        out.append("      matcher: '%s'" % matcher)
    if fail_closed is not None:
        out.append("      fail_closed: %s" % ("true" if fail_closed else "false"))
    if timeout is not None:
        out.append("      timeout: %d" % timeout)
    return out


def _is_observer(command: str) -> bool:
    return "tool_event_client.py" in command


def install(config_path, pre_command, post_command):
    with open(config_path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    # post first: its replacement does not move the pre block above it
    post_range = _block_range(lines, "post_tool_call")
    replacement = ["  post_tool_call:"] + _entry_lines(post_command, matcher=None, fail_closed=False, timeout=1)
    if post_range is None:
        pre_range = _block_range(lines, "pre_tool_call")
        if pre_range is None:
            print("HOOK_CONFIG_ERROR missing pre_tool_call block", file=sys.stderr)
            return 1
        insert_at = pre_range[1]
        lines[insert_at:insert_at] = replacement
    else:
        lines[post_range[0]:post_range[1]] = replacement

    pre_range = _block_range(lines, "pre_tool_call")
    if pre_range is None:
        print("HOOK_CONFIG_ERROR missing pre_tool_call block", file=sys.stderr)
        return 1
    start, end = pre_range
    entries = _split_entries(lines[start + 1:end])
    kept = [e for e in entries if not _is_observer(e["data"]["command"])]
    if not kept:
        print("HOOK_CONFIG_ERROR pre_tool_call guard entry missing", file=sys.stderr)
        return 1
    new_block = []
    for entry in kept:
        new_block.extend(entry["lines"])
    new_block.extend(_entry_lines(pre_command, matcher=r".*", fail_closed=False, timeout=1))
    lines[start + 1:end] = new_block

    with open(config_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines).rstrip() + "\n")
    print("HOOK_CONFIG_INSTALLED event=pre_tool_call,post_tool_call")
    return 0


def _load_entries(config_path):
    with open(config_path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    result = {}
    for event in ("pre_tool_call", "post_tool_call"):
        block = _block_range(lines, event)
        if block is None:
            result[event] = []
        else:
            result[event] = [e["data"] for e in _split_entries(lines[block[0] + 1:block[1]])]
    return result


def verify(config_path, allowlist_path, guard_command, pre_command, post_command, diagnostics):
    errors = []
    entries = _load_entries(config_path)

    pre = entries["pre_tool_call"]
    guards = [e for e in pre if e["command"] == guard_command]
    observers = [e for e in pre if e["command"] == pre_command]
    if len(guards) != 1:
        errors.append("pre_tool_call guard count %d != 1" % len(guards))
    elif guards[0]["matcher"] != "write_file|patch|terminal":
        errors.append("guard matcher is %r" % guards[0]["matcher"])
    elif guards[0]["fail_closed"] is not True:
        errors.append("guard fail_closed is not true")
    if diagnostics:
        if len(observers) != 1:
            errors.append("pre observer count %d != 1" % len(observers))
        else:
            obs = observers[0]
            if obs["matcher"] != ".*":
                errors.append("pre observer matcher is %r" % obs["matcher"])
            if obs["fail_closed"] is not False:
                errors.append("pre observer fail_closed is not false")
            if obs["timeout"] != 1:
                errors.append("pre observer timeout is %r" % obs["timeout"])
        if len(pre) != 2:
            errors.append("pre_tool_call has %d entries, expected 2" % len(pre))
        post = entries["post_tool_call"]
        if len(post) != 1 or post[0]["command"] != post_command:
            errors.append("post_tool_call must be exactly one observer entry")
        elif post[0]["fail_closed"] not in (None, False):
            errors.append("post observer fail_closed is not false")
        elif post[0]["timeout"] != 1:
            errors.append("post observer timeout is %r" % post[0]["timeout"])
        elif post[0]["matcher"] not in (None, ".*"):
            errors.append("post observer matcher is %r" % post[0]["matcher"])
    else:
        if observers:
            errors.append("non-diagnostic config has an observer entry")
        if len(pre) != 1:
            errors.append("pre_tool_call has %d entries, expected 1" % len(pre))

    try:
        with open(allowlist_path, encoding="utf-8") as fh:
            approvals = json.load(fh).get("approvals")
    except Exception as exc:  # noqa: BLE001
        errors.append("allowlist unreadable: %s" % type(exc).__name__)
        approvals = []
    if not isinstance(approvals, list):
        errors.append("allowlist approvals missing")
        approvals = []
    pairs = [(e.get("event"), e.get("command")) for e in approvals if isinstance(e, dict)]
    expected = [("pre_tool_call", guard_command)]
    if diagnostics:
        expected += [("pre_tool_call", pre_command), ("post_tool_call", post_command)]
    if len(pairs) != len(expected):
        errors.append("allowlist count %d != %d" % (len(pairs), len(expected)))
    for pair in expected:
        if pairs.count(pair) != 1:
            errors.append("allowlist pair missing/duplicated: %s" % (pair[0],))
    for pair in pairs:
        if pair not in expected:
            errors.append("allowlist has an extra approval: %s" % (pair[0],))

    if errors:
        for error in errors:
            print("HOOK_WIRING_ERROR %s" % error, file=sys.stderr)
        return 1
    print("HOOK_WIRING_OK diagnostics=%d approvals=%d" % (diagnostics, len(expected)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    ins = sub.add_parser("install")
    ins.add_argument("config")
    ins.add_argument("--pre-command", required=True)
    ins.add_argument("--post-command", required=True)
    ver = sub.add_parser("verify")
    ver.add_argument("config")
    ver.add_argument("allowlist")
    ver.add_argument("--guard-command", required=True)
    ver.add_argument("--pre-command", required=True)
    ver.add_argument("--post-command", required=True)
    ver.add_argument("--diagnostics", choices=("0", "1"), required=True)
    args = ap.parse_args(argv)
    if args.mode == "install":
        return install(args.config, args.pre_command, args.post_command)
    return verify(args.config, args.allowlist, args.guard_command, args.pre_command,
                  args.post_command, args.diagnostics == "1")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
