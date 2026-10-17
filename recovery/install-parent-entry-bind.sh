#!/usr/bin/env bash
# install-parent-entry-bind.sh — plan-by-default installer for five RW self-bind
# mount units + aegl-entry-bind.target. Does NOT claim protection via marker alone.
#
# Trusted delivery (formal AEGL unread by zhong after host-identity switch):
#   TIP=<full-40-hex>   # after controller import + broker promote onto main
#   AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer
#   DEV=/var/tmp/aegl-parent-protection-dev-6yv9e5/repo   # tip source checkout
#   # 1) Import objects (root Git: command-level exact safe.directory only)
#   sudo git -C "$AEGL" -c "safe.directory=$AEGL" -c "safe.directory=$DEV" \
#     fetch "$DEV" "$TIP"
#   # 2) Normal broker register/record/promote of TIP onto refs/heads/main
#   # 3) Extract installer + verify into root-only dir (never sudo user tree scripts)
#   RDIR=$(sudo mktemp -d /var/tmp/aegl-entry-bind-root-XXXXXX)
#   sudo install -o root -g root -m 0700 -d "$RDIR"
#   sudo git -C "$AEGL" -c "safe.directory=$AEGL" show \
#     "$TIP:recovery/install-parent-entry-bind.sh" \
#     | sudo tee "$RDIR/install-parent-entry-bind.sh" >/dev/null
#   sudo chmod 0755 "$RDIR/install-parent-entry-bind.sh"
#   WANT=$(sudo git -C "$AEGL" -c "safe.directory=$AEGL" show \
#     "$TIP:recovery/install-parent-entry-bind.sh" | sha256sum | awk '{print $1}')
#   GOT=$(sha256sum "$RDIR/install-parent-entry-bind.sh" | awk '{print $1}')
#   test "$WANT" = "$GOT"
#   sudo bash "$RDIR/install-parent-entry-bind.sh" --repo "$AEGL" --commit "$TIP"
#   sudo bash "$RDIR/install-parent-entry-bind.sh" --repo "$AEGL" --commit "$TIP" --apply
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
CHECKER_NAME=require-entry-binds.sh
DOC_NAME=PARENT-ENTRY-BIND.md

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

# Root (and any caller): exact-path safe.directory only — never safe.directory=*
git_repo(){
  git -C "$REPO" -c "safe.directory=$REPO" "$@"
}

git_repo cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "commit not in repo: $COMMIT"
git_repo cat-file -e "$COMMIT:recovery/install-parent-entry-bind.sh" 2>/dev/null \
  || fail "installer missing in commit $COMMIT"
git_repo cat-file -e "$COMMIT:recovery/parent-entry-bind/aegl-entry-bind.target" 2>/dev/null \
  || fail "target unit missing in commit $COMMIT"

command -v systemd-escape >/dev/null || fail "systemd-escape required"
command -v findmnt >/dev/null || fail "findmnt required"
command -v systemctl >/dev/null || fail "systemctl required"

unit_name_for(){ systemd-escape -p --suffix=mount "$1"; }

src_path_for_unit(){
  local u="$1"
  if [ "$u" = "$TARGET_NAME" ]; then
    printf '%s\n' "recovery/parent-entry-bind/$TARGET_NAME"
  else
    printf '%s\n' "recovery/parent-entry-bind/units/$u"
  fi
}

want_sha_for_unit(){
  local u="$1" srcp
  srcp="$(src_path_for_unit "$u")"
  git_repo show "$COMMIT:$srcp" | sha256sum | awk '{print $1}'
}

UNIT_NAMES=()
for p in "${PATHS[@]}"; do
  UNIT_NAMES+=("$(unit_name_for "$p")")
done

pack_paths_in_commit(){
  local p u
  for p in "${PATHS[@]}"; do
    u="$(unit_name_for "$p")"
    git_repo cat-file -e "$COMMIT:recovery/parent-entry-bind/units/$u" 2>/dev/null \
      || fail "unit missing in commit: recovery/parent-entry-bind/units/$u"
  done
  git_repo cat-file -e "$COMMIT:recovery/parent-entry-bind/$CHECKER_NAME" 2>/dev/null \
    || fail "$CHECKER_NAME missing in commit"
  git_repo cat-file -e "$COMMIT:recovery/parent-entry-bind/$DOC_NAME" 2>/dev/null \
    || fail "$DOC_NAME missing in commit"
}

# True ownership: FragmentPath + content hash + no drop-ins + no symlink.
# Active unit name alone is NOT ownership.
unit_owned_by_pack(){
  local u="$1" path="$UNITDIR/$u" want got frag drops
  [ -e "$path" ] || return 1
  [ ! -L "$path" ] || return 1
  [ -f "$path" ] || return 1
  if [ -e "$UNITDIR/$u.d" ] || [ -L "$UNITDIR/$u.d" ]; then
    return 1
  fi
  want="$(want_sha_for_unit "$u")"
  got="$(sha256sum "$path" | awk '{print $1}')"
  [ "$want" = "$got" ] || return 1
  if systemctl show "$u" >/dev/null 2>&1; then
    frag="$(systemctl show -p FragmentPath --value "$u" 2>/dev/null || true)"
    if [ -n "$frag" ] && [ "$frag" != "$path" ]; then
      return 1
    fi
    drops="$(systemctl show -p DropInPaths --value "$u" 2>/dev/null || true)"
    if [ -n "${drops// }" ]; then
      return 1
    fi
  fi
  return 0
}

