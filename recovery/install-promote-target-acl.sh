#!/usr/bin/env bash
# install-promote-target-acl.sh — minimal ACL so aegl-promote can FF one project's
# exact target ref (AEGL=main, Stack/KeepLab=master).
#
# Root requesting a promote does NOT change the broker service UID (still aegl-promote).
# This installer grants ONLY what that UID needs for a fast-forward update-ref of
# the project's canonical refs/heads/* — no chown of three projects, no AI
# permission expansion.
#
# Delivery form (piped to bash -s): every input is explicit — --repo, --project,
# --commit (full 40-hex), optional --target-ref / --business-root.
#
#   sudo bash -s -- --repo <AEGL> --project <abs-or-basename> --commit <full-40-hex> \
#     < <(git -C <AEGL> show <full-40-hex>:recovery/install-promote-target-acl.sh)
set -uo pipefail

REPO=""; PROJECT=""; COMMIT=""; TARGET_REF=""; BUSINESS_ROOT=""
POST_OWNER_SWITCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
    --business-root) BUSINESS_ROOT="${2:-}"; shift 2 ;;
    # After host-identity switch, aegl-promote owns the tree and must sync the
    # worktree; do not require "broker cannot write body/objects".
    --post-owner-switch) POST_OWNER_SWITCH=1; shift ;;
    *) printf 'ACL_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

BROKER_USER="aegl-promote"
OPERATOR_USER="${SUDO_USER:-zhong}"
[ "$OPERATOR_USER" = root ] && OPERATOR_USER=zhong
AI_USER="aegl-ai"
# Exact project basenames that may receive promote ACL (not a home-wide root).
ALLOWED_SYSTEM='AI-Engineering-Governance-Layer Google-Android-Agent-Development-Stack'
ALLOWED_BUSINESS='KeepLab-Relay'

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

PROOT="$(cd "$(dirname "$REPO")" && pwd)"
[ -n "$BUSINESS_ROOT" ] || BUSINESS_ROOT="$(cd "$PROOT/.." && pwd)/AppProjects"

