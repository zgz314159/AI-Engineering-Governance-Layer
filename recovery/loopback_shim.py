#!/usr/bin/env python3
"""In-sandbox loopback shim: 127.0.0.1:PORT → a bound Unix socket.

The sandbox has no network (`--unshare-all`), so a model client that only speaks
`http://127.0.0.1:PORT/v1` is served by this shim, which forwards to the Unix socket the
trusted model broker is bound to. It holds no credential and opens no external
connection. stdlib only.

    loopback_shim.py --listen 127.0.0.1:8877 --unix /run/aegl-model/model.sock
"""

from __future__ import annotations

import argparse
import select
import socket
import sys
import threading


def _pump(src: socket.socket, dst: socket.socket) -> None:
    """Forward one direction only: read from ``src``, write to ``dst``."""
    try:
        while True:
            r, _, _ = select.select([src], [], [], 60)
            if not r:
                break
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass


def _handle(client: socket.socket, unix_path: str) -> None:
    try:
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        upstream.connect(unix_path)
    except OSError:
        client.close()
        return
    t = threading.Thread(target=_pump, args=(upstream, client), daemon=True)
    t.start()
    _pump(client, upstream)
    upstream.close()
    client.close()


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True, help="host:port (e.g. 127.0.0.1:8877)")
    parser.add_argument("--unix", required=True)
    args = parser.parse_args(argv)
    host, _, port = args.listen.rpartition(":")
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host or "127.0.0.1", int(port)))
    server.listen(16)
    print("AEGL_LOOPBACK_SHIM listening=%s unix=%s" % (args.listen, args.unix), flush=True)
    try:
        while True:
            client, _ = server.accept()
            threading.Thread(target=_handle, args=(client, args.unix), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
