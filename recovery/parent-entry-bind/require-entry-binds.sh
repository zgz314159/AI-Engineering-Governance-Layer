#!/usr/bin/env bash
# require-entry-binds.sh — production gate for the five RW self-bind entrypoints.
#
# Fixed policy path (no env override):
#   /etc/aegl/entry-bind/policy
#
# States:
#   NOT_DEPLOYED  — policy absent → exit 0, NOT_DEPLOYED / not_claimed
#   DEPLOYED      — unit file What=Where=path + ownership; live RW self-bind via
#                   kernel mountinfo (FSROOT/source/rw) and parent-mount selection.
#                   systemctl runtime What may be the backing device — do NOT require
#                   it equal the directory path.
#
# Optional parse-only (NOT host mount acceptance):
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

# Selected mount id per expected path (filled during assert pass).
# Must not run select_mountinfo_for_path inside $() — that would lose SELECTED_MID.
declare -A SELECTED_MID=()
SELECTED_ROW=""

say(){ printf '%s\n' "$*"; }
die(){ printf 'ENTRY_BIND_REFUSE: %s\n' "$*" >&2; exit 1; }

unit_name_for(){ systemd-escape -p --suffix=mount "$1"; }

# Parse mountinfo line → id|parent|root|mnt|opts|source
parse_mountinfo_line(){
  local line="$1" left right fields root mnt opts id parent src
  case "$line" in
    *" - "*) ;;
    *) return 1 ;;
  esac
  left="${line%% - *}"
  right="${line#* - }"
  # shellcheck disable=SC2206
  fields=($left)
  [ "${#fields[@]}" -ge 6 ] || return 1
  id="${fields[0]}"
  parent="${fields[1]}"
  root="${fields[3]}"
  mnt="${fields[4]}"
  opts="${fields[5]}"
  # right: fstype source [superopts...]
  # shellcheck disable=SC2206
  local rfields=($right)
  [ "${#rfields[@]}" -ge 2 ] || return 1
  src="${rfields[1]}"
  printf '%s|%s|%s|%s|%s|%s\n' "$id" "$parent" "$root" "$mnt" "$opts" "$src"
}

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

