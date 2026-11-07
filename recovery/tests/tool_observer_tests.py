"""Targeted tests for the minimal model/tool observation patch.

No model, no network beyond a local fake upstream, no host mutation.
The hook-path test drives the REAL pinned Hermes shell-hook registration and invocation
(agent.shell_hooks.register_from_config + hermes_cli.lifecycle.invoke_hook) in a
subprocess, then inspects the controller diagnostic sink. It supplies the post-tool
result itself: it proves registration, serialization, callback order and transport, not
a real tool executor or an actual command result. Guard records are trusted pre-call
authorization records, not proof that a tool executed successfully.
"""

from __future__ import annotations

import glob
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RECOVERY = os.path.dirname(HERE)
AEGL = os.path.dirname(RECOVERY)
sys.path.insert(0, RECOVERY)

import model_broker  # noqa: E402
import tool_observer_config  # noqa: E402

BROKER = os.path.join(RECOVERY, "model_broker.py")
CLIENT = os.path.join(RECOVERY, "tool_event_client.py")
HERMES_HOME = os.path.expanduser("~/.hermes/hermes-agent")

SECRET_ARGS = "SECRET_ARGS_9Q7"
SECRET_OUT = "SECRET_OUT_4Z2"
SECRET_ERR = "SECRET_ERR_1X8"


