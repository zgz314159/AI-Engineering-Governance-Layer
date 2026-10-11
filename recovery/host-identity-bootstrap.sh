#!/usr/bin/env bash
# host-identity-bootstrap.sh — scope-limited host identity/permission bootstrap for the
# AEGL AI boundary. DRY-RUN BY DEFAULT (mode `plan`). Nothing changes unless the operator
# runs `sudo bash … apply`. No backups/snapshots/archives; no passwords are read or stored.
#
# Modes:
#   plan      (default) print every command and every pre-check; change nothing
#   apply     perform the ONE controlled permission switch, then IMMEDIATELY verify;
#             if verification fails it reverts and exits non-zero
#   verify    run only the acceptance checks (executes; non-zero on failure)
#   selftest  run the acceptance logic against an ISOLATED throwaway tree (unprivileged)
#   revert    undo the permission switch (chattr -i + ownership back), leaving no lock
#
# Design decisions (see HOST-IDENTITY-BOOTSTRAP.md):
#  * the AI user gets NO access to /home/zhong or the canonical projects at all; it works
#    only in its own task checkout root /var/lib/aegl-ai;
#  * the canonical-tree owner is the real USER aegl-promote (the useradd-created group is
#    named explicitly, never assumed);
#  * the writable parent /home/zhong/Projects is owned by aegl-promote and marked
#    IMMUTABLE (chattr +i) so the running `zhong` process cannot rename/delete/replace the
#    project entries through it;
#  * identity + broker are prepared and isolated-tested BEFORE this switch is applied.
set -euo pipefail

MODE=plan
case "${1:-}" in
  ""|--plan|plan) MODE=plan ;;
  apply)          MODE=apply ;;
  verify)         MODE=verify ;;
  selftest)       MODE=selftest ;;
  revert)         MODE=revert ;;
  *) echo "usage: $0 [plan|apply|verify|selftest|revert]"; exit 2 ;;
esac

AI_USER="aegl-ai";    AI_GROUP="aegl-ai"
BROKER_USER="aegl-promote"; BROKER_GROUP="aegl-broker"
HUMAN_GROUP="aegl-ro"                 # read-only access for the human operator only
OPERATOR_USER="${SUDO_USER:-zhong}"
AI_STATE_ROOT="/var/lib/aegl-ai"

PROJECTS_PARENT="/home/zhong/Projects"
HOME_DIR="/home/zhong"
PROJECTS=(
  "$PROJECTS_PARENT/Google-Android-Agent-Development-Stack"
  "$PROJECTS_PARENT/KeepLab-Relay"
  "$PROJECTS_PARENT/AI-Engineering-Governance-Layer"
)

say(){ printf '%s\n' "$*"; }
phase(){ printf '\n== %s ==\n' "$*"; }
die(){ printf 'BLOCKED: %s\n' "$*" >&2; exit 1; }
run(){ printf '  $ %s\n' "$*"; [ "$MODE" = apply ] || [ "$MODE" = revert ] && "$@"; return 0; }

# --------------------------------------------------------------------------- #
# verification (executes; returns non-zero on any violated expectation)
# --------------------------------------------------------------------------- #
VFAIL=0
# as_user <user> <cmd...> : runuser when root (real check); otherwise run directly
# (used by the unprivileged selftest, where the isolated tree is owned by the caller).
as_user(){ if [ "$(id -u)" = 0 ]; then runuser -u "$1" -- "${@:2}"; else "${@:2}"; fi; }
expect_fail(){ printf '    as %-8s %-52s ' "$OPERATOR_USER" "$1"; if as_user "$OPERATOR_USER" "${@:2}" >/dev/null 2>&1; then echo "LEAK (must be denied)"; VFAIL=$((VFAIL+1)); else echo "denied ok"; fi; }
expect_ok(){   printf '    as %-8s %-52s ' "$1" "${*:2}"; if as_user "$1" "${@:2}" >/dev/null 2>&1; then echo "ok"; else echo "FAIL"; VFAIL=$((VFAIL+1)); fi; }

