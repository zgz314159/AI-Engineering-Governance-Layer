#!/usr/bin/env python3
"""In-sandbox loopback shim: 127.0.0.1:PORT → a bound Unix socket.

This is the ONLY path by which a sandboxed Hermes reaches the model broker: the sandbox
has no external network, so an http client pointed at ``http://127.0.0.1:PORT/v1`` is
served here, and this forwards the byte stream to the Unix socket the trusted broker is
bound to. It holds no credential and opens no external connection.

It handles both directions, propagates EOF / half-close (so a client that reads until EOF
terminates), and bounds idle time. stdlib only.

    loopback_shim.py --listen 127.0.0.1:8877 --unix /run/aegl-model/model.sock
"""

from __future__ import annotations

import argparse
import select
import socket
import sys
import threading

IDLE_TIMEOUT = 30.0


def _pump(src: socket.socket, dst: socket.socket, done: threading.Event) -> None:
    """Forward src→dst until EOF/timeout, then half-close dst and signal ``done``."""
    try:
        while not done.is_set():
            r, _, _ = select.select([src], [], [], IDLE_TIMEOUT)
            if not r:
                break
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        done.set()
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def _handle(client: socket.socket, unix_path: str) -> None:
    try:
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        upstream.connect(unix_path)
    except OSError:
        try:
            client.close()
        except OSError:
            pass
        return
    done = threading.Event()
    thread = threading.Thread(target=_pump, args=(upstream, client, done), daemon=True)
    thread.start()
    try:
        _pump(client, upstream, done)
        thread.join(2.0)
    finally:
        for sock in (client, upstream):
            try:
                sock.close()
            except OSError:
                pass


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