assert_unit_owned_or_absent(){
  local u="$1"
  if [ ! -e "$UNITDIR/$u" ]; then
    return 0
  fi
  if unit_owned_by_pack "$u"; then
    say "  UNIT_OWNED $u"
    return 0
  fi
  stop unit_ownership_conflict \
    "$UNITDIR/$u unknown ownership (symlink, drop-in, FragmentPath mismatch, or content mismatch) — refuse"
}

# Conflict detection — stop, never overwrite / stack.
check_conflicts(){
  local p u
  if [ -f /etc/fstab ]; then
    for p in "${PATHS[@]}"; do
      if awk -v w="$p" 'BEGIN{ok=0} $1!~/^#/ && $2==w {ok=1} END{exit !ok}' /etc/fstab; then
        stop fstab_conflict "fstab already has Where=$p — refuse (no overwrite)"
      fi
    done
  fi
  for u in "${UNIT_NAMES[@]}" "$TARGET_NAME"; do
    if [ -e "$UNITDIR/$u" ] || [ -L "$UNITDIR/$u" ]; then
      if [ -L "$UNITDIR/$u" ]; then
        stop unit_symlink_conflict "$UNITDIR/$u is a symlink — refuse"
      fi
      if [ -e "$UNITDIR/$u.d" ] || [ -L "$UNITDIR/$u.d" ]; then
        stop unit_dropin_conflict "$UNITDIR/$u.d present — refuse"
      fi
      if unit_owned_by_pack "$u"; then
        say "  UNIT_PRESENT_MATCH $u"
      else
        if [ "$MODE" = apply ] || [ "$MODE" = remove ]; then
          stop unit_conflict "$UNITDIR/$u exists with foreign/mismatched content — refuse"
        else
          say "  UNIT_PRESENT_FOREIGN $UNITDIR/$u (plan: --apply will refuse)"
        fi
      fi
    fi
  done
  for p in "${PATHS[@]}"; do
    if findmnt -n -o TARGET --mountpoint "$p" >/dev/null 2>&1; then
      u="$(unit_name_for "$p")"
      if unit_owned_by_pack "$u" && systemctl --quiet is-active "$u" 2>/dev/null; then
        say "  LIVE_MOUNT_OURS path=$p unit=$u"
      else
        stop live_mount_conflict \
          "path $p is a mountpoint but not an owned active pack unit ($u) — refuse stack/overwrite"
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
  say "  $LIBDIR/$CHECKER_NAME"
  say "  $LIBDIR/$DOC_NAME"
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
  say "  3) systemctl start $TARGET_NAME"
  say "  4) write $POLICY then run $LIBDIR/$CHECKER_NAME"
  say "ORDER_START>>"
  say "ORDER_STOP<< explicit reverse (child mounts then parents then target)"
  say "  stop mounts in reverse PATHS order; stop/disable $TARGET_NAME; verify unmounted"
  say "ORDER_STOP>>"
  say ""
  say "WIRING<<"
  say "  /usr/local/lib/aegl-entry-bind/require-entry-binds.sh (fixed policy /etc/aegl/entry-bind/policy)"
  say "  bin/aegl-hermes-sandbox — before sandbox prepare (installed via install-model-broker)"
  say "  recovery/promotion_broker.py — before apply_to_ref (installed via install-broker + restart)"
  say "  bin/aegl-task / host-identity-bootstrap — same installed checker (defense-in-depth)"
  say "  Source tip alone does NOT update /usr/local/lib/aegl-model or /usr/local/lib/aegl-promote"
  say "WIRING>>"
  say ""
  say "REMOVE<<"
  say "  --remove: ownership check first; reverse stop; verify unmounted; delete only hash-matched files"
  say "  stop/unmount failure keeps $POLICY and units; non-zero; never claims success"
  say "  no recursive rm of $LIBDIR; no foreign mounts/fstab/chattr"
  say "REMOVE>>"
  say "FORMAL_DEPLOY=NOT_DONE (this command alone does not install unless --apply)"
  say "AI_BOUNDARY=BLOCKED"
}

extract_to(){
  local dest="$1" src_path="$2"
  git_repo show "$COMMIT:$src_path" > "$dest" \
    || fail "extract failed: $src_path"
}

