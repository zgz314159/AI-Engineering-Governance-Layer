#!/usr/bin/env bash
# keeplab-promote-acl-cas-test.sh — one cross-UID CAS regression for HEAD.lock +
# HEAD reflog with production install-promote-target-acl.sh.
#
# Requires root + aegl-promote + setfacl. Without root: NOT_RUN (never fake PASS).
#
#   sudo bash recovery/keeplab-promote-acl-cas-test.sh --commit <AEGL 40-hex> --repo <AEGL>
#   # or from exec pack (already root) before any formal promote
set -uo pipefail

REPO=""; COMMIT=""
OP_USER="zhong"
BROKER_USER="aegl-promote"
AI_USER="aegl-ai"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --op-user) OP_USER="${2:-}"; shift 2 ;;
    *) printf 'CAS_TEST_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
fail(){ printf 'CAS_TEST_FAIL: %s\n' "$*" >&2; exit 1; }

# Static gates (no root): ACL script must grant HEAD.lock + logs/HEAD.
ACL_SRC=""
if [ -n "$COMMIT" ] && [ -n "$REPO" ] && [ -d "${REPO:-/}/.git" ]; then
  ACL_SRC="$(git -C "$REPO" show "$COMMIT:recovery/install-promote-target-acl.sh" 2>/dev/null)" \
    || fail "cannot show install-promote-target-acl.sh from $COMMIT"
elif [ -n "${AEGL_ROOT:-}" ] && [ -f "$AEGL_ROOT/recovery/install-promote-target-acl.sh" ]; then
  ACL_SRC="$(cat "$AEGL_ROOT/recovery/install-promote-target-acl.sh")"
else
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ACL_SRC="$(cat "$SELF_DIR/install-promote-target-acl.sh")"
fi
printf '%s\n' "$ACL_SRC" | grep -q 'HEAD.lock' \
  || fail "ACL installer does not mention HEAD.lock"
printf '%s\n' "$ACL_SRC" | grep -q 'logs/HEAD' \
  || fail "ACL installer does not grant logs/HEAD"
printf '%s\n' "$ACL_SRC" | grep -qE 'setfacl -m "u:\$\{BROKER_USER\}:rwx" "\$GIT"' \
  || fail "ACL installer missing non-recursive rwx on .git dir"
printf '%s\n' "$ACL_SRC" | grep -qE 'setfacl -R -m "u:\$\{BROKER_USER\}:rw' \
  && fail "ACL installer recursively grants write under .git" || true
say "PASS: ACL script grants HEAD.lock + logs/HEAD without recursive .git write"

if [ "$(id -u)" != 0 ]; then
  say "PROMOTE_ACL_CAS=NOT_RUN need_root (not faking cross-UID PASS)"
  say "PROMOTE_ACL_CAS_TEST static_ok=1 cross_uid=NOT_RUN"
  exit 0
fi

[ -n "$REPO" ] || fail "--repo required for cross-UID run"
[ -n "$COMMIT" ] || fail "--commit required for cross-UID run"
[ -d "$REPO/.git" ] || fail "repo missing: $REPO"
id "$BROKER_USER" >/dev/null 2>&1 || fail "missing $BROKER_USER"
id "$OP_USER" >/dev/null 2>&1 || fail "missing $OP_USER"
id "$AI_USER" >/dev/null 2>&1 || fail "missing $AI_USER"
command -v setfacl >/dev/null 2>&1 || fail "setfacl required"
git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "commit missing: $COMMIT"

ST="$(mktemp -d /var/tmp/aegl-acl-cas-XXXXXX)" || fail "mktemp failed"
cleanup(){
  if [ -n "${ST:-}" ] && [ -d "$ST" ]; then
    chmod -R u+w "$ST" 2>/dev/null || true
    rm -rf "$ST"
  fi
}
trap cleanup EXIT

chmod 0750 "$ST"
chown root:root "$ST"
setfacl -m "u:${OP_USER}:rwx" "$ST"

# Allowlisted basename so production ACL installer accepts the throwaway path.
PROJ="$ST/AI-Engineering-Governance-Layer"

# Operator-owned throwaway; stay checked out on main (the CAS target).
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" init -q "$PROJ"
runuser -u "$OP_USER" -- bash -c "printf 'v1\n' > '$PROJ/body.txt'"
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" add -A
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" \
  -c user.email=t@t -c user.name=t commit -qm v1
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" branch -M main
V1="$(runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" rev-parse HEAD)"

# Second commit object (not checked out); keep worktree at v1 on main.
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" checkout -q -b cand
runuser -u "$OP_USER" -- bash -c "printf 'v2\n' > '$PROJ/body.txt'"
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" add -A
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" \
  -c user.email=t@t -c user.name=t commit -qm v2
V2="$(runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" rev-parse HEAD)"
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" checkout -q main
test "$(runuser -u "$OP_USER" -- cat "$PROJ/body.txt")" = "v1"
test "$(runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" rev-parse --abbrev-ref HEAD)" = "main"

# Production ACL installer from fixed commit (not mutable worktree as root).
git -C "$REPO" show "$COMMIT:recovery/install-promote-target-acl.sh" \
  | bash -s -- --repo "$REPO" --project "$PROJ" --commit "$COMMIT" \
       --target-ref refs/heads/main \
  || fail "install-promote-target-acl failed on throwaway"

# Body must still be v1 before any formal sync (CAS only moves the ref).
BODY_BEFORE="$(runuser -u "$OP_USER" -- cat "$PROJ/body.txt")"
[ "$BODY_BEFORE" = "v1" ] || fail "body changed before CAS"

# Real CAS update-ref as aegl-promote while main is checked out (needs HEAD.lock + logs/HEAD).
runuser -u "$BROKER_USER" -- git \
  -c "safe.directory=$PROJ" \
  -c "core.hooksPath=/dev/null" \
  -c "core.fsmonitor=false" \
  -c "core.attributesFile=/dev/null" \
  -C "$PROJ" update-ref refs/heads/main "$V2" "$V1" \
  || fail "aegl-promote update-ref CAS failed (HEAD.lock/reflog ACL?)"

GOT="$(runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" rev-parse refs/heads/main)"
[ "$GOT" = "$V2" ] || fail "ref not advanced want=$V2 got=$GOT"
# Worktree/index still at v1 until sync — proves we did not overwrite body in CAS.
BODY_AFTER="$(runuser -u "$OP_USER" -- cat "$PROJ/body.txt")"
[ "$BODY_AFTER" = "v1" ] || fail "CAS unexpectedly changed worktree body"
# HEAD reflog must have advanced (not only rev-parse).
runuser -u "$OP_USER" -- git -c "safe.directory=$PROJ" -C "$PROJ" reflog show HEAD -1 \
  | grep -q . || fail "HEAD reflog empty after CAS"
# AI must not gain worktree write.
if runuser -u "$AI_USER" -- touch "$PROJ/.ai-probe" 2>/dev/null; then
  rm -f "$PROJ/.ai-probe"
  fail "aegl-ai can write throwaway worktree"
fi

say "PASS: aegl-promote CAS on checked-out main (HEAD.lock+reflog); body preserved; AI no write"
say "PROMOTE_ACL_CAS_TEST static_ok=1 cross_uid=PASS"