# Nearest expected-path ancestor that is a strict prefix of path (longest wins).
nearest_expected_ancestor(){
  local path="$1" e best=""
  for e in "${EXPECTED_PATHS[@]}"; do
    case "$path" in
      "$e"/*)
        if [ "${#e}" -gt "${#best}" ]; then
          best="$e"
        fi
        ;;
    esac
  done
  printf '%s\n' "$best"
}

# Load /proc/self/mountinfo (or sample stream on stdin) into global arrays via
# printing all rows; caller filters. For selection we re-read file each time
# (small). Returns count of candidates for path via stdout lines id|parent|...
mountinfo_candidates_for(){
  local path="$1" srcfile="${2:-/proc/self/mountinfo}" line parsed
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    parsed="$(parse_mountinfo_line "$line" || true)"
    [ -n "$parsed" ] || continue
    local id parent root mnt opts src
    IFS='|' read -r id parent root mnt opts src <<<"$parsed"
    if [ "$mnt" = "$path" ]; then
      printf '%s\n' "$parsed"
    fi
  done < "$srcfile"
}

# Select the visible self-bind row for path using parent-mount relationship.
# Sets SELECTED_MID[path]=id and SELECTED_ROW (no stdout capture — preserves assoc array).
select_mountinfo_for_path(){
  local path="$1" srcfile="${2:-/proc/self/mountinfo}"
  local -a cands=()
  local line anc anc_mid id parent root mnt opts src
  local -a matched=() shadowed=0
  SELECTED_ROW=""

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    cands+=("$line")
  done < <(mountinfo_candidates_for "$path" "$srcfile")

  if [ "${#cands[@]}" -eq 0 ]; then
    return 1
  fi

  if [ "${#cands[@]}" -eq 1 ]; then
    IFS='|' read -r id parent root mnt opts src <<<"${cands[0]}"
    mountinfo_is_rw_self_bind "$path" "$root" "$mnt" "$opts" || return 2
    SELECTED_MID["$path"]="$id"
    SELECTED_ROW="${cands[0]}"
    return 0
  fi

  # Multiple rows at same mountpoint: pick by parent == selected ancestor mid.
  # Other rows are treated as shadowed (not visible under the pack parent bind).
  anc="$(nearest_expected_ancestor "$path")"
  if [ -z "$anc" ]; then
    printf 'ENTRY_BIND_REFUSE: ambiguous mountinfo count=%s for top-level path %s (no ancestor)\n' \
      "${#cands[@]}" "$path" >&2
    return 3
  fi
  anc_mid="${SELECTED_MID[$anc]:-}"
  if [ -z "$anc_mid" ]; then
    printf 'ENTRY_BIND_REFUSE: ancestor %s has no selected mount id before checking %s\n' \
      "$anc" "$path" >&2
    return 3
  fi

  matched=()
  for line in "${cands[@]}"; do
    IFS='|' read -r id parent root mnt opts src <<<"$line"
    if [ "$parent" = "$anc_mid" ]; then
      matched+=("$line")
    else
      shadowed=$((shadowed + 1))
    fi
  done

  if [ "${#matched[@]}" -eq 1 ]; then
    IFS='|' read -r id parent root mnt opts src <<<"${matched[0]}"
    mountinfo_is_rw_self_bind "$path" "$root" "$mnt" "$opts" || return 2
    SELECTED_MID["$path"]="$id"
    SELECTED_ROW="${matched[0]}"
    printf 'ENTRY_BIND_MOUNTINFO_SELECT path=%s mid=%s parent=%s ancestor=%s shadowed=%s\n' \
      "$path" "$id" "$parent" "$anc" "$shadowed" >&2
    return 0
  fi

  if [ "${#matched[@]}" -eq 0 ]; then
    printf 'ENTRY_BIND_REFUSE: no mountinfo row for %s with parent=%s (ancestor %s); candidates=%s — cannot determine visible self-bind\n' \
      "$path" "$anc_mid" "$anc" "${#cands[@]}" >&2
    return 3
  fi
  printf 'ENTRY_BIND_REFUSE: ambiguous stack: %s mountinfo rows for %s under parent=%s (ancestor %s)\n' \
    "${#matched[@]}" "$path" "$anc_mid" "$anc" >&2
  return 3
}

# Trusted unit FILE: What=Where=path, Options rw; ownership via FragmentPath/drop-ins.
# Do NOT require systemctl runtime What == path (may be backing device).
assert_trusted_unit_what_where(){
  local p="$1" u unitf what where uopts frag drops sc_where sc_what
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
  [ "$what" = "$p" ] || die "unit file What=$what != path $p"
  [ "$where" = "$p" ] || die "unit file Where=$where != path $p"
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
    sc_where="$(systemctl show -p Where --value "$u" 2>/dev/null || true)"
    if [ -n "$sc_where" ] && [ "$sc_where" != "$p" ]; then
      die "systemctl Where=$sc_where != $p"
    fi
    # Runtime What may be /dev/… after bind resolve — record only; do not require == path.
    sc_what="$(systemctl show -p What --value "$u" 2>/dev/null || true)"
    if [ -n "$sc_what" ] && [ "$sc_what" = "$p" ]; then
      say "ENTRY_BIND_UNIT_RUNTIME what=$sc_what (equals path)"
    elif [ -n "$sc_what" ]; then
      say "ENTRY_BIND_UNIT_RUNTIME what=$sc_what (backing source; unit file What=$what)"
    fi
  fi
}

assert_rw_self_bind(){
  local p="$1" row id parent root mnt opts src rc
  command -v systemd-escape >/dev/null 2>&1 || die "systemd-escape required"
  assert_trusted_unit_what_where "$p"

  set +e
  select_mountinfo_for_path "$p"
  rc=$?
  set -e
  if [ "$rc" = 1 ]; then
    die "no /proc/self/mountinfo row for mountpoint $p"
  fi
  if [ "$rc" = 2 ]; then
    die "selected mountinfo for $p is not RW self-bind"
  fi
  if [ "$rc" = 3 ]; then
    die "mountinfo selection refused for $p (shadowed vs stack ambiguous; see prior REFUSE line)"
  fi
  [ "$rc" = 0 ] || die "mountinfo select failed for $p rc=$rc"
  [ -n "$SELECTED_ROW" ] || die "empty SELECTED_ROW for $p"
  IFS='|' read -r id parent root mnt opts src <<<"$SELECTED_ROW"

  # Kernel source: device path; path identity is FSROOT (== root field) + mountpoint.
  [ -n "$src" ] || die "empty mount source for $p mid=$id"
  case "$src" in
    /dev/*|UUID=*|PARTUUID=*|LABEL=*|PARTLABEL=*) ;;
    *"[$p]") ;;
    *)
      # Allow path-style source only if it equals path (rare); else refuse unknown.
      if [ "$src" != "$p" ]; then
        die "unexpected mount source for $p mid=$id source=$src"
      fi
      ;;
  esac

  say "ENTRY_BIND_OK path=$p mid=$id parent=$parent fsroot=$root source=$src options=$opts"
}

# --- parse-only sample check (NOT host mount acceptance) ---
# File formats:
#   A) single-line (legacy): EXPECT|path|mountinfo-line
#   B) multi-block:
#        CASE name
#        EXPECT=PASS|FAIL
#        PATH=/abs/path
#        ANCESTOR_MID=<id>          # optional seed for SELECTED_MID[ancestor]
#        ANCESTOR_PATH=/abs/parent  # required if ANCESTOR_MID set
#        MOUNTINFO
#        <raw mountinfo lines>
#        END
if [ "${1:-}" = "--check-mountinfo-sample" ]; then
  sample_file="${2:-}"
  [ -n "$sample_file" ] && [ -f "$sample_file" ] || die "usage: --check-mountinfo-sample <file>"
  fails=0

  # Detect multi-block vs legacy
  if grep -q '^CASE ' "$sample_file"; then
    tmpmi="$(mktemp)"
    case_name="" expect="" path="" anc_mid="" anc_path=""
    in_mi=0
    flush_case(){
      SELECTED_MID=()
      SELECTED_ROW=""
      if [ -n "$anc_path" ] && [ -n "$anc_mid" ]; then
        SELECTED_MID["$anc_path"]="$anc_mid"
      fi
      local rc=0 ok=0 id parent root mnt opts src
      set +e
      select_mountinfo_for_path "$path" "$tmpmi" 2>/tmp/eb-sel.err
      rc=$?
      set -e
      if [ "$rc" = 0 ]; then
        IFS='|' read -r id parent root mnt opts src <<<"$SELECTED_ROW"
        mountinfo_is_rw_self_bind "$path" "$root" "$mnt" "$opts" && ok=1
      fi
      if [ "$expect" = "PASS" ] && [ "$ok" = 1 ]; then
        say "SAMPLE_OK case=$case_name expect=PASS path=$path mid=${id:-}"
      elif [ "$expect" = "FAIL" ] && [ "$ok" = 0 ]; then
        say "SAMPLE_OK case=$case_name expect=FAIL path=$path"
      else
        say "SAMPLE_MISMATCH case=$case_name expect=$expect ok=$ok rc=$rc path=$path"
        [ -s /tmp/eb-sel.err ] && cat /tmp/eb-sel.err >&2 || true
        fails=$((fails + 1))
      fi
      : > "$tmpmi"
      case_name=""; expect=""; path=""; anc_mid=""; anc_path=""; in_mi=0
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        \#*|'') continue ;;
        CASE\ *)
          [ -n "$case_name" ] && flush_case
          case_name="${line#CASE }"
          ;;
        EXPECT=*) expect="${line#EXPECT=}" ;;
        PATH=*) path="${line#PATH=}" ;;
        ANCESTOR_MID=*) anc_mid="${line#ANCESTOR_MID=}" ;;
        ANCESTOR_PATH=*) anc_path="${line#ANCESTOR_PATH=}" ;;
        MOUNTINFO) in_mi=1 ;;
        END)
          in_mi=0
          flush_case
          ;;
        *)
          if [ "$in_mi" = 1 ]; then
            printf '%s\n' "$line" >> "$tmpmi"
          fi
          ;;
      esac
    done < "$sample_file"
    [ -n "$case_name" ] && flush_case
    rm -f "$tmpmi" /tmp/eb-sel.err
  else
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
      IFS='|' read -r id parent root mnt opts src <<<"$parsed"
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
  fi
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

SELECTED_MID=()
for p in "${EXPECTED_PATHS[@]}"; do
  assert_rw_self_bind "$p"
done

say "ENTRY_BIND_STATE=DEPLOYED"
say "ENTRY_BIND_PROTECTION=live_rw_self_bind_ok count=${#EXPECTED_PATHS[@]}"
exit 0
