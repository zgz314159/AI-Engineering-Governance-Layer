#!/usr/bin/env bash
# install-parent-entry-bind.sh — plan-by-default installer for five RW self-bind
# mount units + aegl-entry-bind.target. Does NOT claim protection via marker alone.
#
# Delivery (trusted terminal; fixed commit SHA — never sudo a user-writable tree):
#
#   TIP=<full-40-hex>
#   AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer   # after promote
#   # or independent controller checkout that contains TIP
#   RDIR=$(sudo mktemp -d /var/tmp/aegl-entry-bind-root-XXXXXX)
#   sudo install -o root -g root -m 0700 -d "$RDIR"
#   git -C "$AEGL" show "$TIP:recovery/install-parent-entry-bind.sh" \
#     | sudo tee "$RDIR/install.sh" >/dev/null
#   sudo chmod 0755 "$RDIR/install.sh"
#   sudo bash "$RDIR/install.sh" --repo "$AEGL" --commit "$TIP"          # plan
#   sudo bash "$RDIR/install.sh" --repo "$AEGL" --commit "$TIP" --apply  # install
#   sudo rm -rf "$RDIR"
#
# Default: print plan only. --apply installs. --remove uninstalls this pack only.
set -euo pipefail

REPO=""; COMMIT=""; MODE=plan   # plan | apply | remove
LIBDIR=/usr/local/lib/aegl-entry-bind
ETCDIR=/etc/aegl/entry-bind
POLICY="$ETCDIR/policy"
UNITDIR=/etc/systemd/system
TARGET_NAME=aegl-entry-bind.target

PATHS=(
  /home/zhong/Projects
  /home/zhong/AppProjects
  /home/zhong/Projects/AI-Engineering-Governance-Layer
  /home/zhong/Projects/Google-Android-Agent-Development-Stack
  /home/zhong/AppProjects/KeepLab-Relay
)

say(){ printf '%s\n' "$*"; }
fail(){ printf 'INSTALL_ERROR: %s\n' "$*" >&2; exit 1; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'INSTALL_ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --apply) MODE=apply; shift ;;
    --remove) MODE=remove; shift ;;
    --plan) MODE=plan; shift ;;
    *) fail "unknown option $1" ;;
  esac
done

[ -n "$REPO" ] || fail "--repo required"
[ -n "$COMMIT" ] || fail "--commit <40-hex> required"
[ "${#COMMIT}" -eq 40 ] || fail "--commit must be 40-hex"
case "$COMMIT" in [0-9a-f]*) ;; *) fail "--commit must be 40-hex" ;; esac
[ -d "$REPO/.git" ] || fail "--repo is not a git repository: $REPO"
git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "commit not in repo: $COMMIT"
git -C "$REPO" cat-file -e "$COMMIT:recovery/install-parent-entry-bind.sh" 2>/dev/null \
  || fail "installer missing in commit $COMMIT"
git -C "$REPO" cat-file -e "$COMMIT:recovery/parent-entry-bind/aegl-entry-bind.target" 2>/dev/null \
  || fail "target unit missing in commit $COMMIT"

command -v systemd-escape >/dev/null || fail "systemd-escape required"
command -v findmnt >/dev/null || fail "findmnt required"
command -v systemctl >/dev/null || fail "systemctl required"

unit_name_for(){ systemd-escape -p --suffix=mount "$1"; }

UNIT_NAMES=()
for p in "${PATHS[@]}"; do
  UNIT_NAMES+=("$(unit_name_for "$p")")
done

pack_paths_in_commit(){
  local p u
  for p in "${PATHS[@]}"; do
    u="$(unit_name_for "$p")"
    git -C "$REPO" cat-file -e "$COMMIT:recovery/parent-entry-bind/units/$u" 2>/dev/null \
      || fail "unit missing in commit: recovery/parent-entry-bind/units/$u"
  done
  git -C "$REPO" cat-file -e "$COMMIT:recovery/parent-entry-bind/require-entry-binds.sh" 2>/dev/null \
    || fail "require-entry-binds.sh missing in commit"
  git -C "$REPO" cat-file -e "$COMMIT:recovery/parent-entry-bind/PARENT-ENTRY-BIND.md" 2>/dev/null \
    || fail "PARENT-ENTRY-BIND.md missing in commit"
}

