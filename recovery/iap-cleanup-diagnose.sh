#!/usr/bin/env bash
# iap-cleanup-diagnose.sh — READ-ONLY diagnosis of the cleanup preflight (root).
#
# Prints, for each repository: the effective uid, the resolved repository path, the
# ownership/mode of the repo and its .git, and the EXACT git argv with exit code and
# bounded stderr for the preflight queries. It changes nothing and reads no credentials.
set -uo pipefail

STACK_REPO="${STACK_REPO:-/home/zhong/Projects/Google-Android-Agent-Development-Stack}"
AEGL_REPO="${AEGL_REPO:-/home/zhong/Projects/AI-Engineering-Governance-Layer}"
EXPECTED_STACK_TIP="${EXPECTED_STACK_TIP:-0b04e1798fffb17ec78aaf096065b9990ec65b0e}"
EXPECTED_AEGL_TIP="${EXPECTED_AEGL_TIP:-a387a501916600fc8feaab6da249d3a2c4764b8d}"
BRIDGE_STATE="${BRIDGE_STATE:-$HOME/.local/state/google-android-agent-stack/bridge/state.json}"

say() { printf '%s\n' "$*"; }

diag_repo() { # <label> <repo> <ref> <expected>
  local label="$1" repo="$2" ref="$3" want="$4" real st
  say "== $label =="
  say "euid=$(id -u) euser=$(id -un)"
  real="$(realpath -e "$repo" 2>/dev/null)" || { say "repo_unresolved $repo"; return; }
  say "repo=$repo real=$real"
  say "repo_stat=$(stat -c '%U:%G %a' "$real" 2>/dev/null || echo unknown)"
  say "git_stat=$(stat -c '%U:%G %a' "$real/.git" 2>/dev/null || echo unknown)"
  say "argv=git -c safe.directory=$real -C $repo rev-parse $ref"
  st="$(mktemp)"
  err="$(mktemp)"
  git -c "safe.directory=$real" -C "$repo" rev-parse "$ref" >"$st" 2>"$err"
  say "rc=$?"
  say "stdout=$(cat "$st")"
  say "stderr=$(head -c 400 "$err" | tr '\n' ' ')"
  say "expected=$want"
  rm -f "$st" "$err"
}

diag_repo "stack" "$STACK_REPO" "refs/heads/master" "$EXPECTED_STACK_TIP"
diag_repo "aegl"  "$AEGL_REPO"  "refs/heads/main"   "$EXPECTED_AEGL_TIP"
say "== bridge =="
cat "$BRIDGE_STATE" 2>/dev/null || say "bridge_state_unreadable $BRIDGE_STATE"
say "pending_result=$(ls "$(dirname "$BRIDGE_STATE")/pending_result.json" 2>/dev/null || echo absent)"
