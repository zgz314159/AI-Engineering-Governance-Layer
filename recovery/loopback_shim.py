#!/usr/bin/env python3
"""In-sandbox loopback shim: 127.0.0.1:PORT → a bound Unix socket.

This is the ONLY path by which a sandboxed Hermes reaches the model broker: the sandbox
has no external network, so an http client pointed at ``http://127.0.0.1:PORT/v1`` is
served here, and this forwards the byte stream to the Unix socket the trusted broker is
bound to. It holds no credential and opens no external connection.

It handles both directions, propagates EOF / half-close (so a client that reads until EOF
terminates), retires an idle request side without aborting the response, and bounds the
whole tunnel by the task budget. stdlib only.

    loopback_shim.py --listen 127.0.0.1:8877 --unix /run/aegl-model/model.sock
"""

from __future__ import annotations

import argparse
import select
import socket
import sys
import threading
import time

IDLE_TIMEOUT = 30.0
MAX_TUNNEL_SECONDS = 120.0


def _pump(src: socket.socket, dst: socket.socket, done: threading.Event, *,
          deadline: float, idle_timeout: float | None) -> None:
    """Forward src→dst until EOF / deadline.

    ``idle_timeout`` retires only a direction that is known not to have more data
    (the request side).  The response side passes ``None``: a model thinking pause is
    not a dead tunnel, and it remains bounded by the overall ``deadline`` instead.
    """
    idle = False
    try:
        while not done.is_set():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            # The response side has no direction idle; poll only so a peer close can
            # stop it promptly. The request side still retires after IDLE_TIMEOUT.
            wait = min(remaining, 1.0) if idle_timeout is None else min(remaining, idle_timeout)
            r, _, _ = select.select([src], [], [], wait)
            if not r:
                if idle_timeout is None:
                    continue
                idle = True
                break
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        # EOF / peer close / overall deadline ends the whole tunnel; a request-side
        # idle does not, because the response may still be in flight.
        if not idle:
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
    deadline = time.monotonic() + MAX_TUNNEL_SECONDS
    thread = threading.Thread(
        target=_pump, args=(upstream, client, done),
        kwargs={"deadline": deadline, "idle_timeout": None}, daemon=True)
    thread.start()
    try:
        _pump(client, upstream, done, deadline=deadline, idle_timeout=IDLE_TIMEOUT)
        # The request side can idle while the model response is still being generated;
        # wait for the response direction instead of dropping the live tunnel.
        thread.join()
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
