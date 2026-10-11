#!/usr/bin/env bash
# host-identity-bootstrap.sh — scope-limited, one-shot host privilege bootstrap for the
# AEGL AI boundary. DRY-RUN BY DEFAULT: it prints the exact commands and changes nothing
# unless `--apply` is given AND the caller is root.
#
# It implements ONLY an identity boundary (users/groups + ownership/mode + minimal
# traversal). It does NOT: create backups/snapshots, read or store passwords, make
# `bwrap` setuid, open the whole home, or expose the canonical `.git`.
#
# Run it from a trusted terminal:
#     sudo bash recovery/host-identity-bootstrap.sh --plan     # review (no changes)
#     sudo bash recovery/host-identity-bootstrap.sh --apply    # perform + verify
set -euo pipefail

MODE=plan
case "${1:-}" in
  ""|--plan) MODE=plan ;;
  --apply)   MODE=apply ;;
  *) echo "usage: $0 [--plan|--apply]"; exit 2 ;;
esac

# ------------------------------------------------------------------ identities
AI_USER="aegl-ai"            # the AI: no shell, no sudo, no write on canonical trees
PROMOTE_USER="aegl-promote"  # trusted promotion owner (a real USER, not just a group)
RO_GROUP="aegl-ro"           # read-only project access (AI + the human operator)
OPERATOR_USER="${SUDO_USER:-zhong}"
AI_STATE_ROOT="/var/lib/aegl-ai"   # the AI's own state/scratch root

# ------------------------------------------------------------------ manifest
# EXACT paths this program may touch. Anything else is refused.
PROJECTS=(
  "/home/zhong/Projects/Google-Android-Agent-Development-Stack"
  "/home/zhong/Projects/KeepLab-Relay"
  "/home/zhong/Projects/AI-Engineering-Governance-Layer"
)
TRAVERSE_PARENTS=( "/home/zhong" "/home/zhong/Projects" )

ROOT_UID=0
say(){ printf '%s\n' "$*"; }
phase(){ printf '\n== %s ==\n' "$*"; }
die(){ printf 'BLOCKED: %s\n' "$*" >&2; exit 1; }

# run <cmd...> : print the exact command; execute only in apply mode
run(){ printf '  $ %s\n' "$*"; [ "$MODE" = apply ] && "$@"; return 0; }

