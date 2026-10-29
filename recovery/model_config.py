#!/usr/bin/env python3
"""Operator-managed model routes. Profiles contain references, never API keys.

One active route is written atomically into the existing trusted model config.
No network, credential reads, shell evaluation, backups, or automatic fallback.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
from urllib.parse import urlsplit

CONFIG = Path('/etc/aegl/model/config')
PROFILES = Path('/etc/aegl/model/providers')
API = 'openai-chat-completions'
PROFILE_KEYS = {'api', 'base_url', 'model', 'credential_source', 'credential_env', 'auth_header'}
ACTIVE_KEYS = ('MODEL_API', 'UPSTREAM', 'MODEL_ID', 'CREDENTIAL_SOURCE', 'CREDENTIAL_ENV', 'AUTH_HEADER')
HEADERS = {'authorization': 'Authorization', 'api-key': 'api-key', 'x-api-key': 'x-api-key'}


class ConfigError(Exception):
    pass


def profile_name(name: str) -> str:
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,47}', name):
        raise ConfigError('invalid profile name')
    return name


def validate_route(route: dict) -> dict:
    if not isinstance(route, dict) or set(route) != PROFILE_KEYS:
        raise ConfigError('profile must contain only the six supported reference fields')
    if any(not isinstance(v, str) or not v or any(ord(c) < 32 for c in v) for v in route.values()):
        raise ConfigError('profile fields must be nonempty single-line strings')
    if route['api'] != API:
        raise ConfigError('only OpenAI Chat Completions is supported by this task broker')
    try:
        url = urlsplit(route['base_url'])
        port = url.port
    except ValueError:
        raise ConfigError('invalid API base URL') from None
    if (url.scheme != 'https' or not url.hostname or url.username is not None or
            url.password is not None or url.query or url.fragment or
            re.search(r'\s', route['base_url']) or port == 0):
        raise ConfigError('API base must be HTTPS without credentials, query, or fragment')
    if url.path.rstrip('/').endswith(('/chat/completions', '/responses', '/messages')):
        raise ConfigError('provide an API base URL, not a complete operation endpoint')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,199}', route['model']):
        raise ConfigError('invalid model identifier')
    if not Path(route['credential_source']).is_absolute():
        raise ConfigError('credential source must be an absolute dotenv file path')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', route['credential_env']):
        raise ConfigError('invalid credential variable name')
    header = HEADERS.get(route['auth_header'].lower())
    if header is None:
        raise ConfigError('auth header must be Authorization, api-key, or x-api-key')
    return {**route, 'base_url': route['base_url'].rstrip('/'), 'auth_header': header}


def read_config(path: Path) -> dict:
    """Literal NAME=value only. In particular, never source a shell file here."""
    data = {}
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        key, sep, raw = stripped.partition('=')
        key = key.strip()
        if not sep or not re.fullmatch(r'[A-Z_][A-Z0-9_]*', key) or key in data:
            raise ConfigError('config must contain unique literal NAME=value assignments')
        try:
            values = shlex.split(raw, comments=True)
        except ValueError:
            raise ConfigError('invalid quoted config value') from None
        if len(values) > 1:
            raise ConfigError('config values containing spaces must be quoted')
        value = values[0] if values else ''
        # The launcher sources the same file: reject expansion and shell syntax even
        # inside quotes, so our literal interpretation cannot differ from Bash's.
        if any(c in value for c in '$`\n\r;|&<>'):
            raise ConfigError('shell expressions are not supported in model config')
        data[key] = value
    return data


def active_route(config: dict) -> dict:
    if any(not config.get(key) for key in ACTIVE_KEYS):
        raise ConfigError('model route is not configured; save and use a provider profile first')
    return validate_route(dict(zip(
        ('api', 'base_url', 'model', 'credential_source', 'credential_env', 'auth_header'),
        (config[key] for key in ACTIVE_KEYS))))


def atomic_write(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def save_profile(directory: Path, name: str, route: dict) -> None:
    name = profile_name(name)
    route = validate_route(route)
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    atomic_write(directory / (name + '.json'), json.dumps(route, indent=2) + '\n')


def read_profile(directory: Path, name: str) -> dict:
    return validate_route(json.loads((directory / (profile_name(name) + '.json')).read_text()))


def activate(path: Path, name: str, route: dict) -> None:
    name = profile_name(name)
    route = validate_route(route)
    # This checks only file metadata, not credential contents or validity.
    if not Path(route['credential_source']).is_file():
        raise ConfigError('configured credential source file does not exist')
    with (path.parent / '.model-config.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        config = read_config(path)
        config.update(dict(zip(ACTIVE_KEYS, (route[k] for k in (
            'api', 'base_url', 'model', 'credential_source', 'credential_env', 'auth_header')))))
        config['MODEL_PROFILE'] = name
        atomic_write(path, ''.join(key + '=' + shlex.quote(value) + '\n'
                                   for key, value in config.items()))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=CONFIG)
    parser.add_argument('--profiles', type=Path, default=PROFILES)
    sub = parser.add_subparsers(dest='action', required=True)
    save = sub.add_parser('save', help='save a named provider profile; does not activate it')
    save.add_argument('name')
    save.add_argument('--base-url', required=True)
    save.add_argument('--model', required=True)
    save.add_argument('--credential-source', required=True)
    save.add_argument('--credential-env', required=True)
    save.add_argument('--auth-header', default='Authorization')
    save.add_argument('--api', default=API)
    use = sub.add_parser('use', help='activate a saved profile for subsequent tasks')
    use.add_argument('name')
    sub.add_parser('list', help='list saved profile names')
    sub.add_parser('show', help='show active route metadata; never read credentials')
    sub.add_parser('validate', help='check active route without a network request')
    args = parser.parse_args(argv)
    try:
        if args.action in ('save', 'use') and os.geteuid() != 0:
            raise ConfigError('root required to change trusted model configuration')
        if args.action == 'save':
            route = {key: getattr(args, key) for key in PROFILE_KEYS}
            save_profile(args.profiles, args.name, route)
            print('MODEL_PROFILE_SAVED=' + args.name)
        elif args.action == 'use':
            activate(args.config, args.name, read_profile(args.profiles, args.name))
            print('MODEL_PROFILE_ACTIVE=' + args.name + ' (applies to subsequent tasks)')
        elif args.action == 'list':
            for file in sorted(args.profiles.glob('*.json')):
                print(profile_name(file.stem))
        else:
            config = read_config(args.config)
            route = active_route(config)
            if args.action == 'show':
                print(json.dumps({'profile': config.get('MODEL_PROFILE', 'manual'), **route}, indent=2))
            else:
                print('MODEL_CONFIG=OK api=' + route['api'])
        return 0
    except (ConfigError, OSError, ValueError) as exc:
        # ConfigError messages are fixed strings; never echo malformed input/file data.
        message = str(exc) if isinstance(exc, ConfigError) else type(exc).__name__
        print('MODEL_CONFIG_ERROR=' + message, file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
