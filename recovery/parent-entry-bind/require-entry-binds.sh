#!/usr/bin/env bash
# require-entry-binds.sh — production gate for the five RW self-bind entrypoints.
#
# Fixed policy path (no env override; callers cannot skip by pointing elsewhere):
#   /etc/aegl/entry-bind/policy
#
# States:
#   NOT_DEPLOYED  — policy absent → exit 0, report NOT_DEPLOYED (never "protection OK")
#   DEPLOYED      — policy present → installed checker must exist; policy lists exactly
#                   the five expected paths; each must be a verified RW self-bind:
#                   trusted unit What=Where, exact mountpoint, kernel FSROOT/source,
#                   and explicit rw (not findmnt OPTIONS bind/rbind).
#
# Optional (parse-only; NOT host mount acceptance):
#   require-entry-binds.sh --check-mountinfo-sample <file>
set -euo pipefail

POLICY="/etc/aegl/entry-bind/policy"
CHECKER_INSTALLED="/usr/local/lib/aegl-entry-bind/require-entry-binds.sh"
UNITDIR="/etc/systemd/system"

EXPECTED_PATHS=(
  /home/zhong/Projects
  /home/zhong/AppProjects
  /home/zhong/Projects/AI-Engineering-Governance-Layer
  /home/zhong/Projects/Google-Android-Agent-Development-Stack
  /home/zhong/AppProjects/KeepLab-Relay
)

say(){ printf '%s\n' "$*"; }
die(){ printf 'ENTRY_BIND_REFUSE: %s\n' "$*" >&2; exit 1; }

unit_name_for(){ systemd-escape -p --suffix=mount "$1"; }

# Parse one mountinfo line → root|mountpoint|opts (opts = per-mount VFS options).
# Real format samples only; unused fields ignored.
parse_mountinfo_line(){
  local line="$1" left right fields root mnt opts
  case "$line" in
    *" - "*) ;;
    *) return 1 ;;
  esac
  left="${line%% - *}"
  # shellcheck disable=SC2206
  fields=($left)
  [ "${#fields[@]}" -ge 6 ] || return 1
  root="${fields[3]}"
  mnt="${fields[4]}"
  opts="${fields[5]}"
  printf '%s|%s|%s\n' "$root" "$mnt" "$opts"
}

# Self-bind + rw from mountinfo fields (no bind/rbind token required).
mountinfo_is_rw_self_bind(){
  local path="$1" root="$2" mnt="$3" opts="$4"
  [ "$mnt" = "$path" ] || return 1
  [ "$root" = "$path" ] || return 1
  case ",$opts," in
    *,ro,*) return 1 ;;
  esac
  case ",$opts," in
    *,rw,*) return 0 ;;
  esac
  return 1
}

# Find mountinfo row whose mountpoint equals path (last match wins = topmost).
mountinfo_row_for(){
  local path="$1" line parsed
  local found=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    parsed="$(parse_mountinfo_line "$line" || true)"
    [ -n "$parsed" ] || continue
    local root mnt opts
    IFS='|' read -r root mnt opts <<<"$parsed"
    if [ "$mnt" = "$path" ]; then
      found="$parsed"
    fi
  done < /proc/self/mountinfo
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Trusted unit at UNITDIR: What=Where=path, Options declare rw (unit text; not findmnt).
assert_trusted_unit_what_where(){
  local p="$1" u unitf what where uopts frag drops
  u="$(unit_name_for "$p")"
  unitf="$UNITDIR/$u"
  [ -f "$unitf" ] || die "trusted unit missing: $unitf"
  [ ! -L "$unitf" ] || die "trusted unit is a symlink: $unitf"
  if [ -e "$UNITDIR/$u.d" ] || [ -L "$UNITDIR/$u.d" ]; then
    die "unit drop-in dir present: $UNITDIR/$u.d"
  fi
  what="$(awk -F= '$1=="What"{print $2; exit}' "$unitf")"
  where="$(awk -F= '$1=="Where"{print $2; exit}' "$unitf")"
  uopts="$(awk -F= '$1=="Options"{print $2; exit}' "$unitf")"
  [ "$what" = "$p" ] || die "unit What=$what != path $p"
  [ "$where" = "$p" ] || die "unit Where=$where != path $p"
  case ",$uopts," in
    *,rw,*) ;;
    *) die "unit Options lack rw: $unitf Options=$uopts" ;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    frag="$(systemctl show -p FragmentPath --value "$u" 2>/dev/null || true)"
    if [ -n "$frag" ] && [ "$frag" != "$unitf" ]; then
      die "FragmentPath=$frag not pack unit $unitf"
    fi
    drops="$(systemctl show -p DropInPaths --value "$u" 2>/dev/null || true)"
    if [ -n "${drops// }" ]; then
      die "DropInPaths present for $u: $drops"
    fi
    local sc_what sc_where
    sc_what="$(systemctl show -p What --value "$u" 2>/dev/null || true)"
    sc_where="$(systemctl show -p Where --value "$u" 2>/dev/null || true)"
    if [ -n "$sc_what" ] && [ "$sc_what" != "$p" ]; then
      die "systemctl What=$sc_what != $p"
    fi
    if [ -n "$sc_where" ] && [ "$sc_where" != "$p" ]; then
      die "systemctl Where=$sc_where != $p"
    fi
  fi
}