# ------------------------------------------------------------------ preflight
preflight() {
  phase "preflight (fail-closed)"
  [ "$MODE" = apply ] && [ "$(id -u)" != "$ROOT_UID" ] && die "--apply requires root (run with sudo)"
  local p
  for p in "${PROJECTS[@]}" "${TRAVERSE_PARENTS[@]}"; do
    [ -e "$p" ] || die "manifest path missing: $p"
    [ -L "$p" ] && die "manifest path is a symlink (refused): $p"
    case "$p/" in
      /home/zhong/Projects/*|/home/zhong/ | /home/zhong/Projects/) : ;;
      *) die "path outside the approved manifest: $p" ;;
    esac
  done
  say "  ok: manifest paths exist and are real directories"
  # 'useradd' must not be asked to create an existing account
  if id "$AI_USER" >/dev/null 2>&1; then say "  note: user $AI_USER already exists (creation step will be skipped)"; fi
  if id "$PROMOTE_USER" >/dev/null 2>&1; then say "  note: user $PROMOTE_USER already exists (creation step will be skipped)"; fi
}

# ------------------------------------------------------------------ step 1: identities
plan_identities() {
  phase "1. identities"
  say "  intent: $AI_USER has no shell/sudo and no write on canonical trees;"
  say "          $PROMOTE_USER owns the canonical trees; $RO_GROUP grants read-only access"
  say "          to $AI_USER and the operator ($OPERATOR_USER)."
  if id "$AI_USER" >/dev/null 2>&1; then say "  pre-check: $AI_USER exists -> skip useradd"
  else run useradd --system --no-create-home --shell /usr/sbin/nologin "$AI_USER"; fi
  if id "$PROMOTE_USER" >/dev/null 2>&1; then say "  pre-check: $PROMOTE_USER exists -> skip useradd"
  else run useradd --system --no-create-home --shell /usr/sbin/nologin "$PROMOTE_USER"; fi
  getent group "$RO_GROUP" >/dev/null || run groupadd --system "$RO_GROUP"
  run usermod -aG "$RO_GROUP" "$AI_USER"
  run usermod -aG "$RO_GROUP" "$OPERATOR_USER"
  run install -d -o "$AI_USER" -g "$AI_USER" -m 0700 "$AI_STATE_ROOT"
  say "  fail-closed: abort if any account command fails (set -e); nothing is deleted"
  say "  verify (after apply):"
  say "    id $AI_USER ; id $PROMOTE_USER ; getent group $RO_GROUP ; stat -c '%a %U:%G' $AI_STATE_ROOT"
}

# ------------------------------------------------------------------ step 2: traversal
plan_traverse() {
  phase "2. parent traversal (minimum: execute-only, no list/read)"
  say "  why: /home/zhong is 750 zhong:zhong, so other uids cannot enter it at all."
  local p
  for p in "${TRAVERSE_PARENTS[@]}"; do
    say "  current: $(stat -c '%a %U:%G' "$p")  $p"
    run setfacl -m "u:$AI_USER:--x" -m "u:$PROMOTE_USER:--x" "$p"
  done
  say "  fail-closed: abort if setfacl is unavailable or fails; mode bits are NOT changed"
  say "  verify (after apply): getfacl -p /home/zhong /home/zhong/Projects"
}

# ------------------------------------------------------------------ step 3: trees
plan_trees() {
  phase "3. canonical projects + .git (owner-only git metadata; group read-only tree)"
  local root d count
  for root in "${PROJECTS[@]}"; do
    say "  --- $root"
    say "  current: $(stat -c '%a %U:%G' "$root")"
    # pre-check: no symlinks crossing out of the root; count node classes
    local dirs files execs links escapes
    dirs=$(find -P "$root" -type d 2>/dev/null | wc -l)
    files=$(find -P "$root" -type f 2>/dev/null | wc -l)
    execs=$(find -P "$root" -type f -perm -u+x 2>/dev/null | wc -l)
    links=$(find -P "$root" -type l 2>/dev/null | wc -l)
    escapes=$(find -P "$root" -type l 2>/dev/null | while read -r l; do
      t="$(readlink -f -- "$l" 2>/dev/null || true)"; case "$t" in "$root"/*) : ;; *) echo "$l";; esac
    done | wc -l)
    say "  pre-check: dirs=$dirs files=$files executable=$execs symlinks=$links (escaping=$escapes)"
    [ "$escapes" -gt 0 ] && die "symlink(s) escape $root — review before applying"
    # working tree (excluding .git): dirs 2750 (setgid on DIRECTORIES only);
    # regular files preserve the exec distinction (0750 exec / 0640 plain), no other bits.
    run find -P "$root" -path "$root/.git" -prune -o -type d -exec chown "$PROMOTE_USER:$RO_GROUP" {} + -exec chmod 2750 {} +
    run find -P "$root" -path "$root/.git" -prune -o -type f -perm -u+x -exec chown "$PROMOTE_USER:$RO_GROUP" {} + -exec chmod 0750 {} +
    run find -P "$root" -path "$root/.git" -prune -o -type f ! -perm -u+x -exec chown "$PROMOTE_USER:$RO_GROUP" {} + -exec chmod 0640 {} +
    # git metadata: owner-only, no group at all (the AI must not read or write canonical .git)
    if [ -e "$root/.git" ]; then
      run find -P "$root/.git" -type d -exec chown "$PROMOTE_USER:$PROMOTE_USER" {} + -exec chmod 2700 {} +
      run find -P "$root/.git" -type f -perm -u+x -exec chown "$PROMOTE_USER:$PROMOTE_USER" {} + -exec chmod 0700 {} +
      run find -P "$root/.git" -type f ! -perm -u+x -exec chown "$PROMOTE_USER:$PROMOTE_USER" {} + -exec chmod 0600 {} +
    fi
    say "  notes: dirs get setgid only; regular files keep their exec distinction (0750/0640);"
    say "         symlinks are never chowned/chmodded (find ! -type l); no -R broad recursion."
    say "  fail-closed: abort on the first failing batch; already-changed nodes are NOT rolled back"
    say "               (re-run --plan/--apply is idempotent because each step re-checks)."
    say "  verify (after apply):"
    say "    find -P '$root' -maxdepth 1 -printf '%m %u:%g %p\\n'"
    say "    runuser -u $AI_USER      -- test -w '$root'   # expect FAILURE (non-zero)"
    say "    runuser -u $OPERATOR_USER -- test -w '$root'   # expect FAILURE (non-zero)"
    say "    runuser -u $PROMOTE_USER -- test -w '$root'   # expect SUCCESS"
    say "    find -P '$root/.git' -maxdepth 1 -printf '%m %u:%g %p\\n'   # expect 2700 aegl-promote"
  done
}

# ------------------------------------------------------------------ step 4: sandbox note
plan_sandbox_note() {
  phase "4. sandbox prerequisite (NOT performed here)"
  say "  bwrap is left unprivileged (never made setuid). Sandboxed tasks need either"
  say "  unprivileged user namespaces or a subuid/subgid range for $AI_USER:"
  say "    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $AI_USER"
  say "  Add that line only after confirming user namespaces are the actual blocker."
}

main() {
  say "AEGL host identity bootstrap  [mode: $MODE]"
  [ "$MODE" = plan ] && say "DRY-RUN: no changes will be made. Re-run with --apply to execute."
  preflight
  plan_identities
  plan_traverse
  plan_trees
  plan_sandbox_note
  phase "done ($MODE)"
}

main "$@"