# Conflict detection — stop, never overwrite / stack.
check_conflicts(){
  local p u fstab_hit existing
  # fstab
  if [ -f /etc/fstab ]; then
    for p in "${PATHS[@]}"; do
      if awk -v w="$p" 'BEGIN{ok=0} $1!~/^#/ && $2==w {ok=1} END{exit !ok}' /etc/fstab; then
        stop fstab_conflict "fstab already has Where=$p — refuse (no overwrite)"
      fi
    done
  fi
  # existing units with different content
  for u in "${UNIT_NAMES[@]}" "$TARGET_NAME"; do
    if [ -e "$UNITDIR/$u" ]; then
      if [ "$MODE" = apply ]; then
        local existing want srcp
        existing="$(sha256sum "$UNITDIR/$u" | awk '{print $1}')"
        if [ "$u" = "$TARGET_NAME" ]; then
          srcp="recovery/parent-entry-bind/$TARGET_NAME"
        else
          srcp="recovery/parent-entry-bind/units/$u"
        fi
        want="$(git -C "$REPO" show "$COMMIT:$srcp" | sha256sum | awk '{print $1}')"
        if [ "$existing" != "$want" ]; then
          stop unit_conflict "$UNITDIR/$u exists with different content — refuse"
        fi
        say "  UNIT_PRESENT_MATCH $u"
      else
        say "  UNIT_PRESENT $UNITDIR/$u (plan: will require content match on --apply)"
      fi
    fi
  done
  # live mounts that are not our units (foreign bind)
  for p in "${PATHS[@]}"; do
    if findmnt -n -o TARGET --mountpoint "$p" >/dev/null 2>&1; then
      u="$(unit_name_for "$p")"
      if systemctl --quiet is-active "$u" 2>/dev/null; then
        say "  LIVE_MOUNT_OURS path=$p unit=$u"
      else
        stop live_mount_conflict "path $p is already a mountpoint but unit $u is not active — refuse stack/overwrite"
      fi
    fi
  done
}

print_plan(){
  local p u
  say "PARENT_ENTRY_BIND plan commit=$COMMIT mode=$MODE"
  say "SCRIPT_IN_COMMIT=install+units+require (trial script is separate evidence file)"
  say ""
  say "PATHS<<"
  for p in "${PATHS[@]}"; do
    u="$(unit_name_for "$p")"
    say "  $p => $u"
  done
  say "PATHS>>"
  say ""
  say "INSTALL_FILES<<"
  say "  $LIBDIR/require-entry-binds.sh"
  say "  $LIBDIR/PARENT-ENTRY-BIND.md"
  say "  $ETCDIR/policy"
  say "  $UNITDIR/$TARGET_NAME"
  for u in "${UNIT_NAMES[@]}"; do
    say "  $UNITDIR/$u"
  done
  say "INSTALL_FILES>>"
  say ""
  say "ORDER_START<< parents then projects"
  say "  1) systemctl daemon-reload"
  say "  2) systemctl enable $TARGET_NAME"
  say "  3) systemctl start $TARGET_NAME   # pulls Requires= mounts; parents Before children via unit deps"
  say "ORDER_START>>"
  say "ORDER_STOP<< reverse (systemd stops Requires= then target)"
  say "  systemctl stop $TARGET_NAME"
  say "  systemctl disable $TARGET_NAME"
  say "ORDER_STOP>>"
  say ""
  say "WIRING<<"
  say "  bin/aegl-task task promote|register|record → require_parent_entry_binds"
  say "  (enforces only when $POLICY exists; then live findmnt exact mountpoints required)"
  say "  host-identity-bootstrap switch_preconditions → same check"
  say "WIRING>>"
  say ""
  say "REMOVE<<"
  say "  --remove: stop/disable target; rm only this pack's units, $LIBDIR, $ETCDIR"
  say "  does not touch foreign mounts, fstab, chattr, or other units"
  say "REMOVE>>"
  say "FORMAL_DEPLOY=NOT_DONE (this command alone does not install unless --apply)"
  say "AI_BOUNDARY=BLOCKED"
}

extract_to(){
  local dest="$1" src_path="$2"
  git -C "$REPO" show "$COMMIT:$src_path" > "$dest" \
    || fail "extract failed: $src_path"
}

