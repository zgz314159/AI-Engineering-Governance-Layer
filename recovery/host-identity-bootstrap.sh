#!/usr/bin/env bash
# host-identity-bootstrap.sh — pre-launch preparation for the AEGL AI boundary.
#
# NO sudo / apply / revert is run by this file as delivered. Modes:
#   plan      (default) print everything, change nothing (dry-run)
#   prepare   idempotent, retry-safe account/group/state-root setup (no project change)
#   switch    the ONE final permission switch; REFUSES until the broker is verified
#   verify    non-mutating acceptance checks against a target (executes; non-zero on fail)
#   selftest  destructive counterexamples run ONLY in an isolated throwaway tree
#
# There is NO auto-revert: an interrupted chown cannot be restored to the exact original
# per-file modes, so this program never claims "restored". It is designed so the tree stays
# READABLE throughout and the switch is short, reporting a precise partial state on failure.
# No backups/snapshots/archives; no passwords read or stored.
set -uo pipefail

MODE=plan
case "${1:-}" in
  ""|plan|--plan) MODE=plan ;;
  prepare) MODE=prepare ;;
  switch)  MODE=switch ;;
  verify)  MODE=verify ;;
  selftest) MODE=selftest ;;
  broker-plan|broker-install) MODE=broker_plan ;;
  *) echo "usage: $0 [plan|prepare|switch|verify|selftest|broker-plan]"; exit 2 ;;
esac

AI_USER="aegl-ai";          AI_GROUP="aegl-ai"
BROKER_USER="aegl-promote"; BROKER_GROUP="aegl-broker"
HUMAN_GROUP="aegl-ro"
OPERATOR_USER="${SUDO_USER:-zhong}"
AI_STATE_ROOT="/var/lib/aegl-ai"
BROKER_MARKER="/etc/aegl/broker-verified"     # root-owned; written only after isolated broker test

HOME_DIR="/home/zhong"
AEGL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_PARENT="/home/zhong/Projects"
PROJECTS=(
  "$PROJECTS_PARENT/Google-Android-Agent-Development-Stack"
  "$PROJECTS_PARENT/KeepLab-Relay"
  "$PROJECTS_PARENT/AI-Engineering-Governance-Layer"
)
# item 1: generated dependency trees to remove before the switch (review list; never auto-deleted)
GENERATED_DEPS=(
  "$PROJECTS_PARENT/AI-Engineering-Governance-Layer/fixture/.specify/extensions/architecture-guard/node_modules"
  "$PROJECTS_PARENT/AI-Engineering-Governance-Layer/upstream/rulesync/node_modules"
)

say(){ printf '%s\n' "$*"; }
phase(){ printf '\n== %s ==\n' "$*"; }
die(){ printf 'BLOCKED: %s\n' "$*" >&2; exit 1; }
# execute only in prepare/switch modes (never in plan/verify/selftest)
run(){ printf '  $ %s\n' "$*"; if [ "$MODE" = prepare ] || [ "$MODE" = switch ]; then "$@"; fi; }

