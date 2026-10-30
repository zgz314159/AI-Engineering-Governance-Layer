#!/usr/bin/env bash
# iap-cleanup-diagnose.sh — READ-ONLY diagnosis of the cleanup preflight (root).
#
# The Bridge state path is FIXED and absolute; it is never derived from $HOME, sudo's
# HOME, Path.home() or root's ~. Nothing here creates or initialises any state.
# Exit status is non-zero when any fact cannot be established (state missing/unreadable/
# invalid, required fields missing, status/sequence mismatch, or a pending result).
set -uo pipefail

STACK_REPO="${STACK_REPO:-/home/zhong/Projects/Google-Android-Agent-Development-Stack}"
AEGL_REPO="${AEGL_REPO:-/home/zhong/Projects/AI-Engineering-Governance-Layer}"
EXPECTED_STACK_TIP="${EXPECTED_STACK_TIP:-0b04e1798fffb17ec78aaf096065b9990ec65b0e}"
EXPECTED_AEGL_TIP="${EXPECTED_AEGL_TIP:-a387a501916600fc8feaab6da249d3a2c4764b8d}"
# Authoritative, fixed Bridge state directory (overridable only for tests).
BRIDGE_DIR="${BRIDGE_DIR:-/home/zhong/.local/state/google-android-agent-stack/bridge}"
STATE="$BRIDGE_DIR/state.json"
PENDING="$BRIDGE_DIR/pending_result.json"

say() { printf '%s\n' "$*"; }
BAD=0

diag_repo() { # <label> <repo> <ref> <expected>
  local label="$1" repo="$2" ref="$3" want="$4" real st err rc
  say "== $label =="
  say "euid=$(id -u) euser=$(id -un)"
  real="$(realpath -e "$repo" 2>/dev/null)" || { say "repo_unresolved $repo"; BAD=1; return; }
  say "repo=$repo real=$real"
  say "repo_stat=$(stat -c '%U:%G %a' "$real" 2>/dev/null || echo unknown)"
  say "git_stat=$(stat -c '%U:%G %a' "$real/.git" 2>/dev/null || echo unknown)"
  say "argv=git -c safe.directory=$real -C $repo rev-parse $ref"
  st="$(mktemp)"; err="$(mktemp)"
  git -c "safe.directory=$real" -C "$repo" rev-parse "$ref" >"$st" 2>"$err"; rc=$?
  say "rc=$rc"
  say "stdout=$(cat "$st")"
  say "stderr=$(head -c 400 "$err" | tr '\n' ' ')"
  say "expected=$want"
  rm -f "$st" "$err"
  if [ "$rc" -ne 0 ]; then BAD=1; say "GIT_FAILED=$label rc=$rc"; fi
  if [ "$(git -c "safe.directory=$real" -C "$repo" rev-parse "$ref" 2>/dev/null)" != "$want" ]; then
    BAD=1; say "REF_MISMATCH=$label"
  fi
}

diag_bridge() {
  say "== bridge =="
  say "bridge_dir=$BRIDGE_DIR (fixed; not derived from HOME)"
  if [ ! -e "$STATE" ]; then say "bridge_state_missing $STATE"; BAD=1; return; fi
  if [ ! -r "$STATE" ]; then say "bridge_state_unreadable $STATE"; BAD=1; return; fi
  python3 - "$STATE" "$PENDING" <<'PY' || { say "BRIDGE_CHECK=FAIL"; BAD=1; return; }
import json, sys, os
path, pending = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception as exc:
    print("bridge_state_bad_json", type(exc).__name__); raise SystemExit(1)
missing = [k for k in ("status", "expected_sequence") if k not in d]
if missing:
    print("bridge_state_missing_field", ",".join(missing)); raise SystemExit(1)
print("status=%s" % d.get("status"))
print("expected_sequence=%s" % d.get("expected_sequence"))
print("pending_result=%s" % ("present" if os.path.exists(pending) else "absent"))
ok = True
if d.get("status") != "WAITING_FOR_GPT":
    print("bridge_status_mismatch want=WAITING_FOR_GPT"); ok = False
if d.get("expected_sequence") != 5:
    print("bridge_sequence_mismatch want=5"); ok = False
if os.path.exists(pending):
    print("bridge_pending_present"); ok = False
if not ok:
    raise SystemExit(1)
print("BRIDGE_OK=1")
PY
}

diag_repo "stack" "$STACK_REPO" "refs/heads/master" "$EXPECTED_STACK_TIP"
diag_repo "aegl"  "$AEGL_REPO"  "refs/heads/main"   "$EXPECTED_AEGL_TIP"
diag_bridge
say "DIAGNOSIS_RESULT=$([ "$BAD" -eq 0 ] && echo OK || echo FAIL)"
exit "$BAD"