# Exact mountpoint + FSROOT/source self-bind + rw (no bind/rbind OPTIONS requirement).
assert_rw_self_bind(){
  local p="$1" mp fsroot src opts row root mnt mi_opts
  command -v systemd-escape >/dev/null 2>&1 || die "systemd-escape required"
  assert_trusted_unit_what_where "$p"

  mp="$(findmnt -n -o TARGET --mountpoint "$p" 2>/dev/null || true)"
  [ "$mp" = "$p" ] || die "not an exact mountpoint: $p (got '${mp:-empty}')"

  fsroot="$(findmnt -n -o FSROOT --mountpoint "$p" 2>/dev/null || true)"
  src="$(findmnt -n -o SOURCE --mountpoint "$p" 2>/dev/null || true)"
  opts="$(findmnt -n -o OPTIONS --mountpoint "$p" 2>/dev/null || true)"
  [ -n "$fsroot" ] || die "no FSROOT for mountpoint $p"
  [ -n "$opts" ] || die "no OPTIONS for mountpoint $p"
  [ "$fsroot" = "$p" ] || die "FSROOT=$fsroot != path $p (not self-bind)"
  case ",$opts," in
    *,ro,*) die "mountpoint $p is read-only (OPTIONS=$opts) — want rw self-bind" ;;
  esac
  case ",$opts," in
    *,rw,*) ;;
    *) die "mountpoint $p OPTIONS lack rw: $opts" ;;
  esac
  # SOURCE often looks like /dev/X[/path] for binds; when bracket form present, require path.
  case "$src" in
    *"[$p]") ;;
    *"["*) die "SOURCE=$src bracket path != $p" ;;
    *) ;; # device-only SOURCE still OK if FSROOT matched
  esac

  row="$(mountinfo_row_for "$p")" \
    || die "no /proc/self/mountinfo row for mountpoint $p"
  IFS='|' read -r root mnt mi_opts <<<"$row"
  mountinfo_is_rw_self_bind "$p" "$root" "$mnt" "$mi_opts" \
    || die "mountinfo not RW self-bind for $p (root=$root mnt=$mnt opts=$mi_opts)"

  say "ENTRY_BIND_OK path=$p fsroot=$fsroot source=$src options=$opts"
}

# --- parse-only sample check (NOT host mount acceptance) ---
if [ "${1:-}" = "--check-mountinfo-sample" ]; then
  sample_file="${2:-}"
  [ -n "$sample_file" ] && [ -f "$sample_file" ] || die "usage: --check-mountinfo-sample <file>"
  fails=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    expect="${line%%|*}"
    rest="${line#*|}"
    path="${rest%%|*}"
    mi="${rest#*|}"
    if ! parsed="$(parse_mountinfo_line "$mi")"; then
      say "SAMPLE_PARSE_FAIL $line"
      fails=$((fails+1))
      continue
    fi
    IFS='|' read -r root mnt opts <<<"$parsed"
    ok=0
    mountinfo_is_rw_self_bind "$path" "$root" "$mnt" "$opts" && ok=1
    if [ "$expect" = "PASS" ] && [ "$ok" = 1 ]; then
      say "SAMPLE_OK expect=PASS path=$path"
    elif [ "$expect" = "FAIL" ] && [ "$ok" = 0 ]; then
      say "SAMPLE_OK expect=FAIL path=$path"
    else
      say "SAMPLE_MISMATCH expect=$expect got_ok=$ok path=$path root=$root mnt=$mnt opts=$opts"
      fails=$((fails+1))
    fi
  done < "$sample_file"
  [ "$fails" = 0 ] || die "mountinfo sample mismatches=$fails (parse check only; not host acceptance)"
  say "MOUNTINFO_SAMPLE_CHECK=OK (parse only; not host mount acceptance)"
  exit 0
fi

# --- not deployed ---
if [ ! -e "$POLICY" ]; then
  say "ENTRY_BIND_STATE=NOT_DEPLOYED"
  say "ENTRY_BIND_PROTECTION=not_claimed"
  exit 0
fi

# --- deployed: fail closed ---
[ -f "$POLICY" ] || die "policy path exists but is not a regular file: $POLICY"
[ -r "$POLICY" ] || die "policy not readable: $POLICY"
if [ ! -f "$CHECKER_INSTALLED" ] || [ ! -x "$CHECKER_INSTALLED" ]; then
  die "deployed policy present but installed checker missing/not executable: $CHECKER_INSTALLED"
fi
command -v findmnt >/dev/null 2>&1 || die "findmnt required"
command -v systemd-escape >/dev/null 2>&1 || die "systemd-escape required"

mapfile -t POLICY_PATHS < <(awk -F= '/^path=/{print $2}' "$POLICY")
[ "${#POLICY_PATHS[@]}" -eq "${#EXPECTED_PATHS[@]}" ] \
  || die "policy path count ${#POLICY_PATHS[@]} != expected ${#EXPECTED_PATHS[@]} (corrupt/incomplete policy)"

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