# --------------------------------------------------------------------------- #
# issue 1: generated-dependency review list (read-only)
# --------------------------------------------------------------------------- #
list_generated_deps(){
  phase "generated dependency trees (review list; nothing is deleted here)"
  local d
  for d in "${GENERATED_DEPS[@]}"; do
    if [ ! -e "$d" ]; then say "  (absent) $d"; continue; fi
    local dev rdev sz nf tracked
    dev="$(stat -c '%d' "$d")"; rdev="$(stat -c '%d' "${PROJECTS[2]}")"
    sz="$(du -sh "$d" 2>/dev/null | cut -f1)"; nf="$(find -P "$d" -type f 2>/dev/null | wc -l)"
    tracked="$(git -C "${d%%/fixture/*}" ls-files -- "${d#"$PROJECTS_PARENT/AI-Engineering-Governance-Layer/"}" 2>/dev/null | wc -l)"
    say "  $d"
    say "    size=$sz files=$nf tracked=$tracked symlink=$([ -L "$d" ] && echo yes || echo no) samedev=$([ "$dev" = "$rdev" ] && echo yes || echo NO)"
    say "    cross-mount=$(find -P "$d" -type f -printf '%D\n' 2>/dev/null | grep -vc "^${dev}$" || true) regen-from=package.json/pnpm-lock"
  done
  say "  -> operator removes these (scheme (a)) BEFORE the switch; this program never deletes them."
}

# --------------------------------------------------------------------------- #
# non-mutating acceptance (issue 2): changes no project-tree bytes
# --------------------------------------------------------------------------- #
VFAIL=0
as_user(){ if [ "$(id -u)" = 0 ]; then runuser -u "$1" -- "${@:2}"; else "${@:2}"; fi; }
# what these checks prove: the permission bits/owner/ACL deny the operator user write, and
# the immutable flag is set. What they CANNOT prove: that the kernel actually rejects a
# rename/write — only the isolated selftest exercises that empirically.
check(){
  local label="$1" want="$2" user="$3"; shift 3
  printf '  %-46s ' "$label"
  if as_user "$user" "$@"; then got=ok; else got=no; fi
  if [ "$got" = "$want" ]; then echo "$got (expected $want)"; else echo "$got (EXPECTED $want)"; VFAIL=$((VFAIL+1)); fi
}
verify_target(){
  local p="$1"
  say "  --- $p"
  local nested; nested="$(find -P "$p" -path "$p/.git" -prune -o -type f -print -quit 2>/dev/null || true)"
  check "operator cannot write project root"   no  "$OPERATOR_USER" test -w "$p"
  [ -n "$nested" ] && check "operator cannot write a nested file" no "$OPERATOR_USER" test -w "$nested"
  [ -e "$p/.git" ] && check "operator cannot write .git config"  no "$OPERATOR_USER" test -w "$p/.git/config"
  check "operator cannot write the parent dir" no  "$OPERATOR_USER" test -w "$PROJECTS_PARENT"
  check "broker can write the project"         ok  "$BROKER_USER"   test -w "$p"
  printf '  %-46s ' "parent lsattr (expect i)"
  local fl; fl="$(lsattr -d "$PROJECTS_PARENT" 2>/dev/null | awk '{print $1}')"
  case "$fl" in *i*) echo "$fl i-present";; *) echo "$fl NO-i"; VFAIL=$((VFAIL+1));; esac
  say "    (non-mutating: proves permission model + immutable flag; does NOT attempt a write/rename)"
}
do_verify(){ phase "verify (non-mutating)"; local p; for p in "${PROJECTS[@]}"; do verify_target "$p"; done; say "  VERIFY_VIOLATIONS=$VFAIL"; [ "$VFAIL" -eq 0 ]; }

# --------------------------------------------------------------------------- #
# issue 3a: prepare (idempotent, safely retryable)
# --------------------------------------------------------------------------- #
preflight_paths(){
  local p; for p in "${PROJECTS[@]}" "$PROJECTS_PARENT" "$HOME_DIR"; do
    [ -e "$p" ] || die "manifest path missing: $p"; [ -L "$p" ] && die "manifest path is a symlink: $p"
  done
}
prepare(){
  phase "prepare (idempotent; re-runnable; NO project permission change)"
  preflight_paths
  getent group "$AI_GROUP"     >/dev/null || run groupadd --system "$AI_GROUP"
  getent group "$BROKER_GROUP" >/dev/null || run groupadd --system "$BROKER_GROUP"
  getent group "$HUMAN_GROUP"  >/dev/null || run groupadd --system "$HUMAN_GROUP"
  id "$AI_USER"     >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$AI_GROUP" "$AI_USER"
  id "$BROKER_USER" >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$BROKER_GROUP" "$BROKER_USER"
  run usermod -aG "$HUMAN_GROUP" "$OPERATOR_USER"           # idempotent
  run install -d -o "$AI_USER" -g "$BROKER_GROUP" -m 2770 "$AI_STATE_ROOT"
  say "  verify: getent group $AI_GROUP $BROKER_GROUP $HUMAN_GROUP; id $AI_USER $BROKER_USER"
  say "  AI access = $AI_STATE_ROOT only; no ACL on $HOME_DIR or $PROJECTS_PARENT"
}

# --------------------------------------------------------------------------- #
# issue 3b: switch — refuses until the broker is verified; no fake restore
# --------------------------------------------------------------------------- #
switch_preconditions(){ # returns 1 with a printed reason when the switch must refuse
  [ -f "$BROKER_MARKER" ] || { say "  REFUSE: broker not verified ($BROKER_MARKER absent) — build the broker and pass its isolated test first"; return 1; }
  local d; for d in "${GENERATED_DEPS[@]}"; do
    [ -e "$d" ] && { say "  REFUSE: generated dependency tree still present (remove it first, scheme (a)): $d"; return 1; }
  done
  say "  broker marker: $(cat "$BROKER_MARKER")"
  return 0
}
switch(){
  phase "switch (final permission change) — gated"
  if [ "$MODE" = plan ]; then
    say "  (plan) the switch would run only if:"
    switch_preconditions || true
    say "  -> apply is currently NOT runnable."
    return 0
  fi
  [ "$(id -u)" = 0 ] || die "switch requires root"
  switch_preconditions || die "switch preconditions unmet (see reasons above); apply is currently NOT runnable"
  say "  no fake revert: an interrupted chown cannot be restored to exact per-file modes;"
  say "  the run stops and prints the precise partial state instead of claiming 'restored'."
  local p
  for p in "${PROJECTS[@]}"; do
    say "  --- tree $p (readable throughout: group $HUMAN_GROUP keeps r-x)"
    run find -P "$p" -path "$p/.git" -prune -o -type d -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 2750 {} +
    run find -P "$p" -path "$p/.git" -prune -o -type f -perm -u+x -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 0750 {} +
    run find -P "$p" -path "$p/.git" -prune -o -type f ! -perm -u+x -exec chown "$BROKER_USER:$HUMAN_GROUP" {} + -exec chmod 0640 {} +
    [ -e "$p/.git" ] || continue
    run find -P "$p/.git" -type d -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 2700 {} +
    run find -P "$p/.git" -type f -exec chown "$BROKER_USER:$BROKER_GROUP" {} + -exec chmod 0600 {} +
  done
  run setfacl -m "u:$BROKER_USER:--x" "$HOME_DIR"
  run chown "$BROKER_USER:$HUMAN_GROUP" "$PROJECTS_PARENT"
  run chmod 2755 "$PROJECTS_PARENT"
  run chattr +i "$PROJECTS_PARENT"        # LAST: entry lock
  say "  switch applied. Run acceptance now:  $0 verify"
}

# --------------------------------------------------------------------------- #
# issue 2: destructive counterexamples ONLY in an isolated tree
# --------------------------------------------------------------------------- #
selftest(){
  phase "selftest (ISOLATED throwaway tree; the only place destructive probes run)"
  local ST; ST="$(mktemp -d /var/tmp/aegl-selftest-XXXXXX)" || die "mktemp failed"
  local fails=0
  # A: unprotected/writable -> non-mutating checks must report violations
  mkdir -p "$ST/A/Demo/sub" "$ST/A/Demo/.git"; echo x > "$ST/A/Demo/sub/f.txt"; echo c > "$ST/A/Demo/.git/config"
  local sp="$PROJECTS_PARENT" spj=("${PROJECTS[@]}"); PROJECTS_PARENT="$ST/A"; PROJECTS=("$ST/A/Demo")
  VFAIL=0; verify_target "$ST/A/Demo" >/dev/null 2>&1
  [ "$VFAIL" -gt 0 ] && say "  PASS A: writable tree -> $VFAIL violations" || { say "  FAIL A: no violations"; fails=$((fails+1)); }
  # B: mode-protected (0555) -> checks report none, and a destructive attempt is denied
  mkdir -p "$ST/B/Demo/sub" "$ST/B/Demo/.git"; echo x > "$ST/B/Demo/sub/f.txt"; echo c > "$ST/B/Demo/.git/config"
  chmod -R a-w "$ST/B/Demo" 2>/dev/null; chmod a-w "$ST/B" 2>/dev/null
  PROJECTS_PARENT="$ST/B"; PROJECTS=("$ST/B/Demo")
  VFAIL=0
  # only the checks that are meaningful without root (broker-positive and immutability need root)
  check "B operator cannot write root"    no "$OPERATOR_USER" test -w "$ST/B/Demo"
  check "B operator cannot write nested"  no "$OPERATOR_USER" test -w "$ST/B/Demo/sub/f.txt"
  check "B operator cannot write .git"    no "$OPERATOR_USER" test -w "$ST/B/Demo/.git/config"
  check "B operator cannot write parent"  no "$OPERATOR_USER" test -w "$ST/B"
  [ "$VFAIL" -eq 0 ] && say "  PASS B: mode-protected tree denies the operator (non-mutating)" || { say "  FAIL B: $VFAIL violations"; fails=$((fails+1)); }
  if ( touch "$ST/B/Demo/sub/probe-$$" ) 2>/dev/null; then say "  FAIL B: destructive write succeeded"; fails=$((fails+1)); else say "  PASS B: destructive write denied (isolated tree only)"; fi
  if ( mv "$ST/B/Demo" "$ST/B/Demo.probe-$$" ) 2>/dev/null; then say "  FAIL B: rename succeeded"; mv "$ST/B/Demo.probe-$$" "$ST/B/Demo" 2>/dev/null; fails=$((fails+1)); else say "  PASS B: rename denied (isolated tree only)"; fi
  PROJECTS_PARENT="$sp"; PROJECTS=("${spj[@]}")
  chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"
  say "  note: immutability (chattr +i) cannot be exercised without root; the selftest covers"
  say "        mode-based denial, and the immutable flag is evidenced at switch time by lsattr."
  say "  selftest failures=$fails"; [ "$fails" -eq 0 ]
}

# --------------------------------------------------------------------------- #
# trusted promotion broker — reviewable install plan (root-owned; NEVER run here)
# --------------------------------------------------------------------------- #
BROKER_LIBDIR="/usr/local/lib/aegl-promote"
BROKER_RUNDIR="/run/aegl-promote"
BROKER_SOCKET="$BROKER_RUNDIR/broker.sock"
BROKER_REGISTRY_DIR="/var/lib/aegl-promote"

broker_install_plan(){
  phase "trusted promotion broker — install (reviewable; the REAL entry is recovery/install-broker.sh)"
  say "Run the idempotent installer from a trusted terminal (NOT this plan printer):"
  say "   sudo $AEGL_ROOT/recovery/install-broker.sh --commit <full-40-hex-commit> [--self-test]"
  say "It extracts every file FROM that pinned commit (verifying sha256), creates the identities,"
  say "the root-owned program/service and the registry dir; it does NOT run switch, does NOT change"
  say "project permissions, does NOT merge and does NOT write the marker. --self-test runs the"
  say "bounded INDEPENDENT-UID acceptance (not the same-uid functional run)."
  say ""
  say "Shape it produces:"
  say "  program (root-owned 0755/0644, flat): $BROKER_LIBDIR/{aegl-promote-broker,promotion_broker.py,promotion_core.py}"
  say "  identities: $BROKER_USER:$BROKER_GROUP (broker) · $AI_USER:$AI_GROUP (AI requester, in $BROKER_GROUP)"
  say "  dirs: $BROKER_RUNDIR ($BROKER_USER:$BROKER_GROUP 2770) · $BROKER_REGISTRY_DIR ($BROKER_USER:$BROKER_GROUP 0700)"
  say "  unit: $UNIT  (User=$BROKER_USER; requesters=$AI_USER; recorders=root — the AI-running identity is"
  say "        NEVER a recorder, so it can never register/record or declare verify_result=PASS)"
  say "  Role: only root (trusted control) register/record; the AI identity may only validate/promote a"
  say "        task a recorder already approved. The same-uid test allowlists are test-only, not production."
}

main(){
  say "AEGL host identity bootstrap  [mode: $MODE]"
  case "$MODE" in
    plan)     preflight_paths; list_generated_deps; say ""; prepare; say ""; switch
              say ""; say "NOTE: 'switch' will refuse until the broker is verified. apply is NOT runnable yet." ;;
    prepare) prepare ;;
    switch)  switch ;;
    verify)  do_verify ;;
    selftest) selftest ;;
    broker_plan) broker_install_plan ;;
  esac
}
main "$@"
