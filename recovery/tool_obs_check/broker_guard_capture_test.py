#!/usr/bin/env python3
"""Round-trip through the packaged broker: /guard -> guard_capture.record -> file.

The broker (_handle_guard), guard_capture.run_guard/record and the assertion are the
shipped package code. Only the guard and the runner are fixtures here:
  * runner: ["/usr/bin/env"] (ordinary-user test; the root check uses the fixed
    unprivileged runner);
  * guard: a local script that prints block/allow and exits 2/0.
The evidence directory is a fresh temp dir; the AI identity used for the evidence trust
check is supplied by the caller and is not the directory owner. Imports are isolated to
the supplied package bin directory (python -I, empty PYTHONPATH); the script asserts the
loaded model_broker and guard_capture files live there.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys

sys.dont_write_bytecode = True


def _main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package-bin", required=True)
    ap.add_argument("--guard", required=True)
    ap.add_argument("--evidence", required=True)
    ap.add_argument("--task", required=True)
    ap.add_argument("--call-id", required=True)
    ap.add_argument("--target-basename", required=True)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--diag", required=True)
    ap.add_argument("--ai-uid", type=int, required=True)
    ap.add_argument("--ai-gid", type=int, required=True)
    ap.add_argument("--mismatch", action="store_true")
    args = ap.parse_args(argv)

    pkg = os.path.realpath(args.package_bin)
    sys.path.insert(0, pkg)
    import model_broker
    import guard_capture

    for module in (model_broker, guard_capture):
        path = os.path.realpath(module.__file__)
        if not path.startswith(pkg + os.sep):
            print("BROKER_GUARD=FAIL reason=module_outside_package")
            return 1

    target = os.path.join(os.path.realpath(args.workdir), args.target_basename)
    command = "sh -c 'printf blocked > %s'" % target
    payload_command = command + " ; true" if args.mismatch else command
    response = {
        "choices": [{
            "message": {
                "tool_calls": [{
                    "id": args.call_id,
                    "type": "function",
                    "function": {"name": "terminal",
                                 "arguments": json.dumps({"command": command})},
                }],
            },
        }],
    }
    model_broker.REQUEST_INDEX.clear()
    model_broker._index_requests(json.dumps(response).encode())

    os.environ.update({
        "AEGL_GUARD_PATH": args.guard,
        "AEGL_GUARD_RUNNER": json.dumps(["/usr/bin/env"]),
        "AEGL_GUARD_EVIDENCE": args.evidence,
        "AEGL_GUARD_AI_UID": str(args.ai_uid),
        "AEGL_GUARD_AI_GID": str(args.ai_gid),
        "AEGL_TASK": args.task,
        "AEGL_DIAG_DIR": args.diag,
    })
    payload = {
        "tool_name": "terminal",
        "tool_call_id": args.call_id,
        "tool_input": {"command": payload_command},
    }
    left, right = socket.socketpair()
    try:
        model_broker._handle_guard(left, json.dumps(payload).encode())
        left.close()
        data = right.recv(1 << 20)
    finally:
        left.close()
        right.close()

    _head, _sep, body = data.partition(b"\r\n\r\n")
    try:
        result = json.loads(body.decode("utf-8"))
    except ValueError:
        print("BROKER_GUARD=FAIL reason=bad_response")
        return 1
    if result.get("evidence") != "appended":
        print("BROKER_GUARD=FAIL reason=not_appended")
        return 1
    if not os.path.isfile(os.path.join(args.evidence, "guard-capture.jsonl")):
        print("BROKER_GUARD=FAIL reason=no_file")
        return 1
    print("BROKER_GUARD=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
