#!/usr/bin/env python3
"""Local real-socket check for the optional connection-phase diagnostic.

No cloud or real credentials. Run with PYTHONDONTWRITEBYTECODE=1.
"""
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


class Upstream(http.server.BaseHTTPRequestHandler):
    received = None

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        type(self).received = (self.path, body, self.headers.get('Authorization'))
        payload = b'{"choices":[{"message":{"content":"ok"}}]}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def run_case(base, server, capture):
    label = 'capture' if capture else 'normal'
    directory = base / label
    directory.mkdir()
    sock = directory / 'model.sock'
    key = directory / 'test-key'
    key.write_text('LOCAL_TEST_ONLY')
    env = {'PATH': os.defpath, 'PYTHONDONTWRITEBYTECODE': '1'}
    if capture:
        env.update(AEGL_DIAG_DIR=str(directory), AEGL_TASK='LOCAL_CONNECT_CHECK')
    proc = subprocess.Popen([
        sys.executable, str(Path(__file__).with_name('model_broker.py')),
        'serve', '--socket', str(sock), '--upstream',
        'http://127.0.0.1:%d/provider/v1' % server.server_port,
        '--credential-file', str(key), '--credential-env', 'UNSET_TEST_KEY',
    ], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 5
        while not sock.exists():
            if proc.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError('local broker did not become ready')
            time.sleep(.01)
        body = b'{"model":"LOCAL_TEST","messages":[]}'
        request = (b'POST /v1/chat/completions HTTP/1.1\r\nHost: local\r\n'
                   b'Content-Length: ' + str(len(body)).encode() +
                   b'\r\nConnection: close\r\n\r\n' + body)
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(str(sock))
            client.sendall(request)
            response = b''
            while True:
                part = client.recv(65536)
                if not part:
                    break
                response += part
        assert response.startswith(b'HTTP/1.1 200 ')
        assert Upstream.received == ('/provider/v1/chat/completions', body,
                                     'Bearer LOCAL_TEST_ONLY')
        events_file = directory / 'events.jsonl'
        if capture:
            text = events_file.read_text()
            events = [json.loads(line) for line in text.splitlines()]
            phases = [event['phase'] for event in events]
            expected = ['broker_req_recv', 'upstream_req_start',
                        'upstream_connect_start', 'upstream_connect_done',
                        'upstream_req_write_done', 'upstream_resp_headers',
                        'upstream_body_read_done', 'client_handoff_done']
            assert phases == expected, phases
            assert {event['seq'] for event in events} == {1}
            assert 'LOCAL_TEST_ONLY' not in text
            assert 'messages' not in text and 'Authorization' not in text
        else:
            assert not events_file.exists()
        print('LOCAL_SOCKET_%s=OK' % label.upper())
    finally:
        if proc.poll() is None:
            # This is our direct child, retained unreaped until wait(): no PID reuse.
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)


def main():
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='aegl-connect-test-', dir='/var/tmp') as tmp:
            for capture in (False, True):
                run_case(Path(tmp), server, capture)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    main()
