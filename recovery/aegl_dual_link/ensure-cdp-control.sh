#!/usr/bin/env bash
# Ensure Chrome CDP :9333 is up and the bound control ChatGPT URL is open.
# Safe to re-run. Does not send HERMES_TASK_V1. Does not kill the user's main Chrome.
set -euo pipefail
ROOT=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
STATE=${AEGL_DUAL_LINK_STATE:-$HOME/.local/state/aegl-dual-link}
PROFILE=${AEGL_CDP_PROFILE:-$HOME/.local/share/aegl-dual-link/chrome-cdp-profile}
CDP=${CDP:-http://127.0.0.1:9333}
mkdir -p "$STATE" "$PROFILE"

CTRL=$(python3 "$ROOT/project_control.py" resolve --cwd "${1:-$PWD}" 2>/dev/null || true)
if [[ -z ${CTRL:-} ]]; then
  echo "CONTROL_UNBOUND — bind-control first for cwd=${1:-$PWD}" >&2
  exit 2
fi

if ! curl -sS --max-time 2 "$CDP/json/list" >/dev/null; then
  echo "Starting Chrome with --remote-debugging-port=9333 (dedicated profile)..."
  nohup google-chrome-stable \
    --remote-debugging-port=9333 \
    --user-data-dir="$PROFILE" \
    --no-first-run --no-default-browser-check \
    "$CTRL" >>"$STATE/chrome-cdp.log" 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    curl -sS --max-time 1 "$CDP/json/list" >/dev/null 2>&1 && break
  done
fi

python3 - "$CDP" "$CTRL" <<'PY'
import json, sys, urllib.request, urllib.parse
cdp, ctrl = sys.argv[1], sys.argv[2]
tabs = json.load(urllib.request.urlopen(cdp + "/json/list", timeout=3))
hits = [t for t in tabs if ctrl in (t.get("url") or "")]
if hits:
    print(f"CONTROL_TAB_OK hits={len(hits)} url={ctrl}")
    sys.exit(0)
# Open a new tab at the control URL (user may still need to log in on fresh profiles).
req = urllib.request.Request(
    cdp + "/json/new?" + urllib.parse.quote(ctrl, safe=":/?=&"), method="PUT"
)
try:
    page = json.load(urllib.request.urlopen(req, timeout=5))
    print("CONTROL_TAB_OPENED id=%s — if ChatGPT asks to 登录, sign in in that Chrome window" % page.get("id"))
except Exception as e:
    print("CONTROL_TAB_OPEN_FAILED", e, file=sys.stderr)
    print("Manually open:", ctrl, file=sys.stderr)
    sys.exit(3)
# Re-check (SPA may redirect until logged in)
tabs = json.load(urllib.request.urlopen(cdp + "/json/list", timeout=3))
hits = [t for t in tabs if ctrl in (t.get("url") or "")]
if hits:
    print(f"CONTROL_TAB_OK hits={len(hits)}")
    sys.exit(0)
print("CONTROL_TAB_NEEDS_LOGIN open the CDP Chrome window and log into ChatGPT, then re-run this script")
print("control_url=", ctrl)
sys.exit(4)
PY