do_apply(){
  [ "$(id -u)" = 0 ] || fail "--apply requires root"
  pack_paths_in_commit
  check_conflicts
  install -d -o root -g root -m 0755 "$LIBDIR" "$ETCDIR" "$UNITDIR"
  extract_to "$LIBDIR/require-entry-binds.sh" "recovery/parent-entry-bind/require-entry-binds.sh"
  extract_to "$LIBDIR/PARENT-ENTRY-BIND.md" "recovery/parent-entry-bind/PARENT-ENTRY-BIND.md"
  chmod 0755 "$LIBDIR/require-entry-binds.sh"
  chmod 0644 "$LIBDIR/PARENT-ENTRY-BIND.md"
  local u p
  for p in "${PATHS[@]}"; do
    u="$(unit_name_for "$p")"
    extract_to "$UNITDIR/$u" "recovery/parent-entry-bind/units/$u"
    chmod 0644 "$UNITDIR/$u"
  done
  extract_to "$UNITDIR/$TARGET_NAME" "recovery/parent-entry-bind/$TARGET_NAME"
  chmod 0644 "$UNITDIR/$TARGET_NAME"
  {
    printf 'commit=%s\n' "$COMMIT"
    printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for p in "${PATHS[@]}"; do
      printf 'path=%s\n' "$p"
      printf 'unit=%s\n' "$(unit_name_for "$p")"
    done
    printf 'note=policy_lists_paths;protection_requires_live_findmnt_not_marker_alone\n'
  } > "$POLICY"
  chmod 0644 "$POLICY"
  chown root:root "$POLICY"
  systemctl daemon-reload
  systemctl enable "$TARGET_NAME"
  systemctl start "$TARGET_NAME" \
    || fail "systemctl start $TARGET_NAME failed — mounts NOT claimed OK"
  # Post-start live verify (not marker-only)
  bash "$LIBDIR/require-entry-binds.sh" \
    || fail "post-start live mount check failed"
  say "INSTALL_RESULT=OK mode=apply commit=$COMMIT"
  say "FORMAL_DEPLOY=UNITS_STARTED (verify with require-entry-binds / findmnt)"
  say "AI_BOUNDARY=BLOCKED"
  say "STOP_AT=complete"
}

do_remove(){
  [ "$(id -u)" = 0 ] || fail "--remove requires root"
  say "PARENT_ENTRY_BIND remove (this pack only)"
  systemctl stop "$TARGET_NAME" 2>/dev/null || true
  systemctl disable "$TARGET_NAME" 2>/dev/null || true
  local u
  for u in "${UNIT_NAMES[@]}" "$TARGET_NAME"; do
    if [ -e "$UNITDIR/$u" ]; then
      # Only remove if it matches our committed content when COMMIT known, else refuse foreign
      if git -C "$REPO" show "$COMMIT:recovery/parent-entry-bind/units/$u" >/dev/null 2>&1 \
         || [ "$u" = "$TARGET_NAME" ]; then
        local want got srcp
        if [ "$u" = "$TARGET_NAME" ]; then srcp="recovery/parent-entry-bind/$TARGET_NAME"
        else srcp="recovery/parent-entry-bind/units/$u"; fi
        want="$(git -C "$REPO" show "$COMMIT:$srcp" | sha256sum | awk '{print $1}')"
        got="$(sha256sum "$UNITDIR/$u" | awk '{print $1}')"
        if [ "$want" = "$got" ]; then
          rm -f "$UNITDIR/$u"
          say "  REMOVED $UNITDIR/$u"
        else
          stop remove_conflict "$UNITDIR/$u content mismatch — refuse delete"
        fi
      fi
    fi
  done
  rm -f "$POLICY"
  rm -rf "$LIBDIR"
  rmdir "$ETCDIR" 2>/dev/null || true
  systemctl daemon-reload
  say "REMOVE_RESULT=OK"
  say "STOP_AT=complete"
}

pack_paths_in_commit
check_conflicts
print_plan

case "$MODE" in
  plan)
    say "MODE=plan (pass --apply to install; --remove to uninstall this pack)"
    say "STOP_AT=plan_ok"
    ;;
  apply) do_apply ;;
  remove) do_remove ;;
  *) fail "bad mode $MODE" ;;
esac