class FakeUpstream(http.server.ThreadingHTTPServer):
    payload = b"{}"
    content_type = "application/json"

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _Handler)


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        self.rfile.read(length)
        body = self.server.payload
        self.send_response(200)
        self.send_header("Content-Type", self.server.content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def _post(sock_path, path, obj, timeout=5.0):
    body = json.dumps(obj).encode("utf-8")
    request = ("POST %s HTTP/1.1\r\nHost: test\r\nContent-Length: %d\r\n"
               "Connection: close\r\n\r\n" % (path, len(body))).encode("utf-8") + body
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(sock_path)
        sock.sendall(request)
        data = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    finally:
        sock.close()
    head, _, response = data.partition(b"\r\n\r\n")
    return head, response


class BrokerFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="obs-test-", dir="/var/tmp")
        self.sock = os.path.join(self.tmp, "broker.sock")
        self.diag = os.path.join(self.tmp, "diag")
        os.makedirs(self.diag)
        self.cred = os.path.join(self.tmp, "cred")
        with open(self.cred, "w", encoding="utf-8") as fh:
            fh.write("dummy")
        self.upstream = FakeUpstream()
        threading.Thread(target=self.upstream.serve_forever, daemon=True).start()
        env = dict(os.environ, AEGL_DIAG_DIR=self.diag, AEGL_TASK="TEST-006")
        self.proc = subprocess.Popen(
            [sys.executable, BROKER, "serve", "--socket", self.sock,
             "--upstream", "http://127.0.0.1:%d" % self.upstream.server_address[1],
             "--credential-file", self.cred],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for _ in range(200):
            if os.path.exists(self.sock):
                break
            time.sleep(0.02)
        if not os.path.exists(self.sock):
            self.proc.terminate()
            try:
                _out, err = self.proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                _out, err = self.proc.communicate()
            self.fail("broker did not start: %s" % err)

    def tearDown(self):
        if self.proc is not None:
            self.proc.terminate()
        try:
            if self.proc is not None:
                self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        if self.proc is not None:
            for stream in (self.proc.stdout, self.proc.stderr):
                if stream is not None:
                    stream.close()
        self.upstream.shutdown()
        self.upstream.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def events(self):
        path = os.path.join(self.diag, "events.jsonl")
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def phases(self, *names):
        return [e for e in self.events() if e.get("phase") in names]

    def model_request(self, payload, content_type="application/json"):
        self.upstream.payload = payload
        self.upstream.content_type = content_type
        return _post(self.sock, "/v1/chat/completions", {"model": "m", "stream": False, "messages": []})

    def index_call(self, call_id, name="terminal"):
        body = json.dumps({"choices": [{"message": {"tool_calls": [
            {"id": call_id, "function": {"name": name, "arguments": "{}"}}]},
            "finish_reason": "tool_calls"}]}).encode()
        self.model_request(body)


class SummaryTests(unittest.TestCase):
    def summary(self, obj):
        return model_broker._index_requests(json.dumps(obj).encode("utf-8"))

    def test_json_tool_text_reasoning_empty_mixed(self):
        tool = self.summary({"choices": [{"message": {"tool_calls": [
            {"id": "c-tool", "function": {"name": "terminal", "arguments": "{}"}}]},
            "finish_reason": "tool_calls"}]})
        self.assertIn("tool_call", tool["flags"])
        self.assertEqual(tool["finish"], "TOOL_CALLS")
        self.assertEqual([c["seq"] for c in tool["calls"]], [tool["calls"][0]["seq"]])

        text = self.summary({"choices": [{"message": {"content": "SECRET"}, "finish_reason": "stop"}]})
        self.assertIn("text", text["flags"])
        self.assertNotIn(SECRET_ARGS, model_broker._summary_arg(text))

        reasoning = self.summary({"choices": [{"message": {"reasoning_content": "SECRET"}, "finish_reason": "stop"}]})
        self.assertIn("reasoning", reasoning["flags"])
        self.assertIn("reasoning_only", reasoning["flags"])

        empty = self.summary({"choices": [{"message": {}, "finish_reason": "stop"}]})
        self.assertIn("empty", empty["flags"])

        mixed = self.summary({"choices": [{"message": {
            "content": "text", "reasoning_content": "reason",
            "tool_calls": [{"id": "c-mix", "function": {"name": "read_file", "arguments": "{}"}}]},
            "finish_reason": "weird"}]})
        self.assertTrue({"tool_call", "text", "reasoning"} <= mixed["flags"])
        self.assertEqual(mixed["finish"], "OTHER")

        malformed = model_broker._index_requests(b"not-json")
        self.assertIn("parse_error", malformed["flags"])

    def test_sse_mixed_and_unknown_finish(self):
        sse = (b'data: {"choices":[{"delta":{"reasoning_content":"r"},"index":0}]}\n\n'
               b'data: {"choices":[{"delta":{"content":"t"},"index":0}]}\n\n'
               b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c-sse",'
               b'"function":{"name":"terminal","arguments":"{}"}}]},"index":0}]}\n\n'
               b'data: {"choices":[{"delta":{},"finish_reason":"made-up","index":0}]}\n\n'
               b'data: [DONE]\n')
        summary = model_broker._index_requests(sse)
        self.assertTrue({"tool_call", "text", "reasoning"} <= summary["flags"])
        self.assertEqual(summary["finish"], "OTHER")
        self.assertEqual(len(summary["calls"]), 1)


class BrokerObservationTests(BrokerFixture):
    def test_model_response_and_tool_sequence(self):
        body = json.dumps({"choices": [{"message": {"content": "hello", "tool_calls": [
            {"id": "call-abc", "function": {"name": "terminal",
                                            "arguments": json.dumps({"command": SECRET_ARGS})}}]},
            "finish_reason": "tool_calls"}]}).encode()
        _head, response = self.model_request(body)
        self.assertEqual(response, body)
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "call-abc", "tool_name": "terminal",
                                        "status": "ok", "error_type": ""})
        _post(self.sock, "/tool-event", {"hook_event_name": "post_tool_call",
                                        "tool_call_id": "call-abc", "tool_name": "terminal",
                                        "status": "ok", "duration_ms": 7, "exit_code": 0})
        events = self.phases("model_response", "model_tool_request",
                             "tool_pre_observe", "tool_post_observe")
        self.assertEqual([e["phase"] for e in events],
                         ["model_response", "model_tool_request",
                          "tool_pre_observe", "tool_post_observe"])
        self.assertLess(events[0]["mono_ns"], events[1]["mono_ns"])
        self.assertLess(events[2]["mono_ns"], events[3]["mono_ns"])
        self.assertIn("tool_call", events[0]["arg"])
        self.assertIn("finish=TOOL_CALLS", events[0]["arg"])
        self.assertIn("tool=terminal", events[1]["arg"])
        self.assertIn("corr=1", events[2]["arg"])
        self.assertIn("exit=0", events[3]["arg"])
        self.assertIn("trust=diagnostic", events[2]["arg"])
        with open(os.path.join(self.diag, "events.jsonl"), encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn(SECRET_ARGS, raw)
        self.assertNotIn("call-abc", raw)
        self.assertNotIn(SECRET_OUT, raw)

    def test_broker_console_has_no_secret(self):
        body = json.dumps({"choices": [{"message": {"content": SECRET_OUT, "tool_calls": [
            {"id": "call-secret", "function": {"name": "terminal",
                                               "arguments": json.dumps({"command": SECRET_ARGS})}}]},
            "finish_reason": "tool_calls"}]}).encode()
        self.model_request(body)
        self.proc.terminate()
        out, err = self.proc.communicate(timeout=5)
        self.assertNotIn(SECRET_OUT, (out or "") + (err or ""))
        self.assertNotIn(SECRET_ARGS, (out or "") + (err or ""))
        self.proc = None

    def test_uncorrelated_events_are_rejected_not_recorded(self):
        payload = {"hook_event_name": "post_tool_call", "tool_call_id": "missing",
                   "tool_name": "read_file", "status": "weird", "error_type": "Nope"}
        _post(self.sock, "/tool-event", payload)
        _post(self.sock, "/tool-event", payload)
        self.assertEqual(self.phases("tool_post_observe"), [])
        self.assertEqual(len(self.phases("tool_event_rejected")), 2)
        self.assertEqual(self.phases("tool_event_duplicate"), [])
        with open(os.path.join(self.diag, "events.jsonl"), encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("missing", raw)

    def test_empty_or_wrong_name_never_correlates(self):
        self.index_call("call-name", "terminal")
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "call-name", "tool_name": "",
                                        "status": "ok"})
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "call-name", "tool_name": "WRONG_SECRET_NAME",
                                        "status": "ok"})
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "", "tool_name": "terminal",
                                        "status": "ok"})
        self.assertEqual(self.phases("tool_pre_observe"), [])
        rejected = self.phases("tool_event_rejected")
        reasons = sorted(e["arg"].split("reason=")[-1] for e in rejected)
        self.assertEqual(reasons, ["empty_reported_name", "name_mismatch", "no_call_id"])
        with open(os.path.join(self.diag, "events.jsonl"), encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("WRONG_SECRET_NAME", raw)
        self.assertNotIn("call-name", raw)

    def test_wrong_name_first_then_correct_pre_post_records(self):
        self.index_call("call-order", "terminal")
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "call-order", "tool_name": "read_file",
                                        "status": "ok"})
        self.assertEqual(self.phases("tool_pre_observe"), [])
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "call-order", "tool_name": "terminal",
                                        "status": "ok"})
        _post(self.sock, "/tool-event", {"hook_event_name": "post_tool_call",
                                        "tool_call_id": "call-order", "tool_name": "terminal",
                                        "status": "ok", "duration_ms": 5, "exit_code": 0})
        pre = self.phases("tool_pre_observe")
        post = self.phases("tool_post_observe")
        self.assertEqual(len(pre), 1)
        self.assertEqual(len(post), 1)
        self.assertIn("corr=1", pre[0]["arg"])
        self.assertIn("corr=1", post[0]["arg"])
        self.assertEqual(self.phases("tool_event_duplicate"), [])

    def test_invalid_event_does_not_occupy_dedup(self):
        head, _ = _post(self.sock, "/tool-event",
                        {"hook_event_name": "bogus", "tool_call_id": "x", "tool_name": "terminal"})
        self.assertTrue(head.startswith(b"HTTP/1.1 400"))
        self.index_call("call-evt", "terminal")
        payload = {"hook_event_name": "pre_tool_call", "tool_call_id": "call-evt",
                   "tool_name": "terminal", "status": "ok"}
        _post(self.sock, "/tool-event", payload)
        _post(self.sock, "/tool-event", payload)
        self.assertEqual(len(self.phases("tool_pre_observe")), 1)
        self.assertEqual(len(self.phases("tool_event_duplicate")), 1)

    def test_unknown_tool_name_exact_match_maps_other(self):
        self.index_call("call-unknown", "weird_tool")
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "call-unknown", "tool_name": "weird_tool",
                                        "status": "ok"})
        _post(self.sock, "/tool-event", {"hook_event_name": "post_tool_call",
                                        "tool_call_id": "call-unknown", "tool_name": "weird_tool",
                                        "status": "error", "error_type": "Nope"})
        pre = self.phases("tool_pre_observe")
        post = self.phases("tool_post_observe")
        self.assertEqual(len(pre), 1)
        self.assertEqual(len(post), 1)
        self.assertIn("corr=1", pre[0]["arg"])
        self.assertIn("tool=other", pre[0]["arg"])
        self.assertIn("err=OTHER", post[0]["arg"])

    def test_missing_post_leaves_pre_only(self):
        self.index_call("call-miss", "read_file")
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "call-miss", "tool_name": "read_file",
                                        "status": "ok"})
        self.assertEqual(len(self.phases("tool_pre_observe")), 1)
        self.assertEqual(self.phases("tool_post_observe"), [])

    def test_legitimate_duplicate_is_flagged(self):
        self.index_call("call-dup", "terminal")
        payload = {"hook_event_name": "post_tool_call", "tool_call_id": "call-dup",
                   "tool_name": "terminal", "status": "ok", "duration_ms": 3, "exit_code": 0}
        _post(self.sock, "/tool-event", payload)
        _post(self.sock, "/tool-event", payload)
        self.assertEqual(len(self.phases("tool_post_observe")), 1)
        self.assertEqual(len(self.phases("tool_event_duplicate")), 1)

    def test_model_text_reasoning_empty_malformed(self):
        bodies = {
            "text": (json.dumps({"choices": [{"message": {"content": "x"}, "finish_reason": "stop"}]}).encode(),
                     "flags=text"),
            "reasoning": (json.dumps({"choices": [{"message": {"reasoning_content": "r"}, "finish_reason": "stop"}]}).encode(),
                          "reasoning_only"),
            "empty": (json.dumps({"choices": [{"message": {}, "finish_reason": "length"}]}).encode(),
                      "flags=empty"),
            "malformed": (b"not-json-at-all", "parse_error"),
        }
        for name, (body, marker) in bodies.items():
            self.model_request(body)
            events = [e for e in self.events() if e.get("phase") == "model_response"]
            self.assertIn(marker, events[-1]["arg"], name)

    def test_sink_survives_run_dir_removal(self):
        run_dir = os.path.join(self.tmp, "run")
        os.makedirs(run_dir)
        with open(os.path.join(run_dir, "session.db"), "w", encoding="utf-8") as fh:
            fh.write("x")
        self.index_call("c1", "read_file")
        _post(self.sock, "/tool-event", {"hook_event_name": "pre_tool_call",
                                        "tool_call_id": "c1", "tool_name": "read_file",
                                        "status": "ok"})
        shutil.rmtree(run_dir)
        self.assertTrue(os.path.exists(os.path.join(self.diag, "events.jsonl")))
        self.assertTrue(self.phases("tool_pre_observe"))


