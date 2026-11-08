#!/usr/bin/env python3
"""Consume the packaged synthetic upstream with the real OpenAI SDK.

Runs under the OpenAI SDK of the declared Hermes runtime environment and exercises the
wire protocol it actually uses: a complete JSON completion and a ``text/event-stream``
completion, with interleaved catalog probes. It never executes a returned command, never
contacts a real model and never reads a real credential (the API key is a literal dummy).

Every scenario request explicitly declares the ``terminal`` tool, as the real client does.
Auxiliary requests without that declaration must receive fixed text and must not advance
the scenario. Within a step, an assistant announcement with no result and an unrelated
tool result must both replay the same unfinished step.

Output is limited to fixed results, counts and error categories; response bodies,
commands and arguments are never printed.
"""

from __future__ import annotations

import argparse
import sys

FAIL_STAGE = "UNKNOWN"

TOOLS = [{
    "type": "function",
    "function": {
        "name": "terminal",
        "description": "run a fixed local fixture command",
        "parameters": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
    },
}]


def _fail(stage: str) -> "sys.NoReturn":
    global FAIL_STAGE
    FAIL_STAGE = stage
    raise AssertionError(stage)


def _tool_view(response) -> tuple[list[dict], str | None, str | None]:
    choice = response.choices[0]
    calls = []
    for call in choice.message.tool_calls or []:
        calls.append({"id": call.id, "name": call.function.name,
                      "arguments": call.function.arguments})
    return calls, choice.message.content, choice.finish_reason


def _stream_view(chunks) -> tuple[list[dict], str | None, str | None, int, int]:
    seen: dict[int, dict] = {}
    content = ""
    finish = None
    events = 0
    fragments = 0
    for chunk in chunks:
        events += 1
        if not chunk.choices:
            continue
        choice = chunk.choices[0]
        if choice.finish_reason:
            finish = choice.finish_reason
        delta = choice.delta
        if delta.content:
            content += delta.content
        for part in delta.tool_calls or []:
            slot = seen.setdefault(part.index, {"id": None, "name": None, "arguments": ""})
            if part.id:
                slot["id"] = part.id
            if part.function:
                if part.function.name:
                    slot["name"] = part.function.name
                if part.function.arguments:
                    slot["arguments"] += part.function.arguments
                    fragments += 1
    calls = [seen[index] for index in sorted(seen)]
    return calls, content or None, finish, events, fragments


def _assert_tool(calls: list[dict], call_id: str, command: str) -> None:
    if len(calls) != 1:
        _fail("tool_count")
    call = calls[0]
    if call["id"] != call_id or call["name"] != "terminal":
        _fail("tool_identity")
    if call["arguments"] != '{"command": %s}' % _json(command):
        _fail("tool_arguments")


def _assert_text(calls: list[dict], content: str | None, finish: str | None,
                 stage: str) -> None:
    if calls or content != "done" or finish != "stop":
        _fail(stage)


def _json(text: str) -> str:
    import json
    return json.dumps(text)


def _turn(client, messages, stream: bool, tools: bool = True):
    kwargs = {"model": "obs-check", "messages": messages, "stream": stream,
              "max_tokens": 16}
    if tools:
        kwargs["tools"] = TOOLS
    response = client.chat.completions.create(**kwargs)
    if stream:
        return _stream_view(response)
    calls, content, finish = _tool_view(response)
    return calls, content, finish, 1, 1


def _announcement(call_id: str, arguments: str) -> dict:
    return {"role": "assistant", "content": None, "tool_calls": [{
        "id": call_id, "type": "function",
        "function": {"name": "terminal", "arguments": arguments}}]}