do_apply(){
  [ "$(id -u)" = 0 ] || fail "--apply requires root"
  pack_paths_in_commit
  check_conflicts
  install -d -o root -g root -m 0755 "$LIBDIR" "$ETCDIR" "$UNITDIR"
  extract_to "$LIBDIR/$CHECKER_NAME" "recovery/parent-entry-bind/$CHECKER_NAME"
  extract_to "$LIBDIR/$DOC_NAME" "recovery/parent-entry-bind/$DOC_NAME"
  chmod 0755 "$LIBDIR/$CHECKER_NAME"
  chmod 0644 "$LIBDIR/$DOC_NAME"
  chown root:root "$LIBDIR/$CHECKER_NAME" "$LIBDIR/$DOC_NAME"
  local u p
  for p in "${PATHS[@]}"; do
    u="$(unit_name_for "$p")"
    extract_to "$UNITDIR/$u" "recovery/parent-entry-bind/units/$u"
    chmod 0644 "$UNITDIR/$u"
    chown root:root "$UNITDIR/$u"
  done
  extract_to "$UNITDIR/$TARGET_NAME" "recovery/parent-entry-bind/$TARGET_NAME"
  chmod 0644 "$UNITDIR/$TARGET_NAME"
  chown root:root "$UNITDIR/$TARGET_NAME"
  systemctl daemon-reload
  systemctl enable "$TARGET_NAME"
  systemctl start "$TARGET_NAME" \
    || fail "systemctl start $TARGET_NAME failed — policy NOT written; mounts NOT claimed OK"
  {
    printf 'commit=%s\n' "$COMMIT"
    printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for p in "${PATHS[@]}"; do
      printf 'path=%s\n' "$p"
      printf 'unit=%s\n' "$(unit_name_for "$p")"
    done
    printf 'note=policy_lists_paths;protection_requires_live_findmnt_rw_bind_not_marker_alone\n'
  } > "$POLICY"
  chmod 0644 "$POLICY"
  chown root:root "$POLICY"
  bash "$LIBDIR/$CHECKER_NAME" \
    || fail "post-start live RW self-bind check failed"
  say "INSTALL_RESULT=OK mode=apply commit=$COMMIT"
  say "FORMAL_DEPLOY=UNITS_STARTED (verify with require-entry-binds / findmnt)"
  say "AI_BOUNDARY=BLOCKED"
  say "STOP_AT=complete"
}

do_remove(){
  [ "$(id -u)" = 0 ] || fail "--remove requires root"
  say "PARENT_ENTRY_BIND remove (this pack only)"
  pack_paths_in_commit

  local u p i
  # 1) Ownership first — never stop/delete foreign units
  for u in "${UNIT_NAMES[@]}" "$TARGET_NAME"; do
    assert_unit_owned_or_absent "$u"
  done
  for p in "${PATHS[@]}"; do
    if findmnt -n -o TARGET --mountpoint "$p" >/dev/null 2>&1; then
      u="$(unit_name_for "$p")"
      if ! unit_owned_by_pack "$u"; then
        stop remove_foreign_mount \
          "live mount at $p is not owned by this pack — keeping policy/units; refuse"
      fi
    fi
  done

  # 2) Explicit reverse stop (children → parents), then target
  for ((i=${#UNIT_NAMES[@]}-1; i>=0; i--)); do
    u="${UNIT_NAMES[i]}"
    if systemctl --quiet is-active "$u" 2>/dev/null; then
      systemctl stop "$u" \
        || stop remove_stop_failed "systemctl stop $u failed — keeping policy/units"
    fi
  done
  if systemctl --quiet is-active "$TARGET_NAME" 2>/dev/null; then
    systemctl stop "$TARGET_NAME" \
      || stop remove_stop_failed "systemctl stop $TARGET_NAME failed — keeping policy/units"
  fi
  systemctl disable "$TARGET_NAME" 2>/dev/null || true

  # 3) Verify all five unmounted — failure keeps config+policy
  for p in "${PATHS[@]}"; do
    if findmnt -n -o TARGET --mountpoint "$p" >/dev/null 2>&1; then
      stop remove_still_mounted \
        "still a mountpoint after stop: $p — keeping policy/units; REMOVE not successful"
    fi
  done

  # 4) Delete only confirmed pack files (exact paths; no recursive LIBDIR wipe)
  for u in "${UNIT_NAMES[@]}" "$TARGET_NAME"; do
    if [ -e "$UNITDIR/$u" ]; then
      unit_owned_by_pack "$u" \
        || stop remove_ownership_race "$UNITDIR/$u ownership lost before delete — refuse"
      rm -f "$UNITDIR/$u"
      say "  REMOVED $UNITDIR/$u"
    fi
  done
  if [ -f "$LIBDIR/$CHECKER_NAME" ]; then
    rm -f "$LIBDIR/$CHECKER_NAME"
    say "  REMOVED $LIBDIR/$CHECKER_NAME"
  fi
  if [ -f "$LIBDIR/$DOC_NAME" ]; then
    rm -f "$LIBDIR/$DOC_NAME"
    say "  REMOVED $LIBDIR/$DOC_NAME"
  fi
  if [ -d "$LIBDIR" ]; then
    rmdir "$LIBDIR" 2>/dev/null \
      || stop remove_libdir_not_empty \
        "$LIBDIR not empty after exact deletes — refuse recursive rm; inspect manually"
  fi
  rm -f "$POLICY"
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
