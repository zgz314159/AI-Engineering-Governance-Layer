#!/usr/bin/env bash
# install-promote-target-acl.sh — minimal ACL so aegl-promote can FF one project's main.
#
# Root requesting a promote does NOT change the broker service UID (still aegl-promote).
# This installer grants ONLY what that UID needs for a fast-forward update-ref of
# refs/heads/main on ONE allowlisted project — no chown of three projects, no AI
# permission expansion.
#
# Required capability (aegl-promote):
#   traverse: --x on each path component from / to <project>
#   read:     r-X on <project>/.git, objects, refs, packed-refs, HEAD, config
#   write:    rwx on .git/refs/heads and .git/logs/refs/heads (CAS update-ref + reflog)
#
# Delivery form (piped to bash -s): every input is explicit — --repo, --project,
# --commit (full 40-hex). Nothing is derived from $BASH_SOURCE. Validated before
# any host change. Never executes a mutable worktree script as root.
#
#   sudo bash -s -- --repo <AEGL> --project <AEGL-abs-or-basename> --commit <full-40-hex> \
#     < <(git -C <AEGL> show <full-40-hex>:recovery/install-promote-target-acl.sh)
set -uo pipefail

REPO=""; PROJECT=""; COMMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    *) printf 'ACL_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

BROKER_USER="aegl-promote"
ALLOWED='AI-Engineering-Governance-Layer'

say(){ printf '%s\n' "$*"; }
fail(){ printf 'ACL_ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "must run as root"
[ -n "$REPO" ] || fail "--repo is required"
[ -n "$PROJECT" ] || fail "--project is required"
[ -n "$COMMIT" ] || fail "--commit is required"
[ -d "$REPO/.git" ] || fail "--repo is not a git repository: $REPO"
case "$COMMIT" in
  [0-9a-f]*) : ;;
  *) fail "--commit must be a full 40-hex commit id" ;;
esac
[ "${#COMMIT}" -eq 40 ] || fail "--commit must be a full 40-hex commit id (got ${#COMMIT} chars)"
git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "commit not found in $REPO: $COMMIT"
git -C "$REPO" cat-file -e "$COMMIT:recovery/install-promote-target-acl.sh" 2>/dev/null \
  || fail "installer missing in commit: recovery/install-promote-target-acl.sh"
id "$BROKER_USER" >/dev/null 2>&1 || fail "broker user missing: $BROKER_USER (install broker first)"
command -v setfacl >/dev/null 2>&1 || fail "setfacl required (acl package)"

# Resolve project to an absolute path under the same parent as REPO (Projects root).
PROOT="$(cd "$(dirname "$REPO")" && pwd)"
case "$PROJECT" in
  /*) PROJ="$(cd "$PROJECT" && pwd)" ;;
  *)  PROJ="$PROOT/$PROJECT" ;;
esac
[ -d "$PROJ/.git" ] || fail "project git dir missing: $PROJ/.git"
BASE="$(basename "$PROJ")"
[ "$BASE" = "$ALLOWED" ] || fail "project not in ACL allowlist (got $BASE; allow $ALLOWED)"
# Refuse symlink .git (worktree gitfile) — ACL must hit the real object store.
[ -d "$PROJ/.git" ] && [ ! -f "$PROJ/.git" ] || fail "project .git must be a directory (not a worktree gitfile)"

say "AEGL promote target ACL   project=$PROJ commit=$COMMIT user=$BROKER_USER"

# Traverse each path component from filesystem root to the project — execute-only.
# Do not grant list/read on home; only the path components needed to reach .git.
grant_x(){
  local p="$1"
  [ -e "$p" ] || fail "missing path for traverse: $p"
  setfacl -m "u:${BROKER_USER}:--x" "$p" || fail "setfacl traverse failed: $p"
}
cur="$PROJ"
while [ "$cur" != "/" ]; do
  grant_x "$cur"
  cur="$(dirname "$cur")"
done

GIT="$PROJ/.git"
setfacl -m "u:${BROKER_USER}:r-x" "$GIT" || fail "setfacl .git"
# objects / info: read (verify commit); refs/heads + logs: write for update-ref CAS
if [ -d "$GIT/objects" ]; then
  setfacl -R -m "u:${BROKER_USER}:r-X" "$GIT/objects" || fail "setfacl objects"
fi
for f in HEAD config packed-refs; do
  [ -e "$GIT/$f" ] || continue
  setfacl -m "u:${BROKER_USER}:r--" "$GIT/$f" || fail "setfacl $f"
done
mkdir -p "$GIT/refs/heads" "$GIT/logs/refs/heads" || fail "mkdir refs"
setfacl -m "u:${BROKER_USER}:r-x" "$GIT/refs" || fail "setfacl refs"
setfacl -m "u:${BROKER_USER}:rwx" "$GIT/refs/heads" || fail "setfacl refs/heads"
setfacl -m "u:${BROKER_USER}:r-x" "$GIT/logs" 2>/dev/null || true
setfacl -m "u:${BROKER_USER}:r-x" "$GIT/logs/refs" 2>/dev/null || true
setfacl -m "u:${BROKER_USER}:rwx" "$GIT/logs/refs/heads" || fail "setfacl logs/refs/heads"
if [ -e "$GIT/refs/heads/main" ]; then
  setfacl -m "u:${BROKER_USER}:rw-" "$GIT/refs/heads/main" || fail "setfacl refs/heads/main"
fi
if [ -e "$GIT/logs/refs/heads/main" ]; then
  setfacl -m "u:${BROKER_USER}:rw-" "$GIT/logs/refs/heads/main" || fail "setfacl logs/main"
fi

# Bounded check: broker can resolve main; cannot write project worktree files.
# Command-level safe.directory for this exact project only (no glob, no global config).
MAIN_OID="$(runuser -u "$BROKER_USER" -- git \
  -c "safe.directory=$PROJ" \
  -c "core.hooksPath=/dev/null" \
  -c "core.fsmonitor=false" \
  -c "core.attributesFile=/dev/null" \
  -C "$PROJ" rev-parse --verify refs/heads/main 2>/dev/null)" \
  || fail "aegl-promote cannot rev-parse refs/heads/main (traverse/read ACL or safe.directory incomplete)"
[ "${#MAIN_OID}" -eq 40 ] || fail "unexpected main oid"
# Must NOT be able to create a file in the project worktree as aegl-promote.
if runuser -u "$BROKER_USER" -- test -w "$PROJ"; then
  # writable worktree root is unexpected for this minimal ACL — warn but only fail
  # if create succeeds (we never grant write on $PROJ itself above).
  :
fi
if runuser -u "$BROKER_USER" -- touch "$PROJ/.aegl-acl-probe" 2>/dev/null; then
  rm -f "$PROJ/.aegl-acl-probe"
  fail "aegl-promote can write project worktree — ACL too broad"
fi

say "ACL_RESULT=OK project=$BASE main=$MAIN_OID user=$BROKER_USER"
