#!/usr/bin/env bash
# Install OR upgrade the fixed task-registry payload from a root-exclusive,
# already-verified directory. This script never runs git and never reads the
# development checkout.
#
#   install-model-task-registry.sh --payload-dir DIR                 # first install
#   install-model-task-registry.sh --upgrade --payload-dir DIR       # controlled upgrade
#
# Upgrade policy: verify the EXISTING target (owner/mode + the approved OLD hashes),
# stage the new payload, verify it, then atomically replace each file. The install
# directory is never removed, permissions are never relaxed and no backup is kept.
set -euo pipefail

CLI_REL="bin/aegl-model-task"
MOD_REL="recovery/model_task_registry.py"
CLI_SHA="edb38c2155f617417c8f225128144fba94c822db317a799613fa5e9203669b6e"
MOD_SHA="baa7133e990a9009256068ac75b772a79d426a45678cd010b8301cdb6dc41491"
# Approved hash of the previously installed module, for a controlled upgrade from the
# original GT1 install. Matches MOD_SHA when there is nothing to upgrade from.
MOD_SHA_OLD="0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de"
TARGET="/usr/local/lib/aegl-model-task"
PARENT_DIR="/usr/local/lib"

say() { printf '%s\n' "$*"; }
fail() { printf 'INSTALL_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail not_root "run as root from a trusted terminal"
for tool in sha256sum mktemp realpath stat install mv chmod; do
  command -v "$tool" >/dev/null 2>&1 || fail missing_tool "$tool"
done

UPGRADE=0
PAYLOAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upgrade) UPGRADE=1; shift ;;
    --payload-dir) PAYLOAD="${2:-}"; shift 2 ;;
    *) fail usage "unknown argument: $1" ;;
  esac
done
[ -n "$PAYLOAD" ] || fail usage "--payload-dir is required"
[ -d "$PAYLOAD" ] || fail payload_missing "$PAYLOAD"
PAYLOAD="$(realpath -e "$PAYLOAD")" || fail payload_missing "$PAYLOAD"
[ ! -L "$PAYLOAD" ] || fail payload_symlink "$PAYLOAD"
[ "$(stat -c '%U:%G %a' "$PAYLOAD")" = "root:root 700" ] \
  || fail payload_not_root_exclusive "$(stat -c '%U:%G %a' "$PAYLOAD")"

for rel in "$CLI_REL" "$MOD_REL"; do
  [ -f "$PAYLOAD/$rel" ] || fail payload_file_missing "$rel"
  [ ! -L "$PAYLOAD/$rel" ] || fail payload_symlink "$rel"
done
printf '%s  %s\n' "$CLI_SHA" "$PAYLOAD/$CLI_REL" | sha256sum -c - >/dev/null || fail cli_hash
printf '%s  %s\n' "$MOD_SHA" "$PAYLOAD/$MOD_REL" | sha256sum -c - >/dev/null || fail module_hash

MANIFEST="$PAYLOAD/recovery/gt1-install-manifest.txt"
[ -f "$MANIFEST" ] || fail manifest_missing "$MANIFEST"
[ ! -L "$MANIFEST" ] || fail manifest_symlink "$MANIFEST"
[ "$(stat -c '%U:%G' "$MANIFEST")" = "root:root" ] || fail manifest_owner
[ -r "$MANIFEST" ] || fail manifest_unreadable

[ -d "$PARENT_DIR" ] || fail parent_missing "$PARENT_DIR"
PARENT_STAT="$(stat -c '%U:%G %a' "$PARENT_DIR")"
case "$PARENT_STAT" in
  "root:root 755"|"root:root 0755") ;;
  *) fail parent_untrusted "$PARENT_STAT" ;;
esac

# --------------------------------------------------------------------------- #
# Target state
# --------------------------------------------------------------------------- #
if [ "$UPGRADE" -eq 0 ]; then
  [ ! -e "$TARGET" ] || fail target_exists "$TARGET (use --upgrade for a controlled upgrade)"
else
  [ -d "$TARGET" ] || fail upgrade_target_missing "$TARGET"
  [ ! -L "$TARGET" ] || fail upgrade_target_symlink "$TARGET"
  T_STAT="$(stat -c '%U:%G %a' "$TARGET")"
  case "$T_STAT" in
    "root:root 755"|"root:root 0755") ;;
    *) fail upgrade_target_untrusted "$T_STAT" ;;
  esac
  for rel in "$CLI_REL" "$MOD_REL"; do
    [ -f "$TARGET/$rel" ] || fail upgrade_file_missing "$rel"
    [ ! -L "$TARGET/$rel" ] || fail upgrade_file_symlink "$rel"
  done
  # the OLD installed module must be exactly the approved predecessor
  printf '%s  %s\n' "$MOD_SHA_OLD" "$TARGET/$MOD_REL" | sha256sum -c - >/dev/null \
    || fail upgrade_old_module_hash "not the approved predecessor hash"
  printf '%s  %s\n' "$CLI_SHA" "$TARGET/$CLI_REL" | sha256sum -c - >/dev/null \
    || fail upgrade_old_cli_hash "installed cli is not the approved hash"
  if [ "$(sha256sum "$TARGET/$MOD_REL" | awk '{print $1}')" = "$MOD_SHA" ]; then
    say "UPGRADE=ALREADY_AT_TARGET (module already $MOD_SHA)"; say "INSTALL=OK"; exit 0
  fi
