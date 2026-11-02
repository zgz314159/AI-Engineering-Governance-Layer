#!/usr/bin/env python3
"""Local real-socket check for the optional connection-phase diagnostic.

No cloud or real credentials. Run with PYTHONDONTWRITEBYTECODE=1.
"""
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model_broker  # noqa: E402


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


def _cert_material(base):
    cert, key = base / 'cert.pem', base / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(key), '-out', str(cert), '-days', '1',
                    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
                   check=True, capture_output=True)
    return cert, key


class _TlsServer:
    """A REAL TCP(/TLS) listener. handshake=False accepts and HOLDS TCP, never handshakes."""

    def __init__(self, cert=None, key=None, handshake=True):
        self.handshake = handshake
        self.sni = None
        self._held = []
        self._ctx = None
        if handshake:
            self._ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            self._ctx.load_cert_chain(certfile=str(cert), keyfile=str(key))
            self._ctx.sni_callback = self._sni
        self._stop = threading.Event()
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(('127.0.0.1', 0))
        self._listener.listen(8)
        self.port = self._listener.getsockname()[1]
        threading.Thread(target=self._serve, daemon=True).start()

    def _sni(self, _sock, name, _ctx):
        self.sni = name

    def _serve(self):
        while not self._stop.is_set():
            try:
                self._listener.settimeout(0.2)
                conn, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if not self.handshake:
                conn.settimeout(None)
                self._held.append(conn)  # hold TCP open: never read, write or handshake
                continue
            conn.settimeout(5)
            try:
                self._ctx.wrap_socket(conn, server_side=True).close()
            except BaseException:  # noqa: BLE001
                try:
                    conn.close()
                except OSError:
                    pass

    def close(self):
        self._stop.set()
        try:
            self._listener.close()
        except OSError:
            pass
        for conn in self._held:
            try:
                conn.close()
            except OSError:
                pass


def _with_addrs(addresses, fn):
    """Inject the resolver RESULT only; TCP and TLS below are real sockets."""
    original = model_broker._resolve_bounded
    model_broker._resolve_bounded = lambda host, port, timeout: list(addresses)
    try:
        return fn()
    finally:
        model_broker._resolve_bounded = original


def _dead_port():
    probe = socket.socket()
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def _addr(port):
    return (socket.AF_INET, socket.SOCK_STREAM, 6, '', ('127.0.0.1', port))


def check_first_address_falls_through(base):
    """First address refuses TCP; a later address must be tried and succeed."""
    cert, key = _cert_material(base)
    server = _TlsServer(cert, key)
    try:
        ctx = ssl.create_default_context(cafile=str(cert))
        up = http.client.HTTPSConnection('localhost', server.port, context=ctx, timeout=120)
        addrs = [_addr(_dead_port()), _addr(server.port)]
        _with_addrs(addrs, lambda: model_broker._connect_bounded(up, 'localhost', server.port, ctx, 1))
        assert up.sock is not None, 'no connection was established'
        assert up.sock.version() in ('TLSv1.2', 'TLSv1.3'), up.sock.version()
        assert up.sock.gettimeout() == 120, 'short connect timeout left behind: %r' % up.sock.gettimeout()
        assert server.sni == 'localhost', 'SNI was not sent: %r' % server.sni
        up.close()
        print('BOUNDED_CONNECT_FALLTHROUGH=OK')
    finally:
        server.close()


def check_total_deadline_bounds_stalls(base):
    """TLS stalls on every address; the TOTAL deadline must bound the whole attempt."""
    servers = [_TlsServer(handshake=False) for _ in range(3)]
    old = (model_broker.CONNECT_DEADLINE_S, model_broker.CONNECT_STAGE_S)
    model_broker.CONNECT_DEADLINE_S, model_broker.CONNECT_STAGE_S = 2.0, 1.0
    try:
        ctx = ssl.create_default_context()
        up = http.client.HTTPSConnection('localhost', 443, context=ctx, timeout=120)
        addrs = [_addr(server.port) for server in servers]
        started = time.monotonic()
        error = None
        try:
            _with_addrs(addrs, lambda: model_broker._connect_bounded(up, 'localhost', 443, ctx, 1))
        except BaseException as exc:  # noqa: BLE001
            error = exc
        elapsed = time.monotonic() - started
        assert error is not None, 'a stalled TLS stage was not reported'
        assert elapsed < 3.0, 'total deadline did not bound the attempt: %.2fs' % elapsed
        assert up.sock is None, 'a stalled connect reported success'
        print('BOUNDED_CONNECT_DEADLINE=OK elapsed=%.2fs error=%s' % (elapsed, type(error).__name__))
    finally:
        model_broker.CONNECT_DEADLINE_S, model_broker.CONNECT_STAGE_S = old
        for server in servers:
            server.close()


def check_bad_certificate_rejected(base):
    """A certificate the trust store does not accept must still be rejected."""
    cert, key = _cert_material(base)
    server = _TlsServer(cert, key)
    try:
        ctx = ssl.create_default_context()  # system trust: the local cert is untrusted
        up = http.client.HTTPSConnection('localhost', server.port, context=ctx, timeout=120)
        error = None
        try:
            _with_addrs([_addr(server.port)],
                        lambda: model_broker._connect_bounded(up, 'localhost', server.port, ctx, 1))
        except BaseException as exc:  # noqa: BLE001
            error = exc
        assert isinstance(error, ssl.SSLCertVerificationError), error
        assert up.sock is None, 'an unverified certificate was accepted'
        print('BOUNDED_CONNECT_BAD_CERT=OK error=%s' % type(error).__name__)
    finally:
        server.close()


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
    with tempfile.TemporaryDirectory(prefix='aegl-bounded-connect-', dir='/var/tmp') as tmp:
        for name, check in (('fallthrough', check_first_address_falls_through),
                            ('stall', check_total_deadline_bounds_stalls),
                            ('badcert', check_bad_certificate_rejected)):
            work = Path(tmp) / name
            work.mkdir()
            check(work)


if __name__ == '__main__':
    main()
