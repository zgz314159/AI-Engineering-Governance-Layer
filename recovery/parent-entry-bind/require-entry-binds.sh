#!/usr/bin/env bash
# require-entry-binds.sh — refuse when the deployed entry-bind pack is present
# but live RW self-binds are missing. Never treats a marker alone as protection.
#
# Policy file (written only by install-parent-entry-bind.sh --apply):
#   /etc/aegl/entry-bind/policy
# When absent: no-op (pack not installed; do not claim protection).
# When present: every listed path must be an exact findmnt mountpoint.
set -euo pipefail

POLICY="${AEGL_ENTRY_BIND_POLICY:-/etc/aegl/entry-bind/policy}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ENTRY_BIND_REFUSE: %s\n' "$*" >&2; exit 1; }

# Exact mountpoint (not findmnt -T filesystem lookup).
is_exact_mountpoint(){
  local p="$1" mp
  mp="$(findmnt -n -o TARGET --mountpoint "$p" 2>/dev/null || true)"
  [ "$mp" = "$p" ]
}

# Sourced or executed: if policy missing, succeed quietly (pack not deployed).
if [ ! -f "$POLICY" ]; then
  if [ "${1:-}" = "--status" ]; then
    say "ENTRY_BIND_POLICY=absent"
    say "ENTRY_BIND_ENFORCE=no"
  fi
  return 0 2>/dev/null || exit 0
fi

command -v findmnt >/dev/null 2>&1 || die "findmnt required"

mapfile -t PATHS < <(awk -F= '/^path=/{print $2}' "$POLICY")
[ "${#PATHS[@]}" -ge 1 ] || die "policy has no path= lines: $POLICY"

missing=0
for p in "${PATHS[@]}"; do
  [ -n "$p" ] || continue
  if is_exact_mountpoint "$p"; then
    say "ENTRY_BIND_OK path=$p"
  else
    say "ENTRY_BIND_MISSING path=$p"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -ne 0 ]; then
  die "missing $missing live entry bind(s); policy=$POLICY (marker/policy alone is not protection)"
fi

if [ "${1:-}" = "--status" ]; then
  say "ENTRY_BIND_POLICY=present"
  say "ENTRY_BIND_ENFORCE=live_mountpoints_ok count=${#PATHS[@]}"
fi
return 0 2>/dev/null || exit 0