class ClientTests(BrokerFixture):
    def _client(self, payload, event="post_tool_call", timeout="0.2", sock=None, extra_env=None):
        env = dict(os.environ)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, CLIENT, "--socket", sock or self.sock, "--event", event,
             "--timeout", timeout],
            input=json.dumps(payload), text=True, capture_output=True, env=env, timeout=5)

    def test_exit_code_only_from_result(self):
        self.index_call("c-x", "terminal")
        result = self._client({
            "hook_event_name": "post_tool_call", "tool_call_id": "c-x", "tool_name": "terminal",
            "status": "ok", "duration_ms": 3,
            "extra": {"result": json.dumps({"output": SECRET_OUT, "exit_code": 7}),
                      "error_message": SECRET_ERR}})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        post = self.phases("tool_post_observe")
        self.assertEqual(len(post), 1)
        self.assertIn("exit=7", post[0]["arg"])
        self.assertNotIn(SECRET_OUT, json.dumps(post))
        self.assertNotIn(SECRET_ERR, json.dumps(post))

    def test_missing_exit_code_is_unknown(self):
        self.index_call("c-y", "read_file")
        self._client({"hook_event_name": "post_tool_call", "tool_call_id": "c-y",
                      "tool_name": "read_file", "status": "ok", "duration_ms": 3,
                      "extra": {"result": {"output": "x"}}})
        post = self.phases("tool_post_observe")
        self.assertEqual(len(post), 1)
        self.assertIn("exit=UNKNOWN", post[0]["arg"])

    def test_missing_socket_is_silent_and_fast(self):
        start = time.monotonic()
        result = self._client({"hook_event_name": "pre_tool_call", "tool_name": "read_file"},
                              sock=os.path.join(self.tmp, "nope.sock"), timeout="0.2")
        self.assertLess(time.monotonic() - start, 1.5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_busy_controller_is_bounded(self):
        busy = os.path.join(self.tmp, "busy.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(busy)
        server.listen(1)
        try:
            start = time.monotonic()
            result = self._client({"hook_event_name": "pre_tool_call", "tool_name": "read_file"},
                                  sock=busy, timeout="0.2")
            self.assertLess(time.monotonic() - start, 1.5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
        finally:
            server.close()


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="obs-cfg-", dir="/var/tmp")
        self.config = os.path.join(self.tmp, "config.yaml")
        with open(self.config, "w", encoding="utf-8") as fh:
            fh.write(
                "model:\n  default: m\nhooks:\n"
                "  pre_tool_call:\n"
                "    - command: '/guard/contract_guard.py'\n"
                "      matcher: write_file|patch|terminal\n"
                "      fail_closed: true\n"
                "      timeout: 20\n"
                "  post_tool_call:\n"
                "    - command: '/host/observer.py'\n"
                "      timeout: 10\n"
                "  pre_api_request:\n"
                "    - command: '/host/api.py'\n"
                "      timeout: 10\n")
        self.allow = os.path.join(self.tmp, "allow.json")
        self.guard = "/guard/contract_guard.py"
        self.pre = "python3 /x/tool_event_client.py --socket /s --event pre_tool_call --timeout 0.5"
        self.post = "python3 /x/tool_event_client.py --socket /s --event post_tool_call --timeout 0.5"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _allow(self, entries):
        with open(self.allow, "w", encoding="utf-8") as fh:
            json.dump({"approvals": entries}, fh)

    def _verify(self):
        return tool_observer_config.verify(self.config, self.allow, self.guard,
                                           self.pre, self.post, True)

    def test_install_and_exact_verify(self):
        self.assertEqual(tool_observer_config.install(self.config, self.pre, self.post), 0)
        entries = [{"event": "pre_tool_call", "command": self.guard},
                   {"event": "pre_tool_call", "command": self.pre},
                   {"event": "post_tool_call", "command": self.post}]
        self._allow(entries)
        self.assertEqual(self._verify(), 0)
        with open(self.config, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("matcher: '.*'", text)
        self.assertIn("timeout: 1", text)
        self.assertNotIn("/host/observer.py", text)

    def test_missing_duplicate_extra_approvals_rejected(self):
        tool_observer_config.install(self.config, self.pre, self.post)
        good = [{"event": "pre_tool_call", "command": self.guard},
                {"event": "pre_tool_call", "command": self.pre},
                {"event": "post_tool_call", "command": self.post}]
        for bad in (good[:2], good + [good[-1]],
                    good + [{"event": "post_tool_call", "command": "EXTRA"}]):
            self._allow(bad)
            self.assertNotEqual(self._verify(), 0)

    def test_extra_config_hook_rejected(self):
        tool_observer_config.install(self.config, self.pre, self.post)
        with open(self.config, encoding="utf-8") as fh:
            text = fh.read().replace(
            "  pre_tool_call:\n", "  pre_tool_call:\n    - command: '/extra/hook.py'\n      timeout: 1\n")
        with open(self.config, "w", encoding="utf-8") as fh:
            fh.write(text)
        self._allow([{"event": "pre_tool_call", "command": self.guard},
                     {"event": "pre_tool_call", "command": self.pre},
                     {"event": "post_tool_call", "command": self.post}])
        self.assertNotEqual(self._verify(), 0)


def _hermes_python():
    candidates = glob.glob(os.path.expanduser(
        "~/.hermes/installs/*/environments/*/venv/bin/python"))
    for candidate in candidates:
        probe = subprocess.run(
            [candidate, "-c",
             "import sys;sys.path.insert(0,%r);import ruamel.yaml,agent.shell_hooks" % HERMES_HOME],
            capture_output=True, text=True)
        if probe.returncode == 0:
            return candidate
    return None


PROBE = r'''
import json, os, sys
home, cfg_path, call_id = sys.argv[1:4]
sys.path.insert(0, %r)
os.environ["HERMES_HOME"] = home
cfg = json.load(open(cfg_path))
from agent.shell_hooks import register_from_config
from hermes_cli.lifecycle import invoke_hook
registered = register_from_config(cfg)
pre = invoke_hook("pre_tool_call", tool_name="terminal", args={"command": %r},
                  tool_call_id=call_id, task_id="T", session_id="S", turn_id="U", api_request_id="A")
post = invoke_hook("post_tool_call", tool_name="terminal", args={"command": %r},
                   result=json.dumps({"output": %r, "exit_code": 7, "error": None}),
                   tool_call_id=call_id, task_id="T", session_id="S", turn_id="U",
                   api_request_id="A", duration_ms=9, status="ok", error_type=None,
                   error_message=%r)
print(json.dumps({"registered": len(registered), "pre": pre, "post": post}))
''' % (HERMES_HOME, SECRET_ARGS, SECRET_ARGS, SECRET_OUT, SECRET_ERR)

GUARD_STUB = r'''
import json, sys
payload = json.load(sys.stdin)
if payload.get("tool_name") == "terminal":
    print(json.dumps({"action": "block", "message": "blocked-by-test"}))
sys.exit(0)
'''


class HookPathTests(BrokerFixture):
    def setUp(self):
        super().setUp()
        self.python = _hermes_python()
        if not self.python:
            self.skipTest("pinned Hermes venv not importable")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.probe = os.path.join(self.tmp, "probe.py")
        with open(self.probe, "w", encoding="utf-8") as fh:
            fh.write(PROBE)
        self.guard = os.path.join(self.tmp, "guard_stub.py")
        with open(self.guard, "w", encoding="utf-8") as fh:
            fh.write(GUARD_STUB)
        self.guard_cmd = "/usr/bin/python3 %s" % self.guard
        self.pre = "/usr/bin/python3 %s --socket %s --event pre_tool_call --timeout 0.5" % (CLIENT, self.sock)
        self.post = "/usr/bin/python3 %s --socket %s --event post_tool_call --timeout 0.5" % (CLIENT, self.sock)

    def _config(self, pre=None, post=None, include_guard=True):
        pre_cmd = pre or self.pre
        post_cmd = post or self.post
        hooks = {"pre_tool_call": [], "post_tool_call": [{"command": post_cmd, "timeout": 1}]}
        if include_guard:
            hooks["pre_tool_call"].append({"command": self.guard_cmd,
                                           "matcher": "write_file|patch|terminal",
                                           "fail_closed": True, "timeout": 5})
        hooks["pre_tool_call"].append({"command": pre_cmd, "matcher": ".*",
                                       "fail_closed": False, "timeout": 1})
        path = os.path.join(self.tmp, "hooks.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"hooks": hooks}, fh)
        approvals = [{"event": "pre_tool_call", "command": pre_cmd},
                     {"event": "post_tool_call", "command": post_cmd}]
        if include_guard:
            approvals.append({"event": "pre_tool_call", "command": self.guard_cmd})
        with open(os.path.join(self.home, "shell-hooks-allowlist.json"), "w", encoding="utf-8") as fh:
            json.dump({"approvals": approvals}, fh)
        return path

    def _run_probe(self, config_path, call_id="call-hook"):
        return subprocess.run(
            [self.python, self.probe, self.home, config_path, call_id],
            capture_output=True, text=True, timeout=30)

    def test_real_hook_path_order_and_fields(self):
        body = json.dumps({"choices": [{"message": {"tool_calls": [
            {"id": "call-hook", "function": {"name": "terminal", "arguments": "{}"}}]},
            "finish_reason": "tool_calls"}]}).encode()
        self.model_request(body)
        result = self._run_probe(self._config())
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(data["registered"], 3)
        self.assertTrue(data["pre"], "guard block missing")
        self.assertEqual(data["pre"][0].get("action"), "block")
        phases = [e["phase"] for e in self.phases(
            "model_response", "model_tool_request", "tool_pre_observe", "tool_post_observe")]
        self.assertEqual(phases, ["model_response", "model_tool_request",
                                  "tool_pre_observe", "tool_post_observe"])
        pre = self.phases("tool_pre_observe")[0]
        post = self.phases("tool_post_observe")[0]
        self.assertIn("corr=1", pre["arg"])
        self.assertIn("when=pre", pre["arg"])
        self.assertIn("when=post", post["arg"])
        self.assertIn("exit=7", post["arg"])
        with open(os.path.join(self.diag, "events.jsonl"), encoding="utf-8") as fh:
            raw = fh.read()
        for secret in (SECRET_ARGS, SECRET_OUT, SECRET_ERR, "call-hook"):
            self.assertNotIn(secret, raw)
            self.assertNotIn(secret, result.stdout)
            self.assertNotIn(secret, result.stderr)

    def test_observer_failure_does_not_change_guard_verdict(self):
        body = json.dumps({"choices": [{"message": {"tool_calls": [
            {"id": "call-fail", "function": {"name": "terminal", "arguments": "{}"}}]},
            "finish_reason": "tool_calls"}]}).encode()
        self.model_request(body)
        dead = "/usr/bin/python3 %s --socket %s --event %%s --timeout 0.2" % (
            CLIENT, os.path.join(self.tmp, "nope.sock"))
        config = self._config(pre=dead % "pre_tool_call", post=dead % "post_tool_call")
        result = self._run_probe(config, call_id="call-fail")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(data["pre"][0].get("action"), "block")
        self.assertEqual(self.phases("tool_pre_observe"), [])

    def test_observer_only_without_guard_does_not_block(self):
        self.index_call("call-ro", "terminal")
        result = self._run_probe(self._config(include_guard=False), call_id="call-ro")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(data["pre"], [])
        self.assertEqual(len(self.phases("tool_pre_observe")), 1)


if __name__ == "__main__":
    unittest.main()
