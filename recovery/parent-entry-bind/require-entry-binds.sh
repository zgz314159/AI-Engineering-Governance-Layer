#!/usr/bin/env bash
# require-entry-binds.sh — production gate for the five RW self-bind entrypoints.
#
# Fixed policy path (no env override; callers cannot skip by pointing elsewhere):
#   /etc/aegl/entry-bind/policy
#
# States:
#   NOT_DEPLOYED  — policy absent → exit 0, report NOT_DEPLOYED (never "protection OK")
#   DEPLOYED      — policy present → checker must exist; policy must list exactly the
#                   five expected paths; each must be an exact findmnt mountpoint with
#                   bind+rw options. Fail closed on missing checker, corrupt policy,
#                   wrong path set, or non-RW-self-bind mounts.
set -euo pipefail

POLICY="/etc/aegl/entry-bind/policy"
CHECKER_INSTALLED="/usr/local/lib/aegl-entry-bind/require-entry-binds.sh"

EXPECTED_PATHS=(
  /home/zhong/Projects
  /home/zhong/AppProjects
  /home/zhong/Projects/AI-Engineering-Governance-Layer
  /home/zhong/Projects/Google-Android-Agent-Development-Stack
  /home/zhong/AppProjects/KeepLab-Relay
)

say(){ printf '%s\n' "$*"; }
die(){ printf 'ENTRY_BIND_REFUSE: %s\n' "$*" >&2; exit 1; }

# Exact mountpoint + RW bind (not findmnt -T; not "any mountpoint").
assert_rw_self_bind(){
  local p="$1" mp opts
  mp="$(findmnt -n -o TARGET --mountpoint "$p" 2>/dev/null || true)"
  [ "$mp" = "$p" ] || die "not an exact mountpoint: $p (got '${mp:-empty}')"
  opts="$(findmnt -n -o OPTIONS --mountpoint "$p" 2>/dev/null || true)"
  [ -n "$opts" ] || die "no OPTIONS for mountpoint $p"
  case ",$opts," in
    *,bind,*|*,rbind,*) ;;
    *) die "mountpoint $p is not a bind/rbind (OPTIONS=$opts)" ;;
  esac
  case ",$opts," in
    *,ro,*) die "mountpoint $p is read-only bind (OPTIONS=$opts) — want RW self-bind" ;;
  esac
  say "ENTRY_BIND_OK path=$p options=$opts"
}

# --- not deployed ---
if [ ! -e "$POLICY" ]; then
  say "ENTRY_BIND_STATE=NOT_DEPLOYED"
  say "ENTRY_BIND_PROTECTION=not_claimed"
  exit 0
fi

# --- deployed: fail closed ---
[ -f "$POLICY" ] || die "policy path exists but is not a regular file: $POLICY"
[ -r "$POLICY" ] || die "policy not readable: $POLICY"
# When this script is the installed checker, or when invoked from source during
# packaging tests, still require the installed checker path to exist in production
# deploy (policy present ⇒ host must have installed checker).
if [ ! -f "$CHECKER_INSTALLED" ] || [ ! -x "$CHECKER_INSTALLED" ]; then
  die "deployed policy present but installed checker missing/not executable: $CHECKER_INSTALLED"
fi
command -v findmnt >/dev/null 2>&1 || die "findmnt required"

mapfile -t POLICY_PATHS < <(awk -F= '/^path=/{print $2}' "$POLICY")
[ "${#POLICY_PATHS[@]}" -eq "${#EXPECTED_PATHS[@]}" ] \
  || die "policy path count ${#POLICY_PATHS[@]} != expected ${#EXPECTED_PATHS[@]} (corrupt/incomplete policy)"

# Every expected path must appear exactly once; no extras.
declare -A SEEN=()
for p in "${POLICY_PATHS[@]}"; do
  [ -n "$p" ] || die "empty path= in policy"
  SEEN["$p"]=1
done
for p in "${EXPECTED_PATHS[@]}"; do
  [ "${SEEN[$p]:-}" = 1 ] || die "policy missing expected path: $p"
done
for p in "${POLICY_PATHS[@]}"; do
  ok=0
  for e in "${EXPECTED_PATHS[@]}"; do
    [ "$p" = "$e" ] && ok=1 && break
  done
  [ "$ok" = 1 ] || die "policy has unexpected path: $p"
done

for p in "${EXPECTED_PATHS[@]}"; do
  assert_rw_self_bind "$p"
done

say "ENTRY_BIND_STATE=DEPLOYED"
say "ENTRY_BIND_PROTECTION=live_rw_self_bind_ok count=${#EXPECTED_PATHS[@]}"
exit 0
