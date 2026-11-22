#!/usr/bin/env bash
# Ensure Chrome CDP :9333 is up (IME-disabled automation profile) and the bound
# control ChatGPT URL is open. Does not send HERMES_TASK_V1.
set -euo pipefail
ROOT=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
STATE=${AEGL_DUAL_LINK_STATE:-$HOME/.local/state/aegl-dual-link}
PROFILE=${AEGL_CDP_PROFILE:-$HOME/.local/share/aegl-dual-link/chrome-cdp-profile}
CDP=${CDP:-http://127.0.0.1:9333}
CWD=${1:-$PWD}
RESTART=0
[[ ${2:-} == --restart || ${1:-} == --restart ]] && RESTART=1
[[ ${1:-} == --restart ]] && CWD=$PWD

mkdir -p "$STATE" "$PROFILE"

if [[ $RESTART -eq 1 ]]; then
  python3 "$ROOT/cdp_chat.py" ensure-cdp --restart --profile "$PROFILE" --state "$STATE" --cdp "$CDP"
else
  python3 "$ROOT/cdp_chat.py" ensure-cdp --profile "$PROFILE" --state "$STATE" --cdp "$CDP"
fi

# Map cwd wins — ignore leftover HERMES_CHATGPT_CONTROL_URL from other sessions.
CTRL=$(python3 "$ROOT/project_control.py" resolve --cwd "$CWD" --no-env 2>/dev/null || true)
if [[ -z ${CTRL:-} ]]; then
  echo "CONTROL_UNBOUND for cwd=$CWD — create a chat then bind-control:" >&2
  echo "  python3 $ROOT/cdp_chat.py new-chat --forbid-substring 6ac4d058" >&2
  echo "  $ROOT/dual-link-operator.sh bind-control --cwd $CWD --url '<new-url>' --aegl-project <Name>" >&2
  exit 2
fi

python3 - "$CDP" "$CTRL" <<'PY'
import json, sys, urllib.request, urllib.parse
cdp, ctrl = sys.argv[1], sys.argv[2]
tabs = json.load(urllib.request.urlopen(cdp + "/json/list", timeout=3))
hits = [t for t in tabs if ctrl in (t.get("url") or "")]
if hits:
    print(f"CONTROL_TAB_OK hits={len(hits)} url={ctrl}")
    sys.exit(0)
req = urllib.request.Request(
    cdp + "/json/new?" + urllib.parse.quote(ctrl, safe=":/?=&"), method="PUT"
)
try:
    page = json.load(urllib.request.urlopen(req, timeout=5))
    print("CONTROL_TAB_OPENED id=%s" % page.get("id"))
except Exception as e:
    print("CONTROL_TAB_OPEN_FAILED", e, file=sys.stderr)
    sys.exit(3)
tabs = json.load(urllib.request.urlopen(cdp + "/json/list", timeout=3))
hits = [t for t in tabs if ctrl in (t.get("url") or "")]
if hits:
    print(f"CONTROL_TAB_OK hits={len(hits)}")
    sys.exit(0)
print("CONTROL_TAB_NEEDS_LOGIN — sign in once in the CDP Chrome window, then re-run")
print("control_url=", ctrl)
sys.exit(4)
PY
