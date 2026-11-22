#!/usr/bin/env python3
"""CDP helpers for ChatGPT control tabs — IME-safe, no HERMES_TASK_V1.

Long-term dual-link testing needs to open *new* ChatGPT conversations and read
their ``/c/<id>`` URLs. Chinese IME (composition sticky ``中``) blocks send if we
type through the OS input method. This module:

  * prefers clipboard/paste + Input.insertText (no IME composition)
  * cancels any active composition (Escape / compositionend)
  * optionally expects CDP Chrome launched with IME disabled (see ensure-cdp)

Usage:
  python3 cdp_chat.py ensure-cdp
  python3 cdp_chat.py new-chat [--forbid-substring 6ac4d058]
  python3 cdp_chat.py wait-url --contains /c/ --forbid 6ac4d058
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

CDP_DEFAULT = os.environ.get("CDP", "http://127.0.0.1:9333")
PROFILE_DEFAULT = Path(
    os.environ.get(
        "AEGL_CDP_PROFILE",
        str(Path.home() / ".local/share/aegl-dual-link/chrome-cdp-profile"),
    )
)
STATE_DEFAULT = Path(
    os.environ.get("AEGL_DUAL_LINK_STATE", str(Path.home() / ".local/state/aegl-dual-link"))
)
CONTROL_URL_RE = re.compile(r"^https://chatgpt\.com/c/[A-Za-z0-9._-]{1,128}$")


class CdpError(RuntimeError):
    pass


def list_tabs(cdp: str = CDP_DEFAULT) -> list[dict]:
    return json.loads(urllib.request.urlopen(cdp + "/json/list", timeout=5).read())


def new_tab(url: str, cdp: str = CDP_DEFAULT) -> dict:
    req = urllib.request.Request(
        cdp + "/json/new?" + urllib.parse.quote(url, safe=":/?=&"), method="PUT"
    )
    return json.loads(urllib.request.urlopen(req, timeout=8).read())


def cdp_up(cdp: str = CDP_DEFAULT) -> bool:
    try:
        urllib.request.urlopen(cdp + "/json/list", timeout=2)
        return True
    except Exception:
        return False


def launch_cdp_chrome(
    *,
    profile: Path = PROFILE_DEFAULT,
    state: Path = STATE_DEFAULT,
    start_url: str = "https://chatgpt.com/",
    port: int = 9333,
) -> None:
    """Start dedicated Chrome with IME disabled (automation profile only)."""
    profile.mkdir(parents=True, exist_ok=True)
    state.mkdir(parents=True, exist_ok=True)
    log = state / "chrome-cdp.log"
    env = os.environ.copy()
    # Kill sticky CJK IME in THIS profile only.
    env["GTK_IM_MODULE"] = "xim"
    env["QT_IM_MODULE"] = "xim"
    env["XMODIFIERS"] = "@im=none"
    env["LANG"] = "en_US.UTF-8"
    env["LC_ALL"] = "en_US.UTF-8"
    cmd = [
        "google-chrome-stable",
        f"--remote-debugging-port={port}",
        f"--user-data-dir={profile}",
        "--no-first-run",
        "--no-default-browser-check",
        "--lang=en-US",
        "--disable-features=TranslateUI,VizDisplayCompositor",
        start_url,
    ]
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("\n# launch %s\n" % time.strftime("%Y-%m-%dT%H:%M:%S%z"))
        subprocess.Popen(
            cmd, env=env, stdout=fh, stderr=subprocess.STDOUT, start_new_session=True
        )
    for _ in range(40):
        time.sleep(0.25)
        if cdp_up(f"http://127.0.0.1:{port}"):
            return
    raise CdpError("CDP chrome failed to open port %d — see %s" % (port, log))


def kill_cdp_chrome(profile: Path = PROFILE_DEFAULT) -> None:
    """Stop only the dual-link CDP profile Chrome (not the user's main browser)."""
    marker = str(profile)
    try:
        out = subprocess.check_output(["pgrep", "-af", "chrome"], text=True)
    except subprocess.CalledProcessError:
        return
    pids = []
    for line in out.splitlines():
        if marker in line and "remote-debugging-port=9333" in line:
            pids.append(int(line.split(None, 1)[0]))
    if not pids:
        return
    # Kill parent first (lowest pid usually main)
    for pid in sorted(pids):
        try:
            os.kill(pid, 15)
        except OSError:
            pass
    time.sleep(1.0)
    for pid in sorted(pids):
        try:
            os.kill(pid, 9)
        except OSError:
            pass


class CdpSession:
    def __init__(self, ws_url: str):
        self._mid = 0
        u = urlparse(ws_url)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock = socket.create_connection((u.hostname, u.port), timeout=15)
        self.sock.sendall(
            (
                f"GET {u.path} HTTP/1.1\r\n"
                f"Host: {u.hostname}:{u.port}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        hdr = b""
        while b"\r\n\r\n" not in hdr:
            hdr += self.sock.recv(4096)
        if b"101" not in hdr.split(b"\r\n", 1)[0]:
            raise CdpError("websocket upgrade failed: %r" % hdr[:120])

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def _readn(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError("cdp socket closed")
            buf += chunk
        return buf

    def _recv(self) -> tuple[int, bytes]:
        h = self._readn(2)
        op = h[0] & 0x0F
        ln = h[1] & 0x7F
        masked = bool(h[1] & 0x80)
        if ln == 126:
            ln = int.from_bytes(self._readn(2), "big")
        elif ln == 127:
            ln = int.from_bytes(self._readn(8), "big")
        mask = self._readn(4) if masked else None
        data = bytearray(self._readn(ln))
        if mask:
            for i in range(len(data)):
                data[i] ^= mask[i % 4]
        return op, bytes(data)

    def _send(self, data: bytes) -> None:
        mask = os.urandom(4)
        ln = len(data)
        if ln < 126:
            out = bytearray([0x81, 0x80 | ln])
        elif ln < 65536:
            out = bytearray([0x81, 0x80 | 126]) + ln.to_bytes(2, "big")
        else:
            out = bytearray([0x81, 0x80 | 127]) + ln.to_bytes(8, "big")
        out += mask
        payload = bytearray(data)
        for i in range(len(payload)):
            payload[i] ^= mask[i % 4]
        out += payload
        self.sock.sendall(out)

    def call(self, method: str, params: dict | None = None) -> dict:
        self._mid += 1
        mid = self._mid
        self._send(json.dumps({"id": mid, "method": method, "params": params or {}}).encode())
        while True:
            op, data = self._recv()
            if op != 1:
                continue
            msg = json.loads(data)
            if msg.get("id") == mid:
                if "error" in msg:
                    raise CdpError("%s: %s" % (method, msg["error"]))
                return msg.get("result") or {}

    def evaluate(self, expression: str, *, await_promise: bool = False):
        r = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": await_promise,
                "userGesture": True,
            },
        )
        if r.get("exceptionDetails"):
            raise CdpError("JS exception: %s" % r["exceptionDetails"])
        return (r.get("result") or {}).get("value")


def _pick_page(tabs: list[dict], *, prefer_home: bool = True) -> dict:
    pages = [t for t in tabs if t.get("type") == "page" and "chatgpt.com" in (t.get("url") or "")]
    if not pages:
        raise CdpError("no chatgpt.com page tab — open ChatGPT in CDP Chrome and login")
    if prefer_home:
        for t in pages:
            u = (t.get("url") or "").rstrip("/")
            if u in {"https://chatgpt.com", "https://chatgpt.com/"}:
                return t
    return pages[0]


def _ime_safe_fill_and_send(sess: CdpSession, text: str) -> dict:
    """Fill composer without CJK IME, then click the form send button."""
    if not text.isascii():
        raise CdpError("bootstrap text must be ASCII to avoid IME composition")
    # Cancel composition / clear sticky IME candidate.
    for _ in range(3):
        sess.call(
            "Input.dispatchKeyEvent",
            {"type": "keyDown", "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27},
        )
        sess.call(
            "Input.dispatchKeyEvent",
            {"type": "keyUp", "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27},
        )
    # Focus + clear + paste via ClipboardEvent (bypasses IME).
    prep = sess.evaluate(
        r"""
(() => {
  const nodes = [...document.querySelectorAll(
    'div[contenteditable="true"][role="textbox"], #prompt-textarea, div.ProseMirror[contenteditable="true"]'
  )].filter(e => {
    const r = e.getBoundingClientRect();
    return r.width > 40 && r.height > 10;
  });
  if (!nodes.length) return {ok:false, reason:'no_composer'};
  nodes.sort((a,b) => (b.getBoundingClientRect().width*b.getBoundingClientRect().height)
                    - (a.getBoundingClientRect().width*a.getBoundingClientRect().height));
  const e = nodes[0];
  e.focus();
  e.dispatchEvent(new CompositionEvent('compositionend', {bubbles:true, data:''}));
  const sel = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(e);
  sel.removeAllRanges();
  sel.addRange(range);
  document.execCommand('delete');
  // Paste path — does not engage CJK IME.
  const dt = new DataTransfer();
  dt.setData('text/plain', %s);
  const paste = new ClipboardEvent('paste', {bubbles:true, cancelable:true, clipboardData:dt});
  const prevented = !e.dispatchEvent(paste);
  if (!(e.innerText || '').trim()) {
    // Fallback: beforeinput / insertText execCommand
    document.execCommand('insertText', false, %s);
  }
  e.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertFromPaste'}));
  return {ok:true, text:(e.innerText||'').slice(0,200), prevented};
})()
"""
        % (json.dumps(text), json.dumps(text))
    )
    if not isinstance(prep, dict) or not prep.get("ok"):
        raise CdpError("composer fill failed: %r" % (prep,))
    # Extra insurance: CDP insertText while focused (still ASCII, no IME).
    if text not in (prep.get("text") or ""):
        sess.call("Input.insertText", {"text": text})
        time.sleep(0.2)
    box = sess.evaluate(
        r"""
(() => {
  const e = [...document.querySelectorAll(
    'div[contenteditable="true"][role="textbox"], #prompt-textarea, div.ProseMirror[contenteditable="true"]'
  )].find(x => x.getBoundingClientRect().width > 40);
  if (!e) return null;
  const form = e.closest('form') || document;
  const buttons = [...form.querySelectorAll('button')].filter(b => {
    const r = b.getBoundingClientRect();
    if (r.width < 8 || r.height < 8) return false;
    if (b.disabled || b.getAttribute('aria-disabled') === 'true') return false;
    const testid = b.getAttribute('data-testid') || '';
    const label = b.getAttribute('aria-label') || '';
    return testid === 'send-button' ||
           ['发送','Send','Send message','发送消息','发送提示'].includes(label);
  });
  if (!buttons.length) return {error:'no_send', labels:[...form.querySelectorAll('button')].slice(0,15).map(b=>b.getAttribute('aria-label'))};
  const b = buttons[0];
  const r = b.getBoundingClientRect();
  return {x:r.x+r.width/2, y:r.y+r.height/2, label:b.getAttribute('aria-label')||b.getAttribute('data-testid')};
})()
"""
    )
    if not isinstance(box, dict) or "x" not in box:
        raise CdpError("send button not ready: %r" % (box,))
    x, y = box["x"], box["y"]
    sess.call(
        "Input.dispatchMouseEvent",
        {"type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1},
    )
    sess.call(
        "Input.dispatchMouseEvent",
        {"type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1},
    )
    return {"filled": prep, "send": box}


def new_chat(
    *,
    cdp: str = CDP_DEFAULT,
    forbid_substring: str | None = None,
    bootstrap: str = "AEGL dual-link control chat bootstrap. Reply with READY only. No Hermes control blocks.",
    timeout_s: float = 45.0,
) -> str:
    """Open a fresh ChatGPT conversation and return its https://chatgpt.com/c/<id> URL."""
    if not cdp_up(cdp):
        raise CdpError("CDP down — run: python3 cdp_chat.py ensure-cdp")
    tabs = list_tabs(cdp)
    try:
        page = _pick_page(tabs, prefer_home=True)
    except CdpError:
        page = new_tab("https://chatgpt.com/", cdp)
    sess = CdpSession(page["webSocketDebuggerUrl"])
    try:
        sess.call("Page.enable")
        sess.call("Runtime.enable")
        sess.call("Page.navigate", {"url": "https://chatgpt.com/"})
        time.sleep(2.5)
        # Click New chat
        clicked = sess.evaluate(
            r"""
(() => {
  const cands = [...document.querySelectorAll('a,button,[role="button"]')];
  const el = cands.find(e => /新聊天|New chat/i.test((e.innerText||e.getAttribute('aria-label')||'').trim()));
  if (!el) return {ok:false};
  el.click();
  return {ok:true, label:(el.innerText||el.getAttribute('aria-label')||'').trim()};
})()
"""
        )
        time.sleep(1.0)
        _ime_safe_fill_and_send(sess, bootstrap)
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            time.sleep(0.5)
            href = sess.evaluate("location.href")
            if isinstance(href, str) and CONTROL_URL_RE.match(href):
                if forbid_substring and forbid_substring in href:
                    continue
                return href
            # Also scan all tabs — SPA may open/update another target.
            for t in list_tabs(cdp):
                u = t.get("url") or ""
                if CONTROL_URL_RE.match(u) and not (forbid_substring and forbid_substring in u):
                    # Prefer URLs that appeared after bootstrap (not the forbidden calendar one).
                    if forbid_substring and forbid_substring in u:
                        continue
                    # If multiple, prefer non-calendar; return first matching new-looking id
                    if u.rstrip("/") != "https://chatgpt.com":
                        # Ensure it's not an old known calendar if forbid set
                        return u
        raise CdpError(
            "timed out waiting for /c/<id> after bootstrap (clicked=%r). "
            "Confirm CDP Chrome is logged in; if IME still sticks, restart with: "
            "python3 cdp_chat.py ensure-cdp --restart" % (clicked,)
        )
    finally:
        sess.close()


def cmd_ensure_cdp(args: argparse.Namespace) -> int:
    if args.restart:
        kill_cdp_chrome(Path(args.profile))
        time.sleep(0.5)
    if cdp_up(args.cdp) and not args.restart:
        print("CDP_OK", args.cdp)
        return 0
    launch_cdp_chrome(profile=Path(args.profile), state=Path(args.state), start_url=args.url)
    print("CDP_STARTED", args.cdp, "profile=", args.profile)
    print("HINT: if ChatGPT asks to login, sign in once in this CDP Chrome window")
    return 0


def cmd_new_chat(args: argparse.Namespace) -> int:
    url = new_chat(
        cdp=args.cdp,
        forbid_substring=args.forbid_substring,
        bootstrap=args.bootstrap,
        timeout_s=args.timeout,
    )
    print(url)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("ensure-cdp", help="start CDP Chrome with IME disabled")
    e.add_argument("--cdp", default=CDP_DEFAULT)
    e.add_argument("--profile", default=str(PROFILE_DEFAULT))
    e.add_argument("--state", default=str(STATE_DEFAULT))
    e.add_argument("--url", default="https://chatgpt.com/")
    e.add_argument("--restart", action="store_true", help="kill CDP-profile Chrome and relaunch")
    e.set_defaults(func=cmd_ensure_cdp)

    n = sub.add_parser("new-chat", help="create a fresh ChatGPT /c/<id> conversation")
    n.add_argument("--cdp", default=CDP_DEFAULT)
    n.add_argument("--forbid-substring", default=None, help="reject URLs containing this (e.g. calendar id)")
    n.add_argument(
        "--bootstrap",
        default="AEGL dual-link control chat bootstrap. Reply with READY only. No Hermes control blocks.",
    )
    n.add_argument("--timeout", type=float, default=45.0)
    n.set_defaults(func=cmd_new_chat)

    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except CdpError as exc:
        print("ERROR:", exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
