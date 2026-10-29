"""Focused configuration and real local TLS forwarding checks; no cloud API calls."""
import http.server
import importlib.util
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
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'recovery'))
import model_config as config
import model_broker as broker


def route(source, **changes):
    return dict(api=config.API, base_url='https://provider.example/v1',
                model='provider/model-a', credential_source=str(source),
                credential_env='PROVIDER_API_KEY', auth_header='Authorization', **changes)


class Configuration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='aegl-provider-test-', dir='/var/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / 'keys.env'
        self.source.write_text('PROVIDER_API_KEY=LOCAL_TEST_ONLY\n')
        self.cfg = self.base / 'config'
        self.cfg.write_text('HERMES_ENTRY=/existing/hermes\nHERMES_PROFILE_CONFIG=/existing/guard.yaml\n')

    def test_saved_routes_switch_all_related_fields_and_preserve_runtime(self):
        directory = self.base / 'profiles'
        a = route(self.source)
        b = {**a, 'base_url': 'https://other.example/provider/v1', 'model': 'other/model-b',
             'credential_env': 'OTHER_API_KEY', 'auth_header': 'api-key'}
        for name, selected in [('first', a), ('second', b)]:
            config.save_profile(directory, name, selected)
            config.activate(self.cfg, name, config.read_profile(directory, name))
            values = config.read_config(self.cfg)
            self.assertEqual(config.active_route(values), selected)
            self.assertEqual(values['MODEL_PROFILE'], name)
            self.assertEqual(values['HERMES_ENTRY'], '/existing/hermes')
            self.assertEqual(values['HERMES_PROFILE_CONFIG'], '/existing/guard.yaml')
        self.assertNotIn('LOCAL_TEST_ONLY', self.cfg.read_text())
        self.assertNotIn('LOCAL_TEST_ONLY', (directory / 'first.json').read_text())
        self.assertEqual(sorted(p.name for p in directory.iterdir()), ['first.json', 'second.json'])

    def test_configuration_never_reads_the_credential_contents(self):
        original = Path.read_text
        def read(path, *args, **kwargs):
            if path == self.source:
                raise AssertionError('configuration read a credential')
            return original(path, *args, **kwargs)
        with patch.object(Path, 'read_text', read):
            config.save_profile(self.base / 'profiles', 'test', route(self.source))
            config.activate(self.cfg, 'test', route(self.source))

    def test_invalid_route_cannot_replace_active_configuration(self):
        config.activate(self.cfg, 'test', route(self.source))
        before = self.cfg.read_bytes()
        cases = [('api', 'anthropic-messages'), ('base_url', 'http://remote.example/v1'),
                 ('base_url', 'https://key@remote.example/v1'),
                 ('base_url', 'https://remote.example/v1?api_key=secret'),
                 ('base_url', 'https://remote.example/v1/chat/completions'),
                 ('model', 'model\nhooks:'), ('credential_env', 'BAD-NAME'),
                 ('credential_source', 'relative.env'), ('auth_header', 'X-Unknown')]
        for key, value in cases:
            with self.subTest(key=key, value=value), self.assertRaises(config.ConfigError):
                config.activate(self.cfg, 'test', {**route(self.source), key: value})
            self.assertEqual(self.cfg.read_bytes(), before)

    def test_rotation_reads_current_source_without_changing_profile(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(broker._load_credential('PROVIDER_API_KEY', str(self.source), ''), 'LOCAL_TEST_ONLY')
            self.source.write_text('PROVIDER_API_KEY=ROTATED_LOCAL_TEST\n')
            self.assertEqual(broker._load_credential('PROVIDER_API_KEY', str(self.source), ''), 'ROTATED_LOCAL_TEST')

    def test_shell_expressions_and_duplicate_keys_are_rejected(self):
        for text in ['MODEL_ID=$(touch /tmp/not-run)\n', 'MODEL_ID=a\nMODEL_ID=b\n']:
            self.cfg.write_text(text)
            with self.assertRaises(config.ConfigError):
                config.read_config(self.cfg)

    def test_legacy_model_is_not_silently_assumed(self):
        with self.assertRaises(config.ConfigError):
            config.active_route(config.read_config(self.cfg))

    def test_generated_hermes_profile_uses_selected_model_and_local_dummy(self):
        script = (ROOT / 'bin/aegl-hermes-sandbox').read_text()
        a = script.index('\nimport json, os, sys\nsrc, dst, port, model_id = sys.argv[1:]') + 1
        b = script.index('\nPY\n}', a)
        code = script[a:b]
        source = self.base / 'hooks.yaml'
        source.write_text("hooks:\n  pre_tool_call:\n    - command: 'old-hook'\n      fail_closed: true\n")
        out = self.base / 'client.yaml'
        for model in ('provider/model-a', 'mimo-model-b', 'arbitrary-compatible-model'):
            env = {**os.environ, 'AEGL_HOOK_CMD': 'python3 /trusted/hook.py'}
            subprocess.run([sys.executable, '-c', code, str(source), str(out), '8877', model],
                           env=env, check=True, capture_output=True)
            text = out.read_text()
            value = next(line.split(':', 1)[1].strip() for line in text.splitlines() if line.startswith('  default:'))
            self.assertEqual(json.loads(value), model)
            self.assertIn('base_url: http://127.0.0.1:8877/v1', text)
            self.assertIn('api_key: aegl-sandbox-dummy', text)
            self.assertIn('api_mode: chat_completions', text)
            self.assertIn('python3 /trusted/hook.py', text)
            self.assertIn('fail_closed: true', text)
            self.assertNotIn('LOCAL_TEST_ONLY', text)


class TLSUpstream(http.server.BaseHTTPRequestHandler):
    received = []
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        type(self).received.append((self.path, json.loads(body),
                                   self.headers.get('Authorization'), self.headers.get('api-key')))
        data = b'{"choices":[{"message":{"content":"local"}}]}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass


class RealTLSForwarding(unittest.TestCase):
    def test_two_provider_routes_and_auth_formats_over_real_sockets(self):
        with tempfile.TemporaryDirectory(prefix='aegl-provider-tls-', dir='/var/tmp') as tmp:
            base = Path(tmp)
            cert, key = base / 'ca.pem', base / 'tls.key'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(key), '-out', str(cert), '-days', '1',
                            '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1'],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), TLSUpstream)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(cert, key)
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            TLSUpstream.received = []
            try:
                for index, auth in enumerate(['Authorization', 'api-key']):
                    source = base / ('key%d.env' % index)
                    source.write_text('TEST_API_KEY=LOCAL_PROVIDER_%d\n' % index)
                    selected = {**route(source), 'base_url': 'https://127.0.0.1:%d/provider%d/v1' % (server.server_port, index),
                                'model': 'provider%d/model%d' % (index, index),
                                'auth_header': auth, 'credential_env': 'TEST_API_KEY'}
                    config.validate_route(selected)
                    sock = base / ('broker%d.sock' % index)
                    env = dict(PATH=os.defpath, HOME=str(base), PYTHONDONTWRITEBYTECODE='1',
                               SSL_CERT_FILE=str(cert), AEGL_MODEL_SOCKET=str(sock),
                               AEGL_MODEL_UPSTREAM=selected['base_url'], AEGL_MODEL_AUTH_HEADER=auth,
                               AEGL_MODEL_CREDENTIAL_ENV='TEST_API_KEY', AEGL_MODEL_CREDENTIAL_SOURCE=str(source))
                    proc = subprocess.Popen(['bash', str(ROOT / 'bin/aegl-model-broker'), 'serve'],
                                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        deadline = time.monotonic() + 5
                        while not sock.exists():
                            if proc.poll() is not None or time.monotonic() >= deadline:
                                self.fail('local broker failed to start')
                            time.sleep(.01)
                        body = json.dumps({'model': selected['model'], 'messages': []}).encode()
                        with socket.socket(socket.AF_UNIX) as client:
                            client.settimeout(5)
                            client.connect(str(sock))
                            client.sendall(b'POST /v1/chat/completions HTTP/1.1\r\nHost: local\r\n'
                                           b'Authorization: Bearer CLIENT_DUMMY\r\nContent-Length: ' +
                                           str(len(body)).encode() + b'\r\n\r\n' + body)
                            response = b''
                            while True:
                                chunk = client.recv(65536)
                                if not chunk:
                                    break
                                response += chunk
                        self.assertTrue(response.startswith(b'HTTP/1.1 200 '))
                        path, request, bearer, api_key = TLSUpstream.received[-1]
                        self.assertEqual(path, '/provider%d/v1/chat/completions' % index)
                        self.assertEqual(request['model'], selected['model'])
                        self.assertEqual(bearer, 'Bearer LOCAL_PROVIDER_0' if index == 0 else None)
                        self.assertEqual(api_key, 'LOCAL_PROVIDER_1' if index == 1 else None)
                        self.assertNotIn(b'LOCAL_PROVIDER_', response)
                        self.assertNotIn(b'CLIENT_DUMMY', response)
                    finally:
                        if proc.poll() is None:
                            proc.terminate()
                        try:
                            proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            proc.kill()
                            proc.wait(timeout=5)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