fi

# --------------------------------------------------------------------------- #
# Stage the new payload (root-exclusive, same filesystem for atomic rename)
# --------------------------------------------------------------------------- #
STAGE="$(mktemp -d "$PARENT_DIR/.aegl-model-task.install.XXXXXX")" || fail stage_dir
chmod 0700 "$STAGE"
cleanup() { [ -n "${STAGE:-}" ] && rm -rf "$STAGE" 2>/dev/null || true; }
trap cleanup EXIT

install -d -o root -g root -m 0755 "$STAGE/bin" "$STAGE/recovery"
install -o root -g root -m 0755 "$PAYLOAD/$CLI_REL" "$STAGE/$CLI_REL"
install -o root -g root -m 0644 "$PAYLOAD/$MOD_REL" "$STAGE/$MOD_REL"

test "$(stat -c '%U:%G %a' "$STAGE/bin")" = "root:root 755" || fail stage_bin_mode
test "$(stat -c '%U:%G %a' "$STAGE/recovery")" = "root:root 755" || fail stage_recovery_mode
test "$(stat -c '%U:%G %a' "$STAGE/$CLI_REL")" = "root:root 755" || fail stage_cli_mode
test "$(stat -c '%U:%G %a' "$STAGE/$MOD_REL")" = "root:root 644" || fail stage_module_mode
printf '%s  %s\n' "$CLI_SHA" "$STAGE/$CLI_REL" | sha256sum -c - >/dev/null || fail stage_cli_hash
printf '%s  %s\n' "$MOD_SHA" "$STAGE/$MOD_REL" | sha256sum -c - >/dev/null || fail stage_module_hash

if [ "$UPGRADE" -eq 0 ]; then
  chmod 0755 "$STAGE"
  [ ! -e "$TARGET" ] || fail target_appeared "$TARGET"
  mv -T "$STAGE" "$TARGET" || fail move_failed "$TARGET"
  STAGE=""
else
  # atomic PER-FILE replace into the existing directory; directory kept, no backup
  for rel in "$CLI_REL" "$MOD_REL"; do
    [ -d "$TARGET/$(dirname "$rel")" ] || fail upgrade_subdir_missing "$(dirname "$rel")"
    mv -T "$STAGE/$rel" "$TARGET/$rel" || fail upgrade_replace_failed "$rel"
  done
  rmdir "$STAGE/bin" "$STAGE/recovery" "$STAGE" 2>/dev/null || true
  STAGE=""
fi

# --------------------------------------------------------------------------- #
# Post-install verification, including the module the ENTRYPOINT actually loads
# --------------------------------------------------------------------------- #
test "$(stat -c '%U:%G %a' "$TARGET")" = "root:root 755" || fail target_mode
test "$(stat -c '%U:%G %a' "$TARGET/bin")" = "root:root 755" || fail target_bin_mode
test "$(stat -c '%U:%G %a' "$TARGET/recovery")" = "root:root 755" || fail target_recovery_mode
test "$(stat -c '%U:%G %a' "$TARGET/$CLI_REL")" = "root:root 755" || fail target_cli_mode
test "$(stat -c '%U:%G %a' "$TARGET/$MOD_REL")" = "root:root 644" || fail target_module_mode
printf '%s  %s\n' "$CLI_SHA" "$TARGET/$CLI_REL" | sha256sum -c - >/dev/null || fail target_cli_hash
printf '%s  %s\n' "$MOD_SHA" "$TARGET/$MOD_REL" | sha256sum -c - >/dev/null || fail target_module_hash

# The CLI shim resolves ROOT=$TARGET and imports "$ROOT/recovery/model_task_registry.py".
# Assert that resolved path IS the file we just verified, so the check cannot pass on a
# copy that is never loaded.
ENTRY="$TARGET/$CLI_REL"
RESOLVED="$("$ENTRY" --help >/dev/null 2>&1; printf '%s' "$ENTRY" | sed -n 's#^\(.*\)/bin/.*#\1#p')"
[ "$RESOLVED" = "$TARGET" ] || fail entrypoint_unresolved "cli does not resolve to $TARGET"
LOADED="$TARGET/recovery/model_task_registry.py"
[ -f "$LOADED" ] || fail loaded_module_missing "$LOADED"
LOADED_SHA="$(sha256sum "$LOADED" | awk '{print $1}')"
[ "$LOADED_SHA" = "$MOD_SHA" ] || fail loaded_module_hash "loaded module $LOADED_SHA != $MOD_SHA"

say "INSTALL_PAYLOAD_SHA_CLI=$CLI_SHA"
say "INSTALL_PAYLOAD_SHA_MODULE=$MOD_SHA"
say "INSTALL_LOADED_MODULE=$LOADED"
say "INSTALL_TARGET=$TARGET"
if [ "$UPGRADE" -eq 1 ]; then
  say "INSTALL_MODE=upgrade (files replaced atomically; directory kept; no backup)"
else
  say "INSTALL_MODE=first (only $TARGET created)"
fi
say "INSTALL_IMPACT=only $TARGET touched; /usr/local/lib/aegl-model and all other paths untouched"
say "INSTALL=OK"