def _conversation(client, block_path: str, stream: bool) -> dict:
    counts = {"probe": 0, "replay": 0, "announcement": 0, "unrelated": 0,
              "steps": 0, "fragments": 0, "aux": 0}
    before = client.models.list()
    if [item.id for item in before.data] != ["obs-check"]:
        _fail("models_probe")
    counts["probe"] += 1

    messages = [{"role": "user", "content": "go"}]

    # Auxiliary request without a tool declaration: fixed text, scenario not advanced.
    calls, content, finish, _events, _fragments = _turn(
        client, messages, stream, tools=False)
    _assert_text(calls, content, finish, "auxiliary_text")
    counts["aux"] += 1

    expected = [("obs-ok", "printf OBS_OK"),
                ("obs-fail", "/usr/bin/false"),
                ("obs-block", "printf blocked > %s" % block_path)]
    for index, (call_id, command) in enumerate(expected):
        calls, _content, finish, _events, fragments = _turn(client, messages, stream)
        if finish != "tool_calls":
            _fail("tool_finish")
        _assert_tool(calls, call_id, command)
        counts["steps"] += 1
        counts["fragments"] += fragments

        # The same conversation must replay the same step, never skip one.
        again, _c, again_finish, _e, _f = _turn(client, messages, stream)
        if again_finish != "tool_calls":
            _fail("repeat_finish")
        _assert_tool(again, call_id, command)
        counts["replay"] += 1

        # An assistant announcement with no result must not advance the step.
        announcement = _announcement(call_id, calls[0]["arguments"])
        only, _c, only_finish, _e, _f = _turn(client, messages + [announcement], stream)
        if only_finish != "tool_calls":
            _fail("announcement_finish")
        _assert_tool(only, call_id, command)
        counts["announcement"] += 1

        # An unrelated tool result must not advance the step either.
        unrelated = messages + [announcement, {
            "role": "tool", "tool_call_id": call_id + "-unrelated", "content": "ok"}]
        other, _c, other_finish, _e, _f = _turn(client, unrelated, stream)
        if other_finish != "tool_calls":
            _fail("unrelated_finish")
        _assert_tool(other, call_id, command)
        counts["unrelated"] += 1

        if index == 0:
            probe = client.models.list()
            if not probe.data:
                _fail("interleaved_probe")
            counts["probe"] += 1
        messages = messages + [
            _announcement(call_id, calls[0]["arguments"]),
            {"role": "tool", "tool_call_id": call_id, "content": "ok"},
        ]

    calls, content, finish, _events, _fragments = _turn(client, messages, stream)
    _assert_text(calls, content, finish, "final_text")
    counts["final_text"] = 1
    return counts


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--block-path", required=True)
    ap.add_argument("--ca", default="")
    args = ap.parse_args(argv)

    try:
        from openai import OpenAI
    except Exception:
        print("PROTOCOL FAIL category=sdk_import")
        return 1

    try:
        import httpx
        # Loopback only: an ambient proxy variable must not intercept the local request.
        http_client = httpx.Client(verify=args.ca or True, trust_env=False, timeout=10.0)
        client = OpenAI(base_url=args.base_url, api_key="obs-dummy",
                        max_retries=0, timeout=10.0, http_client=http_client)
    except Exception:
        print("PROTOCOL FAIL category=sdk_client")
        return 1

    try:
        json_counts = _conversation(client, args.block_path, stream=False)
    except AssertionError as exc:
        print("PROTOCOL FAIL category=json_%s" % exc)
        return 1
    except Exception:
        print("PROTOCOL FAIL category=json_transport")
        return 1

    try:
        sse_counts = _conversation(client, args.block_path, stream=True)
    except AssertionError as exc:
        print("PROTOCOL FAIL category=sse_%s" % exc)
        return 1
    except Exception:
        print("PROTOCOL FAIL category=sse_transport")
        return 1

    if sse_counts["fragments"] <= sse_counts["steps"]:
        print("PROTOCOL FAIL category=arguments_not_fragmented")
        return 1
    print("PROTOCOL json_steps=%d sse_steps=%d fragments=%d probes=%d repeats=%d "
          "aux=%d announcement_only=%d unrelated_results=%d final_text=1"
          % (json_counts["steps"], sse_counts["steps"], sse_counts["fragments"],
             json_counts["probe"] + sse_counts["probe"],
             json_counts["replay"] + sse_counts["replay"],
             json_counts["aux"] + sse_counts["aux"],
             json_counts["announcement"] + sse_counts["announcement"],
             json_counts["unrelated"] + sse_counts["unrelated"]))
    print("PROTOCOL ok=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