verify_project(){ # verify_project <project>
  local p="$1"
  say "  verify $p"
  expect_fail "write root"       test -w "$p"
  local nested; nested="$(find -P "$p" -path "$p/.git" -prune -o -type f -print -quit 2>/dev/null || true)"
  [ -n "$nested" ] && expect_fail "write nested file" test -w "$nested"
  [ -e "$p/.git" ] && expect_fail "write .git/config" test -w "$p/.git/config"
  expect_ok "$BROKER_USER" test -w "$p"
  expect_fail "immutable parent: create entry"  touch "$PROJECTS_PARENT/aegl-probe-$$"
  expect_fail "immutable parent: rename entry"  mv "$p" "$p.aegl-probe-$$"
  [ -e "$p.aegl-probe-$$" ] && { say "    !!! rename SUCCEEDED — restoring"; mv "$p.aegl-probe-$$" "$p" || true; VFAIL=$((VFAIL+1)); }
  printf '    lsattr %-58s ' "$PROJECTS_PARENT"; lsattr -d "$PROJECTS_PARENT" 2>/dev/null | awk '{print $1}'
}
verify_parent_perms(){
  printf '    %-58s ' "parent owner/mode"
  stat -c '%U:%G %a' "$PROJECTS_PARENT"
  local o; o="$(stat -c '%U' "$PROJECTS_PARENT")"
  [ "$o" = "$BROKER_USER" ] || { echo "    (owner is not $BROKER_USER)"; VFAIL=$((VFAIL+1)); }
}
do_verify(){
  phase "verify (executes; non-zero on any leak)"
  verify_parent_perms
  local p; for p in "${PROJECTS[@]}"; do verify_project "$p"; done
  say "  VERIFY_VIOLATIONS=$VFAIL"
  [ "$VFAIL" -eq 0 ] || return 1
}

# --------------------------------------------------------------------------- #
# plan / apply
# --------------------------------------------------------------------------- #
preflight(){
  phase "preflight (fail-closed)"
  [ "$MODE" = apply ] && [ "$(id -u)" != 0 ] && die "apply requires root (run via sudo)"
  local p
  for p in "${PROJECTS[@]}" "$PROJECTS_PARENT" "$HOME_DIR"; do
    [ -e "$p" ] || die "manifest path missing: $p"
    [ -L "$p" ] && die "manifest path is a symlink (refused): $p"
  done
  # mount boundary + hardlink + pre-existing ACL review (no bulk change may touch other inodes)
  say "  mount of $PROJECTS_PARENT: $(findmnt -no FSTYPE --target "$PROJECTS_PARENT")"
  for p in "${PROJECTS[@]}"; do
    local xdev links acl dev
    dev="$(stat -c '%d' "$p")"
    xdev=$(find -P "$p" -type f -printf '%D\n' 2>/dev/null | grep -vc "^${dev}$" || true)
    links=$(find -P "$p" -xdev -type f -links +1 2>/dev/null | wc -l)
    acl=$(getfacl -R -p "$p" 2>/dev/null | grep -c '^user:[^:]' || true)
    say "  $(basename "$p"): cross-mount files=$xdev hardlinked(links>1)=$links explicit-acl-entries=$acl"
    [ "$xdev" = 0 ] || die "path crosses a mount boundary: $p"
    [ "$links" = 0 ] || die "hardlinked files present (a chown would affect inodes outside the manifest): $p"
  done
}

plan_identities(){
  phase "1. identities (explicit groups; useradd is NOT assumed to create them)"
  run groupadd --system "$AI_GROUP"
  run groupadd --system "$BROKER_GROUP"
  run groupadd --system "$HUMAN_GROUP"
  run useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$AI_GROUP" "$AI_USER"
  run useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$BROKER_GROUP" "$BROKER_USER"
  run usermod -aG "$HUMAN_GROUP" "$OPERATOR_USER"
  run install -d -o "$AI_USER" -g "$BROKER_GROUP" -m 2770 "$AI_STATE_ROOT"
  say "  AI access: /var/lib/aegl-ai ONLY. It is NOT added to $HUMAN_GROUP and gets NO ACL"
  say "             on $HOME_DIR or $PROJECTS_PARENT."
  say "  verify: id $AI_USER; id $BROKER_USER; getent group $AI_GROUP $BROKER_GROUP $HUMAN_GROUP"
}

plan_traverse(){
  phase "2. parent traversal — BROKER ONLY (minimum execute-only)"
  say "  current: $(stat -c '%a %U:%G' "$HOME_DIR")  $HOME_DIR   (750 => other uids cannot enter)"
  run setfacl -m "u:$BROKER_USER:--x" "$HOME_DIR"
  run setfacl -m "u:$BROKER_USER:--x" "$PROJECTS_PARENT"
  say "  fail-closed: mode bits unchanged; the AI user gets no ACL here"
}