# Resolve project path: absolute, system under Projects, or business under AppProjects.
case "$PROJECT" in
  /*) PROJ="$(cd "$PROJECT" && pwd)" ;;
  KeepLab-Relay)
    if [ -d "$BUSINESS_ROOT/KeepLab-Relay" ]; then PROJ="$BUSINESS_ROOT/KeepLab-Relay"
    elif [ -d "$PROOT/KeepLab-Relay" ]; then PROJ="$PROOT/KeepLab-Relay"
    else fail "KeepLab-Relay not found under $BUSINESS_ROOT or $PROOT"; fi
    ;;
  *)  PROJ="$PROOT/$PROJECT" ;;
esac
[ -d "$PROJ/.git" ] || fail "project git dir missing: $PROJ/.git"
BASE="$(basename "$PROJ")"
case " $ALLOWED_SYSTEM $ALLOWED_BUSINESS " in
  *" $BASE "*) ;;
  *) fail "project not in ACL allowlist (got $BASE)" ;;
esac
[ -d "$PROJ/.git" ] && [ ! -f "$PROJ/.git" ] || fail "project .git must be a directory (not a worktree gitfile)"

# Exact target ref (must match promotion_core.PROJECT_TARGET_REFS — no branch rename).
if [ -z "$TARGET_REF" ]; then
  case "$BASE" in
    AI-Engineering-Governance-Layer) TARGET_REF="refs/heads/main" ;;
    Google-Android-Agent-Development-Stack|KeepLab-Relay) TARGET_REF="refs/heads/master" ;;
    *) fail "no canonical target_ref for $BASE" ;;
  esac
fi
case "$TARGET_REF" in
  refs/heads/*) ;;
  *) fail "invalid --target-ref: $TARGET_REF" ;;
esac
BRANCH_NAME="${TARGET_REF#refs/heads/}"

say "AEGL promote target ACL   project=$PROJ target_ref=$TARGET_REF commit=$COMMIT user=$BROKER_USER"

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
if [ "$POST_OWNER_SWITCH" = 1 ]; then
  # Broker already owns .git via host-identity switch. Do not apply named-user
  # r-X on objects (would fight owner write needed for sync/object access).
  # Parent traverse grants above still apply for absolute-path access.
  say "ACL post-owner-switch: skip restrictive named-user ACL on .git (owner bits apply)"
else
  # Non-recursive rwx on .git directory only: create/remove HEAD.lock when the
  # target branch is the current checkout. Do NOT -R write the whole .git tree.
  setfacl -m "u:${BROKER_USER}:rwx" "$GIT" || fail "setfacl .git dir (HEAD.lock)"
  if [ -d "$GIT/objects" ]; then
    setfacl -R -m "u:${BROKER_USER}:r-X" "$GIT/objects" || fail "setfacl objects"
  fi
  for f in config packed-refs; do
    [ -e "$GIT/$f" ] || continue
    setfacl -m "u:${BROKER_USER}:r--" "$GIT/$f" || fail "setfacl $f"
  done
  # HEAD + HEAD reflog: checked-out update-ref locks HEAD and appends logs/HEAD.
  setfacl -m "u:${BROKER_USER}:rw-" "$GIT/HEAD" || fail "setfacl HEAD"
  mkdir -p "$GIT/logs" "$GIT/refs/heads" "$GIT/logs/refs/heads" || fail "mkdir refs/logs"
  if [ ! -e "$GIT/logs/HEAD" ]; then
    touch "$GIT/logs/HEAD" || fail "touch logs/HEAD"
    chown --reference="$GIT" "$GIT/logs/HEAD" 2>/dev/null || true
  fi
  setfacl -m "u:${BROKER_USER}:r-x" "$GIT/logs" || fail "setfacl logs"
  setfacl -m "u:${BROKER_USER}:rw-" "$GIT/logs/HEAD" || fail "setfacl logs/HEAD"
  setfacl -m "u:${BROKER_USER}:r-x" "$GIT/refs" || fail "setfacl refs"
  setfacl -m "u:${BROKER_USER}:rwx" "$GIT/refs/heads" || fail "setfacl refs/heads"
  setfacl -m "u:${BROKER_USER}:r-x" "$GIT/logs/refs" 2>/dev/null || true
  setfacl -m "u:${BROKER_USER}:rwx" "$GIT/logs/refs/heads" || fail "setfacl logs/refs/heads"
  if [ -e "$GIT/refs/heads/$BRANCH_NAME" ]; then
    setfacl -m "u:${BROKER_USER}:rw-" "$GIT/refs/heads/$BRANCH_NAME" || fail "setfacl refs/heads/$BRANCH_NAME"
  fi
  if [ -e "$GIT/logs/refs/heads/$BRANCH_NAME" ]; then
    setfacl -m "u:${BROKER_USER}:rw-" "$GIT/logs/refs/heads/$BRANCH_NAME" || fail "setfacl logs/$BRANCH_NAME"
  fi
fi

TIP_OID="$(runuser -u "$BROKER_USER" -- git \
  -c "safe.directory=$PROJ" \
  -c "core.hooksPath=/dev/null" \
  -c "core.fsmonitor=false" \
  -c "core.attributesFile=/dev/null" \
  -C "$PROJ" rev-parse --verify "$TARGET_REF" 2>/dev/null)" \
  || fail "aegl-promote cannot rev-parse $TARGET_REF (traverse/read ACL or safe.directory incomplete)"
[ "${#TIP_OID}" -eq 40 ] || fail "unexpected tip oid"

# Never create/remove HEAD.lock here — preserve any existing lock; fail closed.
[ ! -e "$GIT/HEAD.lock" ] \
  || fail "HEAD.lock already present; refusing to disturb it: $GIT/HEAD.lock"
# Non-destructive permission checks only. Lock creation is proven by throwaway
# cross-UID CAS (exec step 0b), not by probing formal repos.
runuser -u "$BROKER_USER" -- bash --noprofile --norc \
  -c 'builtin test -w "$1"' _ "$GIT" \
  || fail "aegl-promote cannot write .git directory (required for HEAD.lock)"
runuser -u "$BROKER_USER" -- bash --noprofile --norc \
  -c 'builtin test -w "$1"' _ "$GIT/logs/HEAD" \
  || fail "aegl-promote cannot write logs/HEAD"

if [ "$POST_OWNER_SWITCH" = 1 ]; then
  # Owner-switch world: broker may write body/objects (needed for formal sync).
  # Non-privileged identities must still be denied write.
  if runuser -u "$OPERATOR_USER" -- bash --noprofile --norc \
       -c 'builtin test -w "$1"' _ "$PROJ" 2>/dev/null; then
    fail "operator can write project root after post-owner-switch ACL"
  fi
  if runuser -u "$AI_USER" -- bash --noprofile --norc \
       -c 'builtin test -w "$1"' _ "$PROJ" 2>/dev/null; then
    fail "aegl-ai can write project root after post-owner-switch ACL"
  fi
  runuser -u "$BROKER_USER" -- bash --noprofile --norc \
    -c 'builtin test -w "$1"' _ "$PROJ" \
    || fail "aegl-promote cannot write project root after owner switch (sync requires it)"
  say "ACL_RESULT=OK mode=post-owner-switch project=$BASE target_ref=$TARGET_REF tip=$TIP_OID user=$BROKER_USER head_lock=perm_ok broker_worktree_write=expected"
else
  if runuser -u "$BROKER_USER" -- touch "$PROJ/.aegl-acl-probe" 2>/dev/null; then
    rm -f "$PROJ/.aegl-acl-probe"
    fail "aegl-promote can write project worktree — ACL too broad (use --post-owner-switch after identity switch)"
  fi
  if runuser -u "$BROKER_USER" -- touch "$GIT/objects/.aegl-acl-probe" 2>/dev/null; then
    rm -f "$GIT/objects/.aegl-acl-probe"
    fail "aegl-promote can write .git/objects — ACL too broad"
  fi
  say "ACL_RESULT=OK project=$BASE target_ref=$TARGET_REF tip=$TIP_OID user=$BROKER_USER head_lock=perm_ok head_reflog=perm_ok"
fi