plan_trees(){
  phase "3. canonical projects (owner=$BROKER_USER, group=$HUMAN_GROUP read-only; .git owner-only)"
  local p
  for p in "${PROJECTS[@]}"; do
    say "  --- $p  (current $(stat -c '%a %U:%G' "$p"))"
    run find -P "$p" -path "$p/.git" -prune -o -type d -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 2750 {} +
    run find -P "$p" -path "$p/.git" -prune -o -type f -perm -u+x -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 0750 {} +
    run find -P "$p" -path "$p/.git" -prune -o -type f ! -perm -u+x -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 0640 {} +
    [ -e "$p/.git" ] || continue
    run find -P "$p/.git" -type d -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 2700 {} +
    run find -P "$p/.git" -type f -perm -u+x -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 0700 {} +
    run find -P "$p/.git" -type f ! -perm -u+x -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 0600 {} +
  done
  say "  setgid on DIRECTORIES only; files keep exec distinction (0750/0640); other bits cleared;"
  say "  symlinks never followed or changed; no chown -R/chmod -R."
}

plan_parent_lock(){
  phase "4. parent-entry lock (kernel-enforced via the immutable attribute)"
  say "  why: $PROJECTS_PARENT is writable by $OPERATOR_USER today, so it can rename/delete"
  say "       or replace the project entries even if it cannot write inside them."
  say "  current: $(stat -c '%a %U:%G' "$PROJECTS_PARENT")  lsattr: $(lsattr -d "$PROJECTS_PARENT" 2>/dev/null | awk '{print $1}')"
  run chown "$BROKER_USER:$HUMAN_GROUP" "$PROJECTS_PARENT"
  run chmod 2755 "$PROJECTS_PARENT"
  run chattr +i "$PROJECTS_PARENT"
  say "  effect: no entry may be created/renamed/deleted under $PROJECTS_PARENT, and the"
  say "          entry itself cannot be renamed/removed — even by its owner."
  say "  verify: lsattr -d $PROJECTS_PARENT   # expect the 'i' flag"
}

plan_revert(){
  phase "revert (undo the permission switch; no lock left behind)"
  run chattr -i "$PROJECTS_PARENT"
  run chown "$OPERATOR_USER:$OPERATOR_USER" "$PROJECTS_PARENT"
  run chmod 0775 "$PROJECTS_PARENT"
  local p; for p in "${PROJECTS[@]}"; do
    run chown -Rh "$OPERATOR_USER:$OPERATOR_USER" "$p"
  done
  run setfacl -x "u:$BROKER_USER" "$HOME_DIR"
  run setfacl -x "u:$BROKER_USER" "$PROJECTS_PARENT"
  say "  (identities and $AI_STATE_ROOT are left in place; remove them only if desired)"
}

selftest(){
  phase "selftest (ISOLATED throwaway tree; nothing outside /var/tmp is touched)"
  local ST; ST="$(mktemp -d /var/tmp/aegl-selftest-XXXXXX)"
  local parent="$ST/Projects" proj="$ST/Projects/Demo"
  mkdir -p "$proj/sub" "$proj/.git"; echo x > "$proj/sub/f.txt"; echo c > "$proj/.git/config"
  say "  tree=$ST  owner=$(id -un) (unprotected: writable, not immutable)"
  local save_parent="$PROJECTS_PARENT" save_proj=("${PROJECTS[@]}") fails=0
  PROJECTS_PARENT="$parent"; PROJECTS=("$proj")
  VFAIL=0
  verify_project "$proj" || true
  say "  unprotected tree -> verify violations=$VFAIL (expected >0: writable + not immutable)"
  [ "$VFAIL" -gt 0 ] && say "  PASS selftest: verifier detects an unprotected tree" || { say "  FAIL selftest: verifier reported no violations"; fails=$((fails+1)); }
  PROJECTS_PARENT="$save_parent"; PROJECTS=("${save_proj[@]}")
  rm -rf "$ST"
  say "  selftest failures=$fails"; [ "$fails" -eq 0 ]
}

main(){
  say "AEGL host identity bootstrap  [mode: $MODE]"
  case "$MODE" in
    plan) [ "$(id -u)" != 0 ] && say "(dry-run: nothing is changed)"
          preflight; plan_identities; plan_traverse; plan_trees; plan_parent_lock
          say ""; say "next: prepare+isolated-test the broker FIRST, then one 'sudo bash $0 apply'" ;;
    apply) [ "$(id -u)" = 0 ] || die "apply requires root"
          preflight; plan_identities; plan_traverse; plan_trees; plan_parent_lock
          if do_verify; then say "APPLY=OK (verified)"; else say "APPLY=REVERT (verification failed)"; plan_revert; return 1; fi ;;
    verify) do_verify ;;
    selftest) selftest ;;
    revert) plan_revert ;;
  esac
}
main "$@"
